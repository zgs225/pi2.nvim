-- Headless e2e for `tasks_panel.open_with_chat` / `todo.panel.open_with_chat`
-- (lua/pi/ui/chat/layout.lua, the `Layout:show()` hook).
--
-- The behavior under test: a panel configured with `open_with_chat` is on
-- screen the moment the chat appears — the same "open together with the chat"
-- contract `sessions_list.auto_open` has had all along — while the flags stay
-- false by default and are read at call time (G20), so a plain chat is
-- untouched.
--
--   1. a real session opened with both flags on has the :PiTasks and :PiTodo
--      windows in the tab, in the chat layout's right column (tasks above todo)
--   2. the hook never steals the cursor: the chat prompt keeps focus
--   3. both panels hold their empty-state placeholder (`no tasks` / `no todos`)
--      instead of closing — a chat-opened panel is part of the chat UI
--   4. :PiToggleChat (hide_ui/show_ui) closes them with the chat and brings
--      them back
--   5. a session opened in another tab AFTER the flags are switched off gets
--      no panel: the flags are read when the chat opens, not at setup time
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/open_with_chat_e2e.lua
--
-- Isolation (G17/G18): agent dir / prompt history / draft are temp paths set
-- before `require("pi")`, and `_agent.send` is stubbed (no model call).

local real_sessions_dir = vim.fn.expand("~/.pi/agent/sessions")
--- @param dir string
--- @return integer
local function count_jsonl(dir)
    return #vim.fn.globpath(dir, "**/*.jsonl", false, true)
end

local real_sessions_before = count_jsonl(real_sessions_dir)
local agent_dir = vim.fn.tempname()

vim.env.PI_CODING_AGENT_DIR = agent_dir
require("pi.prompt_history")._set_base_dir(vim.fn.tempname())
require("pi.draft")._set_path(vim.fn.tempname() .. "/draft.txt")

local failures = {}

--- Record one assertion. `detail` should carry the got/want evidence.
---@param name string assertion label
---@param ok boolean assertion result
---@param detail? string got/want evidence
local function check(name, ok, detail)
    print(string.format("[%s] %s%s", ok and "PASS" or "FAIL", name, detail and (" — " .. detail) or ""))
    if not ok then
        failures[#failures + 1] = name
    end
end

--- @param ft string
--- @return integer? buf first buffer carrying this filetype
local function find_buf(ft)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].filetype == ft then
            return b
        end
    end
end

--- Drain the event loop instead of sleeping: the marker is queued BEHIND every
--- callback already pending (window cleanup, deferred geometry passes, the
--- scheduled prompt focus), so FIFO order guarantees that work has run when the
--- marker fires.
---@return boolean drained true when the barrier was reached
local function drain()
    local drained = false
    vim.schedule(function()
        drained = true
    end)
    return vim.wait(10000, function()
        return drained
    end, 20)
end

--- @param win integer
--- @return string
local function win_desc(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return "invalid"
    end
    return ("win=%d ft=%s"):format(win, tostring(vim.bo[vim.api.nvim_win_get_buf(win)].filetype))
end

--- Joined buffer text of `win` (empty string for an invalid window).
--- @param win integer?
--- @return string
local function win_text(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return ""
    end
    return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
end

local Config = require("pi.config")
local Tasks = require("pi.ui.tasks")
local Todo = require("pi.todo")

-- The flags under test, on for the first session.
Config.options.tasks_panel.open_with_chat = true
Config.options.todo.panel.open_with_chat = true
Config.options.tasks_panel.mode = "follow"
Config.options.todo.panel.mode = nil

local ok_body, err = pcall(function()
    require("pi").show({ layout = "side" })
    vim.wait(10000, function()
        return find_buf("pi-chat-history") ~= nil and find_buf("pi-chat-prompt") ~= nil
    end, 20)
    drain()

    local session = require("pi.sessions.manager").get()
    check("session created", session ~= nil)
    if not session or not session.chat then
        return
    end
    local chat = session.chat
    if chat._agent then
        chat._agent.send = function() end -- hermetic: never call the model
    end
    local tab = vim.api.nvim_get_current_tabpage()

    -- 1. Both panels came up with the chat -----------------------------------
    local tasks_win = Tasks.win(tab)
    local todo_win = Todo.win(tab)
    check("open_with_chat opened the tasks panel with the chat", tasks_win ~= nil, win_desc(tasks_win))
    check("open_with_chat opened the todo panel with the chat", todo_win ~= nil, win_desc(todo_win))
    check(
        "tasks panel window shows the pi-tasks buffer",
        tasks_win ~= nil and vim.bo[vim.api.nvim_win_get_buf(tasks_win)].filetype == "pi-tasks",
        win_desc(tasks_win)
    )
    check(
        "todo panel window shows the pi-todo buffer",
        todo_win ~= nil and vim.bo[vim.api.nvim_win_get_buf(todo_win)].filetype == "pi-todo",
        win_desc(todo_win)
    )
    if tasks_win and todo_win then
        local tpos, dpos = vim.fn.win_screenpos(tasks_win), vim.fn.win_screenpos(todo_win)
        check(
            "both panels share the right column (same screen column)",
            tpos[2] == dpos[2],
            ("tasks col=%d todo col=%d"):format(tpos[2], dpos[2])
        )
        check(
            "the tasks panel stacks above the todo panel (sidebar ORDER)",
            tpos[1] < dpos[1],
            ("tasks row=%d todo row=%d"):format(tpos[1], dpos[1])
        )
    end

    -- 2. The hook does not steal the cursor ----------------------------------
    vim.api.nvim_set_current_win(chat:prompt_win())
    drain()
    check(
        "the chat prompt keeps focus after the panels open",
        vim.api.nvim_get_current_win() == chat:prompt_win(),
        "current=" .. win_desc(vim.api.nvim_get_current_win()) .. " want=" .. win_desc(chat:prompt_win())
    )

    -- 3. Empty state, not a closed window -----------------------------------
    check(
        "the tasks panel keeps its no-tasks placeholder",
        win_text(tasks_win):find("no tasks", 1, true) ~= nil,
        ("got=%q"):format(win_text(tasks_win))
    )
    check(
        "the todo panel keeps its no-todos placeholder",
        win_text(todo_win):find("no todos", 1, true) ~= nil,
        ("got=%q"):format(win_text(todo_win))
    )

    -- 4. :PiToggleChat closes and restores the whole UI ----------------------
    chat:hide_ui()
    drain()
    check(
        "hide_ui closes the chat-opened panels with the chat",
        Tasks.win(tab) == nil and Todo.win(tab) == nil,
        "tasks=" .. win_desc(Tasks.win(tab)) .. " todo=" .. win_desc(Todo.win(tab))
    )
    chat:show_ui()
    drain()
    check(
        "show_ui restores the chat-opened panels",
        Tasks.win(tab) ~= nil and Todo.win(tab) ~= nil,
        "tasks=" .. win_desc(Tasks.win(tab)) .. " todo=" .. win_desc(Todo.win(tab))
    )

    -- 5. Flags are read when the chat opens (G20) ---------------------------
    vim.cmd("tabnew")
    local tab2 = vim.api.nvim_get_current_tabpage()
    Config.options.tasks_panel.open_with_chat = false
    Config.options.todo.panel.open_with_chat = false
    require("pi").show({ layout = "side" })
    vim.wait(10000, function()
        local cur = require("pi.sessions.manager").get()
        return cur ~= nil and cur.chat ~= nil and cur.chat._layout:prompt_win() ~= nil
    end, 20)
    drain()
    local session2 = require("pi.sessions.manager").get()
    if session2 and session2.chat and session2.chat._agent then
        session2.chat._agent.send = function() end
    end
    check(
        "a tab opened with both flags off gets no panel",
        Tasks.win(tab2) == nil and Todo.win(tab2) == nil,
        "tasks=" .. win_desc(Tasks.win(tab2)) .. " todo=" .. win_desc(Todo.win(tab2))
    )
    check(
        "the flags-off tab still has its chat prompt",
        session2 ~= nil and session2.chat ~= nil and session2.chat._layout:prompt_win() ~= nil,
        win_desc(session2 and session2.chat and session2.chat._layout:prompt_win())
    )

    -- Cleanup: back to tab 1 with the flags restored.
    Config.options.tasks_panel.open_with_chat = true
    Config.options.todo.panel.open_with_chat = true
    vim.cmd("tabclose")
end)

if not ok_body then
    check("e2e body completed without error", false, tostring(err))
end

-- G18: no model call => no transcript.
local real_sessions_after = count_jsonl(real_sessions_dir)
check(
    "G18: real sessions dir jsonl count unchanged",
    real_sessions_after == real_sessions_before,
    ("got=%d want=%d delta=%+d dir=%s"):format(
        real_sessions_after,
        real_sessions_before,
        real_sessions_after - real_sessions_before,
        real_sessions_dir
    )
)
local temp_jsonl = vim.fn.globpath(agent_dir, "**/*.jsonl", false, true)
check("G18: temp agent dir has no session transcript", #temp_jsonl == 0, ("got=%d want=0"):format(#temp_jsonl))

if #failures > 0 then
    print("OPEN WITH CHAT E2E: " .. #failures .. " failed — " .. table.concat(failures, ", "))
    vim.cmd("cq 1")
else
    print("OPEN WITH CHAT E2E: ALL GREEN")
    vim.cmd("cq 0")
end
