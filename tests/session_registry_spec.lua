-- P0 session registry: id-indexed registry, tab detach without killing RPC.

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")

Config.setup({})

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }

local responders = {}
local stopped = {}

local function install_stub()
    responders = {}
    stopped = {}

    Rpc.start = function(self)
        self._job_id = 999
        return true
    end
    Rpc.stop = function(self)
        stopped[self._tab] = true
        self._job_id = nil
        self._pending = {}
    end
    Rpc.send = function(self, cmd, callback)
        if not self._job_id then
            return false
        end
        if not cmd.id then
            cmd.id = self._tab .. ":" .. self._req_id
            self._req_id = self._req_id + 1
        end
        local responder = responders[cmd.type]
        if callback and responder then
            local res = responder(cmd)
            vim.schedule(function()
                callback(res)
            end)
        end
        return true
    end

    responders.get_commands = function()
        return { type = "response", success = true, data = { commands = {} } }
    end
    responders.get_state = function()
        return {
            type = "response",
            success = true,
            data = {
                model = { provider = "qwen", id = "qwen3-max" },
                thinkingLevel = "medium",
                sessionId = "sess-registry-1",
            },
        }
    end
end

local function restore_stub()
    Sessions._reset()
    Rpc.start = real_rpc.start
    Rpc.stop = real_rpc.stop
    Rpc.send = real_rpc.send
end

local function wait_or_fail(fn, what)
    assert(vim.wait(3000, fn, 10), what)
end

describe("session registry (P0)", function()
    before_each(function()
        install_stub()
    end)

    after_each(function()
        restore_stub()
    end)

    it("registers sessions by id and captures pinned_config from get_state", function()
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        assert.is_not_nil(session.id)

        wait_or_fail(function()
            return Sessions.get_by_id("sess-registry-1") ~= nil
        end, "session id was not captured from get_state")

        wait_or_fail(function()
            return session.pinned_config ~= nil and session.pinned_config.model ~= nil
        end, "pinned_config was not captured")
        assert.are.same({ provider = "qwen", id = "qwen3-max" }, session.pinned_config.model)
        assert.equals("medium", session.pinned_config.thinking_level)
        assert.are.same(session.pinned_config.model, session.pinned_model)
    end)

    it("detaches on tab close without stopping the backend process", function()
        vim.cmd("tabnew")
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        local rpc_tab = session.rpc._tab
        local session_id = session.id

        vim.cmd("tabclose")
        Sessions.cleanup()

        assert.is_nil(Sessions.get())
        assert.is_nil(session.attached_tab)
        assert.is_nil(session.chat)
        assert.is_true(session.rpc:is_running(), "detached session RPC must keep running")
        assert.is_nil(stopped[rpc_tab], "detach must not call rpc:stop")
        assert.equals(session, Sessions.get_by_id(session_id))
    end)

    it("bind_chat rebinds a tab chat to another session", function()
        local session_a = Sessions.get_or_create()
        assert.is_not_nil(session_a)
        local chat = session_a.chat
        assert.is_not_nil(chat)
        local tab = vim.api.nvim_get_current_tabpage()

        local rpc_b = Rpc.new(tab)
        assert.is_true(rpc_b:start())
        ---@type pi.Session
        local session_b = {
            id = "sess-b",
            rpc = rpc_b,
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            cwd = vim.fn.getcwd(),
            changed_files = {},
        }
        Sessions._register_for_test(session_b)

        Sessions.bind_chat(session_b, chat, tab)

        assert.equals(session_b, Sessions.get())
        assert.is_nil(session_a.attached_tab)
        assert.is_nil(session_a.chat)
        assert.equals("sess-b", Sessions.get().id)
    end)

    it("forwards agent_settled on detached sub-sessions", function()
        local Subsessions = require("pi.subsessions")
        local settled = nil
        local orig = Subsessions.on_child_settled
        ---@diagnostic disable-next-line: inject-field
        Subsessions.on_child_settled = function(s)
            settled = s
        end

        ---@type pi.Session
        local child = {
            id = "child-detached",
            parent_id = "parent-1",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
        }
        Sessions._register_for_test(child)

        Sessions.handle_event(child, { type = "agent_settled" })

        Subsessions.on_child_settled = orig
        assert.is_not_nil(settled)
        assert.equals("child-detached", settled.id)
    end)

    it("load_session_path dispatches switch_session without error", function()
        local sent = false
        ---@type pi.Session
        local session = {
            id = "load-target",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
                send = function(_, cmd, cb)
                    if cmd.type == "switch_session" then
                        sent = true
                        if cb then
                            cb({ success = true, data = {} })
                        end
                    elseif cmd.type == "get_messages" and cb then
                        cb({ success = true, data = { messages = {} } })
                    end
                    return true
                end,
            },
            chat = {
                clear = function() end,
                show_loading = function() end,
                clear_placeholder = function() end,
                ensure_shown_and_focus_prompt = function() end,
                on_error = function() end,
            },
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }
        Sessions._register_for_test(session)

        Sessions.load_session_path(session, "/tmp/fake-session.jsonl", function(ok)
            assert.is_true(ok)
        end)
        assert.is_true(vim.wait(3000, function()
            return sent
        end, 10), "switch_session was not sent")
    end)

    it("load_session_path preserves view_parent_id when rebind_parent_context is false", function()
        local sent = false
        ---@type pi.Session
        local session = {
            id = "child-id",
            view_parent_id = "parent-id",
            conversation_epoch = 2,
            lineage_id = "lineage",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
                send = function(_, cmd, cb)
                    if cmd.type == "switch_session" then
                        sent = true
                        if cb then
                            cb({ success = true, data = {} })
                        end
                    elseif cmd.type == "get_messages" and cb then
                        cb({ success = true, data = { messages = {} } })
                    end
                    return true
                end,
            },
            chat = {
                clear = function() end,
                show_loading = function() end,
                clear_placeholder = function() end,
                ensure_shown_and_focus_prompt = function() end,
                on_error = function() end,
            },
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }
        Sessions._register_for_test(session)

        Sessions.load_session_path(session, "/tmp/child.jsonl", function(ok)
            assert.is_true(ok)
        end, { rebind_parent_context = false })
        assert.is_true(vim.wait(3000, function()
            return sent
        end, 10), "switch_session was not sent")
        assert.are.equal("parent-id", session.view_parent_id)
        assert.are.equal(2, session.conversation_epoch)
        assert.are.equal("lineage", session.lineage_id)
    end)

    it("load_session_path clears view_parent_id by default for resume", function()
        local History = require("pi.sessions.history")
        local real_parse = History.parse
        History.parse = function()
            return { id = "resumed-parent" }
        end

        local sent = false
        ---@type pi.Session
        local session = {
            id = "old-id",
            view_parent_id = "parent-id",
            conversation_epoch = 2,
            lineage_id = "lineage",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
                send = function(_, cmd, cb)
                    if cmd.type == "switch_session" then
                        sent = true
                        if cb then
                            cb({ success = true, data = {} })
                        end
                    elseif cmd.type == "get_messages" and cb then
                        cb({ success = true, data = { messages = {} } })
                    end
                    return true
                end,
            },
            chat = {
                clear = function() end,
                show_loading = function() end,
                clear_placeholder = function() end,
                ensure_shown_and_focus_prompt = function() end,
                on_error = function() end,
            },
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }
        Sessions._register_for_test(session)

        Sessions.load_session_path(session, "/tmp/parent.jsonl", function(ok)
            assert.is_true(ok)
        end)
        assert.is_true(vim.wait(3000, function()
            return sent
        end, 10), "switch_session was not sent")
        assert.is_nil(session.view_parent_id)
        assert.are.equal(0, session.conversation_epoch)
        assert.are.equal("resumed-parent", session.lineage_id)

        History.parse = real_parse
    end)
end)
