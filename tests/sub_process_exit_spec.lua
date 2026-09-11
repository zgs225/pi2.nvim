-- A10: a crashed sub-session process must settle as failed.
--
-- `_process_exit` is the only signal that a detached child died without
-- emitting `agent_settled`; without settling, the owning batch item stays
-- "running" until its timeout. The registry distinguishes a crash from an
-- intentional close: close_session() unregisters the session synchronously,
-- before the async on_exit dispatch reaches the handler, so a session that is
-- still registered here died unexpectedly.

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")
local SessionsList = require("pi.ui.sessions")
local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")

Config.setup({})

local real = {
    start = Rpc.start,
    stop = Rpc.stop,
    send = Rpc.send,
    log_unhandled = Rpc.log_unhandled,
    request_refresh = SessionsList.request_refresh,
    mark_child_completion_seen = SessionsList.mark_child_completion_seen,
    manifest_path = Manifest.path,
}

local manifest_tmp
local batch_tmp
local tab ---@type integer?
local session ---@type pi.Session?

--- Feed an event through the manager's installed RPC handler.
---@param target pi.Session
---@param msg table
local function feed(target, msg)
    local handler = target.rpc._handler
    assert.truthy(handler, "handler not installed")
    handler(msg)
end

--- Manifest entry + a running batch item whose target is `target`.
---@param target pi.Session
---@return string batch_id
local function start_running_item(target)
    Manifest.upsert(target.id, {
        parent_id = "parent-1",
        parent_epoch = 0,
        name = "worker",
        task_prompt = "t",
        config = {},
        status = "active",
        reported = false,
        created_at = Manifest.iso_now(),
        last_active_at = Manifest.iso_now(),
        agent_spawned = false,
        run_generation = 1,
    })

    local parent = {
        id = "parent-1",
        rpc = {
            is_running = function()
                return true
            end,
        },
    }
    local batch_id
    Batch.dispatch(parent, { items = { { ref = "r", target = target.id, message = "go" } } }, function(res)
        batch_id = res.batch_id
    end)
    assert.is_string(batch_id, "batch dispatch failed")
    assert.is_true(
        vim.wait(1000, function()
            local snap = Batch.poll(batch_id)
            return snap ~= nil and snap.items[1] ~= nil and snap.items[1].status == "running"
        end, 10),
        "the batch item must reach running"
    )
    return batch_id
end

describe("sub-session process exit", function()
    before_each(function()
        Rpc.start = function(self)
            self._job_id = 999
            return true
        end
        Rpc.stop = function(self)
            self._job_id = nil
            self._pending = {}
        end
        Rpc.send = function(self, cmd, callback)
            if cmd.type == "get_messages" and callback then
                vim.schedule(function()
                    callback({ success = true, data = { messages = {} } })
                end)
            end
            return true
        end
        Rpc.log_unhandled = function() end
        SessionsList.request_refresh = function() end
        SessionsList.mark_child_completion_seen = function() end

        manifest_tmp = vim.fn.tempname() .. "-manifest.json"
        batch_tmp = vim.fn.tempname() .. "-batches.json"
        Manifest.path = function()
            return manifest_tmp
        end
        Manifest._reset()
        Batch._reset()
        Batch._set_path(batch_tmp)

        local tabs = vim.api.nvim_list_tabpages()
        vim.cmd("tabnew")
        tab = vim.api.nvim_get_current_tabpage()
        assert.is_true(#vim.api.nvim_list_tabpages() > #tabs, "tab must be created")
        session = Sessions.get_or_create({ layout = "split" })
        assert.truthy(session, "session creation failed")
        session.parent_id = "parent-1"
    end)

    after_each(function()
        if tab then
            local tabs = vim.api.nvim_list_tabpages()
            if #tabs > 1 then
                vim.api.nvim_set_current_tabpage(tabs[1])
            end
            pcall(vim.api.nvim_tabpage_close, tab)
        end
        Sessions._reset()
        Batch._reset()
        Manifest.path = real.manifest_path
        Manifest._reset()
        os.remove(manifest_tmp)
        os.remove(batch_tmp)
        Rpc.start = real.start
        Rpc.stop = real.stop
        Rpc.send = real.send
        Rpc.log_unhandled = real.log_unhandled
        SessionsList.request_refresh = real.request_refresh
        SessionsList.mark_child_completion_seen = real.mark_child_completion_seen
    end)

    it("settles a crashed child as failed and fails its running batch item", function()
        local child_id = session.id
        local batch_id = start_running_item(session)
        assert.equals("active", Manifest.load()[child_id].status, "precondition: child is active")

        feed(session, { type = "_process_exit", code = 1 })

        assert.equals("failed", Manifest.load()[child_id].status)
        local snap = Batch.poll(batch_id)
        assert.equals("failed", snap.items[1].status)
        assert.equals("failed", snap.status)
    end)

    it("does not mark an intentionally closed child as failed", function()
        local child_id = session.id
        local batch_id = start_running_item(session)

        -- Intentional close: the session is unregistered synchronously before
        -- the async exit dispatch reaches the handler.
        Sessions.close_session(session)

        feed(session, { type = "_process_exit", code = 1 })

        assert.equals("active", Manifest.load()[child_id].status)
        local snap = Batch.poll(batch_id)
        assert.equals("running", snap.items[1].status)
        assert.equals("running", snap.status)
    end)
end)
