-- `pi.web.ops`: the daemon process + user-service layer.
--
-- Everything here is injected: `Runtime.read_daemon_json` / `resolve_daemon`,
-- `Ops.system`, `Ops.open_log` and `vim.fn.jobstart` are stubbed, so no daemon,
-- systemctl or `pi2` binary is needed. The contract under test is the ladder
-- (attach → service → spawn), the autostart normalisation, and the `pi2 service`
-- argv/decoding — not the platform probes (those live in pi2d's own CLI tests).

local Runtime = require("pi.web.runtime")
local Ops = require("pi.web.ops")

--- Restore table fields after a test.
local function restore(saved, target)
    for key, value in pairs(saved) do
        target[key] = value
    end
end

--- Save the fields we are about to stub.
local function snapshot(target, keys)
    local saved = {}
    for _, key in ipairs(keys) do
        saved[key] = target[key]
    end
    return saved
end

describe("pi.web.ops.autostart_mode", function()
    it("honours the documented values", function()
        assert.equals("auto", Ops.autostart_mode({ autostart = "auto" }))
        assert.equals("spawn", Ops.autostart_mode({ autostart = "spawn" }))
        assert.is_false(Ops.autostart_mode({ autostart = false }))
    end)

    it("translates the deprecated boolean alias", function()
        assert.is_false(Ops.autostart_mode({ auto_start = false }))
        assert.equals("spawn", Ops.autostart_mode({ auto_start = true }))
    end)

    it("prefers autostart over the alias and defaults to auto", function()
        assert.equals("auto", Ops.autostart_mode({ autostart = "auto", auto_start = false }))
        assert.equals("auto", Ops.autostart_mode({}))
    end)

    it("labels every mode for :PiWebStatus", function()
        assert.is_truthy(Ops.autostart_label("auto"):find("attach", 1, true))
        assert.is_truthy(Ops.autostart_label("spawn"):find("spawn", 1, true))
        assert.is_truthy(Ops.autostart_label(false):find("connect only", 1, true))
    end)
end)

describe("pi.web.ops.decode_service_status", function()
    it("decodes the documented --json body", function()
        local status = Ops.decode_service_status({
            platform = "linux",
            manager = "systemd",
            unit = { name = "pi2.service", path = "/home/u/.config/systemd/user/pi2.service", installed = true },
            enabled = true,
            active = false,
            linger = true,
            error = vim.NIL,
        })
        assert.same({
            manager = "systemd",
            unit = {
                name = "pi2.service",
                path = "/home/u/.config/systemd/user/pi2.service",
                installed = true,
            },
            enabled = true,
            active = false,
            linger = true,
            error = nil,
        }, status)
    end)

    it("accepts raw JSON text and falls back to manager none", function()
        local status = Ops.decode_service_status(vim.json.encode({
            manager = "weird",
            enabled = vim.NIL,
            active = vim.NIL,
            error = "no manager",
        }))
        assert.equals("none", status.manager)
        assert.is_nil(status.enabled)
        assert.equals("no manager", status.error)
        assert.is_nil(status.unit)
    end)

    it("returns nil for unreadable payloads", function()
        assert.is_nil(Ops.decode_service_status(nil))
        assert.is_nil(Ops.decode_service_status(""))
        assert.is_nil(Ops.decode_service_status("not json"))
        assert.is_nil(Ops.decode_service_status({ manager = "systemd" }).unit)
    end)
end)

describe("pi.web.ops.tail_file", function()
    local dir ---@type string

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
    end)

    it("returns the last N lines and drops the partial first line", function()
        local path = dir .. "/daemon.log"
        vim.fn.writefile({ "one", "two", "three", "four" }, path)
        assert.same({ "three", "four" }, Ops.tail_file(path, 2))
        assert.same({ "one", "two", "three", "four" }, Ops.tail_file(path, 99))
    end)

    it("reports a missing file instead of failing", function()
        local lines, err = Ops.tail_file(dir .. "/absent.log", 10)
        assert.same({}, lines)
        assert.is_truthy(err:find("no log yet", 1, true))
    end)
end)

describe("pi.web.ops.spawn", function()
    local saved

    before_each(function()
        saved = {
            resolve = Runtime.resolve_daemon,
            open_log = Ops.open_log,
            jobstart = vim.fn.jobstart,
            config = require("pi.config").options.web,
        }
    end)

    after_each(function()
        Runtime.resolve_daemon = saved.resolve
        Ops.open_log = saved.open_log
        vim.fn.jobstart = saved.jobstart
        require("pi.config").options.web = saved.config
    end)

    it("spawns `<bin> daemon` detached and redirects the daemon log", function()
        local captured
        Runtime.resolve_daemon = function()
            return { bin = "/usr/bin/pi2", source = "path" }
        end
        Ops.open_log = function()
            return 42, "/state/pi2/daemon.log"
        end
        vim.fn.jobstart = function(argv, opts)
            captured = { argv = argv, opts = opts }
            return 4242
        end
        require("pi.config").options.web = {
            daemon_args = { "--port", "0" },
            host = "0.0.0.0",
            workspace_roots = { "~/src", "~/work" },
        }

        local ok, err = Ops.spawn()
        assert.is_true(ok)
        assert.is_nil(err)
        assert.same({ "/usr/bin/pi2", "daemon", "--port", "0" }, captured.argv)
        assert.is_true(captured.opts.detach)
        assert.equals(42, captured.opts.stdout)
        assert.equals(42, captured.opts.stderr)
        assert.equals("0.0.0.0", captured.opts.env.PI2_HOST)
        assert.equals("~/src,~/work", captured.opts.env.PI2_WORKSPACE_ROOTS)
    end)

    it("refuses without an installer message when no pi2 is resolvable", function()
        Runtime.resolve_daemon = function()
            return nil
        end
        local ok, err = Ops.spawn()
        assert.is_false(ok)
        assert.is_truthy(err:find("npm i -g @yuez/pi2d", 1, true))
    end)

    it("still spawns when the log cannot be opened", function()
        local captured
        Runtime.resolve_daemon = function()
            return { bin = "/usr/bin/pi2", source = "path" }
        end
        Ops.open_log = function()
            return nil, "/state/pi2/daemon.log"
        end
        vim.fn.jobstart = function(argv, opts)
            captured = { argv = argv, opts = opts }
            return 1
        end
        assert.is_true(Ops.spawn())
        assert.is_nil(captured.opts.stdout)
    end)
end)

describe("pi.web.ops.ensure", function()
    local saved

    before_each(function()
        saved = {
            read = Runtime.read_daemon_json,
            resolve = Runtime.resolve_daemon,
            spawn = Ops.spawn,
            service_status_sync = Ops.service_status_sync,
            run_sync = Ops.run_sync,
        }
    end)

    after_each(function()
        restore(saved, Runtime)
        restore(saved, Ops)
    end)

    it("attaches first, without needing a resolvable pi2", function()
        Runtime.read_daemon_json = function()
            return { port = 7676, pid = 10 }
        end
        Runtime.resolve_daemon = function()
            return nil
        end
        Ops.spawn = function()
            error("spawn must not run when a daemon is already published")
        end

        local info, err = Ops.ensure({ cfg = { autostart = "auto" } })
        assert.is_nil(err)
        assert.equals(7676, info.port)
    end)

    it("never starts anything when web.autostart is false", function()
        Runtime.read_daemon_json = function()
            return nil
        end
        Ops.spawn = function()
            error("spawn must not run when autostart is off")
        end

        local info, err = Ops.ensure({ cfg = { autostart = false } })
        assert.is_nil(info)
        assert.is_truthy(err:find("web.autostart is disabled", 1, true))
        assert.is_truthy(err:find("pi2 daemon", 1, true))
    end)

    it("starts the installed service before spawning", function()
        local published = false
        local actions = {}
        Runtime.read_daemon_json = function()
            return published and { port = 7676 } or nil
        end
        Runtime.resolve_daemon = function()
            return { bin = "/usr/bin/pi2", source = "path" }
        end
        Ops.service_status_sync = function()
            return { manager = "systemd", unit = { name = "pi2.service", path = "/u", installed = true } }
        end
        Ops.run_sync = function(argv)
            actions[#actions + 1] = table.concat(argv, " ")
            published = true
            return { code = 0, stdout = "", stderr = "" }
        end
        Ops.spawn = function()
            error("the service handled the start; spawn must not run")
        end

        local info, err = Ops.ensure({ cfg = { autostart = "auto" }, wait_ms = 200 })
        assert.is_nil(err)
        assert.equals(7676, info.port)
        assert.same({ "/usr/bin/pi2 service start" }, actions)
    end)

    it("falls through to a detached spawn when no unit is installed", function()
        local published = false
        Runtime.read_daemon_json = function()
            return published and { port = 7677 } or nil
        end
        Ops.service_status_sync = function()
            return { manager = "systemd", unit = { name = "pi2.service", path = "/u", installed = false } }
        end
        Ops.spawn = function()
            published = true
            return true
        end

        local info, err = Ops.ensure({ cfg = { autostart = "auto" }, wait_ms = 200 })
        assert.is_nil(err)
        assert.equals(7677, info.port)
    end)

    it("skips the service probe entirely in `spawn` mode", function()
        local published = false
        Runtime.read_daemon_json = function()
            return published and { port = 7678 } or nil
        end
        Ops.service_status_sync = function()
            error("spawn mode must not probe the service")
        end
        Ops.spawn = function()
            published = true
            return true
        end

        local info = Ops.ensure({ cfg = { autostart = "spawn" }, wait_ms = 200 })
        assert.equals(7678, info.port)
    end)

    it("reports the failing step when the spawn never publishes", function()
        Runtime.read_daemon_json = function()
            return nil
        end
        Ops.spawn = function()
            return true
        end

        local info, err = Ops.ensure({ cfg = { autostart = "spawn" }, wait_ms = 50, poll_ms = 10 })
        assert.is_nil(info)
        assert.is_truthy(err:find("did not publish daemon.json", 1, true))
    end)

    it("keeps the spawn error when spawning itself fails", function()
        Runtime.read_daemon_json = function()
            return nil
        end
        Ops.spawn = function()
            return false, "failed to spawn pi2"
        end

        local info, err = Ops.ensure({ cfg = { autostart = "spawn" }, wait_ms = 50 })
        assert.is_nil(info)
        assert.is_truthy(err:find("failed to spawn pi2", 1, true))
    end)
end)

describe("pi.web.ops.log_lines", function()
    local saved

    before_each(function()
        saved = { service_status_sync = Ops.service_status_sync, run_sync = Ops.run_sync, tail = Ops.tail_file }
        Ops.service_status_sync = function()
            return nil
        end
    end)

    after_each(function()
        restore(saved, Ops)
    end)

    it("reads the spawn-mode log and never returns nil", function()
        Ops.tail_file = function()
            return { "line one", "line two" }, nil
        end
        local lines = Ops.log_lines(2)
        assert.same({ "line one", "line two" }, lines)
    end)

    it("says so when there is no log yet", function()
        Ops.tail_file = function()
            return {}, "no log yet at /state/pi2/daemon.log"
        end
        local lines = Ops.log_lines(5)
        assert.same({ "no log yet at /state/pi2/daemon.log" }, lines)
    end)

    it("prefers journalctl for an installed systemd unit", function()
        Ops.service_status_sync = function()
            return { manager = "systemd", unit = { name = "pi2.service", path = "/u", installed = true } }
        end
        local argv_seen
        Ops.run_sync = function(argv)
            argv_seen = argv
            return { code = 0, stdout = "May 1 pi2 daemon listening\nMay 1 ready\n", stderr = "" }
        end
        local lines = Ops.log_lines(10)
        assert.same({ "May 1 pi2 daemon listening", "May 1 ready" }, lines)
        assert.same({ "journalctl", "--user", "-u", "pi2", "-n", "10", "--no-pager" }, argv_seen)
    end)
end)
