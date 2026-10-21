-- Protocol method handlers (web console → plugin).
--
-- Every handler delegates to the plugin path the TUI itself uses: the session
-- manager (create/open/close/prompt), `pi.attention` (dialogs), `pi.tasks`,
-- `pi.subsessions` (batch dispatch/stop/read). Nothing here talks to the RPC
-- socket directly when a higher-level path exists, and nothing owns state: the
-- handler either triggers an existing function (whose events flow back through
-- `manager.handle_event` → `pi.web.instance`) or answers a read.
--
-- Contract (see `pi.web.bridge`): `handler(params, ctx) -> true, result` acks;
-- `nil, { code = ..., message = ... }` sends an error record.
--
-- A handler that starts asynchronous work acks immediately (`disposition =
-- "started"`); progress and failures arrive as `pi2:*` events.

local M = {}

local Protocol = require("pi.web.protocol")

--- @class pi.web.Commands
--- @field handlers table<string, fun(params: table|nil, ctx: pi.web.CmdContext): any, any>

--- @param code string
--- @param message string
--- @return nil, table
local function failure(code, message)
    return nil, { code = code, message = message }
end

--- @param message string
--- @return nil, table
local function bad_request(message)
    return failure(Protocol.ERR.BAD_REQUEST, message)
end

--- Resolve modules at call time so specs (and users) can stub the plugin paths.
--- @return table
local function Sessions()
    return require("pi.sessions.manager")
end

--- @return pi.web.Instance|nil
local function Instance()
    local ok, instance = pcall(require, "pi.web.instance")
    if not ok then
        return nil
    end
    return instance.instance()
end

--- Target session from the command envelope.
--- @param ctx pi.web.CmdContext
--- @return pi.Session|nil, table|nil
local function target(ctx)
    local id = ctx and ctx.session_id
    if type(id) ~= "string" or id == "" then
        return bad_request("sessionId is required")
    end
    local session = Sessions().get_by_id(id)
    if not session then
        return failure(Protocol.ERR.SESSION_NOT_FOUND, "unknown session: " .. id)
    end
    return session
end

--- @param mode unknown
--- @return "steer"|"follow_up"|nil
local function queue_type(mode)
    if mode == "steer" then
        return "steer"
    end
    if mode == "follow_up" or mode == "followUp" or mode == "follow-up" then
        return "follow_up"
    end
    return nil
end

--- @type table<string, fun(params: table|nil, ctx: pi.web.CmdContext): any, any>
local handlers = {}

-- ---------------------------------------------------------------------------
-- session lifecycle
-- ---------------------------------------------------------------------------

--- @param params table|nil
--- @param _ pi.web.CmdContext
handlers["session.create"] = function(params, _)
    params = params or {}
    local existing = type(params.sessionId) == "string" and Sessions().get_by_id(params.sessionId) or nil
    if existing then
        return true, { sessionId = existing.id }
    end
    local session = Sessions().create_for_web({})
    if not session then
        return failure(Protocol.ERR.INTERNAL, "failed to start a session")
    end
    local instance = Instance()
    if instance then
        instance:on_registry_change(session)
    end
    return true, { sessionId = session.id, cwd = session.cwd }
end

--- @param params table|nil
--- @param _ pi.web.CmdContext
local function open_session(params, _)
    params = params or {}
    local path = params.sessionFile or params.sessionPath
    if type(path) ~= "string" or path == "" then
        return bad_request("sessionFile is required")
    end
    local session = Sessions().create_for_web({})
    if not session then
        return failure(Protocol.ERR.INTERNAL, "failed to start a session")
    end
    Sessions().load_session_path(session, path, function(ok)
        if not ok then
            local instance = Instance()
            if instance then
                instance:emit_error(session, "failed to open session: " .. path)
            end
        end
    end)
    local instance = Instance()
    if instance then
        instance:on_registry_change(session)
    end
    return true, { sessionId = session.id, sessionFile = path, disposition = "started" }
end

handlers["session.open"] = open_session
handlers["session.resume"] = open_session

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["session.close"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    -- `mode = "hibernate"` is accepted for protocol compatibility; the session
    -- file always stays on disk, so both modes stop the process and detach.
    Sessions().close_session(session)
    local instance = Instance()
    if instance then
        instance:on_registry_change(nil)
    end
    return true, { sessionId = ctx.session_id, mode = params.mode or "stop" }
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["session.rename"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    local name = params.name
    if type(name) ~= "string" or name == "" then
        return bad_request("name is required")
    end
    if not session.rpc:is_running() then
        return failure(Protocol.ERR.INTERNAL, "session process is not running")
    end
    session.rpc:send({ type = "set_session_name", name = name })
    return true, { name = name }
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["session.fork"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    local entry_id = params.entryId
    if type(entry_id) ~= "string" or entry_id == "" then
        return bad_request("entryId is required")
    end
    local ok, Fork = pcall(require, "pi.fork")
    if not ok or type(Fork._do_fork) ~= "function" then
        return failure(Protocol.ERR.UNSUPPORTED, "fork is not available")
    end
    Fork._do_fork(session, entry_id)
    return true, { disposition = "started" }
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["session.compact"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    require("pi").compact(params.instructions or params.customInstructions, session)
    return true, { disposition = "started" }
end

-- ---------------------------------------------------------------------------
-- prompts and queue
-- ---------------------------------------------------------------------------

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["prompt.send"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    if type(params.text) ~= "string" then
        return bad_request("text is required")
    end
    local sent = Sessions().prompt(session, params.text, {
        queue_type = queue_type(params.mode),
        images = params.images,
    })
    if not sent then
        return failure(Protocol.ERR.INTERNAL, "failed to send the prompt")
    end
    return true, { disposition = "started" }
end

--- @param _ table|nil
--- @param ctx pi.web.CmdContext
handlers["prompt.abort"] = function(_, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    if session.rpc:is_running() then
        session.rpc:send({ type = "abort" })
    end
    require("pi.attention").clear_session(session)
    return true, {}
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["queue.remove"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    local chat = session.chat
    if not chat or type(chat._delete_pi_queued_entry) ~= "function" then
        return failure(Protocol.ERR.UNSUPPORTED, "queue editing requires an attached chat")
    end
    local history = chat._history
    ---@type any[]
    local queue = history and history.get_pending_queue and history:get_pending_queue() or {}
    local index = tonumber(params.index)
    if not index then
        local id = params.id
        for i, entry in ipairs(queue) do
            if id ~= nil and (entry.id == id or entry.expanded == id or entry.text == id) then
                index = i
                break
            end
        end
    end
    if not index or not queue[index] then
        return failure(Protocol.ERR.NOT_FOUND, "no queued message at that position")
    end
    chat:_delete_pi_queued_entry(index, queue[index])
    return true, { removed = index }
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["queue.setSteer"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    local mode = params.mode
    if mode == nil and type(params.steer) == "boolean" then
        mode = params.steer and "all" or "one-at-a-time"
    end
    if mode ~= "all" and mode ~= "one-at-a-time" then
        return bad_request('mode must be "all" or "one-at-a-time"')
    end
    if not session.rpc:is_running() then
        return failure(Protocol.ERR.INTERNAL, "session process is not running")
    end
    session.rpc:send({ type = "set_steering_mode", mode = mode })
    return true, { mode = mode }
end

-- ---------------------------------------------------------------------------
-- session settings
-- ---------------------------------------------------------------------------

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["session.setModel"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    local model = params.model
    local provider = type(model) == "table" and model.provider or params.provider
    local model_id = type(model) == "table" and model.id or params.modelId
    if type(provider) ~= "string" or type(model_id) ~= "string" then
        return bad_request("model { provider, id } is required")
    end
    if not session.rpc:is_running() then
        return failure(Protocol.ERR.INTERNAL, "session process is not running")
    end
    session.rpc:send({ type = "set_model", provider = provider, modelId = model_id }, function()
        vim.schedule(function()
            Sessions().refresh_state(session)
        end)
    end)
    return true, { provider = provider, id = model_id }
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["session.setThinking"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    local level = params.level or params.thinking
    if type(level) ~= "string" or level == "" then
        return bad_request("level is required")
    end
    if not session.rpc:is_running() then
        return failure(Protocol.ERR.INTERNAL, "session process is not running")
    end
    session.rpc:send({ type = "set_thinking_level", level = level }, function()
        vim.schedule(function()
            Sessions().refresh_state(session)
        end)
    end)
    return true, { level = level }
end

-- ---------------------------------------------------------------------------
-- attention
-- ---------------------------------------------------------------------------

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["attention.respond"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    local request_id = params.requestId or params.id
    if type(request_id) ~= "string" or request_id == "" then
        return bad_request("requestId is required")
    end
    local ok, code = require("pi.attention").resolve(session, request_id, params.by or "web", params.response)
    if not ok then
        return failure(code or Protocol.ERR.ATTENTION_RESOLVED, "attention request already resolved")
    end
    return true, { requestId = request_id }
end

-- ---------------------------------------------------------------------------
-- sub-agents
-- ---------------------------------------------------------------------------

--- @param params table
--- @return string
local function host_payload(params)
    return vim.json.encode({
        action = params.action,
        params = params.params or {},
    })
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["subagent.dispatch"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    if type(params.items) ~= "table" then
        return bad_request("items is required")
    end
    local ok, Subsessions = pcall(require, "pi.subsessions")
    if not ok then
        return failure(Protocol.ERR.UNSUPPORTED, "sub-sessions are not available")
    end
    local instance = Instance()
    Subsessions.handle_host(
        session,
        host_payload({
            action = "dispatch_subagents",
            params = {
                items = params.items,
                cancel_siblings_on_fail = params.cancel_siblings_on_fail,
                wait = params.wait,
                timeout_ms = params.timeout_ms,
            },
        }),
        function(result)
            if instance then
                instance:publish_subagents(session)
                if type(result) == "table" and result.error then
                    instance:emit_error(session, result.error)
                end
            end
        end
    )
    return true, { disposition = "started" }
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["subagent.stop"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    if type(params.targets) ~= "table" or #params.targets == 0 then
        return bad_request("targets is required")
    end
    local ok, Subsessions = pcall(require, "pi.subsessions")
    if not ok then
        return failure(Protocol.ERR.UNSUPPORTED, "sub-sessions are not available")
    end
    local instance = Instance()
    Subsessions.handle_host(
        session,
        host_payload({ action = "stop_subagents", params = { targets = params.targets } }),
        function()
            if instance then
                instance:publish_subagents(session)
            end
        end
    )
    return true, { disposition = "started" }
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["subagent.steer"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    local ref = params.target or params.childId
    local text = params.message or params.text
    if type(ref) ~= "string" or ref == "" then
        return bad_request("target is required")
    end
    if type(text) ~= "string" or text == "" then
        return bad_request("message is required")
    end
    local child = Sessions().get_by_id(ref) or Sessions().find_by_lineage(ref)
    if not child then
        return failure(Protocol.ERR.NOT_FOUND, "unknown sub-agent: " .. ref)
    end
    if not Sessions().prompt(child, text, { queue_type = "steer" }) then
        return failure(Protocol.ERR.INTERNAL, "failed to steer the sub-agent")
    end
    return true, { sessionId = child.id, disposition = "started" }
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["subagent.read"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    local ref = params.target or params.sessionId
    local path = params.sessionFile
    local ok, Read = pcall(require, "pi.subsessions.read")
    if not path and ok and type(ref) == "string" and ref ~= "" then
        path = Read.find_path(ref)
    end
    if not path then
        return failure(Protocol.ERR.NOT_FOUND, "unknown sub-agent session file")
    end
    if not ok then
        return failure(Protocol.ERR.UNSUPPORTED, "sub-session reader is not available")
    end
    local tail = tonumber(params.tail) or tonumber(params.limit) or 50
    return true, { sessionFile = path, lines = Read.project_tail(path, tail) }
end

-- ---------------------------------------------------------------------------
-- tasks
-- ---------------------------------------------------------------------------

--- @param params table|nil
--- @param _ pi.web.CmdContext
handlers["task.stop"] = function(params, _)
    params = params or {}
    local id = params.taskId or params.id
    if type(id) ~= "string" or id == "" then
        return bad_request("taskId is required")
    end
    local Tasks = require("pi.tasks")
    local task = Tasks.get(id)
    if not task then
        return failure(Protocol.ERR.NOT_FOUND, "unknown task: " .. id)
    end
    Tasks.mark_stopped(id)
    if type(task.pid) == "number" then
        local uv = vim.uv or vim.loop
        pcall(uv.kill, task.pid, "sigterm")
    end
    return true, { taskId = id }
end

-- ---------------------------------------------------------------------------
-- workspace reads
-- ---------------------------------------------------------------------------

--- @param session pi.Session
--- @param instance pi.web.Instance|nil
--- @return table
local function live_session_row(session, instance)
    local row = {
        sessionId = session.id,
        sessionFile = session.session_file,
        cwd = session.cwd,
        tab = session.attached_tab,
        live = session.rpc and session.rpc:is_running() or false,
    }
    if instance then
        row.status = instance:live_status(session)
        local pin = session.pinned_config
        if type(pin) == "table" and type(pin.model) == "table" then
            row.model = pin.model
        end
    end
    return row
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
--- @return any, any
local function workspace_query(params, ctx)
    params = params or {}
    local kind = params.kind
    local instance = Instance()

    if kind == "sessions" then
        local sessions = {}
        local seen = {}
        local ok, History = pcall(require, "pi.sessions.history")
        if ok and type(History.list) == "function" then
            for _, info in ipairs(History.list()) do
                sessions[#sessions + 1] = {
                    sessionId = info.id,
                    sessionFile = info.path,
                    name = info.name,
                    timestamp = info.timestamp,
                    modified = info.modified,
                    firstMessage = info.first_message,
                }
                seen[info.id] = true
            end
        end
        for _, session in ipairs(Sessions().list_all()) do
            local row = live_session_row(session, instance)
            if seen[session.id] then
                for _, disk in ipairs(sessions) do
                    if disk.sessionId == session.id then
                        disk.live = row.live
                        disk.status = row.status
                        disk.tab = row.tab
                        disk.sessionFile = disk.sessionFile or row.sessionFile
                        disk.model = row.model
                    end
                end
            else
                sessions[#sessions + 1] = row
            end
        end
        return true, { sessions = sessions }
    end

    if kind == "entries" then
        local path = params.sessionFile
        if not path then
            local session = ctx.session_id and Sessions().get_by_id(ctx.session_id) or nil
            path = session and session.session_file or nil
        end
        if type(path) ~= "string" or path == "" then
            return bad_request("sessionFile is required")
        end
        local ok, History = pcall(require, "pi.web.history")
        if not ok then
            return failure(Protocol.ERR.UNSUPPORTED, "session history is not available")
        end
        local reader, open_err = History.open(path)
        if not reader then
            return failure(Protocol.ERR.NOT_FOUND, open_err or "cannot read session file")
        end
        local page
        if type(params.before) == "string" and params.before ~= "" then
            page = reader:before(params.before, params.limit)
        else
            page = reader:tail(params.limit)
        end
        return true, page
    end

    return bad_request('kind must be "sessions" or "entries"')
end

handlers["workspace.query"] = workspace_query

--- Dispatch a method by name, mapping unknown methods to `E_METHOD_NOT_ALLOWED`
--- (the bridge uses `handlers` directly; this helper is for tests and internal
--- callers that need the error shape).
--- @param method string|nil
--- @param params table|nil
--- @param ctx pi.web.CmdContext
--- @return any, any
function M.dispatch(method, params, ctx)
    local handler = type(method) == "string" and handlers[method] or nil
    if type(handler) ~= "function" then
        return failure(Protocol.ERR.METHOD_NOT_ALLOWED, "unknown method: " .. tostring(method))
    end
    local ok, first, second = pcall(handler, params, ctx)
    if not ok then
        return failure(Protocol.ERR.INTERNAL, tostring(first))
    end
    return first, second
end

--- @type pi.web.Commands
M.handlers = handlers

return M
