--- Idle reaper for settled sub-session child processes.
---
--- A finished/interrupted child keeps its `pi --mode rpc` process alive after
--- `agent_settled` (the manifest is only patched to a settled status), so long
--- sessions accumulate dozens of idle processes. Three mechanisms close them:
--- event-driven (`M.schedule`, armed from `on_child_settled`), a periodic
--- `M.sweep` backstop, and demand-driven auto-reap (`M.reap_oldest_settled`,
--- triggered when dispatch or spawn hits the `max_children` limit). Every close
--- re-validates at fire time:
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
---
--- The same module also owns the worktree backstop (`release_orphaned_worktrees`,
--- run at the top of every sweep): closing a child releases its worktree, but a
--- child that died without a close/settle (Neovim restarted, RPC exit raced the
--- manifest) still owns a checkout on disk.

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

--- True when conditions (a), (b) and (c) all hold for `child_id`.
---@param child_id string
---@param cwd? string workspace cwd expected to hold the row (default: locate it)
---@return boolean
local function can_reap(child_id, cwd)
    if type(child_id) ~= "string" or child_id == "" then
        return false
    end

    -- (a) still registered and the RPC process is alive
    local child = Sessions.get_by_id(child_id)
    if not child or not child.rpc or not child.rpc:is_running() then
        return false
    end

    -- (b) manifest must report a settled run. The row lives in the owner
    -- parent's workspace; the caller's cwd is only a hint, so fall back to
    -- locating it (a reap driven by a timer has no session context).
    ---@type pi.SubsessionManifestEntry?
    local entry = Manifest.load(cwd)[child_id]
    if type(entry) ~= "table" then
        entry = Manifest.locate(child_id, cwd)
    end
    if type(entry) ~= "table" or not settled_status[entry.status] then
        return false
    end

    -- (d) the integration engine owns the checkout while it is queued /
    -- resolving / applying — closing the process would pull the directory out
    -- from under it.
    if Manifest.integration_busy(entry) then
        return false
    end

    -- (c) never close the session a tab is currently showing
    if is_viewed_child(child_id) then
        return false
    end

    return true
end

--- Fire-time check: close `child_id` only when conditions (a), (b) and (c)
--- all hold. Silent no-op otherwise.
---@param child_id string
---@param cwd? string workspace cwd expected to hold the row (default: locate it)
---@return boolean closed True when the child process was closed.
function M.reap(child_id, cwd)
    if not can_reap(child_id, cwd) then
        return false
    end

    require("pi.subsessions").close(child_id)
    return true
end

--- Reap up to `needed` settled-but-alive children of `lineage_id`, oldest
--- first (manifest `last_active_at` ascending), to free spawn slots. Same
--- safety conditions as M.reap: registry row with a running RPC, settled
--- manifest status, and not the current session of any tabpage.
---@param lineage_id string
---@param needed integer
---@param exclude? table<string, boolean> Child ids never to reap (e.g. reuse targets of the batch being admitted).
---@param cwd? string workspace cwd holding the lineage's manifest (default: Neovim's cwd)
---@return integer reaped
function M.reap_oldest_settled(lineage_id, needed, exclude, cwd)
    if type(needed) ~= "number" or needed <= 0 or type(lineage_id) ~= "string" or lineage_id == "" then
        return 0
    end

    local manifest = Manifest.load(cwd)
    local candidates = {}
    for id, entry in pairs(manifest) do
        if
            Manifest.is_entry_id(id)
            and type(entry) == "table"
            and entry.parent_id == lineage_id
            and settled_status[entry.status]
            and not (exclude and exclude[id])
        then
            candidates[#candidates + 1] = {
                id = id,
                last_active_at = tostring(entry.last_active_at or ""),
            }
        end
    end

    table.sort(candidates, function(a, b)
        if a.last_active_at ~= b.last_active_at then
            return a.last_active_at < b.last_active_at
        end
        return a.id < b.id
    end)

    local reaped = 0
    for _, candidate in ipairs(candidates) do
        if reaped >= needed then
            break
        end
        if M.reap(candidate.id, cwd) then
            reaped = reaped + 1
        end
    end

    return reaped
end

--- Release worktrees of orphaned children in one manifest.
---
--- The session manager owns worktree release for every session it still knows
--- about: `close_session` (which `Subsessions.close` / `M.reap` go through) and
--- the `_process_exit` handler both hand the worktree back with a once-only
--- guard. This backstop only covers rows no registry session owns — the state left
--- behind by a Neovim restart, where a child's checkout would otherwise live on
--- disk forever — and `Subsessions.release_worktree` still refuses a path any
--- live session is rooted in (the manifest id can lag the registry id during a
--- revive). `pi.worktree.release` deletes a clean checkout only, so uncommitted
--- child work always survives for a revive to reuse; an already removed
--- directory is skipped before the call.
---@param manifest table<string, pi.SubsessionManifestEntry>
---@return integer released Number of children whose worktree was released.
local function release_orphans_in(manifest)
    local released = 0
    for id, entry in pairs(manifest) do
        -- The worktree record is read structurally: the manifest row class is
        -- owned by the manifest module, this is just the backstop consumer.
        local row = entry --[[@as table]]
        if Manifest.is_entry_id(id) and type(row) == "table" and Sessions.get_by_id(id) == nil then
            -- Rows the integration engine has a record for are the engine's
            -- business, not this backstop's: `queued`/`resolving`/`applying` are
            -- mid-flight, and an `applied`/`needs_attention` checkout may still
            -- hold changes the engine has not finished with. Direct
            -- `Worktree.release` would also refuse a dirty checkout forever.
            -- Engine-driven cleanup is `Integration.enforce_retention`.
            local engine_owned = Manifest.integration_state(row) ~= nil
            local info = row.worktree
            local path = type(info) == "table" and info.path or nil
            if
                not engine_owned
                and type(path) == "string"
                and path ~= ""
                and vim.fn.isdirectory(path) == 1
                and require("pi.subsessions").release_worktree(id)
            then
                released = released + 1
            end
        end
    end
    return released
end

--- Release the worktrees of orphaned children in `cwd`'s manifest.
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return integer released Number of children whose worktree was released.
function M.release_orphaned_worktrees(cwd)
    return release_orphans_in(Manifest.load(cwd))
end

--- Event-driven arming: fire a single re-check after `reap_after_minutes`.
--- The defer is not cancellable — a revived child is caught by the status
--- re-check inside `M.reap` when the timer fires. No-op when the option is 0.
---@param child_id string
---@param cwd? string workspace cwd that holds the child's row (default: locate it)
function M.schedule(child_id, cwd)
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
            M.reap(child_id, cwd)
        end)
    end, math.floor(minutes * 60 * 1000))
end

--- Sweep one manifest scope: storage backstop plus idle reaping.
---@param scope pi.SubsessionScope
---@param minutes integer reap threshold in minutes (0 = storage cleanup only)
---@param cutoff string ISO cutoff derived from `minutes`
---@return integer closed Number of children closed by this scope.
local function sweep_scope(scope, minutes, cutoff)
    local manifest = Manifest.load_at(scope.path)
    local closed = 0

    -- Storage backstop, independent of process reaping: a worktree left behind
    -- by a dead child is disk usage, not a live-process leak.
    pcall(release_orphans_in, manifest)

    if minutes <= 0 then
        return 0
    end

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
                and M.reap(id, scope.cwd)
            then
                closed = closed + 1
            end
        end
    end

    -- Detached children whose workspace reports this manifest but that have
    -- **no** row in it (lost/corrupt manifest): prove settled-ness from the
    -- session JSONL and idleness from its mtime. The transcript lives in the
    -- child's own workspace (its worktree), so the lookup uses the session's
    -- own cwd and recorded file, not the manifest's.
    for _, session in ipairs(Sessions.list_all()) do
        local id = session.id
        if
            type(id) == "string"
            and id ~= ""
            and session.parent_id ~= nil
            and manifest[id] == nil
            and Manifest.path(Manifest.workspace(session)) == scope.path
        then
            local session_file = session.session_file
            local path
            if type(session_file) == "string" and session_file ~= "" and vim.fn.filereadable(session_file) == 1 then
                path = session_file
            else
                path = Read.find_path(id, { cwd = session.cwd })
            end
            local rpc = session.rpc
            local alive = rpc ~= nil and rpc:is_running() == true
            local inferred = path ~= nil and Read.infer_run_status(path) or nil
            local mtime = path ~= nil and vim.fn.getftime(path) or -1
            local idle = mtime > 0 and (os.time() - mtime) >= minutes * 60
            if
                (inferred == "completed" or inferred == "interrupted" or inferred == "failed")
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

--- Full sweep across every workspace.
---
--- Scopes come from `Manifest.scopes`: the process cwd, every live session's
--- workspace, and every manifest on disk — so a tab running in another checkout
--- (or a workspace no live session reports after a restart) is swept too, which
--- the old process-cwd-only sweep silently skipped. Within a scope the manifest
--- comes first (age-gated by `last_active_at`), then live registry children
--- with no row in that workspace's manifest. A no-op for reaping when
--- `reap_after_minutes` is 0 (the storage backstop still runs).
---@return integer closed Number of children closed by this sweep.
function M.sweep()
    local minutes = reap_after_minutes()
    local cutoff = ""
    if minutes > 0 then
        cutoff = tostring(os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - math.floor(minutes * 60)))
    end
    local closed = 0
    local seen = {}
    for _, scope in ipairs(Manifest.scopes({ disk = true })) do
        if not seen[scope.path] then
            seen[scope.path] = true
            closed = closed + sweep_scope(scope, minutes, cutoff)
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
