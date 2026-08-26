-- Unit tests for the auto session title feature: runtime config publication
-- (pi.title), CLI injection of the bundled extension (pi.cli), and the pi
-- version floor (pi.compat). Pure logic only; no RPC, no UI.

local Cli = require("pi.cli")
local Compat = require("pi.compat")
local Title = require("pi.title")

describe("pi.title", function()
    local dir

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        Title._set_path(dir .. "/title-config")
    end)

    after_each(function()
        Title._set_path(nil)
        vim.fn.delete(dir, "rf")
    end)

    describe("published", function()
        it("returns nil without a runtime file", function()
            assert.is_nil(Title.published())
        end)

        it("round-trips defaults", function()
            Title.publish(nil)
            local cfg = Title.published()
            assert.is_true(cfg.enabled)
            assert.are.equal(40, cfg.maxChars)
            assert.is_nil(cfg.lang)
        end)

        it("round-trips custom max_chars and lang", function()
            Title.publish({ enabled = true, max_chars = 25, lang = "zh-CN" })
            local cfg = Title.published()
            assert.is_true(cfg.enabled)
            assert.are.equal(25, cfg.maxChars)
            assert.are.equal("zh-CN", cfg.lang)
        end)

        it("persists an explicit disable", function()
            Title.publish({ enabled = false })
            local cfg = Title.published()
            assert.is_false(cfg.enabled)
        end)

        it("normalizes empty lang to nil and non-numeric max_chars to 40", function()
            Title.publish({ enabled = true, max_chars = "lots", lang = "" })
            local cfg = Title.published()
            assert.are.equal(40, cfg.maxChars)
            assert.is_nil(cfg.lang)
        end)

        it("returns nil for a corrupt runtime file", function()
            local f = io.open(Title.state_path(), "w")
            f:write("not json")
            f:close()
            assert.is_nil(Title.published())
        end)
    end)
end)

describe("pi.cli title injection", function()
    it("injects the bundled title extension before --mode rpc", function()
        local cmd = Cli.command()
        local aug = table.concat(cmd, " ")
        assert.is_true(
            aug:find("--extension%s+%S+title%.ts", 1) ~= nil,
            "expected --extension <path>/extensions/title.ts"
        )
        local mode_idx = nil
        for i, part in ipairs(cmd) do
            if part == "--mode" then
                mode_idx = i
                break
            end
        end
        assert.is_not.is_nil(mode_idx)
        local title_idx = nil
        for i, part in ipairs(cmd) do
            if part:find("title[^/]*%.ts$") then
                title_idx = i
                break
            end
        end
        assert.is_not.is_nil(title_idx)
        assert.is_true(title_idx < mode_idx, "title extension must be injected before --mode")
    end)
end)

describe("pi.compat title floor", function()
    it("declares a version floor for the title extension", function()
        assert.are.equal("0.44.0", Compat.title_min_supported)
    end)
end)
