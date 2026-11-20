-- Unit tests for pi.worktree_config — the repository-level `.pi-worktrees.toml`
-- reader (feat/worktree-isolation, issue #120 C2).
--
-- Two halves: the pure `parse`/`_validate` contract (shape, types, unknown keys,
-- platform selection) and `read`'s filesystem behaviour (missing file, stat-keyed
-- cache, warn-once on a broken file, quiet mode). No git, no subprocess.

local Config = require("pi.worktree_config")
local Notify = require("pi.notify")

---@return string
local function temp_repo()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    return vim.uv.fs_realpath(path) or path
end

---@param dir string
---@param body string
local function write_config(dir, body)
    vim.fn.writefile(vim.split(body, "\n", { plain = true }), dir .. "/.pi-worktrees.toml")
end

---@param text string
---@return pi.WorktreeRepoConfig? cfg
---@return string? err
local function parse(text)
    return Config.parse(text)
end

describe("worktree repo config (validation)", function()
    it("reads every supported key", function()
        local cfg, err = parse([==[
base_ref = "fresh"
include = [".env", "*.local"]

[setup]
unix = [["npm", "ci"], ["./scripts/setup.sh"]]

[retention]
max_count = 40
max_age_days = 30
snapshot_days = 45
]==])
        assert.is_nil(err)
        assert.are.equal("fresh", cfg.base_ref)
        assert.are.same({ ".env", "*.local" }, cfg.include)
        assert.are.same({ { "npm", "ci" }, { "./scripts/setup.sh" } }, cfg.setup)
        assert.are.same({ max_count = 40, max_age_days = 30, snapshot_days = 45 }, cfg.retention)
    end)

    it("accepts a plain command list under [setup] as the shared list", function()
        Config._set_platform("windows")
        local cfg = assert(parse('[setup]\nall = ["npm", "ci"]\n'))
        assert.are.same({ { "npm", "ci" } }, cfg.setup)
        Config._set_platform(nil)
    end)

    it("accepts a single argv command as one setup entry", function()
        local cfg = assert(parse('[setup]\nunix = ["npm", "ci"]\n'))
        assert.are.same({ { "npm", "ci" } }, cfg.setup)
    end)

    it("prefers the platform selector over the shared setup list", function()
        Config._set_platform("unix")
        local both = assert(parse([==[
[setup]
unix = [["unix-cmd"]]
windows = [["windows-cmd"]]
]==]))
        assert.are.same({ { "unix-cmd" } }, both.setup)

        Config._set_platform("windows")
        local win = assert(parse([==[
[setup]
unix = [["unix-cmd"]]
windows = [["windows-cmd"]]
]==]))
        assert.are.same({ { "windows-cmd" } }, win.setup)

        -- A single shared `setup` list applies to every platform.
        Config._set_platform(nil)
        local shared = assert(parse('[setup]\nunix = [["unix-cmd"]]\n'))
        assert.are.same({ { "unix-cmd" } }, shared.setup)
    end)

    it("falls back to nothing when no platform selector matches", function()
        Config._set_platform("windows")
        -- `base_ref` keeps the config non-empty, so the shared-setup fallback is
        -- what is under test here rather than "no settings at all".
        local cfg = assert(parse('base_ref = "head"\n[setup]\nunix = [["unix-cmd"]]\n'))
        assert.is_nil(cfg.setup)
        Config._set_platform(nil)
    end)

    it("answers (nil, nil) for an empty document", function()
        local cfg, err = parse("")
        assert.is_nil(cfg)
        assert.is_nil(err)
        local blank, blank_err = parse("   \n# nothing here\n")
        assert.is_nil(blank)
        assert.is_nil(blank_err)
    end)

    it("rejects unknown keys instead of ignoring a typo", function()
        local _, err = parse('base_reff = "fresh"\n')
        assert.is_truthy(err:find("unknown key 'base_reff'", 1, true))
        local _, rerr = parse("[retention]\nmax_countt = 3\n")
        assert.is_truthy(rerr:find("unknown retention key 'max_countt'", 1, true))
        local _, ierr = parse('[setup]\nlinux = [["x"]]\n')
        assert.is_truthy(ierr:find("unknown setup key 'linux'", 1, true))
    end)

    it("rejects wrong types and unsafe values", function()
        assert.is_truthy(select(2, parse('base_ref = ""\n')):find("base_ref must be a non-empty string", 1, true))
        assert.is_truthy(select(2, parse('include = ".env"\n')):find("include must be a non-empty array", 1, true))
        assert.is_truthy(select(2, parse("include = []\n")):find("include must be a non-empty array", 1, true))
        assert.is_truthy(select(2, parse('[setup]\nunix = [[""]]\n')):find("not a list of non-empty strings", 1, true))
        assert.is_truthy(select(2, parse("[setup]\nunix = 3\n")):find("expected an array of commands", 1, true))
        assert.is_truthy(
            select(2, parse("[retention]\nmax_count = -1\n")):find("must be a non-negative number", 1, true)
        )
        assert.is_truthy(
            select(2, parse("[retention]\nmax_count = 1.5\n")):find("max_count must be an integer", 1, true)
        )
        assert.is_truthy(
            select(2, parse('[retention]\nmax_age_days = "30"\n')):find("must be a non-negative number", 1, true)
        )
    end)

    it("reports a syntax error with its line", function()
        local _, err = parse('base_ref = "fresh\n')
        assert.is_truthy(err:find("toml: line 1:", 1, true))
    end)
end)

describe("worktree repo config (filesystem)", function()
    local dir
    local warnings ---@type string[]
    local original_warn

    before_each(function()
        Config._reset()
        dir = temp_repo()
        warnings = {}
        original_warn = Notify.warn
        Notify.warn = function(msg)
            warnings[#warnings + 1] = msg
        end
    end)

    after_each(function()
        Notify.warn = original_warn
        Config._reset()
        vim.fn.delete(dir, "rf")
    end)

    it("answers (nil, nil) when the repository has no config", function()
        local cfg, err = Config.read(dir)
        assert.is_nil(cfg)
        assert.is_nil(err)
        assert.are.equal(0, #warnings)
    end)

    it("reads the file at the repository root and exposes it through the accessors", function()
        write_config(
            dir,
            [==[
base_ref = "origin/main"
include = [".env"]

[retention]
max_age_days = 7
]==]
        )
        local cfg = assert(Config.read(dir))
        assert.are.equal(dir .. "/.pi-worktrees.toml", cfg.path)
        assert.are.equal("origin/main", Config.base_ref(dir))
        assert.are.same({ ".env" }, Config.include_patterns(dir))
        assert.are.same({ max_age_days = 7 }, Config.retention(dir))
    end)

    it("re-reads after an edit instead of serving a stale cache entry", function()
        write_config(dir, 'base_ref = "head"\n')
        assert.are.equal("head", Config.base_ref(dir))

        write_config(dir, 'base_ref = "fresh"\n')
        assert.are.equal("fresh", Config.base_ref(dir))

        vim.fn.delete(dir .. "/.pi-worktrees.toml")
        assert.is_nil(Config.base_ref(dir))
    end)

    it("warns once per broken file, not once per read, and still answers the error", function()
        write_config(dir, "base_ref = 3\n")
        local cfg, err = Config.read(dir)
        assert.is_nil(cfg)
        assert.is_truthy(err:find("base_ref must be a non-empty string", 1, true))
        assert.are.equal(1, #warnings)
        assert.is_truthy(warnings[1]:find(".pi-worktrees.toml", 1, true))

        -- Same bytes → same stamp → cached verdict, no second warning.
        Config.read(dir)
        Config.read(dir)
        assert.are.equal(1, #warnings)

        -- An edit gets one fresh warning.
        write_config(dir, "base_ref = 4\n")
        Config.read(dir)
        assert.are.equal(2, #warnings)
    end)

    it("stays silent in quiet mode (the retention sweep)", function()
        write_config(dir, "bogus = true\n")
        local cfg = Config.read(dir, { quiet = true })
        assert.is_nil(cfg)
        assert.are.equal(0, #warnings)
        -- The verdict is cached, so a later loud read does not re-report it.
        Config.read(dir)
        assert.are.equal(0, #warnings)
    end)

    it("treats an unreadable path as no config", function()
        local cfg, err = Config.read(dir .. "/does-not-exist")
        assert.is_nil(cfg)
        assert.is_nil(err)
    end)
end)
