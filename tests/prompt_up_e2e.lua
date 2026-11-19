-- Headless e2e: gotchas G5 and G2 on the REAL prompt buffer and its keymaps.
--
-- G5 — insert mode does not persist across separate `feedkeys`/`wait` calls in
--      headless mode, so an insert-only `<Up>` mapping looks dead unless the
--      whole key sequence is fed in ONE call. Part (a) does that on line 2 of a
--      3-line draft: the mapping must decline (`return "<Up>"`), leave the text
--      byte-identical and move the cursor up one line. Part (b) does it on line
--      1 with a real history store injected: the newest entry must take over.
-- G2 — returning `vim.keycode("<Up>")` from an `<expr>` mapping inserts the raw
--      reserved key bytes (`\128ku`) as TEXT. Both parts assert that sequence
--      never appears in the prompt buffer.
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/prompt_up_e2e.lua
--
-- Isolation (G17/G18), before `require("pi")`: the agent dir, the prompt-history
-- base dir and the draft path are redirected to temp paths, so the spawned
-- backend cannot write into ~/.pi/agent and no user history/draft is touched.
-- `_agent.send` is stubbed, so no model call happens and no transcript is written.

vim.env.PI_CODING_AGENT_DIR = vim.fn.tempname()
require("pi.prompt_history")._set_base_dir(vim.fn.tempname())
require("pi.draft")._set_path(vim.fn.tempname() .. "/draft.txt")

local RAW_KEYCODE = "\128ku" -- exactly what a `vim.keycode("<Up>")` return inserts

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

--- @param buf integer
--- @return string[]
local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Feed ONE key sequence and let Neovim process all of it. `vim.keycode` is
--- the correct argument here (feedkeys wants real key bytes); returning it from
--- the mapping is what G2 forbids.
---@param seq string raw key sequence
local function feed(seq)
    vim.api.nvim_feedkeys(seq, "x", false)
end

local ok_body, err = pcall(function()
    require("pi").show({ layout = "side" })
    vim.wait(10000, function()
        return find_buf("pi-chat-prompt") ~= nil
    end, 20)

    local pbuf = find_buf("pi-chat-prompt")
    check("prompt buffer exists", pbuf ~= nil, "got=" .. tostring(pbuf))
    if not pbuf then
        return
    end

    local session = require("pi.sessions.manager").get()
    check("session created", session ~= nil)
    if not session or not session.chat then
        return
    end
    local chat = session.chat
    if chat._agent then
        chat._agent.send = function() end -- hermetic: never call the model
    end
    local pwin = chat._prompt:win()
    check("prompt window valid", pwin ~= nil)
    if not pwin then
        return
    end

    -- (a) G5 + G2: `<Up>` on line 2 declines and moves the cursor, text intact.
    local draft = { "alpha drafted", "bravo drafted", "charlie drafted" }
    vim.api.nvim_set_current_win(pwin)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, draft)
    vim.api.nvim_win_set_cursor(pwin, { 2, 0 })
    check("3-line draft staged, cursor on line 2", #lines_of(pbuf) == 3, "got=" .. #lines_of(pbuf) .. " want=3")

    feed("i" .. vim.keycode("<Up>"))
    vim.wait(10000, function()
        return vim.api.nvim_win_get_cursor(pwin)[1] == 1
    end, 20)

    local got_a = lines_of(pbuf)
    check(
        "line 2 <Up> leaves the draft unchanged",
        table.concat(got_a, "\n") == table.concat(draft, "\n"),
        "got=" .. vim.inspect(got_a) .. " want=" .. vim.inspect(draft)
    )
    check(
        "line 2 <Up> moves the cursor up one line",
        vim.api.nvim_win_get_cursor(pwin)[1] == 1,
        "got=" .. vim.api.nvim_win_get_cursor(pwin)[1] .. " want=1"
    )
    check(
        "no raw keycode bytes inserted",
        not table.concat(lines_of(pbuf), "\n"):find(RAW_KEYCODE, 1, true),
        "got=" .. vim.inspect(table.concat(lines_of(pbuf), "\n")) .. " unclean=raw <Up> bytes"
    )

    -- Leave insert mode so part (b) starts from normal mode.
    feed(vim.keycode("<Esc>"))
    vim.wait(10000, function()
        return vim.api.nvim_get_mode().mode == "n"
    end, 20)

    -- (b) G5 + G2 via a known history store: newline-free prompt, recall fires.
    local store = require("pi.prompt_history").Store.new({ path = false })
    store:add("older remembered prompt")
    store:add("newest remembered prompt")
    chat._prompt_history = store
    chat._prompt_nav = nil

    vim.api.nvim_set_current_win(pwin)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "half-typed draft" })
    vim.api.nvim_win_set_cursor(pwin, { 1, 0 })

    feed("i" .. vim.keycode("<Up>"))
    vim.wait(10000, function()
        return lines_of(pbuf)[1] == "newest remembered prompt"
    end, 20)

    local got_b = lines_of(pbuf)
    check(
        "line 1 <Up> recalls the newest history entry",
        #got_b == 1 and got_b[1] == "newest remembered prompt",
        ("got=%s want=[newest remembered prompt]"):format(vim.inspect(got_b))
    )
    check(
        "recalled prompt carries no raw keycode bytes",
        not table.concat(got_b, "\n"):find(RAW_KEYCODE, 1, true),
        "got=" .. vim.inspect(table.concat(got_b, "\n")) .. " unclean=raw <Up> bytes"
    )
end)

if not ok_body then
    check("e2e body completed without error", false, tostring(err))
end

if #failures > 0 then
    print("PROMPT UP E2E: " .. #failures .. " failed — " .. table.concat(failures, ", "))
    vim.cmd("cq 1")
else
    print("PROMPT UP E2E: ALL GREEN")
    vim.cmd("cq 0")
end
