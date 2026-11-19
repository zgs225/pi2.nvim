-- wait_task rendering (bundled bg-tasks extension) plus the model-facing
-- contract that lives in extensions/bg-tasks.ts. The renderer half runs against
-- a real history buffer; the .ts half is a source contract check, because the
-- tool itself only ever executes inside pi.

local History = require("pi.ui.chat.history")
local Tasks = require("pi.tasks")
local Tools = require("pi.ui.chat.tools")

local TAB = 903

local function pump(ms)
    vim.wait(ms or 30)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function text_of(buf)
    return table.concat(lines_of(buf), "\n")
end

--- Rows (0-based) of every buffer line containing `sub` (plain match).
local function rows_with(buf, sub)
    local out = {}
    for i, l in ipairs(lines_of(buf)) do
        if l:find(sub, 1, true) then
            out[#out + 1] = i - 1
        end
    end
    return out
end

---@return string
local function repo_root()
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
end

local function read_extension()
    local path = repo_root() .. "/extensions/bg-tasks.ts"
    local fh = assert(io.open(path, "r"))
    local text = fh:read("*a")
    fh:close()
    return text
end

--- Every inline virt_text chunk on the block header, in buffer order.
---@param h pi.ChatHistory
---@return string[]
local function header_virt(h)
    local out = {}
    for _, em in ipairs(vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })) do
        local vt = (em[4] or {}).virt_text
        if vt then
            for _, chunk in ipairs(vt) do
                if type(chunk[1]) == "string" then
                    out[#out + 1] = chunk[1]
                end
            end
        end
    end
    return out
end

--- Whether any header virt text equals `want` (trimmed) — the status badge.
---@param h pi.ChatHistory
---@param want string
---@return boolean
local function has_badge(h, want)
    for _, chunk in ipairs(header_virt(h)) do
        if vim.trim(chunk) == want then
            return true
        end
    end
    return false
end

--- Register a background task the way the extension's `started` event does.
---@param id string
---@param command string
local function register_task(id, command)
    Tasks.upsert({
        id = id,
        command = command,
        status = "running",
        start_time = vim.uv.now(),
        session_id = "s1",
        tab = TAB,
    })
end

local function delete(h)
    pcall(vim.api.nvim_buf_delete, h:buf(), { force = true })
end

describe("wait_task renderer", function()
    it("has a dedicated hourglass icon instead of the generic tool fallback", function()
        -- Blocks are read by their glyph: a generic dot makes a wait look like
        -- an unrecognized tool. nf-md-timer_sand, distinct from bash's terminal
        -- and from the sub-agent clock glyphs.
        assert.are.equal(vim.fn.nr2char(0xF051F, 1), Tools.get_tool_icon("wait_task"))
    end)

    it("renders as a block, not an inline one-liner", function()
        local renderer = Tools.get_renderer("wait_task")
        assert.is_table(renderer)
        -- The result body carries the backgrounded command's output — the only
        -- place it reaches the chat — so an inline renderer would hide it.
        assert.is_falsy(Tools.is_inline(renderer, { task_id = "b1" }))
        assert.is_true(renderer.output_visible > 0)
    end)

    it("shows the task id and the attach window as the block body", function()
        local h = History.new(TAB)
        h:on_tool_start("wait_task", "wt1", { task_id = "b3f2a1", timeout_ms = 60000 })
        pump(50)
        local buf = h:buf()
        assert.is_true(#rows_with(buf, "wait_task") == 1, "expected the tool name in the header")
        assert.is_true(#rows_with(buf, "b3f2a1") == 1, "expected the task id")
        assert.is_true(#rows_with(buf, "(timeout 60s)") == 1, "expected the attach window in seconds")
    end)

    it("omits the window when the call did not pass one", function()
        local h = History.new(TAB)
        h:on_tool_start("wait_task", "wt2", { task_id = "b3f2a1" })
        pump(50)
        local buf = h:buf()
        assert.is_true(#rows_with(buf, "b3f2a1") == 1)
        assert.is_true(#rows_with(buf, "timeout") == 0)
    end)

    it("leads with the command the task runs, not just its id", function()
        Tasks._reset()
        register_task("b3f2a1", "npm run dev")
        local h = History.new(TAB)
        h:on_tool_start("wait_task", "wt4", { task_id = "b3f2a1", timeout_ms = 30000 })
        pump(50)
        local buf = h:buf()
        -- The id alone says nothing about what is being waited on; the command
        -- comes from the registry the extension's `started` event populates.
        assert.is_true(#rows_with(buf, "npm run dev · b3f2a1 (timeout 30s)") == 1, table.concat(lines_of(buf), "\n"))
        delete(h)
        Tasks._reset()
    end)

    it("flattens and truncates an over-long command", function()
        Tasks._reset()
        register_task("b3f2a1", "echo one\necho " .. string.rep("x", 200))
        local h = History.new(TAB)
        h:on_tool_start("wait_task", "wt5", { task_id = "b3f2a1" })
        pump(50)
        local buf = h:buf()
        local row = rows_with(buf, "echo one")[1]
        assert.is_not_nil(row, "expected the command row")
        local line = lines_of(buf)[row + 1]
        assert.is_truthy(line:find("…", 1, true), "expected the command to be elided")
        assert.is_true(vim.fn.strdisplaywidth(line) <= 80 + #" · b3f2a1", line)
        delete(h)
        Tasks._reset()
    end)

    it("badges a deadline hit as still running, not as an error", function()
        local h = History.new(TAB)
        h:on_tool_start("wait_task", "wt6", { task_id = "b3f2a1", timeout_ms = 3000 })
        pump(50)
        h:on_tool_end("wait_task", "wt6", {
            content = { { type = "text", text = "[still running] Task b3f2a1 has not exited after 3.0s." } },
            details = { taskId = "b3f2a1", status = "still_running", wallTimeSeconds = 3.0 },
        }, false)
        pump(60)
        assert.is_true(has_badge(h, "still running"), table.concat(header_virt(h), "|"))
        delete(h)
    end)

    it("stays silent on a clean exit and badges a failure", function()
        local h = History.new(TAB)
        h:on_tool_start("wait_task", "wt7", { task_id = "b3f2a1" })
        pump(50)
        h:on_tool_end("wait_task", "wt7", {
            content = { { type = "text", text = "Task b3f2a1 exited with code 0 after 6.0s." } },
            details = { taskId = "b3f2a1", status = "exited", exitCode = 0, wallTimeSeconds = 6.0 },
        }, false)
        pump(60)
        assert.is_false(has_badge(h, "still running"))
        assert.is_false(has_badge(h, "exit 0"))
        delete(h)

        local h2 = History.new(TAB)
        h2:on_tool_start("wait_task", "wt8", { task_id = "b3f2a1" })
        pump(50)
        h2:on_tool_end("wait_task", "wt8", {
            content = { { type = "text", text = "Task b3f2a1 exited with code 2 after 1.0s." } },
            details = { taskId = "b3f2a1", status = "exited", exitCode = 2, wallTimeSeconds = 1.0 },
        }, true)
        pump(60)
        assert.is_true(has_badge(h2, "exit 2"), table.concat(header_virt(h2), "|"))
        delete(h2)
    end)

    it("badges a signal and a cancelled wait", function()
        local h = History.new(TAB)
        h:on_tool_start("wait_task", "wt9", { task_id = "b3f2a1" })
        pump(50)
        h:on_tool_end("wait_task", "wt9", {
            content = { { type = "text", text = "Task b3f2a1 was killed by SIGTERM." } },
            details = { taskId = "b3f2a1", status = "exited", signal = "SIGTERM", wallTimeSeconds = 1.0 },
        }, true)
        pump(60)
        assert.is_true(has_badge(h, "signal SIGTERM"), table.concat(header_virt(h), "|"))
        delete(h)

        local h2 = History.new(TAB)
        h2:on_tool_start("wait_task", "wt10", { task_id = "b3f2a1" })
        pump(50)
        h2:on_tool_end("wait_task", "wt10", {
            content = { { type = "text", text = "[cancelled] stopped waiting for task b3f2a1" } },
            details = { taskId = "b3f2a1", status = "cancelled", wallTimeSeconds = 1.0 },
        }, true)
        pump(60)
        assert.is_true(has_badge(h2, "wait cancelled"), table.concat(header_virt(h2), "|"))
        delete(h2)
    end)

    it("renders the waited task's output as the result body", function()
        local h = History.new(TAB)
        h:on_tool_start("wait_task", "wt3", { task_id = "b3f2a1" })
        pump(50)
        h:on_tool_end(
            "wait_task",
            "wt3",
            { content = { { type = "text", text = "Task b3f2a1 exited with code 0 after 6.0s.\n\nDONE-MARKER" } } },
            false
        )
        pump(60)
        local text = text_of(h:buf())
        assert.is_truthy(text:find("exited with code 0", 1, true), "expected the exit line")
        assert.is_truthy(text:find("DONE-MARKER", 1, true), "expected the task output")
    end)
end)

describe("stop_task / list_tasks renderer", function()
    it("gives both tools their own glyph instead of the generic fallback", function()
        assert.are.equal(vim.fn.nr2char(0xF04DB, 1), Tools.get_tool_icon("stop_task"))
        assert.are.equal(vim.fn.nr2char(0xF0279, 1), Tools.get_tool_icon("list_tasks"))
    end)

    it("names the task a stop targets, with the grace window when one was given", function()
        Tasks._reset()
        register_task("b3f2a1", "npm run dev")
        local h = History.new(TAB)
        h:on_tool_start("stop_task", "st1", { task_id = "b3f2a1", timeout_ms = 5000 })
        pump(50)
        local buf = h:buf()
        assert.is_true(#rows_with(buf, "npm run dev · b3f2a1 (grace 5s)") == 1, table.concat(lines_of(buf), "\n"))
        delete(h)
        Tasks._reset()
    end)

    it("stays silent on a clean stop and badges an escalation", function()
        local h = History.new(TAB)
        h:on_tool_start("stop_task", "st2", { task_id = "b3f2a1" })
        pump(50)
        h:on_tool_end("stop_task", "st2", {
            content = { { type = "text", text = "Task b3f2a1 was stopped (signal SIGTERM) after 3.0s (stopped)." } },
            details = { taskId = "b3f2a1", status = "stopped", escalated = false },
        }, false)
        pump(60)
        assert.is_false(has_badge(h, "killed"))
        assert.is_false(has_badge(h, "still running"))
        delete(h)

        local h2 = History.new(TAB)
        h2:on_tool_start("stop_task", "st3", { task_id = "b3f2a1" })
        pump(50)
        h2:on_tool_end("stop_task", "st3", {
            content = {
                { type = "text", text = "Task b3f2a1 was SIGKILLed (it ignored SIGTERM) after 8.0s (stopped)." },
            },
            details = { taskId = "b3f2a1", status = "stopped", escalated = true },
        }, false)
        pump(60)
        assert.is_true(has_badge(h2, "killed"), table.concat(header_virt(h2), "|"))
        delete(h2)
    end)

    it("badges a stop that did not take as still running", function()
        local h = History.new(TAB)
        h:on_tool_start("stop_task", "st4", { task_id = "b3f2a1" })
        pump(50)
        h:on_tool_end("stop_task", "st4", {
            content = { { type = "text", text = "[still running] Task b3f2a1 did not exit" } },
            details = { taskId = "b3f2a1", status = "still_running", escalated = true },
        }, true)
        pump(60)
        assert.is_true(has_badge(h, "still running"), table.concat(header_virt(h), "|"))
        delete(h)
    end)

    it("renders the task list as the body, not as one collapsed line", function()
        local h = History.new(TAB)
        h:on_tool_start("list_tasks", "lt1", {})
        pump(50)
        h:on_tool_end("list_tasks", "lt1", {
            content = {
                {
                    type = "text",
                    text = '1 of 1 background task, 1 running:\n- b3f2a1 [running] 1m04s "npm run dev" (output: /tmp/pi-bash-b3f2a1.log)',
                },
            },
            details = { total = 1, running = 1, listed = 1 },
        }, false)
        pump(60)
        local text = text_of(h:buf())
        assert.is_truthy(text:find("npm run dev", 1, true), "expected the task row")
        assert.is_truthy(text:find("pi-bash-b3f2a1.log", 1, true), "expected the log path")
        delete(h)
    end)
end)

describe("task_input renderer", function()
    it("gives the tool its own glyph instead of the generic fallback", function()
        assert.are.equal(vim.fn.nr2char(0xF030C, 1), Tools.get_tool_icon("task_input"))
    end)

    it("names the task and quotes the line it wrote", function()
        Tasks._reset()
        register_task("b3f2a1", "npm run dev")
        local h = History.new(TAB)
        h:on_tool_start("task_input", "ti1", { task_id = "b3f2a1", data = "y" })
        pump(50)
        local buf = h:buf()
        assert.is_true(#rows_with(buf, "npm run dev · b3f2a1") == 1, table.concat(lines_of(buf), "\n"))
        assert.is_true(#rows_with(buf, "→ y") == 1, table.concat(lines_of(buf), "\n"))
        delete(h)
        Tasks._reset()
    end)

    it("flags a raw write and stays silent when the bytes landed", function()
        Tasks._reset()
        register_task("b3f2a1", "npm run dev")
        local h = History.new(TAB)
        h:on_tool_start("task_input", "ti2", { task_id = "b3f2a1", data = "x", newline = false })
        pump(50)
        assert.is_true(#rows_with(h:buf(), "(no newline)") == 1, table.concat(lines_of(h:buf()), "\n"))
        h:on_tool_end("task_input", "ti2", {
            content = { { type = "text", text = "Wrote 1 byte(s) to task b3f2a1's stdin." } },
            details = { taskId = "b3f2a1", status = "written", bytes = 1 },
        }, false)
        pump(60)
        assert.is_false(has_badge(h, "no stdin"))
        assert.is_false(has_badge(h, "already exited"))
        delete(h)
        Tasks._reset()
    end)

    it("badges a task that has no stdin, and one that already exited", function()
        local h = History.new(TAB)
        h:on_tool_start("task_input", "ti3", { task_id = "bdead1", data = "y" })
        pump(50)
        h:on_tool_end("task_input", "ti3", {
            content = {
                { type = "text", text = "Task bdead1 has no usable stdin: it was started without a stdin pipe" },
            },
            details = { taskId = "bdead1", status = "no_stdin" },
        }, true)
        pump(60)
        assert.is_true(has_badge(h, "no stdin"), table.concat(header_virt(h), "|"))
        delete(h)

        local h2 = History.new(TAB)
        h2:on_tool_start("task_input", "ti4", { task_id = "bdead2", data = "y" })
        pump(50)
        h2:on_tool_end("task_input", "ti4", {
            content = { { type = "text", text = "Task bdead2 exited with code 0 — its stdin is gone" } },
            details = { taskId = "bdead2", status = "exited" },
        }, true)
        pump(60)
        assert.is_true(has_badge(h2, "already exited"), table.concat(header_virt(h2), "|"))
        delete(h2)
    end)
end)

describe("bg-tasks extension contract", function()
    it("registers a wait_task tool and points bash at it", function()
        local src = read_extension()
        assert.is_truthy(src:find('name: "wait_task"', 1, true), "wait_task must be registered")
        assert.is_truthy(src:find("call wait_task", 1, true), "the bash result must offer wait_task")
        assert.is_truthy(src:find("run_in_background", 1, true))
    end)

    it("never tells the model to sleep, and authorizes ending the turn", function()
        local src = read_extension()
        assert.is_truthy(src:find("Never wait with `sleep`", 1, true))
        assert.is_truthy(src:find("ending your turn is the correct", 1, true))
        assert.is_truthy(src:find("is not a failure", 1, true))
    end)

    it("hands an outlived foreground command to the background instead of killing it", function()
        local src = read_extension()
        assert.is_truthy(src:find("detachedByTimeout", 1, true), "detach must be reported in details")
        assert.is_truthy(
            src:find("keeps running as background task", 1, true),
            "the result must say the command survived"
        )
    end)

    it("marks the wake report as a system notification, not user input", function()
        local src = read_extension()
        assert.is_truthy(src:find("[SYSTEM NOTIFICATION - NOT USER INPUT]", 1, true))
    end)

    it("keeps completion delivery exactly-once through an observer lease", function()
        local src = read_extension()
        -- The lease is what stops a waited-on task from also producing a wake.
        assert.is_truthy(src:find("observers", 1, true))
        assert.is_truthy(src:find("task.observers > 0", 1, true))
    end)

    it("registers stop_task and list_tasks for the model, not only the panel", function()
        local src = read_extension()
        assert.is_truthy(src:find('name: "stop_task"', 1, true), "stop_task must be registered")
        assert.is_truthy(src:find('name: "list_tasks"', 1, true), "list_tasks must be registered")
        -- The model has to be told the affordance exists in the bash tool too.
        assert.is_truthy(src:find("is stopped with stop_task", 1, true))
        assert.is_truthy(src:find("list_tasks shows what is still running", 1, true))
    end)

    it("stops the whole process group, escalating SIGTERM to SIGKILL", function()
        local src = read_extension()
        -- A bare-pid kill leaves `node` under `npm` running and holding the port.
        assert.is_truthy(src:find("process.kill(-pid, signal)", 1, true), "must signal the group")
        assert.is_truthy(src:find("SIGTERM", 1, true))
        assert.is_truthy(src:find("SIGKILL", 1, true))
        assert.is_truthy(src:find("pid <= 1", 1, true), "pid 0/1 must never be signalled")
    end)

    it("takes the observer lease before signalling, so a stop is not also a wake", function()
        local src = read_extension()
        -- Order matters: attach, THEN signal. If the exit landed first the model
        -- would get a wake report for a task this call is describing itself.
        local attach_at = src:find("let waited = attachWait(task, { deadlineMs: grace, signal })", 1, true)
        local signal_at = src:find('signalProcessGroup(task.pid, "SIGTERM")', 1, true)
        assert.is_truthy(attach_at, "stop_task must attach before signalling")
        assert.is_truthy(signal_at, "stop_task must signal the group")
        assert.is_true(attach_at < signal_at, "the lease must be taken before the signal")
    end)

    it("identifies an adopted pid by its start time, not by its command line", function()
        local src = read_extension()
        -- A shell execs the last command of its `-c` script, so the recorded
        -- command text and the live command line routinely disagree; identity
        -- has to be the pid's start time. Text matching must not come back.
        assert.is_truthy(src:find("pidStartTime", 1, true), "adoption must record a start-time fingerprint")
        assert.is_truthy(src:find("/proc/", 1, true), "the fingerprint comes from the process table")
        assert.is_nil(src:find("pidMatchesCommand", 1, true), "a command line is not identity")
    end)

    it("wraps every report in one structured reminder block", function()
        local src = read_extension()
        -- ONE helper builds the block, so the single and the batched form cannot
        -- drift apart (a reader looks for the same wrapper either way).
        local _, wrap_defs = src:gsub("function wrapReminder%(", "")
        assert.are.equal(1, wrap_defs, "wrapReminder must be defined exactly once")
        assert.is_truthy(src:find("<system-reminder>", 1, true))
        assert.is_truthy(src:find("</system-reminder>", 1, true))
        assert.is_truthy(src:find("<background-task ", 1, true), "each task is one element")
        local wake_start = assert(src:find("function buildWakeNote", 1, true), "buildWakeNote must exist")
        local batch_start = assert(src:find("function buildBatchNote", wake_start, true), "buildBatchNote follows")
        local batch_end = src:find("function messageText", batch_start, true) or #src
        assert.is_truthy(
            src:sub(wake_start, batch_start):find("wrapReminder(", 1, true),
            "the single-task note must go through wrapReminder"
        )
        assert.is_truthy(
            src:sub(batch_start, batch_end):find("wrapReminder(", 1, true),
            "the batch note must go through wrapReminder"
        )
    end)

    it("carries the status in machine-readable attributes", function()
        local src = read_extension()
        assert.is_truthy(src:find("function reportStatus(", 1, true), "reportStatus must exist")
        for _, status in ipairs({ '"running"', '"completed"', '"failed"', '"stopped"' }) do
            assert.is_truthy(src:find(status, 1, true), "reportStatus must be able to say " .. status)
        end
        local start = assert(src:find("function taskAttrs", 1, true), "taskAttrs must exist")
        local stop = assert(src:find("function wrapReminder", start, true), "wrapReminder follows taskAttrs")
        local body = src:sub(start, stop)
        for _, attr in ipairs({ 'id="', 'status="', 'exit_code="', 'signal="', 'duration_ms="', 'output="' }) do
            assert.is_truthy(body:find(attr, 1, true), "taskAttrs must emit " .. attr)
        end
    end)

    it("escapes the command, which is arbitrary shell text", function()
        local src = read_extension()
        assert.is_truthy(src:find("function escapeMarkup(", 1, true), "escapeMarkup must exist")
        for _, entity in ipairs({ "&amp;", "&lt;", "&gt;", "&quot;" }) do
            assert.is_truthy(src:find(entity, 1, true), "escapeMarkup must map to " .. entity)
        end
        assert.is_truthy(src:find("escapeMarkup(task.command)", 1, true), "the command must be escaped")
    end)

    it("keeps the banner as the first line, ahead of the reminder block", function()
        local src = read_extension()
        local wake_start = assert(src:find("function buildWakeNote", 1, true))
        local wake = src:sub(wake_start, assert(src:find("function buildBatchNote", wake_start, true)))
        local banner_at = assert(
            wake:find("[SYSTEM NOTIFICATION - NOT USER INPUT]", 1, true),
            "the banner literal must be in buildWakeNote itself"
        )
        local block_at = assert(wake:find("wrapReminder(", 1, true), "buildWakeNote must open the block")
        assert.is_true(banner_at < block_at, "the banner must precede the <system-reminder> block")
    end)

    it("confirms a fallback injection only after a turn completes", function()
        local src = read_extension()
        -- The injected text lives in a per-request deep copy that is never
        -- persisted, so being injected proves nothing: a request that fails
        -- takes the report with it. Confirming at injection time loses it.
        local ctx_start = assert(src:find('pi.on("context"', 1, true), "the context handler must exist")
        local ctx_end = src:find("\n\tpi.on(", ctx_start + 1, true) or #src
        local ctx_handler = src:sub(ctx_start, ctx_end)
        local inject_at =
            assert(ctx_handler:find("buildBatchNote(missing)", 1, true), "the handler must inject the missing reports")
        assert.is_truthy(ctx_handler:find('markSent(task, "fallback", text)', 1, true), "the injection is recorded")
        assert.is_nil(
            ctx_handler:sub(inject_at):find("markConfirmed(", 1, true),
            "the fallback must not confirm an injection: the request may still fail"
        )
        -- The one legitimate confirm left in the handler is the receipt: the
        -- exact text observed in the outgoing payload.
        local _, confirms = ctx_handler:gsub("markConfirmed%(", "")
        assert.are.equal(1, confirms, "only the observed-text receipt confirms")
        assert.is_true(
            assert(ctx_handler:find("texts.has(task.sentText)", 1, true)) < inject_at,
            "the receipt must be the observed-text branch, not the injector"
        )

        -- `turn_end` carries the outcome of the request the injection went into.
        local turn_start = assert(src:find('pi.on("turn_end"', 1, true), "turn_end must be registered")
        local turn_end = src:find("\n\tpi.on(", turn_start + 1, true) or #src
        local turn_handler = src:sub(turn_start, turn_end)
        local outcome_at = assert(
            turn_handler:find('event.outcome === "completed"', 1, true),
            "confirmation must be gated on a completed turn"
        )
        local confirm_at = assert(
            turn_handler:find("confirmFallbackReports()", 1, true),
            "the completed turn must confirm the fallback reports"
        )
        assert.is_true(outcome_at < confirm_at, "the outcome check must gate the confirmation")
        assert.is_truthy(turn_handler:find("deliverAtBoundary(event)", 1, true), "the boundary still delivers")

        -- The helper must be narrow: only a report the fallback carried.
        local fn_start = assert(src:find("function confirmFallbackReports", 1, true), "helper must exist")
        local fn_end = src:find("\n\tfunction ", fn_start + 1, true) or #src
        local body = src:sub(fn_start, fn_end)
        assert.is_truthy(body:find('task.delivery === "sent"', 1, true), "only an unconfirmed report qualifies")
        assert.is_truthy(body:find('task.sentVia === "fallback"', 1, true), "only a fallback delivery qualifies")
        assert.is_truthy(body:find("markConfirmed(task)", 1, true), "the helper confirms it")
    end)
end)
