-- Dedicated history renderers for built-in read-only tools
-- (grep, find, glob, ls): compact input summary lines, dedicated icons,
-- and auto-collapse of their characteristically long outputs (issue #105).

local Config = require("pi.config")
local History = require("pi.ui.chat.history")
local Tools = require("pi.ui.chat.tools")

local function pump(ms)
    vim.wait(ms or 60)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Rows (0-indexed) of every buffer line containing `sub` (plain match).
local function rows_with(buf, sub)
    local out = {}
    for i, l in ipairs(lines_of(buf)) do
        if l:find(sub, 1, true) then
            out[#out + 1] = i - 1
        end
    end
    return out
end

--- Live-event shaped tool result.
local function result_text(text)
    return { content = { { type = "text", text = text } } }
end

describe("built-in read-only tool renderers (issue #105)", function()
    before_each(function()
        Config.options.render = { engine = "builtin" }
    end)

    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    describe("renderer lookup", function()
        it("returns dedicated renderers with collapse thresholds", function()
            local default = Tools.get_renderer("__no_such_tool__")
            for _, name in ipairs({ "grep", "find", "glob", "ls" }) do
                local r = Tools.get_renderer(name)
                assert.is_not(r, default, name .. " must not fall through to default_renderer")
                assert.are.equal(1, r.input_visible)
                assert.are.equal(1, r.output_visible)
                assert.is_nil(r.inline)
            end
        end)

        it("provides dedicated icons", function()
            local generic = Config.options.labels.tool
            assert.are.equal(vim.fn.nr2char(0xF0349, 1), Tools.get_tool_icon("grep"))
            assert.are.equal(vim.fn.nr2char(0xF0869, 1), Tools.get_tool_icon("find"))
            assert.are.equal(vim.fn.nr2char(0xF024B, 1), Tools.get_tool_icon("glob"))
            assert.are.equal(vim.fn.nr2char(0xF024B, 1), Tools.get_tool_icon("ls"))
            assert.is_not(generic, Tools.get_tool_icon("find"))
            assert.is_not(generic, Tools.get_tool_icon("ls"))
        end)
    end)

    describe("grep input summary", function()
        it("shows pattern with default path", function()
            local h = History.new(1050)
            h:on_tool_start("grep", "t1", { pattern = "hello" })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "/hello/ in .") == 1)
        end)

        it("shows pattern with specified path", function()
            local h = History.new(1051)
            h:on_tool_start("grep", "t1", { pattern = "fn main", path = "src/core" })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "/fn main/ in src/core") == 1)
        end)

        it("includes glob filter when provided", function()
            local h = History.new(1052)
            h:on_tool_start("grep", "t1", { pattern = "M.setup", path = "lua", glob = "*.lua" })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "/M.setup/ in lua (*.lua)") == 1)
        end)

        it("includes limit when provided", function()
            local h = History.new(1053)
            h:on_tool_start("grep", "t1", { pattern = "TODO", path = ".", limit = 50 })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "/TODO/ in . limit 50") == 1)
        end)

        it("includes both glob and limit when provided", function()
            local h = History.new(1054)
            h:on_tool_start("grep", "t1", { pattern = "FIXME", path = "src", glob = "*.ts", limit = 25 })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "/FIXME/ in src (*.ts) limit 25") == 1)
        end)
    end)

    describe("find input summary", function()
        it("shows pattern with default path", function()
            local h = History.new(1055)
            h:on_tool_start("find", "t1", { pattern = "*.lua" })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "*.lua in .") == 1)
        end)

        it("shows pattern with specified path", function()
            local h = History.new(1056)
            h:on_tool_start("find", "t1", { pattern = "**/*.spec.ts", path = "tests" })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "**/*.spec.ts in tests") == 1)
        end)

        it("includes limit when provided", function()
            local h = History.new(1057)
            h:on_tool_start("find", "t1", { pattern = "*.json", path = ".", limit = 100 })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "*.json in . (limit 100)") == 1)
        end)

        it("glob alias produces identical format", function()
            local h = History.new(1058)
            h:on_tool_start("glob", "t1", { pattern = "*.md", path = "doc" })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "*.md in doc") == 1)
        end)
    end)

    describe("ls input summary", function()
        it("shows default dot when path omitted", function()
            local h = History.new(1059)
            h:on_tool_start("ls", "t1", {})
            pump(60)
            assert.is_true(#rows_with(h:buf(), ".") >= 1)
        end)

        it("shows specified path", function()
            local h = History.new(1060)
            h:on_tool_start("ls", "t1", { path = "lua/pi" })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "lua/pi") == 1)
        end)

        it("includes limit when provided", function()
            local h = History.new(1061)
            h:on_tool_start("ls", "t1", { path = "tests", limit = 10 })
            pump(60)
            assert.is_true(#rows_with(h:buf(), "tests (limit 10)") == 1)
        end)

        it("includes limit with default path when path omitted", function()
            local h = History.new(1062)
            h:on_tool_start("ls", "t1", { limit = 200 })
            pump(60)
            assert.is_true(#rows_with(h:buf(), ". (limit 200)") == 1)
        end)
    end)

    describe("auto-collapse", function()
        it("collapses long grep output and expands back", function()
            local h = History.new(1063)
            h:on_tool_start("grep", "t1", { pattern = "TODO", path = "." })
            pump(60)
            local out = table.concat({
                "lua/pi/init.lua:10: TODO: fix",
                "lua/pi/config.lua:20: TODO: check",
                "lua/pi/rpc.lua:30: TODO: optimize",
                "lua/pi/tree.lua:40: TODO: handle",
                "lua/pi/stats.lua:50: TODO: cache",
            }, "\n")
            h:on_tool_end("grep", "t1", result_text(out), false)
            pump(120)

            local buf = h:buf()
            local b = h._tool_blocks["t1"]
            assert.is_truthy(b)
            assert.is_false(b.expanded)
            assert.is_true(#rows_with(buf, "…4 lines") == 1)
            assert.is_true(#rows_with(buf, "lua/pi/stats.lua:50: TODO: cache") == 1)
            assert.is_true(#rows_with(buf, "lua/pi/init.lua:10: TODO: fix") == 0)

            -- Expand
            h:_set_tool_block_expanded(b, true)
            pump(60)
            assert.is_true(b.expanded)
            assert.is_true(#rows_with(buf, "…4 lines") == 0)
            assert.is_true(#rows_with(buf, "lua/pi/init.lua:10: TODO: fix") == 1)
            assert.is_true(#rows_with(buf, "lua/pi/stats.lua:50: TODO: cache") == 1)
        end)

        it("does not collapse short grep output", function()
            local h = History.new(1064)
            h:on_tool_start("grep", "t1", { pattern = "single" })
            pump(60)
            h:on_tool_end("grep", "t1", result_text("one matching line"), false)
            pump(120)

            local b = h._tool_blocks["t1"]
            assert.is_truthy(b)
            assert.is_true(b.expanded)
            assert.is_true(#rows_with(h:buf(), "one matching line") == 1)
        end)

        it("collapses long find output and expands back", function()
            local h = History.new(1065)
            h:on_tool_start("find", "t1", { pattern = "*.lua" })
            pump(60)
            local out = table.concat({ "a.lua", "b.lua", "c.lua", "d.lua" }, "\n")
            h:on_tool_end("find", "t1", result_text(out), false)
            pump(120)

            local buf = h:buf()
            local b = h._tool_blocks["t1"]
            assert.is_truthy(b)
            assert.is_false(b.expanded)
            assert.is_true(#rows_with(buf, "…3 lines") == 1)
            assert.is_true(#rows_with(buf, "d.lua") == 1)

            -- Expand
            h:_set_tool_block_expanded(b, true)
            pump(60)
            assert.is_true(b.expanded)
            assert.is_true(#rows_with(buf, "a.lua") == 1)
        end)

        it("collapses long ls output and expands back", function()
            local h = History.new(1066)
            h:on_tool_start("ls", "t1", { path = "src" })
            pump(60)
            local out = table.concat({ "file1.txt", "file2.txt", "file3.txt" }, "\n")
            h:on_tool_end("ls", "t1", result_text(out), false)
            pump(120)

            local buf = h:buf()
            local b = h._tool_blocks["t1"]
            assert.is_truthy(b)
            assert.is_false(b.expanded)
            assert.is_true(#rows_with(buf, "…2 lines") == 1)
            assert.is_true(#rows_with(buf, "file3.txt") == 1)

            -- Expand
            h:_set_tool_block_expanded(b, true)
            pump(60)
            assert.is_true(b.expanded)
            assert.is_true(#rows_with(buf, "file1.txt") == 1)
        end)
    end)
end)
