-- Headless e2e: the bundled compaction cleaner (`extensions/compaction.ts`, L1).
--
-- This is the EXPERIMENT for the whole compaction feature, not just a smoke
-- test: it proves that mutating `event.preparation.fileOps` in place inside
-- `session_before_compact` really changes the summary pi writes. pi's
-- `compact()` destructures `fileOps` at call time and calls `computeFileLists`
-- AFTER the hook (and after the LLM call), so a hook that cleans the Sets in
-- place is enough — every native behaviour (native `details`, `fromHook: false`,
-- the summarisation prompt) must stay untouched. If the assertions below fail,
-- the mechanism is gone and the design has to change; the test is not the bug.
--
-- Drives the REAL stack: a `pi --mode rpc` child with the bundled extension, a
-- scripted fake OpenAI-compatible provider on 127.0.0.1 (no account, no
-- network, no real model), an isolated `PI_CODING_AGENT_DIR`, and the session
-- JSONL as ground truth.
--
-- Layout matters, and the layout is what makes the assertions mean something:
--
--   * 60 files live under `os.tmpdir()` (scratch paths the cleaner must drop),
--     60 files live in a normal project directory (paths that must survive).
--     The project tree cannot live under tmpdir() — everything there is
--     filtered by design.
--   * `keepRecentTokens` is 2000, so a manual `compact` keeps only the tail of
--     the session. The project tree lives in `~/.local/state`, NOT in the repo.
--
-- Scripted turns (one provider request per conversation turn):
--   T1  120 `read` tool calls in one assistant message (60 temp + 60 project)
--   T2  text
--   -> RPC `compact` #1: 120 read ops in, 60 dropped as scratch, capped to 50
--   T3  text  -- a user-message span the SECOND compaction can summarize
--   T4  read(<big project file>)  -- pushes the phase-2 turn past 2000 tokens
--   T5  text
--   -> runtime config rewritten to {"cleaner":{"max_read":5}}, `compact` #2
--
-- Phase 2 needs that shape on purpose: the second compaction must have a
-- non-empty `messagesToSummarize`, because only then does pi send the UPDATE
-- prompt, which is the one request that embeds `<previous-summary>` — the only
-- place the strip of the previous file lists is observable.
--
-- Assertions, all behavioural and read out of the session JSONL:
--   A1  the first summary's `<read-files>` carries ONLY project paths, at most
--       `max_read` (50) of them, and no temp path survives anywhere in it
--   A2  the native `details.readFiles` / `details.modifiedFiles` are still there
--       and `fromHook` is falsy — pi wrote its own entry, the extension only
--       changed the lists
--   A3  the cleaner's custom entry reports the counts (`readOmitted >= 60`) and
--       `strippedPrevious == false` for the first compaction
--   A4  NO summarisation request ever carries `<read-files>`: the previous
--       summary's lists are stripped before they are re-sent inside
--       `<previous-summary>` (the second phase actually takes the update-prompt
--       path, which is asserted, so A4 has teeth)
--   A5  the second compaction's `<read-files>` holds at most 5 entries, the
--       freshly read big project file is among them (recent entries are kept),
--       and the custom entry reports `strippedPrevious == true`
--   A6  no `extension_error` event, both `compact` responses are `success:true`
--
-- Needs the pi binary, nothing else (the provider is fake), so it can run in CI:
--
--   make e2e-compaction
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/compaction.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/compaction.ts"
local TAG = ("%d-%d"):format(uv.os_getpid(), os.time())
local RUN_ROOT = vim.fn.tempname() .. "-compaction"
-- The project tree lives OUTSIDE tmpdir(): the cleaner drops everything under
-- tmpdir() (that is the filter under test), so files that must SURVIVE it
-- cannot live there. `~/.local/state` is a normal, uninteresting path.
local PROJECT_ROOT = vim.fn.expand("~/.local/state/pi2nvim-e2e") .. "/compaction-" .. TAG

local PROVIDER = "e2ecomp"
local MODEL_ID = "e2e-model"

local N_TEMP = 60
local N_PROJECT = 60
local MAX_READ_DEFAULT = 50
local MAX_READ_PHASE2 = 5

-- The summary text the fake "model" returns; must not contain a file list.
local SUMMARY_TEXT = table.concat({
    "## Goal",
    "Finish the scripted e2e run.",
    "",
    "## Progress",
    "### Done",
    "- [x] read the files",
    "",
    "## Next Steps",
    "1. keep going",
}, "\n")

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
-- HTTP helpers + the scripted provider (OpenAI chat-completions, streamed).
-- ---------------------------------------------------------------------------

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

--- A final usage-only chunk, the shape `stream_options.include_usage` produces.
---@return string
local function sse_usage_chunk()
    return ('data: {"id":"chatcmpl-e2e","object":"chat.completion.chunk","created":0,"model":"%s","choices":[],"usage":{"prompt_tokens":900,"completion_tokens":40,"total_tokens":940}}\n\n'):format(
        MODEL_ID
    )
end

---@param index integer
---@param name string
---@param args table
---@return string
local function tool_call_chunk(index, name, args)
    local arguments = vim.json.encode(vim.json.encode(args))
    return sse_chunk(
        ('{"tool_calls":[{"index":%d,"id":"call_%d","type":"function","function":{"name":"%s","arguments":%s}}]}'):format(
            index,
            index,
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
        .. sse_usage_chunk()
        .. "data: [DONE]\n\n"
end

---@param calls table[] list of { name, args }
---@return string
local function tool_turn(calls)
    local chunks = { sse_headers(), sse_chunk('{"role":"assistant","content":""}') }
    for index, call in ipairs(calls) do
        chunks[#chunks + 1] = tool_call_chunk(index - 1, call[1], call[2])
    end
    chunks[#chunks + 1] = sse_chunk("{}", "tool_calls")
    chunks[#chunks + 1] = sse_usage_chunk()
    chunks[#chunks + 1] = "data: [DONE]\n\n"
    return table.concat(chunks)
end

--- Flatten every string in a decoded JSON value: the ground truth for "what the
--- model was actually handed", independent of JSON escaping.
---@param value any
---@param parts string[]
local function flatten_strings(value, parts)
    if type(value) == "string" then
        parts[#parts + 1] = value
    elseif type(value) == "table" then
        for _, child in pairs(value) do
            flatten_strings(child, parts)
        end
    end
end

---@param body string
---@return string
local function body_text(body)
    local ok, decoded = pcall(vim.json.decode, body)
    if not ok or type(decoded) ~= "table" then
        return body
    end
    local parts = {}
    flatten_strings(decoded, parts)
    return table.concat(parts, "\n")
end

--- Is this request a summarisation call rather than a conversation turn? Both
--- the initial prompt and the update prompt wrap the conversation in
--- `<conversation>`; the split-turn prefix prompt uses `# Conversation`.
---@param text string
---@return boolean
local function is_summarization(text)
    return text:find("<conversation>", 1, true) ~= nil
        or text:find("# Conversation", 1, true) ~= nil
        or text:find("Create a structured context checkpoint summary", 1, true) ~= nil
        or text:find("NEW conversation messages to incorporate", 1, true) ~= nil
        or text:find("earlier context from an ongoing conversation", 1, true) ~= nil
end

---@class CompactionE2EProvider
---@field server? uv.uv_tcp_t
---@field turn integer conversation requests answered so far
---@field summarizations string[] flattened text of every summarisation request
---@field temp_paths string[]
---@field project_paths string[]
---@field big_path string

---@param provider CompactionE2EProvider
---@return string
local function respond(provider)
    provider.turn = provider.turn + 1
    local turn = provider.turn

    if turn == 1 then
        -- One assistant message with 120 read calls: 60 scratch paths and 60
        -- project paths. Every call is a real file so pi's read tool succeeds.
        local calls = {}
        for _, path in ipairs(provider.temp_paths) do
            calls[#calls + 1] = { "read", { path = path } }
        end
        for _, path in ipairs(provider.project_paths) do
            calls[#calls + 1] = { "read", { path = path } }
        end
        return tool_turn(calls)
    end
    if turn == 2 then
        return text_turn("Read all 120 files.")
    end
    if turn == 3 then
        -- Phase 2, first prompt: a text-only turn. It must come BEFORE the big
        -- read, because the second compaction has to have a user-message span to
        -- summarize -- only then does pi call the update prompt with
        -- `<previous-summary>`, which is where A4 can observe the strip.
        return text_turn("Acknowledged. Reading the large file next.")
    end
    if turn == 4 then
        return tool_turn({ { "read", { path = provider.big_path } } })
    end
    return text_turn("Read the large file.")
end

---@param provider CompactionE2EProvider
---@param body string
---@return string
local function handle_request(provider, body)
    local text = body_text(body)
    if is_summarization(text) then
        provider.summarizations[#provider.summarizations + 1] = text
        return text_turn(SUMMARY_TEXT)
    end
    return respond(provider)
end

---@param provider CompactionE2EProvider
---@return CompactionE2EProvider
local function start_fake_provider(provider)
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
            -- Scheduled out of the libuv fast context, so the response pipeline
            -- may use `vim.*` helpers freely (same shape as the other e2e scripts).
            vim.schedule(function()
                local response = handle_request(provider, body)
                pcall(client.write, client, response, function()
                    pcall(client.close, client)
                end)
            end)
        end)
    end))
    return provider
end

-- ---------------------------------------------------------------------------
-- Fixtures: agent dir, settings, the temp tree and the project tree.
-- ---------------------------------------------------------------------------

---@param dir string
---@param port integer
local function write_agent_dir(dir, port)
    vim.fn.mkdir(dir, "p")
    local models = {
        providers = {
            [PROVIDER] = {
                name = "E2EComp",
                baseUrl = ("http://127.0.0.1:%d/v1"):format(port),
                apiKey = "sk-e2e-test",
                api = "openai-completions",
                models = {
                    {
                        id = MODEL_ID,
                        name = "E2E Model",
                        contextWindow = 200000,
                        maxTokens = 4096,
                        cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 },
                    },
                },
            },
        },
    }
    local f = assert(io.open(dir .. "/models.json", "w"))
    f:write(vim.json.encode(models))
    f:close()
    -- keepRecentTokens small enough that a manual `compact` summarizes the
    -- whole first span and keeps only the tail; a big window so auto-compaction
    -- never fires during the run.
    local s = assert(io.open(dir .. "/settings.json", "w"))
    s:write('{"compaction":{"reserveTokens":16384,"keepRecentTokens":2000}}')
    s:close()
end

---@param path string
---@param lines string[]
local function write_lines(path, lines)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    assert(vim.fn.writefile(lines, path) == 0, "write " .. path)
end

---@return string[] temp_paths
---@return string[] project_paths
---@return string big_path
local function create_fixture_files()
    local temp_dir = RUN_ROOT .. "/tmp-scratch"
    local project_dir = PROJECT_ROOT .. "/project"
    local temp_paths = {}
    local project_paths = {}
    -- Each file is deliberately NOT tiny (~200 chars -> a ~50 token tool
    -- result). The 120 tool results are what the cut point walks past: they must
    -- together exceed `keepRecentTokens` (2000) so the cut lands AFTER the
    -- assistant message that holds the read calls. A tiny result set makes pi
    -- cut AT that assistant message, the calls stay in the kept tail, and no
    -- file op is ever extracted -- the whole experiment then proves nothing.
    for index = 1, N_TEMP do
        local path = ("%s/tmpread-%03d.txt"):format(temp_dir, index)
        write_lines(path, {
            ("scratch content file %03d line one"):format(index),
            "scratch filler line padding padding pad",
            "scratch filler line padding padding pad",
            "scratch filler line padding padding pad",
        })
        temp_paths[#temp_paths + 1] = path
    end
    for index = 1, N_PROJECT do
        local path = ("%s/projread-%03d.txt"):format(project_dir, index)
        write_lines(path, {
            ("project content file %03d line one"):format(index),
            "project filler line padding padding pad",
            "project filler line padding padding pad",
            "project filler line padding padding pad",
        })
        project_paths[#project_paths + 1] = path
    end
    -- 1500 lines x ~40 chars: the read tool returns it (truncated to 2000 lines /
    -- 50KB, so effectively the whole file), which is ~15k tokens — well past
    -- keepRecentTokens, which is what makes phase 2 compact anything at all.
    local big_lines = {}
    for index = 1, 1500 do
        big_lines[index] = ("large file filler line %04d abcdefghij"):format(index)
    end
    local big_path = project_dir .. "/big-project-file.txt"
    write_lines(big_path, big_lines)
    return temp_paths, project_paths, big_path
end

-- ---------------------------------------------------------------------------
-- RPC backend
-- ---------------------------------------------------------------------------

---@class CompactionE2EBackend
---@field job integer
---@field session_dir string
---@field events table[]
---@field stderr string

---@param session_dir string
---@param cwd string
---@return CompactionE2EBackend
local function start_backend(session_dir, cwd)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type CompactionE2EBackend
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

---@param backend CompactionE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend CompactionE2EBackend
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

---@param backend CompactionE2EBackend
local function stop_backend(backend)
    pcall(vim.fn.chanclose, backend.job, "stdin")
    pcall(vim.fn.jobstop, backend.job)
    pcall(vim.fn.jobwait, { backend.job }, 5000)
end

---@param backend CompactionE2EBackend
---@param message string
---@param timeout_ms integer
local function run_turn(backend, message, timeout_ms)
    local since = #backend.events
    send(backend, { type = "prompt", message = message })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > since
    end, timeout_ms, "agent_settled")
    check(settled ~= nil, "the scripted run settles", { stderr = backend.stderr, message = message })
end

--- Send `compact` and return the response (or nil after printing the events).
---@param backend CompactionE2EBackend
---@param what string
---@return table?
local function run_compact(backend, what)
    local since = #backend.events
    send(backend, { type = "compact" })
    local response = wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "compact" and ev._n > since
    end, 180000, what)
    if response == nil then
        return nil
    end
    check(response.success == true, what .. ": compact response must be success:true", { response = response })
    return response
end

-- ---------------------------------------------------------------------------
-- Session JSONL (ground truth)
-- ---------------------------------------------------------------------------

---@param session_dir string
---@return table[]
local function session_entries(session_dir)
    local names = vim.fn.readdir(session_dir)
    table.sort(names)
    local entries = {}
    for _, name in ipairs(names) do
        if name:match("%.jsonl$") then
            local text = read_file(session_dir .. "/" .. name) or ""
            for line in text:gmatch("[^\n]+") do
                local ok, decoded = pcall(vim.json.decode, line)
                if ok and type(decoded) == "table" then
                    entries[#entries + 1] = decoded
                end
            end
        end
    end
    return entries
end

---@param entries table[]
---@param kind string
---@return table[]
local function by_type(entries, kind)
    local out = {}
    for _, entry in ipairs(entries) do
        if entry.type == kind then
            out[#out + 1] = entry
        end
    end
    return out
end

---@param entries table[]
---@param custom_type string
---@return table[]
local function custom_entries(entries, custom_type)
    local out = {}
    for _, entry in ipairs(entries) do
        if entry.type == "custom" and entry.customType == custom_type then
            out[#out + 1] = entry
        end
    end
    return out
end

--- Body of the `<read-files>` block a summary ends with.
---@param summary string
---@return string?
local function read_files_block(summary)
    return summary:match("<read%-files>\n(.-)\n</read%-files>")
end

---@param block string?
---@return string[]
local function block_paths(block)
    local paths = {}
    if not block then
        return paths
    end
    for line in block:gmatch("[^\n]+") do
        paths[#paths + 1] = line
    end
    return paths
end

---@param list string[]
---@param value string
---@return boolean
local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------

local function cleanup()
    pcall(vim.fn.delete, RUN_ROOT, "rf")
    pcall(vim.fn.delete, PROJECT_ROOT, "rf")
end

local function main()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(RUN_ROOT, "p")
    local agent_dir = RUN_ROOT .. "/agent"
    local config_path = RUN_ROOT .. "/compaction-config.json"

    vim.env.PI_CODING_AGENT_DIR = agent_dir
    vim.env.PI_OFFLINE = "1"
    -- Published by pi.nvim's config.setup() in the real plugin; the extension
    -- re-reads this file on every compaction event. Absent at first, so the
    -- built-in defaults apply to phase 1.
    vim.env.PI_NVIM_COMPACTION_FILE = config_path

    local temp_paths, project_paths, big_path = create_fixture_files()
    ---@type CompactionE2EProvider
    local provider = {
        turn = 0,
        summarizations = {},
        temp_paths = temp_paths,
        project_paths = project_paths,
        big_path = big_path,
    }
    start_fake_provider(provider)
    local addr = provider.server:getsockname()
    local port = type(addr) == "table" and addr.port or nil
    check(type(port) == "number" and port > 0, "fake provider did not bind a port", { addr = addr })
    write_agent_dir(agent_dir, port)
    step(("fixtures ready: %d temp + %d project files, provider on 127.0.0.1:%d"):format(N_TEMP, N_PROJECT, port))

    local backend = start_backend(RUN_ROOT .. "/sessions", PROJECT_ROOT .. "/project")
    send(backend, { type = "set_model", provider = PROVIDER, modelId = MODEL_ID })
    local pinned = wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, "set_model")
    check(pinned ~= nil and pinned.success ~= false, "fake model selected", { stderr = backend.stderr })
    step("model pinned to the fake provider")

    -- Phase 1: one assistant message with 120 read calls, then a text turn.
    run_turn(backend, "Read every file you can see.", 180000)
    check(provider.turn == 2, "phase 1 ran both scripted turns", { turn = provider.turn })
    step("phase 1: 120 read tool calls executed")

    local response = run_compact(backend, "compact #1")
    check(response ~= nil, "compaction #1 returned an RPC response")
    step("compaction #1 finished")

    local entries = session_entries(backend.session_dir)
    local compactions = by_type(entries, "compaction")
    local cleaners = custom_entries(entries, "pi2-compaction-cleaner")
    check(#compactions == 1, "exactly one compaction entry after compaction #1", { count = #compactions })
    check(#cleaners == 1, "the cleaner wrote one custom entry", { count = #cleaners })

    -- A1/A2: the summary pi stored.
    local first = compactions[1]
    local first_summary = first.summary
    check(type(first_summary) == "string" and #first_summary > 0, "the first summary is a non-empty string")
    local block = read_files_block(first_summary)
    check(block ~= nil, "the first summary carries a <read-files> block")
    local first_paths = block_paths(block)
    check(first_summary:find("/tmp/", 1, true) == nil, "no scratch path survives in the summary")
    for _, path in ipairs(temp_paths) do
        local name = vim.fn.fnamemodify(path, ":t")
        check(first_summary:find(name, 1, true) == nil, "a dropped scratch file must not appear in the summary", {
            name = name,
        })
        check(first_summary:find(path, 1, true) == nil, "a dropped scratch path must not appear in the summary")
    end
    check(
        #first_paths == MAX_READ_DEFAULT,
        ("the read list is capped at max_read (%d), got %d"):format(MAX_READ_DEFAULT, #first_paths),
        { paths = #first_paths }
    )
    for _, path in ipairs(first_paths) do
        check(
            path:sub(1, #PROJECT_ROOT) == PROJECT_ROOT,
            "every kept read path must be a project path, never a scratch path",
            { path = path }
        )
    end
    check(type(first.details) == "table", "native details are still written", { details = first.details })
    check(type(first.details.readFiles) == "table", "native details.readFiles is still an array")
    check(type(first.details.modifiedFiles) == "table", "native details.modifiedFiles is still an array")
    check(#first.details.readFiles == #first_paths, "native details carry the SAME cleaned list", {
        details = #first.details.readFiles,
        block = #first_paths,
    })
    check(first.fromHook ~= true, "pi wrote its own compaction entry (fromHook falsy)", { fromHook = first.fromHook })
    step(("A1/A2 summary holds %d project paths, 0 scratch paths, native details intact"):format(#first_paths))

    -- A3: the cleaner's own record.
    local first_report = cleaners[1].data or {}
    check(first_report.readKept == #first_paths, "the custom entry reports the kept read count", {
        report = first_report,
    })
    check(
        first_report.readOmitted >= N_TEMP,
        ("the custom entry reports readOmitted >= %d"):format(N_TEMP),
        { report = first_report }
    )
    check(first_report.strippedPrevious == false, "phase 1 has no previous summary to strip", { report = first_report })
    check(first_report.engine == "cleaner", "the custom entry is tagged with its engine", { report = first_report })
    step(
        ("A3 cleaner entry: readKept=%d readOmitted=%d strippedPrevious=false"):format(
            first_report.readKept,
            first_report.readOmitted
        )
    )

    -- Phase 2: publish max_read=5, then two more turns (a big one and a small
    -- one) so the next compaction has a real user-message span to summarize.
    local f = assert(io.open(config_path, "w"))
    f:write('{"enabled":true,"cleaner":{"max_read":' .. tostring(MAX_READ_PHASE2) .. "}}")
    f:close()
    run_turn(backend, "Acknowledge this prompt.", 180000)
    run_turn(backend, "Read the large project file.", 180000)
    -- 2 phase-1 turns + 1 text turn + (read turn -> text turn) = 5.
    check(provider.turn == 5, "phase 2 ran every scripted turn", { turn = provider.turn })
    step("phase 2: runtime config republished, two more turns ran")

    response = run_compact(backend, "compact #2")
    check(response ~= nil, "compaction #2 returned an RPC response")
    step("compaction #2 finished")

    entries = session_entries(backend.session_dir)
    compactions = by_type(entries, "compaction")
    cleaners = custom_entries(entries, "pi2-compaction-cleaner")
    check(#compactions == 2, "two compaction entries after compaction #2", { count = #compactions })
    check(#cleaners == 2, "the cleaner wrote a second custom entry", { count = #cleaners })

    -- A5: the second compaction honours the new cap.
    local second = compactions[2]
    local second_paths = block_paths(read_files_block(second.summary))
    check(
        #second_paths > 0 and #second_paths <= MAX_READ_PHASE2,
        ("the second read list is capped at max_read=%d, got %d"):format(MAX_READ_PHASE2, #second_paths),
        { paths = second_paths }
    )
    check(
        type(second.details) == "table"
            and type(second.details.readFiles) == "table"
            and #second.details.readFiles <= MAX_READ_PHASE2,
        "the second compaction's native details are capped too",
        { details = second.details }
    )
    check(
        contains(second_paths, provider.big_path),
        "the most recent read survives the cap (recent entries are kept)",
        { paths = second_paths, big = provider.big_path }
    )
    local second_report = cleaners[2].data or {}
    check(second_report.strippedPrevious == true, "the second compaction stripped the previous file lists", {
        report = second_report,
    })
    check(
        second_report.readKept == #second.details.readFiles,
        "the second custom entry reports the kept read count",
        { report = second_report }
    )
    step(
        ("A5 second summary holds %d project paths (<= %d), strippedPrevious=true"):format(
            #second_paths,
            MAX_READ_PHASE2
        )
    )

    -- A4: what the summariser was actually handed. The stored first summary DID
    -- contain a <read-files> block (asserted above), so a request that carries
    -- <previous-summary> WITHOUT that block proves the strip happened before the
    -- prompt was built.
    check(#provider.summarizations >= 2, "both compactions issued summarisation requests", {
        count = #provider.summarizations,
    })
    local saw_previous = false
    for index, text in ipairs(provider.summarizations) do
        if text:find("<previous-summary>", 1, true) ~= nil then
            saw_previous = true
        end
        check(
            text:find("<read-files>", 1, true) == nil,
            "no summarisation request may carry a <read-files> block",
            { request = index }
        )
        check(
            text:find("</modified-files>", 1, true) == nil,
            "no summarisation request may carry a <modified-files> block",
            { request = index }
        )
    end
    check(saw_previous, "phase 2 must really take the update-prompt path (<previous-summary> present)")
    step(
        ("A4 %d summarisation requests, none carries a file list, the update path was used"):format(
            #provider.summarizations
        )
    )

    -- A1 (second half): the FIRST summary is what carried the list into the
    -- update prompt, so the strip above is the only reason A4 holds.
    check(
        read_files_block(first.summary) ~= nil,
        "the first summary keeps its native file block (the extension only bounds it)"
    )

    -- A6: nothing failed.
    local errors = {}
    for _, ev in ipairs(backend.events) do
        if ev.type == "extension_error" then
            errors[#errors + 1] = ev
        end
    end
    check(#errors == 0, "the extension never raised an error event", { errors = errors })
    for _, ev in ipairs(backend.events) do
        if ev.type == "response" and ev.command == "compact" and ev.success ~= true then
            error("a compact response failed: " .. vim.inspect(ev), 0)
        end
    end
    step("A6 no extension_error events, every compact response succeeded")

    stop_backend(backend)
    print(
        ("ALL compaction cleaner cases passed (scratch paths dropped, read list capped, previous lists stripped) in %.2fs"):format(
            (uv.hrtime() - run_started) / 1e9
        )
    )
    cleanup()
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e compaction: " .. tostring(err) .. "\n")
    cleanup()
    vim.cmd("cq 1")
end
