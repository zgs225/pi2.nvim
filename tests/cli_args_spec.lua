-- pi CLI arg filtering: version-gated flags and --provider/--model pairing.
--
-- The pi version probe (`vim.fn.system({ bin, "--version" })`) is stubbed via
-- `Cli._probe_version`, so no real binary is spawned and no state leaks.

local Config = require("pi.config")
local Cli = require("pi.cli")

Config.setup({})

--- vim.notify spy records.
local notes = {}

--- Number of `_probe_version` invocations since the last stub.
local probe_calls = 0

local orig_notify
local orig_probe

describe("pi.cli args gating", function()
    before_each(function()
        notes = {}
        probe_calls = 0
        Cli._reset()
        orig_notify = vim.notify
        orig_probe = Cli._probe_version
        vim.notify = function(msg, level)
            notes[#notes + 1] = { msg = msg, level = level }
        end
    end)

    after_each(function()
        vim.notify = orig_notify
        Cli._probe_version = orig_probe
        Cli._reset()
    end)

    --- Stub the version probe with a raw `pi --version` output (nil = failure).
    ---@param out string?
    local function stub_probe(out)
        probe_calls = 0
        Cli._probe_version = function()
            probe_calls = probe_calls + 1
            return out
        end
    end

    describe("gated flags", function()
        it("strips --no-mcp and warns once when pi is older than 1.0.4", function()
            stub_probe("pi 0.99.1")
            local out = Cli.filter_args({ "--no-mcp", "--foo" })
            assert.are.same({ "--foo" }, out)
            assert.are.same(1, #notes)
            assert.are.same(vim.log.levels.WARN, notes[1].level)
            assert.matches("%-%-no%-mcp", notes[1].msg)
            assert.matches("1%.0%.4", notes[1].msg)
            assert.matches("0%.99%.1", notes[1].msg)
        end)

        it("strips the --no-mcp=value form too", function()
            stub_probe("pi 0.99.1")
            local out = Cli.filter_args({ "--no-mcp=true" })
            assert.are.same({}, out)
            assert.are.same(1, #notes)
        end)

        it("keeps --no-mcp on pi 1.0.4 and newer", function()
            stub_probe("pi 1.1.0")
            local out = Cli.filter_args({ "--no-mcp" })
            assert.are.same({ "--no-mcp" }, out)
            assert.are.same(0, #notes)
        end)

        it("keeps --no-mcp exactly at the floor (1.0.4)", function()
            stub_probe("pi 1.0.4")
            local out = Cli.filter_args({ "--no-mcp" })
            assert.are.same({ "--no-mcp" }, out)
            assert.are.same(0, #notes)
        end)

        it("keeps --no-mcp and warns once when the version probe fails", function()
            stub_probe(nil)
            local out = Cli.filter_args({ "--no-mcp" })
            assert.are.same({ "--no-mcp" }, out)
            assert.are.same(1, #notes)
            assert.matches("%-%-no%-mcp", notes[1].msg)
            assert.matches("version", notes[1].msg)
        end)

        it("warns only once per flag across calls", function()
            stub_probe("pi 0.99.1")
            Cli.filter_args({ "--no-mcp" })
            Cli.filter_args({ "--no-mcp" })
            assert.are.same(1, #notes)
        end)

        it("probes the version only once (cached) across calls", function()
            stub_probe("pi 1.1.0")
            Cli.filter_args({ "--no-mcp" })
            Cli.filter_args({ "--no-mcp" })
            assert.are.same(1, probe_calls)
        end)

        it("does not probe when no gated flag is present", function()
            stub_probe("pi 1.1.0")
            Cli.filter_args({ "--foo", "--model", "gpt-x" })
            assert.are.same(0, probe_calls)
        end)
    end)

    describe("--provider/--model pairing", function()
        it("warns when --provider has no --model", function()
            Cli.filter_args({ "--provider", "openai" })
            assert.are.same(1, #notes)
            assert.are.same(vim.log.levels.WARN, notes[1].level)
            assert.matches("%-%-provider", notes[1].msg)
        end)

        it("warns when --provider=value has no --model", function()
            Cli.filter_args({ "--provider=openai" })
            assert.are.same(1, #notes)
            assert.matches("%-%-provider", notes[1].msg)
        end)

        it("does not warn when --model is present", function()
            local out = Cli.filter_args({ "--provider", "openai", "--model", "gpt-x" })
            assert.are.same({ "--provider", "openai", "--model", "gpt-x" }, out)
            assert.are.same(0, #notes)
        end)

        it("does not warn when --model=value is present", function()
            local out = Cli.filter_args({ "--provider=openai", "--model=gpt-x" })
            assert.are.same({ "--provider=openai", "--model=gpt-x" }, out)
            assert.are.same(0, #notes)
        end)

        it("does not confuse --models (scope) with --model", function()
            Cli.filter_args({ "--provider", "openai", "--models", "gpt-x" })
            assert.are.same(1, #notes)
            assert.matches("%-%-provider", notes[1].msg)
        end)

        it("warns only once across calls", function()
            Cli.filter_args({ "--provider", "openai" })
            Cli.filter_args({ "--provider", "openai" })
            assert.are.same(1, #notes)
        end)

        it("does not probe the version for a pairing warning", function()
            stub_probe("pi 1.1.0")
            Cli.filter_args({ "--provider", "openai" })
            assert.are.same(0, probe_calls)
        end)
    end)
end)
