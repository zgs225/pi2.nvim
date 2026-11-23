-- Headless e2e: `wait_task({ until = … })` — end a wait on a printed line, not
-- on the exit, and still get the exit report exactly once.
--
-- A server that prints a ready line and then runs forever could only be polled
-- by hand: `wait_task` used to return on the exit or on its own timeout, never
-- on "the thing I am waiting for has said hello". `until` ends the wait when a
-- literal line shows up, with the process still running — and the exit report
-- must STILL arrive exactly once afterwards, because a match releases the
-- observer lease instead of claiming the report.
--
-- One `pi --mode rpc` child with the bundled `extensions/bg-tasks.ts` and a
-- scripted fake provider, driving REAL shells:
--
--   U1  bash(run_in_background, "printf 'warming up\n'; sleep 1; printf 'READY\n';
--       sleep 6; printf 'DONE\n'")
--   U2  wait_task(<id from U1>, until = "READY", timeout_ms = 8000)
--   U3  NEW prompt: bash(run_in_background, "sleep 3; printf 'LATE\n'")
--   U4  wait_task(<id from U3>, until = "NEVER", timeout_ms = 1200)
--   ... every other turn is plain assistant text with `finish: "stop"`, so the
--   wake caused by an exit report can never hang the run.
--
-- Assertions, all read off the session transcript:
--   U1.1 the wait result carries `[matched]` and the matched line (READY)
--   U1.2 it is a match, not a deadline: the text never says "has not exited"
--   U1.3 the task's exit report exists, reads `status="completed" exit_code="0"`,
--        and lands AFTER the wait result — a match does not consume the report
--   U1.4 that exit report appears exactly once, re-checked after the run quiesced
--   U2.1 a needle that never shows up ends the wait with `[still running]` and
--        says the output never contained it
--   U2.2 the timeout did not kill anything: the exit report still reads
--        `status="completed" exit_code="0"`, exactly once
--
-- Needs the pi binary, nothing else (the provider is fake), which is why it runs
-- in CI (.github/workflows/e2e.yml). Not part of `make test`:
--
--   make e2e-bg-until
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_until.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-until"

local PROVIDER = "e2euntil"
local MODEL_ID = "e2e-model"
local U1_COMMAND = "printf 'warming up\\n'; sleep 1; printf 'READY\\n'; sleep 6; printf 'DONE\\n'"
local U1_NEEDLE = "READY"
local U2_COMMAND = "sleep 3; printf 'LATE\\n'"
local U2_NEEDLE = "NEVER"

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

---@class UntilE2EProvider
---@field server? uv.uv_tcp_t
---@field turn integer requests answered so far
---@field bodies string[] request body per turn
---@field script (fun(body: string): string)[] queued scripted answers
---@field u1_id string? id of the U1 (matched) background task
---@field u2_id string? id of the U2 (deadline) background task
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
--- The body of a later turn carries every earlier tool result too, so the first
--- match may well be the previous phase's task: the newest one is the last.
---@param body string
---@return string?
local function last_task_id(body)
    local found = nil
    for id in body:gmatch("Task (b%x+) running in background") do
        found = id
    end
    return found
end

---@param provider UntilE2EProvider
---@return string
local function respond(provider)
    provider.turn = provider.turn + 1
    local body = provider.bodies[provider.turn] or ""
    local scripted = table.remove(provider.script, 1)
    if scripted then
        return scripted(body)
    end
    -- Every later turn — a wake caused by the U1 exit report, anything
    -- unexpected — is a plain answer that ends the run. Nothing can hang.
    return text_response("Nothing else to do.")
end

---@return UntilE2EProvider
local function start_fake_provider()
    ---@type UntilE2EProvider
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
                name = "E2EUntil",
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

---@class UntilE2EBackend
---@field job integer
---@field session_dir string
---@field events table[] parsed stdout events (each tagged `_n` = 1-based index)
---@field stderr string

---@param session_dir string
---@param cwd string
---@return UntilE2EBackend
local function start_backend(session_dir, cwd)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type UntilE2EBackend
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

---@param backend UntilE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend UntilE2EBackend
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

---@param backend UntilE2EBackend
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
---@param backend UntilE2EBackend
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
---@param backend UntilE2EBackend
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
    vim.env.PI_OFFLINE = "1"
    -- Write our own policy file instead of inheriting the editor's: this script
    -- IS run from pi.nvim sometimes, and the published policy says `present:
    -- false` whenever the editor is unfocused (which holds the exit report) and
    -- now defaults to `never` anyway. The cases assert the exit report, so opt
    -- into paid wakes explicitly.
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

    -- ------------------------------------------------------------------
    -- U1: a printed line ends the wait; the exit report still arrives once.
    -- ------------------------------------------------------------------
    provider.script = {
        function()
            return tool_response("bash", { command = U1_COMMAND, run_in_background = true })
        end,
        function(body)
            local id = last_task_id(body)
            if type(id) ~= "string" then
                provider.missing_id = true
                return text_response("no task id in the bash result")
            end
            provider.u1_id = id
            return tool_response("wait_task", { task_id = id, ["until"] = U1_NEEDLE, timeout_ms = 8000 })
        end,
    }
    send(backend, { id = "prompt-1", type = "prompt", message = "Start the task that prints READY." })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled"
    end, 120000, "U1 run settle")
    check(settled ~= nil, "U1 the run settles", { stderr = backend.stderr })
    check(provider.missing_id == nil, "U1 the task id was read out of the bash result", { turn = provider.turn })
    local u1_id = provider.u1_id
    check(type(u1_id) == "string", "U1 a background task id was captured")
    step("U1 run settled, task " .. u1_id)

    -- U1.1 / U1.2: the wait ended on the line, not on the deadline.
    local matched_needle = "[matched] Task " .. u1_id .. ' printed "' .. U1_NEEDLE .. '"'
    local entries, matched_index = wait_entry(backend, matched_needle, 20000, "U1 matched result")
    local matched_text = entry_text(entries[matched_index])
    print("[U1 matched] " .. (matched_text:gsub("\n", "\\n")))
    check(
        matched_text:find(U1_NEEDLE, 1, true) ~= nil,
        "U1.1 the matched result carries the line that was printed",
        { text = matched_text }
    )
    check(
        matched_text:find("has not exited", 1, true) == nil,
        "U1.2 a match is not a deadline: no 'has not exited' in the result",
        { text = matched_text }
    )
    step("U1 matched on READY before the process exited")

    -- U1.3 / U1.4: the exit report is a separate, later event that still fires.
    local report_needle = '<background-task id="' .. u1_id .. '"'
    local _, report_index = wait_entry(backend, report_needle, 30000, "U1 exit report")
    entries = read_session(backend.session_dir)
    check(
        report_index > matched_index,
        "U1.3 the exit report lands AFTER the matched wait result",
        { matched = matched_index, report = report_index }
    )
    local report_text = entry_text(entries[report_index])
    print("[U1 report] " .. (report_text:gsub("\n", "\\n")))
    check(
        report_text:find('status="completed"', 1, true) ~= nil,
        "U1.3 the process exited on its own: status=completed",
        { text = report_text }
    )
    check(report_text:find('exit_code="0"', 1, true) ~= nil, "U1.3 exit_code=0", { text = report_text })
    check(
        report_text:find("DONE", 1, true) ~= nil,
        "U1.3 the report carries the tail printed after the match",
        { text = report_text }
    )

    -- The exit report wakes a turn of its own; let it finish before counting.
    wait_quiet(backend, 1500, 30000, "U1 quiesce")
    entries = read_session(backend.session_dir)
    local u1_reports = entry_indices(entries, report_needle)
    check(#u1_reports == 1, "U1.4 the exit report exists exactly once", { count = #u1_reports, at = u1_reports })
    step("U1 green: one exit report, after the matched wait")

    -- ------------------------------------------------------------------
    -- U2: a needle that never appears -> the timeout, not a kill.
    -- ------------------------------------------------------------------
    provider.script = {
        function()
            return tool_response("bash", { command = U2_COMMAND, run_in_background = true })
        end,
        function(body)
            local id = last_task_id(body)
            if type(id) ~= "string" or id == u1_id then
                provider.missing_id = true
                return text_response("no new task id in the bash result")
            end
            provider.u2_id = id
            return tool_response("wait_task", { task_id = id, ["until"] = U2_NEEDLE, timeout_ms = 1200 })
        end,
    }
    -- Only events after this point count: the U1 exit report already woke (and
    -- settled) a turn of its own.
    local since2 = #backend.events
    send(backend, { id = "prompt-2", type = "prompt", message = "Start the task that never prints the needle." })
    local settled2 = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > since2
    end, 120000, "U2 run settle")
    check(settled2 ~= nil, "U2 the run settles", { stderr = backend.stderr })
    check(provider.missing_id == nil, "U2 a fresh task id was read out of the bash result")
    local u2_id = provider.u2_id
    check(type(u2_id) == "string", "U2 a background task id was captured")
    step("U2 run settled, task " .. u2_id)

    -- U2.1: the timeout result says the needle never showed up.
    local deadline_needle = "[still running] Task " .. u2_id
    entries, matched_index = wait_entry(backend, deadline_needle, 20000, "U2 timeout result")
    local deadline_text = entry_text(entries[matched_index])
    print("[U2 timeout] " .. (deadline_text:gsub("\n", "\\n")))
    check(
        deadline_text:find("[still running]", 1, true) ~= nil,
        "U2.1 the timeout is reported as 'still running', not as a result",
        { text = deadline_text }
    )
    check(
        deadline_text:find('The output never contained "' .. U2_NEEDLE .. '".', 1, true) ~= nil,
        "U2.1 the result says the output never contained the needle",
        { text = deadline_text }
    )
    step("U2 timed out on a needle that never appeared")

    -- U2.2: the timeout killed nothing — the exit report is a normal one.
    local report2_needle = '<background-task id="' .. u2_id .. '"'
    local _, report2_index = wait_entry(backend, report2_needle, 30000, "U2 exit report")
    entries = read_session(backend.session_dir)
    check(
        report2_index > matched_index,
        "U2.2 the exit report lands AFTER the timeout result",
        { timeout = matched_index, report = report2_index }
    )
    local report2_text = entry_text(entries[report2_index])
    print("[U2 report] " .. (report2_text:gsub("\n", "\\n")))
    check(
        report2_text:find('status="completed"', 1, true) ~= nil,
        "U2.2 the process was not killed: status=completed",
        { text = report2_text }
    )
    check(
        report2_text:find('exit_code="0"', 1, true) ~= nil,
        "U2.2 exit_code=0 (a kill would show a signal)",
        { text = report2_text }
    )
    check(report2_text:find('signal=""', 1, true) ~= nil, "U2.2 no signal was sent", { text = report2_text })
    check(
        report2_text:find("LATE", 1, true) ~= nil,
        "U2.2 the output printed after the timeout still reached the report",
        { text = report2_text }
    )

    wait_quiet(backend, 1500, 30000, "U2 quiesce")
    entries = read_session(backend.session_dir)
    local u2_reports = entry_indices(entries, report2_needle)
    check(#u2_reports == 1, "U2.2 the exit report exists exactly once", { count = #u2_reports, at = u2_reports })
    step("U2 green: timeout kept the process, one normal exit report")

    stop_backend(backend)

    print(
        ("ALL bg-tasks until cases passed (a match ends the wait without consuming the exit report, a missing needle times out without a kill) in %.2fs"):format(
            (uv.hrtime() - run_started) / 1e9
        )
    )
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e bg_tasks_until: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
