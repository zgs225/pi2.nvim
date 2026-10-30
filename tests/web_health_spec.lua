-- `:checkhealth pi` web-console section. Every probe is injected through
-- `Health._web`, so the spec never spawns `pi2`, never reads the real runtime
-- dir and never depends on what is installed on this machine.

local Config = require("pi.config")
Config.setup({})

local Health = require("pi.health")

--- Run `Health.check()` with `vim.health` captured, `_web` overridden.
--- @param web table
--- @return string[] lines
local function run_check(web)
    local saved_web = Health._web
    Health._web = web
    local saved = {
        start = vim.health.start,
        ok = vim.health.ok,
        warn = vim.health.warn,
        error = vim.health.error,
        info = vim.health.info,
    }
    local lines = {}
    local function record(kind)
        return function(msg, advice)
            lines[#lines + 1] = kind .. " " .. tostring(msg)
            if type(advice) == "table" then
                for _, line in ipairs(advice) do
                    lines[#lines + 1] = kind .. " " .. tostring(line)
                end
            end
        end
    end
    vim.health.start = record("start")
    vim.health.ok = record("ok")
    vim.health.warn = record("warn")
    vim.health.error = record("error")
    vim.health.info = record("info")
    pcall(Health.check)
    vim.health.start = saved.start
    vim.health.ok = saved.ok
    vim.health.warn = saved.warn
    vim.health.error = saved.error
    vim.health.info = saved.info
    Health._web = saved_web
    return lines
end

describe(":checkhealth pi — web console", function()
    it("reports the resolved binary, the running daemon and the unit state", function()
        local lines = run_check({
            resolve = function()
                return { bin = "/usr/bin/pi2", source = "path" }
            end,
            daemon_json = function()
                return { port = 7676 }
            end,
            autostart_mode = function()
                return "auto"
            end,
            service_status = function()
                return {
                    manager = "systemd",
                    unit = { name = "pi2.service", path = "/home/u/.config/systemd/user/pi2.service", installed = true },
                    enabled = true,
                    active = false,
                    linger = true,
                    error = nil,
                }
            end,
        })
        local text = table.concat(lines, "\n")
        assert.is_truthy(text:find("pi2 found via path: `/usr/bin/pi2`", 1, true))
        assert.is_truthy(text:find("daemon running on http://127.0.0.1:7676", 1, true))
        assert.is_truthy(text:find("systemd unit installed", 1, true))
        assert.is_truthy(text:find("active=false", 1, true))
    end)

    it("points at the install commands when no binary is resolvable", function()
        local lines = run_check({
            resolve = function()
                return nil
            end,
            daemon_json = function()
                return nil
            end,
            autostart_mode = function()
                return "spawn"
            end,
            service_status = function()
                return { manager = "none", unit = nil, enabled = nil, active = nil, linger = nil, error = nil }
            end,
        })
        local text = table.concat(lines, "\n")
        assert.is_truthy(text:find("warn pi2 (the web-console daemon) was not found", 1, true))
        assert.is_truthy(text:find("npm i -g @yuez/pi2d", 1, true))
        assert.is_truthy(text:find("curl installer", 1, true))
        assert.is_truthy(text:find("no service manager available", 1, true))
        assert.is_truthy(text:find("autostart: spawn", 1, true))
    end)

    it("mentions the unit to install when none is present", function()
        local lines = run_check({
            resolve = function()
                return { bin = "/usr/bin/pi2", source = "env" }
            end,
            daemon_json = function()
                return nil
            end,
            autostart_mode = function()
                return "auto"
            end,
            service_status = function()
                return {
                    manager = "systemd",
                    unit = {
                        name = "pi2.service",
                        path = "/home/u/.config/systemd/user/pi2.service",
                        installed = false,
                    },
                    enabled = false,
                    active = false,
                    linger = nil,
                    error = nil,
                }
            end,
        })
        local text = table.concat(lines, "\n")
        assert.is_truthy(text:find("no systemd unit", 1, true))
        assert.is_truthy(text:find("pi2 install-service --write", 1, true))
        assert.is_truthy(text:find("no running daemon", 1, true))
    end)
end)
