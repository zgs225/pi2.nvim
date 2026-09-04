local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")

describe("subsession abort batch fixes", function()
    local batch_tmp
    local manifest_tmp
    local real_manifest_path

    before_each(function()
        Batch._reset()
        batch_tmp = vim.fn.tempname() .. "-batches.json"
        manifest_tmp = vim.fn.tempname() .. "-manifest.json"
        Batch._set_path(batch_tmp)
        real_manifest_path = Manifest.path
        Manifest.path = function()
            return manifest_tmp
        end
        Manifest._reset()
        Sessions._reset()
    end)

    after_each(function()
        os.remove(batch_tmp)
        os.remove(manifest_tmp)
        Batch._reset()
        Manifest.path = real_manifest_path
        Manifest._reset()
        Sessions._reset()
    end)

    it("aborts, closes, and interrupts child when batch is cancelled while spawning", function()
        local orig_spawn = Subsessions.spawn
        local orig_close = Subsessions.close
        local spawn_cb = nil
        Subsessions.spawn = function(_parent, _opts, callback)
            spawn_cb = callback
        end

        local closed_children = {}
        Subsessions.close = function(child_id)
            table.insert(closed_children, child_id)
        end

        local parent = {
            id = "parent-spawn-test",
            lineage_id = "parent-spawn-test",
            rpc = {
                is_running = function()
                    return true
                end,
            },
        }

        local batch_id
        Batch.dispatch(parent, {
            items = { { task = "task to spawn" } },
        }, function(res)
            batch_id = res.batch_id
        end)

        assert.is_string(batch_id)

        local ok = vim.wait(1000, function()
            local b = Batch.get(batch_id)
            return b and b.items[1] and b.items[1].status == "spawning"
        end, 20)
        assert.is_true(ok)

        local b = Batch.get(batch_id)
        assert.equals("running", b.status)
        assert.equals("spawning", b.items[1].status)

        -- Cancel batch while spawning
        assert.is_true(Batch.cancel(batch_id))
        assert.equals("cancelled", Batch.get(batch_id).status)

        -- Seed manifest entry since our spawn stub skipped the real upsert
        Manifest.upsert("child-x", {
            parent_id = "parent-spawn-test",
            status = "active",
            name = "child-x",
        })

        local sent_msgs = {}
        local mock_child = {
            id = "child-x",
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(_self, msg)
                    table.insert(sent_msgs, msg)
                end,
                stop = function() end,
            },
        }

        assert.is_not_nil(spawn_cb)
        spawn_cb(mock_child, nil)

        -- Restore stubs
        Subsessions.spawn = orig_spawn
        Subsessions.close = orig_close

        -- Assert child rpc received { type = "abort" }
        assert.equals(1, #sent_msgs)
        assert.equals("abort", sent_msgs[1].type)

        -- Assert Subsessions.close was called with child-x
        assert.equals(1, #closed_children)
        assert.equals("child-x", closed_children[1])

        -- Assert manifest entry has status "interrupted"
        local entry = Manifest.load()["child-x"]
        assert.is_not_nil(entry)
        assert.equals("interrupted", entry.status)
    end)

    it("cancels foreign batch when waiting lineage matches cancel_for_parent", function()
        local other_batch_id = "other-batch-999"
        local other_batch = {
            id = other_batch_id,
            parent_id = "old-lineage-000",
            status = "running",
            created_at = Manifest.iso_now(),
            updated_at = Manifest.iso_now(),
            cancel_siblings_on_fail = false,
            items = {
                { ref = "0", target = "some-child", status = "running" },
            },
        }
        local batches = Batch.load()
        batches[other_batch_id] = other_batch
        local f = io.open(batch_tmp, "w")
        assert.is_not_nil(f)
        f:write(vim.json.encode(batches))
        f:close()
        Batch._reset()
        Batch._set_path(batch_tmp)

        local wait_fired = false
        local wait_snap = nil
        Batch.wait(other_batch_id, function(res)
            wait_fired = true
            wait_snap = res
        end, { owner = "current-lineage-111" })

        Batch.cancel_for_parent("current-lineage-111")

        local updated = Batch.get(other_batch_id)
        assert.is_not_nil(updated)
        assert.equals("cancelled", updated.status)

        local ok = vim.wait(1000, function()
            return wait_fired
        end, 20)
        assert.is_true(ok)
        assert.is_not_nil(wait_snap)
        assert.equals("cancelled", wait_snap.status)
        assert.equals(other_batch_id, wait_snap.batch_id)
    end)

    it("does not cancel foreign batch when waiter owner is a different lineage", function()
        local other_batch_id = "other-batch-isolated"
        local other_batch = {
            id = other_batch_id,
            parent_id = "old-lineage-000",
            status = "running",
            created_at = Manifest.iso_now(),
            updated_at = Manifest.iso_now(),
            cancel_siblings_on_fail = false,
            items = {
                { ref = "0", target = "some-child", status = "running" },
            },
        }
        local batches = Batch.load()
        batches[other_batch_id] = other_batch
        local f = io.open(batch_tmp, "w")
        assert.is_not_nil(f)
        f:write(vim.json.encode(batches))
        f:close()
        Batch._reset()
        Batch._set_path(batch_tmp)

        local wait_fired = false
        Batch.wait(other_batch_id, function(_res)
            wait_fired = true
        end, { owner = "other-lineage-999" })

        Batch.cancel_for_parent("current-lineage-111")

        local current = Batch.get(other_batch_id)
        assert.is_not_nil(current)
        assert.equals("running", current.status)

        vim.wait(50, function()
            return wait_fired
        end, 10)
        assert.is_false(wait_fired)
    end)
end)
