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
    -- `mode = "queue"` (what the web client sends) and any unknown value mean
    -- "plain prompt": the TUI's normal submit path, not a queue injection.
    return nil
end

--- Thinking levels the backend accepts (mirrors the pi thinking-level union).
--- @type table<string, true>
local THINKING_LEVELS = {
    off = true,
    minimal = true,
    low = true,
    medium = true,
    high = true,
    xhigh = true,
    max = true,
}

--- Session ids are placeholders (`tmp-N`) until the backend reports the real id
--- in a `get_state` response; only then is the id stable across the instance.
--- @param id unknown
--- @return boolean
local function is_placeholder_id(id)
    return type(id) == "string" and id:match("^tmp%-") ~= nil
end

--- Upper bound for the id wait in `session.create`/`open`/`resume`. Mutable so
--- specs can exercise both the settled and the timed-out path quickly.
--- @type integer
M._id_wait_ms = 5000

--- Wait for the backend to replace the placeholder id with the real one.
---
--- `vim.wait` processes the event loop in between slices, so the RPC callback
--- that migrates the id (`manager.refresh_state` → `capture_session_id`) runs
--- while we wait. Never blocks past `M._id_wait_ms`.
--- @param session pi.Session
--- @return string id The settled id (or the placeholder on timeout).
--- @return boolean settled
local function await_backend_id(session)
    local uv = vim.uv or vim.loop
    local deadline = uv.now() + M._id_wait_ms
    while is_placeholder_id(session.id) do
        local remaining = deadline - uv.now()
        if remaining <= 0 then
            break
        end
        vim.wait(math.min(50, remaining), function()
            return not is_placeholder_id(session.id)
        end, 5)
    end
    return session.id, not is_placeholder_id(session.id)
end

--- Ack a freshly created/loaded session with its real id.
---
--- The instance is told about the registry entry only after the id settled, so
--- the instance table and the session snapshot carry the backend id instead of
--- the placeholder. A timeout still acks (with `pending = true`) so the client
--- can poll instead of hanging.
--- @param session pi.Session
--- @param extra table|nil Extra ack fields.
--- @return true, table
local function ack_session(session, extra)
    local id, settled = await_backend_id(session)
    local instance = Instance()
    if instance then
        instance:on_registry_change(session)
    end
    local result = { sessionId = id }
    for key, value in pairs(extra or {}) do
        result[key] = value
    end
    if not settled then
        result.pending = true
    end
    return true, result
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
    return ack_session(session, { cwd = session.cwd })
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
    return ack_session(session, { sessionFile = path, disposition = "started" })
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
    if not session.chat then
        return failure(Protocol.ERR.UNSUPPORTED, "forking requires an attached chat")
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
    if not session.chat then
        return failure(Protocol.ERR.UNSUPPORTED, "compaction requires an attached chat")
    end
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

--- Resolve a queue id to an index in the pending queue.
---
--- The daemon renders the queue as `q:steer:N` / `q:follow:N`, one counter per
--- kind; the counters it ships are 0-based (`src/protocol/reducer.ts`), the
--- contract here is 1-based. Both are accepted: `N >= 1` is the 1-based position
--- inside that kind, `N == 0` is the 0-based first entry.
--- @param queue pi.PendingQueueEntry[]
--- @param id unknown
--- @return integer|nil
local function resolve_queue_id(queue, id)
    if type(id) ~= "string" then
        return nil
    end
    local kind, position = id:match("^q:(%a+):(%d+)$")
    if not kind then
        return nil
    end
    local want_steer
    if kind == "steer" then
        want_steer = true
    elseif kind == "follow" or kind == "follow_up" then
        want_steer = false
    else
        return nil
    end
    local n = tonumber(position)
    if not n then
        return nil
    end
    -- Entries keep their kind in `queue_type`; anything that is not a steer is a
    -- follow-up (the TUI's sender groups them the same way).
    local offset = n >= 1 and n or 1
    local seen = 0
    for i, entry in ipairs(queue) do
        local is_steer = (entry.queue_type or "follow_up") == "steer"
        if is_steer == want_steer then
            seen = seen + 1
            if seen == offset then
                return i
            end
        end
    end
    return nil
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
    ---@type pi.PendingQueueEntry[]
    local queue = history and history.get_pending_queue and history:get_pending_queue() or {}

    local index = tonumber(params.index)
    local id = params.id ~= nil and params.id or params.queueId
    if not index and id ~= nil then
        index = resolve_queue_id(queue, id)
    end
    if not index and id ~= nil and #queue > 0 then
        -- Legacy/text form: the raw queued text is accepted as the id too.
        for i, entry in ipairs(queue) do
            if entry.text == id or entry.expanded_text == id then
                index = i
                break
            end
        end
    end
    if not index or not queue[index] then
        return failure(Protocol.ERR.NOT_FOUND, "no queued message at that position")
    end
    chat:_delete_pi_queued_entry(index, queue[index])
    local ack = { removed = index }
    if type(id) == "string" then
        ack.id = id
    end
    return true, ack
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["queue.setSteer"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    -- `{mode}` is canonical. The web client sends `{queueId, steer}`: the switch
    -- is session-wide ("are steers delivered immediately or one at a time?"), so
    -- the per-entry id is accepted and ignored.
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
-- model cache (shared with `workspace.query{kind="models"}`)
-- ---------------------------------------------------------------------------

--- Cached `get_available_models` result for the web console. The web polls
--- `/api/v1/models`; the first call kicks off the fetch and answers with an
--- empty list (`pending = true`), later calls return the grouped providers.
--- `session.setModel` validates against the same cache once it is populated.
--- @type { provider: string, models: table[] }[]|nil
local models_cache = nil
local models_pending = false

--- Group the flat pi model list by provider for the web contract.
--- @param models table[]
--- @return { provider: string, models: table[] }[]
local function group_models(models)
    local order, by_provider = {}, {}
    for _, model in ipairs(models or {}) do
        if type(model) == "table" then
            local provider = model.provider or model.providerId or "unknown"
            local group = by_provider[provider]
            if not group then
                group = { provider = provider, models = {} }
                by_provider[provider] = group
                order[#order + 1] = group
            end
            group.models[#group.models + 1] = {
                id = model.id or model.model or "unknown",
                contextWindow = model.contextWindow or model.contextWindowTokens or model.context_window,
                reasoning = model.reasoning == true,
            }
        end
    end
    return order
end

--- Fetch the available models once, from the first live session.
local function refresh_models()
    if models_pending or models_cache then
        return
    end
    local session
    for _, candidate in ipairs(Sessions().list_all()) do
        if candidate.rpc and candidate.rpc:is_running() then
            session = candidate
            break
        end
    end
    if not session then
        return
    end
    models_pending = true
    session.rpc:send({ type = "get_available_models" }, function(res)
        vim.schedule(function()
            models_pending = false
            if res and res.success then
                local list = (res.data or {}).models or {}
                if #list > 0 then
                    models_cache = group_models(list)
                end
            end
        end)
    end)
end

--- Is `provider/id` a model the backend reported?
--- @param provider string
--- @param id string
--- @return boolean|nil `true`/`false`, or `nil` while the cache is empty.
local function model_is_known(provider, id)
    if not models_cache then
        return nil
    end
    for _, group in ipairs(models_cache) do
        if group.provider == provider then
            for _, model in ipairs(group.models or {}) do
                if model.id == id then
                    return true
                end
            end
            return false
        end
    end
    return false
end

--- Drop the cached model list (specs; also after a provider reconfiguration).
function M._reset_caches()
    models_cache = nil
    models_pending = false
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
    -- Accepted shapes: `{model:{provider,id}}`, `{provider, modelId}`, and
    -- `{provider, id}` (what the web client sends).
    local model = params.model
    local provider = type(model) == "table" and model.provider or params.provider
    local model_id
    if type(model) == "table" then
        model_id = model.id
    elseif type(params.modelId) == "string" then
        model_id = params.modelId
    else
        model_id = params.id
    end
    if type(provider) ~= "string" or provider == "" or type(model_id) ~= "string" or model_id == "" then
        return bad_request("model { provider, id } is required")
    end
    -- Only reject what we know is wrong: an unpopulated cache cannot validate.
    if model_is_known(provider, model_id) == false then
        return bad_request("unknown model: " .. provider .. "/" .. model_id)
    end
    if not session.rpc:is_running() then
        return failure(Protocol.ERR.INTERNAL, "session process is not running")
    end
    -- The TUI switch path (`pi.models.set`): same `set_model` command, plus the
    -- tab model pin and the state refresh on success.
    require("pi.models").set(session, { provider = provider, id = model_id })
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
    if type(level) == "string" then
        level = vim.trim(level)
    end
    if type(level) ~= "string" or not THINKING_LEVELS[level] then
        return bad_request("level must be one of off, minimal, low, medium, high, xhigh, max")
    end
    if not session.rpc:is_running() then
        return failure(Protocol.ERR.INTERNAL, "session process is not running")
    end
    session.rpc:send({ type = "set_thinking_level", level = level }, function(res)
        vim.schedule(function()
            if res and res.success == false then
                -- The model rejected the level; nothing to mirror.
                return
            end
            Sessions().refresh_state(session)
            -- Mirror the accepted level into the projection right away. The
            -- backend's `thinking_level_changed` notification is not one of the
            -- manager's handled events, so without this a client reading the
            -- state before the next `get_state` patch keeps the old level.
            local instance = Instance()
            if instance then
                instance:emit(session, {
                    type = Protocol.DERIVED.SESSION,
                    session = { sessionId = session.id, thinking = level },
                })
            end
        end)
    end)
    return true, { level = level }
end

-- ---------------------------------------------------------------------------
-- attention
-- ---------------------------------------------------------------------------

--- Normalize an attention answer to the `pi.attention.resolve` response shape.
---
--- Canonical: `{response:{value|confirmed|cancelled}}`. Backward compatible: a
--- raw string or `{optionId}`/`params.optionId` answer is wrapped into
--- `{value=...}`; a missing response cancels (what `pi.attention` already did).
--- @param params table
--- @return table|nil response
--- @return string disposition
local function normalize_attention_response(params)
    local response = params.response
    if type(response) == "string" then
        return { value = response }, "accepted"
    end
    if type(response) == "table" then
        if response.cancelled ~= nil then
            local cancelled = response.cancelled == true
            return { cancelled = cancelled }, cancelled and "cancelled" or "accepted"
        end
        if response.confirmed ~= nil then
            local confirmed = response.confirmed == true
            return { confirmed = confirmed }, confirmed and "accepted" or "cancelled"
        end
        if response.value ~= nil then
            return { value = response.value }, "accepted"
        end
        if response.optionId ~= nil then
            return { value = response.optionId }, "accepted"
        end
        return nil, "cancelled"
    end
    if params.optionId ~= nil then
        return { value = params.optionId }, "accepted"
    end
    return nil, "cancelled"
end

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
    local response, disposition = normalize_attention_response(params)
    local ok, code = require("pi.attention").resolve(session, request_id, params.by or "web", response)
    if not ok then
        return failure(code or Protocol.ERR.ATTENTION_RESOLVED, "attention request already resolved")
    end
    return true, { requestId = request_id, disposition = disposition }
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

--- Normalize one `subagent.dispatch` item: `thinking` is an alias for
--- `thinking_level` (the canonical key the batch runner reads).
--- @param raw any
--- @return any
local function normalize_dispatch_item(raw)
    if type(raw) ~= "table" or type(raw.task) ~= "string" then
        return raw
    end
    local thinking = raw.thinking_level
    if thinking == nil then
        thinking = raw.thinking
    end
    if thinking == nil then
        return raw
    end
    local item = vim.deepcopy(raw)
    item.thinking_level = thinking
    -- Forwarded as the canonical key only; `thinking` is not a batch field.
    item.thinking = nil
    return item
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
handlers["subagent.dispatch"] = function(params, ctx)
    local session, err = target(ctx)
    if not session then
        return nil, err
    end
    params = params or {}
    local items = params.items
    if type(items) ~= "table" and type(params.task) == "string" then
        -- Single-task shorthand: the web client's sub-agent form sends the item
        -- fields flat, the canonical shape wraps them in `items`.
        items = {
            {
                task = params.task,
                name = params.name,
                model = params.model,
                thinking_level = params.thinking_level,
                thinking = params.thinking,
            },
        }
    end
    if type(items) ~= "table" or #items == 0 then
        return bad_request("items is required")
    end
    local normalized = {}
    for i, raw in ipairs(items) do
        normalized[i] = normalize_dispatch_item(raw)
    end
    local ok, Subsessions = pcall(require, "pi.subsessions")
    if not ok then
        return failure(Protocol.ERR.UNSUPPORTED, "sub-sessions are not available")
    end
    local instance = Instance()
    local batch_id
    local cancel_siblings = params.cancel_siblings_on_fail
    if cancel_siblings == nil then
        cancel_siblings = params.cancelSiblingsOnFail
    end
    Subsessions.handle_host(
        session,
        host_payload({
            action = "dispatch_subagents",
            params = {
                items = normalized,
                cancel_siblings_on_fail = cancel_siblings,
                wait = params.wait,
                timeout_ms = params.timeout_ms,
            },
        }),
        function(result)
            if type(result) == "table" and type(result.batch_id) == "string" then
                batch_id = result.batch_id
            end
            if instance then
                instance:publish_subagents(session)
                if type(result) == "table" and result.error then
                    instance:emit_error(session, result.error)
                end
            end
        end
    )
    -- The batch is started asynchronously; a synchronously reported id (an
    -- already-terminal dispatch) is included so the client can poll it.
    local ack = { disposition = "started" }
    if batch_id then
        ack.batchId = batch_id
    end
    return true, ack
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

--- Cap on how much of an output file is read (the tail is all the modal shows).
local TASK_OUTPUT_READ_BYTES = 512 * 1024
local TASK_OUTPUT_DEFAULT_LINES = 200
local TASK_OUTPUT_MAX_LINES = 1000

--- Read the last `max_lines` lines of `path` with uv, without slurping a huge
--- log: at most `TASK_OUTPUT_READ_BYTES` from the end of the file are read.
--- @param path string
--- @param max_lines integer
--- @return string|nil
local function read_output_tail(path, max_lines)
    local uv = vim.uv or vim.loop
    local stat = uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
        return nil
    end
    local size = stat.size or 0
    local offset = math.max(0, size - TASK_OUTPUT_READ_BYTES)
    local fd = uv.fs_open(path, "r", 420)
    if not fd then
        return nil
    end
    local ok, data = pcall(uv.fs_read, fd, size - offset, offset)
    pcall(uv.fs_close, fd)
    if not ok or type(data) ~= "string" then
        return nil
    end
    local lines = vim.split(data, "\n", { plain = true })
    if offset > 0 then
        -- The first line may be a fragment of a line we cut in half.
        table.remove(lines, 1)
    end
    if #lines > 0 and lines[#lines] == "" then
        table.remove(lines, #lines)
    end
    if #lines > max_lines then
        local tail = {}
        for i = #lines - max_lines + 1, #lines do
            tail[#tail + 1] = lines[i]
        end
        lines = tail
    end
    return table.concat(lines, "\n")
end

--- @param params table|nil
--- @param _ pi.web.CmdContext
handlers["task.output"] = function(params, _)
    params = params or {}
    local id = params.taskId or params.id
    if type(id) ~= "string" or id == "" then
        return bad_request("taskId is required")
    end
    local task = require("pi.tasks").get(id)
    if not task then
        return failure(Protocol.ERR.NOT_FOUND, "unknown task: " .. id)
    end
    local tail = math.floor(tonumber(params.tail) or TASK_OUTPUT_DEFAULT_LINES)
    tail = math.max(1, math.min(TASK_OUTPUT_MAX_LINES, tail))
    local output_file = type(task.output_file) == "string" and task.output_file ~= "" and task.output_file or nil
    local output = output_file and read_output_tail(output_file, tail) or nil
    local duration
    if type(task.start_time) == "number" then
        local stop = task.end_time
        if type(stop) ~= "number" then
            stop = (vim.uv or vim.loop).now()
        end
        duration = math.max(0, stop - task.start_time)
    end
    local result = {
        taskId = id,
        output = output or "",
        outputFile = output_file,
        status = task.status,
        exitCode = task.exit_code,
        durationMs = duration,
        startTime = task.start_time,
    }
    return true, result
end

-- ---------------------------------------------------------------------------
-- workspace reads
-- ---------------------------------------------------------------------------

--- @class pi.web.SessionListRow
--- One `workspace.query{kind="sessions"}` row: a session JSONL on disk, a live
--- session, or both merged into one row. Sub-session rows carry the manifest
--- projection (`parentId` + metadata + the default :PiSessions `visible`).
--- @field sessionId string
--- @field sessionFile? string
--- @field name? string
--- @field timestamp? string
--- @field modified? integer
--- @field firstMessage? string
--- @field cwd? string
--- @field tab? integer Owning tabpage handle. A handle encodes *creation* order, not the tabline.
--- @field tabRank? integer 1-based visual position of the row's tab in `nvim_list_tabpages()`.
---   Set whenever `tab` is. `:PiSessions` ranks its root rows by the tabline, so a client
---   reproducing that order sorts on `tabRank`: `tab` diverges from it after `:tabmove` and
---   after a mid-tabline insertion (`:tabnew` from tab 1, so handles can be e.g. 1, 2, 4, 3).
--- @field live? boolean
--- @field status? string Live status when the row is live, manifest status otherwise.
--- @field model? pi.ModelRef
--- @field visible? boolean Always set on the wire; roots are always `true`.
--- @field parentId? string Manifest parent, normalized through `Manifest.resolve_lineage`.
--- @field thinking? string Child thinking level (manifest config).
--- @field task? string Child task prompt.
--- @field agentSpawned? boolean
--- @field reported? boolean
--- @field createdAt? number Epoch ms.
--- @field lastActiveAt? number Epoch ms.

--- Visual position of every tabpage, keyed by handle.
---
--- The same map `Sessions.list()` builds to order `:PiSessions`: tabpage handles
--- reflect creation order, not position, so it is the position that has to
--- travel to the client for it to reproduce the list order.
--- @return table<integer, integer>|nil nil when the tabpage list is unavailable.
local function tab_rank_map()
    local ok, tabs = pcall(vim.api.nvim_list_tabpages)
    if not ok or type(tabs) ~= "table" then
        return nil
    end
    --- @type table<integer, integer>
    local rank = {}
    for i, tab in ipairs(tabs) do
        rank[tab] = i
    end
    return rank
end

--- @param session pi.Session
--- @param instance pi.web.Instance|nil
--- @param rank table<integer, integer>|nil Tab visual position per handle (`tab_rank_map()`).
--- @return pi.web.SessionListRow
local function live_session_row(session, instance, rank)
    local tab = session.attached_tab
    local row = {
        sessionId = session.id,
        sessionFile = session.session_file,
        cwd = session.cwd,
        tab = tab,
        tabRank = tab and rank and rank[tab] or nil,
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

--- Manifest status of a child row, in the list's status vocabulary.
--- `active` here means "manifest says active but nothing runs" (the live
--- projection wins whenever the row is live).
--- @param entry pi.SubsessionManifestEntry
--- @return string|nil
local function manifest_row_status(entry)
    local status = entry.status
    if status == "dormant" then
        return "dormant"
    end
    if status == "completed" then
        return "done"
    end
    if status == "failed" then
        return "error"
    end
    if status == "interrupted" then
        return "interrupted"
    end
    if status == "active" then
        return "exited"
    end
    return nil
end

--- Project the sub-session manifest onto the merged session rows: `parentId`,
--- child metadata and the default :PiSessions `visible` policy
--- (`ChildFilter.row_visible`, never acknowledging anything). One index build
--- plus one pass; a corrupt manifest leaves the rows unfiltered.
--- @param sessions pi.web.SessionListRow[]
local function enrich_session_rows(sessions)
    for _, row in ipairs(sessions) do
        row.visible = true
    end
    local ok, Manifest = pcall(require, "pi.subsessions.manifest")
    if not ok or Manifest.decode_failed() then
        return
    end
    local ok_filter, ChildFilter = pcall(require, "pi.subsessions.sessions_list")
    if not ok_filter then
        return
    end
    local ok_entries, entries = pcall(Manifest.entries)
    if not ok_entries or type(entries) ~= "table" or #entries == 0 then
        return
    end
    --- @type table<string, pi.SubsessionManifestEntry>
    local index = {}
    for _, entry in ipairs(entries) do
        if type(entry._id) == "string" then
            index[entry._id] = entry
        end
    end
    -- Use the same liveness/status source as `:PiSessions` (`pi.ui.sessions.status_of`):
    -- a chat-bound child that is streaming (without a `_detached_busy` flag) must
    -- still count as running, or `visible`/`status` would disagree with the TUI.
    local ctx = ChildFilter.make_ctx()
    for _, row in ipairs(sessions) do
        local session_id = row.sessionId
        if type(session_id) == "string" and session_id ~= "" then
            -- A resumed child keeps its own id but the manifest is keyed by lineage.
            local ok_lineage, lineage = pcall(Manifest.resolve_lineage, session_id)
            local entry = ok_lineage and type(lineage) == "string" and index[lineage] or nil
            if entry then
                local ok_parent, parent_id = pcall(Manifest.resolve_lineage, entry.parent_id)
                if not ok_parent or type(parent_id) ~= "string" or parent_id == "" then
                    parent_id = entry.parent_id
                end
                row.parentId = parent_id
                if type(row.name) ~= "string" or row.name == "" then
                    if type(entry.name) == "string" and entry.name ~= "" then
                        row.name = entry.name
                    end
                end
                if type(entry.task_prompt) == "string" and entry.task_prompt ~= "" then
                    row.task = entry.task_prompt
                end
                local config = entry.config
                if type(config) == "table" and type(config.thinking_level) == "string" then
                    row.thinking = config.thinking_level
                end
                row.agentSpawned = entry.agent_spawned == true
                row.reported = entry.reported == true
                row.createdAt = Manifest.epoch_ms(entry.created_at)
                row.lastActiveAt = Manifest.epoch_ms(entry.last_active_at)
                if row.live ~= true then
                    row.status = manifest_row_status(entry) or row.status
                end
                row.visible = ChildFilter.row_visible(entry, {
                    is_current = false,
                    hidden = false,
                    same_epoch = true,
                    ctx = ctx,
                })
            end
        end
    end
end

--- @param params table|nil
--- @param ctx pi.web.CmdContext
--- @return any, any
local function workspace_query(params, ctx)
    params = params or {}
    local kind = params.kind
    local instance = Instance()

    if kind == "sessions" then
        --- @type pi.web.SessionListRow[]
        local sessions = {}
        local seen = {}
        -- Computed once per query, not per row: the tabline position every live
        -- row is annotated with (see `pi.web.SessionListRow.tabRank`).
        local rank = tab_rank_map()
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
            local row = live_session_row(session, instance, rank)
            if seen[session.id] then
                for _, disk in ipairs(sessions) do
                    if disk.sessionId == session.id then
                        disk.live = row.live
                        disk.status = row.status
                        disk.tab = row.tab
                        disk.tabRank = row.tabRank
                        disk.sessionFile = disk.sessionFile or row.sessionFile
                        disk.model = row.model
                    end
                end
            else
                sessions[#sessions + 1] = row
            end
        end
        enrich_session_rows(sessions)
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

    if kind == "attention" then
        local items = {}
        for _, session in ipairs(Sessions().list_all()) do
            local pending = session.attention and session.attention.pending or {}
            for _, entry in ipairs(pending) do
                local msg = entry.msg or {}
                items[#items + 1] = {
                    requestId = entry.id,
                    sessionId = session.id,
                    method = entry.kind,
                    title = msg.title,
                    message = msg.message,
                    options = msg.options,
                    timeoutSec = type(msg.timeout) == "number" and math.floor(msg.timeout / 1000) or nil,
                    expiresAt = entry.expires_at,
                    createdAt = entry.created_at,
                }
            end
        end
        return true, { attention = items }
    end

    if kind == "models" then
        refresh_models()
        return true, { providers = models_cache or {}, pending = models_cache == nil }
    end

    return bad_request('kind must be "sessions", "entries", "attention" or "models"')
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
