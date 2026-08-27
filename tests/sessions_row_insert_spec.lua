-- Sessions-list row keys a/i (issue #94): pressing a or i on a row opens that
-- session's chat and drops into Insert mode with the cursor appended past the
-- very end of its prompt draft (multi-line included). <CR>/o keep their plain
-- jump semantics.

local SessionList = require("pi.ui.sessions")
local Chat = require("pi.ui.chat")

--- Build a session whose chat counts calls to the two focus variants, with
--- just enough surface for status derivation and the name fetch.
---@param tab pi.TabId
local function spy_session(tab)
    local counts = { plain = 0, at_end = 0 }
    return {
        tab = tab,
        counts = counts,
        rpc = {
            is_running = function()
                return true
            end,
            send = function()
                return true
            end,
        },
        chat = {
            ensure_shown_and_focus_prompt = function()
                counts.plain = counts.plain + 1
            end,
            ensure_shown_and_focus_prompt_at_end = function()
                counts.at_end = counts.at_end + 1
            end,
            is_streaming = function()
                return false
            end,
            is_compacting = function()
                return false
            end,
        },
    }
end

--- Open the list against a one-session manager and press a key on its row.
--- Restores the real manager before returning.
---@param s table fake session under test (needs .rpc.send/.is_running, .chat methods)
---@param key string n-mode key to feed ("x" mode: process until typeahead drains)
local function press_on_list_row(s, key)
    local real_manager = package.loaded["pi.sessions.manager"]
    package.loaded["pi.sessions.manager"] = {
        list = function()
            return { s }
        end,
        get = function()
            return nil
        end,
    }
    local ok, err = pcall(function()
        SessionList.open()
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
    end)
    package.loaded["pi.sessions.manager"] = real_manager
    if not ok then
        error(err)
    end
end

--- Build a real Chat bound to the current tab, shown in side layout.
---@return pi.Chat
local function setup_chat()
    local chat = Chat.new(vim.api.nvim_get_current_tabpage(), "side", {
        send = function()
            return true
        end,
    })
    chat:show()
    assert.is_true(chat:is_visible())
    return chat
end

--- Set the prompt draft directly on the buffer (bypasses draft persistence).
---@param chat pi.Chat
---@param lines string[]
local function set_prompt_lines(chat, lines)
    vim.api.nvim_buf_set_lines(chat._prompt:buf(), 0, -1, false, lines)
end

--- Stub the manager to list exactly one session wrapping a real chat, run fn
--- inside, restore afterwards.
---@param chat pi.Chat
---@param fn fun()
local function with_managed_chat(chat, fn)
    local real_manager = package.loaded["pi.sessions.manager"]
    package.loaded["pi.sessions.manager"] = {
        list = function()
            return {
                {
                    tab = chat._tab,
                    rpc = {
                        is_running = function()
                            return true
                        end,
                        send = function()
                            return true
                        end,
                    },
                    chat = chat,
                },
            }
        end,
        get = function()
            return nil
        end,
    }
    local ok, err = pcall(fn)
    package.loaded["pi.sessions.manager"] = real_manager
    if not ok then
        error(err)
    end
end

--- Close the chat's windows/buffers hermetically.
---@param chat pi.Chat?
local function teardown_chat(chat)
    if not chat then
        return
    end
    pcall(vim.cmd, "stopinsert")
    chat._layout:hide()
    pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
end

--- Record every :command issued while fn runs (restores afterwards). Used to
--- prove the focus-end path fires "startinsert!" — insert MODE itself cannot
--- be observed headlessly (gotcha G5), so the command + cursor position are
--- the deterministic proxies.
---@param fn fun()
---@return string[] commands
local function capturing_vim_cmd(fn)
    local commands = {}
    local real_cmd = vim.cmd
    ---@param input string|table|function
    ---@return any
    vim.cmd = function(input)
        if type(input) == "string" then
            commands[#commands + 1] = input
        else
            commands[#commands + 1] = type(input) == "table" and tostring(input[1]) or "<fn>"
        end
        return real_cmd(input)
    end
    local ok, result = pcall(fn)
    vim.cmd = real_cmd
    if not ok then
        error(result)
    end
    return commands
end

describe("sessions list rows: a / i append-focus keys (#94)", function()
    before_each(function()
        SessionList._reset()
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
    end)

    it("a routes to the append-at-end focus variant", function()
        local s = spy_session(vim.api.nvim_get_current_tabpage())
        press_on_list_row(s, "a")
        assert.are.equal(1, s.counts.at_end)
        assert.are.equal(0, s.counts.plain)
    end)

    it("i routes to the append-at-end focus variant", function()
        local s = spy_session(vim.api.nvim_get_current_tabpage())
        press_on_list_row(s, "i")
        assert.are.equal(1, s.counts.at_end)
        assert.are.equal(0, s.counts.plain)
    end)

    it("<CR> keeps the plain jump variant", function()
        local s = spy_session(vim.api.nvim_get_current_tabpage())
        press_on_list_row(s, "<CR>")
        assert.are.equal(1, s.counts.plain)
        assert.are.equal(0, s.counts.at_end)
    end)

    it("o keeps the plain jump variant", function()
        local s = spy_session(vim.api.nvim_get_current_tabpage())
        press_on_list_row(s, "o")
        assert.are.equal(1, s.counts.plain)
        assert.are.equal(0, s.counts.at_end)
    end)
end)

describe("sessions list a/i end state with a real chat (#94)", function()
    local chat

    before_each(function()
        SessionList._reset()
    end)

    after_each(function()
        teardown_chat(chat)
        chat = nil
        pcall(SessionList.close)
        SessionList._reset()
    end)

    it("a lands the prompt cursor past the last character of a multi-line draft", function()
        local commands
        chat = setup_chat()
        set_prompt_lines(chat, { "first draft", "second tail" })

        -- Park the cursor mid-draft to prove the jump really relocates it.
        local pwin = chat._layout:prompt_win()
        vim.api.nvim_win_set_cursor(pwin, { 1, 3 })
        vim.api.nvim_set_current_win(chat._layout:history_win())

        with_managed_chat(chat, function()
            commands = capturing_vim_cmd(function()
                SessionList.open()
                vim.api.nvim_win_set_cursor(0, { 1, 0 })
                vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("a", true, false, true), "x", false)
                -- Insert MODE itself never sticks under headless (gotcha G5);
                -- the window + cursor end state does. Poll for those.
                vim.wait(1500, function()
                    return vim.api.nvim_get_current_win() == chat._layout:prompt_win()
                        and vim.deep_equal(vim.api.nvim_win_get_cursor(chat._layout:prompt_win()), {
                            2,
                            #"second tail",
                        })
                end, 25)
            end)
        end)

        assert.are.equal(pwin, vim.api.nvim_get_current_win())
        assert.same({ 2, #"second tail" }, vim.api.nvim_win_get_cursor(pwin))
        -- Focus must enter Insert mode past EOL (`A` semantics).
        assert.is_true(vim.tbl_contains(commands, "startinsert!"))
    end)

    it("i lands the prompt cursor at column 0 on an empty draft", function()
        local commands
        chat = setup_chat()

        with_managed_chat(chat, function()
            commands = capturing_vim_cmd(function()
                SessionList.open()
                vim.api.nvim_win_set_cursor(0, { 1, 0 })
                vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i", true, false, true), "x", false)
                vim.wait(1500, function()
                    return vim.api.nvim_get_current_win() == chat._layout:prompt_win()
                        and vim.deep_equal(vim.api.nvim_win_get_cursor(chat._layout:prompt_win()), { 1, 0 })
                end, 25)
            end)
        end)

        local pwin = chat._layout:prompt_win()
        assert.are.equal(pwin, vim.api.nvim_get_current_win())
        assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(pwin))
        assert.is_true(vim.tbl_contains(commands, "startinsert!"))
    end)
end)
