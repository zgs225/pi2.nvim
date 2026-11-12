-- Sub-session worktree isolation (lua/pi/subsessions + extensions/subagent-child.ts).
--
-- Covers: automatic worktree creation per child, the child cwd handed to the
-- process, no nesting when the parent already runs in a linked worktree, a
-- failed creation releasing the spawn reservation, worktree release only after
-- the process closed (close / crash / reaper backstop), revive reuse of a dirty
-- worktree, and the dynamic prompt note in the child extension.
--
-- Hermetic: `pi.worktree` is a fake installed in package.loaded, child
-- processes are fakes registered via _register_for_test, and the manifest is
-- redirected to a temp file. No git, no real pi process, no network.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Reaper = require("pi.subsessions.reaper")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")

local function repo_root()
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
end

--- Fake `pi.worktree` module recording every call.
---@class TestWorktreeEnv
---@field root string Temp dir standing in for the checkout root.
---@field create_calls table[] Options of every create() call.
---@field release_calls table[] Worktree info of every release() call.
---@field bind_calls table[] `{ info, meta }` of every bind() call.
---@field linked table<string, boolean> cwds detect() reports as linked worktrees.
---@field repos table<string, boolean> cwds detect() reports as a main work tree.
---@field create_error string? When set, create() reports this error.
---@field reject_base boolean? When true, create() rejects any explicit `base` (as a rewritten history does).
---@field dirty boolean When true, release() keeps the directory (uncommitted work).
---@field running_at_release boolean? rpc liveness observed by the last release().

--- Install a fake worktree module and return its recording environment.
---@return TestWorktreeEnv
local function install_fake_worktree()
    local env = {
        root = vim.fn.tempname() .. "-wt-root",
        create_calls = {},
        release_calls = {},
        bind_calls = {},
        linked = {},
        create_error = nil,
        dirty = false,
        running_at_release = nil,
    }
    vim.fn.mkdir(env.root, "p")

    local fake = {}

    ---@param opts { cwd: string, mode: string }
    ---@param cb fun(info: table?, err: string?)
    function fake.create(opts, cb)
        env.create_calls[#env.create_calls + 1] = opts
        if env.create_error then
            local err = env.create_error
            vim.schedule(function()
                cb(nil, err)
            end)
            return
        end
        if env.reject_base and opts.base ~= nil then
            -- A recorded base commit that no longer resolves (rewritten history).
            vim.schedule(function()
                cb(nil, "create: invalid base commit: " .. opts.base)
            end)
            return
        end
        local n = #env.create_calls
        local name = opts.name or ("wt-%d"):format(n)
        local info = {
            kind = "linked",
            path = ("%s/%s"):format(env.root, name),
            name = name,
            branch = ("sub/%s"):format(name),
            repo_root = opts.cwd,
            mode = opts.mode,
            parent = opts.cwd,
        }
        vim.fn.mkdir(info.path, "p")
        vim.schedule(function()
            cb(info, nil)
        end)
    end

    ---@param cwd string
    ---@return table?
    function fake.detect(cwd)
        if env.linked[cwd] then
            return { kind = "linked", path = cwd, name = "parent-wt", branch = "feat/parent", parent = "/repo" }
        end
        if env.repos[cwd] then
            -- A real detect() also reports the main work tree; that is *not* a
            -- worktree session and must not suppress isolation.
            return { kind = "main", path = cwd, name = "main", repo_root = cwd }
        end
        return nil
    end

    ---@param info table
    ---@param cb? fun(ok: boolean)
    function fake.release(info, cb)
        env.release_calls[#env.release_calls + 1] = info
        if env.live_rpc then
            env.running_at_release = env.live_rpc:is_running() == true
        end
        if not env.dirty and type(info.path) == "string" then
            vim.fn.delete(info.path, "rf")
        end
        if cb then
            cb(true)
        end
    end

    ---@param info table
    ---@param meta { session_id?: string, session_file?: string }
    function fake.bind(info, meta)
        env.bind_calls[#env.bind_calls + 1] = { info = info, meta = meta }
    end

    env.fake = fake
    package.loaded["pi.worktree"] = fake
    return env
end

describe("sub-session worktree isolation", function()
    local manifest_tmp
    local real_manifest_path
    local real_create_detached
    local real_load_session_path
    local real_worktree_module
    local env ---@type TestWorktreeEnv
    local created ---@type table[]
    local children ---@type table<string, table>
    local load_calls ---@type { session: table, path: string }[]

    ---@param id string
    ---@param running boolean
    ---@return table
    local function make_child_session(id, running)
        local state = { running = running }
        local session = {
            id = id,
            attention = { pending = {} },
            cwd = vim.fn.getcwd(),
            rpc = {
                is_running = function()
                    return state.running
                end,
                stop = function()
                    state.running = false
                end,
                send = function(_, cmd, cb)
                    if cmd.type == "get_state" and cb then
                        vim.schedule(function()
                            cb({
                                success = true,
                                data = {
                                    sessionId = id,
                                    sessionFile = ("%s/%s.jsonl"):format(env.root, id),
                                },
                            })
                        end)
                    elseif cmd.type == "prompt" and cb then
                        vim.schedule(function()
                            cb({ success = true })
                        end)
                    elseif cb then
                        vim.schedule(function()
                            cb({ success = true })
                        end)
                    end
                    return true
                end,
            },
        }
        session._state = state
        return session
    end

    ---@param id string
    ---@param cwd string?
    ---@return table
    local function make_parent(id, cwd)
        return {
            id = id,
            conversation_epoch = 0,
            cwd = cwd or vim.fn.getcwd(),
            rpc = {
                is_running = function()
                    return true
                end,
                send = function() end,
            },
        }
    end

    --- Spawn a child and wait for the outcome.
    ---@param parent table
    ---@param task? string
    ---@return table? child
    ---@return string? err
    local function spawn_and_wait(parent, task)
        local result, failure
        Subsessions.spawn(parent, { task = task or "do the thing" }, function(child, err)
            result, failure = child, err
        end)
        local settled = vim.wait(3000, function()
            return result ~= nil or failure ~= nil
        end, 10)
        assert.is_true(settled, "spawn did not settle")
        return result, failure
    end

    --- Seed a dormant child row whose recorded checkout has been released.
    ---@param id string
    ---@param recorded { name: string, repo_root: string, base_sha: string? }
    ---@return string recorded_path Checkout path the row records (no longer on disk).
    ---@return string session_file Transcript the row records.
    local function seed_released_checkout(id, recorded)
        local path = ("%s/%s"):format(env.root, recorded.name)
        -- A clean close deletes the checkout (the normal path); the manifest row
        -- keeps pointing at the directory that no longer exists.
        vim.fn.delete(path, "rf")
        assert.equals(0, vim.fn.isdirectory(path))

        local session_file = ("%s/%s.jsonl"):format(env.root, id)
        vim.fn.writefile({ "{}" }, session_file)
        Manifest.upsert(id, {
            parent_id = "parent-seed",
            status = "dormant",
            workspace = "/repo/parent",
            session_file = session_file,
            worktree = {
                kind = "linked",
                path = path,
                name = recorded.name,
                repo_root = recorded.repo_root,
                base_sha = recorded.base_sha,
                mode = "new",
            },
        })
        return path, session_file
    end

    --- Revive `id` and wait for the outcome.
    ---@param id string
    ---@return table? revived
    ---@return string? err
    local function revive_and_wait(id)
        local revived, revive_err
        Subsessions.revive(id, function(session, err)
            revived, revive_err = session, err
        end)
        local settled = vim.wait(3000, function()
            return revived ~= nil or revive_err ~= nil
        end, 10)
        assert.is_true(settled, "revive did not settle")
        return revived, revive_err
    end

    before_each(function()
        real_worktree_module = package.loaded["pi.worktree"]
        Config.setup({
            subagent = { enabled = true, max_children = 5 },
            worktree = { isolate_subagents = true },
        })
        env = install_fake_worktree()
        created = {}
        children = {}
        env.repos = {}

        -- Keep the real session load out of these tests: revive's worktree
        -- decision is what is under test, not the switch_session round-trip.
        real_load_session_path = Sessions.load_session_path
        load_calls = {}
        Sessions.load_session_path = function(session, path, callback)
            load_calls[#load_calls + 1] = { session = session, path = path }
            session.session_file = path
            session._revive_path = path
            if callback then
                callback(true)
            end
        end

        manifest_tmp = vim.fn.tempname() .. "-worktree-manifest.json"
        real_manifest_path = Manifest.path
        Manifest._reset()
        Reaper._reset()
        Manifest.path = function()
            return manifest_tmp
        end

        real_create_detached = Sessions.create_detached
        Sessions.create_detached = function(tab, opts)
            created[#created + 1] = { tab = tab, opts = opts }
            local id = "child-" .. #created
            local session = make_child_session(id, true)
            session.cwd = opts and opts.cwd or vim.fn.getcwd()
            -- Mirror the real manager: the worktree metadata rides on the
            -- session, which is what close_session / _process_exit release.
            session.worktree = opts and opts.worktree or nil
            children[id] = session
            Sessions._register_for_test(session)
            return session
        end

        env.live_rpc = nil
    end)

    after_each(function()
        Sessions.create_detached = real_create_detached
        Sessions.load_session_path = real_load_session_path
        Manifest.path = real_manifest_path
        Manifest._reset()
        Reaper._reset()
        os.remove(manifest_tmp)
        Sessions._reset()
        package.loaded["pi.worktree"] = real_worktree_module
        Config.setup({})
    end)

    it("creates a dedicated worktree per child and runs it there", function()
        local parent = make_parent("parent-1", "/repo/parent")
        -- The parent's cwd is a normal (main) checkout: not a worktree session.
        env.repos["/repo/parent"] = true
        local child, err = spawn_and_wait(parent)
        assert.is_nil(err)
        assert.is_not_nil(child)

        assert.equals(1, #env.create_calls)
        assert.equals("/repo/parent", env.create_calls[1].cwd)
        assert.equals("new", env.create_calls[1].mode)

        local info = env.create_calls[1] and child.worktree
        assert.is_not_nil(info)
        assert.equals(1, #created)
        assert.equals(info.path, created[1].opts.cwd)
        assert.same(info, created[1].opts.worktree)
        assert.equals(info.path, child.cwd)

        local entry = Manifest.load()["child-1"]
        assert.is_not_nil(entry)
        assert.equals(info.path, entry.worktree.path)
        assert.equals(env.root .. "/child-1.jsonl", entry.session_file)

        assert.equals(1, #env.bind_calls)
        assert.equals("child-1", env.bind_calls[1].meta.session_id)
        assert.equals(env.root .. "/child-1.jsonl", env.bind_calls[1].meta.session_file)
    end)

    it("gives every child its own worktree name", function()
        Config.setup({
            subagent = { enabled = true, max_children = 2 },
            worktree = { isolate_subagents = true },
        })
        local parent = make_parent("parent-1b", "/repo/parent")
        local first, first_err = spawn_and_wait(parent, "one")
        local second, second_err = spawn_and_wait(parent, "two")
        assert.is_nil(first_err)
        assert.is_nil(second_err)
        assert.is_not_nil(first)
        assert.is_not_nil(second)

        -- Second-resolution default names collide for children dispatched
        -- together (batch fan-out), so each spawn must name its own worktree.
        assert.equals(2, #env.create_calls)
        local a, b = env.create_calls[1].name, env.create_calls[2].name
        assert.is_not_nil(a, "create() must be given a worktree name")
        assert.is_not_nil(b, "create() must be given a worktree name")
        assert.is_truthy(a:match("^sub%-"), "child worktrees are named sub-*")
        assert.is_truthy(a:match("^[%w][%w._%-]*$"), "name must satisfy pi.worktree.validate_name")
        assert.are_not_equal(a, b)
    end)

    it("never nests: a child of a worktree session inherits its cwd", function()
        local parent = make_parent("parent-2", "/repo/wt-parent")
        env.linked["/repo/wt-parent"] = true

        local child, err = spawn_and_wait(parent)
        assert.is_nil(err)
        assert.is_not_nil(child)

        assert.equals(0, #env.create_calls)
        assert.equals(1, #created)
        assert.equals("/repo/wt-parent", created[1].opts.cwd)
        assert.is_nil(created[1].opts.worktree)
        assert.is_nil(child.worktree)
        assert.is_nil(Manifest.load()["child-1"].worktree)
        assert.equals(0, #env.bind_calls)
    end)

    it("the parent's worktree metadata alone also prevents nesting", function()
        local parent = make_parent("parent-2b", "/repo/wt-other")
        parent.worktree = { kind = "linked", path = "/repo/wt-other", name = "wt-other" }

        local child, err = spawn_and_wait(parent)
        assert.is_nil(err)
        assert.is_not_nil(child)
        assert.equals(0, #env.create_calls)
        assert.equals("/repo/wt-other", created[1].opts.cwd)
        assert.is_nil(created[1].opts.worktree)
    end)

    it("a failed worktree creation releases the spawn slot and reports the error", function()
        Config.setup({
            subagent = { enabled = true, max_children = 1 },
            worktree = { isolate_subagents = true },
        })
        env.create_error = "fatal: 'sub/wt-1' is already checked out"

        local parent = make_parent("parent-3", "/repo/parent")
        local child, err = spawn_and_wait(parent)
        assert.is_nil(child)
        assert.is_not_nil(err)
        assert.is_truthy(err:find("already checked out", 1, true))
        assert.equals(0, #created)

        -- The reservation must be gone: with max_children = 1 the next spawn
        -- would otherwise fail with a max-children error instead of succeeding.
        env.create_error = nil
        local second, second_err = spawn_and_wait(parent)
        assert.is_nil(second_err)
        assert.is_not_nil(second)
        assert.equals(1, #created)
    end)

    it("isolate_subagents = false keeps the shared parent cwd", function()
        Config.setup({
            subagent = { enabled = true, max_children = 5 },
            worktree = { isolate_subagents = false },
        })
        local parent = make_parent("parent-4", "/repo/parent")
        local child, err = spawn_and_wait(parent)
        assert.is_nil(err)
        assert.is_not_nil(child)

        assert.equals(0, #env.create_calls)
        assert.equals("/repo/parent", created[1].opts.cwd)
        assert.is_nil(created[1].opts.worktree)
    end)

    it("close releases the worktree only after the process is stopped", function()
        local parent = make_parent("parent-5", "/repo/parent")
        local child = assert(spawn_and_wait(parent))
        env.live_rpc = child.rpc

        assert.is_true(Subsessions.close("child-1"))

        -- The manager hands the worktree back from a scheduled callback: it must
        -- land after rpc:stop(), never before (a live cwd must not be removed).
        assert.is_true(
            vim.wait(2000, function()
                return #env.release_calls == 1
            end, 10),
            "close must release the worktree"
        )
        assert.equals(child.worktree.path, env.release_calls[1].path)
        assert.is_false(env.running_at_release == true, "release must not run while the process is alive")
        assert.equals("dormant", Manifest.load()["child-1"].status)
    end)

    it("release skips a live child and keeps a dirty worktree for revive", function()
        local parent = make_parent("parent-6", "/repo/parent")
        local child = assert(spawn_and_wait(parent))
        local info = child.worktree

        -- Still running: nothing may be deleted under a live process.
        env.live_rpc = child.rpc
        assert.is_false(Subsessions.release_worktree("child-1"))
        assert.equals(0, #env.release_calls)

        -- Uncommitted work: release runs but the checkout survives.
        env.dirty = true
        Subsessions.close("child-1")
        assert.is_true(
            vim.wait(2000, function()
                return #env.release_calls == 1
            end, 10),
            "close must ask for a release"
        )
        assert.equals(1, vim.fn.isdirectory(info.path))
        assert.equals(0, child.rpc:is_running() and 1 or 0)

        -- Revive reuses the surviving worktree instead of creating a new one.
        vim.fn.writefile({ "{}" }, env.root .. "/child-1.jsonl")
        local revived, revive_err
        Subsessions.revive("child-1", function(session, err)
            revived, revive_err = session, err
        end)
        assert.is_true(
            vim.wait(3000, function()
                return revived ~= nil or revive_err ~= nil
            end, 10),
            "revive did not settle"
        )
        assert.is_nil(revive_err)
        assert.is_not_nil(revived)

        assert.equals(1, #env.create_calls, "revive must reuse the existing worktree")
        assert.equals(info.path, created[2].opts.cwd)
        assert.equals(info.path, created[2].opts.worktree.path)
        assert.equals("active", Manifest.load()["child-1"].status)
    end)

    it("revive recreates a released checkout at its recorded path", function()
        local recorded_name = "sub-20260101-120000-1-abc"
        env.repos["/repo/parent"] = true
        local recorded_path, session_file = seed_released_checkout("child-dead-1", {
            name = recorded_name,
            repo_root = "/repo/parent",
            base_sha = "0123456789abcdef0123456789abcdef01234567",
        })

        local revived, revive_err = revive_and_wait("child-dead-1")
        assert.is_nil(revive_err)
        assert.is_not_nil(revived)

        -- Recreated under the *recorded* name: only that directory matches the
        -- cwd in the child's transcript, so a fresh sub-<ts> name would make
        -- load_session_path fail on this and every later revive.
        assert.equals(1, #env.create_calls)
        assert.equals(recorded_name, env.create_calls[1].name)
        assert.equals("/repo/parent", env.create_calls[1].cwd)
        assert.equals("new", env.create_calls[1].mode)
        assert.equals("0123456789abcdef0123456789abcdef01234567", env.create_calls[1].base)

        assert.equals(recorded_path, revived.cwd)
        assert.equals(recorded_path, created[1].opts.cwd)
        -- The transcript is loaded with the revived child (whose cwd is the
        -- recreated checkpoint) as its recorded working directory.
        assert.equals(1, #load_calls)
        assert.equals(session_file, load_calls[1].path)
        assert.equals(revived, load_calls[1].session)
        assert.equals(recorded_path, load_calls[1].session.cwd)
        assert.equals(recorded_path, Manifest.load()["child-dead-1"].worktree.path)
        assert.equals("active", Manifest.load()["child-dead-1"].status)
    end)

    it("revive isolates afresh when the recorded checkout is another repository", function()
        local recorded_name = "sub-20260101-120000-1-abc"
        env.repos["/repo/parent"] = true
        local recorded_path, session_file = seed_released_checkout("child-other-1", {
            name = recorded_name,
            repo_root = "/other/repo",
            base_sha = "0123456789abcdef0123456789abcdef01234567",
        })

        local revived, revive_err = revive_and_wait("child-other-1")
        assert.is_nil(revive_err)
        assert.is_not_nil(revived)

        -- Documented fallback: a checkout of a different repository is never
        -- replayed there — the child is isolated afresh instead.
        assert.equals(1, #env.create_calls)
        local name = env.create_calls[1].name
        assert.is_not_nil(name)
        assert.are_not_equal(recorded_name, name)
        assert.is_truthy(name:match("^sub%-"), "a fresh child worktree is named sub-*")
        assert.are_not_equal(recorded_path, revived.cwd)
        assert.equals(env.root .. "/" .. name, revived.cwd)
        assert.equals(session_file, load_calls[1].path)
        assert.equals(revived, load_calls[1].session)
    end)

    it("revive retries without a recorded base commit that no longer resolves", function()
        local recorded_name = "sub-20260101-120000-2-def"
        env.repos["/repo/parent"] = true
        env.reject_base = true
        local recorded_path, session_file = seed_released_checkout("child-dead-2", {
            name = recorded_name,
            repo_root = "/repo/parent",
            base_sha = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        })

        local revived, revive_err = revive_and_wait("child-dead-2")
        assert.is_nil(revive_err)
        assert.is_not_nil(revived)

        -- One rejected attempt, then one retry at HEAD — still the same name.
        assert.equals(2, #env.create_calls)
        assert.equals("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", env.create_calls[1].base)
        assert.is_nil(env.create_calls[2].base)
        assert.equals(recorded_name, env.create_calls[2].name)
        assert.equals(recorded_path, revived.cwd)
        assert.equals(session_file, load_calls[1].path)
        assert.equals(recorded_path, load_calls[1].session.cwd)
    end)

    it("the reaper backstop releases worktrees of orphaned children only", function()
        local parent = make_parent("parent-7", "/repo/parent")
        local child = assert(spawn_and_wait(parent))
        local path = child.worktree.path

        -- A child the registry still knows belongs to the manager's release path.
        assert.equals(0, Reaper.release_orphaned_worktrees())
        assert.equals(0, #env.release_calls)

        -- Neovim restarted: the manifest row survives, the registry row does not.
        Sessions._reset()

        -- A live session rooted in the checkout (manifest id not yet migrated)
        -- still blocks the release of that path.
        local shadow = make_child_session("stale-tmp-id", true)
        shadow.cwd = path
        Sessions._register_for_test(shadow)
        assert.equals(0, Reaper.release_orphaned_worktrees())
        assert.equals(0, #env.release_calls)
        Sessions._reset()

        assert.equals(1, Reaper.release_orphaned_worktrees())
        assert.equals(1, #env.release_calls)
        assert.equals(path, env.release_calls[1].path)
        assert.is_false(env.running_at_release == true)
        assert.equals(0, vim.fn.isdirectory(path))
    end)

    it("a settled child that is still alive keeps its cwd", function()
        local parent = make_parent("parent-8", "/repo/parent")
        local child = assert(spawn_and_wait(parent))
        local path = child.worktree.path

        -- agent_settled with the process still running: keep the worktree (the
        -- reaper closes the process later, and the manager releases on close).
        pcall(Subsessions.on_child_settled, child)
        pcall(Reaper.sweep)
        assert.equals(0, #env.release_calls)
        assert.equals(1, vim.fn.isdirectory(path))
    end)
end)

describe("extensions/subagent-child.ts worktree note", function()
    local content

    before_each(function()
        local path = repo_root() .. "/extensions/subagent-child.ts"
        local file = io.open(path, "r")
        assert.is_not_nil(file, "subagent-child.ts must exist at: " .. path)
        content = file:read("*a")
        file:close()
    end)

    it("keeps WORKER_NOTE a static constant", function()
        local note = content:match("const WORKER_NOTE%s*=%s*%[(.-)%]%.join")
        assert.is_not_nil(note, "WORKER_NOTE must be a [...].join(...) constant")
        assert.is_nil(note:find("${", 1, true), "WORKER_NOTE must not use template interpolation")
        assert.is_nil(note:find("`", 1, true), "WORKER_NOTE must not use template literals")
    end)

    it("reads the worktree path from PI_NVIM_WORKTREE_PATH", function()
        assert.is_not_nil(
            content:match('const WORKTREE_ENV%s*=%s*"PI_NVIM_WORKTREE_PATH"'),
            "the child note must read PI_NVIM_WORKTREE_PATH"
        )
        assert.is_not_nil(content:match("process%.env%[WORKTREE_ENV%]"), "the path must come from the environment")
    end)

    it("stays byte-identical without the env var", function()
        -- The worker note alone is the pre-worktree prompt: without the env var
        -- the suffix must be the empty string, not extra padding.
        assert.is_truthy(
            content:find("const note = WORKER_NOTE + worktreeSuffix();", 1, true),
            "the hook must build WORKER_NOTE + the worktree suffix"
        )
        assert.is_truthy(content:find("if (!path) {", 1, true), "missing no-env guard")
        assert.is_truthy(content:find('return "";', 1, true), "the no-env branch must add nothing")
    end)

    it("declares the isolated cwd and forbids nesting", function()
        local note = content:match("function worktreeNote%(path: string%): string {(.-)\n}")
        assert.is_not_nil(note, "worktreeNote(path) must exist")
        assert.is_not_nil(note:match("isolated git worktree at %${path}"), "the note must name the worktree path")
        assert.is_not_nil(note:match("working directory"), "the note must declare the child cwd")
        assert.is_not_nil(note:match("nested git worktrees"), "the note must forbid nested worktrees")
        assert.is_not_nil(
            note:match("parent owns worktree lifecycle"),
            "the note must say the parent owns the lifecycle"
        )
    end)

    it("injects the assembled note through before_agent_start", function()
        assert.is_not_nil(content:match('pi%.on%("before_agent_start"'))
        assert.is_not_nil(content:match("%${event%.systemPrompt}.*%${note}"))
    end)
end)
