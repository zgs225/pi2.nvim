-- Headless e2e: a completion must NOT start a turn when the idle-wake gate holds it.
--
-- A completion that lands while the agent is idle wakes it (`sendMessage(...,
-- { triggerTurn: true })`), and that wake is one full provider request whose
-- price is the whole CONVERSATION, not the report. The gate
-- (`idleWakeHold` in `extensions/bg-tasks.ts`) holds the wake when a human is
-- not at the editor, when the prompt cache has expired, when the task predates
-- the newest user message, or when the prompt's wake allowance is spent — and it
-- is published by the frontend through `PI_NVIM_BG_TASKS_FILE`.
--
-- This script drives that end-to-end against the real stack: a `pi --mode rpc`
-- child with the bundled `extensions/bg-tasks.ts`, a scripted fake
-- OpenAI-compatible provider on 127.0.0.1 (no account, no network, no model
-- call), and the request bodies the provider actually received as ground truth.
--
-- Two cases, one per policy edge:
--   A `wake_on_idle = "never"`            -> hold reason "policy"
--   B `wake_on_idle = "budgeted"`, budget 0 -> hold reason "budget"
--
-- Scripted turns (both cases):
--   T1  ONE background bash call, blocked on a marker file under the run dir
--   T2  plain assistant text — the run ends with the task still blocked, so its
--       completion arrives with nobody attached and the session idle
--   (release the marker: the task exits while the session is idle)
--   T3  answer to the next user prompt — the report must ride THIS request
--   T4  answer to a third prompt — the report must NOT be injected again
--
-- Assertions, all behavioural:
--   G1 the held completion starts NO turn (no `agent_start` after the release)
--   G2 the transcript carries a panel message whose `details.held` names the
--      expected reason (a silent hold would be indistinguishable from a loss)
--   G3 the report is NOT persisted and NOT woken before the user speaks
--   G4 the next user prompt's request carries the report exactly once
--   G5 the request after that carries it zero times (confirmed, not re-injected)
--   G6 exactly the scripted number of assistant turns ran (no wake turn)
--
-- Needs the pi binary, nothing else (the provider is fake), which is why it runs
-- in CI (.github/workflows/e2e.yml). Not part of `make test`:
--
--   make e2e-bg-wake-gate
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_wake_gate.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-wake-gate"

local PROVIDER = "e2egate"
local MODEL_ID = "e2e-model"
local BLOCK_TIMEOUT_MS = 1500

io.stdout:setvbuf("no")
local run_started = uv.hrtime()
local last_step = run_started

---@return number elapsed seconds since the previous step marker
local function step(name)
    local t = uv.hrtime()
    print(string.format("[step] %-58s +%6.2fs (total %7.2fs)", name, (t - last_step) / 1e9, (t - run_started) / 1e9))
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
        detail = "\n  context: " .. vim.inspect(ctx)
    end
    error(("e2e bg_tasks_wake_gate: %s%s"):format(msg, detail), 2)
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
---@param body string
local function write_file(path, body)
    local f = assert(io.open(path, "w"))
    f:write(body)
    f:close()
end

-- ---------------------------------------------------------------------------
-- Fake OpenAI-compatible provider
-- ---------------------------------------------------------------------------

---@param text string
---@return string
local function sse_headers()
    return "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
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

---@class GateE2EProvider
---@field turn integer
---@field bodies table<integer, string> raw request body per turn
---@field task_ids string[]
---@field missing_task_ids boolean?

---@param provider GateE2EProvider
---@return string
local function respond(provider)
    provider.turn = provider.turn + 1
    local turn = provider.turn

    if turn == 1 then
        return sse_headers()
            .. sse_chunk('{"role":"assistant","content":""}')
            .. tool_call_chunk("bash", { command = provider.command, run_in_background = true })
            .. sse_chunk("{}", "tool_calls")
            .. "data: [DONE]\n\n"
    end

    if turn == 2 then
        -- Read the task id out of the bash tool result we were just handed, the
        -- way a real model reads it out of its context.
        local body = provider.bodies[turn] or ""
        local id = body:match("Task (b%x+) running in background")
        if id == nil then
            provider.missing_task_ids = true
            return text_response("missing the task id in the bash result")
        end
        provider.task_ids = { id }
        -- Plain text, no tool call: the run ends with the task still blocked, so
        -- its completion arrives while the session is idle.
        return text_response("Started it in the background.")
    end

    return text_response("Acknowledged.")
end

---@param command string
---@return GateE2EProvider
local function start_fake_provider(command)
    ---@type GateE2EProvider
    local provider = { turn = 0, bodies = {}, task_ids = {}, command = command }
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
            provider.bodies[provider.turn + 1] = body
            local response = respond(provider)
            pcall(client.write, client, response, function()
                pcall(client.close, client)
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
    write_file(
        agent_dir .. "/models.json",
        vim.json.encode({
            providers = {
                [PROVIDER] = {
                    name = "E2EGate",
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
        })
    )
    write_file(agent_dir .. "/settings.json", "{}")
end

-- ---------------------------------------------------------------------------
-- RPC backend
-- ---------------------------------------------------------------------------

---@class GateE2EBackend
---@field job integer
---@field session_dir string
---@field events table[]
---@field stderr string

---@param session_dir string
---@param cwd string
---@param agent_dir string
---@param prefs_path string
---@return GateE2EBackend
local function start_backend(session_dir, cwd, agent_dir, prefs_path)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type GateE2EBackend
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
        env = {
            PI_CODING_AGENT_DIR = agent_dir,
            PI_OFFLINE = "1",
            -- The frontend's runtime policy file; the extension re-reads it at
            -- every wake decision.
            PI_NVIM_BG_TASKS_FILE = prefs_path,
        },
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

---@param backend GateE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend GateE2EBackend
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

---@param backend GateE2EBackend
local function stop_backend(backend)
    pcall(vim.fn.chanclose, backend.job, "stdin")
    pcall(vim.fn.jobstop, backend.job)
    pcall(vim.fn.jobwait, { backend.job }, 5000)
end

-- ---------------------------------------------------------------------------
-- Transcript (the JSONL is ground truth)
-- ---------------------------------------------------------------------------

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

--- Every custom message whose text carries a report block.
---@param entries table[]
---@return table[]
local function report_entries(entries)
    local out = {}
    for index, entry in ipairs(entries) do
        if
            entry.type == "custom_message"
            and type(entry.content) == "string"
            and entry.content:find("<background-task", 1, true)
        then
            out[#out + 1] = { index = index, content = entry.content }
        end
    end
    return out
end

--- Every panel message that carries a hold reason.
---@param entries table[]
---@return table[]
local function held_entries(entries)
    local out = {}
    for index, entry in ipairs(entries) do
        if
            entry.type == "custom_message"
            and type(entry.details) == "table"
            and type(entry.details.held) == "string"
        then
            out[#out + 1] = { index = index, held = entry.details.held, taskId = entry.details.taskId }
        end
    end
    return out
end

---@param entries table[]
---@return integer
local function count_assistant(entries)
    local n = 0
    for _, entry in ipairs(entries) do
        if entry.type == "message" and type(entry.message) == "table" and entry.message.role == "assistant" then
            n = n + 1
        end
    end
    return n
end

--- Count PLAIN occurrences (no Lua patterns: a task id and the markup around it
--- contain `-`, which is a quantifier in a pattern).
---@param haystack string
---@param needle string
---@return integer
local function count_plain(haystack, needle)
    local n, init = 0, 1
    while true do
        local start = haystack:find(needle, init, true)
        if start == nil then
            return n
        end
        n = n + 1
        init = start + 1
    end
end

--- The text of every message in a request BODY, decoded from the JSON envelope.
--- Searching the raw body would have to guess the escaping; decoding is the same
--- message list the model is handed.
---@param body string
---@return string
local function body_text(body)
    local ok, decoded = pcall(vim.json.decode, body)
    if not ok or type(decoded) ~= "table" then
        return ""
    end
    local parts = {}
    for _, message in ipairs(decoded.messages or {}) do
        local content = message.content
        if type(content) == "string" then
            parts[#parts + 1] = content
        elseif type(content) == "table" then
            for _, part in ipairs(content) do
                if type(part) == "table" and type(part.text) == "string" then
                    parts[#parts + 1] = part.text
                end
            end
        end
    end
    return table.concat(parts, "\n")
end

--- The element opener as the model sees it.
---@param task_id string
---@return string
local function report_needle(task_id)
    return '<background-task id="' .. task_id .. '"'
end

-- ---------------------------------------------------------------------------
-- One gate case
-- ---------------------------------------------------------------------------

---@param name string
---@param prefs table
---@param expected_reason string
local function run_case(name, prefs, expected_reason)
    local case_root = RUN_ROOT .. "/" .. name
    vim.fn.mkdir(case_root, "p")
    local agent_dir = case_root .. "/agent"
    local prefs_path = case_root .. "/bg-tasks.json"
    write_file(prefs_path, vim.json.encode(prefs))

    -- Blocked until the script releases it: the completion must land while the
    -- session is idle, which is the only path the gate applies to.
    local marker = case_root .. "/release"
    local command = ("while [ ! -f '%s' ]; do sleep 0.02; done; echo gate-%s"):format(marker, name)

    local provider = start_fake_provider(command)
    local addr = provider.server:getsockname()
    local port = type(addr) == "table" and addr.port or nil
    check(type(port) == "number" and port > 0, "fake provider did not bind a port", { addr = addr })
    write_agent_dir(agent_dir, port)

    local backend = start_backend(case_root .. "/sessions", case_root .. "/cwd", agent_dir, prefs_path)
    send(backend, { id = name .. "-model", type = "set_model", provider = PROVIDER, modelId = MODEL_ID })
    local pinned = wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, "set_model")
    check(pinned ~= nil and pinned.success ~= false, "fake model selected", {
        pinned = pinned,
        stderr = backend.stderr,
    })

    local since = #backend.events
    send(backend, { id = name .. "-prompt-1", type = "prompt", message = "Start it in the background." })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > since
    end, 60000, "agent_settled")
    check(settled ~= nil, "the first scripted run settles", { stderr = backend.stderr })
    check(provider.missing_task_ids == nil, "the bash result must carry the task id", { turn = provider.turn })
    check(#provider.task_ids == 1, "the task id was read out of the tool result", { ids = provider.task_ids })
    local task_id = provider.task_ids[1]
    step(("%s: task %s running, run settled"):format(name, task_id))

    -- The task exits with the session idle: this is the wake the gate must hold.
    write_file(marker, "go")
    local wake = wait_event(backend, function(ev)
        return ev.type == "agent_start" and ev._n > settled._n
    end, BLOCK_TIMEOUT_MS, "no wake turn")
    check(wake == nil, "a held completion must not start a turn", {
        reason = expected_reason,
        wake = wake,
        stderr = backend.stderr,
    })
    step(("%s: G1 no turn started by the held completion"):format(name))

    -- Let any (wrong) follow-up write land before reading the transcript.
    vim.wait(300, function()
        return false
    end)
    local entries = read_session(backend.session_dir)
    check(#report_entries(entries) == 0, "a held report must not be persisted before the user speaks", {
        reports = report_entries(entries),
    })
    local held = held_entries(entries)
    check(#held == 1, "exactly one panel message announces the hold", { held = held })
    check(held[1].held == expected_reason, "the hold names the expected reason", {
        got = held[1].held,
        want = expected_reason,
    })
    check(held[1].taskId == task_id, "the hold names the task", { got = held[1].taskId, want = task_id })
    step(("%s: G2 the panel message says held (%s)"):format(name, expected_reason))

    -- The next user prompt must carry the report, exactly once.
    local before_prompt = #backend.events
    send(backend, { id = name .. "-prompt-2", type = "prompt", message = "What happened?" })
    local prompt_run = wait_event(backend, function(ev)
        return ev.type == "agent_start" and ev._n > before_prompt
    end, 30000, "the user prompt starts a turn")
    check(prompt_run ~= nil, "the user's next prompt starts a turn", { stderr = backend.stderr })
    local prompt_settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > prompt_run._n
    end, 60000, "the prompt's run settles")
    check(prompt_settled ~= nil, "the prompt's run settles", { stderr = backend.stderr })

    local carried = body_text(provider.bodies[3] or "")
    local needle = report_needle(task_id)
    local hits = count_plain(carried, needle)
    check(hits == 1, "the next user prompt's request carries the report exactly once", {
        hits = hits,
        needle = needle,
        body = carried:sub(-1200),
    })
    step(("%s: G4 the next prompt carries the held report once"):format(name))

    -- A request after that one must NOT carry it again: delivery was confirmed,
    -- not re-injected.
    send(backend, { id = name .. "-prompt-3", type = "prompt", message = "Anything else?" })
    local third = wait_event(backend, function(ev)
        return ev.type == "agent_start" and ev._n > prompt_settled._n
    end, 30000, "the third prompt starts a turn")
    check(third ~= nil, "the third prompt starts a turn", { stderr = backend.stderr })
    local third_settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > third._n
    end, 60000, "the third run settles")
    check(third_settled ~= nil, "the third run settles", { stderr = backend.stderr })
    local repeated = body_text(provider.bodies[4] or "")
    local again = count_plain(repeated, needle)
    check(again == 0, "a later request must not carry the report again", {
        hits = again,
        reason = expected_reason,
    })
    step(("%s: G5 a later request does not carry it again"):format(name))

    vim.wait(300, function()
        return false
    end)
    local final = read_session(backend.session_dir)
    -- One assistant message per scripted turn (T1's tool call included) and no
    -- more: a wake turn would add both a message and a provider turn.
    check(provider.turn == 4, "exactly the four scripted provider turns ran", { turns = provider.turn })
    check(count_assistant(final) == 4, "exactly the scripted assistant turns ran (no wake turn)", {
        assistants = count_assistant(final),
        turns = provider.turn,
    })
    step(("%s: G6 exactly the scripted turns ran"):format(name))

    stop_backend(backend)
end

-- ---------------------------------------------------------------------------

local function main()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(RUN_ROOT, "p")

    -- `present: true` and `wake_cache_window_ms: 0` isolate the policy gate from
    -- the presence and cache rules, so a failure names the rule that broke.
    run_case("never", {
        wake_on_idle = "never",
        wake_budget = 2,
        wake_cache_window_ms = 0,
        present = true,
    }, "policy")

    run_case("budget", {
        wake_on_idle = "budgeted",
        wake_budget = 0,
        wake_cache_window_ms = 0,
        present = true,
    }, "budget")

    print(
        ("ALL bg-tasks idle-wake gate cases passed (a held completion starts no turn, says why, and rides\nthe next user prompt exactly once) in %.2fs"):format(
            (uv.hrtime() - run_started) / 1e9
        )
    )
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e bg_tasks_wake_gate: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
