-- Gitea #127: the session manager is the single place the compaction events are
-- recorded, so the panel, the statusline countdown and the history block all
-- read the same numbers.
--
-- These specs drive the REAL session manager with a stubbed Rpc (no pi
-- process — same pattern as agent_settled_spec): every case asserts what the
-- manager does with an event, not what the backend says. `Chat:set_compaction_budget`
-- and the `meta` argument of the history block belong to the parallel UI task,
-- so the budget and the replay match are observed at the manager→chat boundary.

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")
local SessionsList = require("pi.ui.sessions")
local CompactionSettings = require("pi.compaction.settings")

Config.setup({})

local real = {
    start = Rpc.start,
    stop = Rpc.stop,
    send = Rpc.send,
    log_unhandled = Rpc.log_unhandled,
    request_refresh = SessionsList.request_refresh,
    resolve = CompactionSettings.resolve,
    budget = CompactionSettings.budget,
    notify = vim.notify,
}

--- `get_messages` payload the stub answers with (the compaction rebuild reads it).
local messages = {}
--- `get_state` payload the stub answers with (model + context window).
local state_data = {}

--- `vim.notify` spy records.
local notes = {}

local function install_stubs()
    messages = {}
    notes = {}
    state_data = {
        model = { provider = "test-provider", id = "test-model", contextWindow = 200000 },
        thinkingLevel = "off",
    }

    Rpc.start = function(self)
        self._job_id = 999
        return true
    end
    Rpc.stop = function(self)
        self._job_id = nil
        self._pending = {}
    end
    Rpc.send = function(self, cmd, callback)
        if cmd.type == "get_messages" then
            local payload = messages
            if callback then
                vim.schedule(function()
                    callback({ success = true, data = { messages = payload } })
                end)
            end
        elseif cmd.type == "get_state" then
            local payload = state_data
            if callback then
                vim.schedule(function()
                    callback({ success = true, data = payload })
                end)
            end
        end
        return true
    end
    Rpc.log_unhandled = function() end
    SessionsList.request_refresh = function() end

    vim.notify = function(msg, level, opts)
        notes[#notes + 1] = { msg = msg, level = level, opts = opts }
    end

    -- Settings are stubbed for the whole file: no test may read the user's
    -- ~/.pi/agent or this checkout's .pi/settings.json (G17). The one case that
    -- needs the real resolver pins a temp agent dir instead.
    CompactionSettings.resolve = function()
        return { reserve = 16384, keep = 20000, enabled = true, source = "settings" }
    end
end

local function restore_stubs()
    Rpc.start = real.start
    Rpc.stop = real.stop
    Rpc.send = real.send
    Rpc.log_unhandled = real.log_unhandled
    SessionsList.request_refresh = real.request_refresh
    CompactionSettings.resolve = real.resolve
    CompactionSettings.budget = real.budget
    CompactionSettings._reset()
    vim.notify = real.notify
end

--- Drive the events through the manager's installed RPC handler.
---@param session pi.Session
local function feed(session, ...)
    local handler = session.rpc._handler
    assert.truthy(handler, "handler not installed")
    for _, msg in ipairs({ ... }) do
        handler(msg)
    end
end

---@param fn fun(): boolean
---@param what string
local function wait_for(fn, what)
    assert(vim.wait(4000, fn, 10), what)
end

describe("compaction events", function()
    local tab = nil ---@type integer?
    local session = nil ---@type pi.Session?
    local chat = nil ---@type pi.Chat?
    local tmpdir = nil ---@type string?

    --- Whole history text, for "the existing notice still renders" assertions.
    ---@return string
    local function history_text()
        local lines = vim.api.nvim_buf_get_lines(chat._history._buf, 0, -1, false)
        return table.concat(lines, "\n")
    end

    --- One compaction round-trip, waiting for the post-compaction rebuild.
    ---@param tokens_before integer
    local function compact(tokens_before)
        feed(session, { type = "compaction_start", reason = "threshold" })
        feed(session, {
            type = "compaction_end",
            reason = "threshold",
            result = {
                summary = "S",
                tokensBefore = tokens_before,
                estimatedTokensAfter = tokens_before,
            },
        })
        wait_for(function()
            return session._compaction_rebuilding ~= true
        end, "post-compaction rebuild must finish")
    end

    before_each(function()
        install_stubs()
        tmpdir = vim.fn.tempname()
        vim.fn.mkdir(tmpdir, "p")

        local tabs = vim.api.nvim_list_tabpages()
        vim.cmd("tabnew")
        tab = vim.api.nvim_get_current_tabpage()
        assert.is_true(#vim.api.nvim_list_tabpages() > #tabs, "tab must be created")

        session = Sessions.get_or_create({ layout = "split" })
        assert.truthy(session, "session creation failed")
        chat = session.chat
        assert.truthy(chat, "chat must be bound")
    end)

    after_each(function()
        pcall(Sessions.stop)
        Sessions._reset()
        if tab then
            local tabs = vim.api.nvim_list_tabpages()
            if #tabs > 1 then
                vim.api.nvim_set_current_tabpage(tabs[1])
            end
            pcall(vim.api.nvim_tabpage_close, tab)
        end
        if tmpdir then
            vim.fn.delete(tmpdir, "rf")
        end
        restore_stubs()
    end)

    it("records a successful compaction and renders its history block", function()
        messages = { { role = "compactionSummary", summary = "S", tokensBefore = 150000 } }
        feed(session, { type = "agent_start" }, { type = "agent_end", messages = {} })
        feed(session, { type = "compaction_start", reason = "threshold" })
        feed(session, {
            type = "compaction_end",
            reason = "threshold",
            result = {
                summary = "S",
                firstKeptEntryId = "entry-7",
                tokensBefore = 150000,
                estimatedTokensAfter = 40000,
                usage = { input = 100, output = 20 },
                details = {
                    readFiles = { "a.lua", "b.lua" },
                    modifiedFiles = { "c.lua" },
                    engine = "pi2-compaction",
                },
            },
        })

        local state = Sessions.get_compaction_state(session)
        assert.truthy(state, "session must carry compaction state")
        assert.are.equal(1, #state.records, "one finished compaction, one record")
        local record = state.records[1]
        assert.are.equal("threshold", record.reason)
        assert.are.equal(150000, record.tokens_before)
        assert.are.equal(40000, record.tokens_after)
        assert.is_true(record.estimated)
        assert.are.equal("entry-7", record.first_kept_entry_id)
        assert.are.equal(2, record.read_files)
        assert.are.equal(1, record.modified_files)
        assert.are.equal("pi2-compaction", record.engine)
        assert.are.same({ input = 100, output = 20 }, record.usage)
        assert.are.equal(1, record.turn, "agent_start must open a turn")
        assert.is_false(record.aborted)

        wait_for(function()
            return #chat._history._compaction_blocks == 1
        end, "the rebuilt transcript must carry the compaction block")
        assert.are.equal("S", chat._history._compaction_blocks[1].summary)
        assert.are.equal(150000, chat._history._compaction_blocks[1].tokens_before)
    end)

    it("records aborted and failed compactions, keeping their notices", function()
        feed(session, { type = "agent_start" }, { type = "agent_end", messages = {} })

        feed(session, { type = "compaction_start", reason = "manual" })
        feed(session, { type = "compaction_end", reason = "manual", aborted = true, result = {} })
        local aborted = Sessions.get_compaction_state(session).records[1]
        assert.is_true(aborted.aborted)
        assert.are.equal("manual", aborted.reason)
        wait_for(function()
            return chat._history._status_text == nil
        end, "an aborted compaction must restore the idle status")
        wait_for(function()
            return history_text():find("Compaction cancelled", 1, true) ~= nil
        end, "the cancelled notice must still render")

        feed(session, { type = "compaction_start", reason = "overflow" })
        feed(session, { type = "compaction_end", reason = "overflow", errorMessage = "boom", result = {} })
        local failed = Sessions.get_compaction_state(session).records[2]
        assert.are.equal("boom", failed.error)
        assert.is_false(failed.aborted)
        assert.are.equal("overflow", failed.reason)
        wait_for(function()
            return chat._history._status_text == nil
        end, "a failed compaction must restore the idle status")
        wait_for(function()
            return history_text():find("boom", 1, true) ~= nil
        end, "the failure notice must still render")
    end)

    it("hands the replay the record it matches by summary and occupancy", function()
        local appended = {} ---@type table[]
        local original_append = chat.append_compaction_summary
        chat.append_compaction_summary = function(self, summary, tokens_before, meta)
            appended[#appended + 1] = { summary = summary, tokens_before = tokens_before, meta = meta }
            return original_append(self, summary, tokens_before, meta)
        end

        messages = { { role = "compactionSummary", summary = "S", tokensBefore = 150000 } }
        feed(session, { type = "agent_start" }, { type = "agent_end", messages = {} })
        feed(session, { type = "compaction_start", reason = "threshold" })
        feed(session, {
            type = "compaction_end",
            reason = "threshold",
            result = { summary = "S", tokensBefore = 150000, estimatedTokensAfter = 40000 },
        })
        wait_for(function()
            return session._compaction_rebuilding ~= true
        end, "post-compaction rebuild must finish")
        wait_for(function()
            return #appended == 1
        end, "the replay must append the compaction summary")

        local record = Sessions.get_compaction_state(session).records[1]
        assert.are.equal("S", appended[1].summary)
        assert.are.equal(150000, appended[1].tokens_before)
        assert.are.equal(record, appended[1].meta, "the replayed message must carry its record")
        wait_for(function()
            return #chat._history._compaction_blocks == 1
        end, "the history block must exist")
        -- Once the UI task lands the `meta` parameter on the block, the record
        -- is the very table stored there (identity, not a copy).
        local block = chat._history._compaction_blocks[1]
        if block.meta ~= nil then
            assert.are.equal(record, block.meta)
        end
    end)

    it("records the focus given to the next compaction", function()
        Sessions.set_compaction_focus(session, "keep errors")
        feed(session, { type = "agent_start" }, { type = "agent_end", messages = {} })
        feed(session, { type = "compaction_start", reason = "manual" })
        feed(session, {
            type = "compaction_end",
            reason = "manual",
            result = { summary = "S", tokensBefore = 1000 },
        })
        local record = Sessions.get_compaction_state(session).records[1]
        assert.are.equal("keep errors", record.custom_instructions)
        assert.are.equal(Sessions.get_compaction_state(), Sessions.get_compaction_state(session))
        assert.are.equal(session.compaction, Sessions.get_compaction_state())
    end)

    it("shows summarization retries in the compaction status", function()
        local statuses = {} ---@type table[]
        local errors = 0
        local original_set_status = chat.set_status
        local original_on_error = chat.on_error
        chat.set_status = function(_, status)
            statuses[#statuses + 1] = status
        end
        chat.on_error = function(self, message, opts)
            errors = errors + 1
            return original_on_error(self, message, opts)
        end

        feed(session, { type = "agent_start" }, { type = "agent_end", messages = {} })
        feed(session, { type = "compaction_start", reason = "threshold" })
        feed(session, {
            type = "summarization_retry_scheduled",
            attempt = 2,
            maxAttempts = 3,
            delayMs = 1000,
            errorMessage = "429",
        })
        feed(session, { type = "summarization_retry_attempt_start", source = "compaction" })

        local retry_status = nil
        for _, status in ipairs(statuses) do
            if status.type == "compaction" and status.text ~= nil then
                retry_status = status
            end
        end
        assert.truthy(retry_status, "the retry must reach the compaction status")
        assert.are.equal("summary retry 2/3 (429)", retry_status.text)
        assert.are.equal(0, errors, "a transient retry must not open an error block")

        feed(session, { type = "summarization_retry_finished" })
        local cleared = statuses[#statuses]
        assert.are.equal("compaction", cleared.type)
        assert.is_nil(cleared.text, "finishing the retry must clear the custom text")

        chat.set_status = original_set_status
        chat.on_error = original_on_error
    end)

    it("pushes the compaction budget derived from the model window", function()
        local pushed = {} ---@type pi.CompactionBudget[]
        chat.set_compaction_budget = function(_, budget)
            pushed[#pushed + 1] = budget
        end

        Sessions.refresh_state(session)
        wait_for(function()
            return #pushed >= 1
        end, "refresh_state must push the budget")

        local budget = pushed[#pushed]
        assert.are.equal(200000, budget.window)
        assert.are.equal(16384, budget.reserve)
        assert.are.equal(20000, budget.keep)
        assert.are.equal(200000 - 16384, budget.threshold)
        assert.is_false(budget.pathological)
    end)

    it("warns once about a pathological budget and stays quiet when healthy", function()
        local pushed = 0
        chat.set_compaction_budget = function()
            pushed = pushed + 1
        end

        -- keep (200000) >= threshold (200000 - 16384): nothing is cuttable.
        CompactionSettings.resolve = function()
            return { reserve = 16384, keep = 200000, enabled = true, source = "settings" }
        end
        Sessions.refresh_state(session)
        Sessions.refresh_state(session)
        wait_for(function()
            return pushed >= 2
        end, "both refreshes must push a budget")
        assert.are.equal(1, #notes, "the pathological warning must render once")
        assert.truthy(notes[1].msg:find("Compaction cannot cut anything", 1, true))

        -- A healthy budget must not add anything.
        CompactionSettings.resolve = function()
            return { reserve = 16384, keep = 20000, enabled = true, source = "settings" }
        end
        Sessions.refresh_state(session)
        wait_for(function()
            return pushed >= 3
        end, "the third refresh must push a budget")
        assert.are.equal(1, #notes, "a healthy budget must warn nothing")
    end)

    it("does not duplicate the settings module's invalid-settings warning", function()
        -- The real resolver reports an invalid file once per stamp; the manager
        -- must not add a second notice for the same typo.
        CompactionSettings.resolve = real.resolve
        CompactionSettings._set_agent_dir(tmpdir)
        local settings_path = tmpdir .. "/settings.json"
        vim.fn.writefile({ '{"compaction":{"reserveTokens":"nope"}}' }, settings_path)
        session.cwd = tmpdir

        local pushed = 0
        chat.set_compaction_budget = function()
            pushed = pushed + 1
        end
        Sessions.refresh_state(session)
        Sessions.refresh_state(session)
        wait_for(function()
            return pushed >= 2
        end, "both refreshes must push a budget")
        assert.are.equal(1, #notes, "invalid settings must be reported exactly once")
        assert.truthy(notes[1].msg:find("compaction settings", 1, true))
    end)

    it("warns once when compactions keep re-filling the window", function()
        feed(session, { type = "agent_start" })
        compact(100000)
        compact(110000)
        assert.are.equal(0, #notes, "two compactions are not thrash yet")
        compact(120000)
        wait_for(function()
            return #notes == 1
        end, "three non-releasing compactions must warn once")
        assert.truthy(notes[1].msg:find("Compaction is not freeing context", 1, true))
        assert.truthy(notes[1].msg:find("100k → 110k → 120k", 1, true))

        compact(130000)
        assert.are.equal(1, #notes, "the thrash warning is once per session")
    end)

    it("reads no compaction settings while creating a session", function()
        local reads = 0
        CompactionSettings.resolve = function()
            reads = reads + 1
            error("CompactionSettings.resolve must not run on the setup path")
        end

        pcall(Sessions.stop)
        Sessions._reset()
        local created = Sessions.get_or_create({ layout = "split" })
        assert.truthy(created)
        assert.truthy(created.compaction, "a created session carries compaction state")
        vim.wait(100, function()
            return false
        end)
        assert.are.equal(0, reads, "creating a session must not read pi's settings")
    end)
end)
