-- Specs for `pi.web.instance`: identity (workspace id, epoch, per-session seq),
-- snapshot construction and the derived `pi2:*` fanout.
--
-- The bridge is faked (records + never connects): this file is about the data
-- the plugin ships, not about the transport (`web_bridge_spec` covers that).

local Instance = require("pi.web.instance")
local Runtime = require("pi.web.runtime")
local Sessions = require("pi.sessions.manager")
local Config = require("pi.config")
local Tasks = require("pi.tasks")
local Todo = require("pi.todo")
local Protocol = require("pi.web.protocol")

local uv = vim.uv or vim.loop

--- @class pi.TestFakeBridge
--- @field events table[]
--- @field snapshots table[]
--- @field instance_states table[]
--- @field ready boolean

--- @return pi.TestFakeBridge
local function fake_bridge()
    local bridge = { events = {}, snapshots = {}, instance_states = {}, ready = true }
    function bridge:send_event(session_id, epoch, seq, event)
        self.events[#self.events + 1] = { session_id = session_id, epoch = epoch, seq = seq, event = event }
        return true
    end
    function bridge:send_snapshot(session_id, epoch, seq, state, entries)
        self.snapshots[#self.snapshots + 1] = {
            session_id = session_id,
            epoch = epoch,
            seq = seq,
            state = state,
            entries = entries,
        }
        return true
    end
    function bridge:send_instance_state(payload)
        self.instance_states[#self.instance_states + 1] = payload
        return true
    end
    function bridge:status()
        return { ready = self.ready, instance_id = "i-test", started = true, connected = true }
    end
    function bridge:stop() end
    return bridge
end

--- @param opts? { id?: string, model?: table, thinking?: string }
--- @return pi.Session
local function fake_session(opts)
    opts = opts or {}
    local running = true
    local sent = {}
    --- @type pi.Session
    local session = {
        id = opts.id or "s-1",
        rpc = {
            is_running = function()
                return running
            end,
            stop = function() end,
            send = function(_, cmd)
                sent[#sent + 1] = cmd
                return true
            end,
        },
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        cwd = "/repo",
        changed_files = {},
        pinned_config = {
            model = opts.model or { provider = "anthropic", id = "claude-sonnet-4-5" },
            thinking_level = opts.thinking or "medium",
        },
        _sent = sent,
        _set_running = function(value)
            running = value
        end,
    }
    return session
end

--- @param bridge pi.TestFakeBridge
--- @param name string
--- @return table[]
local function events_of(bridge, name)
    local out = {}
    for _, record in ipairs(bridge.events) do
        if record.event and record.event.type == name then
            out[#out + 1] = record
        end
    end
    return out
end

describe("pi.web.instance", function()
    local saved_cwd
    local saved_agent_dir
    local saved_workspace_env

    before_each(function()
        saved_cwd = vim.fn.getcwd()
        saved_agent_dir = Config.options.agent_dir
        saved_workspace_env = vim.env.PI2_WORKSPACE_ID
        Sessions._reset()
        Tasks._reset()
    end)

    after_each(function()
        Instance.shutdown()
        Sessions._reset()
        Tasks._reset()
        Todo._reset()
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
        Config.options.agent_dir = saved_agent_dir
        vim.env.PI2_WORKSPACE_ID = saved_workspace_env
    end)

    it("derives the workspace id from sha256(realpath(cwd)) and honours PI2_WORKSPACE_ID", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local real = uv.fs_realpath(dir) or dir
        assert.equals(Runtime.hex16(real), Instance.workspace_id_for(dir))

        local instance = Instance.setup({ cwd = dir })
        assert.equals(Runtime.hex16(real), instance.workspace_id)

        vim.env.PI2_WORKSPACE_ID = "ws-from-daemon"
        local overridden = Instance.setup({ cwd = dir })
        assert.equals("ws-from-daemon", overridden.workspace_id)
    end)

    it("mints a per-process epoch and per-session monotonic seq counters", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        assert.is_truthy(instance.epoch:match("^%x+$"))
        assert.equals(32, #instance.epoch)

        assert.equals(1, instance:next_seq("s-1"))
        assert.equals(2, instance:next_seq("s-1"))
        assert.equals(1, instance:next_seq("s-2"))
        assert.equals(2, instance:seq("s-1"))

        local other = Instance.new_epoch()
        assert.is_true(instance.epoch ~= other)
    end)

    it("builds a full SessionState snapshot from the reducer plus live fields", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-snap" })
        Sessions._register_for_test(session)
        instance:on_subscribe("s-snap")

        assert.equals(1, #bridge.snapshots)
        local snapshot = bridge.snapshots[1]
        assert.equals("s-snap", snapshot.session_id)
        assert.equals(instance.epoch, snapshot.epoch)
        local state = snapshot.state
        assert.equals("s-snap", state.sessionId)
        assert.equals("ws-test", state.workspaceId)
        assert.equals("/repo", state.cwd)
        assert.equals("idle", state.status)
        assert.same({ provider = "anthropic", id = "claude-sonnet-4-5" }, state.model)
        assert.equals("medium", state.thinking)
        assert.same({ input = 0, output = 0, cacheRead = 0, cacheWrite = 0, cost = 0 }, state.usage)
        assert.same({}, state.queue)
        assert.same({}, state.todos)
        assert.same({}, state.tasks)
        assert.same({}, state.batches)
        assert.same({}, state.subagents)
        assert.same({}, state.attention)
        assert.same({}, state.entries)
        assert.is_truthy(state.name == vim.NIL)
    end)

    it("reduces pi events into the snapshot (entries, usage, status)", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-live" })
        Sessions._register_for_test(session)
        instance:on_subscribe("s-live")

        instance:on_event(session, { type = "agent_start" })
        instance:on_event(session, {
            type = "message_start",
            message = { role = "user", content = "hello" },
        })
        instance:on_event(session, {
            type = "message_start",
            message = { role = "assistant", content = {} },
        })
        instance:on_event(session, {
            type = "message_end",
            message = {
                role = "assistant",
                content = { { type = "text", text = "hi" } },
                usage = {
                    input = 10,
                    output = 5,
                    cacheRead = 2,
                    cacheWrite = 1,
                    cost = { total = 0.25 },
                },
            },
        })

        local state = instance:snapshot_for(session)
        assert.equals(2, #state.entries)
        assert.equals("user", state.entries[1].role)
        assert.equals("assistant", state.entries[2].role)
        assert.equals("hi", state.entries[2].blocks[1].text)
        assert.equals(10, state.usage.input)
        assert.equals(5, state.usage.output)
        assert.equals(0.25, state.usage.cost)

        -- Raw pi events are forwarded verbatim, in order, with an epoch.
        local raw = events_of(bridge, "agent_start")
        assert.equals(1, #raw)
        assert.equals("s-live", raw[1].session_id)
        assert.equals(instance.epoch, raw[1].epoch)
        assert.equals(2, raw[1].seq)

        -- Status patches are derived after the reducer ran.
        local patch = events_of(bridge, Protocol.DERIVED.SESSION)
        assert.is_true(#patch >= 1)
        assert.equals("busy", patch[#patch].event.session.status)
    end)

    it("derives pi2:session from get_state / get_session_stats responses", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-state" })
        Sessions._register_for_test(session)
        instance:on_subscribe("s-state")

        instance:on_event(session, {
            type = "response",
            command = "get_state",
            success = true,
            data = {
                model = { provider = "openai", id = "gpt-5" },
                thinkingLevel = "high",
                sessionName = "Refactor",
            },
        })
        instance:on_event(session, {
            type = "response",
            command = "get_session_stats",
            success = true,
            data = {
                tokens = { input = 100, output = 20, cacheRead = 10, cacheWrite = 5 },
                cost = 1.5,
                contextUsage = { tokens = 60000, contextWindow = 200000, percent = 30 },
            },
        })

        assert.equals(0, #events_of(bridge, "response"))
        local state = instance:snapshot_for(session)
        assert.same({ provider = "openai", id = "gpt-5" }, state.model)
        assert.equals("high", state.thinking)
        assert.equals("Refactor", state.name)
        assert.same({ input = 100, output = 20, cacheRead = 10, cacheWrite = 5, cost = 1.5 }, state.usage)
        assert.same({ tokens = 60000, window = 200000, percent = 30 }, state.contextUsage)
    end)

    it("pushes pi2:todo only when the todo mirror changed", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-todo" })
        Sessions._register_for_test(session)
        instance:on_subscribe("s-todo")

        Todo.update_from_details({
            todos = { { content = "write spec", status = "in_progress", activeForm = "writing" } },
            completed = 0,
            total = 1,
        }, session)

        instance:publish_todo(session)
        instance:publish_todo(session)
        local todo_events = events_of(bridge, Protocol.DERIVED.TODO)
        assert.equals(1, #todo_events)
        assert.equals("write spec", todo_events[1].event.todos[1].content)
        assert.equals("in_progress", todo_events[1].event.todos[1].status)
        assert.equals("writing", todo_events[1].event.todos[1].activeForm)

        local state = instance:snapshot_for(session)
        assert.equals(1, #state.todos)
    end)

    it("projects background tasks from the task registry", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-task" })
        Sessions._register_for_test(session)
        instance:on_subscribe("s-task")

        Tasks.handle_event({
            type = "pi2_bg_task",
            timestamp = os.time() * 1000,
            details = { kind = "started", taskId = "t1", command = "sleep 1", outputFile = "/tmp/t1.log" },
        }, "s-task", nil)

        instance:publish_tasks()
        local task_events = events_of(bridge, Protocol.DERIVED.TASK)
        assert.equals(1, #task_events)
        assert.equals("t1", task_events[1].event.task.id)
        assert.equals("running", task_events[1].event.task.status)
        assert.equals("/tmp/t1.log", task_events[1].event.task.outputFile)

        -- A terminal transition updates the same record.
        Tasks.handle_event({
            type = "pi2_bg_task",
            timestamp = os.time() * 1000 + 10,
            details = { kind = "completed", taskId = "t1", command = "sleep 1", exitCode = 0 },
        }, "s-task", nil)
        instance:publish_tasks()
        assert.equals(2, #events_of(bridge, Protocol.DERIVED.TASK))

        local state = instance:snapshot_for(session)
        assert.equals(1, #state.tasks)
        assert.equals("completed", state.tasks[1].status)
        assert.equals(0, state.tasks[1].exitCode)
    end)

    it("projects the sub-session manifest and batch queue", function()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        local workspace = root .. "/repo"
        vim.fn.mkdir(workspace, "p")
        Config.options.agent_dir = root .. "/agent"
        vim.fn.mkdir(Config.options.agent_dir .. "/sessions", "p")
        vim.cmd("cd " .. vim.fn.fnameescape(workspace))

        local sessions_dir = require("pi.sessions.history").get_sessions_dir()
        vim.fn.mkdir(sessions_dir, "p")
        require("pi.subsessions.manifest")._reset()
        require("pi.subsessions.batch")._reset()
        vim.fn.writefile({
            vim.json.encode({
                ["child-1"] = {
                    parent_id = "parent",
                    name = "Child",
                    task_prompt = "implement it",
                    config = { model = { provider = "p", id = "m" }, thinking_level = "low" },
                    status = "active",
                },
            }),
        }, sessions_dir .. "/.pi2-subsessions.json")
        local batch_path = sessions_dir .. "/.pi2-batches.json"
        require("pi.subsessions.batch")._set_path(batch_path)
        vim.fn.writefile({
            vim.json.encode({
                b1 = {
                    id = "b1",
                    parent_id = "parent",
                    status = "running",
                    created_at = "2026-01-01T00:00:00.000Z",
                    updated_at = "2026-01-01T00:00:00.000Z",
                    items = { { ref = "r1", status = "running" } },
                },
            }),
        }, batch_path)

        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = workspace, bridge = bridge })
        local session = fake_session({ id = "parent" })
        session.cwd = workspace
        Sessions._register_for_test(session)
        instance:on_subscribe("parent")

        local state = instance:snapshot_for(session)
        assert.equals(1, #state.subagents)
        assert.equals("child-1", state.subagents[1].id)
        assert.equals("Child", state.subagents[1].name)
        assert.equals("active", state.subagents[1].status)
        assert.equals("m", state.subagents[1].model)
        assert.equals("low", state.subagents[1].thinking)
        assert.equals("implement it", state.subagents[1].task)

        assert.equals(1, #state.batches)
        assert.equals("b1", state.batches[1].batchId)
        assert.equals("running", state.batches[1].status)

        assert.equals(1, #events_of(bridge, Protocol.DERIVED.BATCH))
        assert.equals(1, #events_of(bridge, Protocol.DERIVED.SUBAGENTS))
    end)

    it("emits pi2:process_exit and marks the session exited", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-exit" })
        Sessions._register_for_test(session)
        instance:on_subscribe("s-exit")

        session._set_running(false)
        instance:on_event(session, { type = "_process_exit", code = 0 })

        local exits = events_of(bridge, Protocol.DERIVED.PROCESS_EXIT)
        assert.equals(1, #exits)
        assert.equals(0, exits[1].event.code)
        assert.equals("exited", instance:snapshot_for(session).status)
    end)

    it("projects queued attention requests into the snapshot (full fields, diff payload)", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-attn" })
        Sessions._register_for_test(session)
        instance:on_subscribe("s-attn")

        session.attention.pending = {
            {
                id = "req-1",
                kind = "confirm",
                created_at = 1234,
                expires_at = 999999,
                msg = {
                    id = "req-1",
                    method = "confirm",
                    title = "Confirm?",
                    message = "Do it",
                    options = { { id = "a", label = "A" } },
                    timeout = 30000,
                },
            },
        }

        local state = instance:snapshot_for(session)
        assert.equals(1, #state.attention)
        local item = state.attention[1]
        assert.equals("req-1", item.requestId)
        assert.equals("confirm", item.method)
        assert.equals("Confirm?", item.title)
        assert.equals("Do it", item.message)
        assert.same({ { id = "a", label = "A" } }, item.options)
        assert.equals(30, item.timeoutSec)
        assert.equals(1234, item.createdAt)
        assert.is_true(state.flags.attention)

        -- A diff review is projected as method="diff" with the decoded payload.
        local payload = { toolName = "edit", files = { { path = "a.lua" } } }
        session.attention.pending = {
            {
                id = "req-diff",
                kind = "diff",
                created_at = 2000,
                msg = { id = "req-diff", method = "select", title = vim.json.encode(payload) },
            },
        }
        state = instance:snapshot_for(session)
        assert.equals("diff", state.attention[1].method)
        assert.same(payload, state.attention[1].payload)

        -- An empty queue always clears the projection (a pruned request must not
        -- leave a phantom entry or flag behind).
        session.attention.pending = {}
        state = instance:snapshot_for(session)
        assert.same({}, state.attention)
        assert.is_false(state.flags.attention)
    end)

    it("keeps attention requests in the state until resolved", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-attn2" })
        Sessions._register_for_test(session)
        instance:on_subscribe("s-attn2")

        local entry = { id = "req-2", kind = "confirm", created_at = 1234, expires_at = 999999 }
        Instance.emit_attention_request(session, {
            id = "req-2",
            method = "confirm",
            title = "Confirm?",
            message = "Do it",
            timeout = 30000,
        }, entry)
        session.attention.pending = { entry }

        local state = instance:snapshot_for(session)
        assert.equals(1, #state.attention)
        assert.equals("req-2", state.attention[1].requestId)
        assert.is_true(state.flags.attention)
        local request = events_of(bridge, Protocol.DERIVED.ATTENTION_REQUEST)[1].event
        assert.equals("req-2", request.requestId)
        assert.equals(30, request.timeoutSec)

        Instance.emit_attention_resolved(session, "req-2", "web", { confirmed = true })
        session.attention.pending = {}
        state = instance:snapshot_for(session)
        assert.equals(0, #state.attention)
        assert.is_false(state.flags.attention)
    end)

    it("announces a session id migration on the old id and moves the subscription", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "tmp-1" })
        Sessions._register_for_test(session)
        instance:on_subscribe("tmp-1")
        instance:on_event(session, { type = "agent_start" })
        local before = bridge.events[#bridge.events].seq

        -- The real migration path: registry row + alias + web notification.
        Sessions.ensure_id(session, "real-1")

        local migration = bridge.events[#bridge.events]
        assert.equals("tmp-1", migration.session_id)
        assert.equals(Protocol.DERIVED.SESSION, migration.event.type)
        assert.equals("real-1", migration.event.session.sessionId)
        assert.equals("tmp-1", migration.event.session.previousSessionId)
        assert.equals(before + 1, migration.seq)

        -- The daemon learns the new id through a fresh instance_state.
        local announced = bridge.instance_states[#bridge.instance_states]
        assert.is_not_nil(announced)
        local ids = {}
        for _, row in ipairs(announced.sessions) do
            ids[#ids + 1] = row.sessionId
        end
        assert.same({ "real-1" }, ids)

        -- Subscription + seq continue on the new id and the snapshot follows it.
        assert.is_true(instance._subscribed["real-1"] == true)
        assert.is_nil(instance._subscribed["tmp-1"])
        instance:on_subscribe("real-1")
        assert.equals("real-1", bridge.snapshots[#bridge.snapshots].session_id)
        assert.equals("real-1", bridge.snapshots[#bridge.snapshots].state.sessionId)
        assert.equals("real-1", instance:snapshot_for(session).sessionId)

        instance:on_event(session, { type = "agent_settled" })
        local after = events_of(bridge, "agent_settled")[1]
        assert.equals("real-1", after.session_id)
        assert.equals(before + 2, after.seq)

        -- The old id keeps resolving for a while, then stops.
        assert.equals(session, Sessions.get_by_id("tmp-1"))
        local ttl = Sessions.ALIAS_TTL_MS
        Sessions.ALIAS_TTL_MS = -1
        assert.is_nil(Sessions.get_by_id("tmp-1"))
        Sessions.ALIAS_TTL_MS = ttl
    end)

    it("forgets the id alias when the session closes", function()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = fake_bridge() })
        local session = fake_session({ id = "tmp-9" })
        Sessions._register_for_test(session)
        instance:state_for(session)
        Sessions.ensure_id(session, "real-9")
        assert.equals(session, Sessions.get_by_id("tmp-9"))

        Sessions.close_session(session)
        assert.is_nil(Sessions.get_by_id("tmp-9"))
        assert.is_nil(Sessions.get_by_id("real-9"))
    end)

    it("carries the newest entries (capped) in the snapshot", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-big" })
        Sessions._register_for_test(session)
        instance:on_subscribe("s-big")

        for i = 1, 60 do
            instance:on_event(session, {
                type = "message_start",
                message = { role = "assistant", content = {} },
            })
            instance:on_event(session, {
                type = "message_end",
                message = { role = "assistant", content = { { type = "text", text = "turn " .. i } } },
            })
        end

        instance:send_snapshot(session)
        local snapshot = bridge.snapshots[#bridge.snapshots]
        assert.equals(50, #snapshot.entries)
        -- Newest last, and the state itself still holds every entry.
        assert.equals("turn 60", snapshot.entries[50].blocks[1].text)
        assert.equals("turn 11", snapshot.entries[1].blocks[1].text)
        assert.equals(60, #snapshot.state.entries)

        -- A single entry larger than the byte budget is not shipped.
        assert.same(
            {},
            instance:snapshot_entries({
                {
                    id = "m1",
                    role = "assistant",
                    ts = 1,
                    blocks = { { type = "text", text = string.rep("x", 300 * 1024) } },
                    done = true,
                },
            })
        )
    end)

    it("emits pi2:batch only when the batch signature changed", function()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        local workspace = root .. "/repo"
        vim.fn.mkdir(workspace, "p")
        Config.options.agent_dir = root .. "/agent"
        vim.fn.mkdir(Config.options.agent_dir .. "/sessions", "p")
        vim.cmd("cd " .. vim.fn.fnameescape(workspace))

        local sessions_dir = require("pi.sessions.history").get_sessions_dir()
        vim.fn.mkdir(sessions_dir, "p")
        require("pi.subsessions.manifest")._reset()
        local Batch = require("pi.subsessions.batch")
        Batch._reset()
        local batch_path = sessions_dir .. "/.pi2-batches.json"
        Batch._set_path(batch_path)
        local function write_batch(status, item_status)
            vim.fn.writefile({
                vim.json.encode({
                    b1 = {
                        id = "b1",
                        parent_id = "parent",
                        status = status,
                        created_at = "2026-01-01T00:00:00.000Z",
                        updated_at = "2026-01-01T00:00:00.000Z",
                        items = { { ref = "r1", status = item_status } },
                    },
                }),
            }, batch_path)
            Batch._reset()
            Batch._set_path(batch_path)
            Batch.load()
        end
        write_batch("running", "running")

        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = workspace, bridge = bridge })
        local session = fake_session({ id = "parent" })
        session.cwd = workspace
        Sessions._register_for_test(session)
        instance:on_subscribe("parent")
        assert.equals(1, #events_of(bridge, Protocol.DERIVED.BATCH))

        -- settle/tool-end hooks re-run the projection: unchanged batches stay quiet.
        instance:publish_subagents(session)
        instance:on_event(session, { type = "agent_settled" })
        instance:on_event(session, { type = "tool_execution_end", toolCallId = "c1" })
        assert.equals(1, #events_of(bridge, Protocol.DERIVED.BATCH))

        -- A real change ships again.
        write_batch("failed", "failed")
        instance:publish_subagents(session)
        local batches = events_of(bridge, Protocol.DERIVED.BATCH)
        assert.equals(2, #batches)
        assert.equals("failed", batches[2].event.status)
        assert.equals("failed", batches[2].event.items[1].status)
    end)

    it("drops the cached model list when a session switches model", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-model" })
        Sessions._register_for_test(session)
        instance:on_subscribe("s-model")

        local Commands = require("pi.web.commands")
        local original = Commands._reset_caches
        local invalidations = 0
        Commands._reset_caches = function()
            invalidations = invalidations + 1
        end
        local function get_state(model)
            instance:on_event(session, {
                type = "response",
                command = "get_state",
                success = true,
                data = { model = model },
            })
        end

        local ok, err = pcall(function()
            get_state({ provider = "anthropic", id = "claude-sonnet-4-5" })
            -- First observation only seeds the signature (the cache is empty).
            assert.equals(0, invalidations)

            get_state({ provider = "anthropic", id = "claude-sonnet-4-5" })
            assert.equals(0, invalidations)

            get_state({ provider = "openai", id = "gpt-5" })
            assert.equals(1, invalidations)
        end)
        Commands._reset_caches = original
        assert.is_true(ok, tostring(err))
    end)

    it("does not emit events buffered for a view rebuild (replayed once)", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-rebuild" })
        Sessions._register_for_test(session)
        instance:on_subscribe("s-rebuild")

        instance:on_event(session, {
            type = "message_start",
            message = { role = "assistant", content = {} },
        })

        session._view_rebuilding = true
        session._view_event_queue = {}
        local delta = {
            type = "message_update",
            assistantMessageEvent = { type = "text_delta", delta = "a", contentIndex = 0 },
        }
        assert.is_true(Sessions.handle_event(session, delta))
        assert.equals(0, #events_of(bridge, "message_update"))

        session._view_rebuilding = false
        local queued = session._view_event_queue[1]
        assert.equals("message_update", queued.type)
        assert.is_true(Sessions.handle_event(session, queued))
        assert.equals(1, #events_of(bridge, "message_update"))

        local state = instance:snapshot_for(session)
        assert.equals("a", state.entries[1].blocks[1].text)
    end)

    it("does not fan out before the daemon subscribes", function()
        local bridge = fake_bridge()
        local instance = Instance.setup({ workspace_id = "ws-test", cwd = "/repo", bridge = bridge })
        local session = fake_session({ id = "s-unsub" })
        Sessions._register_for_test(session)

        instance:on_event(session, { type = "agent_start" })
        assert.equals(0, #bridge.events)
        instance:on_subscribe("s-unsub")
        instance:on_unsubscribe("s-unsub")
        local subscribed_events = #bridge.events
        instance:on_event(session, { type = "agent_settled" })
        assert.equals(subscribed_events, #bridge.events)
        -- State still accumulated while unsubscribed; a snapshot serves it.
        assert.equals("idle", instance:snapshot_for(session).status)
    end)
end)
