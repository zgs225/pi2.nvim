-- `:PiWeb*` command surface: all five console commands are registered, and the
-- pure helpers behind them (`cli_argv`, doctor/pairing rendering, the local
-- launch flow) behave. The command bodies themselves are exercised through the
-- module entry points elsewhere; here the contract is "they exist and degrade".

local Config = require("pi.config")
Config.setup({})
require("pi.commands").setup()

local Ctl = require("pi.web.ctl")

describe(":PiWeb command surface", function()
    it("registers every console command", function()
        local cmds = vim.api.nvim_get_commands({})
        for _, name in ipairs({ "PiWeb", "PiWebInstall", "PiWebUpdate", "PiWebDoctor", "PiWebPair" }) do
            assert.is_not_nil(cmds[name], "missing :" .. name)
        end
        -- The pre-existing lifecycle commands stay registered.
        for _, name in ipairs({ "PiWebStart", "PiWebStop", "PiWebStatus" }) do
            assert.is_not_nil(cmds[name], "missing :" .. name)
        end
        assert.is_nil(cmds.PiWebAccess, ":PiWebAccess is gone with the access modes")
        assert.equals("*", cmds.PiWebInstall.nargs)
    end)

    it("builds the npx argv for the pinned package and the plain argv otherwise", function()
        assert.same(
            { "npx", "-y", "@yuez/pi2d@latest", "doctor", "--json" },
            Ctl.cli_argv({ bin = "npx", source = "npx" }, "doctor", { "--json" })
        )
        assert.same(
            { "/usr/local/bin/pi2", "daemon", "--force" },
            Ctl.cli_argv({ bin = "/usr/local/bin/pi2", source = "path" }, "daemon", { "--force" })
        )
    end)

    it("renders `pi2 doctor --json` as name/status/detail lines", function()
        local report = vim.json.encode({
            ok = false,
            checks = {
                { name = "node", status = "ok", detail = "v22.1.0" },
                { name = "bind", status = "warn", detail = "127.0.0.1:7676" },
            },
        })
        assert.same({ "node ok v22.1.0", "bind warn 127.0.0.1:7676" }, Ctl.render_doctor(report))
        assert.same({}, Ctl.render_doctor(""))
        assert.same({ "plain text report" }, Ctl.render_doctor("plain text report\n"))
    end)

    it("summarises a pairing report on hosts without a UI", function()
        assert.equals(
            "web console: pair a device at http://192.168.2.10:7676/pair/ABCD2345 (code ABCD2345)",
            Ctl.pairing_line({ url = "http://192.168.2.10:7676/pair/ABCD2345", code = "ABCD2345" })
        )
    end)

    it("reports the URL instead of opening a browser when web.open is false", function()
        local saved_open = Config.options.web.open
        local saved_ensure = Ctl.ensure_running
        local real_notify = vim.notify
        local notes = {}
        vim.notify = function(msg)
            notes[#notes + 1] = tostring(msg)
        end
        Config.options.web.open = false
        Ctl.ensure_running = function()
            return { port = 7676 }
        end
        Ctl.launch()
        Ctl.ensure_running = saved_ensure
        Config.options.web.open = saved_open
        vim.notify = real_notify

        local reported = table.concat(notes, "\n")
        assert.is_truthy(reported:find("http://127.0.0.1:7676", 1, true))
        assert.is_truthy(reported:find("web.open is off", 1, true))
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
        local ok2 = Ctl.call("launch")
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
