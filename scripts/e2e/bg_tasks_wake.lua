-- Headless e2e: two completions in one tick must send ONE wake.
--
-- A completion that lands while the agent is idle wakes it: `sendMessage(...,
-- { triggerTurn: true })` starts a turn immediately with the report. Two tasks
-- that exit in the same event-loop tick used to call that flush twice, so one
-- burst cost two messages, two turns and two full context reads. The idle wake
-- is now coalesced behind a 40 ms timer, which this script checks end-to-end
-- against the real stack: a `pi --mode rpc` child with the bundled
-- `extensions/bg-tasks.ts`, a scripted fake OpenAI-compatible provider on
-- 127.0.0.1 (no account, no network, no model), and the session transcript
-- (JSONL) as ground truth.
--
-- Scripted turns:
--   T1  TWO background bash calls in ONE assistant message (indexes 0 and 1).
--       Each command BLOCKS on its own marker file under the run dir
--       (`while [ ! -f <marker> ]; do sleep 0.02; done; echo wake-<x>`), so
--       neither exit can be decided by scheduling luck.
--   T2  plain assistant text — the run ends with both tasks still blocked, so
--       both completions arrive with nobody attached and the run idle (the
--       same-tick idle wake path, not the boundary path)
--   T3  plain assistant text (answers the wake)
--
-- After the run settles the script releases BOTH markers back-to-back in ONE
-- step, which is what makes this a burst by construction: the two `close`
-- events are microseconds apart on any machine, loaded or not. (The old form
-- used `sleep 0.4` in both commands and relied on the two sleeps expiring
-- within the 40 ms window — a loaded runner could emit two reports of the new
-- code and fail the suite for the wrong reason.)
--
-- Assertions, all behavioural:
--   W1 exactly ONE custom message carries `<background-task` (printed in the
--      failure context, so a regression shows the real count)
--   W2 that message names BOTH task ids, read out of the two tool results of T1
--   W3 exactly ONE assistant message follows it — one wake, not two — and the
--      run the wake started settles
--   W4 both markers were released in the SAME scripted step (and the wake turn
--      started after it), so the burst is deterministic, not a wall-clock
--      coincidence
--
-- Needs the pi binary, nothing else (the provider is fake), which is why it runs
-- in CI (.github/workflows/e2e.yml). Not part of `make test`:
--
--   make e2e-bg-wake
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/bg_tasks_wake.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/bg-tasks.ts"
local RUN_ROOT = vim.fn.tempname() .. "-bg-wake"

local PROVIDER = "e2ewake"
local MODEL_ID = "e2e-model"
-- Both tasks block until their own marker exists, and the script writes the two
-- markers back-to-back in one step (see `main`): the burst is deterministic.
local RELEASE_A = RUN_ROOT .. "/release-a"
local RELEASE_B = RUN_ROOT .. "/release-b"
local COMMAND_A = ("while [ ! -f '%s' ]; do sleep 0.02; done; echo wake-a"):format(RELEASE_A)
local COMMAND_B = ("while [ ! -f '%s' ]; do sleep 0.02; done; echo wake-b"):format(RELEASE_B)

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

---@class WakeE2EProvider
---@field server uv.uv_tcp_t
---@field turn integer requests answered so far
---@field bodies string[] request body per turn
---@field task_ids string[] ids read out of T1's two tool results
---@field missing_task_ids boolean? set when T1's results carried fewer than two ids

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
--- `index` orders several calls inside ONE assistant turn (one streamed chunk
--- per call, the way a real provider emits them).
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

---@param provider WakeE2EProvider
---@return string
local function respond(provider)
    provider.turn = provider.turn + 1
    local turn = provider.turn

    if turn == 1 then
        -- TWO background tasks in ONE assistant message: both exits land in the
        -- same event-loop tick, which is exactly the burst the wake coalesces.
        return sse_headers()
            .. sse_chunk('{"role":"assistant","content":""}')
            .. tool_call_chunk("bash", { command = COMMAND_A, run_in_background = true }, 0)
            .. tool_call_chunk("bash", { command = COMMAND_B, run_in_background = true }, 1)
            .. sse_chunk("{}", "tool_calls")
            .. "data: [DONE]\n\n"
    end

    if turn == 2 then
        -- The two tool results for T1 are in the body we were just handed: read
        -- the task ids out of them, the way a real model reads them out of its
        -- context.
        local body = provider.bodies[turn] or ""
        local ids = {}
        for task_id in body:gmatch("Task (b%x+) running in background") do
            ids[#ids + 1] = task_id
        end
        if #ids < 2 then
            -- Fail fast instead of hanging the run: main asserts on this flag.
            provider.missing_task_ids = true
            return text_response("missing task ids in the bash results")
        end
        provider.task_ids = ids
        -- Plain text, no tool call: the run ends now, with BOTH tasks still
        -- blocked on their markers, so both completions arrive with the run idle.
        return text_response("Both background tasks are running.")
    end

    return text_response("Woken by the completion report.")
end

---@return WakeE2EProvider
local function start_fake_provider()
    ---@type WakeE2EProvider
    local provider = { turn = 0, bodies = {}, task_ids = {} }
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
            -- `respond` must not block in a libuv callback: record the body and
            -- answer from the main loop.
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
                name = "E2EWake",
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

---@class WakeE2EBackend
---@field job integer
---@field session_dir string
---@field events table[] parsed stdout events (each tagged `_n` = 1-based index)
---@field stderr string

---@param session_dir string
---@param cwd string
---@return WakeE2EBackend
local function start_backend(session_dir, cwd)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type WakeE2EBackend
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

---@param backend WakeE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend WakeE2EBackend
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

---@param backend WakeE2EBackend
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

--- Every custom message that carries a report block.
---@param entries table[]
---@return table[] { index:integer, content:string }
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

---@param entries table[]
---@return integer[]
local function assistant_indices(entries)
    local out = {}
    for index, entry in ipairs(entries) do
        if entry.type == "message" and type(entry.message) == "table" and entry.message.role == "assistant" then
            out[#out + 1] = index
        end
    end
    return out
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

    local since = #backend.events
    send(backend, { id = "prompt-1", type = "prompt", message = "Start two tasks." })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > since
    end, 60000, "agent_settled")
    check(settled ~= nil, "the scripted run settles", { stderr = backend.stderr })
    step(("scripted run settled after %d provider turns (tasks still running)"):format(provider.turn))

    check(
        provider.missing_task_ids == nil,
        "the two bash tool results must carry both task ids",
        { turn = provider.turn, ids = provider.task_ids }
    )
    check(#provider.task_ids == 2, "both task ids were read out of T1's tool results", {
        ids = provider.task_ids,
    })
    step(("task ids %s, %s"):format(provider.task_ids[1], provider.task_ids[2]))

    -- Both tasks are blocked on their own marker (neither can have exited: the
    -- markers do not exist yet), so releasing them back-to-back in ONE scripted
    -- step makes the two `close` events microseconds apart by construction.
    local release_steps = 0
    local function release_both()
        release_steps = release_steps + 1
        for _, marker in ipairs({ RELEASE_A, RELEASE_B }) do
            local f = assert(io.open(marker, "w"))
            f:write("go")
            f:close()
        end
    end

    local released_at_event = #backend.events
    release_both()
    step("released both tasks in one scripted step")

    -- Both tasks exit ~instantly, in the same tick, with the run idle: one
    -- coalesced wake, one turn.
    local wake_start = wait_event(backend, function(ev)
        return ev.type == "agent_start" and ev._n > settled._n
    end, 20000, "wake turn")
    check(wake_start ~= nil, "the completion woke the agent", { stderr = backend.stderr })
    local wake_settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > wake_start._n
    end, 30000, "wake settle")
    check(wake_settled ~= nil, "the run the wake started settles", { stderr = backend.stderr })
    step("one wake turn started and settled")

    -- Let the transcript settle: a second (wrong) wake would append its own
    -- custom message and its own assistant answer, so wait a little before
    -- counting.
    vim.wait(1000, function()
        return false
    end)

    local entries = read_session(backend.session_dir)
    local reports = report_entries(entries)

    -- W1: ONE message for the burst.
    check(#reports == 1, "exactly ONE report message for two same-tick completions", {
        count = #reports,
        entries = #entries,
        stderr = backend.stderr,
    })
    local report = reports[1]
    local content = report.content
    print("[report] " .. (content:gsub("\n", "\\n")))
    step("W1 exactly one report message for two completions")

    -- W2: it names BOTH tasks (one message, one element per task).
    for _, task_id in ipairs(provider.task_ids) do
        check(content:find('id="' .. task_id .. '"', 1, true) ~= nil, "the report names task " .. task_id, {
            report = content,
        })
    end
    step("W2 the one report names both task ids")

    -- W3: one wake, not two: exactly one assistant message follows the report.
    local after = {}
    for _, index in ipairs(assistant_indices(entries)) do
        if index > report.index then
            after[#after + 1] = index
        end
    end
    check(#after == 1, "exactly one assistant message follows the report (one wake, not two)", {
        after = after,
        report = report.index,
        assistants = assistant_indices(entries),
        turns = provider.turn,
    })
    step("W3 exactly one assistant message after the report")

    -- W4: the burst was scripted, not lucky. Both markers were written in the
    -- same step, microseconds apart, and nothing was woken before that step, so
    -- both exits are strictly after it.
    check(release_steps == 1, "both markers must be released in the same scripted step", {
        steps = release_steps,
    })
    check(wake_start._n > released_at_event, "the wake turn must start after the release step", {
        wake = wake_start._n,
        released = released_at_event,
    })
    local stat_a = uv.fs_stat(RELEASE_A)
    local stat_b = uv.fs_stat(RELEASE_B)
    check(stat_a ~= nil and stat_b ~= nil, "both release markers exist", { a = stat_a, b = stat_b })
    ---@param st table
    ---@return number
    local function mtime_seconds(st)
        return (st.mtime.sec or 0) + (st.mtime.nsec or 0) / 1e9
    end
    local marker_gap = math.abs(mtime_seconds(stat_a) - mtime_seconds(stat_b))
    check(marker_gap <= 0.05, "the two markers must be written back-to-back", { gap = marker_gap })
    step(("W4 both markers released in one scripted step (%.3fs apart)"):format(marker_gap))

    stop_backend(backend)

    print(
        (
            "ALL bg-tasks wake cases passed (two tasks released in one scripted step sent ONE report naming\n"
            .. "both tasks, answered by ONE turn) in %.2fs"
        ):format((uv.hrtime() - run_started) / 1e9)
    )
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    -- Never leave a marker-blocked task behind: releasing the markers lets any
    -- task this run started exit on its own once the backend is gone.
    for _, marker in ipairs({ RELEASE_A, RELEASE_B }) do
        local f = io.open(marker, "w")
        if f then
            f:write("go")
            f:close()
        end
    end
    io.stderr:write("e2e bg_tasks_wake: " .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end
