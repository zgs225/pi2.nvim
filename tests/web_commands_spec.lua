-- Specs for `pi.web.commands`: every protocol method is routed to the plugin
-- path the TUI uses (manager/chat/attention/tasks/subsessions), and the error
-- shapes match `pi2d/docs/protocol.md` §7.
--
-- The manager and the sub-session host are spied (no `pi` process); attention
-- is exercised for real because its first-wins/ghost-removal rule is the part
-- that must not regress.

local Commands = require("pi.web.commands")
local Sessions = require("pi.sessions.manager")
local Tasks = require("pi.tasks")
local Config = require("pi.config")
local Protocol = require("pi.web.protocol")

local uv = vim.uv or vim.loop

--- @param opts? { id?: string, chat?: boolean }
--- @return pi.Session
local function fake_session(opts)
    opts = opts or {}
    local running = true
    local sent = {}
    local deleted = {}
    --- @type pi.Session
    local session = {
        id = opts.id or "s-1",
        cwd = "/repo",
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        changed_files = {},
        rpc = {
            is_running = function()
                return running
            end,
            stop = function() end,
            send = function(_, cmd)
                sent[#sent + 1] = cmd
                return true
            end,
        },
        _sent = sent,
        _deleted = deleted,
        _set_running = function(value)
            running = value
        end,
    }
    if opts.chat ~= false then
        session.chat = {
            _history = {
                get_pending_queue = function()
                    return {
                        { expanded = "first", text = "first", queue_type = "steer" },
                        { expanded = "second", text = "second", queue_type = "follow_up" },
                    }
                end,
            },
            _delete_pi_queued_entry = function(_, index, entry)
                deleted[#deleted + 1] = { index = index, entry = entry }
            end,
        }
    end
    return session
end

--- @param session pi.Session
--- @return pi.web.CmdContext
local function ctx_for(session)
    return {
        id = "req-1",
        session_id = session.id,
        method = "test",
        bridge = {},
        params = {},
    }
end

--- @param module table
--- @param name string
--- @param replacement function
--- @return function restore
local function spy(module, name, replacement)
    local original = module[name]
    module[name] = replacement
    return function()
        module[name] = original
    end
end

describe("pi.web.commands", function()
    local restores

    before_each(function()
        restores = {}
        Sessions._reset()
        Tasks._reset()
    end)

    after_each(function()
        for _, restore in ipairs(restores) do
            restore()
        end
        Sessions._reset()
        Tasks._reset()
    end)

    --- @param module table
    --- @param name string
    --- @param replacement function
    local function stub(module, name, replacement)
        restores[#restores + 1] = spy(module, name, replacement)
    end

    it("maps unknown methods to E_METHOD_NOT_ALLOWED", function()
        local result, err = Commands.dispatch("nope.method", {}, {})
        assert.is_nil(result)
        assert.equals(Protocol.ERR.METHOD_NOT_ALLOWED, err.code)
        assert.is_nil(Commands.handlers["nope.method"])
    end)

    it("requires a known session for session-scoped methods", function()
        local result, err = Commands.dispatch("prompt.send", { text = "hi" }, { session_id = "ghost" })
        assert.is_nil(result)
        assert.equals(Protocol.ERR.SESSION_NOT_FOUND, err.code)

        result, err = Commands.dispatch("prompt.send", { text = "hi" }, {})
        assert.is_nil(result)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)
    end)

    it("routes prompt.send through manager.prompt (the Chat send path)", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        local called
        stub(Sessions, "prompt", function(target, text, opts)
            called = { target = target, text = text, opts = opts }
            return true
        end)

        local ok, result = Commands.dispatch("prompt.send", {
            text = "hello @file",
            mode = "steer",
            images = { { type = "image", data = "x", mimeType = "image/png" } },
        }, ctx_for(session))

        assert.is_true(ok)
        assert.equals("started", result.disposition)
        assert.equals(session, called.target)
        assert.equals("hello @file", called.text)
        assert.equals("steer", called.opts.queue_type)
        assert.equals(1, #called.opts.images)
    end)

    it("routes prompt.abort to the core abort + attention clear", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        session.attention.pending = { { id = "req-1", kind = "confirm" } }

        local ok = Commands.dispatch("prompt.abort", {}, ctx_for(session))
        assert.is_true(ok)
        assert.equals("abort", session._sent[1].type)
        assert.equals(0, #session.attention.pending)
        assert.equals("extension_ui_response", session._sent[2].type)
        assert.is_true(session._sent[2].cancelled)
    end)

    it("routes session.create/open/resume through create_for_web", function()
        local session = fake_session({ id = "web-1" })
        Sessions._register_for_test(session)
        local created = 0
        stub(Sessions, "create_for_web", function()
            created = created + 1
            return session
        end)
        local loaded
        stub(Sessions, "load_session_path", function(target, path)
            loaded = { target = target, path = path }
        end)

        local ok, result = Commands.dispatch("session.create", { workspaceId = "ws" }, {})
        assert.is_true(ok)
        assert.equals("web-1", result.sessionId)
        assert.equals(1, created)

        ok, result = Commands.dispatch("session.open", { sessionFile = "/tmp/s.jsonl" }, {})
        assert.is_true(ok)
        assert.equals("/tmp/s.jsonl", result.sessionFile)
        assert.equals("/tmp/s.jsonl", loaded.path)

        ok, result = Commands.dispatch("session.resume", { sessionFile = "/tmp/r.jsonl" }, {})
        assert.is_true(ok)
        assert.equals("/tmp/r.jsonl", result.sessionFile)
        assert.equals(3, created)

        ok, result = Commands.dispatch("session.open", {}, {})
        assert.is_nil(ok)
        assert.equals(Protocol.ERR.BAD_REQUEST, result.code)
    end)

    it("closes sessions through manager.close_session", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        local closed
        stub(Sessions, "close_session", function(target)
            closed = target
        end)
        local ok = Commands.dispatch("session.close", { mode = "hibernate" }, ctx_for(session))
        assert.is_true(ok)
        assert.equals(session, closed)
    end)

    it("renames via the set_session_name RPC", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        local ok = Commands.dispatch("session.rename", { name = "New name" }, ctx_for(session))
        assert.is_true(ok)
        assert.same({ type = "set_session_name", name = "New name" }, session._sent[1])
    end)

    it("sets model and thinking through the RPC commands the UI uses", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        stub(Sessions, "refresh_state", function() end)

        local ok = Commands.dispatch(
            "session.setModel",
            { model = { provider = "anthropic", id = "claude-opus-4" } },
            ctx_for(session)
        )
        assert.is_true(ok)
        assert.same({ type = "set_model", provider = "anthropic", modelId = "claude-opus-4" }, session._sent[1])

        ok = Commands.dispatch("session.setThinking", { level = "high" }, ctx_for(session))
        assert.is_true(ok)
        assert.same({ type = "set_thinking_level", level = "high" }, session._sent[2])
    end)

    it("answers attention first-wins and removes the queued entry (no ghost)", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        session.attention.pending = {
            { id = "req-1", kind = "confirm", seq = 1 },
            { id = "req-2", kind = "select", seq = 2 },
        }

        local ok = Commands.dispatch("attention.respond", {
            requestId = "req-1",
            by = "web",
            response = { confirmed = true },
        }, ctx_for(session))
        assert.is_true(ok)
        assert.equals(1, #session.attention.pending)
        assert.equals("req-2", session.attention.pending[1].id)

        local response = session._sent[1]
        assert.equals("extension_ui_response", response.type)
        assert.equals("req-1", response.id)
        assert.is_true(response.confirmed)

        local second, err = Commands.dispatch("attention.respond", {
            requestId = "req-1",
            response = { confirmed = false },
        }, ctx_for(session))
        assert.is_nil(second)
        assert.equals(Protocol.ERR.ATTENTION_RESOLVED, err.code)
        assert.equals(1, #session._sent)

        local unknown, unknown_err = Commands.dispatch("attention.respond", { requestId = "nope" }, ctx_for(session))
        assert.is_nil(unknown)
        assert.equals(Protocol.ERR.ATTENTION_RESOLVED, unknown_err.code)
    end)

    it("deletes queued messages through the Chat queue implementation", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        local ok, result = Commands.dispatch("queue.remove", { index = 2 }, ctx_for(session))
        assert.is_true(ok)
        assert.equals(2, result.removed)
        assert.equals(2, session._deleted[1].index)
        assert.equals("second", session._deleted[1].entry.expanded)
    end)

    it("reports E_UNSUPPORTED for queue edits without a chat", function()
        local session = fake_session({ chat = false })
        Sessions._register_for_test(session)
        local ok, err = Commands.dispatch("queue.remove", { index = 1 }, ctx_for(session))
        assert.is_nil(ok)
        assert.equals(Protocol.ERR.UNSUPPORTED, err.code)
    end)

    it("sets the steering delivery mode", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        local ok, result = Commands.dispatch("queue.setSteer", { steer = false }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("one-at-a-time", result.mode)
        assert.same({ type = "set_steering_mode", mode = "one-at-a-time" }, session._sent[1])

        local bad, err = Commands.dispatch("queue.setSteer", { mode = "sometimes" }, ctx_for(session))
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)
    end)

    it("dispatches and stops sub-agents through the host tunnel", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        local payloads = {}
        local Subsessions = require("pi.subsessions")
        stub(Subsessions, "handle_host", function(_, payload, on_done)
            payloads[#payloads + 1] = vim.json.decode(payload)
            if on_done then
                on_done({ ok = true })
            end
        end)

        local ok, result = Commands.dispatch("subagent.dispatch", {
            items = { { task = "do it", name = "child" } },
            cancel_siblings_on_fail = true,
            wait = true,
            timeout_ms = 1000,
        }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("started", result.disposition)
        assert.equals("dispatch_subagents", payloads[1].action)
        assert.equals("do it", payloads[1].params.items[1].task)
        assert.is_true(payloads[1].params.cancel_siblings_on_fail)

        ok = Commands.dispatch("subagent.stop", { targets = { "child-1" } }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("stop_subagents", payloads[2].action)
        assert.same({ "child-1" }, payloads[2].params.targets)

        local bad, err = Commands.dispatch("subagent.dispatch", { items = "nope" }, ctx_for(session))
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)
    end)

    it("steers a sub-agent through manager.prompt", function()
        local parent = fake_session({ id = "parent" })
        local child = fake_session({ id = "child-1" })
        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        local called
        stub(Sessions, "prompt", function(target, text, opts)
            called = { target = target, text = text, opts = opts }
            return true
        end)

        local ok, result = Commands.dispatch("subagent.steer", {
            target = "child-1",
            message = "focus on tests",
        }, ctx_for(parent))
        assert.is_true(ok)
        assert.equals("child-1", result.sessionId)
        assert.equals(child, called.target)
        assert.equals("steer", called.opts.queue_type)

        local unknown, err = Commands.dispatch("subagent.steer", {
            target = "ghost",
            message = "x",
        }, ctx_for(parent))
        assert.is_nil(unknown)
        assert.equals(Protocol.ERR.NOT_FOUND, err.code)
    end)

    it("reads sub-agent transcripts from the session file", function()
        local parent = fake_session({ id = "parent" })
        Sessions._register_for_test(parent)
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local path = dir .. "/child.jsonl"
        vim.fn.writefile({
            vim.json.encode({ type = "session", id = "child-1", cwd = "/repo" }),
            vim.json.encode({ type = "message", id = "m1", message = { role = "user", content = "go" } }),
        }, path)

        local ok, result = Commands.dispatch("subagent.read", { sessionFile = path, tail = 10 }, ctx_for(parent))
        assert.is_true(ok)
        assert.equals(path, result.sessionFile)
        -- The projection keeps the session header line as entry [1].
        assert.equals(2, #result.lines)
        assert.is_truthy(result.lines[2]:find("user", 1, true))
    end)

    it("stops background tasks through the task registry", function()
        Tasks.upsert({
            id = "t1",
            command = "sleep 1",
            status = "running",
            start_time = uv.now(),
            session_id = "s-1",
        })
        local ok, result = Commands.dispatch("task.stop", { taskId = "t1" }, {})
        assert.is_true(ok)
        assert.equals("t1", result.taskId)
        assert.equals("stopped", Tasks.get("t1").status)

        local unknown, err = Commands.dispatch("task.stop", { taskId = "ghost" }, {})
        assert.is_nil(unknown)
        assert.equals(Protocol.ERR.NOT_FOUND, err.code)
    end)

    it("answers workspace.query sessions by merging disk and live sessions", function()
        local live = fake_session({ id = "live-1" })
        Sessions._register_for_test(live)
        local History = require("pi.sessions.history")
        stub(History, "list", function()
            return {
                {
                    id = "disk-1",
                    path = "/tmp/disk-1.jsonl",
                    timestamp = "2026-01-01T00:00:00Z",
                    modified = 1,
                    first_message = "hi",
                    name = "Disk",
                },
            }
        end)

        local ok, result = Commands.dispatch("workspace.query", { kind = "sessions" }, {})
        assert.is_true(ok)
        assert.equals(2, #result.sessions)
        assert.equals("disk-1", result.sessions[1].sessionId)
        assert.equals("live-1", result.sessions[2].sessionId)
        assert.is_true(result.sessions[2].live)
    end)

    it("answers workspace.query entries with a paginated history page", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local path = dir .. "/session.jsonl"
        vim.fn.writefile({
            vim.json.encode({ type = "session", id = "s-1", cwd = "/repo" }),
            vim.json.encode({ type = "message", id = "m1", message = { role = "user", content = "hi" } }),
            vim.json.encode({ type = "message", id = "m2", message = { role = "assistant", content = "yo" } }),
        }, path)

        local ok, page = Commands.dispatch("workspace.query", {
            kind = "entries",
            sessionFile = path,
            limit = 10,
        }, {})
        assert.is_true(ok)
        assert.equals(2, #page.entries)
        assert.equals("m1", page.entries[1].id)
        assert.equals("m2", page.entries[2].id)

        local before, before_page = Commands.dispatch("workspace.query", {
            kind = "entries",
            sessionFile = path,
            before = "m2",
            limit = 10,
        })
        assert.is_true(before)
        assert.equals(1, #before_page.entries)
        assert.equals("m1", before_page.entries[1].id)

        local bad, err = Commands.dispatch("workspace.query", { kind = "entries" }, {})
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)
    end)

    it("rejects unknown workspace query kinds", function()
        local ok, err = Commands.dispatch("workspace.query", { kind = "nope" }, {})
        assert.is_nil(ok)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)
    end)

    it("keeps config untouched", function()
        assert.equals(false, Config.options.web.enabled)
    end)
end)
