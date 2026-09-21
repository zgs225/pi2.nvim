-- Regression spec: the todo panel's state is keyed per SESSION, and a tab's
-- panel renders the session that tab is currently VIEWING. A tab can host
-- several sessions over time (parent + subagent children): viewing a child
-- rebinds the tab chat (Sessions.bind_chat), the child's todo_write results
-- are stored under the CHILD's session, and switching back to the parent must
-- immediately re-render the PARENT's list — not the child's stale one (the
-- reported "child todo overwrites/mixes with parent" bug).
--
-- Routing goes through Manager.handle_event (tool_execution_end), the same
-- guarded path live events take. The spec injects a hermetic pi.todo.tool_ui
-- stub via package.preload (same approach as tests/todo_panel_spec.lua) and
-- binds chat-less fake sessions via the Manager test hooks.

---@type table<string, table> saved package.loaded entries captured by stub_tool_ui
local saved_loaded = {}

--- Install a hermetic pi.todo.tool_ui stub before pi.todo is first required.
local function stub_tool_ui()
    local preload = package.preload["pi.todo.tool_ui"]
    if preload ~= nil then
        -- Stale preload from an earlier phase would win over our stub.
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
    -- Drop any real module already cached so the stub resolves first.
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

--- Monotonic counter so every fake session object is unique.
local next_fake_id = 0

--- A minimal chat-less pi.Session stand-in for Manager.handle_event /
--- bind_chat routing (update_todo_mirror reads nothing else).
---@param name string
---@return table
local function fake_session(name)
    next_fake_id = next_fake_id + 1
    local session = {
        id = ("spec-%s-%d"):format(name, next_fake_id),
        rpc = {
            is_running = function()
                return false
            end,
            stop = function() end,
        },
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        cwd = vim.fn.getcwd(),
        changed_files = {},
    }
    -- Detached sessions live in the registry too; get_for_tab resolves
    -- through it after bind_chat, so fakes must be registered on creation.
    Manager._register_for_test(session)
    return session
end

--- A chat stub that tolerates every Chat interaction the manager and event
--- routing make on a bound chat (bind_agent, on_tool_*, set_status, ...
--- — all become no-ops); the real flow passes the tab's Chat instance.
---@return table
local function fake_chat()
    return setmetatable({}, {
        __index = function()
            return function() end
        end,
    })
end

--- A tool result shaped like a live todo_write tool_execution_end.
---@param items { content: string, status: string }[]
---@return table
local function result(items)
    local completed = 0
    for _, it in ipairs(items) do
        if it.status == "completed" then
            completed = completed + 1
        end
    end
    return { details = { todos = items, completed = completed, total = #items } }
end

local parent_items = {
    { content = "PARENT: write module", status = "completed" },
    { content = "PARENT: write tests", status = "in_progress" },
}
local child_items = { { content = "CHILD: explore code", status = "in_progress" } }

--- A tool_execution_end todo_write event routed through the session.
---@param session table
---@param items { content: string, status: string }[]
---@param call_id string
local function todo_write(session, items, call_id)
    Manager.handle_event(session, {
        type = "tool_execution_end",
        toolName = "todo_write",
        toolCallId = call_id,
        result = result(items),
    })
end

--- Pump the event loop so scheduled refreshes land.
local function pump()
    vim.wait(300, function()
        return false
    end)
end

--- The open panel buffer's lines in `tab`.
---@param tab integer
---@return string[]
local function panel_lines(tab)
    local win = Todo.win(tab)
    assert.is_truthy(win, "todo panel open in tab")
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

describe("todo panel session switching", function()
    local saved_options

    before_each(function()
        saved_options = vim.deepcopy(Config.options)
        Config.options.todo = { panel = { auto_open = true, height = 0.5, position = "below", hide_when_empty = true } }
        Todo._reset()
    end)

    after_each(function()
        Todo._reset()
        Manager._reset()
        while vim.fn.tabpagenr("$") > 1 do
            vim.cmd("tablast")
            vim.cmd("tabclose")
        end
        Config.options = saved_options
    end)

    it("viewing a child shows the child's list; switching back re-renders the parent's list immediately", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local parent = fake_session("parent")
        Manager._bind_shim_for_test(parent, tab)
        todo_write(parent, parent_items, "p1")
        pump()
        assert.are.equal(2, Todo.current().total, "panel shows the parent's list")
        assert.are.equal("  ✓ PARENT: write module", panel_lines(tab)[4])

        -- View the child in the same tab (the /PiSub* path rebinds the chat).
        local child = fake_session("child")
        Manager.bind_chat(child, fake_chat(), tab)
        pump()
        assert.are.equal(child, Manager.get_for_tab(tab), "child is the tab's viewed session")
        assert.is_nil(parent.attached_tab, "parent detached while the child is viewed")

        -- The child writes todos: the open panel re-renders under the child.
        todo_write(child, child_items, "c1")
        pump()
        assert.are.equal(1, Todo.current().total, "panel shows the child's list while the child is viewed")
        assert.are.equal("  ◐ CHILD: explore code", panel_lines(tab)[4])
        assert.are.equal("  Todo · 0/1 completed", panel_lines(tab)[2])

        -- Switch back to the parent: the PARENT's list must render
        -- immediately, with NO further parent todo_write (the stale-children
        -- mixing bug: the panel used to keep the child's list).
        Manager.bind_chat(parent, fake_chat(), tab)
        pump()
        assert.are.equal(parent, Manager.get_for_tab(tab), "parent is the viewed session again")
        local cur = Todo.current()
        assert.is_truthy(cur, "panel state re-resolved to the parent's session")
        assert.are.equal(2, cur.total, "parent's list, not the child's stale one")
        assert.are.equal("PARENT: write module", cur.todos[1].content)
        assert.are.equal("  ✓ PARENT: write module", panel_lines(tab)[4])
        assert.are.equal("  ◐ PARENT: write tests", panel_lines(tab)[5])
    end)

    it("a detached child's todos are stored but never steal the panel or auto-open it", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local parent = fake_session("parent")
        Manager._bind_shim_for_test(parent, tab)
        todo_write(parent, parent_items, "p1")
        pump()
        assert.is_truthy(Todo.win(tab), "parent's transition auto-opened the panel")
        Todo.close() -- clear the auto-open so the child's writes can be judged on their own

        -- A child that was never bound to a tab writes todos: stored under the
        -- child's own state, the parent's tab shows nothing new.
        local child = fake_session("child")
        todo_write(child, child_items, "c1")
        pump()
        assert.is_nil(Todo.win(tab), "detached child's first write does not auto-open any panel")
        local cur = Todo.current()
        assert.is_truthy(cur, "parent's state survives the child's detached write")
        assert.are.equal(2, cur.total)
        assert.are.equal("PARENT: write module", cur.todos[1].content)

        -- Viewing the child re-renders an open panel, but does not pop one.
        Manager.bind_chat(child, fake_chat(), tab)
        pump()
        assert.is_nil(Todo.win(tab), "switching the view does not auto-open the panel either")

        -- Opening :PiTodo now shows the CHILD's stored list.
        Todo.open()
        assert.are.equal("  Todo · 0/1 completed", panel_lines(tab)[2])
        assert.are.equal("  ◐ CHILD: explore code", panel_lines(tab)[4])
    end)

    it("auto-open fires only on the viewed session's own empty→non-empty transition", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local parent = fake_session("parent")
        Manager._bind_shim_for_test(parent, tab)
        -- First write: the viewed session transitions empty→non-empty.
        todo_write(parent, parent_items, "p1")
        vim.wait(300, function()
            return Todo.win(tab) ~= nil
        end)
        assert.is_truthy(Todo.win(tab))
        Todo.close()

        -- A later write without a transition must not re-open the panel.
        local updated = {
            { content = "PARENT: write module", status = "completed" },
            { content = "PARENT: write tests", status = "completed" },
        }
        todo_write(parent, updated, "p2")
        pump()
        assert.is_nil(Todo.win(tab), "non-transition write stays closed")

        -- Clear the list, then re-add: that is an empty→non-empty transition.
        todo_write(parent, {}, "p3")
        pump()
        assert.is_nil(Todo.win(tab))
        todo_write(parent, parent_items, "p4")
        vim.wait(300, function()
            return Todo.win(tab) ~= nil
        end)
        assert.is_truthy(Todo.win(tab), "cleared then re-added list auto-opens again")
    end)

    it("closing the viewed session prunes its todo state", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local parent = fake_session("parent")
        Manager._bind_shim_for_test(parent, tab)
        todo_write(parent, parent_items, "p1")
        pump()
        assert.is_truthy(Todo.current())

        Manager.close_session(parent)
        pump()
        assert.is_nil(Todo.current(), "closed session's todo state is pruned")
        assert.is_nil(Todo.win(tab), "auto-opened panel closes once the viewed session is gone")
    end)
end)

unstub_tool_ui()
