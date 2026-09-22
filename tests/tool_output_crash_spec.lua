-- Regression: tool output containing runs of consecutive CR characters
-- ("\r\r" — progress-bar redraw residue, seen in the wild from a bash tool
-- whose output carried "\r-#O#- ...\r\r ... 0.0%") must not crash
-- render_output().
--
-- History:_append_lines() / _insert_lines() flatten embedded [\r\n] runs to
-- a single space before writing to the buffer. That flatten must be
-- byte-length-preserving: renderers size their highlight extmarks from the
-- original text (end_col = #line), so a buffer line that ends up shorter
-- than the original makes nvim_buf_set_extmark throw
-- "Invalid 'end_col': out of range" inside the scheduled on_tool_end
-- callback, aborting the rest of the block render.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")

local TAB = 910

local function pump(ms)
    vim.wait(ms or 50)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Create a History with tool-block collapsing disabled so buffer lines
--- are the raw rendered output (easier to assert on).
---@return pi.ChatHistory
local function new_history()
    local h = History.new(TAB)
    h._blocks_expanded = true
    return h
end

--- Fire a bash tool call through the standard on_tool_start / on_tool_end path.
---@param h pi.ChatHistory
---@param output string  tool result text
local function bash_tool(h, output)
    h:on_tool_start("bash", "call1", { command = "make download" })
    pump()
    h:on_tool_end("bash", "call1", {
        content = { { type = "text", text = output } },
    }, false)
    pump()
end

--- Row (0-indexed) of the first buffer line containing `sub`, or nil.
---@param buf integer
---@param sub string
---@return integer?
local function row_with(buf, sub)
    for i, l in ipairs(lines_of(buf)) do
        if l:find(sub, 1, true) then
            return i - 1
        end
    end
    return nil
end

--- Does `row` carry a PiToolOutput highlight extmark?
---@param h pi.ChatHistory
---@param row integer
---@return boolean
local function has_output_hl(h, row)
    local marks = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), { row, 0 }, { row, -1 }, {
        details = true,
    })
    for _, m in ipairs(marks) do
        if m[4].hl_group == "PiToolOutput" then
            return true
        end
    end
    return false
end

describe("tool output with CR runs", function()
    after_each(function()
        Config.options.render = { engine = "builtin" }
    end)

    it("does not crash on \\r\\r progress-bar residue and still highlights output", function()
        local h = new_history()
        bash_tool(h, "progress 10%\r\rprogress 20%\rdone")

        local row = row_with(h:buf(), "progress 10%")
        assert.is_not_nil(row)
        -- the dirty line got its PiToolOutput highlight; before the fix the
        -- extmark loop threw and aborted on_end before this was placed
        assert.is_true(has_output_hl(h, row))
        -- on_end ran to completion: output_extmark is set after the renderer returns
        assert.is_not_nil(h._tool_blocks["call1"].output_extmark)
    end)

    it("handles \\r\\r on a later line of multi-line output", function()
        local h = new_history()
        bash_tool(h, "first line ok\nbad\r\rdone\nlast line")

        -- byte-preserving flatten: each \r becomes one space
        local row = row_with(h:buf(), "bad  done")
        assert.is_not_nil(row)
        assert.is_true(has_output_hl(h, row))
        assert.is_not_nil(h._tool_blocks["call1"].output_extmark)
    end)

    it("same under the render-markdown engine (fenced path)", function()
        Config.options.render = { engine = "render-markdown" }
        local h = new_history()
        bash_tool(h, "progress 10%\r\rprogress 20%\rdone")

        local row = row_with(h:buf(), "progress 10%")
        assert.is_not_nil(row)
        assert.is_not_nil(h._tool_blocks["call1"].output_extmark)
    end)

    it("custom block chunks containing \\r\\n keep valid highlight columns", function()
        local h = new_history()
        h:append_custom_block({
            content = {
                { { "prog ", "PiCustomBlock" }, { "10%\r\n20%", "PiCustomBlock" } },
            },
        })
        pump()

        -- chunk highlight landed without an end_col error; the flatten is
        -- byte-length-preserving so column math still matches the buffer line
        -- ("\r\n" → two spaces, not one)
        local row = row_with(h:buf(), "prog 10%  20%")
        assert.is_not_nil(row)
        assert.is_nil(row_with(h:buf(), "prog 10% 20%"))
    end)

    it("bash block header with \\r\\r does not crash", function()
        local h = new_history()
        h:on_bash_start("b1", "curl\r\r-o out.tgz url", false)
        pump()

        local row = row_with(h:buf(), "curl  -o out.tgz url")
        assert.is_not_nil(row)
    end)
end)
