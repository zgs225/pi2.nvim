-- Headless e2e: a spawn item that names `worktree = { path = <abs> }` really
-- runs its child in that linked checkout, and never in the parent's.
--
-- Unlike tests/*_spec.lua (fake processes, fake git), this drives the real
-- chain end to end:
--   * a real temp git repo with a real **manually created** linked worktree
--     (`git worktree add`, outside `<repo>/.worktrees/`),
--   * a real `pi --mode rpc` child started through the real host bridge
--     (`Subsessions.handle_host` -> Batch -> `Subsessions.spawn`),
--   * a local fake OpenAI-compatible provider that answers the first turn with
--     a `bash` **tool call**, so the child itself writes a unique sentinel in
--     whatever cwd it really has (no real account/quota is used),
--   * the real manifest (`.pi2-subsessions.json`) under a throwaway
--     `PI_CODING_AGENT_DIR` — the user's session store is never read or
--     written.
--
-- What is asserted:
--   * the child's real cwd is the linked worktree — proven three ways: the
--     RPC `bash` command reports `pwd -P`, the session header records it, and
--     the model-driven sentinel file only exists inside the checkout;
--   * the parent main checkout is untouched (HEAD, `git status --porcelain`,
--     file list, no sentinel);
--   * the manifest row records `assigned_worktree.path`, the parent's
--     `workspace`, and a readable `session_file` whose header cwd is the
--     worktree;
--   * close keeps the assigned checkout, whether it is clean or dirty (an
--     assignment is never released), and the row keeps the assignment;
--   * revive reuses that checkout as cwd;
--   * after the checkout is deleted, revive fails closed with an error — no
--     process, no new transcript, no manifest write, nothing spawned in the
--     parent's workspace.
--   * a second, `worktree = { create = { name, base } }` item gets a brand-new
--     checkout under `<repo>/.worktrees/` (a real `git worktree add`), the row
--     records it as **owned**, the child really runs there, and closing the
--     clean checkout releases it again (the assigned one above never is).
--
-- Needs the pi binary, so it is NOT part of `make test` or CI. Run from the
-- repo root:
--   make e2e-subagent-worktree
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/subagent_worktree.lua)

local uv = vim.uv

local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")
local Reaper = require("pi.subsessions.reaper")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")

local TASK = "Run the sentinel check in your working directory."
local CHILD_NAME = "e2e-worktree"
local PROVIDER = "fakee2e"
local MODEL_ID = "e2e-model"

local NONCE = ("%s-%d"):format(os.date("%Y%m%d%H%M%S"), uv.os_getpid())
local ROOT = vim.fn.tempname() .. "-e2e-subagent-worktree"
local AGENT = ROOT .. "/agent"
local REPO = ROOT .. "/repo"
local WT = ROOT .. "/assigned-wt"
local SENTINEL = ".e2e-sentinel-" .. NONCE .. ".txt"
local DIRTY = "dirty-" .. NONCE .. ".txt"

io.stdout:setvbuf("no")
local run_started = uv.hrtime()
local last_step = run_started

---@return number elapsed seconds since the previous step marker
local function step(name)
    local t = uv.hrtime()
    print(string.format("[step] %-58s +%6.2fs (total %7.2fs)", name, (t - last_step) / 1e9, (t - run_started) / 1e9))
    last_step = t
end

--- Assert with context: on failure prints FAIL + context via the outer handler.
---@param cond boolean
---@param msg string
---@param ctx? table
local function check(cond, msg, ctx)
    if cond then
        print("[ok]   " .. msg)
        return
    end
    local detail = ""
    if ctx ~= nil then
        detail = " | ctx=" .. vim.inspect(ctx, { newline = " ", indent = "" })
    end
    error(msg .. detail, 0)
end

---@param path string?
---@return string?
local function read_file(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

---@param path string
---@param content string
local function write_file(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

---@param path string?
---@return string
local function realpath(path)
    if type(path) ~= "string" or path == "" then
        return ""
    end
    return uv.fs_realpath(path) or path
end

---@param path string?
---@return boolean
local function exists(path)
    return type(path) == "string" and path ~= "" and uv.fs_stat(path) ~= nil
end

---@param argv string[]
---@param cwd? string
---@return integer code, string stdout, string stderr
local function sh(argv, cwd)
    local res = vim.system(argv, { text = true, cwd = cwd, timeout = 60000 }):wait()
    return res.code or -1, res.stdout or "", res.stderr or ""
end

--- git with failure detection.
---@param argv string[]
---@param cwd string
---@return string stdout
local function git(argv, cwd)
    local full = { "git" }
    vim.list_extend(full, argv)
    local code, out, err = sh(full, cwd)
    if code ~= 0 then
        error(("git %s failed in %s (code %d): %s%s"):format(table.concat(argv, " "), cwd, code, err, out), 0)
    end
    return out
end

---@param cwd string
---@return string
local function head_sha(cwd)
    return (git({ "rev-parse", "HEAD" }, cwd):gsub("%s+$", ""))
end

--- Sorted list of regular files under `dir`, relative to it.
---@param dir string
---@return string[]
local function list_files(dir)
    if not exists(dir) then
        return {}
    end
    local files = {}
    for _, path in ipairs(vim.fn.globpath(dir, "**/*", false, true)) do
        local stat = uv.fs_stat(path)
        if stat and stat.type == "file" then
            files[#files + 1] = path:sub(#dir + 2)
        end
    end
    table.sort(files)
    return files
end

---@param a string[]
---@param b string[]
---@return boolean
local function same_list(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

--- cwd recorded in a session transcript's header line.
---@param path string
---@return string?
local function session_header_cwd(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local line = f:read("*l")
    f:close()
    if not line then
        return nil
    end
    local ok, header = pcall(vim.json.decode, line)
    if not ok or type(header) ~= "table" then
        return nil
    end
    return type(header.cwd) == "string" and header.cwd or nil
end

-- ---------------------------------------------------------------------------
-- Fake OpenAI-compatible provider.
--
-- The first request (no tool result in the conversation yet) answers with a
-- streamed `bash` tool call that writes the unique sentinel into the process
-- cwd; every later request answers with the text `DONE`. The shape was
-- captured from real pi output (see `scripts/e2e/subagent_failure.lua` for the
-- error variant), so this spends no quota and stays deterministic.
-- ---------------------------------------------------------------------------

---@class E2EFakeProvider
---@field server? uv.uv_tcp_t
---@field port? integer
---@field calls integer
---@field command string Tool-call command the child is told to run.
---@field clients table<integer, uv.uv_tcp_t>

---@param delta_json string
---@param finish_json string
---@return string
local function sse_chunk(delta_json, finish_json)
    return 'data: {"id":"chatcmpl-e2e","object":"chat.completion.chunk","created":0,"model":"e2e-model","choices":[{"index":0,"delta":'
        .. delta_json
        .. ',"finish_reason":'
        .. finish_json
        .. "}]}\n\n"
end

---@param provider E2EFakeProvider
---@param body string
---@return string payload
local function build_sse(provider, body)
    local has_tool_result = body:find('"role"%s*:%s*"tool"') ~= nil
    local chunks = {}
    if provider.calls == 1 and not has_tool_result then
        local args = vim.json.encode({ command = provider.command })
        chunks[#chunks + 1] = sse_chunk('{"role":"assistant","content":null}', "null")
        chunks[#chunks + 1] = sse_chunk(
            '{"tool_calls":[{"index":0,"id":"call_e2e_1","type":"function","function":{"name":"bash","arguments":""}}]}',
            "null"
        )
        chunks[#chunks + 1] =
            sse_chunk('{"tool_calls":[{"index":0,"function":{"arguments":' .. vim.json.encode(args) .. "}}]}", "null")
        chunks[#chunks + 1] = sse_chunk("{}", '"tool_calls"')
    else
        chunks[#chunks + 1] = sse_chunk('{"role":"assistant","content":""}', "null")
        chunks[#chunks + 1] = sse_chunk('{"content":"DONE"}', "null")
        chunks[#chunks + 1] = sse_chunk("{}", '"stop"')
    end
    chunks[#chunks + 1] = "data: [DONE]\n\n"
    return table.concat(chunks)
end

---@param provider E2EFakeProvider
---@param client uv.uv_tcp_t
---@param body string
local function answer(provider, client, body)
    provider.calls = provider.calls + 1
    local payload = build_sse(provider, body)
    local head = table.concat({
        "HTTP/1.1 200 OK",
        "Content-Type: text/event-stream",
        "Cache-Control: no-cache",
        "Connection: close",
        "Content-Length: " .. #payload,
        "",
        "",
    }, "\r\n")
    client:write(head .. payload, function()
        pcall(client.close, client)
    end)
end

--- Start the fake provider on 127.0.0.1 and return its handle.
---@param command string
---@return E2EFakeProvider
local function start_fake_provider(command)
    ---@type E2EFakeProvider
    local provider = { calls = 0, command = command, clients = {} }
    provider.server = assert(uv.new_tcp())
    assert(provider.server:bind("127.0.0.1", 0))
    assert(provider.server:listen(16, function(err)
        if err then
            print("[server] listen error: " .. tostring(err))
            return
        end
        local client = assert(uv.new_tcp())
        provider.server:accept(client)
        provider.clients[#provider.clients + 1] = client
        local buffer = ""
        local answered = false
        client:read_start(function(read_err, chunk)
            if read_err or not chunk then
                pcall(client.close, client)
                return
            end
            buffer = buffer .. chunk
            local sep_start, sep_end = buffer:find("\r\n\r\n", 1, true)
            if not sep_start then
                return
            end
            local headers = buffer:sub(1, sep_start - 1)
            local length = tonumber(headers:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
            local body = buffer:sub(sep_end + 1)
            if #body < length then
                return
            end
            if answered then
                return
            end
            answered = true
            client:read_stop()
            answer(provider, client, body:sub(1, length))
        end)
    end))
    local addr = provider.server:getsockname()
    provider.port = type(addr) == "table" and addr.port or 0
    return provider
end

---@param provider E2EFakeProvider?
local function stop_fake_provider(provider)
    if not provider then
        return
    end
    for _, client in ipairs(provider.clients) do
        pcall(client.close, client)
    end
    pcall(provider.server.close, provider.server)
end

--- Write an isolated agent dir: our own models.json + an empty settings.json.
---@param agent_dir string
---@param port integer
local function write_agent_dir(agent_dir, port)
    vim.fn.mkdir(agent_dir, "p")
    write_file(
        agent_dir .. "/models.json",
        vim.json.encode({
            providers = {
                [PROVIDER] = {
                    name = "FakeE2E",
                    baseUrl = ("http://127.0.0.1:%d/v1"):format(port),
                    apiKey = "sk-e2e-test",
                    api = "openai-completions",
                    models = {
                        {
                            id = MODEL_ID,
                            name = "E2E Model",
                            contextWindow = 8000,
                            maxTokens = 1024,
                            cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 },
                        },
                    },
                },
            },
        })
    )
    write_file(agent_dir .. "/settings.json", "{}")
end

-- ---------------------------------------------------------------------------
-- Await helpers.
-- ---------------------------------------------------------------------------

--- Wait for `cond`; fails the run on timeout.
---@param cond fun(): boolean
---@param ms integer
---@param label string
local function wait(cond, ms, label)
    if not vim.wait(ms, cond, 50) then
        check(false, "timed out waiting for " .. label)
    end
end

--- Run a callback-style function and return its packed arguments.
---@param fn fun(cb: fun(...))
---@param ms integer
---@param label string
---@return table
local function call(fn, ms, label)
    local pack
    fn(function(...)
        pack = { n = select("#", ...), ... }
    end)
    wait(function()
        return pack ~= nil
    end, ms, label)
    return pack
end

---@param batch_id string
---@param timeout_ms integer
---@param cwd string
---@return table? snapshot
local function wait_terminal(batch_id, timeout_ms, cwd)
    local snapshot
    vim.wait(timeout_ms, function()
        local snap = Batch.poll(batch_id, cwd)
        if not snap then
            return false
        end
        if
            snap.status == "completed"
            or snap.status == "partial"
            or snap.status == "failed"
            or snap.status == "cancelled"
        then
            snapshot = snap
            return true
        end
        return false
    end, 200)
    return snapshot
end

--- Run one bash command through the child's RPC (the backend executes it in
--- the session's real cwd) and return its trimmed stdout.
---@param child pi.Session
---@param command string
---@return string output
local function rpc_bash(child, command)
    local pack = call(function(cb)
        child.rpc:send({ type = "bash", command = command, excludeFromContext = true }, cb)
    end, 30000, "child RPC bash: " .. command)
    local res = pack[1]
    check(type(res) == "table" and res.success == true, "RPC bash succeeded: " .. command, { res = res })
    local output = type(res.data) == "table" and res.data.output or nil
    check(type(output) == "string", "RPC bash returned output: " .. command, { res = res })
    return (output:gsub("%s+$", ""))
end

---@param child_id string
---@return boolean
local function child_running(child_id)
    local child = Sessions.get_by_id(child_id)
    return child ~= nil and child.rpc ~= nil and child.rpc:is_running() == true
end

---@param child pi.Session
---@return string session_id, string session_file
local function rpc_get_state(child)
    local pack = call(function(cb)
        child.rpc:send({ type = "get_state" }, cb)
    end, 30000, "child RPC get_state")
    local res = pack[1]
    check(type(res) == "table" and res.success == true, "get_state succeeded", { res = res })
    local data = res.data or {}
    return data.sessionId, data.sessionFile
end

-- ---------------------------------------------------------------------------

local agent_dir_set = false
local server
local ok, failure = pcall(function()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(ROOT, "p")
    vim.fn.mkdir(REPO, "p")

    -- Hermetic: the child inherits this env, and the plugin resolves its
    -- manifest/session lookups through the same throwaway dir.
    vim.env.PI_CODING_AGENT_DIR = AGENT
    vim.env.PI_OFFLINE = "1"
    agent_dir_set = true
    -- Never touch the user's draft/prompt-history files.
    pcall(function()
        require("pi.draft")._set_path(ROOT .. "/draft.txt")
    end)

    -- A real repository with a real, manually created linked worktree.
    git({ "init", "-q", "-b", "main" }, REPO)
    git({ "config", "user.email", "e2e@example.invalid" }, REPO)
    git({ "config", "user.name", "e2e" }, REPO)
    write_file(REPO .. "/README.md", "# e2e\n")
    -- Pre-ignored so a created checkout never dirties the parent checkout (the
    -- "parent unchanged" assertions below would otherwise trip on a generated
    -- `.gitignore`).
    write_file(REPO .. "/.gitignore", "/.worktrees/\n")
    git({ "add", "-A" }, REPO)
    git({ "commit", "-q", "-m", "init" }, REPO)
    git({ "worktree", "add", "-q", "-b", "e2e-assigned-" .. NONCE, WT }, REPO)
    check(exists(WT .. "/.git"), "manual linked worktree created outside the repo", { wt = WT })
    step("temp git repo + manual linked worktree")

    local parent_head = head_sha(REPO)
    local parent_status = git({ "status", "--porcelain" }, REPO)
    local parent_files = list_files(REPO)
    local worktree_list_before = git({ "worktree", "list", "--porcelain" }, REPO)

    local command = ("printf '%%s\\n' '%s' > %s && pwd -P"):format(NONCE, SENTINEL)
    server = start_fake_provider(command)
    check(server.port > 0, "fake provider bound a port", { port = server.port })
    write_agent_dir(AGENT, server.port)
    step(("fake provider on 127.0.0.1:%d, agent dir %s"):format(server.port, AGENT))

    require("pi").setup({ title = { lang = "en" } })

    -- Fake parent: only an id/lineage/workspace the spawn can bind to. The
    -- batch path claims the settle itself, so no parent process is needed.
    ---@type pi.Session
    local parent = {
        id = "e2e-worktree-parent-" .. NONCE,
        conversation_epoch = 0,
        cwd = REPO,
        attached_tab = vim.api.nvim_get_current_tabpage(),
        rpc = {
            is_running = function()
                return true
            end,
            send = function()
                return true
            end,
        },
    }
    Sessions._register_for_test(parent)
    step("pi.setup + fake parent session")

    local dispatched
    Subsessions.handle_host(
        parent,
        vim.json.encode({
            action = "dispatch_subagents",
            params = {
                items = {
                    {
                        ref = "wt",
                        task = TASK,
                        name = CHILD_NAME,
                        model = { provider = PROVIDER, id = MODEL_ID },
                        tools = { "bash" },
                        worktree = { path = WT },
                    },
                },
            },
        }),
        function(res)
            dispatched = res
        end
    )
    check(
        type(dispatched) == "table" and type(dispatched.batch_id) == "string",
        "dispatch_subagents returned a batch id",
        { result = dispatched }
    )
    local batch_id = dispatched.batch_id
    step("dispatched batch " .. batch_id)

    local snap = wait_terminal(batch_id, 180000, REPO)
    check(snap ~= nil, "batch never reached a terminal state", { poll = Batch.poll(batch_id, REPO) })
    step(("batch terminal: %s"):format(snap.status))
    check(snap.status == "completed", "batch status is `completed`", { status = snap.status })
    local item = snap.items[1]
    check(type(item) == "table", "batch snapshot has an item", { snap = snap })
    check(item.status == "ok", "the child run settled as `ok`", { item = item })
    check(snap.summary.ok == 1 and snap.summary.failed == 0, "summary counts one ok", { summary = snap.summary })
    check(
        type(item.output) == "string" and item.output:find("DONE", 1, true) ~= nil,
        "the child's final turn reached the batch as output",
        { output = item.output }
    )
    local child_id = item.target
    check(type(child_id) == "string" and child_id ~= "", "item records the child id", { item = item })
    check(
        type(item.worktree) == "table" and realpath(item.worktree.path) == realpath(WT),
        "batch item surfaces the canonical assigned worktree",
        { worktree = item.worktree }
    )

    -- The model-driven proof: the child wrote the sentinel through its own
    -- bash tool, relative to its cwd.
    local sentinel_path = WT .. "/" .. SENTINEL
    check(exists(sentinel_path), "the child wrote the sentinel inside the linked worktree", {
        path = sentinel_path,
    })
    check(read_file(sentinel_path) == NONCE .. "\n", "the sentinel carries this run's nonce", {
        content = read_file(sentinel_path),
    })
    check(not exists(REPO .. "/" .. SENTINEL), "the parent main checkout has no sentinel", {
        path = REPO .. "/" .. SENTINEL,
    })
    local wt_status = git({ "status", "--porcelain" }, WT)
    check(wt_status:find(SENTINEL, 1, true) ~= nil, "git sees the sentinel as an untracked file in the worktree", {
        status = wt_status,
    })
    step("sentinel written by the model tool call, only in the worktree")

    -- The child's real cwd, three independent ways.
    local child = Sessions.get_by_id(child_id)
    check(child ~= nil, "child session is registered", { child_id = child_id })
    check(child.rpc:is_running() == true, "child process is alive after settling")
    check(realpath(child.cwd) == realpath(WT), "plugin session cwd is the worktree root", { cwd = child.cwd })
    check(
        type(child.assigned_worktree) == "table" and realpath(child.assigned_worktree.path) == realpath(WT),
        "session records the assignment (not an owned worktree)",
        { assigned = child.assigned_worktree }
    )
    check(child.worktree == nil, "the child does not own the checkout", { worktree = child.worktree })

    local bash_pwd = rpc_bash(child, "pwd -P")
    check(realpath(bash_pwd) == realpath(WT), "RPC bash runs in the worktree root (real process cwd)", {
        pwd = bash_pwd,
        wt = WT,
    })

    local state_id, state_file = rpc_get_state(child)
    check(state_id == child_id, "get_state reports the manifest child id", { state_id = state_id, child_id = child_id })
    check(
        type(state_file) == "string" and exists(state_file),
        "get_state reports a readable session file",
        { state_file = state_file }
    )
    step("child cwd proven via get_state + RPC bash pwd")

    -- Manifest row.
    local entry = Manifest.load(REPO)[child_id]
    check(type(entry) == "table", "manifest row exists in the parent workspace", { child_id = child_id })
    check(
        type(entry.assigned_worktree) == "table" and realpath(entry.assigned_worktree.path) == realpath(WT),
        "manifest records assigned_worktree.path",
        { assigned = entry.assigned_worktree }
    )
    check(realpath(entry.workspace) == realpath(REPO), "manifest workspace is the parent main checkout", {
        workspace = entry.workspace,
    })
    check(entry.worktree == nil, "manifest carries no owned-worktree record for an assignment", {
        worktree = entry.worktree,
    })
    local session_file = entry.session_file
    check(exists(session_file), "manifest records a readable session_file", { session_file = session_file })
    check(
        realpath(session_file):sub(1, #realpath(AGENT)) == realpath(AGENT),
        "session_file lives under the throwaway agent dir (no user session store)",
        { session_file = session_file, agent = AGENT }
    )
    check(
        realpath(session_header_cwd(session_file)) == realpath(WT),
        "transcript header records the worktree as cwd",
        { header_cwd = session_header_cwd(session_file) }
    )
    check(
        realpath(state_file) == realpath(session_file),
        "get_state session file matches the manifest row",
        { state_file = state_file, session_file = session_file }
    )
    step("manifest assigned_worktree / workspace / session_file verified")

    -- Parent main checkout unchanged.
    check(head_sha(REPO) == parent_head, "parent HEAD is unchanged", { head = head_sha(REPO) })
    check(git({ "status", "--porcelain" }, REPO) == parent_status, "parent git status is unchanged")
    check(same_list(list_files(REPO), parent_files), "parent file list is unchanged", {
        files = list_files(REPO),
    })
    step("parent main checkout unchanged")

    -- Close a CLEAN assigned checkout: it must survive.
    Subsessions.close(child_id)
    wait(function()
        return not child_running(child_id)
    end, 30000, "child process to stop")
    check(exists(WT), "clean assigned checkout survives close", { wt = WT })
    check(exists(sentinel_path), "the worktree's own file survives close")
    entry = Manifest.load(REPO)[child_id]
    check(type(entry) == "table" and entry.status == "dormant", "close marks the row dormant", {
        status = entry and entry.status,
    })
    check(
        type(entry.assigned_worktree) == "table" and realpath(entry.assigned_worktree.path) == realpath(WT),
        "close keeps the assignment on the row",
        { assigned = entry.assigned_worktree }
    )
    step("close retained the clean assigned checkout")

    -- Revive keeps the worktree as cwd.
    local revive_pack = call(function(cb)
        Subsessions.revive(child_id, cb)
    end, 60000, "revive the child")
    local revived, revive_err = revive_pack[1], revive_pack[2]
    check(revived ~= nil, "revive succeeded while the checkout exists", { err = revive_err })
    check(revived.rpc:is_running() == true, "revived process is alive")
    check(realpath(revived.cwd) == realpath(WT), "revive keeps the worktree as cwd", { cwd = revived.cwd })
    check(realpath(rpc_bash(revived, "pwd -P")) == realpath(WT), "revived process really runs in the worktree")
    local revived_entry = Manifest.load(REPO)[child_id]
    check(
        type(revived_entry) == "table"
            and type(revived_entry.assigned_worktree) == "table"
            and realpath(revived_entry.assigned_worktree.path) == realpath(WT),
        "revive keeps assigned_worktree on the row",
        { assigned = revived_entry and revived_entry.assigned_worktree }
    )
    step("revive preserved the worktree cwd")

    -- Close a DIRTY assigned checkout: still must survive (never released).
    write_file(WT .. "/" .. DIRTY, "keep me\n")
    Subsessions.close(child_id)
    wait(function()
        return not child_running(child_id)
    end, 30000, "revived child to stop")
    check(exists(WT) and exists(WT .. "/" .. DIRTY), "dirty assigned checkout survives close", { wt = WT })
    wt_status = git({ "status", "--porcelain" }, WT)
    check(wt_status:find(DIRTY, 1, true) ~= nil, "uncommitted work is still on disk after close", {
        status = wt_status,
    })
    step("close retained the dirty assigned checkout")

    -- Delete the checkout, then revive must fail closed — never fall back to
    -- the parent workspace.
    local manifest_path = Manifest.path(REPO)
    local manifest_before = read_file(manifest_path)
    local transcripts_before = list_files(AGENT .. "/sessions")
    git({ "worktree", "remove", "--force", WT }, REPO)
    check(not exists(WT), "the linked worktree is gone", { wt = WT })
    check(
        git({ "worktree", "list", "--porcelain" }, REPO) ~= worktree_list_before,
        "git no longer lists the removed worktree"
    )

    local revive_failed_pack = call(function(cb)
        Subsessions.revive(child_id, cb)
    end, 30000, "revive after the checkout was deleted")
    local failed_child, failed_err = revive_failed_pack[1], revive_failed_pack[2]
    check(failed_child == nil, "revive fails instead of relaunching somewhere else", {
        child = type(failed_child),
    })
    check(
        type(failed_err) == "string" and (failed_err:find("worktree", 1, true) or failed_err:find(WT, 1, true)),
        "revive error names the missing worktree",
        { err = failed_err }
    )
    local after = Sessions.get_by_id(child_id)
    check(after == nil or after.rpc:is_running() == false, "no process was left running for the child", {
        child = type(after),
    })
    check(same_list(list_files(AGENT .. "/sessions"), transcripts_before), "revive wrote no new transcript", {
        before = #transcripts_before,
        after = #list_files(AGENT .. "/sessions"),
    })
    check(read_file(manifest_path) == manifest_before, "revive wrote nothing to the parent workspace manifest")
    check(git({ "status", "--porcelain" }, REPO) == parent_status, "parent git status is still unchanged")
    check(head_sha(REPO) == parent_head, "parent HEAD is still unchanged")
    check(not exists(REPO .. "/" .. SENTINEL), "no sentinel appeared in the parent checkout")
    for _, session in ipairs(Sessions.list_all()) do
        check(
            not (session.parent_id ~= nil and realpath(session.cwd) == realpath(REPO)),
            "no child session is rooted in the parent main checkout",
            { id = session.id, cwd = session.cwd }
        )
    end
    step("revive failed closed after deletion, nothing written to the parent")

    -- ---------------------------------------------------------------------
    -- Owned checkout: `worktree = { create = { name, base } }` really creates
    -- one with git, the row records it as owned, and a clean close releases it.
    -- ---------------------------------------------------------------------
    local created_name = "e2e-created-" .. NONCE
    local created_path = realpath(REPO .. "/.worktrees/" .. created_name)
    local worktree_list_before_create = git({ "worktree", "list", "--porcelain" }, REPO)

    local create_dispatched
    Subsessions.handle_host(
        parent,
        vim.json.encode({
            action = "dispatch_subagents",
            params = {
                items = {
                    {
                        ref = "create",
                        task = TASK,
                        name = "e2e-created",
                        model = { provider = PROVIDER, id = MODEL_ID },
                        tools = { "bash" },
                        worktree = { create = { name = created_name, base = "head" } },
                    },
                },
            },
        }),
        function(res)
            create_dispatched = res
        end
    )
    check(
        type(create_dispatched) == "table" and type(create_dispatched.batch_id) == "string",
        "create dispatch returned a batch id",
        { result = create_dispatched }
    )
    local create_snap = wait_terminal(create_dispatched.batch_id, 180000, REPO)
    check(create_snap ~= nil, "create batch never reached a terminal state")
    check(create_snap.status == "completed", "create batch status is `completed`", { status = create_snap.status })
    local created_item = create_snap.items[1]
    check(created_item.status == "ok", "the created checkout's child run settled as `ok`", { item = created_item })
    check(
        type(created_item.worktree) == "table"
            and realpath(created_item.worktree.path) == created_path
            and created_item.worktree.owned == true,
        "the batch item reports the created checkout as owned",
        { worktree = created_item.worktree, path = created_path }
    )
    check(exists(created_path .. "/.git"), "a real linked worktree was created under .worktrees/", {
        path = created_path,
    })
    check(
        git({ "worktree", "list", "--porcelain" }, REPO) ~= worktree_list_before_create,
        "git registers the created worktree"
    )

    local created_child_id = created_item.target
    local created_child = Sessions.get_by_id(created_child_id)
    check(created_child ~= nil, "the created check-out's child session exists", { id = created_child_id })
    check(
        realpath(rpc_bash(created_child, "pwd -P")) == created_path,
        "the created check-out's child really runs in it (pwd -P)"
    )
    local created_entry = Manifest.load(REPO)[created_child_id]
    check(type(created_entry) == "table", "the created check-out has a manifest row")
    check(
        type(created_entry.worktree) == "table"
            and realpath(created_entry.worktree.path) == created_path
            and created_entry.worktree.owned == true,
        "the manifest records the created check-out as owned",
        { worktree = created_entry.worktree }
    )
    check(created_entry.assigned_worktree == nil, "an owned checkout carries no assignment")
    check(
        realpath(session_header_cwd(created_entry.session_file)) == created_path,
        "the owned child's transcript header records the created checkout"
    )
    step("created checkout registered, owned, and used by the real child")

    -- A clean close releases what this spawn created (the assigned one above
    -- never is). Remove the child's own sentinel first so the checkout is clean.
    vim.fn.delete(created_path .. "/" .. SENTINEL)
    Subsessions.close(created_child_id)
    wait(function()
        return not child_running(created_child_id)
    end, 30000, "created child to stop")
    wait(function()
        return not exists(created_path)
    end, 30000, "the owned checkout to be released")
    check(not exists(created_path), "a clean owned checkout is released on close", { path = created_path })
    check(
        git({ "worktree", "list", "--porcelain" }, REPO) == worktree_list_before_create,
        "git no longer lists the released worktree"
    )
    check(git({ "status", "--porcelain" }, REPO) == parent_status, "parent git status is still unchanged")
    check(head_sha(REPO) == parent_head, "parent HEAD is still unchanged")
    step("clean owned checkout released on close")
end)

-- Cleanup: stop timers/processes, drop the throwaway agent dir, restore env.
pcall(Reaper.stop)
for _, session in ipairs(Sessions.list_all()) do
    if session.parent_id ~= nil and session.rpc and session.rpc:is_running() then
        pcall(function()
            session.rpc:send({ type = "abort" })
        end)
        pcall(Sessions.close_session, session)
    end
end
stop_fake_provider(server)
if agent_dir_set then
    vim.env.PI_CODING_AGENT_DIR = nil
end
vim.env.PI_OFFLINE = nil
vim.fn.delete(ROOT, "rf")

local total = (uv.hrtime() - run_started) / 1e9
if not ok then
    print(("FAIL: %s (after %.2fs)"):format(tostring(failure), total))
    io.stdout:flush()
    os.exit(1)
end

print(
    ("PASS: sub-agent worktree e2e OK — the real child ran in the assigned checkout (sentinel + pwd), manifest recorded assigned_worktree/workspace/session_file, close kept clean and dirty checkouts, revive kept the cwd, a deleted checkout failed closed without touching the parent, and a `create` item got a real owned checkout under .worktrees/ that a clean close released again (in %.2fs)"):format(
        total
    )
)
os.exit(0)
