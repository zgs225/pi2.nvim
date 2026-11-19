-- Create / adopt / revive for sub-session checkouts.
--
-- A dispatch item's `worktree` has two modes:
--   * `{ path }`  — borrow an existing linked worktree (covered by
--                   tests/subagent_worktree_assignment_spec.lua),
--   * `{ create }` — create a checkout for the child, or adopt the one its
--                    `name` already resolves to.
--
-- This spec pins the create/adopt contract: the base strategy reaches
-- `Worktree.resolve_base`, creation happens in the parent's *repository* (never
-- in a parent that itself runs in a linked worktree), only a checkout this spawn
-- created is owned/releasable, an adopted name is never reset, base resolution
-- and creation failures leave no process and no manifest row, and a revive
-- recreates a vanished owned checkout in place.
--
-- Hermetic: fake `pi.worktree` (detect/resolve_base/create/release), fake
-- detached processes, temp agent dir. No git, no real pi process, no network.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Batch = require("pi.subsessions.batch")
local Read = require("pi.subsessions.read")
local Reaper = require("pi.subsessions.reaper")
local Notify = require("pi.notify")
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

describe("sub-session checkout create/adopt", function()
    local agent_dir ---@type string
    local workspace ---@type string
    local parent_wt ---@type string
    local original_cwd ---@type string
    local real = {}
    local created ---@type table[]
    local spawn_opts ---@type table[]
    local wt ---@type table
    local warnings ---@type string[]

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

    ---@param cwd string
    ---@param manifest_cwd? string
    ---@return table
    local function make_parent(cwd, manifest_cwd)
        return {
            id = "parent-1",
            conversation_epoch = 0,
            cwd = cwd,
            manifest_cwd = manifest_cwd,
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

    --- Install a recording fake `pi.worktree`.
    ---
    --- `create` behaves like the real one for the revive path: it materializes
    --- `<repo>/.worktrees/<name>` so a re-entered revive finds the directory.
    local function install_fake_worktree()
        wt = {
            calls = { create = {}, detect = 0, release = {}, base = {} },
            by_path = {},
            base_error = nil,
            create_error = nil,
            create_errors = {},
        }
        local fake = {}
        function fake.detect(path)
            wt.calls.detect = wt.calls.detect + 1
            return wt.by_path[resolve(path)]
        end
        function fake.validate_name(name)
            if type(name) ~= "string" or name == "" then
                return false, "worktree: name must be a string"
            end
            if not name:match("^[%w][%w._-]*$") then
                return false, "worktree: name may only contain letters, digits, '.', '_' and '-'"
            end
            return true, nil
        end
        function fake.resolve_base(opts, cb)
            wt.calls.base[#wt.calls.base + 1] = vim.deepcopy(opts)
            if wt.base_error then
                return cb(nil, wt.base_error)
            end
            cb("resolved-" .. tostring(opts.kind), nil)
        end
        function fake.create(opts, cb)
            wt.calls.create[#wt.calls.create + 1] = vim.deepcopy(opts)
            local queued = wt.create_errors[#wt.calls.create]
            if queued then
                return cb(nil, queued)
            end
            if wt.create_error then
                return cb(nil, wt.create_error)
            end
            local name = opts.name or "sub-generated"
            local target = opts.cwd .. "/.worktrees/" .. name
            vim.fn.mkdir(target, "p")
            local info = {
                kind = "linked",
                name = name,
                path = resolve(target),
                repo_root = opts.cwd,
                git_dir = opts.cwd .. "/.git/worktrees/" .. name,
                common_dir = opts.cwd .. "/.git",
                base_sha = opts.base,
                mode = opts.mode,
            }
            wt.by_path[info.path] = vim.tbl_extend("force", { owned = true }, info)
            cb(info, nil)
        end
        function fake.release(info, cb)
            wt.calls.release[#wt.calls.release + 1] = vim.deepcopy(info)
            if cb then
                cb(true)
            end
        end
        package.loaded["pi.worktree"] = fake
    end

    ---@param path string
    ---@param info table
    local function map_worktree(path, info)
        info = vim.tbl_extend("force", { path = resolve(path) }, info)
        wt.by_path[resolve(path)] = info
    end

    before_each(function()
        original_cwd = vim.fn.getcwd()
        agent_dir = make_dir(vim.fn.tempname() .. "-agent")
        workspace = make_dir(vim.fn.tempname() .. "-repo")
        parent_wt = make_dir(workspace .. "/.worktrees/parent")
        vim.fn.mkdir(workspace .. "/.git", "p")
        Config.setup({
            agent_dir = agent_dir,
            subagent = { enabled = true, max_children = 10, batch_timeout_ms = 2000 },
            worktree = {},
        })
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        Manifest._reset()
        Batch._reset()
        Reaper._reset()
        Sessions._reset()
        created = {}
        spawn_opts = {}
        warnings = {}

        real.worktree = package.loaded["pi.worktree"]
        real.warn = Notify.warn
        Notify.warn = function(msg)
            warnings[#warnings + 1] = tostring(msg)
        end
        install_fake_worktree()
        local common = workspace .. "/.git"
        map_worktree(workspace, {
            kind = "main",
            name = "repo",
            path = workspace,
            repo_root = workspace,
            git_dir = common,
            common_dir = common,
        })
        map_worktree(parent_wt, {
            kind = "linked",
            name = "parent",
            path = parent_wt,
            repo_root = workspace,
            git_dir = common .. "/worktrees/parent",
            common_dir = common,
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
            created[#created + 1] = { tab = tab, opts = opts, session = session }
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
        Notify.warn = real.warn
        package.loaded["pi.worktree"] = real.worktree
        Reaper._reset()
        Sessions._reset()
        Manifest._reset()
        Batch._reset()
        Config.setup({})
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        for _, dir in ipairs({ agent_dir, workspace }) do
            pcall(vim.fn.delete, dir, "rf")
        end
    end)

    ---@param opts table
    ---@return table? child
    ---@return string? err
    local function spawn_and_wait(opts)
        local child, err
        Subsessions.spawn(make_parent(parent_wt, workspace), opts, function(c, e)
            child, err = c, e
        end)
        assert.is_true(
            vim.wait(5000, function()
                return child ~= nil or err ~= nil
            end, 10),
            "spawn must settle"
        )
        return child, err
    end

    --- Child rows present in the parent's manifest workspace.
    ---
    --- `__lineage__` bookkeeping is written by every spawn attempt and is not a
    --- child row, so failures are asserted on real rows only.
    ---@return string[]
    local function child_rows()
        local ids = {}
        for id in pairs(Manifest.load(workspace)) do
            if type(id) == "string" and not id:match("^__") then
                ids[#ids + 1] = id
            end
        end
        return ids
    end

    describe("create", function()
        it("creates in the parent's repository at the parent HEAD and runs the child there", function()
            local child, err = spawn_and_wait({ task = "work", worktree = { create = true } })
            assert.is_nil(err)
            assert.is_not_nil(child)

            -- `head` is the strategy default; it is resolved from the parent's
            -- checkout (the linked worktree), ...
            assert.are.equal(1, #wt.calls.base)
            assert.are.equal("head", wt.calls.base[1].kind)
            assert.are.equal(parent_wt, wt.calls.base[1].cwd)
            assert.are.equal(workspace, wt.calls.base[1].repo)

            -- ... while creation never nests inside that checkout.
            assert.are.equal(1, #wt.calls.create)
            local create = wt.calls.create[1]
            assert.are.equal(workspace, create.cwd)
            assert.are.equal("subagent", create.mode)
            assert.are.equal("resolved-head", create.base)
            assert.is_false(create.setup, "setup_cmd is opt-in for child checkouts")
            assert.is_nil(create.name, "the generated sub-… name is the worktree module's job")

            local expected = resolve(workspace .. "/.worktrees/sub-generated")
            assert.are.equal(expected, child.cwd)
            assert.is_true(child.worktree.owned == true, "a created checkout is owned")
            assert.is_nil(child.assigned_worktree, "an owned checkout is not recorded as an assignment")

            local entry = Manifest.load(workspace)[child.id]
            assert.is_not_nil(entry)
            assert.is_true(entry.worktree.owned == true, "the row records ownership")
            assert.is_nil(entry.assigned_worktree, "the row records no assignment")
            assert.are.equal("resolved-head", entry.worktree.base_sha)
        end)

        it("passes an explicit base and an explicit setup opt-in through", function()
            local _, err = spawn_and_wait({
                task = "work",
                worktree = { create = { base = "origin/main", setup = true } },
            })
            assert.is_nil(err)
            assert.are.equal("origin/main", wt.calls.base[1].kind)
            assert.is_true(wt.calls.create[1].setup)
        end)

        it("uses worktree.base_ref = fresh when the item asks for no specific base", function()
            Config.setup({
                agent_dir = agent_dir,
                subagent = { enabled = true, max_children = 10, batch_timeout_ms = 2000 },
                worktree = { base_ref = "fresh" },
            })
            local _, err = spawn_and_wait({ task = "work", worktree = { create = true } })
            assert.is_nil(err)
            assert.are.equal("fresh", wt.calls.base[1].kind)
        end)

        it("records a borrowed path as an assignment, never as owned", function()
            local _, _ = spawn_and_wait({ task = "work", worktree = { path = parent_wt } })
            assert.are.equal(0, #wt.calls.create, "borrowing must never create")
            assert.is_true(created[1].opts.worktree == nil)
            assert.is_not_nil(created[1].opts.assigned_worktree)
        end)

        it("fails without creating anything when the base cannot be resolved", function()
            wt.base_error = "create: invalid base commit: nope"
            local child, err = spawn_and_wait({ task = "work", worktree = { create = { base = "nope" } } })
            assert.is_nil(child)
            assert.are.equal("create: invalid base commit: nope", err)
            assert.are.equal(0, #wt.calls.create)
            assert.are.equal(0, #created)
            assert.is_nil(child_rows()[1])
        end)

        it("fails without a process or row when creation itself fails", function()
            wt.create_error = "create: refusing to create a worktree inside .worktrees"
            local child, err = spawn_and_wait({ task = "work", worktree = { create = true } })
            assert.is_nil(child)
            assert.is_truthy(err:find("refusing to create", 1, true), err)
            assert.are.equal(0, #created)
            assert.is_nil(child_rows()[1])
        end)
    end)

    describe("adopt by name", function()
        local shared ---@type string

        before_each(function()
            shared = make_dir(workspace .. "/.worktrees/shared")
            map_worktree(shared, {
                kind = "linked",
                name = "shared",
                path = shared,
                repo_root = workspace,
                git_dir = workspace .. "/.git/worktrees/shared",
                common_dir = workspace .. "/.git",
                base_sha = "earlier-sha",
            })
        end)

        it("reuses an existing checkout of the same repository instead of creating", function()
            local child, err = spawn_and_wait({
                task = "work",
                worktree = { create = { name = "shared", base = "head" } },
            })
            assert.is_nil(err)
            assert.is_not_nil(child)
            assert.are.equal(0, #wt.calls.create, "an existing name must never be created again")
            assert.are.equal(0, #wt.calls.base, "no base is resolved for an adopted checkout")
            assert.are.equal(shared, child.cwd)
            assert.is_nil(child.worktree, "an adopted checkout is not owned")
            assert.is_true(child.assigned_worktree.reused == true)
            assert.is_true(child.assigned_worktree.base_ignored == true)

            local entry = Manifest.load(workspace)[child.id]
            assert.is_true(entry.assigned_worktree.reused == true)
            assert.is_nil(entry.worktree)
            assert.is_truthy(
                table.concat(warnings, "\n"):find("already exists", 1, true),
                "an ignored base must be reported, not silent"
            )
        end)

        it("keeps the checkout untouched: no reset, no bind, no release on close", function()
            local child = assert(spawn_and_wait({ task = "work", worktree = { create = { name = "shared" } } }))
            assert.is_not_nil(child)
            assert.are.equal(0, #wt.calls.release)
            assert.are.equal("earlier-sha", wt.by_path[shared].base_sha)
        end)

        it("rejects a directory that is not a linked worktree of this repository", function()
            local plain = make_dir(workspace .. "/.worktrees/plain")
            local child, err = spawn_and_wait({ task = "work", worktree = { create = { name = "plain" } } })
            assert.is_nil(child)
            assert.is_truthy(err:find("not a git worktree", 1, true), err)
            assert.are.equal(0, #wt.calls.create)
            assert.are.equal(0, #created)
            assert.is_true(vim.fn.isdirectory(plain) == 1, "the foreign directory must be left alone")
        end)
    end)

    describe("request validation", function()
        it("rejects path and create together", function()
            local child, err = spawn_and_wait({
                task = "work",
                worktree = { path = parent_wt, create = true },
            })
            assert.is_nil(child)
            assert.is_truthy(err:find("not both", 1, true), err)
            assert.are.equal(0, #created)
        end)

        it("rejects an empty request and a non-boolean setup", function()
            local child, err = spawn_and_wait({ task = "work", worktree = {} })
            assert.is_nil(child)
            assert.is_truthy(err:find("`path`", 1, true), err)

            local child2, err2 = spawn_and_wait({
                task = "work",
                worktree = { create = { setup = "yes" } },
            })
            assert.is_nil(child2)
            assert.is_truthy(err2:find("setup must be a boolean", 1, true), err2)
            assert.are.equal(0, #created)
        end)

        it("reads `create = false` as no worktree at all", function()
            local child, err = spawn_and_wait({ task = "work", worktree = { create = false } })
            assert.is_nil(err)
            assert.is_not_nil(child)
            assert.are.equal(parent_wt, child.cwd, "the child runs in the parent cwd")
            assert.are.equal(0, #wt.calls.create)
        end)
    end)

    describe("ownership on release", function()
        ---@param id string
        ---@param patch table
        ---@return string session_file
        local function seed_row(id, patch)
            local file = workspace .. "/" .. id .. ".jsonl"
            vim.fn.writefile({ vim.json.encode({ type = "session", id = id }) }, file)
            Manifest.upsert(
                id,
                vim.tbl_extend("force", {
                    parent_id = "parent-lineage",
                    parent_epoch = 0,
                    name = "worker",
                    task_prompt = "t",
                    config = {},
                    status = "dormant",
                    reported = false,
                    created_at = "t0",
                    last_active_at = "t0",
                    run_generation = 1,
                    session_file = file,
                    workspace = workspace,
                }, patch),
                workspace
            )
            return file
        end

        it("releases an owned checkout but never an adopted one", function()
            local owned_path = make_dir(workspace .. "/.worktrees/owned")
            local adopted_path = make_dir(workspace .. "/.worktrees/adopted")
            seed_row("child-owned", { worktree = { path = owned_path, name = "owned", owned = true } })
            seed_row("child-adopted", { assigned_worktree = { path = adopted_path, name = "adopted", reused = true } })

            assert.is_true(Subsessions.release_worktree("child-owned"))
            assert.is_false(Subsessions.release_worktree("child-adopted"))
            assert.are.equal(1, #wt.calls.release)
            assert.are.equal(owned_path, wt.calls.release[1].path)
        end)
    end)

    describe("revive", function()
        local recorded_path ---@type string

        before_each(function()
            recorded_path = workspace .. "/.worktrees/sub-revived"
        end)

        ---@param id string
        ---@param patch table
        ---@return string session_file
        local function seed_owned_row(id, patch)
            local file = workspace .. "/" .. id .. ".jsonl"
            vim.fn.writefile({ vim.json.encode({ type = "session", id = id, cwd = recorded_path }) }, file)
            Manifest.upsert(
                id,
                vim.tbl_extend("force", {
                    parent_id = "parent-lineage",
                    parent_epoch = 0,
                    name = "worker",
                    task_prompt = "t",
                    config = {},
                    status = "dormant",
                    reported = false,
                    created_at = "t0",
                    last_active_at = "t0",
                    run_generation = 1,
                    session_file = file,
                    workspace = workspace,
                    worktree = {
                        path = recorded_path,
                        name = "sub-revived",
                        repo_root = workspace,
                        base_sha = "recorded-sha",
                        owned = true,
                    },
                }, patch or {}),
                workspace
            )
            return file
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
                vim.wait(5000, function()
                    return child ~= nil or err ~= nil
                end, 10),
                "revive must settle"
            )
            return child, err
        end

        it("recreates a vanished owned checkout in place at its recorded base", function()
            seed_owned_row("child-x")
            local child, err = revive_and_wait("child-x")
            assert.is_nil(err)
            assert.is_not_nil(child)
            assert.are.equal(1, #wt.calls.create, "the checkout must be recreated once")
            assert.are.equal(workspace, wt.calls.create[1].cwd)
            assert.are.equal("sub-revived", wt.calls.create[1].name)
            assert.are.equal("recorded-sha", wt.calls.create[1].base)
            assert.are.equal(resolve(recorded_path), child.cwd)
            assert.is_true(child.worktree.owned == true, "the revived session keeps the checkout owned")
            local entry = Manifest.load(workspace)["child-x"]
            assert.is_true(entry.worktree.owned == true, "a recreated checkout stays owned")
        end)

        it("retries at HEAD when the recorded base no longer resolves", function()
            wt.create_errors = { [1] = "create: invalid base commit: recorded-sha" }
            seed_owned_row("child-y")
            local child, err = revive_and_wait("child-y")
            assert.is_nil(err)
            assert.is_not_nil(child)
            assert.are.equal(2, #wt.calls.create, "one retry at HEAD")
            assert.are.equal("recorded-sha", wt.calls.create[1].base)
            assert.is_nil(wt.calls.create[2].base)
            assert.are.equal(resolve(recorded_path), child.cwd)
        end)

        it("falls back to the parent workspace when the checkout cannot come back", function()
            wt.create_error = "create: not a git repository: /gone"
            seed_owned_row("child-z")
            local child, err = revive_and_wait("child-z")
            assert.is_nil(err, "a revive never fails over a missing owned checkout")
            assert.is_not_nil(child)
            assert.are.equal(workspace, child.cwd)
            assert.is_truthy(
                table.concat(warnings, "\n"):find("could not be recreated", 1, true),
                "the fallback must be reported once"
            )
            local entry = Manifest.load(workspace)["child-z"]
            assert.is_nil(entry.worktree, "the dead record is dropped instead of retried forever")
        end)

        it("never recreates an assigned checkout: a missing one stays a hard error", function()
            local missing = workspace .. "/.worktrees/adopted-gone"
            Manifest.upsert("child-a", {
                parent_id = "parent-lineage",
                parent_epoch = 0,
                name = "adopted",
                task_prompt = "t",
                config = {},
                status = "dormant",
                reported = false,
                created_at = "t0",
                last_active_at = "t0",
                run_generation = 1,
                workspace = workspace,
                assigned_worktree = { path = missing, name = "adopted-gone", reused = true },
            }, workspace)
            local child, err = revive_and_wait("child-a")
            assert.is_nil(child)
            assert.is_truthy(err:find("not an existing directory", 1, true), err)
            assert.are.equal(0, #wt.calls.create, "an assigned checkout is never recreated")
        end)
    end)
end)
