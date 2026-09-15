-- Regression: Attention.clear_session must cancel queued extension UI
-- requests before dropping them.
--
-- The backend is blocked inside ctx.ui.*() until it receives an
-- extension_ui_response. Dropping the pending queue without replying left the
-- process waiting forever (e.g. after a session close/teardown). These specs
-- pin: one cancelled response per queued entry, the queue ends up empty, and a
-- non-running RPC is tolerated silently.

local Attention = require("pi.attention")
local Config = require("pi.config")
local Sessions = require("pi.sessions.manager")

Config.setup({})

--- Minimal session double (mirrors tests/attention_detached_spec.lua).
---@param opts? { id?: string, running?: boolean }
---@return pi.Session
local function make_session(opts)
    opts = opts or {}
    local rpc_running = opts.running ~= false
    local sent_cmds = {} ---@type pi.RpcCommand[]
    ---@type pi.Session
    local session = {
        id = opts.id or "sess-clear-1",
        attached_tab = nil,
        tab = nil,
        chat = nil,
        rpc = {
            is_running = function()
                return rpc_running
            end,
            send = function(_, cmd, cb)
                sent_cmds[#sent_cmds + 1] = cmd
                if cb then
                    cb({ success = true })
                end
                return true
            end,
            stop = function()
                rpc_running = false
            end,
        },
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        cwd = vim.fn.getcwd(),
        changed_files = {},
        _sent_cmds = sent_cmds,
    }
    return session
end

describe("Attention.clear_session", function()
    before_each(function()
        Sessions._reset()
    end)

    after_each(function()
        Sessions._reset()
    end)

    it("cancels every queued request and empties the queue", function()
        local session = make_session({ id = "clear-two" })
        Sessions._register_for_test(session)

        Attention.present(session, {
            id = "req-confirm",
            method = "confirm",
            title = "Confirm?",
            message = "Proceed?",
        })
        Attention.present(session, {
            id = "req-select",
            method = "select",
            title = "Pick",
            options = { "a", "b" },
        })
        assert.equals(2, #session.attention.pending)

        Attention.clear_session(session)

        assert.are.same({}, session.attention.pending)
        assert.equals(2, #session._sent_cmds)

        local by_id = {}
        for _, cmd in ipairs(session._sent_cmds) do
            assert.equals("extension_ui_response", cmd.type)
            assert.is_true(cmd.cancelled)
            assert.is_nil(cmd.confirmed)
            assert.is_nil(cmd.value)
            by_id[cmd.id] = true
        end
        assert.is_true(by_id["req-confirm"] == true)
        assert.is_true(by_id["req-select"] == true)
    end)

    it("cancels directly queued entries with no rpc activity needed", function()
        local session = make_session({ id = "clear-direct" })
        session.attention.pending = {
            { id = "direct-1", seq = 1, kind = "input" },
            { id = "direct-2", seq = 2, kind = "editor" },
            { id = "direct-3", seq = 3, kind = "confirm" },
        }

        Attention.clear_session(session)

        assert.are.same({}, session.attention.pending)
        assert.equals(3, #session._sent_cmds)
        assert.equals("direct-1", session._sent_cmds[1].id)
        assert.equals("direct-2", session._sent_cmds[2].id)
        assert.equals("direct-3", session._sent_cmds[3].id)
    end)

    it("tolerates a stopped RPC: queue cleared, nothing sent", function()
        local session = make_session({ id = "clear-dead", running = false })
        session.attention.pending = { { id = "dead-1", seq = 1, kind = "confirm" } }

        Attention.clear_session(session)

        assert.are.same({}, session.attention.pending)
        assert.equals(0, #session._sent_cmds)
    end)
end)
