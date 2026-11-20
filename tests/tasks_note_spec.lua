-- The background-task note: ONE dim UI-only line per delivery report.
--
-- The bundled bg-tasks extension delivers every completion / check-in / startup
-- summary to the MODEL as a `pi2_bg_task` custom message (`display = false`),
-- and the frontend never renders a custom message as conversation content. The
-- note is derived from that same content, so it costs the model nothing and
-- opens no second delivery channel; the discriminator is the extension's
-- `[SYSTEM NOTIFICATION` banner (a panel ping carries no banner and must stay
-- invisible).
--
-- This file covers the three layers of the feature: the pure parser
-- (`pi.tasks_note`), the history append API against a real buffer, and the
-- manager's REPLAY path driven through the real `replay_messages` fold.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")
local TasksNote = require("pi.tasks_note")

local TAB = 1312

local function pump(ms)
    vim.wait(ms or 60)
end

local function lines_of(h)
    return vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
end

--- Rows (0-based) of every buffer line containing `sub` (plain match).
---@param h pi.ChatHistory
---@param sub string
---@return integer[]
local function rows_with(h, sub)
    local out = {}
    for i, line in ipairs(lines_of(h)) do
        if line:find(sub, 1, true) then
            out[#out + 1] = i - 1
        end
    end
    return out
end

--- Is the row highlighted with `PiSystemNote`?
---@param h pi.ChatHistory
---@param row integer
---@return boolean
local function has_note_hl(h, row)
    local marks = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), { row, 0 }, { row, -1 }, { details = true })
    for _, mark in ipairs(marks) do
        if (mark[4] or {}).hl_group == "PiSystemNote" then
            return true
        end
    end
    return false
end

-- Content fixtures mirror `extensions/bg-tasks.ts` (buildWakeNote /
-- buildBatchNote / buildCheckInNote / the startup orphan summary).
local WAKE_NOTE = table.concat({
    "[SYSTEM NOTIFICATION - NOT USER INPUT]",
    "This is an automated task notification, not a message from the user.",
    "<system-reminder>",
    '<background-task id="b3f2a1" status="completed" exit_code="0" signal="" duration_ms="1234" output="/tmp/pi-bash-b3f2a1.log">',
    'Background task b3f2a1 ("echo hi") exited with code 0 after 1.2s.',
    "</background-task>",
    "</system-reminder>",
}, "\n")

local BATCH_NOTE = table.concat({
    "[SYSTEM NOTIFICATION - NOT USER INPUT]",
    "This is an automated task notification, not a message from the user: several background tasks finished together.",
    "<system-reminder>",
    '<background-task id="b3f2a1" status="failed" exit_code="1" signal="" duration_ms="250">npm test</background-task>',
    '<background-task id="c4d5e6" status="stopped" signal="SIGTERM" duration_ms="600000">npm run dev</background-task>',
    "</system-reminder>",
}, "\n")

---@param attrs string attribute text of one element
---@return string
local function check_in_note(attrs)
    return table.concat({
        "[SYSTEM NOTIFICATION - NOT USER INPUT]",
        "This is an automated task notification, not a message from the user. The task is still running.",
        "<system-reminder>",
        "<background-task " .. attrs .. ">",
        "Background task b3f2a1 is still running.",
        "</background-task>",
        "</system-reminder>",
    }, "\n")
end

local STARTUP_NOTE = table.concat({
    "[SYSTEM NOTIFICATION - NOT USER INPUT]",
    "[Background bash tasks found in this session's transcript: 3 — 2 still running]",
    '- b3f2a1 ("npm run dev") is STILL RUNNING (pid 4242, started 3m12s ago). Output: /tmp/x.log',
    "This is an automated startup report, not a message from the user.",
}, "\n")

describe("pi.tasks_note.lines", function()
    it("renders one line for a single-task report inside <system-reminder>", function()
        assert.are.same({ "⚑ b3f2a1 · completed (exit 0) · 1.2s" }, TasksNote.lines(WAKE_NOTE))
    end)

    it("renders one line per element of a coalesced batch, in payload order", function()
        assert.are.same({
            "⚑ b3f2a1 · failed (exit 1) · 0.2s",
            "⚑ c4d5e6 · stopped (signal SIGTERM) · 10m00s",
        }, TasksNote.lines(BATCH_NOTE))
    end)

    it("names a deadline check-in and takes the duration from elapsed_ms", function()
        local content = check_in_note('id="b3f2a1" status="running" check_in="deadline" elapsed_ms="192000"')
        assert.are.same({ "⚑ b3f2a1 · still running (deadline check-in) · 3m12s" }, TasksNote.lines(content))
    end)

    it("names a lifetime check-in", function()
        local content = check_in_note('id="b3f2a1" status="running" check_in="lifetime" elapsed_ms="1000"')
        assert.are.same({ "⚑ b3f2a1 · still running (lifetime cap passed) · 1.0s" }, TasksNote.lines(content))
    end)

    it("says an unknown exit status is unknown — no code, no signal", function()
        local content = check_in_note('id="b3f2a1" status="unknown" exit_code="" signal="" duration_ms="5000"')
        assert.are.same({ "⚑ b3f2a1 · exit status unknown · 5.0s" }, TasksNote.lines(content))
    end)

    it("omits the parenthetical when exit_code / signal are empty", function()
        local completed = check_in_note('id="b3f2a1" status="completed" exit_code="" signal="" duration_ms=""')
        assert.are.same({ "⚑ b3f2a1 · completed" }, TasksNote.lines(completed))
        local stopped = check_in_note('id="b3f2a1" status="stopped" exit_code="" signal="" duration_ms=""')
        assert.are.same({ "⚑ b3f2a1 · stopped" }, TasksNote.lines(stopped))
    end)

    it("turns the startup orphan summary into one line", function()
        assert.are.same({
            "⚑ background bash tasks found in this session's transcript: 3 — 2 still running",
        }, TasksNote.lines(STARTUP_NOTE))
    end)

    it("renders nothing for a panel ping, which shares the customType", function()
        assert.are.same({}, TasksNote.lines("[Background task b3f2a1 started]"))
        assert.are.same({}, TasksNote.lines("[Background task b3f2a1 completed]"))
    end)

    it("renders nothing for a non-string or empty content", function()
        assert.are.same({}, TasksNote.lines(nil))
        assert.are.same({}, TasksNote.lines(42))
        assert.are.same({}, TasksNote.lines({}))
        assert.are.same({}, TasksNote.lines(""))
    end)
end)

describe("History:append_system_note", function()
    before_each(function()
        Config.setup({})
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
        require("pi.ui.highlights").setup()
    end)

    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    it("draws the exact line, highlighted PiSystemNote", function()
        local h = History.new(TAB)
        h:append_system_note({ { "⚑ b3f2a1 · completed (exit 0) · 1.2s", "PiSystemNote" } })
        pump()
        assert.are.same({ "⚑ b3f2a1 · completed (exit 0) · 1.2s" }, lines_of(h))
        assert.is_true(has_note_hl(h, 0))
    end)

    it("lands the note as the FIRST content and finalizes the placeholder", function()
        local h = History.new(TAB)
        h:show_loading_placeholder({ { { "Loading resources…", "PiStartupHint" } } })
        assert.is_false(h:has_conversation_content(), "fresh history must have no conversation content")
        assert.are.equal("loading", h._placeholder_mode)

        local line = TasksNote.lines(STARTUP_NOTE)[1]
        h:append_system_note({ { line, "PiSystemNote" } })
        pump()

        -- the startup summary can be the very first thing in a session
        assert.is_true(h:has_conversation_content())
        assert.is_nil(h._placeholder_mode, "the loading placeholder must be finalized")
        assert.are.same(
            { "⚑ background bash tasks found in this session's transcript: 3 — 2 still running" },
            lines_of(h)
        )
        assert.is_true(has_note_hl(h, 0))
    end)
end)

-- The resume path: a replayed transcript carries the reports as `role="custom"`
-- entries, so the note must be re-derived from them (the transcript, not a live
-- event, is the source after a resume). This drives the REAL `replay_messages`
-- fold via `Sessions.reload_messages`, i.e. the same code path :PiTree and a
-- resumed session use.
describe("background-task note after resume (replay path)", function()
    local Rpc = require("pi.rpc")
    local Sessions = require("pi.sessions.manager")
    local SessionsList = require("pi.ui.sessions")
    local Tasks = require("pi.tasks")

    local real = {} ---@type table<string, function>
    local tab = nil ---@type integer?
    local session ---@type pi.Session?

    ---@return table[]
    local function transcript()
        return {
            { role = "user", content = { { type = "text", text = "go" } }, timestamp = 1 },
            {
                role = "custom",
                customType = "pi2_bg_task",
                content = "[Background task b3f2a1 started]",
                display = false,
                timestamp = 2,
                details = { kind = "started", taskId = "b3f2a1", command = "echo hi", startedAt = 2 },
            },
            {
                role = "custom",
                customType = "pi2_bg_task",
                content = WAKE_NOTE,
                display = false,
                timestamp = 3,
                details = { kind = "completed", taskId = "b3f2a1", command = "echo hi", exitCode = 0 },
            },
        }
    end

    before_each(function()
        Tasks._reset()
        Config.setup({})
        real = {
            start = Rpc.start,
            stop = Rpc.stop,
            send = Rpc.send,
            log_unhandled = Rpc.log_unhandled,
            request_refresh = SessionsList.request_refresh,
        }
        Rpc.start = function(self)
            self._job_id = 998
            return true
        end
        Rpc.stop = function(self)
            self._job_id = nil
            self._pending = {}
        end
        Rpc.send = function(_, cmd, callback)
            if cmd.type == "get_messages" then
                local messages = transcript()
                vim.schedule(function()
                    callback({ success = true, data = { messages = messages } })
                end)
            elseif cmd.type == "get_commands" then
                vim.schedule(function()
                    callback({ success = true, data = { commands = {} } })
                end)
            end
            return true
        end
        Rpc.log_unhandled = function() end
        SessionsList.request_refresh = function() end

        vim.cmd("tabnew")
        tab = vim.api.nvim_get_current_tabpage()
        session = Sessions.get_or_create({ layout = "split" })
        assert.truthy(session, "session creation failed")
    end)

    after_each(function()
        if tab then
            local tabs = vim.api.nvim_list_tabpages()
            if #tabs > 1 then
                vim.api.nvim_set_current_tabpage(tabs[1])
            end
            pcall(vim.api.nvim_tabpage_close, tab)
            tab = nil
        end
        session = nil
        Rpc.start = real.start
        Rpc.stop = real.stop
        Rpc.send = real.send
        Rpc.log_unhandled = real.log_unhandled
        SessionsList.request_refresh = real.request_refresh
        Tasks._reset()
    end)

    it("renders the report once and leaves the panel ping invisible", function()
        assert.truthy(session, "session missing")
        Sessions.reload_messages(session)
        local h = session.chat._history
        assert.is_true(
            vim.wait(2000, function()
                return #rows_with(h, "⚑ b3f2a1 · completed (exit 0) · 1.2s") == 1
            end, 20),
            "the replayed report must leave one dim line:\n" .. table.concat(lines_of(h), "\n")
        )

        local rows = rows_with(h, "⚑")
        assert.are.equal(1, #rows, "the `started` panel ping must render no line")
        assert.is_true(has_note_hl(h, rows[1]))

        -- The task fold still runs: the note is a display concern, not a
        -- replacement for the registry entry the replayed tool blocks read.
        assert.are.equal("completed", Tasks.get("b3f2a1").status)
    end)
end)
