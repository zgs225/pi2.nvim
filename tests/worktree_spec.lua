-- Unit tests for pi.worktree: name validation, .gitignore bookkeeping,
-- metadata/pointer parsing, detection over a fabricated worktree tree, binding,
-- and the create/status state machine driven by an injected runner.
--
-- No git process is spawned here: the real-git integration lives in
-- tests/worktree_git_spec.lua. `_set_runner` replaces the process layer, and the
-- fabricated trees are plain files under tempname().

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

--- Fake git runner. `handler(argv, opts)` returns { code, stdout, stderr }.
---@param handler fun(argv: string[], opts: table): { [1]: integer?, [2]: string?, [3]: string? }
---@param calls string[]?
local function install_runner(handler, calls)
    W._set_runner(function(argv, opts, cb)
        if calls then
            calls[#calls + 1] = table.concat(argv, " ")
        end
        local res = handler(argv, opts) or {}
        cb(res[1] or 0, res[2] or "", res[3] or "")
    end)
end

---@param argv string[]
---@param needle string
---@return boolean
local function has(argv, needle)
    return table.concat(argv, " "):find(needle, 1, true) ~= nil
end

---@param argv string[]
---@param needle string
---@return integer
local function index_of(argv_list, needle)
    for i, line in ipairs(argv_list) do
        if line:find(needle, 1, true) then
            return i
        end
    end
    return -1
end

--- Fabricate a repository with one linked worktree, exactly as git lays it out:
---   main/.git/worktrees/<name>/{commondir,pi2-worktree.json}
---   main/.worktrees/<name>/.git  ->  "gitdir: <…>/worktrees/<name>"
---@param root string
---@param name string
---@param meta? table
---@return string repo, string wt, string git_dir
local function make_fake_worktree(root, name, meta)
    local repo = root .. "/main"
    local git_dir = repo .. "/.git/worktrees/" .. name
    local wt = repo .. "/.worktrees/" .. name
    vim.fn.mkdir(git_dir, "p")
    vim.fn.mkdir(wt, "p")
    vim.fn.writefile({ "../.." }, git_dir .. "/commondir")
    vim.fn.writefile({ "gitdir: " .. git_dir }, wt .. "/.git")
    local payload = vim.tbl_extend("force", {
        version = 1,
        name = name,
        path = wt,
        repo_root = repo,
        base_sha = "abc123",
        mode = "isolated",
        session_id = vim.NIL,
        session_file = vim.NIL,
    }, meta or {})
    vim.fn.writefile({ vim.json.encode(payload) }, git_dir .. "/pi2-worktree.json")
    vim.fn.mkdir(repo, "p")
    return repo, wt, git_dir
end

describe("worktree names", function()
    it("accepts kebab, dotted and underscored names", function()
        for _, name in ipairs({ "feat-x", "wt-20260101-120000", "a_b.c", "x" }) do
            local ok, err = W.validate_name(name)
            assert.is_true(ok, name .. " should be valid: " .. tostring(err))
        end
    end)

    it("rejects empty, overlong, leading-dot and separator names", function()
        local cases = {
            { "", "1..64" },
            { string.rep("a", 65), "1..64" },
            { ".hidden", "must not start with '.'" },
            { "../escape", "must not start with '.'" },
            { "a/b", "may only contain" },
            { "a b", "may only contain" },
            { "a:b", "may only contain" },
            { 42, "must be a string" },
        }
        for _, case in ipairs(cases) do
            local ok, err = W.validate_name(case[1])
            assert.is_false(ok, "expected rejection for " .. vim.inspect(case[1]))
            assert.is_truthy(err:find(case[2], 1, true), err .. " should mention " .. case[2])
        end
    end)
end)

describe("worktree .gitignore line", function()
    it("appends the anchored directory line to empty content", function()
        assert.are.equal("/.worktrees/\n", W._append_gitignore_line("", "/.worktrees/"))
    end)

    it("preserves existing entries and adds a separating newline", function()
        assert.are.equal("*.log\n/.worktrees/\n", W._append_gitignore_line("*.log", "/.worktrees/"))
    end)

    it("is idempotent for every equivalent spelling", function()
        for _, body in ipairs({
            "/.worktrees/\n",
            "/.worktrees\n",
            ".worktrees/\n",
            ".worktrees\n",
            "  /.worktrees/  \n",
            "*.log\r\n/.worktrees/\r\n",
        }) do
            assert.is_nil(W._append_gitignore_line(body, "/.worktrees/"), body)
        end
    end)

    it("does not treat a commented entry as present", function()
        assert.are.equal("#/.worktrees/\n/.worktrees/\n", W._append_gitignore_line("#/.worktrees/", "/.worktrees/"))
    end)
end)

describe("worktree pointer/metadata parsing", function()
    it("parses a gitdir pointer file with or without a trailing newline", function()
        assert.are.equal("/repo/.git/worktrees/x", W._parse_gitdir_file("gitdir: /repo/.git/worktrees/x\n"))
        assert.are.equal("/repo/.git/worktrees/x", W._parse_gitdir_file("gitdir: /repo/.git/worktrees/x"))
        assert.are.equal("/repo/.git/worktrees/x", W._parse_gitdir_file("gitdir: /repo/.git/worktrees/x\r\n"))
    end)

    it("returns nil for foreign or empty content", function()
        assert.is_nil(W._parse_gitdir_file(""))
        assert.is_nil(W._parse_gitdir_file(nil))
        assert.is_nil(W._parse_gitdir_file("nothing to see"))
    end)
end)

describe("worktree .worktreeinclude patterns", function()
    it("parses one pattern per line, dropping blanks and comments", function()
        assert.are.same({ "node_modules/", ".env*" }, W._parse_include("# vendor\n\nnode_modules/\r\n  .env*  \n"))
    end)

    it("expands directory and bare patterns into git glob pathspecs", function()
        local specs = W._include_pathspecs({ "node_modules/" })
        assert.are.same({ ":(glob)node_modules", ":(glob)node_modules/**" }, specs)

        local bare = W._include_pathspecs({ "*.log" })
        assert.are.same({ ":(glob)*.log", ":(glob)*.log/**", ":(glob)**/*.log" }, bare)
    end)

    it("strips leading ./ and / and de-duplicates", function()
        local specs = W._include_pathspecs({ "./dist/", "/dist", "dist" })
        -- A bare pattern also gets the recursive form (gitignore matches at any depth).
        assert.are.same({ ":(glob)dist", ":(glob)dist/**", ":(glob)**/dist" }, specs)
        assert.are.same({ ":(glob)dist", ":(glob)dist/**" }, W._include_pathspecs({ "./dist/", "/dist/" }))
    end)

    it("ignores comments and empty patterns", function()
        assert.are.same({}, W._include_pathspecs({ "# nope", "" }))
    end)
end)

describe("worktree config", function()
    after_each(function()
        Config.setup({})
    end)

    it("ships safe defaults", function()
        Config.setup({})
        local cfg = Config.options.worktree
        assert.is_nil(cfg.setup_cmd)
        assert.is_true(cfg.snapshot_before_remove)
        -- Per-child checkouts are gone: the option no longer exists.
        assert.is_nil((cfg --[[@as table]]).isolate_subagents)
    end)

    it("merges user overrides without leaking into the defaults", function()
        Config.setup({
            worktree = {
                setup_cmd = { "make", "deps" },
                snapshot_before_remove = false,
            },
        })
        assert.are.same({ "make", "deps" }, Config.options.worktree.setup_cmd)
        assert.is_false(Config.options.worktree.snapshot_before_remove)

        Config.setup({})
        assert.is_nil(Config.options.worktree.setup_cmd)
        assert.is_true(Config.options.worktree.snapshot_before_remove)
    end)
end)

describe("worktree detect", function()
    local root

    before_each(function()
        W._reset()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    it("reports the main work tree when .git is a directory", function()
        local repo = root .. "/plain"
        vim.fn.mkdir(repo .. "/.git", "p")
        local info = W.detect(repo)
        assert.is_not_nil(info)
        assert.are.equal("main", info.kind)
        assert.are.equal(vim.uv.fs_realpath(repo), info.path)
        assert.are.equal(vim.uv.fs_realpath(repo), info.repo_root)
        assert.is_nil(info.base_sha)
    end)

    it("resolves a linked worktree from its .git pointer and metadata", function()
        local repo, wt, git_dir = make_fake_worktree(root, "wt-a")
        local info = W.detect(wt)
        assert.is_not_nil(info)
        assert.are.equal("linked", info.kind)
        assert.are.equal("wt-a", info.name)
        assert.are.equal(vim.uv.fs_realpath(wt), info.path)
        assert.are.equal(vim.uv.fs_realpath(repo), info.repo_root)
        assert.are.equal(vim.uv.fs_realpath(git_dir), info.git_dir)
        assert.are.equal("abc123", info.base_sha)
        assert.are.equal("isolated", info.mode)
        assert.is_nil(info.session_id)
    end)

    it("falls back to commondir when the metadata has no repo_root", function()
        local repo, wt = make_fake_worktree(root, "wt-b", { repo_root = vim.NIL })
        local info = W.detect(wt)
        assert.is_not_nil(info)
        assert.are.equal(vim.uv.fs_realpath(repo), info.repo_root)
    end)

    it("finds the worktree from a nested directory", function()
        local _, wt = make_fake_worktree(root, "wt-c")
        vim.fn.mkdir(wt .. "/lua/pi", "p")
        local info = W.detect(wt .. "/lua/pi")
        assert.is_not_nil(info)
        assert.are.equal("linked", info.kind)
        assert.are.equal(vim.uv.fs_realpath(wt), info.path)
    end)

    it("returns nil outside a repository and for a missing directory", function()
        local plain = root .. "/plain"
        vim.fn.mkdir(plain, "p")
        assert.is_nil(W.detect(plain))
        assert.is_nil(W.detect(root .. "/does-not-exist"))
    end)

    it("never runs git", function()
        make_fake_worktree(root, "wt-d")
        W._set_runner(function()
            error("detect must not spawn a process")
        end)
        local info = W.detect(root .. "/main/.worktrees/wt-d")
        assert.is_not_nil(info)
    end)

    it("revalidates the cache when the metadata changes on disk", function()
        local _, wt, git_dir = make_fake_worktree(root, "wt-e")
        assert.are.equal("abc123", W.detect(wt).base_sha)

        vim.fn.writefile({
            vim.json.encode({ version = 1, name = "wt-e", base_sha = "def456789", mode = "isolated" }),
        }, git_dir .. "/pi2-worktree.json")

        assert.are.equal("def456789", W.detect(wt).base_sha)
    end)
end)

describe("worktree bind", function()
    local root

    before_each(function()
        W._reset()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    it("writes session fields atomically and refreshes detect", function()
        local _, wt, git_dir = make_fake_worktree(root, "wt-f")
        local info = W.detect(wt)
        assert.is_nil(info.session_id)

        local ok, err = W.bind(info, { session_id = "sess-1", session_file = "/tmp/sess-1.jsonl" })
        assert.is_true(ok, tostring(err))
        assert.is_nil(vim.uv.fs_stat(W._meta_path(info) .. ".tmp"))

        local fresh = W.detect(wt)
        assert.are.equal("sess-1", fresh.session_id)
        assert.are.equal("/tmp/sess-1.jsonl", fresh.session_file)

        local decoded = vim.json.decode(table.concat(vim.fn.readfile(git_dir .. "/pi2-worktree.json"), "\n"))
        assert.are.equal(1, decoded.version)
        assert.are.equal("wt-f", decoded.name)
        assert.are.equal("sess-1", decoded.session_id)
    end)

    it("keeps untouched fields and rejects an invalid info table", function()
        local _, wt = make_fake_worktree(root, "wt-g", { session_id = "keep-me" })
        local info = W.detect(wt)
        local ok = W.bind(info, { session_file = "/tmp/x.jsonl" })
        assert.is_true(ok)
        local fresh = W.detect(wt)
        assert.are.equal("keep-me", fresh.session_id)
        assert.are.equal("/tmp/x.jsonl", fresh.session_file)

        local bad_ok, bad_err = W.bind({ path = root .. "/nope" }, {})
        assert.is_false(bad_ok)
        assert.is_truthy(bad_err)
    end)
end)

describe("worktree create (injected runner)", function()
    local root
    local repo
    local calls
    local setup_cwd
    local setup_code
    local setup_stderr

    before_each(function()
        W._reset()
        Config.setup({})
        root = vim.fn.tempname()
        repo = root .. "/repo"
        vim.fn.mkdir(repo, "p")
        calls = {}
        setup_cwd = nil
        setup_code, setup_stderr = nil, nil
    end)

    after_each(function()
        W._reset()
        Config.setup({})
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    --- Install a runner that fakes a healthy repository and materializes the
    --- linked worktree the way git would.
    ---@param opts? { add_code?: integer, add_error?: table, stale_once?: boolean, include_files?: string[], base_sha?: string, base_ok?: boolean }
    local function install_fake_git(opts)
        opts = opts or {}
        install_runner(function(argv, run_opts)
            if has(argv, "rev-parse --show-toplevel") then
                return { 0, repo .. "\n" }
            end
            if has(argv, "rev-parse --verify") then
                if opts.base_ok == false then
                    return { 128, "", "fatal: bad revision" }
                end
                return { 0, (opts.base_sha or "base-sha-1") .. "\n" }
            end
            if has(argv, "check-ignore") then
                return { 1 }
            end
            if has(argv, "worktree add") then
                local target = argv[#argv - 1]
                if opts.add_error then
                    return { opts.add_error[1], "", opts.add_error[2] }
                end
                if opts.stale_once and not has(argv, "--force") then
                    return {
                        128,
                        "",
                        "fatal: '" .. target .. "' is a missing but already registered worktree;",
                    }
                end
                if opts.add_code and opts.add_code ~= 0 then
                    return { opts.add_code, "", "fatal: boom" }
                end
                local name = target:match("([^/]+)$")
                local git_dir = repo .. "/.git/worktrees/" .. name
                vim.fn.mkdir(git_dir, "p")
                vim.fn.mkdir(target, "p")
                vim.fn.writefile({ "gitdir: " .. git_dir }, target .. "/.git")
                return { 0 }
            end
            if has(argv, "ls-files") then
                local files = opts.include_files or {}
                if #files == 0 then
                    return { 0, "" }
                end
                return { 0, table.concat(files, "\0") .. "\0" }
            end
            if argv[1] == "fake-setup" then
                setup_cwd = run_opts and run_opts.cwd or nil
                return { setup_code or 0, "", setup_stderr or "" }
            end
            return { 0 }
        end, calls)
    end

    it("creates the worktree, ignores it, and writes metadata", function()
        install_fake_git()
        local res = call(W.create, { cwd = repo, name = "wt-1" })
        local info, err = res[1], res[2]
        assert.is_nil(err)
        assert.is_not_nil(info)
        assert.are.equal("linked", info.kind)
        assert.are.equal("wt-1", info.name)
        assert.are.equal(repo .. "/.worktrees/wt-1", info.path)
        assert.are.equal("base-sha-1", info.base_sha)
        assert.are.equal("isolated", info.mode)

        assert.are.equal("/.worktrees/\n", table.concat(vim.fn.readfile(repo .. "/.gitignore"), "\n") .. "\n")

        local meta =
            vim.json.decode(table.concat(vim.fn.readfile(repo .. "/.git/worktrees/wt-1/pi2-worktree.json"), ""))
        assert.are.equal(1, meta.version)
        assert.are.equal("wt-1", meta.name)
        assert.are.equal(repo .. "/.worktrees/wt-1", meta.path)
        assert.are.equal(repo, meta.repo_root)
        assert.are.equal("base-sha-1", meta.base_sha)
        assert.are.equal("isolated", meta.mode)
        assert.is_truthy(
            table
                .concat(vim.fn.readfile(repo .. "/.git/worktrees/wt-1/pi2-worktree.json"), "")
                :find('"session_id":null', 1, true)
        )

        -- Ordered steps: gitignore before `worktree add`, and a detached checkout.
        assert.is_true(index_of(calls, "rev-parse --show-toplevel") < index_of(calls, "check-ignore"))
        assert.is_true(index_of(calls, "check-ignore") < index_of(calls, "worktree add"))
        assert.is_truthy(index_of(calls, "worktree add --detach") > 0)
    end)

    it("keeps an existing .gitignore entry and does not duplicate it", function()
        vim.fn.writefile({ "*.log", "/.worktrees/" }, repo .. "/.gitignore")
        install_fake_git()
        local res = call(W.create, { cwd = repo, name = "wt-2" })
        assert.is_nil(res[2])
        local lines = vim.fn.readfile(repo .. "/.gitignore")
        assert.are.same({ "*.log", "/.worktrees/" }, lines)
    end)

    it("rejects bad names, non-directories, and existing targets", function()
        install_fake_git()
        local bad_name = call(W.create, { cwd = repo, name = "../escape" })
        assert.is_nil(bad_name[1])
        assert.is_truthy(bad_name[2]:find("must not start with", 1, true))

        local bad_cwd = call(W.create, { cwd = repo .. "/nope" })
        assert.is_nil(bad_cwd[1])
        assert.is_truthy(bad_cwd[2]:find("not a directory", 1, true))

        vim.fn.mkdir(repo .. "/.worktrees/taken", "p")
        local taken = call(W.create, { cwd = repo, name = "taken" })
        assert.is_nil(taken[1])
        assert.is_truthy(taken[2]:find("already exists", 1, true))
    end)

    it("refuses to create from inside a linked worktree", function()
        local _, wt = make_fake_worktree(root, "outer")
        install_fake_git()
        local res = call(W.create, { cwd = wt, name = "inner" })
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("already inside worktree", 1, true))
    end)

    it("reports a failing `git worktree add` without writing metadata", function()
        install_fake_git({ add_code = 128 })
        local res = call(W.create, { cwd = repo, name = "wt-3" })
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("git worktree add", 1, true))
        assert.is_nil(vim.uv.fs_stat(repo .. "/.git/worktrees/wt-3/pi2-worktree.json"))
    end)

    it("runs setup_cmd before the success callback", function()
        Config.setup({ worktree = { setup_cmd = { "fake-setup" } } })
        install_fake_git()
        local res = call(W.create, { cwd = repo, name = "wt-4" })
        assert.is_nil(res[2])
        assert.is_not_nil(res[1])
        assert.is_truthy(index_of(calls, "fake-setup") > index_of(calls, "worktree add"))
        assert.are.equal(repo .. "/.worktrees/wt-4", setup_cwd)
    end)

    it("keeps the worktree and reports setup failures", function()
        setup_code, setup_stderr = 3, "boom happened"
        Config.setup({ worktree = { setup_cmd = { "fake-setup" } } })
        install_fake_git()
        local res = call(W.create, { cwd = repo, name = "wt-5" })
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("setup_cmd failed (exit 3)", 1, true))
        assert.is_truthy(res[2]:find("boom happened", 1, true))
        assert.is_not_nil(vim.uv.fs_stat(repo .. "/.worktrees/wt-5"))
        assert.is_not_nil(vim.uv.fs_stat(repo .. "/.git/worktrees/wt-5/pi2-worktree.json"))
    end)

    it("refuses to copy more include matches than the file cap", function()
        vim.fn.writefile({ "node_modules/" }, repo .. "/.worktreeinclude")
        W._set_max_files(1)
        install_fake_git({ include_files = { "node_modules/a.js", "node_modules/b.js" } })
        local res = call(W.create, { cwd = repo, name = "wt-cap" })
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("include: 2 files match", 1, true))
        assert.is_truthy(res[2]:find("(limit 1)", 1, true))
    end)

    it("detaches at an explicit base commit", function()
        install_fake_git({ base_sha = "resolved-base-sha" })
        local res = call(W.create, { cwd = repo, name = "wt-base", base = "main~2" })
        assert.is_nil(res[2], tostring(res[2]))
        assert.is_not_nil(res[1])
        assert.are.equal("resolved-base-sha", res[1].base_sha)

        -- The revision is committed to a sha before `worktree add` uses it.
        local resolved = index_of(calls, "rev-parse --verify -q main~2^{commit}")
        assert.is_true(resolved > 0, table.concat(calls, " | "))
        assert.is_true(resolved < index_of(calls, "worktree add --detach"))
        assert.is_truthy(
            table
                .concat(calls, " ")
                :find("worktree add --detach " .. repo .. "/.worktrees/wt-base resolved-base-sha", 1, true)
        )

        local meta =
            vim.json.decode(table.concat(vim.fn.readfile(repo .. "/.git/worktrees/wt-base/pi2-worktree.json"), ""))
        assert.are.equal("resolved-base-sha", meta.base_sha)
    end)

    it("rejects an unknown base commit", function()
        install_fake_git({ base_ok = false })
        local res = call(W.create, { cwd = repo, name = "wt-base-bad", base = "nope" })
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("create: invalid base commit: nope", 1, true))
        assert.are.equal(-1, index_of(calls, "worktree add"))
    end)

    it("retries with --force when the target is registered but missing", function()
        install_fake_git({ stale_once = true })
        local res = call(W.create, { cwd = repo, name = "wt-stale" })
        assert.is_nil(res[2], tostring(res[2]))
        assert.is_not_nil(res[1])

        local plain = index_of(calls, "worktree add --detach " .. repo .. "/.worktrees/wt-stale")
        local forced = index_of(calls, "worktree add --force --detach " .. repo .. "/.worktrees/wt-stale")
        assert.is_true(plain > 0, table.concat(calls, " | "))
        assert.is_true(forced > plain, "the retry must use --force")
        assert.is_not_nil(vim.uv.fs_stat(repo .. "/.git/worktrees/wt-stale/pi2-worktree.json"))
    end)

    it("never forces when the target directory exists", function()
        install_fake_git({ add_error = { 128, "fatal: '" .. repo .. "/.worktrees/wt-taken' already exists" } })
        local res = call(W.create, { cwd = repo, name = "wt-taken" })
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("already exists", 1, true), tostring(res[2]))
        assert.is_true(index_of(calls, "worktree add --detach") > 0)
        assert.are.equal(-1, index_of(calls, "--force"))
    end)
end)

describe("worktree default names", function()
    before_each(function()
        W._reset()
    end)

    after_each(function()
        W._reset()
    end)

    it("appends the pid and a per-process sequence to the timestamp", function()
        local first = W._default_name()
        local second = W._default_name()

        assert.is_true(first ~= second, "same-second names must differ")
        assert.is_true((W.validate_name(first)), first)
        assert.is_true((W.validate_name(second)), second)

        local stamp, pid, seq = first:match("^wt%-(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d)%-(%d+)%-(%d+)$")
        assert.is_not_nil(stamp, first)
        assert.are.equal(tostring(vim.uv.os_getpid()), pid)
        assert.are.equal("1", seq)
        assert.are.equal("2", second:match("^wt%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+%-(%d+)$"))
    end)
end)

describe("worktree metadata version guard", function()
    local root

    before_each(function()
        W._reset()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    it("detect ignores metadata written by a newer version", function()
        local _, wt = make_fake_worktree(root, "wt-future", {
            version = 99,
            base_sha = "future-sha",
            session_id = "future-session",
        })
        local info = W.detect(wt)
        assert.is_not_nil(info)
        assert.are.equal("linked", info.kind)
        -- Falls back to the directory name and keeps git-derived fields only.
        assert.are.equal("wt-future", info.name)
        assert.is_nil(info.base_sha)
        assert.is_nil(info.session_id)
    end)

    it("bind refuses to overwrite newer metadata", function()
        local _, wt, git_dir = make_fake_worktree(root, "wt-future2", { version = 99 })
        local info = W.detect(wt)
        assert.is_not_nil(info)

        local ok, err = W.bind(info, { session_id = "sess-new", session_file = "/tmp/x.jsonl" })
        assert.is_false(ok)
        assert.is_truthy(err:find("unsupported worktree metadata version 99", 1, true), tostring(err))

        local raw = table.concat(vim.fn.readfile(git_dir .. "/pi2-worktree.json"), "\n")
        assert.is_truthy(raw:find('"version":99', 1, true))
        assert.is_nil(raw:find("sess-new", 1, true))
        assert.is_nil(vim.uv.fs_stat(git_dir .. "/pi2-worktree.json.tmp"))
    end)
end)

describe("worktree snapshot guards", function()
    local root

    before_each(function()
        W._reset()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    --- Fake the three commands `collect_diff` runs (tracked diff, ls-files, and
    --- one `--no-index` answer for every untracked entry).
    ---@param opts { diff?: table, untracked?: string[], no_index?: table, no_index_by_path?: table<string, table> }
    local function install_collect_runner(opts)
        local untracked = table.concat(opts.untracked or {}, "\0")
        if #untracked > 0 then
            untracked = untracked .. "\0"
        end
        W._set_runner(function(argv, _, cb)
            if has(argv, "rev-parse HEAD") then
                return cb(0, (opts.head or "head-sha") .. "\n", "")
            end
            if has(argv, "ls-files") then
                return cb(0, untracked, "")
            end
            if has(argv, "--no-index") then
                local rel = argv[#argv]
                local answer = opts.no_index_by_path and opts.no_index_by_path[rel]
                    or opts.no_index
                    or { 1, "diff --git a/x b/x\nnew file mode 100644\n", "" }
                return cb(answer[1], answer[2] or "", answer[3] or "")
            end
            local tracked = opts.diff or { 0, "", "" }
            return cb(tracked[1], tracked[2] or "", tracked[3] or "")
        end)
    end

    ---@return pi.WorktreeInfo
    local function fake_info()
        local _, wt = make_fake_worktree(root, "wt-guard")
        local info = W.detect(wt)
        assert.is_not_nil(info)
        return info
    end

    it("fails when an untracked entry is a nested repository", function()
        local info = fake_info()
        install_collect_runner({
            untracked = { "nested/" },
            no_index = { 1, "", "error: Could not access 'nested/null'" },
        })
        local res = call(W.snapshot, info)
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find('cannot capture untracked path "nested/"', 1, true), tostring(res[2]))
        assert.is_truthy(res[2]:find("nested repository or empty diff", 1, true))
    end)

    it("fails on a --no-index error exit", function()
        local info = fake_info()
        install_collect_runner({ untracked = { "u.txt" }, no_index = { 2, "", "boom" } })
        local res = call(W.snapshot, info)
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("git diff --no-index failed (exit 2)", 1, true), tostring(res[2]))
        assert.is_truthy(res[2]:find("cannot capture untracked path", 1, true))
    end)

    it("fails when --no-index yields no patch", function()
        local info = fake_info()
        install_collect_runner({ untracked = { "u.txt" }, no_index = { 1, "", "" } })
        local res = call(W.snapshot, info)
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("cannot capture untracked path", 1, true))
    end)

    it("fails above the untracked file cap before writing anything", function()
        local info = fake_info()
        W._set_max_files(1)
        install_collect_runner({ untracked = { "a.txt", "b.txt" } })
        local res = call(W.snapshot, info)
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("cannot capture 2 untracked files (limit 1)", 1, true), tostring(res[2]))
        assert.is_nil(vim.uv.fs_stat(info.common_dir .. "/pi2-worktree-snapshots"))
    end)

    it("rejects an unsafe metadata name before running git", function()
        local info = fake_info()
        W._set_runner(function()
            error("snapshot must validate the name before spawning git")
        end)
        for _, name in ipairs({ "../evil", "a/b", "", ".hidden" }) do
            local res = call(W.snapshot, vim.tbl_extend("force", {}, info, { name = name }))
            assert.is_nil(res[1], name)
            assert.is_truthy(res[2]:find("snapshot: ", 1, true), tostring(res[2]))
        end
    end)

    it("writes the patch when every untracked file is representable", function()
        local info = fake_info()
        install_collect_runner({
            diff = { 0, "diff --git a/seed.txt b/seed.txt\n--- a/seed.txt\n+++ b/seed.txt\n", "" },
            untracked = { "u.txt" },
            no_index = { 1, "diff --git a/u.txt b/u.txt\nnew file mode 100644\n", "" },
        })
        local res = call(W.snapshot, info)
        assert.is_nil(res[2], tostring(res[2]))
        local body = table.concat(vim.fn.readfile(res[1]), "\n")
        assert.is_truthy(body:find("diff --git a/seed.txt", 1, true))
        assert.is_truthy(body:find("diff --git a/u.txt", 1, true))
    end)
end)

describe("worktree probe and apply_patch", function()
    local root
    local calls

    before_each(function()
        W._reset()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        calls = {}
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    --- Ordered scripted runner: first matching needle wins.
    ---@param answers table<integer, table> list of { needle, { code, stdout?, stderr? } }
    local function install(answers)
        W._set_runner(function(argv, opts, cb)
            local line = table.concat(argv, " ")
            calls[#calls + 1] = { line = line, stdin = opts and opts.stdin }
            for _, entry in ipairs(answers) do
                if line:find(entry[1], 1, true) then
                    local answer = entry[2]
                    return cb(answer[1], answer[2] or "", answer[3] or "")
                end
            end
            return cb(0, "", "")
        end)
    end

    it("reports clean and passes the patch on stdin", function()
        install({ { "rev-parse", { 0, root .. "\n" } }, { "apply --check -", { 0 } } })
        local patch = "diff --git a/x b/x\n"
        local res = call(W.probe, root, patch)

        assert.are.equal("clean", res[1])
        assert.is_nil(res[2])
        assert.are.equal(2, #calls)
        assert.is_truthy(calls[2].line:find("apply --check -", 1, true))
        assert.are.equal(patch, calls[2].stdin)
    end)

    it("normalizes a patch without a trailing newline", function()
        install({ { "rev-parse", { 0, root .. "\n" } }, { "apply --check -", { 0 } } })
        call(W.probe, root, "diff --git a/x b/x")
        assert.are.equal("diff --git a/x b/x\n", calls[2].stdin)
    end)

    it("reports already when only the reverse check applies", function()
        install({
            { "rev-parse", { 0, root .. "\n" } },
            { "apply --reverse --check -", { 0 } },
            { "apply --check -", { 1, "", "patch does not apply" } },
        })
        local res = call(W.probe, root, "diff --git a/x b/x\n")
        assert.are.equal("already", res[1])
        assert.is_nil(res[2])
        assert.are.equal(3, #calls)
        assert.is_truthy(calls[3].line:find("apply --reverse --check -", 1, true))
    end)

    it("reports conflict when neither direction applies", function()
        install({
            { "rev-parse", { 0, root .. "\n" } },
            { "apply --reverse --check -", { 1, "", "patch does not apply" } },
            { "apply --check -", { 1, "", "patch does not apply" } },
        })
        local res = call(W.probe, root, "diff --git a/x b/x\n")
        assert.are.equal("conflict", res[1])
        assert.is_nil(res[2])
    end)

    it("treats an empty patch as already integrated without spawning git", function()
        W._set_runner(function()
            error("probe must not spawn git for an empty patch")
        end)
        local res = call(W.probe, root, "   \n")
        assert.are.equal("already", res[1])
        assert.is_nil(res[2])
    end)

    it("rejects a missing target, a non-git target and a non-string patch", function()
        local missing = call(W.probe, root .. "/nope", "diff --git a/x b/x\n")
        assert.is_nil(missing[1])
        assert.is_truthy(missing[2]:find("target is not a directory", 1, true))

        local not_string = call(W.probe, root, 42)
        assert.is_nil(not_string[1])
        assert.is_truthy(not_string[2]:find("patch must be a string", 1, true))

        install({ { "rev-parse", { 128, "", "fatal: not a git repository" } } })
        local not_git = call(W.probe, root, "diff --git a/x b/x\n")
        assert.is_nil(not_git[1])
        assert.is_truthy(not_git[2]:find("not a git repository", 1, true))
    end)

    it("applies to the working tree only", function()
        install({ { "rev-parse", { 0, root .. "\n" } }, { "apply -", { 0 } } })
        local patch = "diff --git a/x b/x\n"
        local res = call(W.apply_patch, root, patch)

        assert.is_true(res[1], tostring(res[2]))
        assert.is_nil(res[2])
        assert.are.equal(2, #calls)
        assert.is_truthy(calls[2].line:find(" apply -", 1, true))
        assert.is_nil(calls[2].line:find("--index", 1, true))
        assert.is_nil(calls[2].line:find("--cached", 1, true))
        assert.is_nil(calls[2].line:find("--3way", 1, true))
        assert.are.equal(patch, calls[2].stdin)
    end)

    it("reports a failing apply and refuses an empty patch", function()
        install({
            { "rev-parse", { 0, root .. "\n" } },
            { "apply -", { 1, "", "error: patch failed: f.txt:1" } },
        })
        local res = call(W.apply_patch, root, "diff --git a/f b/f\n")
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("git apply failed (exit 1)", 1, true))
        assert.is_truthy(res[2]:find("patch failed", 1, true))

        local calls_before = #calls
        local empty = call(W.apply_patch, root, "")
        assert.is_nil(empty[1])
        assert.is_truthy(empty[2]:find("empty patch", 1, true))
        assert.are.equal(calls_before, #calls)
    end)
end)

describe("worktree diff base override", function()
    local root

    before_each(function()
        W._reset()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    ---@return string[] seen diff argv lines
    local function install_diff_runner()
        local seen = {}
        W._set_runner(function(argv, _, cb)
            local line = table.concat(argv, " ")
            if line:find("ls-files", 1, true) then
                return cb(0, "", "")
            end
            seen[#seen + 1] = line
            return cb(0, "diff --git a/seed b/seed\n", "")
        end)
        return seen
    end

    it("defaults to base_sha and honours opts.from without changing the old signature", function()
        local _, wt = make_fake_worktree(root, "wt-diff")
        local info = W.detect(wt)
        assert.is_not_nil(info)

        --- `W.diff(info, cb, opts)` takes the callback *before* the options, so the
        --- shared `call()` helper (which appends the callback last) cannot be used.
        ---@param opts? table
        ---@return { n: integer, [integer]: any }
        local function diff_with(opts)
            local pack, done = nil, false
            W.diff(info, function(diff, err)
                pack = { n = 2, diff, err }
                done = true
            end, opts)
            assert.is_true(
                vim.wait(5000, function()
                    return done
                end, 5),
                "timed out waiting for diff callback"
            )
            return pack
        end

        local seen = install_diff_runner()
        local legacy = diff_with(nil)
        assert.is_nil(legacy[2])
        assert.is_truthy(seen[1]:find(info.base_sha, 1, true))

        seen = install_diff_runner()
        local override = diff_with({ from = "abc999def" })
        assert.is_nil(override[2])
        assert.is_truthy(seen[1]:find("abc999def", 1, true))
        assert.is_nil(seen[1]:find(info.base_sha, 1, true))

        seen = install_diff_runner()
        local blank = diff_with({ from = "   " })
        assert.is_nil(blank[2])
        assert.is_truthy(seen[1]:find(info.base_sha, 1, true))
    end)
end)

describe("worktree snapshot sidecar", function()
    local root

    before_each(function()
        W._reset()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    local function install_snapshot_runner()
        W._set_runner(function(argv, _, cb)
            local line = table.concat(argv, " ")
            if line:find("rev-parse HEAD", 1, true) then
                return cb(0, "head-sha-1\n", "")
            end
            if line:find("ls-files", 1, true) then
                return cb(0, "", "")
            end
            return cb(0, "diff --git a/seed.txt b/seed.txt\n", "")
        end)
    end

    it("writes a .json sidecar next to the patch", function()
        local _, wt = make_fake_worktree(root, "wt-snap")
        local info = W.detect(wt)
        install_snapshot_runner()

        local res = call(W.snapshot, info)
        assert.is_nil(res[2], tostring(res[2]))
        local patch = res[1]
        assert.is_not_nil(patch)
        assert.is_not_nil(vim.uv.fs_stat(patch .. ".json"))

        local meta = vim.json.decode(table.concat(vim.fn.readfile(patch .. ".json"), ""))
        assert.are.equal("wt-snap", meta.name)
        assert.are.equal(info.path, meta.path)
        assert.are.equal(info.repo_root, meta.repo_root)
        assert.are.equal(info.base_sha, meta.base_sha)
        assert.are.equal("head-sha-1", meta.head)
        assert.are.equal("number", type(meta.created_at))
        assert.is_true(meta.created_at > 0)
    end)

    it("fails (and removes the patch) when the sidecar cannot be written", function()
        local _, wt = make_fake_worktree(root, "wt-snap2")
        local info = W.detect(wt)
        install_snapshot_runner()
        W._set_sidecar_writer(function()
            return false, "disk full"
        end)

        local res = call(W.snapshot, info)
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("disk full", 1, true), tostring(res[2]))

        local dir = info.common_dir .. "/pi2-worktree-snapshots/wt-snap2"
        local scan = vim.uv.fs_scandir(dir)
        assert.is_not_nil(scan)
        assert.is_nil(vim.uv.fs_scandir_next(scan), "no orphan patch may be left behind")
    end)

    it("latest_snapshot returns the newest patch with its metadata (sync)", function()
        local repo, wt = make_fake_worktree(root, "wt-latest")
        local info = W.detect(wt)
        install_snapshot_runner()

        local first = call(W.snapshot, info)[1]
        assert.is_not_nil(first)
        vim.uv.fs_utime(first, 0, 1000)
        local second = call(W.snapshot, info)[1]
        assert.is_not_nil(second)
        assert.is_true(first ~= second)
        vim.uv.fs_utime(second, 0, 2000)

        local latest = W.latest_snapshot(repo, "wt-latest")
        assert.is_not_nil(latest)
        assert.are.equal(second, latest.path)
        assert.is_not_nil(latest.meta)
        assert.are.equal("wt-latest", latest.meta.name)
        assert.are.equal("head-sha-1", latest.meta.head)
    end)

    it("returns a sidecar-less patch and nil for unknown names", function()
        local repo, wt = make_fake_worktree(root, "wt-orphan")
        local info = W.detect(wt)
        local dir = info.common_dir .. "/pi2-worktree-snapshots/wt-orphan"
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({ "diff --git a/x b/x" }, dir .. "/20260101-000000.patch")

        local latest = W.latest_snapshot(repo, "wt-orphan")
        assert.is_not_nil(latest)
        assert.is_nil(latest.meta)
        assert.is_truthy(latest.path:find("20260101-000000.patch", 1, true))

        assert.is_nil(W.latest_snapshot(repo, "never-created"))
        assert.is_nil(W.latest_snapshot(repo, "../escape"))
        assert.is_nil(W.latest_snapshot(root .. "/no-such-repo", "wt-orphan"))
    end)
end)

describe("worktree list", function()
    local root

    before_each(function()
        W._reset()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    it("parses porcelain blocks (pure)", function()
        local records = W._parse_worktree_list(table.concat({
            "worktree /repo",
            "HEAD aaa",
            "branch refs/heads/main",
            "",
            "worktree /repo/.worktrees/w1",
            "HEAD bbb",
            "detached",
            "",
            "worktree /repo/.worktrees/gone",
            "HEAD ccc",
            "detached",
            "prunable gitdir file points to non-existent location",
            "",
            "worktree /repo/.worktrees/bare",
            "bare",
            "",
        }, "\r\n"))

        assert.are.equal(4, #records)
        assert.are.equal("/repo/.worktrees/w1", records[2].path)
        assert.are.equal("main", records[1].branch)
        assert.are.equal("aaa", records[1].head)
        assert.is_false(records[1].detached)
        assert.is_true(records[2].detached)
        assert.is_nil(records[2].branch)
        assert.is_true(records[3].prunable)
        assert.is_true(records[4].bare)
    end)

    it("returns linked worktrees with git head/branch, skipping the main checkout", function()
        local repo, wt1 = make_fake_worktree(root, "w1")
        local wt2 = repo .. "/.worktrees/w2"
        local git_dir2 = repo .. "/.git/worktrees/w2"
        vim.fn.mkdir(git_dir2, "p")
        vim.fn.mkdir(wt2, "p")
        vim.fn.writefile({ "../.." }, git_dir2 .. "/commondir")
        vim.fn.writefile({ "gitdir: " .. git_dir2 }, wt2 .. "/.git")
        vim.fn.writefile({
            vim.json.encode({ version = 1, name = "w2", path = wt2, repo_root = repo, base_sha = "bbb" }),
        }, git_dir2 .. "/pi2-worktree.json")

        local porcelain = table.concat({
            "worktree " .. repo,
            "HEAD main-sha",
            "branch refs/heads/main",
            "",
            "worktree " .. wt1,
            "HEAD sha1",
            "detached",
            "",
            "worktree " .. wt2,
            "HEAD sha2",
            "branch refs/heads/feat",
            "",
        }, "\n")

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

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        local entries = res[1]
        assert.are.equal(2, #entries)
        assert.are.equal(wt1, entries[1].path)
        assert.are.equal(wt2, entries[2].path)
        assert.are.equal("w1", entries[1].name)
        assert.are.equal("abc123", entries[1].base_sha)
        assert.are.equal(repo, entries[1].repo_root)
        assert.are.equal("sha1", entries[1].head)
        assert.is_true(entries[1].detached)
        assert.is_nil(entries[1].branch)
        assert.are.equal("feat", entries[2].branch)
        assert.is_false(entries[2].detached)
    end)

    it("reports managed registrations whose directory is gone as missing", function()
        local repo = make_fake_worktree(root, "w1")
        local repo_real = vim.uv.fs_realpath(repo) or repo
        local stale = repo .. "/.worktrees/stale"
        local stale_git_dir = repo .. "/.git/worktrees/stale"
        vim.fn.mkdir(stale_git_dir, "p")
        vim.fn.writefile({ "../.." }, stale_git_dir .. "/commondir")
        vim.fn.writefile({
            vim.json.encode({
                version = 1,
                name = "stale",
                path = stale,
                repo_root = repo,
                base_sha = "stale-base",
                mode = "isolated",
                session_id = "sess-stale",
                session_file = "/tmp/sess-stale.jsonl",
            }),
        }, stale_git_dir .. "/pi2-worktree.json")

        -- A missing registration outside `<repo>/.worktrees/` is not managed and
        -- must not be reported (it could belong to another tool/user).
        local external = root .. "/external"
        local porcelain = table.concat({
            "worktree " .. repo,
            "HEAD main-sha",
            "branch refs/heads/main",
            "",
            "worktree " .. repo .. "/.worktrees/w1",
            "HEAD sha1",
            "detached",
            "",
            "worktree " .. stale,
            "HEAD sha-stale",
            "detached",
            "prunable gitdir file points to non-existent location",
            "",
            "worktree " .. external,
            "HEAD sha-ext",
            "detached",
            "prunable gitdir file points to non-existent location",
            "",
        }, "\n")
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

        local res = call(W.list, repo)
        assert.is_nil(res[2], tostring(res[2]))
        local entries = res[1]
        assert.are.equal(2, #entries)

        local stale_entry
        for _, entry in ipairs(entries) do
            if entry.missing then
                stale_entry = entry
            elseif entry.path == repo .. "/.worktrees/w1" then
                assert.is_false(entry.missing)
            end
        end
        assert.is_not_nil(stale_entry, "the stale registration must be listed")
        assert.are.equal("stale", stale_entry.name)
        assert.are.equal(vim.fs.normalize(stale), stale_entry.path)
        assert.are.equal(repo_real, stale_entry.repo_root)
        assert.are.equal("linked", stale_entry.kind)
        assert.is_true(stale_entry.prunable)
        assert.are.equal("sha-stale", stale_entry.head)
        assert.is_true(stale_entry.detached)
        -- The checkout's own metadata outlives the directory: Resume needs it.
        assert.are.equal("stale-base", stale_entry.base_sha)
        assert.are.equal("sess-stale", stale_entry.session_id)
        assert.are.equal("/tmp/sess-stale.jsonl", stale_entry.session_file)
    end)

    it("reports an error outside a repository", function()
        W._set_runner(function(_, _, cb)
            cb(128, "", "fatal: not a git repository")
        end)
        local res = call(W.list, root)
        assert.is_nil(res[1])
        assert.is_truthy(res[2]:find("list: not a git repository", 1, true))
    end)
end)

describe("worktree snapshot_worktrees", function()
    local root

    before_each(function()
        W._reset()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    ---@param repo string
    ---@param name string
    ---@param meta? table
    ---@return string dir
    local function write_snapshot(repo, name, meta)
        local dir = repo .. "/.git/pi2-worktree-snapshots/" .. name
        vim.fn.mkdir(dir, "p")
        vim.fn.writefile({ "diff --git a/x b/x\n" }, dir .. "/20260101-000000.patch")
        if meta ~= nil then
            vim.fn.writefile({ vim.json.encode(meta) }, dir .. "/20260101-000000.patch.json")
        end
        return dir
    end

    it("returns snapshot-backed worktrees whose checkout is gone", function()
        local repo, live = make_fake_worktree(root, "live")
        local repo_real = vim.uv.fs_realpath(repo) or repo
        local gone = repo .. "/.worktrees/gone"
        write_snapshot(repo, "gone", {
            name = "gone",
            path = gone,
            repo_root = repo,
            base_sha = "base-gone",
            head = "head-gone",
            created_at = 1700000000,
        })
        -- Skipped: no sidecar, then a corrupt one in the same place.
        local corrupt_dir = write_snapshot(repo, "corrupt", nil)
        vim.fn.writefile({ "{not json" }, corrupt_dir .. "/20260101-000000.patch.json")
        -- Skipped: sidecar belongs to another worktree name.
        write_snapshot(repo, "mismatch", {
            name = "other",
            path = repo .. "/.worktrees/other",
            repo_root = repo,
            base_sha = "b",
            head = "h",
        })
        -- Skipped: unsafe directory name.
        write_snapshot(repo, ".hidden", {
            name = ".hidden",
            path = repo .. "/.worktrees/.hidden",
            repo_root = repo,
            base_sha = "b",
            head = "h",
        })
        -- Skipped: that checkout still exists (list() covers it).
        write_snapshot(repo, "live", { name = "live", path = live, repo_root = repo, base_sha = "b", head = "h" })

        local entries = W.snapshot_worktrees(repo)
        assert.are.equal(1, #entries)
        local entry = entries[1]
        assert.are.equal("gone", entry.name)
        assert.are.equal(vim.fs.normalize(gone), entry.path)
        assert.are.equal(repo_real, entry.repo_root)
        assert.are.equal("linked", entry.kind)
        assert.is_true(entry.missing)
        assert.is_true(entry.prunable)
        assert.are.equal("base-gone", entry.base_sha)
        assert.are.equal("head-gone", entry.head)
        assert.is_not_nil(entry.snapshot)
        assert.is_true(entry.snapshot:find("pi2-worktree-snapshots/gone/", 1, true) ~= nil)
    end)

    it("returns an empty list outside a repository, and never raises", function()
        assert.are.equal(0, #W.snapshot_worktrees(root))
        assert.are.equal(0, #W.snapshot_worktrees(root .. "/nope"))

        local repo = make_fake_worktree(root, "x")
        write_snapshot(repo, "gone", {
            name = "gone",
            path = repo .. "/.worktrees/gone",
            repo_root = repo,
            base_sha = "b",
            head = "h",
        })
        assert.are.equal(1, #W.snapshot_worktrees(root .. "/main"))
    end)
end)

describe("worktree release snapshot", function()
    local root
    local calls

    before_each(function()
        W._reset()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        calls = {}
    end)

    after_each(function()
        W._reset()
        if root then
            vim.fn.delete(root, "rf")
        end
    end)

    ---@param list string[]
    ---@param needle string
    ---@return integer
    local function last_index(list, needle)
        local found = -1
        for i, line in ipairs(list) do
            if line:find(needle, 1, true) then
                found = i
            end
        end
        return found
    end

    ---@param list string[]
    ---@param needle string
    ---@return integer
    local function count_of(list, needle)
        local n = 0
        for _, line in ipairs(list) do
            if line:find(needle, 1, true) then
                n = n + 1
            end
        end
        return n
    end

    --- Status / snapshot / removal runner: `dirty` flips `git status`, `ahead`
    --- feeds `rev-list --count`, everything else succeeds with empty output.
    ---@param opts? { dirty?: boolean, ahead?: integer }
    local function install(opts)
        opts = opts or {}
        W._set_runner(function(argv, _, cb)
            local line = table.concat(argv, " ")
            calls[#calls + 1] = line
            if line:find("status --porcelain", 1, true) then
                return cb(0, opts.dirty and "?? dirty.txt\0" or "", "")
            end
            if line:find("rev-list --count", 1, true) then
                return cb(0, tostring(opts.ahead or 0) .. "\n", "")
            end
            if line:find("rev-parse HEAD", 1, true) then
                return cb(0, "head-sha\n", "")
            end
            if line:find("ls-files", 1, true) then
                return cb(0, "", "")
            end
            return cb(0, "", "")
        end)
    end

    it("snapshots a clean checkout before deleting it", function()
        local _, wt = make_fake_worktree(root, "wt-clean")
        local info = W.detect(wt)
        install()

        local res = call(W.release, info)
        assert.is_true(res[1], tostring(res[2]))
        assert.is_nil(res[2])

        local snap = W.latest_snapshot(info.repo_root, "wt-clean")
        assert.is_not_nil(snap)
        assert.is_not_nil(snap.meta)
        assert.are.equal("wt-clean", snap.meta.name)
        assert.are.equal(info.base_sha, snap.meta.base_sha)
        assert.are.equal("head-sha", snap.meta.head)
        assert.are.equal(0, vim.uv.fs_stat(snap.path).size)

        -- The snapshot must be complete (diff + sidecar head) before the removal,
        -- and the removal happens exactly once (no recursion).
        local diff_at = last_index(calls, " diff ")
        local head_at = last_index(calls, "rev-parse HEAD")
        local remove_at = last_index(calls, "worktree remove")
        assert.is_true(diff_at > 0, table.concat(calls, " | "))
        assert.is_true(head_at > diff_at, "the sidecar head is read after the patch")
        assert.is_true(remove_at > head_at, "the snapshot must be complete before the removal")
        assert.are.equal(1, count_of(calls, "worktree remove"))
        assert.are.equal(1, count_of(calls, "worktree prune"))
    end)

    it("keeps a clean checkout (single callback) when the snapshot fails", function()
        local _, wt = make_fake_worktree(root, "wt-clean2")
        local info = W.detect(wt)
        install()
        W._set_sidecar_writer(function()
            return false, "disk full"
        end)

        local results = {}
        W.release(info, function(removed, err)
            results[#results + 1] = { removed, err }
        end)
        assert.is_true(
            vim.wait(5000, function()
                return #results > 0
            end, 5),
            "timed out waiting for release callback"
        )
        vim.wait(50)

        assert.are.equal(1, #results, "the callback must fire exactly once")
        assert.is_false(results[1][1])
        assert.is_truthy(results[1][2]:find("snapshot failed", 1, true), tostring(results[1][2]))
        assert.is_truthy(results[1][2]:find("disk full", 1, true))
        assert.are.equal(0, count_of(calls, "worktree remove"))
        assert.are.equal(0, count_of(calls, "worktree prune"))
        assert.is_not_nil(vim.uv.fs_stat(info.path))
    end)

    it("does not snapshot a dirty or ahead checkout (old semantics)", function()
        local _, dirty_wt = make_fake_worktree(root, "wt-dirty")
        local dirty_info = W.detect(dirty_wt)
        install({ dirty = true })
        local dirty = call(W.release, dirty_info)
        assert.is_false(dirty[1])
        assert.is_truthy(dirty[2]:find("uncommitted changes", 1, true))
        assert.are.equal(0, count_of(calls, "worktree remove"))
        assert.are.equal(0, count_of(calls, " diff "))
        assert.is_nil(W.latest_snapshot(dirty_info.repo_root, "wt-dirty"))

        local _, ahead_wt = make_fake_worktree(root, "wt-ahead")
        local ahead_info = W.detect(ahead_wt)
        calls = {}
        install({ ahead = 2 })
        local ahead = call(W.release, ahead_info)
        assert.is_false(ahead[1])
        assert.is_truthy(ahead[2]:find("commit(s) not in", 1, true))
        assert.are.equal(0, count_of(calls, "worktree remove"))
        assert.are.equal(0, count_of(calls, " diff "))
        assert.is_nil(W.latest_snapshot(ahead_info.repo_root, "wt-ahead"))
    end)
end)
