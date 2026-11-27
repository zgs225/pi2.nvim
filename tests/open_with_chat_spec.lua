-- Unit coverage for the `open_with_chat` contract (tasks_panel + todo.panel):
--
--   * both flags ship false in the defaults (a plain chat is untouched)
--   * `pi.ui.chat.layout`'s `_open_with_chat_panels()` — the function the
--     `Layout:show()` hook calls — opens only the panels whose flag is set and
--     reports whether it asked for anything (idempotent: `open()` only focuses
--     an existing window)
--   * a chat-opened todo panel is a MANUAL panel (`_opened_by() == "manual"`),
--     which is what keeps its `no todos` placeholder instead of closing when
--     the list empties (tests/todo_panel_e2e.lua section 9 pins that mapping)
--   * `tasks_panel.open_with_chat` disables the all-tasks-finished auto-close;
--     without the flag the panel still closes as before
--
-- The real wiring (a session opened through `pi.show` with the flags on/off,
-- focus, column stacking) is `tests/open_with_chat_e2e.lua` — this spec only
-- proves the decisions, without constructing a chat.

local Tasks = require("pi.tasks")
local Panel = require("pi.ui.tasks")
local Todo = require("pi.todo")
local Config = require("pi.config")
local Sidebar = require("pi.ui.sidebar")
local Layout = require("pi.ui.chat.layout")

---@return pi.TabId
local function tab()
    return vim.api.nvim_get_current_tabpage()
end

--- The shipped flag values, captured before `before_each` mutates the live
--- options table (config.lua keeps its `defaults` local, not exported).
local shipped = {
    tasks = Config.options.tasks_panel.open_with_chat,
    todo = Config.options.todo.panel.open_with_chat,
}

---@param tasks boolean
---@param todo boolean
local function set_flags(tasks, todo)
    Config.options.tasks_panel.open_with_chat = tasks
    Config.options.todo.panel.open_with_chat = todo
end

--- Focus a window that is neither the tasks nor the todo panel, so
--- `request_auto_close` does not defer for focus.
local function focus_outside_panels()
    local tasks_win, todo_win = Panel.win(tab()), Todo.win(tab())
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win ~= tasks_win and win ~= todo_win then
            vim.api.nvim_set_current_win(win)
            return
        end
    end
    error("no window outside the panels to move focus to")
end

--- Seed one finished task so `Tasks.has_running` is false for the tab.
local function seed_finished_task()
    local now = vim.uv.now()
    Tasks.upsert({
        id = "t1",
        command = "make test",
        status = "completed",
        start_time = now - 2000,
        end_time = now - 1000,
        exit_code = 0,
    })
end

describe("open_with_chat", function()
    before_each(function()
        Tasks._reset()
        Panel._reset()
        Panel._resubscribe()
        Todo._reset()
        Sidebar._reset()
        set_flags(false, false)
    end)

    after_each(function()
        Panel._reset()
        Todo._reset()
        Tasks._reset()
        Sidebar._reset()
        set_flags(false, false)
    end)

    it("defaults both flags to false", function()
        assert.is_false(shipped.tasks)
        assert.is_false(shipped.todo)
    end)

    it("opens nothing when both flags are off", function()
        assert.is_false(Layout._open_with_chat_panels())
        assert.is_nil(Panel.win(tab()))
        assert.is_nil(Todo.win(tab()))
    end)

    it("opens the tasks panel for tasks_panel.open_with_chat only", function()
        set_flags(true, false)
        assert.is_true(Layout._open_with_chat_panels())
        assert.is_not_nil(Panel.win(tab()))
        assert.is_nil(Todo.win(tab()))
    end)

    it("opens the todo panel for todo.panel.open_with_chat only", function()
        set_flags(false, true)
        assert.is_true(Layout._open_with_chat_panels())
        assert.is_nil(Panel.win(tab()))
        assert.is_not_nil(Todo.win(tab()))
    end)

    it("marks a chat-opened todo panel manual, so its placeholder survives", function()
        set_flags(false, true)
        Layout._open_with_chat_panels()
        local win = Todo.win(tab())
        assert.are.equal("manual", Todo._opened_by())
        local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
        assert.is_truthy(table.concat(lines, "\n"):find("no todos", 1, true))
    end)

    it("is idempotent: a second call focuses the existing window", function()
        set_flags(true, true)
        Layout._open_with_chat_panels()
        local tasks_win, todo_win = Panel.win(tab()), Todo.win(tab())
        Layout._open_with_chat_panels()
        assert.are.equal(tasks_win, Panel.win(tab()))
        assert.are.equal(todo_win, Todo.win(tab()))
    end)

    it("keeps a chat-opened tasks panel after the last task finishes", function()
        seed_finished_task()
        set_flags(true, false)
        Layout._open_with_chat_panels()
        focus_outside_panels()
        Panel.request_auto_close(tab())
        assert.is_not_nil(Panel.win(tab()))
    end)

    it("still auto-closes a tasks panel opened without open_with_chat", function()
        seed_finished_task()
        Panel.open()
        focus_outside_panels()
        Panel.request_auto_close(tab())
        assert.is_nil(Panel.win(tab()))
    end)
end)
