-- Headless e2e: task OWNERSHIP across sessions (fork) and across a clean quit.
--
-- The task table is folded from the session transcript, and pi copies every
-- entry when a session is forked. Without an ownership rule, the fork would
-- adopt the parent's still-running task: one exit reported twice, and a
-- `stop_task` in the fork signalling a process the parent is watching. The rule
-- is the session id that PRODUCED the record, never the pid.
--
-- Two independent scenarios, each with a real `pi --mode rpc` child and a
-- scripted fake provider:
--
--   S2 fork       run A starts a background task, then is SIGKILLed (orphan
--                 survives, transcript still says "running"). A fork of that
--                 session must FIND the record, must NOT adopt it, must refuse
--                 to stop it, must not list it as running, and must leave the
--                 orphan alive.
--   S3 clean quit run C starts a task and gets SIGTERM. `session_shutdown`
--                 records the ids it killed, so the next run on that session
--                 reads `stopped (SIGKILL)` instead of guessing — and does not
--                 adopt a corpse.
--
-- Assertions are behavioural:
--   B1 the fork's first request carries the summary naming the owning session
--   B2 the fork's `list_tasks` (default) shows no running task; with
--      include_finished it shows the record as "running elsewhere"
--   B3 `stop_task` from the fork is refused, and no wake report follows
--   B4 the orphan is STILL ALIVE after the fork's run (nothing was signalled)
--   B5 a clean quit appends the shutdown record with the killed task ids
--   B6 the next run on that session does not adopt it and reports the stop
--
-- Needs the pi binary, nothing else (the provider is fake), which is why it runs
-- in CI (.github/workflows/e2e.yml). Not part of `make test`:
--
--   make e2e-bg-ownership
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_ownership.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-ownership"

local PROVIDER = "e2eowner"
local MODEL_ID = "e2e-model"
local RUN_ID = tostring(uv.hrtime() % 1000000)
local SESSION_A = "e2e-own-a-" .. RUN_ID
local SESSION_C = "e2e-own-c-" .. RUN_ID

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

---@param pid integer?
---@return boolean
local function alive(pid)
    if type(pid) ~= "number" or pid <= 1 then
        return false
    end
    local out = vim.fn.system({ "ps", "-p", tostring(pid), "-o", "pid=" })
    return vim.trim(out or "") ~= ""
end

-- ---------------------------------------------------------------------------
-- Scripted fake provider (OpenAI chat-completions, streamed).
-- ---------------------------------------------------------------------------

---@class OwnershipE2EProvider
---@field server uv.uv_tcp_t
---@field phase "A"|"F"|"C"|"D"
---@field turn integer
---@field bodies string[] request body per answered request, in this phase
---@field gc_path string
---@field pid_path string
---@field task_id string? task started by phase A (or C)
---@field missing_id boolean?

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

---@param provider OwnershipE2EProvider
---@return string
local function respond(provider)
    provider.turn = provider.turn + 1
    local turn = provider.turn
    local body = provider.bodies[#provider.bodies] or ""

    if provider.phase == "A" or provider.phase == "C" then
        if turn == 1 then
            local command = ("sh -c 'echo $$ > %s; sleep 300'"):format(provider.pid_path)
            return tool_turn("bash", { command = command, run_in_background = true })
        end
        local id = body:match("Task (b%x%x%x%x%x%x%x?) running in background")
        if type(id) ~= "string" then
            provider.missing_id = true
            return text_turn("no task id in the bash result")
        end
        provider.task_id = id
        return text_turn("Backgrounded.")
    end

    if provider.phase == "F" then
        if turn == 1 then
            return tool_turn("list_tasks", vim.empty_dict())
        end
        if turn == 2 then
            return tool_turn("list_tasks", { include_finished = true })
        end
        if turn == 3 then
            return tool_turn("stop_task", { task_id = provider.task_id or "unknown" })
        end
        return text_turn("Checked.")
    end

    -- phase D: the session after a clean quit.
    if turn == 1 then
        return tool_turn("list_tasks", { include_finished = true })
    end
    return text_turn("Nothing to do.")
end

---@param pid_path string
---@return OwnershipE2EProvider
local function start_fake_provider(pid_path)
    ---@type OwnershipE2EProvider
    local provider = { phase = "A", turn = 0, bodies = {}, gc_path = "", pid_path = pid_path }
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

---@param agent_dir string
---@param port integer
local function write_agent_dir(agent_dir, port)
    vim.fn.mkdir(agent_dir, "p")
    local models = {
        providers = {
            [PROVIDER] = {
                name = "E2EOwnership",
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

---@class OwnershipE2EBackend
---@field job integer
---@field session_dir string
---@field events table[]
---@field stderr string

---@param session_dir string
---@param cwd string
---@param extra string[] extra CLI flags (e.g. --session-id, --fork)
---@return OwnershipE2EBackend
local function start_backend(session_dir, cwd, extra)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type OwnershipE2EBackend
    local backend = { job = 0, session_dir = session_dir, events = {}, stderr = "" }
    local argv = {
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
    }
    for _, item in ipairs(extra) do
        argv[#argv + 1] = item
    end
    local partial = { out = "" }
    backend.job = vim.fn.jobstart(argv, {
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

---@param backend OwnershipE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend OwnershipE2EBackend
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

---@param backend OwnershipE2EBackend
local function pin_model(backend)
    send(backend, { id = "model-1", type = "set_model", provider = PROVIDER, modelId = MODEL_ID })
    local pinned = wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, "set_model")
    check(pinned ~= nil and pinned.success ~= false, "fake model selected", { stderr = backend.stderr })
end

---@param backend OwnershipE2EBackend
---@param message string
---@param timeout_ms integer
local function run_prompt(backend, message, timeout_ms)
    local since = #backend.events
    send(backend, { id = "prompt-" .. tostring(since), type = "prompt", message = message })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > since
    end, timeout_ms, "agent_settled")
    check(settled ~= nil, "the scripted run settles", { stderr = backend.stderr })
end

---@param backend OwnershipE2EBackend
local function stop_backend(backend)
    pcall(vim.fn.chanclose, backend.job, "stdin")
    pcall(vim.fn.jobstop, backend.job)
    pcall(vim.fn.jobwait, { backend.job }, 5000)
end

---@param dir string
---@return string
local function session_file(dir)
    for _, name in ipairs(vim.fn.readdir(dir)) do
        if name:match("%.jsonl$") then
            return dir .. "/" .. name
        end
    end
    error("no session file in " .. dir, 0)
end

---@param dir string
---@return string
local function transcript(dir)
    local names = vim.fn.readdir(dir)
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do
        if name:match("%.jsonl$") then
            out[#out + 1] = read_file(dir .. "/" .. name) or ""
        end
    end
    return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------

local function main()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(RUN_ROOT, "p")
    local agent_dir = RUN_ROOT .. "/agent"
    local pid_path = RUN_ROOT .. "/task.pid"
    local session_dir = RUN_ROOT .. "/sessions"
    local cwd = RUN_ROOT .. "/cwd"

    vim.env.PI_CODING_AGENT_DIR = agent_dir
    vim.env.PI_OFFLINE = "1"

    local provider = start_fake_provider(pid_path)
    local addr = provider.server:getsockname()
    local port = type(addr) == "table" and addr.port or nil
    check(type(port) == "number" and port > 0, "fake provider did not bind a port", { addr = addr })
    write_agent_dir(agent_dir, port)
    step(("fake provider on 127.0.0.1:%d"):format(port))

    -- ================= S2: a fork must not adopt the parent's task =========
    provider.phase = "A"
    provider.turn = 0
    local backend_a = start_backend(session_dir, cwd, { "--session-id", SESSION_A })
    pin_model(backend_a)
    run_prompt(backend_a, "Start the server.", 180000)
    check(provider.missing_id == nil, "phase A got the task id", { turn = provider.turn })
    vim.wait(3000, function()
        return read_pid(pid_path) ~= nil
    end, 20)
    local task_pid = read_pid(pid_path)
    check(type(task_pid) == "number", "the task reported its pid", { file = read_file(pid_path) })
    local a_file = session_file(session_dir)
    step(("S2 run A started task %s (pid %d)"):format(tostring(provider.task_id), task_pid))

    -- SIGKILL: the orphan survives, the transcript still says "running".
    local api_pid = vim.fn.jobpid(backend_a.job)
    pcall(uv.kill, api_pid, "sigkill")
    pcall(vim.fn.chanclose, backend_a.job, "stdin")
    pcall(vim.fn.jobwait, { backend_a.job }, 10000)
    vim.wait(5000, function()
        return not alive(api_pid)
    end, 50)
    check(not alive(api_pid), "run A's pi process is gone", { pid = api_pid })
    vim.wait(1500, function()
        return false
    end, 150)
    check(alive(task_pid), "S2 the orphan task is alive before the fork", { pid = task_pid })
    check(
        (read_file(a_file) or ""):find('"sessionId":"' .. SESSION_A .. '"', 1, true) ~= nil,
        "S2 the parent transcript records the owner",
        { path = a_file }
    )

    provider.phase = "F"
    provider.turn = 0
    local f_base = #provider.bodies
    local backend_f = start_backend(session_dir, cwd, { "--fork", a_file })
    pin_model(backend_f)
    run_prompt(backend_f, "What is still running?", 180000)
    check(provider.turn == 4, "S2 the fork ran its four scripted turns", { turn = provider.turn })

    local first = provider.bodies[f_base + 1] or ""
    check(
        first:find("belongs to session", 1, true) ~= nil,
        "B1 the fork's summary names the owning session",
        { stderr = backend_f.stderr:sub(1, 600) }
    )
    check(
        first:find(provider.task_id or "", 1, true) ~= nil,
        "B1 the summary names the leftover task",
        { stderr = backend_f.stderr:sub(1, 600) }
    )
    local empty_list = provider.bodies[f_base + 2] or ""
    check(
        empty_list:find("No running background tasks in this session.", 1, true) ~= nil,
        "B2 list_tasks (default) must not show a task owned elsewhere",
        { stderr = backend_f.stderr:sub(1, 600) }
    )
    local full_list = provider.bodies[f_base + 3] or ""
    check(
        full_list:find("running elsewhere (session ", 1, true) ~= nil,
        "B2 list_tasks (include_finished) marks it as running elsewhere",
        { stderr = backend_f.stderr:sub(1, 600) }
    )
    local refused = provider.bodies[f_base + 4] or ""
    check(
        refused:find("is not this session's to control", 1, true) ~= nil,
        "B3 stop_task from the fork is refused",
        { stderr = backend_f.stderr:sub(1, 600) }
    )
    for index = f_base + 2, #provider.bodies do
        check(
            (provider.bodies[index] or ""):find("[Background task " .. (provider.task_id or "") .. ' ("', 1, true)
                == nil,
            "B3 a foreign task must never produce a wake report",
            { index = index }
        )
    end
    check(alive(task_pid), "B4 the orphan was never signalled by the fork", { pid = task_pid })
    step("S2/B1-B4 fork: found, not adopted, refused, orphan untouched")
    stop_backend(backend_f)

    -- clean up the orphan the fork refused to touch
    pcall(uv.kill, task_pid, "sigkill")
    vim.wait(5000, function()
        return not alive(task_pid)
    end, 50)

    -- ================= S3: a clean quit records what it killed =============
    provider.phase = "C"
    provider.turn = 0
    provider.task_id = nil
    pcall(os.remove, pid_path)
    local backend_c = start_backend(session_dir, cwd, { "--session-id", SESSION_C })
    pin_model(backend_c)
    run_prompt(backend_c, "Start another server.", 180000)
    check(provider.missing_id == nil, "phase C got the task id", { turn = provider.turn })
    vim.wait(3000, function()
        return read_pid(pid_path) ~= nil
    end, 20)
    local c_pid = read_pid(pid_path)
    local c_task = provider.task_id
    check(type(c_pid) == "number" and type(c_task) == "string", "S3 the task reported its pid")
    step(("S3 run C started task %s (pid %d)"):format(c_task, c_pid))

    -- SIGTERM: a graceful shutdown, which is what `session_shutdown` sees.
    local c_pi = vim.fn.jobpid(backend_c.job)
    pcall(uv.kill, c_pi, "sigterm")
    pcall(vim.fn.jobwait, { backend_c.job }, 15000)
    vim.wait(5000, function()
        return not alive(c_pi)
    end, 50)
    check(not alive(c_pi), "S3 the quitted pi process is gone", { pid = c_pi })
    vim.wait(5000, function()
        return not alive(c_pid)
    end, 50)
    check(not alive(c_pid), "S3 the exit hook killed the task", { pid = c_pid })

    local c_file = session_file(session_dir)
    -- session_file() may pick either session; find the one with the shutdown mark
    for _, name in ipairs(vim.fn.readdir(session_dir)) do
        if name:match("%.jsonl$") then
            local body = read_file(session_dir .. "/" .. name) or ""
            if body:find('"customType":"pi2_bg_task_shutdown"', 1, true) ~= nil then
                c_file = session_dir .. "/" .. name
            end
        end
    end
    local c_body = read_file(c_file) or ""
    check(
        c_body:find('"customType":"pi2_bg_task_shutdown"', 1, true) ~= nil,
        "B5 a clean quit appends the shutdown record",
        { path = c_file, tail = c_body:sub(-800) }
    )
    check(
        c_body:find('"taskIds":["' .. c_task .. '"]', 1, true) ~= nil,
        "B5 the shutdown record names the killed task",
        { tail = c_body:sub(-800) }
    )
    step("S3/B5 shutdown record appended with the killed task id")

    provider.phase = "D"
    provider.turn = 0
    local d_base = #provider.bodies
    local backend_d = start_backend(session_dir, cwd, { "--session-id", SESSION_C })
    pin_model(backend_d)
    run_prompt(backend_d, "What happened to it?", 180000)
    local d_first = provider.bodies[d_base + 1] or ""
    check(
        d_first:find("STILL RUNNING", 1, true) == nil,
        "B6 the next run must not adopt the killed task",
        { stderr = backend_d.stderr:sub(1, 600) }
    )
    local d_list = provider.bodies[d_base + 2] or ""
    check(
        d_list:find("was stopped (signal SIGKILL)", 1, true) ~= nil,
        "B6 the folded record says it was stopped",
        { stderr = backend_d.stderr:sub(1, 600) }
    )
    step("S3/B6 the killed task is terminal, not adopted")
    stop_backend(backend_d)

    print(
        ("ALL bg-tasks ownership cases passed (fork does not adopt, clean quit records its kills) in %.2fs"):format(
            (uv.hrtime() - run_started) / 1e9
        )
    )
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e bg_tasks_ownership: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
