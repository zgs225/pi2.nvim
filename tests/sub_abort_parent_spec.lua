local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")
local Pi = require("pi")

local function make_mock_rpc(sent_list, running_override)
    return {
        is_running = function()
            if running_override ~= nil then
                return running_override
            end
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
        render_statusline = function() end,
        refresh_prompt_attention = function() end,
    }
end

local function has_abort(messages)
    for _, msg in ipairs(messages) do
        if msg.type == "abort" then
            return true
        end
    end
    return false
end

describe("sub-session abort propagation and lineage resolution", function()
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
        Subsessions._reset_abort_epochs()
        Subsessions._reset_child_aborts()
    end)

    after_each(function()
        os.remove(batch_tmp)
        os.remove(manifest_tmp)
        Batch._reset()
        Manifest.path = real_manifest_path
        Manifest._reset()
        Sessions._reset()
        Subsessions._reset_abort_epochs()
        Subsessions._reset_child_aborts()
    end)

    it("Child-view abort stays inside the child", function()
        local parent_sent = {}
        local child_sent = {}

        local parent = {
            id = "parent-uuid-1",
            lineage_id = "parent-uuid-1",
            rpc = make_mock_rpc(parent_sent),
            attention = { pending = { { id = "parent-att" } } },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        local child = {
            id = "child-uuid-1",
            view_parent_id = "parent-uuid-1",
            rpc = make_mock_rpc(child_sent),
            attention = { pending = { { id = "child-att" } } },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        local tab = vim.api.nvim_get_current_tabpage()

        local chat = make_mock_chat()
        Sessions.bind_chat(parent, chat, tab)
        Manifest.upsert(parent.id, {
            parent_id = parent.id,
            status = "active",
            name = "parent",
        })

        local batch_id
        Batch.dispatch(parent, {
            items = { { target = child.id, message = "do work" } },
        }, function(res)
            batch_id = res.batch_id
        end)

        assert.is_string(batch_id)
        local initial_snap = Batch.get(batch_id)
        assert.equals("running", initial_snap.status)

        child.view_parent_id = parent.id
        Sessions.bind_chat(child, chat, tab)
        assert.equals(child.id, Sessions.get().id)

        Pi.abort()

        assert.is_true(has_abort(child_sent), "Child received abort")
        assert.is_false(has_abort(parent_sent), "Parent must not receive the child-view abort")
        local current_batch = Batch.get(batch_id)
        assert.equals("cancelled", current_batch.status)
        assert.equals("cancelled", current_batch.items[1].status)
        assert.equals(1, #parent.attention.pending)
        assert.equals(0, #child.attention.pending)
    end)

    it("Child-view abort with an idle child still isolates the parent", function()
        local parent_sent = {}
        local child_sent = {}

        local parent = {
            id = "parent-uuid-2",
            lineage_id = "parent-uuid-2",
            rpc = make_mock_rpc(parent_sent, true),
            attention = { pending = { { id = "parent-att" } } },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        local child = {
            id = "child-uuid-2",
            view_parent_id = "parent-uuid-2",
            rpc = make_mock_rpc(child_sent, false),
            attention = { pending = { { id = "child-att" } } },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        local tab = vim.api.nvim_get_current_tabpage()

        local chat = make_mock_chat()
        Sessions.bind_chat(parent, chat, tab)
        Manifest.upsert(parent.id, {
            parent_id = parent.id,
            status = "active",
            name = "parent",
        })

        local batch_id
        Batch.dispatch(parent, {
            items = { { target = child.id, message = "do work" } },
        }, function(res)
            batch_id = res.batch_id
        end)

        assert.is_string(batch_id)
        assert.equals("running", Batch.get(batch_id).status)

        child.view_parent_id = parent.id
        Sessions.bind_chat(child, chat, tab)
        assert.equals(child.id, Sessions.get().id)

        Pi.abort()

        -- An idle child cannot be sent `abort`, but its pending batch item is
        -- still cancelled so a parent blocked in wait_subagents wakes up — and
        -- the parent itself must stay untouched.
        assert.is_false(has_abort(child_sent), "Non-running child did not receive abort")
        assert.is_false(has_abort(parent_sent), "Parent must not receive the child-view abort")
        assert.equals(1, #parent.attention.pending)
        assert.equals(0, #child.attention.pending)
        local current_batch = Batch.get(batch_id)
        assert.equals("cancelled", current_batch.status)
        assert.equals("cancelled", current_batch.items[1].status)
        assert.is_string(current_batch.items[1].error, "cancelled item carries a reason")
    end)

    it("Parent-view abort cascades to active children without closing processes", function()
        local parent_sent = {}
        local active_sent = {}
        local done_sent = {}

        local parent = {
            id = "parent-view-1",
            lineage_id = "parent-view-1",
            rpc = make_mock_rpc(parent_sent),
            attention = { pending = { { id = "parent-att" } } },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        local active_child = {
            id = "active-child",
            rpc = make_mock_rpc(active_sent),
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        local done_child = {
            id = "done-child",
            rpc = make_mock_rpc(done_sent),
            attention = { pending = { { id = "done-att" } } },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        -- An abort-only cascade must never stop a child process.
        local active_stops, done_stops = 0, 0
        active_child.rpc.stop = function()
            active_stops = active_stops + 1
        end
        done_child.rpc.stop = function()
            done_stops = done_stops + 1
        end

        Sessions._register_for_test(parent)
        Sessions._register_for_test(active_child)
        Sessions._register_for_test(done_child)
        local tab = vim.api.nvim_get_current_tabpage()
        Sessions.bind_chat(parent, make_mock_chat(), tab)

        Manifest.upsert(parent.id, {
            parent_id = parent.id,
            status = "active",
            name = "parent",
        })
        Manifest.upsert(active_child.id, {
            parent_id = parent.id,
            status = "active",
            name = "a",
        })
        Manifest.upsert(done_child.id, {
            parent_id = parent.id,
            status = "completed",
            name = "d",
        })

        local real_close = Subsessions.close
        local real_close_session = Sessions.close_session
        local close_calls, close_session_calls = 0, 0
        Subsessions.close = function()
            close_calls = close_calls + 1
        end
        Sessions.close_session = function()
            close_session_calls = close_session_calls + 1
        end

        Pi.abort()

        Subsessions.close = real_close
        Sessions.close_session = real_close_session

        assert.is_true(has_abort(parent_sent), "Parent received abort")
        assert.is_true(has_abort(active_sent), "Active child received abort")
        assert.is_false(has_abort(done_sent), "Completed child must not receive abort")
        assert.equals(1, #done_child.attention.pending, "Completed child keeps its attention")
        assert.equals(0, #parent.attention.pending, "Parent attention is cleared")
        assert.equals(0, close_calls, "Subsessions.close is never called")
        assert.equals(0, close_session_calls, "Sessions.close_session is never called")
        assert.equals(0, active_stops, "Active child process is not stopped")
        assert.equals(0, done_stops, "Completed child process is not stopped")
    end)

    it("tmp→real lineage alias", function()
        local session = {
            id = "tmp-test-1",
            rpc = make_mock_rpc(),
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }
        Sessions._register_for_test(session)
        Sessions.ensure_id(session, "real-uuid-x")
        assert.equals("real-uuid-x", Manifest.resolve_lineage("tmp-test-1"))
    end)

    it("Plain single-session abort unchanged", function()
        local parent_sent = {}
        local parent = {
            id = "parent-single-1",
            lineage_id = "parent-single-1",
            rpc = make_mock_rpc(parent_sent),
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        Sessions._register_for_test(parent)
        local tab = vim.api.nvim_get_current_tabpage()
        local chat = make_mock_chat()
        Sessions.bind_chat(parent, chat, tab)
        Manifest.upsert(parent.id, {
            parent_id = parent.id,
            status = "active",
            name = "parent",
        })

        local batch_id
        Batch.dispatch(parent, {
            items = { { target = "child-target-1", message = "do work" } },
        }, function(res)
            batch_id = res.batch_id
        end)

        assert.is_string(batch_id)
        assert.equals("running", Batch.get(batch_id).status)

        Pi.abort()

        assert.is_true(has_abort(parent_sent), "Parent received abort")
        assert.equals("cancelled", Batch.get(batch_id).status)
    end)
end)
