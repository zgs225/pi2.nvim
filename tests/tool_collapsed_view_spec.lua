-- Collapsed-view composition (lua/pi/ui/chat/tools.lua build_collapsed_view):
-- row ORDER and fence balance.
--
-- Two regressions this locks:
--   * the input elision summary (" +N lines") used to be emitted *before* the
--     visible input lines it summarises, so a collapsed block read
--     ` +3 lines` / `const x = …` instead of the other way round;
--   * a collapsed window can start/end inside a ```snippet``` block, and an
--     unmatched fence swallows the footer and every following message.

local Config = require("pi.config")
local Tools = require("pi.ui.chat.tools")

--- Backtick run of the fence still open at the end of `lines` (nil = balanced).
---@param lines string[]
---@return integer?
local function open_fence(lines)
    local open = nil ---@type integer?
    for _, l in ipairs(lines) do
        local ticks = l:match("^%s*(`+)")
        if ticks then
            if not open then
                open = #ticks
            elseif #ticks >= open then
                open = nil
            end
        end
    end
    return open
end

---@param lines string[]
---@return integer
local function fence_rows(lines)
    local n = 0
    for _, l in ipairs(lines) do
        if l:match("^%s*```") then
            n = n + 1
        end
    end
    return n
end

describe("build_collapsed_view", function()
    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    describe("input summary order", function()
        before_each(function()
            Config.options.render = { engine = "builtin" }
            require("pi.ui.render")._reset()
        end)

        it("emits +N lines under the visible input lines", function()
            local lines, specs = Tools.build_collapsed_view({ "l1", "l2", "l3" }, {}, false, 1, 0, 0)
            assert.are.same({ "l1", " +2 lines" }, lines)
            assert.are.same({ "input", "summary" }, specs)
        end)

        it("emits +N lines after the fenced input under render-markdown", function()
            Config.options.render = { engine = "render-markdown" }
            require("pi.ui.render")._reset()
            local lines, specs = Tools.build_collapsed_view({ "l1", "l2", "l3" }, {}, false, 1, 0, 0)
            assert.are.same({ "```", "l1", "```", " +2 lines" }, lines)
            assert.are.same({ "input", "input", "input", "summary" }, specs)
        end)

        it("keeps the whole order: input, +N lines, separator, …N lines, tail", function()
            local lines, specs = Tools.build_collapsed_view({ "i1", "i2" }, { "o1", "o2", "o3", "o4" }, true, 1, 1, 0)
            assert.are.same({ "i1", " +1 lines", "", "…3 lines", "o4" }, lines)
            assert.are.same({ "input", "summary", "separator", "summary", "output" }, specs)
        end)

        it("emits no summary when nothing is elided", function()
            local lines = Tools.build_collapsed_view({ "i1" }, { "o1" }, true, 1, 1, 0)
            assert.are.same({ "i1", "", "o1" }, lines)
        end)
    end)

    describe("fence balance", function()
        it("closes a tail that ends inside a fence", function()
            local lines, specs = Tools.build_collapsed_view({ "cmd" }, { "pre", "```" }, true, 1, 2, 0)
            assert.are.same({ "cmd", "", "pre", "```", "```" }, lines)
            assert.is_nil(open_fence(lines))
            assert.are.equal(0, fence_rows(lines) % 2)
            assert.are.equal("output", specs[#specs], "the synthetic closer is output-coloured")
        end)

        it("leaves a balanced tail alone", function()
            local lines = Tools.build_collapsed_view({ "cmd" }, { "```ts", "x", "```" }, true, 1, 3, 0)
            assert.are.same({ "cmd", "", "```ts", "x", "```" }, lines)
            assert.is_nil(open_fence(lines))
        end)

        it("closes a fence opened inside the visible tail with the same backtick run", function()
            -- The tail opens a fence and never closes it: the closer must use
            -- the same backtick run, and it must be a real closing row.
            local lines = Tools.build_collapsed_view({ "cmd" }, { "a", "`````", "b" }, true, 1, 3, 0)
            assert.are.equal("`````", lines[#lines])
            assert.is_nil(open_fence(lines))
        end)

        it("does not misread a ``` row inside a ```` block as an unmatched fence", function()
            -- render-markdown wraps the visible tail in a fence one backtick
            -- longer than the longest run, so a ``` row inside it is content.
            -- Raw row parity would "close" this already balanced view and leave
            -- a fresh opener behind.
            Config.options.render = { engine = "render-markdown" }
            require("pi.ui.render")._reset()
            local lines = Tools.build_collapsed_view({ "cmd" }, { "````", "x", "```", "````" }, true, 1, 4, 0)
            assert.is_nil(open_fence(lines), "the view must stay balanced")
            assert.are.equal("`````", lines[#lines], "the wrapper fence, not a stray ```")
        end)
    end)
end)
