-- `:PiWeb*` command surface: every console command is registered, and the pure
-- helpers behind them (`cli_argv`, install planning, doctor/pairing rendering,
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
            "PiWebInstall",
            "PiWebUpdate",
            "PiWebDoctor",
            "PiWebPair",
            "PiWebService",
            "PiWebLog",
        }) do
            assert.is_not_nil(cmds[name], "missing :" .. name)
        end
        -- The lifecycle commands stay registered.
        for _, name in ipairs({ "PiWebStart", "PiWebStop", "PiWebStatus" }) do
            assert.is_not_nil(cmds[name], "missing :" .. name)
        end
        assert.is_nil(cmds.PiWebAccess, ":PiWebAccess is gone with the access modes")
        assert.equals("*", cmds.PiWebInstall.nargs)
        assert.equals("*", cmds.PiWebService.nargs)
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

describe(":PiWebInstall planning", function()
    local saved

    before_each(function()
        saved = { confirm = Ctl.confirm, run = Ctl.run, install_dir = Ctl.install_dir }
        -- No resolvable pi2: the npm channel is the only one the plugin can bootstrap.
        local Runtime = require("pi.web.runtime")
        saved.resolve = Runtime.resolve_daemon
        Runtime.resolve_daemon = function()
            return nil
        end
    end)

    after_each(function()
        Ctl.confirm = saved.confirm
        Ctl.run = saved.run
        Ctl.install_dir = saved.install_dir
        require("pi.web.runtime").resolve_daemon = saved.resolve
    end)

    it("defaults to @yuez/pi2d@latest and can be pinned by a version argument", function()
        assert.equals("@yuez/pi2d@latest", Ctl.package_spec(nil))
        assert.equals("@yuez/pi2d@latest", Ctl.package_spec("latest"))
        assert.equals("@yuez/pi2d@0.1.6", Ctl.package_spec("0.1.6"))
        assert.equals("@yuez/pi2d@0.1.6", Ctl.package_spec("@yuez/pi2d@0.1.6"))
    end)

    it("parses --global and an optional version", function()
        local global, version = Ctl.parse_install_args({ "--global", "0.1.6" })
        assert.is_true(global)
        assert.equals("0.1.6", version)
        local global2, version2 = Ctl.parse_install_args({})
        assert.is_false(global2)
        assert.is_nil(version2)
    end)

    it("asks before running npm and runs it only on confirmation", function()
        local ran = {}
        Ctl.run = function(argv)
            ran[#ran + 1] = argv
            return true
        end
        Ctl.install_dir = function()
            return "/tmp/pi2d"
        end

        Ctl.confirm = function()
            return false
        end
        local cancelled = capture_notify(function()
            Ctl.install({})
        end)
        assert.equals(0, #ran)
        assert.is_truthy(table.concat(cancelled, "\n"):find("cancelled", 1, true))

        Ctl.confirm = function()
            return true
        end
        capture_notify(function()
            Ctl.install({})
        end)
        assert.same({ "npm", "i", "--prefix", "/tmp/pi2d", "@yuez/pi2d@latest" }, ran[1])

        capture_notify(function()
            Ctl.install({ "--global", "0.1.6" })
        end)
        assert.same({ "npm", "i", "-g", "@yuez/pi2d@0.1.6" }, ran[2])
    end)
end)

describe(":PiWebService actions", function()
    local saved

    before_each(function()
        saved = { ops = package.loaded["pi.web.ops"], confirm = Ctl.confirm, run = Ctl.run }
    end)

    after_each(function()
        package.loaded["pi.web.ops"] = saved.ops
        Ctl.confirm = saved.confirm
        Ctl.run = saved.run
    end)

    it("renders `pi2 service status` as lines and points at install", function()
        package.loaded["pi.web.ops"] = {
            SERVICE_ACTIONS = { "status", "start", "stop", "enable", "disable" },
            service_status = function(on_done)
                on_done({
                    manager = "systemd",
                    unit = {
                        name = "pi2.service",
                        path = "/home/u/.config/systemd/user/pi2.service",
                        installed = false,
                    },
                    enabled = nil,
                    active = nil,
                    linger = false,
                    error = nil,
                })
            end,
        }
        local notes = capture_notify(function()
            Ctl.service({})
        end)
        local text = table.concat(notes, "\n")
        assert.is_truthy(text:find("service: systemd", 1, true))
        assert.is_truthy(text:find("(missing)", 1, true))
        assert.is_truthy(text:find(":PiWebService install", 1, true))
    end)

    it("routes enable/disable/start/stop through pi.web.ops", function()
        local seen = {}
        package.loaded["pi.web.ops"] = {
            SERVICE_ACTIONS = { "status", "start", "stop", "enable", "disable" },
            service = function(action, on_done)
                seen[#seen + 1] = action
                on_done({ code = 0, stdout = "", stderr = "", argv = { "pi2", "service", action } })
            end,
        }
        local notes = capture_notify(function()
            Ctl.service({ "enable" })
        end)
        assert.same({ "enable" }, seen)
        assert.is_truthy(table.concat(notes, "\n"):find("service enable done", 1, true))
    end)

    it("rejects an unknown action without touching the service", function()
        package.loaded["pi.web.ops"] = {
            SERVICE_ACTIONS = { "status", "start", "stop", "enable", "disable" },
        }
        local notes = capture_notify(function()
            Ctl.service({ "frobnicate" })
        end)
        assert.is_truthy(table.concat(notes, "\n"):find("unknown :PiWebService action", 1, true))
    end)

    it("writes the unit for `install` and mentions the enable step", function()
        local Runtime = require("pi.web.runtime")
        local saved_resolve = Runtime.resolve_daemon
        Runtime.resolve_daemon = function()
            return { bin = "/usr/bin/pi2", source = "path" }
        end
        local ran = {}
        Ctl.run = function(argv, on_done)
            ran[#ran + 1] = argv
            on_done({ code = 0, stdout = "wrote /home/u/.config/systemd/user/pi2.service\n", stderr = "" })
            return true
        end
        Ctl.confirm = function()
            return true
        end
        local notes = capture_notify(function()
            Ctl.service({ "install" })
        end)
        Runtime.resolve_daemon = saved_resolve

        assert.same({ "/usr/bin/pi2", "install-service", "--write" }, ran[1])
        assert.is_truthy(table.concat(notes, "\n"):find(":PiWebService enable", 1, true))
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

describe(":PiWebInstall / :PiWebUpdate channel dispatch", function()
    local Runtime = require("pi.web.runtime")
    local saved

    --- Stub `Ctl.run` with a pi2 that reports `shape`, and answer the update
    --- probes with `replies` ({ check = payload, update = payload }).
    --- @param shape string|nil
    --- @param replies? table
    --- @return table[] argv log
    local function fake_run(shape, replies)
        replies = replies or {}
        local ran = {}
        Ctl.run = function(argv, on_done)
            ran[#ran + 1] = argv
            local joined = table.concat(argv, " ")
            local res = { code = 0, stdout = "", stderr = "", argv = argv }
            if joined:find("config %-%-json") then
                if shape ~= nil then
                    res.stdout = vim.json.encode({ installShape = shape })
                else
                    res.code = 1
                    res.stderr = "pi2: config failed"
                end
            elseif joined:find("update %-%-json %-%-check") then
                res.stdout = vim.json.encode(replies.check or {})
                if replies.check_code then
                    res.code = replies.check_code
                    res.stdout = ""
                    res.stderr = replies.check_stderr or ""
                end
            elseif joined:find("update") then
                res.stdout = vim.json.encode(replies.update or {})
                if replies.update_code then
                    res.code = replies.update_code
                    res.stdout = ""
                    res.stderr = replies.update_stderr or ""
                end
            end
            on_done(res)
            return true
        end
        return ran
    end

    before_each(function()
        saved =
            { resolve = Runtime.resolve_daemon, run = Ctl.run, confirm = Ctl.confirm, install_dir = Ctl.install_dir }
        Runtime.resolve_daemon = function()
            return { bin = "/usr/local/bin/pi2", source = "path" }
        end
        Ctl.install_dir = function()
            return "/tmp/pi2d"
        end
        Ctl.confirm = function()
            return true
        end
    end)

    after_each(function()
        Runtime.resolve_daemon = saved.resolve
        Ctl.run = saved.run
        Ctl.confirm = saved.confirm
        Ctl.install_dir = saved.install_dir
    end)

    it("maps the plugin flags onto `pi2 update`", function()
        local resolved = { bin = "/usr/local/bin/pi2", source = "path" }
        assert.same({ "/usr/local/bin/pi2", "update", "--json" }, Ctl.update_argv(resolved))
        assert.same(
            { "/usr/local/bin/pi2", "update", "--json", "--check" },
            Ctl.update_argv(resolved, { check = true })
        )
        assert.same(
            { "/usr/local/bin/pi2", "update", "--json", "--version", "0.1.6" },
            Ctl.update_argv(resolved, { version = "@yuez/pi2d@0.1.6" })
        )
        assert.same(
            { "/usr/local/bin/pi2", "update", "--json", "--force", "--version", "0.1.7" },
            Ctl.update_argv(resolved, { version = "v0.1.7", force = true })
        )
        -- `latest` is not a pin.
        assert.same({ "/usr/local/bin/pi2", "update", "--json" }, Ctl.update_argv(resolved, { version = "latest" }))
    end)

    it("parses --check and --force alongside the version", function()
        local global, version, check, force = Ctl.parse_install_args({ "--global", "--check", "0.1.6" })
        assert.is_true(global)
        assert.equals("0.1.6", version)
        assert.is_true(check)
        assert.is_false(force)

        local _, _, _, forced = Ctl.parse_install_args({ "--force" })
        assert.is_true(forced)
    end)

    it("renders update payloads as one line", function()
        assert.equals(
            "web console: pi2 0.1.7 is up to date (latest 0.1.7)",
            Ctl.update_report({ action = "up-to-date", current = "0.1.7", latest = "0.1.7" })
        )
        assert.equals(
            "web console: pi2 0.1.6 — latest 0.1.7",
            Ctl.update_report({ action = "checked", current = "0.1.6", latest = "0.1.7" })
        )
        local installed = Ctl.update_report({
            action = "installed",
            current = "0.1.6",
            latest = "0.1.7",
            restart = "pi2 service stop && pi2 service start",
        })
        assert.is_truthy(installed:find("0.1.6 → 0.1.7 installed", 1, true))
        assert.is_truthy(installed:find("pi2 service stop", 1, true))
    end)

    it("uses npm for an npm-installed (node) pi2", function()
        local ran = fake_run("node")
        capture_notify(function()
            Ctl.update({})
        end)
        assert.same({ "npm", "i", "--prefix", "/tmp/pi2d", "@yuez/pi2d@latest" }, ran[2])
    end)

    it("drives `pi2 update` for a standalone (bundled) pi2, asking first", function()
        local ran = fake_run("bundled", {
            check = { action = "checked", current = "0.1.6", latest = "0.1.7", updatable = true },
            update = {
                action = "installed",
                current = "0.1.6",
                latest = "0.1.7",
                restart = "pi2 service stop && pi2 service start",
            },
        })
        local notes = capture_notify(function()
            Ctl.update({})
        end)
        local text = table.concat(notes, "\n")

        assert.equals(3, #ran)
        assert.equals("config", ran[1][2])
        assert.same({ "/usr/local/bin/pi2", "update", "--json", "--check" }, ran[2])
        assert.same({ "/usr/local/bin/pi2", "update", "--json" }, ran[3])
        for _, argv in ipairs(ran) do
            assert.is_true(argv[1] ~= "npm", "the standalone channel must not shell out to npm")
        end
        assert.is_truthy(text:find("0.1.6 → 0.1.7 installed", 1, true))
        assert.is_truthy(text:find("restart the daemon", 1, true))
    end)

    it("--check only reports and never downloads", function()
        local ran = fake_run("bundled", {
            check = { action = "checked", current = "0.1.6", latest = "0.1.7", updatable = true },
        })
        local asked = false
        Ctl.confirm = function()
            asked = true
            return true
        end
        local notes = capture_notify(function()
            Ctl.update({ "--check" })
        end)
        assert.equals(2, #ran)
        assert.is_false(asked)
        assert.is_truthy(table.concat(notes, "\n"):find("latest 0.1.7", 1, true))
    end)

    it("reports up-to-date without asking", function()
        local ran = fake_run("bundled", { check = { action = "up-to-date", current = "0.1.7", latest = "0.1.7" } })
        local asked = false
        Ctl.confirm = function()
            asked = true
            return true
        end
        local notes = capture_notify(function()
            Ctl.update({})
        end)
        assert.equals(2, #ran)
        assert.is_false(asked)
        assert.is_truthy(table.concat(notes, "\n"):find("is up to date", 1, true))
    end)

    it("pins a version with --force, straight from the command", function()
        local ran = fake_run("bundled", {
            update = { action = "installed", current = "0.1.7", latest = "0.1.6", restart = "pi2 stop" },
        })
        capture_notify(function()
            Ctl.update({ "0.1.6" })
        end)
        assert.equals(2, #ran)
        assert.same({ "/usr/local/bin/pi2", "update", "--json", "--force", "--version", "0.1.6" }, ran[2])
    end)

    it("surfaces the CLI's channel refusal instead of running npm", function()
        local ran = fake_run("bundled", {
            check_code = 1,
            check_stderr = "pi2: pi2 was installed by brew; let it upgrade itself: brew upgrade pi2d",
        })
        local notes = capture_notify(function()
            Ctl.update({})
        end)
        local text = table.concat(notes, "\n")
        assert.equals(2, #ran)
        assert.is_truthy(text:find("brew upgrade pi2d", 1, true))
        assert.is_truthy(text:find("update unavailable", 1, true))
    end)

    it("cancels when the user says no", function()
        local ran = fake_run("bundled", {
            check = { action = "checked", current = "0.1.6", latest = "0.1.7", updatable = true },
            update = { action = "installed", current = "0.1.6", latest = "0.1.7" },
        })
        Ctl.confirm = function()
            return false
        end
        local notes = capture_notify(function()
            Ctl.update({})
        end)
        assert.equals(2, #ran)
        assert.is_truthy(table.concat(notes, "\n"):find("update cancelled", 1, true))
    end)

    it("warns that --global is npm-only on the standalone channel", function()
        fake_run("bundled", { check = { action = "up-to-date", current = "0.1.7", latest = "0.1.7" } })
        local notes = capture_notify(function()
            Ctl.update({ "--global" })
        end)
        local text = table.concat(notes, "\n")
        assert.is_truthy(text:find("--global is npm-only", 1, true))
        assert.is_truthy(text:find("is up to date", 1, true))
    end)

    it("falls back to npm when the install shape is unknown", function()
        local ran = fake_run(nil)
        local notes = capture_notify(function()
            Ctl.update({})
        end)
        assert.same({ "npm", "i", "--prefix", "/tmp/pi2d", "@yuez/pi2d@latest" }, ran[2])
        assert.is_truthy(table.concat(notes, "\n"):find("could not tell how this pi2 was installed", 1, true))
    end)

    it("`install` shares the dispatch (a standalone pi2 reinstalls via pi2 update)", function()
        local ran = fake_run("bundled", {
            check = { action = "checked", current = "0.1.6", latest = "0.1.7", updatable = true },
            update = { action = "installed", current = "0.1.6", latest = "0.1.7" },
        })
        capture_notify(function()
            Ctl.install({})
        end)
        assert.equals("config", ran[1][2])
        assert.equals("update", ran[2][2])
    end)
end)
