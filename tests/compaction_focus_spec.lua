-- Compaction focus dialog, the abort/retry API and their commands (Gitea #127,
-- P0-4).
--
-- Everything here is driven against a hand-built session: `Sessions.get` is
-- stubbed and the session carries a fake rpc/chat, so no pi process is started
-- and no real session file is touched (G17/G18). `pi.ui.dialog` and the
-- compaction settings resolver are stubbed as well — the menu construction, the
-- context line and the command wiring are the behaviour under test, not
-- `vim.ui.select` nor the user's `~/.pi/agent/settings.json`.

local Config = require("pi.config")
local CompactionDialog = require("pi.ui.compaction_dialog")
local CompactionSettings = require("pi.compaction.settings")
local CompactionState = require("pi.compaction.state")
local Pi = require("pi")
local Sessions = require("pi.sessions.manager")

Config.setup({})
Pi.setup({})

-- Originals, restored in every `after_each` so a failing case cannot leak a
-- stub into the next one.
local real = {
    get = Sessions.get,
    set_focus = Sessions.set_compaction_focus,
    resolve = CompactionSettings.resolve,
    compact = Pi.compact,
    dialog = package.loaded["pi.ui.dialog"],
    dialog_module = package.loaded["pi.ui.compaction_dialog"],
    notify = vim.notify,
}

--- Commands handed to the fake rpc, in order.
local sent = {}
--- vim.notify spy records.
local notes = {}
--- Dialog spy state.
local select_opts = nil ---@type table?
local select_choice = nil ---@type string?
local input_opts = nil ---@type table?
local input_value = nil ---@type string?
--- `get_session_stats` payload the fake rpc answers with.
local stats_data = nil ---@type table?

local fake_dialog = {
    select = function(opts, callback)
        select_opts = opts
        callback(select_choice)
    end,
    input = function(opts, callback)
        input_opts = opts
        callback(input_value)
    end,
    info = function() end,
}

--- A session with just enough surface for `pi.compact` and the dialog: a fake
--- rpc that answers synchronously, a fake chat that tracks `compacting`.
---@param opts? { running?: boolean, compacting?: boolean }
---@return pi.Session
local function new_session(opts)
    opts = opts or {}
    ---@diagnostic disable-next-line: missing-fields -- a fake stands in for the real session object
    local session = {
        id = "session-1",
        cwd = "/tmp/pi-compaction-focus",
        model_state = { model = { provider = "test-provider", id = "test-model", contextWindow = 200000 } },
        compaction = CompactionState.new(),
    }
    -- The casts keep this file lintable against the real `pi.Session` type.
    session.rpc = {
        running = opts.running ~= false,
        is_running = function(self)
            return self.running
        end,
        send = function(self, cmd, callback)
            sent[#sent + 1] = vim.deepcopy(cmd)
            if callback then
                local data = cmd.type == "get_session_stats" and stats_data or nil
                callback({ success = true, data = data })
            end
            return self.running
        end,
    }
    session.chat = {
        compacting = opts.compacting == true,
        streaming = false,
        is_compacting = function(self)
            return self.compacting
        end,
        is_streaming = function(self)
            return self.streaming
        end,
        set_compacting = function(self, value)
            self.compacting = value
        end,
        set_status = function() end,
    }
    return session --[[@as pi.Session]]
end

---@param kind string rpc command type
---@return table? cmd
local function first_sent(kind)
    for _, cmd in ipairs(sent) do
        if cmd.type == kind then
            return cmd
        end
    end
    return nil
end

---@return table? note
local function last_note()
    return notes[#notes]
end

--- Replace `Pi.compact` with a recorder (the dialog's only effect).
---@return { text: string? }[]
local function spy_compact()
    ---@type { text: string? }[]
    local calls = {}
    Pi.compact = function(text)
        calls[#calls + 1] = { text = text }
    end
    return calls
end

describe("compaction focus dialog and commands", function()
    local session = nil ---@type pi.Session?

    before_each(function()
        sent = {}
        notes = {}
        select_opts = nil
        select_choice = nil
        input_opts = nil
        input_value = nil
        stats_data = nil
        CompactionDialog._reset()

        session = new_session()
        Sessions.get = function()
            return session
        end
        Sessions.set_compaction_focus = real.set_focus
        -- Never read the real pi settings files: the resolver is stubbed, the
        -- budget maths stays real so the context line is exercised.
        CompactionSettings.resolve = function()
            return { reserve = 16384, keep = 20000, enabled = true, source = "settings" }
        end
        package.loaded["pi.ui.dialog"] = fake_dialog
        package.loaded["pi.ui.compaction_dialog"] = CompactionDialog
        Pi.compact = real.compact

        vim.notify = function(msg, level)
            notes[#notes + 1] = { msg = msg, level = level }
        end
    end)

    after_each(function()
        Sessions.get = real.get
        Sessions.set_compaction_focus = real.set_focus
        CompactionSettings.resolve = real.resolve
        CompactionSettings._reset()
        Pi.compact = real.compact
        package.loaded["pi.ui.dialog"] = real.dialog
        package.loaded["pi.ui.compaction_dialog"] = real.dialog_module
        vim.notify = real.notify
    end)

    it("registers the compaction commands", function()
        local commands = vim.api.nvim_get_commands({})
        assert.is_not_nil(commands.PiCompactions)
        assert.is_not_nil(commands.PiCompactAbort)
        assert.is_not_nil(commands.PiCompactRetry)
        assert.truthy(commands.PiCompact.bang)
        assert.are.equal("?", commands.PiCompact.nargs)
    end)

    it(":PiCompact with args sends the focus and opens no dialog", function()
        package.loaded["pi.ui.compaction_dialog"] = {
            open = function()
                error("the focus dialog must not open for :PiCompact with args")
            end,
        }
        vim.cmd("PiCompact keep-errors")
        local cmd = first_sent("compact")
        assert.is_not_nil(cmd)
        assert.are.equal("keep-errors", cmd.customInstructions)
        assert.is_true(session.chat.compacting)
    end)

    it("bare :PiCompact opens the focus dialog and sends nothing itself", function()
        local opened = 0
        package.loaded["pi.ui.compaction_dialog"] = {
            open = function()
                opened = opened + 1
            end,
        }
        vim.cmd("PiCompact")
        assert.are.equal(1, opened)
        assert.are.equal(0, #sent)
    end)

    it(":PiCompact! compacts immediately with no focus, even with a saved one", function()
        session.compaction.last_focus = "Preserve architectural decisions"
        package.loaded["pi.ui.compaction_dialog"] = {
            open = function()
                error("the focus dialog must not open for :PiCompact!")
            end,
        }
        vim.cmd("PiCompact!")
        local cmd = first_sent("compact")
        assert.is_not_nil(cmd)
        assert.is_nil(cmd.customInstructions)
        assert.is_true(session.chat.compacting)
    end)

    it("records the focus through Sessions.set_compaction_focus", function()
        vim.cmd("PiCompact keep-errors")
        assert.are.equal("keep-errors", session._compaction_focus)
        assert.are.equal("keep-errors", session.compaction.last_focus)
        assert.are.equal("keep-errors", session.compaction.focus_history[1])
    end)

    it("hands the focus text to Sessions.set_compaction_focus unchanged", function()
        ---@type { session: pi.Session, text: string? }[]
        local recorded = {}
        Sessions.set_compaction_focus = function(target, text)
            recorded[#recorded + 1] = { session = target, text = text }
        end
        Pi.compact("Preserve test failures and exact errors")
        assert.are.equal(1, #recorded)
        assert.are.equal(session, recorded[1].session)
        assert.are.equal("Preserve test failures and exact errors", recorded[1].text)
    end)

    it("offers the presets, the focus history, custom and no-focus rows", function()
        local calls = spy_compact()
        session.compaction.focus_history = { "keep errors", "drop logs" }
        select_choice = nil
        CompactionDialog.open()
        assert.is_not_nil(select_opts)
        assert.are.equal("Compact with focus", select_opts.title)
        assert.are.equal("compaction_focus", select_opts.kind)
        assert.are.same({
            "Preserve architectural decisions",
            "Drop intermediate tool outputs",
            "Preserve test failures and exact errors",
            "Preserve user constraints and rejected approaches",
            "Keep next steps and open questions",
            "↺ keep errors",
            "↺ drop logs",
            "Custom focus…",
            "No focus (summarize everything)",
        }, select_opts.options)
        assert.are.equal(0, #calls)
    end)

    it("compacting from a preset uses that preset as the focus", function()
        local calls = spy_compact()
        select_choice = "Drop intermediate tool outputs"
        CompactionDialog.open()
        assert.are.equal(1, #calls)
        assert.are.equal("Drop intermediate tool outputs", calls[1].text)
    end)

    it("compacting from a focus-history row reuses the stored text", function()
        local calls = spy_compact()
        session.compaction.focus_history = { "keep errors" }
        select_choice = "↺ keep errors"
        CompactionDialog.open()
        assert.are.equal(1, #calls)
        assert.are.equal("keep errors", calls[1].text)
    end)

    it("Custom focus defaults to the last focus and compacts with the input", function()
        local calls = spy_compact()
        session.compaction.last_focus = "keep errors"
        select_choice = "Custom focus…"
        input_value = "  keep the rollout plan  "
        CompactionDialog.open()
        assert.is_not_nil(input_opts)
        assert.are.equal("Compaction focus", input_opts.title)
        assert.are.equal("keep errors", input_opts.default)
        assert.are.equal(false, input_opts.multiline)
        assert.are.equal(1, #calls)
        assert.are.equal("keep the rollout plan", calls[1].text)
    end)

    it("blank custom focus compacts with no focus", function()
        local calls = spy_compact()
        select_choice = "Custom focus…"
        input_value = "   "
        CompactionDialog.open()
        assert.are.equal(1, #calls)
        assert.is_nil(calls[1].text)
    end)

    it("cancelling the custom input compacts nothing", function()
        local calls = spy_compact()
        select_choice = "Custom focus…"
        input_value = nil
        CompactionDialog.open()
        assert.are.equal(0, #calls)
    end)

    it("the no-focus row compacts with no focus", function()
        local calls = spy_compact()
        select_choice = "No focus (summarize everything)"
        CompactionDialog.open()
        assert.are.equal(1, #calls)
        assert.is_nil(calls[1].text)
    end)

    it("warns instead of opening the dialog without a session", function()
        Sessions.get = function()
            return nil
        end
        local calls = spy_compact()
        CompactionDialog.open()
        assert.is_nil(select_opts)
        assert.are.equal(0, #calls)
        assert.are.equal(vim.log.levels.WARN, last_note().level)
    end)

    it("opens with the generic line before the stats answer is cached", function()
        spy_compact()
        select_choice = nil
        CompactionDialog.open()
        assert.are.equal("Current context will be summarized; the most recent turns are kept.", select_opts.message)
    end)

    it("shows the cached context numbers on the next open", function()
        stats_data = { contextUsage = { tokens = 50000, contextWindow = 200000, percent = 25 } }
        spy_compact()
        select_choice = nil
        CompactionDialog.open()
        assert.are.equal("Current context will be summarized; the most recent turns are kept.", select_opts.message)
        CompactionDialog.open()
        assert.are.equal("context 25% of 200k · keep ~20k · 184k to compact", select_opts.message)
    end)

    it("requests an abort while a compaction runs", function()
        session.chat.compacting = true
        assert.is_true(Pi.compact_abort())
        assert.is_not_nil(first_sent("abort"))
        assert.are.equal(vim.log.levels.INFO, last_note().level)
        assert.is_not_nil(last_note().msg:find("Compaction abort requested", 1, true))
    end)

    it("warns and sends nothing when no compaction is running", function()
        session.chat.compacting = false
        assert.is_false(Pi.compact_abort())
        assert.are.equal(0, #sent)
        assert.are.equal(vim.log.levels.WARN, last_note().level)
        assert.is_not_nil(last_note().msg:find("No compaction is running", 1, true))
    end)

    it("warns and sends nothing when the process is not running", function()
        session.chat.compacting = true
        session.rpc.running = false
        assert.is_false(Pi.compact_abort())
        assert.are.equal(0, #sent)
        assert.are.equal(vim.log.levels.WARN, last_note().level)
    end)

    it("retries an aborted compaction with the same focus", function()
        session.compaction.records = { { aborted = true } }
        session.compaction.last_focus = "keep errors"
        assert.is_true(Pi.compact_retry())
        local cmd = first_sent("compact")
        assert.is_not_nil(cmd)
        assert.are.equal("keep errors", cmd.customInstructions)
    end)

    it("retries a failed compaction with the same focus", function()
        session.compaction.records = { { aborted = false, error = "summarizer exploded" } }
        session.compaction.last_focus = "Preserve test failures and exact errors"
        assert.is_true(Pi.compact_retry())
        local cmd = first_sent("compact")
        assert.is_not_nil(cmd)
        assert.are.equal("Preserve test failures and exact errors", cmd.customInstructions)
    end)

    it("does not retry a successful compaction", function()
        session.compaction.records = { { aborted = false } }
        assert.is_false(Pi.compact_retry())
        assert.are.equal(0, #sent)
        assert.is_not_nil(last_note().msg:find("Nothing to retry", 1, true))
    end)

    it("does not retry without a record", function()
        assert.is_false(Pi.compact_retry())
        assert.are.equal(0, #sent)
        assert.is_not_nil(last_note().msg:find("Nothing to retry", 1, true))
    end)

    it("does not retry while a compaction runs", function()
        session.compaction.records = { { aborted = true } }
        session.chat.compacting = true
        assert.is_false(Pi.compact_retry())
        assert.are.equal(0, #sent)
        assert.is_not_nil(last_note().msg:find("A compaction is already running", 1, true))
    end)
end)
