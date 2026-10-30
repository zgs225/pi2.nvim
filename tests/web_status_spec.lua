-- `:PiWebStatus` rendering: `pi.web.status_lines(extra)` (init.lua) plus the
-- The `:PiWebStatus` service formatter (ctl.lua). Both are pure string builders —
-- no daemon, no service manager, no subprocess — so the specs only stub the
-- probes that feed them.

local Config = require("pi.config")
Config.setup({})

local Runtime = require("pi.web.runtime")
local Web = require("pi.web")
local Ctl = require("pi.web.ctl")

--- Replace fields, returning the previous ones.
local function stub(target, values)
    local saved = {}
    for key, value in pairs(values) do
        saved[key] = target[key]
        target[key] = value
    end
    return saved
end

describe("pi.web.status_lines", function()
    local saved

    after_each(function()
        if saved then
            for key, value in pairs(saved) do
                Runtime[key] = value
            end
            saved = nil
        end
    end)

    it("reports the binary source, the daemon URL, the service and the version", function()
        saved = stub(Runtime, {
            resolve_daemon = function()
                return { bin = "/usr/bin/pi2", source = "path" }
            end,
            read_daemon_json = function()
                return { port = 7676 }
            end,
            socket_path = function()
                return "/run/user/1000/pi2/d.sock"
            end,
        })

        local lines = Web.status_lines({
            version = "0.1.6",
            install_shape = "bundled",
            service = {
                manager = "systemd",
                unit = { name = "pi2.service", path = "/home/u/.config/systemd/user/pi2.service", installed = true },
                enabled = true,
                active = true,
                linger = false,
                error = nil,
            },
        })
        local text = table.concat(lines, "\n")
        assert.is_truthy(text:find("daemon: /usr/bin/pi2 (path)", 1, true))
        assert.is_truthy(text:find("daemon: running at http://127.0.0.1:7676", 1, true))
        assert.is_truthy(text:find("service: systemd", 1, true))
        assert.is_truthy(text:find("enabled=yes", 1, true))
        assert.is_truthy(text:find("linger=no", 1, true))
        assert.is_truthy(text:find("pi2: 0.1.6 (bundled)", 1, true))
        assert.is_truthy(text:find("autostart: auto", 1, true))
    end)

    it("explains a missing binary and a missing daemon", function()
        saved = stub(Runtime, {
            resolve_daemon = function()
                return nil
            end,
            read_daemon_json = function()
                return nil
            end,
            socket_path = function()
                return "/run/user/1000/pi2/d.sock"
            end,
        })

        local text = table.concat(Web.status_lines(), "\n")
        assert.is_truthy(text:find("install the curl installer", 1, true))
        assert.is_truthy(text:find("daemon: not running", 1, true))
        assert.is_truthy(text:find("service: not probed", 1, true))
    end)

    it("says when no service manager is available", function()
        saved = stub(Runtime, {
            resolve_daemon = function()
                return { bin = "/usr/bin/pi2", source = "path" }
            end,
            read_daemon_json = function()
                return nil
            end,
        })
        local text =
            table.concat(Web.status_lines({ service = { manager = "none", error = "systemctl not found" } }), "\n")
        assert.is_truthy(text:find("service: no manager (systemctl not found)", 1, true))
    end)
end)

describe("pi.web.ctl service_lines", function()
    it("lists the unit state and the next step", function()
        local lines = Ctl.service_lines({
            manager = "launchd",
            unit = {
                name = "com.pi2.daemon.plist",
                path = "/Users/u/Library/LaunchAgents/com.pi2.daemon.plist",
                installed = true,
            },
            enabled = true,
            active = false,
            linger = nil,
            error = nil,
        })
        local text = table.concat(lines, "\n")
        assert.is_truthy(text:find("service: launchd", 1, true))
        assert.is_truthy(text:find("(installed)", 1, true))
        assert.is_truthy(text:find("enabled: yes   active: no", 1, true))
        assert.is_nil(text:find("linger", 1, true))
        assert.is_truthy(text:find("next: `systemctl --user enable --now pi2.service`", 1, true))
    end)

    it("suggests install when the unit is missing", function()
        local text = table.concat(
            Ctl.service_lines({
                manager = "systemd",
                unit = { name = "pi2.service", path = "/u/pi2.service", installed = false },
                enabled = nil,
                active = nil,
                linger = true,
                error = nil,
            }),
            "\n"
        )
        assert.is_truthy(text:find("next: `pi2 install-service --write`", 1, true))
        assert.is_truthy(text:find("linger: yes", 1, true))
    end)
end)

describe("pi.web.ctl status probes", function()
    it("never blocks or throws when pi.web.ops is missing", function()
        local saved_ops = package.loaded["pi.web.ops"]
        -- `require` returning a non-table is exactly how `ctl.ops()` detects a
        -- broken/missing module, so the notify path is exercised hermetically.
        package.loaded["pi.web.ops"] = true
        local real_notify = vim.notify
        local notes = {}
        vim.notify = function(msg)
            notes[#notes + 1] = tostring(msg)
        end
        local ok = pcall(Ctl.status)
        vim.notify = real_notify
        package.loaded["pi.web.ops"] = saved_ops
        assert.is_true(ok)
        assert.is_truthy(table.concat(notes, "\n"):find("pi.web.ops is missing", 1, true))
    end)
end)
