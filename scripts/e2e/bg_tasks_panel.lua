-- Headless e2e: the task PANEL channel — state reaches the frontend the moment
-- it changes, and a resumed session rebuilds its rows from one digest.
--
-- `:PiTasks` used to be driven by a `display:false` custom MESSAGE per task
-- transition. Core defers such a message while a run is streaming (it waits for
-- the next turn boundary, because a message inserted mid-turn would sit between
-- an assistant tool call and its result), so a task that exited during a long
-- tool call kept reading "running" until that turn ended — measured 7.4 s of lag
-- for a `sleep 3` task followed by a `sleep 10`, and N minutes for an N-minute
-- command. Worse, when both calls were issued in ONE assistant message the
-- `started` row was delayed too: the panel was empty for the whole run.
--
-- The panel now folds an extension ENTRY (`pi.appendEntry`), which core appends
-- and emits as `entry_appended` immediately, and which never enters LLM context.
-- The model keeps its own channel (the delivery ladder's structured report).
--
-- Scripted turns, against a real `pi --mode rpc` child with the bundled
-- `extensions/bg-tasks.ts`, a scripted fake OpenAI-compatible provider on
-- 127.0.0.1 (no account, no network, no model), and the session transcript as
-- ground truth:
--   T1  ONE assistant message with two bash calls — background
--       `sleep 2; touch <marker>` and foreground `sleep 6`
--   T2  plain assistant text (the run ends; the report rides the ladder)
--
-- Assertions, all behavioural:
--   P1 the `started` panel entry arrives while the run is still busy (within
--      1 s of the turn), not at its boundary
--   P2 the `completed` panel entry arrives right after the process exits —
--      before the foreground tool returns, with the exit marker already on disk
--   P3 the transcript holds the panel record as a `custom` entry, and carries
--      NO `[Background task …]` custom message any more (the model's context no
--      longer gets the ping) while the ladder report still arrives
--   P4 resuming the session in a SECOND process publishes ONE
--      `pi2_bg_tasks_snapshot` digest carrying the record with its real
--      `endedAt`, so a replayed chat can rebuild the row without fetching the
--      whole entry list
--
-- Needs the pi binary, nothing else (the provider is fake), which is why it runs
-- in CI (.github/workflows/e2e.yml). Not part of `make test`:
--
--   make e2e-bg-panel
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_panel.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-panel"
local MARKER = RUN_ROOT .. "/bg-exited.marker"

local PROVIDER = "e2epanel"
local MODEL_ID = "e2e-model"
local BG_COMMAND = "sleep 2; touch " .. MARKER
local FG_COMMAND = "sleep 6"

io.stdout:setvbuf("no")
local run_started = uv.hrtime()
local last_step = run_started

---@return number elapsed seconds since the previous step marker
local function step(name)
    local t = uv.hrtime()
    print(string.format("[step] %-62s +%6.2fs (total %7.2fs)", name, (t - last_step) / 1e9, (t - run_started) / 1e9))
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

---@class PanelE2EProvider
---@field server? uv.uv_tcp_t
---@field turn integer requests answered so far
---@field bodies string[] request body per turn

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
--- `index` orders several calls inside ONE assistant turn.
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

---@param provider PanelE2EProvider
---@return string
local function respond(provider)
    provider.turn = provider.turn + 1
    if provider.turn == 1 then
        -- BOTH calls in one assistant message: the run stays busy while the
        -- background task exits, so a boundary-deferred panel update cannot
        -- arrive before the foreground command returns.
        return sse_headers()
            .. sse_chunk('{"role":"assistant","content":""}')
            .. tool_call_chunk("bash", { command = BG_COMMAND, run_in_background = true }, 0)
            .. tool_call_chunk("bash", { command = FG_COMMAND }, 1)
            .. sse_chunk("{}", "tool_calls")
            .. "data: [DONE]\n\n"
    end
    return text_response("Both calls are done.")
end

---@return PanelE2EProvider
local function start_fake_provider()
    ---@type PanelE2EProvider
    local provider = { turn = 0, bodies = {} }
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
            vim.schedule(function()
                provider.bodies[provider.turn + 1] = body
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
                name = "E2EPanel",
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

---@class PanelE2EBackend
---@field job integer
---@field session_dir string
---@field events table[] parsed stdout events (each tagged `_n` and `_t`)
---@field stderr string
---@field on_event? fun(ev: table) called for every decoded event

---@param session_dir string
---@param cwd string
---@param on_event? fun(ev: table)
---@return PanelE2EBackend
local function start_backend(session_dir, cwd, on_event)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type PanelE2EBackend
    local backend = { job = 0, session_dir = session_dir, events = {}, stderr = "", on_event = on_event }
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
                        decoded._t = (uv.hrtime() - run_started) / 1e9
                        backend.events[#backend.events + 1] = decoded
                        if backend.on_event then
                            pcall(backend.on_event, decoded)
                        end
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

---@param backend PanelE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend PanelE2EBackend
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
    end, 25)
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

---@param backend PanelE2EBackend
local function stop_backend(backend)
    pcall(vim.fn.chanclose, backend.job, "stdin")
    pcall(vim.fn.jobstop, backend.job)
    pcall(vim.fn.jobwait, { backend.job }, 5000)
end

---@param backend PanelE2EBackend
---@param id string
---@param provider string
---@param model_id string
---@param what string
---@return table? response
local function pin_model(backend, id, provider, model_id, what)
    send(backend, { id = id, type = "set_model", provider = provider, modelId = model_id })
    return wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, what)
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
                    decoded._file = name
                    entries[#entries + 1] = decoded
                end
            end
        end
    end
    return entries
end

---@param session_dir string
---@return string? path
local function first_session_file(session_dir)
    local names = vim.fn.readdir(session_dir)
    table.sort(names)
    for _, name in ipairs(names) do
        if name:match("%.jsonl$") then
            return session_dir .. "/" .. name
        end
    end
    return nil
end

--- Panel records (`pi.appendEntry(CUSTOM_TYPE, details)` entries).
---@param entries table[]
---@param kind string?
---@return table[]
local function panel_entries(entries, kind)
    local out = {}
    for _, entry in ipairs(entries) do
        if entry.type == "custom" and entry.customType == "pi2_bg_task" and type(entry.data) == "table" then
            if kind == nil or entry.data.kind == kind then
                out[#out + 1] = entry
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------

---@class PanelTrace
---@field task_id? string
---@field started_ev? table
---@field completed_ev? table
---@field started_entry? table the transcript's started record
---@field foreground_start_at? number
---@field foreground_end_at? number
---@field marker_present_at_entry boolean? was the exit marker on disk when the
---        `completed` entry reached the frontend
---@field tool_starts integer

--- Record what the frontend saw, event by event.
---@param trace PanelTrace
---@return fun(ev: table)
local function tracer(trace)
    return function(ev)
        if ev.type == "tool_execution_start" and ev.toolName == "bash" then
            trace.tool_starts = trace.tool_starts + 1
            if trace.tool_starts == 2 then
                trace.foreground_start_at = ev._t
            end
        elseif ev.type == "tool_execution_end" and ev.toolName == "bash" then
            trace.foreground_end_at = ev._t
        elseif ev.type == "entry_appended" and type(ev.entry) == "table" then
            local entry = ev.entry
            if entry.type == "custom" and entry.customType == "pi2_bg_task" and type(entry.data) == "table" then
                if entry.data.kind == "started" and trace.started_ev == nil then
                    trace.started_ev = ev
                    trace.task_id = type(entry.data.taskId) == "string" and entry.data.taskId or nil
                elseif entry.data.kind == "completed" and trace.completed_ev == nil then
                    trace.completed_ev = ev
                    trace.marker_present_at_entry = uv.fs_stat(MARKER) ~= nil
                end
            end
        end
    end
end

local function main()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(RUN_ROOT, "p")
    local agent_dir = RUN_ROOT .. "/agent"
    local session_dir = RUN_ROOT .. "/sessions"
    local cwd = RUN_ROOT .. "/cwd"

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

    local provider = start_fake_provider()
    local addr = provider.server:getsockname()
    local port = type(addr) == "table" and addr.port or nil
    check(type(port) == "number" and port > 0, "fake provider did not bind a port", { addr = addr })
    write_agent_dir(agent_dir, port)
    step(("fake provider on 127.0.0.1:%d"):format(port))

    ---@type PanelTrace
    local trace = { tool_starts = 0 }
    local backend = start_backend(session_dir, cwd, tracer(trace))
    local pinned = pin_model(backend, "model-1", PROVIDER, MODEL_ID, "set_model")
    check(pinned ~= nil and pinned.success ~= false, "fake model selected", {
        pinned = pinned,
        stderr = backend.stderr,
    })
    step("model pinned to the fake provider")

    local since = #backend.events
    send(backend, { id = "prompt-1", type = "prompt", message = "Start both commands." })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > since
    end, 120000, "agent_settled")
    check(settled ~= nil, "the scripted run settles", { stderr = backend.stderr })
    step("scripted run settled (background task exited mid-run)")

    check(trace.task_id ~= nil, "the panel entry named a task id", {
        started = trace.started_ev ~= nil,
        stderr = backend.stderr,
    })
    step("task id " .. tostring(trace.task_id))

    -- ------------------------------------------------------------------
    -- P1: the `started` row is live, not boundary-deferred.
    -- ------------------------------------------------------------------
    check(trace.started_ev ~= nil, "a `started` panel entry reached the frontend", { stderr = backend.stderr })
    check(trace.foreground_start_at ~= nil, "both tool calls were traced", { trace = trace })
    local started_lag = trace.started_ev._t - trace.foreground_start_at
    print(("[panel] started entry arrived %.2fs after the turn's first tool call"):format(started_lag))
    check(started_lag <= 1.0, "P1 the `started` entry arrives while the run is busy", {
        lag = started_lag,
        foreground_end = trace.foreground_end_at,
    })
    check(
        trace.started_ev._t < trace.foreground_end_at,
        "P1 the `started` entry arrives BEFORE the foreground tool returns",
        { started_at = trace.started_ev._t, foreground_end = trace.foreground_end_at }
    )
    step("P1 `started` entry is live (turn still busy)")

    -- ------------------------------------------------------------------
    -- P2: the `completed` row follows the exit, not the turn.
    -- ------------------------------------------------------------------
    check(trace.completed_ev ~= nil, "a `completed` panel entry reached the frontend", {
        started = trace.started_ev ~= nil,
        stderr = backend.stderr,
    })
    local exit_lag = trace.completed_ev._t - trace.started_ev._t
    print(("[panel] completed entry arrived %.2fs after the started entry "):format(exit_lag))
    check(trace.marker_present_at_entry == true, "P2 the process had really exited when the entry arrived", {
        marker = MARKER,
    })
    check(
        trace.completed_ev._t < trace.foreground_end_at,
        "P2 the `completed` entry arrives BEFORE the foreground tool returns (not at the turn boundary)",
        { completed_at = trace.completed_ev._t, foreground_end = trace.foreground_end_at }
    )
    -- The background command sleeps 2 s and the foreground one 6 s: a boundary
    -- channel could not report before ~6 s, so a 4 s bound is well clear of it
    -- while tolerating a loaded machine.
    check(exit_lag <= 4.0, "P2 the `completed` entry follows the exit, not the turn", { lag = exit_lag })
    step("P2 `completed` entry follows the exit, not the turn")

    -- ------------------------------------------------------------------
    -- P3: the panel record is an entry, and the model's context lost the ping.
    -- ------------------------------------------------------------------
    local entries = read_session(session_dir)
    local completed_records = panel_entries(entries, "completed")
    check(#completed_records == 1, "P3 exactly ONE `completed` panel entry is in the transcript", {
        count = #completed_records,
    })
    local record = completed_records[1].data
    check(record.taskId == trace.task_id, "P3 the record names the task", { record = record })
    check(record.exitCode == 0, "P3 the record carries the exit code", { record = record })
    check(type(record.endedAt) == "number" and record.endedAt > 0, "P3 the record carries its exit time", {
        record = record,
    })

    local pings, reports = 0, 0
    for _, entry in ipairs(entries) do
        if entry.type == "custom_message" and entry.customType == "pi2_bg_task" then
            local content = type(entry.content) == "string" and entry.content or ""
            if content:find("[Background task ", 1, true) == 1 then
                pings = pings + 1
            end
            if content:find("[SYSTEM NOTIFICATION", 1, true) == 1 then
                reports = reports + 1
            end
        end
    end
    check(pings == 0, "P3 no `[Background task …]` ping is in the model's context any more", { pings = pings })
    check(reports >= 1, "P3 the model still gets the structured delivery report", { reports = reports })
    step("P3 panel records are entries; the model keeps only the report")

    stop_backend(backend)

    -- ------------------------------------------------------------------
    -- P4: resuming the session republishes the folded table as ONE digest.
    -- ------------------------------------------------------------------
    local session_path = first_session_file(session_dir)
    check(type(session_path) == "string", "P4 the first process wrote a session file", { dir = session_dir })

    local backend2 = start_backend(session_dir, cwd)
    local pinned2 = pin_model(backend2, "model-2", PROVIDER, MODEL_ID, "set_model (resume)")
    check(pinned2 ~= nil and pinned2.success ~= false, "P4 fake model selected in the second process", {
        stderr = backend2.stderr,
    })
    local switch_since = #backend2.events
    send(backend2, { id = "switch-1", type = "switch_session", sessionPath = session_path })
    local snapshot = wait_event(backend2, function(ev)
        if ev.type ~= "entry_appended" or ev._n <= switch_since then
            return false
        end
        local entry = ev.entry
        return type(entry) == "table" and entry.type == "custom" and entry.customType == "pi2_bg_tasks_snapshot"
    end, 60000, "resume snapshot")
    check(snapshot ~= nil, "P4 resuming publishes a snapshot digest", { stderr = backend2.stderr })
    local records = snapshot.entry.data and snapshot.entry.data.tasks or {}
    local found = nil
    for _, item in ipairs(records) do
        if type(item) == "table" and item.taskId == trace.task_id then
            found = item
        end
    end
    check(found ~= nil, "P4 the digest carries the task", { task_id = trace.task_id, records = records })
    check(found.kind == "completed", "P4 the digest carries the terminal state", { record = found })
    check(found.exitCode == 0, "P4 the digest carries the exit code", { record = found })
    check(type(found.endedAt) == "number" and found.endedAt > 0, "P4 the digest keeps the real exit time", {
        record = found,
    })
    step("P4 the resume digest rebuilds the row with its real exit time")

    stop_backend(backend2)

    print(
        (
            "ALL bg-tasks panel cases passed (the `started` and `completed` rows are live instead of\n"
            .. "boundary-deferred, the model's context keeps only the delivery report, and a resumed\n"
            .. "session rebuilds its rows from ONE snapshot digest) in %.2fs"
        ):format((uv.hrtime() - run_started) / 1e9)
    )
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e bg_tasks_panel: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
