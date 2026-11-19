-- Unit tests for pi.worktree base resolution (`Worktree.resolve_base`).
--
-- Three strategies, all driven by an injected git runner:
--   * `head`  — the commit the calling checkout has checked out,
--   * `fresh` — the repository's remote default branch, with a 24h fetch
--               throttle, a hard timeout, and two fallbacks,
--   * a revision — anything `git rev-parse <rev>^{commit}` accepts.
--
-- The real-git counterpart (a true fetch, a true `origin/HEAD`) lives in
-- tests/worktree_git_spec.lua.

local Config = require("pi.config")
local W = require("pi.worktree")

--- Run an async public API to completion, returning its packed callback args.
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

describe("worktree resolve_base", function()
    local repo ---@type string
    local cwd ---@type string
    local calls ---@type { argv: string[], opts: table }[]

    ---@param dir string
    ---@return string
    local function make_dir(dir)
        vim.fn.mkdir(dir, "p")
        return assert(vim.uv.fs_realpath(dir))
    end

    --- Install a fake git that answers from a routing table.
    ---@param handler fun(argv: string[], opts: table): table
    local function install(handler)
        calls = {}
        W._set_runner(function(argv, opts, cb)
            calls[#calls + 1] = { argv = argv, opts = opts or {} }
            local res = handler(argv, opts or {}) or {}
            cb(res[1] or 0, res[2] or "", res[3] or "")
        end)
    end

    ---@param needle string
    ---@return table?
    local function find_call(needle)
        for _, entry in ipairs(calls) do
            if table.concat(entry.argv, " "):find(needle, 1, true) then
                return entry
            end
        end
        return nil
    end

    ---@param needle string
    ---@return boolean
    local function called(needle)
        return find_call(needle) ~= nil
    end

    --- Write a FETCH_HEAD stamp `age` seconds old (the throttle signal).
    ---@param age integer
    local function stamp_fetch(age)
        local path = repo .. "/.git/FETCH_HEAD"
        vim.fn.writefile({ "stamp" }, path)
        local now = os.time()
        assert(vim.uv.fs_utime(path, now - age, now - age))
    end

    before_each(function()
        Config.setup({})
        W._reset()
        repo = make_dir(vim.fn.tempname() .. "-repo")
        cwd = make_dir(repo .. "/sub")
        vim.fn.mkdir(repo .. "/.git", "p")
    end)

    after_each(function()
        W._reset()
        Config.setup({})
        for _, dir in ipairs({ repo }) do
            pcall(vim.fn.delete, dir, "rf")
        end
    end)

    describe("head", function()
        it("resolves the commit the calling checkout has checked out", function()
            install(function(argv)
                if table.concat(argv, " "):find("HEAD^{commit}", 1, true) then
                    return { 0, "headsha\n" }
                end
                return { 128, "" }
            end)

            local res = call(W.resolve_base, { kind = "head", cwd = cwd })
            assert.is_nil(res[2], tostring(res[2]))
            assert.are.equal("headsha", res[1])
            assert.is_true(called("-C " .. cwd .. " rev-parse"), "head must be read in the calling checkout")
        end)

        it("is the default when no kind is given", function()
            install(function(argv)
                if table.concat(argv, " "):find("HEAD^{commit}", 1, true) then
                    return { 0, "headsha\n" }
                end
                return { 128, "" }
            end)

            local res = call(W.resolve_base, { cwd = cwd })
            assert.are.equal("headsha", res[1])
        end)

        it("falls back to the repository HEAD when the cwd has none", function()
            install(function(argv)
                local joined = table.concat(argv, " ")
                if joined:find("rev-parse --show-toplevel", 1, true) then
                    return { 0, repo .. "\n" }
                end
                if joined:find("HEAD^{commit}", 1, true) then
                    if joined:find("-C " .. repo .. " ", 1, true) then
                        return { 0, "reposha\n" }
                    end
                    return { 128, "" }
                end
                return { 128, "" }
            end)

            local res = call(W.resolve_base, { kind = "head", cwd = cwd })
            assert.is_nil(res[2], tostring(res[2]))
            assert.are.equal("reposha", res[1])
        end)

        it("reports an unborn repository instead of a bare git failure", function()
            install(function(argv)
                local joined = table.concat(argv, " ")
                if joined:find("rev-parse --show-toplevel", 1, true) then
                    return { 0, repo .. "\n" }
                end
                return { 128, "" }
            end)

            local res = call(W.resolve_base, { kind = "head", cwd = cwd })
            assert.is_nil(res[1])
            assert.is_truthy(res[2]:find("repository has no commits yet", 1, true), tostring(res[2]))
        end)
    end)

    describe("explicit revision", function()
        it("resolves the revision to a commit sha", function()
            install(function(argv)
                local joined = table.concat(argv, " ")
                if joined:find("rev-parse --show-toplevel", 1, true) then
                    return { 0, repo .. "\n" }
                end
                if joined:find("origin/main^{commit}", 1, true) then
                    return { 0, "revsha\n" }
                end
                return { 128, "" }
            end)

            local res = call(W.resolve_base, { kind = "origin/main", cwd = cwd })
            assert.is_nil(res[2], tostring(res[2]))
            assert.are.equal("revsha", res[1])
        end)

        it("names the revision it could not resolve", function()
            install(function(argv)
                local joined = table.concat(argv, " ")
                if joined:find("rev-parse --show-toplevel", 1, true) then
                    return { 0, repo .. "\n" }
                end
                return { 128, "" }
            end)

            local res = call(W.resolve_base, { kind = "no-such-rev", cwd = cwd })
            assert.is_nil(res[1])
            assert.are.equal("create: invalid base commit: no-such-rev", res[2])
        end)
    end)

    describe("fresh", function()
        ---@param fetch_ok boolean
        ---@param opts? { branch?: string, head?: string, origin_head?: boolean, ls_remote?: boolean }
        local function install_fresh(fetch_ok, opts)
            opts = opts or {}
            local branch = opts.branch or "main"
            local head = opts.head or "freshsha"
            local origin_head = opts.origin_head ~= false
            local ls_remote = opts.ls_remote ~= false
            install(function(argv)
                local joined = table.concat(argv, " ")
                if joined:find("rev-parse --show-toplevel", 1, true) then
                    return { 0, repo .. "\n" }
                end
                if joined:find("symbolic-ref", 1, true) then
                    if not origin_head then
                        return { 1, "" }
                    end
                    return { 0, "origin/" .. branch .. "\n" }
                end
                if joined:find("ls-remote", 1, true) then
                    if not ls_remote then
                        return { 1, "" }
                    end
                    return { 0, "ref: refs/heads/" .. branch .. "\tHEAD\n" }
                end
                if joined:find("rev-parse --git-path FETCH_HEAD", 1, true) then
                    return { 0, repo .. "/.git/FETCH_HEAD\n" }
                end
                if joined:find(" fetch ", 1, true) then
                    return { fetch_ok and 0 or 1, "" }
                end
                if joined:find("refs/remotes/origin/" .. branch .. "^{commit}", 1, true) then
                    return { 0, head .. "\n" }
                end
                if joined:find("refs/remotes/origin/HEAD^{commit}", 1, true) then
                    if not origin_head then
                        return { 128, "" }
                    end
                    return { 0, "cachedsha\n" }
                end
                if joined:find("HEAD^{commit}", 1, true) then
                    return { 0, "localsha\n" }
                end
                return { 128, "" }
            end)
        end

        it("uses the cached remote branch when the last fetch is recent", function()
            stamp_fetch(60)
            install_fresh(true)

            local res = call(W.resolve_base, { kind = "fresh", cwd = cwd })
            assert.is_nil(res[2], tostring(res[2]))
            assert.are.equal("freshsha", res[1])
            assert.is_false(called(" fetch "), "a checkout fetched a minute ago must not fetch again")
        end)

        it("fetches the default branch when the stamp is older than 24h", function()
            stamp_fetch(25 * 60 * 60)
            install_fresh(true)

            local res = call(W.resolve_base, { kind = "fresh", cwd = cwd })
            assert.is_nil(res[2], tostring(res[2]))
            assert.are.equal("freshsha", res[1])
            local fetch = assert(find_call(" fetch "), "a stale checkout must fetch")
            assert.are.equal(5000, fetch.opts.timeout, "the fetch must be capped at 5s")
        end)

        it("fetches when there is no stamp at all", function()
            install_fresh(true)
            local res = call(W.resolve_base, { kind = "fresh", cwd = cwd })
            assert.are.equal("freshsha", res[1])
            assert.is_true(called(" fetch "))
        end)

        it("falls back to the cached remote ref when the fetch fails", function()
            stamp_fetch(25 * 60 * 60)
            install_fresh(false)

            local res = call(W.resolve_base, { kind = "fresh", cwd = cwd })
            assert.is_nil(res[2], tostring(res[2]))
            assert.are.equal("freshsha", res[1])
        end)

        it("discovers the default branch with ls-remote when origin/HEAD is absent", function()
            stamp_fetch(60)
            install_fresh(true, { branch = "trunk", head = "trunksha", origin_head = false })

            local res = call(W.resolve_base, { kind = "fresh", cwd = cwd })
            assert.is_nil(res[2], tostring(res[2]))
            assert.are.equal("trunksha", res[1])
            assert.is_true(called("ls-remote --symref origin HEAD"))
        end)

        it("falls back to local HEAD when the repository has no origin", function()
            install_fresh(true, { origin_head = false, ls_remote = false })

            local res = call(W.resolve_base, { kind = "fresh", cwd = cwd })
            assert.is_nil(res[2], tostring(res[2]))
            assert.are.equal("localsha", res[1])
        end)

        it("remembers a dead remote for the rest of the session", function()
            local handler = function(argv)
                local joined = table.concat(argv, " ")
                if joined:find("rev-parse --show-toplevel", 1, true) then
                    return { 0, repo .. "\n" }
                end
                if joined:find("symbolic-ref", 1, true) then
                    return { 1, "" }
                end
                if joined:find("ls-remote", 1, true) then
                    return { 1, "" }
                end
                if joined:find("HEAD^{commit}", 1, true) then
                    return { 0, "localsha\n" }
                end
                if joined:find("refs/remotes/origin/HEAD^{commit}", 1, true) then
                    return { 128, "" }
                end
                return { 128, "" }
            end
            install(handler)

            local first = call(W.resolve_base, { kind = "fresh", cwd = cwd })
            assert.are.equal("localsha", first[1])
            assert.is_true(called("ls-remote"))

            calls = {}
            local second = call(W.resolve_base, { kind = "fresh", cwd = cwd })
            assert.are.equal("localsha", second[1])
            assert.is_false(called("ls-remote"), "a dead remote must not be probed again this session")

            -- `_reset` also drops the injected runner, so re-install it.
            W._reset()
            calls = {}
            install(handler)
            call(W.resolve_base, { kind = "fresh", cwd = cwd })
            assert.is_true(called("ls-remote"), "_reset must drop the dead-remote memo")
        end)
    end)
end)
