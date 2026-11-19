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
        assert.is_truthy(src:find("function escapeText(", 1, true), "escapeText must exist")
        assert.is_truthy(src:find("function escapeAttr(", 1, true), "escapeAttr must exist")
        -- One escaper for element text, one for attributes/prose: a single
        -- over-escaping helper is what made the output tail a hole.
        assert.is_nil(src:find("escapeMarkup", 1, true), "escapeMarkup must be gone, with no call sites")
        for _, entity in ipairs({ "&amp;", "&lt;", "&gt;", "&quot;" }) do
            assert.is_truthy(src:find(entity, 1, true), "the escapers must map to " .. entity)
        end
        -- `&` first, or `&lt;` would be escaped twice into `&amp;lt;`.
        local text_start = assert(src:find("function escapeText(", 1, true))
        local text_body = src:sub(text_start, assert(src:find("function escapeAttr(", text_start, true)))
        assert.is_true(
            assert(text_body:find('replace(/&/g, "&amp;")', 1, true))
                < assert(text_body:find('replace(/</g, "&lt;")', 1, true)),
            "`&` must be escaped before `<`"
        )
        assert.is_truthy(src:find("escapeAttr(task.command)", 1, true), "the quoted command must be escaped")
        assert.is_truthy(src:find("escapeAttr(task.outputFile)", 1, true), "an attribute value must be escaped")
    end)

    it("cannot let task output forge the report block", function()
        local src = read_extension()
        local wake_start = assert(src:find("function buildWakeNote", 1, true))
        local wake = src:sub(wake_start, assert(src:find("function buildBatchNote", wake_start, true)))
        -- The output tail is arbitrary program output: escaped as TEXT, it can
        -- no longer close </system-reminder> or forge a second element.
        assert.is_truthy(wake:find("escapeText(tail.text)", 1, true), "the tail must be escaped as text")
        assert.is_truthy(wake:find("escapeText(describeExit(task))", 1, true), "the exit summary must be escaped")
        assert.is_truthy(
            wake:find("Full output: ", 1, true),
            "a single-task report must still name the full output file"
        )
        assert.is_truthy(wake:find("wait_task ", 1, true), "and point at wait_task for the rest of it")

        local batch_start = assert(src:find("function buildBatchNote", 1, true))
        local batch = src:sub(batch_start, src:find("function messageText", batch_start, true) or #src)
        -- One element per task: a burst must not collapse into one element.
        assert.is_truthy(batch:find("batch.map(", 1, true), "the batch builds one element per task")
        assert.is_truthy(batch:find("<background-task ", 1, true), "each batch element is a task element")
        assert.is_truthy(batch:find("escapeText(task.command)", 1, true), "element text is escaped as text")
    end)

    it("reports an exit nobody watched as unknown, not as failed", function()
        local src = read_extension()
        local start = assert(src:find("function reportStatus(", 1, true))
        local stop = assert(src:find("function escapeText(", start, true))
        local body = src:sub(start, stop)
        assert.is_truthy(body:find('"unknown"', 1, true), "the union must allow an unknown status")
        local unknown_at = assert(body:find("task.exitUnknown", 1, true), "exitUnknown must be consulted")
        assert.is_true(
            unknown_at < assert(body:find("task.exitCode === 0", 1, true)),
            "the unknown branch must come before the exit-code tests"
        )
        assert.is_truthy(body:sub(unknown_at):find('return "unknown"', 1, true), "and return unknown")
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

    it("coalesces same-tick completions into ONE wake", function()
        local src = read_extension()
        assert.is_truthy(src:find("const WAKE_COALESCE_MS", 1, true), "the coalescing window must be a named constant")

        -- ONE scheduler, and the flush happens inside its timer (so N completions
        -- in one tick cost one sendMessage).
        local sched_start = assert(src:find("function scheduleWake", 1, true), "scheduleWake must exist")
        local sched_end = src:find("\n\tfunction ", sched_start + 1, true) or #src
        local sched = src:sub(sched_start, sched_end)
        local timer_at = assert(sched:find("setTimeout(", 1, true), "scheduleWake must arm a timer")
        assert.is_truthy(sched:find("WAKE_COALESCE_MS", 1, true), "the timer must use the coalescing window")
        assert.is_truthy(
            sched:sub(timer_at):find("flushPending({ wake: true })", 1, true),
            "the wake must be flushed from the timer, not at schedule time"
        )

        -- The idle branch schedules, it does not flush: that is the bug (two
        -- same-tick exits each sent their own wake).
        local finish_start = assert(src:find("function finishTask", 1, true), "finishTask must exist")
        local finish_end = src:find("\n\tfunction ", finish_start + 1, true) or #src
        local finish = src:sub(finish_start, finish_end)
        assert.is_truthy(finish:find("scheduleWake()", 1, true), "finishTask's idle branch must schedule the wake")
        assert.is_nil(
            finish:find("flushPending({ wake: true })", 1, true),
            "finishTask must not flush directly: two exits in one tick would send two wakes"
        )

        -- A queued wake must not outlive the process that scheduled it.
        local exit_start = assert(src:find('process.on("exit"', 1, true), "the exit hook must exist")
        local exit_end = src:find("function formatSeconds", exit_start, true) or #src
        local hook = src:sub(exit_start, exit_end)
        assert.is_truthy(hook:find("clearTimeout(wakeTimer)", 1, true), "the exit hook must clear the pending wake")
        assert.is_truthy(hook:find("wakeTimer = undefined", 1, true), "and forget it")
    end)

    it("never wakes into a run that became active inside the window", function()
        local src = read_extension()
        local sched_start = assert(src:find("function scheduleWake", 1, true), "scheduleWake must exist")
        local sched_end = src:find("\n\tfunction ", sched_start + 1, true) or #src
        local sched = src:sub(sched_start, sched_end)
        local callback_at = assert(sched:find("setTimeout(", 1, true), "scheduleWake must arm a timer")
        local body = sched:sub(callback_at)
        local flush_at =
            assert(body:find("flushPending({ wake: true })", 1, true), "the wake must still be flushed from the timer")
        -- `triggerTurn` on a run that is already going queues a FOLLOW-UP TURN, so
        -- the report would not arrive at this run's next boundary: with a run
        -- active the reports must stay `none` for `deliverAtBoundary` (turn_end /
        -- agent_before_settle) or the next `agent_settled` to carry them.
        local busy_at = assert(body:find("if (busy)", 1, true), "the timer must look at the run state")
        assert.is_true(busy_at < flush_at, "the busy check must gate the flush")
        assert.is_truthy(
            body:sub(busy_at, flush_at):find("return", 1, true),
            "a run that became active must skip the wake, not queue a turn"
        )
    end)

    it("drops a queued wake when its session goes away", function()
        local src = read_extension()
        local shut_start = assert(src:find('pi.on("session_shutdown"', 1, true), "the shutdown handler must exist")
        local shut_end = src:find("\n\tpi.on(", shut_start + 1, true) or #src
        local shutdown = src:sub(shut_start, shut_end)
        local clear_at =
            assert(shutdown:find("clearTimeout(wakeTimer)", 1, true), "session_shutdown must clear the pending wake")
        assert.is_truthy(shutdown:find("wakeTimer = undefined", 1, true), "and forget it")
        -- Before anything else: the successor (a `/new`, a resume, a fork) would
        -- otherwise deliver the replaced session's report.
        local tasks_at = assert(
            shutdown:find("for (const task of tasks.values())", 1, true),
            "the handler still walks the task table"
        )
        assert.is_true(clear_at < tasks_at, "the timer must be cleared before the handler does its work")
    end)

    it("escapes the id and the exit status instead of trusting the record", function()
        local src = read_extension()
        local attrs_start = assert(src:find("function taskAttrs", 1, true), "taskAttrs must exist")
        local attrs = src:sub(attrs_start, assert(src:find("function wrapReminder", attrs_start, true)))
        -- A record FOLDED from a doctored transcript carries an id this extension
        -- never generated (`b` + 6 hex): interpolated raw it could close the
        -- attribute or forge a second element.
        for _, shape in ipairs({ 'id="${escapeAttr(', 'exit_code="${escapeAttr(', 'signal="${escapeAttr(' }) do
            assert.is_truthy(attrs:find(shape, 1, true), "taskAttrs must emit " .. shape)
        end

        -- The prose line and the `wait_task` pointer interpolate the id as TEXT.
        local wake_start = assert(src:find("function buildWakeNote", 1, true))
        local wake = src:sub(wake_start, assert(src:find("function buildBatchNote", wake_start, true)))
        assert.is_truthy(wake:find("Background task ${id}", 1, true), "the prose id must be escaped text")
        assert.is_truthy(wake:find("wait_task ${id}", 1, true), "and so must the wait_task pointer")
        assert.is_nil(wake:find("${task.taskId}", 1, true), "no raw task id may reach a report")

        -- The check-in note has the same hole and the same fix.
        local note_start = assert(src:find("function buildCheckInNote", 1, true))
        local note = src:sub(note_start, assert(src:find("function messageText", note_start, true)))
        assert.is_truthy(note:find('id="${escapeAttr(', 1, true), "a check-in id must be escaped")
        assert.is_truthy(note:find("Background task ${id}", 1, true), "its prose id too")
        assert.is_nil(note:find("${task.taskId}", 1, true), "no raw task id may reach a check-in")
    end)

    it("bounds the re-arm so a failing provider cannot loop forever", function()
        local src = read_extension()
        assert.is_truthy(src:find("rearmCount?: number", 1, true), "the task must count its re-arms")
        local cap = src:match("const MAX_REARMS = (%d+)")
        assert.is_truthy(cap, "the cap must be a named constant")
        assert.is_true(tonumber(cap) > 0 and tonumber(cap) <= 5, "the cap must be a small, finite bound")

        local fn_start = assert(src:find("function rearmLostFallbacks", 1, true), "the helper must exist")
        local fn_end = src:find("\n\tfunction ", fn_start + 1, true) or #src
        local body = src:sub(fn_start, fn_end)
        local guard_at =
            assert(body:find("task.rearmCount ?? 0) >= MAX_REARMS", 1, true), "the cap must gate the re-arm")
        assert.is_true(
            guard_at < assert(body:find('task.delivery = "none"', 1, true)),
            "the cap must be checked before the report is re-armed"
        )
        assert.is_truthy(
            body:find("task.rearmCount = (task.rearmCount ?? 0) + 1", 1, true),
            "every re-arm must be counted"
        )
    end)

    --- Count plain occurrences of `needle` in `text`.
    ---@param text string
    ---@param needle string
    ---@return integer
    local function count_occurrences(text, needle)
        local n, at = 0, 1
        while true do
            local found = text:find(needle, at, true)
            if not found then
                return n
            end
            n = n + 1
            at = found + #needle
        end
    end

    it("offers a deadline_ms bash parameter bounded by named constants", function()
        local src = read_extension()
        local params_start = assert(src:find("const bgBashParameters", 1, true), "the bash schema must exist")
        local params_end = assert(src:find("type BgBashParams", params_start, true), "the static shape follows")
        local params = src:sub(params_start, params_end)
        assert.is_truthy(params:find("deadline_ms", 1, true), "deadline_ms must be a bash parameter")
        assert.is_truthy(params:find("run_in_background", 1, true), "next to run_in_background")
        -- The inferred Static<> shape has to carry it, or the model-facing type lies.
        assert.is_truthy(params:find("deadline_ms: Type.TOptional<Type.TNumber>", 1, true), "in the Static<> shape too")
        assert.is_truthy(params:find("minimum: MIN_DEADLINE_MS", 1, true), "the schema must use the named minimum")
        assert.is_truthy(params:find("maximum: MAX_DEADLINE_MS", 1, true), "and the named maximum")

        for _, name in ipairs({
            "MIN_DEADLINE_MS",
            "MAX_DEADLINE_MS",
            "DEFAULT_MAX_LIFETIME_MS",
            "LIFETIME_ENV",
            "CHECK_IN_TAIL_LINES",
        }) do
            assert.is_truthy(src:find("const " .. name, 1, true), name .. " must be a named constant")
        end
        assert.is_truthy(src:find('const LIFETIME_ENV = "PI_BG_TASK_MAX_LIFETIME_MS"', 1, true))
        assert.is_truthy(
            src:find("const DEFAULT_MAX_LIFETIME_MS = 24 * 60 * 60 * 1000", 1, true),
            "the default lifetime cap is 24 hours"
        )

        -- The env var is read LAZILY, when a timer is armed, not at module load:
        -- a child process's environment only exists at arm time.
        local cap_start = assert(src:find("function lifetimeCapMs", 1, true), "lifetimeCapMs must exist")
        local cap_end = src:find("\nfunction ", cap_start + 1, true) or #src
        local cap = src:sub(cap_start, cap_end)
        assert.is_truthy(cap:find("process.env[LIFETIME_ENV]", 1, true), "the cap comes from the environment")
        assert.is_truthy(cap:find("Number.isFinite(value) && value > 0", 1, true), "any positive finite number wins")
        assert.is_truthy(cap:find("return DEFAULT_MAX_LIFETIME_MS", 1, true), "otherwise the default")
    end)

    it("checks in with a notify-only message, never a kill", function()
        local src = read_extension()

        -- One shot per task, so a long-lived task cannot flood the context.
        assert.is_truthy(src:find("deadlineNoted", 1, true), "the deadline check-in must be one-shot")
        assert.is_truthy(src:find("lifetimeNoted", 1, true), "the lifetime note must be one-shot")

        -- The note builder: both kinds, same block style, no killing in it.
        local note_start = assert(src:find("function buildCheckInNote", 1, true), "buildCheckInNote must exist")
        local note_end = assert(src:find("function messageText", note_start, true), "messageText follows it")
        local note = src:sub(note_start, note_end)
        assert.is_truthy(note:find('check_in="deadline"', 1, true), "a deadline check-in says so")
        assert.is_truthy(note:find('check_in="lifetime"', 1, true), "a lifetime note says so")
        assert.is_truthy(note:find("[SYSTEM NOTIFICATION - NOT USER INPUT]", 1, true), "banner first")
        assert.is_truthy(note:find("check-in, not a result", 1, true), "a check-in must not read like a result")
        assert.is_truthy(note:find("wrapReminder(", 1, true), "the block goes through wrapReminder")
        assert.is_truthy(note:find("escapeAttr(task.command)", 1, true), "the command is escaped")
        assert.is_truthy(note:find("escapeText(tail.text)", 1, true), "the tail is escaped as text")
        assert.is_truthy(note:find("CHECK_IN_TAIL_BYTES, CHECK_IN_TAIL_LINES", 1, true), "the tail is bounded")
        for _, forbidden in ipairs({ "killProcessGroup", "SIGTERM", "SIGKILL", "finishTask" }) do
            assert.is_nil(note:find(forbidden, 1, true), "a check-in note must never call " .. forbidden)
        end

        -- The sender: display:false, NO details (a check-in is not a panel row),
        -- and outside the delivery ladder.
        local send_start = assert(src:find("function sendCheckIn", 1, true), "sendCheckIn must exist")
        -- Slice to the function's own closing brace: the next function starts with
        -- its doc comment, and that comment talks about `finishTask` by name.
        local send_end = assert(src:find("\n\t}\n", send_start, true), "sendCheckIn must be closed") + 3
        local sender = src:sub(send_start, send_end)
        assert.is_truthy(sender:find("display: false", 1, true), "the check-in is display:false")
        assert.is_nil(sender:find("details:", 1, true), "and carries NO details: no phantom panel row")
        assert.is_truthy(
            sender:find("busy ? undefined : { triggerTurn: true }", 1, true),
            "a wake only when the session is idle"
        )
        assert.is_truthy(sender:find("catch", 1, true), "a stale extension ctx must not throw into a timer")
        assert.is_nil(sender:find("markSent", 1, true), "a check-in is outside the delivery ladder")
        assert.is_nil(sender:find("markConfirmed", 1, true), "and must not touch a report's delivery state")
        assert.is_nil(sender:find("pendingReports", 1, true), "nor the report queue")
        for _, forbidden in ipairs({ "killProcessGroup", "SIGTERM", "SIGKILL", "finishTask" }) do
            assert.is_nil(sender:find(forbidden, 1, true), "the check-in path must never call " .. forbidden)
        end

        -- Both timers are unref'd and unarmed for an adopted task.
        local arm_start = assert(src:find("function armCheckIns", 1, true), "armCheckIns must exist")
        local arm_end = src:find("\n\t/**", arm_start + 1, true) or #src
        local arm = src:sub(arm_start, arm_end)
        assert.are.equal(2, count_occurrences(arm, ".unref?.()"), "both timers must be unref'd")
        assert.is_truthy(arm:find("task.adopted", 1, true), "an adopted task must never be armed")
    end)

    it("disarms both check-in timers when the task finishes", function()
        local src = read_extension()
        local finish_start = assert(src:find("function finishTask", 1, true), "finishTask must exist")
        local finish_end = src:find("\n\tfunction ", finish_start + 1, true) or #src
        local finish = src:sub(finish_start, finish_end)
        for _, timer in ipairs({ "task.deadlineTimer", "task.lifetimeTimer" }) do
            assert.is_truthy(finish:find("clearTimeout(" .. timer .. ")", 1, true), timer .. " must be cleared")
            assert.is_truthy(finish:find(timer .. " = undefined", 1, true), timer .. " must be forgotten")
        end
        assert.is_nil(finish:find("killProcessGroup", 1, true), "finishing a task must not kill anything")

        -- Armed exactly where a task BECOMES a background task: with the model's
        -- deadline on the run_in_background path, and without one where a
        -- foreground command detaches (there `timeout` was the attach window).
        assert.is_true(
            count_occurrences(src, "armCheckIns(task, clampDeadlineMs(") == 1,
            "the deadline arms on the run_in_background path"
        )
        assert.is_true(
            count_occurrences(src, "armCheckIns(task)") >= 2,
            "the lifetime note arms on the detach and the '&' paths"
        )
    end)
end)

-- A resumed session replays its transcript (`replay_messages`) instead of
-- receiving live events. The bg-tasks extension keeps the task table in the
-- transcript, so the frontend has to fold the same entries: without that fold
-- `pi.tasks` is empty and every replayed `wait_task` / `stop_task` /
-- `task_input` block falls back to a bare task id — precisely the shape a
-- resumed session sees, because the tasks in front of it have already exited.
describe("resumed session (history replay)", function()
    local Config = require("pi.config")
    local Rpc = require("pi.rpc")
    local Sessions = require("pi.sessions.manager")
    local SessionsList = require("pi.ui.sessions")

    local real = {} ---@type table<string, function>
    local tab = nil ---@type integer?
    local session ---@type pi.Session?
    --- What the stubbed get_messages serves (nil = the whole transcript). A
    --- second replay can serve a narrower window, the way a compaction rebuild
    --- does.
    local served = nil ---@type table[]?

    --- The transcript of a resumed run: a background task started, the model
    --- waiting on it, and — because this is a resume — the task already exited.
    --- Entry shapes are copied from a real `pi --mode rpc` get_messages
    --- snapshot (`role="custom"`, `customType="pi2_bg_task"`, details payload).
    ---@return table[]
    local function transcript()
        return {
            { role = "user", content = { { type = "text", text = "go" } }, timestamp = 1 },
            {
                role = "assistant",
                content = {
                    {
                        type = "toolCall",
                        toolCallId = "call_1",
                        toolName = "bash",
                        arguments = { command = "echo quick-done", run_in_background = true },
                    },
                },
                timestamp = 2,
            },
            {
                role = "toolResult",
                toolCallId = "call_1",
                toolName = "bash",
                content = { { type = "text", text = "Task b3f2a1 running in background (output: /tmp/x.log)" } },
                timestamp = 3,
            },
            {
                role = "custom",
                customType = "pi2_bg_task",
                content = "[Background task b3f2a1 started]",
                display = false,
                timestamp = 4,
                details = {
                    kind = "started",
                    taskId = "b3f2a1",
                    command = "echo quick-done",
                    pid = 424242,
                    startedAt = 4,
                    sessionId = "sess-1",
                },
            },
            {
                role = "assistant",
                content = {
                    {
                        type = "toolCall",
                        toolCallId = "call_2",
                        toolName = "wait_task",
                        arguments = { task_id = "b3f2a1", timeout_ms = 30000 },
                    },
                },
                timestamp = 5,
            },
            {
                role = "toolResult",
                toolCallId = "call_2",
                toolName = "wait_task",
                content = { { type = "text", text = "Task b3f2a1 exited with code 0 after 0.3s.\n\nquick-done" } },
                timestamp = 6,
            },
            {
                role = "custom",
                customType = "pi2_bg_task",
                content = "[Background task b3f2a1 completed]",
                display = false,
                timestamp = 7,
                details = { kind = "completed", taskId = "b3f2a1", command = "echo quick-done", exitCode = 0 },
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
            self._job_id = 999
            return true
        end
        Rpc.stop = function(self)
            self._job_id = nil
            self._pending = {}
        end
        Rpc.send = function(_, cmd, callback)
            if cmd.type == "get_messages" then
                local messages = served or transcript()
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
        served = nil
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

    it("names the command of a task that already exited in a previous process", function()
        assert.truthy(session, "session missing")
        Sessions.reload_messages(session)
        local h = session.chat._history
        local found = vim.wait(2000, function()
            return #rows_with(h:buf(), "echo quick-done · b3f2a1") == 1
        end, 20)
        assert.is_true(
            found,
            "the replayed wait_task block must lead with the command, not the bare id:\n" .. text_of(h:buf())
        )

        -- ...and the fold is the frontend's copy of the table, not a one-off
        -- label: a later live call (or `:PiTasks`) sees the same record.
        local task = Tasks.get("b3f2a1")
        assert.is_table(task)
        assert.are.equal("echo quick-done", task.command)
        assert.are.equal("completed", task.status)
    end)

    it("keeps a finished task finished when a replay window drops its terminal entry", function()
        assert.truthy(session, "session missing")
        Sessions.reload_messages(session)
        local h = session.chat._history
        assert.is_true(
            vim.wait(2000, function()
                return #rows_with(h:buf(), "echo quick-done · b3f2a1") == 1
            end, 20),
            text_of(h:buf())
        )
        assert.are.equal("completed", Tasks.get("b3f2a1").status)

        -- A compaction rebuild (or :PiTree) replays a narrower window that can
        -- hold the `started` entry without the terminal one. Folding that again
        -- must not resurrect the row as running.
        served = {}
        for _, m in ipairs(transcript()) do
            served[#served + 1] = m
            if m.role == "custom" and type(m.details) == "table" and m.details.kind == "started" then
                break
            end
        end
        Sessions.reload_messages(session)
        vim.wait(300)
        assert.are.equal("completed", Tasks.get("b3f2a1").status)
        assert.are.equal("echo quick-done", Tasks.get("b3f2a1").command)
    end)
end)
