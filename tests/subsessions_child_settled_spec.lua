local Config = require("pi.config")
local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")
local SessionList = require("pi.ui.sessions")

Config.setup({})

---@param sent_list table?
---@return table
local function make_mock_rpc(sent_list)
    return {
        is_running = function()
            return true
        end,
        stop = function() end,
        send = function(_self, msg, cb)
            if sent_list then
                table.insert(sent_list, msg)
            end
            if cb then
                cb({ success = true })
            end
        end,
    }
end

--- Write a minimal pi session JSONL whose last assistant turn stopped with `stop_reason`.
---@param id string
---@param stop_reason string
---@return string path
local function write_session_jsonl(id, stop_reason)
    local path = vim.fn.tempname() .. "-session.jsonl"
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode({ type = "session", id = id, timestamp = Manifest.iso_now() }) .. "\n")
    f:write(vim.json.encode({
        type = "message",
        message = {
            role = "assistant",
            stopReason = stop_reason,
            content = { { type = "text", text = "output" } },
        },
    }) .. "\n")
    f:close()
    return path
end

---@param batch_id string
---@param index integer
---@param status string
local function wait_item_status(batch_id, index, status)
    local ok = vim.wait(2000, function()
        local snap = Batch.poll(batch_id)
        return snap and snap.items[index] and snap.items[index].status == status
    end, 20)
    assert.is_true(ok, ("item %d never reached %q"):format(index, status))
end

---@param messages table[]
---@param kind string
---@return boolean
local function has_message(messages, kind)
    for _, msg in ipairs(messages) do
        if msg.type == kind then
            return true
        end
    end
    return false
end

describe("subsession completion reporting", function()
    local manifest_tmp
    local batch_tmp
    local tmp_files
    local real_read = Read.last_assistant_message
    local real_manifest_path = Manifest.path
    local tab

    before_each(function()
        tab = vim.api.nvim_get_current_tabpage()
        tmp_files = {}
        manifest_tmp = vim.fn.tempname() .. ".json"
        batch_tmp = vim.fn.tempname() .. "-batches.json"
        Batch._reset()
        Batch._set_path(batch_tmp)
        Manifest.path = function()
            return manifest_tmp
        end
        Manifest._reset()
        SessionList._reset()
    end)

    after_each(function()
        Read.last_assistant_message = real_read
        Manifest.path = real_manifest_path
        os.remove(manifest_tmp)
        os.remove(batch_tmp)
        for _, path in ipairs(tmp_files) do
            os.remove(path)
        end
        Batch._reset()
        Sessions._reset()
        Manifest._reset()
    end)

    it("find_by_lineage resolves parent after session id migration", function()
        Manifest.register_session_lineage("session-b", "session-b")
        Manifest.register_session_lineage("session-a", "session-b")
        local parent = {
            id = "session-b",
            lineage_id = "session-b",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        }
        Sessions._register_for_test(parent)
        assert.are.equal(parent, Sessions.find_by_lineage("session-a"))
        assert.are.equal(parent, Sessions.find_by_lineage("session-b"))
    end)

    it("marks reported and acknowledges when parent is on the current tab", function()
        Read.last_assistant_message = function()
            return "done report"
        end

        Manifest.upsert("child-1", {
            parent_id = "lineage-a",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
        })

        local parent = {
            id = "parent-live",
            lineage_id = "lineage-a",
            attached_tab = tab,
            tab = tab,
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
                send = function(_, cmd, cb)
                    if cmd.type == "prompt" and cb then
                        vim.schedule(function()
                            cb({ success = true })
                        end)
                    end
                    return true
                end,
            },
        }
        local child = {
            id = "child-1",
            parent_id = "parent-live",
            session_file = "/tmp/child.jsonl",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
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

        Subsessions.on_child_settled(child)

        assert.is_true(
            vim.wait(3000, function()
                local entry = Manifest.load()["child-1"]
                return entry and entry.reported == true
            end, 10),
            "completion report was not marked reported"
        )

        local rows = SessionList.build_rows({ parent }, function()
            return 0
        end, function()
            return "parent"
        end)
        assert.are.equal(1, #rows)
    end)

    it("injects a completion prompt for user-spawned children", function()
        Read.last_assistant_message = function()
            return "done report"
        end

        Manifest.upsert("child-user", {
            parent_id = "lineage-a",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
            agent_spawned = false,
            run_generation = 1,
        })

        local prompted
        local parent = {
            id = "parent-live",
            lineage_id = "lineage-a",
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

        Subsessions.on_child_settled({
            id = "child-user",
            parent_id = "parent-live",
            session_file = "/tmp/child.jsonl",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        })

        assert.is_true(
            vim.wait(3000, function()
                local entry = Manifest.load()["child-user"]
                return entry and entry.reported == true
            end, 10),
            "user-spawned completion was not reported"
        )
        assert.is_truthy(prompted)
        assert.is_truthy(prompted:find("worker", 1, true))
        assert.is_truthy(prompted:find("done report", 1, true))
    end)

    --- Build a parent + child with a running batch item and a session file whose
    --- last assistant turn stopped with `stop_reason`.
    ---@param suffix string
    ---@param stop_reason string
    ---@return table parent_sent
    ---@return string batch_id
    ---@return pi.Session child
    local function setup_running_child(suffix, stop_reason)
        local parent_sent = {}
        local parent = {
            id = "parent-" .. suffix,
            rpc = make_mock_rpc(parent_sent),
            attention = { pending = {} },
        }
        local child = {
            id = "child-" .. suffix,
            rpc = make_mock_rpc({}),
            attention = { pending = {} },
        }
        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        Manifest.upsert(child.id, {
            parent_id = parent.id,
            status = "active",
            run_generation = 1,
            agent_spawned = false,
            name = "c",
        })
        local path = write_session_jsonl(child.id, stop_reason)
        tmp_files[#tmp_files + 1] = path
        child.session_file = path

        local batch_id
        Batch.dispatch(parent, { items = { { target = child.id, message = "work" } } }, function(res)
            batch_id = res.batch_id
        end)
        assert.is_string(batch_id)
        wait_item_status(batch_id, 1, "running")
        return parent_sent, batch_id, child
    end

    it("settles as cancelled from the aborted event flag even when the file is not aborted", function()
        local parent_sent, batch_id, child = setup_running_child("flag-true", "stop")
        assert.equals("stop", Read.last_stop_reason(child.session_file))

        Subsessions.on_child_settled(child, true)

        assert.equals("cancelled", Batch.get(batch_id).items[1].status)
        assert.equals("cancelled", Batch.get(batch_id).status)
        assert.equals("interrupted", Manifest.load()[child.id].status)
        assert.is_false(has_message(parent_sent, "prompt"))
    end)

    it("keeps file-based abort detection when the event flag is nil (older pi)", function()
        local parent_sent, batch_id, child = setup_running_child("flag-nil", "aborted")

        Subsessions.on_child_settled(child, nil)

        assert.equals("cancelled", Batch.get(batch_id).items[1].status)
        assert.equals("interrupted", Manifest.load()[child.id].status)
        assert.is_false(has_message(parent_sent, "prompt"))
    end)

    it("keeps file-based abort detection when the event flag is false", function()
        local parent_sent, batch_id, child = setup_running_child("flag-false", "aborted")

        Subsessions.on_child_settled(child, false)

        assert.equals("cancelled", Batch.get(batch_id).items[1].status)
        assert.equals("interrupted", Manifest.load()[child.id].status)
        assert.is_false(has_message(parent_sent, "prompt"))
    end)
end)
