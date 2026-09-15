-- Regression spec for the generation-race / spawn-window / per-child-pcall
-- abort fixes (third rework round). Promotes the adversarial acceptance repros
-- (R2/R3/R4) into repo-owned tests with stronger assertions and adds the
-- missing cascading-abort coverage:
--
--   N1 (= R3) a LATE aborted settle of run N must not cancel run N+1's item
--   N2 (= R4) an abort landing inside the apply_config window still reclaims
--             the child instead of starting its task
--   N3        one child's `send` raising must not truncate the abort cascade
--   N4        Batch.abort is abort-only: it never closes/stops a child process
--   N5 (= R2) interrupting one child keeps its siblings running and the waiter
--             asleep until the batch is actually terminal
--   N6        the per-child abort watermark is monotonic and reset-scoped

local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")
local Pi = require("pi")

---@class pi.TestMockRpc
---@field stops integer Number of `stop` calls (proves abort did not close it).
---@field is_running fun(): boolean
---@field stop fun()
---@field send fun(self: any, msg: table, cb?: fun(res: table)): boolean

--- Mock RPC that records every outbound message and optionally runs a
--- per-message-type handler (used to park the spawn chain inside apply_config).
---@param sent_list? table[] Receives every sent message.
---@param handlers? table<string, fun(msg: table, cb?: fun(res: table))>
---@return pi.TestMockRpc
local function make_mock_rpc(sent_list, handlers)
    ---@type pi.TestMockRpc
    local rpc
    rpc = {
        stops = 0,
        is_running = function()
            return true
        end,
        stop = function()
            rpc.stops = rpc.stops + 1
        end,
        send = function(_self, msg, cb)
            if sent_list then
                table.insert(sent_list, msg)
            end
            if handlers and handlers[msg.type] then
                handlers[msg.type](msg, cb)
                return true
            end
            if msg.type == "get_state" and cb then
                cb({ success = true, data = { sessionId = "real-uuid-123" } })
            elseif cb then
                cb({ success = true })
            end
            return true
        end,
    }
    return rpc
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
        render_statusline = function() end,
        refresh_prompt_attention = function() end,
    }
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

describe("sub-session abort generation race", function()
    local batch_tmp
    local manifest_tmp
    local real_manifest_path
    local real_create_detached
    local real_close_session
    local real_subsessions_close
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
        Subsessions._reset_abort_epochs()
        Subsessions._reset_child_aborts()
        real_create_detached = Sessions.create_detached
        real_close_session = Sessions.close_session
        real_subsessions_close = Subsessions.close
    end)

    after_each(function()
        Sessions.create_detached = real_create_detached
        Sessions.close_session = real_close_session
        Subsessions.close = real_subsessions_close
        os.remove(batch_tmp)
        os.remove(manifest_tmp)
        for _, path in ipairs(tmp_files) do
            os.remove(path)
        end
        Batch._reset()
        Manifest.path = real_manifest_path
        Manifest._reset()
        Sessions._reset()
        Subsessions._reset_abort_epochs()
        Subsessions._reset_child_aborts()
    end)

    it("N1: a late aborted settle of run N must not cancel run N+1's item", function()
        local parent = { id = "p-n1", rpc = make_mock_rpc({}), attention = { pending = {} } }
        local child = { id = "c-n1", rpc = make_mock_rpc({}), attention = { pending = {} } }
        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        Manifest.upsert(child.id, {
            parent_id = parent.id,
            status = "active",
            name = "c",
            run_generation = 0,
            agent_spawned = true,
        })

        -- Run 1 owns the child at generation 1.
        local batch1
        Batch.dispatch(parent, { items = { { target = child.id, message = "run1" } } }, function(res)
            batch1 = res.batch_id
        end)
        assert.is_string(batch1)
        wait_item_status(batch1, 1, "running")
        local gen1 = Manifest.load()[child.id].run_generation
        assert.equals(1, gen1)
        assert.equals(1, Batch.get(batch1).items[1].generation)

        -- User aborts the child: the watermark records run 1 and its item dies.
        assert.equals(
            1,
            Batch.interrupt_items_for_child(child.id, { generation = gen1, reason = "cancelled: user aborted" })
        )
        assert.equals("cancelled", Batch.get(batch1).items[1].status)
        assert.equals(gen1, Subsessions.aborted_generation(child.id), "abort watermark must record run 1")

        -- The parent immediately reuses the same child: generation 2.
        local batch2
        Batch.dispatch(parent, { items = { { target = child.id, message = "run2" } } }, function(res)
            batch2 = res.batch_id
        end)
        assert.is_string(batch2)
        wait_item_status(batch2, 1, "running")
        assert.equals(2, Manifest.load()[child.id].run_generation)
        assert.equals(2, Batch.get(batch2).items[1].generation)

        -- The late `agent_settled` of the aborted run 1 finally arrives. Its
        -- session file still ends with run 1's aborted tail, and the settle
        -- event itself carries no generation.
        local path = write_session_jsonl(child.id, {
            vim.json.encode({
                type = "message",
                message = {
                    role = "assistant",
                    stopReason = "aborted",
                    content = { { type = "text", text = "half" } },
                },
            }),
        })
        tmp_files[#tmp_files + 1] = path
        child.session_file = path

        Subsessions.on_child_settled(child)

        -- Core: the late settle must not kill the live run-2 item, and it must
        -- not downgrade the manifest for a child the parent already reused.
        assert.equals("running", Batch.get(batch2).items[1].status, "late settle cancelled run N+1's item")
        assert.equals("running", Batch.get(batch2).status, "batch 2 must stay running")
        assert.equals("active", Manifest.load()[child.id].status, "reused child must not be marked interrupted")
    end)

    it("N2: abort during the apply_config window reclaims the child before send_task", function()
        local parent = {
            id = "p-n2",
            rpc = make_mock_rpc({}),
            attention = { pending = {} },
            -- Pinned config => resolve_child_config returns a config, so
            -- apply_config does an async set_model round-trip first.
            pinned_config = { model = { provider = "prov", id = "mod" } },
        }
        Sessions._register_for_test(parent)

        local child_sent = {}
        local set_model_cb
        local spawned = {
            id = "tmp-n2",
            rpc = make_mock_rpc(child_sent, {
                get_state = function(_msg, cb)
                    cb({ success = true, data = { sessionId = "child-n2" } })
                end,
                set_model = function(_msg, cb)
                    set_model_cb = cb -- hold it: the abort lands while in flight
                end,
            }),
            attention = { pending = {} },
        }
        local create_calls = 0
        Sessions.create_detached = function()
            create_calls = create_calls + 1
            return spawned
        end

        local close_session_calls = {}
        Sessions.close_session = function(session)
            close_session_calls[#close_session_calls + 1] = session
        end

        local result
        Subsessions.spawn(parent, { task = "do the work" }, function(child, err)
            result = { child = child, err = err }
        end)
        assert.equals(1, create_calls)

        -- get_state answers via vim.schedule; pump until the chain parks inside
        -- apply_config waiting for set_model.
        assert.is_true(
            vim.wait(1000, function()
                return set_model_cb ~= nil
            end),
            "spawn should be parked in apply_config"
        )
        assert.is_not_nil(Manifest.load()["child-n2"], "manifest entry exists once parked in apply_config")
        assert.equals("active", Manifest.load()["child-n2"].status)

        -- User aborts the parent, bumping the lineage abort epoch.
        Subsessions.mark_lineage_aborted(Manifest.lineage_for_session(parent))

        -- set_model finally succeeds: the complete guard must bail out here.
        set_model_cb({ success = true })
        assert.is_true(
            vim.wait(1000, function()
                return result ~= nil
            end),
            "spawn callback was never invoked"
        )

        assert.is_false(has_message(child_sent, "prompt"), "task was sent to the child AFTER the abort")
        assert.is_nil(result.child, "aborted spawn must not hand a child back")
        assert.is_truthy(tostring(result.err):find("aborted while spawning", 1, true))
        assert.is_true(#close_session_calls >= 1, "the reclaimed child process must be closed")
        local entry = Manifest.load()["child-n2"]
        assert.is_not_nil(entry, "manifest entry must exist")
        assert.equals("interrupted", entry.status)
    end)

    it("N3: a child whose send raises does not truncate the abort cascade", function()
        local parent_sent = {}
        local parent = { id = "p-n3", rpc = make_mock_rpc(parent_sent), attention = { pending = {} } }

        local throw_sent = {}
        local throw_attempted = false
        local throws = {
            id = "c-n3-throws",
            rpc = make_mock_rpc(throw_sent, {
                abort = function()
                    throw_attempted = true
                    error("boom")
                end,
            }),
            attention = { pending = {} },
        }
        local ok_sent = {}
        local ok_child = { id = "c-n3-ok", rpc = make_mock_rpc(ok_sent), attention = { pending = {} } }

        Sessions._register_for_test(parent)
        Sessions._register_for_test(throws)
        Sessions._register_for_test(ok_child)
        -- children_of sorts by created_at descending: the throwing child is
        -- processed FIRST, so only a working per-child pcall lets the sibling
        -- after it still receive the abort.
        Manifest.upsert(throws.id, {
            parent_id = parent.id,
            status = "active",
            name = "throws",
            created_at = "2026-01-02T00:00:00Z",
        })
        Manifest.upsert(ok_child.id, {
            parent_id = parent.id,
            status = "active",
            name = "ok",
            created_at = "2026-01-01T00:00:00Z",
        })
        assert.equals(throws.id, Manifest.children_of(parent.id)[1]._id, "throwing child must be processed first")

        local tab = vim.api.nvim_get_current_tabpage()
        Sessions.bind_chat(parent, make_mock_chat(), tab)
        assert.equals(parent.id, Sessions.get().id)

        Pi.abort()

        assert.is_true(has_message(parent_sent, "abort"), "parent must be aborted")
        assert.is_true(throw_attempted, "the throwing child must have been attempted")
        assert.is_true(has_message(ok_sent, "abort"), "the sibling after the throwing child must still be aborted")
    end)

    it("N4: Batch.abort is abort-only and never closes or stops the child process", function()
        local parent_sent = {}
        local parent = {
            id = "p-n4",
            rpc = make_mock_rpc(parent_sent),
            attention = { pending = { { id = "p-att" } } },
        }
        local child_sent = {}
        local child = {
            id = "c-n4",
            rpc = make_mock_rpc(child_sent),
            attention = { pending = { { id = "c-att" } } },
        }
        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        Manifest.upsert(child.id, { parent_id = parent.id, status = "active", name = "c" })

        local batch_id
        Batch.dispatch(parent, { items = { { target = child.id, message = "work" } } }, function(res)
            batch_id = res.batch_id
        end)
        assert.is_string(batch_id)
        wait_item_status(batch_id, 1, "running")

        local subs_close_calls = 0
        Subsessions.close = function()
            subs_close_calls = subs_close_calls + 1
            return false
        end
        local close_session_calls = 0
        Sessions.close_session = function()
            close_session_calls = close_session_calls + 1
        end

        local tab = vim.api.nvim_get_current_tabpage()
        Sessions.bind_chat(parent, make_mock_chat(), tab)
        Pi.abort()

        -- Batch.abort and interrupt_children may each abort the child: assert
        -- "at least one", never an exact count.
        assert.is_true(has_message(child_sent, "abort"), "child must be aborted")
        local batch = Batch.get(batch_id)
        assert.equals("cancelled", batch.status)
        assert.equals("cancelled", batch.items[1].status)
        assert.equals(0, subs_close_calls, "abort must not call Subsessions.close")
        assert.equals(0, close_session_calls, "abort must not call Sessions.close_session")
        assert.equals(0, child.rpc.stops, "abort must not stop the child process")
        assert.equals(0, #parent.attention.pending, "parent attention must be cleared")
    end)

    it("N5: interrupting one child keeps its siblings running and the waiter asleep", function()
        local parent = { id = "p-n5", rpc = make_mock_rpc({}), attention = { pending = {} } }
        local ca = { id = "ca-n5", rpc = make_mock_rpc({}), attention = { pending = {} } }
        local cb = { id = "cb-n5", rpc = make_mock_rpc({}), attention = { pending = {} } }
        Sessions._register_for_test(parent)
        Sessions._register_for_test(ca)
        Sessions._register_for_test(cb)
        Manifest.upsert(ca.id, { parent_id = parent.id, status = "active", name = "a" })
        Manifest.upsert(cb.id, { parent_id = parent.id, status = "active", name = "b" })

        local batch_id
        Batch.dispatch(parent, {
            items = { { target = ca.id, message = "a" }, { target = cb.id, message = "b" } },
        }, function(res)
            batch_id = res.batch_id
        end)
        assert.is_string(batch_id)
        wait_item_status(batch_id, 1, "running")
        wait_item_status(batch_id, 2, "running")

        local woken = false
        Batch.wait(batch_id, function()
            woken = true
        end, { timeout_ms = 5000, interval_ms = 50 })

        Batch.interrupt_items_for_child(ca.id, {})

        local batch = Batch.get(batch_id)
        assert.equals("cancelled", batch.items[1].status)
        assert.equals("running", batch.items[2].status)
        assert.equals("running", batch.status, "batch must stay running while a sibling runs")
        assert.is_false(woken, "waiter must not be woken before terminal")

        -- Settling the surviving sibling makes the batch partial and wakes it.
        Batch.complete_item(batch_id, batch.items[2].ref, true, { output = "done" })
        assert.equals("partial", Batch.get(batch_id).status)
        assert.is_true(
            vim.wait(1000, function()
                return woken
            end),
            "waiter should wake once terminal"
        )
    end)

    it("N6: the per-child abort watermark is monotonic and reset-scoped", function()
        assert.is_nil(Subsessions.aborted_generation("c-n6"), "unknown child has no watermark")

        Subsessions.mark_child_aborted("c-n6", 3)
        assert.equals(3, Subsessions.aborted_generation("c-n6"))

        -- An older run settling later must never lower the watermark.
        Subsessions.mark_child_aborted("c-n6", 1)
        assert.equals(3, Subsessions.aborted_generation("c-n6"), "watermark must be monotonic")

        -- Nil / non-numeric generations are ignored, not coerced.
        Subsessions.mark_child_aborted("c-n6", nil)
        Subsessions.mark_child_aborted("c-n6", "2")
        assert.equals(3, Subsessions.aborted_generation("c-n6"))

        Subsessions._reset_child_aborts()
        assert.is_nil(Subsessions.aborted_generation("c-n6"), "reset must drop watermarks")
    end)

    it("N7: Batch.abort survives a raising child send and still persists + wakes waiters", function()
        local parent = { id = "p-n7", rpc = make_mock_rpc({}), attention = { pending = {} } }
        local child_sent = {}
        local child = {
            id = "c-n7",
            rpc = make_mock_rpc(child_sent, {
                abort = function()
                    error("boom")
                end,
            }),
            attention = { pending = {} },
        }
        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        Manifest.upsert(child.id, { parent_id = parent.id, status = "active", name = "c" })

        local batch_id
        Batch.dispatch(parent, { items = { { target = child.id, message = "work" } } }, function(res)
            batch_id = res.batch_id
        end)
        assert.is_string(batch_id)
        wait_item_status(batch_id, 1, "running")
        assert.is_true(has_message(child_sent, "prompt"), "fixture: the task must have been sent")

        local woken
        Batch.wait(batch_id, function(snap)
            woken = snap
        end, { timeout_ms = 3000, interval_ms = 50 })

        -- Deliberately NOT wrapped in pcall: the per-child pcall inside
        -- abort_child_process must keep the raising send from escaping here.
        local ok = Batch.abort(batch_id)
        assert.is_true(ok)
        assert.is_true(has_message(child_sent, "abort"), "the abort must still be attempted")
        assert.equals("cancelled", Batch.get(batch_id).status)
        assert.equals("cancelled", Batch.get(batch_id).items[1].status)

        -- Drop the caches so the next load() re-reads from disk: the item loop
        -- must have reached persist() even though the child's send raised.
        -- (_reset also clears the path override, so point it back at the temp
        -- file; it is the same file the batch was written to.)
        Batch._reset()
        Batch._set_path(batch_tmp)
        local persisted = Batch.get(batch_id)
        assert.is_not_nil(persisted, "cancelled batch must be persisted to disk")
        assert.equals("cancelled", persisted.status, "persist() must run after the raising child send")
        assert.equals("cancelled", persisted.items[1].status)

        assert.is_true(
            vim.wait(2000, function()
                return woken ~= nil
            end),
            "notify_waiters must still wake the waiter"
        )
        assert.equals("cancelled", woken.status)
    end)

    it("N8: every plugin-issued abort records the child's generation watermark", function()
        local parent_sent = {}
        local parent = { id = "p-n8", rpc = make_mock_rpc(parent_sent), attention = { pending = {} } }
        local batch_sent = {}
        local batch_child = {
            id = "c-n8-batch",
            rpc = make_mock_rpc(batch_sent),
            attention = { pending = {} },
        }
        local plain_sent = {}
        local plain_child = {
            id = "c-n8-plain",
            rpc = make_mock_rpc(plain_sent),
            attention = { pending = {} },
        }
        Sessions._register_for_test(parent)
        Sessions._register_for_test(batch_child)
        Sessions._register_for_test(plain_child)
        -- Neither child owns a batch: both are reached through the parent
        -- cascade (interrupt_children) only.
        Manifest.upsert(batch_child.id, {
            parent_id = parent.id,
            status = "active",
            name = "b",
            run_generation = 0,
        })
        Manifest.upsert(plain_child.id, {
            parent_id = parent.id,
            status = "active",
            name = "p",
            run_generation = 5,
        })

        local tab = vim.api.nvim_get_current_tabpage()
        Sessions.bind_chat(parent, make_mock_chat(), tab)
        assert.equals(parent.id, Sessions.get().id)
        assert.is_nil(Subsessions.aborted_generation(batch_child.id), "no watermark before the abort")
        assert.is_nil(Subsessions.aborted_generation(plain_child.id), "no watermark before the abort")

        Pi.abort()

        assert.is_true(has_message(parent_sent, "abort"), "parent must be aborted")
        assert.is_true(has_message(plain_sent, "abort"), "the batch-less sibling must be aborted")
        assert.is_true(has_message(batch_sent, "abort"), "the other sibling must be aborted")
        -- Core: a cascaded abort records the generation straight from the
        -- manifest, even for a child with no in-flight batch item.
        assert.equals(
            5,
            Subsessions.aborted_generation(plain_child.id),
            "cascaded abort must record the declared run_generation"
        )
        assert.equals(
            0,
            Subsessions.aborted_generation(batch_child.id),
            "run_generation 0 is a number and must be recorded, not treated as absent"
        )

        -- Extra: a top-level session with no manifest entry must never get a
        -- fabricated watermark.
        local top = { id = "plain-top", rpc = make_mock_rpc({}), attention = { pending = {} } }
        Sessions._register_for_test(top)
        Sessions.bind_chat(top, make_mock_chat(), tab)
        assert.equals(top.id, Sessions.get().id)
        Pi.abort()
        assert.is_nil(Subsessions.aborted_generation("plain-top"), "no manifest entry -> no watermark")
    end)

    it("N9: an abort landing inside with_parent_id's id lookup cancels the spawn", function()
        -- A `tmp-` id forces with_parent_id onto its async get_state path, which
        -- parks the whole spawn before anything is reserved or created.
        local parent_get_state_cb
        local parent_sent = {}
        local parent = {
            id = "tmp-parent-n9",
            rpc = make_mock_rpc(parent_sent, {
                get_state = function(_msg, cb)
                    parent_get_state_cb = cb -- hold it: the abort lands in this window
                end,
            }),
            attention = { pending = {} },
        }
        Sessions._register_for_test(parent)
        -- Pin the pre-migration lineage key the abort has to bump.
        assert.equals("tmp-parent-n9", Manifest.lineage_for_session(parent))

        local child_sent = {}
        local spawned = {
            id = "tmp-child-n9",
            rpc = make_mock_rpc(child_sent, {
                get_state = function(_msg, cb)
                    cb({ success = true, data = { sessionId = "child-n9" } })
                end,
            }),
            attention = { pending = {} },
        }
        local create_calls = 0
        Sessions.create_detached = function()
            create_calls = create_calls + 1
            return spawned
        end

        local result
        Subsessions.spawn(parent, { task = "work" }, function(child, err)
            result = { child = child, err = err }
        end)
        assert.is_function(parent_get_state_cb, "spawn must be parked in with_parent_id")
        assert.is_nil(result, "spawn must not have finished yet")

        -- Abort lands while the parent's own id lookup is in flight, under the
        -- pre-migration key. It must be caught by the entry-epoch guard.
        Subsessions.mark_lineage_aborted("tmp-parent-n9")

        parent_get_state_cb({ success = true, data = { sessionId = "parent-n9-real" } })
        assert.is_true(
            vim.wait(1500, function()
                return result ~= nil
            end),
            "spawn callback was never invoked"
        )

        assert.is_nil(result.child, "aborted spawn must not hand a child back")
        assert.is_truthy(tostring(result.err):find("aborted while spawning", 1, true))
        assert.is_nil(Manifest.load()["child-n9"], "aborted spawn must not leave a manifest entry")
        assert.equals(0, create_calls, "nothing may be created once the abort is known")
        assert.is_false(has_message(child_sent, "prompt"), "the task must never reach the child")
    end)
end)
