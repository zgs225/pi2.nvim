-- Agent bash tool output routed to a terminal window (bash.terminal, #65).
--
-- Covers: history renders a summary card instead of the full output; replay
-- keeps the legacy inline rendering; BashTerminal delta computation from
-- cumulative tool_execution_update text; Chat routing opens the terminal
-- window inside the chat layout and clears it with the session.

local Chat = require("pi.ui.chat")
local History = require("pi.ui.chat.history")
local BashTerminal = require("pi.ui.chat.bash_terminal")
local Config = require("pi.config")

local TAB = 965

local function pump(ms)
    vim.wait(ms or 50)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function text_of(buf)
    return table.concat(lines_of(buf), "\n")
end

local function rows_with(buf, sub)
    local out = {}
    for i, l in ipairs(lines_of(buf)) do
        if l:find(sub, 1, true) then
            out[#out + 1] = i - 1
        end
    end
    return out
end

--- Simulate a tool_execution_update with cumulative text.
local function update_msg(text)
    return { partialResult = { content = { { type = "text", text = text } } } }
end

--- Simulate a tool_execution_end result.
local function result_msg(text)
    return { content = { { type = "text", text = text } } }
end

describe("bash terminal mode (bash.terminal)", function()
    local saved_bash

    before_each(function()
        saved_bash = vim.deepcopy(Config.options.bash)
        Config.options.bash.terminal = true
    end)

    after_each(function()
        Config.options.bash = saved_bash
    end)

    describe("history summary card", function()
        it("shows the command but not the streamed output", function()
            local h = History.new(TAB)
            h:on_tool_start("bash", "call1", { command = "make test" })
            pump(60)
            h:on_tool_update("bash", "call1", update_msg("one\ntwo\nthree"))
            pump(60)
            h:on_tool_end("bash", "call1", result_msg("one\ntwo\nthree"), false)
            pump(60)

            local buf = h:buf()
            assert.is_true(#rows_with(buf, "make test") >= 1, "command visible")
            assert.is_true(#rows_with(buf, "3 lines") == 1, "summary shows line count")
            assert.is_true(#rows_with(buf, ":PiBashOpen") == 1, "summary points at :PiBashOpen")
            assert.is_true(#rows_with(buf, "one") == 0, "output not rendered into history")
            assert.is_true(#rows_with(buf, "three") == 0, "output not rendered into history")
        end)

        it("marks failures in the summary", function()
            local h = History.new(TAB)
            h:on_tool_start("bash", "call1", { command = "false" })
            pump(60)
            h:on_tool_end("bash", "call1", result_msg("Command aborted"), true)
            pump(60)

            local buf = h:buf()
            assert.is_true(#rows_with(buf, "0 lines") == 1, "zero-line summary rendered")
            assert.is_true(text_of(buf):find(Config.options.labels.tool_failure, 1, true) ~= nil)
        end)

        it("keeps legacy inline rendering during replay", function()
            local h = History.new(TAB)
            h._replaying = true
            h:on_tool_start("bash", "call1", { command = "echo hi" })
            pump(60)
            h:on_tool_end("bash", "call1", result_msg("hi"), false)
            pump(60)

            local buf = h:buf()
            assert.is_true(#rows_with(buf, "hi") >= 1, "replay renders output inline")
            assert.is_true(#rows_with(buf, ":PiBashOpen") == 0, "no terminal summary on replay")
        end)

        it("keeps legacy rendering when disabled", function()
            Config.options.bash.terminal = false
            local h = History.new(TAB)
            h:on_tool_start("bash", "call1", { command = "echo hi" })
            pump(60)
            h:on_tool_end("bash", "call1", result_msg("hi"), false)
            pump(60)

            local buf = h:buf()
            assert.is_true(#rows_with(buf, "hi") >= 1, "output rendered inline")
            assert.is_true(#rows_with(buf, ":PiBashOpen") == 0)
        end)
    end)

    describe("BashTerminal delta computation", function()
        local function stub_layout()
            return {
                titles = {},
                opened = 0,
                closed = 0,
                open_terminal_win = function(self2)
                    self2.opened = self2.opened + 1
                end,
                set_terminal_title = function(self2, text)
                    self2.titles[#self2.titles + 1] = text
                end,
                close_terminal_win = function(self2)
                    self2.closed = self2.closed + 1
                end,
            }
        end

        local handlers = {
            focus_prompt = function() end,
            on_abort = function() end,
        }

        it("forwards only the delta of cumulative updates", function()
            local layout = stub_layout()
            local bt = BashTerminal.new(TAB, layout, handlers)
            bt:start("call1", "seq 1 10")
            assert.is_true(bt:is_running())
            assert.is_true(bt:has_output())

            bt:update("call1", "1\n2\n3")
            assert.equals(2, bt:line_count())
            -- Same cumulative text again: no double counting.
            bt:update("call1", "1\n2\n3")
            assert.equals(2, bt:line_count())
            -- Grown cumulatively: only the new part counts.
            bt:update("call1", "1\n2\n3\n4\n5")
            assert.equals(4, bt:line_count())

            bt:finish("call1", true, "done")
            assert.is_false(bt:is_running())
            local last = layout.titles[#layout.titles]
            assert.is_true(last:find("done", 1, true) ~= nil, "winbar carries status")
            assert.is_true(last:find("4 lines", 1, true) ~= nil, "winbar carries line count")

            -- Late updates for a finished run are ignored.
            bt:update("call1", "1\n2\n3\n4\n5\n6")
            assert.equals(4, bt:line_count())
            bt:destroy()
        end)

        it("ignores updates for other tool calls", function()
            local layout = stub_layout()
            local bt = BashTerminal.new(TAB, layout, handlers)
            bt:start("call1", "ls")
            bt:update("call2", "x\ny\nz")
            assert.equals(0, bt:line_count())
            bt:destroy()
        end)

        it("writes a separator header when reused across runs", function()
            local layout = stub_layout()
            local bt = BashTerminal.new(TAB, layout, handlers)
            bt:start("call1", "one")
            bt:finish("call1", true, "done")
            bt:start("call2", "two")
            assert.equals(2, layout.opened, "window re-open request on each run")
            bt:destroy()
            assert.is_false(bt:has_output())
        end)
    end)

    describe("Chat routing", function()
        local chat

        local function setup_chat()
            chat = Chat.new(TAB, "side", {
                send = function()
                    return true
                end,
            })
            chat:ensure_shown_and_focus_prompt()
        end

        local function teardown_chat()
            if not chat then
                return
            end
            if chat._bash_terminal then
                chat._bash_terminal:destroy()
            end
            chat._layout:hide()
            pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
            pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
            pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
            local wins = vim.api.nvim_list_wins()
            for i = 2, #wins do
                pcall(vim.api.nvim_win_close, wins[i], false)
            end
            chat = nil
        end

        after_each(teardown_chat)

        it("streams agent bash output into a terminal window inside the layout", function()
            setup_chat()
            local layout = chat._layout

            chat:on_tool_start("bash", "call1", { command = "seq 1 200" })
            pump(60)
            local twin = layout:terminal_win()
            assert.is_not_nil(twin, "terminal window opened")
            local tbuf = vim.api.nvim_win_get_buf(twin)
            assert.equals(chat:bash_terminal():buf(), tbuf)

            chat:on_tool_update("bash", "call1", update_msg("a\nb\nc"))
            pump(60)
            chat:on_tool_end("bash", "call1", result_msg("a\nb\nc"), false)
            pump(60)

            -- Terminal buffer received the output (CRLF-converted stream).
            local ttext = text_of(tbuf)
            assert.is_true(ttext:find("a", 1, true) ~= nil, "output landed in terminal")
            assert.is_true(ttext:find("$ seq 1 200", 1, true) ~= nil, "command header present")

            -- History shows only the summary card.
            local htext = text_of(chat._history:buf())
            assert.is_true(htext:find("3 lines", 1, true) ~= nil, "summary card rendered")
            assert.is_true(htext:find("\na\n", 1, true) == nil, "no raw output in history")
        end)

        it("does not open a terminal for non-bash tools", function()
            setup_chat()
            chat:on_tool_start("read", "call2", { path = "x.lua" })
            pump(60)
            assert.is_nil(chat._layout:terminal_win())
            chat:on_tool_end("read", "call2", result_msg("data"), false)
            pump(60)
        end)

        it("destroys the terminal on session clear", function()
            setup_chat()
            chat:on_tool_start("bash", "call1", { command = "ls" })
            pump(60)
            assert.is_true(chat:bash_terminal():has_output())

            chat:clear()
            pump(60)
            assert.is_nil(chat._bash_terminal, "terminal instance dropped on clear")
        end)

        it(":PiBashOpen reports when there is no output yet", function()
            setup_chat()
            -- No bash ran: the API path notifies and stays a no-op.
            chat:open_bash_terminal(false)
            assert.is_nil(chat._layout:terminal_win())
        end)
    end)
end)
