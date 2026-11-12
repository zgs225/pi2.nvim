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
---@param opts? { text?: string, error_message?: string }
---@return string path
local function write_session_jsonl(id, stop_reason, opts)
    opts = opts or {}
    local path = vim.fn.tempname() .. "-session.jsonl"
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode({ type = "session", id = id, timestamp = Manifest.iso_now() }) .. "\n")
    --- A failed turn is persisted with empty content (see the real pi 1.5.2
    --- shape: `content: []`, `stopReason: "error"`, `errorMessage`).
    local text = opts.text
    if text == nil and stop_reason ~= "error" then
        text = "output"
    end
    f:write(vim.json.encode({
        type = "message",
        message = {
            role = "assistant",
            stopReason = stop_reason,
            content = text and { { type = "text", text = text } } or {},
            errorMessage = opts.error_message,
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
    local real_last_turn = Read.last_turn
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
        Read.last_turn = real_last_turn
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
        Read.last_turn = function()
            return { text = "done report", stop_reason = "stop" }
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
        Read.last_turn = function()
            return { text = "done report", stop_reason = "stop" }
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
    ---@param opts? { text?: string, error_message?: string }
    ---@return table parent_sent
    ---@return string batch_id
    ---@return pi.Session child
    local function setup_running_child(suffix, stop_reason, opts)
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
        local path = write_session_jsonl(child.id, stop_reason, opts)
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

    -- A failed turn is what pi persists for a quota/auth/network failure: an
    -- assistant message with `stopReason: "error"`, empty content and the reason
    -- in `errorMessage`. Before this was read, the item settled as `ok` with an
    -- empty output and the parent saw a silent success.
    it("books an errored turn as a failed item with the provider reason", function()
        local _, batch_id, child = setup_running_child("quota", "error", {
            error_message = '429: {"message":"You exceeded your current quota","type":"insufficient_quota"}',
        })

        Subsessions.on_child_settled(child, false)

        local snap = Batch.poll(batch_id)
        local item = snap.items[1]
        assert.equals("failed", item.status)
        assert.equals("failed", snap.status)
        assert.equals(1, snap.summary.failed)
        assert.equals(0, snap.summary.ok)
        assert.is_truthy(item.error:find("insufficient_quota", 1, true))
        assert.is_nil(item.output)

        local entry = Manifest.load()[child.id]
        assert.equals("failed", entry.status)
        assert.is_truthy(entry.last_error:find("insufficient_quota", 1, true))
    end)

    it("keeps the partial report a failed run produced", function()
        local _, batch_id, child = setup_running_child("fail-partial", "error", {
            text = "read the file, then the provider died",
            error_message = "529: overloaded",
        })

        Subsessions.on_child_settled(child, false)

        local item = Batch.poll(batch_id).items[1]
        assert.equals("failed", item.status)
        assert.is_truthy(item.output:find("read the file", 1, true))
        assert.is_truthy(item.error:find("overloaded", 1, true))
    end)

    it("prefers the abort signal over an errored turn", function()
        local parent_sent, batch_id, child = setup_running_child("abort-error", "error", {
            error_message = "429: quota",
        })

        Subsessions.on_child_settled(child, true)

        assert.equals("cancelled", Batch.poll(batch_id).items[1].status)
        local entry = Manifest.load()[child.id]
        assert.equals("interrupted", entry.status)
        assert.is_nil(entry.last_error)
        assert.is_false(has_message(parent_sent, "prompt"))
    end)

    it("settles from the manifest when the run crashed (keepalive, no outcome)", function()
        local _, batch_id, child = setup_running_child("crash", "stop")
        -- The manager patches `failed` before settling a child that died with a
        -- registered process: a crashed run leaves no assistant turn to read.
        Manifest.patch(child.id, { status = "failed", last_error = "process exited with code 137" })

        assert.is_true(Batch.on_child_settled(child.id))

        local item = Batch.poll(batch_id).items[1]
        assert.equals("failed", item.status)
        assert.equals("process exited with code 137", item.error)
    end)

    it("books an unexpected process exit without recycling an earlier reason", function()
        local _, batch_id, child = setup_running_child("crash-settle", "stop")
        -- A stale `last_error` from a previous run must not be presented as the
        -- reason this process died.
        Manifest.patch(child.id, { status = "failed", last_error = "429: quota from an earlier run" })

        Subsessions.on_child_settled(child, nil)

        local item = Batch.poll(batch_id).items[1]
        assert.equals("failed", item.status)
        assert.equals("sub-agent process exited", item.error)
    end)

    it("injects a failure notice for a user-spawned child", function()
        Manifest.upsert("child-fail-user", {
            parent_id = "lineage-fail",
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
            id = "parent-fail",
            lineage_id = "lineage-fail",
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
        local path = write_session_jsonl("child-fail-user", "error", {
            error_message = "401: Incorrect API key provided",
        })
        tmp_files[#tmp_files + 1] = path

        Subsessions.on_child_settled({
            id = "child-fail-user",
            parent_id = "parent-fail",
            session_file = path,
            rpc = make_mock_rpc({}),
        }, false)

        assert.is_true(
            vim.wait(3000, function()
                local entry = Manifest.load()["child-fail-user"]
                return entry and entry.reported == true
            end, 10),
            "failure notice was not injected"
        )
        assert.is_truthy(prompted:find("401: Incorrect API key provided", 1, true))
        local entry = Manifest.load()["child-fail-user"]
        assert.equals("failed", entry.status)
        assert.is_truthy(entry.last_error:find("Incorrect API key", 1, true))
    end)

    it("clears the recorded failure reason on a later successful run", function()
        local _, batch_id, child = setup_running_child("recover", "error", { error_message = "429: quota" })

        Subsessions.on_child_settled(child, false)
        assert.equals("failed", Batch.poll(batch_id).status)
        assert.is_truthy(Manifest.load()[child.id].last_error)

        local ok_path = write_session_jsonl(child.id, "stop", { text = "all good now" })
        tmp_files[#tmp_files + 1] = ok_path
        child.session_file = ok_path
        Manifest.patch(child.id, { run_generation = 2, status = "active", reported = false })

        Subsessions.on_child_settled(child, false)

        assert.is_true(
            vim.wait(3000, function()
                local entry = Manifest.load()[child.id]
                return entry and entry.reported == true
            end, 10),
            "successful run was not reported"
        )
        local entry = Manifest.load()[child.id]
        assert.equals("completed", entry.status)
        assert.is_nil(entry.last_error)
    end)

    it("rebuild restores a failed item with the recorded reason", function()
        Manifest.upsert("child-rebuild", {
            parent_id = "parent-rebuild",
            name = "w",
            task_prompt = "t",
            config = {},
            status = "failed",
            last_error = "429: quota exceeded",
            reported = false,
            created_at = Manifest.iso_now(),
            last_active_at = Manifest.iso_now(),
            run_generation = 3,
        })
        local batches = {
            b1 = {
                id = "b1",
                parent_id = "parent-rebuild",
                status = "running",
                created_at = Manifest.iso_now(),
                updated_at = Manifest.iso_now(),
                cancel_siblings_on_fail = false,
                items = {
                    { ref = "0", task = "t", status = "running", target = "child-rebuild", generation = 3 },
                },
            },
        }
        local f = assert(io.open(Batch.path(), "w"))
        f:write(vim.json.encode(batches))
        f:close()

        Batch.rebuild()

        local batch = Batch.get("b1")
        assert.equals("failed", batch.status)
        assert.equals("failed", batch.items[1].status)
        assert.equals("429: quota exceeded", batch.items[1].error)
    end)
end)
