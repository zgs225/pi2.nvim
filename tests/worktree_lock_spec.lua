-- Unit tests for the worktree lock surface (spec: worktree lock + retention,
-- §8 items 1-7): the `git worktree lock` a create takes (A1), the
-- unlock-before-remove rule and the foreign-lock refusal of the removal paths
-- (A1), and the stale-lock sweep (A2).
--
-- No git process is spawned here: `_set_runner` replaces the process layer (the
-- `install_runner` pattern of tests/worktree_spec.lua) and the fabricated
-- repository is plain files under tempname(). The lock itself is a real file
-- (`<git_dir>/locked`, exactly where git keeps it), so `lock_state` is exercised
-- through the filesystem and never through the fake runner.

local Config = require("pi.config")
local W = require("pi.worktree")

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
        vim.wait(5000, function()
            return done
        end, 5),
        "timed out waiting for callback"
    )
    return pack or { n = 0 }
end

--- A temp directory whose path is already canonical (`tempname()` is unresolved
--- on macOS while pi.worktree reports real paths).
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

--- First recorded call whose argv contains `needle`.
---@param calls table[]
---@param needle string
---@return table?
local function find_call(calls, needle)
    return all_calls(calls, needle)[1]
end

--- 1-based position of the first call containing `needle` (0 when absent).
---@param calls table[]
---@param needle string
---@return integer
local function call_index(calls, needle)
    for i, c in ipairs(calls) do
        if has(c.argv, needle) then
            return i
        end
    end
    return 0
end

--- The last argv element (git puts the worktree path there).
---@param entry table
---@return string
local function path_arg(entry)
    return entry.argv[#entry.argv]
end

--- A pid that is certainly gone: the shell printing it has already exited.
---@return integer
local function dead_pid()
    local res = vim.system({ "sh", "-c", "echo $$" }, { text = true }):wait()
    local pid = tonumber(vim.trim(res.stdout or ""))
    assert.is_truthy(pid and pid > 0, "cannot obtain a dead pid from sh")
    return pid
end

---@return string
local function our_host()
    return vim.uv.os_gethostname() or "-"
end

--- Write `<git_dir>/locked` the way git does: the raw reason, no trailing newline.
---@param git_dir string
---@param reason string
local function write_lock(git_dir, reason)
    local fd = assert(io.open(git_dir .. "/locked", "w"))
    fd:write(reason)
    fd:close()
end

--- Fabricate a linked worktree the way git lays it out:
---   <repo>/.git/worktrees/<name>/{commondir,pi2-worktree.json,locked}
---   <repo>/.worktrees/<name>/.git  ->  "gitdir: <…>/worktrees/<name>"
---@param repo string
---@param name string
---@param opts? { meta?: boolean, lock_reason?: string, dir?: boolean }
---@return string wt, string git_dir
local function make_linked(repo, name, opts)
    opts = opts or {}
    local git_dir = repo .. "/.git/worktrees/" .. name
    local wt = repo .. "/.worktrees/" .. name
    vim.fn.mkdir(git_dir, "p")
    vim.fn.writefile({ "../.." }, git_dir .. "/commondir")
    if opts.meta ~= false then
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
    if opts.lock_reason then
        write_lock(git_dir, opts.lock_reason)
    end
    if opts.dir ~= false then
        vim.fn.mkdir(wt, "p")
        vim.fn.writefile({ "gitdir: " .. git_dir }, wt .. "/.git")
    end
    return wt, git_dir
end

--- `git worktree list --porcelain` output for a repository plus linked rows.
---@param repo string
---@param rows { path: string, locked?: string, prunable?: boolean }[]
---@return string
local function porcelain(repo, rows)
    local lines = { "worktree " .. repo, "HEAD main-sha", "branch refs/heads/main", "" }
    for _, row in ipairs(rows) do
        lines[#lines + 1] = "worktree " .. row.path
        lines[#lines + 1] = "HEAD sha-linked"
        lines[#lines + 1] = "detached"
        if row.prunable then
            lines[#lines + 1] = "prunable gitdir file points to non-existent location"
        end
        if row.locked then
            lines[#lines + 1] = "locked " .. row.locked
        end
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end

-- The retention module is loaded lazily by `create` (spec §1.4); its timers must
-- never leak into another test, so reset them on both sides when it exists.
local ok_retention, Retention = pcall(require, "pi.worktree_retention")

local function reset_retention()
    if ok_retention and type(Retention) == "table" and type(Retention._reset) == "function" then
        pcall(Retention._reset)
    end
end

describe("worktree lock on create", function()
    local root
    local repo
    local calls

    before_each(function()
        W._reset()
        Config.setup({})
        reset_retention()
        root = tempdir()
        repo = root .. "/repo"
        vim.fn.mkdir(repo, "p")
        calls = {}
    end)

    after_each(function()
        W._reset()
        reset_retention()
        Config.setup({})
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    --- Install a runner that fakes a healthy repository, materializes the linked
    --- worktree the way git would, and records (or refuses) `worktree lock`.
    ---@param opts? { lock_code?: integer, lock_error?: string }
    local function install_fake_git(opts)
        opts = opts or {}
        install_runner(function(argv)
            if has(argv, "rev-parse --show-toplevel") then
                return { 0, repo .. "\n" }
            end
            if has(argv, "rev-parse --verify") then
                return { 0, "base-sha-1\n" }
            end
            if has(argv, "check-ignore") then
                return { 1 }
            end
            if has(argv, "worktree add") then
                local target = argv[#argv - 1]
                local name = target:match("([^/]+)$")
                local git_dir = repo .. "/.git/worktrees/" .. name
                vim.fn.mkdir(git_dir, "p")
                vim.fn.writefile({ "../.." }, git_dir .. "/commondir")
                vim.fn.mkdir(target, "p")
                vim.fn.writefile({ "gitdir: " .. git_dir }, target .. "/.git")
                return { 0 }
            end
            if has(argv, "worktree lock") then
                if opts.lock_code and opts.lock_code ~= 0 then
                    return { opts.lock_code, "", "fatal: " .. tostring(opts.lock_error or "cannot lock") }
                end
                -- git writes the reason into the per-worktree git dir.
                local target = argv[#argv]
                local name = target:match("([^/]+)$")
                local reason = argv[#argv - 1]
                write_lock(repo .. "/.git/worktrees/" .. name, reason)
                return { 0 }
            end
            return { 0 }
        end, calls)
    end

    it("locks a fresh checkout with our reason, and records session_id", function()
        install_fake_git()
        local expected = string.format("pi2 name=wt-1 session=- pid=0 nvim=%d host=%s", vim.fn.getpid(), our_host())
        local res = call(W.create, { cwd = repo, name = "wt-1" })
        local info, err = res[1], res[2]
        assert.is_nil(err, tostring(err))
        assert.is_not_nil(info)

        local lock_call = find_call(calls, "worktree lock")
        assert.is_not_nil(lock_call, "create must lock the checkout it made")
        assert.are.same({
            "git",
            "-C",
            repo,
            "worktree",
            "lock",
            "--reason",
            expected,
            repo .. "/.worktrees/wt-1",
        }, lock_call.argv)
        assert.is_true(
            call_index(calls, "worktree add") < call_index(calls, "worktree lock"),
            "the lock must be the first thing that happens to the new checkout"
        )
        assert.is_true(info.locked)
        assert.are.equal(expected, info.lock_reason)

        -- The reason also carries the pi session id once it is known.
        local with_session =
            string.format("pi2 name=wt-2 session=s1 pid=0 nvim=%d host=%s", vim.fn.getpid(), our_host())
        local res2 = call(W.create, { cwd = repo, name = "wt-2", session_id = "s1" })
        assert.is_nil(res2[2], tostring(res2[2]))
        local second = all_calls(calls, "worktree lock")[2]
        assert.is_not_nil(second)
        assert.are.same(
            { "git", "-C", repo, "worktree", "lock", "--reason", with_session, repo .. "/.worktrees/wt-2" },
            second.argv
        )
        assert.are.equal(with_session, res2[1].lock_reason)
    end)

    it("skips the lock when worktree.lock = false", function()
        Config.setup({ worktree = { lock = false } })
        install_fake_git()
        local res = call(W.create, { cwd = repo, name = "wt-nolock" })
        assert.is_nil(res[2], tostring(res[2]))
        assert.are.equal(0, #all_calls(calls, "worktree lock"))
        assert.is_falsy(res[1].locked)
        assert.is_nil(res[1].lock_reason)
    end)

    it("honours worktree.lock = false for a direct relock call", function()
        -- The once-per-session relock in `bind_session_worktree` calls
        -- `Worktree.lock` directly, so it never passes `create`'s short-circuit:
        -- the knob has to be honoured inside `lock` itself.
        Config.setup({ worktree = { lock = false } })
        install_fake_git()
        local wt = make_linked(repo, "wt-relock")
        local info = W.detect(wt)
        assert.is_not_nil(info)

        local res = call(W.lock, info, { session_id = "s1", pid = 4242 })
        assert.is_true(res[1])
        assert.is_nil(res[2])
        assert.are.equal(0, #all_calls(calls, "worktree lock"))
    end)

    it("fails the create and removes the checkout when the lock fails", function()
        install_fake_git({ lock_code = 128, lock_error = "cannot lock" })
        local res = call(W.create, { cwd = repo, name = "wt-fail" })
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:match("^create: "), tostring(res[2]))
        assert.is_truthy(res[2]:find("lock", 1, true), tostring(res[2]))

        local cleanup = find_call(calls, "worktree remove")
        assert.is_not_nil(cleanup, "a checkout nobody can lock must not be left behind")
        assert.are.same(
            { "git", "-C", repo, "worktree", "remove", "--force", repo .. "/.worktrees/wt-fail" },
            cleanup.argv
        )
        assert.are.equal(0, #all_calls(calls, "worktree unlock"))
    end)
end)

describe("worktree lock state", function()
    local root
    local repo
    local calls

    before_each(function()
        W._reset()
        Config.setup({})
        root = tempdir()
        repo = root .. "/repo"
        vim.fn.mkdir(repo .. "/.git/worktrees", "p")
        calls = {}
    end)

    after_each(function()
        W._reset()
        Config.setup({})
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    it("reads the lock file (ours, foreign, unlocked) without spawning git", function()
        local ours = string.format("pi2 name=wt-a session=s1 pid=0 nvim=%d host=%s", vim.fn.getpid(), our_host())
        local our_wt = make_linked(repo, "wt-a", { lock_reason = ours })
        local foreign_wt = make_linked(repo, "wt-b", { lock_reason = "hand locked by a human" })
        local open_wt = make_linked(repo, "wt-c")

        install_runner(function()
            return { 0 }
        end, calls)

        local st = W.lock_state(W.detect(our_wt))
        assert.is_true(st.locked)
        assert.is_true(st.ours)
        assert.are.equal(ours, (st.reason:gsub("%s+$", "")))

        local foreign = W.lock_state(W.detect(foreign_wt))
        assert.is_true(foreign.locked)
        assert.is_false(foreign.ours)
        assert.are.equal("hand locked by a human", (foreign.reason:gsub("%s+$", "")))

        local open = W.lock_state(W.detect(open_wt))
        assert.is_false(open.locked)
        assert.is_false(open.ours)
        assert.is_nil(open.reason)

        -- §1.2: lock state is a file read, never a `git worktree list`.
        assert.are.equal(0, #calls)
    end)
end)

describe("worktree lock on removal", function()
    local root
    local repo
    local calls

    before_each(function()
        W._reset()
        Config.setup({})
        root = tempdir()
        repo = root .. "/repo"
        vim.fn.mkdir(repo .. "/.git/worktrees", "p")
        calls = {}
    end)

    after_each(function()
        W._reset()
        Config.setup({})
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    --- A runner that reports a clean, in-sync checkout for every git query.
    local function install_clean_git()
        install_runner(function(argv)
            if has(argv, "status --porcelain") then
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

    it("unlocks our lock before removing the checkout", function()
        local reason = string.format("pi2 name=wt-1 session=- pid=0 nvim=%d host=%s", vim.fn.getpid(), our_host())
        local wt = make_linked(repo, "wt-1", { lock_reason = reason })
        local info = W.detect(wt)
        assert.is_not_nil(info)
        install_clean_git()

        local res = call(W.remove, info, { force = true, snapshot = false })
        assert.is_true(res[1], tostring(res[2]))

        local unlock = find_call(calls, "worktree unlock")
        assert.is_not_nil(unlock, "our lock must be released before the checkout goes away")
        assert.are.same({ "git", "-C", repo, "worktree", "unlock", wt }, unlock.argv)
        local remove = find_call(calls, "worktree remove")
        assert.is_not_nil(remove)
        assert.is_true(
            call_index(calls, "worktree unlock") < call_index(calls, "worktree remove"),
            "unlock must run before remove"
        )
    end)

    it("refuses to remove a foreign-locked checkout without unlocking or removing", function()
        local wt = make_linked(repo, "wt-2", { lock_reason = "someone else is working here" })
        local info = W.detect(wt)
        assert.is_not_nil(info)
        install_clean_git()

        local res = call(W.remove, info, { force = true, snapshot = false })
        assert.is_false(res[1])
        assert.is_truthy(res[2]:find("is locked", 1, true), tostring(res[2]))
        assert.is_truthy(res[2]:find("someone else is working here", 1, true), tostring(res[2]))
        assert.is_truthy(res[2]:find(wt, 1, true), tostring(res[2]))
        assert.are.equal(0, #all_calls(calls, "worktree unlock"))
        assert.are.equal(0, #all_calls(calls, "worktree remove"))
    end)

    it("removes an unlocked checkout without calling unlock", function()
        local wt = make_linked(repo, "wt-3")
        local info = W.detect(wt)
        assert.is_not_nil(info)
        install_clean_git()

        local res = call(W.remove, info, { force = true, snapshot = false })
        assert.is_true(res[1], tostring(res[2]))
        assert.are.equal(0, #all_calls(calls, "worktree unlock"))
        assert.is_not_nil(find_call(calls, "worktree remove"))
    end)

    it("refuses a lock whose owner pid is alive and is not this process", function()
        -- pid 1 is always alive and never the test process: releasing it would
        -- pull a live external session's checkout out from under it.
        local reason = string.format("pi2 name=wt-own-live session=s1 pid=1 nvim=1 host=%s", our_host())
        local wt = make_linked(repo, "wt-own-live", { lock_reason = reason })
        local info = W.detect(wt)
        assert.is_not_nil(info)
        install_clean_git()

        local res = call(W.remove, info, { force = true, snapshot = false })
        assert.is_false(res[1], "a live foreign owner must refuse the removal")
        assert.is_truthy(res[2]:find("is locked", 1, true), tostring(res[2]))
        assert.is_truthy(res[2]:find(wt, 1, true), "the error names the path: " .. tostring(res[2]))
        assert.is_truthy(res[2]:find(reason, 1, true), "the error names the reason: " .. tostring(res[2]))
        assert.is_truthy(res[2]:find("git worktree unlock", 1, true), tostring(res[2]))
        assert.are.equal(0, #all_calls(calls, "worktree unlock"))
        assert.are.equal(0, #all_calls(calls, "worktree remove"))
    end)

    it("refuses a lock that records no pid at all", function()
        -- Nothing proves the owner is gone, so the lock is kept.
        local reason = "pi2 name=wt-own-nopid session=s1"
        local wt = make_linked(repo, "wt-own-nopid", { lock_reason = reason })
        local info = W.detect(wt)
        assert.is_not_nil(info)
        install_clean_git()

        local res = call(W.remove, info, { force = true, snapshot = false })
        assert.is_false(res[1], "a lock without pids must refuse the removal")
        assert.is_truthy(res[2]:find("is locked", 1, true), tostring(res[2]))
        assert.is_truthy(res[2]:find(wt, 1, true), "the error names the path: " .. tostring(res[2]))
        assert.is_truthy(res[2]:find(reason, 1, true), "the error names the reason: " .. tostring(res[2]))
        assert.is_truthy(res[2]:find("git worktree unlock", 1, true), tostring(res[2]))
        assert.are.equal(0, #all_calls(calls, "worktree unlock"))
        assert.are.equal(0, #all_calls(calls, "worktree remove"))
    end)

    it("refuses a lock recorded on another host", function()
        -- Another machine's pid says nothing about this machine's processes.
        local reason = "pi2 name=wt-own-host session=s1 pid=1 nvim=1 host=some-other-host"
        local wt = make_linked(repo, "wt-own-host", { lock_reason = reason })
        local info = W.detect(wt)
        assert.is_not_nil(info)
        install_clean_git()

        local res = call(W.remove, info, { force = true, snapshot = false })
        assert.is_false(res[1], "a lock from another host must refuse the removal")
        assert.is_truthy(res[2]:find("is locked", 1, true), tostring(res[2]))
        assert.is_truthy(res[2]:find(wt, 1, true), "the error names the path: " .. tostring(res[2]))
        assert.is_truthy(res[2]:find(reason, 1, true), "the error names the reason: " .. tostring(res[2]))
        assert.is_truthy(res[2]:find("git worktree unlock", 1, true), tostring(res[2]))
        assert.are.equal(0, #all_calls(calls, "worktree unlock"))
        assert.are.equal(0, #all_calls(calls, "worktree remove"))
    end)

    it("keeps a foreign-locked clean checkout on release", function()
        local wt = make_linked(repo, "wt-4", { lock_reason = "hand locked" })
        local info = W.detect(wt)
        assert.is_not_nil(info)
        install_clean_git()

        local res = call(W.release, info)
        assert.is_false(res[1], "release must keep a foreign-locked checkout")
        assert.is_truthy(res[2]:find("is locked", 1, true), tostring(res[2]))
        assert.are.equal(0, #all_calls(calls, "worktree remove"))
        assert.are.equal(0, #all_calls(calls, "worktree unlock"))
        assert.is_not_nil(vim.uv.fs_stat(wt))
    end)
end)

describe("worktree lock sweep", function()
    local root
    local repo
    local calls
    local fixture

    before_each(function()
        W._reset()
        Config.setup({})
        root = tempdir()
        repo = root .. "/repo"
        vim.fn.mkdir(repo .. "/.git/worktrees", "p")
        calls = {}

        local host = our_host()
        local dead = dead_pid()
        local live = vim.fn.getpid()
        ---@param name string
        ---@param reason string
        ---@param opts? table
        local function add(name, reason, opts)
            local wt = make_linked(repo, name, vim.tbl_extend("force", { lock_reason = reason }, opts or {}))
            return { name = name, path = wt, reason = reason }
        end

        fixture = {
            repo = repo,
            dead = dead,
            live = live,
            host = host,
            with_dead_pids = add(
                "wt-stale",
                string.format("pi2 name=wt-stale session=s1 pid=%d nvim=%d host=%s", dead, dead, host)
            ),
            with_live_pid = add(
                "wt-alive",
                string.format("pi2 name=wt-alive session=s2 pid=0 nvim=%d host=%s", live, host)
            ),
            foreign = add("wt-foreign", "someone else is working here"),
            other_host = add(
                "wt-otherhost",
                string.format("pi2 name=wt-otherhost session=s3 pid=%d nvim=%d host=some-other-host", dead, dead)
            ),
            no_pid = add("wt-nopid", "pi2 name=wt-nopid session=s4"),
            missing = add(
                "wt-gone",
                string.format("pi2 name=wt-gone session=s5 pid=%d nvim=%d host=%s", dead, dead, host),
                { dir = false }
            ),
        }
        fixture.all = {
            fixture.with_dead_pids,
            fixture.with_live_pid,
            fixture.foreign,
            fixture.other_host,
            fixture.no_pid,
            fixture.missing,
        }

        local rows = {}
        for _, entry in ipairs(fixture.all) do
            rows[#rows + 1] = {
                path = entry.path,
                locked = entry.reason,
                prunable = entry == fixture.missing or nil,
            }
        end
        local listing = porcelain(repo, rows)
        install_runner(function(argv)
            if has(argv, "rev-parse --show-toplevel") then
                return { 0, repo .. "\n" }
            end
            if has(argv, "worktree list --porcelain") then
                return { 0, listing }
            end
            return { 0 }
        end, calls)
    end)

    after_each(function()
        W._reset()
        Config.setup({})
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    ---@param report pi.WorktreeSweepReport
    ---@param field string
    ---@return string[]
    local function sorted(report, field)
        local out = {}
        for _, value in ipairs(report[field]) do
            out[#out + 1] = value
        end
        return vim.fn.sort(out)
    end

    it("releases our lock when every recorded pid is gone", function()
        local res = call(W.sweep_locks, repo)
        local report, err = res[1], res[2]
        assert.is_nil(err, tostring(err))
        assert.is_not_nil(report)

        assert.are.same(vim.fn.sort({ fixture.with_dead_pids.path, fixture.missing.path }), sorted(report, "released"))
        assert.are.equal(1, report.foreign, "only the foreign reason is a foreign lock")

        -- Exactly the two stale locks are released, by path, with no other argv.
        local unlocked = {}
        for _, entry in ipairs(all_calls(calls, "worktree unlock")) do
            assert.are.equal("git", entry.argv[1])
            assert.are.equal("-C", entry.argv[2])
            assert.are.equal(repo, entry.argv[3])
            assert.are.equal("unlock", entry.argv[5])
            assert.are.equal(6, #entry.argv)
            unlocked[#unlocked + 1] = path_arg(entry)
        end
        assert.are.same(vim.fn.sort({ fixture.with_dead_pids.path, fixture.missing.path }), vim.fn.sort(unlocked))
    end)

    it("keeps a lock whose process is alive, and one that records no pid", function()
        local res = call(W.sweep_locks, repo)
        local report = res[1]
        assert.is_nil(res[2], tostring(res[2]))
        local kept = sorted(report, "kept")

        assert.is_true(vim.tbl_contains(kept, fixture.with_live_pid.path), vim.inspect(kept))
        assert.is_true(vim.tbl_contains(kept, fixture.no_pid.path), vim.inspect(kept))
        for _, entry in ipairs(all_calls(calls, "worktree unlock")) do
            assert.are_not.equal(fixture.with_live_pid.path, path_arg(entry))
            assert.are_not.equal(fixture.no_pid.path, path_arg(entry))
        end
    end)

    it("never touches a foreign reason or a lock recorded on another host", function()
        local res = call(W.sweep_locks, repo)
        local report = res[1]
        assert.is_nil(res[2], tostring(res[2]))
        local kept = sorted(report, "kept")

        assert.is_true(vim.tbl_contains(kept, fixture.foreign.path), vim.inspect(kept))
        assert.is_true(vim.tbl_contains(kept, fixture.other_host.path), vim.inspect(kept))
        for _, entry in ipairs(all_calls(calls, "worktree unlock")) do
            assert.are_not.equal(fixture.foreign.path, path_arg(entry))
            assert.are_not.equal(fixture.other_host.path, path_arg(entry))
        end
    end)

    it("unlocks a stale lock on a checkout whose directory is gone", function()
        local res = call(W.sweep_locks, repo)
        local report = res[1]
        assert.is_nil(res[2], tostring(res[2]))
        assert.is_true(vim.tbl_contains(report.released, fixture.missing.path), vim.inspect(report.released))

        local by_path = {}
        for _, entry in ipairs(all_calls(calls, "worktree unlock")) do
            by_path[path_arg(entry)] = entry
        end
        local unlock = by_path[fixture.missing.path]
        assert.is_not_nil(unlock, "a missing checkout is unlocked by path")
        assert.are.same({ "git", "-C", repo, "worktree", "unlock", fixture.missing.path }, unlock.argv)
    end)
end)

describe("worktree lock in the list surface", function()
    local root
    local repo
    local calls

    before_each(function()
        W._reset()
        Config.setup({})
        root = tempdir()
        repo = root .. "/repo"
        vim.fn.mkdir(repo .. "/.git/worktrees", "p")
        calls = {}
    end)

    after_each(function()
        W._reset()
        Config.setup({})
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    it("parses the locked reason out of porcelain", function()
        local records = W._parse_worktree_list(table.concat({
            "worktree /repo",
            "HEAD aaa",
            "branch refs/heads/main",
            "locked pi2 name=w1 session=s1 pid=0 nvim=42 host=h",
            "",
            "worktree /repo/.worktrees/w2",
            "HEAD bbb",
            "detached",
            "locked",
            "",
            "worktree /repo/.worktrees/w3",
            "HEAD ccc",
            "detached",
            "",
        }, "\n"))

        assert.are.equal(3, #records)
        assert.is_true(records[1].locked)
        assert.are.equal("pi2 name=w1 session=s1 pid=0 nvim=42 host=h", records[1].locked_reason)
        -- A bare `locked` line has no reason: locked, but nothing to parse.
        assert.is_true(records[2].locked)
        assert.is_nil(records[2].locked_reason)
        assert.is_false(records[3].locked)
        assert.is_nil(records[3].locked_reason)
    end)

    it("exposes managed/locked/locked_reason from list and detect", function()
        local reason = string.format("pi2 name=wt-a session=s1 pid=0 nvim=%d host=%s", vim.fn.getpid(), our_host())
        local wt_a = make_linked(repo, "wt-a", { lock_reason = reason })
        local wt_b = make_linked(repo, "wt-b", { meta = false })
        -- A managed registration whose directory is gone but whose lock survives.
        local gone_reason =
            string.format("pi2 name=wt-gone session=s2 pid=0 nvim=%d host=%s", vim.fn.getpid(), our_host())
        local wt_gone = make_linked(repo, "wt-gone", { lock_reason = gone_reason, dir = false })

        local listing = porcelain(repo, {
            { path = wt_a, locked = reason },
            { path = wt_b },
            { path = wt_gone, locked = gone_reason, prunable = true },
        })
        install_runner(function(argv)
            if has(argv, "rev-parse --show-toplevel") then
                return { 0, repo .. "\n" }
            end
            if has(argv, "worktree list --porcelain") then
                return { 0, listing }
            end
            return { 0 }
        end, calls)

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        local entries = res[1]
        assert.are.equal(3, #entries)

        local by_name = {}
        for _, entry in ipairs(entries) do
            by_name[entry.name] = entry
        end

        assert.is_true(by_name["wt-a"].managed)
        assert.is_true(by_name["wt-a"].locked)
        assert.are.equal(reason, by_name["wt-a"].locked_reason)

        -- No metadata: not ours to prune, and nothing locked.
        assert.is_false(by_name["wt-b"].managed)
        assert.is_false(by_name["wt-b"].locked)
        assert.is_nil(by_name["wt-b"].locked_reason)

        -- A missing registration still reports its (stale) lock.
        assert.is_true(by_name["wt-gone"].managed)
        assert.is_true(by_name["wt-gone"].locked)
        assert.are.equal(gone_reason, by_name["wt-gone"].locked_reason)

        -- detect() carries the same fields on a linked checkout.
        local info = W.detect(wt_a)
        assert.is_not_nil(info)
        assert.is_true(info.managed)
        assert.is_true(info.locked)
        assert.are.equal(reason, info.lock_reason)

        -- ... and the main checkout has neither metadata nor a lock.
        local main = W.detect(repo)
        assert.is_not_nil(main)
        assert.are.equal("main", main.kind)
        assert.is_falsy(main.managed)
        assert.is_falsy(main.locked)
        assert.is_nil(main.lock_reason)
    end)
end)
