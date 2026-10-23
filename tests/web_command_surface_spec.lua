-- `:PiWeb*` command surface: all seven console commands are registered, and the
-- pure helpers behind them (`cli_argv`, doctor/pairing rendering, the external
-- URL) behave. The command bodies themselves are exercised through the module
-- entry points elsewhere; here the contract is "they exist and degrade".

local Config = require("pi.config")
Config.setup({})
require("pi.commands").setup()

local Ctl = require("pi.web.ctl")

describe(":PiWeb command surface", function()
    it("registers every console command", function()
        local cmds = vim.api.nvim_get_commands({})
        for _, name in ipairs({ "PiWeb", "PiWebInstall", "PiWebUpdate", "PiWebDoctor", "PiWebAccess", "PiWebPair" }) do
            assert.is_not_nil(cmds[name], "missing :" .. name)
        end
        -- The pre-existing lifecycle commands stay registered.
        for _, name in ipairs({ "PiWebStart", "PiWebStop", "PiWebStatus" }) do
            assert.is_not_nil(cmds[name], "missing :" .. name)
        end
        assert.equals("?", cmds.PiWebAccess.nargs)
        assert.equals("*", cmds.PiWebInstall.nargs)
    end)

    it("builds the npx argv for the pinned package and the plain argv otherwise", function()
        assert.same(
            { "npx", "-y", "@yuez/pi2d@latest", "doctor", "--json" },
            Ctl.cli_argv({ bin = "npx", source = "npx" }, "doctor", { "--json" })
        )
        assert.same(
            { "/usr/local/bin/pi2", "pairing", "--public-url", "https://h.ts.net" },
            Ctl.cli_argv(
                { bin = "/usr/local/bin/pi2", source = "path" },
                "pairing",
                { "--public-url", "https://h.ts.net" }
            )
        )
    end)

    it("renders `pi2 doctor --json` as name/status/detail lines", function()
        local report = vim.json.encode({
            ok = false,
            checks = {
                { name = "node", status = "ok", detail = "v22.1.0" },
                { name = "access", status = "warn", detail = "lan (bind 0.0.0.0/7676)" },
            },
        })
        assert.same({ "node ok v22.1.0", "access warn lan (bind 0.0.0.0/7676)" }, Ctl.render_doctor(report))
        assert.same({}, Ctl.render_doctor(""))
        assert.same({ "plain text report" }, Ctl.render_doctor("plain text report\n"))
    end)

    it("renders the pairing url + code", function()
        local stdout = "url     http://127.0.0.1:7676/pair/ABCD-1234\n"
            .. "code    ABCD-1234\n"
            .. "expires 2026-01-01T00:00:00.000Z (60s)\n"
            .. 'qr      {"v":1}\n'
        assert.equals(
            "web console: pair a device at http://127.0.0.1:7676/pair/ABCD-1234 (code ABCD-1234)",
            Ctl.render_pairing(stdout)
        )
    end)

    it("prefers the daemon's publicUrl for the external URL", function()
        local saved = Config.options.web.public_url
        Config.options.web.public_url = nil
        assert.equals(
            "https://myhost.tail1234.ts.net",
            Ctl.external_url("tailscale", { port = 7676, publicUrl = "https://myhost.tail1234.ts.net/" })
        )
        Config.options.web.public_url = nil
        assert.is_truthy(Ctl.external_url("lan", { port = 7676 }):find("other devices", 1, true))
        Config.options.web.public_url = "https://cfg.example"
        assert.equals("https://cfg.example", Ctl.external_url("lan", { port = 7676 }))
        Config.options.web.public_url = saved
    end)

    it("degrades to a one-line notify instead of throwing", function()
        local real_notify = vim.notify
        local notes = {}
        vim.notify = function(msg)
            notes[#notes + 1] = msg
        end
        local ok = Ctl.call("does_not_exist")
        local real_launch = Ctl.launch
        Ctl.launch = function()
            error("boom")
        end
        local ok2 = Ctl.call("launch", "local")
        Ctl.launch = real_launch
        vim.notify = real_notify

        assert.is_false(ok)
        assert.is_false(ok2)
        assert.equals(2, #notes)
        for _, note in ipairs(notes) do
            assert.is_nil(note:find("\n", 1, true), "notify must stay one line: " .. note)
        end
    end)
end)
