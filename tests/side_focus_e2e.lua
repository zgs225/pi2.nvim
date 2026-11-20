-- Headless e2e: gotcha G11 — side layout's WinEnter redirect on the history
-- window must fire for *accidental* focus and NOT for a deliberate move from
-- the prompt. The compensating invariant is the whole contract: the redirect
-- exists so a stray click/`:wincmd` out of the history panel lands you back on
-- the prompt, but the prompt → history path (`<C-g>h`, which the user presses
-- from the prompt) must be reachable, so it is exempt when the previous window
-- was the prompt.
--
-- The block under test, `lua/pi/ui/chat/init.lua` (`Chat:_set_keymaps`); the
-- layout half it consults is `lua/pi/ui/chat/layout.lua` (`prompt_win()`):
--
--   vim.api.nvim_create_autocmd("WinEnter", {
--       buffer = hbuf,
--       callback = function()
--           if self._layout:mode() == "float" then return end
--           local pwin = self._layout:prompt_win()
--           local prev = vim.fn.win_getid(vim.fn.winnr("#"))
--           if prev == pwin then
--               return          -- <-- the exemption this script pins down
--           end
--           local entered_win = vim.api.nvim_get_current_win()
--           vim.schedule(function()
--               ...
--               vim.api.nvim_set_current_win(pwin)
--               vim.cmd("startinsert")
--           end)
--       end,
--   })
--
-- G11's own note: the history window is `winfixbuf`, so never `:edit` inside
-- it — this script only ever reads that buffer.
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/side_focus_e2e.lua
--
-- Isolation (G17/G18): agent dir / prompt history / draft are temp paths set
-- before `require("pi")`, and `_agent.send` is stubbed (no model call).

vim.env.PI_CODING_AGENT_DIR = vim.fn.tempname()
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

--- @param win integer
--- @return boolean
local function is_pi_win(win)
    return (vim.bo[vim.api.nvim_win_get_buf(win)].filetype or ""):match("^pi%-") ~= nil
end

--- Drain the event loop instead of sleeping: the marker is queued BEHIND every
--- callback already pending (the WinEnter handler's `vim.schedule` redirect), so
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
    check("side layout is active", layout and layout:mode() == "side", "got=" .. tostring(layout and layout:mode()))
    if not layout then
        return
    end
    local hwin, pwin = layout:history_win(), layout:prompt_win()
    check("history and prompt windows valid", hwin ~= nil and pwin ~= nil, win_desc(hwin) .. " / " .. win_desc(pwin))
    if not hwin or not pwin then
        return
    end
    local hbuf = vim.api.nvim_win_get_buf(hwin)
    check(
        "history window holds the pi-chat-history buffer",
        vim.bo[hbuf].filetype == "pi-chat-history",
        "got=" .. tostring(vim.bo[hbuf].filetype) .. " want=pi-chat-history"
    )
    check("history window is winfixbuf", vim.wo[hwin].winfixbuf, "got=" .. tostring(vim.wo[hwin].winfixbuf))

    -- A plain, non-π editor window to enter history FROM (the accidental case).
    local origin
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if w ~= hwin and w ~= pwin and not is_pi_win(w) then
            origin = w
            break
        end
    end
    origin = origin or pwin
    vim.api.nvim_set_current_win(origin)
    vim.cmd("new")
    local plain_win = vim.api.nvim_get_current_win()
    vim.bo.buftype = "nofile"
    vim.bo.bufhidden = "wipe"
    vim.bo.swapfile = false
    check(
        "plain editor window created outside π",
        plain_win ~= hwin and plain_win ~= pwin and not is_pi_win(plain_win),
        win_desc(plain_win)
    )

    -- (a) prompt -> history: exempt, no bounce.
    vim.api.nvim_set_current_win(pwin)
    drain()
    vim.api.nvim_set_current_win(hwin)
    drain()
    local after_a = vim.api.nvim_get_current_win()
    check(
        "entering history from the prompt is NOT bounced",
        after_a == hwin,
        "got=" .. win_desc(after_a) .. " want=" .. win_desc(hwin)
    )

    -- (b) plain editor window -> history: the redirect must fire.
    vim.api.nvim_set_current_win(plain_win)
    drain()
    vim.api.nvim_set_current_win(hwin)
    drain()
    local after_b = vim.api.nvim_get_current_win()
    check(
        "entering history from a plain window redirects to the prompt",
        after_b == pwin,
        "got=" .. win_desc(after_b) .. " want=" .. win_desc(pwin)
    )

    -- (c) neither transition touched the history buffer itself.
    check(
        "history window still shows the same buffer",
        vim.api.nvim_win_get_buf(hwin) == hbuf,
        "got=" .. tostring(vim.api.nvim_win_get_buf(hwin)) .. " want=" .. tostring(hbuf)
    )
    check(
        "history buffer still pi-chat-history",
        vim.bo[hbuf].filetype == "pi-chat-history",
        "got=" .. tostring(vim.bo[hbuf].filetype) .. " want=pi-chat-history"
    )

    pcall(vim.api.nvim_win_close, plain_win, true)
    check("plain editor window closed at teardown", not vim.api.nvim_win_is_valid(plain_win))
end)

if not ok_body then
    check("e2e body completed without error", false, tostring(err))
end

if #failures > 0 then
    print("SIDE FOCUS E2E: " .. #failures .. " failed — " .. table.concat(failures, ", "))
    vim.cmd("cq 1")
else
    print("SIDE FOCUS E2E: ALL GREEN")
    vim.cmd("cq 0")
end
