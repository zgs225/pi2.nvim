-- Headless e2e for the todo panel (lua/pi/todo/init.lua).
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/todo_panel_e2e.lua
-- Exercises the real pi.todo.tool_ui + pi.ui.sessions accessor:
--   1. manager.update_todo_mirror-equivalent routing through update_from_details
--   2. standalone column open (winfixwidth, sessions_list width)
--   3. stacked layout below a fake registered sessions window (winfixheight)
--   4. auto_open on the empty -> non-empty transition
--   5. refresh renders new content into the open panel
--   6. hide_when_empty: cleared list -> manual panel keeps "no todos" placeholder
--   7. replay-style toolResult + non-todo tool gating
--   8. per-tab buffers: two tabs with open panels each show their own list
--   9. opened_by semantics: auto-opened panel closes on clear, manual keeps

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
    { panel = { auto_open = true, height = 10, position = "below", hide_when_empty = true } }
require("pi.config").options.sessions_list = { position = "left", width = 40 }

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
Todo.open()
eq("manual", Todo._opened_by(), "explicit open marks the panel manual")
local win = vim.api.nvim_get_current_win()
check(vim.api.nvim_win_is_valid(win), "standalone open creates a valid window")
check(vim.wo[win].winfixwidth == true, "standalone window is winfixwidth")
check(vim.wo[win].winfixheight == false, "standalone window is not winfixheight")
local bufnr = vim.api.nvim_win_get_buf(win)
local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
check(#lines >= 4, "panel buffer has header + 3 items")
check(lines[2]:find("write module", 1, true) ~= nil, "panel shows item content")
-- auto_open was consumed by the transition above; this open() is explicit.
Todo.close()
check(not Todo.is_open(), "close removes the panel")

-- 3. Stacked layout --------------------------------------------------------
-- Register a real sessions-list window through pi.ui.sessions so the panel
-- stacks in its column. Its side win is a 40-wide left vsplit.
SessionList.open()
local sess_win = SessionList.win(vim.api.nvim_get_current_tabpage())
check(sess_win ~= nil, "sessions list window registered")
Manager._update_todo_mirror("todo_write", live_result)
pump()
-- auto_open fired on the mirror transition? The state was already non-empty,
-- so open explicitly (the transition test is #5).
Todo.open()
local todo_win = vim.api.nvim_get_current_win()
check(todo_win ~= sess_win, "todo window differs from sessions window")
check(vim.wo[todo_win].winfixheight == true, "stacked todo window is winfixheight")
-- The todo split is height-pinned: winfixheight + height = content lines
-- bounded by the configured max (4 rendered lines here, max 10).
check(vim.fn.winheight(todo_win) == 4, "stacked todo window height equals its content height")
check(vim.fn.win_screenpos(sess_win)[1] < vim.fn.win_screenpos(todo_win)[1], "todo panel is below the sessions window")
check(vim.wo[todo_win].winfixwidth == true, "stacked todo window also fixes the column width")

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
eq("2/3 completed", lines2[1], "refresh renders the new progress header")

-- 5. Clear + hide_when_empty: explicit panel keeps a placeholder -----------
Manager._update_todo_mirror("todo_write", { details = { todos = {}, completed = 0, total = 0 } })
pump()
local lines3 = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(todo_win), 0, -1, false)
eq({ "no todos" }, lines3, "explicit panel shows the no-todos placeholder after clear")
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
eq("0/1 completed", vim.api.nvim_buf_get_lines(buf_b, 0, -1, false)[1], "tab 2 panel shows its own header")
eq({ "◐ tab two item" }, { vim.api.nvim_buf_get_lines(buf_b, 0, -1, false)[2] }, "tab 2 panel shows its own item")

-- Back on tab 1: its buffer still shows tab one's list (no cross-talk).
vim.api.nvim_set_current_tabpage(tab1)
pump(200)
eq(
    { "0/1 completed", "○ tab one item" },
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
    { "no todos" },
    vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(Todo.win(tab1)), 0, -1, false),
    "manual panel placeholder after clear"
)
-- Auto panel on tab 2 closes on clear.
vim.api.nvim_set_current_tabpage(tab2)
Manager._update_todo_mirror("todo_write", { details = { todos = {}, completed = 0, total = 0 } })
pump()
check(Todo.win(tab2) == nil, "auto panel closed after clear")
check(Todo._opened_by() == nil, "opened_by cleared with the auto panel")

-- Cleanup ------------------------------------------------------------------
Todo._reset()
if vim.fn.tabpagenr("$") > 1 then
    vim.cmd("tabclose") -- back to the first tab
end
SessionList.close()
SessionList._reset()
require("pi.config").options.todo = saved_todo
require("pi.config").options.sessions_list = saved_sl

print(string.format("== todo panel e2e: %d failure(s) ==", failures))
os.exit(failures == 0 and 0 or 1)
