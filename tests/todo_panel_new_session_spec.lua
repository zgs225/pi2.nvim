--- Regression spec: `/new` (Manager.new_session() / require("pi").new_session())
--- resets the per-session todo mirror and cleans up the panel.
---
--- Previously, start_new_session reset every per-session mirror except pi.todo;
--- because pi.todo keys state by session object identity and the session object
--- survives /new, stale todos remained rendered in the panel and suppressed
--- auto_open for the new conversation.
---
--- Routing and session replacement are exercised through Manager.new_session()
--- and Manager.load_session_path with stubbed RPC and Chat instances.

---@type table<string, table> saved package.loaded entries captured by stub_tool_ui
local saved_loaded = {}

--- Install a hermetic pi.todo.tool_ui stub before pi.todo is first required.
local function stub_tool_ui()
    local preload = package.preload["pi.todo.tool_ui"]
    if preload ~= nil then
        package.preload["pi.todo.tool_ui"] = nil
        package.loaded["pi.todo.tool_ui"] = nil
    end
    package.preload["pi.todo.tool_ui"] = function()
        return {
            is_todo_tool = function(name)
                return name == "todo_write"
            end,
            result_details = function(result)
                local d = result and (result.details or result) or nil
                if type(d) ~= "table" or type(d.todos) ~= "table" then
                    return nil
                end
                local completed, total = 0, #d.todos
                for _, t in ipairs(d.todos) do
                    if t.status == "completed" then
                        completed = completed + 1
                    end
                end
                return { todos = d.todos, completed = completed, total = total }
            end,
            progress_text = function(details)
                return string.format("%d/%d completed", details.completed, details.total)
            end,
            format_lines = function(details)
                local lines = { string.format("%d/%d", details.completed, details.total) }
                for _, t in ipairs(details.todos) do
                    local icon = t.status == "completed" and "✓" or (t.status == "in_progress" and "◐" or "○")
                    lines[#lines + 1] = icon .. " " .. t.content
                end
                return lines
            end,
        }
    end
    for _, name in ipairs({
        "pi.todo",
        "pi.todo.tool_ui",
        "pi.sessions.manager",
        "pi.ui.sessions",
        "pi.config",
        "pi.notify",
    }) do
        saved_loaded[name] = package.loaded[name]
        package.loaded[name] = nil
    end
end

--- Remove the stub and restore the previous package.loaded state.
local function unstub_tool_ui()
    package.preload["pi.todo.tool_ui"] = nil
    package.loaded["pi.todo.tool_ui"] = nil
    for name, mod in pairs(saved_loaded) do
        package.loaded[name] = mod
    end
    saved_loaded = {}
end

stub_tool_ui()
local Todo = require("pi.todo")
local Manager = require("pi.sessions.manager")
local Config = require("pi.config")
local Sidebar = require("pi.ui.sidebar")
local Manifest = require("pi.subsessions.manifest")

local next_fake_id = 0

--- Create a fake session with stubbed RPC and Chat for testing the real Manager paths.
---@param name string
---@param opts? { on_send?: fun(msg: table, cb?: fun(res: table)): boolean }
---@return pi.Session
local function make_session(name, opts)
    next_fake_id = next_fake_id + 1
    opts = opts or {}
    local sent = {}
    local session = {
        id = ("spec-%s-%d"):format(name, next_fake_id),
        rpc = {
            is_running = function()
                return true
            end,
            stop = function() end,
            send = function(_, msg, cb)
                sent[#sent + 1] = msg and msg.type or "?"
                if opts.on_send then
                    return opts.on_send(msg, cb)
                end
                if cb then
                    cb({ success = true, data = {} })
                end
                return true
            end,
        },
        chat = setmetatable({
            is_streaming = function()
                return false
            end,
            clear = function() end,
            update_state = function() end,
            show_startup_block = function() end,
            set_model_ambiguity_for = function() end,
            show_loading = function() end,
            clear_placeholder = function() end,
            ensure_shown_and_focus_prompt = function() end,
            on_error = function() end,
            on_tool_end = function() end,
            set_replaying = function() end,
        }, {
            __index = function()
                return function() end
            end,
        }),
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        cwd = vim.fn.getcwd(),
        changed_files = {},
        _sent = sent,
    }
    Manager._register_for_test(session)
    return session
end

--- Pump the event loop so vim.schedule and timer events run.
---@param ms? integer
local function pump(ms)
    vim.wait(ms or 150, function()
        return false
    end)
end

--- The open panel buffer's lines in `tab`.
---@param tab integer
---@return string[]?
local function panel_lines(tab)
    local win = Todo.win(tab)
    if not win then
        return nil
    end
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

--- A tool result shaped like a live todo_write tool_execution_end.
---@param items { content: string, status: string }[]
---@return table
local function todo_result(items)
    local completed = 0
    for _, it in ipairs(items) do
        if it.status == "completed" then
            completed = completed + 1
        end
    end
    return { details = { todos = items, completed = completed, total = #items } }
end

--- Route a todo_write event to the manager for `session`.
---@param session pi.Session
---@param items { content: string, status: string }[]
---@param call_id? string
local function todo_write(session, items, call_id)
    Manager.handle_event(session, {
        type = "tool_execution_end",
        toolName = "todo_write",
        toolCallId = call_id or "c1",
        result = todo_result(items),
    })
end

local conv_a_items = {
    { content = "CONV-A: write code", status = "completed" },
    { content = "CONV-A: write tests", status = "in_progress" },
    { content = "CONV-A: documentation", status = "pending" },
}

local conv_b_items = {
    { content = "CONV-B: new task", status = "in_progress" },
}

describe("todo panel new_session and conversation replacement", function()
    local saved_options
    local tmp_manifest

    before_each(function()
        saved_options = vim.deepcopy(Config.options)
        Config.options.todo = {
            panel = { auto_open = false, height = 0.5, position = "below", hide_when_empty = true },
        }
        tmp_manifest = vim.fn.tempname()
        Manifest.path = function()
            return tmp_manifest
        end
        Manifest._reset()
        Todo._reset()
        Sidebar._reset()
        Manager._reset()
    end)

    after_each(function()
        Todo._reset()
        Sidebar._reset()
        Manager._reset()
        Manifest._reset()
        while vim.fn.tabpagenr("$") > 1 do
            vim.cmd("tablast")
            vim.cmd("tabclose")
        end
        if tmp_manifest and vim.fn.filereadable(tmp_manifest) == 1 then
            vim.fn.delete(tmp_manifest)
        end
        Config.options = saved_options
    end)

    it("after /new success path, pi.todo.get(session) == nil and pi.todo.current() == nil", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local session = make_session("sess-a")
        Manager._bind_shim_for_test(session, tab)

        todo_write(session, conv_a_items, "call-1")
        pump()

        assert.is_truthy(Todo.get(session), "snapshot stored before /new")
        assert.are.equal(3, Todo.get(session).total)
        assert.is_truthy(Todo.current(), "current() resolves before /new")
        assert.are.equal(3, Todo.current().total)

        -- Execute the real Manager.new_session() path
        Manager.new_session()
        pump()

        assert.is_nil(Todo.get(session), "pi.todo.get(session) is nil after /new")
        assert.is_nil(Todo.current(), "pi.todo.current() is nil after /new")
    end)

    it("auto-opened panel (M.open('auto')) is CLOSED after the reset", function()
        Config.options.todo.panel.auto_open = true
        local tab = vim.api.nvim_get_current_tabpage()
        local session = make_session("sess-auto")
        Manager._bind_shim_for_test(session, tab)

        todo_write(session, conv_a_items, "call-auto")
        pump()

        assert.is_true(Todo.is_open(), "panel auto-opened for conversation A")
        assert.are.equal("auto", Todo._opened_by())
        assert.is_truthy(Todo.win(tab))

        -- /new executes and resets the conversation
        Manager.new_session()
        pump()

        assert.is_false(Todo.is_open(), "auto-opened panel is closed after /new")
        assert.is_nil(Todo.win(tab), "panel window handle is nil after /new")
        assert.is_nil(Todo._opened_by())
    end)

    it("manually opened panel (M.open('manual')) stays open showing the '  no todos' placeholder", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local session = make_session("sess-manual")
        Manager._bind_shim_for_test(session, tab)

        todo_write(session, conv_a_items, "call-manual")
        Todo.open("manual")
        pump()

        assert.is_true(Todo.is_open(), "panel open before /new")
        assert.are.equal("manual", Todo._opened_by())
        local lines_before = panel_lines(tab)
        assert.is_truthy(lines_before)
        assert.are.equal("  Todo · 1/3 completed", lines_before[2])

        -- /new executes
        Manager.new_session()
        pump()

        assert.is_true(Todo.is_open(), "manually opened panel stays open after /new")
        assert.are.equal("manual", Todo._opened_by())
        local lines_after = panel_lines(tab)
        assert.is_truthy(lines_after)
        assert.are.equal("  no todos", lines_after[2], "placeholder is rendered instead of stale todos")
    end)

    it("auto_open_pending is cleared: a stale marker for that tab does not re-open the panel", function()
        Config.options.todo.panel.auto_open = true
        local tab1 = vim.api.nvim_get_current_tabpage()
        local session1 = make_session("sess-tab1")
        Manager._bind_shim_for_test(session1, tab1)

        -- Open a second tab for background testing
        vim.cmd("tabnew")
        local tab2 = vim.api.nvim_get_current_tabpage()
        local session2 = make_session("sess-tab2")
        Manager._bind_shim_for_test(session2, tab2)

        -- Switch back to tab 1
        vim.cmd("tabprevious")
        assert.are.equal(tab1, vim.api.nvim_get_current_tabpage())

        -- session2 writes todos while tab 2 is in background -> auto_open_pending[tab2] = true
        todo_write(session2, conv_a_items, "bg-call")
        pump()

        -- Panel for tab2 has not opened yet because tab2 is not the current tab
        assert.is_nil(Todo.win(tab2), "tab2 panel not open while backgrounded")

        -- Conversation on session2 is replaced while still in the background
        Todo.on_conversation_replaced(session2)
        pump()

        -- Now disable auto_open for new writes so that ONLY a stale marker could pop the panel
        Config.options.todo.panel.auto_open = false
        -- Provide empty or new todos to session2 without auto-opening
        Todo.update_from_details({ todos = conv_b_items, completed = 0, total = 1 }, session2)

        -- Switch to tab 2, firing TabEnter
        vim.cmd("tabnext")
        assert.are.equal(tab2, vim.api.nvim_get_current_tabpage())
        pump()

        assert.is_false(Todo.is_open(), "stale marker was cleared; panel did not pop on TabEnter")
    end)

    it("regression: the first todo_write of the NEW conversation triggers auto_open", function()
        Config.options.todo.panel.auto_open = true
        local tab = vim.api.nvim_get_current_tabpage()
        local session = make_session("sess-reg")
        Manager._bind_shim_for_test(session, tab)

        -- Turn 1: write items in conversation A -> panel auto-opens
        todo_write(session, conv_a_items, "turn-1")
        pump()
        assert.is_true(Todo.is_open(), "panel auto-opened in conversation A")
        assert.are.equal(3, Todo.current().total)

        -- /new starts a fresh conversation
        Manager.new_session()
        pump()

        assert.is_false(Todo.is_open(), "panel closed after /new")
        assert.is_nil(Todo.current(), "current() is nil after /new")

        -- First todo_write of conversation B
        todo_write(session, conv_b_items, "turn-new-1")
        pump()

        assert.is_true(Todo.is_open(), "first todo_write of new conversation triggered auto_open")
        assert.are.equal("auto", Todo._opened_by())
        assert.are.equal(1, Todo.current().total)
        local lines = panel_lines(tab)
        assert.is_truthy(lines)
        assert.are.equal("  Todo · 0/1 completed", lines[2])
        assert.are.equal("  ◐ CONV-B: new task", lines[4])
    end)

    it("resume-style rebuild still works: replaying a toolResult repopulates the mirror after reset", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local session = make_session("sess-rebuild")
        Manager._bind_shim_for_test(session, tab)

        todo_write(session, conv_a_items, "call-a")
        pump()
        assert.are.equal(3, Todo.get(session).total)

        -- Conversation reset
        Todo.on_conversation_replaced(session)
        pump()
        assert.is_nil(Todo.get(session), "mirror cleared by reset")

        -- Replay a toolResult through Manager.handle_event
        todo_write(session, conv_b_items, "call-replayed")
        pump()

        assert.is_truthy(Todo.get(session), "mirror repopulated after replay")
        assert.are.equal(1, Todo.get(session).total)
        assert.are.equal("CONV-B: new task", Todo.get(session).todos[1].content)
        assert.are.equal(1, Todo.current().total)
    end)

    it("load_session_path resets stale todos and rebuilds when resumed conversation has todos", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local resumed_messages = {
            {
                role = "toolResult",
                toolName = "todo_write",
                toolCallId = "call-resumed",
                content = "{}",
                details = {
                    todos = conv_b_items,
                    completed = 0,
                    total = 1,
                },
            },
        }

        local session = make_session("sess-load", {
            on_send = function(msg, cb)
                if msg.type == "switch_session" then
                    if cb then
                        cb({ success = true, data = {} })
                    end
                    return true
                elseif msg.type == "get_messages" then
                    if cb then
                        cb({ success = true, data = { messages = resumed_messages } })
                    end
                    return true
                end
                if cb then
                    cb({ success = true, data = {} })
                end
                return true
            end,
        })
        Manager._bind_shim_for_test(session, tab)

        -- Initial state from prior conversation
        todo_write(session, conv_a_items, "init-conv")
        pump()
        assert.are.equal(3, Todo.get(session).total)

        -- Load another session
        local done = false
        Manager.load_session_path(session, "/tmp/fake-session.jsonl", function(ok)
            done = ok
        end)
        pump(250)

        assert.is_true(done, "load_session_path completed")
        assert.is_truthy(Todo.get(session), "rebuilt with resumed session todos")
        assert.are.equal(1, Todo.get(session).total, "contains 1 resumed todo, not old 3")
        assert.are.equal("CONV-B: new task", Todo.get(session).todos[1].content)
    end)

    it("load_session_path resets stale todos to nil when resumed conversation has no todos", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local session = make_session("sess-load-empty", {
            on_send = function(msg, cb)
                if msg.type == "switch_session" then
                    if cb then
                        cb({ success = true, data = {} })
                    end
                    return true
                elseif msg.type == "get_messages" then
                    if cb then
                        cb({ success = true, data = { messages = {} } })
                    end
                    return true
                end
                if cb then
                    cb({ success = true, data = {} })
                end
                return true
            end,
        })
        Manager._bind_shim_for_test(session, tab)

        -- Initial state from prior conversation
        todo_write(session, conv_a_items, "init-conv-2")
        pump()
        assert.are.equal(3, Todo.get(session).total)

        -- Load a session that contains no todos
        local done = false
        Manager.load_session_path(session, "/tmp/empty-session.jsonl", function(ok)
            done = ok
        end)
        pump(250)

        assert.is_true(done, "load_session_path completed")
        assert.is_nil(Todo.get(session), "stale todos cleared and not inherited when resumed conversation has no todos")
        assert.is_nil(Todo.current())
    end)
end)

unstub_tool_ui()
