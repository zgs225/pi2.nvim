local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")
local Sessions = require("pi.sessions.manager")
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
    end)

    after_each(function()
        os.remove(batch_tmp)
        os.remove(manifest_tmp)
        Batch._reset()
        Manifest.path = real_manifest_path
        Manifest._reset()
        Sessions._reset()
    end)

    it("Child-view abort reaches parent and cancels batch", function()
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
        assert.is_true(has_abort(parent_sent), "Parent received abort")
        local current_batch = Batch.get(batch_id)
        assert.equals("cancelled", current_batch.status)
        assert.equals(0, #parent.attention.pending)
        assert.equals(0, #child.attention.pending)
    end)

    it("Non-running child still forwards to parent", function()
        local parent_sent = {}
        local child_sent = {}

        local parent = {
            id = "parent-uuid-2",
            lineage_id = "parent-uuid-2",
            rpc = make_mock_rpc(parent_sent, true),
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }

        local child = {
            id = "child-uuid-2",
            view_parent_id = "parent-uuid-2",
            rpc = make_mock_rpc(child_sent, false),
            attention = { pending = {} },
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

        assert.is_false(has_abort(child_sent), "Non-running child did not receive abort")
        assert.is_true(has_abort(parent_sent), "Parent received abort")
        local current_batch = Batch.get(batch_id)
        assert.equals("cancelled", current_batch.status)
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
