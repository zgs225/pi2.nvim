-- Projection of the sub-session tree onto `workspace.query{kind="sessions"}`
-- rows: `parentId` + the manifest metadata + the default :PiSessions
-- `visible` policy (never acknowledged by the query path).
--
-- The disk listing is stubbed (`History.list`) and the manifest is written to a
-- temp sessions dir, so the spec exercises only the projection, not IO.

local Commands = require("pi.web.commands")
local Sessions = require("pi.sessions.manager")
local History = require("pi.sessions.history")
local Manifest = require("pi.subsessions.manifest")
local ChildFilter = require("pi.subsessions.sessions_list")
local Config = require("pi.config")
local Instance = require("pi.web.instance")

--- @return pi.TestFakeWebBridge
local function fake_bridge()
    local bridge = { events = {}, snapshots = {}, instance_states = {}, ready = true }
    function bridge:send_event()
        return true
    end
    function bridge:send_snapshot()
        return true
    end
    function bridge:send_instance_state()
        return true
    end
    function bridge:status()
        return { ready = true, instance_id = "i-tree", started = true, connected = true }
    end
    function bridge:stop() end
    return bridge
end

--- @param opts? { id?: string, running?: boolean, busy?: boolean, streaming?: boolean }
--- @return pi.Session
local function fake_session(opts)
    opts = opts or {}
    local running = opts.running ~= false
    --- @type pi.Session
    local session = {
        id = opts.id or "s-1",
        cwd = "/repo",
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        changed_files = {},
        pinned_config = {},
        rpc = {
            is_running = function()
                return running
            end,
            stop = function() end,
            send = function()
                return true
            end,
        },
        _set_running = function(value)
            running = value
        end,
    }
    if opts.busy then
        session._detached_busy = true
    end
    if opts.streaming then
        -- A tab-backed session reports its live turn through `chat`, not the
        -- detached flags; `:PiSessions` reads that first.
        session.chat = {
            is_streaming = function()
                return true
            end,
            is_compacting = function()
                return false
            end,
        }
    end
    return session
end

--- @param overrides? table
--- @return pi.SubsessionManifestEntry
local function child_entry(overrides)
    return vim.tbl_extend("force", {
        parent_id = "root-1",
        name = "Child",
        task_prompt = "implement it",
        config = { model = { provider = "p", id = "m" }, thinking_level = "low" },
        status = "completed",
        reported = true,
        created_at = "2026-01-01T00:00:00Z",
        last_active_at = "2026-01-01T00:05:00Z",
    }, overrides or {})
end

--- @param ids string[]
--- @return table[]
local function disk_rows(ids)
    local rows = {}
    for _, id in ipairs(ids) do
        rows[#rows + 1] = {
            id = id,
            path = "/tmp/" .. id .. ".jsonl",
            timestamp = "2026-01-01T00:00:00Z",
            modified = 1,
            first_message = "hi",
        }
    end
    return rows
end

describe("pi.web sessions tree projection", function()
    local saved_cwd
    local saved_agent_dir
    local saved_subagent
    local sessions_dir
    local restores

    --- @param module table
    --- @param name string
    --- @param replacement function
    local function stub(module, name, replacement)
        local original = module[name]
        module[name] = replacement
        restores[#restores + 1] = function()
            module[name] = original
        end
    end

    --- Temp workspace + sessions dir; the manifest path follows `agent_dir`.
    --- @return string workspace
    local function setup_workspace()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        local workspace = root .. "/repo"
        vim.fn.mkdir(workspace, "p")
        Config.options.agent_dir = root .. "/agent"
        vim.fn.mkdir(Config.options.agent_dir .. "/sessions", "p")
        vim.cmd("cd " .. vim.fn.fnameescape(workspace))
        sessions_dir = History.get_sessions_dir()
        vim.fn.mkdir(sessions_dir, "p")
        Manifest._reset()
        return workspace
    end

    --- @param manifest table
    local function write_manifest(manifest)
        vim.fn.writefile({ vim.json.encode(manifest) }, sessions_dir .. "/.pi2-subsessions.json")
        Manifest._reset()
    end

    --- @param rows table[]
    local function stub_disk(rows)
        stub(History, "list", function()
            return rows
        end)
    end

    --- @return table sessions, table<string, table>
    local function query()
        local ok, result = Commands.dispatch("workspace.query", { kind = "sessions" }, {})
        assert.is_true(ok)
        local by_id = {}
        for _, row in ipairs(result.sessions) do
            by_id[row.sessionId] = row
        end
        return result.sessions, by_id
    end

    before_each(function()
        restores = {}
        saved_cwd = vim.fn.getcwd()
        saved_agent_dir = Config.options.agent_dir
        saved_subagent = vim.deepcopy(Config.options.subagent)
        Sessions._reset()
        Commands._reset_caches()
        ChildFilter._reset_completion_seen()
        Manifest._reset()
    end)

    after_each(function()
        for _, restore in ipairs(restores) do
            restore()
        end
        Instance.shutdown()
        Sessions._reset()
        Commands._reset_caches()
        ChildFilter._reset_completion_seen()
        Manifest._reset()
        Config.options.agent_dir = saved_agent_dir
        Config.options.subagent = saved_subagent
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(saved_cwd))
    end)

    it("marks root rows visible and leaves them without a parentId", function()
        setup_workspace()
        write_manifest({ ["child-1"] = child_entry() })
        stub_disk(disk_rows({ "root-1", "child-1" }))

        local sessions, by_id = query()
        assert.equals(2, #sessions)
        assert.is_true(by_id["root-1"].visible)
        assert.is_nil(by_id["root-1"].parentId)
        assert.is_true(by_id["child-1"].visible)
    end)

    it("links a child to its parent and projects the manifest metadata", function()
        setup_workspace()
        write_manifest({ ["child-1"] = child_entry({ status = "completed", reported = true }) })
        stub_disk(disk_rows({ "root-1", "child-1" }))

        local _, by_id = query()
        local child = by_id["child-1"]
        assert.equals("root-1", child.parentId)
        -- The disk row has no name: the manifest name is the fallback.
        assert.equals("Child", child.name)
        assert.equals("done", child.status)
        assert.equals("low", child.thinking)
        assert.equals("implement it", child.task)
        assert.is_false(child.agentSpawned)
        assert.is_true(child.reported)
        assert.equals(Manifest.epoch_ms("2026-01-01T00:00:00Z"), child.createdAt)
        assert.equals(Manifest.epoch_ms("2026-01-01T00:05:00Z"), child.lastActiveAt)
        assert.equals("number", type(child.createdAt))
        assert.is_true(child.createdAt > 0)
    end)

    it("resolves a grandchild parentId to the child session id", function()
        setup_workspace()
        write_manifest({
            ["child-1"] = child_entry(),
            ["grand-1"] = child_entry({ parent_id = "child-1", name = "Grandchild" }),
        })
        stub_disk(disk_rows({ "root-1", "child-1", "grand-1" }))

        local _, by_id = query()
        assert.equals("child-1", by_id["grand-1"].parentId)
        assert.equals("root-1", by_id["child-1"].parentId)
    end)

    it("hides a completed agent-spawned child", function()
        setup_workspace()
        write_manifest({
            ["child-1"] = child_entry({ status = "completed", reported = true, agent_spawned = true }),
        })
        stub_disk(disk_rows({ "root-1", "child-1" }))

        local _, by_id = query()
        assert.is_false(by_id["child-1"].visible)
    end)

    it("keeps an unreported completed child visible after an acknowledgement", function()
        setup_workspace()
        write_manifest({ ["child-1"] = child_entry({ status = "completed", reported = false }) })
        stub_disk(disk_rows({ "root-1", "child-1" }))

        local _, by_id = query()
        assert.is_true(by_id["child-1"].visible)

        -- Unreported work stays in the list: acknowledgement only hides a child
        -- whose report already reached the parent.
        assert.is_true(ChildFilter.mark_completion_seen("child-1"))
        local _, again = query()
        assert.is_true(again["child-1"].visible)
    end)

    it("hides a reported completed child once its completion was acknowledged", function()
        setup_workspace()
        write_manifest({ ["child-1"] = child_entry({ status = "completed", reported = true }) })
        stub_disk(disk_rows({ "root-1", "child-1" }))

        local _, by_id = query()
        assert.is_true(by_id["child-1"].visible)

        -- The query path never acknowledges; only a user action does.
        assert.is_true(ChildFilter.mark_completion_seen("child-1"))
        local _, again = query()
        assert.is_false(again["child-1"].visible)
    end)

    it("hides dormant children by default and shows them with show_dormant", function()
        setup_workspace()
        write_manifest({ ["child-1"] = child_entry({ status = "dormant" }) })
        stub_disk(disk_rows({ "root-1", "child-1" }))

        local _, by_id = query()
        assert.equals("dormant", by_id["child-1"].status)
        assert.is_false(by_id["child-1"].visible)

        Config.options.subagent.sessions_list.show_dormant = true
        local _, shown = query()
        assert.is_true(shown["child-1"].visible)
    end)

    it("hides a failed child once it was acknowledged", function()
        setup_workspace()
        write_manifest({ ["child-1"] = child_entry({ status = "failed" }) })
        stub_disk(disk_rows({ "root-1", "child-1" }))

        local _, by_id = query()
        assert.equals("error", by_id["child-1"].status)
        assert.is_true(by_id["child-1"].visible)

        ChildFilter.mark_completion_seen("child-1")
        local _, again = query()
        assert.is_false(again["child-1"].visible)
    end)

    it("keeps a running child visible and uses the instance's live status", function()
        local workspace = setup_workspace()
        write_manifest({ ["child-1"] = child_entry({ status = "dormant" }) })
        Instance.setup({ workspace_id = "ws-tree", cwd = workspace, bridge = fake_bridge() })

        local live = fake_session({ id = "child-1", busy = true })
        live.cwd = workspace
        Sessions._register_for_test(live)
        stub_disk(disk_rows({ "root-1" }))

        local _, by_id = query()
        assert.is_true(by_id["child-1"].live)
        assert.equals("busy", by_id["child-1"].status)
        assert.is_true(by_id["child-1"].visible)
        assert.equals("root-1", by_id["child-1"].parentId)
    end)

    it("treats a chat-streaming child as running, like :PiSessions", function()
        local workspace = setup_workspace()
        write_manifest({ ["child-1"] = child_entry({ status = "dormant" }) })
        Instance.setup({ workspace_id = "ws-tree", cwd = workspace, bridge = fake_bridge() })

        local live = fake_session({ id = "child-1", streaming = true })
        live.cwd = workspace
        Sessions._register_for_test(live)
        stub_disk(disk_rows({ "root-1" }))

        local _, by_id = query()
        -- `chat:is_streaming()` (no `_detached_busy`) must still count as running:
        -- the shared policy and the row status come from the same source.
        assert.is_true(by_id["child-1"].visible)
        assert.equals("busy", by_id["child-1"].status)
    end)

    it("enriches a live-only child that has no disk row", function()
        local workspace = setup_workspace()
        write_manifest({ ["child-2"] = child_entry({ name = "Live child" }) })
        Instance.setup({ workspace_id = "ws-tree", cwd = workspace, bridge = fake_bridge() })

        local live = fake_session({ id = "child-2" })
        live.cwd = workspace
        Sessions._register_for_test(live)
        stub_disk(disk_rows({ "root-1" }))

        local sessions, by_id = query()
        assert.equals(2, #sessions)
        local child = by_id["child-2"]
        assert.is_true(child.live)
        assert.equals("root-1", child.parentId)
        assert.equals("Live child", child.name)
        assert.is_true(child.visible)
        assert.equals("number", type(child.createdAt))
    end)

    it("normalizes a migrated parent_id through resolve_lineage", function()
        setup_workspace()
        write_manifest({
            ["child-1"] = child_entry({ parent_id = "root-legacy" }),
            __lineage__ = { ["root-legacy"] = "root-1" },
        })
        stub_disk(disk_rows({ "root-1", "child-1" }))

        local _, by_id = query()
        assert.equals("root-1", by_id["child-1"].parentId)
    end)

    it("does not crash on a corrupt manifest and leaves rows unfiltered", function()
        setup_workspace()
        vim.fn.writefile({ "{ not json" }, sessions_dir .. "/.pi2-subsessions.json")
        Manifest._reset()
        assert.same({}, Manifest.load())
        assert.is_true(Manifest.decode_failed())
        stub_disk(disk_rows({ "root-1", "child-1" }))

        local sessions, by_id = query()
        assert.equals(2, #sessions)
        for _, row in ipairs(sessions) do
            assert.is_true(row.visible)
            assert.is_nil(row.parentId)
        end
    end)

    it("keeps exactly one row for a child present on disk and live", function()
        local workspace = setup_workspace()
        write_manifest({ ["child-1"] = child_entry() })
        Instance.setup({ workspace_id = "ws-tree", cwd = workspace, bridge = fake_bridge() })

        local live = fake_session({ id = "child-1" })
        live.cwd = workspace
        Sessions._register_for_test(live)
        stub_disk(disk_rows({ "root-1", "child-1" }))

        local sessions = query()
        local n = 0
        for _, row in ipairs(sessions) do
            if row.sessionId == "child-1" then
                n = n + 1
            end
        end
        assert.equals(1, n)
    end)
end)
