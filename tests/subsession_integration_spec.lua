-- Sub-session ⟷ worktree-integration wiring.
--
-- The integration engine (`pi.worktree_integration`) turns a settled child's
-- checkout into parent changes. The sub-session layer must:
--   * hand the settle to the engine **before** batch accounting / waiter wake-up,
--     so a parent blocked in `wait_subagents` gets the applied/queued state;
--   * never auto-integrate an aborted run;
--   * keep close/reap/release away from a checkout the engine owns;
--   * persist the run generation (spawn = 1, every revive bumps) so a stale
--     apply/cleanup can be rejected;
--   * reconcile + enforce retention after a rebuild, and keep integration
--     records across a resume.
--
-- Hermetic: fake `pi.worktree_integration` + fake `pi.worktree`, temp agent dir,
-- fake RPC processes. No git, no real pi process.

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

--- Fake integration engine with recorded calls and per-child behaviour.
---@class TestIntegration
local function make_engine()
    local engine = {
        calls = {},
        settlement = {}, ---@type table<string, string>
        records = {}, ---@type table<string, table>
        order = {},
        parent_ready = 0,
        children = {},
        fail_settle = false,
        async = true,
        no_record = false,
    }

    ---@param child table
    ---@param entry table
    ---@param cwd string
    ---@param done fun(state: string?, record: table?)
    function engine.on_child_settled(child, entry, cwd, done)
        engine.children[#engine.children + 1] = {
            child = child,
            entry = entry,
            cwd = cwd,
            -- The batch accounting must not have run yet: the item is still
            -- "running" here, which is exactly the ordering guarantee.
            item_status = engine.observe_item and engine.observe_item() or nil,
        }
        if engine.fail_settle then
            error("engine exploded")
        end
        local state = engine.settlement[child.id] or "applied"
        local record = engine.records[child.id]
        if record == nil and not engine.no_record then
            record = { state = state, files = { "src/" .. child.id .. ".lua" }, patch_sha = "sha-" .. child.id }
        end
        if engine.async then
            vim.schedule(function()
                done(state, record)
            end)
        else
            done(state, record)
        end
    end

    function engine.on_parent_ready()
        engine.parent_ready = engine.parent_ready + 1
    end

    function engine.reconcile(done)
        engine.order[#engine.order + 1] = "reconcile"
        if done then
            done()
        end
    end

    function engine.enforce_retention()
        engine.order[#engine.order + 1] = "enforce_retention"
        engine.retention_calls = (engine.retention_calls or 0) + 1
    end

    return engine
end

describe("sub-session integration wiring", function()
    local agent_dir
    local parent_cwd
    local other_cwd
    local original_cwd
    local real = {}
    local engine
    local created ---@type table[]
    local released ---@type table[]

    before_each(function()
        original_cwd = vim.fn.getcwd()
        agent_dir = make_dir(vim.fn.tempname() .. "-agent")
        parent_cwd = make_dir(vim.fn.tempname() .. "-parent-ws")
        other_cwd = make_dir(vim.fn.tempname() .. "-neovim-ws")
        Config.setup({
            agent_dir = agent_dir,
            subagent = { enabled = true, max_children = 5, reap_after_minutes = 30 },
            worktree = { integration = { auto = true } },
        })
        vim.cmd("cd " .. vim.fn.fnameescape(other_cwd))
        Manifest._reset()
        Batch._reset()
        Reaper._reset()
        Sessions._reset()
        created = {}
        released = {}
        engine = make_engine()

        real.create_detached = Sessions.create_detached
        Sessions.create_detached = function(_, opts)
            opts = opts or {}
            local id = "child-" .. (#created + 1)
            local state = { running = true }
            local session = {
                id = id,
                attention = { pending = {} },
                cwd = opts.cwd or parent_cwd,
                session_file = ("%s/%s.jsonl"):format(parent_cwd, id),
                worktree = opts.worktree,
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
                                cb({
                                    success = true,
                                    data = { sessionId = id, sessionFile = ("%s/%s.jsonl"):format(parent_cwd, id) },
                                })
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

        real.worktree = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            create = function(opts, cb)
                local path = ("%s/wt-%d"):format(parent_cwd, #created + 1)
                vim.fn.mkdir(path, "p")
                vim.schedule(function()
                    cb({ kind = "linked", path = path, name = opts.name, repo_root = opts.cwd }, nil)
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

        real.engine = package.loaded["pi.worktree_integration"]
        package.loaded["pi.worktree_integration"] = engine
    end)

    after_each(function()
        Sessions.create_detached = real.create_detached
        Sessions.load_session_path = real.load_session_path
        package.loaded["pi.worktree"] = real.worktree
        package.loaded["pi.worktree_integration"] = real.engine
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

    ---@param parent table
    ---@param req table
    ---@param cb? fun(result: table)
    local function host(parent, req, cb)
        Subsessions.handle_host(parent, vim.json.encode(req), cb)
    end

    --- Dispatch one spawn item and wait until its child process exists.
    ---@param parent table
    ---@param cb? fun(result: table)
    ---@return string batch_id
    ---@return table child
    local function dispatch_one(parent, cb)
        local result
        host(parent, { action = "dispatch_subagents", params = { items = { { task = "do it" } } } }, function(r)
            result = r
            if cb then
                cb(r)
            end
        end)
        assert.is_not_nil(result, "dispatch must report its batch")
        assert.is_not_nil(result.batch_id, vim.inspect(result))
        assert.is_true(
            vim.wait(3000, function()
                return #created == 1
            end, 10),
            "dispatch must spawn the child"
        )
        return result.batch_id, created[1].session
    end

    --- Wait for `predicate` with a generous test timeout.
    ---@param predicate fun(): boolean
    ---@param message string
    local function wait_for(predicate, message)
        assert.is_true(vim.wait(3000, predicate, 10), message)
    end

    it("hands the settle to the engine before the batch accounting", function()
        local parent = make_parent("parent-integration-1")
        Sessions._register_for_test(parent)
        local batch_id, child = dispatch_one(parent)
        engine.observe_item = function()
            local snap = Batch.poll(batch_id, parent_cwd)
            return snap and snap.items[1] and snap.items[1].status
        end

        Subsessions.on_child_settled(child)

        wait_for(function()
            local snap = Batch.poll(batch_id, parent_cwd)
            return snap and snap.status == "completed"
        end, "settle must complete the batch")

        assert.equals(1, #engine.children)
        assert.equals("running", engine.children[1].item_status, "the engine must run before the batch settle")
        assert.equals(parent_cwd, engine.children[1].cwd)
        assert.equals("child-1", engine.children[1].child.id)

        local snap = Batch.poll(batch_id, parent_cwd)
        assert.equals("ok", snap.items[1].status)
        assert.equals("applied", snap.items[1].integration.state)
        assert.same({ "src/child-1.lua" }, snap.items[1].integration.files)
        assert.equals(1, snap.integration.applied)
        assert.same({ "src/child-1.lua" }, snap.integration.files)
        assert.equals("applied", Manifest.load(parent_cwd)["child-1"].integration.state)
    end)

    it("reports an applied state to a parent blocked in wait_subagents", function()
        local parent = make_parent("parent-integration-2")
        Sessions._register_for_test(parent)
        local batch_id, child = dispatch_one(parent)

        local waited
        local result
        host(parent, {
            action = "wait_subagents",
            params = { batch_id = batch_id, timeout_ms = 5000 },
        }, function(r)
            result = r
        end)
        assert.is_true(Subsessions.parent_waiting(parent), "the parent must be marked as waiting")

        Subsessions.on_child_settled(child)

        wait_for(function()
            return result ~= nil
        end, "wait must resolve after the settle")
        waited = result
        assert.is_nil(waited.error, vim.inspect(waited))
        assert.equals("completed", waited.status)
        assert.equals("applied", waited.items[1].integration.state)
        assert.equals(1, waited.integration.applied)
        assert.is_false(Subsessions.parent_waiting(parent), "the waiting marker must be cleared")
    end)

    it("keeps a queued state on the item and protects the checkout", function()
        local parent = make_parent("parent-integration-3")
        Sessions._register_for_test(parent)
        local batch_id, child = dispatch_one(parent)
        engine.settlement["child-1"] = "queued"
        engine.records["child-1"] = {
            state = "queued",
            reason = "parent_busy",
            files = { "src/queued.lua" },
        }

        Subsessions.on_child_settled(child)

        wait_for(function()
            local snap = Batch.poll(batch_id, parent_cwd)
            return snap and snap.status == "completed"
        end, "settle must complete even when the integration is queued")

        local snap = Batch.poll(batch_id, parent_cwd)
        assert.equals("queued", snap.items[1].integration.state)
        assert.equals(1, snap.integration.queued)
        assert.equals("queued", Manifest.load(parent_cwd)["child-1"].integration.state)

        -- The engine owns the checkout while queued: no reap, no close.
        assert.is_false(Reaper.reap("child-1", parent_cwd), "a queued integration must not be reaped")
        assert.is_false(Subsessions.close("child-1"), "a queued integration must not be closed")
        assert.are_not.equal(
            "dormant",
            Manifest.load(parent_cwd)["child-1"].status,
            "a refused close must not drop the row to dormant"
        )

        -- Applied rows are the retention engine's business, not the orphan
        -- backstop's (a direct release would refuse a dirty checkout forever).
        engine.records["child-1"] = { state = "applied", files = { "src/queued.lua" } }
        Manifest.patch("child-1", { status = "completed", integration = engine.records["child-1"] }, parent_cwd)
        child._state.running = false
        assert.equals(0, Reaper.release_orphaned_worktrees(parent_cwd))
        assert.equals(0, #released)
    end)

    it("never auto-integrates an aborted run", function()
        local parent = make_parent("parent-integration-4")
        Sessions._register_for_test(parent)
        local batch_id, child = dispatch_one(parent)

        Subsessions.on_child_settled(child, true)

        wait_for(function()
            local snap = Batch.poll(batch_id, parent_cwd)
            return snap and snap.status == "cancelled"
        end, "aborted settle must cancel the item")

        assert.equals(0, #engine.children, "an aborted run must not reach the engine")
        local snap = Batch.poll(batch_id, parent_cwd)
        assert.equals("cancelled", snap.items[1].status)
        assert.equals("skipped", snap.items[1].integration.state)
        assert.equals(1, snap.integration.skipped)
        assert.is_nil(Manifest.load(parent_cwd)["child-1"].integration, "an aborted run keeps no integration record")
        assert.equals("interrupted", Manifest.load(parent_cwd)["child-1"].status)
    end)

    it("drops engine outcome codes that are not persisted states", function()
        local parent = make_parent("parent-integration-9")
        Sessions._register_for_test(parent)
        local batch_id, child = dispatch_one(parent)
        -- Real engine outcomes like "skipped" (empty patch) / "no_worktree" carry
        -- no record: they must not leave an integration row behind, or the
        -- checkout would be treated as engine-owned forever.
        engine.settlement["child-1"] = "skipped"
        engine.no_record = true

        Subsessions.on_child_settled(child)

        wait_for(function()
            local snap = Batch.poll(batch_id, parent_cwd)
            return snap and snap.status == "completed"
        end, "the settle must complete")
        local snap = Batch.poll(batch_id, parent_cwd)
        assert.is_nil(snap.items[1].integration)
        assert.equals(0, snap.integration.skipped, "no state was recorded, so none is counted")
        assert.is_nil(Manifest.load(parent_cwd)["child-1"].integration)
    end)

    it("never auto-integrates a failed run", function()
        local parent = make_parent("parent-integration-11")
        Sessions._register_for_test(parent)
        local batch_id, child = dispatch_one(parent)
        -- What the manager's `_process_exit` path does before settling a crash.
        Manifest.patch(child.id, { status = "failed" }, parent_cwd)

        Subsessions.on_child_settled(child)

        wait_for(function()
            local snap = Batch.poll(batch_id, parent_cwd)
            return snap and snap.status ~= "running"
        end, "a failed settle must still settle the batch")

        assert.equals(0, #engine.children, "a failed/crashed run must not reach the engine")
        local snap = Batch.poll(batch_id, parent_cwd)
        assert.equals("failed", snap.items[1].status)
        assert.is_nil(snap.items[1].integration, "no integration state may be reported for a failed run")

        local row = Manifest.load(parent_cwd)[child.id]
        assert.equals("failed", row.status, "a failed run must stay failed, not be flipped to completed")
        assert.is_nil(row.integration, "a half-finished checkout must never be recorded as applied")
        -- A child owns no checkout any more: it ran in the parent's workspace, so
        -- there is nothing to keep or release for diagnosis.
        assert.is_nil(child.worktree)
        assert.equals(parent_cwd, child.cwd)
    end)

    it("degrades to needs_attention when the engine raises", function()
        local parent = make_parent("parent-integration-5")
        Sessions._register_for_test(parent)
        local batch_id, child = dispatch_one(parent)
        engine.fail_settle = true

        Subsessions.on_child_settled(child)

        wait_for(function()
            local snap = Batch.poll(batch_id, parent_cwd)
            return snap and snap.status == "completed"
        end, "an engine failure must not block the settle")

        local snap = Batch.poll(batch_id, parent_cwd)
        assert.equals("needs_attention", snap.items[1].integration.state)
        assert.is_truthy(tostring(snap.items[1].integration.error):find("engine exploded", 1, true))
    end)

    it("marks the parent waiting and drives the engine, clearing on timeout", function()
        local parent = make_parent("parent-integration-6")
        Sessions._register_for_test(parent)
        local batch_id = dispatch_one(parent)

        local result
        host(parent, { action = "wait_subagents", params = { batch_id = batch_id, timeout_ms = 50 } }, function(r)
            result = r
        end)

        local seen_marker = false
        local seen_batch_waiting = false
        assert.is_true(
            vim.wait(3000, function()
                if Subsessions.parent_waiting(parent) then
                    seen_marker = true
                end
                if Batch.is_waiting(parent_cwd, "parent-integration-6") then
                    seen_batch_waiting = true
                end
                return result ~= nil
            end, 10),
            "the wait must time out"
        )

        assert.is_true(seen_marker, "the parent waiting marker must be visible while blocked")
        assert.is_true(seen_batch_waiting, "Batch.is_waiting must report the blocked lineage")
        assert.is_truthy(tostring(result.error):find("timeout", 1, true))
        assert.is_false(Subsessions.parent_waiting(parent), "the marker must be cleared on timeout")
        assert.is_false(Batch.is_waiting(parent_cwd, "parent-integration-6"), "the waiter must be gone")
        assert.is_true(engine.parent_ready >= 2, "on_parent_ready must drive the queue on both edges")
    end)

    it("drives the queue and marks the parent for dispatch(wait = true)", function()
        local parent = make_parent("parent-integration-10")
        Sessions._register_for_test(parent)

        local result
        host(parent, {
            action = "dispatch_subagents",
            params = { items = { { task = "go" } }, wait = true, timeout_ms = 5000 },
        }, function(r)
            result = r
        end)
        assert.is_true(Subsessions.parent_waiting(parent), "dispatch(wait = true) must mark the parent")

        wait_for(function()
            return #created == 1
        end, "dispatch must spawn the child")
        Subsessions.on_child_settled(created[1].session)

        wait_for(function()
            return result ~= nil
        end, "the blocking dispatch must resolve")
        assert.equals("completed", result.status)
        assert.equals("applied", result.items[1].integration.state)
        assert.is_false(Subsessions.parent_waiting(parent), "the marker must be cleared")
        assert.is_true(engine.parent_ready >= 2, "both wait edges must drive the queue")
    end)

    it("persists the run generation and bumps it on every revive", function()
        local parent = make_parent("parent-integration-7")
        Sessions._register_for_test(parent)

        local child, err
        Subsessions.spawn(parent, { task = "work" }, function(c, e)
            child, err = c, e
        end)
        wait_for(function()
            return child ~= nil or err ~= nil
        end, "spawn must settle")
        assert.is_nil(err)
        assert.equals(1, Manifest.load(parent_cwd)["child-1"].run_generation)
        assert.equals(1, child.run_generation)

        Subsessions.close("child-1")
        child._state.running = false
        -- The backend-reported transcript is what a revive loads.
        vim.fn.writefile({ vim.json.encode({ type = "session", id = "child-1" }) }, child.session_file)

        local revived, revive_err
        Subsessions.revive("child-1", function(c, e)
            revived, revive_err = c, e
        end)
        wait_for(function()
            return revived ~= nil or revive_err ~= nil
        end, "revive must settle")
        assert.is_nil(revive_err)

        assert.equals(2, Manifest.load(parent_cwd)["child-1"].run_generation, "a revive starts a new run")
        assert.equals(2, revived.run_generation)
        assert.equals(2, created[2].session.run_generation)
    end)

    it("reuses a live process without bumping the generation", function()
        local parent = make_parent("parent-integration-8")
        Sessions._register_for_test(parent)
        local _, child = dispatch_one(parent)
        local before = Manifest.load(parent_cwd)[child.id].run_generation

        local live
        Subsessions.revive(child.id, function(c)
            live = c
        end)

        assert.equals(child, live)
        assert.equals(before, Manifest.load(parent_cwd)[child.id].run_generation)
    end)

    it("keeps the integration record across a resume", function()
        Manifest.upsert("child-resume", {
            parent_id = "parent-lineage",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "t",
            config = {},
            status = "dormant",
            reported = true,
            created_at = "t0",
            last_active_at = "t0",
            run_generation = 3,
            session_file = parent_cwd .. "/child-resume.jsonl",
            workspace = parent_cwd,
            integration = { state = "applied", files = { "src/applied.lua" }, patch_sha = "sha-1", applied_at = "t1" },
        }, parent_cwd)
        vim.fn.writefile(
            { vim.json.encode({ type = "session", id = "child-resume" }) },
            parent_cwd .. "/child-resume.jsonl"
        )

        local revived
        Subsessions.revive("child-resume", function(c)
            revived = c
        end)
        wait_for(function()
            return revived ~= nil
        end, "revive must settle")

        local entry = Manifest.load(parent_cwd)["child-resume"]
        assert.equals(4, entry.run_generation, "the resume is a new run")
        assert.equals("applied", entry.integration.state, "the integration record must survive the resume")
        assert.same({ "src/applied.lua" }, entry.integration.files)
        assert.equals("sha-1", entry.integration.patch_sha)
    end)

    it("reconciles and then enforces retention on rebuild", function()
        Subsessions.rebuild_statuses()

        assert.equals("reconcile", engine.order[1])
        wait_for(function()
            return engine.order[2] == "enforce_retention"
        end, "enforce_retention must run after reconcile completes")
    end)
end)
