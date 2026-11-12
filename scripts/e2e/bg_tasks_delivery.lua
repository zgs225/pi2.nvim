-- Headless e2e: background bash task COMPLETION DELIVERY into the agent context.
--
-- Unlike scripts/e2e/bg_tasks_notify.lua (which checks that the *frontend panel*
-- hears about an exit), this script verifies that the MODEL hears about it, on
-- every terminal path, exactly once. It drives a real `pi --mode rpc` with the
-- bundled `extensions/bg-tasks.ts` injected and reads the session transcript
-- (JSONL) as ground truth. No plugin UI, no Lua registry — the extension's
-- delivery semantics are the subject.
--
--   E1  idle wake       task exits while no run is active -> ONE report message,
--                       a turn starts on its own, an assistant message follows.
--   E2  turn boundary   task exits mid-run -> the report is appended as a
--                       `custom_message` entry at the next turn boundary and
--                       `continue: true` produces a follow-up assistant turn.
--   E3  aborted run     the run is aborted after the task exited -> the entry is
--                       still committed (no silent loss) and NO continuation is
--                       requested (the abort still ends the run).
--   E4  aggregation     two tasks exit in the same run -> ONE report entry
--                       naming both ids (not one message per task).
--
-- Delivery is confirmed through the `context` event (the exact message list
-- about to be sent), so a report that never lands is re-injected. The "exactly
-- one" assertions below are what proves the fallback never double-injects.
--
-- Needs the pi binary + a configured provider (E2-E4 need a long enough model
-- answer for the task to exit mid-run). NOT part of `make test`/CI:
--
--   make e2e-bg-delivery
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_delivery.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-delivery"

io.stdout:setvbuf("no")
local run_started = uv.hrtime()
local last_step = run_started

---@return number elapsed seconds since the previous step marker
local function step(name)
    local t = uv.hrtime()
    print(string.format("[step] %-56s +%6.2fs (total %7.2fs)", name, (t - last_step) / 1e9, (t - run_started) / 1e9))
    last_step = t
end

--- Assert with context: on failure the outer handler prints the message + ctx.
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

---@param path string
---@return string?
local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

---@param seconds number
local function sleep_s(seconds)
    vim.wait(math.floor(seconds * 1000), function()
        return false
    end, 50)
end

--- A live `pi --mode rpc` backend with a transcript dir of its own.
---@class BgE2EBackend
---@field job integer
---@field session_dir string
---@field events table[] parsed stdout events (each tagged `_n` = 1-based index)
---@field stderr string
---@field _partial string

---@param tag string
---@return BgE2EBackend
local function start_backend(tag)
    local session_dir = RUN_ROOT .. "/sessions-" .. tag
    vim.fn.mkdir(session_dir, "p")
    local cwd = RUN_ROOT .. "/cwd-" .. tag
    vim.fn.mkdir(cwd, "p")

    ---@type BgE2EBackend
    local backend = { job = 0, session_dir = session_dir, events = {}, stderr = "", _partial = "" }
    local partial = { out = backend._partial }

    local function handle(line)
        if line == "" then
            return
        end
        local ok, decoded = pcall(vim.json.decode, line)
        if not ok or type(decoded) ~= "table" then
            return
        end
        decoded._n = #backend.events + 1
        backend.events[#backend.events + 1] = decoded
    end

    backend.job = vim.fn.jobstart({
        "pi",
        "--mode",
        "rpc",
        "--no-extensions",
        "-e",
        EXTENSION,
        "--no-mcp",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--no-tools",
        "--session-dir",
        session_dir,
    }, {
        cwd = cwd,
        on_stdout = function(_, data)
            if not data then
                return
            end
            -- nvim hands over complete lines except the trailing chunk, which is
            -- a partial line carried into the next callback.
            data[1] = partial.out .. (data[1] or "")
            partial.out = data[#data] or ""
            for index = 1, #data - 1 do
                handle(((data[index] or ""):gsub("\r$", "")))
            end
        end,
        on_stderr = function(_, data)
            if not data then
                return
            end
            backend.stderr = backend.stderr .. table.concat(data, "")
            partial.err = backend.stderr
        end,
        stdout_buffered = false,
        stderr_buffered = false,
    })
    check(backend.job > 0, "backend process started", { tag = tag })
    return backend
end

---@param backend BgE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend BgE2EBackend
---@return integer
local function event_count(backend)
    return #backend.events
end

---@param backend BgE2EBackend
---@param predicate fun(ev: table): boolean
---@param timeout_ms integer
---@param what string
---@return table?
local function wait_event(backend, predicate, timeout_ms, what)
    local found = nil
    local settled = vim.wait(timeout_ms, function()
        for _, ev in ipairs(backend.events) do
            if predicate(ev) then
                found = ev
                return true
            end
        end
        return false
    end, 50)
    if settled and found then
        return found
    end
    local seen = {}
    for _, ev in ipairs(backend.events) do
        seen[#seen + 1] = string.format("%d:%s", ev._n, tostring(ev.type))
    end
    print(("[debug] %s timed out; events=%s; stderr=%s"):format(what, table.concat(seen, ","), backend.stderr))
    return nil
end

--- Wait for an `agent_settled` that arrives after event index `since`, so an
--- earlier phase's settle can neither be consumed nor missed.
---@param backend BgE2EBackend
---@param since integer
---@param what string
---@param timeout_ms? integer
local function wait_settled(backend, since, what, timeout_ms)
    local ev = wait_event(backend, function(e)
        return e.type == "agent_settled" and e._n > since
    end, timeout_ms or 180_000, what)
    check(ev ~= nil, "settled: " .. what, { since = since, stderr = backend.stderr })
end

---@param backend BgE2EBackend
---@param command string
local function start_task(backend, command)
    local since = event_count(backend)
    send(backend, { id = "bash-" .. tostring(since), type = "bash", command = command })
    local response = wait_event(backend, function(e)
        return e.type == "response" and e.command == "bash" and e._n > since
    end, 30_000, "bash response")
    check(response ~= nil and response.success ~= false, "bash command accepted", { response = response })
    return since
end

--- Start a long single-turn answer so a background task can exit mid-run.
---@param backend BgE2EBackend
---@return integer event index to pass to wait_settled
local function start_long_run(backend)
    local since = event_count(backend)
    send(backend, {
        id = "prompt-1",
        type = "prompt",
        message = "Count from 1 to 80 slowly, one number per line, no prose.",
    })
    local started = wait_event(backend, function(e)
        return e.type == "agent_start" and e._n > since
    end, 60_000, "agent_start")
    check(started ~= nil, "long run started", { stderr = backend.stderr })
    return since
end

---@param backend BgE2EBackend
local function stop_backend(backend)
    pcall(vim.fn.chanclose, backend.job, "stdin")
    pcall(vim.fn.jobstop, backend.job)
    pcall(vim.fn.jobwait, { backend.job }, 5000)
end

--- Parsed session transcript for one backend process.
---@param session_dir string
---@return table[]
local function read_session(session_dir)
    local names = vim.fn.readdir(session_dir)
    table.sort(names)
    local entries = {}
    for _, name in ipairs(names) do
        if name:match("%.jsonl$") then
            local content = read_file(session_dir .. "/" .. name) or ""
            for line in content:gmatch("[^\n]+") do
                local ok, decoded = pcall(vim.json.decode, line)
                if ok and type(decoded) == "table" then
                    entries[#entries + 1] = decoded
                end
            end
        end
    end
    return entries
end

--- Report messages the model actually received, in transcript order.
---@param entries table[]
---@return table[] { index:integer, content:string, details:table? }
local function report_entries(entries)
    local out = {}
    for index, entry in ipairs(entries) do
        if entry.type == "custom_message" and type(entry.content) == "string" then
            if entry.content:find("[SYSTEM NOTIFICATION", 1, true) then
                out[#out + 1] = { index = index, content = entry.content, details = entry.details }
            end
        end
    end
    return out
end

---@param entries table[]
---@return integer[]
local function assistant_indices(entries)
    local out = {}
    for index, entry in ipairs(entries) do
        if entry.type == "message" and type(entry.message) == "table" and entry.message.role == "assistant" then
            out[#out + 1] = index
        end
    end
    return out
end

---@param entries table[]
---@param start_index integer
---@return integer? first assistant entry after `start_index`
local function assistant_after(entries, start_index)
    for _, index in ipairs(assistant_indices(entries)) do
        if index > start_index then
            return index
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- E1: idle wake. `&` routes the command through the extension's user_bash hook,
-- so starting a task needs no model cooperation at all.
-- ---------------------------------------------------------------------------
local function case_e1()
    local backend = start_backend("e1")
    local since = start_task(backend, "& sleep 1; echo E1_IDLE")
    -- Nobody prompts: the completion itself must start the turn.
    local started = wait_event(backend, function(e)
        return e.type == "agent_start" and e._n > since
    end, 60_000, "idle-wake agent_start")
    check(started ~= nil, "E1 idle completion starts a turn on its own", { stderr = backend.stderr })
    step("E1 idle wake turn started")
    wait_settled(backend, since, "E1 wake turn")
    stop_backend(backend)

    local entries = read_session(backend.session_dir)
    local reports = report_entries(entries)
    check(#reports == 1, "E1 exactly one report message", { count = #reports, reports = reports })
    check(reports[1].content:find("E1_IDLE", 1, true) ~= nil, "E1 report carries the output tail", {
        content = reports[1].content,
    })
    check(assistant_after(entries, reports[1].index) ~= nil, "E1 the model answered after the report", {
        report = reports[1].index,
        assistants = assistant_indices(entries),
    })
    step("E1 transcript: one report, then the model's answer")
end

-- ---------------------------------------------------------------------------
-- E2: mid-run delivery at a turn boundary + continuation.
-- ---------------------------------------------------------------------------
local function case_e2()
    local backend = start_backend("e2")
    local since = start_long_run(backend)
    start_task(backend, "& sleep 1; echo E2_BUSY")
    -- Let the task exit while the answer is still streaming.
    sleep_s(3)
    wait_settled(backend, since, "E2 run")
    stop_backend(backend)

    local entries = read_session(backend.session_dir)
    local reports = report_entries(entries)
    check(#reports == 1, "E2 exactly one report message", { count = #reports })
    check(reports[1].content:find("E2_BUSY", 1, true) ~= nil, "E2 report carries the output tail", {
        content = reports[1].content,
    })
    local assistants = assistant_indices(entries)
    check(#assistants >= 2, "E2 continuation produced a follow-up assistant turn", { assistants = assistants })
    check(assistant_after(entries, reports[1].index) ~= nil, "E2 follow-up turn came after the report", {
        report = reports[1].index,
        assistants = assistants,
    })
    step("E2 transcript: report at the boundary, model continued after it")
end

-- ---------------------------------------------------------------------------
-- E3: aborted run keeps the report and does not continue.
-- ---------------------------------------------------------------------------
local function case_e3()
    local backend = start_backend("e3")
    local since = start_long_run(backend)
    start_task(backend, "& sleep 1; echo E3_ABORT")
    -- The task has exited, the run is still streaming: abort now, so the report
    -- can only reach the model through the aborted turn's boundary.
    sleep_s(2.5)
    send(backend, { id = "abort-1", type = "abort" })
    wait_settled(backend, since, "E3 aborted run")
    stop_backend(backend)

    local entries = read_session(backend.session_dir)
    local reports = report_entries(entries)
    check(#reports == 1, "E3 aborted run still committed exactly one report", {
        count = #reports,
        reports = reports,
        stderr = backend.stderr,
    })
    check(assistant_after(entries, reports[1].index) == nil, "E3 no wake turn for an aborted run", {
        report = reports[1].index,
        assistants = assistant_indices(entries),
    })
    step("E3 transcript: report committed, no continuation")
end

-- ---------------------------------------------------------------------------
-- E4: two tasks in the same run share ONE aggregated report.
-- ---------------------------------------------------------------------------
local function case_e4()
    local backend = start_backend("e4")
    local since = start_long_run(backend)
    start_task(backend, "& sleep 1; echo E4_A")
    start_task(backend, "& sleep 1; echo E4_B")
    sleep_s(3)
    wait_settled(backend, since, "E4 run")
    stop_backend(backend)

    local entries = read_session(backend.session_dir)
    local reports = report_entries(entries)
    check(#reports == 1, "E4 two tasks produced ONE report message", { count = #reports, reports = reports })
    check(reports[1].content:find("2 finished", 1, true) ~= nil, "E4 report is the batched form", {
        content = reports[1].content,
    })
    step("E4 transcript: one aggregated report for both tasks")
end

local function main()
    vim.fn.mkdir(RUN_ROOT, "p")
    print("extension: " .. EXTENSION)
    print("run root : " .. RUN_ROOT)
    check(read_file(EXTENSION) ~= nil, "bg-tasks extension exists at " .. EXTENSION)

    case_e1()
    case_e2()
    case_e3()
    case_e4()

    print("ALL bg-tasks delivery cases passed")
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e bg_tasks_delivery: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
