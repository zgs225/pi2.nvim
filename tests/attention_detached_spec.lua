local Attention = require("pi.attention")
local Config = require("pi.config")
local Sessions = require("pi.sessions.manager")

Config.setup({})

---@param opts? { id?: string, running?: boolean }
---@return pi.Session
local function make_detached_session(opts)
    opts = opts or {}
    local rpc_running = opts.running ~= false
    local sent_cmds = {}
    ---@type pi.Session
    local session = {
        id = opts.id or "sess-detached-1",
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

describe("detached session attention support", function()
    local orig_select
    local orig_notify
    local notifications

    before_each(function()
        Sessions._reset()
        notifications = {}
        orig_notify = vim.notify
        vim.notify = function(msg, level, opts)
            notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
        end
        orig_select = vim.ui.select
        vim.ui.select = function(items, _, on_choice)
            on_choice(items and items[1])
        end
    end)

    after_each(function()
        Sessions._reset()
        vim.notify = orig_notify
        vim.ui.select = orig_select
    end)

    it("Attention.present cleanly enqueues an entry when session.chat == nil without error", function()
        local session = make_detached_session({ id = "detached-present" })
        Sessions._register_for_test(session)

        local handled = Attention.present(session, {
            id = "req-present-1",
            method = "confirm",
            title = "Confirm detached action",
            message = "Should enqueue cleanly",
        })

        assert.is_true(handled)
        assert.equals(1, #session.attention.pending)
        assert.equals("req-present-1", session.attention.pending[1].id)
        assert.equals("confirm", session.attention.pending[1].kind)

        -- Total count increments, but current tab count is 0
        assert.equals(1, Attention.total_count())
        assert.equals(0, Attention.count())

        -- State table does not index state.tabs[nil]
        local state = Attention.state()
        assert.equals(1, state.total_count)
        assert.equals(0, state.current_tab_count)
        assert.is_nil(state.tabs[nil])

        -- Notification dispatched with background id and suffix
        assert.is_true(#notifications > 0)
        local last = notifications[#notifications]
        assert.equals("pi-attention-background", last.opts and last.opts.id)
        assert.is_truthy(last.msg:find("%(background%)"))
    end)

    it(
        "prune_stale_queue does NOT remove the pending entry when session.tab == nil while session.rpc:is_running() == true",
        function()
            local session = make_detached_session({ id = "detached-prune" })
            Sessions._register_for_test(session)

            local ok = Attention.present(session, {
                id = "req-prune-1",
                method = "confirm",
                title = "Keep alive",
                message = "Do not prune",
            })
            assert.is_true(ok)
            assert.equals(1, #session.attention.pending)

            Attention.prune_stale_queue()

            assert.equals(1, #session.attention.pending)
            assert.equals("req-prune-1", session.attention.pending[1].id)
            assert.equals(1, Attention.total_count())
        end
    )

    it("prune_stale_queue removes the pending entry when session.rpc:is_running() == false", function()
        local session = make_detached_session({ id = "detached-dead-rpc" })
        Sessions._register_for_test(session)

        Attention.present(session, {
            id = "req-prune-2",
            method = "confirm",
            title = "Dead RPC",
            message = "Prune when dead",
        })
        assert.equals(1, #session.attention.pending)

        -- Stop RPC to mark session not running
        session.rpc:stop()
        assert.is_false(session.rpc:is_running())

        Attention.prune_stale_queue()

        assert.equals(0, #session.attention.pending)
        assert.equals(0, Attention.total_count())
    end)

    it("prune_stale_queue removes expired entries on detached sessions", function()
        local session = make_detached_session({ id = "detached-expired" })
        Sessions._register_for_test(session)

        Attention.present(session, {
            id = "req-expired-1",
            method = "confirm",
            title = "Timed request",
            timeout = 50000,
        })
        assert.equals(1, #session.attention.pending)

        -- Expire the entry
        session.attention.pending[1].expires_at = 0

        Attention.prune_stale_queue()

        assert.equals(0, #session.attention.pending)
        assert.equals(0, Attention.total_count())
    end)

    it("open_next does not throw an error when opening a pending entry whose session has session.tab == nil", function()
        local session = make_detached_session({ id = "detached-open" })
        Sessions._register_for_test(session)

        local presented = Attention.present(session, {
            id = "req-open-1",
            method = "confirm",
            title = "Confirm action",
            message = "Proceed?",
        })
        assert.is_true(presented)
        assert.equals(1, #session.attention.pending)

        local opened = Attention.open_next()
        assert.is_true(opened)
        assert.equals(0, #session.attention.pending)
        assert.equals(0, Attention.total_count())

        -- Verify extension response sent via session RPC
        assert.equals(1, #session._sent_cmds)
        assert.equals("extension_ui_response", session._sent_cmds[1].type)
        assert.equals("req-open-1", session._sent_cmds[1].id)
        assert.is_true(session._sent_cmds[1].confirmed)
    end)

    it("open_next handles select dialogs on detached sessions cleanly", function()
        local session = make_detached_session({ id = "detached-select" })
        Sessions._register_for_test(session)

        Attention.present(session, {
            id = "req-select-1",
            method = "select",
            title = "Select branch",
            options = { "main", "dev" },
        })
        assert.equals(1, #session.attention.pending)

        local opened = Attention.open_next()
        assert.is_true(opened)
        assert.equals(0, #session.attention.pending)

        assert.equals(1, #session._sent_cmds)
        assert.equals("extension_ui_response", session._sent_cmds[1].type)
        assert.equals("req-select-1", session._sent_cmds[1].id)
        assert.equals("main", session._sent_cmds[1].value)
    end)
end)
