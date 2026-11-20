-- Sub-session cwd consistency: one authoritative workspace per chain.
--
-- The authoritative workspace for sub-session bookkeeping is the **owner parent
-- session's cwd** (the cwd the spawned pi process reports as `process.cwd()`),
-- which is not necessarily Neovim's cwd — a tab can run in a git-worktree
-- checkout. Covers:
--
--   1. dispatch → spawn → settle → wait with `parent.cwd ~= vim.fn.getcwd()`:
--      the manifest and batch rows land in the parent's workspace and settle
--      there, so `wait_subagents` wakes instead of answering "batch not found".
--   2. the settle path still finds the row when the child carries no workspace
--      hint (locate fallback) — the shape manager hooks have.
--   3. revive: runs the child in the parent workspace (never a checkout),
--      prefers the recorded transcript, and reuses an already-live process
--      instead of spawning a second one.
--   4. reaper/rebuild: sweep and rebuild cover each live session's workspace and
--      the manifests on disk, not just Neovim's cwd; a recorded `session_file`
--      beats the workspace id index.
--
-- Hermetic: temp agent dir, cwd switched to a second temp dir, fake RPC
-- processes, fake `pi.worktree`.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Batch = require("pi.subsessions.batch")
local Reaper = require("pi.subsessions.reaper")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")

Config.setup({})

---@param dir string
---@return string
local function make_dir(dir)
    vim.fn.mkdir(dir, "p")
    return assert(vim.uv.fs_realpath(dir))
end

---@param path string
---@return boolean
local function file_exists(path)
    return vim.fn.filereadable(path) == 1
end

--- Minimal running child process stand-in.
---@param id string
---@param session_file? string
---@return table
local function make_child(id, session_file)
    local state = { running = true }
    return {
        id = id,
        attention = { pending = {} },
        session_file = session_file,
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
                if cmd.type == "get_state" then
                    vim.schedule(function()
                        cb({ success = true, data = { sessionId = id, sessionFile = session_file } })
                    end)
                else
                    vim.schedule(function()
                        cb({ success = true })
                    end)
                end
                return true
            end,
        },
        _state = state,
    }
end

describe("sub-session workspace consistency", function()
    local agent_dir
    local parent_cwd
    local other_cwd
    local original_cwd
    local real = {}
    local created ---@type table[]
    local released ---@type table[]
    local closed ---@type string[]

    before_each(function()
        original_cwd = vim.fn.getcwd()
        agent_dir = make_dir(vim.fn.tempname() .. "-agent")
        parent_cwd = make_dir(vim.fn.tempname() .. "-parent-ws")
        other_cwd = make_dir(vim.fn.tempname() .. "-neovim-ws")
        Config.setup({
            agent_dir = agent_dir,
            subagent = { enabled = true, max_children = 5 },
        })
        vim.cmd("cd " .. vim.fn.fnameescape(other_cwd))
        Manifest._reset()
        Batch._reset()
        Sessions._reset()
        created = {}
        released = {}
        closed = {}

        real.create_detached = Sessions.create_detached
        Sessions.create_detached = function(_, opts)
            opts = opts or {}
            local id = "child-" .. (#created + 1)
            local session = make_child(id, ("%s/%s.jsonl"):format(parent_cwd, id))
            session.cwd = opts.cwd or parent_cwd
            session.worktree = opts.worktree
            created[#created + 1] = { session = session, opts = opts }
            Sessions._register_for_test(session)
            return session
        end

        real.close = Subsessions.close
        Subsessions.close = function(id, cb)
            closed[#closed + 1] = id
            if cb then
                cb(true)
            end
            return true
        end

        real.worktree = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            create = function(opts, cb)
                local path = ("%s/wt-%d"):format(parent_cwd, #created + 1)
                vim.fn.mkdir(path, "p")
                vim.schedule(function()
                    cb({
                        kind = "linked",
                        path = path,
                        name = opts.name,
                        repo_root = opts.cwd,
                        git_dir = path .. "/.git",
                        mode = opts.mode,
                    }, nil)
                end)
            end,
            detect = function()
                return nil
            end,
            release = function(info, cb)
                released[#released + 1] = info
                if cb then
                    cb(true)
                end
            end,
            bind = function() end,
        }
    end)

    after_each(function()
        Sessions.create_detached = real.create_detached
        Subsessions.close = real.close
        package.loaded["pi.worktree"] = real.worktree
        Reaper._reset()
        Sessions._reset()
        Manifest._reset()
        Batch._reset()
        Config.setup({})
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        for _, dir in ipairs({ agent_dir, parent_cwd, other_cwd }) do
            pcall(vim.fn.delete, dir, "rf")
        end
    end)

    ---@param id string
    ---@return table
    local function make_parent(id)
        return {
            id = id,
            conversation_epoch = 0,
            cwd = parent_cwd,
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

    --- Run a host-bridge action, capturing the result it reports.
    ---
    --- The bridge answers through `on_done` (dispatch/poll/list synchronously,
    --- wait asynchronously), so the result is captured rather than returned.
    ---@param parent table
    ---@param req table
    ---@return table? captured result (nil while an action is still pending)
    local function host(parent, req)
        local captured
        Subsessions.handle_host(parent, vim.json.encode(req), function(result)
            captured = result
        end)
        return captured
    end

    --- Spawn one dispatch item and wait until its child process exists.
    ---@param parent table
    ---@return string batch_id
    ---@return table child
    local function dispatch_one(parent)
        local result = host(parent, { action = "dispatch_subagents", params = { items = { { task = "do it" } } } })
        assert.is_not_nil(result, "dispatch must report its batch")
        assert.is_not_nil(result.batch_id, "dispatch must return a batch id: " .. vim.inspect(result))
        assert.is_true(
            vim.wait(3000, function()
                return #created == 1
            end, 10),
            "dispatch must spawn the child"
        )
        return result.batch_id, created[1].session
    end

    it("keeps manifest and batch rows in the parent workspace, not Neovim's cwd", function()
        local parent = make_parent("parent-ws")
        Sessions._register_for_test(parent)

        local batch_id, child = dispatch_one(parent)

        assert.is_true(file_exists(Batch.path(parent_cwd)), "batch file must live in the parent workspace")
        assert.is_false(file_exists(Batch.path(other_cwd)), "Neovim's cwd must stay untouched")
        local entry = Manifest.load(parent_cwd)[child.id]
        assert.is_not_nil(entry, "child row must live in the parent workspace manifest")
        assert.is_nil(Manifest.load(other_cwd)[child.id])
        assert.equals(parent_cwd, child.manifest_cwd, "bookkeeping follows the parent's workspace")
        -- The child runs in the parent's workspace cwd as well: no checkout of
        -- its own, so the manifest workspace is also the process cwd.
        assert.equals(parent_cwd, child.cwd)
        assert.equals(parent_cwd, created[1].opts.cwd)
        assert.is_nil(Batch.poll(batch_id), "the batch is invisible from Neovim's cwd by design")
    end)

    it("settles a dispatched child and wakes a waiter across workspaces", function()
        local parent = make_parent("parent-ws-2")
        Sessions._register_for_test(parent)

        local batch_id, child = dispatch_one(parent)
        assert.equals("running", Batch.poll(batch_id, parent_cwd).status)

        Subsessions.on_child_settled(child)

        local snap = Batch.poll(batch_id, parent_cwd)
        assert.equals("completed", snap.status)
        assert.equals("ok", snap.items[1].status)
        assert.equals("completed", Manifest.load(parent_cwd)[child.id].status)

        -- `wait_subagents` must resolve from the parent workspace (this is the
        -- "batch not found"/never-settles bug when parent.cwd differs). An
        -- already-terminal batch answers synchronously.
        local waited = host(parent, {
            action = "wait_subagents",
            params = { batch_id = batch_id, timeout_ms = 2000 },
        })
        assert.is_not_nil(waited, "an already-terminal batch must answer immediately")
        assert.is_nil(waited.error, "waiter must not report an error: " .. vim.inspect(waited))
        assert.equals("completed", waited.status)

        -- A waiter registered after the settle is woken from the same workspace.
        local late
        Batch.wait(batch_id, function(r)
            late = r
        end, { cwd = parent_cwd, timeout_ms = 2000 })
        assert.is_true(
            vim.wait(3000, function()
                return late ~= nil
            end, 10),
            "waiter must be woken"
        )
        assert.equals("completed", late.status)
    end)

    it("still settles when the child carries no workspace hint (locate fallback)", function()
        local parent = make_parent("parent-ws-3")
        Sessions._register_for_test(parent)

        local batch_id, child = dispatch_one(parent)
        -- Manager hooks hand over only the session object; drop every hint and
        -- let the locate fallback find the row in the parent's workspace.
        child.manifest_cwd = nil
        child.cwd = other_cwd

        Subsessions.on_child_settled(child)

        local snap = Batch.poll(batch_id, parent_cwd)
        assert.equals("completed", snap.status, "settle must find the row across workspaces")
        assert.equals("ok", snap.items[1].status)
    end)

    it("poll/list report the batch from the parent workspace", function()
        local parent = make_parent("parent-ws-4")
        Sessions._register_for_test(parent)
        local batch_id = dispatch_one(parent)

        local polled = assert(host(parent, { action = "poll_subagents", params = { batch_id = batch_id } }))
        assert.is_nil(polled.error, "poll must find the batch: " .. tostring(polled.error))

        local listed = assert(host(parent, { action = "list_batches", params = {} }))
        assert.equals(1, #listed.batches)
        assert.equals(batch_id, listed.batches[1].batch_id)
    end)
end)

describe("sub-session revive workspace handling", function()
    local agent_dir
    local parent_cwd
    local other_cwd
    local original_cwd
    local real = {}
    local created ---@type table[]

    before_each(function()
        original_cwd = vim.fn.getcwd()
        agent_dir = make_dir(vim.fn.tempname() .. "-agent")
        parent_cwd = make_dir(vim.fn.tempname() .. "-parent-ws")
        other_cwd = make_dir(vim.fn.tempname() .. "-neovim-ws")
        Config.setup({
            agent_dir = agent_dir,
            subagent = { enabled = true, max_children = 5 },
        })
        vim.cmd("cd " .. vim.fn.fnameescape(other_cwd))
        Manifest._reset()
        Batch._reset()
        Sessions._reset()
        created = {}

        real.create_detached = Sessions.create_detached
        Sessions.create_detached = function(_, opts)
            opts = opts or {}
            local id = "tmp-revive-" .. (#created + 1)
            local session = make_child(id, nil)
            session.cwd = opts.cwd or parent_cwd
            session.worktree = opts.worktree
            created[#created + 1] = { session = session, opts = opts }
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
    end)

    after_each(function()
        Sessions.create_detached = real.create_detached
        Sessions.load_session_path = real.load_session_path
        Reaper._reset()
        Sessions._reset()
        Manifest._reset()
        Batch._reset()
        Config.setup({})
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        for _, dir in ipairs({ agent_dir, parent_cwd, other_cwd }) do
            pcall(vim.fn.delete, dir, "rf")
        end
    end)

    --- A manifest row in the parent workspace plus a transcript on disk.
    ---@param id string
    ---@param worktree? table
    ---@return string session_file
    local function seed_child(id, worktree)
        local session_file = ("%s/%s.jsonl"):format(parent_cwd, id)
        vim.fn.writefile({ vim.json.encode({ type = "session", id = id, cwd = parent_cwd }) }, session_file)
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
            worktree = worktree,
            workspace = parent_cwd,
        }, parent_cwd)
        return session_file
    end

    ---@param fn fun(child: table?, err: string?)
    local function revive(id, fn)
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
        fn(child, err)
    end

    it("starts the revived child in the parent workspace and records its transcript", function()
        local session_file = seed_child("child-revive", { kind = "linked", path = parent_cwd .. "/gone-wt" })

        revive("child-revive", function(child, err)
            assert.is_nil(err)
            assert.is_not_nil(child)
        end)

        local entry = Manifest.load(parent_cwd)["child-revive"]
        assert.equals("active", entry.status)
        assert.equals(session_file, entry.session_file)
        -- A row recording a checkout that no longer exists falls back to the
        -- parent's workspace: no checkout is recreated for the child.
        assert.equals(parent_cwd, created[1].opts.cwd)
        assert.is_nil(created[1].opts.worktree)
        assert.is_nil(entry.worktree, "the vanished checkout is no longer recorded")
        assert.equals(parent_cwd, created[1].session.manifest_cwd)
    end)

    it("reuses an already-live process for the same id", function()
        local session_file = seed_child("child-live")
        local live = make_child("child-live", session_file)
        live.manifest_cwd = parent_cwd
        Sessions._register_for_test(live)

        local got
        Subsessions.revive("child-live", function(child)
            got = child
        end)

        assert.equals(live, got, "an already-live child must be reused, not respawned")
        assert.equals(0, #created, "no second process may be started")
        assert.equals("active", Manifest.load(parent_cwd)["child-live"].status)
    end)

    it("reads the row from the parent workspace even when Neovim is elsewhere", function()
        seed_child("child-elsewhere")

        revive("child-elsewhere", function(child, err)
            assert.is_nil(err)
            assert.is_not_nil(child)
        end)

        assert.equals(1, #created)
        assert.equals(parent_cwd, created[1].session.manifest_cwd)
        -- The row was resolved, not re-created in Neovim's cwd.
        assert.is_nil(Manifest.load(other_cwd)["child-elsewhere"])
    end)
end)

describe("sub-session reaper and rebuild across workspaces", function()
    local agent_dir
    local parent_cwd
    local other_cwd
    local original_cwd
    local real = {}
    local released ---@type table[]

    before_each(function()
        original_cwd = vim.fn.getcwd()
        agent_dir = make_dir(vim.fn.tempname() .. "-agent")
        parent_cwd = make_dir(vim.fn.tempname() .. "-parent-ws")
        other_cwd = make_dir(vim.fn.tempname() .. "-neovim-ws")
        Config.setup({
            agent_dir = agent_dir,
            subagent = { enabled = true, reap_after_minutes = 30, max_children = 5 },
        })
        vim.cmd("cd " .. vim.fn.fnameescape(other_cwd))
        Manifest._reset()
        Batch._reset()
        Sessions._reset()
        Reaper._reset()
        released = {}

        real.worktree = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            release = function(info, cb)
                released[#released + 1] = info
                if cb then
                    cb(true)
                end
            end,
        }
    end)

    after_each(function()
        package.loaded["pi.worktree"] = real.worktree
        Reaper._reset()
        Sessions._reset()
        Manifest._reset()
        Batch._reset()
        Config.setup({})
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        for _, dir in ipairs({ agent_dir, parent_cwd, other_cwd }) do
            pcall(vim.fn.delete, dir, "rf")
        end
    end)

    it("sweeps settled children of a workspace Neovim is not in", function()
        Manifest.upsert("child-sweep", {
            parent_id = "parent-lineage",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "t",
            config = {},
            status = "completed",
            reported = true,
            created_at = "2020-01-01T00:00:00Z",
            last_active_at = "2020-01-01T00:00:00Z",
            run_generation = 1,
        }, parent_cwd)

        local child = make_child("child-sweep", parent_cwd .. "/child-sweep.jsonl")
        child.parent_id = "parent-lineage"
        child.manifest_cwd = parent_cwd
        Sessions._register_for_test(child)

        local reaped = {}
        local saved_close = require("pi.subsessions").close
        require("pi.subsessions").close = function(id)
            reaped[#reaped + 1] = id
            return true
        end
        local ok, err = pcall(function()
            Reaper.sweep()
        end)
        require("pi.subsessions").close = saved_close
        assert.is_true(ok, tostring(err))

        assert.same({ "child-sweep" }, reaped, "the sweep must cover the parent workspace")
    end)

    it("releases orphaned worktrees of a workspace discovered on disk", function()
        local wt_path = parent_cwd .. "/child-wt"
        vim.fn.mkdir(wt_path, "p")
        Manifest.upsert("child-orphan", {
            parent_id = "parent-lineage",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "t",
            config = {},
            status = "completed",
            reported = true,
            created_at = "t0",
            last_active_at = "t0",
            run_generation = 1,
            worktree = { kind = "linked", path = wt_path, name = "child-wt", repo_root = parent_cwd },
        }, parent_cwd)
        -- Simulate a restart: no registry row claims the child.
        Sessions._reset()

        Reaper.sweep()

        assert.equals(1, #released)
        assert.equals(wt_path, released[1].path)
    end)

    it("rebuild prefers the recorded session_file over the workspace id index", function()
        -- Transcript lives in the parent workspace, not in any session dir the
        -- id index would cover, and its last entry is an assistant message.
        local transcript = ("%s/recorded-child.jsonl"):format(parent_cwd)
        local file = assert(io.open(transcript, "w"))
        file:write(vim.json.encode({ type = "session", id = "child-recorded", cwd = parent_cwd }) .. "\n")
        file:write(vim.json.encode({
            type = "message",
            message = { role = "assistant", content = { { type = "text", text = "done" } } },
        }) .. "\n")
        file:close()
        Manifest.upsert("child-recorded", {
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
            session_file = transcript,
        }, parent_cwd)

        Subsessions.rebuild_statuses()

        local entry = Manifest.load(parent_cwd)["child-recorded"]
        assert.equals("completed", entry.status, "the recorded transcript must be used, not marked dormant")
        assert.equals(tostring(os.date("!%Y-%m-%dT%H:%M:%SZ", vim.fn.getftime(transcript))), entry.last_active_at)
    end)

    it("rebuild reconciles a workspace Neovim is not in", function()
        Manifest.upsert("child-gone", {
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
        }, parent_cwd)

        Subsessions.rebuild_statuses()

        assert.equals("dormant", Manifest.load(parent_cwd)["child-gone"].status)
    end)
end)
