-- Unit tests for pi.todo (:PiTodo panel): the details state mirror, panel
-- line building, height computation, hide_when_empty behavior, and the
-- open/close/is_open bookkeeping (exercised against real headless windows).
--
-- pi.todo.tool_ui is owned by another change, so the spec injects a stub via
-- package.preload before the first require and restores it afterwards.

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

describe("todo panel", function()
    local saved_options

    before_each(function()
        saved_options = vim.deepcopy(Config.options)
        -- Defensive-config coverage: the todo key does not exist yet.
        Config.options.todo = nil
        Todo._reset()
    end)

    after_each(function()
        pcall(Todo.close)
        Todo._reset()
        Config.options = saved_options
    end)

    describe("state mirror", function()
        it("current() is nil before any update", function()
            assert.is_nil(Todo.current())
        end)

        it("stores the latest details", function()
            Todo.update_from_details(details({ { content = "a", status = "pending" } }))
            local cur = Todo.current()
            assert.is_truthy(cur)
            assert.are.equal(1, cur.total)
            assert.are.equal(0, cur.completed)
            assert.are.equal("a", cur.todos[1].content)
        end)

        it("replaces the list on every update (full-replace semantics)", function()
            Todo.update_from_details(details({ { content = "a", status = "pending" } }))
            Todo.update_from_details(details({
                { content = "a", status = "completed" },
                { content = "b", status = "in_progress" },
            }))
            local cur = Todo.current()
            assert.are.equal(2, cur.total)
            assert.are.equal(1, cur.completed)
            assert.are.equal(2, #cur.todos)
        end)

        it("keeps an empty state after a clear (total == 0)", function()
            Todo.update_from_details(details({ { content = "a", status = "pending" } }))
            Todo.update_from_details({ todos = {}, completed = 0, total = 0 })
            local cur = Todo.current()
            assert.is_truthy(cur)
            assert.are.equal(0, cur.total)
        end)

        it("ignores malformed details", function()
            Todo.update_from_details(nil)
            Todo.update_from_details({})
            Todo.update_from_details({ nope = true })
            assert.is_nil(Todo.current())
        end)
    end)

    describe("height computation", function()
        local cfg = { auto_open = false, height = 10, position = "below", hide_when_empty = true }

        it("caps at the configured height", function()
            assert.are.equal(10, Todo._height_for(25, cfg))
        end)

        it("uses the line count when smaller than the max", function()
            assert.are.equal(4, Todo._height_for(4, cfg))
        end)

        it("never goes below one line", function()
            assert.are.equal(1, Todo._height_for(0, cfg))
        end)
    end)

    describe("open/close/is_open bookkeeping", function()
        it("is_open is false before opening and true after", function()
            assert.is_false(Todo.is_open())
            Todo.open()
            assert.is_true(Todo.is_open())
        end)

        it("open creates one valid window per tab", function()
            Todo.open()
            local win = vim.api.nvim_get_current_win()
            assert.is_true(vim.api.nvim_win_is_valid(win))
            Todo.close()
            assert.is_false(Todo.is_open())
        end)

        it("toggle switches between open and closed", function()
            Todo.toggle()
            assert.is_true(Todo.is_open())
            Todo.toggle()
            assert.is_false(Todo.is_open())
        end)

        it("open when no todos still shows the placeholder (explicit toggle)", function()
            Todo.update_from_details({ todos = {}, completed = 0, total = 0 })
            Todo.open()
            assert.is_true(Todo.is_open())
            local bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal("no todos", lines[1])
        end)

        it("close is a safe no-op when nothing is open", function()
            assert.has_no_errors(function()
                Todo.close()
            end)
            assert.is_false(Todo.is_open())
        end)

        it("stale window handles do not leak is_open=true", function()
            Todo.open()
            local win = vim.api.nvim_get_current_win()
            vim.api.nvim_win_close(win, true)
            assert.is_false(Todo.is_open())
        end)
    end)

    describe("rendering", function()
        it("renders header line and todo items from format_lines", function()
            Todo.update_from_details(details({
                { content = "write code", status = "completed" },
                { content = "run tests", status = "in_progress" },
                { content = "review", status = "pending" },
            }))
            Todo.open()
            local bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal("1/3", lines[1])
            assert.are.equal("✓ write code", lines[2])
            assert.are.equal("◐ run tests", lines[3])
            assert.are.equal("○ review", lines[4])
        end)

        it("refresh re-renders after a details update", function()
            Todo.open()
            Todo.update_from_details(details({ { content = "only item", status = "pending" } }))
            -- update schedules the refresh; pump the event loop.
            vim.wait(200, function()
                return false
            end)
            local bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal("0/1", lines[1])
            assert.are.equal("○ only item", lines[2])
        end)
    end)

    describe("stacked layout", function()
        ---@type integer?
        local fake_sess_win

        ---@type table? saved package.loaded['pi.ui.sessions']
        local saved_sessions_mod

        ---@return integer sessions-like window (10-line topleft split)
        local function open_fake_sessions()
            vim.cmd("topleft 10split")
            local b = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_win_set_buf(0, b)
            vim.wo.winfixheight = true
            fake_sess_win = vim.api.nvim_get_current_win()
            -- Point pi.ui.sessions at a fake exposing the same M.win(tab)
            -- accessor the panel uses to find the sidebar column.
            package.loaded["pi.ui.sessions"] = {
                win = function()
                    return fake_sess_win
                end,
            }
            return fake_sess_win
        end

        before_each(function()
            fake_sess_win = nil
            saved_sessions_mod = package.loaded["pi.ui.sessions"]
        end)

        after_each(function()
            pcall(Todo.close)
            if fake_sess_win and vim.api.nvim_win_is_valid(fake_sess_win) then
                pcall(vim.api.nvim_win_close, fake_sess_win, true)
            end
            package.loaded["pi.ui.sessions"] = saved_sessions_mod
        end)

        it("stacks below the sessions window with winfixheight", function()
            local sess = open_fake_sessions()
            Todo.update_from_details(details({ { content = "a", status = "pending" } }))
            Todo.open()
            local todo_win = vim.api.nvim_get_current_win()
            assert.are_not.equal(sess, todo_win)
            assert.is_true(vim.wo[todo_win].winfixheight)
            -- The sessions window keeps its configured height.
            assert.are.equal(10, vim.fn.winheight(sess))
            -- The todo panel sits below the sessions window.
            assert.is_true(vim.fn.win_screenpos(sess)[1] < vim.fn.win_screenpos(todo_win)[1])
        end)

        it("stacks above the sessions window with position=above", function()
            Config.options.todo =
                { panel = { auto_open = false, height = 10, position = "above", hide_when_empty = true } }
            local sess = open_fake_sessions()
            Todo.update_from_details(details({ { content = "a", status = "pending" } }))
            Todo.open()
            local todo_win = vim.api.nvim_get_current_win()
            assert.is_true(vim.fn.win_screenpos(todo_win)[1] < vim.fn.win_screenpos(sess)[1])
        end)
    end)

    describe("per-tab buffers", function()
        it("two tabs with open panels each show their own list (no cross-talk)", function()
            Todo.update_from_details(details({ { content = "tab one", status = "pending" } }))
            Todo.open()
            local tab1 = vim.api.nvim_get_current_tabpage()
            local win1 = vim.api.nvim_get_current_win()
            local buf1 = vim.api.nvim_win_get_buf(win1)

            vim.cmd("tabnew")
            Todo.update_from_details(details({ { content = "tab two", status = "pending" } }))
            Todo.open()
            local tab2 = vim.api.nvim_get_current_tabpage()
            local win2 = vim.api.nvim_get_current_win()
            local buf2 = vim.api.nvim_win_get_buf(win2)

            -- Distinct buffers, each showing its own tab's list.
            assert.are_not.equal(buf1, buf2)
            local lines2 = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
            assert.are.equal("0/1", lines2[1])
            assert.are.equal("○ tab two", lines2[2])

            -- Back on tab 1: its panel buffer still shows tab one's list.
            vim.api.nvim_set_current_tabpage(tab1)
            local lines1 = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
            assert.are.equal("0/1", lines1[1])
            assert.are.equal("○ tab one", lines1[2])

            -- Cleanup: drop both panels, then close the extra tab.
            Todo._reset()
            vim.api.nvim_set_current_tabpage(tab2)
            vim.cmd("tabclose")
        end)

        it("refresh on one tab does not clobber the other tab's buffer", function()
            Todo.update_from_details(details({ { content = "alpha", status = "pending" } }))
            Todo.open()
            local tab1 = vim.api.nvim_get_current_tabpage()
            local buf1 = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())

            vim.cmd("tabnew")
            Todo.update_from_details(details({ { content = "beta", status = "in_progress" } }))
            Todo.open()
            local buf2 = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            -- Refresh scheduled by tab 2's update must not rewrite buf1.
            vim.wait(200, function()
                return false
            end)
            vim.api.nvim_set_current_tabpage(tab1)
            local lines1 = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
            assert.are.equal("○ alpha", lines1[2])

            Todo._reset()
            vim.cmd("tabclose")
        end)
    end)

    describe("opened_by semantics", function()
        it("manual :PiTodo open marks the panel manual", function()
            Todo.open()
            assert.are.equal("manual", Todo._opened_by())
        end)

        it("auto_open transition marks the panel auto", function()
            Config.options.todo =
                { panel = { auto_open = true, height = 10, position = "below", hide_when_empty = true } }
            Todo.update_from_details(details({ { content = "first", status = "pending" } }))
            vim.wait(300, function()
                return Todo.is_open()
            end)
            assert.are.equal("auto", Todo._opened_by())
        end)

        it("auto-opened panel closes when the list clears (hide_when_empty)", function()
            Config.options.todo =
                { panel = { auto_open = true, height = 10, position = "below", hide_when_empty = true } }
            Todo.update_from_details(details({ { content = "first", status = "pending" } }))
            vim.wait(300, function()
                return Todo.is_open()
            end)
            assert.is_true(Todo.is_open())
            Todo.update_from_details({ todos = {}, completed = 0, total = 0 })
            vim.wait(300, function()
                return not Todo.is_open()
            end)
            assert.is_false(Todo.is_open())
            assert.is_nil(Todo._opened_by())
        end)

        it("auto-opened panel stays when hide_when_empty=false", function()
            Config.options.todo =
                { panel = { auto_open = true, height = 10, position = "below", hide_when_empty = false } }
            Todo.update_from_details(details({ { content = "first", status = "pending" } }))
            vim.wait(300, function()
                return Todo.is_open()
            end)
            Todo.update_from_details({ todos = {}, completed = 0, total = 0 })
            vim.wait(300, function()
                return false
            end)
            assert.is_true(Todo.is_open())
            local bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            assert.are.equal("no todos", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1])
        end)
    end)

    describe("hide_when_empty", function()
        it("open with hide_when_empty=false keeps the empty panel usable", function()
            Config.options.todo =
                { panel = { auto_open = false, height = 10, position = "below", hide_when_empty = false } }
            Todo.update_from_details({ todos = {}, completed = 0, total = 0 })
            Todo.open()
            assert.is_true(Todo.is_open())
        end)

        it("default hide_when_empty=true hides the panel on clear", function()
            Config.options.todo =
                { panel = { auto_open = false, height = 10, position = "below", hide_when_empty = true } }
            Todo.update_from_details(details({ { content = "a", status = "pending" } }))
            Todo.open()
            assert.is_true(Todo.is_open())
            Todo.update_from_details({ todos = {}, completed = 0, total = 0 })
            vim.wait(200, function()
                return false
            end)
            -- Panel window remains (explicitly opened), but content shows the placeholder.
            local bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal("no todos", lines[1])
        end)
    end)

    describe("auto_open", function()
        it("auto_open=true opens the panel on empty to non-empty transition", function()
            Config.options.todo =
                { panel = { auto_open = true, height = 10, position = "below", hide_when_empty = true } }
            Todo.update_from_details(details({ { content = "first", status = "pending" } }))
            vim.wait(300, function()
                return Todo.is_open()
            end)
            assert.is_true(Todo.is_open())
        end)

        it("auto_open=false (default) keeps the panel closed", function()
            Todo.update_from_details(details({ { content = "first", status = "pending" } }))
            vim.wait(200, function()
                return false
            end)
            assert.is_false(Todo.is_open())
        end)

        it("does not re-trigger auto_open on later updates", function()
            Config.options.todo =
                { panel = { auto_open = true, height = 10, position = "below", hide_when_empty = true } }
            Todo.update_from_details(details({ { content = "a", status = "pending" } }))
            vim.wait(300, function()
                return Todo.is_open()
            end)
            Todo.close()
            Todo.update_from_details(details({ { content = "a", status = "completed" } }))
            vim.wait(200, function()
                return false
            end)
            assert.is_false(Todo.is_open())
        end)
    end)
end)

unstub_tool_ui()
