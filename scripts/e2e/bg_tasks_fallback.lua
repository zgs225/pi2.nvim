-- Headless e2e: a report the `context` FALLBACK injected survives a failed request.
--
-- The fallback exists for the report nobody else carried: `context` is the exact
-- message list about to be sent, so a pending report that is not in there is
-- injected before that request. The catch is that the injection is never
-- persisted — `event.messages` is a per-request deep copy — so a request that
-- then FAILS takes the injected text with it. Confirming at injection time (the
-- old behaviour) therefore lost the report for good: the model never saw it, the
-- task was already `confirmed`, and nothing would ever deliver it again.
--
-- This script reproduces that in a real process: a `pi --mode rpc` child with the
-- bundled `extensions/bg-tasks.ts`, a scripted fake OpenAI-compatible provider on
-- 127.0.0.1, and the exact request bodies the model received as ground truth.
--
-- Scripted run (attempt = one provider request):
--   attempt 1   bash({ command = "while [ ! -f <marker> ]; do sleep 0.05; done;
--               echo fb-body", run_in_background: true }) -> tool result; the task
--               is blocked on the marker, so the report is `none`.
--   attempt 2   answered HTTP 500, and only THEN is the marker written. Its
--               `turn_end` (outcome `error`) is the last boundary of that run, so
--               the task exits just after it: nothing is appended, nothing is sent.
--   (backoff)   pi's auto-retry waits (retry.baseDelayMs, 2 s by default) while the
--               task exits — mid-run, no boundary, no wake: the report is pending
--               and absent from every message.
--   attempt 3   pi retries (re-firing `context`): the report is injected HERE, into
--               a request that fails. Answered 500 on purpose — this is the request
--               that used to eat it.
--   attempt 4+  the retry must inject it AGAIN; answered 200 with plain text, so
--               the turn completes and only then is the report confirmed.
--
-- Assertions (on `provider.bodies` = the exact payload each request carried):
--   F1 neither of the first two attempts carries a report, and the transcript
--      holds no report message at all (nothing was boundary-delivered or
--      persisted: the fallback is the only carrier this run can exercise)
--   F2 at least two requests carry the report — the failed one did not consume it
--   F3 the LAST request that carries it got a 2xx, i.e. the model actually saw it
--      (with the old confirm-at-injection behaviour the only carrier is the 500)
--   F4 that body carries the block exactly once (a re-injection must not stack)
--   F5 the block names the task id from the bash tool result
--   F6 the run settles — nothing hangs
--
-- Needs the pi binary, nothing else (the provider is fake), which is why it runs
-- in CI (.github/workflows/e2e.yml). Not part of `make test`:
--
--   make e2e-bg-fallback
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_fallback.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-fallback"

local PROVIDER = "e2efallback"
local MODEL_ID = "e2e-model"
-- The task holds until attempt 2 has FAILED, so its report is created strictly
-- after that attempt's turn_end (the last boundary of the run) and strictly
-- before the retry — the one window where only `context` can carry it.
local MARKER = RUN_ROOT .. "/attempt2-failed"
local COMMAND = ("while [ ! -f '%s' ]; do sleep 0.05; done; sleep 0.25; echo fb-body"):format(MARKER)

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

---@class FallbackE2EProvider
---@field server uv.uv_tcp_t
---@field attempt integer requests received so far
---@field bodies table<integer, string> request body per attempt
---@field status table<integer, integer> HTTP status answered per attempt
---@field carries table<integer, boolean> did that body carry the report block

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
        .. sse_chunk(vim.json.encode({ role = "assistant", content = text }))
        .. sse_chunk("{}", "stop")
        .. "data: [DONE]\n\n"
end

--- A non-2xx answer is written WITHOUT SSE, exactly like a real provider error.
---@param code integer
---@param reason string
---@param message string
---@return string
local function error_response(code, reason, message)
    local body = vim.json.encode({ error = { message = message, type = "server_error", param = vim.NIL } })
    return table.concat({
        ("HTTP/1.1 %d %s"):format(code, reason),
        "Content-Type: application/json",
        "Content-Length: " .. #body,
        "Connection: close",
        "",
        body,
    }, "\r\n")
end

---@class FallbackE2EPlan
---@field response string what to write back
---@field status integer the status code in that response

--- What attempt n gets. Deliberately index-driven: no timing race.
---@param provider FallbackE2EProvider
---@param attempt integer
---@return FallbackE2EPlan
local function plan(provider, attempt)
    local body = provider.bodies[attempt] or ""
    provider.carries[attempt] = body:find("<background-task", 1, true) ~= nil

    if attempt == 1 then
        -- Start a background task and end the turn: when the tool result is
        -- persisted the task is still running, so nothing can be reported yet.
        return {
            status = 200,
            response = sse_headers() .. sse_chunk('{"role":"assistant","content":""}') .. tool_call_chunk(
                "bash",
                { command = COMMAND, run_in_background = true }
            ) .. sse_chunk("{}", "tool_calls") .. "data: [DONE]\n\n",
        }
    end
    if attempt == 2 then
        -- The request the tool result belongs to, failed at once so its turn_end
        -- (the last boundary of this run) happens before the task exits: nothing
        -- is pending then, so no report is appended and none is sent.
        return {
            status = 500,
            response = error_response(500, "Internal Server Error", "e2e transient server error"),
        }
    end
    if attempt == 3 then
        -- The retry: the task exited during the backoff and `context` has just
        -- injected the report into this request. Failing it is the whole point —
        -- the injected text dies with it.
        return {
            status = 500,
            response = error_response(500, "Internal Server Error", "e2e transient server error"),
        }
    end
    -- The next retry must inject the report again, and this one succeeds.
    return { status = 200, response = text_response("Background task reported; all done.") }
end

---@return FallbackE2EProvider
local function start_fake_provider()
    local provider = { attempt = 0, bodies = {}, status = {}, carries = {} }
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
            -- Nothing here may block a libuv callback: record the body and
            -- answer from the main loop (with a timer when a delay is wanted).
            vim.schedule(function()
                provider.attempt = provider.attempt + 1
                local attempt = provider.attempt
                provider.bodies[attempt] = body
                local planned = plan(provider, attempt)
                provider.status[attempt] = planned.status
                if attempt == 2 then
                    -- Release the background task now that this attempt has
                    -- failed: its report lands after the turn_end of this run
                    -- (nothing is pending there) and before the retry.
                    vim.fn.writefile({ tostring(uv.now()) }, MARKER)
                end
                print(
                    ("[provider] attempt %d -> %d, carries_report=%s"):format(
                        attempt,
                        planned.status,
                        provider.carries[attempt] and "yes" or "no"
                    )
                )
                pcall(client.write, client, planned.response, function()
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
                name = "E2EFallback",
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

---@class FallbackE2EBackend
---@field job integer
---@field session_dir string
---@field events table[] parsed stdout events (each tagged `_n` = 1-based index)
---@field stderr string

---@param session_dir string
---@param cwd string
---@return FallbackE2EBackend
local function start_backend(session_dir, cwd)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
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

---@param backend FallbackE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend FallbackE2EBackend
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

---@param backend FallbackE2EBackend
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

--- Every custom message that carries a structured report element.
---@param entries table[]
---@return table[]
local function report_entries(entries)
    local out = {}
    for index, entry in ipairs(entries) do
        if entry.type == "custom_message" and type(entry.content) == "string" then
            if entry.content:find("<background-task", 1, true) then
                out[#out + 1] = { index = index, content = entry.content }
            end
        end
    end
    return out
end

---@param text string
---@param needle string
---@return integer
local function count(text, needle)
    local n = 0
    local at = 1
    while true do
        local found = text:find(needle, at, true)
        if not found then
            return n
        end
        n = n + 1
        at = found + 1
    end
end

-- ---------------------------------------------------------------------------

local function main()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(RUN_ROOT, "p")
    local agent_dir = RUN_ROOT .. "/agent"

    -- The child pi inherits this env; nothing touches the user's real config.
    vim.env.PI_CODING_AGENT_DIR = agent_dir
    vim.env.PI_OFFLINE = "1"

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
    step("model pinned to the fake provider")

    send(backend, { id = "prompt-1", type = "prompt", message = "Start the background task." })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled"
    end, 120000, "agent_settled")
    check(settled ~= nil, "the scripted run settles", { stderr = backend.stderr })
    step(("run settled after %d provider attempts"):format(provider.attempt))

    -- The per-attempt table: what each request carried and how it was answered.
    print("[table] attempt -> status, carries_report")
    for attempt = 1, provider.attempt do
        print(
            ("[table]   #%d -> %d, carries_report=%s"):format(
                attempt,
                provider.status[attempt] or -1,
                provider.carries[attempt] and "yes" or "no"
            )
        )
    end

    -------------------------------------------------------------------------
    -- F1: nothing was boundary-delivered; the fallback is the only carrier.
    -------------------------------------------------------------------------
    check(#provider.bodies >= 3, "the provider was asked at least three times (retry on 5xx)", {
        attempts = provider.attempt,
        status = provider.status,
    })
    check(
        provider.carries[1] ~= true and provider.carries[2] ~= true,
        "the first two attempts carry no report (the task had not exited when they were built)",
        { status = provider.status, carries = provider.carries }
    )
    local entries = read_session(backend.session_dir)
    local reports = report_entries(entries)
    if #reports > 0 then
        for _, rep in ipairs(reports) do
            print(("[debug] persisted report entry #%d: %s"):format(rep.index, (rep.content:gsub("\n", "\\n"))))
        end
    end
    check(#reports == 0, "the report was never persisted as a message (the fallback carried it)", {
        count = #reports,
    })
    step("F1 the fallback is the only carrier (no report message in the transcript)")

    -------------------------------------------------------------------------
    -- F2/F3: every request that carried it got a 2xx — the failed one did not
    -- consume it. This is the property the fix adds.
    -------------------------------------------------------------------------
    local carriers = {}
    for attempt = 1, provider.attempt do
        if provider.carries[attempt] then
            carriers[#carriers + 1] = attempt
        end
    end
    check(#carriers >= 1, "some request carried the report", { carriers = carriers, attempts = provider.attempt })
    check(#carriers >= 2, "the report was injected again after the failed request (a failure must not consume it)", {
        carriers = carriers,
        status = provider.status,
    })
    check(
        (provider.status[carriers[1]] or 0) >= 500,
        "the report was FIRST injected into a request that failed",
        { carriers = carriers, status = provider.status }
    )
    local last = carriers[#carriers]
    check(
        (provider.status[last] or 0) >= 200 and (provider.status[last] or 0) < 300,
        "the LAST request carrying the report got a 2xx — the model actually saw it",
        { last_carrier = last, status = provider.status[last], carriers = carriers, statuses = provider.status }
    )
    step(("F2/F3 injected again on the retry; attempt %d answered %d"):format(last, provider.status[last]))

    local winning = provider.bodies[last] or ""
    -------------------------------------------------------------------------
    -- F4: exactly one block in that request — a re-injection must not stack.
    -------------------------------------------------------------------------
    local blocks = count(winning, "<background-task")
    check(blocks == 1, "the successful request carries the block exactly once", { count = blocks })

    -------------------------------------------------------------------------
    -- F5: the block names the task the bash tool result started.
    -------------------------------------------------------------------------
    local task_id = winning:match("Task (b%x+) running in background")
    if type(task_id) ~= "string" then
        -- The tool result may have been dropped from later payloads; read it
        -- out of the earliest body that still carries it.
        for attempt = 1, provider.attempt do
            task_id = (provider.bodies[attempt] or ""):match("Task (b%x+) running in background")
            if type(task_id) == "string" then
                break
            end
        end
    end
    check(type(task_id) == "string", "the bash tool result carried a task id", { attempts = provider.attempt })
    check(
        winning:find('id=\\"' .. task_id .. '\\"', 1, true) ~= nil,
        "the injected block names the task the tool result started",
        { task_id = task_id }
    )
    step("F4/F5 one block in the 2xx request, naming task " .. task_id)
    print("[report] " .. ((winning:match("<system%-reminder>.-</system%-reminder>") or ""):gsub("\n", "\\n")))

    -------------------------------------------------------------------------
    -- F6: the run settled, so nothing hangs (asserted above as well).
    -------------------------------------------------------------------------
    local last_settle = nil
    for _, ev in ipairs(backend.events) do
        if ev.type == "agent_settled" then
            last_settle = ev
        end
    end
    check(last_settle ~= nil, "the run reached agent_settled", { stderr = backend.stderr })
    step("F6 the run settled")

    stop_backend(backend)

    print(
        ("ALL bg-tasks fallback cases passed (the report survives a failed request, exactly once, in a 2xx) in %.2fs"):format(
            (uv.hrtime() - run_started) / 1e9
        )
    )
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e bg_tasks_fallback: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
