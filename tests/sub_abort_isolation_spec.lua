-- Isolation spec for the sub-session abort rework.
--
-- Covers the invariants that must hold after an abort in a sub-session tree:
--   T2  an aborted child's settle never books "ok" and never injects a report
--   T3  aborting an idle child still wakes a parent blocked in wait_subagents
--   T4  a process reused by :PiResume drops stale parentage (P0-1 regression)
--   T5  interrupting one child does not kill its siblings in the same batch
--   T6  the spawn abort-epoch guard stops an in-flight interactive spawn
--   T10 child-view abort interrupts own children, not the parent or siblings

local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")
local Pi = require("pi")

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
            if msg.type == "get_state" and cb then
                cb({ success = true, data = { sessionId = "real-uuid-123" } })
            elseif cb then
                cb({ success = true })
            end
        end,
    }
end

local function make_mock_chat()
    return {
        bind_agent = function() end,
        clear = function() end,
        is_streaming = function()
            return false
        end,
        is_compacting = function()
            return false
        end,
        set_subsession_breadcrumb = function() end,
        clear_subsession_breadcrumb = function() end,
    }
end

local function has_message(messages, kind)
    for _, msg in ipairs(messages) do
        if msg.type == kind then
            return true
        end
    end
    return false
end

--- Write a minimal pi session JSONL file with the given message lines.
---@param id string
---@param message_lines string[]
---@return string path
local function write_session_jsonl(id, message_lines)
    local path = vim.fn.tempname() .. "-session.jsonl"
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode({ type = "session", id = id, timestamp = Manifest.iso_now() }) .. "\n")
    for _, line in ipairs(message_lines) do
        f:write(line .. "\n")
    end
    f:close()
    return path
end

--- Wait until a batch item reaches the given status.
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

describe("sub-session abort isolation", function()
    local batch_tmp
    local manifest_tmp
    local real_manifest_path
    local real_create_detached
    local tmp_files

    before_each(function()
        tmp_files = {}
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
        require("pi.subsessions")._reset_abort_epochs()
        Subsessions._reset_child_aborts()
        real_create_detached = Sessions.create_detached
    end)

    after_each(function()
        Sessions.create_detached = real_create_detached
        os.remove(batch_tmp)
        os.remove(manifest_tmp)
        for _, path in ipairs(tmp_files) do
            os.remove(path)
        end
        Batch._reset()
        Manifest.path = real_manifest_path
        Manifest._reset()
        Sessions._reset()
        require("pi.subsessions")._reset_abort_epochs()
        Subsessions._reset_child_aborts()
    end)

    it("T2: aborted child settle is cancelled and never injected as a completion", function()
        local parent_sent = {}
        local parent = {
            id = "parent-uuid-t2",
            rpc = make_mock_rpc(parent_sent),
            attention = { pending = {} },
        }
        local child = {
            id = "child-uuid-t2",
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

        -- Aborted session file: last assistant message stopped with "aborted".
        local path = write_session_jsonl(child.id, {
            vim.json.encode({
                type = "message",
                message = {
                    role = "assistant",
                    stopReason = "aborted",
                    content = { { type = "text", text = "half output" } },
                },
            }),
        })
        tmp_files[#tmp_files + 1] = path
        child.session_file = path
        assert.equals("aborted", Read.last_stop_reason(path))

        local batch_id
        Batch.dispatch(parent, {
            items = { { target = child.id, message = "work" } },
        }, function(res)
            batch_id = res.batch_id
        end)
        assert.is_string(batch_id)
        wait_item_status(batch_id, 1, "running")

        Subsessions.on_child_settled(child)

        -- (a) the in-flight item is cancelled, not booked as ok
        local item = Batch.get(batch_id).items[1]
        assert.equals("cancelled", item.status)
        assert.is_not.equals("ok", item.status)
        -- (b) single-item batch settles as cancelled
        assert.equals("cancelled", Batch.get(batch_id).status)
        -- (c) manifest records the interruption
        assert.equals("interrupted", Manifest.load()[child.id].status)
        -- (d) no completion report is injected into the parent
        assert.is_false(has_message(parent_sent, "prompt"))
    end)

    it("T3: aborting an idle child wakes the parent waiting on its batch", function()
        local parent_sent = {}
        local parent = {
            id = "parent-idle-1",
            rpc = make_mock_rpc(parent_sent),
            attention = { pending = {} },
        }
        local child_sent = {}
        local child = {
            id = "child-idle-1",
            view_parent_id = parent.id,
            rpc = make_mock_rpc(child_sent),
            attention = { pending = {} },
        }
        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        local tab = vim.api.nvim_get_current_tabpage()
        Sessions.bind_chat(parent, make_mock_chat(), tab)
        Manifest.upsert(child.id, {
            parent_id = parent.id,
            status = "active",
            run_generation = 1,
            name = "c",
        })

        local batch_id
        Batch.dispatch(parent, {
            items = { { target = child.id, message = "work" } },
        }, function(res)
            batch_id = res.batch_id
        end)
        assert.is_string(batch_id)
        wait_item_status(batch_id, 1, "running")

        local replied
        Batch.wait(batch_id, function(snap)
            replied = snap
        end, { timeout_ms = 2000 })

        -- The child is idle: no further agent events will arrive for it.
        Sessions.bind_chat(child, make_mock_chat(), tab)
        assert.equals(child.id, Sessions.get().id)

        Pi.abort()

        assert.is_true(
            vim.wait(2000, function()
                return replied ~= nil
            end),
            "waiter was never woken"
        )
        assert.equals("cancelled", replied.status)
        assert.is_false(has_message(parent_sent, "abort"), "parent must not be aborted")
    end)

    it("T4: :PiResume drops stale parentage and abort cascades as a parent", function()
        local session_sent = {}
        local session = {
            id = "parent-uuid-r",
            rpc = make_mock_rpc(session_sent),
            attention = { pending = {} },
            parent_id = "stale-parent",
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }
        Sessions._register_for_test(session)

        local path = write_session_jsonl(session.id, {
            vim.json.encode({
                type = "message",
                message = { role = "user", content = { { type = "text", text = "hi" } } },
            }),
        })
        tmp_files[#tmp_files + 1] = path

        Subsessions.on_parent_resumed(session, path)
        assert.is_nil(session.parent_id)

        -- Branch selection: with parentage cleared, abort cascades to children.
        local child_sent = {}
        local child = {
            id = "child-uuid-r",
            rpc = make_mock_rpc(child_sent),
            attention = { pending = {} },
        }
        Sessions._register_for_test(child)
        Manifest.upsert(child.id, {
            parent_id = session.id,
            status = "active",
            name = "c",
        })

        local tab = vim.api.nvim_get_current_tabpage()
        Sessions.bind_chat(session, make_mock_chat(), tab)
        assert.equals(session.id, Sessions.get().id)

        Pi.abort()

        assert.is_true(has_message(child_sent, "abort"), "child must be interrupted by the parent abort")
    end)

    it("T5: interrupting one child keeps its siblings in the batch running", function()
        local parent_sent = {}
        local child_a_sent = {}
        local child_b_sent = {}
        local parent = {
            id = "parent-uuid-t5",
            rpc = make_mock_rpc(parent_sent),
            attention = { pending = {} },
        }
        local child_a = {
            id = "child-a-t5",
            rpc = make_mock_rpc(child_a_sent),
            attention = { pending = {} },
        }
        local child_b = {
            id = "child-b-t5",
            rpc = make_mock_rpc(child_b_sent),
            attention = { pending = {} },
        }
        Sessions._register_for_test(parent)
        Sessions._register_for_test(child_a)
        Sessions._register_for_test(child_b)

        Manifest.upsert(child_a.id, { parent_id = parent.id, status = "active", name = "a" })
        Manifest.upsert(child_b.id, { parent_id = parent.id, status = "active", name = "b" })

        local batch_id
        Batch.dispatch(parent, {
            cancel_siblings_on_fail = true,
            items = {
                { target = child_a.id, message = "a" },
                { target = child_b.id, message = "b" },
            },
        }, function(res)
            batch_id = res.batch_id
        end)
        assert.is_string(batch_id)
        wait_item_status(batch_id, 1, "running")
        wait_item_status(batch_id, 2, "running")

        assert.equals(1, Batch.interrupt_items_for_child(child_a.id, { reason = "cancelled: user aborted" }))

        local batch = Batch.get(batch_id)
        assert.equals("cancelled", batch.items[1].status)
        assert.equals("running", batch.items[2].status)
        assert.equals("running", batch.status)
        assert.is_false(has_message(child_b_sent, "abort"), "sibling must not be aborted")
    end)

    it("T6: abort epoch guard stops an in-flight interactive spawn", function()
        local parent = {
            id = "parent-uuid-s",
            rpc = make_mock_rpc({}),
            attention = { pending = {} },
            parent_id = nil,
        }
        Sessions._register_for_test(parent)

        local captured
        local spawned = {
            id = nil,
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(_self, msg, cb)
                    if msg.type == "get_state" then
                        captured = cb
                    end
                end,
                stop = function() end,
            },
            attention = { pending = {} },
        }
        Sessions.create_detached = function()
            return spawned
        end

        local result
        Subsessions.spawn(parent, { task = "work" }, function(child, err)
            result = { child = child, err = err }
        end)
        assert.is_function(captured, "get_state callback was not captured")

        Subsessions.mark_lineage_aborted(Manifest.lineage_for_session(parent))

        captured({ success = true, data = { sessionId = "child-uuid-s" } })

        assert.is_true(
            vim.wait(1000, function()
                return result ~= nil
            end),
            "spawn callback was never invoked"
        )
        assert.is_true(result.child == nil, "aborted spawn must not hand a child back: " .. tostring(result.child))
        assert.is_truthy(tostring(result.err):find("aborted while spawning", 1, true))
        assert.is_nil(Sessions.get_by_id("child-uuid-s"))
        assert.is_nil(Manifest.load()["child-uuid-s"])
    end)

    it("T10: child-view abort interrupts own children without touching parent or siblings", function()
        local parent_sent = {}
        local a_sent = {}
        local b_sent = {}
        local s_sent = {}
        local parent = {
            id = "p",
            rpc = make_mock_rpc(parent_sent),
            attention = { pending = {} },
        }
        local a = {
            id = "a",
            view_parent_id = "p",
            rpc = make_mock_rpc(a_sent),
            attention = { pending = {} },
        }
        local b = {
            id = "b",
            rpc = make_mock_rpc(b_sent),
            attention = { pending = {} },
        }
        local s = {
            id = "s",
            rpc = make_mock_rpc(s_sent),
            attention = { pending = {} },
        }
        Sessions._register_for_test(parent)
        Sessions._register_for_test(a)
        Sessions._register_for_test(b)
        Sessions._register_for_test(s)

        Manifest.upsert(b.id, { parent_id = a.id, status = "active", name = "b" })
        Manifest.upsert(s.id, { parent_id = parent.id, status = "active", name = "s" })

        local tab = vim.api.nvim_get_current_tabpage()
        Sessions.bind_chat(a, make_mock_chat(), tab)
        assert.equals(a.id, Sessions.get().id)

        Pi.abort()

        assert.is_true(has_message(a_sent, "abort"), "A must be aborted")
        assert.is_true(has_message(b_sent, "abort"), "A's child B must be aborted")
        assert.is_false(has_message(parent_sent, "abort"), "parent must not be aborted")
        assert.is_false(has_message(s_sent, "abort"), "A's sibling S must not be aborted")
    end)
end)
