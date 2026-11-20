-- Unit tests for the worktree retention sweep and the snapshot GC (spec:
-- worktree lock + retention, §8 items 8-15): the `max_count` / `max_age_days`
-- selection, the A5 guarantee (an unmanaged checkout is never touched), the
-- live/dirty vetoes, `dry_run`, the debounce, and `Worktree.snapshot_gc`.
--
-- No git process is spawned: `_set_runner` replaces the process layer with a
-- fake that reports a clean, in-sync checkout for every query, and the
-- fabricated repository is plain files under tempname(). Selection order is
-- driven by real directory mtimes (`uv.fs_utime`), not by the fake.

local Config = require("pi.config")
local W = require("pi.worktree")
local Retention = require("pi.worktree_retention")

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
        vim.wait(10000, function()
            return done
        end, 5),
        "timed out waiting for callback"
    )
    return pack or { n = 0 }
end

--- A temp directory whose path is already canonical.
---@return string
local function tempdir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    return vim.uv.fs_realpath(path) or path
end

--- Fake git runner that records every spawned argv.
---@param handler fun(argv: string[], opts: table): { [1]: integer?, [2]: string?, [3]: string? }
---@param calls table[]
local function install_runner(handler, calls)
    W._set_runner(function(argv, opts, cb)
        calls[#calls + 1] = { argv = vim.deepcopy(argv) }
        local res = handler(argv, opts) or {}
        cb(res[1] or 0, res[2] or "", res[3] or "")
    end)
end

---@param argv string[]
---@return string
local function joined(argv)
    return table.concat(argv, " ")
end

---@param argv string[]
---@param needle string
---@return boolean
local function has(argv, needle)
    return joined(argv):find(needle, 1, true) ~= nil
end

--- Every recorded call whose argv contains `needle`.
---@param calls table[]
---@param needle string
---@return table[]
local function all_calls(calls, needle)
    local out = {}
    for _, c in ipairs(calls) do
        if has(c.argv, needle) then
            out[#out + 1] = c
        end
    end
    return out
end

--- The last argv element (git puts the worktree path there).
---@param entry table
---@return string
local function path_arg(entry)
    return entry.argv[#entry.argv]
end

--- Fabricate a linked worktree the way git lays it out. `opts.managed = false`
--- leaves out `pi2-worktree.json`, i.e. a checkout pi2 does not own (A5).
---@param repo string
---@param name string
---@param opts? { managed?: boolean, age_seconds?: number }
---@return string wt, string git_dir
local function make_checkout(repo, name, opts)
    opts = opts or {}
    local git_dir = repo .. "/.git/worktrees/" .. name
    local wt = repo .. "/.worktrees/" .. name
    vim.fn.mkdir(git_dir, "p")
    vim.fn.mkdir(wt, "p")
    vim.fn.writefile({ "../.." }, git_dir .. "/commondir")
    vim.fn.writefile({ "gitdir: " .. git_dir }, wt .. "/.git")
    if opts.managed ~= false then
        vim.fn.writefile({
            vim.json.encode({
                version = 1,
                name = name,
                path = wt,
                repo_root = repo,
                base_sha = "base-" .. name,
                mode = "isolated",
            }),
        }, git_dir .. "/pi2-worktree.json")
    end
    if opts.age_seconds then
        local stamp = os.time() - opts.age_seconds
        vim.uv.fs_utime(wt, stamp, stamp)
    end
    return wt, git_dir
end

--- `git worktree list --porcelain` output for a repository plus linked rows.
---@param repo string
---@param rows { path: string }[]
---@return string
local function porcelain(repo, rows)
    local lines = { "worktree " .. repo, "HEAD main-sha", "branch refs/heads/main", "" }
    for _, row in ipairs(rows) do
        lines[#lines + 1] = "worktree " .. row.path
        lines[#lines + 1] = "HEAD sha-linked"
        lines[#lines + 1] = "detached"
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end

describe("worktree retention", function()
    local root
    local repo
    local calls

    before_each(function()
        W._reset()
        Retention._reset()
        Config.setup({})
        root = tempdir()
        repo = root .. "/repo"
        vim.fn.mkdir(repo .. "/.git/worktrees", "p")
        calls = {}
    end)

    after_each(function()
        Retention._reset()
        W._reset()
        Config.setup({})
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    --- Fabricate the checkouts and the porcelain listing describing them.
    ---@param specs { name: string, managed?: boolean, age_seconds?: number }[]
    ---@return table<string, string> paths, string listing
    local function build(specs)
        local paths = {}
        local rows = {}
        for _, spec in ipairs(specs) do
            local wt = make_checkout(repo, spec.name, spec)
            paths[spec.name] = wt
            rows[#rows + 1] = { path = wt }
        end
        return paths, porcelain(repo, rows)
    end

    --- A runner that reports a clean, in-sync checkout for every query.
    ---@param opts { repo: string, listing: string, dirty?: table<string, true> }
    local function install_git(opts)
        install_runner(function(argv)
            if has(argv, "rev-parse --show-toplevel") then
                return { 0, opts.repo .. "\n" }
            end
            if has(argv, "worktree list --porcelain") then
                return { 0, opts.listing }
            end
            if has(argv, "status --porcelain") then
                if opts.dirty and opts.dirty[argv[3]] then
                    return { 0, " M changed.txt\0" }
                end
                return { 0, "" }
            end
            if has(argv, "rev-parse HEAD") then
                return { 0, "head-sha\n" }
            end
            if has(argv, "rev-list --count") then
                return { 0, "0\n" }
            end
            return { 0 }
        end, calls)
    end

    it("releases the oldest checkout above max_count (and only it)", function()
        local paths, listing = build({
            { name = "wt-1", age_seconds = 3000 },
            { name = "wt-2", age_seconds = 2000 },
            { name = "wt-3", age_seconds = 1000 },
        })
        install_git({ repo = repo, listing = listing })

        local res = call(Retention.run, { cwd = repo, max_count = 2, quiet = true })
        local report, err = res[1], res[2]
        assert.is_nil(err, tostring(err))
        assert.are.same({ "wt-1" }, report.removed)
        assert.are.equal(0, #report.kept)
        assert.are.equal(0, report.foreign)

        local removes = all_calls(calls, "worktree remove")
        assert.are.equal(1, #removes)
        assert.are.same({ "git", "-C", repo, "worktree", "remove", paths["wt-1"] }, removes[1].argv)
    end)

    it("releases a checkout older than max_age_days and keeps a fresh one", function()
        local paths, listing = build({
            { name = "wt-stale", age_seconds = 20 * 86400 },
            { name = "wt-fresh", age_seconds = 60 },
        })
        install_git({ repo = repo, listing = listing })

        local res = call(Retention.run, { cwd = repo, quiet = true })
        local report = res[1]
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.same({ "wt-stale" }, report.removed)
        assert.are.equal(0, #report.kept)

        local removes = all_calls(calls, "worktree remove")
        assert.are.equal(1, #removes)
        assert.are.same({ "git", "-C", repo, "worktree", "remove", paths["wt-stale"] }, removes[1].argv)
    end)

    it("never touches an unmanaged checkout, even above the cap (A5)", function()
        local paths, listing = build({
            { name = "wt-hand", managed = false, age_seconds = 5000 },
            { name = "wt-a", age_seconds = 200 },
            { name = "wt-b", age_seconds = 400 },
        })
        install_git({ repo = repo, listing = listing })

        local res = call(Retention.run, { cwd = repo, max_count = 1, quiet = true })
        local report = res[1]
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.equal(1, report.foreign)
        assert.are.same({ "wt-b" }, report.removed)
        for _, entry in ipairs(all_calls(calls, "worktree remove")) do
            assert.are_not.equal(paths["wt-hand"], path_arg(entry), "an unmanaged checkout must never be pruned")
        end
    end)

    it("reports a candidate a live session uses as live and releases nothing", function()
        local _, listing = build({
            { name = "wt-old", age_seconds = 3000 },
            { name = "wt-new", age_seconds = 1000 },
        })
        install_git({ repo = repo, listing = listing })

        local res = call(Retention.run, {
            cwd = repo,
            max_count = 1,
            quiet = true,
            skip = function(entry)
                return entry.name == "wt-old"
            end,
        })
        local report = res[1]
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.same({ "wt-old" }, report.live)
        assert.are.equal(0, #report.removed)
        assert.are.equal(0, #all_calls(calls, "worktree remove"))
    end)

    it("keeps a dirty checkout instead of forcing it", function()
        local paths, listing = build({
            { name = "wt-dirty", age_seconds = 3000 },
            { name = "wt-clean", age_seconds = 1000 },
        })
        install_git({ repo = repo, listing = listing, dirty = { [paths["wt-dirty"]] = true } })

        local res = call(Retention.run, { cwd = repo, max_count = 1, quiet = true })
        local report = res[1]
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.same({ "wt-dirty" }, report.kept)
        assert.are.equal(0, #report.removed)
        assert.are.equal(0, #all_calls(calls, "worktree remove"))
        assert.is_not_nil(vim.uv.fs_stat(paths["wt-dirty"]))
    end)

    it("reports a dry run without releasing anything", function()
        local paths, listing = build({
            { name = "wt-old", age_seconds = 3000 },
            { name = "wt-new", age_seconds = 1000 },
        })
        install_git({ repo = repo, listing = listing })

        local res = call(Retention.run, { cwd = repo, max_count = 1, quiet = true, dry_run = true })
        local report = res[1]
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.same({ "wt-old" }, report.removed)
        assert.are.equal(0, #all_calls(calls, "worktree remove"))
        assert.is_nil(vim.uv.fs_stat(repo .. "/.git/pi2-worktree-snapshots"), "a dry run writes no snapshot")
        assert.is_not_nil(vim.uv.fs_stat(paths["wt-old"]))
    end)

    it("coalesces two schedule() calls into a single run", function()
        -- The sweep would list the repository a second time; only the prune's
        -- list call is counted here.
        Config.setup({ worktree = { retention = { sweep_locks = false } } })
        local _, listing = build({ { name = "wt-keep", age_seconds = 10 } })
        install_git({ repo = repo, listing = listing })

        local function list_calls()
            return #all_calls(calls, "worktree list --porcelain")
        end

        Retention._set_delay(10)
        Retention.schedule(repo)
        Retention.schedule(repo)

        assert.is_true(
            vim.wait(5000, function()
                return list_calls() >= 1
            end, 5),
            "the debounced run never happened"
        )
        -- Give a coalescing bug the time to fire its second run before asserting.
        vim.wait(300, function()
            return list_calls() > 1
        end, 5)
        assert.are.equal(1, list_calls())
    end)
end)

describe("worktree snapshot gc", function()
    local root
    local repo

    before_each(function()
        W._reset()
        Config.setup({})
        root = tempdir()
        repo = root .. "/repo"
        vim.fn.mkdir(repo .. "/.git", "p")
    end)

    after_each(function()
        W._reset()
        Config.setup({})
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    --- Write one snapshot patch + sidecar for `name`.
    ---@param name string
    ---@param stamp string `YYYYmmdd-HHMMSS`
    ---@param opts? { age_days?: number }
    ---@return string patch
    local function write_snapshot(name, stamp, opts)
        opts = opts or {}
        local dir = repo .. "/.git/pi2-worktree-snapshots/" .. name
        vim.fn.mkdir(dir, "p")
        local patch = dir .. "/" .. stamp .. ".patch"
        vim.fn.writefile({ "" }, patch)
        vim.fn.writefile({ "{}" }, patch .. ".json")
        if opts.age_days then
            local stamp_sec = os.time() - opts.age_days * 86400
            vim.uv.fs_utime(patch, stamp_sec, stamp_sec)
            vim.uv.fs_utime(patch .. ".json", stamp_sec, stamp_sec)
        end
        return patch
    end

    it("keeps the newest patch and deletes older patches with their sidecars", function()
        local old = write_snapshot("wt-gone", "20260101-000000")
        local new = write_snapshot("wt-gone", "20260201-000000")
        -- A directory whose name fails validate_name is skipped, never emptied.
        local unsafe = write_snapshot(".hidden", "20260101-000000")

        local res = call(W.snapshot_gc, repo, { keep_days = 30 })
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.equal(1, res[1])

        assert.is_nil(vim.uv.fs_stat(old))
        assert.is_nil(vim.uv.fs_stat(old .. ".json"))
        assert.is_not_nil(vim.uv.fs_stat(new))
        assert.is_not_nil(vim.uv.fs_stat(new .. ".json"))
        assert.is_not_nil(vim.uv.fs_stat(unsafe))
    end)

    it("keeps every patch of a checkout that still exists", function()
        local old = write_snapshot("wt-live", "20260101-000000")
        local new = write_snapshot("wt-live", "20260201-000000")

        local res = call(W.snapshot_gc, repo, { keep_days = 30, live_names = { ["wt-live"] = true } })
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.equal(0, res[1])

        assert.is_not_nil(vim.uv.fs_stat(old))
        assert.is_not_nil(vim.uv.fs_stat(old .. ".json"))
        assert.is_not_nil(vim.uv.fs_stat(new))
        assert.is_not_nil(vim.uv.fs_stat(new .. ".json"))
    end)

    it("removes the name directory once every snapshot has expired", function()
        local first = write_snapshot("wt-old", "20260101-000000", { age_days = 10 })
        local second = write_snapshot("wt-old", "20260201-000000", { age_days = 10 })

        local res = call(W.snapshot_gc, repo, { keep_days = 1 })
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.equal(2, res[1])

        assert.is_nil(vim.uv.fs_stat(first))
        assert.is_nil(vim.uv.fs_stat(second))
        assert.is_nil(vim.uv.fs_stat(first .. ".json"))
        assert.is_nil(vim.uv.fs_stat(repo .. "/.git/pi2-worktree-snapshots/wt-old"))
    end)

    it("reports zero for a repository without snapshots", function()
        local res = call(W.snapshot_gc, repo, { keep_days = 30 })
        assert.are.equal(0, res[1])
        assert.is_nil(res[2])
    end)
end)
