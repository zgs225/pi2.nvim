-- Prompt-history recall regressions (gotchas G1/G2/G3).
--
-- G1 — an `<expr>` mapping cannot mutate the buffer: `_set_prompt_draft` must defer
--      its `set_lines` + cursor move, so every recall assertion polls.
-- G2 — `<Up>` pass-through must return the LITERAL `"<Up>"`; `vim.keycode("<Up>")`
--      inserts the raw bytes `\x80ku` as text.
-- G3 — the reset compares buffer text to `_last_applied_prompt` (a timing flag
--      cannot work: TextChangedI is deferred), so a second recall walks further
--      back and a deferred recall edit never clobbers navigation.
--
-- `pi.worktree` is stubbed so `Chat:show()` never shells out to git.

local Chat = require("pi.ui.chat")
local PH = require("pi.prompt_history")

local TAB = 1341

-- Budget for a polled assertion. `make test` runs every spec file as a parallel
-- child nvim (168 files on a 2-core CI runner), so a scheduled callback can wait
-- far longer than it does on an idle machine. The product behaviour is correct —
-- this is the test's budget, not a race to paper over (G33: a killed/slow child
-- is a red run, and a tight budget is how that happens).
local WAIT_MS = 10000

describe("prompt recall (G1/G2/G3)", function()
    local chat
    local real_worktree

    before_each(function()
        real_worktree = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            detect = function()
                return nil
            end,
        }
        chat = Chat.new(TAB, "side", {
            send = function()
                return true
            end,
        })
        chat:show()
        assert.is_true(chat:is_visible())
    end)

    after_each(function()
        if chat then
            pcall(vim.cmd, "stopinsert")
            chat._layout:hide()
            pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
            pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
            pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
            local wins = vim.api.nvim_list_wins()
            for i = 3, #wins do
                pcall(vim.api.nvim_win_close, wins[i], false)
            end
            chat = nil
        end
        package.loaded["pi.worktree"] = real_worktree
    end)

    --- The prompt window, falling back to the window holding the prompt buffer.
    ---@param c pi.Chat
    ---@return integer?
    local function prompt_win(c)
        local win = c._prompt:win()
        if win then
            return win
        end
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_buf(w) == c._prompt:buf() then
                return w
            end
        end
        return nil
    end

    --- Prompt buffer text, untrimmed (unlike `Prompt:text()`).
    ---@param c pi.Chat
    ---@return string
    local function prompt_text(c)
        return table.concat(vim.api.nvim_buf_get_lines(c._prompt:buf(), 0, -1, false), "\n")
    end

    --- Poll until the prompt buffer text equals `want` (recall edits are deferred).
    ---@param c pi.Chat
    ---@param want string
    ---@return boolean
    local function wait_prompt(c, want)
        return vim.wait(WAIT_MS, function()
            return prompt_text(c) == want
        end, 5)
    end

    --- Poll until the prompt window cursor is at `row`, column `col`.
    ---@param c pi.Chat
    ---@param row integer
    ---@param col integer
    ---@return boolean
    local function wait_cursor(c, row, col)
        return vim.wait(WAIT_MS, function()
            local win = prompt_win(c)
            if not win then
                return false
            end
            local cur = vim.api.nvim_win_get_cursor(win)
            return cur[1] == row and cur[2] == col
        end, 5)
    end

    --- Inject an in-memory history store with "one", "two", "three".
    ---@param c pi.Chat
    ---@return pi.PromptHistoryStore
    local function inject_store(c)
        local store = PH.Store.new({ path = false })
        -- Oldest first; "three" is the newest entry.
        store:add("one")
        store:add("two")
        store:add("three")
        c._prompt_history = store
        c._prompt_nav = nil
        return store
    end

    --- Fire the history-reset autocmd the way a buffer change would.
    ---@param c pi.Chat
    local function fire_text_changed(c)
        vim.api.nvim_exec_autocmds("TextChangedI", { buffer = c._prompt:buf() })
    end

    --- The insert-mode `<Up>` mapping as a dict.
    ---@param c pi.Chat
    ---@return table
    local function up_map(c)
        local win = assert(prompt_win(c))
        vim.api.nvim_set_current_win(win)
        local map = vim.fn.maparg("<Up>", "i", false, true)
        return map
    end

    it("G1: defers the draft edit and appends the cursor past a multi-line draft", function()
        chat:_set_prompt_draft("line one\nline two")
        assert.is_true(wait_prompt(chat, "line one\nline two"))
        assert.are.same({ "line one", "line two" }, vim.api.nvim_buf_get_lines(chat._prompt:buf(), 0, -1, false))
        -- Deferred with the buffer edit: cursor ends appended past the last line.
        assert.is_true(wait_cursor(chat, 2, #"line two"))
    end)

    it("G3: a second recall walks back instead of repeating the newest entry", function()
        inject_store(chat)
        local nav = assert(chat:_history_nav())
        assert.is_true(chat:history_prev())
        assert.is_true(wait_prompt(chat, "three"))
        assert.is_true(nav:navigating())
        -- Without the text comparison the deferred TextChangedI reset would
        -- leave nav off, and this second recall would show "three" again.
        assert.is_true(chat:history_prev())
        assert.is_true(wait_prompt(chat, "two"))
        assert.is_true(nav:navigating())
    end)

    it("G3: a manual edit resets navigation", function()
        inject_store(chat)
        local nav = assert(chat:_history_nav())
        assert.is_true(chat:history_prev())
        assert.is_true(wait_prompt(chat, "three"))
        assert.is_true(nav:navigating())
        vim.api.nvim_buf_set_lines(chat._prompt:buf(), 0, -1, false, { "typed by hand" })
        fire_text_changed(chat)
        assert.is_false(nav:navigating())
    end)

    it("G3: a simulated recall edit keeps navigation", function()
        inject_store(chat)
        local nav = assert(chat:_history_nav())
        assert.is_true(chat:history_prev())
        assert.is_true(wait_prompt(chat, "three"))
        assert.is_true(nav:navigating())
        -- Buffer text still equals `_last_applied_prompt`: a deferred
        -- TextChangedI from the recall itself must not reset navigation.
        fire_text_changed(chat)
        assert.is_true(nav:navigating())
        assert.are.equal("three", prompt_text(chat))
    end)

    it("G2: <Up> off the top line passes through as the literal string", function()
        local map = up_map(chat)
        assert.is_true(map.expr == 1 or map.expr == true, "expected an <expr> mapping")
        assert.is_true(type(map.callback) == "function")
        chat:_set_prompt_draft("line one\nline two")
        assert.is_true(wait_prompt(chat, "line one\nline two"))
        vim.api.nvim_win_set_cursor(assert(prompt_win(chat)), { 2, 0 })

        local ret = map.callback()
        -- The literal angle-bracket notation, not `vim.keycode("<Up>")` bytes.
        assert.equals("<Up>", ret)
        assert.are.equal("line one\nline two", prompt_text(chat))
    end)

    it("G2/G5: <Up> on the top line recalls the newest entry", function()
        inject_store(chat)
        vim.api.nvim_win_set_cursor(assert(prompt_win(chat)), { 1, 0 })

        local map = up_map(chat)
        local ret = map.callback()
        assert.equals("", ret)
        assert.is_true(wait_prompt(chat, "three"))
        assert.is_true(assert(chat:_history_nav()):navigating())
    end)
end)
