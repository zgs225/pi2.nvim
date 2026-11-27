-- Unit tests for `pi.worktree.list` and registered-but-gone (prunable) entries.
--
-- The contract under test: whether a prunable registration is reported is
-- decided by *metadata*, never by where the checkout used to live.
--
--   * a checkout under `<repo>/.worktrees/` without `pi2-worktree.json` is
--     somebody else's and must be dropped (A5: only touch checkouts we created),
--   * a managed checkout that `git worktree move` relocated outside
--     `.worktrees/` is still ours and must be reported, with the name stored in
--     its metadata.
--
-- No git process is spawned here: `_set_runner` fakes the porcelain output. The
-- real-git counterpart lives in tests/worktree_git_spec.lua.

local W = require("pi.worktree")

--- Run an async public API to completion, returning its packed callback args.
---
--- The callback is appended by hand: in Lua 5.1 a vararg expression that is not
--- the last item of an argument list (`fn(..., cb)`) collapses to a single value.
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
        vim.wait(5000, function()
            return done
        end, 5),
        "timed out waiting for callback"
    )
    return pack or { n = 0 }
end

--- A temp directory whose path is already canonical (pi.worktree reports real
--- paths; `tempname()` is unresolved on macOS).
---@return string
local function tempdir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    return vim.uv.fs_realpath(path) or path
end

describe("worktree list: prunable registrations", function()
    local root
    local repo

    before_each(function()
        W._reset()
        root = tempdir()
        repo = root .. "/main"
        vim.fn.mkdir(repo .. "/.git", "p")
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    --- Lay out a per-worktree git dir the way git does, optionally with our
    --- metadata file.
    ---@param name string Registry name (`<common>/worktrees/<name>`)
    ---@param meta? table Contents of `pi2-worktree.json`
    ---@param target? string Work tree path git records in the `gitdir` file
    ---@return string git_dir
    local function write_registration(name, meta, target)
        local git_dir = repo .. "/.git/worktrees/" .. name
        vim.fn.mkdir(git_dir, "p")
        vim.fn.writefile({ "../.." }, git_dir .. "/commondir")
        if target ~= nil then
            vim.fn.writefile({ target .. "/.git" }, git_dir .. "/gitdir")
        end
        if meta ~= nil then
            vim.fn.writefile({ vim.json.encode(meta) }, git_dir .. "/pi2-worktree.json")
        end
        return git_dir
    end

    --- Fake `git rev-parse` / `git worktree list` for the given linked records.
    ---@param records string[] Porcelain blocks, one per linked worktree
    local function fake_list(records)
        local porcelain = table.concat(
            vim.list_extend({
                "worktree " .. repo,
                "HEAD main-sha",
                "branch refs/heads/main",
                "",
            }, records),
            "\n"
        )
        W._set_runner(function(argv, _, cb)
            local line = table.concat(argv, " ")
            if line:find("--show-toplevel", 1, true) then
                return cb(0, repo .. "\n", "")
            end
            if line:find("worktree list --porcelain", 1, true) then
                return cb(0, porcelain, "")
            end
            return cb(0, "", "")
        end)
    end

    ---@param path string
    ---@return string
    local function prunable(path)
        return table.concat({
            "worktree " .. path,
            "HEAD sha-gone",
            "detached",
            "prunable gitdir file points to non-existent location",
            "",
        }, "\n")
    end

    it("drops a prunable checkout without metadata, even under .worktrees/", function()
        local foreign = repo .. "/.worktrees/foreign"
        write_registration("foreign", nil)
        fake_list({ prunable(foreign) })

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        local entries = res[1]
        assert.are.equal(0, #entries, "a checkout we did not create must not be reported")
    end)

    it("reports a prunable checkout with metadata wherever it points", function()
        -- `git worktree move` took this one out of `.worktrees/`; the registry
        -- still holds our metadata under its basename.
        local moved = root .. "/elsewhere/checkout-1"
        write_registration("checkout-1", {
            version = 1,
            name = "moved-name",
            path = moved,
            repo_root = repo,
            base_sha = "moved-base",
            mode = "isolated",
            session_id = "sess-moved",
            session_file = "/tmp/sess-moved.jsonl",
        })
        fake_list({ prunable(moved) })

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        local entries = res[1]
        assert.are.equal(1, #entries)
        local entry = entries[1]
        assert.is_true(entry.missing)
        assert.is_true(entry.prunable)
        assert.is_true(entry.managed)
        assert.are.equal("moved-name", entry.name)
        assert.are.equal(vim.fs.normalize(moved), entry.path)
        assert.are.equal("linked", entry.kind)
        assert.are.equal("moved-base", entry.base_sha)
        assert.are.equal("sess-moved", entry.session_id)
        assert.are.equal("/tmp/sess-moved.jsonl", entry.session_file)
    end)

    it("finds a moved-then-deleted checkout under its old registry name", function()
        -- `git worktree add .worktrees/alpha`, `git worktree move alpha beta`,
        -- then `rm -rf beta`: git does not rename the registry dir, it only
        -- rewrites `alpha/gitdir` to point at `<repo>/beta`. The basename of the
        -- recorded path (`beta`) therefore names a registry dir that either does
        -- not exist or belongs to another checkout — here a decoy that must not
        -- be mistaken for ours.
        local moved = repo .. "/beta"
        write_registration("beta", nil, repo .. "/gamma")
        write_registration("alpha", {
            version = 1,
            name = "alpha",
            path = moved,
            repo_root = repo,
            base_sha = "moved-base",
            mode = "isolated",
        }, moved)
        fake_list({ prunable(moved) })

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        local entries = res[1]
        assert.are.equal(1, #entries, "a moved-then-deleted managed checkout must be reported")
        local entry = entries[1]
        assert.is_true(entry.missing)
        assert.is_true(entry.prunable)
        assert.is_true(entry.managed)
        assert.are.equal("alpha", entry.name)
        assert.are.equal(vim.fs.normalize(moved), entry.path)
        assert.are.equal(repo .. "/.git/worktrees/alpha", entry.git_dir)
        assert.are.equal("moved-base", entry.base_sha)
    end)

    it("drops a moved-then-deleted registration without metadata", function()
        local moved = repo .. "/beta"
        write_registration("alpha", nil, moved)
        fake_list({ prunable(moved) })

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.equal(0, #res[1], "metadata, not the resolved registry dir, decides ownership")
    end)

    it("reports a gone checkout whose registry name is the path basename", function()
        local gone = repo .. "/.worktrees/plain"
        write_registration("plain", { version = 1, name = "plain", path = gone, repo_root = repo }, gone)
        fake_list({ prunable(gone) })

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        local entries = res[1]
        assert.are.equal(1, #entries, "the unmatched-name fast path must still find the registry dir")
        assert.are.equal("plain", entries[1].name)
        assert.are.equal(repo .. "/.git/worktrees/plain", entries[1].git_dir)
        assert.is_true(entries[1].managed)
        assert.is_true(entries[1].missing)
    end)

    it("does not claim a registry dir whose gitdir is missing (M4)", function()
        -- The basename fast path used to accept this directory merely because it
        -- exists. Its metadata belongs to a DIFFERENT checkout, so claiming it
        -- reports a row — and a recovery target — for a checkout we never created
        -- here, carrying the other checkout's name/base_sha/session_id.
        local claimed = repo .. "/.worktrees/decoy"
        local elsewhere = root .. "/elsewhere/other"
        -- No `gitdir` file at all: nothing proves the dir belongs to `claimed`.
        write_registration("decoy", {
            version = 1,
            name = "other-checkout",
            path = elsewhere,
            repo_root = repo,
            base_sha = "other-base",
            session_id = "sess-other",
        })
        fake_list({ prunable(claimed) })

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.equal(0, #res[1], "a registry dir with no readable gitdir is not evidence of ownership")
    end)

    it("claims a registry dir by its sidecar when no gitdir file is left (M4)", function()
        -- The `gitdir` file is git's authoritative link, but it is not the only
        -- POSITIVE evidence: a registry dir whose `gitdir` was lost (a `.git`
        -- restored from a backup that skipped it, a hand-cleaned
        -- `.git/worktrees/<name>`, `git worktree repair` on a checkout whose
        -- registration is damaged — git itself then drops the worktree from
        -- `git worktree list`) still carries OUR sidecar, which only ever names
        -- the checkout it was written for. Claiming it is what lets such a
        -- checkout be recovered at all; the test above shows the same fixture
        -- with metadata naming ANOTHER path is still rejected, so this is the
        -- sidecar-as-evidence clause, not existence.
        local gone = repo .. "/elsewhere/sidecar-only"
        write_registration("kept-name", {
            version = 1,
            name = "metadata-name",
            path = gone,
            repo_root = repo,
            base_sha = "sidecar-base",
        })
        fake_list({ prunable(gone) })

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        local entries = res[1]
        assert.are.equal(1, #entries, "our own sidecar naming exactly this path is evidence enough")
        assert.are.equal("metadata-name", entries[1].name)
        assert.are.equal(repo .. "/.git/worktrees/kept-name", entries[1].git_dir)
        assert.is_true(entries[1].managed)
        assert.is_true(entries[1].missing)
    end)

    it("does not claim a registry dir whose gitdir points at another checkout (M4)", function()
        local claimed = repo .. "/.worktrees/decoy"
        -- Existence plus a *different* recorded target: a decoy the old code also
        -- reached, and which the content scan must reject too.
        write_registration("decoy", {
            version = 1,
            name = "other-checkout",
            path = repo .. "/gamma",
            repo_root = repo,
            base_sha = "other-base",
        }, repo .. "/gamma")
        fake_list({ prunable(claimed) })

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.equal(0, #res[1], "only a gitdir that names this path may be claimed")
    end)

    it("reports the managed one and drops the foreign one in the same list", function()
        local ours = repo .. "/.worktrees/ours"
        local foreign = repo .. "/.worktrees/foreign"
        write_registration("ours", { version = 1, name = "ours", path = ours, repo_root = repo })
        write_registration("foreign", nil)
        fake_list({ prunable(ours), prunable(foreign) })

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        local entries = res[1]
        assert.are.equal(1, #entries)
        assert.are.equal("ours", entries[1].name)
        assert.is_true(entries[1].managed)
        assert.is_true(entries[1].missing)
    end)
end)
