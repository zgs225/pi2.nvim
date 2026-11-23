-- Headless e2e: `[[` / `]]` turn navigation through the REAL buffer-local
-- keymaps, on both π buffers.
--
-- The unit spec (tests/turn_nav_spec.lua) pins the motion math and the anchor
-- bookkeeping on a bare History. This script pins what only a booted session can
-- show: the mappings are actually installed by `Chat:_set_keymaps()` on the
-- history *and* prompt buffers, the pressed key moves the HISTORY window's
-- cursor while focus stays where the user is (typing in the prompt), the count
-- is honoured (`2]]`), and `]]` past the last turn lands at the bottom and
-- re-attaches the stream instead of stopping dead.
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/turn_nav_e2e.lua
--
-- Isolation (G17/G18), before `require("pi")`: the agent dir, the prompt-history
-- base dir and the draft path are temp paths, so the spawned backend cannot
-- write into ~/.pi/agent. `_agent.send` is stubbed, so no model call happens and
-- no transcript is written; the real sessions dir is counted before and after
-- (G18 is asserted, not just measured).

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
--- callback already pending (scheduled renders, the WinEnter startinsert), so
--- FIFO order guarantees that work has run when the marker fires.
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

local ok_body, err = pcall(function()
    require("pi").show({ layout = "side" })
    vim.wait(10000, function()
        return find_buf("pi-chat-history") ~= nil and find_buf("pi-chat-prompt") ~= nil
    end, 20)

    local session = require("pi.sessions.manager").get()
    check("session created", session ~= nil)
    if not session or not session.chat then
        return
    end
    local chat = session.chat
    if chat._agent then
        chat._agent.send = function() end -- hermetic: never call the model
    end

    local layout = chat._layout
    local hwin, pwin = layout:history_win(), layout:prompt_win()
    check("history and prompt windows valid", hwin ~= nil and pwin ~= nil, win_desc(hwin) .. " / " .. win_desc(pwin))
    if not hwin or not pwin then
        return
    end
    local hbuf = vim.api.nvim_win_get_buf(hwin)
    local pbuf = vim.api.nvim_win_get_buf(pwin)
    local history = chat._history

    -- The mappings themselves: buffer-local `[[` / `]]` in normal mode on both
    -- π buffers (never global, never insert mode — `[[` in insert mode is a
    -- literal bracket).
    ---@param buf integer
    ---@return string[]
    local function normal_lhs(buf)
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            out[#out + 1] = m.lhs
        end
        return out
    end
    local function has_lhs(list, lhs)
        for _, l in ipairs(list) do
            if l == lhs then
                return true
            end
        end
        return false
    end
    for _, buf in ipairs({ hbuf, pbuf }) do
        local lhs = normal_lhs(buf)
        check(
            ("`]]` bound in normal mode on %s"):format(vim.bo[buf].filetype),
            has_lhs(lhs, "]]"),
            "lhs=" .. vim.inspect(lhs)
        )
        check(
            ("`[[` bound in normal mode on %s"):format(vim.bo[buf].filetype),
            has_lhs(lhs, "[["),
            "lhs=" .. vim.inspect(lhs)
        )
    end
    check(
        "`]]` is NOT bound in insert mode on the prompt",
        (function()
            for _, m in ipairs(vim.api.nvim_buf_get_keymap(pbuf, "i")) do
                if m.lhs == "]]" then
                    return false
                end
            end
            return true
        end)(),
        "an insert-mode `]]` would eat the literal bracket"
    )

    --- Render one complete turn through the same calls session replay makes.
    ---@param text string
    local function turn(text)
        history:add_user_message(text, nil, nil)
        drain()
        history:on_agent_start(nil)
        drain()
        history:on_text_delta("reply to " .. text .. "\n")
        vim.wait(150)
        history:on_agent_end("done")
        drain()
    end

    --- 1-indexed rows of the user message labels (text oracle, independent of
    --- the anchor list under test).
    ---@return integer[]
    local function label_rows()
        local icon = require("pi.config").options.labels.user_message
        local out = {}
        for i, line in ipairs(vim.api.nvim_buf_get_lines(hbuf, 0, -1, false)) do
            if line:sub(1, #icon) == icon then
                out[#out + 1] = i
            end
        end
        return out
    end

    ---@return integer
    local function history_cursor()
        return vim.api.nvim_win_get_cursor(hwin)[1]
    end

    --- Feed one key sequence from the prompt, in normal mode. G5: the whole
    --- sequence goes in ONE call, and the insert-mode redirect is drained before
    --- `stopinsert` so nothing re-enters insert underneath us.
    ---@param keys string
    local function feed_from_prompt(keys)
        vim.api.nvim_set_current_win(pwin)
        drain()
        vim.cmd("stopinsert")
        vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
        drain()
    end

    turn("one")
    turn("two")
    turn("three")
    local rows = label_rows()
    check("three turns rendered", #rows == 3, "rows=" .. vim.inspect(rows))
    if #rows ~= 3 then
        return
    end
    local prompt_before = table.concat(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false), "\n")

    -- Park on the first turn, then `]]` from the prompt: the history cursor
    -- moves, focus does not.
    vim.api.nvim_win_set_cursor(hwin, { rows[1], 0 })
    feed_from_prompt("]]")
    check(
        "`]]` from the prompt lands on the second turn",
        history_cursor() == rows[2],
        ("got=%d want=%d"):format(history_cursor(), rows[2])
    )
    check(
        "focus stays in the prompt",
        vim.api.nvim_get_current_win() == pwin,
        "got=" .. win_desc(vim.api.nvim_get_current_win())
    )

    feed_from_prompt("[[")
    check(
        "`[[` from the prompt lands on the first turn",
        history_cursor() == rows[1],
        ("got=%d want=%d"):format(history_cursor(), rows[1])
    )

    feed_from_prompt("[[")
    check(
        "`[[` at the first turn is a no-op",
        history_cursor() == rows[1],
        ("got=%d want=%d"):format(history_cursor(), rows[1])
    )

    feed_from_prompt("2]]")
    check("`2]]` skips a turn", history_cursor() == rows[3], ("got=%d want=%d"):format(history_cursor(), rows[3]))

    -- Past the last turn: the live end, following again.
    feed_from_prompt("]]")
    local total = vim.api.nvim_buf_line_count(hbuf)
    check(
        "`]]` past the last turn lands at the bottom",
        history_cursor() == total,
        ("got=%d want=%d"):format(history_cursor(), total)
    )
    check(
        "landing at the bottom re-attaches the stream",
        history._auto_follow == true,
        "got=" .. tostring(history._auto_follow)
    )

    -- Same keys from the history buffer itself (the reading position).
    vim.api.nvim_win_set_cursor(hwin, { rows[1], 0 })
    vim.api.nvim_set_current_win(hwin)
    drain()
    vim.api.nvim_feedkeys(vim.keycode("]]"), "mx", false)
    drain()
    check(
        "`]]` in the history buffer lands on the second turn",
        history_cursor() == rows[2],
        ("got=%d want=%d"):format(history_cursor(), rows[2])
    )
    check(
        "focus stays in the history buffer",
        vim.api.nvim_get_current_win() == hwin,
        "got=" .. win_desc(vim.api.nvim_get_current_win())
    )

    -- The motion never edits a buffer.
    check(
        "prompt text untouched by turn navigation",
        table.concat(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false), "\n") == prompt_before,
        "got=" .. vim.inspect(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false))
    )
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
check(
    "G18: temp agent dir has no session transcript",
    #temp_jsonl == 0,
    ("got=%d want=0 dir=%s%s"):format(
        #temp_jsonl,
        agent_dir,
        #temp_jsonl > 0 and (" files=" .. vim.inspect(temp_jsonl)) or ""
    )
)

if #failures > 0 then
    print("TURN NAV E2E: " .. #failures .. " failed — " .. table.concat(failures, ", "))
    vim.cmd("cq 1")
else
    print("TURN NAV E2E: ALL GREEN")
    vim.cmd("cq 0")
end
