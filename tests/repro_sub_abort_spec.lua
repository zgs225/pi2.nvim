-- Regression spec: PiAbort during sub-wait.
-- These cases originally reproduced six failure modes of :PiAbort while a parent
-- session was blocked in wait_subagents; they now assert the FIXED behavior.
-- Case 4 is the exception: it documents intended double-<Esc> guard behavior
-- (inert while not streaming/retrying), which is by design and unchanged.

local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")
local Pi = require("pi")
local Config = require("pi.config")

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

describe("regression: PiAbort during sub-wait", function()
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

    it("Case 1: PiAbort in child view aborts the parent session and cancels the batch", function()
        local parent_sent = {}
        local child_sent = {}

        local parent = {
            id = "parent-uuid-1",
            lineage_id = "parent-uuid-1",
            rpc = make_mock_rpc(parent_sent),
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        local child = {
            id = "child-uuid-1",
            view_parent_id = "parent-uuid-1",
            rpc = make_mock_rpc(child_sent),
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        local tab = vim.api.nvim_get_current_tabpage()

        -- Bind parent to tab
        local chat = make_mock_chat()
        Sessions.bind_chat(parent, chat, tab)
        Manifest.upsert(parent.id, {
            parent_id = parent.id,
            status = "active",
            name = "parent",
        })

        -- Parent dispatches a batch
        local batch_id
        Batch.dispatch(parent, {
            items = { { target = child.id, message = "do work" } },
        }, function(res)
            batch_id = res.batch_id
        end)

        assert.is_string(batch_id)
        local initial_snap = Batch.get(batch_id)
        assert.equals("running", initial_snap.status)

        -- Now simulate user switching view to child session (:PiSubSwitch)
        child.view_parent_id = parent.id
        Sessions.bind_chat(child, chat, tab)
        assert.equals(child.id, Sessions.get().id)

        -- User executes Pi.abort()
        Pi.abort()

        local child_aborted = false
        for _, msg in ipairs(child_sent) do
            if msg.type == "abort" then
                child_aborted = true
            end
        end
        local parent_aborted = false
        for _, msg in ipairs(parent_sent) do
            if msg.type == "abort" then
                parent_aborted = true
            end
        end
        local current_batch = Batch.get(batch_id)

        -- FIXED: the abort reaches BOTH the child and the parent, and the
        -- batch is cancelled via the parent's lineage.
        assert.is_true(child_aborted, "Child received abort")
        assert.is_true(parent_aborted, "Parent received abort while viewing the child")
        assert.equals("cancelled", current_batch.status)
    end)

    it("Case 2: extensions/subagent.ts forwards the tool AbortSignal to the host select", function()
        -- Inspect extensions/subagent.ts source code directly
        local ts_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/extensions/subagent.ts"
        local file = io.open(ts_path, "r")
        assert.is_not_nil(file, "subagent.ts exists")
        local content = file:read("*a")
        file:close()

        -- FIXED: wait_subagents / dispatch_subagents accept `signal` and pass
        -- it into hostRequest (balanced-match patterns: the parameters schema
        -- contains nested braces, so [^}] cannot span the block).
        for _, action in ipairs({ "wait_subagents", "dispatch_subagents" }) do
            local params, body = content:match('name:%s*"' .. action .. '".-async execute%s*(%b())%s*(%b{})')
            assert.is_not_nil(params, action .. " execute parameters must exist")
            assert.is_not_nil(body, action .. " execute body must exist")
            assert.is_truthy(
                params:match("[^_]signal") ~= nil,
                action .. " execute must accept `signal` (not `_signal`), got: " .. params
            )
            assert.is_truthy(
                body:match('hostRequest%(ctx,%s*"' .. action .. '",%s*params,%s*signal%)'),
                action .. " execute body must pass signal to hostRequest, got: " .. body
            )
        end

        -- FIXED: hostRequest accepts a signal parameter.
        local host_request_decl = content:match("async function hostRequest%(([^%)]*)%)")
        assert.is_not_nil(host_request_decl)
        assert.is_not_nil(host_request_decl:match("signal"), "hostRequest must accept a signal parameter")

        -- FIXED: ctx.ui.select receives an options object referencing signal,
        -- so rpc-mode's createDialogPromise resolves on core abort.
        local select_call = content:match("ctx%.ui%.select%([^%)]+%)")
        assert.is_not_nil(select_call)
        assert.is_not_nil(select_call:match("signal"), "ctx.ui.select must receive { signal } options")
    end)

    it("Case 3: PiAbort with a stale tmp session id still resolves the real batch lineage", function()
        local parent_sent = {}
        local parent = {
            id = "tmp-12345678-1",
            rpc = make_mock_rpc(parent_sent),
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        Sessions._register_for_test(parent)
        local tab = vim.api.nvim_get_current_tabpage()
        Sessions.bind_chat(parent, make_mock_chat(), tab)

        -- Dispatch batch using parent
        local batch_id
        Batch.dispatch(parent, {
            items = { { task = "some task" } },
        }, function(res)
            batch_id = res.batch_id
        end)

        vim.wait(1000, function()
            return batch_id ~= nil
        end)
        assert.is_string(batch_id)
        local batch = Batch.get(batch_id)
        -- The batch parent_id was resolved to real-uuid-123:
        assert.equals("real-uuid-123", batch.parent_id)

        -- Simulate a stale session id (e.g. reset or observed before migration).
        parent.id = "tmp-12345678-1"
        parent.lineage_id = nil

        -- User triggers PiAbort
        Pi.abort()

        -- FIXED: migrate_session_id aliased tmp-... -> real-uuid-123 in the
        -- lineage map, so cancel_for_parent("tmp-...") resolves to the real id.
        local after_abort_batch = Batch.get(batch_id)
        assert.equals("cancelled", after_abort_batch.status)
    end)

    it("Case 4: double-<Esc> stays inert while not streaming/retrying (by design)", function()
        -- Test Chat:_handle_abort_esc
        local Chat = require("pi.ui.chat")
        -- Create a mock chat object similar to Chat.new
        local chat_inst = setmetatable({
            _streaming = false,
            _retrying = false,
            _bash_running = false,
            _abort_esc_at = nil,
            _prompt = {
                statusline = function()
                    return {
                        set_abort_hint = function() end,
                        clear_abort_hint = function() end,
                    }
                end,
            },
        }, { __index = Chat })

        local abort_called = false
        local real_abort = Pi.abort
        Pi.abort = function()
            abort_called = true
        end

        -- Call _handle_abort_esc twice
        chat_inst:_handle_abort_esc()
        chat_inst:_handle_abort_esc()

        Pi.abort = real_abort

        -- BY DESIGN: outside streaming/retrying, <Esc> keeps its normal
        -- behavior (the gesture never arms). During sub-wait the parent's turn
        -- is still active, so _streaming stays true and the gesture works;
        -- view switches restore it via Chat:restore_busy().
        assert.is_false(abort_called)
        assert.is_nil(chat_inst._abort_esc_at)
    end)

    it("Case 5: spawning sub-session is aborted and closed when its batch is cancelled", function()
        local orig_spawn = Subsessions.spawn
        local spawn_cb = nil

        Subsessions.spawn = function(parent, opts, callback)
            spawn_cb = callback
        end

        local parent = {
            id = "parent-spawn-test",
            lineage_id = "parent-spawn-test",
            rpc = make_mock_rpc(),
        }

        local batch_id
        Batch.dispatch(parent, {
            items = { { task = "task to spawn" } },
        }, function(res)
            batch_id = res.batch_id
        end)

        vim.wait(1000, function()
            local b = Batch.get(batch_id)
            return b and b.items[1] and b.items[1].status == "spawning"
        end)

        local b = Batch.get(batch_id)
        assert.equals("running", b.status)
        assert.equals("spawning", b.items[1].status)

        -- Now user aborts before spawn completes!
        Batch.cancel(batch_id)
        assert.equals("cancelled", Batch.get(batch_id).status)

        -- The async spawn completes afterwards: the real spawn would have
        -- registered the manifest entry by now (stub skipped it, so seed it).
        Manifest.upsert("leaked-child-1", {
            parent_id = "parent-spawn-test",
            name = "leaked",
            task_prompt = "task to spawn",
            config = {},
            status = "active",
            reported = false,
            created_at = Manifest.iso_now(),
            last_active_at = Manifest.iso_now(),
        })

        local leaked_child_sent = {}
        local leaked_child = {
            id = "leaked-child-1",
            rpc = make_mock_rpc(leaked_child_sent),
        }

        assert.is_not_nil(spawn_cb, "Spawn callback was captured")

        -- Invoke the REAL batch.lua spawn callback with the completed child.
        spawn_cb(leaked_child, nil)

        -- FIXED: the late child is aborted and closed, and the manifest entry
        -- no longer occupies an active spawn slot.
        local child_aborted = false
        for _, msg in ipairs(leaked_child_sent) do
            if msg.type == "abort" then
                child_aborted = true
            end
        end
        assert.is_true(child_aborted, "Late-spawned child received abort")
        assert.equals("interrupted", Manifest.load()["leaked-child-1"].status)
        assert.equals(0, Manifest.spawn_occupancy("parent-spawn-test"))

        Subsessions.spawn = orig_spawn
    end)

    it("Case 6: PiAbort cancels a waited batch from a different lineage (waiter owner)", function()
        -- Suppose LLM called wait_subagents for a batch belonging to an older session / lineage
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
        -- Re-save into batch_tmp
        local f = io.open(batch_tmp, "w")
        f:write(vim.json.encode(batches))
        f:close()
        Batch._reset()
        Batch._set_path(batch_tmp)

        local parent = {
            id = "current-parent-111",
            lineage_id = "current-lineage-111",
            rpc = make_mock_rpc(),
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }
        Sessions._register_for_test(parent)
        local tab = vim.api.nvim_get_current_tabpage()
        Sessions.bind_chat(parent, make_mock_chat(), tab)

        -- Extension host handles wait_subagents for other_batch_id
        local select_replied = false
        local host_payload = vim.json.encode({
            action = "wait_subagents",
            params = { batch_id = other_batch_id, timeout_ms = 60000 },
        })
        Subsessions.handle_host(parent, host_payload, function(result)
            select_replied = true
        end)

        -- Now user triggers PiAbort in the current parent session!
        Pi.abort()

        -- FIXED: cancel_for_parent also matches batches the current lineage is
        -- actively WAITING on (waiter owner), regardless of batch lineage.
        local current_other_batch = Batch.get(other_batch_id)
        assert.equals("cancelled", current_other_batch.status)

        -- The waiter is notified (notify_waiters schedules the callback), so
        -- the pending host select gets its extension_ui_response.
        vim.wait(1000, function()
            return select_replied
        end)
        assert.is_true(select_replied, "Waiter was notified after abort")
    end)
end)
