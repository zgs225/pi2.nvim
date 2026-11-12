-- Sub-sessions run in the parent session's workspace cwd.
--
-- A spawned child never gets a checkout of its own: `Subsessions.spawn` starts
-- the process in the parent's workspace and calls nothing on `pi.worktree`.
-- The only recorded cwd a revive honours is the one an older version wrote on
-- the row: while that directory still exists the child keeps running there, and
-- once it is gone the child falls back to the parent's workspace with a single
-- warning. A revive never creates a checkout and never fails over a missing one.
--
-- Hermetic: `pi.worktree` is a recording fake installed in package.loaded, child
-- processes are fakes registered via _register_for_test, and the manifest is
-- redirected to a temp file. No git, no real pi process, no network.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Notify = require("pi.notify")
local Reaper = require("pi.subsessions.reaper")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")

local function repo_root()
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
end

---@param dir string
---@return string
local function make_dir(dir)
    vim.fn.mkdir(dir, "p")
    return dir
end

--- Fake `pi.worktree` module recording every call.
--- No call is expected any more; the recorder is what proves it.
---@class TestWorktreeRecorder
---@field calls table<string, table[]> Per-function call log.
---@field root string Temp dir standing in for the checkout root.

--- Install the recording fake and return it.
---@return TestWorktreeRecorder
local function install_fake_worktree()
    local env = { calls = { create = {}, detect = {}, bind = {}, release = {} } }
    env.root = make_dir(vim.fn.tempname() .. "-wt-root")

    local fake = {}

    ---@param opts table
    ---@param cb fun(info: table?, err: string?)
    function fake.create(opts, cb)
        env.calls.create[#env.calls.create + 1] = opts
        vim.schedule(function()
            cb({ kind = "linked", path = env.root .. "/" .. (opts.name or "wt"), name = opts.name, mode = opts.mode })
        end)
    end

    ---@param cwd string
    ---@return table?
    function fake.detect(cwd)
        env.calls.detect[#env.calls.detect + 1] = { cwd = cwd }
        return nil
    end

    ---@param info table
    ---@param meta table
    function fake.bind(info, meta)
        env.calls.bind[#env.calls.bind + 1] = { info = info, meta = meta }
    end

    ---@param info table
    ---@param cb? fun(ok: boolean)
    function fake.release(info, cb)
        env.calls.release[#env.calls.release + 1] = info
        if cb then
            cb(true)
        end
    end

    package.loaded["pi.worktree"] = fake
    return env
end

describe("sub-session cwd", function()
    local workspace ---@type string
    local checkout ---@type string
    local manifest_tmp ---@type string
    local env ---@type TestWorktreeRecorder
    local created ---@type table[]
    local warnings ---@type string[]
    local real = {}

    ---@param id string
    ---@return table
    local function make_child_session(id)
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
                    if cb then
                        vim.schedule(function()
                            cb({
                                success = true,
                                data = { sessionId = id, sessionFile = env.root .. "/" .. id .. ".jsonl" },
                            })
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
    ---@param cwd string
    ---@return table
    local function make_parent(id, cwd)
        return {
            id = id,
            conversation_epoch = 0,
            cwd = cwd,
            attached_tab = vim.api.nvim_get_current_tabpage(),
            rpc = {
                is_running = function()
                    return true
                end,
                send = function() end,
            },
        }
    end

    --- Seed a dormant row carrying a legacy checkout record.
    ---@param id string
    ---@param recorded_path string
    ---@return string session_file
    local function seed_row(id, recorded_path)
        local session_file = ("%s/%s.jsonl"):format(env.root, id)
        vim.fn.writefile({ "{}" }, session_file)
        Manifest.upsert(id, {
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
            session_file = session_file,
            worktree = { kind = "linked", path = recorded_path, name = "sub-legacy", repo_root = workspace },
            workspace = workspace,
        }, workspace)
        return session_file
    end

    before_each(function()
        workspace = make_dir(vim.fn.tempname() .. "-workspace")
        checkout = workspace .. "/.worktrees/sub-legacy"
        Config.setup({ subagent = { enabled = true, max_children = 5 } })
        real.worktree = package.loaded["pi.worktree"]
        env = install_fake_worktree()
        created = {}
        warnings = {}

        real.warn = Notify.warn
        Notify.warn = function(msg)
            warnings[#warnings + 1] = msg
        end

        -- Keep the real process/transcript plumbing out of the spec: the cwd a
        -- child is started in is what is under test.
        real.create_detached = Sessions.create_detached
        Sessions.create_detached = function(tab, opts)
            opts = opts or {}
            local id = "child-" .. (#created + 1)
            local session = make_child_session(id)
            session.cwd = opts.cwd
            session.worktree = opts.worktree
            created[#created + 1] = { tab = tab, opts = opts, session = session }
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

        manifest_tmp = vim.fn.tempname() .. "-manifest.json"
        real.manifest_path = Manifest.path
        Manifest._reset()
        Reaper._reset()
        Manifest.path = function()
            return manifest_tmp
        end
    end)

    after_each(function()
        Notify.warn = real.warn
        Sessions.create_detached = real.create_detached
        Sessions.load_session_path = real.load_session_path
        Manifest.path = real.manifest_path
        Manifest._reset()
        Reaper._reset()
        Sessions._reset()
        package.loaded["pi.worktree"] = real.worktree
        Config.setup({})
        os.remove(manifest_tmp)
        pcall(vim.fn.delete, workspace, "rf")
        pcall(vim.fn.delete, env.root, "rf")
    end)

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

    it("starts a spawned child in the parent's workspace cwd", function()
        local parent = make_parent("parent-1", workspace)

        local child, err = spawn_and_wait(parent)
        assert.is_nil(err)
        assert.is_not_nil(child)

        assert.equals(1, #created)
        assert.equals(workspace, created[1].opts.cwd, "the child process runs in the parent's workspace")
        assert.is_nil(created[1].opts.worktree, "the child owns no checkout")
        assert.is_nil(child.worktree)

        local entry = Manifest.load()[child.id]
        assert.is_not_nil(entry)
        assert.is_nil(entry.worktree, "a fresh row records no checkout")
        assert.equals(workspace, entry.workspace)
        assert.equals(0, #warnings)
    end)

    it("calls nothing on pi.worktree when spawning", function()
        local parent = make_parent("parent-2", workspace)

        local child, err = spawn_and_wait(parent)
        assert.is_nil(err)
        assert.is_not_nil(child)

        assert.equals(0, #env.calls.create, "no worktree may be created for a child")
        assert.equals(0, #env.calls.detect)
        assert.equals(0, #env.calls.bind)
        assert.equals(0, #env.calls.release)
    end)

    it("keeps a revived child in its recorded checkout while it exists", function()
        local recorded = make_dir(checkout)
        local session_file = seed_row("child-revive-keep", recorded)

        local revived, err = revive_and_wait("child-revive-keep")
        assert.is_nil(err)
        assert.is_not_nil(revived)

        -- A leftover checkout is a perfectly good workspace: the transcript
        -- records it as the child's cwd, so the revived process runs there.
        assert.equals(recorded, created[1].opts.cwd)
        assert.is_nil(created[1].opts.worktree)
        assert.equals(0, #env.calls.create, "a revive must never create a checkout")
        assert.equals(0, #warnings, "an existing recorded cwd is not a warning")
        assert.equals(session_file, created[1].session.session_file)

        local entry = Manifest.load()["child-revive-keep"]
        assert.equals("active", entry.status)
        assert.equals(recorded, entry.worktree.path, "the row keeps the checkout it runs in")
    end)

    it("falls back to the parent workspace when the recorded checkout is gone", function()
        assert.equals(0, vim.fn.isdirectory(checkout))
        seed_row("child-revive-gone", checkout)

        local revived, err = revive_and_wait("child-revive-gone")
        assert.is_nil(err)
        assert.is_not_nil(revived)

        assert.equals(workspace, created[1].opts.cwd, "a gone checkout falls back to the parent workspace")
        assert.is_nil(created[1].opts.worktree)
        assert.equals(0, #env.calls.create, "a revive must never recreate the checkout")
        assert.equals(1, #warnings, "the missing checkout warns exactly once")
        assert.is_truthy(warnings[1]:find(checkout, 1, true), "the warning names the missing checkout")

        local entry = Manifest.load()["child-revive-gone"]
        assert.equals("active", entry.status)
        assert.is_nil(entry.worktree, "a checkout that does not exist is no longer recorded")
        assert.equals(revived, Sessions.get_by_id("child-revive-gone"))
    end)

    it("keeps the child note byte-constant and free of worktree instructions", function()
        local path = repo_root() .. "/extensions/subagent-child.ts"
        local file = assert(io.open(path, "r"), "subagent-child.ts must exist at: " .. path)
        local content = file:read("*a")
        file:close()

        local note = content:match("const WORKER_NOTE%s*=%s*%[(.-)%]%.join")
        assert.is_not_nil(note, "WORKER_NOTE must be a [...].join(...) constant")
        assert.is_nil(note:find("${", 1, true), "WORKER_NOTE must not use template interpolation")
        assert.is_nil(note:find("`", 1, true), "WORKER_NOTE must not use template literals")
        assert.is_nil(content:find("WORKTREE_ENV", 1, true), "the worktree paragraph is gone")
        assert.is_nil(content:find("PI_NVIM_WORKTREE_PATH", 1, true), "the child note reads no worktree env")
        assert.is_truthy(
            content:find("${event.systemPrompt}\\n\\n${WORKER_NOTE}", 1, true),
            "the hook appends the constant note and nothing else"
        )
    end)
end)
