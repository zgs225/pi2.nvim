-- ANSI rendering through the chat history (ui/chat/ansi.lua + tools/history).
--
-- Contract under test: the buffer never contains escape bytes, SGR spans land
-- as `PiAnsi*` extmarks (above the block's base highlight), the collapsed view
-- keeps the colours of the tail it duplicates, toggling preserves them, and
-- streamed `!` bash output stays escape-free even though the pi backend already
-- strips it (nothing to colour ⇒ degrade to plain text).

local Config = require("pi.config")
local History = require("pi.ui.chat.history")
local Tools = require("pi.ui.chat.tools")
local Ansi = require("pi.ui.chat.ansi")

local TAB = 941

local function pump(ms)
    vim.wait(ms or 60)
end

---@param h pi.ChatHistory
---@return string[]
local function lines_of(h)
    return vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
end

--- @param h pi.ChatHistory
--- @return table[]
local function ansi_marks(h)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })) do
        local hl = m[4] and m[4].hl_group
        if type(hl) == "string" and hl:match("^PiAnsi") then
            out[#out + 1] = m
        end
    end
    return out
end

---@param h pi.ChatHistory
---@param text string
---@return integer? 0-indexed row
local function row_of(h, text)
    for i, l in ipairs(lines_of(h)) do
        if l == text then
            return i - 1
        end
    end
    return nil
end

--- True when no buffer line carries an ESC byte.
---@param h pi.ChatHistory
---@return boolean
local function escape_free(h)
    for _, l in ipairs(lines_of(h)) do
        if l:find("\27", 1, true) then
            return false
        end
    end
    return true
end

describe("ansi rendering", function()
    before_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
        Ansi._reset()
    end)

    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
        Ansi._reset()
    end)

    describe("tool output", function()
        it("writes escape-free text and colours the spans", function()
            local h = History.new(TAB)
            h:on_tool_start("bash", "a1", { command = "ls --color" })
            pump()
            h:on_tool_end("bash", "a1", {
                content = { { type = "text", text = "\27[1;32mPASS\27[0m ok" } },
            }, false)
            pump()

            assert.is_true(escape_free(h), "buffer must not contain escape bytes")
            local row = row_of(h, "PASS ok")
            assert.is_not_nil(row)

            local marks = ansi_marks(h)
            assert.is_true(#marks > 0, "expected ANSI span extmarks")
            local first = marks[1]
            assert.are.equal(row, first[2])
            assert.are.equal(0, first[3])
            assert.are.equal(4, first[4].end_col) -- "PASS"
        end)

        it("keeps the collapsed view's tail colours", function()
            local h = History.new(TAB + 1)
            h:on_tool_start("bash", "a2", { command = "ls --color" })
            pump()
            -- 3 output lines > bash's output_visible=1 ⇒ auto-collapse to the tail.
            h:on_tool_end("bash", "a2", {
                content = {
                    { type = "text", text = "one\n\27[31mtwo\27[0m\n\27[32mthree\27[0m" },
                },
            }, false)
            pump()

            assert.is_true(escape_free(h))
            local row = row_of(h, "three")
            assert.is_not_nil(row, "collapsed tail renders the last output line")
            local mark_rows = {}
            for _, m in ipairs(ansi_marks(h)) do
                mark_rows[m[2]] = true
            end
            assert.is_true(mark_rows[row] == true, "collapsed tail line keeps its colour span")
        end)

        it("preserves colours across collapse and expand", function()
            local h = History.new(TAB + 2)
            h:on_tool_start("bash", "a3", { command = "ls --color" })
            pump()
            h:on_tool_end("bash", "a3", {
                content = { { type = "text", text = "\27[31mone\27[0m\n\27[32mtwo\27[0m\n\27[33mthree\27[0m" } },
            }, false)
            pump()

            local block = h._tool_blocks["a3"]
            assert.is_not_nil(block)
            assert.is_false(block.expanded, "3 lines + output_visible=1 collapses")

            assert.is_true(h:_set_tool_block_expanded(block, true))
            pump()
            local expanded_rows = {}
            for _, m in ipairs(ansi_marks(h)) do
                expanded_rows[m[2]] = true
            end
            assert.is_true(expanded_rows[row_of(h, "one")], "expanded rows are coloured")
            assert.is_true(expanded_rows[row_of(h, "two")])

            assert.is_true(h:_set_tool_block_expanded(block, false))
            pump()
            local collapsed_rows = {}
            for _, m in ipairs(ansi_marks(h)) do
                collapsed_rows[m[2]] = true
            end
            assert.is_true(collapsed_rows[row_of(h, "three")], "re-collapse re-colours the tail")
            assert.is_true(escape_free(h))
        end)

        it("keeps a plain tail line uncoloured", function()
            local h = History.new(TAB + 6)
            h:on_tool_start("bash", "a6", { command = "ls --color" })
            pump()
            h:on_tool_end("bash", "a6", {
                content = { { type = "text", text = "\27[31mone\27[0m\nplain last" } },
            }, false)
            pump()

            local row = row_of(h, "plain last")
            assert.is_not_nil(row)
            for _, m in ipairs(ansi_marks(h)) do
                assert.is_true(m[2] ~= row, "the uncoloured tail line must not inherit a span")
            end
        end)

        it("still renders markdown-fenced output (row offset) with colours", function()
            Config.options.render = { engine = "render-markdown" }
            require("pi.ui.render")._reset()
            local h = History.new(TAB + 3)
            h:on_tool_start("bash", "a4", { command = "ls --color" })
            pump()
            h:on_tool_end("bash", "a4", {
                content = { { type = "text", text = "\27[35mmagenta\27[0m" } },
            }, false)
            pump()

            assert.is_true(escape_free(h))
            local row = row_of(h, "magenta")
            assert.is_not_nil(row)
            local hit = false
            for _, m in ipairs(ansi_marks(h)) do
                if m[2] == row then
                    hit = true
                end
            end
            assert.is_true(hit, "fenced output keeps its span on the content row")
        end)
    end)

    describe("live tool updates", function()
        it("colours streamed partial output", function()
            local h = History.new(TAB + 4)
            h:on_tool_start("bash", "a5", { command = "sleep 1" })
            pump()
            h:on_tool_update("bash", "a5", {
                partialResult = { content = { { type = "text", text = "\27[35mlive\27[0m row" } } },
            })
            pump()

            assert.is_true(escape_free(h))
            local row = row_of(h, "live row")
            assert.is_not_nil(row)
            local hit = false
            for _, m in ipairs(ansi_marks(h)) do
                if m[2] == row and m[3] == 0 and m[4].end_col == 4 then
                    hit = true
                end
            end
            assert.is_true(hit, "live row keeps its colour span")
        end)
    end)

    describe("! bash blocks", function()
        it("strips escapes from streamed and final output", function()
            local h = History.new(TAB + 5)
            h:on_bash_start("b1", "ls --color", false)
            pump()
            -- The pi backend strips SGR before emitting bash_execution_update,
            -- so this is the defensive path: text may still arrive raw.
            h:on_bash_output("b1", "\27[1;34mdir\27[0m\n")
            h:on_bash_end("b1", { output = "\27[1;34mdir\27[0m\n", exitCode = 0 })
            pump()

            assert.is_true(escape_free(h), "bash block output must be escape-free")
            assert.is_not_nil(row_of(h, "dir"))
        end)
    end)

    describe("Tools.sanitize_text", function()
        it("strips escapes so widths are computed on visible text", function()
            local raw = "\27[31mred\27[0m"
            assert.are.equal("red", Tools.sanitize_text(raw))
            assert.are.equal(3, vim.fn.strdisplaywidth(Tools.sanitize_text(raw)))
            -- Untreated, the ESC pair would count as extra columns.
            assert.is_true(vim.fn.strdisplaywidth(raw) > 3)
        end)

        it("keeps a tool block from collapsing on invisible bytes", function()
            -- 8 visible columns plus a 28-byte escape wrapper would trip a
            -- width-based collapse; sanitized text must not.
            local lines = { "\27[38;5;208m" .. string.rep("x", 8) .. "\27[0m" }
            assert.is_false(Tools.should_collapse(lines, {}, 10, 10, 20))
        end)
    end)

    describe("Tools.map_collapsed_ansi", function()
        it("maps tail rows by text and skips unmatched rows", function()
            local collapsed = { " +2 lines", "", "three" }
            local specs = { "summary", "separator", "output" }
            local source = { "one", "two", "three" }
            local marks = {
                { row = 0, col = 0, end_col = 3, hl_group = "PiAnsiOne" },
                { row = 2, col = 0, end_col = 5, hl_group = "PiAnsiThree" },
            }
            local out = Tools.map_collapsed_ansi(collapsed, specs, source, marks)
            assert.are.equal(1, #out)
            assert.are.equal(2, out[1].row)
            assert.are.equal("PiAnsiThree", out[1].hl_group)
            assert.are.equal(5, out[1].end_col)
        end)

        it("returns nothing without marks", function()
            assert.are.same({}, Tools.map_collapsed_ansi({ "x" }, { "output" }, { "x" }, {}))
        end)
    end)
end)
