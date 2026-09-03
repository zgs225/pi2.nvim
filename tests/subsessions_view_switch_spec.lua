-- View-switch must not switch_session when the target process already has
-- that session file (pi aborts the agent on every switch_session).

local Config = require("pi.config")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")
local Read = require("pi.subsessions.read")

Config.setup({})

---@return table
local function stub_chat()
    return {
        _streaming = false,
        bind_agent = function() end,
        set_subsession_breadcrumb = function() end,
        clear_subsession_breadcrumb = function() end,
        clear = function(self)
            self._streaming = false
            self._compacting = false
        end,
        show_loading = function() end,
        clear_placeholder = function() end,
        show_startup_block = function() end,
        set_replaying = function() end,
        ensure_shown_and_focus_prompt = function() end,
        on_error = function() end,
        on_agent_start = function(self)
            self._streaming = true
            self.agent_starts = (self.agent_starts or 0) + 1
        end,
        on_agent_end = function(self)
            self._streaming = false
        end,
        on_text_delta = function(self, delta)
            self.deltas = (self.deltas or "") .. (delta or "")
        end,
        on_thinking_start = function() end,
        on_thinking_delta = function() end,
        on_thinking_end = function() end,
        is_streaming = function(self)
            return self._streaming == true
        end,
        is_compacting = function(self)
            return self._compacting == true
        end,
        set_compacting = function(self, value)
            self._compacting = value
        end,
        active_verb = function()
            return nil
        end,
        set_status = function(self, status)
            self.status = status
        end,
        add_user_message = function() end,
        add_vision_block = function() end,
        add_usage = function() end,
        on_tool_start = function() end,
        on_tool_end = function() end,
        on_bash_replay = function() end,
        append_compaction_summary = function() end,
        update_state = function() end,
        set_model_ambiguity_for = function() end,
        render_statusline = function() end,
        refresh_prompt_attention = function() end,
    }
end

---@return table
local function make_rpc()
    local sent = {}
    local pending = {}
    return {
        sent = sent,
        pending = pending,
        is_running = function()
            return true
        end,
        stop = function() end,
        send = function(_, cmd, cb)
            sent[#sent + 1] = cmd.type
            if cmd.type == "get_messages" then
                pending.get_messages = cb
            elseif cmd.type == "switch_session" then
                pending.switch_session = cb
            elseif cmd.type == "abort" then
                pending.abort = cb
            elseif cmd.type == "get_state" and cb then
                cb({ success = true, data = {} })
            elseif cmd.type == "get_commands" and cb then
                cb({ success = true, data = { commands = {} } })
            end
            return true
        end,
    }
end

---@param rpc table
---@param t string
---@return boolean
local function sent_type(rpc, t)
    for _, ty in ipairs(rpc.sent) do
        if ty == t then
            return true
        end
    end
    return false
end

---@param rpc table
---@param res? table
local function flush_get_messages(rpc, res)
    local cb = rpc.pending.get_messages
    rpc.pending.get_messages = nil
    assert.truthy(cb, "get_messages was not sent")
    cb(res or { success = true, data = { messages = {} } })
end

---@param rpc table
---@param res? table
local function flush_switch_session(rpc, res)
    local cb = rpc.pending.switch_session
    rpc.pending.switch_session = nil
    assert.truthy(cb, "switch_session was not sent")
    cb(res or { success = true, data = {} })
end

---@param session table
---@param rpc table
local function fill_session(session, rpc)
    session.rpc = rpc
    session.attention = session.attention or { pending = {} }
    session.startup_announcements = session.startup_announcements or {}
    session.system_errors = session.system_errors or {}
    session.changed_files = session.changed_files or {}
    return session
end

describe("subsession view-switch without abort", function()
    local real_find
    local real_create
    local real_load
    local real_resumed
    local find_paths
    local tab
    local chat

    before_each(function()
        Config.setup({})
        find_paths = {}
        real_find = Read.find_path
        real_create = Sessions.create_detached
        real_load = Sessions.load_session_path
        real_resumed = Subsessions.on_parent_resumed
        Read.find_path = function(id)
            return find_paths[id]
        end
        tab = vim.api.nvim_get_current_tabpage()
        chat = stub_chat()
    end)

    after_each(function()
        Read.find_path = real_find
        Sessions.create_detached = real_create
        Sessions.load_session_path = real_load
        Subsessions.on_parent_resumed = real_resumed
        Sessions._reset()
        Config.setup({})
    end)

    local function register_parent_child(opts)
        opts = opts or {}
        local parent = fill_session({
            id = "parent-id",
            session_file = opts.parent_file or "/tmp/parent.jsonl",
            conversation_epoch = opts.epoch or 3,
            lineage_id = "lineage",
        }, make_rpc())
        local child = fill_session({
            id = "child-id",
            session_file = opts.child_file or "/tmp/child.jsonl",
            parent_id = "parent-id",
            _detached_busy = opts.detached_busy,
        }, make_rpc())
        find_paths["parent-id"] = opts.parent_disk or parent.session_file
        find_paths["child-id"] = opts.child_disk or child.session_file
        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        return parent, child
    end

    it("parent → child skips switch_session when the child already has the file", function()
        local parent, child = register_parent_child()
        chat._streaming = true
        Sessions.bind_chat(parent, chat, tab)

        local ok
        Subsessions.switch_to("child-id", function(result)
            ok = result
        end)

        assert.is_true(parent._detached_busy)
        assert.is_false(sent_type(child.rpc, "switch_session"))
        assert.is_false(sent_type(child.rpc, "abort"))
        assert.is_true(sent_type(child.rpc, "get_messages"))
        flush_get_messages(child.rpc)
        assert.is_true(
            vim.wait(3000, function()
                return ok == true
            end, 10),
            "switch_to should complete via reattach_view"
        )
        assert.are.equal("child-id", Sessions.get_for_tab(tab).id)
    end)

    it("child → parent skips switch_session when the parent already has the file", function()
        local parent, child = register_parent_child()
        child.view_parent_id = "parent-id"
        Sessions.bind_chat(child, chat, tab)

        local resumed = false
        local orig_resumed = Subsessions.on_parent_resumed
        Subsessions.on_parent_resumed = function()
            resumed = true
        end

        local ok
        Subsessions.switch_to_parent(function(result)
            ok = result
        end)

        assert.is_false(sent_type(parent.rpc, "switch_session"))
        assert.is_false(sent_type(parent.rpc, "abort"))
        assert.is_true(sent_type(parent.rpc, "get_messages"))
        flush_get_messages(parent.rpc)
        assert.is_true(
            vim.wait(3000, function()
                return ok == true
            end, 10),
            "switch_to_parent should complete via reattach_view"
        )

        Subsessions.on_parent_resumed = orig_resumed
        assert.is_false(resumed)
        assert.are.equal(3, parent.conversation_epoch)
        assert.are.equal("lineage", parent.lineage_id)
        assert.is_nil(parent.view_parent_id)
        assert.are.equal("parent-id", Sessions.get_for_tab(tab).id)
    end)

    it("sibling → sibling skips switch_session when the target already has the file", function()
        local parent, child_a = register_parent_child()
        local child_b = fill_session({
            id = "child-b",
            session_file = "/tmp/child-b.jsonl",
            parent_id = "parent-id",
        }, make_rpc())
        find_paths["child-b"] = child_b.session_file
        Sessions._register_for_test(child_b)
        child_a.view_parent_id = "parent-id"
        Sessions.bind_chat(child_a, chat, tab)

        local ok
        Subsessions.switch_to("child-b", function(result)
            ok = result
        end)

        assert.is_false(sent_type(child_b.rpc, "switch_session"))
        assert.is_false(sent_type(child_b.rpc, "abort"))
        assert.is_true(sent_type(child_b.rpc, "get_messages"))
        flush_get_messages(child_b.rpc)
        assert.is_true(vim.wait(3000, function()
            return ok == true
        end, 10))
        assert.are.equal("child-b", Sessions.get_for_tab(tab).id)
        assert.are.equal("parent-id", child_b.view_parent_id)
        assert.is_not_nil(parent)
    end)

    it("treats resolve-equivalent paths as already open", function()
        local path = vim.fn.tempname() .. "-child.jsonl"
        local file = assert(io.open(path, "w"))
        file:close()
        local resolved = vim.fn.resolve(path)
        local parent, child = register_parent_child({
            child_file = path,
            child_disk = resolved,
        })
        Sessions.bind_chat(parent, chat, tab)

        local ok
        Subsessions.switch_to("child-id", function(result)
            ok = result
        end)

        assert.is_false(sent_type(child.rpc, "switch_session"))
        assert.is_true(sent_type(child.rpc, "get_messages"))
        flush_get_messages(child.rpc)
        assert.is_true(vim.wait(3000, function()
            return ok == true
        end, 10))
        os.remove(path)
    end)

    it("skips switch_session when a live child has not reported session_file yet", function()
        local parent, child = register_parent_child()
        child.session_file = nil
        Sessions.bind_chat(parent, chat, tab)

        local ok
        Subsessions.switch_to("child-id", function(result)
            ok = result
        end)

        assert.is_false(sent_type(child.rpc, "switch_session"))
        assert.is_false(sent_type(child.rpc, "abort"))
        assert.is_true(sent_type(child.rpc, "get_messages"))
        flush_get_messages(child.rpc)
        assert.is_true(vim.wait(3000, function()
            return ok == true
        end, 10))
    end)

    it("sends switch_session when the live file differs from the disk path", function()
        local parent, child = register_parent_child({
            child_file = "/tmp/empty-child.jsonl",
            child_disk = "/tmp/disk-child.jsonl",
        })
        Sessions.bind_chat(parent, chat, tab)

        local load_opts
        local orig_load = Sessions.load_session_path
        Sessions.load_session_path = function(session, path, cb, opts)
            load_opts = opts
            return orig_load(session, path, cb, opts)
        end

        local ok
        Subsessions.switch_to("child-id", function(result)
            ok = result
        end)

        assert.is_true(sent_type(child.rpc, "switch_session"))
        assert.is_not_nil(load_opts)
        assert.is_false(load_opts.rebind_parent_context)
        flush_switch_session(child.rpc)
        if child.rpc.pending.get_messages then
            flush_get_messages(child.rpc)
        end
        assert.is_true(vim.wait(3000, function()
            return ok == true
        end, 10))
        Sessions.load_session_path = orig_load
    end)

    it("switch_to_parent passes rebind_parent_context false when it must load", function()
        local parent, child = register_parent_child({
            parent_file = "/tmp/parent-empty.jsonl",
            parent_disk = "/tmp/parent-disk.jsonl",
        })
        child.view_parent_id = "parent-id"
        Sessions.bind_chat(child, chat, tab)

        local resumed = false
        local orig_resumed = Subsessions.on_parent_resumed
        Subsessions.on_parent_resumed = function()
            resumed = true
        end
        local load_opts
        local orig_load = Sessions.load_session_path
        Sessions.load_session_path = function(session, path, cb, opts)
            load_opts = opts
            return orig_load(session, path, cb, opts)
        end

        local ok
        Subsessions.switch_to_parent(function(result)
            ok = result
        end)

        assert.is_true(sent_type(parent.rpc, "switch_session"))
        assert.is_not_nil(load_opts)
        assert.is_false(load_opts.rebind_parent_context)
        flush_switch_session(parent.rpc)
        if parent.rpc.pending.get_messages then
            flush_get_messages(parent.rpc)
        end
        assert.is_true(vim.wait(3000, function()
            return ok == true
        end, 10))

        Subsessions.on_parent_resumed = orig_resumed
        Sessions.load_session_path = orig_load
        assert.is_false(resumed)
        assert.are.equal(3, parent.conversation_epoch)
        assert.are.equal("lineage", parent.lineage_id)
    end)

    it("revive still sends switch_session for a new process", function()
        local revived
        local orig_create = Sessions.create_detached
        Sessions.create_detached = function()
            revived = fill_session({
                id = "tmp-revive",
                session_file = "/tmp/fresh-empty.jsonl",
            }, make_rpc())
            Sessions._register_for_test(revived)
            return revived
        end
        find_paths["dormant-id"] = "/tmp/dormant.jsonl"

        local result
        Subsessions.revive("dormant-id", function(session)
            result = session
        end)

        assert.is_not_nil(revived)
        assert.is_true(sent_type(revived.rpc, "switch_session"))
        flush_switch_session(revived.rpc)
        assert.is_true(vim.wait(3000, function()
            return result ~= nil
        end, 10))
        assert.are.equal("dormant-id", result.id)
        assert.are.equal("/tmp/dormant.jsonl", revived.session_file)
        Sessions.create_detached = orig_create
    end)

    it("queues inbound events while reattaching a busy session and does not abort", function()
        local parent, child = register_parent_child({ detached_busy = true })
        Sessions.bind_chat(parent, chat, tab)

        local ok
        Subsessions.switch_to("child-id", function(result)
            ok = result
        end)

        assert.is_true(child._view_rebuilding)
        assert.is_false(sent_type(child.rpc, "switch_session"))
        assert.is_false(sent_type(child.rpc, "abort"))
        Sessions.handle_event(child, {
            type = "message_update",
            assistantMessageEvent = { type = "text_delta", delta = "hi" },
        })
        assert.is_nil(chat.deltas)

        flush_get_messages(child.rpc)
        assert.is_true(
            vim.wait(3000, function()
                return ok == true and child._view_rebuilding ~= true
            end, 10),
            "reattach_view should finish and flush the queue"
        )
        assert.are.equal("hi", chat.deltas)
        assert.is_true((chat.agent_starts or 0) >= 1)
    end)
end)
