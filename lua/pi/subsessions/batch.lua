--- Sub-session batch dispatch / poll / wait (persistent `.pi2-sub-batches.json`).

local M = {}

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Sessions = require("pi.sessions.manager")
local Reaper = require("pi.subsessions.reaper")

local BATCH_FILE = ".pi2-sub-batches.json"

---@type string?
local path_override = nil

--- Batches keyed by their workspace file path (several workspaces can be
--- consulted in one event-loop tick: a tab may live in a different workspace
--- than Neovim's cwd).
---@type table<string, table<string, pi.SubsessionBatch>>
local cache = {}

---@class pi.SubsessionWaiter
---@field cb fun(result: table): boolean
---@field owner? string Lineage/session id that is blocked on the wait.
---@field cwd? string Workspace the waiter registered against (nil = process cwd).
---@field scope? string Manifest path of that workspace, resolved at registration.

---@type table<string, pi.SubsessionWaiter[]>
local waiters = {}

---@class pi.SubsessionBatchItem
---@field ref string
---@field target? string
---@field task? string
---@field message? string
---@field name? string
---@field model? pi.ModelRef
---@field thinking_level? string
---@field tools? string[] Child tool allowlist (spawn items only; nil = inherit every tool)
---@field status "queued"|"spawning"|"running"|"ok"|"failed"|"cancelled"
---@field generation? integer Run generation the item was dispatched against.
---@field output? string
---@field error? string

---@class pi.SubsessionBatch
---@field id string
---@field parent_id string
---@field status "pending"|"running"|"completed"|"partial"|"failed"|"cancelled"
---@field created_at string
---@field updated_at string
---@field cancel_siblings_on_fail boolean
---@field items pi.SubsessionBatchItem[]
---@field cwd? string workspace cwd the batch belongs to (additive; absent in older files = process cwd)

---@param path string
function M._set_path(path)
    path_override = path
    cache = {}
end

function M._reset()
    path_override = nil
    cache = {}
    waiters = {}
end

--- Batch file path for a workspace cwd.
--- The batch file lives next to the session files (and the sub-session
--- manifest) it belongs to, so a worktree session keeps its own there.
--- Callers pass the owning session's cwd; omitting it keeps the process-cwd
--- behaviour.
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return string
function M.path(cwd)
    if path_override then
        return path_override
    end
    local History = require("pi.sessions.history")
    return History.get_sessions_dir(cwd) .. "/" .. BATCH_FILE
end

--- Read a batch file by path (the primitive behind `M.load`).
---@param path string
---@return table<string, pi.SubsessionBatch>
function M.load_at(path)
    local cached = cache[path]
    if cached ~= nil then
        return cached
    end
    local file = io.open(path, "r")
    if not file then
        cache[path] = {}
        return cache[path]
    end
    local content = file:read("*a")
    file:close()
    if type(content) ~= "string" or content == "" then
        cache[path] = {}
        return cache[path]
    end
    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
        cache[path] = data
        return cache[path]
    end
    return {}
end

---@param cwd? string workspace cwd whose batches to read (default: Neovim's current cwd)
---@return table<string, pi.SubsessionBatch>
function M.load(cwd)
    return M.load_at(M.path(cwd))
end

---@param batches table<string, pi.SubsessionBatch>
---@param path string
---@return boolean
function M.save_at(batches, path)
    cache[path] = batches
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "w")
    if not file then
        return false
    end
    file:write(vim.json.encode(batches))
    file:close()
    local ok = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
    end
    return ok == true
end

---@param batches table<string, pi.SubsessionBatch>
---@param cwd? string workspace cwd whose batches to write (default: Neovim's current cwd)
---@return boolean
local function save(batches, cwd)
    return M.save_at(batches, M.path(cwd))
end

---@param status? string
---@return boolean
local function is_terminal_status(status)
    return status == "completed" or status == "partial" or status == "failed" or status == "cancelled"
end

---@param id string
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return pi.SubsessionBatch?
function M.get(id, cwd)
    return M.load(cwd)[id]
end

---@param batch pi.SubsessionBatch
---@param cwd? string workspace cwd (default: `batch.cwd`, then Neovim's current cwd)
local function persist(batch, cwd)
    local workspace = cwd
    if workspace == nil and type(batch.cwd) == "string" then
        workspace = batch.cwd
    end
    local batches = M.load(workspace)
    batch.updated_at = Manifest.iso_now()
    batches[batch.id] = batch
    save(batches, workspace)
end

---@return string
local function new_id()
    return ("%s-%s"):format(os.time(), math.random(100000, 999999))
end

---@param batch pi.SubsessionBatch
---@return table
function M.snapshot(batch)
    local summary = { total = 0, done = 0, ok = 0, failed = 0, cancelled = 0, running = 0 }
    for _, item in ipairs(batch.items) do
        summary.total = summary.total + 1
        if item.status == "ok" then
            summary.done = summary.done + 1
            summary.ok = summary.ok + 1
        elseif item.status == "failed" then
            summary.done = summary.done + 1
            summary.failed = summary.failed + 1
        elseif item.status == "cancelled" then
            summary.done = summary.done + 1
            summary.cancelled = summary.cancelled + 1
        elseif item.status == "running" or item.status == "spawning" then
            summary.running = summary.running + 1
        end
    end
    return {
        batch_id = batch.id,
        status = batch.status,
        summary = summary,
        items = vim.deepcopy(batch.items),
    }
end

---@param batch pi.SubsessionBatch
local function recompute_status(batch)
    local ok_n, fail_n, cancel_n, pending = 0, 0, 0, 0
    for _, item in ipairs(batch.items) do
        if item.status == "ok" then
            ok_n = ok_n + 1
        elseif item.status == "failed" then
            fail_n = fail_n + 1
        elseif item.status == "cancelled" then
            cancel_n = cancel_n + 1
        else
            pending = pending + 1
        end
    end
    if batch.status == "cancelled" then
        return
    end
    if pending > 0 then
        batch.status = "running"
        return
    end
    if ok_n > 0 and fail_n == 0 and cancel_n == 0 then
        batch.status = "completed"
    elseif ok_n > 0 and (fail_n > 0 or cancel_n > 0) then
        batch.status = "partial"
    elseif fail_n > 0 then
        batch.status = "failed"
    else
        batch.status = "cancelled"
    end
end

---@param batch_id string
local function notify_waiters(batch_id)
    local batch = M.get(batch_id)
    if not batch then
        return
    end
    if not is_terminal_status(batch.status) then
        return
    end
    local entries = waiters[batch_id]
    if not entries then
        return
    end
    waiters[batch_id] = nil
    local snap = M.snapshot(batch)
    for _, waiter in ipairs(entries) do
        vim.schedule(function()
            waiter.cb(snap)
        end)
    end
end

---@param child_id string
---@param parent_epoch? integer
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return integer
function M.bump_generation(child_id, parent_epoch, cwd)
    local entry = Manifest.load(cwd)[child_id]
    local gen = (entry and entry.run_generation or 0) + 1
    local patch = {
        run_generation = gen,
        status = "active",
        last_active_at = Manifest.iso_now(),
    }
    if parent_epoch ~= nil then
        patch.parent_epoch = parent_epoch
    end
    Manifest.patch(child_id, patch, cwd)
    return gen
end

---@param batch pi.SubsessionBatch
---@param ref string
---@param patch table
local function patch_item(batch, ref, patch)
    for _, item in ipairs(batch.items) do
        if item.ref == ref then
            for k, v in pairs(patch) do
                item[k] = v
            end
            return item
        end
    end
    return nil
end

---@param batch pi.SubsessionBatch?
---@param ref string
---@return pi.SubsessionBatchItem?
local function find_item(batch, ref)
    if not batch then
        return nil
    end
    for _, item in ipairs(batch.items) do
        if item.ref == ref then
            return item
        end
    end
    return nil
end

--- Abort a child's agent and optionally close its RPC process, never letting
--- one unresponsive child break the caller's item loop. An unguarded `rpc:send`
--- or `close` that raises would skip the rest of the loop — including the
--- `persist` / `notify_waiters` at the end — leaving a cancelled batch that
--- never wakes its waiter.
---@param child_id? string
---@param close? boolean
local function abort_child_process(child_id, close)
    if type(child_id) ~= "string" or child_id == "" then
        return
    end
    local child = Sessions.get_by_id(child_id)
    if child and child.rpc and child.rpc:is_running() then
        pcall(function()
            child.rpc:send({ type = "abort" })
        end)
    end
    if close then
        pcall(function()
            require("pi.subsessions").close(child_id)
        end)
    end
end

---@param batch pi.SubsessionBatch
---@param failed_ref string
local function maybe_cancel_siblings(batch, failed_ref)
    if not batch.cancel_siblings_on_fail then
        return
    end
    for _, item in ipairs(batch.items) do
        if
            item.ref ~= failed_ref
            and (item.status == "queued" or item.status == "spawning" or item.status == "running")
        then
            item.status = "cancelled"
            item.error = "cancelled: sibling failed"
            abort_child_process(item.target, true)
        end
    end
end

---@param batch_id string
---@param ref string
---@param ok boolean
---@param opts? { output?: string, error?: string, cwd?: string } `cwd` is the owning session's workspace (default: Neovim's current cwd).
function M.complete_item(batch_id, ref, ok, opts)
    opts = opts or {}
    local batch = M.get(batch_id, opts.cwd)
    if not batch or batch.status == "cancelled" then
        return
    end
    local item = patch_item(batch, ref, {})
    if not item or item.status == "cancelled" or item.status == "ok" or item.status == "failed" then
        return
    end
    if ok then
        patch_item(batch, ref, {
            status = "ok",
            output = opts.output,
            error = nil,
        })
    else
        patch_item(batch, ref, {
            status = "failed",
            error = opts.error or "failed",
            -- A run that failed after producing text keeps it: the parent can
            -- still tell how far the child got, and the error says why it stopped.
            output = opts.output,
        })
        maybe_cancel_siblings(batch, ref)
    end
    recompute_status(batch)
    persist(batch, opts.cwd)
    notify_waiters(batch_id)
    require("pi.ui.sessions").request_refresh()
end

--- Outcome of a settled child run, as decided by the settle handler
--- (subsessions/init.lua), which is the only place that can tell an aborted run
--- from a failed one (`stopReason: "error"` plus the provider's `errorMessage`).
---@class pi.SubsessionItemOutcome
---@field ok boolean False when the run itself failed.
---@field error? string Provider/runtime error text for a failed run.
---@field output? string Text the run produced (kept on failure when non-empty).

--- Settle the running items that this child's finished run owns.
---
--- `outcome` is authoritative when given. Without it the manifest's `failed`
--- status is the fallback — that is the unexpected-exit path, where the manager
--- patches `failed` before settling because a crashed child leaves no assistant
--- turn to read.
---@param child_id string
---@param outcome? pi.SubsessionItemOutcome
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return boolean claimed True when this settle completed a running batch item.
function M.on_child_settled(child_id, outcome, cwd)
    -- The row belongs to the parent's workspace, which the caller usually knows
    -- (the child session carries it). A mismatch must not strand the batch, so
    -- fall back to locating the row and settle against *its* workspace.
    local entry = Manifest.load(cwd)[child_id]
    if type(entry) ~= "table" then
        local located, located_cwd = Manifest.locate(child_id, cwd)
        if type(located) ~= "table" then
            return false
        end
        entry = located
        if located_cwd then
            cwd = located_cwd
        end
    end
    local gen = entry.run_generation
    if type(gen) ~= "number" then
        return false
    end
    local batches = M.load(cwd)
    local claimed_outcome = type(outcome) == "table" and type(outcome.ok) == "boolean" and outcome or nil
    if not claimed_outcome then
        local failed = entry.status == "failed"
        claimed_outcome = {
            ok = not failed,
            error = failed and (entry.last_error or "sub-session failed") or nil,
        }
    end
    local output = claimed_outcome.output
    if claimed_outcome.ok and type(output) ~= "string" then
        -- The transcript file recorded at spawn time is authoritative: a child's
        -- JSONL can live in a different workspace (its worktree) than the batch.
        local path = nil
        local session_file = entry.session_file
        if type(session_file) == "string" and session_file ~= "" and vim.fn.filereadable(session_file) == 1 then
            path = session_file
        else
            path = Read.find_path(child_id, { cwd = cwd })
        end
        output = path and Read.last_assistant_message(path) or ""
    end
    -- A failed run usually produced no text at all (quota/auth/network errors
    -- arrive before any content); keep a partial report when it did.
    if not claimed_outcome.ok and (type(output) ~= "string" or output == "") then
        output = nil
    end
    local claimed = false
    for batch_id, batch in pairs(batches) do
        if batch.status == "running" or batch.status == "pending" then
            for _, item in ipairs(batch.items) do
                if
                    item.target == child_id
                    and item.generation == gen
                    and (item.status == "running" or item.status == "spawning")
                then
                    M.complete_item(batch_id, item.ref, claimed_outcome.ok, {
                        output = output,
                        error = claimed_outcome.ok and nil or (claimed_outcome.error or "sub-agent run failed"),
                        cwd = cwd,
                    })
                    claimed = true
                end
            end
        end
    end
    return claimed
end

---@param parent pi.Session
---@param callback fun(parent_id: string)
local function with_parent_id(parent, callback)
    local id = parent.id
    if type(id) == "string" and id ~= "" and not id:match("^tmp%-") then
        callback(id)
        return
    end
    parent.rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            local sid = res.success and res.data and res.data.sessionId
            if type(sid) == "string" and sid ~= "" then
                Sessions.ensure_id(parent, sid)
                callback(sid)
            elseif type(id) == "string" and id ~= "" then
                callback(id)
            else
                callback("")
            end
        end)
    end)
end

--- JSON `null` decodes to `vim.NIL` (`vim.json.decode` in handle_host), which
--- is truthy *and* throws when indexed. Treat it as absent, so an explicit
--- `"model": null` from a model that pads optional fields is neither rejected as
--- "field present" nor propagated into spawn where `config.model.provider`
--- would raise "attempt to index vim.NIL".
---@param value any
---@return boolean
local function present(value)
    return value ~= nil and value ~= vim.NIL
end

---@param raw table
---@param index integer
---@return pi.SubsessionBatchItem?, string?
local function normalize_item(raw, index)
    if type(raw) ~= "table" then
        return nil, ("item %d: expected object"):format(index)
    end
    local ref = type(raw.ref) == "string" and raw.ref ~= "" and raw.ref or tostring(index - 1)
    local is_spawn = type(raw.task) == "string" and raw.task ~= ""
    local is_reuse = type(raw.target) == "string" and raw.target ~= ""
    if is_spawn and is_reuse then
        return nil, ("item %d: use either `task` (spawn) or `target` + `message` (reuse), not both"):format(index)
    end
    if is_reuse then
        -- Spawn-only fields are rejected rather than silently dropped: a reused
        -- child keeps its own model/thinking level, name and tool allowlist.
        for _, field in ipairs({ "name", "model", "thinking_level", "tools" }) do
            if present(raw[field]) then
                return nil, ("item %d: `%s` is not accepted on a reuse item ({ target, message })"):format(index, field)
            end
        end
        if type(raw.message) ~= "string" then
            return nil, ("item %d: reuse items need `message` (string)"):format(index)
        end
        return {
            ref = ref,
            target = raw.target,
            message = raw.message,
            status = "queued",
        },
            nil
    end
    if is_spawn then
        -- `tools` is a whole-selection allowlist, so a malformed value must fail
        -- the item: silently dropping it would hand the child every tool.
        local tools, tools_err = Manifest.normalize_tools(present(raw.tools) and raw.tools or nil)
        if tools_err then
            return nil, ("item %d: %s"):format(index, tools_err)
        end
        return {
            ref = ref,
            task = raw.task,
            name = type(raw.name) == "string" and raw.name or nil,
            model = present(raw.model) and raw.model or nil,
            thinking_level = present(raw.thinking_level) and raw.thinking_level or nil,
            tools = tools,
            status = "queued",
        },
            nil
    end
    return nil, ("item %d: need `task` to spawn a child, or `target` + `message` to reuse one"):format(index)
end

---@param batch pi.SubsessionBatch
---@param parent pi.Session
local function run_batch(batch, parent)
    local Subsessions = require("pi.subsessions")
    -- The batch belongs to the parent session's workspace: every manifest /
    -- batch lookup in this closure must resolve against it, not Neovim's cwd.
    local cwd = parent and parent.cwd or batch.cwd

    ---@param item pi.SubsessionBatchItem
    local function start_item(item)
        local current = M.get(batch.id, cwd)
        if not current or is_terminal_status(current.status) then
            return
        end
        if item.status ~= "queued" then
            return
        end

        --- Resolve the *live* batch/item from disk: the in-memory `item` this
        --- closure captured is stale once a cancel/complete persisted to disk.
        ---@param expected_status string
        ---@return pi.SubsessionBatch?, pi.SubsessionBatchItem?
        local function live_item(expected_status)
            local b = M.get(batch.id, cwd)
            if not b or is_terminal_status(b.status) then
                return nil, nil
            end
            local live = find_item(b, item.ref)
            if not live or live.status ~= expected_status then
                return nil, nil
            end
            return b, live
        end

        if item.task then
            item.status = "spawning"
            persist(current, cwd)
            Subsessions.spawn(parent, {
                task = item.task,
                name = item.name,
                model = item.model,
                thinking_level = item.thinking_level,
                tools = item.tools,
                agent_spawned = true,
            }, function(child, err)
                local b, live = live_item("spawning")
                if not b or not live then
                    -- Batch/item no longer wants this spawn (cancelled or
                    -- already settled): discard the child instead of
                    -- resurrecting a cancelled item as "running".
                    if child then
                        if child.rpc and child.rpc:is_running() then
                            child.rpc:send({ type = "abort" })
                        end
                        Subsessions.close(child.id)
                        Manifest.patch(child.id, {
                            status = "interrupted",
                            last_active_at = Manifest.iso_now(),
                        }, cwd)
                    end
                    return
                end
                if not child then
                    M.complete_item(b.id, item.ref, false, { error = err or "spawn failed", cwd = cwd })
                    return
                end
                local entry = Manifest.load(cwd)[child.id]
                live.target = child.id
                live.generation = entry and entry.run_generation
                live.status = "running"
                persist(b, cwd)
            end)
            return
        end

        local target = item.target
        if not target then
            M.complete_item(batch.id, item.ref, false, { error = "missing target", cwd = cwd })
            return
        end
        local function send_to(child)
            local b, live = live_item("queued")
            if not b or not live then
                -- Stale callback: the item was cancelled or already settled.
                -- Leave the child running (no abort, no close, no generation
                -- bump) — it belongs to whatever superseded this item.
                return
            end
            if not child then
                M.complete_item(b.id, item.ref, false, { error = "sub-agent not found", cwd = cwd })
                return
            end
            local gen = M.bump_generation(target, parent.conversation_epoch, cwd)
            live.generation = gen
            live.status = "running"
            persist(b, cwd)
            child.rpc:send({ type = "prompt", message = item.message }, function(res)
                if not res.success then
                    -- Carry the backend's reason (e.g. "No API key found for …")
                    -- instead of an opaque "prompt failed": the parent can act
                    -- on the former and only guess at the latter.
                    local reason = type(res.error) == "string" and res.error ~= "" and res.error or nil
                    M.complete_item(batch.id, item.ref, false, {
                        error = reason and ("prompt failed: " .. reason) or "prompt failed",
                        cwd = cwd,
                    })
                end
            end)
        end

        local child = Sessions.get_by_id(target)
        if child and child.rpc:is_running() then
            send_to(child)
            return
        end
        Subsessions.revive(target, function(revived, err)
            if not revived then
                M.complete_item(batch.id, item.ref, false, { error = err or "revive failed", cwd = cwd })
                return
            end
            local b, live = live_item("queued")
            if not b or not live then
                -- Revive won the race against a cancel/complete: the freshly
                -- revived child has no item to serve. Same cleanup as the
                -- stale spawn callback above.
                if revived.rpc and revived.rpc:is_running() then
                    revived.rpc:send({ type = "abort" })
                end
                Subsessions.close(revived.id)
                Manifest.patch(revived.id, {
                    status = "interrupted",
                    last_active_at = Manifest.iso_now(),
                }, cwd)
                return
            end
            send_to(revived)
        end)
    end

    for _, item in ipairs(batch.items) do
        start_item(item)
    end
end

---@class pi.SubsessionDispatchOpts
---@field items table[]
---@field cancel_siblings_on_fail? boolean

---@param parent pi.Session
---@param opts pi.SubsessionDispatchOpts
---@param callback fun(result: table)
function M.dispatch(parent, opts, callback)
    local subcfg = Config.options.subagent or {}
    -- The batch and its manifest rows belong to the parent session's workspace
    -- (a worktree session keeps them in the worktree's session directory).
    local cwd = type(parent.cwd) == "string" and parent.cwd or nil
    if subcfg.enabled == false then
        callback({ error = "subagent disabled" })
        return
    end

    with_parent_id(parent, function(parent_id)
        if parent_id == "" then
            callback({ error = "parent session id not available" })
            return
        end

        local raw_items = opts.items
        if type(raw_items) ~= "table" or #raw_items == 0 then
            callback({ error = "items required" })
            return
        end

        local max_batch = subcfg.max_batch_size or 5
        if #raw_items > max_batch then
            callback({ error = ("max %d items per batch"):format(max_batch) })
            return
        end

        Manifest.bind_session_lineage(parent, parent_id, cwd)
        local lineage_id = Manifest.lineage_for_session(parent, cwd)
        if lineage_id == "" then
            lineage_id = parent_id
        end

        ---@type pi.SubsessionBatchItem[]
        local items = {}
        local seen_refs = {}
        for i, raw in ipairs(raw_items) do
            local item, err = normalize_item(raw, i)
            if not item then
                callback({ error = err })
                return
            end
            -- Refs must be unique. Both the spawn callback in run_batch and
            -- on_child_settled resolve an item by ref with first-match-wins
            -- (patch_item), so a duplicate misroutes a child's target onto the
            -- wrong item and can strand the batch permanently non-terminal
            -- (wait_subagents then only ends on its timeout).
            if seen_refs[item.ref] then
                callback({
                    error = ("item %d: duplicate ref %q (refs must be unique; omitted refs default to the item index)"):format(
                        i,
                        item.ref
                    ),
                })
                return
            end
            seen_refs[item.ref] = true
            items[#items + 1] = item
        end

        for i, item in ipairs(items) do
            if item.target then
                local entry = Manifest.load(cwd)[item.target]
                if type(entry) ~= "table" then
                    callback({ error = ("item %d: unknown sub-agent target %q"):format(i, item.target) })
                    return
                end
                if entry.parent_id ~= lineage_id then
                    callback({
                        error = ("item %d: target %q is not a sub-agent of this session"):format(i, item.target),
                    })
                    return
                end
            end
        end

        -- Spawn pre-check shares the alive-process occupancy check with M.spawn.
        local Subsessions = require("pi.subsessions")
        local new_spawns = 0
        local counted_targets = {}
        for _, item in ipairs(items) do
            if item.task then
                new_spawns = new_spawns + 1
            elseif item.target and not counted_targets[item.target] then
                counted_targets[item.target] = true
                if not Subsessions.is_child_process_alive(item.target) then
                    new_spawns = new_spawns + 1
                end
            end
        end

        local reuse_exclude = {}
        for _, item in ipairs(items) do
            if item.target then
                reuse_exclude[item.target] = true
            end
        end

        local max_children = subcfg.max_children or 5
        local occupancy = Manifest.spawn_occupancy(lineage_id, Subsessions.is_child_process_alive, cwd)
        if occupancy + new_spawns > max_children then
            local deficit = occupancy + new_spawns - max_children
            -- Auto-reap settled children to make room, but never reap targets this
            -- batch is about to reuse (otherwise run_batch would have to revive them,
            -- defeating the reap and risking over-quota spawn).
            Reaper.reap_oldest_settled(lineage_id, deficit, reuse_exclude, cwd)
            occupancy = Manifest.spawn_occupancy(lineage_id, Subsessions.is_child_process_alive, cwd)
        end
        if occupancy + new_spawns > max_children then
            callback({ error = ("would exceed max %d concurrent sub-sessions"):format(max_children) })
            return
        end

        ---@type pi.SubsessionBatch
        local batch = {
            id = new_id(),
            parent_id = lineage_id,
            status = "running",
            created_at = Manifest.iso_now(),
            updated_at = Manifest.iso_now(),
            cancel_siblings_on_fail = opts.cancel_siblings_on_fail == true,
            items = items,
            cwd = cwd,
        }
        persist(batch, cwd)
        callback(M.snapshot(batch))
        vim.defer_fn(function()
            run_batch(batch, parent)
        end, 0)
    end)
end

---@param batch_id string
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return table?
function M.poll(batch_id, cwd)
    local batch = M.get(batch_id, cwd)
    if not batch then
        return nil
    end
    return M.snapshot(batch)
end

---@param parent_id string Session id or lineage id.
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return table[]
function M.list_for_parent(parent_id, cwd)
    local lineage = Manifest.resolve_lineage(parent_id, cwd) or parent_id
    local batches = M.load(cwd)
    ---@type table[]
    local out = {}
    for _, batch in pairs(batches) do
        local batch_lineage = Manifest.resolve_lineage(batch.parent_id, cwd) or batch.parent_id
        if batch_lineage == lineage then
            out[#out + 1] = M.snapshot(batch)
        end
    end
    table.sort(out, function(a, b)
        return (a.batch_id or "") > (b.batch_id or "")
    end)
    return out
end

---@param batch_id string
---@param callback fun(result: table)
---@param opts? { timeout_ms?: integer, interval_ms?: integer, owner?: string, cwd?: string } `cwd` is the workspace the batch lives in (default: Neovim's cwd)
function M.wait(batch_id, callback, opts)
    opts = opts or {}
    local cwd = opts.cwd
    local timeout_ms = opts.timeout_ms or (Config.options.subagent or {}).batch_timeout_ms or 300000
    local interval_ms = opts.interval_ms or 200
    local owner = opts.owner
    local started = vim.uv.hrtime() / 1e6
    local settled = false

    ---@param result table
    ---@return boolean settled_now
    local function finish(result)
        if settled then
            return true
        end
        local ok = pcall(callback, result)
        if not ok then
            return false
        end
        settled = true
        local entries = waiters[batch_id]
        if entries then
            for i = #entries, 1, -1 do
                if entries[i].cb == finish then
                    table.remove(entries, i)
                end
            end
            if #entries == 0 then
                waiters[batch_id] = nil
            end
        end
        return true
    end

    local function tick()
        if settled then
            return
        end
        local snap = M.poll(batch_id, cwd)
        if not snap then
            if finish({ error = "batch not found" }) then
                return
            end
        elseif is_terminal_status(snap.status) then
            if finish(snap) then
                return
            end
        elseif (vim.uv.hrtime() / 1e6 - started) >= timeout_ms then
            if
                finish({
                    error = "timeout waiting for batch",
                    batch_id = batch_id,
                    status = snap.status,
                    summary = snap.summary,
                })
            then
                return
            end
        end
        vim.defer_fn(tick, interval_ms)
    end

    local batch = M.get(batch_id, cwd)
    if not batch then
        if finish({ error = "batch not found" }) then
            return
        end
    elseif is_terminal_status(batch.status) then
        if finish(M.snapshot(batch)) then
            return
        end
    end
    waiters[batch_id] = waiters[batch_id] or {}
    -- The workspace is resolved once here, so the recorded scope cannot drift
    -- when Neovim's cwd changes while the caller waits.
    table.insert(waiters[batch_id], { cb = finish, owner = owner, cwd = cwd, scope = Manifest.path(cwd) })
    vim.defer_fn(tick, interval_ms)
end

--- True when `lineage` is currently blocked in a wait on a batch of `cwd`'s
--- workspace.
---
--- A waiter is parked until its batch reaches a terminal status, so this is the
--- authoritative test for "the parent is blocked right now" (as opposed to
--- `pi.subsessions.parent_waiting`, which reads the session-level depth marker).
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@param lineage string lineage id (any session id of the lineage)
---@return boolean
function M.is_waiting(cwd, lineage)
    if type(lineage) ~= "string" or lineage == "" then
        return false
    end
    local scope = Manifest.path(cwd)
    local target = Manifest.resolve_lineage(lineage, cwd) or lineage
    for _, entries in pairs(waiters) do
        for _, waiter in ipairs(entries) do
            local waiter_scope = type(waiter.scope) == "string" and waiter.scope or Manifest.path(waiter.cwd)
            local owner = waiter.owner
            if
                waiter_scope == scope
                and type(owner) == "string"
                and owner ~= ""
                and (Manifest.resolve_lineage(owner, cwd) or owner) == target
            then
                return true
            end
        end
    end
    return false
end

---@param batch_id string
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return boolean
function M.cancel(batch_id, cwd)
    local batch = M.get(batch_id, cwd)
    if not batch then
        return false
    end
    if is_terminal_status(batch.status) then
        return true
    end
    batch.status = "cancelled"
    for _, item in ipairs(batch.items) do
        if item.status == "queued" or item.status == "spawning" or item.status == "running" then
            item.status = "cancelled"
            item.error = "batch cancelled"
            abort_child_process(item.target, true)
        end
    end
    persist(batch, cwd)
    notify_waiters(batch_id)
    return true
end

---@param parent_id string Session id or lineage id.
---@param fn fun(batch_id: string, batch: pi.SubsessionBatch)
---@param cwd? string workspace cwd (default: Neovim's current cwd)
local function for_each_target_batch(parent_id, fn, cwd)
    local lineage = Manifest.resolve_lineage(parent_id, cwd) or parent_id
    local batches = M.load(cwd)
    for id, batch in pairs(batches) do
        if batch.status == "running" or batch.status == "pending" then
            local batch_lineage = Manifest.resolve_lineage(batch.parent_id, cwd) or batch.parent_id
            local matches = (batch_lineage == lineage)
            if not matches and waiters[id] then
                for _, w in ipairs(waiters[id]) do
                    if w.owner and w.owner ~= "" then
                        local owner_lineage = Manifest.resolve_lineage(w.owner, cwd) or w.owner
                        if owner_lineage == lineage then
                            matches = true
                            break
                        end
                    end
                end
            end
            if matches then
                fn(id, batch)
            end
        end
    end
end

---@param parent_id string Session id or lineage id.
---@param cwd? string workspace cwd (default: Neovim's current cwd)
function M.cancel_for_parent(parent_id, cwd)
    if not parent_id or parent_id == "" then
        return
    end
    for_each_target_batch(parent_id, function(id)
        M.cancel(id, cwd)
    end, cwd)
end

--- Record the abort watermark for a child whose in-flight item is being
--- cancelled, so a late `agent_settled` (which carries no generation) can tell
--- the aborted run apart from a newer run on the same child.
---@param child_id? string
---@param generation? any
local function note_child_aborted(child_id, generation)
    if type(child_id) ~= "string" or child_id == "" or type(generation) ~= "number" then
        return
    end
    pcall(function()
        require("pi.subsessions").mark_child_aborted(child_id, generation)
    end)
end

--- Abort-only cancellation of one batch: marks the batch cancelled and aborts
--- (never closes) its in-flight children, then wakes any waiters.
---@param batch_id string
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return boolean ok
function M.abort(batch_id, cwd)
    local batch = M.get(batch_id, cwd)
    if not batch then
        return false
    end
    if is_terminal_status(batch.status) then
        return true
    end
    batch.status = "cancelled"
    for _, item in ipairs(batch.items) do
        if item.status == "queued" or item.status == "spawning" or item.status == "running" then
            item.status = "cancelled"
            item.error = "batch cancelled"
            if item.target then
                note_child_aborted(item.target, item.generation)
                abort_child_process(item.target, false)
            end
        end
    end
    persist(batch, cwd)
    notify_waiters(batch_id)
    return true
end

--- Abort-only counterpart of M.cancel_for_parent: same matching rules (own
--- lineage + batches this lineage is currently waiting on), but children are
--- aborted instead of closed.
---@param parent_id string
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return integer n Batches aborted.
function M.abort_for_parent(parent_id, cwd)
    if not parent_id or parent_id == "" then
        return 0
    end
    local n = 0
    for_each_target_batch(parent_id, function(id, batch)
        if batch.status == "running" or batch.status == "pending" then
            M.abort(id, cwd)
            n = n + 1
        end
    end, cwd)
    return n
end

--- Mark a child's in-flight batch items as cancelled without killing sibling
--- items or the child process. Idempotent: a terminal item is skipped, and a
--- later complete_item for it is already a no-op.
---
--- `opts.generation`, when given, only matches items whose generation is **at
--- most** that value — the aborted run and anything older, never a newer run the
--- parent started by reusing this child after the abort.
---@param child_id string
---@param opts? { generation?: integer, reason?: string, cwd?: string } `cwd` is the workspace the batches live in (default: Neovim's cwd).
---@return integer n Number of items marked cancelled.
function M.interrupt_items_for_child(child_id, opts)
    opts = opts or {}
    if type(child_id) ~= "string" or child_id == "" then
        return 0
    end
    if type(opts.generation) == "number" then
        note_child_aborted(child_id, opts.generation)
    end
    local n = 0
    local batches = M.load(opts.cwd)
    for batch_id, batch in pairs(batches) do
        if batch.status == "running" or batch.status == "pending" then
            local changed = 0
            for _, item in ipairs(batch.items) do
                if
                    item.target == child_id
                    and (item.status == "queued" or item.status == "spawning" or item.status == "running")
                    and (
                        type(opts.generation) ~= "number"
                        or (type(item.generation) == "number" and item.generation <= opts.generation)
                    )
                then
                    item.status = "cancelled"
                    item.error = opts.reason or "cancelled: aborted by user"
                    note_child_aborted(item.target, item.generation)
                    changed = changed + 1
                end
            end
            if changed > 0 then
                recompute_status(batch)
                persist(batch, opts.cwd)
                notify_waiters(batch_id)
                n = n + changed
            end
        end
    end
    return n
end

--- Batch file that lives next to a manifest file (same workspace directory).
--- Lets a caller that only knows a manifest path (a workspace discovered on
--- disk) reach that workspace's batches.
---@param manifest_path string
---@return string
function M.path_for_manifest(manifest_path)
    return vim.fn.fnamemodify(manifest_path, ":h") .. "/" .. BATCH_FILE
end

--- Reconcile running batches after Neovim restart.
---@param cwd? string workspace cwd (default: Neovim's current cwd)
function M.rebuild(cwd)
    M.rebuild_at(M.path(cwd), Manifest.path(cwd))
end

--- Reconcile running batches in one batch file.
---@param path string batch file path
---@param manifest_path? string manifest of the same workspace (default: the manifest file next to the batch file)
function M.rebuild_at(path, manifest_path)
    local ttl_hours = (Config.options.subagent or {}).batch_ttl_hours or 24
    local now = os.time()
    local batches = M.load_at(path)
    -- Items are settled against the manifest of the same workspace, so a rebuild
    -- in one workspace never reads another's rows. The caller's workspace wins
    -- when it resolves one (`M.rebuild`); a batch file reached purely by path
    -- falls back to the manifest next to it.
    local manifest = Manifest.load_at(manifest_path or Manifest.path_for_batch(path))
    local changed = false
    for id, batch in pairs(batches) do
        local created = batch.created_at or ""
        local ts = created:match("^(%d%d%d%d%-%d%d%-%d%d)T")
        if ts then
            local y, m, d = ts:match("^(%d+)%-(%d+)%-(%d+)$")
            local ny, nm, nd = tonumber(y), tonumber(m), tonumber(d)
            if ny and nm and nd then
                local age_h = (now - os.time({ year = ny, month = nm, day = nd, hour = 0 })) / 3600
                if age_h > ttl_hours and batch.status ~= "running" then
                    batches[id] = nil
                    changed = true
                end
            end
        end
        if batch.status == "running" then
            for _, item in ipairs(batch.items) do
                if item.status == "running" and item.target and item.generation then
                    local entry = manifest[item.target]
                    if entry and entry.run_generation == item.generation and entry.status == "completed" then
                        -- The row's recorded transcript is authoritative: a child
                        -- in its own worktree keeps its JSONL in another workspace.
                        local session_file = entry.session_file
                        local transcript
                        if
                            type(session_file) == "string"
                            and session_file ~= ""
                            and vim.fn.filereadable(session_file) == 1
                        then
                            transcript = session_file
                        else
                            -- Same workspace as the row (unknown only for a batch
                            -- file reached purely by path).
                            transcript = Read.find_path(item.target, { cwd = entry.workspace })
                        end
                        item.status = "ok"
                        item.output = transcript and Read.last_assistant_message(transcript) or ""
                        changed = true
                    elseif entry and entry.run_generation == item.generation and entry.status == "failed" then
                        item.status = "failed"
                        -- The settle recorded why (provider error, process exit);
                        -- a manifest written before that field existed falls back
                        -- to the generic text.
                        item.error = type(entry.last_error) == "string" and entry.last_error ~= "" and entry.last_error
                            or "sub-session failed"
                        changed = true
                    end
                end
            end
            recompute_status(batch)
            changed = true
        end
    end
    if changed then
        M.save_at(batches, path)
    end
end

return M
