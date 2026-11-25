-- User message alignment (`user_message_align`).
--
-- The default is "left" and must stay byte-identical to the rendering that
-- existed before the option: body lines indented two spaces, no padding, no
-- bookkeeping. "right" pushes the label and the body to the window's right
-- edge, which in a buffer can only be done with padding spaces — so the block
-- has to be recomputed when the window width changes, and its body lines have
-- to be hard-wrapped (a soft-wrapped continuation would restart at column 0).
--
-- These assert buffer content and extmarks; the visual result (font-dependent
-- glyph widths, the actual right edge on screen) needs a GUI screenshot.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")
local Highlights = require("pi.ui.highlights")

local TAB = 1351
local ICON = Config.options.labels.user_message

local function pump(ms)
    vim.wait(ms or 60)
end

--- A history shown in a float of a known text width, so `_history_width()` is
--- deterministic regardless of the editor size.
---@param width integer
---@return pi.ChatHistory history, integer win
local function setup_history(width)
    local history = History.new(TAB)
    local win = vim.api.nvim_open_win(history:buf(), true, {
        relative = "editor",
        row = 1,
        col = 1,
        width = width,
        height = 24,
        style = "minimal",
    })
    history:set_win(win)
    pump(20)
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

---@param text string
---@return integer
local function dw(text)
    return vim.fn.strdisplaywidth(text)
end

--- The right edge right-aligned lines must end on: the text-area width minus
--- the one-column right margin `history.lua` keeps.
---@param history pi.ChatHistory
---@return integer
local function edge(history)
    return history:_history_width() - 1
end

--- Non-blank buffer lines that are not a label row (a row whose first
--- non-blank character is the user icon) — i.e. the rendered message body.
--- Trimmed for the test, because a right-aligned row carries leading padding.
---@param history pi.ChatHistory
---@return string[]
local function body_lines(history)
    local out = {}
    for _, line in ipairs(buffer_lines(history)) do
        local trimmed = vim.trim(line)
        if trimmed ~= "" and not vim.startswith(trimmed, ICON) then
            out[#out + 1] = line
        end
    end
    return out
end

--- The label row as written (padding included, so its right edge is measurable).
---@param history pi.ChatHistory
---@return string?
local function label_line(history)
    for _, line in ipairs(buffer_lines(history)) do
        if vim.startswith(vim.trim(line), ICON) then
            return line
        end
    end
    return nil
end

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

describe("user message alignment", function()
    local history, win, orig

    before_each(function()
        Highlights.setup()
        orig = Config.options
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    after_each(function()
        if history then
            teardown_history(history, win)
            history, win = nil, nil
        end
        Config.options.user_message_align = orig.user_message_align
        Config.options.render = orig.render
        require("pi.ui.render")._reset()
    end)

    describe("left (default)", function()
        it("is the shipped default", function()
            -- `make test` runs with the shipped defaults, not a user config.
            assert.are.equal("left", Config.options.user_message_align)
        end)

        it("indents the body two spaces and pads nothing", function()
            history, win = setup_history(40)
            history:add_user_message("hello there", nil)
            pump(80)

            local body = body_lines(history)
            assert.are.equal(1, #body)
            assert.are.equal("  hello there", body[1])
            assert.are.equal(2 + #"hello there", #body[1], "no leading padding")
        end)

        it("keeps the label flush left and tracks no block", function()
            history, win = setup_history(40)
            history:add_user_message("hi", nil)
            pump(80)

            local label = label_line(history)
            assert.is_not_nil(label)
            assert.are.equal(ICON, label:sub(1, #ICON), "label starts at column 0")
            assert.are.equal(0, #history._user_blocks, "left alignment stores nothing")
        end)
    end)

    describe("right", function()
        before_each(function()
            Config.options.user_message_align = "right"
        end)

        it("pushes the body to the right edge with display-width padding", function()
            history, win = setup_history(40)
            history:add_user_message("hello there", nil)
            pump(80)

            local body = body_lines(history)
            assert.are.equal(1, #body)
            assert.are.equal("hello there", vim.trim(body[1]))
            assert.are.equal(edge(history), dw(body[1]), "body ends on the right edge")
        end)

        it("pads by display width, not byte length", function()
            history, win = setup_history(40)
            history:add_user_message("你好", nil)
            pump(80)

            local body = body_lines(history)
            assert.are.equal("你好", vim.trim(body[1]))
            assert.are.equal(edge(history), dw(body[1]), "CJK text still ends on the edge")
        end)

        it("right-aligns the label with the body", function()
            history, win = setup_history(40)
            history:add_user_message("hi", nil)
            pump(80)

            local label = label_line(history)
            assert.is_not_nil(label)
            assert.are.equal(edge(history), dw(label), "label ends on the right edge")
        end)

        it("hard-wraps a line wider than the window and pads every chunk", function()
            history, win = setup_history(40)
            history:add_user_message(string.rep("x", 120), nil)
            pump(80)

            local body = body_lines(history)
            assert.is_true(#body >= 4, "long line wrapped into several rows")
            for _, line in ipairs(body) do
                assert.are.equal(edge(history), dw(line), "every chunk ends on the right edge")
            end
            assert.are.equal(120, #table.concat(vim.tbl_map(vim.trim, body), ""), "no characters lost")
        end)

        it("keeps blank message lines blank instead of padding them", function()
            history, win = setup_history(40)
            history:add_user_message("first\n\nthird", nil)
            pump(80)

            local lines = buffer_lines(history)
            local blank_rows = 0
            for _, line in ipairs(lines) do
                if line == "" then
                    blank_rows = blank_rows + 1
                end
            end
            assert.is_true(blank_rows >= 2, "separator blanks stay empty")
            for _, line in ipairs(lines) do
                if vim.trim(line) == "" then
                    assert.are.equal("", line, "a blank row carries no padding")
                end
            end
        end)

        it("still copies the authored text, not the padded rows", function()
            history, win = setup_history(40)
            history:add_user_message("hello **world**", nil)
            pump(80)

            local target = history:copy_target_at(row_with(history, "hello"))
            assert.are.equal("user", target.kind)
            assert.are.equal("hello **world**", target.text)
        end)
    end)

    describe("resize", function()
        before_each(function()
            Config.options.user_message_align = "right"
        end)

        it("re-pads the block for the new window width", function()
            history, win = setup_history(40)
            history:add_user_message("hello there", nil)
            pump(80)
            assert.are.equal(39, dw(body_lines(history)[1]))

            vim.api.nvim_win_set_config(win, { relative = "editor", row = 1, col = 1, width = 60, height = 24 })
            vim.api.nvim_exec_autocmds("WinResized", {})
            pump(120)

            local body = body_lines(history)
            assert.are.equal(1, #body)
            assert.are.equal("hello there", vim.trim(body[1]))
            assert.are.equal(edge(history), dw(body[1]), "re-padded to the new edge")
            assert.are.equal(59, dw(body[1]))
        end)

        it("re-wraps when the window gets narrower, keeping the content", function()
            history, win = setup_history(60)
            history:add_user_message(string.rep("y", 50), nil)
            pump(80)
            assert.are.equal(1, #body_lines(history), "fits on one row at 60 columns")

            vim.api.nvim_win_set_config(win, { relative = "editor", row = 1, col = 1, width = 30, height = 24 })
            vim.api.nvim_exec_autocmds("WinResized", {})
            pump(120)

            local body = body_lines(history)
            assert.is_true(#body >= 2, "the line wrapped after shrinking")
            assert.are.equal(50, #table.concat(vim.tbl_map(vim.trim, body), ""), "no characters lost")
            for _, line in ipairs(body) do
                assert.are.equal(edge(history), dw(line), "every chunk ends on the new edge")
            end
        end)

        it("keeps the turn anchor and the copy entry on the label row", function()
            history, win = setup_history(40)
            history:add_user_message("hi", nil)
            pump(80)

            vim.api.nvim_win_set_config(win, { relative = "editor", row = 1, col = 1, width = 60, height = 24 })
            vim.api.nvim_exec_autocmds("WinResized", {})
            pump(120)

            local label_row ---@type integer?
            for i, line in ipairs(buffer_lines(history)) do
                if vim.startswith(vim.trim(line), ICON) then
                    label_row = i - 1
                end
            end
            assert.is_not_nil(label_row)

            local tns = vim.api.nvim_get_namespaces()["pi-chat-turn"]
            local pos = vim.api.nvim_buf_get_extmark_by_id(history:buf(), tns, history._turn_anchors[1], {})
            assert.are.equal(label_row, pos[1], "[[ / ]] still land on the label")

            local target = history:copy_target_at(label_row)
            assert.are.equal("user", target.kind, "yy still resolves the user message")
            assert.are.equal("hi", target.text)
        end)

        it("leaves the content below the block intact", function()
            history, win = setup_history(40)
            history:add_user_message("hi", nil)
            pump(80)
            history:on_agent_start(nil)
            pump(60)
            history:on_text_delta("agent reply")
            pump(120)

            vim.api.nvim_win_set_config(win, { relative = "editor", row = 1, col = 1, width = 56, height = 24 })
            vim.api.nvim_exec_autocmds("WinResized", {})
            pump(120)

            local seen = 0
            for _, line in ipairs(buffer_lines(history)) do
                if line:find("agent reply", 1, true) then
                    seen = seen + 1
                    assert.are.equal(0, #line - #"agent reply", "agent text is untouched")
                end
            end
            assert.are.equal(1, seen, "agent reply still rendered exactly once")
        end)
    end)
end)
