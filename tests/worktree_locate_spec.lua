-- Tests for `pi.worktree.locate`: the reverse path resolution a resume needs
-- after the checkout directory is gone.
--
-- `Worktree.detect` reads the checkout's own `.git` file, so it cannot answer
-- for a deleted checkout. `locate` resolves metadata-first instead:
--
--   1. the registry entry under `<common>/worktrees/` whose `gitdir` file points
--      at the path — authoritative, so a checkout moved with `git worktree move`
--      still resolves,
--   2. only after `git worktree prune` removed that entry, the layout join
--      `<repo>/.worktrees/<name>`.
--
-- Real-git fixtures on purpose: the registry files `locate` reads (`gitdir`,
-- `commondir`, the metadata file) are written by git itself, and the move/prune
-- cases are actual `git worktree move` / `git worktree prune` runs, not a
-- hand-built imitation of what git might have written.

local W = require("pi.worktree")

---@param argv string[]
---@param cwd string
---@return integer code, string stdout, string stderr
local function sh(argv, cwd)
    local res = vim.system(argv, { text = true, cwd = cwd }):wait()
    return res.code or -1, res.stdout or "", res.stderr or ""
end

---@param argv string[]
---@param cwd string
---@return string stdout
local function git_ok(argv, cwd)
    local code, out, err = sh(argv, cwd)
    assert.are.equal(0, code, table.concat(argv, " ") .. " failed: " .. err .. out)
    return out
end

--- Temp directory whose path is already canonical (`pi.worktree` reports real
--- paths, and on macOS `tempname()` lives under `/var/…`, a symlink).
---@return string
local function tempdir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    return vim.uv.fs_realpath(path) or path
end

--- Repository with one commit and a neutral local identity.
---@return string repo
local function make_repo()
    local dir = tempdir()
    git_ok({ "git", "init", "-q" }, dir)
    git_ok({ "git", "config", "user.email", "pi-test@example.com" }, dir)
    git_ok({ "git", "config", "user.name", "pi test" }, dir)
    vim.fn.writefile({ "seed" }, dir .. "/seed.txt")
    git_ok({ "git", "add", "-A" }, dir)
    git_ok({ "git", "commit", "-qm", "init" }, dir)
    return dir
end

--- Add a detached linked checkout through git itself.
---@param repo string
---@param rel string Path relative to the repository root
---@return string path
local function add_checkout(repo, rel)
    local path = repo .. "/" .. rel
    git_ok({ "git", "worktree", "add", "--detach", path, "HEAD" }, repo)
    return path
end

--- Write our metadata sidecar the way `M.create`/`M.bind` do.
---@param git_dir string
---@param meta table
local function write_worktree_meta(git_dir, meta)
    vim.fn.mkdir(git_dir, "p")
    vim.fn.writefile({ vim.json.encode(meta) }, git_dir .. "/pi2-worktree.json")
end

--- Global/system git config is neutralized so a user-level setting cannot change
--- what git writes into a registry dir (children inherit the process
--- environment, which is why this works for `vim.system`).
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_SYSTEM = "/dev/null"

describe("worktree locate (real git)", function()
    local root
    local repo

    before_each(function()
        W._reset()
        root = tempdir()
        repo = make_repo()
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    it("resolves an existing linked checkout to its metadata name", function()
        local path = add_checkout(repo, ".worktrees/wt-alpha")
        write_worktree_meta(repo .. "/.git/worktrees/wt-alpha", {
            version = 1,
            name = "alpha",
            path = path,
            repo_root = repo,
            base_sha = "base-sha",
            mode = "isolated",
        })

        local loc = W.locate(path)
        assert.is_not_nil(loc, "an existing managed checkout must resolve")
        assert.are.equal(repo, loc.repo_root)
        -- The metadata name wins over the registry dir name (`wt-alpha`).
        assert.are.equal("alpha", loc.name)
        assert.are.equal(path, loc.path)
        assert.are.equal(repo .. "/.git/worktrees/wt-alpha", loc.git_dir)
        assert.is_false(loc.missing)
    end)

    it("resolves a deleted checkout from its surviving registry entry", function()
        local path = add_checkout(repo, ".worktrees/wt-alpha")
        write_worktree_meta(repo .. "/.git/worktrees/wt-alpha", {
            version = 1,
            name = "alpha",
            path = path,
            repo_root = repo,
            base_sha = "base-sha",
            mode = "isolated",
            session_id = "sess-alpha",
        })
        vim.fn.delete(path, "rf")
        -- The registry entry survives a plain `rm -rf`; only `git worktree
        -- prune` (or `remove`) deletes it.
        assert.is_not_nil(vim.uv.fs_stat(repo .. "/.git/worktrees/wt-alpha/gitdir"))

        local loc = W.locate(path)
        assert.is_not_nil(loc, "a deleted checkout with a registry entry must resolve")
        assert.are.equal(repo, loc.repo_root)
        assert.are.equal("alpha", loc.name)
        assert.are.equal(path, loc.path)
        assert.are.equal(repo .. "/.git/worktrees/wt-alpha", loc.git_dir)
        assert.is_true(loc.missing)
    end)

    it("resolves a moved-then-deleted checkout through the registry, not the layout", function()
        local first = add_checkout(repo, ".worktrees/wt-alpha")
        local registry = repo .. "/.git/worktrees/wt-alpha"
        write_worktree_meta(registry, {
            version = 1,
            name = "alpha",
            path = first,
            repo_root = repo,
            base_sha = "base-sha",
            mode = "isolated",
        })
        -- `git worktree move` does NOT rename the registry dir: it rewrites the
        -- `gitdir` file inside it, so the directory name now names a checkout
        -- that no longer lives there.
        local moved = repo .. "/beta"
        git_ok({ "git", "worktree", "move", first, moved }, repo)
        assert.are.equal(moved .. "/.git", vim.trim(vim.fn.readfile(registry .. "/gitdir")[1] or ""))
        vim.fn.delete(moved, "rf")

        local loc = W.locate(moved)
        assert.is_not_nil(loc, "the registry entry is authoritative for a moved checkout")
        assert.are.equal(repo, loc.repo_root)
        assert.are.equal("alpha", loc.name, "the metadata name, not the layout leaf `beta`")
        assert.are.equal(moved, loc.path)
        assert.are.equal(registry, loc.git_dir)
        assert.is_true(loc.missing)
    end)

    it("returns nil for a path that is not a checkout of any repository", function()
        -- Outside every repository: the upward walk finds no `.git` marker.
        local outside = root .. "/plain"
        vim.fn.mkdir(outside, "p")
        assert.is_nil(W.locate(outside))

        -- Inside the repository but not in its worktree layout (the layout join
        -- is a single-segment check, not a general path pattern).
        assert.is_nil(W.locate(repo .. "/not-a-worktree"))
        -- ... and not a valid name component either.
        assert.is_nil(W.locate(repo .. "/.worktrees/nested/child"))
        assert.is_nil(W.locate(""))
    end)

    it("falls back to the layout join after git worktree prune", function()
        local path = add_checkout(repo, ".worktrees/ghost")
        write_worktree_meta(repo .. "/.git/worktrees/ghost", {
            version = 1,
            name = "ghost",
            path = path,
            repo_root = repo,
            base_sha = "base-sha",
        })
        vim.fn.delete(path, "rf")
        git_ok({ "git", "worktree", "prune" }, repo)
        assert.is_nil(vim.uv.fs_stat(repo .. "/.git/worktrees/ghost"), "prune must delete the registry entry")

        local loc = W.locate(path)
        assert.is_not_nil(loc, "the layout is the only evidence left after prune")
        assert.are.equal(repo, loc.repo_root)
        assert.are.equal("ghost", loc.name)
        assert.are.equal(path, loc.path)
        assert.is_nil(loc.git_dir, "no registry dir matched, so none is reported")
        assert.is_true(loc.missing)
    end)

    it("tolerates a trailing slash on the input path", function()
        local path = add_checkout(repo, ".worktrees/wt-alpha")
        write_worktree_meta(repo .. "/.git/worktrees/wt-alpha", {
            version = 1,
            name = "alpha",
            path = path,
            repo_root = repo,
        })

        -- `basename("/repo/beta/")` is `""`: without normalizing first, both the
        -- fast path and the reported `path` would be wrong.
        local loc = W.locate(path .. "/")
        assert.is_not_nil(loc)
        assert.are.equal("alpha", loc.name)
        assert.are.equal(path, loc.path)
        assert.are.equal(repo .. "/.git/worktrees/wt-alpha", loc.git_dir)
        assert.is_false(loc.missing)
    end)
end)
