-- Host bridge for extensions/subagent.ts (handle_host).

local Subsessions = require("pi.subsessions")
local Manifest = require("pi.subsessions.manifest")
local Batch = require("pi.subsessions.batch")
local Sessions = require("pi.sessions.manager")

describe("subsessions handle_host", function()
    local real_get_by_id = Sessions.get_by_id
    local real_spawn
    local real_close
    local batch_tmp
    local manifest_tmp

    before_each(function()
        batch_tmp = vim.fn.tempname() .. "-batches.json"
        manifest_tmp = vim.fn.tempname() .. "-manifest.json"
        Batch._set_path(batch_tmp)
        Manifest.path = function()
            return manifest_tmp
        end
        real_spawn = Subsessions.spawn
    end)

    after_each(function()
        Sessions.get_by_id = real_get_by_id
        Subsessions.spawn = real_spawn
        Batch._reset()
        os.remove(batch_tmp)
        os.remove(manifest_tmp)
    end)

    it("stop_subagents closes each target", function()
        local closed = {}
        Subsessions.close = function(id)
            closed[#closed + 1] = id
        end
        local parent = { id = "parent-1" }
        local res = Subsessions.handle_host(parent, vim.json.encode({
            action = "stop_subagents",
            params = { targets = { "a", "b" } },
        }))
        assert.is_true(res.ok)
        assert.are.equal(2, res.stopped)
        assert.are.equal("a", closed[1])
        assert.are.equal("b", closed[2])
    end)

    it("dispatch_subagents with wait returns completed batch", function()
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
            callback({ id = id }, nil)
        end

        local parent = { id = "parent-1", rpc = { is_running = function()
            return true
        end } }
        local done = false
        Subsessions.handle_host(parent, vim.json.encode({
            action = "dispatch_subagents",
            params = {
                items = { { task = "do work", name = "w" } },
                wait = true,
                timeout_ms = 5000,
            },
        }), function(res)
            done = res.status == "completed"
        end)

        vim.wait(2000, function()
            local batches = Batch.load()
            for _, batch in pairs(batches) do
                for _, item in ipairs(batch.items) do
                    if item.target then
                        Manifest.patch(item.target, { status = "completed" })
                        Batch.on_child_settled(item.target)
                    end
                end
            end
            return done
        end, 20)

        assert.is_true(done)
    end)
end)
