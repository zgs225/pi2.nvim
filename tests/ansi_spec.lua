-- ANSI handling for the history buffer (lua/pi/ui/chat/ansi.lua).
--
-- Two contracts:
--   * `strip()` removes escapes/control bytes — this is what keeps the buffer
--     free of `^[[1;32m` garbage and what makes width math correct (an ESC
--     counts as two display columns).
--   * `scan()`/`apply()` turn SGR sequences into extmark spans without putting
--     the escape bytes in the buffer.
-- Degradation is part of the contract: once a highlight/extmark call fails the
-- module turns itself off and callers keep the stripped text.

local Ansi = require("pi.ui.chat.ansi")

local function new_buf()
    local buf = vim.api.nvim_create_buf(false, true)
    return buf, vim.api.nvim_create_namespace("pi-ansi-spec-" .. tostring(buf))
end

--- 0-indexed rows/cols of extmarks in `ns`, sorted.
local function marks(buf, ns)
    return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

describe("pi.ui.chat.ansi.strip", function()
    before_each(function()
        Ansi._reset()
    end)

    it("leaves plain text untouched", function()
        assert.are.equal("plain text", Ansi.strip("plain text"))
        assert.are.equal("", Ansi.strip(nil))
        assert.are.equal("42", Ansi.strip(42))
    end)

    it("removes SGR colour codes", function()
        assert.are.equal("PASS ok", Ansi.strip("\27[1;32mPASS\27[0m ok"))
        assert.are.equal("rgb", Ansi.strip("\27[38;2;255;0;0mrgb\27[0m"))
        assert.are.equal("idx", Ansi.strip("\27[38;5;208midx\27[0m"))
    end)

    it("removes non-SGR CSI sequences", function()
        -- progress-bar erase-line, cursor home
        assert.are.equal("50%", Ansi.strip("\27[2K50%"))
        assert.are.equal("abc", Ansi.strip("\27[1;1Habc"))
    end)

    it("removes OSC sequences with either terminator", function()
        assert.are.equal("visible", Ansi.strip("\27]0;a-title\7visible"))
        assert.are.equal("visible", Ansi.strip("\27]8;;https://x\27\\visible"))
    end)

    it("drops a lone ESC and an unterminated sequence", function()
        assert.are.equal("tail", Ansi.strip("tail\27"))
        assert.are.equal("x", Ansi.strip("x\27[31"))
    end)

    it("scrubs C0 control bytes but keeps tab and newline", function()
        assert.are.equal("a\tb\nc", Ansi.strip("a\tb\nc"))
        assert.are.equal("ab", Ansi.strip("a\1\2\3b"))
        assert.are.equal("ab", Ansi.strip("a\127b")) -- DEL
    end)

    it("maps CR to a space and NUL to the visible placeholder", function()
        assert.are.equal("a b", Ansi.strip("a\rb"))
        assert.are.equal("␀", Ansi.strip("\0"))
    end)
end)

describe("pi.ui.chat.ansi.scan", function()
    before_each(function()
        Ansi._reset()
    end)

    it("keeps line count and returns escape-free text", function()
        local items = Ansi.scan({ "\27[31mred\27[0m", "", "tail" })
        assert.are.equal(3, #items)
        assert.are.equal("red", items[1].text)
        assert.are.equal("", items[2].text)
        assert.are.equal("tail", items[3].text)
    end)

    it("reports byte spans for one line", function()
        local items = Ansi.scan({ "\27[31mred\27[0m plain" })
        local spans = items[1].spans
        assert.are.equal(1, #spans)
        assert.are.equal(0, spans[1].from)
        assert.are.equal(3, spans[1].to)
        assert.are.equal(1, spans[1].style.fg.idx)
    end)

    it("carries colour state across lines", function()
        local items = Ansi.scan({ "\27[32mgreen", "still green\27[0m done" })
        assert.are.equal(1, #items[1].spans)
        assert.are.equal(0, items[1].spans[1].from)
        assert.are.equal(5, items[1].spans[1].to)
        -- The continuation is styled up to the reset, then plain.
        assert.are.equal(1, #items[2].spans)
        assert.are.equal(0, items[2].spans[1].from)
        assert.are.equal(11, items[2].spans[1].to)
        assert.are.equal("still green done", items[2].text)
    end)

    it("splits a line at each SGR boundary", function()
        local items = Ansi.scan({ "\27[1ma\27[4mb\27[0mc" })
        local spans = items[1].spans
        -- `c` follows the reset, so it carries no style and produces no span.
        assert.are.equal(2, #spans)
        assert.are.equal(0, spans[1].from)
        assert.are.equal(1, spans[1].to)
        assert.is_true(spans[1].style.bold)
        assert.are.equal(1, spans[2].from)
        assert.are.equal(2, spans[2].to)
        assert.is_true(spans[2].style.bold)
        assert.is_true(spans[2].style.underline)
    end)

    it("parses 256-colour and truecolor", function()
        local items = Ansi.scan({ "\27[38;5;208ma\27[48;2;10;20;30mb\27[0m" })
        local spans = items[1].spans
        assert.are.equal(208, spans[1].style.fg.idx)
        assert.are.same({ 10, 20, 30 }, spans[2].style.bg.rgb)
    end)

    it("uses byte columns so multibyte text stays aligned", function()
        local items = Ansi.scan({ "中文\27[31m红\27[0m" })
        local span = items[1].spans[1]
        assert.are.equal(6, span.from) -- 中文 = 6 bytes
        assert.are.equal(9, span.to) -- 红 = 3 bytes
    end)

    it("strips non-SGR escapes without creating spans", function()
        local items = Ansi.scan({ "\27[2Kdone\27]0;title\7" })
        assert.are.equal("done", items[1].text)
        assert.are.equal(0, #items[1].spans)
        assert.is_false(items[1].styled)
    end)
end)

describe("pi.ui.chat.ansi.apply", function()
    before_each(function()
        Ansi._reset()
    end)

    it("writes spans as extmarks above the block base highlight", function()
        local buf, ns = new_buf()
        local items = Ansi.scan({ "\27[31mred\27[0m plain" })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { items[1].text })
        Ansi.apply(buf, ns, 0, items)
        assert.are.equal("red plain", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
        local m = marks(buf, ns)
        assert.are.equal(1, #m)
        assert.are.equal(0, m[1][3])
        assert.are.equal(3, m[1][4].end_col)
        assert.is_true(m[1][4].priority > 200)
        -- SGR 31 borrows the colorscheme's error colour.
        local expected = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
        local got = vim.api.nvim_get_hl(0, { name = m[1][4].hl_group, link = false })
        assert.are.equal(expected.fg, got.fg)
    end)

    it("honours row and column offsets", function()
        local buf, ns = new_buf()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "fence", "  red", "fence" })
        local items = Ansi.scan({ "\27[31mred\27[0m" })
        assert.are.equal("red", items[1].text)
        Ansi.apply(buf, ns, 0, items, { row_offset = 1, col_offset = 2 })
        local m = marks(buf, ns)
        assert.are.equal(1, #m)
        assert.are.equal(1, m[1][2]) -- row_offset
        assert.are.equal(2, m[1][3]) -- col_offset
        assert.are.equal(5, m[1][4].end_col)
    end)

    it("creates one reusable group per distinct style", function()
        local buf, ns = new_buf()
        local items = Ansi.scan({
            "\27[31mred\27[0m",
            "\27[31mred again\27[0m",
            "\27[32mgreen\27[0m",
        })
        local texts = {}
        for i, item in ipairs(items) do
            texts[i] = item.text
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, texts)
        Ansi.apply(buf, ns, 0, items)
        local m = marks(buf, ns)
        local groups = {}
        for _, one in ipairs(m) do
            groups[one[4].hl_group] = true
        end
        local n = 0
        for _ in pairs(groups) do
            n = n + 1
        end
        assert.are.equal(2, n)
    end)
end)

describe("pi.ui.chat.ansi degradation", function()
    before_each(function()
        Ansi._reset()
    end)

    after_each(function()
        Ansi._reset()
    end)

    it("turns itself off after a highlight failure and keeps text clean", function()
        local buf, ns = new_buf()
        local real_set_hl = vim.api.nvim_set_hl
        -- Fail only the ANSI group creation, not the rest of the suite.
        vim.api.nvim_set_hl = function(ns_id, name, attrs)
            if name:match("^PiAnsi") then
                error("boom")
            end
            return real_set_hl(ns_id, name, attrs)
        end
        local ok, err = pcall(function()
            local items = Ansi.scan({ "\27[31mred\27[0m" })
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { items[1].text })
            Ansi.apply(buf, ns, 0, items)
            assert.is_false(Ansi.enabled)
            assert.is_truthy(Ansi.disabled_reason)
            assert.are.equal(0, #marks(buf, ns))
            -- Text still comes back escape-free.
            assert.are.equal("red", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
        end)
        vim.api.nvim_set_hl = real_set_hl
        assert.is_true(ok, tostring(err))
    end)
end)
