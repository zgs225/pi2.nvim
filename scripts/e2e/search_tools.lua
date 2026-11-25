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
-- Needs the pi binary, nothing else (the provider is fake), so it runs in CI:
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

---@class SearchToolsE2EProvider
---@field server? uv.uv_tcp_t
---@field requests table[] decoded request bodies, in arrival order

---@param provider SearchToolsE2EProvider
---@return SearchToolsE2EProvider
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
            -- Scheduled out of the libuv fast context so `vim.json` is used safely.
            vim.schedule(function()
                local ok, decoded = pcall(vim.json.decode, body)
                check(ok and type(decoded) == "table", "the provider received a JSON request body")
                provider.requests[#provider.requests + 1] = decoded
                pcall(client.write, client, text_response("hello"), function()
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

-- ---------------------------------------------------------------------------

local function cleanup()
    pcall(vim.fn.delete, RUN_ROOT, "rf")
end

local function main()
    if not deps.require_executable("pi", "pi binary not found in PATH (required for this e2e)") then
        return
    end
    vim.fn.mkdir(RUN_ROOT, "p")
    local agent_dir = RUN_ROOT .. "/agent"
    local cwd = RUN_ROOT .. "/cwd"

    -- The child pi inherits this env; nothing touches the user's real config.
    vim.env.PI_CODING_AGENT_DIR = agent_dir
    vim.env.PI_OFFLINE = "1"

    ---@type SearchToolsE2EProvider
    local provider = { requests = {} }
    start_fake_provider(provider)
    local addr = provider.server:getsockname()
    local port = type(addr) == "table" and addr.port or nil
    check(type(port) == "number" and port > 0, "fake provider did not bind a port", { addr = addr })
    write_agent_dir(agent_dir, port)
    check(vim.fn.filereadable(EXTENSION) == 1, "the bundled extension exists", { path = EXTENSION })
    step(("fixtures ready, provider on 127.0.0.1:%d"):format(port))

    -- ------------------------------------------------------------------
    -- Group A: WITH the extension.
    -- ------------------------------------------------------------------
    local a = start_backend(RUN_ROOT .. "/sessions-a", cwd, true)
    run_one_turn(a)
    check(#provider.requests >= 1, "group A issued a provider request", { count = #provider.requests })
    local a_request = provider.requests[1]
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
    local mark = #provider.requests
    local b = start_backend(RUN_ROOT .. "/sessions-b", cwd, false)
    run_one_turn(b)
    check(#provider.requests > mark, "group B issued a provider request", { mark = mark, count = #provider.requests })
    local b_request = provider.requests[mark + 1]
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

    print(
        (
            "ALL search-tools cases passed (the extension rewrites the bash snippet and description,\n"
            .. "adds grep/find/ls guidelines on the wire AND in the transcript, and the negative control\n"
            .. "keeps the stock pi prompt) in %.2fs"
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
