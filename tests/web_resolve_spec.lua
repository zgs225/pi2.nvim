-- Daemon resolution ladder for `pi.web.runtime.resolve_daemon()` and the
-- platform path helpers it shares with pi2d.
--
-- The candidate order is fixed (web.binary / web.daemon → $PI2_DAEMON_BIN →
-- PATH → plugin data → checkout) and every candidate must exist *and* be
-- executable. There is no `npx` fallback (pi2d ADR 0002). Filesystem, `exepath`
-- and the environment are injected so the specs stay hermetic (no real `pi2`,
-- no dependence on this machine's PATH or PI2_* vars).

local Runtime = require("pi.web.runtime")

--- @return string
local function tmpdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return dir
end

--- Create an executable file and return its path.
--- @param dir string
--- @param name? string
--- @return string
local function executable_file(dir, name)
    local path = dir .. "/" .. (name or "pi2")
    vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path)
    vim.uv.fs_chmod(path, 493) -- 0755
    return path
end

--- Create a non-executable file and return its path.
--- @param dir string
--- @param name? string
--- @return string
local function plain_file(dir, name)
    local path = dir .. "/" .. (name or "pi2")
    vim.fn.writefile({ "not a binary" }, path)
    vim.uv.fs_chmod(path, 420) -- 0644
    return path
end

--- `exepath` stub: bare names resolved through `map`, everything else "".
--- @param map? table<string, string>
--- @return fun(name: string): string
local function exepath(map)
    return function(name)
        return (map or {})[name] or ""
    end
end

describe("pi.web.runtime.resolve_daemon", function()
    local sandbox

    --- Resolve with hermetic defaults: no ambient environment, no real PATH, and
    --- a cwd/data root that cannot accidentally contain a candidate.
    --- @param opts pi.web.ResolveOpts
    --- @return pi.web.DaemonCandidate|nil
    local function resolve(opts)
        opts.env = opts.env or {}
        opts.exepath = opts.exepath or exepath()
        opts.cwd = opts.cwd or (sandbox .. "/missing")
        opts.data_dir = opts.data_dir or (sandbox .. "/no-data")
        return Runtime.resolve_daemon(opts)
    end

    before_each(function()
        sandbox = tmpdir()
    end)

    it("prefers web.binary (absolute path used as-is)", function()
        local bin = executable_file(sandbox)
        local resolved = resolve({ config = { binary = bin } })
        assert.same({ bin = bin, source = "config" }, resolved)
    end)

    it("resolves a bare web.binary through exepath", function()
        local bin = executable_file(sandbox, "pi2-custom")
        local resolved = resolve({
            config = { binary = "pi2-custom" },
            exepath = exepath({ ["pi2-custom"] = bin }),
        })
        assert.same({ bin = bin, source = "config" }, resolved)
    end)

    it("prefers web.binary over the deprecated web.daemon alias", function()
        local preferred = executable_file(sandbox, "pi2-new")
        local legacy = executable_file(sandbox, "pi2-legacy")
        local resolved = resolve({ config = { binary = preferred, daemon = legacy } })
        assert.same({ bin = preferred, source = "config" }, resolved)
    end)

    it("falls back to the deprecated web.daemon alias", function()
        local legacy = executable_file(sandbox, "pi2-legacy")
        local resolved = resolve({ config = { daemon = legacy } })
        assert.same({ bin = legacy, source = "config" }, resolved)
    end)

    it("falls through to PATH when web.binary is not executable", function()
        local configured = plain_file(sandbox, "stale-pi2")
        local on_path = executable_file(sandbox, "path-pi2")
        local resolved = resolve({
            config = { binary = configured },
            exepath = exepath({ pi2 = on_path }),
        })
        assert.same({ bin = on_path, source = "path" }, resolved)
    end)

    it("uses $PI2_DAEMON_BIN, winning over PATH", function()
        local exported = executable_file(sandbox, "env-pi2")
        local on_path = executable_file(sandbox, "path-pi2")
        local resolved = resolve({
            config = {},
            env = { PI2_DAEMON_BIN = exported },
            exepath = exepath({ pi2 = on_path }),
        })
        assert.same({ bin = exported, source = "env" }, resolved)
    end)

    it("loses $PI2_DAEMON_BIN to web.binary", function()
        local configured = executable_file(sandbox, "configured-pi2")
        local exported = executable_file(sandbox, "env-pi2")
        local resolved = resolve({
            config = { binary = configured },
            env = { PI2_DAEMON_BIN = exported },
        })
        assert.same({ bin = configured, source = "config" }, resolved)
    end)

    it("resolves a bare $PI2_DAEMON_BIN through exepath", function()
        local bin = executable_file(sandbox, "pi2-dev")
        local resolved = resolve({
            config = {},
            env = { PI2_DAEMON_BIN = "pi2-dev" },
            exepath = exepath({ ["pi2-dev"] = bin }),
        })
        assert.same({ bin = bin, source = "env" }, resolved)
    end)

    it("ignores an empty or unrunnable $PI2_DAEMON_BIN", function()
        local on_path = executable_file(sandbox, "path-pi2")
        local empty = resolve({
            config = {},
            env = { PI2_DAEMON_BIN = "" },
            exepath = exepath({ pi2 = on_path }),
        })
        assert.same({ bin = on_path, source = "path" }, empty)

        local unrunnable = resolve({
            config = {},
            env = { PI2_DAEMON_BIN = sandbox .. "/missing-pi2" },
            exepath = exepath({ pi2 = on_path }),
        })
        assert.same({ bin = on_path, source = "path" }, unrunnable)
    end)

    it("uses <install_dir>/node_modules/.bin/pi2 from the plugin data dir", function()
        local install_dir = sandbox .. "/data/pi2d"
        vim.fn.mkdir(install_dir .. "/node_modules/.bin", "p")
        local bin = executable_file(install_dir .. "/node_modules/.bin")
        local resolved = resolve({ config = { install_dir = install_dir } })
        assert.same({ bin = bin, source = "plugin-data" }, resolved)
    end)

    it("falls back to <stdpath('data')>/pi2d when install_dir is unset", function()
        local data_dir = sandbox .. "/data"
        vim.fn.mkdir(data_dir .. "/pi2d/node_modules/.bin", "p")
        local bin = executable_file(data_dir .. "/pi2d/node_modules/.bin")
        local resolved = resolve({ config = {}, data_dir = data_dir })
        assert.same({ bin = bin, source = "plugin-data" }, resolved)
    end)

    it("walks up from the cwd to a checkout's node_modules/.bin/pi2", function()
        local repo = sandbox .. "/repo"
        vim.fn.mkdir(repo .. "/node_modules/.bin", "p")
        local bin = executable_file(repo .. "/node_modules/.bin")
        local nested = repo .. "/packages/web/src"
        vim.fn.mkdir(nested, "p")
        local resolved = resolve({ config = {}, cwd = nested })
        assert.same({ bin = bin, source = "checkout" }, resolved)
    end)

    it("returns nil when nothing is found (no npx fallback)", function()
        local resolved = resolve({
            config = {},
            exepath = exepath({ npx = "/usr/bin/npx" }),
        })
        assert.is_nil(resolved)
    end)

    it("never throws when a probe does", function()
        local none = resolve({
            config = {},
            exepath = function()
                error("boom")
            end,
            executable = function()
                error("boom")
            end,
        })
        assert.is_nil(none)
    end)
end)

describe("pi.web.runtime.state_dir", function()
    local saved

    before_each(function()
        saved = { state = vim.env.PI2_STATE_DIR, xdg = vim.env.XDG_STATE_HOME }
    end)

    after_each(function()
        vim.env.PI2_STATE_DIR = saved.state
        vim.env.XDG_STATE_HOME = saved.xdg
    end)

    it("prefers $PI2_STATE_DIR", function()
        vim.env.PI2_STATE_DIR = "/tmp/pi2-state-override"
        assert.equals("/tmp/pi2-state-override", Runtime.state_dir())
    end)

    it("follows pi2d's platform default (daemon log directory)", function()
        vim.env.PI2_STATE_DIR = nil
        vim.env.XDG_STATE_HOME = "/tmp/xdg-state"
        local expected
        if Runtime.is_mac() then
            expected = vim.fn.expand("~") .. "/Library/Logs/pi2"
        else
            expected = "/tmp/xdg-state/pi2"
        end
        assert.equals(expected, Runtime.state_dir())
    end)
end)
