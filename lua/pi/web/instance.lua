-- Instance identity, event fanout and snapshot construction for the pi2 web
-- console (W9).
--
-- One instance represents one Neovim process serving one workspace
-- (`pi2d/docs/protocol.md` §2/§5). It owns:
--
--   * the workspace id (`sha256(realpath(cwd))[:16]`, or `$PI2_WORKSPACE_ID`
--     when the daemon spawned us),
--   * the per-process `epoch` (a reconnect/restart marker),
--   * one authoritative `pi.web.state` object per live session,
--   * the per-session `seq` counter shared with the bridge (acks and events),
--   * the derived `pi2:*` events the browser reducer consumes in addition to
--     the verbatim pi events.
--
-- The module never renders: it reads the plugin's own state (session object,
-- `pi.todo`, `pi.tasks`, the sub-session manifest/queue, the attention queue)
-- and ships it. Everything runs on the main loop (`handle_event` tail and the
-- bridge's scheduled callbacks); nothing here touches `vim.fn.jobstart`.

local M = {}

local Runtime = require("pi.web.runtime")
local State = require("pi.web.state")
local Protocol = require("pi.web.protocol")

local uv = vim.uv or vim.loop

--- @class pi.web.Instance
--- @field workspace_id string
--- @field cwd string
--- @field epoch string
--- @field bridge pi.web.Bridge|nil
--- @field _states table<pi.Session, pi.web.State> lazily created, one per session
--- @field _ids table<pi.Session, string> session id last seen per object (migration detection)
--- @field _seq table<string, integer> per-session sequence counter
--- @field _subscribed table<string, boolean> session ids the daemon subscribed to
--- @field _todo_sig table<pi.Session, string>
--- @field _task_sig table<string, string>
--- @field _sub_sig table<pi.Session, string>
--- @field _batch_sig table<pi.Session, table<string, string>> per-batchId signature
--- @field _model_sig table<pi.Session, string> last model emitted per session
--- @field _stats_at table<string, number>
--- @field _active boolean
local Instance = {}
Instance.__index = Instance

--- Newest entries a snapshot may carry.
local MAX_SNAPSHOT_ENTRIES = 50
--- Byte budget for the entries a snapshot carries (encoded JSON, approximate).
local MAX_SNAPSHOT_ENTRY_BYTES = 256 * 1024

--- @type pi.web.Instance|nil
local current = nil

--- @return integer milliseconds since the epoch
local function now_ms()
    local ok, sec, usec = pcall(uv.gettimeofday)
    if ok and type(sec) == "number" then
        return sec * 1000 + math.floor((usec or 0) / 1000)
    end
    return os.time() * 1000
end

--- @return number monotonic milliseconds
local function mono_ms()
    return math.floor(uv.hrtime() / 1e6)
end

--- @param value unknown
--- @return string|nil
local function non_empty(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

--- Stable workspace id for a directory: first 16 hex chars of the SHA-256 of
--- the real path. Matches `workspaceIdForCwd` in `pi2d/src/core/paths.ts`.
--- @param cwd string
--- @return string
function M.workspace_id_for(cwd)
    local real = uv.fs_realpath(cwd) or cwd
    return Runtime.hex16(real)
end

--- Random epoch, fresh per process. Any change tells the browser to resync.
--- @return string
function M.new_epoch()
    local seed = string.format("%d:%d:%d:%d", uv.os_getpid(), uv.hrtime(), os.time(), math.random(1, 2147483647))
    return Runtime.hex16(seed) .. Runtime.hex16(seed .. ":" .. tostring(math.random(1, 2147483647)))
end

--- Build the singleton instance. Call before the bridge so its callbacks can
--- reach the instance through the module-level `M.current`.
--- @param opts? { cwd?: string, workspace_id?: string, bridge?: pi.web.Bridge }
--- @return pi.web.Instance
function M.setup(opts)
    opts = opts or {}
    local instance = setmetatable({}, Instance)
    instance.cwd = opts.cwd or vim.fn.getcwd()
    instance.workspace_id = non_empty(opts.workspace_id)
        or non_empty(vim.env.PI2_WORKSPACE_ID)
        or M.workspace_id_for(instance.cwd)
    instance.epoch = M.new_epoch()
    instance.bridge = opts.bridge
    instance._states = setmetatable({}, { __mode = "k" })
    instance._ids = setmetatable({}, { __mode = "k" })
    instance._seq = {}
    instance._subscribed = {}
    instance._todo_sig = setmetatable({}, { __mode = "k" })
    instance._task_sig = {}
    instance._sub_sig = setmetatable({}, { __mode = "k" })
    instance._batch_sig = setmetatable({}, { __mode = "k" })
    instance._model_sig = setmetatable({}, { __mode = "k" })
    instance._stats_at = {}
    instance._active = true
    current = instance
    return instance
end

--- @return pi.web.Instance|nil
function M.instance()
    return current
end

--- True while a web instance is running. Used by the manager hook to skip
--- any work (and any module load) when the web console is off.
--- @return boolean
function M.active()
    return current ~= nil and current._active == true
end

--- @return boolean
function M.has_ui()
    return #vim.api.nvim_list_uis() > 0
end

-- ---------------------------------------------------------------------------
-- instance state
-- ---------------------------------------------------------------------------

--- Live `pi.Session` status, taking the reducer's projection as the fallback.
--- Reads only fields the plugin already maintains.
--- @param session pi.Session
--- @param fallback string|nil
--- @return string
function Instance:live_status(session, fallback)
    local rpc = session.rpc
    if rpc and type(rpc.is_running) == "function" and not rpc:is_running() then
        return "exited"
    end
    if session._detached_compacting then
        return "compacting"
    end
    if fallback == nil or fallback == "starting" then
        if session._detached_busy or session._detached_retrying or type(session._busy_started_at) == "number" then
            return "busy"
        end
        return "idle"
    end
    return fallback
end

--- State object for a session, created on first use. Detects id migration
--- (`tmp-N` → backend id) and keeps the projection's identity in sync.
--- @param session pi.Session
--- @return pi.web.State
function Instance:state_for(session)
    local id = session.id
    local previous = self._ids[session]
    if previous and id and previous ~= id then
        self:_migrate_session(session, previous, id)
    end
    self._ids[session] = id

    local state = self._states[session]
    if not state then
        local pin = session.pinned_config or {}
        state = State.new({
            session_id = id or "",
            workspace_id = self.workspace_id,
            cwd = session.cwd or self.cwd,
            status = self:live_status(session, "starting"),
            model = pin.model,
            thinking = pin.thinking_level,
        })
        self._states[session] = state
    end
    return state
end

--- Migrate everything keyed by the old session id.
---
--- A daemon/web client that subscribed to `tmp-N` addresses the session by that
--- id, so the migration is announced *on the old id* first (`pi2:session` with
--- `sessionId` + `previousSessionId`), and only then is the subscription/seq
--- mapping moved to the new id.
--- @param session pi.Session
--- @param old_id string
--- @param new_id string
function Instance:_migrate_session(session, old_id, new_id)
    local subscribed = self._subscribed[old_id] == true
    local old_seq = self._seq[old_id] or 0
    local announced = old_seq
    if subscribed and self.bridge then
        announced = old_seq + 1
        self.bridge:send_event(old_id, self.epoch, announced, {
            type = Protocol.DERIVED.SESSION,
            ts = now_ms(),
            session = { sessionId = new_id, previousSessionId = old_id },
        })
    end
    -- The new id continues the old counter (so the wire never goes backwards)
    -- but never regresses a seq the new key already earned. The old counter is
    -- kept: a delta still coalescing in the bridge may flush under the old id.
    self._seq[new_id] = math.max(announced, self._seq[new_id] or 0)
    if subscribed then
        self._subscribed[new_id] = true
        self._subscribed[old_id] = nil
    end
    local state = self._states[session]
    if state then
        -- Keep snapshots addressed by the live id. `_state` is the model's own
        -- projection; there is no public setter for the id.
        state._state.sessionId = new_id
    end
end

--- Next sequence number for a session (shared by events, snapshots and acks).
--- @param session_id string|nil
--- @return integer
function Instance:next_seq(session_id)
    local key = session_id or ""
    local seq = (self._seq[key] or 0) + 1
    self._seq[key] = seq
    return seq
end

--- @param session_id string|nil
--- @return integer
function Instance:seq(session_id)
    return self._seq[session_id or ""] or 0
end

--- @return integer
function Instance:session_count()
    local count = 0
    for _ in pairs(self._states) do
        count = count + 1
    end
    return count
end

-- ---------------------------------------------------------------------------
-- outbound
-- ---------------------------------------------------------------------------

--- Whether the bridge coalesces this event, i.e. writes it later than it is
--- handed over (and therefore owns its seq).
--- @param event table
--- @return boolean
function Instance:_coalesces(event)
    local bridge = self.bridge
    if not bridge or type(bridge.coalesces) ~= "function" then
        return false
    end
    local ok, result = pcall(bridge.coalesces, bridge, event)
    return ok and result == true
end

--- Send an already-applied event when the daemon is subscribed to the id.
--- @param session_id string|nil
--- @param event table
--- @return boolean queued
function Instance:_send_to(session_id, event)
    if not session_id or not self.bridge or not self._subscribed[session_id] then
        return false
    end
    -- A coalesced frame is written after this call returns, so its seq is
    -- assigned by the bridge at flush time; burning one here would leave a
    -- hole the wire order could overtake.
    local seq
    if not self:_coalesces(event) then
        seq = self:next_seq(session_id)
    end
    return self.bridge:send_event(session_id, self.epoch, seq, event)
end

--- Send an already-applied event when the daemon is subscribed to the session.
--- @param session pi.Session
--- @param event table
--- @return boolean queued
function Instance:_send(session, event)
    return self:_send_to(session.id, event)
end

--- Apply one event to the projection and ship it.
--- @param session pi.Session
--- @param event table
--- @return boolean queued
function Instance:emit(session, event)
    if type(event) ~= "table" then
        return false
    end
    event.ts = event.ts or now_ms()
    self:state_for(session):apply(event)
    return self:_send(session, event)
end

--- Emit a derived `pi2:error`.
--- @param session pi.Session
--- @param message string
function Instance:emit_error(session, message)
    self:emit(session, { type = Protocol.DERIVED.ERROR, message = tostring(message or "error") })
end

--- Drop the lazily fetched model list `pi.web.commands` caches for
--- `/api/v1/models`. That cache is keyed by nothing, so a provider
--- reconfiguration would otherwise keep a stale list until nvim restarts. A
--- session switching to a different model is the cheapest available signal.
--- Best effort: the cache lives in another module, so a missing hook is fine.
--- @return boolean invalidated
function Instance:invalidate_models()
    local ok, Commands = pcall(require, "pi.web.commands")
    if not ok or type(Commands) ~= "table" then
        return false
    end
    local reset = Commands._reset_caches
    if type(reset) ~= "function" then
        return false
    end
    return pcall(reset)
end

--- @param session pi.Session
function Instance:emit_session(session)
    local state = self:state_for(session):snapshot()
    local patch = {
        sessionId = session.id,
        status = self:live_status(session, state.status),
        cwd = session.cwd or self.cwd,
    }
    -- The reducer already tracks model/thinking changes (thinking_level_changed,
    -- get_state patches). The pin is the fallback for a session the reducer has
    -- not seen a value for yet — never overwrite fresher backend data with it.
    local pin = session.pinned_config
    if type(pin) == "table" then
        if type(pin.model) == "table" and (state.model == nil or state.model == vim.NIL) then
            patch.model = pin.model
        end
        if type(pin.thinking_level) == "string" and (state.thinking == nil or state.thinking == vim.NIL) then
            patch.thinking = pin.thinking_level
        end
    end
    if type(state.name) == "string" then
        patch.name = state.name
    end
    self:emit(session, { type = Protocol.DERIVED.SESSION, session = patch })
end

-- ---------------------------------------------------------------------------
-- derived: todos / tasks / subagents
-- ---------------------------------------------------------------------------

--- @param details pi.TodoDetails|nil
--- @return table[]
local function project_todos(details)
    local todos = {}
    for _, raw in ipairs(details and details.todos or {}) do
        if type(raw) == "table" then
            local todo = { content = raw.content or "", status = raw.status or "pending" }
            if type(raw.activeForm) == "string" then
                todo.activeForm = raw.activeForm
            end
            todos[#todos + 1] = todo
        end
    end
    return todos
end

--- @param session pi.Session
function Instance:publish_todo(session)
    local ok, Todo = pcall(require, "pi.todo")
    if not ok then
        return
    end
    local details = Todo.get and Todo.get(session) or nil
    if type(details) ~= "table" then
        return
    end
    local parts = {}
    for _, todo in ipairs(details.todos or {}) do
        parts[#parts + 1] = tostring(todo.content) .. "|" .. tostring(todo.status)
    end
    local sig = table.concat(parts, "\0")
    if self._todo_sig[session] == sig then
        return
    end
    self._todo_sig[session] = sig
    self:emit(session, { type = Protocol.DERIVED.TODO, todos = project_todos(details) })
end

--- @param task pi.Task
--- @return table
local function project_task(task)
    local out = {
        id = task.id,
        command = task.command or "",
        status = task.status or "running",
        startTime = task.start_time,
    }
    if type(task.end_time) == "number" and type(task.start_time) == "number" then
        out.durationMs = math.max(0, task.end_time - task.start_time)
    end
    if task.exit_code ~= nil then
        out.exitCode = task.exit_code
    end
    if type(task.output_file) == "string" then
        out.outputFile = task.output_file
    end
    return out
end

--- @param session pi.Session
function Instance:_publish_tasks_for(session)
    local ok, Tasks = pcall(require, "pi.tasks")
    if not ok or not session.id then
        return
    end
    for _, task in ipairs(Tasks.list(session.id)) do
        local sig = table.concat({
            tostring(task.status),
            tostring(task.end_time),
            tostring(task.exit_code),
            tostring(task.output_file),
        }, "|")
        if self._task_sig[task.id] ~= sig then
            self._task_sig[task.id] = sig
            self:emit(session, { type = Protocol.DERIVED.TASK, task = project_task(task) })
        end
    end
end

--- Push task changes for every live session (registered as a `Tasks.on_refresh`
--- listener by `pi.web`).
function Instance:publish_tasks()
    local ok, manager = pcall(require, "pi.sessions.manager")
    if not ok then
        return
    end
    for _, session in ipairs(manager.list_all()) do
        self:_publish_tasks_for(session)
    end
end

--- @param batch pi.SubsessionBatch|table Batch object or `Batch.snapshot()` result
--- @return table
local function project_batch(batch)
    local snapshot
    if type(batch.batch_id) == "string" then
        snapshot = batch
    else
        local ok, Batch = pcall(require, "pi.subsessions.batch")
        snapshot = ok and Batch.snapshot(batch)
            or { batch_id = batch.id, status = batch.status, items = batch.items or {} }
    end
    local items = {}
    for _, raw in ipairs(snapshot.items or {}) do
        local item = { ref = tostring(raw.ref or ""), status = raw.status or "queued" }
        if type(raw.name) == "string" then
            item.name = raw.name
        end
        if type(raw.error) == "string" then
            item.error = raw.error
        end
        items[#items + 1] = item
    end
    local out = {
        batchId = snapshot.batch_id,
        status = snapshot.status,
        items = items,
    }
    if type(snapshot.summary) == "table" then
        out.summary = snapshot.summary
    end
    return out
end

--- @param session pi.Session
--- @return string lineage
local function lineage_of(session)
    local ok, Manifest = pcall(require, "pi.subsessions.manifest")
    if not ok then
        return session.id or ""
    end
    local lineage = Manifest.lineage_for_session(session)
    if lineage == "" then
        return session.id or ""
    end
    return lineage
end

--- @param session pi.Session
--- @return table[] batches, table[] subagents
function Instance:project_subagents(session)
    local lineage = lineage_of(session)
    local batches = {}
    local subagents = {}

    local ok_batch, Batch = pcall(require, "pi.subsessions.batch")
    if ok_batch and type(Batch.list_for_parent) == "function" then
        for _, batch in ipairs(Batch.list_for_parent(lineage)) do
            batches[#batches + 1] = project_batch(batch)
        end
    end

    local ok_manifest, Manifest = pcall(require, "pi.subsessions.manifest")
    if ok_manifest and type(Manifest.children_of) == "function" then
        for _, row in ipairs(Manifest.children_of(lineage)) do
            local child = {
                id = row._id or "",
                status = row.status or "dormant",
            }
            if type(row.name) == "string" and row.name ~= "" then
                child.name = row.name
            end
            if type(row.task_prompt) == "string" and row.task_prompt ~= "" then
                child.task = row.task_prompt
            end
            local config = row.config
            if type(config) == "table" then
                if type(config.model) == "table" and type(config.model.id) == "string" then
                    child.model = config.model.id
                end
                if type(config.thinking_level) == "string" then
                    child.thinking = config.thinking_level
                end
            end
            subagents[#subagents + 1] = child
        end
    end

    return batches, subagents
end

--- Signature of a projected batch: status + items + summary.
--- @param batch table
--- @return string
local function batch_signature(batch)
    local ok, encoded = pcall(vim.json.encode, {
        status = batch.status,
        items = batch.items or {},
        summary = batch.summary,
    })
    if ok and type(encoded) == "string" then
        return encoded
    end
    return table.concat({ tostring(batch.status), tostring(#(batch.items or {})), tostring(batch.summary ~= nil) }, "|")
end

--- @param session pi.Session
function Instance:publish_subagents(session)
    local batches, subagents = self:project_subagents(session)
    local parts = {}
    local sigs = self._batch_sig[session]
    if not sigs then
        sigs = {}
        self._batch_sig[session] = sigs
    end
    for _, batch in ipairs(batches) do
        parts[#parts + 1] = batch.batchId .. ":" .. tostring(batch.status)
        -- This runs on every settle/tool_end; only ship a batch whose status,
        -- items or summary actually changed.
        local sig = batch_signature(batch)
        if sigs[batch.batchId] ~= sig then
            sigs[batch.batchId] = sig
            self:emit(session, {
                type = Protocol.DERIVED.BATCH,
                batchId = batch.batchId,
                status = batch.status,
                items = batch.items,
                summary = batch.summary,
            })
        end
    end
    for _, child in ipairs(subagents) do
        parts[#parts + 1] = child.id .. ":" .. tostring(child.status)
    end
    local sig = table.concat(parts, "\0")
    if self._sub_sig[session] == sig then
        return
    end
    self._sub_sig[session] = sig
    self:emit(session, { type = Protocol.DERIVED.SUBAGENTS, subagents = subagents })
end

-- ---------------------------------------------------------------------------
-- derived: usage / context
-- ---------------------------------------------------------------------------

--- Ask the backend for authoritative token/cost/context numbers. Fire and
--- forget: the response travels through `handle_event`, where it becomes a
--- `pi2:session` patch (a response callback would duplicate it).
--- @param session pi.Session
function Instance:refresh_stats(session)
    if not self.bridge or not session.id then
        return
    end
    local rpc = session.rpc
    if not rpc or not rpc:is_running() then
        return
    end
    local now = mono_ms()
    local last = self._stats_at[session.id]
    if last and now - last < 1000 then
        return
    end
    self._stats_at[session.id] = now
    rpc:send({ type = "get_session_stats" })
end

--- @param data table `get_session_stats` response data
--- @return table patch
function Instance:stats_patch(data)
    local patch = {}
    local tokens = type(data.tokens) == "table" and data.tokens or nil
    local cost = type(data.cost) == "number" and data.cost or 0
    if tokens then
        patch.usage = {
            input = tonumber(tokens.input) or 0,
            output = tonumber(tokens.output) or 0,
            cacheRead = tonumber(tokens.cacheRead) or 0,
            cacheWrite = tonumber(tokens.cacheWrite) or 0,
            cost = cost,
        }
    elseif type(cost) == "number" then
        patch.usage = nil
    end
    local context = type(data.contextUsage) == "table" and data.contextUsage or nil
    if context then
        patch.contextUsage = {
            tokens = tonumber(context.tokens) or 0,
            window = tonumber(context.contextWindow) or tonumber(context.window) or 0,
            percent = tonumber(context.percent) or 0,
        }
    end
    return patch
end

-- ---------------------------------------------------------------------------
-- snapshots
-- ---------------------------------------------------------------------------

--- Project one queued attention request as a protocol `attention[]` item
--- (`pi2d/docs/protocol.md` §4/§6). Diffs are reported as method "diff" with
--- the decoded request payload, not as the pi-level "select".
--- @param entry pi.AttentionEntry
--- @param msg table|nil raw `extension_ui_request`
--- @param now integer
--- @return table
local function project_attention_entry(entry, msg, now)
    if type(msg) ~= "table" then
        msg = type(entry.msg) == "table" and entry.msg or {}
    end
    local item = {
        requestId = tostring(entry.id or msg.id or ""),
        method = entry.kind or msg.method or "select",
        createdAt = entry.created_at or now,
        receivedAt = entry.created_at or now,
    }
    if type(msg.title) == "string" then
        item.title = msg.title
    end
    if type(msg.message) == "string" then
        item.message = msg.message
    end
    if type(msg.options) == "table" then
        item.options = msg.options
    end
    if type(msg.timeout) == "number" then
        item.timeoutSec = math.max(0, math.floor(msg.timeout / 1000))
    end
    if item.method == "diff" then
        -- A diff review carries its payload as JSON in `title`.
        local ok, payload = pcall(vim.json.decode, type(msg.title) == "string" and msg.title or "")
        if ok and type(payload) == "table" then
            item.payload = payload
        end
    end
    return item
end

--- Project the attention queue of a session for a snapshot.
--- @param session pi.Session
--- @return table[]
local function project_attention(session)
    local pending = session.attention and session.attention.pending or {}
    local out = {}
    local now = now_ms()
    for _, entry in ipairs(pending) do
        out[#out + 1] = project_attention_entry(entry, entry.msg, now)
    end
    return out
end

--- Full SessionState for one session: the reducer's projection plus the live
--- fields only the plugin can read (session object, todo/task registries,
--- sub-session manifest, attention queue).
--- @param session pi.Session
--- @return table
function Instance:snapshot_for(session)
    local state = self:state_for(session):snapshot()
    state.sessionId = session.id or state.sessionId
    state.workspaceId = self.workspace_id
    state.cwd = session.cwd or self.cwd
    state.status = self:live_status(session, state.status)

    local pin = session.pinned_config
    if type(pin) == "table" then
        if type(pin.model) == "table" and (state.model == nil or state.model == vim.NIL) then
            state.model = pin.model
        end
        if type(pin.thinking_level) == "string" and (state.thinking == nil or state.thinking == vim.NIL) then
            state.thinking = pin.thinking_level
        end
    end

    local ok_todo, Todo = pcall(require, "pi.todo")
    if ok_todo and Todo.get then
        local details = Todo.get(session)
        if type(details) == "table" then
            state.todos = project_todos(details)
        end
    end

    local ok_tasks, Tasks = pcall(require, "pi.tasks")
    if ok_tasks and session.id then
        local tasks = {}
        for _, task in ipairs(Tasks.list(session.id)) do
            tasks[#tasks + 1] = project_task(task)
        end
        state.tasks = tasks
    end

    local batches, subagents = self:project_subagents(session)
    state.batches = batches
    state.subagents = subagents
    -- The queued attention entries are authoritative for what can still be
    -- answered, so the snapshot always carries them: an empty array clears a
    -- request that was answered/pruned elsewhere (protocol §6).
    local attention = project_attention(session)
    state.attention = attention
    state.flags.attention = #attention > 0

    return state
end

--- Entries a snapshot carries: the newest that fit the cap (`pi2d/docs/protocol.md`
--- §2 — a snapshot replaces the client's cache, so it must include a transcript
--- tail, not an empty list). Older history stays with the paginated
--- `workspace.query{kind="entries"}` path, which is authoritative.
--- @param entries pi.web.Entry[]|nil
--- @return pi.web.Entry[]
function Instance:snapshot_entries(entries)
    local out = {}
    if type(entries) ~= "table" then
        return out
    end
    local bytes = 0
    for i = #entries, 1, -1 do
        if #out >= MAX_SNAPSHOT_ENTRIES then
            break
        end
        local entry = entries[i]
        local ok, size = pcall(function()
            return #vim.json.encode(entry)
        end)
        if not ok then
            break
        end
        if bytes + size > MAX_SNAPSHOT_ENTRY_BYTES then
            break
        end
        bytes = bytes + size
        table.insert(out, 1, entry)
    end
    return out
end

--- @param session pi.Session
--- @return boolean queued
function Instance:send_snapshot(session)
    if not self.bridge or not session.id then
        return false
    end
    local state = self:snapshot_for(session)
    return self.bridge:send_snapshot(
        session.id,
        self.epoch,
        self:seq(session.id),
        state,
        self:snapshot_entries(state.entries)
    )
end

--- Instance-wide state (`instance_state`): session table + transport status.
--- @return table
function Instance:instance_state()
    local ok, manager = pcall(require, "pi.sessions.manager")
    local sessions = {}
    if ok then
        for _, session in ipairs(manager.list_all()) do
            local state = self:state_for(session):snapshot()
            local row = {
                sessionId = session.id,
                status = self:live_status(session, state.status),
                cwd = session.cwd,
            }
            if type(state.name) == "string" then
                row.name = state.name
            end
            if session.attached_tab then
                row.tab = session.attached_tab
            end
            if type(state.model) == "table" then
                row.model = state.model
            end
            sessions[#sessions + 1] = row
        end
    end
    local ready = self.bridge and self.bridge:status().ready or false
    return {
        status = ready and "ready" or "starting",
        workspaceId = self.workspace_id,
        instanceId = self.bridge and self.bridge:status().instance_id or nil,
        hasUI = M.has_ui(),
        sessions = sessions,
    }
end

--- @return boolean queued
function Instance:send_instance_state()
    if not self.bridge then
        return false
    end
    return self.bridge:send_instance_state(self:instance_state())
end

-- ---------------------------------------------------------------------------
-- daemon callbacks
-- ---------------------------------------------------------------------------

--- The daemon subscribed to a session: answer with a snapshot (protocol §2).
--- @param session_id string|nil
function Instance:on_subscribe(session_id)
    if type(session_id) ~= "string" or session_id == "" then
        return
    end
    self._subscribed[session_id] = true
    local ok, manager = pcall(require, "pi.sessions.manager")
    local session = ok and manager.get_by_id(session_id) or nil
    if not session then
        return
    end
    self:send_snapshot(session)
    self:publish_todo(session)
    self:_publish_tasks_for(session)
    self:publish_subagents(session)
    self:refresh_stats(session)
end

--- @param session_id string|nil
function Instance:on_unsubscribe(session_id)
    if type(session_id) == "string" then
        self._subscribed[session_id] = nil
    end
end

--- Registry changed (create/open/close/rename): refresh the instance table and
--- re-snapshot subscribed sessions.
--- @param session pi.Session|nil
function Instance:on_registry_change(session)
    if type(session) == "table" and session.id then
        self:state_for(session)
        if self._subscribed[session.id] then
            self:send_snapshot(session)
        end
    end
    self:send_instance_state()
end

-- ---------------------------------------------------------------------------
-- event fanout
-- ---------------------------------------------------------------------------

--- Raw pi event fanout. Called from the tail of `manager.handle_event`, i.e.
--- after every built-in handler ran, so derived events read updated state.
--- @param session pi.Session
--- @param msg table
function Instance:on_event(session, msg)
    if type(session) ~= "table" or type(msg) ~= "table" then
        return
    end
    local event_type = msg.type
    if type(event_type) ~= "string" then
        return
    end
    self:state_for(session)

    if event_type == "response" then
        local command = msg.command
        local data = type(msg.data) == "table" and msg.data or nil
        if msg.success and data then
            if command == "get_state" then
                local patch = { sessionId = session.id }
                if
                    type(data.model) == "table"
                    and type(data.model.provider) == "string"
                    and type(data.model.id) == "string"
                then
                    patch.model = { provider = data.model.provider, id = data.model.id }
                end
                if type(data.thinkingLevel) == "string" then
                    patch.thinking = data.thinkingLevel
                end
                if patch.model then
                    -- A different model may come from a provider that was just
                    -- (re)configured: drop the cached model list so the web
                    -- picks the new one up instead of a stale snapshot.
                    local sig = tostring(patch.model.provider) .. "/" .. tostring(patch.model.id)
                    local previous = self._model_sig[session]
                    if previous and previous ~= sig then
                        self:invalidate_models()
                    end
                    self._model_sig[session] = sig
                end
                if type(data.sessionName) == "string" then
                    patch.name = data.sessionName
                elseif data.sessionName == vim.NIL then
                    patch.name = vim.NIL
                end
                self:emit(session, { type = Protocol.DERIVED.SESSION, session = patch })
            elseif command == "get_session_stats" then
                local patch = self:stats_patch(data)
                patch.sessionId = session.id
                self:emit(session, { type = Protocol.DERIVED.SESSION, session = patch })
            end
        end
        return
    end

    if event_type == "_stderr" then
        if type(msg.message) == "string" and msg.message ~= "" then
            self:emit_error(session, msg.message)
        end
        return
    end

    -- Verbatim pi event (the reducer and the browser both consume it).
    msg.ts = msg.ts or now_ms()
    self:state_for(session):apply(msg)
    self:_send(session, msg)

    if
        event_type == "agent_start"
        or event_type == "agent_settled"
        or event_type == "compaction_start"
        or event_type == "compaction_end"
        or event_type == "auto_compaction_start"
        or event_type == "auto_compaction_end"
        or event_type == "thinking_level_changed"
        or event_type == "session_info_changed"
        or event_type == "_process_exit"
    then
        self:emit_session(session)
        self:send_instance_state()
    end

    if event_type == "tool_execution_end" then
        self:publish_todo(session)
        self:_publish_tasks_for(session)
        self:publish_subagents(session)
    elseif event_type == "message_start" then
        local message = msg.message
        if type(message) == "table" and message.role == "custom" then
            self:_publish_tasks_for(session)
        end
    elseif event_type == "agent_settled" then
        self:_publish_tasks_for(session)
        self:publish_subagents(session)
        self:refresh_stats(session)
    elseif event_type == "_process_exit" then
        self:emit(session, { type = Protocol.DERIVED.PROCESS_EXIT, code = msg.code })
        self:_publish_tasks_for(session)
        self:publish_subagents(session)
    end
end

-- ---------------------------------------------------------------------------
-- attention hooks (called from `pi.attention`)
-- ---------------------------------------------------------------------------

--- @param session pi.Session
--- @param msg table the raw `extension_ui_request`
--- @param entry pi.AttentionEntry
function Instance:emit_attention_request(session, msg, entry)
    local event = project_attention_entry(entry, msg, now_ms())
    event.type = Protocol.DERIVED.ATTENTION_REQUEST
    self:emit(session, event)
end

--- @param session pi.Session
--- @param request_id string
--- @param by string|nil
--- @param response table|nil
function Instance:emit_attention_resolved(session, request_id, by, response)
    self:emit(session, {
        type = Protocol.DERIVED.ATTENTION_RESOLVED,
        requestId = request_id,
        by = by or "web",
        response = response,
    })
end

--- Stop the singleton (called from `pi.web.stop`).
function M.shutdown()
    if current then
        current._active = false
        current.bridge = nil
    end
    current = nil
end

-- ---------------------------------------------------------------------------
-- module-level facade (the manager/attention hooks use these)
-- ---------------------------------------------------------------------------

--- @param session pi.Session
--- @param msg table
function M.on_event(session, msg)
    if current then
        current:on_event(session, msg)
    end
end

--- @param session pi.Session|nil
function M.on_registry_change(session)
    if current then
        current:on_registry_change(session)
    end
end

--- @param session pi.Session
--- @param msg table
--- @param entry pi.AttentionEntry
function M.emit_attention_request(session, msg, entry)
    if current then
        current:emit_attention_request(session, msg, entry)
    end
end

--- @param session pi.Session
--- @param request_id string
--- @param by string|nil
--- @param response table|nil
function M.emit_attention_resolved(session, request_id, by, response)
    if current then
        current:emit_attention_resolved(session, request_id, by, response)
    end
end

--- @param session pi.Session
--- @param message string
function M.emit_error(session, message)
    if current then
        current:emit_error(session, message)
    end
end

return M
