-- Headless e2e: pi 1.1.0 tool execution durationMs wire & rendering (#113).
--
-- Drives REAL processes end to end:
-- real `pi --mode rpc` processes, real LLM calls through cliproxyapi,
-- real tool executions (bash and read), real wire events (tool_execution_end with durationMs),
-- and real extmark rendering in the chat history buffer.
--
--   Scenario A (block tool + seconds):
--     spawn real session in temp cwd -> prompt bash sleep 2 && echo done ->
--     assert wire tool_execution_end durationMs >= 1500 ->
--     assert virt_text regex ^Took %d+%.%ds$ ("Took 2.0s") ->
--     assert agent_settled (non-aborted)
--
--   Scenario B (inline tool + milliseconds):
--     spawn new session in temp cwd with hello.txt -> prompt read hello.txt ->
--     assert wire tool_execution_end durationMs < 1000 ->
--     assert virt_text regex ^Took %d+ms$ ("Took Nms") ->
--     assert agent_settled (non-aborted)
--
-- How to run (from worktree root):
--   nvim --headless -u tests/minimal_init.lua -l scripts/e2e/pi110_duration.lua
--
-- Exit code:
--   0 = SUCCESS (PASS)
--   non-zero (1) = FAIL

local uv = vim.uv or vim.loop

local Config = require("pi.config")
local Draft = require("pi.draft")
local Manifest = require("pi.subsessions.manifest")
local PromptHistory = require("pi.prompt_history")
local Reaper = require("pi.subsessions.reaper")
local Sessions = require("pi.sessions.manager")

io.stdout:setvbuf("no")
local run_started = uv.hrtime()
local last_step = run_started

---@return number elapsed seconds since the previous step marker
local function step(name)
    local t = uv.hrtime()
    print(string.format("[step] %-58s +%6.2fs (total %7.2fs)", name, (t - last_step) / 1e9, (t - run_started) / 1e9))
    last_step = t
end

--- Assert with context: on failure prints FAIL + context via the outer handler.
---@param cond boolean
---@param msg string
---@param ctx? table
local function check(cond, msg, ctx)
    if cond then
        return
    end
    local detail = ""
    if ctx ~= nil then
        detail = " | ctx=" .. vim.inspect(ctx, { newline = " ", indent = "" })
    end
    error(msg .. detail, 0)
end

---@param path string?
---@return string?
local function read_file(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

--- OS pid behind an Rpc's nvim job (nil when the job is gone).
---@param rpc table?
---@return integer? pid
local function rpc_pid(rpc)
    local job = rpc and rpc._job_id
    if type(job) ~= "number" then
        return nil
    end
    local ok, pid = pcall(vim.fn.jobpid, job)
    if not ok or type(pid) ~= "number" or pid <= 1 then
        return nil
    end
    return pid
end

--- POSIX liveness probe independent of nvim's job table.
---@param pid integer?
---@return boolean
local function os_alive(pid)
    if type(pid) ~= "number" or pid <= 1 then
        return false
    end
    vim.fn.system({ "kill", "-0", tostring(pid) })
    return vim.v.shell_error == 0
end

---@param pid integer?
---@param timeout_ms integer
---@return boolean dead
local function wait_os_dead(pid, timeout_ms)
    if type(pid) ~= "number" or pid <= 1 then
        return true
    end
    return vim.wait(timeout_ms, function()
        return not os_alive(pid)
    end, 100)
end

--- Record session metadata for teardown tracking.
---@param report table { ids: string[], pids: integer[], path_set: table<string, boolean> }
---@param session table
---@return integer? pid
local function record_session(report, session)
    if not session then
        return nil
    end
    report.ids[#report.ids + 1] = session.id
    local pid = rpc_pid(session.rpc)
    if pid then
        report.pids[#report.pids + 1] = pid
    end
    if type(session.session_file) == "string" and session.session_file ~= "" then
        report.path_set[session.session_file] = true
    end
    return pid
end

--- Query get_state from session.rpc to capture the backend sessionFile path.
---@param session table
---@param report table
---@param timeout_ms integer?
local function poll_session_file(session, report, timeout_ms)
    if not session or not session.rpc or not session.rpc:is_running() then
        return
    end
    session.rpc:send({ type = "get_state" }, function(res)
        if res and res.data and type(res.data.sessionFile) == "string" and res.data.sessionFile ~= "" then
            session.session_file = res.data.sessionFile
            report.path_set[res.data.sessionFile] = true
        end
    end)
    vim.wait(timeout_ms or 2000, function()
        return type(session.session_file) == "string" and session.session_file ~= ""
    end, 50)
    if type(session.session_file) == "string" and session.session_file ~= "" then
        report.path_set[session.session_file] = true
    end
end

--- Extract all duration virt_text items from chat history buffer.
---@param chat table
---@return table[] list of { text: string, raw: string, hl: string? }
local function get_duration_chunks(chat)
    local results = {}
    if not chat or not chat._history then
        return results
    end
    local h = chat._history
    local buf = h:buf()
    local ns = h:ns()
    if not vim.api.nvim_buf_is_valid(buf) then
        return results
    end
    local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    for _, em in ipairs(extmarks) do
        local details = em[4] or {}
        local vt = details.virt_text
        if vt then
            for _, chunk in ipairs(vt) do
                local text = chunk[1]
                local hl = chunk[2]
                if type(text) == "string" and text:find("Took", 1, true) then
                    table.insert(results, {
                        text = vim.trim(text),
                        raw = text,
                        hl = hl,
                    })
                end
            end
        end
    end
    return results
end

--- Check if an error message represents a rate limit or capacity exhaustion.
---@param err any
---@return boolean
local function is_rate_limit(err)
    local s = tostring(err):lower()
    return s:find("429") ~= nil
        or s:find("capacity") ~= nil
        or s:find("rate limit") ~= nil
        or s:find("overloaded") ~= nil
end

--- Check captured wire errors for rate limiting.
---@param errors table[]
local function check_wire_error(errors)
    for _, e in ipairs(errors) do
        local s = vim.inspect(e):lower()
        if s:find("429") or s:find("capacity") or s:find("rate limit") or s:find("overloaded") then
            error("rate limit error on wire: " .. vim.inspect(e), 0)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Global setup & snapshotting
-- ---------------------------------------------------------------------------

local report = { ids = {}, pids = {}, path_set = {} }
local temp_dirs = {}
local active_listeners = {}

local orig_cwd = vim.fn.getcwd()
local config_snapshot = vim.deepcopy(Config.options)
local manifest_path = Manifest.path()
local manifest_snapshot = read_file(manifest_path)

local draft_temp = vim.fn.tempname() .. "-e2e-duration-draft.txt"
local history_temp = vim.fn.tempname() .. "-e2e-duration-history.json"
pcall(function()
    Draft._set_path(draft_temp)
    PromptHistory._set_base_dir(vim.fn.tempname())
    Config.options.prompt.history.path = history_temp
end)

-- Hook Sessions.handle_event to intercept raw wire events before processing
local orig_handle_event = Sessions.handle_event
Sessions.handle_event = function(session, msg)
    if type(msg) == "table" then
        for _, l in ipairs(active_listeners) do
            pcall(l, session, msg)
        end
    end
    return orig_handle_event(session, msg)
end

-- ---------------------------------------------------------------------------
-- Always-run teardown
-- ---------------------------------------------------------------------------

local function cleanup()
    local notes = {}

    -- 1. Restore Sessions.handle_event hook
    Sessions.handle_event = orig_handle_event
    active_listeners = {}

    -- 2. Close each registered session cleanly
    local closed = {}
    for _, id in ipairs(report.ids) do
        if not closed[id] then
            closed[id] = true
            local sess = Sessions.get_by_id(id)
            if sess then
                pcall(Sessions.close_session, sess)
            end
        end
    end
    pcall(Sessions._reset)

    -- 3. Verify and enforce OS-level process death
    local seen_pid = {}
    for _, pid in ipairs(report.pids) do
        if not seen_pid[pid] then
            seen_pid[pid] = true
            wait_os_dead(pid, 5000)
            if os_alive(pid) then
                pcall(uv.kill, pid, 9)
                wait_os_dead(pid, 5000)
            end
            if os_alive(pid) then
                notes[#notes + 1] = string.format("pid %d still alive after SIGKILL", pid)
            else
                notes[#notes + 1] = string.format("pid %d stopped and verified dead", pid)
            end
        end
    end

    -- 4. Delete only exact recorded session files (G18)
    local removed_files = 0
    local seen_path = {}
    for p in pairs(report.path_set) do
        if type(p) == "string" and p ~= "" and not seen_path[p] then
            seen_path[p] = true
            if vim.fn.filereadable(p) == 1 and os.remove(p) then
                removed_files = removed_files + 1
            end
            -- Also remove empty session dir under ~/.pi/agent/sessions/ if created for this test run
            local parent_dir = vim.fn.fnamemodify(p, ":h")
            if parent_dir:find("%-pi%-e2e%-dur%-") then
                local meta_file = parent_dir .. "/.pi2-subsessions.json"
                if vim.fn.filereadable(meta_file) == 1 then
                    pcall(os.remove, meta_file)
                end
                pcall(os.remove, parent_dir)
            end
        end
    end
    notes[#notes + 1] = string.format("%d session file(s) removed", removed_files)

    -- 5. Restore original working directory and clean up temp cwd trees
    pcall(vim.fn.chdir, orig_cwd)
    for _, dir in ipairs(temp_dirs) do
        if vim.fn.isdirectory(dir) == 1 then
            vim.fn.delete(dir, "rf")
        end
    end
    notes[#notes + 1] = string.format("%d temporary directory(ies) removed", #temp_dirs)

    -- 6. Restore manifest snapshot (G17)
    if type(manifest_snapshot) == "string" then
        local dir = vim.fn.fnamemodify(manifest_path, ":h")
        if vim.fn.isdirectory(dir) == 0 then
            vim.fn.mkdir(dir, "p")
        end
        local f = io.open(manifest_path, "w")
        if f then
            f:write(manifest_snapshot)
            f:close()
            notes[#notes + 1] = "manifest restored to pre-run snapshot"
        else
            notes[#notes + 1] = "FAILED to restore manifest snapshot"
        end
    elseif vim.fn.filereadable(manifest_path) == 1 then
        if os.remove(manifest_path) then
            notes[#notes + 1] = "manifest created by the run removed"
        end
    end

    -- 7. Remove temp draft and prompt history files (G17)
    if vim.fn.filereadable(draft_temp) == 1 then
        os.remove(draft_temp)
    end
    if vim.fn.filereadable(history_temp) == 1 then
        os.remove(history_temp)
    end

    -- 8. Reset module singletons
    pcall(Reaper._reset)
    pcall(Manifest._reset)

    -- 9. Restore Config options
    Config.options = vim.deepcopy(config_snapshot)

    return notes
end

-- ---------------------------------------------------------------------------
-- Scenario implementations
-- ---------------------------------------------------------------------------

--- Scenario A: block tool (bash) with seconds-level execution time.
local function run_scenario_a()
    step("Scenario A: setup isolated cwd")
    local tmp = vim.fn.tempname() .. "-pi-e2e-dur-a"
    vim.fn.mkdir(tmp, "p")
    table.insert(temp_dirs, tmp)
    vim.fn.chdir(tmp)

    step("Scenario A: spawn session")
    require("pi").show({ layout = "side" })
    local session = Sessions.get()
    check(session ~= nil, "Scenario A: session not created")
    local pid = record_session(report, session)
    check(pid ~= nil, "Scenario A: could not determine RPC process pid")
    check(session.rpc:is_running() == true, "Scenario A: RPC process not running")
    poll_session_file(session, report, 3000)

    local tool_ends = {}
    local settled = {}
    local all_errors = {}
    local listener = function(s, msg)
        if s.id == session.id then
            if msg.type == "tool_execution_end" then
                table.insert(tool_ends, vim.deepcopy(msg))
            elseif msg.type == "agent_settled" then
                table.insert(settled, vim.deepcopy(msg))
            elseif msg.type == "response" and msg.success == false then
                table.insert(all_errors, vim.deepcopy(msg))
            elseif msg.type == "error" then
                table.insert(all_errors, vim.deepcopy(msg))
            end
        end
    end
    table.insert(active_listeners, listener)

    step("Scenario A: submit bash sleep 2 prompt")
    local prompt =
        "Use the bash tool to run exactly this command: sleep 2 && echo done. After the tool result, reply with exactly: FIN"
    session.chat._prompt:set_text(prompt)
    session.chat:submit()

    step("Scenario A: wait for tool_execution_end (budget 90s)")
    local got_tool = vim.wait(90000, function()
        check_wire_error(all_errors)
        return #tool_ends > 0
    end, 100)
    check(got_tool and #tool_ends > 0, "Scenario A: tool_execution_end not received within 90s", {
        tool_ends = tool_ends,
        errors = all_errors,
    })

    local end_msg = tool_ends[1]
    step(
        string.format(
            "Scenario A: received tool_execution_end (tool=%s durationMs=%s)",
            tostring(end_msg.toolName),
            tostring(end_msg.durationMs)
        )
    )

    -- Wire assertion 1: durationMs is a number and >= 1500
    check(type(end_msg.durationMs) == "number", "Scenario A wire: durationMs must be a number", { msg = end_msg })
    check(
        end_msg.durationMs >= 1500,
        string.format("Scenario A wire: durationMs %d < 1500ms (expected >= 1500ms)", end_msg.durationMs),
        { msg = end_msg }
    )
    print(
        string.format(
            "[wire] Scenario A: toolName=%s durationMs=%d (>= 1500ms PASS)",
            tostring(end_msg.toolName),
            end_msg.durationMs
        )
    )

    -- Render assertion 2: extmark virt_text matches ^Took %d+%.%ds$
    step("Scenario A: check extmark virt_text rendering")
    local matched_chunk = nil
    local got_render = vim.wait(10000, function()
        local chunks = get_duration_chunks(session.chat)
        for _, c in ipairs(chunks) do
            if c.text:match("^Took %d+%.%ds$") then
                matched_chunk = c
                return true
            end
        end
        return false
    end, 100)
    check(
        got_render and matched_chunk ~= nil,
        "Scenario A render: extmark virt_text matching '^Took %d+%.%ds$' not found",
        {
            chunks = get_duration_chunks(session.chat),
            durationMs = end_msg.durationMs,
        }
    )
    check(
        matched_chunk.hl == "PiToolStatus",
        "Scenario A render: highlight group must be PiToolStatus",
        { chunk = matched_chunk }
    )
    print(
        string.format(
            "[render] Scenario A: virt_text '%s' hl=%s (format Took <x.x>s PASS)",
            matched_chunk.text,
            matched_chunk.hl
        )
    )

    -- Settle assertion 3: agent_settled received, non-aborted
    step("Scenario A: wait for agent settle (budget 60s)")
    local got_settle = vim.wait(60000, function()
        check_wire_error(all_errors)
        return #settled > 0 and session.chat:is_streaming() ~= true
    end, 100)
    check(got_settle and #settled > 0, "Scenario A: agent_settled not received within 60s", { settled = settled })
    check(settled[1].aborted ~= true, "Scenario A: agent settled with aborted=true", { msg = settled[1] })
    print("[settle] Scenario A: agent_settled received, non-aborted (PASS)")

    poll_session_file(session, report, 3000)
    step("Scenario A: PASS")
    return {
        durationMs = end_msg.durationMs,
        virt_text = matched_chunk.text,
    }
end

--- Scenario B: inline/fast tool (read) with millisecond-level execution time.
local function run_scenario_b()
    step("Scenario B: setup isolated cwd with hello.txt")
    local tmp = vim.fn.tempname() .. "-pi-e2e-dur-b"
    vim.fn.mkdir(tmp, "p")
    table.insert(temp_dirs, tmp)
    local f = io.open(tmp .. "/hello.txt", "w")
    check(f ~= nil, "Scenario B: failed to create hello.txt")
    f:write("Hello from e2e duration test\n")
    f:close()
    vim.fn.chdir(tmp)

    step("Scenario B: spawn new session in fresh tab")
    vim.cmd("tabnew")
    require("pi").show({ layout = "side" })
    local session = Sessions.get()
    check(session ~= nil, "Scenario B: session not created")
    local pid = record_session(report, session)
    check(pid ~= nil, "Scenario B: could not determine RPC process pid")
    check(session.rpc:is_running() == true, "Scenario B: RPC process not running")
    poll_session_file(session, report, 3000)

    local tool_ends = {}
    local settled = {}
    local all_errors = {}
    local listener = function(s, msg)
        if s.id == session.id then
            if msg.type == "tool_execution_end" then
                table.insert(tool_ends, vim.deepcopy(msg))
            elseif msg.type == "agent_settled" then
                table.insert(settled, vim.deepcopy(msg))
            elseif msg.type == "response" and msg.success == false then
                table.insert(all_errors, vim.deepcopy(msg))
            elseif msg.type == "error" then
                table.insert(all_errors, vim.deepcopy(msg))
            end
        end
    end
    table.insert(active_listeners, listener)

    step("Scenario B: submit read hello.txt prompt")
    local prompt = "Use the read tool to read hello.txt. After reading it, reply with exactly: FIN"
    session.chat._prompt:set_text(prompt)
    session.chat:submit()

    step("Scenario B: wait for tool_execution_end (budget 90s)")
    local got_tool = vim.wait(90000, function()
        check_wire_error(all_errors)
        return #tool_ends > 0
    end, 100)
    check(got_tool and #tool_ends > 0, "Scenario B: tool_execution_end not received within 90s", {
        tool_ends = tool_ends,
        errors = all_errors,
    })

    local end_msg = tool_ends[1]
    step(
        string.format(
            "Scenario B: received tool_execution_end (tool=%s durationMs=%s)",
            tostring(end_msg.toolName),
            tostring(end_msg.durationMs)
        )
    )

    -- Wire assertion 1: durationMs is a number and < 1000
    check(type(end_msg.durationMs) == "number", "Scenario B wire: durationMs must be a number", { msg = end_msg })
    check(
        end_msg.durationMs < 1000,
        string.format("Scenario B wire: durationMs %d >= 1000ms (expected < 1000ms for read)", end_msg.durationMs),
        { msg = end_msg }
    )
    print(
        string.format(
            "[wire] Scenario B: toolName=%s durationMs=%d (< 1000ms PASS)",
            tostring(end_msg.toolName),
            end_msg.durationMs
        )
    )

    -- Render assertion 2: extmark virt_text matches ^Took %d+ms$
    step("Scenario B: check extmark virt_text rendering")
    local matched_chunk = nil
    local got_render = vim.wait(10000, function()
        local chunks = get_duration_chunks(session.chat)
        for _, c in ipairs(chunks) do
            if c.text:match("^Took %d+ms$") then
                matched_chunk = c
                return true
            end
        end
        return false
    end, 100)
    check(
        got_render and matched_chunk ~= nil,
        "Scenario B render: extmark virt_text matching '^Took %d+ms$' not found",
        {
            chunks = get_duration_chunks(session.chat),
            durationMs = end_msg.durationMs,
        }
    )
    check(
        matched_chunk.hl == "PiToolStatus",
        "Scenario B render: highlight group must be PiToolStatus",
        { chunk = matched_chunk }
    )
    print(
        string.format(
            "[render] Scenario B: virt_text '%s' hl=%s (format Took <N>ms PASS)",
            matched_chunk.text,
            matched_chunk.hl
        )
    )

    -- Settle assertion 3: agent_settled received, non-aborted
    step("Scenario B: wait for agent settle (budget 60s)")
    local got_settle = vim.wait(60000, function()
        check_wire_error(all_errors)
        return #settled > 0 and session.chat:is_streaming() ~= true
    end, 100)
    check(got_settle and #settled > 0, "Scenario B: agent_settled not received within 60s", { settled = settled })
    check(settled[1].aborted ~= true, "Scenario B: agent settled with aborted=true", { msg = settled[1] })
    print("[settle] Scenario B: agent_settled received, non-aborted (PASS)")

    poll_session_file(session, report, 3000)
    step("Scenario B: PASS")
    return {
        durationMs = end_msg.durationMs,
        virt_text = matched_chunk.text,
    }
end

--- Execute a scenario with retry and exponential backoff on 429/capacity.
---@param name string
---@param max_retries integer
---@param fn fun(): table
---@return table
local function run_with_retry(name, max_retries, fn)
    local last_err = nil
    for attempt = 1, max_retries do
        local ok, res = pcall(fn)
        if ok then
            return res
        end
        last_err = res
        if is_rate_limit(res) and attempt < max_retries then
            local delay = 2 ^ attempt
            print(
                string.format(
                    "[retry] %s encountered rate limit on attempt %d/%d, sleeping %ds before retry: %s",
                    name,
                    attempt,
                    max_retries,
                    delay,
                    tostring(res)
                )
            )
            vim.wait(delay * 1000, function()
                return false
            end, 200)
        else
            error(res, 0)
        end
    end
    error(last_err, 0)
end

-- ---------------------------------------------------------------------------
-- Main execution
-- ---------------------------------------------------------------------------

local summary = {}

local suite_ok, suite_err = xpcall(function()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")

    require("pi").setup({
        title = { lang = "en" },
        render = { engine = "builtin" },
    })
    step("setup complete (pi.setup with builtin rendering)")

    local res_a = run_with_retry("Scenario A", 3, run_scenario_a)
    summary.A = res_a

    local res_b = run_with_retry("Scenario B", 3, run_scenario_b)
    summary.B = res_b
end, debug.traceback)

-- Execute teardown in all circumstances
local notes = cleanup()
local total_s = (uv.hrtime() - run_started) / 1e9

for _, n in ipairs(notes) do
    print("[cleanup] " .. n)
end

print(string.rep("-", 70))
if not suite_ok then
    print(string.format("FAIL: e2e test failed after %.2fs:\n%s", total_s, tostring(suite_err)))
    io.stdout:flush()
    os.exit(1)
end

print(
    string.format(
        "PASS: tool execution duration e2e verified in %.2fs\n"
            .. "  Scenario A (block/bash): wire durationMs = %d ms | render = '%s'\n"
            .. "  Scenario B (inline/read): wire durationMs = %d ms | render = '%s'",
        total_s,
        summary.A.durationMs,
        summary.A.virt_text,
        summary.B.durationMs,
        summary.B.virt_text
    )
)
io.stdout:flush()
os.exit(0)
