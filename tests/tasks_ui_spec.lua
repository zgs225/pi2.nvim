-- Background tasks panel (:PiTasks) UI — lua/pi/ui/tasks.lua.
--
-- Hermetic: seeds fake tasks through pi.tasks.upsert (no RPC, no spawned
-- processes) and exercises row formatting, ordering, cursor lookup, the
-- stop keymap path (with vim.fn.confirm mocked), open/close/toggle, output
-- windows, the preview float, and the help overlay against real headless
-- windows.

local Tasks = require("pi.tasks")
local Panel = require("pi.ui.tasks")
local Sidebar = require("pi.ui.sidebar")
local Config = require("pi.config")
local Manager = require("pi.sessions.manager")

--- Windows created by a test to stand in for another panel's window;
--- closed in after_each so a failed assertion can't leak a stray split.
---@type integer[]
local fake_wins = {}

--- Create a fake "sessions" window claimed on the current tab's left edge,
--- mimicking the sessions list before the tasks panel opens.
---@return integer
local function claim_fake_sessions()
    vim.cmd("topleft 30vsplit")
    local win = vim.api.nvim_get_current_win()
    fake_wins[#fake_wins + 1] = win
    Sidebar.claim(vim.api.nvim_get_current_tabpage(), "left", "sessions", win)
    return win
end

--- Panel keys currently registered at the current tab's left edge.
---@return table<string, integer>
local function left_edge_keys()
    local keys = {}
    for _, panel in ipairs(Sidebar.panels(vim.api.nvim_get_current_tabpage(), "left")) do
        keys[panel.key] = panel.win
    end
    return keys
end

---@return integer
local function now_ms()
    return vim.uv.now()
end

--- Seed a fake task.
---@param fields table
---@return table
local function seed(fields)
    local task = vim.tbl_extend("force", {
        id = "t1",
        command = "echo hi",
        status = "running",
        start_time = now_ms() - 60_000,
    }, fields)
    Tasks.upsert(task)
    return task
end

--- Press a key in the current window through the real key path.
---@param key string
local function press(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
end

--- Find a window displaying a buffer whose name contains `fragment`.
---@param fragment string
---@return integer?
local function find_win_by_name(fragment)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        if name:find(fragment, 1, true) then
            return win
        end
    end
    return nil
end

--- Find the help float: a pi-dialog buffer showing the panel shortcuts.
---@return integer?, integer?
local function find_help_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "pi-dialog" then
            local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            if text:find("Toggle this help", 1, true) then
                return win, buf
            end
        end
    end
    return nil, nil
end

--- Concatenated buffer lines of the panel open in the current tab.
---@return string
local function panel_text()
    local win = Panel.win(vim.api.nvim_get_current_tabpage())
    local buf = vim.api.nvim_win_get_buf(win)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- Buffer lines of the panel open in the current tab.
---@return string[]
local function panel_lines()
    local win = Panel.win(vim.api.nvim_get_current_tabpage())
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

--- Highlight groups carried by the panel namespace's extmarks on a 1-based
--- buffer line, as a set.
---@param lnum integer
---@return table<string, boolean>
local function hl_on_line(lnum)
    local win = Panel.win(vim.api.nvim_get_current_tabpage())
    local b = vim.api.nvim_win_get_buf(win)
    local groups = {}
    local marks =
        vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace("pi-tasks-list"), 0, -1, { details = true })
    for _, mark in ipairs(marks) do
        if mark[2] == lnum - 1 then
            groups[mark[4].hl_group] = true
        end
    end
    return groups
end

--- Position {lnum, col, len} of the running-row marker whose row contains
--- `fragment` (nil when that row is unmarked).
---@param fragment string
---@return integer[]?
local function marker_pos(fragment)
    local win = Panel.win(vim.api.nvim_get_current_tabpage())
    local lines = panel_lines()
    local matches = vim.api.nvim_win_call(win, function()
        return vim.fn.getmatches()
    end)
    for _, m in ipairs(matches) do
        if m.group == "PiTasksListCurrent" then
            for _, pos in pairs(m) do
                if type(pos) == "table" and lines[pos[1]] and lines[pos[1]]:find(fragment, 1, true) then
                    return pos
                end
            end
        end
    end
    return nil
end

--- Line numbers (1-based) of rows whose text contains `fragment`.
---@param fragment string
---@return table<integer, boolean>
local function marked_lines(fragment)
    local win = Panel.win(vim.api.nvim_get_current_tabpage())
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    local hits = {}
    for lnum, line in ipairs(lines) do
        if line:find(fragment, 1, true) then
            hits[lnum] = true
        end
    end
    local matches = vim.api.nvim_win_call(win, function()
        return vim.fn.getmatches()
    end)
    local marked = {}
    for _, m in ipairs(matches) do
        if m.group == "PiTasksListCurrent" then
            -- getmatches() reports each position as a numbered posN field.
            for _, pos in pairs(m) do
                if type(pos) == "table" and hits[pos[1]] then
                    marked[pos[1]] = true
                end
            end
        end
    end
    return marked
end

describe("tasks panel UI", function()
    before_each(function()
        Tasks._reset()
        Panel._reset()
        Panel._resubscribe()
        Sidebar._reset()
        fake_wins = {}
    end)

    after_each(function()
        -- Close anything the test left open besides the panel itself.
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_is_valid(win) then
                local buf = vim.api.nvim_win_get_buf(win)
                local name = vim.api.nvim_buf_get_name(buf)
                if name:find("pi://task", 1, true) or name:find("pi://tasks", 1, true) then
                    pcall(vim.api.nvim_win_close, win, true)
                end
            end
        end
        Panel._reset()
        Tasks._reset()
        Sidebar._reset()
        for _, win in ipairs(fake_wins) do
            if vim.api.nvim_win_is_valid(win) then
                pcall(vim.api.nvim_win_close, win, true)
            end
        end
        fake_wins = {}
        Config.options.tasks_panel.auto_open = false
    end)

    describe("format_line", function()
        it("formats a running row with dot, spinner, summary and mm:ss subtitle", function()
            local task = seed({ id = "run1", command = "make test" })
            local row = Tasks.build_rows(task.start_time + 65_000)[1]
            local line, chunks = Panel.format_line(row, 0, 80)

            assert.is_truthy(line:find("●", 1, true), "running dot")
            assert.is_truthy(line:find(Panel.spinner_frame(0), 1, true), "spinner frame")
            assert.is_truthy(line:find("make test", 1, true), "command summary")
            assert.is_truthy(line:find("run1 · 01:05", 1, true), "subtitle with live duration")

            assert.are.equal("PiTasksListRunning", chunks[1][3])
            assert.are.equal("PiTasksListSpinner", chunks[2][3])
            -- The subtitle chunk is dimmed metadata.
            local subtitle_hl = chunks[#chunks][3]
            assert.are.equal("PiTasksListDotDim", subtitle_hl)
            -- The dot sits at the left edge.
            assert.are.equal(0, chunks[1][1])
        end)

        it("blinks the running dot on odd ticks", function()
            local task = seed({ id = "run1" })
            local row = Tasks.build_rows(task.start_time + 1000)[1]
            local _, even = Panel.format_line(row, 2, 80)
            local _, odd = Panel.format_line(row, 3, 80)
            assert.are.equal("PiTasksListRunning", even[1][3])
            assert.are.equal("PiTasksListDotDim", odd[1][3])
        end)

        it("renders terminal rows with a dim glyph and relative end time", function()
            local base = now_ms()
            seed({ id = "done1", status = "completed", start_time = base - 300_000, end_time = base - 180_000 })
            local rows = Tasks.build_rows(base)
            local row
            for _, r in ipairs(rows) do
                if r.task.id == "done1" then
                    row = r
                end
            end
            assert.is_not_nil(row)
            local line, chunks = Panel.format_line(row, 0, 80, base)
            assert.is_truthy(line:find("◌", 1, true), "completed uses the dim glyph")
            assert.is_truthy(line:find("done1 · 3m ago", 1, true), "relative end time")
            assert.are.equal("PiTasksListSuccess", chunks[1][3])
        end)

        it("maps failed and stopped statuses to their highlight groups", function()
            local base = now_ms()
            seed({ id = "f1", status = "failed", start_time = base - 10_000, end_time = base - 5000, exit_code = 1 })
            seed({ id = "s1", status = "stopped", start_time = base - 20_000, end_time = base - 15_000 })
            local by_id = {}
            for _, r in ipairs(Tasks.build_rows(base)) do
                by_id[r.task.id] = r
            end
            local _, failed_chunks = Panel.format_line(by_id.f1, 0, 80)
            local _, stopped_chunks = Panel.format_line(by_id.s1, 0, 80)
            assert.are.equal("PiTasksListFailure", failed_chunks[1][3])
            assert.are.equal("PiTasksListStopped", stopped_chunks[1][3])
        end)

        it("truncates the command summary to the indent-adjusted budget", function()
            local task = seed({ id = "run1", command = string.rep("x", 200) })
            local row = Tasks.build_rows(task.start_time + 1000)[1]
            local line, _ = Panel.format_line(row, 0, 40)
            -- Budget = window width - the 2-space row indent.
            assert.is_true(vim.fn.strdisplaywidth(line) <= 38, "content fits width - 2")
            assert.is_true(vim.fn.strdisplaywidth("  " .. line) <= 40, "indented row fits the window width")
            assert.is_truthy(line:find("…", 1, true), "truncated with ellipsis")
        end)
    end)

    describe("render and lookup", function()
        it("renders running tasks first, then newest terminal tasks", function()
            local base = now_ms()
            seed({ id = "old_done", status = "completed", start_time = base - 500_000, end_time = base - 400_000 })
            seed({ id = "new_done", status = "completed", start_time = base - 300_000, end_time = base - 200_000 })
            seed({ id = "run_a", command = "aaa", start_time = base - 50_000 })
            seed({ id = "run_b", command = "bbb", start_time = base - 10_000 })

            Panel.open()
            local rendered = table.concat(
                vim.api.nvim_buf_get_lines(
                    vim.api.nvim_win_get_buf(Panel.win(vim.api.nvim_get_current_tabpage())),
                    0,
                    -1,
                    false
                ),
                "\n"
            )
            local i_run_a = rendered:find("run_a", 1, true)
            local i_run_b = rendered:find("run_b", 1, true)
            local i_new = rendered:find("new_done", 1, true)
            local i_old = rendered:find("old_done", 1, true)
            assert.is_not_nil(i_run_a)
            assert.is_not_nil(i_run_b)
            assert.is_not_nil(i_new)
            assert.is_not_nil(i_old)
            assert.is_true(i_run_a < i_run_b, "running sorted by start_time ascending")
            assert.is_true(i_run_b < i_new, "running before terminal")
            assert.is_true(i_new < i_old, "terminal sorted by end_time descending")
        end)

        it("marks row highlights with the contract highlight group names", function()
            local base = now_ms()
            seed({ id = "run1", command = "make" })
            seed({ id = "f1", status = "failed", start_time = base - 10_000, end_time = base - 5000, exit_code = 1 })
            Panel.open()

            local buf = vim.api.nvim_win_get_buf(Panel.win(vim.api.nvim_get_current_tabpage()))
            local groups = {}
            for _, mark in
                ipairs(
                    vim.api.nvim_buf_get_extmarks(
                        buf,
                        vim.api.nvim_create_namespace("pi-tasks-list"),
                        0,
                        -1,
                        { details = true }
                    )
                )
            do
                groups[mark[4].hl_group] = true
            end
            assert.is_truthy(groups.PiTasksListRunning, "running dot group")
            assert.is_truthy(groups.PiTasksListSpinner, "running spinner group")
            assert.is_truthy(groups.PiTasksListFailure, "failed dot group")
            assert.is_truthy(groups.PiTasksListDotDim, "subtitle dim group")
        end)

        it("renders a blank/title/blank header with running and finished counts", function()
            local base = now_ms()
            seed({ id = "run1", command = "make test", start_time = base - 50_000 })
            seed({ id = "run2", command = "make lint", start_time = base - 40_000 })
            seed({ id = "done1", status = "completed", start_time = base - 300_000, end_time = base - 200_000 })
            seed({ id = "fail1", status = "failed", start_time = base - 10_000, end_time = base - 5000, exit_code = 1 })

            Panel.open()
            local lines = panel_lines()
            assert.are.equal("", lines[1], "leading blank spacer")
            assert.are.equal("  Tasks · 2 running · 2 finished", lines[2])
            assert.is_truthy(hl_on_line(2).PiTasksListDotDim, "title renders dimmed")
            assert.are.equal("", lines[3], "blank spacer between title and rows")
            -- Rows start after the 3-line header and carry the 2-space indent.
            assert.are.equal("  ", lines[4]:sub(1, 2), "first row indented by 2")
            assert.is_truthy(lines[4]:find("run1", 1, true), "first running row at line 4")
        end)

        it("writes zero running counts when every task has finished", function()
            local base = now_ms()
            seed({ id = "done1", status = "completed", start_time = base - 300_000, end_time = base - 200_000 })
            seed({ id = "stop1", status = "stopped", start_time = base - 20_000, end_time = base - 15_000 })

            Panel.open()
            assert.are.equal("  Tasks · 0 running · 2 finished", panel_lines()[2])
        end)

        it("resolves the row under the cursor past the title header", function()
            local base = now_ms()
            seed({ id = "first", command = "one", start_time = base - 30_000 })
            seed({ id = "second", command = "two", start_time = base - 20_000 })
            Panel.open()
            local win = Panel.win(vim.api.nvim_get_current_tabpage())
            vim.api.nvim_set_current_win(win)
            -- The header block occupies lines 1-3, so rows start at line 4.
            vim.api.nvim_win_set_cursor(win, { 4, 0 })
            local row, task = Panel._row_task_under_cursor()
            assert.is_not_nil(row)
            assert.are.equal("first", task.id)
            vim.api.nvim_win_set_cursor(win, { 5, 0 })
            row, task = Panel._row_task_under_cursor()
            assert.is_not_nil(row)
            assert.are.equal("second", task.id)
            -- Blank spacer and title line map to no row.
            vim.api.nvim_win_set_cursor(win, { 1, 0 })
            row, task = Panel._row_task_under_cursor()
            assert.is_nil(row)
            assert.is_nil(task)
            vim.api.nvim_win_set_cursor(win, { 2, 0 })
            row, task = Panel._row_task_under_cursor()
            assert.is_nil(row)
            assert.is_nil(task)
        end)

        it("indents rows and shifts their chunks and marker right by 2", function()
            seed({ id = "run1", command = "make test" })
            Panel.open()
            local lines = panel_lines()
            assert.are.equal(4, #lines)
            assert.are.equal("  ", lines[4]:sub(1, 2), "row indented by 2")

            -- Dot extmark: buffer line 4 → 0-based row 3, dot at byte 2.
            local win = Panel.win(vim.api.nvim_get_current_tabpage())
            local dot_mark
            for _, mark in
                ipairs(
                    vim.api.nvim_buf_get_extmarks(
                        vim.api.nvim_win_get_buf(win),
                        vim.api.nvim_create_namespace("pi-tasks-list"),
                        0,
                        -1,
                        { details = true }
                    )
                )
            do
                if mark[2] == 3 and mark[3] == 2 then
                    dot_mark = mark
                end
            end
            assert.is_not_nil(dot_mark, "dot extmark rendered after the indent")

            -- Window marker follows the same offset: line 4, 1-based col 3.
            local pos = marker_pos("make test")
            assert.is_not_nil(pos, "running row marked")
            assert.are.equal(4, pos[1], "marker on the first row line")
            assert.are.equal(3, pos[2], "marker on the indented dot")
        end)

        it("shows a dimmed no-tasks placeholder under a count-free title", function()
            Panel.open()
            local lines = panel_lines()
            assert.are.equal(4, #lines)
            assert.are.equal("", lines[1])
            assert.are.equal("  Tasks", lines[2], "title carries no counts without tasks")
            assert.is_nil(lines[2]:find("·", 1, true), "no counts appended")
            assert.are.equal("", lines[3])
            assert.are.equal("  no tasks", lines[4])
            assert.is_truthy(hl_on_line(4).PiTasksListDotDim, "placeholder renders dimmed")
        end)
    end)

    describe("per-session view", function()
        it("renders only the current session's rows by default", function()
            seed({ id = "mine", command = "mine cmd", session_id = "sess-1", tab = 1 })
            seed({ id = "theirs", command = "theirs cmd", session_id = "sess-2", tab = 2 })
            Panel._set_session_resolver(function()
                return "sess-1"
            end)

            Panel.open()
            local text = panel_text()
            assert.is_truthy(text:find("mine cmd", 1, true))
            assert.is_nil(text:find("theirs cmd", 1, true), "foreign session rows hidden by default")
        end)

        it("A toggles between the current-session and the all-tasks view", function()
            seed({ id = "mine", command = "mine cmd", session_id = "sess-1", tab = 1 })
            seed({ id = "theirs", command = "theirs cmd", session_id = "sess-2", tab = 2 })
            Panel._set_session_resolver(function()
                return "sess-1"
            end)

            Panel.open()
            assert.is_false(Panel._show_all())
            press("A")
            assert.is_true(Panel._show_all())
            local text = panel_text()
            assert.is_truthy(text:find("mine cmd", 1, true))
            assert.is_truthy(text:find("theirs cmd", 1, true), "all view lists every task")
            press("A")
            assert.is_false(Panel._show_all())
            text = panel_text()
            assert.is_truthy(text:find("mine cmd", 1, true))
            assert.is_nil(text:find("theirs cmd", 1, true), "second A returns to the session view")
        end)

        it("dims foreign rows and prefixes their subtitle with #tab in the all view", function()
            seed({ id = "mine", command = "mine cmd", session_id = "sess-1", tab = 1 })
            seed({ id = "theirs", command = "theirs cmd", session_id = "sess-2", tab = 2 })
            Panel._set_session_resolver(function()
                return "sess-1"
            end)

            Panel.open()
            press("A")
            assert.is_truthy(panel_text():find("#2 · theirs", 1, true), "foreign subtitle carries the #tab prefix")

            local mine_row, theirs_row
            for _, r in ipairs(Panel._rows()) do
                if r.task.id == "mine" then
                    mine_row = r
                elseif r.task.id == "theirs" then
                    theirs_row = r
                end
            end
            assert.is_not_nil(mine_row)
            assert.is_not_nil(theirs_row)
            -- Even tick: the running dot is bright, so the only dim command
            -- chunk belongs to the foreign row.
            local _, mine_chunks = Panel.format_line(mine_row, 0, 80, nil, "sess-1")
            local _, theirs_chunks = Panel.format_line(theirs_row, 0, 80, nil, "sess-1")
            assert.are.equal("Normal", mine_chunks[3][3])
            assert.are.equal("PiTasksListDotDim", theirs_chunks[3][3], "foreign command chunk renders dimmed")
            local theirs_line = Panel.format_line(theirs_row, 0, 80, nil, "sess-1")
            assert.is_truthy(theirs_line:find("#2 · theirs", 1, true))
        end)

        it("marks only the current session's running rows", function()
            seed({ id = "mine", command = "mine cmd", session_id = "sess-1", tab = 1 })
            seed({ id = "theirs", command = "theirs cmd", session_id = "sess-2", tab = 2 })
            Panel._set_session_resolver(function()
                return "sess-1"
            end)

            Panel.open()
            press("A")
            assert.is_truthy(next(marked_lines("mine cmd")), "current-session row marked")
            local marked = marked_lines("theirs cmd")
            assert.is_nil(next(marked), "foreign running row left unmarked")
        end)

        it("falls back to all tasks and marks every running row when the tab has no session", function()
            seed({ id = "one", command = "one cmd", session_id = "sess-1", tab = 1 })
            seed({ id = "two", command = "two cmd", session_id = "sess-2", tab = 2 })
            Panel._set_session_resolver(function()
                return nil
            end)

            Panel.open()
            local text = panel_text()
            assert.is_truthy(text:find("one cmd", 1, true))
            assert.is_truthy(text:find("two cmd", 1, true), "no session: every task shown")
            assert.is_truthy(next(marked_lines("one cmd")), "running row marked")
            assert.is_truthy(next(marked_lines("two cmd")), "no session: every running row marked")
        end)
    end)

    describe("open/close/toggle", function()
        it("opens a side window on the shared buffer and reports focus", function()
            Panel.open()
            local win = Panel.win(vim.api.nvim_get_current_tabpage())
            assert.is_not_nil(win)
            assert.is_true(vim.api.nvim_win_is_valid(win))
            local buf = vim.api.nvim_win_get_buf(win)
            assert.are.equal("pi-tasks", vim.bo[buf].filetype)
            local name = vim.api.nvim_buf_get_name(buf)
            assert.is_truthy(name:find("pi://tasks", 1, true))
            assert.is_true(Panel.has_focus())
            assert.is_true(vim.wo[win].cursorline)
            assert.is_false(vim.wo[win].number)
        end)

        it("toggle closes an open panel and reopens a closed one", function()
            Panel.toggle()
            assert.is_not_nil(Panel.win(vim.api.nvim_get_current_tabpage()))

            Panel.toggle()
            assert.is_nil(Panel.win(vim.api.nvim_get_current_tabpage()))

            Panel.toggle()
            assert.is_not_nil(Panel.win(vim.api.nvim_get_current_tabpage()))
        end)

        it("focuses an already-open panel window instead of stacking", function()
            Panel.open()
            local first = Panel.win(vim.api.nvim_get_current_tabpage())
            vim.cmd("wincmd p")
            Panel.open()
            assert.are.equal(first, Panel.win(vim.api.nvim_get_current_tabpage()))
            assert.are.equal(first, vim.api.nvim_get_current_win())
        end)
    end)

    describe("auto_close", function()
        --- Feed a bg-task lifecycle event through the session manager's real
        --- event path for a fake session attached to `tab`.
        ---@param tab pi.TabId
        ---@param kind string
        ---@param task_id string
        local function feed(tab, kind, task_id)
            Manager.handle_event({ id = "sess-auto", attached_tab = tab }, {
                type = "message_start",
                message = {
                    role = "custom",
                    customType = "pi2_bg_task",
                    details = { kind = kind, taskId = task_id, command = "sleep 1", pid = 4242 },
                },
            })
        end

        local function wait_closed(tab)
            vim.wait(500, function()
                return Panel.win(tab) == nil
            end, 10)
        end

        it("closes the panel when the session's last running task finishes", function()
            local tab = vim.api.nvim_get_current_tabpage()
            feed(tab, "started", "ac1")
            Panel.open()
            assert.is_not_nil(Panel.win(tab))
            feed(tab, "completed", "ac1")
            vim.wait(100)
            -- Focus sits in the panel right after open: the close defers.
            assert.is_not_nil(Panel.win(tab), "close deferred while the panel has focus")
            vim.cmd("wincmd p")
            wait_closed(tab)
            assert.is_nil(Panel.win(tab), "panel auto-closed after focus left")
        end)

        it("waits for every running task before closing", function()
            local tab = vim.api.nvim_get_current_tabpage()
            feed(tab, "started", "ac1")
            feed(tab, "started", "ac2")
            Panel.open()
            feed(tab, "completed", "ac1")
            vim.wait(100)
            assert.is_not_nil(Panel.win(tab), "one task still running keeps the panel open")
            feed(tab, "failed", "ac2")
            vim.wait(100)
            assert.is_not_nil(Panel.win(tab), "close still deferred while focused")
            vim.cmd("wincmd p")
            wait_closed(tab)
            assert.is_nil(Panel.win(tab), "panel closes once all tasks finished")
        end)

        it("defers while focused and closes after focus leaves", function()
            local tab = vim.api.nvim_get_current_tabpage()
            feed(tab, "started", "ac1")
            Panel.open()
            vim.api.nvim_set_current_win(Panel.win(tab))
            feed(tab, "completed", "ac1")
            vim.wait(100)
            assert.is_not_nil(Panel.win(tab), "focused panel is not yanked")
            vim.cmd("wincmd p")
            wait_closed(tab)
            assert.is_nil(Panel.win(tab), "deferred close flushed after focus left")
        end)

        it("treats an output view as focused", function()
            local out = vim.api.nvim_create_buf(false, true)
            vim.bo[out].filetype = "pi-task-output"
            vim.api.nvim_set_current_buf(out)
            assert.is_true(Panel.has_focus(), "reading an output view counts as looking at the panel")
        end)
    end)

    describe("registry merge", function()
        --- Feed a bg-task lifecycle event through the session manager's real
        --- event path for a fake session attached to the current tab.
        ---@param details table
        local function feed(details)
            Manager.handle_event({ id = "sess-merge", attached_tab = vim.api.nvim_get_current_tabpage() }, {
                type = "message_start",
                message = {
                    role = "custom",
                    customType = "pi2_bg_task",
                    timestamp = 1_700_000_000_000,
                    details = details,
                },
            })
        end

        it("merges the full completion payload into a synthesized task", function()
            feed({
                kind = "completed",
                taskId = "m1",
                command = "make build",
                pid = 777,
                outputFile = "/tmp/m1.log",
                exitCode = 0,
                signal = "SIGTERM",
            })
            local task = Tasks.get("m1")
            assert.is_not_nil(task)
            assert.are.equal("completed", task.status)
            assert.are.equal("make build", task.command)
            assert.are.equal(777, task.pid)
            assert.are.equal("/tmp/m1.log", task.output_file)
            assert.are.equal(0, task.exit_code)
            assert.are.equal("SIGTERM", task.signal)
        end)

        it("falls back to exit 1 when a failed event carries a JSON-null exitCode", function()
            feed({ kind = "failed", taskId = "m2", exitCode = vim.NIL, signal = nil })
            assert.are.equal(1, Tasks.get("m2").exit_code)
        end)

        it("still merges a stopped payload after a local mark_stopped", function()
            feed({ kind = "started", taskId = "m3", command = "sleep 1" })
            local local_end = now_ms() - 1_000
            assert.is_true(Tasks.mark_stopped("m3", local_end))
            feed({
                kind = "stopped",
                taskId = "m3",
                pid = 5,
                signal = "SIGTERM",
                exitCode = vim.NIL,
            })
            local task = Tasks.get("m3")
            assert.are.equal("stopped", task.status)
            assert.are.equal("SIGTERM", task.signal)
            assert.is_nil(task.exit_code)
            assert.are.equal(5, task.pid)
            assert.are.equal(local_end, task.end_time, "local mark_stopped end_time is preserved")
        end)
    end)

    describe("close_tab", function()
        it("closes another tab's panel without stealing focus", function()
            Panel.open()
            local tab = vim.api.nvim_get_current_tabpage()
            local panel_win = Panel.win(tab)
            assert.is_not_nil(panel_win)
            vim.cmd("tabnew")
            local other = vim.api.nvim_get_current_tabpage()

            Panel.close_tab(tab)

            assert.is_nil(Panel.win(tab))
            assert.is_false(vim.api.nvim_win_is_valid(panel_win))
            assert.are.equal(other, vim.api.nvim_get_current_tabpage(), "current tabpage untouched")
            assert.are.equal(0, #Sidebar.panels(tab, "left"), "sidebar claim released")
            vim.cmd("tabclose!")
        end)

        it("is a no-op for a tab without a panel", function()
            Panel.close_tab(424242)
        end)
    end)

    describe("sidebar stacking", function()
        it("claims the left edge while open and releases it on close and toggle", function()
            Panel.open()
            local tasks_win = Panel.win(vim.api.nvim_get_current_tabpage())
            assert.is_not_nil(tasks_win)
            assert.are.equal(tasks_win, left_edge_keys().tasks, "open panel registered on the left edge")

            Panel.close()
            assert.is_nil(left_edge_keys().tasks, "close releases the claim")

            Panel.open()
            assert.is_not_nil(left_edge_keys().tasks)
            Panel.toggle()
            assert.is_nil(Panel.win(vim.api.nvim_get_current_tabpage()))
            assert.is_nil(left_edge_keys().tasks, "toggle close releases the claim too")
        end)

        it("splits into an existing sessions column instead of opening a new one", function()
            local sess_win = claim_fake_sessions()

            Panel.open()
            local tasks_win = Panel.win(vim.api.nvim_get_current_tabpage())
            assert.is_not_nil(tasks_win)
            assert.are_not.equal(sess_win, tasks_win)

            -- Same column: identical left position and width (the split
            -- stacks the new window above the sessions window, so row
            -- starts differ by construction).
            local sess_pos = vim.api.nvim_win_get_position(sess_win)
            local tasks_pos = vim.api.nvim_win_get_position(tasks_win)
            assert.are.equal(sess_pos[2], tasks_pos[2], "same column: no second sidebar column")
            assert.are.equal(
                vim.api.nvim_win_get_width(sess_win),
                vim.api.nvim_win_get_width(tasks_win),
                "in-column split inherits the column width"
            )

            -- Both panels are claimed and restack divides the column height.
            local keys = left_edge_keys()
            assert.are.equal(sess_win, keys.sessions)
            assert.are.equal(tasks_win, keys.tasks)
            local budget = vim.o.lines - vim.o.cmdheight - 2
            assert.are.equal(
                budget,
                vim.api.nvim_win_get_height(sess_win) + vim.api.nvim_win_get_height(tasks_win),
                "restack splits the column height between the two panels"
            )
            assert.is_true(vim.wo[sess_win].winfixheight)
            assert.is_true(vim.wo[tasks_win].winfixheight)

            -- Closing tasks leaves the sessions panel registered and expands it.
            Panel.close()
            keys = left_edge_keys()
            assert.is_nil(keys.tasks)
            assert.are.equal(sess_win, keys.sessions)
            assert.are.equal(vim.o.lines - vim.o.cmdheight - 1, vim.api.nvim_win_get_height(sess_win))
        end)
    end)

    describe("auto_open", function()
        --- Feed a bg-task "started" custom message through the session
        --- manager's real event path for a fake session attached to `tab`.
        ---@param tab pi.TabId
        ---@param kind string
        local function feed_bg_event(tab, kind)
            Manager.handle_event({ id = "sess-auto", attached_tab = tab }, {
                type = "message_start",
                message = {
                    role = "custom",
                    customType = "pi2_bg_task",
                    details = { kind = kind, taskId = "auto1", command = "sleep 1", pid = 4242 },
                },
            })
        end

        it("defaults to false in the config", function()
            assert.is_false(Config.options.tasks_panel.auto_open)
        end)

        it("opens the panel when a task starts in the current tab", function()
            Config.options.tasks_panel.auto_open = true
            local tab = vim.api.nvim_get_current_tabpage()
            feed_bg_event(tab, "started")
            vim.wait(500, function()
                return Panel.win(tab) ~= nil
            end, 10)
            assert.is_not_nil(Panel.win(tab), "panel auto-opened for a started task")
            Panel.close()
        end)

        it("stays closed while auto_open is disabled", function()
            Config.options.tasks_panel.auto_open = false
            local tab = vim.api.nvim_get_current_tabpage()
            feed_bg_event(tab, "started")
            vim.wait(100)
            assert.is_nil(Panel.win(tab), "disabled auto_open never opens the panel")
        end)

        it("ignores a task started for another tab", function()
            Config.options.tasks_panel.auto_open = true
            local cur = vim.api.nvim_get_current_tabpage()
            vim.cmd("tabnew")
            local other = vim.api.nvim_get_current_tabpage()
            vim.cmd("tabprevious")
            assert.are_not.equal(cur, other)

            feed_bg_event(other, "started")
            vim.wait(100)
            assert.is_nil(Panel.win(cur), "no auto-open in the current tab")
            assert.is_nil(Panel.win(other), "no auto-open for the foreign tab either")

            vim.api.nvim_set_current_tabpage(other)
            vim.cmd("tabclose!")
        end)

        it("ignores non-started bg-task events", function()
            Config.options.tasks_panel.auto_open = true
            local tab = vim.api.nvim_get_current_tabpage()
            feed_bg_event(tab, "completed")
            vim.wait(100)
            assert.is_nil(Panel.win(tab), "terminal events do not auto-open")
        end)
    end)

    describe("stop key (x)", function()
        it("confirms, marks the task stopped, and signals the pid", function()
            seed({ id = "run1", pid = 987_654_321 })
            Panel.open()
            vim.api.nvim_set_current_win(Panel.win(vim.api.nvim_get_current_tabpage()))

            local orig_confirm = vim.fn.confirm
            vim.fn.confirm = function()
                return 1 -- &Yes
            end
            press("x")
            vim.fn.confirm = orig_confirm

            local stopped = Tasks.get("run1")
            assert.are.equal("stopped", stopped.status)
            assert.is_not_nil(stopped.end_time)
        end)

        it("keeps the task running when the confirmation is declined", function()
            seed({ id = "run1", pid = 987_654_321 })
            Panel.open()
            vim.api.nvim_set_current_win(Panel.win(vim.api.nvim_get_current_tabpage()))

            local orig_confirm = vim.fn.confirm
            vim.fn.confirm = function()
                return 2 -- &No
            end
            press("x")
            vim.fn.confirm = orig_confirm

            assert.are.equal("running", Tasks.get("run1").status)
        end)

        it("binds x to the stop action with a description", function()
            Panel.open()
            local map = vim.fn.maparg("x", "n", false, true)
            assert.are.equal(1, map.buffer)
            assert.are.equal("Stop the task under the cursor", map.desc)
        end)

        it("does not bind a delete key", function()
            Panel.open()
            local map = vim.fn.maparg("d", "n", false, true)
            assert.are_not.equal(1, map.buffer)
        end)
    end)

    describe("task output", function()
        it("<CR> opens the output in a vsplit without focusing it; a focuses it", function()
            local path = vim.fn.tempname()
            local fifty = {}
            for i = 1, 50 do
                fifty[i] = tostring(i)
            end
            vim.fn.writefile(fifty, path)
            seed({ id = "run1", output_file = path })
            Panel.open()
            vim.api.nvim_set_current_win(Panel.win(vim.api.nvim_get_current_tabpage()))
            local list_win = vim.api.nvim_get_current_win()

            press("<CR>")
            local out_win = find_win_by_name("pi://task-output/run1")
            assert.is_not_nil(out_win)
            assert.are.equal(list_win, vim.api.nvim_get_current_win(), "o/<CR> keeps focus on the list")
            local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(out_win), 0, -1, false)
            assert.are.equal(50, #lines)
            -- Each open creates a fresh output window: close the first so the
            -- focus assertion below sees exactly one.
            vim.api.nvim_win_close(out_win, true)

            press("a")
            out_win = find_win_by_name("pi://task-output/run1")
            assert.is_not_nil(out_win)
            assert.are.equal(out_win, vim.api.nvim_get_current_win(), "a focuses the output window")

            vim.fn.delete(path)
        end)

        it("p toggles a focusable centered preview float with a header and output tail", function()
            local path = vim.fn.tempname()
            local lines = {}
            for i = 1, 300 do
                lines[i] = "line " .. i
            end
            vim.fn.writefile(lines, path)
            seed({ id = "run1", command = "make test", output_file = path })
            Panel.open()
            vim.api.nvim_set_current_win(Panel.win(vim.api.nvim_get_current_tabpage()))

            press("p")
            local preview = find_win_by_name("pi://task-preview/run1")
            assert.is_not_nil(preview)
            local cfg = vim.api.nvim_win_get_config(preview)
            assert.is_true(cfg.focusable, "preview is focusable so it can be scrolled")
            assert.is_not_nil(cfg.border, "preview has a border")
            local title = type(cfg.title) == "table" and cfg.title[1][1] or tostring(cfg.title)
            assert.is_truthy(title:find("run1", 1, true))
            local buf_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview), 0, -1, false)
            -- Header: `$ command`, blank, id/status line, duration, output path,
            -- blank; the 300-line file fits under the 1000-line cap in full.
            assert.are.equal("$ make test", buf_lines[1])
            assert.is_truthy(buf_lines[3]:find("run1", 1, true), "metadata line carries the id")
            assert.is_truthy(buf_lines[3]:find("running", 1, true), "metadata line carries the status")
            assert.are.equal(6 + 300, #buf_lines, "header plus the full output tail")
            assert.are.equal("line 300", buf_lines[#buf_lines])

            -- Preview float is per list window: toggle the same key to close.
            vim.api.nvim_set_current_win(Panel.win(vim.api.nvim_get_current_tabpage()))
            press("p")
            assert.is_nil(find_win_by_name("pi://task-preview/run1"))

            vim.fn.delete(path)
        end)

        it("p renders a metadata header for a finished task and never polls", function()
            local path = vim.fn.tempname()
            vim.fn.writefile({ "hello", "world" }, path)
            local start = now_ms() - 12_000
            seed({
                id = "done1",
                command = "make build",
                status = "completed",
                exit_code = 0,
                pid = 4321,
                start_time = start,
                end_time = start + 12_000,
                output_file = path,
            })
            Panel.open()
            vim.api.nvim_set_current_win(Panel.win(vim.api.nvim_get_current_tabpage()))

            press("p")
            local preview = find_win_by_name("pi://task-preview/done1")
            assert.is_not_nil(preview)
            local b = vim.api.nvim_win_get_buf(preview)
            local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
            assert.are.equal("$ make build", lines[1])
            assert.is_truthy(lines[3]:find("done1", 1, true), "meta line carries the id")
            assert.is_truthy(lines[3]:find("done (exit 0)", 1, true), "meta line carries the exit status")
            assert.is_truthy(lines[3]:find("pid 4321", 1, true), "meta line carries the pid")
            local text = table.concat(lines, "\n")
            assert.is_truthy(text:find(path, 1, true), "meta header shows the output path")
            assert.are.equal("world", lines[#lines], "tail rendered under the header")

            -- A terminal task never arms the poll: even appending to the file
            -- leaves the buffer byte-for-byte unchanged.
            local frozen = table.concat(lines, "\n")
            local f = io.open(path, "a")
            assert.is_not_nil(f)
            f:write("late line\n")
            f:close()
            vim.wait(1500, function()
                return false
            end, 50)
            local after = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
            assert.are.equal(frozen, after, "finished preview is static")

            vim.fn.delete(path)
        end)

        it("renders a stopped task's signal in the preview header", function()
            local path = vim.fn.tempname()
            vim.fn.writefile({ "bye" }, path)
            seed({
                id = "stop1",
                command = "sleep 100",
                status = "stopped",
                pid = 9,
                signal = "SIGTERM",
                start_time = now_ms() - 3_000,
                end_time = now_ms() - 1_000,
                output_file = path,
            })
            Panel.open()
            vim.api.nvim_set_current_win(Panel.win(vim.api.nvim_get_current_tabpage()))

            press("p")
            local preview = find_win_by_name("pi://task-preview/stop1")
            assert.is_not_nil(preview)
            local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview), 0, -1, false)
            assert.is_truthy(lines[3]:find("stopped (signal SIGTERM)", 1, true), "header shows the stop signal")

            vim.fn.delete(path)
        end)

        it("p follows a running task's output live and freezes once it settles", function()
            local path = vim.fn.tempname()
            vim.fn.writefile({ "first" }, path)
            local start = now_ms() - 5_000
            seed({
                id = "live1",
                command = "tail -f log",
                status = "running",
                start_time = start,
                output_file = path,
            })
            Panel.open()
            vim.api.nvim_set_current_win(Panel.win(vim.api.nvim_get_current_tabpage()))

            press("p")
            local preview = find_win_by_name("pi://task-preview/live1")
            assert.is_not_nil(preview)

            -- Append a line; the 500ms poll should pick it up.
            local f = io.open(path, "a")
            assert.is_not_nil(f)
            f:write("appended live\n")
            f:close()

            local followed = vim.wait(2000, function()
                if not vim.api.nvim_win_is_valid(preview) then
                    return true
                end
                local ls = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview), 0, -1, false)
                return ls[#ls] == "appended live"
            end, 50)
            assert.is_true(followed, "poll picked up the appended output")
            local followed_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview), 0, -1, false)
            assert.are.equal(#followed_lines, vim.api.nvim_win_get_cursor(preview)[1], "cursor follows the tail")

            -- Settle the task: the header flips to done, then the poll stops.
            Tasks.upsert({
                id = "live1",
                command = "tail -f log",
                status = "completed",
                start_time = start,
                end_time = now_ms(),
                exit_code = 0,
                output_file = path,
            })
            local updated = vim.wait(2000, function()
                local ls = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview), 0, -1, false)
                return ls[3] ~= nil and ls[3]:find("done (exit 0)", 1, true) ~= nil
            end, 50)
            assert.is_true(updated, "terminal render shows the exit status")

            -- With the poll stopped the buffer no longer changes.
            local frozen =
                table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview), 0, -1, false), "\n")
            vim.fn.writefile({ "first", "appended live", "after settle" }, path)
            vim.wait(1500, function()
                return false
            end, 50)
            local after =
                table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview), 0, -1, false), "\n")
            assert.are.equal(frozen, after, "content frozen once the task settles")

            vim.fn.delete(path)
        end)

        it("keeps a scrolled cursor in place on live updates", function()
            local path = vim.fn.tempname()
            vim.fn.writefile({ "first", "second", "third" }, path)
            local start = now_ms() - 5_000
            seed({
                id = "scroll1",
                command = "tail -f log",
                status = "running",
                start_time = start,
                output_file = path,
            })
            Panel.open()
            vim.api.nvim_set_current_win(Panel.win(vim.api.nvim_get_current_tabpage()))

            press("p")
            local preview = find_win_by_name("pi://task-preview/scroll1")
            assert.is_not_nil(preview)

            -- Park the cursor on line 1: the live tail must still refresh
            -- without yanking it back to the bottom.
            vim.api.nvim_win_set_cursor(preview, { 1, 0 })
            local f = io.open(path, "a")
            assert.is_not_nil(f)
            f:write("appended scrolled\n")
            f:close()

            local updated = vim.wait(2000, function()
                local ls = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview), 0, -1, false)
                for _, line in ipairs(ls) do
                    if line == "appended scrolled" then
                        return true
                    end
                end
                return false
            end, 50)
            assert.is_true(updated, "live tail still picked up the new line")
            assert.are.equal(1, vim.api.nvim_win_get_cursor(preview)[1], "scrolled cursor is not pulled to the bottom")

            -- Settle the task so the poll stops before the spec ends.
            Tasks.upsert({
                id = "scroll1",
                command = "tail -f log",
                status = "stopped",
                start_time = start,
                end_time = now_ms(),
                output_file = path,
            })
            vim.wait(1000, function()
                return false
            end, 50)

            vim.fn.delete(path)
        end)
    end)

    describe("help overlay", function()
        it("lists every bound key", function()
            Panel.open()
            press("?")
            local win, buf = find_help_win()
            assert.is_not_nil(win)
            local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            for _, key in ipairs({ "<CR>, o", "a, i", "p", "x", "A", "R", "q", "?" }) do
                assert.is_truthy(text:find(key, 1, true), "help should list " .. key)
            end
            assert.are.equal(8, #Panel._help_entries())
        end)

        it("toggles on a second ?", function()
            Panel.open()
            press("?")
            assert.is_not_nil(find_help_win())
            press("?")
            assert.is_nil(find_help_win())
        end)
    end)

    describe("refresh wiring", function()
        it("redraws from a tasks refresh notification while visible", function()
            Panel.open()
            seed({ id = "late", command = "arrived late" })
            Tasks.request_refresh()
            vim.wait(100, function()
                local win = Panel.win(vim.api.nvim_get_current_tabpage())
                if not win then
                    return false
                end
                local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
                return text:find("arrived late", 1, true) ~= nil
            end)
            local win = Panel.win(vim.api.nvim_get_current_tabpage())
            local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
            assert.is_truthy(text:find("arrived late", 1, true))
        end)

        it("request_refresh coalesces multiple notifications into one render", function()
            Panel.open()
            local renders = 0
            local orig = Panel._render
            Panel._render = function()
                renders = renders + 1
                return orig()
            end
            Tasks.request_refresh()
            Tasks.request_refresh()
            Tasks.request_refresh()
            vim.wait(100)
            Panel._render = orig
            assert.are.equal(1, renders)
        end)
    end)
end)
