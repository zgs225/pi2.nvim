-- Specs for the web-aware attention path: every request is emitted as a
-- `pi2:attention_request` (even headless), `Attention.resolve` implements
-- first-answer-wins and removes the queued entry so `:PiAttention` can never
-- pop a ghost dialog, and every local answer emits `pi2:attention_resolved`.

local Attention = require("pi.attention")
local Config = require("pi.config")
local Sessions = require("pi.sessions.manager")
local Instance = require("pi.web.instance")
local Protocol = require("pi.web.protocol")

Config.setup({})

--- @return table bridge, table[] events
local function fake_bridge()
    local bridge = { events = {}, snapshots = {}, ready = true }
    function bridge:send_event(_, _, _, event)
        self.events[#self.events + 1] = event
        return true
    end
    function bridge:send_snapshot() end
    function bridge:send_instance_state() end
    function bridge:status()
        return { ready = true, instance_id = "i-test" }
    end
    function bridge:stop() end
    return bridge
end

--- @param id string
--- @return pi.Session
local function fake_session(id)
    local running = true
    --- @type pi.Session
    local session
    session = {
        id = id,
        cwd = "/repo",
        rpc = {
            is_running = function()
                return running
            end,
            stop = function() end,
            send = function(_, cmd)
                session._sent[#session._sent + 1] = cmd
                return true
            end,
        },
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        changed_files = {},
        _sent = {},
    }
    return session
end

--- @param bridge table
--- @param name string
--- @return table[]
local function events_of(bridge, name)
    local out = {}
    for _, event in ipairs(bridge.events) do
        if event.type == name then
            out[#out + 1] = event
        end
    end
    return out
end

describe("web attention request/resolve", function()
    local bridge
    local instance
    local session

    before_each(function()
        Sessions._reset()
        bridge = fake_bridge()
        instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        session = fake_session("s-attn")
        Sessions._register_for_test(session)
        instance:on_subscribe("s-attn")
    end)

    after_each(function()
        Instance.shutdown()
        Sessions._reset()
    end)

    it("emits pi2:attention_request even without a UI and does not open a dialog", function()
        local dialogs = 0
        local orig_select, orig_confirm = vim.ui.select, vim.ui.confirm
        vim.ui.select = function()
            dialogs = dialogs + 1
        end
        -- luassert also patches vim.ui, but restore defensively either way.
        local had_confirm = vim.ui.confirm ~= nil
        if had_confirm then
            vim.ui.confirm = function()
                dialogs = dialogs + 1
            end
        end

        local handled = Attention.present(session, {
            id = "req-1",
            method = "confirm",
            title = "Confirm",
            message = "Proceed?",
        })

        vim.ui.select = orig_select
        if had_confirm then
            vim.ui.confirm = orig_confirm
        end

        assert.is_true(handled)
        assert.equals(0, dialogs)
        assert.equals(1, #session.attention.pending)
        assert.is_true(type(session.attention.pending[1].created_at) == "number")

        local requests = events_of(bridge, Protocol.DERIVED.ATTENTION_REQUEST)
        assert.equals(1, #requests)
        assert.equals("req-1", requests[1].requestId)
        assert.equals("confirm", requests[1].method)
        assert.equals("Confirm", requests[1].title)
        assert.equals("Proceed?", requests[1].message)

        local state = instance:snapshot_for(session)
        assert.equals(1, #state.attention)
    end)

    it("resolves from the web, removes the pending entry and forwards the answer", function()
        Attention.present(session, { id = "req-2", method = "confirm", title = "Confirm" })

        local ok, code = Attention.resolve(session, "req-2", "web", { confirmed = true })
        assert.is_true(ok)
        assert.is_nil(code)
        assert.equals(0, #session.attention.pending)

        local response = session._sent[#session._sent]
        assert.equals("extension_ui_response", response.type)
        assert.equals("req-2", response.id)
        assert.is_true(response.confirmed)

        local resolved = events_of(bridge, Protocol.DERIVED.ATTENTION_RESOLVED)
        assert.equals(1, #resolved)
        assert.equals("req-2", resolved[1].requestId)
        assert.equals("web", resolved[1].by)

        local state = instance:snapshot_for(session)
        assert.equals(0, #state.attention)
        assert.is_false(state.flags.attention)
    end)

    it("rejects a second answer with E_ATTENTION_RESOLVED", function()
        Attention.present(session, { id = "req-3", method = "confirm", title = "Confirm" })
        assert.is_true(Attention.resolve(session, "req-3", "web", { confirmed = true }))

        local sent_count = #session._sent
        local ok, code = Attention.resolve(session, "req-3", "web", { confirmed = false })
        assert.is_false(ok)
        assert.equals("E_ATTENTION_RESOLVED", code)
        assert.equals(sent_count, #session._sent)
    end)

    it("treats a malformed request id as E_BAD_REQUEST", function()
        local ok, code = Attention.resolve(session, nil, "web", { confirmed = true })
        assert.is_false(ok)
        assert.equals("E_BAD_REQUEST", code)
    end)

    it("emits pi2:attention_resolved for locally cancelled requests", function()
        Attention.present(session, { id = "req-4", method = "confirm", title = "Confirm" })
        Attention.present(session, { id = "req-5", method = "confirm", title = "Confirm" })

        Attention.clear_session(session)

        assert.equals(0, #session.attention.pending)
        local resolved = events_of(bridge, Protocol.DERIVED.ATTENTION_RESOLVED)
        assert.equals(2, #resolved)
        assert.equals("nvim", resolved[1].by)
        assert.is_true(resolved[1].response.cancelled)
    end)

    it("gives a request without a pi timeout the 120 s default expiry", function()
        Attention.present(session, { id = "req-default", method = "confirm", title = "Confirm" })

        local entry = session.attention.pending[1]
        assert.is_number(entry.expires_at)
        assert.is_number(entry.created_at)
        assert.equals(120000, entry.expires_at - entry.created_at)

        -- With a pi-level timeout the request keeps it.
        Attention.present(session, { id = "req-timed", method = "confirm", title = "Confirm", timeout = 5000 })
        local timed = session.attention.pending[2]
        assert.equals(5000, timed.expires_at - timed.created_at)
    end)

    it("emits pi2:attention_resolved (and cancels) when a request expires", function()
        Attention.present(session, {
            id = "req-expire",
            method = "confirm",
            title = "Confirm",
            timeout = 60000,
        })
        assert.equals(1, #session.attention.pending)
        -- Force the entry to be stale, then run the prune timer's body.
        session.attention.pending[1].expires_at = 0
        Attention.prune_stale_queue()

        assert.equals(0, #session.attention.pending)
        local resolved = events_of(bridge, Protocol.DERIVED.ATTENTION_RESOLVED)
        assert.equals(1, #resolved)
        assert.equals("req-expire", resolved[1].requestId)
        assert.equals("timeout", resolved[1].by)

        local response = session._sent[#session._sent]
        assert.equals("extension_ui_response", response.type)
        assert.equals("req-expire", response.id)
        assert.is_true(response.cancelled)

        local state = instance:snapshot_for(session)
        assert.equals(0, #state.attention)
        assert.is_false(state.flags.attention)
    end)

    it("emits pi2:attention_resolved when a session transition drops requests", function()
        Attention.present(session, { id = "req-old", method = "confirm", title = "Confirm" })
        Attention.begin_session_transition(session)
        Attention.end_session_transition(session, true)

        assert.equals(0, #session.attention.pending)
        local resolved = events_of(bridge, Protocol.DERIVED.ATTENTION_RESOLVED)
        assert.equals(1, #resolved)
        assert.equals("req-old", resolved[1].requestId)
        assert.equals("session", resolved[1].by)
        assert.is_false(instance:snapshot_for(session).flags.attention)
    end)

    it("keeps an entry pending while a local dialog is open so the web can answer", function()
        local opened = 0
        session.attention.pending = {
            {
                id = "req-local",
                seq = 1,
                kind = "confirm",
                created_at = vim.uv.now(),
                expires_at = vim.uv.now() + 60000,
                open = function()
                    opened = opened + 1
                    return true
                end,
            },
        }

        assert.is_true(Attention.open_next())
        assert.equals(1, opened)
        -- Still pending (the web may answer it), but not counted/openable twice.
        assert.equals(1, #session.attention.pending)
        assert.equals(0, Attention.count(session.tab))
        assert.is_true(Attention.open_next() == false)
        assert.equals(1, opened)

        local ok = Attention.resolve(session, "req-local", "web", { confirmed = true })
        assert.is_true(ok)
        assert.equals(0, #session.attention.pending)

        -- The local dialog answering afterwards must not send a second response.
        local sent = #session._sent
        assert.is_true(Attention.resolve(session, "req-local", "nvim", { confirmed = true }) == false)
        assert.equals(sent, #session._sent)
    end)

    it("drops an entry that is already expired before opening it", function()
        local opened = 0
        session.attention.pending = {
            {
                id = "req-stale",
                seq = 1,
                kind = "confirm",
                created_at = 0,
                expires_at = 0,
                open = function()
                    opened = opened + 1
                    return true
                end,
            },
        }

        assert.is_false(Attention.open_next())
        assert.equals(0, opened)
        assert.equals(0, #session.attention.pending)
        local resolved = events_of(bridge, Protocol.DERIVED.ATTENTION_RESOLVED)
        assert.equals(1, #resolved)
        assert.equals("req-stale", resolved[1].requestId)
    end)
end)
