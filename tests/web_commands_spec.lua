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

--- @param opts? { id?: string, chat?: boolean, queue?: table[], rpc_handler?: fun(cmd: table, callback: function|nil) }
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
            send = function(_, cmd, callback)
                sent[#sent + 1] = cmd
                if opts.rpc_handler then
                    opts.rpc_handler(cmd, callback)
                end
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
                    return opts.queue
                        or {
                            { expanded = "first", expanded_text = "first", text = "first", queue_type = "steer" },
                            {
                                expanded = "second",
                                expanded_text = "second",
                                text = "second",
                                queue_type = "follow_up",
                            },
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

--- Close every tab except the first one, leaving it current.
---
--- The tab-rank specs open real tabs to get a tabline whose visual order
--- differs from tabpage-handle order; this keeps one from leaking into the next
--- test (the whole file runs in a single headless instance).
local function close_extra_tabs()
    local tabs = vim.api.nvim_list_tabpages()
    for i = #tabs, 2, -1 do
        if vim.api.nvim_tabpage_is_valid(tabs[i]) then
            vim.api.nvim_set_current_tabpage(tabs[i])
            vim.cmd("tabclose!")
        end
    end
    local first = vim.api.nvim_list_tabpages()[1]
    if first and vim.api.nvim_tabpage_is_valid(first) then
        vim.api.nvim_set_current_tabpage(first)
    end
end

describe("pi.web.commands", function()
    local restores

    before_each(function()
        restores = {}
        Sessions._reset()
        Tasks._reset()
        Commands._reset_caches()
        Commands._id_wait_ms = 5000
    end)

    after_each(function()
        for _, restore in ipairs(restores) do
            restore()
        end
        Sessions._reset()
        Tasks._reset()
        Commands._reset_caches()
        Commands._id_wait_ms = 5000
        close_extra_tabs()
    end)

    --- @param module table
    --- @param name string
    --- @param replacement function
    local function stub(module, name, replacement)
        restores[#restores + 1] = spy(module, name, replacement)
    end

    --- Replace the instance singleton with a fake (the handlers call
    --- `on_registry_change` / `emit` on it).
    --- @param hooks table
    local function stub_instance(hooks)
        local key = "pi.web.instance"
        local original = package.loaded[key]
        package.loaded[key] = {
            instance = function()
                return hooks
            end,
            -- Module-level hooks (`manager.handle_event`, `pi.attention`) call
            -- `active()` first; the fake instance is not a running bridge.
            active = function()
                return false
            end,
        }
        restores[#restores + 1] = function()
            package.loaded[key] = original
        end
    end

    it("maps unknown methods to E_METHOD_NOT_ALLOWED", function()
        local result, err = Commands.dispatch("nope.method", {}, {})
        assert.is_nil(result)
        assert.equals(Protocol.ERR.METHOD_NOT_ALLOWED, err.code)
        assert.is_nil(Commands.handlers["nope.method"])
    end)

    it("registers every command the daemon can route (task.output included)", function()
        local methods = {
            "session.create",
            "session.open",
            "session.resume",
            "session.close",
            "session.rename",
            "session.fork",
            "session.compact",
            "session.setModel",
            "session.setThinking",
            "prompt.send",
            "prompt.abort",
            "queue.remove",
            "queue.setSteer",
            "attention.respond",
            "subagent.dispatch",
            "subagent.stop",
            "subagent.steer",
            "subagent.read",
            "task.stop",
            "task.output",
            "workspace.query",
        }
        -- `session.create/open/resume` would spawn a real pi process without a
        -- session file or a registered session; keep the probe hermetic.
        stub(Sessions, "create_for_web", function()
            return nil
        end)
        stub(Sessions, "load_session_path", function() end)

        for _, method in ipairs(methods) do
            assert.equals("function", type(Commands.handlers[method]), method)
            local _, err = Commands.dispatch(method, {}, {})
            assert.is_true(err == nil or err.code ~= Protocol.ERR.METHOD_NOT_ALLOWED, method)
        end
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

    it("ranks live session rows by the tabline, not by tabpage handle", function()
        local History = require("pi.sessions.history")
        stub(History, "list", function()
            return {}
        end)

        Sessions._bind_shim_for_test(fake_session({ id = "s-1" }), vim.api.nvim_get_current_tabpage())
        vim.cmd("tabnew")
        Sessions._bind_shim_for_test(fake_session({ id = "s-2" }), vim.api.nvim_get_current_tabpage())
        -- A tab created from tab 1 lands between tabs 1 and 2: `s-3` gets the
        -- largest handle but the second visual position.
        vim.cmd("tabfirst")
        vim.cmd("tabnew")
        Sessions._bind_shim_for_test(fake_session({ id = "s-3" }), vim.api.nvim_get_current_tabpage())

        local visual = vim.api.nvim_list_tabpages()
        assert.equals(3, #visual)
        -- Precondition: handle order must diverge from the tabline here, or the
        -- assertions below would pass on `tab` alone.
        local by_handle = { unpack(visual) }
        table.sort(by_handle)
        assert.are_not.same(by_handle, visual)

        local ok, result = Commands.dispatch("workspace.query", { kind = "sessions" }, {})
        assert.is_true(ok)
        assert.equals(3, #result.sessions)

        local rows = {}
        for _, row in ipairs(result.sessions) do
            rows[row.sessionId] = row
        end
        assert.equals(visual[1], rows["s-1"].tab)
        assert.equals(visual[2], rows["s-3"].tab)
        assert.equals(visual[3], rows["s-2"].tab)
        assert.equals(1, rows["s-1"].tabRank)
        assert.equals(2, rows["s-3"].tabRank)
        assert.equals(3, rows["s-2"].tabRank)

        -- Sorting the rows on `tabRank` reproduces the :PiSessions order.
        local ordered = vim.list_slice(result.sessions)
        table.sort(ordered, function(a, b)
            return a.tabRank < b.tabRank
        end)
        local ids = {}
        for _, row in ipairs(ordered) do
            ids[#ids + 1] = row.sessionId
        end
        assert.are.same({ "s-1", "s-3", "s-2" }, ids)
    end)

    it("keeps the tab rank on a row that is both on disk and live", function()
        local tab = vim.api.nvim_get_current_tabpage()
        Sessions._bind_shim_for_test(fake_session({ id = "both-1" }), tab)
        local History = require("pi.sessions.history")
        stub(History, "list", function()
            return {
                {
                    id = "both-1",
                    path = "/tmp/both-1.jsonl",
                    timestamp = "2026-01-01T00:00:00Z",
                    modified = 1,
                    first_message = "hi",
                    name = "Both",
                },
            }
        end)

        local ok, result = Commands.dispatch("workspace.query", { kind = "sessions" }, {})
        assert.is_true(ok)
        assert.equals(1, #result.sessions)
        local row = result.sessions[1]
        -- Merged into the disk row, which keeps the disk projection…
        assert.equals("both-1", row.sessionId)
        assert.equals("Both", row.name)
        -- …and gains the live tab projection, rank included.
        assert.equals(tab, row.tab)
        assert.equals(1, row.tabRank)
        assert.is_true(row.live)
    end)

    it("leaves tabRank off rows that have no tab", function()
        Sessions._register_for_test(fake_session({ id = "detached-1" }))
        local History = require("pi.sessions.history")
        stub(History, "list", function()
            return {
                {
                    id = "disk-only-1",
                    path = "/tmp/disk-only-1.jsonl",
                    timestamp = "2026-01-01T00:00:00Z",
                    modified = 1,
                    first_message = "hi",
                },
            }
        end)

        local ok, result = Commands.dispatch("workspace.query", { kind = "sessions" }, {})
        assert.is_true(ok)
        assert.equals(2, #result.sessions)
        for _, row in ipairs(result.sessions) do
            assert.is_nil(row.tab, row.sessionId)
            assert.is_nil(row.tabRank, row.sessionId)
        end
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

    it("answers an empty page for a live session whose file is not written yet", function()
        local session = fake_session({ id = "fresh-1" })
        -- `pi` creates the JSONL with the first entry: until then the path the
        -- backend reported does not exist on disk.
        session.session_file = vim.fn.tempname() .. "/not-yet.jsonl"
        Sessions._register_for_test(session)

        local ok, page = Commands.dispatch("workspace.query", { kind = "entries", limit = 10 }, ctx_for(session))
        assert.is_true(ok)
        assert.same({}, page.entries)
        assert.is_false(page.cursor.hasMore)
        assert.is_nil(page.cursor.before)
        assert.same(0, page.bytes)

        -- The same live session answers through the file when it exists.
        local path = vim.fn.tempname()
        vim.fn.writefile({
            vim.json.encode({ type = "session", id = "s-1", cwd = "/repo" }),
            vim.json.encode({ type = "message", id = "m1", message = { role = "user", content = "hi" } }),
        }, path)
        session.session_file = path
        local ok2, written = Commands.dispatch("workspace.query", { kind = "entries", limit = 10 }, ctx_for(session))
        assert.is_true(ok2)
        assert.equals(1, #written.entries)
        assert.equals("m1", written.entries[1].id)
    end)

    it("rejects unknown workspace query kinds", function()
        local ok, err = Commands.dispatch("workspace.query", { kind = "nope" }, {})
        assert.is_nil(ok)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)
    end)

    it("acks a created session with the backend id, not the tmp placeholder", function()
        local session = fake_session({ id = "tmp-7" })
        Sessions._register_for_test(session)
        stub(Sessions, "create_for_web", function()
            return session
        end)
        local registry_changes = {}
        stub_instance({
            on_registry_change = function(_, target)
                registry_changes[#registry_changes + 1] = target.id
            end,
        })
        vim.defer_fn(function()
            session.id = "real-9"
        end, 25)

        local ok, result = Commands.dispatch("session.create", {}, {})
        assert.is_true(ok)
        assert.equals("real-9", result.sessionId)
        assert.is_nil(result.pending)
        -- The instance is told about the registry entry only with the real id.
        assert.same({ "real-9" }, registry_changes)
    end)

    it("waits for the loaded session id before acking session.open", function()
        local session = fake_session({ id = "tmp-3" })
        stub(Sessions, "create_for_web", function()
            return session
        end)
        stub(Sessions, "load_session_path", function(target)
            vim.defer_fn(function()
                target.id = "opened-1"
            end, 25)
        end)

        local ok, result = Commands.dispatch("session.open", { sessionFile = "/tmp/x.jsonl" }, {})
        assert.is_true(ok)
        assert.equals("opened-1", result.sessionId)
        assert.equals("/tmp/x.jsonl", result.sessionFile)
        assert.equals("started", result.disposition)
        assert.is_nil(result.pending)
    end)

    it("acks pending = true when the backend id never arrives", function()
        Commands._id_wait_ms = 40
        local session = fake_session({ id = "tmp-1" })
        stub(Sessions, "create_for_web", function()
            return session
        end)

        local ok, result = Commands.dispatch("session.create", {}, {})
        assert.is_true(ok)
        assert.equals("tmp-1", result.sessionId)
        assert.is_true(result.pending)
    end)

    it("accepts only known thinking levels (and the thinking alias)", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        stub(Sessions, "refresh_state", function() end)

        local bad, err = Commands.dispatch("session.setThinking", { level = "turbo" }, ctx_for(session))
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)
        assert.equals(0, #session._sent)

        bad, err = Commands.dispatch("session.setThinking", {}, ctx_for(session))
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)

        for _, level in ipairs({ "off", "minimal", "low", "medium", "high", "xhigh", "max" }) do
            local ok, result = Commands.dispatch("session.setThinking", { level = level }, ctx_for(session))
            assert.is_true(ok, level)
            assert.equals(level, result.level)
        end
        assert.same({ type = "set_thinking_level", level = "max" }, session._sent[#session._sent])

        local ok, result = Commands.dispatch("session.setThinking", { thinking = "low" }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("low", result.level)
        assert.same({ type = "set_thinking_level", level = "low" }, session._sent[#session._sent])
    end)

    it("mirrors an accepted thinking level into the projection", function()
        local emits = {}
        stub_instance({
            emit = function(_, _, event)
                emits[#emits + 1] = event
            end,
        })
        local session = fake_session({
            rpc_handler = function(cmd, callback)
                if cmd.type == "set_thinking_level" and callback then
                    callback({ success = true })
                end
            end,
        })
        Sessions._register_for_test(session)
        stub(Sessions, "refresh_state", function() end)

        local ok = Commands.dispatch("session.setThinking", { level = "low" }, ctx_for(session))
        assert.is_true(ok)
        vim.wait(1000, function()
            return #emits > 0
        end)
        assert.equals(1, #emits)
        assert.equals(Protocol.DERIVED.SESSION, emits[1].type)
        assert.equals("low", emits[1].session.thinking)
    end)

    it("validates session.setModel against the models cache", function()
        local session = fake_session({
            rpc_handler = function(cmd, callback)
                if cmd.type == "get_available_models" and callback then
                    callback({
                        success = true,
                        data = {
                            models = {
                                { provider = "anthropic", id = "claude-opus-4", contextWindow = 200000 },
                                { provider = "openai", id = "gpt-5", contextWindow = 128000 },
                            },
                        },
                    })
                end
            end,
        })
        Sessions._register_for_test(session)

        -- Populate the cache through the same path the web client polls.
        Commands.handlers["workspace.query"]({ kind = "models" }, {})
        vim.wait(1000, function()
            local ok, res = Commands.handlers["workspace.query"]({ kind = "models" }, {})
            return ok and res.pending == false
        end)

        local ok, result = Commands.dispatch(
            "session.setModel",
            { model = { provider = "anthropic", id = "claude-opus-4" } },
            ctx_for(session)
        )
        assert.is_true(ok)
        assert.same({ provider = "anthropic", id = "claude-opus-4" }, result)
        assert.same(
            { type = "set_model", provider = "anthropic", modelId = "claude-opus-4" },
            session._sent[#session._sent]
        )

        -- `{provider, id}`: what the web client sends.
        ok = Commands.dispatch("session.setModel", { provider = "openai", id = "gpt-5" }, ctx_for(session))
        assert.is_true(ok)
        assert.same({ type = "set_model", provider = "openai", modelId = "gpt-5" }, session._sent[#session._sent])

        -- `{provider, modelId}`.
        ok = Commands.dispatch("session.setModel", { provider = "openai", modelId = "gpt-5" }, ctx_for(session))
        assert.is_true(ok)

        local bad, err =
            Commands.dispatch("session.setModel", { provider = "anthropic", id = "nope" }, ctx_for(session))
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)

        bad, err = Commands.dispatch("session.setModel", { provider = "ghost", id = "gpt-5" }, ctx_for(session))
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)

        bad, err = Commands.dispatch("session.setModel", {}, ctx_for(session))
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)
    end)

    it("permits session.setModel while the models cache is empty", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        local ok, result = Commands.dispatch("session.setModel", { provider = "custom", id = "m1" }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("custom", result.provider)
    end)

    it("removes a queued message by q:steer:N / q:follow:N id", function()
        local session = fake_session({
            queue = {
                { expanded_text = "s1", text = "s1", queue_type = "steer" },
                { expanded_text = "f1", text = "f1", queue_type = "follow_up" },
                { expanded_text = "s2", text = "s2", queue_type = "steer" },
            },
        })
        Sessions._register_for_test(session)

        local ok, result = Commands.dispatch("queue.remove", { id = "q:steer:2" }, ctx_for(session))
        assert.is_true(ok)
        assert.equals(3, result.removed)
        assert.equals("s2", session._deleted[#session._deleted].entry.text)

        ok, result = Commands.dispatch("queue.remove", { queueId = "q:follow:1" }, ctx_for(session))
        assert.is_true(ok)
        assert.equals(2, result.removed)

        -- 0-based ids (the daemon reducer's own numbering) still resolve.
        ok, result = Commands.dispatch("queue.remove", { queueId = "q:steer:0" }, ctx_for(session))
        assert.is_true(ok)
        assert.equals(1, result.removed)

        local bad, err = Commands.dispatch("queue.remove", { id = "q:follow:2" }, ctx_for(session))
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.NOT_FOUND, err.code)

        bad, err = Commands.dispatch("queue.remove", {}, ctx_for(session))
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.NOT_FOUND, err.code)
    end)

    it("accepts the canonical steering mode and ignores queueId", function()
        local session = fake_session()
        Sessions._register_for_test(session)

        local ok, result = Commands.dispatch("queue.setSteer", { mode = "all" }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("all", result.mode)
        assert.same({ type = "set_steering_mode", mode = "all" }, session._sent[1])

        ok, result = Commands.dispatch("queue.setSteer", { queueId = "q:steer:1", steer = true }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("all", result.mode)
        assert.same({ type = "set_steering_mode", mode = "all" }, session._sent[2])

        local bad, err = Commands.dispatch("queue.setSteer", {}, ctx_for(session))
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)
    end)

    it("tails a task's output file", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local path = dir .. "/out.log"
        local lines = {}
        for i = 1, 300 do
            lines[i] = "line " .. i
        end
        vim.fn.writefile(lines, path)
        Tasks.upsert({
            id = "t-out",
            command = "echo",
            status = "completed",
            start_time = 1000,
            end_time = 1750,
            exit_code = 0,
            output_file = path,
        })

        local ok, result = Commands.dispatch("task.output", { taskId = "t-out" }, {})
        assert.is_true(ok)
        assert.equals("t-out", result.taskId)
        assert.equals(path, result.outputFile)
        assert.equals("completed", result.status)
        assert.equals(0, result.exitCode)
        assert.equals(750, result.durationMs)
        assert.equals(1000, result.startTime)
        -- default tail is 200 lines
        assert.equals(199, select(2, result.output:gsub("\n", "\n")))
        assert.is_truthy(result.output:find("line 300", 1, true))
        assert.is_nil(result.output:find("line 100", 1, true))

        ok, result = Commands.dispatch("task.output", { id = "t-out", tail = 2 }, {})
        assert.is_true(ok)
        assert.equals("line 299\nline 300", result.output)

        -- tail is capped at 1000 lines
        local many = {}
        for i = 1, 1200 do
            many[i] = "row " .. i
        end
        local big = dir .. "/big.log"
        vim.fn.writefile(many, big)
        Tasks.upsert({ id = "t-big", command = "x", status = "running", start_time = 1, output_file = big })
        ok, result = Commands.dispatch("task.output", { taskId = "t-big", tail = 5000 }, {})
        assert.is_true(ok)
        assert.equals(999, select(2, result.output:gsub("\n", "\n")))
    end)

    it("answers task.output for unknown ids and tasks without an output file", function()
        Tasks.upsert({ id = "t-plain", command = "x", status = "running", start_time = 5 })
        local ok, result = Commands.dispatch("task.output", { taskId = "t-plain" }, {})
        assert.is_true(ok)
        assert.equals("", result.output)
        assert.is_nil(result.outputFile)

        local missing, err = Commands.dispatch("task.output", { taskId = "ghost" }, {})
        assert.is_nil(missing)
        assert.equals(Protocol.ERR.NOT_FOUND, err.code)

        local bad, bad_err = Commands.dispatch("task.output", {}, {})
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.BAD_REQUEST, bad_err.code)

        -- An output file that vanished after the task settled degrades to "".
        Tasks.upsert({
            id = "t-gone",
            command = "x",
            status = "completed",
            start_time = 1,
            output_file = "/nope/missing.log",
        })
        ok, result = Commands.dispatch("task.output", { taskId = "t-gone" }, {})
        assert.is_true(ok)
        assert.equals("", result.output)
        assert.equals("/nope/missing.log", result.outputFile)
    end)

    it("accepts thinking as an alias for thinking_level when dispatching sub-agents", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        local payloads = {}
        local Subsessions = require("pi.subsessions")
        stub(Subsessions, "handle_host", function(_, payload, on_done)
            payloads[#payloads + 1] = vim.json.decode(payload)
            if on_done then
                on_done({ ok = true, batch_id = "b-1" })
            end
        end)

        local ok, result = Commands.dispatch("subagent.dispatch", {
            items = { { task = "do it", name = "child", thinking = "low", model = { provider = "p", id = "m" } } },
            cancelSiblingsOnFail = true,
        }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("started", result.disposition)
        assert.equals("b-1", result.batchId)
        local item = payloads[1].params.items[1]
        assert.equals("low", item.thinking_level)
        assert.is_nil(item.thinking)
        assert.equals("child", item.name)
        assert.same({ provider = "p", id = "m" }, item.model)
        assert.is_true(payloads[1].params.cancel_siblings_on_fail)

        -- The canonical snake_case key wins over the alias.
        ok = Commands.dispatch("subagent.dispatch", {
            items = { { task = "x", thinking_level = "high", thinking = "low" } },
            cancel_siblings_on_fail = false,
        }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("high", payloads[2].params.items[1].thinking_level)
        assert.is_false(payloads[2].params.cancel_siblings_on_fail)

        -- Single-task shorthand (the web sub-agent form sends the fields flat).
        ok = Commands.dispatch("subagent.dispatch", { task = "flat", name = "flat-child" }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("flat", payloads[3].params.items[1].task)
        assert.equals("flat-child", payloads[3].params.items[1].name)

        local bad, err = Commands.dispatch("subagent.dispatch", { items = "nope" }, ctx_for(session))
        assert.is_nil(bad)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)
    end)

    it("wraps raw string and optionId attention answers into {value}", function()
        local session = fake_session()
        Sessions._register_for_test(session)

        session.attention.pending = { { id = "req-1", kind = "select", seq = 1 } }
        local ok, result = Commands.dispatch("attention.respond", {
            requestId = "req-1",
            response = "accept",
        }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("req-1", result.requestId)
        assert.equals("accepted", result.disposition)
        assert.equals("accept", session._sent[1].value)

        session.attention.pending = { { id = "req-2", kind = "select", seq = 2 } }
        ok = Commands.dispatch("attention.respond", { requestId = "req-2", optionId = "opt-1" }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("opt-1", session._sent[2].value)

        session.attention.pending = { { id = "req-3", kind = "confirm", seq = 3 } }
        ok, result = Commands.dispatch("attention.respond", {
            requestId = "req-3",
            response = { value = '{"result":"Accepted"}' },
        }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("accepted", result.disposition)
        assert.equals('{"result":"Accepted"}', session._sent[3].value)

        session.attention.pending = { { id = "req-4", kind = "confirm", seq = 4 } }
        ok, result = Commands.dispatch("attention.respond", {
            requestId = "req-4",
            response = { cancelled = true },
        }, ctx_for(session))
        assert.is_true(ok)
        assert.equals("cancelled", result.disposition)
        assert.is_true(session._sent[4].cancelled)
    end)

    it("maps prompt.send mode aliases onto the TUI send paths", function()
        local session = fake_session()
        Sessions._register_for_test(session)
        local seen = {}
        stub(Sessions, "prompt", function(_, _, opts)
            seen[#seen + 1] = opts.queue_type or "plain"
            return true
        end)

        for _, case in ipairs({
            { mode = "steer", expect = "steer" },
            { mode = "follow_up", expect = "follow_up" },
            { mode = "followUp", expect = "follow_up" },
            { mode = "follow-up", expect = "follow_up" },
            { mode = "queue", expect = "plain" },
            { mode = nil, expect = "plain" },
        }) do
            local ok = Commands.dispatch("prompt.send", { text = "hi", mode = case.mode }, ctx_for(session))
            assert.is_true(ok)
            assert.equals(case.expect, seen[#seen])
        end
    end)

    it("keeps config untouched", function()
        assert.equals(false, Config.options.web.enabled)
    end)
end)
