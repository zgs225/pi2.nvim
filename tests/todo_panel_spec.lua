-- Unit tests for pi.todo (:PiTodo panel): the details state mirror, panel
-- line building, the pi.ui.sidebar claim (weight/order mapping and stacked
-- geometry), hide_when_empty behavior, and the open/close/is_open
-- bookkeeping (exercised against real headless windows).
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
local Manager = require("pi.sessions.manager")
local Sidebar = require("pi.ui.sidebar")

--- Chat-less fake sessions bound to tabs, so the todo panel's per-session
--- state has a routing session and its viewed-session resolution
--- (manager.get_for_tab) finds it. Keyed by tab handle: each tab gets its own
--- session, like the real manager would.
---@type table<integer, table>
local bound_sessions = {}
local next_fake_id = 0

--- The tab's fake session, creating + binding one on first use.
---@param tab integer
---@return table
local function session_for_tab(tab)
    local session = bound_sessions[tab]
    if not session then
        next_fake_id = next_fake_id + 1
        session = {
            id = "todo-spec-" .. tostring(next_fake_id),
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
        Manager._bind_shim_for_test(session, tab)
        bound_sessions[tab] = session
    end
    return session
end

--- Update the mirror under the current tab's fake session (per-session
--- keying: direct callers must name the routing session).
---@param d table?
local function update(d)
    Todo.update_from_details(d, session_for_tab(vim.api.nvim_get_current_tabpage()))
end

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
        Sidebar._reset()
        Manager._reset()
        bound_sessions = {}
        Config.options = saved_options
    end)

    describe("state mirror", function()
        it("current() is nil before any update", function()
            assert.is_nil(Todo.current())
        end)

        it("stores the latest details", function()
            update(details({ { content = "a", status = "pending" } }))
            local cur = Todo.current()
            assert.is_truthy(cur)
            assert.are.equal(1, cur.total)
            assert.are.equal(0, cur.completed)
            assert.are.equal("a", cur.todos[1].content)
        end)

        it("replaces the list on every update (full-replace semantics)", function()
            update(details({ { content = "a", status = "pending" } }))
            update(details({
                { content = "a", status = "completed" },
                { content = "b", status = "in_progress" },
            }))
            local cur = Todo.current()
            assert.are.equal(2, cur.total)
            assert.are.equal(1, cur.completed)
            assert.are.equal(2, #cur.todos)
        end)

        it("keeps an empty state after a clear (total == 0)", function()
            update(details({ { content = "a", status = "pending" } }))
            update({ todos = {}, completed = 0, total = 0 })
            local cur = Todo.current()
            assert.is_truthy(cur)
            assert.are.equal(0, cur.total)
        end)

        it("ignores malformed details", function()
            update(nil)
            update({})
            update({ nope = true })
            assert.is_nil(Todo.current())
        end)
    end)

    describe("sidebar claim", function()
        --- Registered panels of the current tab's left edge (the default
        --- sessions_list.position, so the edge the panel claims).
        ---@return table[]
        local function panels()
            return Sidebar.panels(vim.api.nvim_get_current_tabpage(), "left")
        end

        it("standalone open claims the edge with the default weight and order", function()
            Todo.open()
            local ps = panels()
            assert.are.equal(1, #ps)
            assert.are.equal("todo", ps[1].key)
            assert.are.equal(Todo.win(vim.api.nvim_get_current_tabpage()), ps[1].win)
            -- height 0.5 (default) maps to weight 1 (f/(1-f), the even
            -- split); position "below" falls through to the ORDER map
            -- entry (todo = 2).
            assert.are.equal(1, ps[1].weight)
            assert.are.equal(2, ps[1].order)
        end)

        it("fractional height maps to weight f/(1-f)", function()
            Config.options.todo =
                { panel = { auto_open = false, height = 0.25, position = "below", hide_when_empty = true } }
            Todo.open()
            assert.are.equal(0.25 / 0.75, panels()[1].weight)
        end)

        it("absolute height maps to a weight normalized against the column budget", function()
            Config.options.todo =
                { panel = { auto_open = false, height = 6, position = "below", hide_when_empty = true } }
            Todo.open()
            local budget = vim.o.lines - vim.o.cmdheight - 2
            assert.are.equal(6 / (budget - 6), panels()[1].weight)
        end)

        it("position=above claims order 0.5 (stacked before sessions)", function()
            Config.options.todo =
                { panel = { auto_open = false, height = 0.5, position = "above", hide_when_empty = true } }
            Todo.open()
            assert.are.equal(0.5, panels()[1].order)
        end)

        it("closing releases the claim", function()
            Todo.open()
            assert.is_true(#panels() > 0)
            Todo.close()
            assert.are.equal(0, #panels())
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
            update({ todos = {}, completed = 0, total = 0 })
            Todo.open()
            assert.is_true(Todo.is_open())
            local bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal("", lines[1])
            assert.are.equal("  no todos", lines[2])
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
            update(details({
                { content = "write code", status = "completed" },
                { content = "run tests", status = "in_progress" },
                { content = "review", status = "pending" },
            }))
            Todo.open()
            local bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            -- DESIGN.md padding: blank spacer, calm header, blank, indented rows.
            assert.are.equal("", lines[1])
            assert.are.equal("  Todo · 1/3 completed", lines[2])
            assert.are.equal("", lines[3])
            assert.are.equal("  ✓ write code", lines[4])
            assert.are.equal("  ◐ run tests", lines[5])
            assert.are.equal("  ○ review", lines[6])
        end)

        it("refresh re-renders after a details update", function()
            Todo.open()
            update(details({ { content = "only item", status = "pending" } }))
            -- update schedules the refresh; pump the event loop.
            vim.wait(200, function()
                return false
            end)
            local bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal("  Todo · 0/1 completed", lines[2])
            assert.are.equal("  ○ only item", lines[4])
        end)
    end)

    describe("stacked layout", function()
        ---@type integer?
        local fake_sess_win

        --- Column budget shared by the stacked windows (pi.ui.sidebar restack
        --- counts one statusline row per stacked window).
        ---@param n integer
        ---@return integer
        local function budget(n)
            return vim.o.lines - vim.o.cmdheight - n
        end

        ---@return table[] registered panels of the current tab's left edge
        local function panels()
            return Sidebar.panels(vim.api.nvim_get_current_tabpage(), "left")
        end

        --- Open a fake sessions column and register it with the sidebar the
        --- way the real sessions list claims it (key "sessions", weight 1):
        --- the todo panel finds its stacking neighbour through the registry,
        --- not through pi.ui.sessions.
        ---@return integer sessions-like window (full-height side column)
        local function open_fake_sessions()
            -- Mimic the real :PiSessions geometry: a full-height side column
            -- (vsplit) that the todo split stacks into as the column's bottom
            -- window — row exchanges during resizes then stay between the two
            -- windows instead of leaking into the neighboring chat column.
            vim.cmd("topleft vsplit")
            local sess = vim.api.nvim_get_current_win()
            local b = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_win_set_buf(sess, b)
            -- Move the rest of the editor into its own column.
            vim.cmd("wincmd j")
            vim.cmd("vsplit")
            fake_sess_win = sess
            Sidebar.claim(vim.api.nvim_get_current_tabpage(), "left", "sessions", sess, { weight = 1 })
            return sess
        end

        before_each(function()
            fake_sess_win = nil
        end)

        after_each(function()
            pcall(Todo.close)
            if fake_sess_win and vim.api.nvim_win_is_valid(fake_sess_win) then
                pcall(vim.api.nvim_win_close, fake_sess_win, true)
            end
        end)

        it("stacks below the sessions window and claims the sidebar registry", function()
            local sess = open_fake_sessions()
            update(details({ { content = "a", status = "pending" } }))
            Todo.open()
            local todo_win = vim.api.nvim_get_current_win()
            assert.are_not.equal(sess, todo_win)
            assert.is_true(vim.wo[todo_win].winfixheight)
            -- Registry: sessions (order 1) first, todo (order 2, default
            -- weight 0.5) after it.
            local ps = panels()
            assert.are.equal(2, #ps)
            assert.are.equal("sessions", ps[1].key)
            assert.are.equal("todo", ps[2].key)
            assert.are.equal(0.5, ps[2].weight)
            -- Geometry: restack divides the column budget by weight (1 : 0.5).
            local total = budget(2)
            local h_sess = vim.fn.winheight(sess)
            local h_todo = vim.fn.winheight(todo_win)
            assert.are.equal(total, h_sess + h_todo)
            assert.is_true(h_sess > h_todo, "sessions keeps the larger share")
            assert.is_true(math.abs(h_todo - total / 3) <= 2, "todo gets its ~0.5 weight share, got " .. h_todo)
            -- The todo panel sits below the sessions window.
            assert.is_true(vim.fn.win_screenpos(sess)[1] < vim.fn.win_screenpos(todo_win)[1])
        end)

        it("ratio override 0.25 maps to a 0.25 claim weight", function()
            Config.options.todo =
                { panel = { auto_open = false, height = 0.25, position = "below", hide_when_empty = true } }
            local sess = open_fake_sessions()
            update(details({ { content = "a", status = "pending" } }))
            Todo.open()
            local todo_win = vim.api.nvim_get_current_win()
            assert.are.equal(0.25, panels()[2].weight)
            -- Weight split 1 : 0.25 — the sessions window keeps the rest.
            local total = budget(2)
            local h_sess = vim.fn.winheight(sess)
            local h_todo = vim.fn.winheight(todo_win)
            assert.are.equal(total, h_sess + h_todo)
            assert.is_true(h_sess > h_todo, "sessions keeps the larger share")
            assert.is_true(math.abs(h_todo - total / 5) <= 2, "todo gets its 0.25 weight share, got " .. h_todo)
        end)

        it("absolute height 6 maps to a normalized claim weight", function()
            Config.options.todo =
                { panel = { auto_open = false, height = 6, position = "below", hide_when_empty = true } }
            local sess = open_fake_sessions()
            update(details({ { content = "a", status = "pending" } }))
            Todo.open()
            local todo_win = vim.api.nvim_get_current_win()
            local total = budget(2)
            -- weight = L / budget against the sessions weight of 1: restack
            -- approximates the pinned line count (within rounding).
            assert.are.equal(6 / total, panels()[2].weight)
            local h_sess = vim.fn.winheight(sess)
            local h_todo = vim.fn.winheight(todo_win)
            local expect = 6 * total / (total + 6)
            assert.are.equal(total, h_sess + h_todo)
            assert.is_true(math.abs(h_todo - expect) <= 2, "todo approximates 6 lines, got " .. h_todo)
        end)

        it("content taller than the panel does not grow it (scrolls instead)", function()
            local sess = open_fake_sessions()
            update(details({
                { content = "a", status = "pending" },
                { content = "b", status = "pending" },
                { content = "c", status = "pending" },
                { content = "d", status = "pending" },
                { content = "e", status = "pending" },
                { content = "f", status = "pending" },
                { content = "g", status = "pending" },
            }))
            Todo.open()
            local todo_win = vim.api.nvim_get_current_win()
            -- 3 header lines + 7 items = 10 rendered lines, but the window is
            -- sized by its claim weight (~a third of the column at the default
            -- 0.5), not by the content — the excess scrolls.
            local total = budget(2)
            local h_todo = vim.fn.winheight(todo_win)
            assert.is_true(math.abs(h_todo - total / 3) <= 2, "sized by claim weight, got " .. h_todo)
            assert.is_true(h_todo < 10, "window stays below the rendered line count, got " .. h_todo)
            assert.are.equal(total, vim.fn.winheight(sess) + h_todo)
        end)

        it("stacks above the sessions window with position=above (order 0.5)", function()
            Config.options.todo =
                { panel = { auto_open = false, height = 0.5, position = "above", hide_when_empty = true } }
            local sess = open_fake_sessions()
            update(details({ { content = "a", status = "pending" } }))
            Todo.open()
            local todo_win = vim.api.nvim_get_current_win()
            -- Registry order puts todo before sessions; the split lands the
            -- window above the anchor.
            local ps = panels()
            assert.are.equal("todo", ps[1].key)
            assert.are.equal(0.5, ps[1].order)
            assert.is_true(vim.fn.win_screenpos(todo_win)[1] < vim.fn.win_screenpos(sess)[1])
        end)

        it("sidebar restack re-asserts the weight split after layout churn", function()
            local sess = open_fake_sessions()
            update(details({ { content = "a", status = "pending" } }))
            Todo.open()
            local todo_win = vim.api.nvim_get_current_win()
            -- Simulate layout churn: grow the panel beyond its target.
            pcall(vim.api.nvim_win_set_height, todo_win, 12)
            Sidebar.restack(vim.api.nvim_get_current_tabpage(), "left")
            local total = budget(2)
            local h_sess = vim.fn.winheight(sess)
            local h_todo = vim.fn.winheight(todo_win)
            assert.are.equal(total, h_sess + h_todo)
            assert.is_true(h_sess > h_todo, "sessions keeps the larger share")
            assert.is_true(
                math.abs(h_todo - total / 3) <= 2,
                "drift corrected back to the weight split, got " .. h_todo
            )
        end)

        it("sidebar restack re-asserts the split after the sessions window is resized", function()
            local sess = open_fake_sessions()
            update(details({ { content = "a", status = "pending" } }))
            Todo.open()
            local todo_win = vim.api.nvim_get_current_win()
            -- Manual resize of the sessions window redistributes the column.
            pcall(vim.api.nvim_win_set_height, sess, 12)
            Sidebar.restack(vim.api.nvim_get_current_tabpage(), "left")
            local total = budget(2)
            local h_sess = vim.fn.winheight(sess)
            local h_todo = vim.fn.winheight(todo_win)
            assert.are.equal(total, h_sess + h_todo)
            assert.is_true(h_sess > h_todo, "sessions keeps the larger share")
            assert.is_true(
                math.abs(h_todo - total / 3) <= 2,
                "drift corrected back to the weight split, got " .. h_todo
            )
        end)
    end)

    describe("per-tab buffers", function()
        it("two tabs with open panels each show their own list (no cross-talk)", function()
            update(details({ { content = "tab one", status = "pending" } }))
            Todo.open()
            local tab1 = vim.api.nvim_get_current_tabpage()
            local win1 = vim.api.nvim_get_current_win()
            local buf1 = vim.api.nvim_win_get_buf(win1)

            vim.cmd("tabnew")
            update(details({ { content = "tab two", status = "pending" } }))
            Todo.open()
            local tab2 = vim.api.nvim_get_current_tabpage()
            local win2 = vim.api.nvim_get_current_win()
            local buf2 = vim.api.nvim_win_get_buf(win2)

            -- Distinct buffers, each showing its own tab's list.
            assert.are_not.equal(buf1, buf2)
            local lines2 = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
            assert.are.equal("  Todo · 0/1 completed", lines2[2])
            assert.are.equal("  ○ tab two", lines2[4])

            -- Back on tab 1: its panel buffer still shows tab one's list.
            vim.api.nvim_set_current_tabpage(tab1)
            local lines1 = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
            assert.are.equal("  Todo · 0/1 completed", lines1[2])
            assert.are.equal("  ○ tab one", lines1[4])

            -- Cleanup: drop both panels, then close the extra tab.
            Todo._reset()
            vim.api.nvim_set_current_tabpage(tab2)
            vim.cmd("tabclose")
        end)

        it("refresh on one tab does not clobber the other tab's buffer", function()
            update(details({ { content = "alpha", status = "pending" } }))
            Todo.open()
            local tab1 = vim.api.nvim_get_current_tabpage()
            local buf1 = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())

            vim.cmd("tabnew")
            update(details({ { content = "beta", status = "in_progress" } }))
            Todo.open()
            local buf2 = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            -- Refresh scheduled by tab 2's update must not rewrite buf1.
            vim.wait(200, function()
                return false
            end)
            vim.api.nvim_set_current_tabpage(tab1)
            local lines1 = vim.api.nvim_buf_get_lines(buf1, 0, -1, false)
            assert.are.equal("  ○ alpha", lines1[4])

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
                { panel = { auto_open = true, height = 0.5, position = "below", hide_when_empty = true } }
            update(details({ { content = "first", status = "pending" } }))
            vim.wait(300, function()
                return Todo.is_open()
            end)
            assert.are.equal("auto", Todo._opened_by())
        end)

        it("auto-opened panel closes when the list clears (hide_when_empty)", function()
            Config.options.todo =
                { panel = { auto_open = true, height = 0.5, position = "below", hide_when_empty = true } }
            update(details({ { content = "first", status = "pending" } }))
            vim.wait(300, function()
                return Todo.is_open()
            end)
            assert.is_true(Todo.is_open())
            update({ todos = {}, completed = 0, total = 0 })
            vim.wait(300, function()
                return not Todo.is_open()
            end)
            assert.is_false(Todo.is_open())
            assert.is_nil(Todo._opened_by())
        end)

        it("auto-opened panel stays when hide_when_empty=false", function()
            Config.options.todo =
                { panel = { auto_open = true, height = 0.5, position = "below", hide_when_empty = false } }
            update(details({ { content = "first", status = "pending" } }))
            vim.wait(300, function()
                return Todo.is_open()
            end)
            update({ todos = {}, completed = 0, total = 0 })
            vim.wait(300, function()
                return false
            end)
            assert.is_true(Todo.is_open())
            local bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            assert.are.equal("  no todos", vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[2])
        end)
    end)

    describe("hide_when_empty", function()
        it("open with hide_when_empty=false keeps the empty panel usable", function()
            Config.options.todo =
                { panel = { auto_open = false, height = 0.5, position = "below", hide_when_empty = false } }
            update({ todos = {}, completed = 0, total = 0 })
            Todo.open()
            assert.is_true(Todo.is_open())
        end)

        it("default hide_when_empty=true hides the panel on clear", function()
            Config.options.todo =
                { panel = { auto_open = false, height = 0.5, position = "below", hide_when_empty = true } }
            update(details({ { content = "a", status = "pending" } }))
            Todo.open()
            assert.is_true(Todo.is_open())
            update({ todos = {}, completed = 0, total = 0 })
            vim.wait(200, function()
                return false
            end)
            -- Panel window remains (explicitly opened), but content shows the placeholder.
            local bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal("  no todos", lines[2])
        end)
    end)

    describe("auto_open", function()
        it("auto_open=true opens the panel on empty to non-empty transition", function()
            Config.options.todo =
                { panel = { auto_open = true, height = 0.5, position = "below", hide_when_empty = true } }
            update(details({ { content = "first", status = "pending" } }))
            vim.wait(300, function()
                return Todo.is_open()
            end)
            assert.is_true(Todo.is_open())
        end)

        it("auto_open=false (default) keeps the panel closed", function()
            update(details({ { content = "first", status = "pending" } }))
            vim.wait(200, function()
                return false
            end)
            assert.is_false(Todo.is_open())
        end)

        it("does not re-trigger auto_open on later updates", function()
            Config.options.todo =
                { panel = { auto_open = true, height = 0.5, position = "below", hide_when_empty = true } }
            update(details({ { content = "a", status = "pending" } }))
            vim.wait(300, function()
                return Todo.is_open()
            end)
            Todo.close()
            update(details({ { content = "a", status = "completed" } }))
            vim.wait(200, function()
                return false
            end)
            assert.is_false(Todo.is_open())
        end)
    end)
end)

unstub_tool_ui()
