-- `:PiWeb*` command surface: every console command is registered, and the pure
-- helpers behind them (`cli_argv`, the service report, doctor/pairing rendering,
-- the local launch flow) behave. The command bodies themselves are exercised
-- through the module entry points elsewhere; here the contract is "they exist,
-- they route to pi.web.ctl, and they degrade to one line".

local Config = require("pi.config")
Config.setup({})
require("pi.commands").setup()

local Ctl = require("pi.web.ctl")

--- Capture `vim.notify` for the duration of `fn`.
--- @param fn fun()
--- @return string[]
local function capture_notify(fn)
    local real = vim.notify
    local notes = {}
    vim.notify = function(msg)
        notes[#notes + 1] = tostring(msg)
    end
    local ok, err = pcall(fn)
    vim.notify = real
    if not ok then
        error(err)
    end
    return notes
end

describe(":PiWeb command surface", function()
    it("registers every console command", function()
        local cmds = vim.api.nvim_get_commands({})
        for _, name in ipairs({
            "PiWeb",
            "PiWebDoctor",
            "PiWebPair",
            "PiWebLog",
        }) do
            assert.is_not_nil(cmds[name], "missing :" .. name)
        end
        -- The lifecycle commands stay registered.
        for _, name in ipairs({ "PiWebStart", "PiWebStop", "PiWebStatus" }) do
            assert.is_not_nil(cmds[name], "missing :" .. name)
        end
        assert.is_nil(cmds.PiWebAccess, ":PiWebAccess is gone with the access modes")
        assert.equals("?", cmds.PiWebLog.nargs)
    end)

    it("builds a plain `<bin> <sub>` argv — there is no npx path", function()
        assert.same(
            { "/usr/local/bin/pi2", "doctor", "--json" },
            Ctl.cli_argv({ bin = "/usr/local/bin/pi2", source = "path" }, "doctor", { "--json" })
        )
        assert.same(
            { "/usr/bin/pi2", "service", "status", "--json" },
            Ctl.cli_argv({ bin = "/usr/bin/pi2", source = "system" }, "service", { "status", "--json" })
        )
        for _, argv in ipairs({
            Ctl.cli_argv({ bin = "pi2", source = "path" }, "daemon"),
            Ctl.cli_argv({ bin = "pi2", source = "env" }, "config", { "--json" }),
        }) do
            for _, part in ipairs(argv) do
                assert.is_nil(part:find("npx", 1, true), "no argv may mention npx: " .. table.concat(argv, " "))
            end
        end
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
        Config.options.web.open = false
        Ctl.ensure_running = function()
            return { port = 7676 }
        end
        local notes = capture_notify(Ctl.launch)
        Ctl.ensure_running = saved_ensure
        Config.options.web.open = saved_open

        local reported = table.concat(notes, "\n")
        assert.is_truthy(reported:find("http://127.0.0.1:7676", 1, true))
        assert.is_truthy(reported:find("web.open is off", 1, true))
    end)
end)

describe(":PiWeb degradation", function()
    it("degrades to a one-line notify instead of throwing", function()
        local ok = Ctl.call("does_not_exist")
        local real_launch = Ctl.launch
        Ctl.launch = function()
            error("boom")
        end
        local notes = capture_notify(function()
            Ctl.call("launch")
        end)
        Ctl.launch = real_launch

        assert.is_false(ok)
        assert.equals(1, #notes)
        for _, note in ipairs(notes) do
            assert.is_nil(note:find("\n", 1, true), "notify must stay one line: " .. note)
        end
    end)
end)
