-- Headless e2e: a background task keeps its stdin, and `task_input` feeds it
-- (P0-3).
--
-- Before this, every spawn was `stdio: ["ignore", "pipe", "pipe"]`, so a
-- command that asks a question got EOF: an interactive tool either aborted or
-- blocked forever — the "never exits, never notifies" hole.
--
-- One `pi --mode rpc` child with the bundled `extensions/bg-tasks.ts` and a
-- scripted fake provider, driving a REAL shell that reads a line from stdin:
--
--   T1  bash(run_in_background: true, `IFS= read -r line; printf ... > out`)
--   T2  task_input(<id from T1>, "hello")
--   T3  wait_task(<id>)
--   T4  bash(`sleep 900`, timeout 1000)        — foreground, detaches
--   T5  task_input(<id from T4>)               — must refuse: no stdin pipe
--   T6  stop_task(<id from T4>)
--   T7  "done"
--
-- Assertions, all behavioural:
--   A1 the shell really read the piped line (the file it wrote says so)
--   A2 task_input reports the bytes it wrote
--   A3 wait_task returns the task's output, carrying the same line
--   A4 the write did not turn into a wake report (the wait owned the exit)
--   A5 a foreground task that detached has NO stdin, and task_input says why
--
-- Needs the pi binary, nothing else (the provider is fake), which is why it runs
-- in CI (.github/workflows/e2e.yml). Not part of `make test`:
--
--   make e2e-bg-stdin
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_stdin.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-stdin"

local PROVIDER = "e2estdin"
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

-- ---------------------------------------------------------------------------
-- Scripted fake provider (OpenAI chat-completions, streamed).
-- ---------------------------------------------------------------------------

---@class StdinE2EProvider
---@field server uv.uv_tcp_t
---@field turn integer
---@field bodies string[]
---@field out_path string file the background shell writes the line it read into
---@field bg_id string? id of the background task that waits for input
---@field fg_id string? id of the foreground command that detached
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

---@param provider StdinE2EProvider
---@return string
local function respond(provider)
    provider.turn = provider.turn + 1
    local turn = provider.turn
    local body = provider.bodies[#provider.bodies] or ""

    if turn == 1 then
        -- The shell reads exactly one line from stdin, then answers with it.
        local command = ('IFS= read -r line; printf \'got:%%s\\n\' "$line" > %s; echo "read: $line"'):format(
            provider.out_path
        )
        return tool_turn("bash", { command = command, run_in_background = true })
    end

    if turn == 2 then
        local id = body:match("Task (b%x%x%x%x%x%x%x?) running in background")
        if type(id) ~= "string" then
            provider.missing_id = true
            return text_turn("no task id in the bash result")
        end
        provider.bg_id = id
        return tool_turn("task_input", { task_id = id, data = "hello" })
    end

    if turn == 3 then
        return tool_turn("wait_task", { task_id = provider.bg_id, timeout_ms = 30000 })
    end

    if turn == 4 then
        return tool_turn("bash", { command = "sleep 900", timeout = 1000 })
    end

    if turn == 5 then
        local id = body:match("keeps running as background task (b%x%x%x%x%x%x%x?)")
        if type(id) ~= "string" then
            provider.missing_id = true
            return text_turn("no task id in the detached bash result")
        end
        provider.fg_id = id
        return tool_turn("task_input", { task_id = id, data = "anything" })
    end

    if turn == 6 then
        return tool_turn("stop_task", { task_id = provider.fg_id })
    end

    return text_turn("All done.")
end

---@param out_path string
---@return StdinE2EProvider
local function start_fake_provider(out_path)
    ---@type StdinE2EProvider
    local provider = { turn = 0, bodies = {}, out_path = out_path }
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

--- Isolated agent dir: our own models.json + an empty settings.json.
---@param agent_dir string
---@param port integer
local function write_agent_dir(agent_dir, port)
    vim.fn.mkdir(agent_dir, "p")
    local models = {
        providers = {
            [PROVIDER] = {
                name = "E2EStdin",
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

---@class StdinE2EBackend
---@field job integer
---@field session_dir string
---@field events table[]
---@field stderr string

---@param session_dir string
---@param cwd string
---@return StdinE2EBackend
local function start_backend(session_dir, cwd)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type StdinE2EBackend
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

---@param backend StdinE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend StdinE2EBackend
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

---@param backend StdinE2EBackend
local function stop_backend(backend)
    pcall(vim.fn.chanclose, backend.job, "stdin")
    pcall(vim.fn.jobstop, backend.job)
    pcall(vim.fn.jobwait, { backend.job }, 5000)
end

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
    local out_path = RUN_ROOT .. "/read.txt"

    vim.env.PI_CODING_AGENT_DIR = agent_dir
    vim.env.PI_OFFLINE = "1"

    local provider = start_fake_provider(out_path)
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

    local since = #backend.events
    send(backend, { id = "prompt-1", type = "prompt", message = "Run it and answer the prompt." })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > since
    end, 240000, "agent_settled")
    check(settled ~= nil, "the scripted run settles", { stderr = backend.stderr })
    step(("run settled after %d provider turns"):format(provider.turn))

    check(provider.turn == 7, "every scripted turn ran", { turn = provider.turn })
    check(provider.missing_id == nil, "both task ids were read out of the tool results", { turn = provider.turn })

    -- A1: the shell really read what task_input wrote.
    check(
        vim.wait(5000, function()
            local got = read_file(out_path)
            return got ~= nil and got:find("got:hello", 1, true) ~= nil
        end, 50),
        "A1 the background shell read the line task_input wrote",
        { file = read_file(out_path) }
    )
    step("A1 the task read the piped line: " .. vim.trim(read_file(out_path) or ""))

    local text = transcript(backend.session_dir)
    check(#text > 0, "the session transcript exists", { dir = backend.session_dir })

    -- A2: the write is reported with its byte count (6 = "hello" + newline).
    check(
        text:find("Wrote 6 byte(s) to task " .. (provider.bg_id or "") .. "'s stdin", 1, true) ~= nil,
        "A2 task_input reports what it wrote"
    )
    -- A3: the wait returned the task's output, so the same line reached the model.
    check(text:find("read: hello", 1, true) ~= nil, "A3 the task's output carries the line it read")
    -- A4: the wait owned the exit; no wake report may follow for that task.
    for index, body in ipairs(provider.bodies) do
        check(
            body:find("[Background task " .. (provider.bg_id or "") .. ' ("', 1, true) == nil,
            "A4 a task whose exit a wait_task carried must not also produce a wake report",
            { index = index }
        )
    end
    -- A5: a detached foreground command has no stdin, and the refusal says why.
    check(
        text:find("was started without a stdin pipe", 1, true) ~= nil,
        "A5 task_input refuses a task that has no stdin pipe",
        { tail = text:sub(-1200) }
    )
    step("A2/A3/A4/A5 transcript asserts pass")

    stop_backend(backend)

    print(
        ("ALL bg-tasks stdin cases passed (background stdin kept, task_input fed it, detached foreground refused) in %.2fs"):format(
            (uv.hrtime() - run_started) / 1e9
        )
    )
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e bg_tasks_stdin: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
