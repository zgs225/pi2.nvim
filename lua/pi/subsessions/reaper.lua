--- Idle reaper for settled sub-session child processes.
---
--- A finished/interrupted child keeps its `pi --mode rpc` process alive after
--- `agent_settled` (the manifest is only patched to a settled status), so long
--- sessions accumulate dozens of idle processes. Two mechanisms close them:
--- event-driven (`M.schedule`, armed from `on_child_settled`) and a periodic
--- `M.sweep` backstop. Every close re-validates at fire time:
---
---   a) the child is still in the Sessions registry with a live RPC process;
---   b) its manifest status is settled (`completed`/`interrupted`/`failed`) —
---      `active` means revived / new task, `dormant` means the process is
---      already gone, both are skipped;
---   c) it is not the current session of any tabpage (never kill what the
---      user is looking at).
---
--- Closing goes through `Subsessions.close`: manifest turns `dormant`, the
--- session JSONL is retained and the child stays revivable via dispatch.

local M = {}

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Sessions = require("pi.sessions.manager")

--- Manifest statuses that mean "no run in flight" — safe to reap.
local settled_status = {
    completed = true,
    failed = true,
    interrupted = true,
}

--- Periodic sweep timer (nil when disabled/stopped). Held at module scope so
--- libuv cannot GC it out from under us (G26).
---@type uv.uv_timer_t?
local sweep_timer
local leave_autocmd_registered = false

--- Subagent config, read at call time — never cached at module load (G20).
---@return table
local function sub_opts()
    return Config.options.subagent or {}
end

--- @return number minutes Non-negative minute count (0 when unset).
local function reap_after_minutes()
    return math.max(tonumber(sub_opts().reap_after_minutes) or 0, 0)
end

--- @return number minutes Non-negative minute count (0 when unset).
local function reap_sweep_minutes()
    return math.max(tonumber(sub_opts().reap_sweep_minutes) or 0, 0)
end

--- True when `child_id` is the current session of some tabpage. Walks the
--- Sessions registry (attached children carry `attached_tab`; a `:tabclose`
--- detaches and clears it).
---@param child_id string
---@return boolean
local function is_viewed_child(child_id)
    for _, session in ipairs(Sessions.list_all()) do
        if session.id == child_id and session.attached_tab ~= nil then
            return true
        end
    end
    return false
end

--- Fire-time check: close `child_id` only when conditions (a), (b) and (c)
--- all hold. Silent no-op otherwise.
---@param child_id string
---@return boolean closed True when the child process was closed.
function M.reap(child_id)
    if type(child_id) ~= "string" or child_id == "" then
        return false
    end

    -- (a) still registered and the RPC process is alive
    local child = Sessions.get_by_id(child_id)
    if not child or not child.rpc or not child.rpc:is_running() then
        return false
    end

    -- (b) manifest must report a settled run
    local entry = Manifest.load()[child_id]
    if type(entry) ~= "table" or not settled_status[entry.status] then
        return false
    end

    -- (c) never close the session a tab is currently showing
    if is_viewed_child(child_id) then
        return false
    end

    require("pi.subsessions").close(child_id)
    return true
end

--- Event-driven arming: fire a single re-check after `reap_after_minutes`.
--- The defer is not cancellable — a revived child is caught by the status
--- re-check inside `M.reap` when the timer fires. No-op when the option is 0.
---@param child_id string
function M.schedule(child_id)
    if type(child_id) ~= "string" or child_id == "" then
        return
    end
    local minutes = reap_after_minutes()
    if minutes <= 0 then
        return
    end
    vim.defer_fn(function()
        -- uv timer callbacks are fast events; reap() touches registry/manifest.
        vim.schedule(function()
            M.reap(child_id)
        end)
    end, math.floor(minutes * 60 * 1000))
end

--- Full sweep: every settled child idle longer than `reap_after_minutes`.
--- Iterates the manifest first (age-gated by `last_active_at`), then live
--- registry children that have **no** manifest row (lost/corrupt manifest):
--- those fall back to the session JSONL for settled-ness and its file mtime
--- for idleness. A no-op when `reap_after_minutes` is 0.
---@return integer closed Number of children closed by this sweep.
function M.sweep()
    local minutes = reap_after_minutes()
    if minutes <= 0 then
        return 0
    end
    local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - math.floor(minutes * 60))
    local manifest = Manifest.load()
    local closed = 0

    -- Manifest children: settled status + idle past the threshold; `reap`
    -- re-validates registry liveness and tab view at close time.
    for id, entry in pairs(manifest) do
        if Manifest.is_entry_id(id) and type(entry) == "table" and entry.parent_id ~= nil then
            local last = entry.last_active_at
            if
                settled_status[entry.status]
                and type(last) == "string"
                and last ~= ""
                and last < cutoff
                and M.reap(id)
            then
                closed = closed + 1
            end
        end
    end

    -- Detached children missing from the manifest: prove settled from the
    -- session JSONL and idleness from its mtime (no manifest row means no
    -- `last_active_at` to age against).
    for _, session in ipairs(Sessions.list_all()) do
        local id = session.id
        if type(id) == "string" and id ~= "" and session.parent_id ~= nil and manifest[id] == nil then
            local path = session.session_file or Read.find_path(id)
            local rpc = session.rpc
            local alive = rpc ~= nil and rpc:is_running() == true
            local inferred = path ~= nil and Read.infer_run_status(path) or nil
            local mtime = path ~= nil and vim.fn.getftime(path) or -1
            local idle = mtime > 0 and (os.time() - mtime) >= minutes * 60
            if
                (inferred == "completed" or inferred == "interrupted")
                and idle
                and alive
                and not is_viewed_child(id)
            then
                require("pi.subsessions").close(id)
                closed = closed + 1
            end
        end
    end

    return closed
end

--- Start the periodic sweep timer (interval from `reap_sweep_minutes`).
--- No-op when the option is 0 or the timer is already running. Registers the
--- `VimLeavePre` stop hook once.
function M.start()
    local minutes = reap_sweep_minutes()
    if minutes <= 0 or sweep_timer then
        return
    end
    local interval = math.floor(minutes * 60 * 1000)
    local timer = assert(vim.uv.new_timer())
    timer:start(
        interval,
        interval,
        vim.schedule_wrap(function()
            M.sweep()
        end)
    )
    sweep_timer = timer

    if not leave_autocmd_registered then
        leave_autocmd_registered = true
        vim.api.nvim_create_autocmd("VimLeavePre", {
            group = vim.api.nvim_create_augroup("pi-subagent-reaper", { clear = false }),
            desc = "Stop the sub-session idle reaper before exit",
            callback = function()
                M.stop()
            end,
        })
    end
end

--- Stop the sweep timer. Idempotent.
function M.stop()
    local timer = sweep_timer
    if timer then
        sweep_timer = nil
        timer:stop()
        timer:close()
    end
end

--- Test helper: stop the timer so specs leave no state behind.
function M._reset()
    M.stop()
end

--- Test helper: whether the periodic sweep timer is armed.
---@return boolean
function M._sweep_running()
    return sweep_timer ~= nil
end

return M
