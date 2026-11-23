-- Headless e2e: the log sweep at session start — stale, unknown `pi-bash-*.log`
-- files go, and nothing else does.
--
-- Every background task writes `tmpdir()/pi-bash-<taskId>.log` and nothing used
-- to delete it. The sweep runs ONCE per process, on `session_start`, and may
-- only touch names matching `pi-bash-b<6 hex digits>.log` whose taskId this
-- process does not know AND whose mtime is older than the TTL. The interesting
-- part is therefore the boundary: the stale unknown one goes, the fresh unknown
-- one stays, a same-prefix non-hex id stays, a foreign file stays, and a task
-- this process started keeps its log both while it runs and after it exits.
--
-- One `pi --mode rpc` child with the bundled `extensions/bg-tasks.ts` and a
-- scripted fake provider, driving REAL shells:
--
--   (setup) TMPDIR=<RUN_ROOT>/tmp, PI_BG_TASK_LOG_TTL_MS=60000, and four files
--           in it: pi-bash-b111111.log (mtime 2 days ago), pi-bash-b222222.log
--           (mtime now), pi-bash-zzzzzz.log and not-ours.log (names that are
--           not ours). TMPDIR is isolated because `tmpdir()` follows it: a script
--           that swept the developer's real /tmp would delete other sessions'
--           logs.
--   L1  start pi -> the stale log is gone, the other three are still there
--   L2  bash(run_in_background, "sleep 4; echo reaper-done") -> that task's log
--       exists (the process knows it, so age/name rules never apply)
--   L3  the task exits -> its log is STILL there (TTL has not passed, and
--       `list_tasks` may still point at it)
--
-- Assertions, read off the session transcript (ground truth) plus the real
-- directory listing:
--   L1.1 pi-bash-b111111.log was removed
--   L1.2 pi-bash-b222222.log (fresh, unknown) survived — the sweep is about age
--   L1.3 pi-bash-zzzzzz.log and not-ours.log survived — the sweep is about names
--   L2.1 the task's log file exists and lives in the isolated TMPDIR
--   L2.2 it exists while the task is still RUNNING (the exit report is not there
--        yet), i.e. a live task's log is never a sweep candidate
--   L3.1 after the exit report the log still exists
--   L3.2 it still carries the line the shell printed before it exited
--
-- Needs the pi binary, nothing else (the provider is fake), which is why it runs
-- in CI (.github/workflows/e2e.yml). Not part of `make test`:
--
--   make e2e-bg-logs
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_logs.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-logs"
--- The child's `tmpdir()`: the ONLY directory this run may create or delete logs in.
local TMP_DIR = RUN_ROOT .. "/tmp"

local PROVIDER = "e2elogs"
local MODEL_ID = "e2e-model"
-- 60 s: short enough that "mtime two days ago" is unambiguously stale and "now"
-- unambiguously fresh, long enough that the live task below cannot age out.
local LOG_TTL_MS = 60000
local TASK_COMMAND = "sleep 4; echo reaper-done"

-- The four files planted before pi starts. Only the first may disappear.
local STALE_LOG = "pi-bash-b111111.log" -- stale + unknown -> swept
local FRESH_LOG = "pi-bash-b222222.log" -- unknown but fresh -> kept
local NON_HEX_LOG = "pi-bash-zzzzzz.log" -- looks like ours, taskId is not hex -> kept
local FOREIGN_LOG = "not-ours.log" -- another tool's spill file -> kept

local STALE_AGE_S = 2 * 24 * 60 * 60

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

---@param path string
---@param content string
local function write_file(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

---@param path string
---@return boolean
local function path_exists(path)
    return uv.fs_stat(path) ~= nil
end

--- The directory as `name@mtime`, so a failure shows WHAT the sweep saw.
---@param dir string
---@return string[]
local function dir_listing(dir)
    local names = vim.fn.readdir(dir)
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do
        local stats = uv.fs_stat(dir .. "/" .. name)
        out[#out + 1] = ("%s@%d"):format(name, stats and stats.mtime.sec or -1)
    end
    return out
end

---@param path string
---@param want_present boolean
---@param timeout_ms integer
---@param what string
local function wait_path(path, want_present, timeout_ms, what)
    local ok = vim.wait(timeout_ms, function()
        return path_exists(path) == want_present
    end, 50)
    check(ok, what, { path = path, listing = dir_listing(TMP_DIR) })
end

---@param path string
---@param needle string
---@param timeout_ms integer
---@param what string
local function wait_file_contains(path, needle, timeout_ms, what)
    local ok = vim.wait(timeout_ms, function()
        local content = read_file(path)
        return content ~= nil and content:find(needle, 1, true) ~= nil
    end, 50)
    check(ok, what, { path = path, content = read_file(path), listing = dir_listing(TMP_DIR) })
end

-- ---------------------------------------------------------------------------
-- Scripted fake provider (OpenAI chat-completions, streamed).
-- ---------------------------------------------------------------------------

---@class LogsE2EProvider
---@field server? uv.uv_tcp_t
---@field turn integer requests answered so far
---@field bodies string[] request body per turn
---@field script (fun(body: string): string)[] queued scripted answers
---@field task_id string? id of the background task started in L2
---@field missing_id boolean?

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
---@return string
local function tool_call_chunk(name, args)
    local arguments = vim.json.encode(vim.json.encode(args))
    return sse_chunk(
        ('{"tool_calls":[{"index":0,"id":"call_%s","type":"function","function":{"name":"%s","arguments":%s}}]}'):format(
            tostring(uv.hrtime()),
            name,
            arguments
        )
    )
end

---@param text string
---@return string
local function text_response(text)
    return sse_headers()
        .. sse_chunk(('{"role":"assistant","content":%s}'):format(vim.json.encode(text)))
        .. sse_chunk("{}", "stop")
        .. "data: [DONE]\n\n"
end

---@param tool string
---@param args table
---@return string
local function tool_response(tool, args)
    return sse_headers()
        .. sse_chunk('{"role":"assistant","content":""}')
        .. tool_call_chunk(tool, args)
        .. sse_chunk("{}", "tool_calls")
        .. "data: [DONE]\n\n"
end

--- The LAST background task id mentioned in a request body.
---
--- The body of a later turn carries every earlier tool result too, so anything
--- a previous phase started is in there: the newest one is the last.
---@param body string
---@return string?
local function last_task_id(body)
    local found = nil
    for id in body:gmatch("Task (b%x+) running in background") do
        found = id
    end
    return found
end

---@param provider LogsE2EProvider
---@return string
local function respond(provider)
    provider.turn = provider.turn + 1
    local body = provider.bodies[provider.turn] or ""
    local scripted = table.remove(provider.script, 1)
    if scripted then
        return scripted(body)
    end
    -- Every later turn — the wake caused by the exit report, anything unexpected
    -- — is a plain answer that ends the run. Nothing can hang.
    return text_response("Nothing else to do.")
end

---@return LogsE2EProvider
local function start_fake_provider()
    ---@type LogsE2EProvider
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
            -- `respond` must not block inside a libuv callback: record the body
            -- and answer from the main loop.
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
                name = "E2ELogs",
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
    write_file(agent_dir .. "/models.json", vim.json.encode(models))
    write_file(agent_dir .. "/settings.json", "{}")
end

-- ---------------------------------------------------------------------------
-- RPC backend
-- ---------------------------------------------------------------------------

---@class LogsE2EBackend
---@field job integer
---@field session_dir string
---@field events table[] parsed stdout events (each tagged `_n` = 1-based index)
---@field stderr string

---@param session_dir string
---@param cwd string
---@param env table<string, string> extra environment for the pi child
---@return LogsE2EBackend
local function start_backend(session_dir, cwd, env)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type LogsE2EBackend
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
        -- `env` merges over the inherited environment, so the rest of the parent
        -- process (PATH, HOME, …) still applies. TMPDIR goes here instead of
        -- into `vim.env` on purpose: it must redirect the CHILD's `tmpdir()`
        -- without moving this Neovim's own scratch directory.
        env = env,
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

---@param backend LogsE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend LogsE2EBackend
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

---@param backend LogsE2EBackend
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

--- Every string inside a decoded transcript entry, joined.
---
--- Searching the decoded strings instead of the raw JSONL line keeps the
--- needles readable: report attributes are `id="b123"`, which the raw line
--- stores as `id=\"b123\"`.
---@param entry table
---@return string
local function entry_text(entry)
    local out = {}
    local function walk(value)
        if type(value) == "string" then
            out[#out + 1] = value
        elseif type(value) == "table" then
            for _, item in pairs(value) do
                walk(item)
            end
        end
    end
    walk(entry)
    return table.concat(out, "\n")
end

--- Indices of the transcript entries whose text contains `needle`.
---@param entries table[]
---@param needle string
---@return integer[]
local function entry_indices(entries, needle)
    local out = {}
    for index, entry in ipairs(entries) do
        if entry_text(entry):find(needle, 1, true) then
            out[#out + 1] = index
        end
    end
    return out
end

--- Poll the transcript until an entry contains `needle`.
---@param backend LogsE2EBackend
---@param needle string
---@param timeout_ms integer
---@param what string
---@return table[] entries, integer index
local function wait_entry(backend, needle, timeout_ms, what)
    local entries = {}
    local indices = {}
    local ok = vim.wait(timeout_ms, function()
        entries = read_session(backend.session_dir)
        indices = entry_indices(entries, needle)
        return #indices > 0
    end, 100)
    if not ok then
        print(
            ("[debug] %s timed out (needle %q); entries=%d; stderr=%s"):format(
                what,
                needle,
                #read_session(backend.session_dir),
                backend.stderr
            )
        )
    end
    check(ok, what .. ": the transcript carries it", { needle = needle, stderr = backend.stderr })
    return entries, indices[1]
end

--- Wait until the backend has settled and no new run started for `quiet_ms`.
---@param backend LogsE2EBackend
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

--- Plant the four files the sweep has to judge, with their mtimes.
local function plant_logs()
    vim.fn.mkdir(TMP_DIR, "p")
    local now = os.time()
    write_file(TMP_DIR .. "/" .. STALE_LOG, "stale output\n")
    write_file(TMP_DIR .. "/" .. FRESH_LOG, "fresh output\n")
    write_file(TMP_DIR .. "/" .. NON_HEX_LOG, "zzzzzz output\n")
    write_file(TMP_DIR .. "/" .. FOREIGN_LOG, "someone else's spill file\n")
    -- Two days old against a 60 s TTL: unambiguously stale by mtime alone.
    local stale_s = now - STALE_AGE_S
    assert(uv.fs_utime(TMP_DIR .. "/" .. STALE_LOG, stale_s, stale_s))
    assert(uv.fs_utime(TMP_DIR .. "/" .. FRESH_LOG, now, now))
    assert(uv.fs_utime(TMP_DIR .. "/" .. NON_HEX_LOG, now, now))
    assert(uv.fs_utime(TMP_DIR .. "/" .. FOREIGN_LOG, now, now))
end

local function main()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(RUN_ROOT, "p")
    local agent_dir = RUN_ROOT .. "/agent"

    -- The child pi inherits this env; nothing touches the user's real config.
    vim.env.PI_CODING_AGENT_DIR = agent_dir
    vim.env.PI_OFFLINE = "1"

    -- These cases exercise the delivery ladder, not the cost gate: opt into a
    -- paid wake explicitly. The default policy is `never`, which would (rightly)
    -- hold the report for the next user prompt.
    local prefs_path = RUN_ROOT .. "/bg-tasks.json"
    local prefs = assert(io.open(prefs_path, "w"))
    prefs:write(vim.json.encode({ wake_on_completion = "always", present = true }))
    prefs:close()
    vim.env.PI_NVIM_BG_TASKS_FILE = prefs_path

    plant_logs()
    step("four logs planted in the isolated tmpdir")

    local provider = start_fake_provider()
    local addr = provider.server:getsockname()
    local port = type(addr) == "table" and addr.port or nil
    check(type(port) == "number" and port > 0, "fake provider did not bind a port", { addr = addr })
    write_agent_dir(agent_dir, port)
    step(("fake provider on 127.0.0.1:%d"):format(port))

    local backend = start_backend(RUN_ROOT .. "/sessions", RUN_ROOT .. "/cwd", {
        -- `tmpdir()` follows TMPDIR, so the sweep only ever sees our four files.
        TMPDIR = TMP_DIR,
        TMP = TMP_DIR,
        TEMP = TMP_DIR,
        PI_BG_TASK_LOG_TTL_MS = tostring(LOG_TTL_MS),
    })
    send(backend, { id = "model-1", type = "set_model", provider = PROVIDER, modelId = MODEL_ID })
    local pinned = wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, "set_model")
    check(
        pinned ~= nil and pinned.success ~= false,
        "fake model selected",
        { pinned = pinned, stderr = backend.stderr }
    )

    -- ------------------------------------------------------------------
    -- L1: the sweep at session start judges by name AND age.
    -- ------------------------------------------------------------------
    wait_path(TMP_DIR .. "/" .. STALE_LOG, false, 30000, "L1.1 the stale unknown log was swept")
    step("L1.1 the stale unknown log is gone")

    local survivors = { FRESH_LOG, NON_HEX_LOG, FOREIGN_LOG }
    local missing = {}
    for _, name in ipairs(survivors) do
        if not path_exists(TMP_DIR .. "/" .. name) then
            missing[#missing + 1] = name
        end
    end
    check(
        #missing == 0,
        "L1.2/L1.3 only the stale, unknown log was removed (fresh mtime, non-hex id and a foreign name all stay)",
        { missing = missing, listing = dir_listing(TMP_DIR) }
    )
    -- Age and name are two separate rules; assert each one with its own witness.
    check(
        not path_exists(TMP_DIR .. "/" .. STALE_LOG) and path_exists(TMP_DIR .. "/" .. FRESH_LOG),
        "L1.2 the sweep goes by mtime: the fresh unknown log survived",
        { listing = dir_listing(TMP_DIR) }
    )
    check(
        path_exists(TMP_DIR .. "/" .. NON_HEX_LOG) and path_exists(TMP_DIR .. "/" .. FOREIGN_LOG),
        "L1.3 the sweep goes by name: a non-hex task id and a foreign file survived",
        { listing = dir_listing(TMP_DIR) }
    )
    print("[L1 tmpdir] " .. table.concat(dir_listing(TMP_DIR), " "))
    step("L1 green: stale swept, fresh/non-hex/foreign kept")

    -- ------------------------------------------------------------------
    -- L2: a task THIS process started keeps its log.
    -- ------------------------------------------------------------------
    provider.script = {
        function()
            return tool_response("bash", { command = TASK_COMMAND, run_in_background = true })
        end,
        function(body)
            local id = last_task_id(body)
            if type(id) ~= "string" then
                provider.missing_id = true
                return text_response("no task id in the bash result")
            end
            provider.task_id = id
            return text_response("Task started.")
        end,
    }
    send(backend, { id = "prompt-1", type = "prompt", message = "Start the background task." })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled"
    end, 120000, "L2 run settle")
    check(settled ~= nil, "L2 the run settles", { stderr = backend.stderr })
    check(provider.missing_id == nil, "L2 the task id was read out of the bash result", { turn = provider.turn })
    local task_id = provider.task_id
    check(type(task_id) == "string", "L2 a background task id was captured")
    step("L2 run settled, task " .. task_id)

    -- The started record proves the task is this process's own, and its
    -- `Output:` line proves TMPDIR really reached the child.
    local _, started_index = wait_entry(backend, "Task " .. task_id .. " running in background", 20000, "L2 task start")
    local started_text = entry_text(read_session(backend.session_dir)[started_index])
    local output_path = started_text:match("Output: ([^\n]+)")
    local expected_path = TMP_DIR .. "/pi-bash-" .. task_id .. ".log"
    check(
        output_path == expected_path,
        "L2.1 the task writes its log into the isolated TMPDIR",
        { output_path = output_path, expected = expected_path, text = started_text }
    )
    wait_path(expected_path, true, 20000, "L2.1 the live task's log exists")
    print("[L2 log] " .. expected_path)
    step("L2.1 green: the live task's log exists and is in the isolated tmpdir")

    -- The task sleeps before it prints, so no report can exist yet: this is the
    -- "known to this process while running" case, the one age alone must not touch.
    local report_needle = '<background-task id="' .. task_id .. '"'
    local early_reports = entry_indices(read_session(backend.session_dir), report_needle)
    check(
        #early_reports == 0,
        "L2.2 the task is still running, and its log exists",
        { reports = early_reports, listing = dir_listing(TMP_DIR), stderr = backend.stderr }
    )
    wait_path(expected_path, true, 20000, "L2.2 the running task's log is not a sweep candidate")
    step("L2.2 green: the running task's log survives")

    -- ------------------------------------------------------------------
    -- L3: the exit does not collect the log (TTL has not passed).
    -- ------------------------------------------------------------------
    local _, report_index = wait_entry(backend, report_needle, 60000, "L3 exit report")
    local report_text = entry_text(read_session(backend.session_dir)[report_index])
    print("[L3 report] " .. (report_text:gsub("\n", "\\n")))
    check(
        report_text:find('status="completed"', 1, true) ~= nil,
        "L3 the task really exited on its own",
        { text = report_text }
    )
    wait_path(expected_path, true, 20000, "L3.1 the finished task's log is still there (TTL not reached)")
    step("L3.1 green: the finished task's log is still there")

    wait_file_contains(expected_path, "reaper-done", 20000, "L3.2 the finished task's log still carries its output")
    step("L3.2 green: the finished task's log still carries its output")

    wait_quiet(backend, 1500, 30000, "L3 quiesce")
    wait_path(expected_path, true, 10000, "L3.1 the log survives the run going quiet as well")
    print("[L3 tmpdir] " .. table.concat(dir_listing(TMP_DIR), " "))

    stop_backend(backend)

    print(
        ("ALL bg-tasks logs cases passed (the startup sweep removed only the stale unknown log; a live task's log and its post-exit log both survived) in %.2fs"):format(
            (uv.hrtime() - run_started) / 1e9
        )
    )
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e bg_tasks_logs: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
