-- Headless e2e: the two settle paths differ only in `agent_spawned`.
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/subsessions_user_spawn_e2e.lua
--
-- A child the user spawned (`agent_spawned = false`) must inject its report into
-- the parent conversation; a child the Agent tool spawned (`agent_spawned =
-- true`) must not — its report travels back as a tool result. Both are driven
-- here against the SAME real transcript, because proving one path runs says
-- nothing about the other.
--
-- The report text is read from a REAL session JSONL on disk: the settle path
-- takes the last assistant turn with `Read.last_turn`, so stubbing the reader
-- would verify the stub instead of the contract. That is exactly how this
-- script used to be green-on-nothing — it stubbed `Read.last_assistant_message`
-- (which this path no longer calls) while pointing `session_file` at a file that
-- did not exist, so every settle took the "no report to deliver" branch.
--
-- Everything (manifest, batches, transcript, workspace) lives under
-- `vim.fn.tempname()`; nothing reads or writes the user's `~/.pi`.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Batch = require("pi.subsessions.batch")
local Notify = require("pi.notify")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")

Config.setup({ title = { lang = "en" } })

local failures = {}

---@param name string
---@param ok boolean
---@param detail? string
local function check(name, ok, detail)
    print(string.format("[%s] %s%s", ok and "PASS" or "FAIL", name, detail and (" — " .. detail) or ""))
    if not ok then
        failures[#failures + 1] = name
    end
end

local workspace = vim.fn.tempname()
vim.fn.mkdir(workspace, "p")
local manifest_tmp = workspace .. "/.pi2-subsessions.json"
local batch_tmp = workspace .. "/.pi2-batches.json"
Manifest.path = function()
    return manifest_tmp
end
Batch._set_path(batch_tmp)
Manifest._reset()

--- Write a two-turn pi session JSONL. `text` is what the settle must deliver.
---@param id string
---@param text string
---@return string path
local function write_transcript(id, text)
    local path = workspace .. "/" .. id .. ".jsonl"
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode({ type = "session", id = id, timestamp = Manifest.iso_now() }) .. "\n")
    f:write(vim.json.encode({ type = "message", message = { role = "user", content = "review code" } }) .. "\n")
    f:write(vim.json.encode({
        type = "message",
        message = {
            role = "assistant",
            stopReason = "stop",
            content = { { type = "text", text = text } },
        },
    }) .. "\n")
    f:close()
    return path
end

local real_read_turn = require("pi.subsessions.read").last_turn
local real_manifest_path = Manifest.path
local real_warn = Notify.warn

local ok, err = pcall(function()
    -- A parent registered the way a real one is: the session id differs from its
    -- lineage id, which is what the child rows record as `parent_id`.
    local tab = vim.api.nvim_get_current_tabpage()
    local prompts = {}
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
                    prompts[#prompts + 1] = cmd.message
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

    ---@param id string
    ---@param agent_spawned boolean
    ---@param text string
    local function spawn_row(id, agent_spawned, text)
        Manifest.upsert(id, {
            parent_id = "lineage-e2e",
            name = "review",
            task_prompt = "review code",
            config = {},
            status = "active",
            reported = false,
            created_at = Manifest.iso_now(),
            last_active_at = Manifest.iso_now(),
            workspace = workspace,
            agent_spawned = agent_spawned,
            run_generation = 1,
        })
        -- A real spawn/revive bumps the generation; the bump must not touch
        -- `agent_spawned` (that flag decides which delivery path the settle takes).
        Batch.bump_generation(id)
        local row = Manifest.load()[id]
        assert(row.run_generation == 2, id .. ": generation should increment")
        assert(row.agent_spawned == agent_spawned, id .. ": bump_generation must not flip agent_spawned")
        return write_transcript(id, text)
    end

    ---@param id string
    ---@param path string
    local function settle(id, path)
        Subsessions.on_child_settled({
            id = id,
            parent_id = "parent-e2e",
            cwd = workspace,
            session_file = path,
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        })
    end

    ---@param id string
    ---@param predicate fun(entry: table): boolean
    ---@return boolean
    local function wait_row(id, predicate)
        return vim.wait(3000, function()
            local entry = Manifest.load()[id]
            return type(entry) == "table" and predicate(entry)
        end, 10)
    end

    -- 1. User-spawned child: the report goes into the parent conversation.
    local user_path = spawn_row("user-child", false, "all good from the user child")
    settle("user-child", user_path)

    check(
        "user-spawned child is reported",
        wait_row("user-child", function(entry)
            return entry.reported == true
        end),
        vim.inspect(Manifest.load()["user-child"])
    )
    local user_row = Manifest.load()["user-child"]
    local user_prompt = prompts[1]
    check("user-spawned child injects exactly one parent prompt", #prompts == 1, vim.inspect(prompts))
    check("user-spawned settle books the row completed", user_row and user_row.status == "completed")
    check("report names the child", type(user_prompt) == "string" and user_prompt:find("review", 1, true) ~= nil)
    check(
        "report carries the transcript text read from disk",
        type(user_prompt) == "string" and user_prompt:find("all good from the user child", 1, true) ~= nil,
        tostring(user_prompt)
    )
    check(
        "report is localized",
        type(user_prompt) == "string"
            and (user_prompt:find("Sub-session", 1, true) ~= nil or user_prompt:find("子会话", 1, true) ~= nil)
    )

    -- 2. Agent-spawned child: same transcript, same parent — no prompt, but the
    --    report is still booked on the row (the tool result carries it instead).
    local tool_path = spawn_row("tool-child", true, "all good from the tool child")
    settle("tool-child", tool_path)

    check(
        "agent-spawned child settles",
        wait_row("tool-child", function(entry)
            return entry.status == "completed"
        end),
        vim.inspect(Manifest.load()["tool-child"])
    )
    local tool_row = Manifest.load()["tool-child"]
    check("agent-spawned child injects no parent prompt", #prompts == 1, vim.inspect(prompts))
    check("agent-spawned child stays unreported", tool_row and tool_row.reported ~= true)
    check(
        "agent-spawned report is still recorded on the row",
        tool_row and tool_row.last_report == "all good from the tool child",
        tool_row and tostring(tool_row.last_report)
    )
end)

os.remove(manifest_tmp)
os.remove(batch_tmp)
vim.fn.delete(workspace, "rf")
Sessions._reset()
Manifest._reset()
Batch._reset()
Manifest.path = real_manifest_path
Notify.warn = real_warn
require("pi.subsessions.read").last_turn = real_read_turn

if not ok then
    check("e2e body completed without error", false, tostring(err))
end

if #failures > 0 then
    print(string.format("USER SPAWN E2E: %d failed — %s", #failures, table.concat(failures, ", ")))
    vim.cmd("cq 1")
end
print("subsessions_user_spawn_e2e: OK")
vim.cmd("cq 0")
