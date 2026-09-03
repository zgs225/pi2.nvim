-- Sub-session batch dispatch / poll / wait.

local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")

describe("subsession batch", function()
    local batch_tmp
    local manifest_tmp
    local real_spawn
    local real_revive
    local real_manifest_path
    local Subsessions

    before_each(function()
        Batch._reset()
        batch_tmp = vim.fn.tempname() .. "-batches.json"
        manifest_tmp = vim.fn.tempname() .. "-manifest.json"
        Batch._set_path(batch_tmp)
        real_manifest_path = Manifest.path
        Manifest.path = function()
            return manifest_tmp
        end
        Subsessions = require("pi.subsessions")
        real_spawn = Subsessions.spawn
        real_revive = Subsessions.revive
        Manifest._reset()
    end)

    after_each(function()
        Subsessions.spawn = real_spawn
        Subsessions.revive = real_revive
        os.remove(batch_tmp)
        os.remove(manifest_tmp)
        Batch._reset()
        Manifest.path = real_manifest_path
        Manifest._reset()
    end)

  it("dispatch fans out items and completes via on_child_settled", function()
        Subsessions.spawn = function(_parent, opts, callback)
            local id = "child-" .. (opts.name or "x")
            Manifest.upsert(id, {
                parent_id = "parent-1",
                name = opts.name or "task",
                task_prompt = opts.task,
                config = {},
                status = "active",
                reported = false,
                created_at = Manifest.iso_now(),
                last_active_at = Manifest.iso_now(),
                agent_spawned = true,
                run_generation = 1,
            })
            callback({
                id = id,
                rpc = { is_running = function()
                    return true
                end },
            }, nil)
        end

        local parent = { id = "parent-1", rpc = { is_running = function()
            return true
        end } }
        local done = false
        local batch_id
        Batch.dispatch(parent, {
            items = {
                { ref = "a", task = "one", name = "A" },
                { ref = "b", task = "two", name = "B" },
            },
        }, function(res)
            done = true
            batch_id = res.batch_id
            assert.equals("running", res.status)
            assert.equals(2, res.summary.total)
        end)
        assert.is_true(done)
        assert.is_string(batch_id)

        vim.wait(1000, function()
            local snap = Batch.poll(batch_id)
            return snap and snap.items[1] and snap.items[1].target ~= nil
        end, 20)

        Manifest.patch("child-A", { status = "completed" })
        Batch.on_child_settled("child-A")
        Manifest.patch("child-B", { status = "completed" })
        Batch.on_child_settled("child-B")

        local snap = Batch.poll(batch_id)
        assert.equals("completed", snap.status)
        assert.equals(2, snap.summary.ok)
    end)

    it("poll reports partial when one item fails", function()
        Subsessions.spawn = function(_parent, opts, callback)
            local id = "child-" .. opts.name
            Manifest.upsert(id, {
                parent_id = "parent-1",
                name = opts.name,
                task_prompt = opts.task,
                config = {},
                status = "active",
                reported = false,
                created_at = Manifest.iso_now(),
                last_active_at = Manifest.iso_now(),
                agent_spawned = true,
                run_generation = 1,
            })
            callback({ id = id }, nil)
        end

        local parent = { id = "parent-1", rpc = { is_running = function()
            return true
        end } }
        local batch_id
        Batch.dispatch(parent, {
            items = {
                { ref = "ok", task = "t", name = "ok" },
                { ref = "bad", task = "t", name = "bad" },
            },
        }, function(res)
            batch_id = res.batch_id
        end)

        vim.wait(1000, function()
            local snap = Batch.poll(batch_id)
            return snap and snap.summary.running == 2
        end, 20)

        Manifest.patch("child-ok", { status = "completed" })
        Batch.on_child_settled("child-ok")
        Manifest.patch("child-bad", { status = "failed" })
        Batch.on_child_settled("child-bad")

        local snap = Batch.poll(batch_id)
        assert.equals("partial", snap.status)
        assert.equals(1, snap.summary.ok)
        assert.equals(1, snap.summary.failed)
    end)

    it("cancel_siblings_on_fail cancels queued siblings", function()
        local spawn_count = 0
        Subsessions.spawn = function(_parent, opts, callback)
            spawn_count = spawn_count + 1
            local id = "child-" .. spawn_count
            Manifest.upsert(id, {
                parent_id = "parent-1",
                name = opts.name or id,
                task_prompt = opts.task,
                config = {},
                status = "active",
                reported = false,
                created_at = Manifest.iso_now(),
                last_active_at = Manifest.iso_now(),
                agent_spawned = true,
                run_generation = 1,
            })
            callback({ id = id }, nil)
        end

        local parent = { id = "parent-1", rpc = { is_running = function()
            return true
        end } }
        local batch_id
        Batch.dispatch(parent, {
            items = {
                { ref = "1", task = "a", name = "1" },
                { ref = "2", task = "b", name = "2" },
            },
            cancel_siblings_on_fail = true,
        }, function(res)
            batch_id = res.batch_id
        end)

        vim.wait(1000, function()
            local snap = Batch.poll(batch_id)
            return snap and snap.summary.running == 2
        end, 20)

        Manifest.patch("child-1", { status = "failed" })
        Batch.on_child_settled("child-1")

        local snap = Batch.poll(batch_id)
        assert.equals("failed", snap.status)
        assert.equals("cancelled", snap.items[2].status)
    end)

    it("wait invokes callback when batch completes", function()
        Subsessions.spawn = function(_parent, opts, callback)
            Manifest.upsert("child-w", {
                parent_id = "parent-1",
                name = "w",
                task_prompt = opts.task,
                config = {},
                status = "active",
                reported = false,
                created_at = Manifest.iso_now(),
                last_active_at = Manifest.iso_now(),
                agent_spawned = true,
                run_generation = 1,
            })
            callback({ id = "child-w" }, nil)
        end

        local parent = { id = "parent-1", rpc = { is_running = function()
            return true
        end } }
        local batch_id
        Batch.dispatch(parent, { items = { { task = "x" } } }, function(res)
            batch_id = res.batch_id
        end)

        vim.wait(1000, function()
            local snap = Batch.poll(batch_id)
            return snap and snap.items[1] and snap.items[1].status == "running"
        end, 20)

        local waited = false
        Batch.wait(batch_id, function(res)
            waited = true
            assert.equals("completed", res.status)
        end, { timeout_ms = 5000, interval_ms = 10 })

        Manifest.patch("child-w", { status = "completed" })
        Batch.on_child_settled("child-w")

        vim.wait(1000, function()
            return waited
        end)
        assert.is_true(waited)
    end)

    it("wait invokes callback only once when settle races the poll tick", function()
        Subsessions.spawn = function(_parent, opts, callback)
            Manifest.upsert("child-once", {
                parent_id = "parent-1",
                name = "w",
                task_prompt = opts.task,
                config = {},
                status = "active",
                reported = false,
                created_at = Manifest.iso_now(),
                last_active_at = Manifest.iso_now(),
                agent_spawned = true,
                run_generation = 1,
            })
            callback({ id = "child-once" }, nil)
        end

        local parent = { id = "parent-1", rpc = { is_running = function()
            return true
        end } }
        local batch_id
        Batch.dispatch(parent, { items = { { task = "x" } } }, function(res)
            batch_id = res.batch_id
        end)

        vim.wait(1000, function()
            local snap = Batch.poll(batch_id)
            return snap and snap.items[1] and snap.items[1].status == "running"
        end, 20)

        local calls = 0
        Batch.wait(batch_id, function(res)
            calls = calls + 1
            assert.equals("completed", res.status)
        end, { timeout_ms = 5000, interval_ms = 10 })

        Manifest.patch("child-once", { status = "completed" })
        Batch.on_child_settled("child-once")

        vim.wait(1000, function()
            return calls >= 1
        end)
        vim.wait(80)
        assert.equals(1, calls)
    end)

    it("bump_generation does not mark the child as agent_spawned", function()
        Manifest.upsert("child-user", {
            parent_id = "parent-1",
            name = "user",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = Manifest.iso_now(),
            last_active_at = Manifest.iso_now(),
            agent_spawned = false,
            run_generation = 1,
        })
        Batch.bump_generation("child-user")
        local entry = Manifest.load()["child-user"]
        assert.is_false(entry.agent_spawned)
        assert.equals(2, entry.run_generation)
    end)

    it("stores batch.parent_id as lineage and list/cancel resolve migrated ids", function()
        local parent = {
            id = "session-new",
            lineage_id = "lineage-old",
            rpc = { is_running = function()
                return true
            end },
        }
        Manifest.bind_session_lineage(parent, "session-new")
        Subsessions.spawn = function(_parent, opts, callback)
            Manifest.upsert("child-lin", {
                parent_id = "lineage-old",
                name = "w",
                task_prompt = opts.task,
                config = {},
                status = "active",
                reported = false,
                created_at = Manifest.iso_now(),
                last_active_at = Manifest.iso_now(),
                agent_spawned = true,
                run_generation = 1,
            })
            callback({ id = "child-lin" }, nil)
        end

        local batch_id
        Batch.dispatch(parent, { items = { { task = "x" } } }, function(res)
            batch_id = res.batch_id
        end)

        local stored = Batch.get(batch_id)
        assert.equals("lineage-old", stored.parent_id)
        local listed = Batch.list_for_parent("session-new")
        assert.equals(1, #listed)
        assert.equals(batch_id, listed[1].batch_id)

        vim.wait(1000, function()
            local snap = Batch.poll(batch_id)
            return snap and snap.items[1] and snap.items[1].status == "running"
        end, 20)

        Batch.cancel_for_parent("session-new")
        assert.equals("cancelled", Batch.get(batch_id).status)
    end)
end)
