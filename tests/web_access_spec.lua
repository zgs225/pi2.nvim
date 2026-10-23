-- Remembered console access mode (`pi.web.access`): defaults, persisted value,
-- `web.access` override, malformed files, atomic 0600 writes and the
-- `vim.ui.select` prompt.
--
-- The state directory is redirected with `_set_base_dir` (the same test hook
-- pattern as `pi.prompt_history`), so nothing touches the real
-- `stdpath("state")`.

local Access = require("pi.web.access")
local Config = require("pi.config")

--- @return string
local function tmpdir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return dir
end

--- @param path string
--- @return integer permissions (0600 → 384)
local function perms(path)
    local stat = vim.uv.fs_stat(path)
    assert.is_truthy(stat, "missing file: " .. path)
    return stat.mode % 512
end

describe("pi.web.access", function()
    local dir
    local saved_access

    before_each(function()
        dir = tmpdir()
        Access._set_base_dir(dir)
        saved_access = Config.options.web.access
        Config.options.web.access = nil
    end)

    after_each(function()
        Access._set_base_dir(nil)
        Config.options.web.access = saved_access
    end)

    it("defaults to local with nothing remembered", function()
        assert.is_nil(Access.remembered())
        assert.equals("local", Access.get())
        assert.is_nil(Access.pinned())
    end)

    it("persists a mode atomically with private permissions", function()
        assert.equals("lan", Access.set("lan"))
        assert.equals("lan", Access.remembered())
        assert.equals("lan", Access.get())

        local path = Access.path()
        assert.equals(dir .. "/access.json", path)
        assert.equals(384, perms(path)) -- 0600
        assert.same({ access = "lan" }, vim.json.decode(table.concat(vim.fn.readfile(path), "\n")))

        -- Only the final file survives: the temp file is renamed away.
        local leftovers = vim.fn.glob(dir .. "/access.json.tmp.*", false, true)
        assert.same({}, leftovers)
    end)

    it("rejects unknown modes without writing", function()
        local mode, err = Access.set("internet")
        assert.is_nil(mode)
        assert.is_truthy(err)
        assert.equals(0, vim.fn.filereadable(Access.path()))
    end)

    it("lets web.access override the remembered value, and 'ask' falls back", function()
        Access.set("local")
        Config.options.web.access = "tailscale"
        assert.equals("tailscale", Access.pinned())
        assert.equals("tailscale", Access.get())

        Config.options.web.access = "ask"
        assert.is_nil(Access.pinned())
        assert.equals("local", Access.get())
    end)

    it("falls back to local on malformed JSON without raising", function()
        vim.fn.writefile({ "not json at all" }, Access.path())
        assert.is_nil(Access.remembered())
        assert.equals("local", Access.get())

        vim.fn.writefile({ vim.json.encode({ access = 42 }) }, Access.path())
        assert.is_nil(Access.remembered())
        assert.equals("local", Access.get())

        vim.fn.writefile({ '{"access":"lan"' }, Access.path())
        assert.equals("local", Access.get())
    end)

    it("reads without side effects (no file created)", function()
        local missing = dir .. "/nested/deeper/access.json"
        Access._set_base_dir(dir .. "/nested/deeper")
        assert.is_nil(Access.remembered())
        assert.equals(0, vim.fn.filereadable(missing))
        assert.equals("local", Access.get())
        assert.is_nil(vim.uv.fs_stat(dir .. "/nested"))
    end)

    it("choose() persists the picked mode", function()
        local real_select = vim.ui.select
        local asked = nil
        vim.ui.select = function(items, opts, callback)
            asked = items
            assert.is_truthy(opts.prompt)
            callback("tailscale")
        end
        local mode = Access.choose()
        vim.ui.select = real_select

        assert.same({ "local", "lan", "tailscale" }, asked)
        assert.equals("tailscale", mode)
        assert.equals("tailscale", Access.remembered())
    end)

    it("choose() returns nil and writes nothing when cancelled", function()
        local real_select = vim.ui.select
        vim.ui.select = function(_, _, callback)
            callback(nil)
        end
        local mode = Access.choose()
        vim.ui.select = real_select

        assert.is_nil(mode)
        assert.equals(0, vim.fn.filereadable(Access.path()))
    end)
end)
