-- Integration tests for pi.worktree against a real git binary.
--
-- Every case builds a throwaway repository under tempname(), drives the public
-- async API (vim.system under the hood) with vim.wait(), and asserts on git's
-- own view (`worktree list --porcelain`, `status`, `rev-parse`) rather than on
-- the module's own bookkeeping alone. Global/system git config is neutralized so
-- a user-level excludes file cannot change the .gitignore assertions.

local Config = require("pi.config")
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

--- Run an async public API to completion, returning its packed callback args.
---
--- The callback is appended by hand: in Lua 5.1 a vararg expression that is not
--- the last item of an argument list (`fn(..., cb)`) collapses to a single value,
--- so a two-argument API would silently lose its middle argument.
---@param fn function
---@return { n: integer, [integer]: any }
local function call(fn, ...)
    local args = { n = select("#", ...), ... }
    local pack, done = nil, false
    args.n = args.n + 1
    args[args.n] = function(...)
        pack = { n = select("#", ...), ... }
        done = true
    end
    fn(unpack(args, 1, args.n))
    assert.is_true(
        vim.wait(20000, function()
            return done
        end, 5),
        "timed out waiting for callback"
    )
    return pack or { n = 0 }
end

---@param dir string
---@return string
local function head_of(dir)
    return vim.trim(git_ok({ "git", "-C", dir, "rev-parse", "HEAD" }, dir))
end

--- Create a repository with one commit and neutral local identity.
---@return string repo absolute, symlink-resolved path
local function make_repo()
    local dir = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    git_ok({ "git", "init", "-q" }, dir)
    git_ok({ "git", "config", "user.email", "pi-test@example.com" }, dir)
    git_ok({ "git", "config", "user.name", "pi test" }, dir)
    vim.fn.writefile({ "seed" }, dir .. "/seed.txt")
    git_ok({ "git", "add", "-A" }, dir)
    git_ok({ "git", "commit", "-qm", "init" }, dir)
    return dir
end

---@param repo string
---@return string[]
local function gitignore_lines(repo)
    local path = repo .. "/.gitignore"
    if not vim.uv.fs_stat(path) then
        return {}
    end
    return vim.fn.readfile(path)
end

---@param repo string
---@param name string
---@return pi.WorktreeInfo
local function create_wt(repo, name)
    local res = call(W.create, { cwd = repo, name = name })
    assert.is_nil(res[2], "create failed: " .. tostring(res[2]))
    assert.is_not_nil(res[1])
    return res[1]
end

--- Create a real repository nested inside `dir` (a nested checkout, as produced by
--- cloning a project into an untracked subdirectory).
---@param dir string
local function make_nested_repo(dir)
    vim.fn.mkdir(dir, "p")
    git_ok({ "git", "init", "-q" }, dir)
    git_ok({ "git", "config", "user.email", "nested@example.com" }, dir)
    git_ok({ "git", "config", "user.name", "nested" }, dir)
    vim.fn.writefile({ "inner" }, dir .. "/inner.txt")
    git_ok({ "git", "add", "-A" }, dir)
    git_ok({ "git", "commit", "-qm", "inner" }, dir)
end

--- Global/system git config is neutralized for the whole file so a user-level
--- excludes file cannot change the .gitignore assertions (children inherit the
--- process environment, which is why this works for `vim.system`).
local SAVED_GIT_CONFIG_GLOBAL = vim.env.GIT_CONFIG_GLOBAL
local SAVED_GIT_CONFIG_SYSTEM = vim.env.GIT_CONFIG_SYSTEM
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_SYSTEM = "/dev/null"

--- Shared fixture: temp repo + reset caches/config.
---@param extra? { files?: table<string, string>, worktreeinclude?: string, gitignore?: string }
---@return table ctx
local function setup_repo(extra)
    extra = extra or {}

    local repo = make_repo()
    if extra.gitignore then
        vim.fn.writefile(vim.split(extra.gitignore, "\n", { plain = true, trimempty = true }), repo .. "/.gitignore")
    end
    if extra.worktreeinclude then
        vim.fn.writefile(
            vim.split(extra.worktreeinclude, "\n", { plain = true, trimempty = true }),
            repo .. "/.worktreeinclude"
        )
    end
    if extra.gitignore or extra.worktreeinclude then
        git_ok({ "git", "add", "-A" }, repo)
        git_ok({ "git", "commit", "-qm", "fixtures" }, repo)
    end
    for rel, content in pairs(extra.files or {}) do
        vim.fn.mkdir(vim.fs.dirname(repo .. "/" .. rel), "p")
        vim.fn.writefile({ content }, repo .. "/" .. rel)
    end
    return { repo = repo }
end

---@param ctx table
local function teardown_repo(ctx)
    if ctx.repo then
        vim.fn.delete(ctx.repo, "rf")
    end
    vim.env.GIT_CONFIG_GLOBAL = SAVED_GIT_CONFIG_GLOBAL
    vim.env.GIT_CONFIG_SYSTEM = SAVED_GIT_CONFIG_SYSTEM
    W._reset()
    Config.setup({})
end

describe("worktree create (real git)", function()
    local ctx
    local repo

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    it("creates a detached worktree under .worktrees/<name> and ignores it", function()
        local base = head_of(repo)
        local info = create_wt(repo, "wt-real")
        local wt = repo .. "/.worktrees/wt-real"

        assert.are.equal("linked", info.kind)
        assert.are.equal("wt-real", info.name)
        assert.are.equal(wt, info.path)
        assert.are.equal(repo, info.repo_root)
        assert.are.equal(base, info.base_sha)
        assert.are.equal("isolated", info.mode)

        -- Detached HEAD: `.git` is a pointer file and no branch owns the worktree.
        local st = vim.uv.fs_stat(wt .. "/.git")
        assert.are.equal("file", st and st.type)
        assert.are.equal("HEAD", vim.trim(git_ok({ "git", "-C", wt, "rev-parse", "--abbrev-ref", "HEAD" }, wt)))
        assert.is_truthy(
            git_ok({ "git", "-C", repo, "worktree", "list", "--porcelain" }, repo):find("detached", 1, true)
        )

        -- ./.gitignore got the anchored entry, and git agrees it is ignored.
        assert.is_true(vim.tbl_contains(gitignore_lines(repo), "/.worktrees/"))
        assert.are.equal(0, (sh({ "git", "-C", repo, "check-ignore", "-q", ".worktrees/" }, repo)))

        -- Nothing about the worktree shows up as untracked in the main checkout;
        -- only the (intentionally uncommitted) .gitignore edit does.
        local status = git_ok({ "git", "-C", repo, "status", "--porcelain" }, repo)
        assert.is_nil(status:find(".worktrees", 1, true))
        assert.is_truthy(status:find(".gitignore", 1, true))
        assert.are.equal("", git_ok({ "git", "-C", repo, "diff", "--cached", "--name-only" }, repo))
    end)

    it("writes every documented metadata field into the per-worktree git dir", function()
        local base = head_of(repo)
        create_wt(repo, "wt-meta")
        local meta_path = repo .. "/.git/worktrees/wt-meta/pi2-worktree.json"
        assert.is_not_nil(vim.uv.fs_stat(meta_path))
        local raw = table.concat(vim.fn.readfile(meta_path), "\n")
        local decoded = vim.json.decode(raw)

        assert.are.equal(1, decoded.version)
        assert.are.equal("wt-meta", decoded.name)
        assert.are.equal(repo .. "/.worktrees/wt-meta", decoded.path)
        assert.are.equal(repo, decoded.repo_root)
        assert.are.equal(base, decoded.base_sha)
        assert.are.equal("isolated", decoded.mode)
        -- session binding is written as an explicit JSON null until bound
        assert.is_truthy(raw:find('"session_id":null', 1, true))
        assert.is_truthy(raw:find('"session_file":null', 1, true))

        -- No temp file left behind by the atomic write.
        assert.is_nil(vim.uv.fs_stat(meta_path .. ".tmp"))
    end)

    it("keeps .gitignore idempotent across several creations", function()
        create_wt(repo, "wt-a")
        create_wt(repo, "wt-b")
        local count = 0
        for _, line in ipairs(gitignore_lines(repo)) do
            if line == "/.worktrees/" then
                count = count + 1
            end
        end
        assert.are.equal(1, count)
    end)

    it("copies only the gitignored files matched by .worktreeinclude", function()
        teardown_repo(ctx)
        ctx = setup_repo({
            gitignore = "node_modules/\n.cache/\ndist/\n",
            worktreeinclude = "node_modules/\n.cache/\ndist/\n.env\n*.log\n",
            files = {
                ["node_modules/pkg/i.js"] = "nm",
                [".cache/x"] = "cache",
                ["dist/o.js"] = "dist",
                [".env"] = "secret", -- matched but NOT gitignored: must stay behind
                ["debug.log"] = "log", -- not ignored either
            },
        })
        repo = ctx.repo

        local info = create_wt(repo, "wt-inc")
        local wt = info.path

        assert.is_not_nil(vim.uv.fs_stat(wt .. "/node_modules/pkg/i.js"))
        assert.is_not_nil(vim.uv.fs_stat(wt .. "/.cache/x"))
        assert.is_not_nil(vim.uv.fs_stat(wt .. "/dist/o.js"))
        assert.is_nil(vim.uv.fs_stat(wt .. "/.env"))
        assert.is_nil(vim.uv.fs_stat(wt .. "/debug.log"))

        -- The copied files are ignored in the new worktree too, and the
        -- .worktrees directory itself is never nested inside a worktree.
        assert.are.equal("", git_ok({ "git", "-C", wt, "status", "--porcelain" }, wt))
        assert.is_nil(vim.uv.fs_stat(wt .. "/.worktrees"))
    end)

    it("runs setup_cmd with the worktree as cwd before reporting success", function()
        Config.setup({ worktree = { setup_cmd = { "sh", "-c", "pwd > .setup-cwd && echo ok > .setup-ok" } } })
        local info = create_wt(repo, "wt-setup")
        assert.are.equal(info.path, vim.trim(table.concat(vim.fn.readfile(info.path .. "/.setup-cwd"), "\n")))
        assert.is_not_nil(vim.uv.fs_stat(info.path .. "/.setup-ok"))
    end)

    it("keeps the worktree and returns the error when setup_cmd fails", function()
        Config.setup({ worktree = { setup_cmd = { "sh", "-c", "echo nope >&2; exit 7" } } })
        local res = call(W.create, { cwd = repo, name = "wt-setup-fail" })
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("setup_cmd failed (exit 7)", 1, true))
        assert.is_truthy(res[2]:find("nope", 1, true))
        assert.is_not_nil(vim.uv.fs_stat(repo .. "/.worktrees/wt-setup-fail"))
        assert.is_not_nil(vim.uv.fs_stat(repo .. "/.git/worktrees/wt-setup-fail/pi2-worktree.json"))
    end)

    it("reports a clear error outside a repository, without commits, and nested", function()
        local plain = vim.fn.tempname()
        vim.fn.mkdir(plain, "p")
        plain = vim.uv.fs_realpath(plain) or plain
        local not_repo = call(W.create, { cwd = plain, name = "nope" })
        assert.is_nil(not_repo[1])
        assert.is_truthy(not_repo[2]:find("not a git repository", 1, true))
        vim.fn.delete(plain, "rf")

        local empty = vim.fn.tempname()
        vim.fn.mkdir(empty, "p")
        empty = vim.uv.fs_realpath(empty) or empty
        git_ok({ "git", "init", "-q" }, empty)
        local no_commits = call(W.create, { cwd = empty, name = "nope" })
        assert.is_nil(no_commits[1])
        assert.is_truthy(no_commits[2]:find("no commits yet", 1, true))
        vim.fn.delete(empty, "rf")

        local info = create_wt(repo, "wt-outer")
        local nested = call(W.create, { cwd = info.path, name = "wt-inner" })
        assert.is_nil(nested[1])
        assert.is_truthy(nested[2]:find("already inside worktree", 1, true))
    end)

    it("rejects an unsafe name and a duplicate target", function()
        local bad = call(W.create, { cwd = repo, name = "bad name" })
        assert.is_nil(bad[1])
        assert.is_truthy(bad[2]:find("may only contain", 1, true))

        local info = create_wt(repo, "wt-dup")
        assert.is_not_nil(info)
        local dup = call(W.create, { cwd = repo, name = "wt-dup" })
        assert.is_nil(dup[1])
        assert.is_truthy(dup[2]:find("already exists", 1, true))
    end)

    it("generates unique names for back-to-back creations", function()
        local first = call(W.create, { cwd = repo })
        assert.is_nil(first[2], tostring(first[2]))
        local second = call(W.create, { cwd = repo })
        assert.is_nil(second[2], tostring(second[2]))

        assert.is_not_nil(first[1])
        assert.is_not_nil(second[1])
        assert.is_true(first[1].name ~= second[1].name, "default names collided in the same second")
        assert.is_true(first[1].path ~= second[1].path)
        assert.is_true((W.validate_name(first[1].name)), first[1].name)
        assert.is_not_nil(vim.uv.fs_stat(first[1].path))
        assert.is_not_nil(vim.uv.fs_stat(second[1].path))
    end)

    it("re-creates a registered-but-missing worktree without pruning the others", function()
        local keep = create_wt(repo, "wt-keep")
        local stale = create_wt(repo, "wt-stale")
        assert.is_true(W.bind(stale, { session_id = "sess-stale", session_file = "/tmp/sess-stale.jsonl" }))

        -- Simulate a manual delete / crash: the directory is gone while git keeps
        -- the registration (the record turns `prunable`).
        vim.fn.delete(stale.path, "rf")
        assert.is_nil(vim.uv.fs_stat(stale.path))

        local listed = call(W.list, repo)
        assert.is_nil(listed[2], tostring(listed[2]))
        local missing
        for _, entry in ipairs(listed[1]) do
            if entry.path == stale.path then
                missing = entry
            end
        end
        assert.is_not_nil(missing, "the stale registration must still be listed")
        assert.is_true(missing.missing)
        assert.is_true(missing.prunable)
        assert.are.equal("sess-stale", missing.session_id)
        assert.are.equal("/tmp/sess-stale.jsonl", missing.session_file)

        -- Creating the same name again recovers exactly that target.
        local recreated = call(W.create, { cwd = repo, name = "wt-stale" })
        assert.is_nil(recreated[2], tostring(recreated[2]))
        assert.is_not_nil(recreated[1])
        assert.are.equal(stale.path, recreated[1].path)
        assert.is_not_nil(vim.uv.fs_stat(recreated[1].path))

        -- Nothing else was pruned or removed.
        assert.is_not_nil(vim.uv.fs_stat(keep.path))
        local porcelain = git_ok({ "git", "-C", repo, "worktree", "list", "--porcelain" }, repo)
        assert.is_nil(porcelain:find("prunable", 1, true), porcelain)
        assert.is_truthy(porcelain:find("wt-keep", 1, true))
        assert.is_truthy(porcelain:find("wt-stale", 1, true))

        -- The recovered checkout is a normal (non-missing) entry again.
        for _, entry in ipairs(call(W.list, repo)[1]) do
            if entry.path == stale.path then
                assert.is_false(entry.missing)
            end
        end
    end)
end)

describe("worktree status (real git)", function()
    local ctx
    local repo
    local info

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
        info = create_wt(repo, "wt-status")
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    it("reports a clean, in-sync worktree right after creation", function()
        local res = call(W.status, info)
        assert.is_nil(res[2])
        assert.is_false(res[1].dirty)
        assert.are.equal(0, res[1].ahead)
        assert.are.equal(info.base_sha, res[1].head)
    end)

    it("reports untracked files as dirty", function()
        vim.fn.writefile({ "new" }, info.path .. "/untracked.txt")
        local res = call(W.status, info)
        assert.is_true(res[1].dirty)
        assert.are.equal(0, res[1].ahead)
    end)

    it("reports staged and unstaged edits as dirty", function()
        vim.fn.writefile({ "changed" }, info.path .. "/seed.txt")
        assert.is_true(call(W.status, info)[1].dirty)
        git_ok({ "git", "-C", info.path, "add", "seed.txt" }, info.path)
        assert.is_true(call(W.status, info)[1].dirty)
    end)

    it("counts commits made inside the worktree as ahead of the base", function()
        vim.fn.writefile({ "committed" }, info.path .. "/committed.txt")
        git_ok({ "git", "-C", info.path, "add", "-A" }, info.path)
        git_ok({ "git", "-C", info.path, "commit", "-qm", "inside" }, info.path)

        local res = call(W.status, info)
        assert.is_false(res[1].dirty)
        assert.are.equal(1, res[1].ahead)
        assert.are_not.equal(info.base_sha, res[1].head)
    end)

    it("returns an error for a missing worktree", function()
        local res = call(W.status, vim.tbl_extend("force", {}, info, { path = repo .. "/gone" }))
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("not a directory", 1, true))
    end)
end)

describe("worktree release (real git)", function()
    local ctx
    local repo
    local info

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
        info = create_wt(repo, "wt-release")
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    it("removes a clean worktree", function()
        local res = call(W.release, info)
        assert.is_true(res[1], tostring(res[2]))
        assert.is_nil(res[2])
        assert.is_nil(vim.uv.fs_stat(info.path))
        assert.is_nil(
            git_ok({ "git", "-C", repo, "worktree", "list", "--porcelain" }, repo):find("wt-release", 1, true)
        )
    end)

    it("keeps a dirty worktree", function()
        vim.fn.writefile({ "dirty" }, info.path .. "/untracked.txt")
        local res = call(W.release, info)
        assert.is_false(res[1])
        assert.is_truthy(res[2]:find("uncommitted changes", 1, true))
        assert.is_not_nil(vim.uv.fs_stat(info.path))
        -- Still registered with git, so it can be cleaned up later by hand.
        assert.is_truthy(
            git_ok({ "git", "-C", repo, "worktree", "list", "--porcelain" }, repo):find("wt-release", 1, true)
        )
    end)

    it("keeps a worktree with commits that are not in the base", function()
        vim.fn.writefile({ "x" }, info.path .. "/x.txt")
        git_ok({ "git", "-C", info.path, "add", "-A" }, info.path)
        git_ok({ "git", "-C", info.path, "commit", "-qm", "inside" }, info.path)

        local res = call(W.release, info)
        assert.is_false(res[1])
        assert.is_truthy(res[2]:find("commit(s) not in", 1, true))
        assert.is_not_nil(vim.uv.fs_stat(info.path))
        assert.is_truthy(
            git_ok({ "git", "-C", repo, "worktree", "list", "--porcelain" }, repo):find("wt-release", 1, true)
        )
    end)

    it("snapshots a clean release so the checkout stays resumable", function()
        -- Clean by construction: nothing changed since creation, so the released
        -- snapshot is an empty patch.
        local res = call(W.release, info)
        assert.is_true(res[1], tostring(res[2]))
        assert.is_nil(res[2])
        assert.is_nil(vim.uv.fs_stat(info.path))

        -- Discoverable through the snapshot store even though git pruned both the
        -- checkout and its registration.
        local snaps = W.snapshot_worktrees(repo)
        assert.are.equal(1, #snaps)
        local entry = snaps[1]
        assert.are.equal("wt-release", entry.name)
        assert.are.equal(info.path, entry.path)
        assert.are.equal(repo, entry.repo_root)
        assert.is_true(entry.missing)
        assert.is_true(entry.prunable)
        assert.are.equal(info.base_sha, entry.base_sha)
        assert.are.equal(info.base_sha, entry.head)
        assert.is_not_nil(entry.snapshot)
        assert.are.equal(0, vim.uv.fs_stat(entry.snapshot).size)

        local patch = table.concat(vim.fn.readfile(entry.snapshot), "\n")
        assert.are.equal("", patch)

        -- Recreate the same path at the snapshot's base: the empty snapshot is a
        -- no-op there and the recreated checkout matches the captured state.
        local recreated = call(W.create, { cwd = repo, name = "wt-release", base = entry.base_sha })
        assert.is_nil(recreated[2], tostring(recreated[2]))
        assert.is_not_nil(recreated[1])
        assert.are.equal(info.path, recreated[1].path)
        assert.are.equal("already", call(W.probe, entry.path, patch)[1])

        local diff = call(W.diff, recreated[1])
        assert.is_nil(diff[2], tostring(diff[2]))
        assert.are.equal("", vim.trim(diff[1]))
    end)
end)

describe("worktree snapshot and diff (real git)", function()
    local ctx
    local repo
    local info

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
        info = create_wt(repo, "wt-snap")
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    it("snapshots tracked edits and untracked files into an appliable patch", function()
        vim.fn.writefile({ "seed", "added line" }, info.path .. "/seed.txt")
        vim.fn.writefile({ "brand new" }, info.path .. "/untracked.txt")

        local res = call(W.snapshot, info)
        assert.is_nil(res[2])
        local patch = res[1]
        assert.is_not_nil(patch)
        assert.is_truthy(patch:find(repo .. "/.git/pi2-worktree-snapshots/wt-snap/", 1, true))

        local body = table.concat(vim.fn.readfile(patch), "\n")
        assert.is_truthy(body:find("diff --git a/seed.txt", 1, true))
        assert.is_truthy(body:find("untracked.txt", 1, true))

        -- The patch applies to a pristine checkout of the base commit.
        local other = vim.fn.tempname()
        git_ok({ "git", "-C", repo, "worktree", "add", "--detach", other, info.base_sha }, repo)
        local code, _, err = sh({ "git", "-C", other, "apply", "--check", patch }, other)
        assert.are.equal(0, code, err)
        sh({ "git", "-C", repo, "worktree", "remove", "--force", other }, repo)
    end)

    it("still writes an (empty) snapshot for a clean worktree", function()
        local res = call(W.snapshot, info)
        assert.is_nil(res[2])
        assert.is_not_nil(res[1])
        assert.are.equal(0, vim.uv.fs_stat(res[1]).size)
    end)

    it("returns a unified diff including untracked files", function()
        vim.fn.writefile({ "seed", "edited" }, info.path .. "/seed.txt")
        vim.fn.writefile({ "fresh" }, info.path .. "/fresh.txt")

        local res = call(W.diff, info)
        assert.is_nil(res[2])
        assert.is_truthy(res[1]:find("diff --git a/seed.txt", 1, true))
        assert.is_truthy(res[1]:find("fresh.txt", 1, true))
    end)

    it("refuses to diff without a known base commit", function()
        local res = call(W.diff, { path = info.path, git_dir = info.git_dir, repo_root = repo })
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("unknown base commit", 1, true))
    end)

    it("fails instead of dropping a nested repository from the snapshot", function()
        make_nested_repo(info.path .. "/nested")
        -- git lists the nested checkout as one untracked directory entry, which
        -- `git diff --no-index` cannot render (`exit 1`, no output).
        assert.is_truthy(
            git_ok({ "git", "-C", info.path, "ls-files", "-o", "--exclude-standard" }, info.path):find("nested")
        )

        local snapshot_res = call(W.snapshot, info)
        assert.is_nil(snapshot_res[1])
        assert.is_truthy(snapshot_res[2]:find("cannot capture untracked path", 1, true), tostring(snapshot_res[2]))
        assert.is_truthy(snapshot_res[2]:find("nested", 1, true))

        local diff_res = call(W.diff, info)
        assert.is_nil(diff_res[1], "diff must not silently omit the nested repository")
    end)

    it("fails when there are more untracked files than the cap", function()
        vim.fn.writefile({ "one" }, info.path .. "/one.txt")
        vim.fn.writefile({ "two" }, info.path .. "/two.txt")
        W._set_max_files(1)

        local res = call(W.snapshot, info)
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("cannot capture 2 untracked files", 1, true), tostring(res[2]))
        assert.is_truthy(res[2]:find("(limit 1)", 1, true))
    end)
end)

describe("worktree branch (real git)", function()
    local ctx
    local repo
    local info

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
        info = create_wt(repo, "wt-branch")
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    it("creates and attaches a new branch in the worktree", function()
        local res = call(W.branch, info, "feat-inside")
        assert.is_true(res[1], tostring(res[2]))
        assert.are.equal(
            "feat-inside",
            vim.trim(git_ok({ "git", "-C", info.path, "rev-parse", "--abbrev-ref", "HEAD" }, info.path))
        )
    end)

    it("attaches an existing branch instead of failing", function()
        git_ok({ "git", "-C", repo, "branch", "shared-branch" }, repo)
        local res = call(W.branch, info, "shared-branch")
        assert.is_true(res[1], tostring(res[2]))
        assert.are.equal(
            "shared-branch",
            vim.trim(git_ok({ "git", "-C", info.path, "rev-parse", "--abbrev-ref", "HEAD" }, info.path))
        )
    end)

    it("rejects an invalid branch name", function()
        local res = call(W.branch, info, "bad name")
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("invalid name", 1, true))
    end)
end)

describe("worktree remove (real git)", function()
    local ctx
    local repo
    local info

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
        info = create_wt(repo, "wt-remove")
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    it("snapshots before a forced removal", function()
        vim.fn.writefile({ "dirty" }, info.path .. "/untracked.txt")
        local res = call(W.remove, info, { force = true })
        assert.is_true(res[1], tostring(res[2]))
        assert.is_not_nil(res[3], "expected a snapshot path")
        assert.is_not_nil(vim.uv.fs_stat(res[3]))
        assert.is_nil(vim.uv.fs_stat(info.path))
    end)

    it("skips the snapshot when asked to", function()
        vim.fn.writefile({ "dirty" }, info.path .. "/untracked.txt")
        local res = call(W.remove, info, { force = true, snapshot = false })
        assert.is_true(res[1], tostring(res[2]))
        assert.is_nil(res[3])
        assert.is_nil(vim.uv.fs_stat(info.path))
    end)

    it("honours worktree.snapshot_before_remove = false", function()
        Config.setup({ worktree = { snapshot_before_remove = false } })
        vim.fn.writefile({ "dirty" }, info.path .. "/untracked.txt")
        local res = call(W.remove, info, { force = true })
        assert.is_true(res[1], tostring(res[2]))
        assert.is_nil(res[3])
    end)

    it("refuses to delete when the snapshot fails", function()
        vim.fn.writefile({ "dirty" }, info.path .. "/untracked.txt")
        -- An unknown base commit makes `git diff <base>` fail, so snapshotting
        -- fails and the removal must not be attempted at all.
        local broken = vim.tbl_extend("force", {}, info, { base_sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" })
        local res = call(W.remove, broken, { force = true })

        assert.is_false(res[1], "removal must be refused when the snapshot fails")
        assert.is_truthy(res[2]:find("git diff failed", 1, true), tostring(res[2]))
        assert.is_nil(res[3])
        assert.is_not_nil(vim.uv.fs_stat(info.path))
        assert.is_truthy(
            git_ok({ "git", "-C", repo, "worktree", "list", "--porcelain" }, repo):find("wt-remove", 1, true)
        )
    end)

    it("refuses to delete a worktree containing a nested repository", function()
        make_nested_repo(info.path .. "/nested")
        local res = call(W.remove, info, { force = true })

        assert.is_false(res[1], "a nested checkout must block a forced removal")
        assert.is_truthy(res[2]:find("cannot capture untracked path", 1, true), tostring(res[2]))
        assert.is_nil(res[3], "no snapshot path when the snapshot failed")
        assert.is_not_nil(vim.uv.fs_stat(info.path .. "/nested/inner.txt"))
        assert.is_truthy(
            git_ok({ "git", "-C", repo, "worktree", "list", "--porcelain" }, repo):find("wt-remove", 1, true)
        )
    end)

    it("refuses to delete when the untracked cap is exceeded", function()
        vim.fn.writefile({ "one" }, info.path .. "/one.txt")
        vim.fn.writefile({ "two" }, info.path .. "/two.txt")
        W._set_max_files(1)

        local res = call(W.remove, info, { force = true })
        assert.is_false(res[1])
        assert.is_truthy(res[2]:find("cannot capture 2 untracked files", 1, true), tostring(res[2]))
        assert.is_not_nil(vim.uv.fs_stat(info.path .. "/one.txt"))
        assert.is_not_nil(vim.uv.fs_stat(info.path .. "/two.txt"))
    end)
end)

describe("worktree detect and bind (real git)", function()
    local ctx
    local repo

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    it("detects the created worktree, the main checkout, and survives binding", function()
        local info = create_wt(repo, "wt-detect")
        vim.fn.mkdir(info.path .. "/lua", "p")

        local detected = W.detect(info.path .. "/lua")
        assert.is_not_nil(detected)
        assert.are.equal("linked", detected.kind)
        assert.are.equal("wt-detect", detected.name)
        assert.are.equal(info.path, detected.path)
        assert.are.equal(info.base_sha, detected.base_sha)

        local main = W.detect(repo)
        assert.is_not_nil(main)
        assert.are.equal("main", main.kind)
        assert.are.equal(repo, main.repo_root)

        -- detect() caches; bind() must invalidate so UI paths see the session.
        assert.is_nil(W.detect(info.path).session_id)
        assert.is_true(W.bind(detected, { session_id = "sess-real", session_file = "/tmp/sess-real.jsonl" }))
        local rebound = W.detect(info.path)
        assert.are.equal("sess-real", rebound.session_id)
        assert.are.equal("/tmp/sess-real.jsonl", rebound.session_file)

        -- Removing the worktree makes detection fall back to nil for its path.
        git_ok({ "git", "-C", repo, "worktree", "remove", "--force", info.path }, repo)
        W._reset()
        assert.is_nil(W.detect(info.path))
    end)
end)

describe("worktree patch integration (real git)", function()
    local ctx
    local repo
    local info

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
        info = create_wt(repo, "wt-patch")
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    ---@return string patch of the worktree relative to its base commit
    local function worktree_patch()
        local res = call(W.diff, info)
        assert.is_nil(res[2], tostring(res[2]))
        assert.is_true(vim.trim(res[1]) ~= "", "expected a non-empty worktree patch")
        return res[1]
    end

    it("probes clean, applies to the working tree only, then probes already", function()
        vim.fn.writefile({ "seed", "worktree line" }, info.path .. "/seed.txt")
        vim.fn.writefile({ "new file" }, info.path .. "/added.txt")
        local patch = worktree_patch()

        local probe = call(W.probe, repo, patch)
        assert.are.equal("clean", probe[1])
        assert.is_nil(probe[2])

        local applied = call(W.apply_patch, repo, patch)
        assert.is_true(applied[1], tostring(applied[2]))
        assert.is_nil(applied[2])

        assert.are.same({ "seed", "worktree line" }, vim.fn.readfile(repo .. "/seed.txt"))
        assert.are.same({ "new file" }, vim.fn.readfile(repo .. "/added.txt"))
        -- Working tree only: the index is untouched.
        assert.are.equal("", git_ok({ "git", "-C", repo, "diff", "--cached", "--name-only" }, repo))

        -- The patch is now in the tree, so only the reverse check matches.
        assert.are.equal("already", call(W.probe, repo, patch)[1])
        local again = call(W.apply_patch, repo, patch)
        assert.is_nil(again[1])
        assert.is_truthy(again[2]:find("git apply failed", 1, true), tostring(again[2]))
    end)

    it("probes conflict and writes nothing when the checkout diverged", function()
        vim.fn.writefile({ "seed", "worktree line" }, info.path .. "/seed.txt")
        local patch = worktree_patch()

        -- The same line was edited differently in the main checkout.
        vim.fn.writefile({ "seed", "main checkout line" }, repo .. "/seed.txt")

        local probe = call(W.probe, repo, patch)
        assert.are.equal("conflict", probe[1])
        assert.is_nil(probe[2])

        local applied = call(W.apply_patch, repo, patch)
        assert.is_nil(applied[1])
        assert.is_truthy(applied[2]:find("git apply failed", 1, true), tostring(applied[2]))
        -- Atomic: the user's edit and the index are untouched.
        assert.are.same({ "seed", "main checkout line" }, vim.fn.readfile(repo .. "/seed.txt"))
        assert.are.equal("", git_ok({ "git", "-C", repo, "diff", "--cached", "--name-only" }, repo))
    end)

    it("rejects a non-repository target", function()
        vim.fn.writefile({ "seed", "x" }, info.path .. "/seed.txt")
        local patch = worktree_patch()
        local plain = vim.fn.tempname()
        vim.fn.mkdir(plain, "p")
        local res = call(W.probe, plain, patch)
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("not a git repository", 1, true))
        vim.fn.delete(plain, "rf")
    end)
end)

describe("worktree create base (real git)", function()
    local ctx
    local repo

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    it("detaches at the requested base commit", function()
        local first = head_of(repo)
        vim.fn.writefile({ "second" }, repo .. "/second.txt")
        git_ok({ "git", "-C", repo, "add", "-A" }, repo)
        git_ok({ "git", "-C", repo, "commit", "-qm", "second" }, repo)
        assert.is_true(head_of(repo) ~= first)

        local res = call(W.create, { cwd = repo, name = "wt-base", base = first })
        assert.is_nil(res[2], tostring(res[2]))
        local info = res[1]

        assert.are.equal(first, info.base_sha)
        assert.are.equal(first, vim.trim(git_ok({ "git", "-C", info.path, "rev-parse", "HEAD" }, info.path)))
        assert.is_nil(vim.uv.fs_stat(info.path .. "/second.txt"))

        local status = call(W.status, info)
        assert.is_nil(status[2])
        assert.are.equal(0, status[1].ahead)
    end)

    it("rejects an unknown base commit without creating anything", function()
        local res = call(W.create, { cwd = repo, name = "wt-base-bad", base = "no-such-rev" })
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("invalid base commit", 1, true), tostring(res[2]))
        assert.is_nil(vim.uv.fs_stat(repo .. "/.worktrees/wt-base-bad"))
    end)
end)

describe("worktree snapshot sidecar (real git)", function()
    local ctx
    local repo
    local info

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
        info = create_wt(repo, "wt-snap")
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    it("writes a self-describing snapshot that survives removal", function()
        vim.fn.writefile({ "seed", "snapshot change" }, info.path .. "/seed.txt")
        vim.fn.writefile({ "untracked" }, info.path .. "/extra.txt")

        local res = call(W.snapshot, info)
        assert.is_nil(res[2], tostring(res[2]))
        local patch = res[1]
        assert.is_not_nil(patch)
        assert.is_not_nil(vim.uv.fs_stat(patch .. ".json"))

        local meta = vim.json.decode(table.concat(vim.fn.readfile(patch .. ".json"), ""))
        assert.are.equal("wt-snap", meta.name)
        assert.are.equal(info.path, meta.path)
        assert.are.equal(repo, meta.repo_root)
        assert.are.equal(info.base_sha, meta.base_sha)
        assert.are.equal(vim.trim(git_ok({ "git", "-C", info.path, "rev-parse", "HEAD" }, info.path)), meta.head)
        assert.are.equal("number", type(meta.created_at))

        local body = table.concat(vim.fn.readfile(patch), "\n")
        assert.is_truthy(body:find("seed.txt", 1, true))
        assert.is_truthy(body:find("extra.txt", 1, true))

        local latest = W.latest_snapshot(repo, "wt-snap")
        assert.is_not_nil(latest)
        assert.are.equal(patch, latest.path)
        assert.is_not_nil(latest.meta)
        assert.are.equal("wt-snap", latest.meta.name)

        -- The snapshot lives under .git: removing the checkout keeps it restorable.
        local removed = call(W.remove, info, { force = true, snapshot = false })
        assert.is_true(removed[1], tostring(removed[2]))
        assert.is_nil(vim.uv.fs_stat(info.path))

        local after = W.latest_snapshot(repo, "wt-snap")
        assert.is_not_nil(after)
        assert.are.equal(patch, after.path)
        assert.is_not_nil(after.meta)
        assert.are.equal(info.path, after.meta.path)
    end)

    it("latest_snapshot picks the newest patch", function()
        vim.fn.writefile({ "seed", "one" }, info.path .. "/seed.txt")
        local first = call(W.snapshot, info)[1]
        assert.is_not_nil(first)
        vim.uv.fs_utime(first, 0, 1000)

        vim.fn.writefile({ "seed", "two" }, info.path .. "/seed.txt")
        local second = call(W.snapshot, info)[1]
        assert.is_not_nil(second)
        assert.is_true(first ~= second)
        vim.uv.fs_utime(second, 0, 2000)

        local latest = W.latest_snapshot(repo, "wt-snap")
        assert.are.equal(second, latest.path)
    end)

    it("lists snapshot-backed worktrees after the checkout is gone", function()
        vim.fn.writefile({ "seed", "snap" }, info.path .. "/seed.txt")
        local snap = call(W.snapshot, info)[1]
        assert.is_not_nil(snap)
        local base = info.base_sha
        local head = vim.trim(git_ok({ "git", "-C", info.path, "rev-parse", "HEAD" }, info.path))

        -- A checkout that still exists must NOT be reported as restorable, even
        -- though it has a snapshot.
        local live = create_wt(repo, "wt-live")
        vim.fn.writefile({ "seed", "live" }, live.path .. "/seed.txt")
        assert.is_not_nil(call(W.snapshot, live)[1])

        -- Remove the first checkout for real: git prunes the directory and its
        -- registration (`.git/worktrees/<name>`).
        local removed = call(W.remove, info, { force = true, snapshot = false })
        assert.is_true(removed[1], tostring(removed[2]))
        assert.is_nil(vim.uv.fs_stat(info.path))

        local listed = call(W.list, repo)
        for _, entry in ipairs(listed[1]) do
            assert.is_true(entry.name ~= "wt-snap", "a pruned worktree must not be listed")
        end

        local snaps = W.snapshot_worktrees(repo)
        assert.are.equal(1, #snaps)
        local entry = snaps[1]
        assert.are.equal("wt-snap", entry.name)
        assert.are.equal(info.path, entry.path)
        assert.are.equal(repo, entry.repo_root)
        assert.are.equal("linked", entry.kind)
        assert.is_true(entry.missing)
        assert.is_true(entry.prunable)
        assert.are.equal(base, entry.base_sha)
        assert.are.equal(head, entry.head)
        assert.are.equal(snap, entry.snapshot)
    end)
end)

describe("worktree list (real git)", function()
    local ctx
    local repo

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    it("lists the repository's linked worktrees and never the main checkout", function()
        local a = create_wt(repo, "wt-a")
        local b = create_wt(repo, "wt-b")

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        local entries = res[1]
        assert.are.equal(2, #entries)

        local by_name = {}
        for _, entry in ipairs(entries) do
            by_name[entry.name] = entry
            assert.are.equal("linked", entry.kind)
            assert.are.equal(repo, entry.repo_root)
            assert.is_true(entry.detached)
            assert.are.equal(40, #entry.head) -- full sha
        end
        assert.are.equal(a.path, by_name["wt-a"].path)
        assert.are.equal(b.path, by_name["wt-b"].path)
        assert.are.equal(a.base_sha, by_name["wt-a"].base_sha)
        assert.are.equal(a.base_sha, by_name["wt-a"].head)

        -- From inside a linked worktree the same repository is listed.
        local from_wt = call(W.list, a.path)
        assert.is_nil(from_wt[2], tostring(from_wt[2]))
        assert.are.equal(2, #from_wt[1])

        -- Removing one drops it from the list.
        local removed = call(W.remove, a, { force = true, snapshot = false })
        assert.is_true(removed[1], tostring(removed[2]))
        local after = call(W.list, repo)
        assert.are.equal(1, #after[1])
        assert.are.equal("wt-b", after[1][1].name)
    end)

    it("reports an error outside a repository", function()
        local plain = vim.fn.tempname()
        vim.fn.mkdir(plain, "p")
        local res = call(W.list, plain)
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("not a git repository", 1, true))
        vim.fn.delete(plain, "rf")
    end)
end)

describe("worktree diff from (real git)", function()
    local ctx
    local repo
    local info

    before_each(function()
        W._reset()
        Config.setup({})
        ctx = setup_repo()
        repo = ctx.repo
        info = create_wt(repo, "wt-from")
    end)

    after_each(function()
        teardown_repo(ctx)
    end)

    it("honours an explicit from commit while the two-arg call keeps using base_sha", function()
        vim.fn.writefile({ "seed", "committed change" }, info.path .. "/seed.txt")
        git_ok({ "git", "-C", info.path, "add", "-A" }, info.path)
        git_ok({ "git", "-C", info.path, "commit", "-qm", "inside" }, info.path)
        local head = vim.trim(git_ok({ "git", "-C", info.path, "rev-parse", "HEAD" }, info.path))
        assert.is_true(head ~= info.base_sha)

        -- Legacy call: still base_sha, so the commit is part of the patch.
        local legacy = call(W.diff, info)
        assert.is_nil(legacy[2])
        assert.is_truthy(legacy[1]:find("diff --git a/seed.txt", 1, true))

        -- From the worktree's own HEAD nothing is left to capture.
        local pack, done = nil, false
        W.diff(info, function(diff, err)
            pack = { diff, err }
            done = true
        end, { from = head })
        assert.is_true(
            vim.wait(20000, function()
                return done
            end, 5),
            "timed out waiting for diff callback"
        )
        assert.is_nil(pack[2], tostring(pack[2]))
        assert.are.equal("", vim.trim(pack[1]))
    end)
end)
