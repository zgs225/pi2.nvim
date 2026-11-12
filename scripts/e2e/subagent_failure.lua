-- Headless e2e: a sub-agent whose model call fails must reach the parent as a
-- FAILED batch item carrying the provider's reason.
--
-- Unlike tests/*_e2e.lua (mocked RPC), this drives the real chain end to end:
-- a real `pi --mode rpc` child, a real provider error on the wire, the real
-- settle path (sessions/manager -> subsessions.on_child_settled -> Batch), the
-- real manifest, and the real host bridge (`dispatch_subagents`).
--
-- The provider is a fake OpenAI-compatible server on 127.0.0.1 that answers
-- every request with `429 insufficient_quota`, so nothing is spent and the run
-- is deterministic. `PI_CODING_AGENT_DIR` points the child (and the plugin's
-- session/manifest lookups) at a throwaway directory, so no real state is read
-- or written.
--
-- What is asserted:
--   * the child's session JSONL last turn is `stopReason: "error"` (the shape
--     this feature keys on — captured from real pi output, not invented),
--   * the batch snapshot reports `status = "failed"` / one failed item with the
--     provider message, instead of the former `ok` + empty output,
--   * the manifest records `failed` plus `last_error`, so rehydration
--     (`rebuild`, `list_subagents`) keeps the reason,
--   * the child process stays alive after the failure (revivable, not killed).
--
-- Needs the pi binary, so it is NOT part of `make test` or CI. Run from the
-- repo root:
--   make e2e-subagent-failure
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/subagent_failure.lua)

local uv = vim.uv

local Batch = require("pi.subsessions.batch")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Reaper = require("pi.subsessions.reaper")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")

local TASK = "Reply with exactly: DONE"
local CHILD_NAME = "e2e-quota"
local PROVIDER = "fakequota"
local MODEL_ID = "quota-model"
local QUOTA_MESSAGE = "You exceeded your current quota, please check your plan and billing details."

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

--- A fake OpenAI-compatible provider: every request gets 429 insufficient_quota.
---@return uv.uv_tcp_t server
local function start_fake_provider()
    local server = assert(uv.new_tcp())
    assert(server:bind("127.0.0.1", 0))
    assert(server:listen(16, function(err)
        if err then
            print("[server] listen error: " .. tostring(err))
            return
        end
        local client = assert(uv.new_tcp())
        server:accept(client)
        local buffer = ""
        client:read_start(function(read_err, chunk)
            if read_err or not chunk then
                pcall(client.close, client)
                return
            end
            buffer = buffer .. chunk
            -- Wait for the request head (the body is irrelevant to the answer).
            if not buffer:find("\r\n\r\n", 1, true) and #buffer < 65536 then
                return
            end
            local body = vim.json.encode({
                error = {
                    message = QUOTA_MESSAGE,
                    type = "insufficient_quota",
                    param = vim.NIL,
                    code = "insufficient_quota",
                },
            })
            local response = table.concat({
                "HTTP/1.1 429 Too Many Requests",
                "Content-Type: application/json",
                "Content-Length: " .. #body,
                "Connection: close",
                "",
                body,
            }, "\r\n")
            client:write(response, function()
                pcall(client.close, client)
            end)
        end)
    end))
    return server
end

--- Write an isolated agent dir: our own models.json + an empty settings.json.
---@param agent_dir string
---@param port integer
local function write_agent_dir(agent_dir, port)
    vim.fn.mkdir(agent_dir, "p")
    local models = {
        providers = {
            [PROVIDER] = {
                name = "FakeQuota",
                baseUrl = ("http://127.0.0.1:%d/v1"):format(port),
                apiKey = "sk-e2e-test",
                api = "openai-completions",
                models = {
                    {
                        id = MODEL_ID,
                        name = "Quota Model",
                        contextWindow = 8000,
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

---@param batch_id string
---@param timeout_ms integer
---@return table? snapshot
local function wait_terminal(batch_id, timeout_ms)
    local snapshot
    vim.wait(timeout_ms, function()
        local snap = Batch.poll(batch_id)
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

-- ---------------------------------------------------------------------------

local root = vim.fn.tempname() .. "-e2e-subagent-failure"
local agent_dir = root .. "/agent"
local ok, failure = pcall(function()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(root, "p")

    -- Hermetic: the child (a `pi --mode rpc` job) inherits this env, and the
    -- plugin resolves the same dir for its manifest/session lookups.
    vim.env.PI_CODING_AGENT_DIR = agent_dir
    vim.env.PI_OFFLINE = "1"

    local server = start_fake_provider()
    local addr = server:getsockname()
    local port = type(addr) == "table" and addr.port or nil
    check(type(port) == "number" and port > 0, "fake provider did not bind a port", { addr = addr })
    write_agent_dir(agent_dir, port)
    step(("fake provider on 127.0.0.1:%d, agent dir %s"):format(port, agent_dir))

    -- Never touch the user's draft/prompt-history files.
    pcall(function()
        require("pi.draft")._set_path(vim.fn.tempname() .. "-e2e-subagent-failure-draft.txt")
    end)
    require("pi").setup({ title = { lang = "en" } })
    step("pi.setup")

    -- Fake parent: the batch path claims the settle itself, so no parent
    -- process is needed — only an id/lineage the spawn can bind to.
    local parent = {
        id = "e2e-failure-parent-" .. tostring(os.time()),
        conversation_epoch = 0,
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

    local dispatched
    Subsessions.handle_host(
        parent,
        vim.json.encode({
            action = "dispatch_subagents",
            params = {
                items = {
                    {
                        ref = "quota",
                        task = TASK,
                        name = CHILD_NAME,
                        model = { provider = PROVIDER, id = MODEL_ID },
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
        "dispatch_subagents did not return a batch id",
        { result = dispatched }
    )
    local batch_id = dispatched.batch_id
    check(dispatched.status == "running", "batch should start running", { status = dispatched.status })
    step("dispatched batch " .. batch_id)

    local snap = wait_terminal(batch_id, 180000)
    check(snap ~= nil, "batch never reached a terminal state", { poll = Batch.poll(batch_id) })
    step(("batch terminal: %s"):format(snap.status))

    local item = snap.items[1]
    check(item ~= nil, "batch snapshot has no item", { snap = snap })
    check(item.status == "failed", "a failed run must settle the item as `failed`", { item = item })
    check(snap.status == "failed", "batch status must be `failed`", { status = snap.status })
    check(
        snap.summary.failed == 1 and snap.summary.ok == 0,
        "summary must count one failure",
        { summary = snap.summary }
    )
    check(
        type(item.error) == "string" and item.error:find("insufficient_quota", 1, true) ~= nil,
        "item error must carry the provider reason",
        { error = item.error }
    )
    check(item.output == nil, "an errored turn produces no output", { output = item.output })

    local child_id = item.target
    check(type(child_id) == "string" and child_id ~= "", "item must record the child id", { item = item })
    local entry = Manifest.load()[child_id]
    check(type(entry) == "table", "manifest entry missing for the child", { child_id = child_id })
    check(entry.status == "failed", "manifest status must be `failed`", { status = entry.status })
    check(
        type(entry.last_error) == "string" and entry.last_error:find("insufficient_quota", 1, true) ~= nil,
        "manifest must keep the provider reason for `list_subagents` / rebuild",
        { last_error = entry.last_error }
    )

    -- The shape this feature keys on, straight from the real backend.
    local path = entry and (Sessions.get_by_id(child_id) or {}).session_file or Read.find_path(child_id)
    check(type(path) == "string" and vim.fn.filereadable(path) == 1, "child session JSONL missing", { path = path })
    local turn = Read.last_turn(path)
    check(turn ~= nil, "child session has no assistant turn", { path = path })
    check(turn.stop_reason == "error", "backend must persist the failed turn as stopReason=error", { turn = turn })
    check(
        type(turn.error_message) == "string" and turn.error_message:find("insufficient_quota", 1, true) ~= nil,
        "backend must persist the provider reason in errorMessage",
        { turn = turn }
    )
    step("child JSONL confirms stopReason=error + errorMessage")

    -- A failed run leaves the process alone: the child stays reusable.
    local child = Sessions.get_by_id(child_id)
    check(child ~= nil and child.rpc:is_running() == true, "failed child process must stay alive for reuse", {
        child = type(child) == "table",
    })
    child.rpc:send({ type = "abort" })
    Subsessions.close(child_id)
    step("child closed")
end)

-- Cleanup: stop timers/processes, restore env, drop the throwaway agent dir.
pcall(Reaper.stop)
for _, session in ipairs(Sessions.list_all()) do
    if session.parent_id ~= nil and session.rpc and session.rpc:is_running() then
        pcall(function()
            session.rpc:send({ type = "abort" })
        end)
        pcall(Sessions.close_session, session)
    end
end
vim.env.PI_CODING_AGENT_DIR = nil
vim.env.PI_OFFLINE = nil
vim.fn.delete(root, "rf")

local total = (uv.hrtime() - run_started) / 1e9
if not ok then
    print(("FAIL: %s (after %.2fs)"):format(tostring(failure), total))
    io.stdout:flush()
    os.exit(1)
end

print(
    ("PASS: sub-agent failure e2e OK — provider 429 settled the item as failed with the reason, manifest kept `last_error`, child stayed revivable (in %.2fs)"):format(
        total
    )
)
os.exit(0)
