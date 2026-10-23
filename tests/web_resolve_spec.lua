-- Daemon resolution ladder for `pi.web.runtime.resolve_daemon()`.
--
-- The candidate order is fixed (config → path → plugin-data → checkout → npx)
-- and every non-npx candidate must exist *and* be executable. Filesystem and
-- `exepath` are injected so the specs stay hermetic (no real `pi2`/`npx`
-- needed, and no dependence on this machine's PATH).

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

    before_each(function()
        sandbox = tmpdir()
    end)

    it("prefers web.daemon (absolute path used as-is)", function()
        local bin = executable_file(sandbox)
        local resolved = Runtime.resolve_daemon({
            config = { daemon = bin },
            cwd = sandbox .. "/missing",
            exepath = exepath(),
        })
        assert.same({ bin = bin, source = "config" }, resolved)
    end)

    it("resolves a bare web.daemon through exepath", function()
        local bin = executable_file(sandbox, "pi2-custom")
        local resolved = Runtime.resolve_daemon({
            config = { daemon = "pi2-custom" },
            cwd = sandbox .. "/missing",
            exepath = exepath({ ["pi2-custom"] = bin }),
        })
        assert.same({ bin = bin, source = "config" }, resolved)
    end)

    it("falls through to PATH when web.daemon is not executable", function()
        local configured = plain_file(sandbox, "stale-pi2")
        local on_path = executable_file(sandbox, "path-pi2")
        local resolved = Runtime.resolve_daemon({
            config = { daemon = configured },
            cwd = sandbox .. "/missing",
            exepath = exepath({ pi2 = on_path }),
        })
        assert.same({ bin = on_path, source = "path" }, resolved)
    end)

    it("uses <install_dir>/node_modules/.bin/pi2 from the plugin data dir", function()
        local install_dir = sandbox .. "/data/pi2d"
        vim.fn.mkdir(install_dir .. "/node_modules/.bin", "p")
        local bin = executable_file(install_dir .. "/node_modules/.bin")
        local resolved = Runtime.resolve_daemon({
            config = { install_dir = install_dir },
            cwd = sandbox .. "/missing",
            exepath = exepath(),
        })
        assert.same({ bin = bin, source = "plugin-data" }, resolved)
    end)

    it("falls back to <stdpath('data')>/pi2d when install_dir is unset", function()
        local data_dir = sandbox .. "/data"
        vim.fn.mkdir(data_dir .. "/pi2d/node_modules/.bin", "p")
        local bin = executable_file(data_dir .. "/pi2d/node_modules/.bin")
        local resolved = Runtime.resolve_daemon({
            config = {},
            data_dir = data_dir,
            cwd = sandbox .. "/missing",
            exepath = exepath(),
        })
        assert.same({ bin = bin, source = "plugin-data" }, resolved)
    end)

    it("walks up from the cwd to a checkout's node_modules/.bin/pi2", function()
        local repo = sandbox .. "/repo"
        vim.fn.mkdir(repo .. "/node_modules/.bin", "p")
        local bin = executable_file(repo .. "/node_modules/.bin")
        local nested = repo .. "/packages/web/src"
        vim.fn.mkdir(nested, "p")
        local resolved = Runtime.resolve_daemon({
            config = {},
            data_dir = sandbox .. "/no-data",
            cwd = nested,
            exepath = exepath(),
        })
        assert.same({ bin = bin, source = "checkout" }, resolved)
    end)

    it("uses npx last, only when exepath('npx') is non-empty", function()
        local resolved = Runtime.resolve_daemon({
            config = {},
            data_dir = sandbox .. "/no-data",
            cwd = sandbox .. "/missing",
            exepath = exepath({ npx = "/usr/bin/npx" }),
        })
        assert.same({ bin = "npx", source = "npx" }, resolved)

        local none = Runtime.resolve_daemon({
            config = {},
            data_dir = sandbox .. "/no-data",
            cwd = sandbox .. "/missing",
            exepath = exepath(),
        })
        assert.is_nil(none)
    end)

    it("never throws when a probe does", function()
        local none = Runtime.resolve_daemon({
            config = {},
            data_dir = sandbox .. "/no-data",
            cwd = sandbox .. "/missing",
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
