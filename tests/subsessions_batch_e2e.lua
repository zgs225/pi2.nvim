-- Headless e2e: sub-session batch host bridge (dispatch → poll → wait).
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/subsessions_batch_e2e.lua

local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")
local Subsessions = require("pi.subsessions")

local batch_tmp = vim.fn.tempname() .. "-e2e-batches.json"
local manifest_tmp = vim.fn.tempname() .. "-e2e-manifest.json"
Batch._set_path(batch_tmp)
Manifest.path = function()
    return manifest_tmp
end

local real_spawn = Subsessions.spawn
Subsessions.spawn = function(_parent, opts, callback)
    local id = "e2e-child"
    Manifest.upsert(id, {
        parent_id = "e2e-parent",
        name = opts.name or "e2e",
        task_prompt = opts.task,
        config = {},
        status = "active",
        reported = false,
        created_at = Manifest.iso_now(),
        last_active_at = Manifest.iso_now(),
        agent_spawned = true,
        run_generation = 1,
    })
    callback({ id = id, rpc = {
        is_running = function()
            return true
        end,
    } }, nil)
end

local parent = {
    id = "e2e-parent",
    rpc = {
        is_running = function()
            return true
        end,
    },
}

local batch_id
local dispatch_ok = false
Batch.dispatch(parent, { items = { { ref = "only", task = "e2e task", name = "e2e" } } }, function(res)
    dispatch_ok = res.batch_id ~= nil and res.status == "running"
    batch_id = res.batch_id
end)

assert(dispatch_ok, "dispatch failed")

vim.wait(2000, function()
    local snap = Batch.poll(batch_id)
    return snap and snap.items[1] and snap.items[1].status == "running"
end, 50)

local host_payload = vim.json.encode({
    action = "poll_subagents",
    params = { batch_id = batch_id },
})
local poll_res = Subsessions.handle_host(parent, host_payload)
assert(poll_res and poll_res.status == "running", "poll should be running")

Manifest.patch("e2e-child", { status = "completed" })
Batch.on_child_settled("e2e-child")

poll_res = Subsessions.handle_host(parent, host_payload)
assert(poll_res and poll_res.status == "completed", "poll should be completed after settle")

local waited = false
local wait_calls = 0
Subsessions.handle_host(
    parent,
    vim.json.encode({
        action = "wait_subagents",
        params = { batch_id = batch_id, timeout_ms = 3000 },
    }),
    function(res)
        wait_calls = wait_calls + 1
        waited = res.status == "completed"
    end
)

vim.wait(2000, function()
    return waited
end)
assert(waited, "wait_subagents did not complete")
vim.wait(80)
assert(wait_calls == 1, "wait_subagents callback fired " .. tostring(wait_calls) .. " times")

local list_res = Subsessions.handle_host(parent, vim.json.encode({ action = "list_batches", params = {} }))
assert(list_res and type(list_res.batches) == "table" and #list_res.batches >= 1, "list_batches failed")

Subsessions.spawn = real_spawn
os.remove(batch_tmp)
os.remove(manifest_tmp)

print("subsessions_batch_e2e: OK")
vim.cmd("cq 0")
