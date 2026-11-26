-- The `ask` bridge in lua/pi/attention.lua: a blocking `select` request whose
-- title is the `__pi_ask__` sentinel becomes a kind="ask" attention entry that
-- opens lua/pi/ui/ask (this worktree's own dialog) instead of a plain
-- vim.ui.select, and whose answer travels back as ONE
-- `extension_ui_response` RPC command carrying the JSON-encoded result.
--
-- The dialog module is injected via `package.preload["pi.ui.ask"]` before it is
-- ever required (same approach as tests/todo_panel_tab_focus_spec.lua): the
-- spec controls `decode`/`open` and asserts the request the host hands over —
-- not the pixels of the window.
--
-- Two entry paths are covered, matching the two branches of `M.present`:
--   * the session's prompt has focus and no draft -> the entry opens at once
--     (`entry.open()` runs inside `present`), which is the path a user typing
--     at the prompt takes;
--   * there is no chat -> the entry is queued on the session (the path a
--     background/detached session takes).

local Attention = require("pi.attention")
local Config = require("pi.config")
local Sessions = require("pi.sessions.manager")

Config.setup({})

---@type table<string, any>
local saved_loaded = {}

--- Calls recorded by the injected pi.ui.ask stub.
local calls = {
    open = {}, ---@type { req: any, opts: table }[]
    decode_payload = {}, ---@type any[]
}

--- Zero the recorded calls without installing a stub.
local function reset_calls()
    calls.open = {}
    calls.decode_payload = {}
end

--- Install a hermetic pi.ui.ask stub with the given decode behaviour.
---@param decode fun(payload: any): any, string?
---@param open_result? boolean What the stubbed `open` returns; `false` models a
--- float that refused to open because another ask already owns the screen.
local function stub_ask(decode, open_result)
    reset_calls()
    package.loaded["pi.ui.ask"] = nil
    package.preload["pi.ui.ask"] = function()
        return {
            decode = function(payload)
                calls.decode_payload[#calls.decode_payload + 1] = payload
                return decode(payload)
            end,
            open = function(req, opts)
                calls.open[#calls.open + 1] = { req = req, opts = opts }
                -- `open` returns whether the float is now showing; attention
                -- re-queues the request when it is not.
                return open_result ~= false
            end,
        }
    end
end

--- Restore the real module graph (and drop the stub) after the spec.
local function unstub_ask()
    package.preload["pi.ui.ask"] = nil
    package.loaded["pi.ui.ask"] = nil
    for name, value in pairs(saved_loaded) do
        package.loaded[name] = value
    end
    saved_loaded = {}
end

--- A session double mirroring tests/attention_detached_spec.lua.
---@param opts? { id?: string, focused_chat?: boolean }
---@return pi.Session
local function make_session(opts)
    opts = opts or {}
    local sent = {} ---@type pi.RpcCommand[]
    ---@type pi.Session
    local session = {
        id = opts.id or "sess-ask-1",
        attached_tab = nil,
        tab = nil,
        chat = nil,
        rpc = {
            is_running = function()
                return true
            end,
            send = function(_, cmd, cb)
                sent[#sent + 1] = cmd
                if cb then
                    cb({ success = true })
                end
                return true
            end,
            stop = function() end,
        },
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        cwd = "/tmp",
        changed_files = {},
        _sent_cmds = sent,
    }
    if opts.focused_chat then
        session.chat = {
            has_prompt_focus = function()
                return true
            end,
            has_draft = function()
                return false
            end,
        }
    end
    return session
end

--- The decoded payload the extension sends through `select`.
---@return table
local function ask_body()
    return {
        v = 1,
        questions = {
            {
                id = "q1",
                header = "Database",
                question = "Which database?",
                options = { { label = "Postgres" }, { label = "SQLite" } },
            },
            {
                id = "q2",
                header = "Data dir",
                question = "Where?",
                options = {},
                allow_free_text = true,
            },
        },
    }
end

---@param body table
---@return pi.RpcEvent
local function ask_event(body)
    return {
        id = "r1",
        method = "select",
        title = "__pi_ask__",
        options = { vim.json.encode(body) },
    }
end

describe("attention ask request", function()
    local orig_notify

    before_each(function()
        Sessions._reset()
        orig_notify = vim.notify
        vim.notify = function() end
        stub_ask(function()
            return { v = 1, questions = ask_body().questions }, nil
        end)
    end)

    after_each(function()
        Sessions._reset()
        vim.notify = orig_notify
        unstub_ask()
        Config.setup({})
    end)

    it("opens the ask dialog for a focused prompt and replies through RPC", function()
        local session = make_session({ id = "sess-ask-focused", focused_chat = true })
        Sessions._register_for_test(session)

        local body = ask_body()
        local handled = Attention.present(session, ask_event(body))
        assert.is_true(handled)

        -- The entry opened immediately: nothing is queued.
        assert.equals(0, #session.attention.pending)

        -- decode() got the payload string the extension put in options[1].
        assert.equals(1, #calls.decode_payload)
        assert.are.equal(vim.json.encode(body), calls.decode_payload[1])

        -- open() got the decoded request and a callback.
        assert.equals(1, #calls.open)
        local handed = calls.open[1]
        assert.are.equal(body.v, handed.req.v)
        assert.are.equal(2, #handed.req.questions)
        assert.are.equal("q1", handed.req.questions[1].id)
        assert.are.equal("function", type(handed.opts.on_done))
        assert.is_nil(session._sent_cmds[1], "no response before the user answers")

        -- The user answers (cancels): one extension_ui_response, JSON-encoded.
        handed.opts.on_done({ v = 1, cancelled = true })

        assert.equals(1, #session._sent_cmds)
        local cmd = session._sent_cmds[1]
        assert.are.equal("extension_ui_response", cmd.type)
        assert.are.equal("r1", cmd.id)
        assert.are.equal("string", type(cmd.value))
        assert.are.same({ v = 1, cancelled = true }, vim.json.decode(cmd.value))
    end)

    it("answers on a queued (chat-less) session", function()
        local session = make_session({ id = "sess-ask-queued" })
        Sessions._register_for_test(session)

        assert.is_true(Attention.present(session, ask_event(ask_body())))
        -- Queued, not opened: the dialog must not steal a background session.
        assert.equals(1, #session.attention.pending)
        assert.equals(0, #calls.open)

        local opened = Attention.open_next()
        assert.is_true(opened)
        assert.equals(0, #session.attention.pending)
        assert.equals(1, #calls.open)

        calls.open[1].opts.on_done({ v = 1, answers = { q1 = "Postgres" } })
        assert.equals(1, #session._sent_cmds)
        assert.are.equal("extension_ui_response", session._sent_cmds[1].type)
        assert.are.equal("r1", session._sent_cmds[1].id)
        assert.are.same({ v = 1, answers = { q1 = "Postgres" } }, vim.json.decode(session._sent_cmds[1].value))
    end)

    it("opens an ask for the current tab even while the prompt is unfocused", function()
        -- The backend is stalled inside ctx.ui.select, so waiting for the prompt
        -- to gain focus froze the whole turn behind whichever window the user
        -- happened to be in, with only a toast to explain it.
        local session = make_session({ id = "sess-ask-blocking" })
        session.tab = vim.api.nvim_get_current_tabpage()
        session.chat = {
            has_prompt_focus = function()
                return false
            end,
            has_draft = function()
                return true
            end,
        }
        Sessions._register_for_test(session)

        assert.is_true(Attention.present(session, ask_event(ask_body())))
        assert.equals(0, #session.attention.pending)
        assert.equals(1, #calls.open)
    end)

    it("still queues a plain select for the same unfocused prompt", function()
        -- Only the blocking kind bypasses the gate; a diff/select popping up
        -- over the window the user is typing in is what the queue exists for.
        local session = make_session({ id = "sess-select-gated" })
        session.tab = vim.api.nvim_get_current_tabpage()
        session.chat = {
            has_prompt_focus = function()
                return false
            end,
            has_draft = function()
                return true
            end,
        }
        Sessions._register_for_test(session)

        local handled = Attention.present(session, {
            id = "s2",
            method = "select",
            title = "Approve?",
            options = { "yes", "no" },
        })
        assert.is_true(handled)
        assert.equals(1, #session.attention.pending)
        assert.equals("select", session.attention.pending[1].kind)
        assert.equals(0, #calls.open)
        assert.equals(0, #session._sent_cmds)
    end)

    it("queues the request when another ask float already owns the screen", function()
        stub_ask(function()
            return { v = 1, questions = ask_body().questions }, nil
        end, false)
        local session = make_session({ id = "sess-ask-busy", focused_chat = true })
        Sessions._register_for_test(session)

        assert.is_true(Attention.present(session, ask_event(ask_body())))
        -- open() refused: the request must stay queued (never dropped) so the
        -- blocked backend is answered later through :PiAttention.
        assert.equals(1, #session.attention.pending)
        assert.equals(0, #session._sent_cmds)
    end)

    it("re-queues instead of answering when the float is hidden", function()
        local session = make_session({ id = "sess-ask-hide", focused_chat = true })
        session.tab = vim.api.nvim_get_current_tabpage()
        Sessions._register_for_test(session)

        assert.is_true(Attention.present(session, ask_event(ask_body())))
        assert.equals(0, #session.attention.pending)
        local handed = calls.open[1]
        assert.equals("function", type(handed.opts.on_hide))

        handed.opts.on_hide()
        -- Hidden is not answered: back in the queue, still no RPC reply, and
        -- not reopened on its own (a hidden float must not pop straight back).
        assert.equals(1, #session.attention.pending)
        assert.equals(0, #session._sent_cmds)
        assert.equals(1, #calls.open)

        -- Focusing the prompt again must NOT reopen it: a dismissed float that
        -- bounces straight back cannot be dismissed at all. Only an explicit
        -- :PiAttention (open_next) reopens a hidden request.
        assert.is_false(Attention.open_next_for_tab(session.tab))
        assert.equals(1, #session.attention.pending)
        assert.equals(1, #calls.open)

        -- :PiAttention drains the queue, which reopens the float.
        assert.is_true(Attention.open_next())
        assert.equals(2, #calls.open)
        assert.equals(0, #session.attention.pending)
    end)

    it("replies 'unsupported' and never opens a dialog when the payload cannot be decoded", function()
        stub_ask(function()
            return nil, "bad payload"
        end)
        local session = make_session({ id = "sess-ask-bad", focused_chat = true })
        Sessions._register_for_test(session)

        assert.is_true(Attention.present(session, ask_event(ask_body())))

        -- No dialog was attempted...
        assert.equals(0, #calls.open)
        -- ...and nothing is stuck in the queue.
        assert.equals(0, #session.attention.pending)

        assert.equals(1, #session._sent_cmds)
        local cmd = session._sent_cmds[1]
        assert.are.equal("extension_ui_response", cmd.type)
        assert.are.equal("r1", cmd.id)
        local value = vim.json.decode(cmd.value)
        assert.are.equal(1, value.v)
        assert.are.equal("unsupported", value.error)
        -- The decode error is forwarded so the extension can log it.
        assert.are.equal("bad payload", value.detail)
    end)

    it("queues 'unsupported' correctly when the session is chat-less", function()
        stub_ask(function()
            return nil, "bad payload"
        end)
        local session = make_session({ id = "sess-ask-bad-queued" })
        Sessions._register_for_test(session)

        assert.is_true(Attention.present(session, ask_event(ask_body())))
        assert.equals(1, #session.attention.pending)

        assert.is_true(Attention.open_next())
        assert.equals(0, #session.attention.pending)
        assert.equals(0, #calls.open)
        assert.equals(1, #session._sent_cmds)
        assert.are.equal("r1", session._sent_cmds[1].id)
        assert.are.equal("unsupported", vim.json.decode(session._sent_cmds[1].value).error)
    end)
end)

describe("attention non-ask select requests", function()
    local orig_notify
    local orig_select

    before_each(function()
        Sessions._reset()
        reset_calls()
        orig_notify = vim.notify
        vim.notify = function() end
        orig_select = vim.ui.select
    end)

    after_each(function()
        Sessions._reset()
        vim.notify = orig_notify
        vim.ui.select = orig_select
        unstub_ask()
    end)

    it("keeps a plain select a kind=select entry, not an ask", function()
        -- Regression guard: only the __pi_ask__ title routes to the ask dialog.
        local session = make_session({ id = "sess-plain-select" })
        Sessions._register_for_test(session)

        local handled = Attention.present(session, {
            id = "sel-1",
            method = "select",
            title = "Select branch",
            options = { "main", "dev" },
        })
        assert.is_true(handled)
        assert.equals(1, #session.attention.pending)
        assert.are.equal("select", session.attention.pending[1].kind)
        assert.are.equal("sel-1", session.attention.pending[1].id)
        -- The ask dialog is not involved at all.
        assert.equals(0, #calls.open)
        assert.equals(0, #calls.decode_payload)
    end)

    it("opens a plain select through vim.ui.select, not the ask dialog", function()
        local picked = {} ---@type string[]
        vim.ui.select = function(items, _, on_choice)
            picked[#picked + 1] = items[1]
            on_choice(items[1])
        end

        local session = make_session({ id = "sess-plain-select-open" })
        Sessions._register_for_test(session)

        Attention.present(session, {
            id = "sel-2",
            method = "select",
            title = "Select branch",
            options = { "main", "dev" },
        })
        assert.is_true(Attention.open_next())

        assert.are.same({ "main" }, picked)
        assert.equals(0, #calls.open)
        assert.equals(0, #calls.decode_payload)
        assert.equals(1, #session._sent_cmds)
        assert.are.equal("sel-2", session._sent_cmds[1].id)
        assert.are.equal("main", session._sent_cmds[1].value)
    end)
end)
