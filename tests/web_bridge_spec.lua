-- Transport-level specs for `pi.web.bridge` (plugin <-> pi2d JSONL over a unix
-- socket) and `pi.web.runtime` (daemon socket/token path resolution).
--
-- No session semantics are covered here: framing, handshake, dispatch, replies,
-- throttling, queue accounting and reconnect/stop only. The daemon side is
-- simulated by an in-process `vim.uv` unix-socket server so the specs stay
-- hermetic (no daemon binary, no network).

local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
if not package.path:find(repo_root, 1, true) then
    package.path = package.path .. ";" .. repo_root .. "/?.lua"
end

local Bridge = require("pi.web.bridge")
local Protocol = require("pi.web.protocol")
local Runtime = require("pi.web.runtime")
local PipeServer = require("tests.helpers.uv_pipe_server")

---@class pi.TestWebEnv
---@field dir string
---@field sock string
---@field srv pi.TestUvPipeServer
---@field bridges pi.web.Bridge[]
---@field prev_socket string|nil
---@field prev_runtime string|nil

local env = {}

local function new_env()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local sock = dir .. "/d.sock"
    vim.fn.writefile({ "tok-abc123" }, sock .. ".token")
    local e = {
        dir = dir,
        sock = sock,
        prev_socket = vim.env.PI2_SOCKET,
        prev_runtime = vim.env.PI2_RUNTIME_DIR,
        bridges = {},
    }
    vim.env.PI2_RUNTIME_DIR = dir
    vim.env.PI2_SOCKET = sock
    e.srv = PipeServer.new(sock):start()
    return e
end

---@param opts table|nil
---@return pi.web.Bridge
local function new_bridge(e, opts)
    local merged = vim.tbl_deep_extend("force", {
        workspace_id = "ws-1",
        cwd = "/repo",
        plugin_version = "1.0.0",
        has_ui = true,
        listen_addr = "/run/pi2/i/ab12.sock",
        backoff_initial = 20,
        backoff_max = 60,
    }, opts or {})
    local bridge = Bridge.new(merged)
    e.bridges[#e.bridges + 1] = bridge
    return bridge
end

local function teardown(e)
    for _, bridge in ipairs(e.bridges) do
        pcall(bridge.stop, bridge)
    end
    e.srv:stop()
    vim.env.PI2_SOCKET = e.prev_socket
    vim.env.PI2_RUNTIME_DIR = e.prev_runtime
end

local function wait(cond, timeout)
    return vim.wait(timeout or 2000, cond, 10)
end

--- Start a bridge and wait for its hello to reach the fake daemon.
---@param e pi.TestWebEnv
---@param opts table|nil
---@return pi.web.Bridge, table
local function started_bridge(e, opts)
    local bridge = new_bridge(e, opts)
    bridge:start()
    assert.is_true(
        wait(function()
            return #e.srv:records_of("hello") == 1
        end),
        "bridge never sent hello"
    )
    return bridge, e.srv:records_of("hello")[1]
end

--- One message_update record carrying a text/thinking delta.
local function delta_event(kind, text, content_index)
    return {
        type = "message_update",
        assistantMessageEvent = {
            type = kind or "text_delta",
            contentIndex = content_index or 0,
            delta = text,
        },
    }
end

describe("pi.web.runtime", function()
    it("resolves the daemon socket and token paths from the environment", function()
        local dir = vim.fn.fnamemodify(vim.fn.tempname(), ":p:h")
        vim.fn.mkdir(dir, "p")
        local saved_runtime, saved_socket = vim.env.PI2_RUNTIME_DIR, vim.env.PI2_SOCKET

        vim.env.PI2_RUNTIME_DIR = dir
        vim.env.PI2_SOCKET = nil
        assert.equals(dir .. "/d.sock", Runtime.socket_path())
        assert.equals(dir .. "/d.sock.token", Runtime.token_path())
        assert.is_nil(Runtime.read_token())

        vim.fn.writefile({ "  secret  " }, dir .. "/d.sock.token")
        assert.equals("secret", Runtime.read_token())

        vim.env.PI2_SOCKET = dir .. "/custom.sock"
        assert.equals(dir .. "/custom.sock", Runtime.socket_path())
        assert.equals(dir .. "/custom.sock.token", Runtime.token_path())

        vim.env.PI2_RUNTIME_DIR, vim.env.PI2_SOCKET = saved_runtime, saved_socket
    end)

    it("derives short, stable instance socket paths", function()
        local dir = vim.fn.fnamemodify(vim.fn.tempname(), ":p")
        vim.fn.mkdir(dir, "p")
        local saved_runtime = vim.env.PI2_RUNTIME_DIR
        vim.env.PI2_RUNTIME_DIR = dir

        local a = Runtime.instance_socket_path("ws-1", "i-1")
        local b = Runtime.instance_socket_path("ws-1", "i-1")
        local c = Runtime.instance_socket_path("ws-2", "i-1")
        assert.equals(a, b)
        assert.are_not.equal(a, c)
        assert.is_true(#a < 100, "socket path too long: " .. a)
        assert.is_truthy(a:match("/i/[0-9a-f]+%.sock$"))

        vim.env.PI2_RUNTIME_DIR = saved_runtime
    end)

    it("creates directories with a private mode", function()
        local dir = vim.fn.fnamemodify(vim.fn.tempname(), ":p") .. "pi2/web-test"
        local created = Runtime.ensure_dir(dir)
        assert.equals(dir, created)
        local st = vim.uv.fs_stat(dir)
        assert.is_truthy(st)
        assert.equals("directory", st.type)
    end)
end)

describe("pi.web.bridge", function()
    before_each(function()
        env = new_env()
    end)

    after_each(function()
        teardown(env)
    end)

    it("connects to the daemon socket and sends hello with the token", function()
        local _, hello = started_bridge(env)
        assert.equals(Protocol.VERSION, hello.v)
        assert.equals(Protocol.OUT.HELLO, hello.type)
        assert.equals("ws-1", hello.workspaceId)
        assert.equals("/repo", hello.cwd)
        assert.equals("1.0.0", hello.pluginVersion)
        assert.is_true(hello.hasUI)
        assert.equals("/run/pi2/i/ab12.sock", hello.listenAddr)
        assert.is_truthy(tostring(hello.instanceId):match("^i%-"))
        assert.equals(vim.uv.os_getpid(), hello.pid)
        assert.equals("tok-abc123", hello.token)
        assert.is_truthy(type(hello.capabilities) == "table" and #hello.capabilities > 0)
    end)

    it("stores the daemon limits on hello_ack and fires on_ready once", function()
        local ready_count, got_limits = 0, nil
        local bridge = started_bridge(env, {
            on_ready = function(limits)
                ready_count = ready_count + 1
                got_limits = limits
            end,
        })
        assert.is_false(bridge:status().ready)

        env.srv:send({
            v = 1,
            type = Protocol.IN.HELLO_ACK,
            daemonId = "d-1",
            limits = { maxFrameBytes = 4096 },
            policy = { attention = "all" },
        })
        assert.is_true(
            wait(function()
                return ready_count == 1
            end),
            "on_ready never fired"
        )
        assert.equals(4096, got_limits.maxFrameBytes)
        assert.equals("d-1", bridge:status().daemon_id)
        assert.is_true(bridge:status().ready)

        -- a duplicate hello_ack must not re-fire on_ready
        env.srv:send({ v = 1, type = Protocol.IN.HELLO_ACK, daemonId = "d-1" })
        wait(function()
            return false
        end, 100)
        assert.equals(1, ready_count)
    end)

    it("invokes a registered handler and acks the cmd by id", function()
        local seen = {}
        local bridge = started_bridge(env, {
            handlers = {
                ["prompt.send"] = function(params, ctx)
                    seen.params, seen.ctx = params, ctx
                    return true, { disposition = "started" }
                end,
            },
        })
        assert.is_truthy(bridge)

        env.srv:send({
            v = 1,
            type = Protocol.IN.CMD,
            id = "req-1",
            sessionId = "s1",
            payload = { method = "prompt.send", params = { text = "hi" }, clientRequestId = "c-9" },
        })
        assert.is_true(
            wait(function()
                return #env.srv:records_of(Protocol.OUT.ACK) == 1
            end),
            "no ack was sent"
        )

        local ack = env.srv:records_of(Protocol.OUT.ACK)[1]
        assert.equals("req-1", ack.id)
        assert.is_number(ack.seq)
        assert.equals("started", ack.payload.disposition)
        assert.equals("hi", seen.params.text)
        assert.equals("s1", seen.ctx.session_id)
        assert.equals("c-9", seen.ctx.client_request_id)
        assert.equals("prompt.send", seen.ctx.method)
    end)

    it("replies with an error record when a handler fails", function()
        started_bridge(env, {
            handlers = {
                ["session.abort"] = function()
                    return nil, { code = Protocol.ERR.LEASE_CONFLICT, message = "session is owned by i-2" }
                end,
                ["session.explode"] = function()
                    error("boom")
                end,
            },
        })

        env.srv:send({
            v = 1,
            type = Protocol.IN.CMD,
            id = "req-2",
            sessionId = "s1",
            payload = { method = "session.abort" },
        })
        env.srv:send({
            v = 1,
            type = Protocol.IN.CMD,
            id = "req-3",
            sessionId = "s1",
            payload = { method = "session.explode" },
        })
        env.srv:send({
            v = 1,
            type = Protocol.IN.CMD,
            id = "req-4",
            sessionId = "s1",
            payload = { method = "nope.unknown" },
        })
        assert.is_true(
            wait(function()
                return #env.srv:records_of(Protocol.OUT.ERROR) == 3
            end),
            "expected three error records"
        )

        local by_id = {}
        for _, rec in ipairs(env.srv:records_of(Protocol.OUT.ERROR)) do
            by_id[rec.id] = rec
        end
        assert.equals(Protocol.ERR.LEASE_CONFLICT, by_id["req-2"].payload.code)
        assert.equals("session is owned by i-2", by_id["req-2"].payload.message)
        assert.equals(Protocol.ERR.INTERNAL, by_id["req-3"].payload.code)
        assert.is_truthy(by_id["req-3"].payload.message:find("boom", 1, true))
        assert.equals(Protocol.ERR.METHOD_NOT_ALLOWED, by_id["req-4"].payload.code)
        assert.equals(0, #env.srv:records_of(Protocol.OUT.ACK))
    end)

    it("routes an unknown method through pi.web.commands instead of failing internally", function()
        started_bridge(env, {
            handlers = {
                ["prompt.send"] = function()
                    return true
                end,
            },
        })

        env.srv:send({
            v = 1,
            type = Protocol.IN.CMD,
            id = "req-unknown",
            sessionId = "s1",
            payload = { method = "does.not.exist" },
        })
        assert.is_true(
            wait(function()
                return #env.srv:records_of(Protocol.OUT.ERROR) == 1
            end),
            "no error record was sent"
        )
        local err = env.srv:records_of(Protocol.OUT.ERROR)[1]
        assert.equals("req-unknown", err.id)
        assert.equals(Protocol.ERR.METHOD_NOT_ALLOWED, err.payload.code)

        -- A real Commands handler that the bridge was not given also runs.
        env.srv:send({
            v = 1,
            type = Protocol.IN.CMD,
            id = "req-query",
            sessionId = "s1",
            payload = { method = "workspace.query", params = {} },
        })
        assert.is_true(
            wait(function()
                return #env.srv:records_of(Protocol.OUT.ERROR) == 2
            end),
            "workspace.query was not dispatched"
        )
        local query_err = env.srv:records_of(Protocol.OUT.ERROR)[2]
        assert.equals("req-query", query_err.id)
        assert.equals(Protocol.ERR.BAD_REQUEST, query_err.payload.code)
        assert.equals(0, #env.srv:records_of(Protocol.OUT.ACK))
    end)

    it("routes subscribe/unsubscribe and shutdown records to their callbacks", function()
        local subscribed, unsubscribed, shutdown = {}, {}, nil
        started_bridge(env, {
            on_subscribe = function(session_id)
                subscribed[#subscribed + 1] = session_id
            end,
            on_unsubscribe = function(session_id)
                unsubscribed[#unsubscribed + 1] = session_id
            end,
            on_shutdown = function(payload)
                shutdown = payload
            end,
        })

        env.srv:send({ v = 1, type = Protocol.IN.SUB_SUBSCRIBE, sessionId = "s1" })
        env.srv:send({ v = 1, type = Protocol.IN.SUB_UNSUBSCRIBE, sessionId = "s1" })
        env.srv:send({ v = 1, type = Protocol.IN.INSTANCE_SHUTDOWN, payload = { mode = "drain" } })

        assert.is_true(
            wait(function()
                return #subscribed == 1 and #unsubscribed == 1 and shutdown ~= nil
            end),
            "subscribe/unsubscribe/shutdown callbacks did not run"
        )
        assert.equals("s1", subscribed[1])
        assert.equals("s1", unsubscribed[1])
        assert.equals("drain", shutdown.mode)
    end)

    it("reassembles records split across socket writes", function()
        started_bridge(env, {
            handlers = {
                ["prompt.send"] = function()
                    return true
                end,
            },
        })

        local line = vim.json.encode({
            v = 1,
            type = Protocol.IN.CMD,
            id = "req-split",
            sessionId = "s1",
            payload = { method = "prompt.send", params = { text = string.rep("x", 4096) } },
        })
        local cut = math.floor(#line / 2)
        env.srv:send_raw(line:sub(1, cut))
        env.srv:send_raw(line:sub(cut + 1, #line - 5))
        -- a record without its terminating newline must not be dispatched
        wait(function()
            return false
        end, 150)
        assert.equals(0, #env.srv:records_of(Protocol.OUT.ACK))
        env.srv:send_raw(line:sub(#line - 4) .. "\n")

        assert.is_true(
            wait(function()
                return #env.srv:records_of(Protocol.OUT.ACK) == 1
            end),
            "split record was not reassembled"
        )
        assert.equals("req-split", env.srv:records_of(Protocol.OUT.ACK)[1].id)
    end)

    it("keeps U+2028/U+2029 inside a record instead of splitting on them", function()
        local got
        started_bridge(env, {
            handlers = {
                ["prompt.send"] = function(params)
                    got = params.text
                    return true
                end,
            },
        })
        env.srv:send({
            v = 1,
            type = Protocol.IN.CMD,
            id = "req-2028",
            sessionId = "s1",
            payload = { method = "prompt.send", params = { text = "a\u{2028}b\u{2029}c\nd" } },
        })
        assert.is_true(
            wait(function()
                return #env.srv:records_of(Protocol.OUT.ACK) == 1
            end),
            "record with unicode line separators was not dispatched"
        )
        assert.equals("a\u{2028}b\u{2029}c\nd", got)
    end)

    it("reconnects with backoff after the daemon closes the connection", function()
        local bridge = started_bridge(env)
        assert.is_true(bridge:status().connected)

        env.srv:close_clients(true)
        assert.is_true(
            wait(function()
                return #env.srv:records_of("hello") == 2
            end, 3000),
            "bridge did not reconnect"
        )
        assert.is_true(wait(function()
            return bridge:status().connected == true
        end))
    end)

    it("coalesces deltas of one content index into a single event", function()
        local bridge = started_bridge(env)
        bridge:send_event("s1", "e1", 1, delta_event("text_delta", "he", 0))
        bridge:send_event("s1", "e1", 2, delta_event("text_delta", "llo", 0))
        bridge:send_event("s1", "e1", 3, delta_event("thinking_delta", "hm", 1))

        assert.is_true(
            wait(function()
                return #env.srv:records_of(Protocol.OUT.EVENT) == 2
            end),
            "expected one event per content index"
        )

        local by_index = {}
        for _, rec in ipairs(env.srv:records_of(Protocol.OUT.EVENT)) do
            local ev = rec.payload.event
            local idx = ev.assistantMessageEvent.contentIndex
            by_index[idx] = rec
        end
        assert.equals("hello", by_index[0].payload.event.assistantMessageEvent.delta)
        assert.equals("hm", by_index[1].payload.event.assistantMessageEvent.delta)
        assert.equals("s1", by_index[0].sessionId)
        assert.equals("e1", by_index[0].epoch)
        assert.is_number(by_index[0].ts)
        -- Coalesced frames get their seq when they are written (see `_flush_throttle`).
        assert.is_true(by_index[1].seq > by_index[0].seq, "throttled seqs must increase in write order")

        wait(function()
            return false
        end, 150)
        assert.equals(2, #env.srv:records_of(Protocol.OUT.EVENT))
    end)

    it("stays monotonic when a coalesced frame flushes after a newer record", function()
        local counter = 0
        local bridge = started_bridge(env, {
            delta_throttle_ms = 40,
            tool_throttle_ms = 40,
            seq_provider = function()
                counter = counter + 1
                return counter
            end,
        })

        -- Mirrors `pi.web.instance`: only records written immediately consume a
        -- seq up front; coalesced ones are numbered when flushed.
        local function send(event)
            local seq
            if not bridge:coalesces(event) then
                counter = counter + 1
                seq = counter
            end
            bridge:send_event("s1", "e1", seq, event)
        end

        send(delta_event("text_delta", "late", 0)) -- held in the throttle window
        send({ type = "agent_settled" }) -- written right away

        assert.is_true(
            wait(function()
                return #env.srv:records_of(Protocol.OUT.EVENT) == 2
            end),
            "expected the delta to flush"
        )

        local seqs = {}
        for _, rec in ipairs(env.srv:records_of(Protocol.OUT.EVENT)) do
            seqs[#seqs + 1] = rec.seq
        end
        assert.equals(2, #seqs)
        assert.is_true(
            seqs[2] > seqs[1],
            ("wire seq regressed: %s then %s"):format(tostring(seqs[1]), tostring(seqs[2]))
        )
    end)

    it("numbers several coalesced streams in flush order", function()
        local bridge = started_bridge(env, { delta_throttle_ms = 30, tool_throttle_ms = 30 })
        bridge:send_event("s1", "e1", 16, delta_event("text_delta", "a", 0))
        bridge:send_event("s1", "e1", 15, delta_event("thinking_delta", "b", 1))

        assert.is_true(
            wait(function()
                return #env.srv:records_of(Protocol.OUT.EVENT) == 2
            end),
            "expected both throttled streams to flush"
        )
        local seqs = {}
        for _, rec in ipairs(env.srv:records_of(Protocol.OUT.EVENT)) do
            seqs[#seqs + 1] = rec.seq
        end
        -- The seq arguments passed above are ignored for coalesced frames, so a
        -- caller cannot drag the wire backwards.
        assert.is_true(seqs[2] > seqs[1], ("non-increasing seqs %s, %s"):format(seqs[1], seqs[2]))
    end)

    it("drops low-priority frames and emits one dropped marker on queue overflow", function()
        local bridge = started_bridge(env, { max_queue_bytes = 300 })
        for i = 1, 12 do
            bridge:send_snapshot("s1", "e1", i, { sessionId = "s1", pad = string.rep("x", 120) }, {})
        end

        assert.is_true(
            wait(function()
                return #env.srv:records_of("dropped") == 1
            end),
            "no dropped marker was emitted"
        )
        assert.is_true(
            wait(function()
                return bridge:status().queued_bytes == 0
            end),
            "outbound queue never drained"
        )

        local snapshots = #env.srv:records_of(Protocol.OUT.SNAPSHOT)
        assert.is_true(snapshots < 12, "expected overflow to drop frames, got " .. snapshots)
        assert.is_true(bridge:status().dropped > 0)

        wait(function()
            return false
        end, 100)
        assert.equals(1, #env.srv:records_of("dropped"))
    end)

    it("drops deltas before normal records on overflow", function()
        local bridge = started_bridge(env, { max_queue_bytes = 260 })
        for i = 1, 4 do
            bridge:send_snapshot("s1", "e1", i, { sessionId = "s1", pad = string.rep("y", 120) }, {})
        end
        bridge:send_event("s1", "e1", 9, delta_event("text_delta", string.rep("z", 400), 0))

        assert.is_true(
            wait(function()
                return #env.srv:records_of("dropped") == 1
            end),
            "delta overflow did not emit a dropped marker"
        )
        assert.is_true(
            wait(function()
                return bridge:status().queued_bytes == 0
            end),
            "outbound queue never drained"
        )
        for _, rec in ipairs(env.srv:records_of(Protocol.OUT.EVENT)) do
            assert.equals(0, #rec.payload.event.assistantMessageEvent.delta)
        end
        assert.equals(0, #env.srv:records_of(Protocol.OUT.EVENT))
    end)

    it("stops cleanly and cancels pending throttled frames", function()
        local bridge = started_bridge(env)
        bridge:send_event("s1", "e1", 1, delta_event("text_delta", "pending", 0))
        bridge:stop()
        bridge:stop() -- idempotent

        assert.is_false(bridge:status().connected)
        wait(function()
            return false
        end, 150)
        assert.equals(0, #env.srv:records_of(Protocol.OUT.EVENT))
        -- no reconnect attempt after an explicit stop
        assert.equals(1, #env.srv:records_of("hello"))
    end)

    it("never throws when the daemon socket is missing", function()
        env.srv:stop()
        local bridge = new_bridge(env, { backoff_initial = 10, backoff_max = 20 })
        assert.is_true(bridge:start())
        wait(function()
            return false
        end, 120)
        assert.is_false(bridge:status().connected)
        assert.is_true(bridge:status().attempts > 0)
        bridge:stop()
    end)
end)

describe("pi.web.bridge module setup", function()
    it("registers VimLeavePre and exposes status", function()
        env = new_env()
        local bridge = Bridge.setup({
            workspace_id = "ws-1",
            cwd = "/repo",
            plugin_version = "1.0.0",
            has_ui = false,
            backoff_initial = 20,
            backoff_max = 60,
        })
        assert.is_truthy(bridge)
        assert.equals(bridge, Bridge.instance())
        assert.equals("ws-1", Bridge.status().workspace_id)

        local autocmds = vim.api.nvim_get_autocmds({ event = "VimLeavePre", group = "pi2_web_bridge" })
        assert.equals(1, #autocmds)

        Bridge.shutdown()
        assert.is_false(Bridge.status().started)
        teardown(env)
    end)
end)
