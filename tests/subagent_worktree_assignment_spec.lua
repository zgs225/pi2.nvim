-- Explicit worktree assignment for sub-agent spawn/revive.
--
-- A spawn/dispatch item may name an **existing linked worktree** (`worktree =
-- { path }`). The child runs there but never owns it: it lives on
-- `assigned_worktree`, so close/crash/reaper never release it, a resume never
-- rebinds it as owned, and a revive revalidates it instead of falling back to
-- the parent workspace. The parent's manifest/batch workspace is unchanged.
--
-- Hermetic: fake `pi.worktree` detection, fake detached processes, temp agent
-- dir. No git, no real pi process, no network.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Batch = require("pi.subsessions.batch")
local Read = require("pi.subsessions.read")
local Reaper = require("pi.subsessions.reaper")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")

---@param path string
---@return string
local function make_dir(path)
    vim.fn.mkdir(path, "p")
    return assert(vim.uv.fs_realpath(path))
end

---@param path string
---@return string
local function resolve(path)
    return vim.fn.resolve(path)
end

describe("sub-agent worktree assignment", function()
    local agent_dir ---@type string
    local workspace ---@type string
    local neovim_cwd ---@type string
    local assigned_path ---@type string
    local other_repo ---@type string
    local original_cwd ---@type string
    local real = {}
    local created ---@type table[]
    local spawn_opts ---@type table[]
    local worktree_env ---@type table

    ---@param id string
    ---@param file string?
    ---@return table
    local function make_child(id, file)
        local state = { running = true }
        local session = {
            id = id,
            attention = { pending = {} },
            rpc = {
                is_running = function()
                    return state.running
                end,
                stop = function()
                    state.running = false
                end,
                send = function(_, cmd, cb)
                    if not cb then
                        return true
                    end
                    vim.schedule(function()
                        if cmd.type == "get_state" then
                            cb({ success = true, data = { sessionId = id, sessionFile = file } })
                        else
                            cb({ success = true })
                        end
                    end)
                    return true
                end,
            },
        }
        session._state = state
        return session
    end

    ---@param id string
    ---@return table
    local function make_parent(id)
        return {
            id = id,
            conversation_epoch = 0,
            cwd = workspace,
            attached_tab = vim.api.nvim_get_current_tabpage(),
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
                send = function() end,
            },
        }
    end

    ---@param path string
    ---@param info table
    local function map_worktree(path, info)
        info = vim.tbl_extend("force", { path = resolve(path) }, info)
        worktree_env.by_path[resolve(path)] = info
    end

    --- Install a recording fake `pi.worktree` whose detect() is a path map.
    local function install_fake_worktree()
        worktree_env = {
            calls = { create = 0, detect = 0, bind = 0, release = 0 },
            by_path = {},
            detect_paths = {},
        }
        local fake = {}
        function fake.detect(path)
            worktree_env.calls.detect = worktree_env.calls.detect + 1
            local key = resolve(path)
            worktree_env.detect_paths[#worktree_env.detect_paths + 1] = key
            return worktree_env.by_path[key]
        end
        function fake.create(_, cb)
            worktree_env.calls.create = worktree_env.calls.create + 1
            if cb then
                cb(nil, "create must not be called")
            end
        end
        function fake.bind()
            worktree_env.calls.bind = worktree_env.calls.bind + 1
        end
        function fake.release(_, cb)
            worktree_env.calls.release = worktree_env.calls.release + 1
            if cb then
                cb(true)
            end
        end
        package.loaded["pi.worktree"] = fake
    end

    before_each(function()
        original_cwd = vim.fn.getcwd()
        agent_dir = make_dir(vim.fn.tempname() .. "-agent")
        workspace = make_dir(vim.fn.tempname() .. "-workspace")
        neovim_cwd = make_dir(vim.fn.tempname() .. "-neovim")
        assigned_path = make_dir(vim.fn.tempname() .. "-assigned-wt")
        other_repo = make_dir(vim.fn.tempname() .. "-other-repo")
        Config.setup({
            agent_dir = agent_dir,
            subagent = { enabled = true, max_children = 10, batch_timeout_ms = 2000 },
        })
        -- Neovim's cwd stays on the repository so lazy module discovery keeps
        -- working; the parent's workspace/assignment paths still differ from it.
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        Manifest._reset()
        Batch._reset()
        Reaper._reset()
        Sessions._reset()
        created = {}
        spawn_opts = {}

        real.worktree = package.loaded["pi.worktree"]
        install_fake_worktree()
        local common = workspace .. "/.git"
        map_worktree(workspace, {
            kind = "main",
            name = "workspace",
            path = workspace,
            repo_root = workspace,
            git_dir = common,
            common_dir = common,
        })
        map_worktree(assigned_path, {
            kind = "linked",
            name = "assigned",
            path = assigned_path,
            repo_root = workspace,
            git_dir = common .. "/worktrees/assigned",
            common_dir = common,
            base_sha = "abc123",
        })
        map_worktree(other_repo, {
            kind = "linked",
            name = "foreign",
            path = other_repo,
            repo_root = other_repo .. "-main",
            git_dir = other_repo .. "-main/.git/worktrees/foreign",
            common_dir = other_repo .. "-main/.git",
        })

        real.create_detached = Sessions.create_detached
        Sessions.create_detached = function(tab, opts)
            opts = opts or {}
            local id = "child-" .. (#created + 1)
            local session = make_child(id, (opts.cwd or workspace) .. "/" .. id .. ".jsonl")
            session.cwd = opts.cwd
            session._process_cwd = opts.cwd
            session.worktree = opts.worktree
            session.assigned_worktree = opts.assigned_worktree
            created[#created + 1] = {
                tab = tab,
                opts = opts,
                session = session,
                reserved = Sessions.cwd_reserved(opts.cwd),
            }
            spawn_opts[#spawn_opts + 1] = opts
            Sessions._register_for_test(session)
            return session
        end

        real.load_session_path = Sessions.load_session_path
        Sessions.load_session_path = function(session, path, cb)
            session.session_file = path
            if cb then
                cb(true)
            end
        end

        real.read_find_path = Read.find_path
        real.reattach_view = Sessions.reattach_view
    end)

    after_each(function()
        Sessions.create_detached = real.create_detached
        Sessions.load_session_path = real.load_session_path
        Read.find_path = real.read_find_path
        Sessions.reattach_view = real.reattach_view
        package.loaded["pi.worktree"] = real.worktree
        Reaper._reset()
        Sessions._reset()
        Manifest._reset()
        Batch._reset()
        Config.setup({})
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        for _, dir in ipairs({ agent_dir, workspace, neovim_cwd, assigned_path, other_repo }) do
            pcall(vim.fn.delete, dir, "rf")
        end
    end)

    ---@param parent table
    ---@param opts table
    ---@return table? child
    ---@return string? err
    local function spawn_and_wait(parent, opts)
        local child, err
        Subsessions.spawn(parent, opts, function(c, e)
            child, err = c, e
        end)
        assert.is_true(
            vim.wait(3000, function()
                return child ~= nil or err ~= nil
            end, 10),
            "spawn must settle"
        )
        return child, err
    end

    ---@param id string
    ---@return table? child
    ---@return string? err
    local function revive_and_wait(id)
        local child, err
        Subsessions.revive(id, function(c, e)
            child, err = c, e
        end)
        assert.is_true(
            vim.wait(3000, function()
                return child ~= nil or err ~= nil
            end, 10),
            "revive must settle"
        )
        return child, err
    end

    ---@param id string
    ---@param worktree table
    ---@param status? string
    ---@return string session_file
    local function seed_assigned_row(id, worktree, status)
        local session_file = workspace .. "/" .. id .. ".jsonl"
        vim.fn.writefile({ vim.json.encode({ type = "session", id = id, cwd = worktree.path }) }, session_file)
        Manifest.upsert(id, {
            parent_id = "parent-lineage",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "t",
            config = {},
            status = status or "dormant",
            reported = false,
            created_at = "t0",
            last_active_at = "t0",
            run_generation = 1,
            session_file = session_file,
            workspace = workspace,
            assigned_worktree = worktree,
        }, workspace)
        return session_file
    end

    it("runs a spawned child in the assigned worktree and records it separately", function()
        local parent = make_parent("parent-1")

        local child, err = spawn_and_wait(parent, { task = "work", worktree = { path = assigned_path } })
        assert.is_nil(err)
        assert.is_not_nil(child)

        assert.equals(1, #created)
        local record = created[1]
        assert.equals(resolve(assigned_path), record.opts.cwd, "the process cwd is the canonical worktree root")
        assert.equals(resolve(assigned_path), record.opts.assigned_worktree.path)
        assert.equals("linked", record.opts.assigned_worktree.kind)
        assert.is_nil(record.opts.worktree, "an assignment is not passed as an owned worktree")
        assert.is_nil(child.worktree, "the child owns no worktree")
        assert.equals(resolve(assigned_path), child.assigned_worktree.path)
        assert.is_false(Sessions.cwd_reserved(assigned_path), "the spawn reservation is released")

        local entry = Manifest.load(workspace)[child.id]
        assert.is_not_nil(entry)
        assert.equals(workspace, entry.workspace, "the row stays in the parent's manifest workspace")
        assert.equals(workspace, child.manifest_cwd)
        assert.is_nil(entry.worktree, "assigned/owned stay separate in the manifest")
        assert.equals(resolve(assigned_path), entry.assigned_worktree.path)
        assert.equals("linked", entry.assigned_worktree.kind)
        assert.equals(child.session_file, entry.session_file, "the transcript is recorded")

        assert.equals(0, worktree_env.calls.create)
        assert.equals(0, worktree_env.calls.bind)
        assert.equals(0, worktree_env.calls.release)
    end)

    it("keeps the original parent-workspace behavior when worktree is omitted", function()
        local parent = make_parent("parent-2")

        local child, err = spawn_and_wait(parent, { task = "plain" })
        assert.is_nil(err)
        assert.is_not_nil(child)

        assert.equals(workspace, created[1].opts.cwd)
        assert.is_nil(created[1].opts.assigned_worktree)
        assert.is_nil(child.assigned_worktree)
        assert.equals(0, worktree_env.calls.detect, "omitted worktree performs no detection")
        local entry = Manifest.load(workspace)[child.id]
        assert.is_nil(entry.assigned_worktree)
        assert.is_nil(entry.worktree)
        assert.equals(workspace, entry.workspace)
    end)

    it("recognizes POSIX and Windows-drive absolute paths in the pure predicate", function()
        -- The resolver's filesystem checks still run on the host OS; this pins
        -- the platform rule (same as `pi.worktree`'s is_abs) without a Windows
        -- runtime.
        assert.is_true(Subsessions._is_absolute_path("/tmp/wt"))
        assert.is_true(Subsessions._is_absolute_path("C:\\repo\\wt"))
        assert.is_true(Subsessions._is_absolute_path("C:/repo/wt"))
        assert.is_false(Subsessions._is_absolute_path("relative/wt"))
        assert.is_false(Subsessions._is_absolute_path("C:relative"))
    end)

    it("rejects missing, relative, main, plain-dir and other-repository paths", function()
        local plain_dir = make_dir(vim.fn.tempname() .. "-plain")
        local missing = make_dir(vim.fn.tempname() .. "-missing")
        vim.fn.delete(missing, "rf")
        local cases = {
            { path = missing, pattern = "existing directory" },
            { path = "relative/worktree", pattern = "absolute" },
            { path = workspace, pattern = "not a linked worktree" },
            { path = plain_dir, pattern = "not a git worktree" },
            { path = other_repo, pattern = "different repository" },
        }
        local parent = make_parent("parent-3")
        for _, case in ipairs(cases) do
            local child, err = spawn_and_wait(parent, { task = "no", worktree = { path = case.path } })
            assert.is_nil(child)
            assert.is_truthy(err, "case must fail: " .. case.path)
            assert.is_truthy(err:find(case.pattern, 1, true), ("error %q must mention %q"):format(err, case.pattern))
        end
        assert.equals(0, #created, "no rejected assignment may start a process")
        assert.equals(0, #spawn_opts)
        assert.is_nil(next(Manifest.load(workspace)), "no row may be written for a rejected assignment")
        assert.equals(0, worktree_env.calls.create)
        assert.equals(0, worktree_env.calls.release)
        pcall(vim.fn.delete, plain_dir, "rf")
    end)

    it("allows several children to share one assigned worktree", function()
        local parent = make_parent("parent-4")

        local first, first_err = spawn_and_wait(parent, { task = "one", worktree = { path = assigned_path } })
        local second, second_err = spawn_and_wait(parent, { task = "two", worktree = { path = assigned_path } })
        assert.is_nil(first_err)
        assert.is_nil(second_err)
        assert.is_not_nil(first)
        assert.is_not_nil(second)

        assert.equals(2, #created)
        assert.equals(created[1].opts.cwd, created[2].opts.cwd)
        assert.equals(resolve(assigned_path), created[1].opts.cwd)
        local manifest = Manifest.load(workspace)
        assert.equals(resolve(assigned_path), manifest[first.id].assigned_worktree.path)
        assert.equals(resolve(assigned_path), manifest[second.id].assigned_worktree.path)
        assert.is_false(Sessions.cwd_reserved(assigned_path))
    end)

    it("revalidates an assigned worktree on revive and fails closed when it is gone", function()
        local assigned = {
            kind = "linked",
            path = resolve(assigned_path),
            name = "assigned",
            repo_root = workspace,
            git_dir = workspace .. "/.git/worktrees/assigned",
            common_dir = workspace .. "/.git",
        }
        local session_file = seed_assigned_row("child-revive", assigned)

        local revived, err = revive_and_wait("child-revive")
        assert.is_nil(err)
        assert.is_not_nil(revived)
        assert.equals(resolve(assigned_path), created[1].opts.cwd)
        assert.equals(resolve(assigned_path), created[1].opts.assigned_worktree.path)
        assert.is_nil(created[1].opts.worktree)
        assert.is_nil(revived.worktree)
        assert.equals(session_file, revived.session_file, "the original transcript is still loaded")
        local entry = Manifest.load(workspace)["child-revive"]
        assert.equals("active", entry.status)
        assert.equals(resolve(assigned_path), entry.assigned_worktree.path)
        assert.is_nil(entry.worktree)
        assert.is_false(Sessions.cwd_reserved(assigned_path))

        -- Remove the checkout: the next revive must error, not fall back.
        Sessions.close_session(revived)
        vim.fn.delete(assigned_path, "rf")
        local missing, missing_err = revive_and_wait("child-revive")
        assert.is_nil(missing)
        assert.is_truthy(missing_err)
        assert.is_truthy(missing_err:find("existing directory", 1, true))
        assert.equals(1, #created, "a missing assignment never starts a parent-workspace process")
        assert.equals(resolve(assigned_path), Manifest.load(workspace)["child-revive"].assigned_worktree.path)
    end)

    it("fails closed when an assigned worktree was replaced by a non-worktree path", function()
        local assigned = {
            kind = "linked",
            path = resolve(assigned_path),
            name = "assigned",
            repo_root = workspace,
            common_dir = workspace .. "/.git",
        }
        seed_assigned_row("child-replaced", assigned)
        map_worktree(
            assigned_path,
            { kind = "main", name = "assigned", path = assigned_path, repo_root = assigned_path }
        )

        local revived, err = revive_and_wait("child-replaced")
        assert.is_nil(revived)
        assert.is_truthy(err and err:find("not a linked worktree", 1, true))
        assert.equals(0, #created, "no fallback to the parent workspace")
    end)

    it("does not release an assigned worktree on close, crash or reaper sweep", function()
        local parent = make_parent("parent-5")
        local child = assert(spawn_and_wait(parent, { task = "close", worktree = { path = assigned_path } }))
        Sessions.close_session(child)
        vim.wait(50)
        assert.equals(0, worktree_env.calls.release, "close must not release an assigned worktree")
        assert.is_true(vim.fn.isdirectory(assigned_path) == 1)

        local crash = assert(spawn_and_wait(parent, { task = "crash", worktree = { path = assigned_path } }))
        crash.parent_id = nil -- crash release hook only; no settle/batch bookkeeping
        Sessions.handle_event(crash, { type = "_process_exit", code = 1 })
        vim.wait(50)
        assert.equals(0, worktree_env.calls.release, "a crash must not release an assigned worktree")

        -- A leftover assigned row with no live process is not an orphaned
        -- *owned* worktree: the reaper's backstop must leave it alone too.
        Manifest.upsert("child-orphan-assigned", {
            parent_id = "parent-lineage",
            parent_epoch = 0,
            name = "orphan",
            task_prompt = "t",
            config = {},
            status = "completed",
            reported = true,
            created_at = "t0",
            last_active_at = "t0",
            run_generation = 1,
            workspace = workspace,
            assigned_worktree = {
                kind = "linked",
                path = resolve(assigned_path),
                name = "assigned",
                repo_root = workspace,
                common_dir = workspace .. "/.git",
            },
        }, workspace)
        Sessions._reset()
        Reaper.sweep()
        assert.equals(0, worktree_env.calls.release, "the reaper must not release an assigned worktree")
    end)

    it("reserves the canonical cwd while spawning and releases it on failure", function()
        local parent = make_parent("parent-6")
        local child = assert(spawn_and_wait(parent, { task = "reserve", worktree = { path = assigned_path } }))
        assert.is_not_nil(child)
        assert.is_true(created[1].reserved, "create_detached must see the reservation")
        assert.is_false(Sessions.cwd_reserved(assigned_path), "the successful path releases it")

        local rescue = Sessions.create_detached
        Sessions.create_detached = function()
            return nil
        end
        local failed, failed_err = spawn_and_wait(parent, { task = "fail", worktree = { path = assigned_path } })
        Sessions.create_detached = rescue
        assert.is_nil(failed)
        assert.is_truthy(failed_err)
        assert.is_false(Sessions.cwd_reserved(assigned_path), "a failed start must not leak the reservation")
    end)

    it("keeps an owner worktree alive while a spawn holds its cwd reservation", function()
        local owner = make_child("owner", nil)
        owner.worktree = {
            kind = "linked",
            path = resolve(assigned_path),
            name = "owner",
            repo_root = workspace,
            common_dir = workspace .. "/.git",
        }
        Sessions._register_for_test(owner)

        Sessions.reserve_cwd(assigned_path)
        assert.is_true(Sessions.cwd_reserved(assigned_path))
        Sessions.close_session(owner)
        vim.wait(50)
        assert.equals(0, worktree_env.calls.release, "a reservation must keep the checkout alive")

        Sessions.release_cwd(assigned_path)
        local second = make_child("owner-2", nil)
        second.worktree = {
            kind = "linked",
            path = resolve(assigned_path),
            name = "owner",
            repo_root = workspace,
            common_dir = workspace .. "/.git",
        }
        Sessions._register_for_test(second)
        Sessions.close_session(second)
        vim.wait(50)
        assert.equals(1, worktree_env.calls.release, "once the reservation is gone the owner release runs")
    end)

    it("does not rebind an assigned worktree as owned on resume", function()
        local assigned = {
            kind = "linked",
            path = resolve(assigned_path),
            name = "assigned",
            repo_root = workspace,
            common_dir = workspace .. "/.git",
        }
        local session_file = workspace .. "/resumed.jsonl"
        vim.fn.writefile({ "{}" }, session_file)
        local session = make_child("child-resume", session_file)
        session.cwd = resolve(assigned_path)
        session._process_cwd = resolve(assigned_path)
        session.assigned_worktree = assigned

        local loaded
        -- Use the real wrapper (the spawn/revive fake above would skip the manager
        -- path this test exists to exercise).
        real.load_session_path(session, session_file, function(ok)
            loaded = ok
        end)
        assert.is_true(
            vim.wait(3000, function()
                return loaded ~= nil
            end, 10),
            "load_session must settle"
        )
        assert.is_true(loaded)
        assert.is_nil(session.worktree, "an assigned worktree must not become owned")
        assert.equals(resolve(assigned_path), session.assigned_worktree.path)
        assert.equals(0, worktree_env.calls.detect, "resume must skip rebind_resumed_worktree")
        assert.equals(0, worktree_env.calls.bind, "Worktree.bind must not see an assignment")
    end)

    it("binds an assigned child to its own transcript, not the owner workspace's", function()
        local assigned_file = assigned_path .. "/child-bind.jsonl"
        vim.fn.writefile({ "{}" }, assigned_file)
        local owner_file = workspace .. "/child-bind.jsonl"
        vim.fn.writefile({ "{}" }, owner_file)
        local child = make_child("child-bind", assigned_file)
        child.session_file = assigned_file
        child.cwd = resolve(assigned_path)
        child.manifest_cwd = workspace
        child.assigned_worktree = {
            kind = "linked",
            path = resolve(assigned_path),
            name = "assigned",
            repo_root = workspace,
            common_dir = workspace .. "/.git",
        }
        local current = make_parent("parent-bind")
        local chat = {
            bind_agent = function() end,
            set_subsession_breadcrumb = function() end,
        }
        local find_calls = {}
        Read.find_path = function(_, opts)
            find_calls[#find_calls + 1] = type(opts) == "table" and opts.cwd or nil
            return owner_file
        end
        local bound ---@type table?
        Sessions.reattach_view = function(session, cb)
            bound = session
            cb(true)
        end

        local ok
        Subsessions._bind_and_load(current, child, vim.api.nvim_get_current_tabpage(), chat, function(result)
            ok = result
        end)
        assert.is_true(ok)
        assert.equals(0, #find_calls, "a readable child.session_file needs no lookup")
        assert.equals(child, bound)

        -- Unreadable session_file: search the assigned worktree, never the
        -- owner workspace that may hold an unrelated transcript.
        child.session_file = assigned_path .. "/missing.jsonl"
        find_calls = {}
        Read.find_path = function(_, opts)
            local cwd = type(opts) == "table" and opts.cwd or nil
            find_calls[#find_calls + 1] = cwd
            return cwd == resolve(assigned_path) and assigned_file or owner_file
        end
        Subsessions._bind_and_load(current, child, vim.api.nvim_get_current_tabpage(), chat, function(result)
            ok = result
        end)
        assert.is_true(ok)
        assert.same({ resolve(assigned_path) }, find_calls)

        -- An ordinary child keeps the old lookup order (manifest workspace).
        local ordinary = make_child("child-ordinary", workspace .. "/missing.jsonl")
        ordinary.manifest_cwd = workspace
        find_calls = {}
        Read.find_path = function(_, opts)
            find_calls[#find_calls + 1] = type(opts) == "table" and opts.cwd or nil
            return owner_file
        end
        Subsessions._bind_and_load(current, ordinary, vim.api.nvim_get_current_tabpage(), chat, function(result)
            ok = result
        end)
        assert.is_true(ok)
        assert.same({ workspace }, find_calls)
    end)

    it("resolves a child transcript in its assigned worktree before the owner workspace", function()
        local legacy_path = make_dir(vim.fn.tempname() .. "-legacy-wt")
        local assigned_file = assigned_path .. "/child-resolve.jsonl"
        vim.fn.writefile({ "{}" }, assigned_file)
        local missing = workspace .. "/missing-transcript.jsonl"
        Manifest.upsert("child-resolve", {
            parent_id = "parent-lineage",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t0",
            last_active_at = "t0",
            run_generation = 1,
            session_file = missing,
            workspace = workspace,
            assigned_worktree = {
                kind = "linked",
                path = resolve(assigned_path),
                name = "assigned",
                repo_root = workspace,
                common_dir = workspace .. "/.git",
            },
            -- A stale legacy record must not win over the assignment.
            worktree = { kind = "linked", path = resolve(legacy_path), name = "legacy", repo_root = workspace },
        }, workspace)
        -- Deliberately registered under a different key: this is the revive
        -- id-migration window `resolve_child` exists for.
        local live = make_child("live-migrated", assigned_file)
        live.session_file = assigned_file
        live.parent_id = "parent-lineage"
        Sessions._register_for_test(live)

        local find_calls = {}
        Read.find_path = function(_, opts)
            local cwd = type(opts) == "table" and opts.cwd or nil
            find_calls[#find_calls + 1] = cwd
            return cwd == resolve(assigned_path) and assigned_file or nil
        end
        local stopped = Subsessions.close("child-resolve")
        assert.is_true(stopped)
        assert.same({ resolve(assigned_path) }, find_calls)
        assert.equals("dormant", Manifest.load(workspace)["child-resolve"].status)
        pcall(vim.fn.delete, legacy_path, "rf")
    end)

    describe("batch dispatch", function()
        ---@param parent table
        ---@param items table[]
        ---@return table batch snapshot
        local function dispatch(parent, items)
            local result
            Batch.dispatch(parent, { items = items }, function(res)
                result = res
            end)
            assert.is_not_nil(result, "dispatch must report synchronously")
            return result
        end

        it("returns the canonical assignment after a mixed batch launches", function()
            local parent = make_parent("parent-batch")
            local result = dispatch(parent, {
                { ref = "wt", task = "isolated", worktree = { path = assigned_path } },
                { ref = "plain", task = "parent" },
            })
            assert.is_string(result.batch_id, vim.inspect(result))
            assert.is_true(
                vim.wait(3000, function()
                    local snap = Batch.poll(result.batch_id, workspace)
                    return snap and snap.summary.running == 2
                end, 10),
                "both items must start"
            )
            local snap = Batch.poll(result.batch_id, workspace)
            local by_ref = {}
            for _, item in ipairs(snap.items) do
                by_ref[item.ref] = item
            end
            assert.equals(resolve(assigned_path), by_ref.wt.worktree.path)
            assert.equals("assigned", by_ref.wt.worktree.name)
            assert.is_nil(by_ref.plain.worktree, "an unassigned item reports no worktree")

            local manifest = Manifest.load(workspace)
            assert.equals(workspace, manifest[by_ref.wt.target].workspace)
            assert.equals(workspace, manifest[by_ref.plain.target].workspace)
            assert.equals(resolve(assigned_path), manifest[by_ref.wt.target].assigned_worktree.path)
            assert.is_nil(manifest[by_ref.plain.target].assigned_worktree)
            -- The batch is still owned by the parent workspace, never the worktree.
            assert.is_not_nil(Batch.get(result.batch_id, workspace))
            assert.is_nil(Batch.get(result.batch_id, neovim_cwd))
            Batch.cancel(result.batch_id, workspace)
        end)

        it("keeps a nested assigned parent's batch in the original manifest workspace", function()
            local parent = make_parent("parent-nested")
            parent.cwd = resolve(assigned_path)
            parent.manifest_cwd = workspace
            parent.parent_id = "grandparent-lineage"
            Sessions._register_for_test(parent)

            local result = dispatch(parent, { { ref = "nested", task = "nested work" } })
            assert.is_string(result.batch_id, vim.inspect(result))
            assert.is_not_nil(Batch.get(result.batch_id, workspace))
            assert.is_nil(Batch.get(result.batch_id, assigned_path), "the shared worktree holds no batch")
            assert.is_true(
                vim.wait(3000, function()
                    local snap = Batch.poll(result.batch_id, workspace)
                    return snap and snap.summary.running == 1
                end, 10),
                "the nested spawn must start"
            )

            local child = created[1].session
            assert.equals(
                resolve(assigned_path),
                created[1].opts.cwd,
                "an unassigned nested child inherits the assigned parent's actual cwd"
            )
            assert.equals(resolve(assigned_path), child.cwd)
            assert.equals(workspace, child.manifest_cwd, "bookkeeping stays in the owner workspace")
            assert.is_not_nil(Manifest.load(workspace)[child.id])
            assert.is_nil(Manifest.load(assigned_path)[child.id])

            -- poll/wait through the host bridge use Manifest.workspace(parent),
            -- so an assigned parent's nested batch stays discoverable.
            local polled
            Subsessions.handle_host(
                parent,
                vim.json.encode({ action = "poll_subagents", params = { batch_id = result.batch_id } }),
                function(r)
                    polled = r
                end
            )
            assert.is_not_nil(polled)
            assert.equals(result.batch_id, polled.batch_id)

            local entry = Manifest.load(workspace)[child.id]
            assert.equals(entry.run_generation, Batch.get(result.batch_id, workspace).items[1].generation)
            Subsessions.on_child_settled(child)
            local snap = Batch.poll(result.batch_id, workspace)
            assert.equals("completed", snap.status)
            assert.equals("ok", snap.items[1].status)
            assert.equals("completed", Manifest.load(workspace)[child.id].status)

            local waited
            Subsessions.handle_host(
                parent,
                vim.json.encode({
                    action = "wait_subagents",
                    params = { batch_id = result.batch_id, timeout_ms = 1000 },
                }),
                function(r)
                    waited = r
                end
            )
            assert.is_not_nil(waited, "a terminal nested batch must answer synchronously")
            assert.is_nil(waited.error, vim.inspect(waited))
            assert.equals("completed", waited.status)
        end)

        it("rejects worktree on a reuse item and still accepts plain spawn items", function()
            local parent = make_parent("parent-reuse")
            local result = dispatch(parent, {
                { target = "child-uuid", message = "continue", worktree = { path = assigned_path } },
            })
            assert.is_nil(result.batch_id)
            assert.is_truthy(result.error and result.error:find("`worktree`", 1, true))
            assert.is_nil(next(Batch.load(workspace)), "a rejected reuse item writes no batch")

            local accepted = dispatch(parent, { { task = "plain", worktree = { path = assigned_path } } })
            assert.is_string(accepted.batch_id, vim.inspect(accepted))
            Batch.cancel(accepted.batch_id, workspace)
        end)
    end)
end)
