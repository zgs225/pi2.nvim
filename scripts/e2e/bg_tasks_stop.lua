-- Headless e2e: `stop_task` / `list_tasks` — the model-side control of
-- background bash tasks.
--
-- Drives the REAL stack: a `pi --mode rpc` child with the bundled
-- `extensions/bg-tasks.ts`, a scripted fake OpenAI-compatible provider on
-- 127.0.0.1 (no account, no network, no real model) and a REAL process tree —
-- a shell plus a long-lived grandchild, which is the `npm run dev` shape a
-- pid-only kill leaks.
--
-- Scripted turns:
--   T1  bash(run_in_background: true) -> `sh -c 'sleep 600 & echo $! > gc.pid; sleep 600'`
--   T2  stop_task(<id from T1's result>)   (the fake provider finds the id in
--                                          the tool result it receives back)
--   T3  list_tasks({ include_finished: true })
--   T4  "done"
--
-- Assertions, all behavioural:
--   A1 the grandchild (and its shell) are alive while the task runs
--   A2 stop_task's own tool result reports the signal stop
--   A3 the shell AND the grandchild are gone after the stop — the regression
--      a bare-pid signal leaves behind
--   A4 NO wake report was delivered: the stop's tool result carried the
--      terminal state (the observer lease), so `[SYSTEM NOTIFICATION ...]`
--      never appears in the transcript
--   A5 list_tasks(include_finished: true) still knows the stopped task
--
-- Needs the pi binary, nothing else (the provider is fake), which is why it runs
-- in CI (.github/workflows/e2e.yml). Not part of `make test`:
--
--   make e2e-bg-stop
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_stop.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-stop"

local PROVIDER = "e2estop"
local MODEL_ID = "e2e-model"

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

--- Parent pid of a live process.
---@param pid integer
---@return integer?
local function parent_of(pid)
    local out = vim.fn.system({ "ps", "-p", tostring(pid), "-o", "ppid=" })
    return tonumber(vim.trim(out or ""))
end

-- ---------------------------------------------------------------------------
-- Scripted fake provider (OpenAI chat-completions, streamed).
-- ---------------------------------------------------------------------------

---@class StopE2EProvider
---@field server? uv.uv_tcp_t
---@field turn integer requests answered so far
---@field bodies string[] request body per turn
---@field gc_path string file the background shell writes its child pid to
---@field grandchild integer? child pid observed while the task ran
---@field shell integer? the task shell's pid (parent of the grandchild)
---@field grandchild_alive boolean? the grandchild was in the process table at stop time
---@field shell_alive boolean? the shell was in the process table at stop time
---@field task_id string? the task id read out of the bash tool result
---@field missing_task_id boolean? set when the bash result carried no task id

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

---@param provider StopE2EProvider
---@return string
local function respond(provider)
    provider.turn = provider.turn + 1
    local turn = provider.turn

    if turn == 1 then
        local command = ("sh -c 'sleep 600 & echo $! > %s; sleep 600'"):format(provider.gc_path)
        return sse_headers()
            .. sse_chunk('{"role":"assistant","content":""}')
            .. tool_call_chunk("bash", { command = command, run_in_background = true })
            .. sse_chunk("{}", "tool_calls")
            .. "data: [DONE]\n\n"
    end

    if turn == 2 then
        -- The tool result for T1 is in the body we were just handed: read the
        -- task id out of it, the way a real model reads it out of its context.
        local body = provider.bodies[turn] or ""
        local task_id = body:match("Task (b%x%x%x%x%x%x%x?) running in background")
        if type(task_id) ~= "string" then
            -- Fail fast instead of hanging the run: main asserts on this flag.
            provider.missing_task_id = true
            return sse_headers()
                .. sse_chunk('{"role":"assistant","content":"no task id in the bash result"}')
                .. sse_chunk("{}", "stop")
                .. "data: [DONE]\n\n"
        end
        provider.task_id = task_id
        -- Give the real shell a moment to write its child's pid, then prove the
        -- whole tree is alive BEFORE the stop, so A3 means something.
        vim.wait(5000, function()
            provider.grandchild = read_pid(provider.gc_path)
            return provider.grandchild ~= nil
        end, 20)
        if provider.grandchild then
            provider.shell = parent_of(provider.grandchild)
            provider.grandchild_alive = alive(provider.grandchild)
            provider.shell_alive = alive(provider.shell)
        end
        return sse_headers()
            .. sse_chunk('{"role":"assistant","content":""}')
            .. tool_call_chunk("stop_task", { task_id = task_id })
            .. sse_chunk("{}", "tool_calls")
            .. "data: [DONE]\n\n"
    end

    if turn == 3 then
        return sse_headers()
            .. sse_chunk('{"role":"assistant","content":""}')
            .. tool_call_chunk("list_tasks", { include_finished = true })
            .. sse_chunk("{}", "tool_calls")
            .. "data: [DONE]\n\n"
    end

    return sse_headers()
        .. sse_chunk('{"role":"assistant","content":"All done."}')
        .. sse_chunk("{}", "stop")
        .. "data: [DONE]\n\n"
end

---@param gc_path string
---@return StopE2EProvider
local function start_fake_provider(gc_path)
    ---@type StopE2EProvider
    local provider = { turn = 0, bodies = {}, gc_path = gc_path }
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
            -- `respond` waits for the real process tree to appear, and vim.wait
            -- is not allowed in a libuv callback (fast event context).
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
                name = "E2EStop",
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

---@class StopE2EBackend
---@field job integer
---@field session_dir string
---@field events table[]
---@field stderr string

---@param session_dir string
---@param cwd string
---@return StopE2EBackend
local function start_backend(session_dir, cwd)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type StopE2EBackend
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

---@param backend StopE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend StopE2EBackend
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

---@param backend StopE2EBackend
local function stop_backend(backend)
    pcall(vim.fn.chanclose, backend.job, "stdin")
    pcall(vim.fn.jobstop, backend.job)
    pcall(vim.fn.jobwait, { backend.job }, 5000)
end

--- Raw text of the session transcript (the JSONL is ground truth; every needle
--- used below survives JSON escaping).
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

-- ---------------------------------------------------------------------------

local function main()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(RUN_ROOT, "p")
    local agent_dir = RUN_ROOT .. "/agent"
    local gc_path = RUN_ROOT .. "/grandchild.pid"

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

    local provider = start_fake_provider(gc_path)
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

    local since = #backend.events
    send(backend, { id = "prompt-1", type = "prompt", message = "Do it." })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > since
    end, 180000, "agent_settled")
    check(settled ~= nil, "the scripted run settles", { stderr = backend.stderr })
    step(("run settled after %d provider turns"):format(provider.turn))

    check(
        provider.turn == 4,
        "every scripted turn ran (bash -> stop_task -> list_tasks -> text)",
        { turn = provider.turn }
    )
    check(provider.missing_task_id == nil, "the bash tool result must carry the task id", { turn = provider.turn })
    check(type(provider.grandchild) == "number", "the background command reported a grandchild pid")
    check(type(provider.shell) == "number", "the grandchild's shell pid was observed", { gc = provider.grandchild })
    check(provider.grandchild_alive == true, "the grandchild must be alive while the task runs", {
        grandchild = provider.grandchild,
    })
    check(
        provider.shell_alive == true,
        "the task's shell must be alive while the task runs",
        { shell = provider.shell }
    )
    step(("observed live tree: shell %d, grandchild %d"):format(provider.shell, provider.grandchild))

    -- A3: the whole process group is gone, not just the shell.
    check(
        vim.wait(5000, function()
            return not alive(provider.grandchild)
        end, 50),
        "the grandchild must be dead after stop_task (pid-only kill regression)",
        { grandchild = provider.grandchild }
    )
    check(not alive(provider.shell), "the task's shell must be dead after stop_task", { shell = provider.shell })
    step("A3 shell + grandchild are gone")

    local text = transcript(backend.session_dir)
    check(#text > 0, "the session transcript exists", { dir = backend.session_dir })

    -- A2: the stop's own result carries the terminal state.
    local stopped_line = text:match('Task b%x+ was stopped [^"\\]*')
    check(
        text:find("was stopped (signal SIGTERM)", 1, true) ~= nil,
        "stop_task's result must report the signal stop",
        { line = stopped_line }
    )
    print("[step] stop result: " .. vim.trim(stopped_line or "?"))
    -- A5: the list saw the stopped task, with its log path.
    check(text:find("[was stopped (signal SIGTERM)]", 1, true) ~= nil, "list_tasks must show the stopped task")
    check(text:find("(output: ", 1, true) ~= nil, "list_tasks rows must carry the output file")
    -- A4: exactly-once — the stop's tool result carried the terminal state, so
    -- no request the model saw after the stop may also carry a wake report.
    -- (The `context` fallback injects into the request, not into the session
    -- file, so the provider's recorded bodies are the ground truth here.)
    for turn = 3, provider.turn do
        check(
            (provider.bodies[turn] or ""):find("[SYSTEM NOTIFICATION", 1, true) == nil,
            "a task stopped by stop_task must not also be reported as a wake",
            { turn = turn }
        )
    end
    -- ...and nothing is re-injected into the transcript either.
    check(
        text:find("[SYSTEM NOTIFICATION", 1, true) == nil,
        "a task stopped by stop_task must not also produce a wake entry"
    )
    step("A2/A4/A5 transcript asserts pass")

    stop_backend(backend)

    print(
        ("ALL bg-tasks stop cases passed (stop_task killed the group, list_tasks saw it, no wake report) in %.2fs"):format(
            (uv.hrtime() - run_started) / 1e9
        )
    )
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e bg_tasks_stop: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
