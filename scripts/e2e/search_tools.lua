-- Headless e2e: the bundled search-tools extension steers the model off `bash`.
--
-- pi's own bash tool advertises itself as `Execute bash commands (ls, grep,
-- find, etc.)`, and the dedicated grep/find/ls tools carry no
-- `promptGuidelines` at all — so the model reads "bash is how you search" and
-- shells out to rg/grep/find. This script proves the extension really changes
-- what the model is handed, at TWO independent sources:
--
--   1. the WIRE — the decoded request body a fake OpenAI-compatible provider
--      receives (what the model actually reads), and
--   2. the SESSION JSONL — the system message pi persisted.
--
-- A negative control (the same run WITHOUT the extension) proves the change
-- came from the extension and not from the fixture.
--
-- Group A (with `--extension extensions/search-tools.ts`) asserts:
--   A1 the system message carries `- bash: Execute shell commands (build, test, git, network, pipelines)`
--   A2 it no longer carries `Execute bash commands (ls, grep, find, etc.)`
--   A3-A5 it carries the grep / find / ls guidelines
--   A6 the bash tool declaration's `description` carries the search rule and no
--      longer advertises `(ls, grep, find, etc.)`
--   A7 the JSONL system message's `sections.tools` / `sections.rules` carry the
--      same strings
--   A8 the JSONL `toolsAdded` bash description is byte-identical to the wire one
-- Group B (no extension) is the control:
--   B1 the old bash snippet IS there
--   B2 the grep guideline is NOT there
--   B3 the bash declaration does NOT carry the search rule
--
-- Group C runs the extension's grep override for real (a fresh child per case, a
-- scripted `grep` toolCall, assertions on the persisted toolResult):
--   C1 output=files lists both matching files exactly once each (2 matches -> 1 path)
--   C2 output=count prints a.ts:2 and dist/c.ts:1
--   C3 exclude={"dist/**"} drops dist/c.ts and keeps a.ts
--   C4 output=count, max_per_file=1 caps a.ts at one match
--   C5 word=true does not match foobar.ts
--   C6 a call with no new parameter keeps the builtin `path:LINE: text` rows
--   C7 a match that only exists under .git/ reads as "No matches found"
--   C8 the same in count mode: every call is filtered, not just the new ones
--   C9 context lines survive the re-emit, and .git rows still do not
--
-- Needs the pi binary and ripgrep (the grep cases run it for real); no account,
-- the provider is fake, so it runs in CI:
--
--   make e2e-search-tools
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/search_tools.lua)

local deps = require("e2e_deps")

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/search-tools.ts"
local RUN_ROOT = vim.fn.tempname() .. "-search-tools"

local PROVIDER = "e2esys"
local MODEL_ID = "e2e-model"

-- The exact strings the extension must produce. Spelled once, so a drifting
-- snippet in either file turns this red instead of passing on a near-miss.
local NEW_SNIPPET_LINE = "- bash: Execute shell commands (build, test, git, network, pipelines)"
local OLD_SNIPPET_LINE = "- bash: Execute bash commands (ls, grep, find, etc.)"
local OLD_SNIPPET = "Execute bash commands (ls, grep, find, etc.)"
local GREP_GUIDELINE = "Use grep to search file contents instead of bash grep/rg/git grep"
local FIND_GUIDELINE = "Use find to locate files by glob instead of bash find/ls"
local LS_GUIDELINE = "Use ls to list a directory instead of bash ls/tree"
local BASH_RULE_HEAD = "Do NOT use this tool to search or read files"

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
-- The scripted fake provider (OpenAI chat-completions, streamed).
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
---@param prompt_tokens integer
---@return string
local function sse_usage_chunk(prompt_tokens)
    local completion = 5
    return ('data: {"id":"chatcmpl-e2e","object":"chat.completion.chunk","created":0,"model":"%s","choices":[],"usage":{"prompt_tokens":%d,"completion_tokens":%d,"total_tokens":%d}}\n\n'):format(
        MODEL_ID,
        prompt_tokens,
        completion,
        prompt_tokens + completion
    )
end

--- Every answer is plain assistant text: no tool call is ever issued, so the
--- conversation cannot wander and the first request stays the only one.
---@param text string
---@return string
local function text_response(text)
    return sse_headers()
        .. sse_chunk(vim.json.encode({ role = "assistant", content = text }))
        .. sse_chunk("{}", "stop")
        .. sse_usage_chunk(100)
        .. "data: [DONE]\n\n"
end

--- An assistant turn that calls one tool. The arguments ride as a JSON *string*,
--- the shape the OpenAI chat-completions stream uses.
---@param name string
---@param args table
---@return string
local function tool_call_response(name, args)
    local arguments = vim.json.encode(vim.json.encode(args))
    return sse_headers()
        .. sse_chunk('{"role":"assistant","content":""}')
        .. sse_chunk(
            ('{"tool_calls":[{"index":0,"id":"call_%s","type":"function","function":{"name":"%s","arguments":%s}}]}'):format(
                tostring(uv.hrtime()),
                name,
                arguments
            )
        )
        .. sse_chunk("{}", "tool_calls")
        .. sse_usage_chunk(100)
        .. "data: [DONE]\n\n"
end

---@class SearchToolsE2EProvider
---@field server? uv.uv_tcp_t
---@field requests table[] decoded request bodies, in arrival order
---@field turn integer requests answered since the current child started
---@field script fun(turn: integer, request: table): string the SSE answer for a turn

--- One provider serves every group: groups A/B answer plain text, group C swaps
--- `script` per case so the first turn calls `grep` instead.
---@type SearchToolsE2EProvider
local provider = {
    requests = {},
    turn = 0,
    script = function()
        return text_response("hello")
    end,
}

---@param script fun(turn: integer, request: table): string
---@return SearchToolsE2EProvider
local function start_provider(script)
    provider.script = script
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
            -- Scheduled out of the libuv fast context so `vim.json` is used safely.
            vim.schedule(function()
                local ok, decoded = pcall(vim.json.decode, body)
                check(ok and type(decoded) == "table", "the provider received a JSON request body")
                provider.requests[#provider.requests + 1] = decoded
                provider.turn = provider.turn + 1
                local answer = provider.script(provider.turn, decoded)
                pcall(client.write, client, answer, function()
                    pcall(client.close, client)
                end)
            end)
        end)
    end))
    return provider
end

-- ---------------------------------------------------------------------------
-- Fixtures: an isolated agent dir (models.json + settings.json).
-- ---------------------------------------------------------------------------

---@param dir string
---@param port integer
local function write_agent_dir(dir, port)
    vim.fn.mkdir(dir, "p")
    local models = {
        providers = {
            [PROVIDER] = {
                name = "E2ESys",
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
    local s = assert(io.open(dir .. "/settings.json", "w"))
    s:write("{}")
    s:close()
end

-- ---------------------------------------------------------------------------
-- RPC backend
-- ---------------------------------------------------------------------------

---@class SearchToolsE2EBackend
---@field job integer
---@field session_dir string
---@field events table[]
---@field stderr string
---@field request? table the request this child produced (set by run_group)

---@param session_dir string
---@param cwd string
---@param with_extension boolean
---@return SearchToolsE2EBackend
local function start_backend(session_dir, cwd, with_extension)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type SearchToolsE2EBackend
    local backend = { job = 0, session_dir = session_dir, events = {}, stderr = "" }
    local partial = { out = "" }
    local argv = { "pi", "--mode", "rpc" }
    if with_extension then
        argv[#argv + 1] = "--extension"
        argv[#argv + 1] = EXTENSION
    end
    vim.list_extend(argv, {
        "--tools",
        "read,bash,edit,write,grep,find,ls",
        "--no-mcp",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--session-dir",
        session_dir,
    })
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

---@param backend SearchToolsE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend SearchToolsE2EBackend
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

---@param backend SearchToolsE2EBackend
local function stop_backend(backend)
    pcall(vim.fn.chanclose, backend.job, "stdin")
    pcall(vim.fn.jobstop, backend.job)
    pcall(vim.fn.jobwait, { backend.job }, 5000)
end

--- Pin the fake model, send one prompt and wait for the run to settle. The
--- provider answers with plain text, so exactly ONE request reaches it.
---@param backend SearchToolsE2EBackend
local function run_one_turn(backend)
    send(backend, { id = "model-1", type = "set_model", provider = PROVIDER, modelId = MODEL_ID })
    local pinned = wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, "set_model")
    check(pinned ~= nil and pinned.success ~= false, "fake model selected", {
        pinned = pinned,
        stderr = backend.stderr,
    })
    local since = #backend.events
    send(backend, { id = "prompt-1", type = "prompt", message = "hello" })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > since
    end, 60000, "agent_settled")
    check(settled ~= nil, "the scripted run settles", { stderr = backend.stderr })
end

---@class RunGroupOpts
---@field name string how the group is named in its assertion ("group A")
---@field session_dir string a fresh session dir for the child
---@field cwd string the child's cwd
---@field with_extension boolean

--- Start one child, run one scripted turn and hand back the request it produced.
--- A/B differ only in `with_extension`; group C reuses this once per case.
---@param opts RunGroupOpts
---@return SearchToolsE2EBackend
local function run_group(opts)
    -- The turn counter is per child: each group gets a fresh conversation.
    provider.turn = 0
    local mark = #provider.requests
    local backend = start_backend(opts.session_dir, opts.cwd, opts.with_extension)
    run_one_turn(backend)
    check(#provider.requests > mark, ("%s issued a provider request"):format(opts.name), {
        mark = mark,
        count = #provider.requests,
    })
    backend.request = provider.requests[mark + 1]
    return backend
end

-- ---------------------------------------------------------------------------
-- Wire helpers
-- ---------------------------------------------------------------------------

--- The first system prompt text in a request body.
---@param request table
---@return string
local function system_text(request)
    local messages = request.messages
    check(type(messages) == "table", "the request carries messages", { keys = vim.tbl_keys(request) })
    for _, message in ipairs(messages) do
        if message.role == "system" or message.role == "developer" then
            local content = message.content
            if type(content) == "string" then
                return content
            end
            local parts = {}
            for _, block in ipairs(content) do
                if type(block) == "table" and block.type == "text" then
                    parts[#parts + 1] = block.text
                end
            end
            return table.concat(parts, "\n")
        end
    end
    check(false, "the request carries a system message", { messages = messages })
    return ""
end

--- The bash tool declaration a request carries.
---@param request table
---@return table
local function bash_declaration(request)
    check(type(request.tools) == "table", "the request declares tools", { keys = vim.tbl_keys(request) })
    for _, tool in ipairs(request.tools) do
        local fn = tool["function"] or tool.custom
        if type(fn) == "table" and fn.name == "bash" then
            return fn
        end
    end
    check(false, "the request declares the bash tool", { tools = vim.tbl_keys(request) })
    return {}
end

-- ---------------------------------------------------------------------------
-- Session JSONL (the second, independent source)
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

--- The first persisted `role == "system"` message.
---@param entries table[]
---@return table
local function first_system_message(entries)
    for _, entry in ipairs(entries) do
        if entry.type == "message" and type(entry.message) == "table" and entry.message.role == "system" then
            return entry.message
        end
    end
    check(false, "the transcript holds a system message", { entries = #entries })
    return {}
end

--- The bash entry of a system message's `toolsAdded` declaration list.
---@param message table
---@return table?
local function tools_added_bash(message)
    for _, tool in ipairs(message.toolsAdded or {}) do
        if tool.name == "bash" then
            return tool
        end
    end
    return nil
end

--- The text of the LAST persisted `role == "toolResult"` message for `tool_name`.
--- This is the tool's real result, not the model's summary of it.
---@param session_dir string
---@param tool_name string
---@return string?
local function tool_result_text(session_dir, tool_name)
    local found = nil
    for _, entry in ipairs(session_entries(session_dir)) do
        local message = entry.message
        if
            entry.type == "message"
            and type(message) == "table"
            and message.role == "toolResult"
            and message.toolName == tool_name
        then
            local parts = {}
            for _, block in ipairs(message.content or {}) do
                if type(block) == "table" and block.type == "text" then
                    parts[#parts + 1] = block.text
                end
            end
            found = table.concat(parts, "\n")
        end
    end
    return found
end

-- ---------------------------------------------------------------------------
-- Group C: the grep fixture, and the seven cases it proves.
-- ---------------------------------------------------------------------------

--- Group C's tree: just enough to tell the four new parameters apart.
--- No git init and no .gitignore: the tool must filter `.git/` itself, and
--- `dist/` must stay visible (only `exclude` hides it). `a.ts` carries a third,
--- NON-matching line so `context: 1` has a context row to emit (C9).
---@param dir string
local function write_grep_fixture(dir)
    vim.fn.mkdir(dir .. "/dist", "p")
    vim.fn.mkdir(dir .. "/.git/logs", "p")
    local files = {
        ["a.ts"] = "alpha one\nalpha two\nnothing here matches\n",
        ["dist/c.ts"] = "alpha three\n",
        [".git/logs/HEAD"] = "GITONLY32\n",
        ["foobar.ts"] = "foobar\n",
    }
    for name, text in pairs(files) do
        local file = assert(io.open(dir .. "/" .. name, "w"))
        file:write(text)
        file:close()
    end
end

---@class GrepCase
---@field name string the case id (C1…C7), also its assertion prefix
---@field what string one-line label for the [step] trace
---@field args table the `grep` toolCall arguments, spelled out verbatim
---@field check fun(text: string) assertions over the grep toolResult text

--- Every case proves that one parameter survives the trip to a real ripgrep run.
---@type GrepCase[]
local GREP_CASES = {
    {
        name = "C1",
        what = "output=files lists each matching file once",
        args = { pattern = "alpha", output = "files" },
        check = function(text)
            local lines = {}
            for line in text:gmatch("[^\n]+") do
                lines[#lines + 1] = line
            end
            local listed, a_ts = {}, 0
            for _, line in ipairs(lines) do
                listed[line] = true
                if line == "a.ts" then
                    a_ts = a_ts + 1
                end
            end
            check(listed["a.ts"] == true, "C1 files mode lists a.ts", { text = text })
            check(listed["dist/c.ts"] == true, "C1 files mode lists dist/c.ts", { text = text })
            check(a_ts == 1, "C1 files mode lists a.ts exactly once (two matches -> one path)", { text = text })
            check(#lines == 2, "C1 files mode lists exactly the two matching files", { text = text })
        end,
    },
    {
        name = "C2",
        what = "output=count prints path:N per file",
        args = { pattern = "alpha", output = "count" },
        check = function(text)
            check(text:find("a.ts:2", 1, true) ~= nil, "C2 count mode reports a.ts:2", { text = text })
            check(text:find("dist/c.ts:1", 1, true) ~= nil, "C2 count mode reports dist/c.ts:1", { text = text })
        end,
    },
    {
        name = "C3",
        what = "exclude globs drop dist/** from the results",
        args = { pattern = "alpha", exclude = { "dist/**" } },
        check = function(text)
            check(text:find("dist/c.ts", 1, true) == nil, "C3 exclude drops dist/c.ts", { text = text })
            check(text:find("a.ts:", 1, true) ~= nil, "C3 exclude keeps a.ts", { text = text })
        end,
    },
    {
        name = "C4",
        what = "max_per_file caps a file's rows",
        args = { pattern = "alpha", output = "count", max_per_file = 1 },
        check = function(text)
            check(text:find("a.ts:1", 1, true) ~= nil, "C4 max_per_file=1 caps a.ts at one match", { text = text })
        end,
    },
    {
        name = "C5",
        what = "word=true matches whole words only",
        args = { pattern = "foo", word = true },
        check = function(text)
            check(text:find("foobar.ts", 1, true) == nil, "C5 word mode does not match foobar.ts", { text = text })
        end,
    },
    {
        name = "C6",
        what = "no new parameter -> the builtin row format, unchanged",
        args = { pattern = "alpha" },
        check = function(text)
            local rows = 0
            for line in text:gmatch("[^\n]+") do
                rows = rows + 1
                check(line:match("^[^:]+:%d+: ") ~= nil, "C6 every row keeps the builtin `path:LINE: text` form", {
                    line = line,
                })
            end
            check(rows >= 3, "C6 the plain search returns both a.ts rows and dist/c.ts", { rows = rows, text = text })
        end,
    },
    {
        name = "C7",
        what = ".git is never searched",
        args = { pattern = "GITONLY32" },
        check = function(text)
            check(text == "No matches found", "C7 a .git-only match reads as No matches found", { text = text })
        end,
    },
    {
        name = "C8",
        what = "a new parameter filters .git too",
        args = { pattern = "GITONLY32", output = "count" },
        check = function(text)
            check(text == "No matches found", "C8 count mode reads a .git-only match as No matches found", {
                text = text,
            })
        end,
    },
    {
        name = "C9",
        what = "context rows survive the re-emit",
        args = { pattern = "alpha", context = 1 },
        check = function(text)
            local context_rows = {}
            for line in text:gmatch("[^\n]+") do
                if line:match("^[^-]+-%d+- ") ~= nil then
                    context_rows[#context_rows + 1] = line
                end
            end
            check(#context_rows > 0, "C9 context lines are kept, not dropped", { text = text })
            check(text:find(".git", 1, true) == nil, "C9 no .git path leaks through", { text = text })
        end,
    },
}

--- One case: a fresh child (own session dir), a scripted `grep` toolCall on turn
--- 1, plain text on turn 2, then the grep toolResult read back out of the JSONL.
---@param index integer
---@param case GrepCase
---@param cwd string
---@return string text
local function run_grep_case(index, case, cwd)
    provider.script = function(turn)
        if turn == 1 then
            return tool_call_response("grep", case.args)
        end
        return text_response("done")
    end
    local backend = run_group({
        name = case.name,
        session_dir = ("%s/sessions-c%d"):format(RUN_ROOT, index),
        cwd = cwd,
        with_extension = true,
    })
    local text = tool_result_text(backend.session_dir, "grep")
    stop_backend(backend)
    check(text ~= nil, case.name .. " the transcript holds a grep toolResult", case.args)
    ---@cast text string
    return text
end

-- ---------------------------------------------------------------------------

local function cleanup()
    pcall(vim.fn.delete, RUN_ROOT, "rf")
end

local function main()
    if not deps.require_executable("pi", "pi binary not found in PATH (required for this e2e)") then
        return
    end
    if not deps.require_executable("rg", "ripgrep (rg) not found in PATH (the grep tool needs it)") then
        return
    end
    vim.fn.mkdir(RUN_ROOT, "p")
    local agent_dir = RUN_ROOT .. "/agent"
    local cwd = RUN_ROOT .. "/cwd"

    -- The child pi inherits this env; nothing touches the user's real config.
    vim.env.PI_CODING_AGENT_DIR = agent_dir
    vim.env.PI_OFFLINE = "1"

    start_provider(function()
        return text_response("hello")
    end)
    local addr = provider.server:getsockname()
    local port = type(addr) == "table" and addr.port or nil
    check(type(port) == "number" and port > 0, "fake provider did not bind a port", { addr = addr })
    write_agent_dir(agent_dir, port)
    check(vim.fn.filereadable(EXTENSION) == 1, "the bundled extension exists", { path = EXTENSION })
    step(("fixtures ready, provider on 127.0.0.1:%d"):format(port))

    -- ------------------------------------------------------------------
    -- Group A: WITH the extension.
    -- ------------------------------------------------------------------
    local a = run_group({
        name = "group A",
        session_dir = RUN_ROOT .. "/sessions-a",
        cwd = cwd,
        with_extension = true,
    })
    local a_request = a.request
    local a_text = system_text(a_request)
    print("[A system] " .. (a_text:match("[^\n]*bash[^\n]*") or "(no bash line)"))
    step("A: one scripted turn with the extension")

    -- A1
    check(
        a_text:find(NEW_SNIPPET_LINE, 1, true) ~= nil,
        "A1 the system prompt carries the rewritten bash snippet",
        { wanted = NEW_SNIPPET_LINE }
    )
    -- A2
    check(
        a_text:find(OLD_SNIPPET, 1, true) == nil,
        "A2 the system prompt no longer advertises grep/find in the bash snippet"
    )
    -- A3-A5
    check(a_text:find(GREP_GUIDELINE, 1, true) ~= nil, "A3 the grep guideline is in the rules", {
        wanted = GREP_GUIDELINE,
    })
    check(a_text:find(FIND_GUIDELINE, 1, true) ~= nil, "A4 the find guideline is in the rules", {
        wanted = FIND_GUIDELINE,
    })
    check(a_text:find(LS_GUIDELINE, 1, true) ~= nil, "A5 the ls guideline is in the rules", {
        wanted = LS_GUIDELINE,
    })
    step("A1-A5 system prompt: new bash snippet, grep/find/ls guidelines, old snippet gone")

    -- A6
    local a_bash = bash_declaration(a_request)
    local a_description = a_bash.description or ""
    print("[A bash description] " .. a_description:sub(1, 200):gsub("\n", " / "))
    check(
        a_description:find(BASH_RULE_HEAD, 1, true) ~= nil,
        "A6 the bash declaration carries the search rule",
        { wanted = BASH_RULE_HEAD }
    )
    check(
        a_description:find("(ls, grep, find, etc.)", 1, true) == nil,
        "A6 the bash declaration no longer advertises (ls, grep, find, etc.)"
    )
    step("A6 bash declaration: search rule present, ls/grep/find advertisement gone")

    -- A7: the session JSONL system message carries the same strings.
    local a_system = first_system_message(session_entries(a.session_dir))
    local a_sections = a_system.sections or {}
    local a_tools_section = a_sections.tools or ""
    local a_rules_section = a_sections.rules or ""
    check(
        a_tools_section:find(NEW_SNIPPET_LINE, 1, true) ~= nil,
        "A7 sections.tools carries the rewritten snippet",
        { wanted = NEW_SNIPPET_LINE }
    )
    check(a_rules_section:find(GREP_GUIDELINE, 1, true) ~= nil, "A7 sections.rules carries the grep guideline")
    check(a_rules_section:find(FIND_GUIDELINE, 1, true) ~= nil, "A7 sections.rules carries the find guideline")
    check(a_rules_section:find(LS_GUIDELINE, 1, true) ~= nil, "A7 sections.rules carries the ls guideline")
    step("A7 transcript sections: tools/rules match the wire")

    -- A8: the persisted declaration is byte-identical to the one on the wire.
    local a_added = tools_added_bash(a_system)
    check(a_added ~= nil, "A8 the transcript declares the bash tool", {
        added = vim.tbl_map(function(tool)
            return tool.name
        end, a_system.toolsAdded or {}),
    })
    check(
        a_added.description == a_description,
        "A8 the transcript's bash description is byte-identical to the wire one",
        { jsonl = #a_added.description, wire = #a_description }
    )
    step("A8 transcript toolsAdded bash description == wire description")

    stop_backend(a)

    -- ------------------------------------------------------------------
    -- Group B: WITHOUT the extension (negative control).
    -- ------------------------------------------------------------------
    local b = run_group({
        name = "group B",
        session_dir = RUN_ROOT .. "/sessions-b",
        cwd = cwd,
        with_extension = false,
    })
    local b_request = b.request
    local b_text = system_text(b_request)
    print("[B system] " .. (b_text:match("[^\n]*bash[^\n]*") or "(no bash line)"))
    step("B: one scripted turn without the extension")

    -- B1
    check(
        b_text:find(OLD_SNIPPET, 1, true) ~= nil,
        "B1 (control) the stock bash snippet is still there",
        { wanted = OLD_SNIPPET }
    )
    check(
        b_text:find(OLD_SNIPPET_LINE, 1, true) ~= nil,
        "B1 (control) the stock snippet line is spelled as pi writes it",
        { wanted = OLD_SNIPPET_LINE }
    )
    -- B2
    check(
        b_text:find(GREP_GUIDELINE, 1, true) == nil,
        "B2 (control) the grep guideline is NOT injected without the extension"
    )
    -- B3
    local b_description = bash_declaration(b_request).description or ""
    check(
        b_description:find(BASH_RULE_HEAD, 1, true) == nil,
        "B3 (control) the bash declaration carries no search rule"
    )
    step("B1-B3 control: stock snippet, no guidelines, no search rule")

    stop_backend(b)

    -- ------------------------------------------------------------------
    -- Group C: grep really runs — the new parameters against real ripgrep.
    -- ------------------------------------------------------------------
    write_grep_fixture(cwd)
    for index, case in ipairs(GREP_CASES) do
        local text = run_grep_case(index, case, cwd)
        print(("[%s] %s"):format(case.name, (text:gsub("\n", " | "):sub(1, 120))))
        case.check(text)
        step(case.name .. ": " .. case.what)
    end

    print(
        (
            "ALL search-tools cases passed (the extension rewrites the bash snippet and description,\n"
            .. "adds grep/find/ls guidelines on the wire AND in the transcript, the negative control\n"
            .. "keeps the stock pi prompt, and the grep override runs a real ripgrep with its new\n"
            .. "parameters) in %.2fs"
        ):format((uv.hrtime() - run_started) / 1e9)
    )
    cleanup()
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e search_tools: " .. tostring(err) .. "\n")
    cleanup()
    vim.cmd("cq 1")
end
