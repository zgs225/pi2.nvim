-- Automatic worktree integration: the parent chat keeps a persistent, visible
-- record of every integration event instead of only firing a transient
-- notification. Records are written straight into the history buffer (so they
-- survive the chat having no window) and are replayed on the next show when the
-- buffer could not take them yet.
--
-- `pi.worktree` is stubbed through package.loaded; no git is involved.

local Chat = require("pi.ui.chat")
local Config = require("pi.config")

local TAB = 1301
local GLYPH = "󰙅"

---@param chat pi.Chat
---@return string[]
local function history_lines(chat)
    return vim.api.nvim_buf_get_lines(chat._history:buf(), 0, -1, false)
end

---@param chat pi.Chat
---@param needle string
---@return integer
local function count_occurrences(chat, needle)
    local count = 0
    for _, line in ipairs(history_lines(chat)) do
        if line:find(needle, 1, true) then
            count = count + 1
        end
    end
    return count
end

---@param chat pi.Chat
---@param fn fun(): boolean
---@return boolean
local function wait_for(chat, fn)
    local ok = vim.wait(1000, fn, 10)
    assert.is_true(ok, "timed out waiting for the history buffer")
    return ok
end

local function teardown_chat(chat)
    chat._layout:hide()
    pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
    local wins = vim.api.nvim_list_wins()
    for i = 2, #wins do
        pcall(vim.api.nvim_win_close, wins[i], false)
    end
end

---@return pi.Chat
local function new_chat()
    return Chat.new(TAB, "side", {
        send = function()
            return true
        end,
    })
end

describe("chat worktree integration record", function()
    local real_worktree_module

    before_each(function()
        Config.setup({})
        real_worktree_module = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            detect = function()
                return nil
            end,
            status = function() end,
        }
    end)

    after_each(function()
        package.loaded["pi.worktree"] = real_worktree_module
    end)

    it("records an event in the history buffer even before the chat is shown", function()
        local chat = new_chat()
        assert.is_nil(chat._layout:history_win(), "no window yet")

        chat:show_worktree_integration("wt-a → queued (parent_busy)")

        wait_for(chat, function()
            return count_occurrences(chat, "wt-a → queued (parent_busy)") == 1
        end)
        local found = false
        for _, line in ipairs(history_lines(chat)) do
            if line:sub(1, #GLYPH) == GLYPH and line:find("wt-a → queued", 1, true) then
                found = true
            end
        end
        assert.is_true(found, "the record carries the worktree glyph")
        teardown_chat(chat)
    end)

    it("keeps the record across show/hide without duplicating it", function()
        local chat = new_chat()
        chat:show_worktree_integration("wt-a → applied 2 file(s)")
        wait_for(chat, function()
            return count_occurrences(chat, "wt-a → applied 2 file(s)") == 1
        end)

        chat:show()
        vim.wait(200, function()
            return false
        end, 10)
        assert.are.equal(1, count_occurrences(chat, "wt-a → applied 2 file(s)"))

        chat._layout:hide()
        chat:show()
        vim.wait(200, function()
            return false
        end, 10)
        assert.are.equal(1, count_occurrences(chat, "wt-a → applied 2 file(s)"))
        teardown_chat(chat)
    end)

    it("appends an event that arrives while the chat is hidden", function()
        local chat = new_chat()
        chat:show()
        vim.wait(100, function()
            return false
        end, 10)
        chat._layout:hide()

        chat:show_worktree_integration("wt-b → applying 1 file(s)")
        wait_for(chat, function()
            return count_occurrences(chat, "wt-b → applying 1 file(s)") == 1
        end)

        chat:show()
        vim.wait(200, function()
            return false
        end, 10)
        assert.are.equal(1, count_occurrences(chat, "wt-b → applying 1 file(s)"))
        teardown_chat(chat)
    end)

    it("replays a record the buffer could not take yet on the next show", function()
        local chat = new_chat()
        -- Simulate a record whose write could not land: pending, buffer clean.
        chat._worktree_records = { { text = "wt-c → needs attention: conflict", rendered = false } }
        local buf = chat._history:buf()
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
        vim.bo[buf].modifiable = false
        assert.are.equal(0, count_occurrences(chat, "wt-c → needs attention"))

        chat:show()
        wait_for(chat, function()
            return count_occurrences(chat, "wt-c → needs attention: conflict") == 1
        end)
        assert.is_true(chat._worktree_records[1].rendered)
        teardown_chat(chat)
    end)

    it("records every integration state the module reports, in order", function()
        local chat = new_chat()
        local texts = {
            "wt-a → queued (parent_dirty)",
            "wt-a → applying 3 file(s)",
            "wt-a → resolving in its checkout (attempt 1/1)",
            "wt-a → applied 3 file(s) · checkout removed (snapshot kept)",
            "wt-b → needs attention: conflict (parent checkout differs)",
        }
        for _, text in ipairs(texts) do
            chat:show_worktree_integration(text)
        end
        wait_for(chat, function()
            return count_occurrences(chat, texts[#texts]) == 1
        end)

        local rows = {}
        for _, line in ipairs(history_lines(chat)) do
            for _, text in ipairs(texts) do
                if line:find(text, 1, true) then
                    rows[#rows + 1] = text
                end
            end
        end
        assert.are.same(texts, rows)
        teardown_chat(chat)
    end)

    it("renders a multi-line message as one indented record", function()
        local chat = new_chat()
        chat:show_worktree_integration("wt-a → needs attention: conflict\nparent HEAD moved")
        wait_for(chat, function()
            return count_occurrences(chat, "parent HEAD moved") == 1
        end)

        local first, second
        for _, line in ipairs(history_lines(chat)) do
            if line:find("needs attention: conflict", 1, true) then
                first = line
            elseif line:find("parent HEAD moved", 1, true) then
                second = line
            end
        end
        assert.are.equal(GLYPH .. " wt-a → needs attention: conflict", first)
        assert.are.equal("  parent HEAD moved", second)
        teardown_chat(chat)
    end)

    it("ignores empty text and bounds the record history", function()
        local chat = new_chat()
        chat:show_worktree_integration("   ")
        chat:show_worktree_integration(nil)
        assert.are.equal(0, #chat._worktree_records)

        for i = 1, 25 do
            chat:show_worktree_integration(("wt-%d → queued"):format(i))
        end
        assert.are.equal(20, #chat._worktree_records)
        assert.are.equal("wt-25 → queued", chat._worktree_records[#chat._worktree_records].text)
        assert.are.equal("wt-6 → queued", chat._worktree_records[1].text)
        teardown_chat(chat)
    end)

    it("drops records on a conversation reset", function()
        local chat = new_chat()
        chat:show_worktree_integration("wt-a → applied 1 file(s)")
        wait_for(chat, function()
            return count_occurrences(chat, "wt-a → applied 1 file(s)") == 1
        end)

        chat:clear()
        assert.are.equal(0, #chat._worktree_records)
        vim.wait(100, function()
            return false
        end, 10)
        assert.are.equal(0, count_occurrences(chat, "wt-a → applied 1 file(s)"))
        teardown_chat(chat)
    end)

    it("highlights the record with the worktree integration groups", function()
        local chat = new_chat()
        chat:show_worktree_integration("wt-a → applied 2 file(s)")
        wait_for(chat, function()
            return count_occurrences(chat, "wt-a → applied 2 file(s)") == 1
        end)

        local ns_all = -1
        local groups = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat._history:buf(), ns_all, 0, -1, { details = true })) do
            local hl = mark[4] and mark[4].hl_group
            if hl then
                groups[hl] = true
            end
        end
        assert.is_true(groups.PiWorktreeIntegrationIcon == true)
        assert.is_true(groups.PiWorktreeIntegration == true)
        teardown_chat(chat)
    end)
end)
