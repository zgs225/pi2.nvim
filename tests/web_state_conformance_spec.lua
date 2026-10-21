-- Conformance of the authoritative web state reducer against the pi2d fixtures.
--
-- `lua/pi/web/state.lua` is a rule-for-rule port of `pi2d/src/protocol/reducer.ts`
-- (docs: `pi2d/docs/protocol.md` §4/§4.1). The pi2d repo commits
-- `fixtures/<case>/events.jsonl` + `expected.json`, where `expected.json` is
-- GENERATED from the TypeScript reference reducer. Reproducing it exactly
-- (including entry ids, block order, usage accumulation and flags) is the
-- conformance contract; the browser's TS render cache and the plugin's Lua state
-- both have to agree on it.
--
-- Fixtures live in the pi2d checkout (env `PI2D_DIR`, default
-- `/home/yuez/Workspace/Neovim/pi2d`). When they are absent this spec is
-- skipped with an explicit message instead of failing.

local fixtures = require("tests.helpers.web_fixtures")
local State = require("pi.web.state")

--- Replay a fixture case through a fresh state object.
---@param name string
---@return table state the reducer object
---@return pi.web.FixtureCase loaded fixture data
local function replay(name)
    local loaded = fixtures.load(name)
    local state = State.new(loaded.init)
    for _, event in ipairs(loaded.events) do
        state:apply(event)
    end
    return state, loaded
end

--- First differing path between two values, for readable assertion messages.
---@param a any
---@param b any
---@param path string|nil
---@return string|nil
local function first_diff(a, b, path)
    path = path or "$"
    if a == b then
        return nil
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return ("%s: expected %s, got %s"):format(path, vim.inspect(a), vim.inspect(b))
    end
    local seen = {}
    for k in pairs(a) do
        seen[k] = true
    end
    for k in pairs(b) do
        seen[k] = true
    end
    local keys = {}
    for k in pairs(seen) do
        keys[#keys + 1] = k
    end
    table.sort(keys, function(x, y)
        return tostring(x) < tostring(y)
    end)
    for _, k in ipairs(keys) do
        local diff = first_diff(a[k], b[k], ("%s.%s"):format(path, tostring(k)))
        if diff then
            return diff
        end
    end
    return nil
end

--- Assert deep equality with a path-precise failure message.
---@param expected any
---@param actual any
---@param label string
local function assert_deep_equal(expected, actual, label)
    assert.is_true(
        vim.deep_equal(expected, actual),
        ("%s diverged at %s"):format(label, first_diff(expected, actual) or "<unknown>")
    )
end

--- @param state table a SessionState
--- @param role string entry role
--- @return table|nil
local function entry_by_role(state, role)
    for _, entry in ipairs(state.entries) do
        if entry.role == role then
            return entry
        end
    end
    return nil
end

--- @param state table a SessionState
--- @return string[]
local function entry_ids(state)
    local ids = {}
    for _, entry in ipairs(state.entries) do
        ids[#ids + 1] = entry.id
    end
    return ids
end

local missing = fixtures.missing_reason()

if missing then
    describe("web state conformance (pi2d fixtures)", function()
        it("requires the pi2d fixtures", function()
            pending(missing)
        end)
    end)
else
    local cases = fixtures.cases()

    describe("web state conformance (pi2d fixtures)", function()
        for _, name in ipairs(cases) do
            it(("replays %s to the committed expected state"):format(name), function()
                local state, loaded = replay(name)
                assert_deep_equal(loaded.expected, state:state(), "fixtures/" .. name .. "/expected.json")
            end)
        end

        for _, name in ipairs(cases) do
            it(("is deterministic when replayed onto a fresh state (%s)"):format(name), function()
                local a = replay(name)
                local b = replay(name)
                assert_deep_equal(a:state(), b:state(), "second replay of " .. name)
            end)
        end

        it("numbers entries m1, m2, … in arrival order (basic-turn)", function()
            local state = replay("basic-turn"):state()
            assert.is_true(vim.deep_equal({ "m1", "m2" }, entry_ids(state)))
            assert.equals("user", state.entries[1].role)
            assert.equals("assistant", state.entries[2].role)
        end)

        it("attaches tool execution to the assistant entry after message_end (basic-turn)", function()
            local state = replay("basic-turn"):state()
            local assistant = entry_by_role(state, "assistant")
            assert.is_not_nil(assistant)

            -- message_end rebuilt the blocks from the authoritative content, so
            -- the order is content order (thinking, text, tool).
            local types = {}
            for _, block in ipairs(assistant.blocks) do
                types[#types + 1] = block.type
            end
            assert.is_true(vim.deep_equal({ "thinking", "text", "tool" }, types))

            local tool = assistant.blocks[3]
            assert.equals("call_1", tool.toolCallId)
            assert.equals("bash", tool.name)
            assert.equals("done", tool.state)
            assert.equals(9, tool.durationMs)
            assert.is_true(vim.deep_equal({ command = "ls" }, tool.args))
            assert.is_true(vim.deep_equal({ text = "a.txt\nb.txt", details = {} }, tool.output))
            assert.is_true(assistant.done)
        end)

        it("accumulates assistant usage into the session totals (basic-turn)", function()
            local state = replay("basic-turn"):state()
            assert.is_true(vim.deep_equal({
                input = 100,
                output = 20,
                cacheRead = 0,
                cacheWrite = 0,
                cost = 0.003,
            }, state.usage))
            -- exact float equality: cost comes from `cost.total`, not a recomputation
            assert.equals(0.003, state.usage.cost)
            -- tool result partial updates never leak into usage
            assert.equals(1200, state.contextUsage.tokens)
        end)

        it("flags an aborted run as error without marking it done (error-abort-compaction)", function()
            local state = replay("error-abort-compaction"):state()
            assert.equals("exited", state.status)
            assert.is_true(state.flags.error)
            assert.is_false(state.flags.done)

            local entry = state.entries[1]
            assert.equals("assistant", entry.role)
            assert.equals("m1", entry.id)
            assert.is_false(entry.done)
            -- streamed partial text survives, then one error block per error
            -- source: the assistantMessageEvent and the derived pi2:error.
            local errors = 0
            for _, block in ipairs(entry.blocks) do
                if block.type == "error" then
                    errors = errors + 1
                    assert.equals("Aborted by user", block.text)
                end
            end
            assert.equals(2, errors)
            assert.equals("text", entry.blocks[1].type)
            assert.equals("partial answer", entry.blocks[1].text)
        end)

        it("keeps `done` untouched on process exit (error-abort-compaction)", function()
            -- protocol.md §4.1 says `flags.done=true` for pi2:process_exit, but
            -- reducer.ts deliberately keeps it: an exit is not a finished turn.
            -- The committed expected.json follows reducer.ts and so do we.
            local state = replay("error-abort-compaction"):state()
            assert.equals("exited", state.status)
            assert.is_false(state.flags.done)
        end)

        it("clears pending attention and keeps the derived panels (queue-todo-attention)", function()
            local state = replay("queue-todo-attention"):state()
            assert.equals(0, #state.attention)
            assert.is_false(state.flags.attention)

            local queue = {}
            for _, item in ipairs(state.queue) do
                queue[#queue + 1] = { item.id, item.text, item.steer }
            end
            assert.is_true(vim.deep_equal({
                { "q:steer:0", "use pnpm", true },
                { "q:follow:0", "then run the tests", false },
            }, queue))

            assert.equals(3, #state.todos)
            assert.is_true(vim.deep_equal({
                content = "refactor",
                status = "in_progress",
                activeForm = "refactoring",
            }, state.todos[2]))
            assert.is_nil(state.todos[3].activeForm)

            assert.equals(2, #state.subagents)
            assert.equals("b1", state.batches[1].batchId)
            assert.equals(1, state.batches[1].summary.done)
            assert.is_true(vim.deep_equal({
                id = "t1",
                command = "pnpm test",
                status = "running",
                startTime = 2005,
            }, state.tasks[1]))
            assert.equals("Refactor auth", state.name)
            assert.equals("high", state.thinking)
            assert.equals("idle", state.status)
            assert.is_true(state.flags.done)
        end)

        it("projects exactly the documented SessionState keys", function()
            local snap = replay("basic-turn"):snapshot()
            local keys = {}
            for key in pairs(snap) do
                keys[#keys + 1] = key
            end
            table.sort(keys)
            assert.is_true(vim.deep_equal({
                "attention",
                "batches",
                "contextUsage",
                "cwd",
                "entries",
                "flags",
                "model",
                "name",
                "queue",
                "sessionId",
                "status",
                "subagents",
                "tasks",
                "thinking",
                "todos",
                "usage",
                "workspaceId",
            }, keys))
            -- null fields must stay explicit (`vim.NIL` encodes as JSON null);
            -- dropping the key would make the snapshot invalid on the wire.
            assert.equals(vim.NIL, snap.name)
        end)

        it("returns an independent copy from :state()", function()
            local state = replay("basic-turn")
            local first = state:state()
            first.entries[1].blocks[1].text = "mutated"
            first.status = "busy"
            first.queue[1] = { id = "q:steer:0", text = "nope", steer = true }

            local second = state:state()
            assert.equals("List the files", second.entries[1].blocks[1].text)
            assert.equals("idle", second.status)
            assert.equals(0, #second.queue)
        end)

        it("is pure Lua (no Neovim API calls)", function()
            local info = debug.getinfo(State.new, "S")
            local path = info.source:gsub("^@", "")
            local fd = assert(io.open(path, "r"))
            local src = fd:read("*a")
            fd:close()
            for _, needle in ipairs({ "vim.fn.", "vim.api.", "vim.schedule(" }) do
                assert.is_nil(src:find(needle, 1, true), ("state.lua must not use %s"):format(needle))
            end
        end)
    end)

    describe("web state reducer semantics (synthetic streams)", function()
        --- @return table a state object with a minimal init
        local function fresh()
            return State.new({ session_id = "s1", workspace_id = "ws-1", cwd = "/repo" })
        end

        it("sums usage across assistant turns", function()
            local state = fresh()
            state:apply({
                type = "message_start",
                ts = 1,
                message = { role = "assistant", content = {} },
            })
            state:apply({
                type = "message_end",
                ts = 2,
                message = {
                    role = "assistant",
                    content = { { type = "text", text = "ok" } },
                    usage = { input = 10, output = 2, cacheRead = 5, cacheWrite = 7, cost = { total = 0.125 } },
                },
            })
            state:apply({
                type = "message_start",
                ts = 3,
                message = { role = "assistant", content = {} },
            })
            state:apply({
                type = "message_end",
                ts = 4,
                message = {
                    role = "assistant",
                    content = { { type = "text", text = "ok" } },
                    usage = { input = 1, output = 1, cacheRead = 5, cacheWrite = 7, cost = { total = 0.5 } },
                },
            })
            assert.is_true(vim.deep_equal({
                input = 11,
                output = 3,
                cacheRead = 10,
                cacheWrite = 14,
                cost = 0.625,
            }, state:state().usage))
        end)

        it("keeps tool execution state when message_end rebuilds the entry", function()
            local state = fresh()
            for _, event in ipairs({
                { type = "message_start", ts = 10, message = { role = "assistant", content = {} } },
                {
                    type = "message_update",
                    ts = 11,
                    assistantMessageEvent = { type = "toolcall_start", contentIndex = 0, id = "c1", toolName = "bash" },
                },
                {
                    type = "tool_execution_start",
                    ts = 12,
                    toolCallId = "c1",
                    toolName = "bash",
                    args = { command = "ls" },
                },
                {
                    type = "tool_execution_end",
                    ts = 13,
                    toolCallId = "c1",
                    result = { content = { { type = "text", text = "out" } } },
                    durationMs = 4,
                },
                {
                    type = "message_end",
                    ts = 14,
                    message = {
                        role = "assistant",
                        content = {
                            { type = "toolCall", id = "c1", name = "bash", arguments = { command = "ls" } },
                        },
                    },
                },
                -- late execution event after the authoritative rebuild: the
                -- tool block must still be found by toolCallId.
                {
                    type = "tool_execution_end",
                    ts = 15,
                    toolCallId = "c1",
                    result = { content = { { type = "text", text = "late" } } },
                    isError = true,
                },
            }) do
                state:apply(event)
            end

            local entry = state:state().entries[1]
            assert.equals(1, #entry.blocks)
            local tool = entry.blocks[1]
            assert.equals("tool", tool.type)
            assert.equals("c1", tool.toolCallId)
            assert.equals("bash", tool.name)
            assert.equals("error", tool.state)
            assert.equals(4, tool.durationMs)
            assert.is_true(vim.deep_equal({ text = "late" }, tool.output))
        end)

        it("raises and clears flags.attention across a request lifecycle", function()
            local state = fresh()
            state:apply({
                type = "pi2:attention_request",
                ts = 20,
                requestId = "att1",
                method = "select",
                title = "Apply diff?",
            })
            local pending_state = state:state()
            assert.equals(1, #pending_state.attention)
            assert.is_true(pending_state.flags.attention)
            assert.equals(20, pending_state.attention[1].receivedAt)
            assert.equals(20, pending_state.attention[1].createdAt)

            state:apply({ type = "pi2:attention_resolved", ts = 21, requestId = "att1" })
            local resolved = state:state()
            assert.equals(0, #resolved.attention)
            assert.is_false(resolved.flags.attention)
        end)

        it("appends a notice entry for pi2:error without an active assistant", function()
            local state = fresh()
            state:apply({ type = "pi2:error", ts = 30, message = "boom" })
            local snapshot = state:state()
            assert.equals(1, #snapshot.entries)
            assert.equals("m1", snapshot.entries[1].id)
            assert.equals("notice", snapshot.entries[1].role)
            assert.is_true(snapshot.entries[1].done)
            assert.is_true(vim.deep_equal({ { type = "error", text = "boom" } }, snapshot.entries[1].blocks))
            assert.is_true(snapshot.flags.error)
        end)

        it("maps process exit codes to exited / interrupted", function()
            local ok_exit = fresh()
            ok_exit:apply({ type = "agent_start", ts = 40 })
            ok_exit:apply({ type = "pi2:process_exit", ts = 41, code = 0 })
            assert.equals("exited", ok_exit:state().status)
            assert.is_false(ok_exit:state().flags.done)

            local bad_exit = fresh()
            bad_exit:apply({ type = "pi2:process_exit", ts = 42, code = 1 })
            assert.equals("interrupted", bad_exit:state().status)

            local null_exit = fresh()
            null_exit:apply({ type = "pi2:process_exit", ts = 43, code = vim.NIL })
            assert.equals("exited", null_exit:state().status)
        end)

        it("keeps session identity stable across a pi2:session patch", function()
            local state = fresh()
            state:apply({
                type = "pi2:session",
                ts = 50,
                session = {
                    status = "busy",
                    cwd = "/elsewhere",
                    name = "Refactor",
                    usage = { input = 3, output = 4, cacheRead = 0, cacheWrite = 0, cost = 0.5 },
                },
            })
            local snapshot = state:state()
            assert.equals("s1", snapshot.sessionId)
            assert.equals("ws-1", snapshot.workspaceId)
            assert.equals("/repo", snapshot.cwd)
            assert.equals("busy", snapshot.status)
            assert.equals("Refactor", snapshot.name)
            assert.is_true(vim.deep_equal({
                input = 3,
                output = 4,
                cacheRead = 0,
                cacheWrite = 0,
                cost = 0.5,
            }, snapshot.usage))
        end)
    end)
end
