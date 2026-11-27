-- User message alignment (`user_message_align`, `user_message_max_width`).
--
-- The default is "left" and must stay byte-identical to the rendering that
-- existed before the option: body lines indented two spaces, no padding, no
-- bookkeeping. "right" renders a message as a BLOCK: the widest line (the
-- label included) sets the block width, capped by `user_message_max_width`,
-- and every line is padded by the SAME amount — the text is left-aligned
-- inside a box that is itself flush right. Padding is the only way a buffer
-- line can be right-aligned, so the block is recomputed when the window width
-- changes and its body lines are word-wrapped (a soft-wrapped continuation
-- would restart at column 0).
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
---@return integer[]
local function label_rows(history)
    local out = {}
    for i, line in ipairs(buffer_lines(history)) do
        if vim.startswith(vim.trim(line), ICON) then
            out[#out + 1] = i - 1
        end
    end
    return out
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

--- Leading padding of a rendered row, in columns (the padding is ASCII spaces).
---@param line string
---@return integer
local function left_col(line)
    return #(line:match("^ *") or "")
end

--- One rendered block as written (padding included): its label row and its body
--- rows, so both the shared left column and the right edge are measurable.
---@param history pi.ChatHistory
---@return { label: string, body: string[] }[]
local function blocks(history)
    local lines = buffer_lines(history)
    local out = {}
    local i = 1
    while i <= #lines do
        if vim.startswith(vim.trim(lines[i]), ICON) then
            local body = {}
            local j = i + 2 -- label row, then exactly one blank
            while j <= #lines and vim.trim(lines[j]) ~= "" do
                body[#body + 1] = lines[j]
                j = j + 1
            end
            out[#out + 1] = { label = lines[i], body = body }
            i = j
        else
            i = i + 1
        end
    end
    return out
end

--- The configured floor on a box's width, in columns (0 = none).
---@return integer
local function min_width()
    local minw = Config.options.user_message_min_width
    if type(minw) ~= "number" or minw <= 0 then
        return 0
    end
    return minw
end

--- Assert the block contract: every row starts on the label's left column, the
--- box's right edge sits on `edge` (a box is at least `user_message_min_width`
--- wide, so the widest row need not reach it), and nothing overflows.
---@param block { label: string, body: string[] }
---@param edge integer
local function assert_block_shape(block, edge)
    local left = left_col(block.label)
    local content = dw(block.label) - left
    for _, row in ipairs(block.body) do
        assert.are.equal(left, left_col(row), "row off the block's left column: " .. vim.trim(row))
        assert.is_true(dw(row) <= edge, "row overflows the right edge: " .. vim.trim(row))
        content = math.max(content, dw(row) - left)
    end
    assert.is_true(left + content <= edge, "label row overflows the right edge")
    assert.are.equal(edge, left + math.max(content, min_width()), "the box does not end on the right edge")
end

describe("user message alignment", function()
    local history, win, orig

    before_each(function()
        Highlights.setup()
        orig = Config.options
        Config.options.render = { engine = "builtin" }
        -- `orig` aliases the live options table, so the width bounds are reset
        -- to their shipped values explicitly instead of being read back off it.
        Config.options.user_message_max_width = 0.75
        Config.options.user_message_min_width = 24
        require("pi.ui.render")._reset()
    end)

    after_each(function()
        if history then
            teardown_history(history, win)
            history, win = nil, nil
        end
        Config.options.user_message_align = orig.user_message_align
        Config.options.user_message_max_width = 0.75
        Config.options.user_message_min_width = 24
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

        it("puts the block flush right with the body on the label's column", function()
            history, win = setup_history(40)
            history:add_user_message("hello there", nil)
            pump(80)

            local block = blocks(history)[1]
            assert.is_not_nil(block)
            -- The box (not necessarily the label: a 24-column floor is wider
            -- than the label) ends on the edge; the body starts on its column.
            assert.are.equal(left_col(block.label), left_col(block.body[1]), "body starts on the label's column")
            assert.are.equal("hello there", vim.trim(block.body[1]))
            assert_block_shape(block, edge(history))
        end)

        it("left-aligns every body row inside the block", function()
            history, win = setup_history(60)
            history:add_user_message("short\na much longer second line here", nil)
            pump(80)

            local block = blocks(history)[1]
            assert.are.equal(2, #block.body)
            assert.are.equal(left_col(block.label), left_col(block.body[1]))
            assert.are.equal(left_col(block.label), left_col(block.body[2]))
            assert.is_true(dw(block.body[1]) < edge(history), "the short row stops before the edge")
            assert.are.equal(edge(history), dw(block.body[2]), "the widest row ends on the edge")
            assert_block_shape(block, edge(history))
        end)

        it("pads by display width, not byte length", function()
            history, win = setup_history(40)
            history:add_user_message("你好", nil)
            pump(80)

            local block = blocks(history)[1]
            assert.are.equal("你好", vim.trim(block.body[1]))
            assert.are.equal(left_col(block.label), left_col(block.body[1]))
            assert_block_shape(block, edge(history))
        end)

        it("hard-wraps a word wider than the block, on one shared column", function()
            history, win = setup_history(40)
            history:add_user_message(string.rep("x", 120), nil)
            pump(80)

            local block = blocks(history)[1]
            assert.is_true(#block.body >= 4, "long word wrapped into several rows")
            for _, row in ipairs(block.body) do
                assert.are.equal(left_col(block.label), left_col(row), "chunk off the block's column")
                assert.is_true(dw(row) - left_col(row) <= edge(history) - 2, "chunk wider than the text area")
            end
            assert.are.equal(120, #table.concat(vim.tbl_map(vim.trim, block.body), ""), "no characters lost")
            assert_block_shape(block, edge(history))
        end)

        it("breaks prose between words instead of mid-word", function()
            local text = "the quick brown fox jumps over the lazy dog and keeps on running"
            history, win = setup_history(40)
            history:add_user_message(text, nil)
            pump(80)

            local block = blocks(history)[1]
            assert.is_true(#block.body >= 2, "the line wrapped")
            for _, row in ipairs(block.body) do
                local body = vim.trim(row)
                -- every rendered row is a run of whole words from the message
                assert.is_truthy((" " .. text .. " "):find(" " .. body .. " ", 1, true), "mid-word break: " .. body)
            end
            assert.are.equal(
                (text:gsub("%s+", " ")),
                (table.concat(vim.tbl_map(vim.trim, block.body), " "):gsub("%s+", " ")),
                "the rendered rows rejoin into the message"
            )
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

    describe("width bounds", function()
        before_each(function()
            Config.options.user_message_align = "right"
        end)

        it("ships a 75% cap and a 24-column floor", function()
            -- The literals `before_each` resets to; the shipped values are
            -- asserted end to end in tests/user_message_align_e2e.lua, which
            -- runs with the real setup() defaults.
            assert.are.equal(0.75, Config.options.user_message_max_width)
            assert.are.equal(24, Config.options.user_message_min_width)
        end)

        it("caps the block content to a column count", function()
            -- 30 is safely wider than the label, so the body sets the block
            -- width and the expected left column is exact.
            Config.options.user_message_max_width = 30
            history, win = setup_history(60)
            history:add_user_message(string.rep("x", 120), nil)
            pump(80)

            local block = blocks(history)[1]
            assert.are.equal(edge(history) - 30, left_col(block.label), "a 30-column block, flush right")
            for _, row in ipairs(block.body) do
                assert.is_true(dw(row) - left_col(block.label) <= 30, "row wider than the cap: " .. vim.trim(row))
            end
            assert_block_shape(block, edge(history))
        end)

        it("accepts a fraction of the history width", function()
            Config.options.user_message_max_width = 0.5
            history, win = setup_history(60)
            history:add_user_message(string.rep("y", 120), nil)
            pump(80)

            local block = blocks(history)[1]
            assert.are.equal(edge(history) - 30, left_col(block.label), "half of a 60-column window")
            assert_block_shape(block, edge(history))
        end)

        it("lets the label widen the box: the cap applies to the body", function()
            Config.options.user_message_max_width = 8
            Config.options.user_message_min_width = 0
            history, win = setup_history(60)
            history:add_user_message("hi", nil)
            pump(80)

            local block = blocks(history)[1]
            local label_w = dw(block.label) - left_col(block.label)
            assert.is_true(label_w > 8, "the label alone is wider than the cap")
            assert.are.equal(edge(history) - label_w, left_col(block.label))
            assert.are.equal(left_col(block.label), left_col(block.body[1]))
            assert.are.equal(edge(history), dw(block.label), "the label still ends on the edge")
        end)

        it("renders a short message as a box of the minimum width", function()
            history, win = setup_history(80)
            history:add_user_message("ok", nil)
            pump(80)

            local block = blocks(history)[1]
            assert.are.equal(edge(history) - min_width(), left_col(block.label), "the box is min_width wide")
            assert.are.equal(left_col(block.label), left_col(block.body[1]))
            assert.is_true(dw(block.label) < edge(history), "a short box does not fill its own width")
            assert_block_shape(block, edge(history))
        end)

        it("a minimum of 0 lets the content decide", function()
            Config.options.user_message_min_width = 0
            history, win = setup_history(80)
            history:add_user_message("ok", nil)
            pump(80)

            local block = blocks(history)[1]
            local label_w = dw(block.label) - left_col(block.label)
            assert.are.equal(edge(history) - label_w, left_col(block.label))
            assert.are.equal(edge(history), dw(block.label), "the label ends on the edge")
        end)

        it("the minimum lifts a cap that would fall below it", function()
            Config.options.user_message_max_width = 0.1
            history, win = setup_history(80)
            history:add_user_message(string.rep("w", 90), nil)
            pump(80)

            local block = blocks(history)[1]
            assert.are.equal(edge(history) - min_width(), left_col(block.label), "the floor wins over the cap")
            for _, row in ipairs(block.body) do
                assert.is_true(dw(row) - left_col(block.label) <= min_width(), "row wider than the floor")
            end
            assert_block_shape(block, edge(history))
        end)

        it("a cap wider than the window changes nothing", function()
            Config.options.user_message_max_width = 500
            Config.options.user_message_min_width = 0
            history, win = setup_history(60)
            history:add_user_message("short\na much longer second line here", nil)
            pump(80)

            local block = blocks(history)[1]
            assert.are.equal(edge(history), dw(block.body[2]), "the widest row still ends on the edge")
            assert_block_shape(block, edge(history))
        end)

        it("is ignored by the left alignment", function()
            Config.options.user_message_max_width = 20
            Config.options.user_message_align = "left"
            history, win = setup_history(60)
            history:add_user_message("hello there", nil)
            pump(80)

            local body = body_lines(history)
            assert.are.equal("  hello there", body[1], "left mode keeps its two-space indent")
            assert.are.equal(0, #history._user_blocks, "left alignment still stores nothing")
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
            local before_left = left_col(blocks(history)[1].label)

            vim.api.nvim_win_set_config(win, { relative = "editor", row = 1, col = 1, width = 60, height = 24 })
            vim.api.nvim_exec_autocmds("WinResized", {})
            pump(120)

            local block = blocks(history)[1]
            assert.are.equal("hello there", vim.trim(block.body[1]))
            assert.is_true(left_col(block.label) > before_left, "the block moved further right")
            assert_block_shape(block, edge(history))
        end)

        it("re-wraps when the window gets narrower, keeping the content", function()
            -- No cap: this test is about the window driving the wrap width.
            Config.options.user_message_max_width = 0
            history, win = setup_history(60)
            history:add_user_message(string.rep("y", 50), nil)
            pump(80)
            assert.are.equal(1, #blocks(history)[1].body, "fits on one row at 60 columns")

            vim.api.nvim_win_set_config(win, { relative = "editor", row = 1, col = 1, width = 30, height = 24 })
            vim.api.nvim_exec_autocmds("WinResized", {})
            pump(120)

            local block = blocks(history)[1]
            assert.is_true(#block.body >= 2, "the line wrapped after shrinking")
            assert.are.equal(50, #table.concat(vim.tbl_map(vim.trim, block.body), ""), "no characters lost")
            for _, row in ipairs(block.body) do
                assert.are.equal(left_col(block.label), left_col(row), "every chunk on the block's column")
            end
            assert_block_shape(block, edge(history))
        end)

        it("keeps the cap across a resize", function()
            Config.options.user_message_max_width = 30
            history, win = setup_history(60)
            history:add_user_message(string.rep("z", 90), nil)
            pump(80)
            assert.are.equal(edge(history) - 30, left_col(blocks(history)[1].label))

            vim.api.nvim_win_set_config(win, { relative = "editor", row = 1, col = 1, width = 40, height = 24 })
            vim.api.nvim_exec_autocmds("WinResized", {})
            pump(150)

            local block = blocks(history)[1]
            assert.are.equal(edge(history) - 30, left_col(block.label), "still 30 columns, re-flushed right")
            for _, row in ipairs(block.body) do
                assert.is_true(dw(row) - left_col(block.label) <= 30, "row wider than the cap")
            end
            assert_block_shape(block, edge(history))
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

        it("re-pads EVERY block, keeping each anchor on its own message", function()
            history, win = setup_history(40)
            history:add_user_message("first message", nil)
            pump(60)
            history:add_user_message("second message", nil)
            pump(80)

            vim.api.nvim_win_set_config(win, { relative = "editor", row = 1, col = 1, width = 56, height = 24 })
            vim.api.nvim_exec_autocmds("WinResized", {})
            pump(150)

            -- Each label is followed by one blank row, then its own body: a
            -- realign that pulled the second block's anchor onto the first would
            -- duplicate one message and drop the other.
            local labels = label_rows(history)
            assert.are.equal(2, #labels, "both labels still rendered")
            local rendered = blocks(history)
            assert.are.equal(2, #rendered, "both blocks rendered")
            local expected = { "first message", "second message" }
            for i, block in ipairs(rendered) do
                assert.are.equal(expected[i], vim.trim(block.body[1]), "block " .. i .. " keeps its own text")
                assert_block_shape(block, edge(history))
            end

            local ans = vim.api.nvim_get_namespaces()["pi-chat-user-align"]
            local rows = {}
            for _, block in ipairs(history._user_blocks) do
                rows[#rows + 1] = vim.api.nvim_buf_get_extmark_by_id(history:buf(), ans, block.anchor, {})[1]
            end
            assert.are.equal(2, #rows, "both blocks tracked")
            assert.is_true(rows[1] < rows[2], "block anchors stayed apart")
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
