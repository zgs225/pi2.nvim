-- Headless e2e: the two NOTIFY-ONLY timers of a background task.
--
-- `timeout` is the ATTACH window, not a deadline, so before this feature a
-- background task that never exited simply never told the agent anything: the
-- process kept running with nobody informed. Two timers now cover that hole,
-- and neither may ever kill anything:
--
--   * `deadline_ms` (background tasks only) — ONE `check_in="deadline"`
--     notification with an output tail, after which the process keeps running.
--   * an advisory lifetime note — ONE `check_in="lifetime"` message once the
--     task outlives `PI_BG_TASK_MAX_LIFETIME_MS`, saying it is NOT being killed.
--
-- This script checks both end-to-end, against the real stack: a `pi --mode rpc`
-- child with the bundled `extensions/bg-tasks.ts`, a scripted fake
-- OpenAI-compatible provider on 127.0.0.1 (no account, no network, no model),
-- and the session transcript (JSONL) as ground truth. The child is spawned with
-- `PI_BG_TASK_MAX_LIFETIME_MS=4000` so the lifetime cap is 4 s instead of a day,
-- which also proves the env var is read when the timer is armed.
--
-- Scripted turns:
--   T1  bash({ command = "sleep 3; echo dl-done", run_in_background = true,
--              deadline_ms = 800 })
--   ... every later turn is plain assistant text with `finish: "stop"`, so an
--   unexpected check-in wake is harmless.
--   D2  a NEW prompt issues bash({ command = "sleep 7; echo lt-done",
--       run_in_background = true }) with no deadline.
--
-- Assertions, all behavioural and all read off the transcript:
--   D1 exactly ONE `check_in="deadline"` message, `status="running"`, and it
--      appears strictly BEFORE the exit report; no `check_in="lifetime"` (the
--      task exits at ~3 s, inside the 4 s cap); the exit report exists exactly
--      once and reads `status="completed" exit_code="0"` — a kill would show a
--      signal, so this is the "nothing was killed" proof.
--   D2 exactly ONE `check_in="lifetime"` message, before the exit report, and
--      the exit report is `status="completed" exit_code="0"` exactly once.
--
-- Needs the pi binary, nothing else (the provider is fake), which is why it runs
-- in CI (.github/workflows/e2e.yml). Not part of `make test`:
--
--   make e2e-bg-deadline
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_deadline.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-deadline"

local PROVIDER = "e2edeadline"
local MODEL_ID = "e2e-model"
local LIFETIME_MS = 4000
local D1_COMMAND = "sleep 3; echo dl-done"
local D2_COMMAND = "sleep 7; echo lt-done"

io.stdout:setvbuf("no")
local run_started = uv.hrtime()
local last_step = run_started

---@return number elapsed seconds since the previous step marker
local function step(name)
    local t = uv.hrtime()
    print(string.format("[step] %-56s +%6.2fs (total %7.2fs)", name, (t - last_step) / 1e9, (t - run_started) / 1e9))
    last_step = t
end

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

-- ---------------------------------------------------------------------------
-- Scripted fake provider (OpenAI chat-completions, streamed).
-- ---------------------------------------------------------------------------

---@class DeadlineE2EProvider
---@field server? uv.uv_tcp_t
---@field turn integer requests answered so far
---@field bodies string[] request body per turn
---@field script (fun(): string)[] queued scripted answers

---@return string
local function sse_headers()
    return table.concat({
        "HTTP/1.1 200 OK",
        "Content-Type: text/event-stream",
        "Cache-Control: no-cache",
        "Connection: close",
        "",
        "",
    }, "\r\n")
end

---@param delta_json string
---@param finish? string
---@return string
local function sse_chunk(delta_json, finish)
    local fr = finish and ('"' .. finish .. '"') or "null"
    return ('data: {"id":"chatcmpl-e2e","object":"chat.completion.chunk","created":0,"model":"%s","choices":[{"index":0,"delta":%s,"finish_reason":%s}]}\n\n'):format(
        MODEL_ID,
        delta_json,
        fr
    )
end

--- Tool-call arguments are DOUBLE-encoded (a JSON string inside the JSON chunk).
---@param name string
---@param args table
---@param index? integer
---@return string
local function tool_call_chunk(name, args, index)
    local arguments = vim.json.encode(vim.json.encode(args))
    index = index or 0
    return sse_chunk(
        ('{"tool_calls":[{"index":%d,"id":"call_%s_%d","type":"function","function":{"name":"%s","arguments":%s}}]}'):format(
            index,
            tostring(uv.hrtime()),
            index,
            name,
            arguments
        )
    )
end

---@param text string
---@return string
local function text_response(text)
    return sse_headers()
        .. sse_chunk(vim.json.encode({ role = "assistant", content = text }))
        .. sse_chunk("{}", "stop")
        .. "data: [DONE]\n\n"
end

---@param args table
---@return string
local function bash_tool_response(args)
    return sse_headers()
        .. sse_chunk('{"role":"assistant","content":""}')
        .. tool_call_chunk("bash", args)
        .. sse_chunk("{}", "tool_calls")
        .. "data: [DONE]\n\n"
end

---@param provider DeadlineE2EProvider
---@return string
local function respond(provider)
    provider.turn = provider.turn + 1
    local scripted = table.remove(provider.script, 1)
    if scripted then
        return scripted(provider.bodies[provider.turn] or "")
    end
    -- Every later turn — a check-in wake, an exit-report wake, anything
    -- unexpected — is a plain answer that ends the run. Nothing can hang.
    return text_response("Nothing else to do.")
end

---@return DeadlineE2EProvider
local function start_fake_provider()
    ---@type DeadlineE2EProvider
    local provider = { turn = 0, bodies = {}, script = {} }
    local server = assert(uv.new_tcp())
    assert(server:bind("127.0.0.1", 0))
    provider.server = server
    assert(server:listen(16, function(err)
        if err then
            print("[provider] listen error: " .. tostring(err))
            return
        end
        local client = assert(uv.new_tcp())
        server:accept(client)
        local buffer = ""
        local answered = false
        client:read_start(function(read_err, chunk)
            if read_err or not chunk then
                pcall(client.close, client)
                return
            end
            buffer = buffer .. chunk
            local head_end = buffer:find("\r\n\r\n", 1, true)
            if not head_end then
                return
            end
            local head = buffer:sub(1, head_end - 1)
            local length = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
            local body = buffer:sub(head_end + 4)
            if #body < length or answered then
                return
            end
            answered = true
            local full_body = body
            -- `respond` must not block in a libuv callback: record the body and
            -- answer from the main loop.
            vim.schedule(function()
                provider.bodies[provider.turn + 1] = full_body
                local response = respond(provider)
                pcall(client.write, client, response, function()
                    pcall(client.close, client)
                end)
            end)
        end)
    end))
    return provider
end

--- Isolated agent dir: our own models.json + an empty settings.json.
---@param agent_dir string
---@param port integer
local function write_agent_dir(agent_dir, port)
    vim.fn.mkdir(agent_dir, "p")
    local models = {
        providers = {
            [PROVIDER] = {
                name = "E2EDeadline",
                baseUrl = ("http://127.0.0.1:%d/v1"):format(port),
                apiKey = "sk-e2e-test",
                api = "openai-completions",
                models = {
                    {
                        id = MODEL_ID,
                        name = "E2E Model",
                        contextWindow = 32000,
                        maxTokens = 1024,
                        cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 },
                    },
                },
            },
        },
    }
    local f = assert(io.open(agent_dir .. "/models.json", "w"))
    f:write(vim.json.encode(models))
    f:close()
    local s = assert(io.open(agent_dir .. "/settings.json", "w"))
    s:write("{}")
    s:close()
end

-- ---------------------------------------------------------------------------
-- RPC backend
-- ---------------------------------------------------------------------------

---@class DeadlineE2EBackend
---@field job integer
---@field session_dir string
---@field events table[] parsed stdout events (each tagged `_n` = 1-based index)
---@field stderr string

---@param session_dir string
---@param cwd string
---@return DeadlineE2EBackend
local function start_backend(session_dir, cwd)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type DeadlineE2EBackend
    local backend = { job = 0, session_dir = session_dir, events = {}, stderr = "" }
    local partial = { out = "" }
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
        "--session-dir",
        session_dir,
    }, {
        cwd = cwd,
        -- The advisory lifetime cap: 4 s instead of a day, so the note can be
        -- observed. Merged into the child's inherited environment.
        env = { PI_BG_TASK_MAX_LIFETIME_MS = tostring(LIFETIME_MS) },
        on_stdout = function(_, data)
            if not data then
                return
            end
            data[1] = partial.out .. (data[1] or "")
            partial.out = data[#data] or ""
            for index = 1, #data - 1 do
                local line = (data[index] or ""):gsub("\r$", "")
                if line ~= "" then
                    local ok, decoded = pcall(vim.json.decode, line)
                    if ok and type(decoded) == "table" then
                        decoded._n = #backend.events + 1
                        backend.events[#backend.events + 1] = decoded
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if not data then
                return
            end
            backend.stderr = backend.stderr .. table.concat(data, "")
        end,
        stdout_buffered = false,
        stderr_buffered = false,
    })
    check(backend.job > 0, "backend process started")
    return backend
end

---@param backend DeadlineE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend DeadlineE2EBackend
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

---@param backend DeadlineE2EBackend
local function stop_backend(backend)
    pcall(vim.fn.chanclose, backend.job, "stdin")
    pcall(vim.fn.jobstop, backend.job)
    pcall(vim.fn.jobwait, { backend.job }, 5000)
end

-- ---------------------------------------------------------------------------
-- Transcript (the JSONL is ground truth)
-- ---------------------------------------------------------------------------

--- Parsed session transcript: every line of every `*.jsonl` in the dir.
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

--- Every custom message of the extension, in transcript order.
---@param entries table[]
---@return table[] { index:integer, content:string, entry:table }
local function custom_messages(entries)
    local out = {}
    for index, entry in ipairs(entries) do
        if entry.type == "custom_message" and type(entry.content) == "string" then
            out[#out + 1] = { index = index, content = entry.content, entry = entry }
        end
    end
    return out
end

--- Custom messages whose text contains `needle` (plain find).
---@param entries table[]
---@param needle string
---@return table[]
local function messages_matching(entries, needle)
    local out = {}
    for _, message in ipairs(custom_messages(entries)) do
        if message.content:find(needle, 1, true) then
            out[#out + 1] = message
        end
    end
    return out
end

--- The messages carrying one task's *exit* report (never a check-in).
---@param entries table[]
---@param task_id string
---@return table[]
local function report_messages(entries, task_id)
    local out = {}
    for _, message in ipairs(messages_matching(entries, 'id="' .. task_id .. '"')) do
        if not message.content:find("check_in=", 1, true) then
            out[#out + 1] = message
        end
    end
    return out
end

---@param entries table[]
---@param kind string
---@return table[]
local function check_in_messages(entries, kind)
    return messages_matching(entries, 'check_in="' .. kind .. '"')
end

--- Poll the transcript until `pick` returns a non-empty list.
---@param backend DeadlineE2EBackend
---@param pick fun(entries: table[]): table[]
---@param timeout_ms integer
---@param what string
---@return table[]
local function wait_transcript(backend, pick, timeout_ms, what)
    local found = {}
    local ok = vim.wait(timeout_ms, function()
        found = pick(read_session(backend.session_dir))
        return #found > 0
    end, 100)
    if not ok then
        print(
            ("[debug] %s timed out; entries=%d; stderr=%s"):format(
                what,
                #read_session(backend.session_dir),
                backend.stderr
            )
        )
    end
    check(ok, what .. ": the transcript carries it", { stderr = backend.stderr })
    return found
end

--- Wait until the backend has settled and no new run started for `quiet_ms`.
---@param backend DeadlineE2EBackend
---@param quiet_ms integer
---@param timeout_ms integer
---@param what string
local function wait_quiet(backend, quiet_ms, timeout_ms, what)
    local deadline = uv.hrtime() + timeout_ms * 1e6
    while uv.hrtime() < deadline do
        local last_n = #backend.events
        local settle_n = nil
        for _, ev in ipairs(backend.events) do
            if ev.type == "agent_settled" then
                settle_n = ev._n
            end
        end
        if settle_n == nil then
            vim.wait(quiet_ms)
        else
            local restarted = vim.wait(quiet_ms, function()
                for _, ev in ipairs(backend.events) do
                    if ev.type == "agent_start" and ev._n > settle_n then
                        return true
                    end
                end
                return false
            end, 50)
            if not restarted then
                return
            end
            local next_settle = wait_event(backend, function(ev)
                return ev.type == "agent_settled" and ev._n > last_n
            end, 60000, what .. ": follow-up settle")
            check(next_settle ~= nil, what .. ": the follow-up run settles", { stderr = backend.stderr })
        end
    end
    check(false, what .. ": the backend settled and stayed quiet", { stderr = backend.stderr })
end

-- ---------------------------------------------------------------------------

local function main()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(RUN_ROOT, "p")
    local agent_dir = RUN_ROOT .. "/agent"

    -- The child pi inherits this env; nothing touches the user's real config.
    vim.env.PI_CODING_AGENT_DIR = agent_dir

    -- Hermetic: never inherit the developer's editor. pi.nvim publishes its
    -- idle-wake policy through PI_NVIM_BG_TASKS_FILE, and an unfocused editor (or
    -- `wake_on_completion = "never"`) HOLDS every idle completion instead of
    -- waking it — which is exactly what several of these assertions measure. CI
    -- has no such variable, so without this a suite can pass there and fail on a
    -- laptop.
    vim.env.PI_NVIM_BG_TASKS_FILE = nil
    vim.env.PI_OFFLINE = "1"

    -- These cases exercise the delivery ladder, not the cost gate: opt into a
    -- paid wake explicitly. The default policy is `never`, which would (rightly)
    -- hold the report for the next user prompt.
    local prefs_path = RUN_ROOT .. "/bg-tasks.json"
    local prefs = assert(io.open(prefs_path, "w"))
    prefs:write(vim.json.encode({ wake_on_completion = "always", present = true }))
    prefs:close()
    vim.env.PI_NVIM_BG_TASKS_FILE = prefs_path

    local provider = start_fake_provider()
    local addr = provider.server:getsockname()
    local port = type(addr) == "table" and addr.port or nil
    check(type(port) == "number" and port > 0, "fake provider did not bind a port", { addr = addr })
    write_agent_dir(agent_dir, port)
    step(("fake provider on 127.0.0.1:%d"):format(port))

    local backend = start_backend(RUN_ROOT .. "/sessions", RUN_ROOT .. "/cwd")

    send(backend, { id = "model-1", type = "set_model", provider = PROVIDER, modelId = MODEL_ID })
    local pinned = wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, "set_model")
    check(
        pinned ~= nil and pinned.success ~= false,
        "fake model selected",
        { pinned = pinned, stderr = backend.stderr }
    )
    step(("model pinned (lifetime cap %dms)"):format(LIFETIME_MS))

    -- ------------------------------------------------------------------
    -- D1: deadline_ms -> ONE check-in, no kill, normal exit report.
    -- ------------------------------------------------------------------
    provider.script = {
        function()
            return bash_tool_response({
                command = D1_COMMAND,
                run_in_background = true,
                deadline_ms = 800,
            })
        end,
    }
    send(backend, { id = "prompt-1", type = "prompt", message = "Start the deadline task." })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled"
    end, 60000, "D1 run settle")
    check(settled ~= nil, "D1 the run settles", { stderr = backend.stderr })
    step("D1 run settled")

    local deadlines = wait_transcript(backend, function(entries)
        return check_in_messages(entries, "deadline")
    end, 20000, "D1 deadline check-in")
    check(#deadlines == 1, "D1 exactly ONE deadline check-in", { count = #deadlines })
    local deadline = deadlines[1]
    print("[D1 check-in] " .. (deadline.content:gsub("\n", "\\n")))
    check(
        deadline.content:find("[SYSTEM NOTIFICATION - NOT USER INPUT]", 1, true) ~= nil,
        "D1 the check-in carries the banner",
        { content = deadline.content }
    )
    check(
        deadline.content:find("check-in, not a result", 1, true) ~= nil,
        "D1 the check-in says it is not a result",
        { content = deadline.content }
    )
    check(
        deadline.content:find('status="running"', 1, true) ~= nil,
        "D1 the task is still running",
        { content = deadline.content }
    )
    check(deadline.entry.details == nil, "D1 a check-in carries NO details (no panel row)", { entry = deadline.entry })
    local d1_id = deadline.content:match('id="(b%x+)"')
    check(type(d1_id) == "string", "D1 the check-in names a task id", { content = deadline.content })
    step("D1 one deadline check-in for " .. d1_id .. ", status=running")

    local d1_reports = wait_transcript(backend, function(entries)
        return report_messages(entries, d1_id)
    end, 20000, "D1 exit report")
    local d1_report = d1_reports[1]
    print("[D1 report] " .. (d1_report.content:gsub("\n", "\\n")))
    check(
        d1_report.index > deadline.index,
        "D1 the check-in appears strictly BEFORE the exit report",
        { check_in = deadline.index, report = d1_report.index }
    )
    check(
        d1_report.content:find('status="completed"', 1, true) ~= nil,
        "D1 the process exited on its own: status=completed",
        { content = d1_report.content }
    )
    check(
        d1_report.content:find('exit_code="0"', 1, true) ~= nil,
        "D1 exit_code=0 (a kill would show a signal)",
        { content = d1_report.content }
    )
    check(
        d1_report.content:find('signal=""', 1, true) ~= nil,
        "D1 no signal: the deadline did not kill anything",
        { content = d1_report.content }
    )
    step("D1 exit report completed/0, no signal, after the check-in")

    -- The exit report wakes a turn of its own; let it finish before asserting
    -- "exactly once" counts.
    wait_quiet(backend, 1500, 20000, "D1 quiesce")
    local after_d1 = read_session(backend.session_dir)
    check(#report_messages(after_d1, d1_id) == 1, "D1 the exit report exists exactly once", {
        count = #report_messages(after_d1, d1_id),
    })
    check(#check_in_messages(after_d1, "deadline") == 1, "D1 exactly one deadline check-in stays one", {
        count = #check_in_messages(after_d1, "deadline"),
    })
    check(
        #check_in_messages(after_d1, "lifetime") == 0,
        "D1 no lifetime note: the task exited inside the cap",
        { count = #check_in_messages(after_d1, "lifetime") }
    )
    step("D1 settled: one check-in, one report, no lifetime note")

    -- ------------------------------------------------------------------
    -- D2: no deadline_ms -> ONE advisory lifetime note at the 4 s cap,
    -- no kill, normal exit report.
    -- ------------------------------------------------------------------
    provider.script = {
        function()
            return bash_tool_response({ command = D2_COMMAND, run_in_background = true })
        end,
    }
    send(backend, { id = "prompt-2", type = "prompt", message = "Start the long task." })
    local d2_settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > settled._n
    end, 60000, "D2 run settle")
    check(d2_settled ~= nil, "D2 the run settles", { stderr = backend.stderr })
    step("D2 run settled")

    local lifetimes = wait_transcript(backend, function(entries)
        return check_in_messages(entries, "lifetime")
    end, 30000, "D2 lifetime note")
    check(#lifetimes == 1, "D2 exactly ONE lifetime note", { count = #lifetimes })
    local lifetime = lifetimes[1]
    print("[D2 note] " .. (lifetime.content:gsub("\n", "\\n")))
    check(
        lifetime.content:find("lifetime cap passed", 1, true) ~= nil,
        "D2 the note says the lifetime cap passed",
        { content = lifetime.content }
    )
    check(
        lifetime.content:find("NOT being killed", 1, true) ~= nil,
        "D2 the note says the process is not being killed",
        { content = lifetime.content }
    )
    check(
        lifetime.content:find("stop_task", 1, true) ~= nil,
        "D2 the note points at stop_task",
        { content = lifetime.content }
    )
    check(
        lifetime.content:find('status="running"', 1, true) ~= nil,
        "D2 the task is still running at the cap",
        { content = lifetime.content }
    )
    check(lifetime.entry.details == nil, "D2 a lifetime note carries NO details", { entry = lifetime.entry })
    local d2_id = lifetime.content:match('id="(b%x+)"')
    check(type(d2_id) == "string", "D2 the note names a task id", { content = lifetime.content })
    step("D2 one lifetime note for " .. d2_id .. ", status=running")

    local d2_reports = wait_transcript(backend, function(entries)
        return report_messages(entries, d2_id)
    end, 30000, "D2 exit report")
    local d2_report = d2_reports[1]
    print("[D2 report] " .. (d2_report.content:gsub("\n", "\\n")))
    check(
        d2_report.index > lifetime.index,
        "D2 the lifetime note appears BEFORE the exit report",
        { note = lifetime.index, report = d2_report.index }
    )
    check(
        d2_report.content:find('status="completed"', 1, true) ~= nil,
        "D2 the process exited on its own: status=completed",
        { content = d2_report.content }
    )
    check(
        d2_report.content:find('exit_code="0"', 1, true) ~= nil,
        "D2 exit_code=0 (the lifetime cap did not kill anything)",
        { content = d2_report.content }
    )
    check(
        d2_report.content:find("lt-done", 1, true) ~= nil,
        "D2 the task really ran to completion",
        { content = d2_report.content }
    )
    step("D2 exit report completed/0 after the lifetime note")

    wait_quiet(backend, 1500, 30000, "D2 quiesce")
    local after_d2 = read_session(backend.session_dir)
    check(#report_messages(after_d2, d2_id) == 1, "D2 the exit report exists exactly once", {
        count = #report_messages(after_d2, d2_id),
    })
    check(#check_in_messages(after_d2, "lifetime") == 1, "D2 exactly one lifetime note stays one", {
        count = #check_in_messages(after_d2, "lifetime"),
    })
    check(
        #check_in_messages(after_d2, "deadline") == 1,
        "D2 no extra deadline check-in (a task without deadline_ms gets none)",
        { count = #check_in_messages(after_d2, "deadline") }
    )
    step("D2 settled: one lifetime note, one report")

    stop_backend(backend)

    print(
        (
            "ALL bg-tasks deadline cases passed (deadline_ms sends ONE check-in before the exit report,\n"
            .. "the lifetime cap sends ONE advisory note, and neither killed the process) in %.2fs"
        ):format((uv.hrtime() - run_started) / 1e9)
    )
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e bg_tasks_deadline: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
