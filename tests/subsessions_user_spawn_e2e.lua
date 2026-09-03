-- Headless e2e: user-spawned children keep agent_spawned=false and inject a parent report.
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/subsessions_user_spawn_e2e.lua

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Batch = require("pi.subsessions.batch")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")

Config.setup({ title = { lang = "en" } })

local manifest_tmp = vim.fn.tempname() .. "-e2e-manifest.json"
local batch_tmp = vim.fn.tempname() .. "-e2e-batches.json"
Manifest.path = function()
    return manifest_tmp
end
Batch._set_path(batch_tmp)
Manifest._reset()

local Read = require("pi.subsessions.read")
local real_read = Read.last_assistant_message

local ok, err = pcall(function()
    Manifest.upsert("user-child", {
        parent_id = "lineage-e2e",
        name = "review",
        task_prompt = "review code",
        config = {},
        status = "active",
        reported = false,
        created_at = Manifest.iso_now(),
        last_active_at = Manifest.iso_now(),
        agent_spawned = false,
        run_generation = 1,
    })

    Batch.bump_generation("user-child")
    local after_bump = Manifest.load()["user-child"]
    assert(after_bump.agent_spawned == false, "bump_generation must not set agent_spawned")
    assert(after_bump.run_generation == 2, "generation should increment")

    local prompted
    local tab = vim.api.nvim_get_current_tabpage()
    local parent = {
        id = "parent-e2e",
        lineage_id = "lineage-e2e",
        attached_tab = tab,
        tab = tab,
        rpc = {
            is_running = function()
                return true
            end,
            stop = function() end,
            send = function(_, cmd, cb)
                if cmd.type == "prompt" then
                    prompted = cmd.message
                    if cb then
                        vim.schedule(function()
                            cb({ success = true })
                        end)
                    end
                end
                return true
            end,
        },
    }
    Sessions._register_for_test(parent)
    Sessions.bind_chat(parent, {
        bind_agent = function() end,
        clear = function() end,
        is_streaming = function()
            return false
        end,
        is_compacting = function()
            return false
        end,
    }, tab)

    Read.last_assistant_message = function()
        return "all good"
    end

    Subsessions.on_child_settled({
        id = "user-child",
        parent_id = "parent-e2e",
        session_file = "/tmp/user-child.jsonl",
        rpc = {
            is_running = function()
                return true
            end,
            stop = function() end,
        },
    })

    assert(
        vim.wait(3000, function()
            local entry = Manifest.load()["user-child"]
            return entry and entry.reported == true
        end, 10),
        "user-spawned child should inject a parent report"
    )

    assert(type(prompted) == "string", "parent prompt missing")
    assert(prompted:find("review", 1, true), "report should include child name")
    assert(prompted:find("all good", 1, true), "report should include last assistant text")
    assert(prompted:find("Sub-session", 1, true) or prompted:find("子会话", 1, true), "report should be localized")
end)

os.remove(manifest_tmp)
os.remove(batch_tmp)
Sessions._reset()
Manifest._reset()
Batch._reset()
Read.last_assistant_message = real_read

if not ok then
    io.stderr:write("subsessions_user_spawn_e2e: FAIL\n" .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end

print("subsessions_user_spawn_e2e: OK")
vim.cmd("cq 0")
