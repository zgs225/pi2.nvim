-- Headless e2e: the `context` FALLBACK, the report nobody else carried.
--
-- `context` is the exact message list about to be sent, so a pending report that
-- is not in there is injected before that request. Two properties follow from the
-- injection never being persisted — `event.messages` is a per-request deep copy —
-- and this script proves both in a real `pi --mode rpc` child with the bundled
-- `extensions/bg-tasks.ts`, a scripted fake OpenAI-compatible provider on
-- 127.0.0.1, and the exact request bodies the model received as ground truth.
--
-- SCENARIO 1 — the report survives a FAILED request (attempt = one provider
-- request; the background task is blocked on a marker file):
--   attempt 1   bash({ command, run_in_background: true }) -> tool result; the
--               task is blocked on the marker, so the report is `none`.
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
--   Assertions F1..F6 (see their comments): the report is injected into the failed
--   attempt and again into the successful one, appears once in that body, names the
--   task id, was never persisted, and the run settles.
--
-- SCENARIO 2 — a report whose ONLY carrier was a failed request still arrives when
-- the run gives up. Same start (a task blocked on its own marker), then EVERY
-- attempt is answered 500 (no SSE) until pi's retries are exhausted: no attempt
-- ever completes, so nothing confirms the injection, and `agent_settled` fires
-- without a `completed` turn_end. The extension re-arms the report in that settle
-- and its wake persists it, so:
--   G1 no report message exists while the failing attempts are running (checked
--      against the transcript snapshot taken at the last failing attempt),
--   G2 after `agent_settled` exactly ONE persisted report message exists, and it
--      carries the banner, the `<background-task` element and the task id,
--   G3 a further prompt's request body carries that report as a normal message and
--      NOT a second copy of it (no re-injection once it is persisted),
--   G4 every run settles — nothing hangs.
--   Reverting the re-arm fails G2/G3: nothing wakes, no wake attempt arrives.
--
-- The retry policy is PINNED in this script's own settings.json
-- (`retry.maxRetries`, see RETRY_SETTINGS) instead of taken from pi's default, and
-- the assertions name that value — otherwise a change to the default silently
-- turns scenario 1 into a different test. The marker margin is deliberately ~1 s
-- (MARKER_MARGIN_S), comfortably inside the 2 s first backoff and comfortably
-- longer than the gap between answering a request and its `turn_end`, so the
-- scenarios do not depend on sub-100 ms scheduling luck.
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

--- How many retries the runs get — PINNED, not inherited (see the header).
--- Scenario 1 needs 2 (fail, fail, succeed) and scenario 2 needs every retry to
--- fail, so the whole suite stays well under half a minute of backoff.
local MAX_RETRIES = 2
--- The agent-dir settings.json this script writes; `retry.baseDelayMs` stays at
--- pi's 2 s default, which is what the ~1 s marker margin fits inside.
local RETRY_SETTINGS = { retry = { maxRetries = MAX_RETRIES } }
--- The last attempt of a give-up run that fails: the failed turn itself plus
--- every retry pi gets.
local LAST_FAILING_ATTEMPT = MAX_RETRIES + 2

--- Delay between the task being released and its exit. The marker is written
--- right after the failing attempt's response, so the task must exit strictly
--- AFTER that attempt's `turn_end` (the last boundary of the run): ~1 s is a
--- comfortably wide version of that window, and still well inside the 2 s
--- backoff before the retry.
local MARKER_MARGIN_S = 1

-- Declared before the provider, which reads them from its scheduled callback.
local read_session, report_entries

-- Scenario 1: the task holds until attempt 2 has FAILED, so its report is created
-- strictly after that attempt's turn_end (the last boundary of the run) and
-- strictly before the retry — the one window where only `context` can carry it.
local MARKER = RUN_ROOT .. "/attempt2-failed"
-- Scenario 2: same shape, its own task/marker, and every attempt after the first
-- fails.
local MARKER_GIVEUP = RUN_ROOT .. "/giveup-attempt2-failed"

--- A command that blocks on `marker`, then waits the margin before exiting.
---@param marker string
---@param body string
---@return string
local function waiting_command(marker, body)
    return ("while [ ! -f '%s' ]; do sleep 0.05; done; sleep %d; echo %s"):format(marker, MARKER_MARGIN_S, body)
end

local COMMAND = waiting_command(MARKER, "fb-body")
local COMMAND_GIVEUP = waiting_command(MARKER_GIVEUP, "fb-giveup-body")

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

--- One scripted run: which attempts it answers, and what its task waits on.
---@class FallbackE2EScenario
---@field mode "retry" | "giveup" `retry` = fail twice then succeed, `giveup` = never succeed
---@field marker string released after this run's second attempt failed
---@field command string the background command the first attempt starts
---@field base integer provider attempts that belong to earlier runs

---@class FallbackE2EProvider
---@field server? uv.uv_tcp_t
---@field attempt integer requests received so far
---@field bodies table<integer, string> request body per attempt
---@field status table<integer, integer> HTTP status answered per attempt
---@field carries table<integer, boolean> did that body carry the report block
---@field scenario FallbackE2EScenario the run the next attempt belongs to
---@field session_dir string? where the transcript is read from mid-run

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

    local scenario = provider.scenario
    local local_attempt = attempt - scenario.base
    local server_error = {
        status = 500,
        response = error_response(500, "Internal Server Error", "e2e transient server error"),
    }

    if local_attempt == 1 then
        -- Start a background task and end the turn: when the tool result is
        -- persisted the task is still running, so nothing can be reported yet.
        return {
            status = 200,
            response = sse_headers() .. sse_chunk('{"role":"assistant","content":""}') .. tool_call_chunk(
                "bash",
                { command = scenario.command, run_in_background = true }
            ) .. sse_chunk("{}", "tool_calls") .. "data: [DONE]\n\n",
        }
    end
    if local_attempt == 2 then
        -- The request the tool result belongs to, failed at once so its turn_end
        -- (the last boundary of this run) happens before the task exits: nothing
        -- is pending then, so no report is appended and none is sent.
        return server_error
    end
    if scenario.mode == "retry" then
        if local_attempt == 3 then
            -- The retry: the task exited during the backoff and `context` has just
            -- injected the report into this request. Failing it is the whole point
            -- — the injected text dies with it.
            return server_error
        end
        -- The next retry must inject the report again, and this one succeeds.
        return { status = 200, response = text_response("Background task reported; all done.") }
    end
    -- give-up mode: every retry fails too, so the run ends without a completed
    -- turn_end. Only the wake the settle sends afterwards is answered 200.
    if local_attempt <= LAST_FAILING_ATTEMPT then
        return server_error
    end
    return { status = 200, response = text_response("Noted.") }
end

---@return FallbackE2EProvider
local function start_fake_provider()
    local provider = {
        attempt = 0,
        bodies = {},
        status = {},
        carries = {},
        scenario = { mode = "retry", marker = MARKER, command = COMMAND, base = 0 },
    }
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
                local scenario = provider.scenario
                local local_attempt = attempt - scenario.base
                local planned = plan(provider, attempt)
                provider.status[attempt] = planned.status
                if local_attempt == 2 then
                    -- Release the background task now that this attempt has
                    -- failed: its report lands after the turn_end of this run
                    -- (nothing is pending there) and before the retry.
                    vim.fn.writefile({ tostring(uv.now()) }, scenario.marker)
                end
                if scenario.mode == "giveup" and local_attempt == LAST_FAILING_ATTEMPT then
                    -- The last failing attempt: whatever the transcript holds now is
                    -- what the model could have seen DURING the run (G1).
                    local entries = read_session(provider.session_dir)
                    scenario.snapshot_entries = #entries
                    scenario.snapshot_reports = #report_entries(entries)
                end
                print(
                    ("[provider] attempt %d (#%d) -> %d, carries_report=%s"):format(
                        attempt,
                        local_attempt,
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

--- Isolated agent dir: our own models.json + a pinned retry policy.
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
    -- The retry count is part of the fixture, not pi's default: scenario 1 fails
    -- twice and needs one more attempt, scenario 2 needs every retry to fail.
    local s = assert(io.open(agent_dir .. "/settings.json", "w"))
    s:write(vim.json.encode(RETRY_SETTINGS))
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

--- Print what the backend has seen so far (a timed-out wait has no other trace).
---@param backend FallbackE2EBackend
---@param what string
local function print_events(backend, what)
    local seen = {}
    for _, ev in ipairs(backend.events) do
        seen[#seen + 1] = string.format("%d:%s", ev._n, tostring(ev.type))
    end
    print(("[debug] %s timed out; events=%s; stderr=%s"):format(what, table.concat(seen, ","), backend.stderr))
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
    print_events(backend, what)
    return nil
end

--- How many runs have settled so far (each run, and each wake-started
--- continuation, is its own run).
---@param backend FallbackE2EBackend
---@return integer
local function settle_count(backend)
    local n = 0
    for _, ev in ipairs(backend.events) do
        if ev.type == "agent_settled" then
            n = n + 1
        end
    end
    return n
end

--- Wait until at least `at_least` runs have settled.
---@param backend FallbackE2EBackend
---@param at_least integer
---@param timeout_ms integer
---@param what string
---@return boolean
local function wait_settles(backend, at_least, timeout_ms, what)
    local ok = vim.wait(timeout_ms, function()
        return settle_count(backend) >= at_least
    end, 50)
    if not ok then
        print_events(backend, what)
    end
    return ok
end

--- Wait until the provider has been asked at least `at_least` times.
---@param provider FallbackE2EProvider
---@param at_least integer
---@param timeout_ms integer
---@param what string
---@return boolean
local function wait_attempts(provider, at_least, timeout_ms, what)
    local ok = vim.wait(timeout_ms, function()
        return provider.attempt >= at_least
    end, 50)
    if not ok then
        print(
            ("[debug] %s timed out; attempts=%d, statuses=%s"):format(
                what,
                provider.attempt,
                vim.inspect(provider.status, { newline = " ", indent = "" })
            )
        )
    end
    return ok
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
---@param session_dir string?
---@return table[]
function read_session(session_dir)
    if type(session_dir) ~= "string" then
        return {}
    end
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
function report_entries(entries)
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

---@param provider FallbackE2EProvider
---@param from integer first attempt to print
---@param to integer last attempt to print
---@param title string
local function print_table(provider, from, to, title)
    print("[table] " .. title)
    for attempt = from, math.min(to, provider.attempt) do
        print(
            ("[table]   #%d -> %d, carries_report=%s"):format(
                attempt,
                provider.status[attempt] or -1,
                provider.carries[attempt] and "yes" or "no"
            )
        )
    end
end

--- The task id the run's own bash tool result carried. Every request body holds
--- the WHOLE conversation, so earlier runs' tool results are in there too: take
--- the LAST match, which is the task this run started.
---@param provider FallbackE2EProvider
---@param base integer
---@return string?
local function task_id_of(provider, base)
    local id = nil
    for attempt = base + 1, provider.attempt do
        for found in (provider.bodies[attempt] or ""):gmatch("Task (b%x+) running in background") do
            id = found
        end
    end
    return id
end

-- ---------------------------------------------------------------------------
-- Scenario 1: an injection into a failed request is repeated on the retry
-- ---------------------------------------------------------------------------

---@param backend FallbackE2EBackend
---@param provider FallbackE2EProvider
local function run_retry_scenario(backend, provider)
    provider.scenario = { mode = "retry", marker = MARKER, command = COMMAND, base = provider.attempt }

    send(backend, { id = "prompt-1", type = "prompt", message = "Start the background task." })
    check(wait_settles(backend, 1, 120000, "agent_settled"), "the scripted run settles", {
        stderr = backend.stderr,
    })
    step(("run settled after %d provider attempts"):format(provider.attempt))

    -- The per-attempt table: what each request carried and how it was answered.
    print_table(provider, 1, provider.attempt, "attempt -> status, carries_report")

    -------------------------------------------------------------------------
    -- F1: nothing was boundary-delivered; the fallback is the only carrier.
    -------------------------------------------------------------------------
    check(
        #provider.bodies >= 3,
        ("the provider was asked at least three times (retry.maxRetries=%d)"):format(MAX_RETRIES),
        { attempts = provider.attempt, status = provider.status }
    )
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
    local task_id = task_id_of(provider, 0)
    if type(task_id) ~= "string" then
        task_id = winning:match("Task (b%x+) running in background")
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
    check(settle_count(backend) >= 1, "the run reached agent_settled", { stderr = backend.stderr })
    step("F6 the run settled")
end

-- ---------------------------------------------------------------------------
-- Scenario 2: a report only a failed request carried still arrives when the run
-- gives up (the re-arm in `agent_settled`)
-- ---------------------------------------------------------------------------

---@param backend FallbackE2EBackend
---@param provider FallbackE2EProvider
local function run_giveup_scenario(backend, provider)
    local settles_before = settle_count(backend)
    local scenario = {
        mode = "giveup",
        marker = MARKER_GIVEUP,
        command = COMMAND_GIVEUP,
        base = provider.attempt,
    }
    provider.scenario = scenario
    local first_attempt = scenario.base + 1
    local last_failing_attempt = scenario.base + LAST_FAILING_ATTEMPT
    local wake_attempt = last_failing_attempt + 1
    local followup_attempt = wake_attempt + 1

    step(("scenario 2: every attempt fails (retry.maxRetries=%d) until the run gives up"):format(MAX_RETRIES))
    send(backend, { id = "prompt-2", type = "prompt", message = "Start the second background task." })
    check(
        wait_settles(backend, settles_before + 1, 120000, "agent_settled after the retries were exhausted"),
        "the run whose attempts all failed settles — the retries are exhausted, nothing hangs",
        { stderr = backend.stderr, attempts = provider.attempt, status = provider.status }
    )
    step(("the failed run settled after %d attempts"):format(provider.attempt - scenario.base))
    print_table(provider, first_attempt, provider.attempt, "scenario 2 attempt -> status, carries_report")

    -------------------------------------------------------------------------
    -- G1: nothing was persisted while the attempts were running. The snapshot
    -- is taken at the LAST failing attempt, so it is what the model could have
    -- seen mid-run; the exits and the injections are all in that window.
    -------------------------------------------------------------------------
    check(
        type(scenario.snapshot_reports) == "number",
        "the last failing attempt was observed (transcript snapshot taken)",
        { snapshot = scenario.snapshot_reports, attempts = provider.attempt }
    )
    check(
        scenario.snapshot_reports == 0,
        "no report message exists while the failing attempts are running (only `context` carried it)",
        { reports = scenario.snapshot_reports, entries = scenario.snapshot_entries }
    )
    local injected = {}
    for attempt = first_attempt, last_failing_attempt do
        if provider.carries[attempt] then
            injected[#injected + 1] = attempt
        end
    end
    check(#injected >= 1, "at least one failing attempt had the report injected into it", {
        carriers = provider.carries,
        status = provider.status,
    })
    for _, attempt in ipairs(injected) do
        check(
            (provider.status[attempt] or 0) >= 500,
            "every attempt that carried the report while the run was failing was answered 500",
            { carriers = injected, status = provider.status }
        )
    end
    step(
        ("G1 no persisted report while attempts %d..%d ran (%d carried it, all 500)"):format(
            first_attempt,
            last_failing_attempt,
            #injected
        )
    )

    local task_id = task_id_of(provider, scenario.base)
    check(type(task_id) == "string", "the bash tool result carried a task id for the second run", {
        attempts = provider.attempt,
    })

    -------------------------------------------------------------------------
    -- G2: the settle re-armed the report, so its wake persisted EXACTLY ONE
    -- report message — and it woke a real request (the wake attempt below).
    -------------------------------------------------------------------------
    check(
        wait_attempts(provider, wake_attempt, 30000, "the re-armed report woke a new turn"),
        "after the run gave up, the re-armed report woke a new turn (a failed request must not swallow it)",
        {
            wake_attempt = wake_attempt,
            attempts = provider.attempt,
            status = provider.status,
            carriers = provider.carries,
        }
    )
    check(
        (provider.status[wake_attempt] or 0) >= 200 and (provider.status[wake_attempt] or 0) < 300,
        "the wake request was answered 2xx",
        { status = provider.status[wake_attempt] }
    )
    check(
        provider.carries[wake_attempt] == true,
        "the wake request carries the re-armed report as a persisted message",
        { carriers = provider.carries }
    )

    local entries = read_session(backend.session_dir)
    local reports = report_entries(entries)
    if #reports > 0 then
        for _, rep in ipairs(reports) do
            print(("[debug] persisted report entry #%d: %s"):format(rep.index, (rep.content:gsub("\n", "\\n"))))
        end
    end
    check(
        #reports == 1,
        "after agent_settled exactly one persisted report message exists (the re-arm delivered it)",
        { count = #reports, attempts = provider.attempt, status = provider.status }
    )
    local persisted = reports[1]
    check(
        persisted.index > (scenario.snapshot_entries or 0),
        "the persisted report was appended AFTER the failing attempts (it came from the settle)",
        { index = persisted.index, snapshot_entries = scenario.snapshot_entries }
    )
    for _, needle in ipairs({ "[SYSTEM NOTIFICATION", "<background-task", task_id }) do
        check(
            persisted.content:find(needle, 1, true) ~= nil,
            "the persisted report carries " .. needle,
            { task_id = task_id }
        )
    end
    step(("G2 one persisted report after the settle, naming task %s"):format(task_id))
    print("[report] " .. ((persisted.content:match("<system%-reminder>.-</system%-reminder>") or ""):gsub("\n", "\\n")))

    -------------------------------------------------------------------------
    -- G3: a further prompt carries it as a NORMAL message, and no second copy:
    -- once the report is persisted, `context` confirms it instead of injecting.
    -------------------------------------------------------------------------
    check(
        wait_settles(backend, settles_before + 2, 60000, "the wake turn settles"),
        "the wake turn settles",
        { stderr = backend.stderr }
    )
    step("the wake turn completed (the re-armed report reached the model)")

    send(backend, { id = "prompt-3", type = "prompt", message = "Nothing to do; confirm you are done." })
    check(
        wait_attempts(provider, followup_attempt, 30000, "the follow-up prompt is answered"),
        "a further prompt is answered (the session is not stuck)",
        { followup_attempt = followup_attempt, attempts = provider.attempt }
    )
    local followup_body = provider.bodies[followup_attempt] or ""
    check(
        count(followup_body, "[SYSTEM NOTIFICATION") == 1,
        "the follow-up request carries the report banner exactly once (no re-injection)",
        { count = count(followup_body, "[SYSTEM NOTIFICATION") }
    )
    check(
        count(followup_body, "<background-task") == 1,
        "the follow-up request carries exactly one report element (no second copy)",
        { count = count(followup_body, "<background-task") }
    )
    check(
        followup_body:find(task_id, 1, true) ~= nil,
        "the report the follow-up request carries names the task (it is the persisted message)",
        { task_id = task_id }
    )
    step("G3 the follow-up request carries the report once, as a normal message")

    check(
        wait_settles(backend, settles_before + 3, 60000, "the follow-up turn settles"),
        "the follow-up turn settles",
        { stderr = backend.stderr }
    )
    local reports_after = report_entries(read_session(backend.session_dir))
    check(
        #reports_after == 1,
        "still exactly one persisted report message (nothing added a second copy)",
        { count = #reports_after }
    )
    -------------------------------------------------------------------------
    -- G4: every run settled — asserted by the waits above, restated for the log.
    -------------------------------------------------------------------------
    step(
        ("G4 all %d runs settled, %d provider attempts, no duplicates"):format(settle_count(backend), provider.attempt)
    )
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
    step(("fake provider on 127.0.0.1:%d (retry.maxRetries=%d pinned)"):format(port, MAX_RETRIES))

    local backend = start_backend(RUN_ROOT .. "/sessions", RUN_ROOT .. "/cwd")
    provider.session_dir = backend.session_dir

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

    run_retry_scenario(backend, provider)
    run_giveup_scenario(backend, provider)

    stop_backend(backend)

    print(
        ("ALL bg-tasks fallback cases passed (an injection survives a failed request, and a run that gives up delivers it as a persisted message, exactly once) in %.2fs"):format(
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
