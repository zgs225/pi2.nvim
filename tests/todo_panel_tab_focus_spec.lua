-- Unit tests for the todo panel's per-session state and per-tab view
-- resolution: todo events are stored under the ROUTING SESSION (per-session
-- mirror), a tab's panel renders the session that tab currently VIEWES via
-- manager.get_for_tab, and a deferred auto-open fires on TabEnter — consumed
-- only if the tab's then-viewed session still has todos.
--
-- Routing goes through Manager._update_todo_mirror — the same guarded path
-- (tool gating + result_details) the live tool_execution_end and replay
-- handlers use — with an explicit tab (shim session), nil (detached shim
-- session), or a session object. The spec injects a hermetic pi.todo.tool_ui
-- stub via package.preload before the first require and restores it
-- afterwards (same approach as tests/todo_panel_spec.lua).

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

--- Build a details payload as the todo_write tool would produce.
---@param items { content: string, status: string }[]
---@return table
local function details(items)
    local completed = 0
    for _, it in ipairs(items) do
        if it.status == "completed" then
            completed = completed + 1
        end
    end
    return { todos = items, completed = completed, total = #items }
end

--- Pump the event loop so scheduled refreshes land.
local function pump()
    vim.wait(200, function()
        return false
    end)
end

describe("todo panel per-session state", function()
    local saved_options

    before_each(function()
        saved_options = vim.deepcopy(Config.options)
        Config.options.todo = { panel = { auto_open = true, height = 0.5, position = "below", hide_when_empty = true } }
        Todo._reset()
    end)

    after_each(function()
        Todo._reset()
        Manager._reset()
        -- Drop any extra tab created by the tests (close from the last tab so
        -- the first tab survives).
        while vim.fn.tabpagenr("$") > 1 do
            vim.cmd("tablast")
            vim.cmd("tabclose")
        end
        Config.options = saved_options
    end)

    it(
        "stores the write under the session's shim while another tab is focused, and defers auto-open to TabEnter",
        function()
            local tab1 = vim.api.nvim_get_current_tabpage()

            -- Session-less tab 2 gets the keyboard focus (the bug scenario).
            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()
            assert.are_not.equal(tab1, tab2)

            -- A todo_write result for the tab-1 session arrives while tab 2 is
            -- focused: routed with the session's tab explicitly.
            Manager._update_todo_mirror(
                "todo_write",
                { details = details({ { content = "write module", status = "completed" } }) },
                tab1
            )
            pump()

            -- The focused session-less tab captured nothing.
            assert.is_nil(Todo.current(), "no todo state under the focused session-less tab")
            assert.is_nil(Todo.win(tab2), "no panel auto-opened in the focused session-less tab")
            -- And the session's tab has no panel YET: a split cannot be created in
            -- a non-current tabpage without stealing focus, so the auto-open waits.
            assert.is_nil(Todo.win(tab1), "no panel created in the background session tab while unfocused")

            -- Entering the session's tab consumes the pending auto-open.
            vim.api.nvim_set_current_tabpage(tab1)
            local win1 = Todo.win(tab1)
            assert.is_truthy(win1, "entering the session tab auto-opens its panel")
            assert.are.equal("auto", Todo._opened_by(), "deferred auto-open marks the panel auto")

            -- :PiTodo-equivalent: the panel shows the session's todos, not 'no todos'.
            local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win1), 0, -1, false)
            assert.are.equal("  Todo · 1/1 completed", lines[2])
            assert.are.equal("  ✓ write module", lines[4])

            -- No cross-talk: re-entering the session-less tab opens nothing.
            vim.api.nvim_set_current_tabpage(tab2)
            assert.is_nil(Todo.win(tab2), "session-less tab stays panel-less after the deferred open")
        end
    )

    it(
        "a detached session (explicit nil tab) stores under its own state, visible in no tab, and leaves no pending auto-open",
        function()
            local tab1 = vim.api.nvim_get_current_tabpage()

            Manager._update_todo_mirror(
                "todo_write",
                { details = details({ { content = "detached", status = "pending" } }) },
                nil -- explicit third argument = detached session
            )
            pump()

            assert.is_nil(Todo.current(), "detached session wrote no state visible to any tab")
            assert.is_nil(Todo.win(tab1), "detached session opened no panel")
            -- Entering any tab consumes nothing: no marker was left behind.
            vim.cmd("tabnew")
            vim.api.nvim_set_current_tabpage(tab1)
            assert.is_nil(Todo.win(tab1), "no deferred panel opened from a detached-session event")
        end
    )

    it("a table third argument is treated as the routing session object", function()
        local tab1 = vim.api.nvim_get_current_tabpage()
        local session = { id = "explicit-session", attached_tab = tab1, tab = tab1 }
        Manager._bind_shim_for_test(session, tab1)
        Manager._update_todo_mirror(
            "todo_write",
            { details = details({ { content = "object-keyed", status = "pending" } }) },
            session
        )
        pump()
        local cur = Todo.current()
        assert.is_truthy(cur, "state stored under the passed session (resolvable via get_for_tab)")
        assert.are.equal(1, cur.total)
        assert.is_truthy(Todo.win(tab1), "the attached+viewed session's write auto-opens the panel")
    end)

    it("legacy no-tab hook calls keep keying to the current tab (compat)", function()
        local tab1 = vim.api.nvim_get_current_tabpage()
        Manager._update_todo_mirror("todo_write", { details = details({ { content = "legacy", status = "pending" } }) })
        pump()
        local cur = Todo.current()
        assert.is_truthy(cur, "no-tab hook call still populates the current tab's mirror")
        assert.are.equal(1, cur.total)
        assert.is_truthy(Todo.win(tab1), "legacy call still auto-opens the panel in the CURRENT tab")
        assert.are.equal("auto", Todo._opened_by())
    end)
end)

unstub_tool_ui()
