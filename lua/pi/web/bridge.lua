---@class pi.web.BridgeOptions
---@field workspace_id string Workspace this nvim instance belongs to (`ws-…`)
---@field cwd? string Session cwd reported in `hello` (default: nvim's cwd)
---@field plugin_version? string Reported in `hello`
---@field has_ui? boolean Reported in `hello` as `hasUI`
---@field listen_addr? string Path of this instance's socket, reported in `hello`
---@field handlers? table<string, fun(params: table|nil, ctx: pi.web.CmdContext): any, any> Command handlers by method
---@field log? fun(level: string, msg: string) Diagnostics sink
---@field on_ready? fun(limits: table, record: table) `hello_ack` received
---@field on_subscribe? fun(session_id: string|nil, record: table) Daemon subscribed to a session
---@field on_unsubscribe? fun(session_id: string|nil, record: table) Daemon unsubscribed
---@field on_shutdown? fun(payload: table|nil, record: table) Daemon asked the instance to shut down
---@field on_query? fun(payload: table|nil, ctx: pi.web.CmdContext) `workspace.query`
---@field socket_path? string Override the daemon socket (default: `pi.web.runtime.socket_path()`)
---@field token? string Override the handshake token (default: read the token file)
---@field seq_provider? fun(session_id: string|nil): integer Provider for `ack` seq numbers (default: per-bridge counter)
---@field backoff_initial? integer First reconnect delay in ms (default 200)
---@field backoff_max? integer Reconnect delay cap in ms (default 5000)
---@field max_queue_bytes? integer Outbound write queue cap in bytes (default 4 MB)
---@field max_frame_bytes? integer Inbound buffer cap in bytes (default 8 MB)
---@field delta_throttle_ms? integer Delta coalescing window in ms (default 50)
---@field tool_throttle_ms? integer Tool-update coalescing window in ms (default 100)

---@class pi.web.CmdContext
---@field bridge pi.web.Bridge
---@field id string|nil Request id being answered
---@field session_id string|nil Session the command targets
---@field method string|nil Protocol method
---@field client_request_id string|nil Idempotency key from the daemon
---@field params table|nil Command parameters

---@class pi.web.BridgeThrottle
---@field key string
---@field kind "delta"|"tool"
---@field session_id string|nil
---@field epoch string|nil
---@field event table
---@field timer uv.uv_timer_t

---@class pi.web.Bridge
---@field opts pi.web.BridgeOptions
---@field _handlers table<string, function>
---@field _workspace_id string
---@field _cwd string
---@field _plugin_version string|nil
---@field _has_ui boolean
---@field _listen_addr string|nil
---@field _instance_id string
---@field _backoff_initial integer
---@field _backoff_max integer
---@field _max_queue_bytes integer
---@field _max_frame_bytes integer
---@field _delta_ms integer
---@field _tool_ms integer
---@field _started boolean
---@field _stopped boolean
---@field _connected boolean
---@field _ready boolean
---@field _pipe uv.uv_pipe_t|nil
---@field _reconnect_timer uv.uv_timer_t|nil
---@field _attempts integer
---@field _connects integer
---@field _daemon_id string|nil
---@field _limits table
---@field _policy table|nil
---@field _in_parts string[]
---@field _in_len integer
---@field _inbox string[]
---@field _drain_scheduled boolean
---@field _out { frame: string, priority: string, size: integer }[]
---@field _queued_bytes integer
---@field _writing boolean
---@field _dropped_total integer
---@field _episode_drops integer
---@field _episode_bytes integer
---@field _marker_queued boolean
---@field _throttles table<string, pi.web.BridgeThrottle>
---@field _seq table<string, integer>
local Bridge = {}
Bridge.__index = Bridge

local uv = vim.uv or vim.loop
local Protocol = require("pi.web.protocol")
local Runtime = require("pi.web.runtime")

--- @type pi.web.Bridge|nil the singleton created by `Bridge.setup()`
local instance = nil
local autocmd_installed = false

local DEFAULTS = {
    backoff_initial = 200,
    backoff_max = 5000,
    max_queue_bytes = 4 * 1024 * 1024,
    max_frame_bytes = 8 * 1024 * 1024,
    delta_throttle_ms = 50,
    tool_throttle_ms = 100,
}

--- Protocol stages that need throttling (protocol §2 "Plugin obligations").
local DELTA_KINDS = { text_delta = true, thinking_delta = true }

--- @return integer milliseconds since the epoch
local function now_ms()
    local ok, sec, usec = pcall(uv.gettimeofday)
    if ok and type(sec) == "number" then
        return sec * 1000 + math.floor((usec or 0) / 1000)
    end
    return os.time() * 1000
end

--- @return integer monotonic milliseconds
local function mono_ms()
    return math.floor(uv.hrtime() / 1e6)
end

--- Build a new bridge. Does not connect: call `:start()`.
--- @param opts pi.web.BridgeOptions
--- @return pi.web.Bridge
function Bridge.new(opts)
    opts = opts or {}
    assert(type(opts.workspace_id) == "string" and opts.workspace_id ~= "", "workspace_id is required")

    local self = setmetatable({}, Bridge)
    self.opts = opts
    self._handlers = opts.handlers or {}
    self._workspace_id = opts.workspace_id
    self._cwd = opts.cwd or vim.fn.getcwd()
    self._plugin_version = opts.plugin_version
    self._has_ui = opts.has_ui and true or false
    self._listen_addr = opts.listen_addr
    -- i-… instance id: unique per nvim process, stable for its lifetime.
    self._instance_id = "i-" .. Runtime.hex16(string.format("%d:%d:%d", uv.os_getpid(), uv.hrtime(), math.random(1e9)))

    self._backoff_initial = opts.backoff_initial or DEFAULTS.backoff_initial
    self._backoff_max = opts.backoff_max or DEFAULTS.backoff_max
    self._max_queue_bytes = opts.max_queue_bytes or DEFAULTS.max_queue_bytes
    self._max_frame_bytes = opts.max_frame_bytes or DEFAULTS.max_frame_bytes
    self._delta_ms = opts.delta_throttle_ms or DEFAULTS.delta_throttle_ms
    self._tool_ms = opts.tool_throttle_ms or DEFAULTS.tool_throttle_ms

    -- connection
    self._started = false
    self._stopped = false
    self._connected = false
    self._ready = false
    self._pipe = nil
    self._reconnect_timer = nil
    self._attempts = 0
    self._connects = 0
    self._daemon_id = nil
    self._limits = { maxFrameBytes = DEFAULTS.max_frame_bytes }
    self._policy = nil

    -- inbound JSONL framing
    self._in_parts = {}
    self._in_len = 0
    self._inbox = {}
    self._drain_scheduled = false

    -- outbound queue
    self._out = {}
    self._queued_bytes = 0
    self._writing = false
    self._dropped_total = 0
    self._episode_drops = 0
    self._episode_bytes = 0
    self._marker_queued = false

    -- throttling
    self._throttles = {}
    self._seq = {}

    return self
end

-- ---------------------------------------------------------------------------
-- logging
-- ---------------------------------------------------------------------------

--- @param level string
--- @param msg string
function Bridge:_log(level, msg)
    local sink = self.opts.log
    if type(sink) == "function" then
        pcall(sink, level, msg)
    end
end

--- Call one of the user callbacks, never letting it break the transport.
--- @param name string callback name, e.g. "on_ready"
--- @param ... any
function Bridge:_emit(name, ...)
    local fn = self.opts[name]
    if type(fn) ~= "function" then
        return
    end
    local ok, err = pcall(fn, ...)
    if not ok then
        self:_log("error", name .. " callback failed: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- connection lifecycle
-- ---------------------------------------------------------------------------

--- @return string
function Bridge:_socket_path()
    return self.opts.socket_path or Runtime.socket_path()
end

--- Start connecting (idempotent). Never throws.
--- @return boolean
function Bridge:start()
    if self._stopped then
        return false
    end
    if self._started then
        return true
    end
    self._started = true
    self:_connect()
    return true
end

function Bridge:_connect()
    if self._stopped then
        return
    end
    local path = self:_socket_path()
    local ok_new, pipe = pcall(uv.new_pipe, false)
    if not ok_new or not pipe then
        self:_log("error", "uv.new_pipe failed: " .. tostring(pipe))
        self:_schedule_reconnect("no pipe handle")
        return
    end
    self._pipe = pipe
    -- connect() is asynchronous: the handshake starts from the completion
    -- callback, which uv invokes on the event loop (hop to the main loop there).
    local ok, err = pcall(pipe.connect, pipe, path, function(conn_err)
        vim.schedule(function()
            self:_on_connect(pipe, conn_err)
        end)
    end)
    if not ok then
        self:_close_pipe(pipe)
        self:_schedule_reconnect("connect setup failed: " .. tostring(err))
    end
end

--- @param pipe uv.uv_pipe_t
--- @param err string|nil
function Bridge:_on_connect(pipe, err)
    if self._stopped or pipe ~= self._pipe then
        if not pipe:is_closing() then
            pipe:close()
        end
        return
    end
    if err then
        self:_close_pipe(pipe)
        self:_schedule_reconnect("connect failed: " .. tostring(err))
        return
    end

    self._connected = true
    self._connects = self._connects + 1
    self._attempts = 0
    self:_log("info", "connected to daemon at " .. self:_socket_path())

    pipe:read_start(function(read_err, data)
        if read_err then
            vim.schedule(function()
                self:_on_disconnect(pipe, "read error: " .. tostring(read_err))
            end)
            return
        end
        if data == nil then
            vim.schedule(function()
                self:_on_disconnect(pipe, "eof")
            end)
            return
        end
        -- Pure-Lua framing in the uv callback; dispatch happens on the main loop.
        self:_ingest(data)
    end)

    self:_send_hello()
    self:_pump()
end

--- @param pipe uv.uv_pipe_t
function Bridge:_close_pipe(pipe)
    if not pipe then
        return
    end
    if self._pipe == pipe then
        self._pipe = nil
    end
    if not pipe:is_closing() then
        pipe:read_stop()
        pipe:close()
    end
end

--- @param pipe uv.uv_pipe_t
--- @param reason string
function Bridge:_on_disconnect(pipe, reason)
    if self._stopped then
        return
    end
    if self._pipe ~= pipe then
        if not pipe:is_closing() then
            pipe:close()
        end
        return
    end
    self:_close_pipe(pipe)
    local was_connected = self._connected
    self._connected = false
    self._ready = false
    self._writing = false
    -- Frames written for the previous connection are stale: seq/epoch pairing
    -- does not survive a reconnect, the daemon asks for a resync instead.
    self._out = {}
    self._queued_bytes = 0
    self._marker_queued = false
    self._episode_drops = 0
    self._episode_bytes = 0
    if was_connected then
        self:_log("warn", "daemon connection lost: " .. reason)
    end
    self:_schedule_reconnect(reason)
end

--- @param reason string
function Bridge:_schedule_reconnect(reason)
    if self._stopped or self._reconnect_timer then
        return
    end
    self._attempts = self._attempts + 1
    local delay = math.min(self._backoff_initial * 2 ^ (self._attempts - 1), self._backoff_max)
    self:_log("info", string.format("reconnect in %dms (%s)", delay, reason))

    local timer = uv.new_timer()
    if not timer then
        return
    end
    self._reconnect_timer = timer
    timer:start(delay, 0, function()
        vim.schedule(function()
            if self._reconnect_timer ~= timer then
                return
            end
            self._reconnect_timer = nil
            if not timer:is_closing() then
                timer:stop()
                timer:close()
            end
            if self._stopped then
                return
            end
            self:_connect()
        end)
    end)
end

--- Send the handshake record (protocol §2).
function Bridge:_send_hello()
    local token = self.opts.token
    if token == nil then
        token = Runtime.read_token()
    end
    local hello = Protocol.envelope(Protocol.OUT.HELLO, {
        instanceId = self._instance_id,
        workspaceId = self._workspace_id,
        cwd = self._cwd,
        pid = uv.os_getpid(),
        hasUI = self._has_ui,
        listenAddr = self._listen_addr,
        pluginVersion = self._plugin_version,
        capabilities = { "snapshot", "attention" },
        token = token,
    })
    self:_enqueue(hello, "normal")
end

--- Stop the bridge: close the socket, cancel timers, drop the queues.
--- Idempotent.
function Bridge:stop()
    if self._stopped then
        return
    end
    self._stopped = true
    self._connected = false
    self._ready = false
    self._writing = false

    local timer = self._reconnect_timer
    self._reconnect_timer = nil
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
    for key, pending in pairs(self._throttles) do
        self._throttles[key] = nil
        local throttle_timer = pending.timer
        if throttle_timer and not throttle_timer:is_closing() then
            throttle_timer:stop()
            throttle_timer:close()
        end
    end
    self._out = {}
    self._queued_bytes = 0
    self._inbox = {}
    self._in_parts = {}
    self._in_len = 0
    if self._pipe then
        self:_close_pipe(self._pipe)
    end
    self:_log("info", "bridge stopped")
end

-- ---------------------------------------------------------------------------
-- inbound framing + dispatch
-- ---------------------------------------------------------------------------

--- Accumulate a socket chunk and extract complete `\n`-terminated records.
--- Runs in the uv read callback: pure Lua only.
--- @param data string
function Bridge:_ingest(data)
    if not data:find("\n", 1, true) then
        -- No terminator in this chunk: keep it as a raw piece (no O(n²) growth).
        self._in_len = self._in_len + #data
        if self._in_len > self._max_frame_bytes then
            self._in_parts = {}
            self._in_len = 0
            vim.schedule(function()
                self:_log(
                    "error",
                    "inbound frame exceeded " .. tostring(self._max_frame_bytes) .. " bytes; buffer reset"
                )
            end)
            return
        end
        self._in_parts[#self._in_parts + 1] = data
        return
    end

    self._in_parts[#self._in_parts + 1] = data
    local buf = table.concat(self._in_parts)
    local lines, start = self._inbox, 1
    while true do
        local nl = buf:find("\n", start, true)
        if not nl then
            break
        end
        local line = buf:sub(start, nl - 1)
        if line:sub(-1) == "\r" then
            line = line:sub(1, -2)
        end
        if line ~= "" then
            lines[#lines + 1] = line
        end
        start = nl + 1
    end
    local rest = buf:sub(start)
    self._in_parts = rest ~= "" and { rest } or {}
    self._in_len = #rest

    if #lines > 0 then
        self:_schedule_drain()
    end
end

function Bridge:_schedule_drain()
    if self._drain_scheduled then
        return
    end
    self._drain_scheduled = true
    vim.schedule(function()
        self._drain_scheduled = false
        self:_drain()
    end)
end

function Bridge:_drain()
    if self._stopped then
        self._inbox = {}
        return
    end
    while #self._inbox > 0 do
        local line = table.remove(self._inbox, 1)
        local record, err = Protocol.decode(line)
        if record then
            self:_dispatch(record)
        else
            self:_log("error", "bad inbound record (" .. tostring(err) .. ")")
        end
    end
end

--- @param record table
function Bridge:_dispatch(record)
    local kind = record.type
    if kind == Protocol.IN.HELLO_ACK then
        self._daemon_id = record.daemonId
        if type(record.limits) == "table" then
            self._limits = record.limits
            -- Never buffer more than the daemon is willing to read.
            if type(record.limits.maxFrameBytes) == "number" then
                self._max_frame_bytes = record.limits.maxFrameBytes
            end
        end
        self._policy = record.policy
        local was_ready = self._ready
        self._ready = true
        if not was_ready then
            self:_emit("on_ready", self._limits, record)
        end
    elseif kind == Protocol.IN.CMD then
        self:_handle_cmd(record)
    elseif kind == Protocol.IN.SUB_SUBSCRIBE then
        self:_emit("on_subscribe", record.sessionId, record)
    elseif kind == Protocol.IN.SUB_UNSUBSCRIBE then
        self:_emit("on_unsubscribe", record.sessionId, record)
    elseif kind == Protocol.IN.INSTANCE_SHUTDOWN then
        self:_emit("on_shutdown", record.payload, record)
    elseif kind == Protocol.IN.WORKSPACE_QUERY then
        self:_emit("on_query", record.payload, self:_context(record, record.payload and record.payload.method))
    elseif kind == Protocol.IN.PING then
        -- liveness probe: no reply needed (protocol §3.3)
    else
        self:_log("warn", "unknown inbound record type: " .. tostring(kind))
    end
end

--- @param record table
--- @param method string|nil
--- @return pi.web.CmdContext
function Bridge:_context(record, method)
    return {
        bridge = self,
        id = record.id,
        session_id = record.sessionId,
        method = method,
        client_request_id = record.payload and record.payload.clientRequestId,
        params = record.payload and record.payload.params,
    }
end

--- Run a `cmd` handler and answer with `ack` or `error`.
--- @param record table
function Bridge:_handle_cmd(record)
    local payload = type(record.payload) == "table" and record.payload or {}
    local method = payload.method
    local ctx = self:_context(record, method)
    local handler = method and self._handlers[method]

    if type(handler) ~= "function" then
        -- Not in the handler table: let `pi.web.commands` answer it. That path
        -- maps an unknown method to `E_METHOD_NOT_ALLOWED` (a nil handler here
        -- must never surface as `E_INTERNAL`).
        local ok_cmd, Commands = pcall(require, "pi.web.commands")
        if not ok_cmd or type(Commands) ~= "table" or type(Commands.dispatch) ~= "function" then
            self:_send_error(record.id, Protocol.ERR.METHOD_NOT_ALLOWED, "unknown method: " .. tostring(method))
            return
        end
        local ok, first, second = pcall(Commands.dispatch, method, payload.params, ctx)
        if not ok then
            self:_log("error", "dispatch for " .. tostring(method) .. " threw: " .. tostring(first))
            self:_send_error(record.id, Protocol.ERR.INTERNAL, tostring(first))
            return
        end
        self:_reply(record.id, ctx, first, second)
        return
    end

    local ok, first, second = pcall(handler, payload.params, ctx)
    if not ok then
        self:_log("error", "handler for " .. tostring(method) .. " threw: " .. tostring(first))
        self:_send_error(record.id, Protocol.ERR.INTERNAL, tostring(first))
        return
    end
    self:_reply(record.id, ctx, first, second)
end

--- Turn a handler's return value into an `ack` or an `error` record.
--- Contract: `true, result` (or a bare result) acks; `nil, err` errors.
--- @param id string|nil request id being answered
--- @param ctx pi.web.CmdContext
--- @param first any
--- @param second any
function Bridge:_reply(id, ctx, first, second)
    local result
    if first == nil or first == false then
        local err = second
        if type(err) == "table" then
            self:_send_error(id, err.code or Protocol.ERR.INTERNAL, err.message or "command failed", err.retryable)
        elseif err ~= nil then
            self:_send_error(id, Protocol.ERR.INTERNAL, tostring(err))
        else
            self:_send_error(id, Protocol.ERR.INTERNAL, "handler returned no result")
        end
        return
    end
    if type(first) == "table" then
        result = first
    elseif second ~= nil then
        result = second
    else
        result = first ~= true and first or nil
    end
    self:_send_ack(id, ctx.session_id, result)
end

--- Per-session `ack` seq. The daemon only requires monotonicity inside one
--- session; a session module that owns the real sequence can inject
--- `opts.seq_provider` to keep `ack`, `event` and `snapshot` on one counter.
--- @param session_id string|nil
--- @return integer
function Bridge:_next_seq(session_id)
    if type(self.opts.seq_provider) == "function" then
        local ok, seq = pcall(self.opts.seq_provider, session_id)
        if ok and type(seq) == "number" then
            return seq
        end
    end
    local key = session_id or ""
    local seq = (self._seq[key] or 0) + 1
    self._seq[key] = seq
    return seq
end

--- @param id string|nil
--- @param session_id string|nil
--- @param result table|string|number|nil
function Bridge:_send_ack(id, session_id, result)
    local payload = { disposition = "started" }
    if type(result) == "table" then
        for k, v in pairs(result) do
            payload[k] = v
        end
    elseif result ~= nil then
        payload.detail = result
    end
    self:_enqueue(
        Protocol.envelope(Protocol.OUT.ACK, { id = id, seq = self:_next_seq(session_id), payload = payload }),
        "normal"
    )
end

--- @param id string|nil
--- @param code string|nil
--- @param message string|nil
--- @param retryable boolean|nil
function Bridge:_send_error(id, code, message, retryable)
    self:_enqueue(
        Protocol.envelope(Protocol.OUT.ERROR, {
            id = id,
            payload = { code = code or Protocol.ERR.INTERNAL, message = message or "", retryable = retryable or false },
        }),
        "normal"
    )
end

-- ---------------------------------------------------------------------------
-- outbound queue
-- ---------------------------------------------------------------------------

--- Remove queued low-priority frames until `need` more bytes fit.
--- @param need integer
function Bridge:_purge_low_priority(need)
    local i = 1
    while i <= #self._out and self._queued_bytes + need > self._max_queue_bytes do
        local item = self._out[i]
        if item.priority == "delta" or item.priority == "tool" then
            table.remove(self._out, i)
            self._queued_bytes = self._queued_bytes - item.size
            self._dropped_total = self._dropped_total + 1
            self._episode_drops = self._episode_drops + 1
            self._episode_bytes = self._episode_bytes + item.size
        else
            i = i + 1
        end
    end
end

--- Emit exactly one `dropped` marker per overflow episode, once the queue has
--- drained far enough that the marker itself is out of the way.
function Bridge:_maybe_emit_marker()
    if self._marker_queued or self._episode_drops == 0 then
        return
    end
    if self._queued_bytes > 0 or self._writing or not self._connected then
        return
    end
    self._marker_queued = true
    local marker = Protocol.envelope("dropped", {
        ts = now_ms(),
        mono = mono_ms(),
        payload = { count = self._episode_drops, bytes = self._episode_bytes, reason = "queue_overflow" },
    })
    self._episode_drops = 0
    self._episode_bytes = 0
    self:_append(marker, "normal", true)
end

--- @param size integer
function Bridge:_count_drop(size)
    self._dropped_total = self._dropped_total + 1
    self._episode_drops = self._episode_drops + 1
    self._episode_bytes = self._episode_bytes + size
    self:_maybe_emit_marker()
end

--- Encode + enqueue one record. Applies the 4 MB queue cap.
--- @param record table
--- @param priority "delta"|"tool"|"normal"
--- @return boolean queued
function Bridge:_enqueue(record, priority)
    if self._stopped then
        return false
    end
    return self:_append(record, priority, false)
end

--- @param record table
--- @param priority "delta"|"tool"|"normal"
--- @param bypass_cap boolean
--- @return boolean queued
function Bridge:_append(record, priority, bypass_cap)
    local ok, frame = pcall(vim.json.encode, record)
    if not ok or type(frame) ~= "string" then
        self:_log("error", "failed to encode " .. tostring(record.type) .. ": " .. tostring(frame))
        return false
    end
    frame = frame .. "\n"
    local size = #frame

    if not self._connected then
        -- Nothing to write to; the daemon resyncs with a snapshot on reconnect.
        return false
    end

    if not bypass_cap then
        if size > self._max_queue_bytes then
            self:_log("warn", "frame too large to queue (" .. tostring(size) .. " bytes)")
            self:_count_drop(size)
            return false
        end
        if self._queued_bytes + size > self._max_queue_bytes then
            if priority == "normal" then
                self:_purge_low_priority(size)
            end
            if self._queued_bytes + size > self._max_queue_bytes then
                self:_count_drop(size)
                return false
            end
        end
    end

    self._out[#self._out + 1] = { frame = frame, priority = priority, size = size }
    self._queued_bytes = self._queued_bytes + size
    self:_pump()
    return true
end

--- Write queued frames one at a time; the next write is scheduled from the
--- previous write's completion callback.
function Bridge:_pump()
    if self._stopped or self._writing or not self._connected then
        return
    end
    if #self._out == 0 then
        self._marker_queued = false
        self:_maybe_emit_marker()
        return
    end
    local pipe = self._pipe
    if not pipe then
        return
    end
    local item = table.remove(self._out, 1)
    self._queued_bytes = self._queued_bytes - item.size
    self._writing = true
    local ok = pcall(pipe.write, pipe, item.frame, function(write_err)
        self._writing = false
        if write_err then
            vim.schedule(function()
                self:_on_disconnect(pipe, "write error: " .. tostring(write_err))
            end)
            return
        end
        vim.schedule(function()
            self:_pump()
        end)
    end)
    if not ok then
        self._writing = false
        self:_on_disconnect(pipe, "write failed")
    end
end

-- ---------------------------------------------------------------------------
-- outbound API
-- ---------------------------------------------------------------------------

--- Send one raw record (escape hatch for handlers that answer daemon queries).
--- @param record table
--- @return boolean queued
function Bridge:send_record(record)
    return self:_enqueue(record, "normal")
end

--- @param session_id string|nil
--- @param epoch string|nil
--- @param seq integer|nil
--- @param event table
--- @return boolean queued
function Bridge:_write_event(session_id, epoch, seq, event, priority)
    return self:_enqueue(
        Protocol.envelope(Protocol.OUT.EVENT, {
            sessionId = session_id,
            epoch = epoch,
            seq = seq,
            ts = now_ms(),
            mono = mono_ms(),
            payload = { event = event },
        }),
        priority
    )
end

--- Classify a session event for throttling.
--- @param event table
--- @return "delta"|"tool"|nil kind, string|nil key_suffix
function Bridge:_throttle_kind(event)
    if type(event) ~= "table" then
        return nil
    end
    if event.type == "message_update" then
        local ame = event.assistantMessageEvent
        if type(ame) == "table" and DELTA_KINDS[ame.type] then
            return "delta", string.format("%s:%s", tostring(ame.contentIndex or 0), ame.type)
        end
    elseif event.type == "tool_execution_update" then
        return "tool", tostring(event.toolCallId or "")
    end
    return nil
end

--- Merge a delta into the pending frame (concatenate text) or, for tool
--- updates, keep the newest snapshot of the output.
--- @param pending pi.web.BridgeThrottle
--- @param event table
function Bridge:_merge_throttle(pending, event)
    if pending.kind == "tool" then
        pending.event = vim.deepcopy(event)
        return
    end
    local dst = pending.event.assistantMessageEvent
    local src = event.assistantMessageEvent or {}
    dst.delta = (dst.delta or "") .. (src.delta or "")
end

--- Whether `send_event` coalesces this event (i.e. writes it later than it was
--- handed to the bridge). Callers that own the seq counter must not consume a
--- seq for such an event: the bridge assigns it when the frame is written.
--- @param event table
--- @return boolean
function Bridge:coalesces(event)
    return self:_throttle_kind(event) ~= nil
end

--- @param session_id string|nil
--- @param epoch string|nil
--- @param event table
--- @param kind "delta"|"tool"
--- @param suffix string|nil
--- @return boolean coalesced
function Bridge:_throttle_event(session_id, epoch, event, kind, suffix)
    local key = tostring(session_id) .. "|" .. kind .. "|" .. (suffix or "")
    local pending = self._throttles[key]
    if pending then
        -- The merged frame represents every event up to this one; its seq is
        -- assigned when it is flushed (see `_flush_throttle`).
        pending.epoch = epoch
        self:_merge_throttle(pending, event)
        return true
    end

    local timer = uv.new_timer()
    if not timer then
        return false
    end
    pending = {
        key = key,
        kind = kind,
        session_id = session_id,
        epoch = epoch,
        event = vim.deepcopy(event),
        timer = timer,
    }
    self._throttles[key] = pending
    local window = kind == "tool" and self._tool_ms or self._delta_ms
    timer:start(window, 0, function()
        vim.schedule(function()
            self:_flush_throttle(key)
        end)
    end)
    return true
end

--- @param key string
function Bridge:_flush_throttle(key)
    local pending = self._throttles[key]
    if not pending then
        return
    end
    self._throttles[key] = nil
    local timer = pending.timer
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
    if self._stopped then
        return
    end
    -- Seq is assigned here, at write time: throttled frames from different
    -- keys flush in timer order, not in arrival order, so a seq reserved when
    -- the event was queued could reach the wire *after* a newer one.
    self:_write_event(
        pending.session_id,
        pending.epoch,
        self:_next_seq(pending.session_id),
        pending.event,
        pending.kind
    )
end

--- Send one session event. Streaming deltas are coalesced (protocol §2); for
--- those the `seq` argument is ignored and the bridge assigns one at flush.
--- @param session_id string|nil
--- @param epoch string|nil
--- @param seq integer|nil
--- @param event table
--- @return boolean queued
function Bridge:send_event(session_id, epoch, seq, event)
    local kind, suffix = self:_throttle_kind(event)
    if kind then
        return self:_throttle_event(session_id, epoch, event, kind, suffix)
    end
    return self:_write_event(session_id, epoch, seq, event, "normal")
end

--- Send a full render snapshot (replaces the client's cache).
--- @param session_id string|nil
--- @param epoch string|nil
--- @param seq integer|nil
--- @param state table|nil
--- @param entries table|nil
--- @return boolean queued
function Bridge:send_snapshot(session_id, epoch, seq, state, entries)
    return self:_enqueue(
        Protocol.envelope(Protocol.OUT.SNAPSHOT, {
            sessionId = session_id,
            epoch = epoch,
            seq = seq,
            ts = now_ms(),
            mono = mono_ms(),
            payload = { state = state, entries = entries or {} },
        }),
        "normal"
    )
end

--- Report instance-wide state (ready + session table).
--- @param payload table
--- @return boolean queued
function Bridge:send_instance_state(payload)
    return self:_enqueue(
        Protocol.envelope(Protocol.OUT.INSTANCE_STATE, {
            ts = now_ms(),
            mono = mono_ms(),
            payload = payload or {},
        }),
        "normal"
    )
end

--- Status snapshot. Callable both as an instance method (`bridge:status()`) and
--- as a module function for the singleton (`Bridge.status()`).
--- @param self pi.web.Bridge|nil
--- @return table status
function Bridge.status(self)
    if type(self) ~= "table" or self == Bridge then
        if not instance then
            return { started = false, connected = false, ready = false }
        end
        return instance:status()
    end
    local throttled = 0
    for _ in pairs(self._throttles) do
        throttled = throttled + 1
    end
    return {
        started = self._started and not self._stopped,
        connected = self._connected,
        ready = self._ready,
        workspace_id = self._workspace_id,
        instance_id = self._instance_id,
        socket = self:_socket_path(),
        daemon_id = self._daemon_id,
        limits = self._limits,
        policy = self._policy,
        queued_bytes = self._queued_bytes,
        queued_frames = #self._out,
        throttled = throttled,
        dropped = self._dropped_total,
        connects = self._connects,
        attempts = self._attempts,
    }
end

-- ---------------------------------------------------------------------------
-- module level: one bridge per nvim
--
-- The module returns the class itself: `Bridge.new()`, `Bridge.setup()`,
-- `Bridge.instance()`, `Bridge.status()` and `Bridge.shutdown()` are statics,
-- everything else is an instance method (`bridge:start()`, `bridge:stop()`, …).
-- ---------------------------------------------------------------------------

--- Build + start the singleton bridge and make sure it is stopped on exit.
--- @param opts pi.web.BridgeOptions
--- @return pi.web.Bridge
function Bridge.setup(opts)
    if instance then
        instance:stop()
    end
    instance = Bridge.new(opts)
    instance:start()
    if not autocmd_installed then
        local group = vim.api.nvim_create_augroup("pi2_web_bridge", { clear = true })
        vim.api.nvim_create_autocmd("VimLeavePre", {
            group = group,
            desc = "Stop the pi2 web bridge",
            callback = function()
                Bridge.shutdown()
            end,
        })
        autocmd_installed = true
    end
    return instance
end

--- The singleton bridge, if `setup()` ran.
--- @return pi.web.Bridge|nil
function Bridge.instance()
    return instance
end

--- Stop the singleton bridge (used by `VimLeavePre` and tests).
function Bridge.shutdown()
    if instance then
        instance:stop()
    end
end

return Bridge
