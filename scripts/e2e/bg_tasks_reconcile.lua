-- Headless e2e: the task table survives the process that built it (P0-1).
--
-- Two real `pi --mode rpc` runs against the SAME session (`--session-id`), each
-- with the bundled `extensions/bg-tasks.ts` and a scripted fake provider:
--
--   run A  bash(run_in_background: true) starts a shell plus a long-lived
--          grandchild, then the transcript settles. The pi process is then
--          SIGKILLed — no exit hook, so the detached process tree survives and
--          the transcript still says "running".
--   run B  starts on the same session. It must fold that transcript:
--
--   A1 the transcript holds a `pi2_bg_task` started record for the task, owned
--      by this session, with no terminal record after it
--   A2 the orphan tree (shell + grandchild) is alive after the kill — the
--      thing the snapshot is supposed to describe
--   A3 run B's FIRST provider request already carries the leftover summary,
--      naming the task and saying it is still running
--   A4 list_tasks sees it, marked as adopted from an earlier pi process
--   A5 stop_task works on it: the whole group dies
--   A6 the exit the stop causes is carried by its own tool result — no wake
--      report for an adopted task
--   A7 the summary is delivered exactly once (not echoed per request), the
--      transcript ends up recording the stop, and NOTHING is written to tmpdir
--
-- Needs the pi binary, nothing else (the provider is fake). NOT part of
-- `make test`/CI:
--
--   make e2e-bg-reconcile
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_reconcile.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-reconcile"

local PROVIDER = "e2ereconcile"
local MODEL_ID = "e2e-model"
local SESSION_ID = ("e2e-bg-reconcile-%d"):format(uv.hrtime() % 1000000)

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
---@return integer?
local function read_pid(path)
    local text = read_file(path)
    if not text then
        return nil
    end
    return tonumber((text:gsub("%s+", "")))
end

--- Whether a pid is still in the process table (`ps` rather than kill(0): a
--- reaped-then-reused pid must not read as alive).
---@param pid integer?
---@return boolean
local function alive(pid)
    if type(pid) ~= "number" or pid <= 1 then
        return false
    end
    local out = vim.fn.system({ "ps", "-p", tostring(pid), "-o", "pid=" })
    return vim.trim(out or "") ~= ""
end

---@param pid integer
---@return integer?
local function parent_of(pid)
    local out = vim.fn.system({ "ps", "-p", tostring(pid), "-o", "ppid=" })
    return tonumber(vim.trim(out or ""))
end

--- One row of a reconcile summary, cut at the end of that row.
---
--- The provider body is JSON, so the line breaks inside the summary are the two
--- characters `\n`; cutting there keeps an assertion about one task from
--- matching text that belongs to another. A bare id is not enough to find the
--- row either — the same transcript is replayed into the request, so the id also
--- appears in the replayed messages.
---@param text string
---@param id string
---@return string
local function summary_row(text, id)
    local at = text:find("- " .. id .. " ", 1, true)
    if at == nil then
        return ""
    end
    local stop = text:find("\\n", at, true) or (#text + 1)
    return text:sub(at, stop - 1)
end

-- ---------------------------------------------------------------------------
-- Scripted fake provider (OpenAI chat-completions, streamed).
-- ---------------------------------------------------------------------------

---@class ReconcileE2EProvider
---@field server uv.uv_tcp_t
---@field phase "A"|"B" which run is being answered
---@field turn integer requests answered in this phase
---@field bodies string[] request body per answered request, in order
---@field gc_path string file the background shell writes its child pid to
---@field task_id string? task id captured during phase A
---@field grandchild integer? child pid observed in phase A
---@field shell integer? the task shell's pid (parent of the grandchild)
---@field grandchild_alive boolean? the grandchild was alive after the SIGKILL
---@field missing_task_id boolean? set when a body carried no task id

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
local function text_turn(text)
    return sse_headers()
        .. sse_chunk(('{"role":"assistant","content":%s}'):format(vim.json.encode(text)))
        .. sse_chunk("{}", "stop")
        .. "data: [DONE]\n\n"
end

---@param tool string
---@param args table
---@return string
local function tool_turn(tool, args)
    return sse_headers()
        .. sse_chunk('{"role":"assistant","content":""}')
        .. tool_call_chunk(tool, args)
        .. sse_chunk("{}", "tool_calls")
        .. "data: [DONE]\n\n"
end

---@param provider ReconcileE2EProvider
---@return string
local function respond(provider)
    provider.turn = provider.turn + 1
    local turn = provider.turn
    local body = provider.bodies[#provider.bodies] or ""

    if provider.phase == "A" then
        if turn == 1 then
            local command = ("sh -c 'sleep 900 & echo $! > %s; sleep 900'"):format(provider.gc_path)
            return tool_turn("bash", { command = command, run_in_background = true })
        end
        -- T2: the bash result is in this request; record the id and the live
        -- tree, then end the turn so the run settles with the task running.
        local task_id = body:match("Task (b%x%x%x%x%x%x%x?) running in background")
        if type(task_id) ~= "string" then
            provider.missing_task_id = true
            return text_turn("no task id in the bash result")
        end
        provider.task_id = task_id
        vim.wait(5000, function()
            provider.grandchild = read_pid(provider.gc_path)
            return provider.grandchild ~= nil
        end, 20)
        if provider.grandchild then
            provider.shell = parent_of(provider.grandchild)
        end
        return text_turn("Backgrounded, waiting for the report.")
    end

    -- phase B: the first request already carries the reconcile summary.
    if turn == 1 then
        local task_id = provider.task_id or body:match("(b%x%x%x%x%x%x%x?)")
        if type(task_id) == "string" then
            provider.task_id = task_id
        end
        return tool_turn("list_tasks", { include_finished = true })
    end
    if turn == 2 then
        local task_id = body:match("%-%s*(b%x%x%x%x%x%x%x?) %[running %(adopted")
            or body:match("(b%x%x%x%x%x%x%x%)")
            or provider.task_id
        if type(task_id) ~= "string" then
            provider.missing_task_id = true
            return text_turn("no task id for the adopted task")
        end
        provider.task_id = task_id
        return tool_turn("stop_task", { task_id = task_id })
    end
    return text_turn("Cleaned up.")
end

---@param gc_path string
---@return ReconcileE2EProvider
local function start_fake_provider(gc_path)
    ---@type ReconcileE2EProvider
    local provider = { phase = "A", turn = 0, bodies = {}, gc_path = gc_path }
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
            -- `respond` waits for the real process tree to appear, and vim.wait
            -- is not allowed in a libuv callback (fast event context).
            vim.schedule(function()
                provider.bodies[#provider.bodies + 1] = body
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
                name = "E2EReconcile",
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

---@class ReconcileE2EBackend
---@field job integer
---@field session_dir string
---@field events table[]
---@field stderr string

---@param session_dir string
---@param cwd string
---@param session_id string
---@return ReconcileE2EBackend
local function start_backend(session_dir, cwd, session_id)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type ReconcileE2EBackend
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
        "--session-id",
        session_id,
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

---@param backend ReconcileE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend ReconcileE2EBackend
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

---@param backend ReconcileE2EBackend
local function pin_model(backend)
    send(backend, { id = "model-1", type = "set_model", provider = PROVIDER, modelId = MODEL_ID })
    local pinned = wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, "set_model")
    check(
        pinned ~= nil and pinned.success ~= false,
        "fake model selected",
        { pinned = pinned, stderr = backend.stderr }
    )
end

---@param backend ReconcileE2EBackend
local function run_prompt(backend, message, timeout_ms)
    local since = #backend.events
    send(backend, { id = "prompt-" .. tostring(since), type = "prompt", message = message })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > since
    end, timeout_ms, "agent_settled")
    check(settled ~= nil, "the scripted run settles", { stderr = backend.stderr })
end

---@param backend ReconcileE2EBackend
local function stop_backend(backend)
    pcall(vim.fn.chanclose, backend.job, "stdin")
    pcall(vim.fn.jobstop, backend.job)
    pcall(vim.fn.jobwait, { backend.job }, 5000)
end

--- Read the session transcript (the JSONL is ground truth).
---@param session_dir string
---@return string
local function transcript(session_dir)
    local names = vim.fn.readdir(session_dir)
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do
        if name:match("%.jsonl$") then
            out[#out + 1] = read_file(session_dir .. "/" .. name) or ""
        end
    end
    return table.concat(out, "\n")
end

--- The single session file a run left in its session dir.
---@param session_dir string
---@return string
local function session_file(session_dir)
    for _, name in ipairs(vim.fn.readdir(session_dir)) do
        if name:match("%.jsonl$") then
            return session_dir .. "/" .. name
        end
    end
    error("no session file in " .. session_dir, 0)
end

--- Append one entry to a session file the way pi would (chained to the last id).
---@param path string
---@param entry table
local function append_session_entry(path, entry)
    local body = read_file(path) or ""
    local last_id = ""
    for line in body:gmatch("[^\n]+") do
        local ok, decoded = pcall(vim.json.decode, line)
        if ok and type(decoded) == "table" and type(decoded.id) == "string" then
            last_id = decoded.id
        end
    end
    entry.id = entry.id or ("e2e" .. tostring(uv.hrtime()):sub(-8))
    entry.parentId = last_id ~= "" and last_id or nil
    entry.timestamp = entry.timestamp or os.date("!%Y-%m-%dT%H:%M:%S.000Z")
    local f = assert(io.open(path, "a"))
    f:write(vim.json.encode(entry) .. "\n")
    f:close()
end

-- ---------------------------------------------------------------------------

local function main()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(RUN_ROOT, "p")
    local agent_dir = RUN_ROOT .. "/agent"
    local gc_path = RUN_ROOT .. "/grandchild.pid"
    local session_dir = RUN_ROOT .. "/sessions"
    local cwd = RUN_ROOT .. "/cwd"

    -- The child pi inherits this env; nothing touches the user's real config.
    vim.env.PI_CODING_AGENT_DIR = agent_dir
    vim.env.PI_OFFLINE = "1"

    local STRAY_BEFORE = 0
    for _, name in ipairs(vim.fn.readdir(uv.os_tmpdir())) do
        if name:match("^pi%-bash%-tasks%-.*%.json$") then
            STRAY_BEFORE = STRAY_BEFORE + 1
        end
    end

    local provider = start_fake_provider(gc_path)
    local addr = provider.server:getsockname()
    local port = type(addr) == "table" and addr.port or nil
    check(type(port) == "number" and port > 0, "fake provider did not bind a port", { addr = addr })
    write_agent_dir(agent_dir, port)
    step(("fake provider on 127.0.0.1:%d"):format(port))

    -- ---------------- run A: start a task, then die without a shutdown -----
    local backend_a = start_backend(session_dir, cwd, SESSION_ID)
    pin_model(backend_a)
    run_prompt(backend_a, "Start the server in the background.", 180000)
    check(provider.turn == 2, "run A ran its two scripted turns", { turn = provider.turn })
    check(provider.missing_task_id == nil, "the bash result carried the task id", { turn = provider.turn })
    check(type(provider.grandchild) == "number", "the background command reported a grandchild pid")
    step(
        ("run A started task %s (shell %s, grandchild %s)"):format(
            tostring(provider.task_id),
            tostring(provider.shell),
            tostring(provider.grandchild)
        )
    )

    local sfile = session_file(session_dir)
    local sbody = read_file(sfile) or ""
    check(
        sbody:find('"customType":"pi2_bg_task"', 1, true) ~= nil,
        "A1 the transcript carries a bg-task record",
        { path = sfile }
    )
    check(
        sbody:find('"taskId":"' .. (provider.task_id or "") .. '"', 1, true) ~= nil,
        "A1 the transcript records the task",
        { path = sfile }
    )
    check(
        sbody:find('"sessionId":"' .. SESSION_ID .. '"', 1, true) ~= nil,
        "A1 the record names its owning session",
        { body = sbody:sub(1, 800) }
    )
    check(
        sbody:find('"kind":"stopped"', 1, true) == nil and sbody:find('"kind":"completed"', 1, true) == nil,
        "A1 no terminal record yet: the task is still running",
        { path = sfile }
    )
    step("A1 transcript " .. vim.fn.fnamemodify(sfile, ":t"))

    -- SIGKILL: no exit hook, no session_shutdown, no graceful anything. The
    -- detached process tree is exactly what a crash leaves behind.
    local pid = vim.fn.jobpid(backend_a.job)
    check(type(pid) == "number" and pid > 1, "run A has a pid")
    pcall(uv.kill, pid, "sigkill")
    pcall(vim.fn.chanclose, backend_a.job, "stdin")
    pcall(vim.fn.jobwait, { backend_a.job }, 10000)
    vim.wait(5000, function()
        return not alive(pid)
    end, 50)
    check(not alive(pid), "run A's pi process is gone", { pid = pid })
    check(alive(provider.grandchild), "A2 the orphan grandchild survived the SIGKILL", {
        grandchild = provider.grandchild,
    })
    check(alive(provider.shell), "A2 the orphan shell survived the SIGKILL", { shell = provider.shell })

    -- The orphan has to outlive the run that started it for a moment: a task
    -- that dies with pi is not something reconcile ever sees.
    vim.wait(2000, function()
        return false
    end, 200)
    check(alive(provider.grandchild), "A2 the orphan grandchild is still there when the next process starts", {
        grandchild = provider.grandchild,
    })
    check(alive(provider.shell), "A2 the orphan shell is still there when the next process starts", {
        shell = provider.shell,
    })
    step("A2 orphan tree survived the SIGKILL (pi pid " .. tostring(pid) .. ")")

    -- A8 setup: a transcript record with a LIVE pid that is not ours — this
    -- e2e's own nvim. A recycled pid must not be adopted, waited on or
    -- signalled; the transcript is history, not an authority on pid ownership.
    local ghost_id = "bdead01"
    local ghost_pid = vim.fn.getpid()
    local sid = sbody:match('"sessionId":"([^"]+)"') or SESSION_ID
    append_session_entry(sfile, {
        type = "custom_message",
        customType = "pi2_bg_task",
        content = "[Background task " .. ghost_id .. " started]",
        display = false,
        details = {
            kind = "started",
            taskId = ghost_id,
            command = "npm run ghost",
            pid = ghost_pid,
            outputFile = uv.os_tmpdir() .. "/pi-bash-" .. ghost_id .. ".log",
            startedAt = os.time() * 1000,
            sessionId = sid,
        },
    })
    step(("A8 forged record %s -> nvim pid %d"):format(ghost_id, ghost_pid))

    -- A8b setup: the same live pid, but with a command line that MATCHES and a
    -- start-time fingerprint that does not. That is the shape a recycled pid
    -- has — the text is a coincidence, the identity is wrong. The old
    -- command-line heuristic adopted this; identity has to be the fingerprint.
    local ghost2_id = "bdead02"
    local ghost2_command = (vim.fn.system({ "ps", "-o", "command=", "-p", tostring(ghost_pid) }) or ""):gsub("%s+$", "")
    append_session_entry(sfile, {
        type = "custom_message",
        customType = "pi2_bg_task",
        content = "[Background task " .. ghost2_id .. " started]",
        display = false,
        details = {
            kind = "started",
            taskId = ghost2_id,
            command = ghost2_command ~= "" and ghost2_command or "nvim --headless",
            pid = ghost_pid,
            pidStartTime = "0", -- deliberately not the live process's start time
            outputFile = uv.os_tmpdir() .. "/pi-bash-" .. ghost2_id .. ".log",
            startedAt = os.time() * 1000,
            sessionId = sid,
        },
    })
    step(("A8b forged record %s -> nvim pid %d with a stale fingerprint"):format(ghost2_id, ghost_pid))

    -- ---------------- run B: same session, folding that transcript ----------
    provider.phase = "B"
    provider.turn = 0
    local bodies_before = #provider.bodies
    local backend_b = start_backend(session_dir, cwd, SESSION_ID)
    pin_model(backend_b)
    run_prompt(backend_b, "What is still running from before?", 180000)
    check(provider.turn == 3, "run B ran its three scripted turns", { turn = provider.turn })
    check(provider.missing_task_id == nil, "run B found the adopted task id", { turn = provider.turn })

    -- A3: the summary is in the FIRST request of the new process. Everything
    -- below is asserted against the summary section alone: the transcript is
    -- replayed into this request, so a bare id would also match a replayed
    -- message and pass for the wrong reason.
    local first_body = provider.bodies[bodies_before + 1] or ""
    local summary_at = first_body:find("[Background bash tasks found in this session's transcript", 1, true)
    check(summary_at ~= nil, "A3 run B's first request carries the reconcile summary", {
        head = first_body:sub(1, 300),
    })
    local summary = first_body:sub(summary_at)
    check(
        summary:find(provider.task_id or "", 1, true) ~= nil,
        "A3 the summary names the leftover task",
        { id = provider.task_id }
    )
    check(
        summary:find("STILL RUNNING", 1, true) ~= nil,
        "A3 the summary says the task is still running",
        { summary = summary:sub(1, 600), stderr = backend_b.stderr:sub(1, 600) }
    )
    step("A3 summary reached the model on the first request")

    -- A8: the live-but-unrelated pid was NOT adopted, and the summary says so.
    local ghost_row = summary_row(summary, ghost_id)
    check(ghost_row ~= "", "A8 the summary mentions the unverifiable record", { summary = summary:sub(1, 400) })
    check(
        ghost_row:find("no longer runs it", 1, true) ~= nil,
        "A8 a live pid running a different command is not adopted",
        { row = ghost_row }
    )
    check(alive(ghost_pid), "A8 the unrelated process was left alone", { pid = ghost_pid })
    step("A8 unverifiable record refused, nvim untouched")

    -- A8b: a MATCHING command line with a WRONG start time is still refused —
    -- the fingerprint, not the text, is what proves identity.
    local ghost2_row = summary_row(summary, ghost2_id)
    check(ghost2_row ~= "", "A8b the summary lists the stale-fingerprint record", { summary = summary:sub(1, 400) })
    check(
        ghost2_row:find("no longer runs it", 1, true) ~= nil,
        "A8b a matching command line does not make a recycled pid adoptable",
        { row = ghost2_row }
    )

    -- A4: list_tasks reports it as adopted rather than as a task of this process.
    local second_body = provider.bodies[bodies_before + 2] or ""
    check(
        second_body:find(ghost_id .. " [is no longer running", 1, true) ~= nil,
        "A8 list_tasks reports the unverifiable record as unknown, not running",
        { stderr = backend_b.stderr:sub(1, 600) }
    )
    check(
        second_body:find("running (adopted from an earlier pi process)", 1, true) ~= nil,
        "A4 list_tasks marks the adopted task",
        { stderr = backend_b.stderr:sub(1, 600) }
    )
    step("A4 list_tasks shows the adopted task")

    -- A5: the stop works across the process boundary, on the whole group.
    check(
        vim.wait(5000, function()
            return not alive(provider.grandchild)
        end, 50),
        "A5 stop_task killed the orphaned grandchild",
        { grandchild = provider.grandchild }
    )
    check(not alive(provider.shell), "A5 stop_task killed the orphaned shell", { shell = provider.shell })

    local text = transcript(session_dir)
    check(#text > 0, "the session transcript exists", { dir = session_dir })
    check(text:find("was stopped (signal SIGTERM)", 1, true) ~= nil, "A5 stop_task reported the signal stop")
    check(
        text:find("running (adopted from an earlier pi process)", 1, true) ~= nil,
        "A4 the adopted marker is in the transcript"
    )

    -- A6: the stop's own result carried the exit, so no wake report followed.
    -- The panel notification (`[Background task <id> started]`) is a separate,
    -- pre-existing message and is not what this looks for: the wake note reads
    -- `[Background task <id> ("<command>") …`, a batch reads `[Background tasks: `.
    for index = bodies_before + 2, #provider.bodies do
        local body = provider.bodies[index] or ""
        check(
            body:find("[Background task " .. (provider.task_id or "") .. ' ("', 1, true) == nil,
            "A6 an adopted task stopped by stop_task must not also produce a wake report",
            { index = index }
        )
        check(
            body:find("[Background tasks: ", 1, true) == nil,
            "A6 a batched wake report must not follow a stop either",
            { index = index }
        )
    end

    -- A7: delivered once, and the snapshot ends up terminal.
    local first = text:find("[Background bash tasks found in this session's transcript", 1, true)
    check(first ~= nil, "A3 the summary is in the transcript")
    check(
        text:find("[Background bash tasks found in this session's transcript", first + 1, true) == nil,
        "A7 the summary is delivered exactly once"
    )
    check(
        (read_file(sfile) or ""):find('"kind":"stopped"', 1, true) ~= nil,
        "A7 the transcript records the stop",
        { path = sfile }
    )
    -- The whole point of the fold: there is no sidecar to go stale.
    local stray = {}
    for _, name in ipairs(vim.fn.readdir(uv.os_tmpdir())) do
        if name:match("^pi%-bash%-tasks%-.*%.json$") then
            stray[#stray + 1] = name
        end
    end
    check(
        #stray <= STRAY_BEFORE,
        "A7 no new task snapshot may be written to tmpdir",
        { count = #stray, before = STRAY_BEFORE }
    )
    step("A5/A6/A7 stop, no wake, single summary")

    stop_backend(backend_b)

    print(
        ("ALL bg-tasks reconcile cases passed (transcript fold, SIGKILL orphan, adoption, stop across processes) in %.2fs"):format(
            (uv.hrtime() - run_started) / 1e9
        )
    )
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e bg_tasks_reconcile: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
