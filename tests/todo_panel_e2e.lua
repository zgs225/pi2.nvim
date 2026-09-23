-- Headless e2e for the todo panel (lua/pi/todo/init.lua).
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/todo_panel_e2e.lua
-- Exercises the real pi.todo.tool_ui + pi.ui.sessions accessor:
--   0. winfix preconditions (set number + winfix.setup before any pi window
--      exists) and focus-bounce assertions in 2/3: re-entering the
--      pi-sessions panel must not reset it to user defaults (the reported
--      line-number + dropped winfix* bug)
--   1. manager.update_todo_mirror-equivalent routing through update_from_details
--   2. standalone column open (winfixwidth, sessions_list width)
--   3. stacked layout below a fake registered sessions window (winfixheight,
--      default even 50/50 split, ratio 0.25 override, absolute 6)
--   4. refresh renders new content + re-asserts the configured ratio after a
--      manual resize
--   6. hide_when_empty: cleared list -> manual panel keeps "no todos" placeholder
--   7. replay-style toolResult + non-todo tool gating
--   8. per-tab buffers: two tabs with open panels each show their own list
--   9. opened_by semantics: auto-opened panel closes on clear, manual keeps
--  10. session-tab keying: event routed to the session's tab while another
--      tab is focused; auto-open defers to TabEnter; detached (nil session)
--      writes store under the session, visible in no tab

local Todo = require("pi.todo")
local Manager = require("pi.sessions.manager")
local ToolUi = require("pi.todo.tool_ui")
local SessionList = require("pi.ui.sessions")

local failures = 0
local function check(cond, msg)
    if cond then
        print("PASS: " .. msg)
    else
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end

local function eq(a, b, msg)
    check(vim.deep_equal(a, b), msg .. " (got " .. vim.inspect(a) .. ", want " .. vim.inspect(b) .. ")")
end

local function pump(ms)
    vim.wait(ms or 300, function()
        return false
    end)
end

local saved_todo = vim.deepcopy(require("pi.config").options.todo)
local saved_sl = vim.deepcopy(require("pi.config").options.sessions_list)
require("pi.config").options.todo =
    { panel = { auto_open = true, height = 0.5, position = "below", hide_when_empty = true } }
require("pi.config").options.sessions_list = { position = "left", width = 40 }

-- 0. winfix preconditions ---------------------------------------------------
-- Reported bug: with a user `set number` config, a pi-sessions panel window
-- can match winfix's fingerprint (concealcursor="nvic" inherited from a chat
-- window split, number/relativenumber/cursorline false). The pre-fix
-- allowlist exempted only pi-chat-*, so the next focus-in ran winfix's reset
-- and the sidebar showed line numbers while losing winfixbuf/winfixwidth/
-- winfixheight. winfix.setup() must run before any pi window exists —
-- section 1 below auto-opens the first panel, so arm everything here.
vim.cmd("set number")
check(
    vim.api.nvim_get_option_value("number", { scope = "global" }) == true,
    "precondition: user config `set number` (global number=true) is in effect"
)
-- Global nvic keeps the fingerprint part of the captured user defaults, so
-- even a (pre-fix) reset writes "nvic" back and the bounce below always
-- re-enters a fingerprint-armed panel window.
vim.o.concealcursor = "nvic"
check(
    vim.api.nvim_get_option_value("concealcursor", { scope = "global" }) == "nvic",
    "precondition: global concealcursor armed to nvic"
)
require("pi.ui.winfix").setup()

--- Bounce focus out of a panel window and back, then assert winfix left the
--- panel untouched (the reported bug: focus-in reset pi-sessions to user
--- defaults → line numbers + dropped winfix* pins). Prints the observed
--- options after re-entry so a failure is diagnosable.
---@param panel integer the panel window to bounce back into
---@param label string label prefix for the assertion messages
---@param expect_wfixheight boolean? when set, also assert winfixheight
local function bounce_focus(panel, label, expect_wfixheight)
    -- The panel must be fingerprint-armed at bounce time, otherwise the
    -- assertions below prove nothing about the bug path.
    check(
        vim.wo[panel].concealcursor == "nvic"
            and vim.wo[panel].number == false
            and vim.wo[panel].relativenumber == false
            and vim.wo[panel].cursorline == false,
        label
            .. ": panel carries the winfix fingerprint before bounce (got "
            .. vim.inspect({
                concealcursor = vim.wo[panel].concealcursor,
                number = vim.wo[panel].number,
                relativenumber = vim.wo[panel].relativenumber,
                cursorline = vim.wo[panel].cursorline,
            })
            .. ")"
    )
    local others = vim.tbl_filter(function(w)
        return vim.api.nvim_win_is_valid(w) and w ~= panel
    end, vim.api.nvim_tabpage_list_wins(0))
    check(#others > 0, label .. ": another window exists to bounce focus to")
    vim.api.nvim_set_current_win(others[1])
    vim.api.nvim_set_current_win(panel)
    local opts = {
        number = vim.wo[panel].number,
        relativenumber = vim.wo[panel].relativenumber,
        concealcursor = vim.wo[panel].concealcursor,
        cursorline = vim.wo[panel].cursorline,
        winfixbuf = vim.wo[panel].winfixbuf,
        winfixwidth = vim.wo[panel].winfixwidth,
        winfixheight = vim.wo[panel].winfixheight,
    }
    print(("INFO %s panel options after focus bounce: %s"):format(label, vim.inspect(opts)))
    check(opts.number == false, label .. ": no line numbers after focus bounce (number=false)")
    check(opts.relativenumber == false, label .. ": relativenumber stays false after focus bounce")
    check(opts.concealcursor == "nvic", label .. ": concealcursor=nvic survives focus bounce")
    check(opts.cursorline == false, label .. ": cursorline stays false after focus bounce")
    check(opts.winfixbuf == true, label .. ": winfixbuf survives focus bounce")
    check(opts.winfixwidth == true, label .. ": winfixwidth survives focus bounce")
    if expect_wfixheight ~= nil then
        check(opts.winfixheight == expect_wfixheight, label .. ": winfixheight survives focus bounce")
    end
end

-- 1. Tool name routing through the manager hook -----------------------------
check(ToolUi.is_todo_tool("todo_write") == true, "is_todo_tool(todo_write) is true")
check(ToolUi.is_todo_tool("read") == false, "is_todo_tool(read) is false")

local live_result = {
    details = {
        todos = {
            { content = "write module", status = "completed" },
            { content = "write tests", status = "in_progress" },
            { content = "review", status = "pending" },
        },
        completed = 1,
        total = 3,
    },
}
local d = ToolUi.result_details(live_result)
eq({ completed = d.completed, total = d.total }, { completed = 1, total = 3 }, "result_details parses live result")

-- Route through the same helper manager.lua uses (private but reachable).
Manager._update_todo_mirror("todo_write", live_result)
pump()
local cur = Todo.current()
check(cur ~= nil and cur.total == 3 and cur.completed == 1, "manager hook populated the mirror")
-- The empty->non-empty transition also auto-opened the panel (auto_open=true).
check(Todo.is_open(), "auto_open opened the panel via the manager hook")
eq("auto", Todo._opened_by(), "auto-opened panel is marked auto")

-- 2. Standalone column (close the auto panel, reopen manually) --------------
Todo.close()
-- Realistic source for the standalone split: a chat-like window carrying
-- pi's fingerprint options (mirrors lua/pi/ui/chat/layout.lua set_win_opts),
-- so the panel inherits concealcursor="nvic" exactly like :PiTodo run while
-- a chat window is current.
vim.cmd("split")
local chatlike = vim.api.nvim_get_current_win()
vim.wo[chatlike].wrap = false
vim.wo[chatlike].number = false
vim.wo[chatlike].relativenumber = false
vim.wo[chatlike].signcolumn = "no"
vim.wo[chatlike].concealcursor = "nvic"
vim.wo[chatlike].cursorline = false
vim.wo[chatlike].winfixbuf = true
Todo.open()
eq("manual", Todo._opened_by(), "explicit open marks the panel manual")
local win = vim.api.nvim_get_current_win()
check(vim.api.nvim_win_is_valid(win), "standalone open creates a valid window")
check(vim.wo[win].winfixwidth == true, "standalone window is winfixwidth")
check(vim.wo[win].winfixheight == false, "standalone window is not winfixheight")
local bufnr = vim.api.nvim_win_get_buf(win)
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
-- DESIGN.md padding: blank spacer, calm header, blank, then indented rows.
check(#lines == 6, "panel renders spacer + header + blank + 3 items (got " .. #lines .. ")")
eq(
    { "", "  Todo · 1/3 completed", "", "  ✓ write module", "  ◐ write tests", "  ○ review" },
    lines,
    "standalone panel renders the padded layout"
)
-- Focus bounce: re-entering the panel must not reset it to user defaults
-- (the reported pi-sessions line-number bug).
bounce_focus(win, "standalone")
-- auto_open was consumed by the transition above; this open() is explicit.
Todo.close()
check(not Todo.is_open(), "close removes the panel")

-- 3. Stacked layout --------------------------------------------------------
-- Register a real sessions-list window through pi.ui.sessions so the panel
-- stacks in its column. Its side win is a 40-wide left vsplit.
-- Open it from the chat-like window so the stacked chain (chat-like ->
-- sessions -> todo split) inherits concealcursor="nvic".
vim.api.nvim_set_current_win(chatlike)
SessionList.open()
local sess_win = SessionList.win(vim.api.nvim_get_current_tabpage())
check(sess_win ~= nil, "sessions list window registered")
-- The real sessions left/right column fixes width only; the todo split's
-- height must survive without a fixed-height neighbor.
check(vim.wo[sess_win].winfixheight == false, "sessions column has no winfixheight (mimics real layout)")
Manager._update_todo_mirror("todo_write", live_result)
pump()
-- auto_open fired on the mirror transition? The state was already non-empty,
-- so open explicitly (the transition test is #5).
-- Sessions owns the whole column before the split, so its height is what the
-- fraction is taken from.
local sess_h = vim.fn.winheight(sess_win)
Todo.open()
local todo_win = vim.api.nvim_get_current_win()
check(todo_win ~= sess_win, "todo window differs from sessions window")
check(vim.wo[todo_win].winfixheight == true, "stacked todo window is winfixheight")
-- RIGHT AFTER open: default height 0.5 = even 50/50 split of the column.
-- Catches both the 'equalalways' collapse and a content-sized shrink-to-fit.
check(
    vim.fn.winheight(todo_win) == math.floor(sess_h * 0.5),
    "stacked todo window is the default 50/50 split (got "
        .. vim.fn.winheight(todo_win)
        .. ", want "
        .. math.floor(sess_h * 0.5)
        .. ")"
)
check(vim.fn.win_screenpos(sess_win)[1] < vim.fn.win_screenpos(todo_win)[1], "todo panel is below the sessions window")
check(vim.wo[todo_win].winfixwidth == true, "stacked todo window also fixes the column width")
-- Focus bounce in the stacked panel: the winfix reset must leave the stacked
-- window (including winfixheight) untouched.
bounce_focus(todo_win, "stacked", true)

-- 4. Refresh updates content ----------------------------------------------
local v2 = {
    details = {
        todos = {
            { content = "write module", status = "completed" },
            { content = "write tests", status = "completed" },
            { content = "review", status = "pending" },
        },
        completed = 2,
        total = 3,
    },
}
Manager._update_todo_mirror("todo_write", v2)
pump()
local buf2 = vim.api.nvim_win_get_buf(todo_win)
local lines2 = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
eq("  Todo · 2/3 completed", lines2[2], "refresh renders the new progress header")
-- refresh re-asserts the configured ratio even after layout churn: it is
-- re-derived from the current column total (sessions + todo).
vim.api.nvim_win_set_height(todo_win, 14)
local column = vim.fn.winheight(sess_win) + vim.fn.winheight(todo_win)
Todo.refresh()
check(
    vim.fn.winheight(todo_win) == math.floor(column * 0.5),
    "refresh re-asserts the stacked ratio after a manual resize (got "
        .. vim.fn.winheight(todo_win)
        .. ", want "
        .. math.floor(column * 0.5)
        .. ")"
)

-- 4b. Ratio and absolute overrides (close + reopen so open-time sizing runs) -
local saved_height = require("pi.config").options.todo.panel.height
Todo.close()
require("pi.config").options.todo.panel.height = 0.25
-- Sessions owns the whole column again once the panel is closed.
local sess_h25 = vim.fn.winheight(sess_win)
Todo.open()
local todo_win25 = vim.api.nvim_get_current_win()
check(
    vim.fn.winheight(todo_win25) == math.floor(sess_h25 * 0.25),
    "ratio override 0.25 sizes the panel from the column (got "
        .. vim.fn.winheight(todo_win25)
        .. ", want "
        .. math.floor(sess_h25 * 0.25)
        .. ")"
)
Todo.close()
require("pi.config").options.todo.panel.height = 6
Todo.open()
local todo_win6 = vim.api.nvim_get_current_win()
check(
    vim.fn.winheight(todo_win6) == 6,
    "absolute height 6 is honored in lines (got " .. vim.fn.winheight(todo_win6) .. ")"
)
require("pi.config").options.todo.panel.height = saved_height
-- Reopen at the default ratio for the following sections; re-grab the window
-- handle (the old one was closed above).
Todo.close()
Todo.open()
todo_win = vim.api.nvim_get_current_win()

-- 5. Clear + hide_when_empty: explicit panel keeps a placeholder -----------
Manager._update_todo_mirror("todo_write", { details = { todos = {}, completed = 0, total = 0 } })
pump()
local lines3 = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(todo_win), 0, -1, false)
eq({ "", "  no todos" }, lines3, "explicit panel shows the padded no-todos placeholder after clear")
Todo.close()

-- 6. Replay-style result (details at top level) ----------------------------
Todo._reset()
Manager._update_todo_mirror("todo_write", {
    toolName = "todo_write",
    details = { todos = { { content = "replayed", status = "pending" } }, completed = 0, total = 1 },
})
check(Todo.current() ~= nil and Todo.current().total == 1, "replay-style toolResult updates the mirror")

-- 7. Non-todo tool does not touch the mirror -------------------------------
Manager._update_todo_mirror("read", { details = { todos = {}, completed = 0, total = 5 } })
check(Todo.current().total == 1, "non-todo tool ignored by the mirror")

-- 8. Per-tab buffers: two tabs with open panels each show their own list ----
Todo._reset()
local details_a = {
    details = {
        todos = { { content = "tab one item", status = "pending" } },
        completed = 0,
        total = 1,
    },
}
-- Tab 1: empty -> non-empty auto-opens the panel here too.
Manager._update_todo_mirror("todo_write", details_a)
pump()
local tab1 = vim.api.nvim_get_current_tabpage()
local win_a = Todo.win(tab1)
check(win_a ~= nil, "tab 1 panel open after auto_open")
local buf_a = vim.api.nvim_win_get_buf(win_a)

vim.cmd("tabnew")
Manager._update_todo_mirror("todo_write", {
    details = {
        todos = { { content = "tab two item", status = "in_progress" } },
        completed = 0,
        total = 1,
    },
})
pump()
local tab2 = vim.api.nvim_get_current_tabpage()
local win_b = Todo.win(tab2)
check(win_b ~= nil and win_b ~= win_a, "tab 2 panel auto-opened independently")
local buf_b = vim.api.nvim_win_get_buf(win_b)
check(buf_b ~= buf_a, "each tab's panel has its own buffer")
eq("  Todo · 0/1 completed", vim.api.nvim_buf_get_lines(buf_b, 0, -1, false)[2], "tab 2 panel shows its own header")
eq({ "  ◐ tab two item" }, { vim.api.nvim_buf_get_lines(buf_b, 0, -1, false)[4] }, "tab 2 panel shows its own item")

-- Back on tab 1: its buffer still shows tab one's list (no cross-talk).
vim.api.nvim_set_current_tabpage(tab1)
pump(200)
eq(
    { "", "  Todo · 0/1 completed", "", "  ○ tab one item" },
    vim.api.nvim_buf_get_lines(buf_a, 0, -1, false),
    "tab 1 panel unaffected by tab 2 refresh"
)

-- 9. opened_by semantics end-to-end ----------------------------------------
-- Manual reopen on tab 1: clear keeps the placeholder.
Todo.close()
Todo.open()
eq("manual", Todo._opened_by(), "tab 1 reopened manually")
Manager._update_todo_mirror("todo_write", { details = { todos = {}, completed = 0, total = 0 } })
pump()
check(Todo.is_open(), "manual panel stays open after clear")
eq(
    { "", "  no todos" },
    vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(Todo.win(tab1)), 0, -1, false),
    "manual panel placeholder after clear"
)
-- Auto panel on tab 2 closes on clear.
vim.api.nvim_set_current_tabpage(tab2)
Manager._update_todo_mirror("todo_write", { details = { todos = {}, completed = 0, total = 0 } })
pump()
check(Todo.win(tab2) == nil, "auto panel closed after clear")
check(Todo._opened_by() == nil, "opened_by cleared with the auto panel")

-- 10. Session-tab keying: event for tab 1 routed while tab 2 is focused ------
Todo._reset()
tab1 = vim.api.nvim_get_current_tabpage()
vim.cmd("tabnew")
tab2 = vim.api.nvim_get_current_tabpage()
-- The keyboard focus is on session-less tab 2, but the session lives in tab 1:
-- the mirror is keyed to tab 1 and the auto-open defers to TabEnter.
Manager._update_todo_mirror(
    "todo_write",
    { details = { todos = { { content = "session tab item", status = "pending" } }, completed = 0, total = 1 } },
    tab1
)
pump()
check(Todo.win(tab2) == nil, "session-less focused tab captured no panel")
check(Todo.current() == nil, "session-less focused tab captured no state")
check(Todo.win(tab1) == nil, "background session tab has no panel yet (auto-open deferred)")
vim.api.nvim_set_current_tabpage(tab1)
local win_deferred = Todo.win(tab1)
check(win_deferred ~= nil, "entering the session tab consumes the deferred auto-open")
eq("auto", Todo._opened_by(), "deferred auto-open marks the panel auto")
eq(
    "  Todo · 0/1 completed",
    vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win_deferred), 0, -1, false)[2],
    "session tab panel shows the session's todos"
)
-- Detached session (explicit nil third argument): update skipped, no state.
vim.api.nvim_set_current_tabpage(tab2)
Manager._update_todo_mirror(
    "todo_write",
    { details = { todos = { { content = "detached item", status = "pending" } }, completed = 0, total = 1 } },
    nil
)
check(Todo.current() == nil, "detached session (explicit nil tab) writes no state")

-- Cleanup ------------------------------------------------------------------
Todo._reset()
Manager._reset()
if vim.fn.tabpagenr("$") > 1 then
    vim.cmd("tabclose") -- back to the first tab
end
SessionList.close()
SessionList._reset()
require("pi.config").options.todo = saved_todo
require("pi.config").options.sessions_list = saved_sl

print(string.format("== todo panel e2e: %d failure(s) ==", failures))
os.exit(failures == 0 and 0 or 1)
