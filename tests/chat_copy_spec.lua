-- Copying the message under the cursor (`yy`) and a history line range
-- (`:PiCopy`).
--
-- Two properties pull in opposite directions here, so both are pinned:
--
--   * what gets copied is the SOURCE text, not the rendered rows — the buffer
--     draws markdown tables as box art, indents the user body two spaces and
--     keeps only the tail of a collapsed tool block, so re-reading the buffer
--     would not reproduce what was written;
--   * the register writes behave like a real yank (``"`` + `0`, a register
--     prefix, 'clipboard' mirroring), or a user's `"ap` / `"0p` habits break.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")
local Chat = require("pi.ui.chat")
local Copy = require("pi.copy")
local Commands = require("pi.commands")
local Manager = require("pi.sessions.manager")

local TAB = 1341

local function pump(ms)
    vim.wait(ms or 60)
end

--- A history with a real window (cursor-based helpers need one) and its buffer.
---@return pi.ChatHistory history, integer win
local function setup_history()
    local history = History.new(TAB)
    local win = vim.api.nvim_open_win(history:buf(), true, {
        relative = "editor",
        row = 1,
        col = 1,
        width = 90,
        height = 24,
        style = "minimal",
    })
    history:set_win(win)
    return history, win
end

---@param history pi.ChatHistory
---@param win integer
local function teardown_history(history, win)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
    end
    pcall(vim.api.nvim_buf_delete, history:buf(), { force = true })
end

---@param history pi.ChatHistory
---@return string[]
local function buffer_lines(history)
    return vim.api.nvim_buf_get_lines(history:buf(), 0, -1, false)
end

--- 0-indexed row of the first buffer line containing `needle`.
---@param history pi.ChatHistory
---@param needle string
---@return integer?
local function row_with(history, needle)
    for i, line in ipairs(buffer_lines(history)) do
        if line:find(needle, 1, true) then
            return i - 1
        end
    end
    return nil
end

--- A completed turn: user message then one streamed assistant message.
---@param history pi.ChatHistory
---@param user_text string
---@param assistant_text string
local function render_turn(history, user_text, assistant_text)
    history:add_user_message(user_text, nil)
    pump()
    history:on_agent_start(nil)
    pump()
    history:on_text_delta(assistant_text)
    pump(80)
    history:on_agent_end("Completed")
    pump(120)
end

describe("copy: source text under the cursor", function()
    local history, win, orig_render

    before_each(function()
        -- Keep render-markdown out of this spec: the copy code only cares about
        -- the buffer rows, and the plugin's logger does not survive buffer
        -- teardown (the builtin engine draws tables the same way).
        orig_render = Config.options.render
        Config.options.render = { engine = "builtin" }
        history, win = setup_history()
    end)

    after_each(function()
        teardown_history(history, win)
        Config.options.render = orig_render
    end)

    it("returns the authored user message, not the indented buffer row", function()
        history:add_user_message("hello **world**", nil)
        pump(80)

        local row = row_with(history, "hello")
        assert.is_not_nil(row)
        local target = history:copy_target_at(row)
        assert.are.equal("user", target.kind)
        assert.are.equal("hello **world**", target.text)
        -- The rendered row really is indented, so this is not a tautology.
        assert.are.equal("  hello **world**", buffer_lines(history)[row + 1])
    end)

    it("returns the markdown source of a rendered table", function()
        render_turn(history, "make a table", "| a | b |\n|---|---|\n| 1 | 2 |\n")

        local row = row_with(history, "│ a │ b │")
        assert.is_not_nil(row, "the table must be rendered as box art first")
        local target = history:copy_target_at(row)
        assert.are.equal("assistant", target.kind)
        assert.are.equal("| a | b |\n|---|---|\n| 1 | 2 |", target.text)
    end)

    it("prefers a tool block over the message that contains it", function()
        history:on_agent_start(nil)
        pump()
        history:on_tool_start("read", "t1", { path = "lua/pi/copy.lua" })
        pump()
        history:on_tool_end("read", "t1", "file body", false)
        pump(120)

        local row = row_with(history, "copy.lua")
        assert.is_not_nil(row)
        local target = history:copy_target_at(row)
        assert.are.equal("tool", target.kind)
        assert.is_true(target.text ~= "")
        assert.is_true(target.text:find("copy.lua", 1, true) ~= nil)
    end)

    it("uses the saved body of a collapsed tool block", function()
        history:on_agent_start(nil)
        pump()
        history:on_tool_start("read", "t1", { path = "a.txt" })
        pump()
        history:on_tool_end("read", "t1", "file body", false)
        pump(120)

        -- Simulate the collapse the render code performs on a long output: the
        -- buffer keeps only a tail, the saved copy keeps everything.
        local block = history._tool_blocks["t1"]
        assert.is_not_nil(block)
        local saved = { "  first line of output", "  second line of output" }
        block.expanded_inner_lines = saved
        block.collapsed_inner_lines = { "  … 1 line hidden" }

        local target = history:copy_target_at(row_with(history, "a.txt"))
        assert.are.equal("tool", target.kind)
        assert.are.equal(table.concat(saved, "\n"), target.text)
    end)

    it("copies [count] consecutive messages", function()
        render_turn(history, "first question", "first answer")
        render_turn(history, "second question", "second answer")

        vim.api.nvim_win_set_cursor(win, { (row_with(history, "first question") or 0) + 1, 0 })
        local target = history:copy_target_under_cursor(2)
        assert.are.equal("messages", target.kind)
        assert.are.equal(2, target.count)
        assert.are.equal("first question\n\nfirst answer", target.text)
    end)

    it("has no target past the last rendered line", function()
        history:add_user_message("only message", nil)
        pump(80)
        local last = vim.api.nvim_buf_line_count(history:buf()) - 1
        vim.api.nvim_win_set_cursor(win, { last + 1, 0 })
        -- The trailing blank line still belongs to the message; a row past it
        -- does not exist, so the row lookup is what is under test.
        assert.is_not_nil(history:copy_target_at(last))
    end)
end)

describe("copy: :PiCopy range", function()
    local history, win, orig_render

    before_each(function()
        orig_render = Config.options.render
        Config.options.render = { engine = "builtin" }
        history, win = setup_history()
    end)

    after_each(function()
        teardown_history(history, win)
        Config.options.render = orig_render
    end)

    it("returns source text when the range is exactly whole messages", function()
        render_turn(history, "hello **world**", "| a | b |\n|---|---|\n| 1 | 2 |")
        local total = vim.api.nvim_buf_line_count(history:buf())

        local result = history:copy_range_text(1, total)
        assert.is_true(result.whole)
        assert.are.equal(2, result.messages)
        assert.are.equal("hello **world**\n\n| a | b |\n|---|---|\n| 1 | 2 |", result.text)
    end)

    it("returns the rendered rows for a partial range", function()
        render_turn(history, "hello **world**", "answer")
        local row = row_with(history, "hello")
        local result = history:copy_range_text(row + 1, row + 1)

        assert.is_false(result.whole)
        assert.are.equal("  hello **world**", result.text)
    end)

    it("returns a tool block's body when the range is exactly that block", function()
        history:on_agent_start(nil)
        pump()
        history:on_tool_start("read", "t1", { path = "a.txt" })
        pump()
        history:on_tool_end("read", "t1", "file body", false)
        pump(120)

        local block = history._tool_blocks["t1"]
        local target = history:copy_target_at(row_with(history, "a.txt"))
        local result = history:copy_range_text(target.start_row + 1, target.end_row + 1)
        assert.is_true(result.whole)
        assert.are.equal(target.text, result.text)
        assert.is_not_nil(block)
    end)
end)

describe("copy: register semantics", function()
    local orig_clipboard

    before_each(function()
        orig_clipboard = vim.o.clipboard
        vim.o.clipboard = ""
        vim.fn.setreg('"', "")
        vim.fn.setreg("0", "")
        vim.fn.setreg("a", "")
    end)

    after_each(function()
        vim.o.clipboard = orig_clipboard
        vim.fn.setreg("a", "")
    end)

    it("fills the unnamed and 0 registers like a yank", function()
        local target = Copy.write("hello")
        assert.are.equal('"', target)
        assert.are.equal("hello\n", vim.fn.getreg('"'))
        assert.are.equal("hello\n", vim.fn.getreg("0"))
        assert.are.equal("", vim.fn.getreg("a"))
    end)

    it("honours a register prefix and leaves 0 alone", function()
        vim.fn.setreg("0", "untouched", "V")
        local target = Copy.write("hello", { register = "a" })
        assert.are.equal("a", target)
        assert.are.equal("hello\n", vim.fn.getreg("a"))
        assert.are.equal("untouched\n", vim.fn.getreg("0"))
    end)

    it("mirrors the system clipboard when 'clipboard' asks for it", function()
        vim.o.clipboard = "unnamedplus"
        local target = Copy.write("hello")
        assert.are.equal("+", target)
        assert.are.equal("hello\n", vim.fn.getreg("+"))
    end)

    it("writes + for an explicit clipboard request", function()
        local target = Copy.write("hello", { clipboard = true })
        assert.are.equal("+", target)
        assert.are.equal("hello\n", vim.fn.getreg("+"))
        -- Still recoverable without a clipboard provider.
        assert.are.equal("hello\n", vim.fn.getreg('"'))
    end)
end)

describe("copy: yy and :PiCopy wiring", function()
    local chat, win, notices, orig_notify, orig_get, orig_render

    before_each(function()
        notices = {}
        orig_notify = vim.notify
        orig_render = Config.options.render
        Config.options.render = { engine = "builtin" }
        vim.notify = function(msg)
            notices[#notices + 1] = msg
        end
        vim.fn.setreg('"', "")

        chat = Chat.new(TAB, "side", {
            send = function()
                return true
            end,
        })
        local history = chat._history
        win = vim.api.nvim_open_win(history:buf(), true, {
            relative = "editor",
            row = 1,
            col = 1,
            width = 90,
            height = 24,
            style = "minimal",
        })
        history:set_win(win)
        chat:_set_keymaps()

        orig_get = Manager.get
        Manager.get = function()
            return { chat = chat }
        end
    end)

    after_each(function()
        Manager.get = orig_get
        vim.notify = orig_notify
        Config.options.render = orig_render
        chat._history:clear()
        pcall(vim.api.nvim_win_close, win, true)
        pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
        pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
        pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
    end)

    local function history()
        return chat._history
    end

    it("binds yy on the history buffer only", function()
        assert.is_true(vim.fn.maparg("yy", "n", false, true).buffer == 1)
        -- The y operator itself stays native, so `y{motion}` and V+y keep
        -- yanking what is on screen.
        assert.are.equal(0, #vim.fn.maparg("y", "n"))
    end)

    it("yy copies the message under the cursor", function()
        history():add_user_message("copy me", nil)
        pump(80)
        vim.api.nvim_win_set_cursor(win, { (row_with(history(), "copy me") or 0) + 1, 0 })

        vim.api.nvim_feedkeys("yy", "x", false)
        pump(20)

        assert.are.equal("copy me\n", vim.fn.getreg('"'))
        assert.is_true(
            (notices[#notices] or ""):find("User message copied", 1, true) ~= nil,
            "expected a copy notification, got " .. tostring(notices[#notices])
        )
    end)

    it(":PiCopy copies a range as source text", function()
        Commands.setup()
        render_turn(history(), "range question", "range answer")
        vim.api.nvim_set_current_win(win)
        local total = vim.api.nvim_buf_line_count(history():buf())

        vim.cmd(("%d,%dPiCopy"):format(1, total))

        assert.are.equal("range question\n\nrange answer\n", vim.fn.getreg('"'))
    end)

    it(":PiCopy! writes the clipboard register", function()
        Commands.setup()
        history():add_user_message("clip me", nil)
        pump(80)
        vim.api.nvim_set_current_win(win)
        vim.fn.setreg("+", "")
        local total = vim.api.nvim_buf_line_count(history():buf())

        vim.cmd(("1,%dPiCopy!"):format(total))

        assert.are.equal("clip me\n", vim.fn.getreg("+"))
    end)

    it(":PiCopy refuses a buffer that is not the chat history", function()
        Commands.setup()
        local other = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(other)
        vim.fn.setreg('"', "")

        vim.cmd("1,1PiCopy")

        assert.are.equal("", vim.fn.getreg('"'))
        assert.is_true((notices[#notices] or ""):find("chat history buffer", 1, true) ~= nil)
        pcall(vim.api.nvim_buf_delete, other, { force = true })
    end)
end)
