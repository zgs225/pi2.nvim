-- Idle reaper for settled sub-session children: condition branches of
-- M.reap / M.sweep, event-driven scheduling, and the periodic sweep timer.
-- Hermetic: manifest redirected to a temp file, registry fakes via
-- _register_for_test / _bind_shim_for_test, Subsessions.close stubbed, and
-- vim.defer_fn captured — no real pi processes, no network, no real clock waits.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Reaper = require("pi.subsessions.reaper")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")

Config.setup({})

describe("subsession idle reaper", function()
    local manifest_tmp
    local real_manifest_path
    local real_close
    local real_defer_fn
    local real_find_path
    local real_infer
    local real_subagent_opts
    local closed
    local deferred

    ---@param id string
    ---@param status string manifest status
    ---@param opts? { running?: boolean, last_active_at?: string | false, bound?: boolean, parent_id?: string }
    ---@return table session Registered fake child session.
    local function add_child(id, status, opts)
        opts = opts or {}
        local last_active_at = opts.last_active_at ~= false and (opts.last_active_at or "2024-01-01T00:00:00Z") or nil
        Manifest.upsert(id, {
            parent_id = opts.parent_id or "lineage-a",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "t",
            config = {},
            status = status,
            reported = false,
            created_at = "2024-01-01T00:00:00Z",
            last_active_at = last_active_at,
        })
        ---@type table
        local session = {
            id = id,
            parent_id = opts.parent_id or "lineage-a",
            rpc = {
                is_running = function()
                    return opts.running ~= false
                end,
                stop = function() end,
            },
        }
        if opts.bound then
            Sessions._bind_shim_for_test(session, vim.api.nvim_get_current_tabpage())
        else
            Sessions._register_for_test(session)
        end
        return session
    end

    before_each(function()
        Config.setup({})
        -- tbl_deep_extend aliases nested defaults tables onto options: decouple
        -- before per-test mutations, or they pollute the shared defaults (G19).
        Config.options.subagent = vim.deepcopy(Config.options.subagent)
        closed = {}
        deferred = {}
        real_manifest_path = Manifest.path
        manifest_tmp = vim.fn.tempname() .. ".json"
        Manifest.path = function()
            return manifest_tmp
        end
        Manifest._reset()
        Sessions._reset()
        Reaper._reset()
        real_close = Subsessions.close
        Subsessions.close = function(child_id)
            closed[#closed + 1] = child_id
            return true
        end
        real_defer_fn = vim.defer_fn
        vim.defer_fn = function(fn, ms)
            deferred[#deferred + 1] = { fn = fn, ms = ms }
        end
        real_find_path = Read.find_path
        real_infer = Read.infer_run_status
        real_subagent_opts = vim.deepcopy(Config.options.subagent)
    end)

    after_each(function()
        Subsessions.close = real_close
        vim.defer_fn = real_defer_fn
        Read.find_path = real_find_path
        Read.infer_run_status = real_infer
        Config.options.subagent = real_subagent_opts
        Sessions._reset()
        Manifest.path = real_manifest_path
        Manifest._reset()
        Reaper._reset()
        pcall(os.remove, manifest_tmp)
    end)

    describe("reap", function()
        it("closes a settled, live child that no tab is showing", function()
            add_child("child-1", "completed")
            assert.is_true(Reaper.reap("child-1"))
            assert.are.same({ "child-1" }, closed)
        end)

        it("reaps interrupted and failed children too", function()
            add_child("child-i", "interrupted")
            add_child("child-f", "failed")
            assert.is_true(Reaper.reap("child-i"))
            assert.is_true(Reaper.reap("child-f"))
            assert.are.same({ "child-i", "child-f" }, closed)
        end)

        it("skips an active child (revived / new task)", function()
            add_child("child-1", "active")
            assert.is_false(Reaper.reap("child-1"))
            assert.are.same({}, closed)
        end)

        it("skips a dormant child", function()
            add_child("child-1", "dormant")
            assert.is_false(Reaper.reap("child-1"))
            assert.are.same({}, closed)
        end)

        it("skips when the process is no longer running", function()
            add_child("child-1", "completed", { running = false })
            assert.is_false(Reaper.reap("child-1"))
            assert.are.same({}, closed)
        end)

        it("skips when the child is not in the registry at all", function()
            Manifest.upsert("child-ghost", {
                parent_id = "lineage-a",
                parent_epoch = 0,
                name = "ghost",
                task_prompt = "t",
                config = {},
                status = "completed",
                reported = false,
                created_at = "2024-01-01T00:00:00Z",
                last_active_at = "2024-01-01T00:00:00Z",
            })
            assert.is_false(Reaper.reap("child-ghost"))
            assert.are.same({}, closed)
        end)

        it("skips a child with no manifest entry", function()
            Sessions._register_for_test({
                id = "child-nomanifest",
                rpc = {
                    is_running = function()
                        return true
                    end,
                    stop = function() end,
                },
            })
            assert.is_false(Reaper.reap("child-nomanifest"))
            assert.are.same({}, closed)
        end)

        it("skips a child that is the current session of a tab", function()
            add_child("child-1", "completed", { bound = true })
            assert.is_false(Reaper.reap("child-1"))
            assert.are.same({}, closed)
        end)

        it("rejects empty / non-string ids", function()
            assert.is_false(Reaper.reap(""))
            assert.is_false(Reaper.reap(nil --[[@as string]]))
            assert.are.same({}, closed)
        end)
    end)

    describe("reap_oldest_settled", function()
        it("reaps the oldest child first when needed is 1 (LRU order)", function()
            add_child("child-old", "completed", { last_active_at = "2024-01-01T00:00:00Z" })
            add_child("child-new", "completed", { last_active_at = "2024-01-02T00:00:00Z" })
            assert.are.equal(1, Reaper.reap_oldest_settled("lineage-a", 1))
            assert.are.same({ "child-old" }, closed)
        end)

        it("reaps all settled children when needed covers all", function()
            add_child("child-1", "completed", { last_active_at = "2024-01-01T00:00:00Z" })
            add_child("child-2", "completed", { last_active_at = "2024-01-02T00:00:00Z" })
            assert.are.equal(2, Reaper.reap_oldest_settled("lineage-a", 2))
            assert.are.same({ "child-1", "child-2" }, closed)
        end)

        it("treats nil last_active_at as oldest", function()
            add_child("child-nil", "completed", { last_active_at = false })
            add_child("child-dated", "completed", { last_active_at = "2024-01-01T00:00:00Z" })
            assert.are.equal(1, Reaper.reap_oldest_settled("lineage-a", 1))
            assert.are.same({ "child-nil" }, closed)
        end)

        it("skips active children", function()
            add_child("child-active", "active", { last_active_at = "2024-01-01T00:00:00Z" })
            add_child("child-completed", "completed", { last_active_at = "2024-01-02T00:00:00Z" })
            assert.are.equal(1, Reaper.reap_oldest_settled("lineage-a", 2))
            assert.are.same({ "child-completed" }, closed)
        end)

        it("skips dormant children and dead processes", function()
            add_child("child-dormant", "dormant", { last_active_at = "2024-01-01T00:00:00Z" })
            add_child("child-dead", "completed", { last_active_at = "2024-01-01T01:00:00Z", running = false })
            add_child("child-live", "completed", { last_active_at = "2024-01-01T02:00:00Z" })
            assert.are.equal(1, Reaper.reap_oldest_settled("lineage-a", 3))
            assert.are.same({ "child-live" }, closed)
        end)

        it("skips children viewed by a tabpage", function()
            add_child("child-viewed", "completed", { last_active_at = "2024-01-01T00:00:00Z", bound = true })
            add_child("child-unbound", "completed", { last_active_at = "2024-01-02T00:00:00Z" })
            assert.are.equal(1, Reaper.reap_oldest_settled("lineage-a", 2))
            assert.are.same({ "child-unbound" }, closed)
        end)

        it("only reaps children belonging to the specified lineage_id", function()
            add_child("child-a", "completed", { parent_id = "lineage-a", last_active_at = "2024-01-01T00:00:00Z" })
            add_child("child-b", "completed", { parent_id = "lineage-b", last_active_at = "2024-01-01T00:00:00Z" })
            assert.are.equal(1, Reaper.reap_oldest_settled("lineage-a", 2))
            assert.are.same({ "child-a" }, closed)
        end)

        it("returns 0 when needed <= 0 or lineage_id is empty/invalid", function()
            add_child("child-1", "completed")
            assert.are.equal(0, Reaper.reap_oldest_settled("lineage-a", 0))
            assert.are.equal(0, Reaper.reap_oldest_settled("lineage-a", -1))
            assert.are.equal(0, Reaper.reap_oldest_settled("", 1))
            assert.are.equal(0, Reaper.reap_oldest_settled(nil --[[@as string]], 1))
            assert.are.same({}, closed)
        end)
    end)

    describe("schedule", function()
        it("defers one re-check after reap_after_minutes", function()
            Config.options.subagent.reap_after_minutes = 45
            Reaper.schedule("child-1")
            assert.are.equal(1, #deferred)
            assert.are.equal(45 * 60 * 1000, deferred[1].ms)
        end)

        it("does not schedule when reap_after_minutes is 0", function()
            Config.options.subagent.reap_after_minutes = 0
            Reaper.schedule("child-1")
            assert.are.equal(0, #deferred)
        end)

        it("the deferred check reaps a still-settled child", function()
            Config.options.subagent.reap_after_minutes = 1
            add_child("child-1", "completed")
            Reaper.schedule("child-1")
            assert.are.equal(1, #deferred)
            deferred[1].fn()
            vim.wait(200, function()
                return #closed > 0
            end, 10)
            assert.are.same({ "child-1" }, closed)
        end)

        it("the deferred check skips a child revived to active", function()
            Config.options.subagent.reap_after_minutes = 1
            add_child("child-1", "completed")
            Reaper.schedule("child-1")
            Manifest.patch("child-1", { status = "active", last_active_at = Manifest.iso_now() })
            deferred[1].fn()
            vim.wait(100)
            assert.are.same({}, closed)
        end)
    end)

    describe("sweep", function()
        it("closes manifest children idle past reap_after_minutes", function()
            add_child("child-old", "completed", { last_active_at = "2000-01-01T00:00:00Z" })
            assert.are.equal(1, Reaper.sweep())
            assert.are.same({ "child-old" }, closed)
        end)

        it("leaves recently active children alone", function()
            add_child("child-new", "completed", { last_active_at = Manifest.iso_now() })
            assert.are.equal(0, Reaper.sweep())
            assert.are.same({}, closed)
        end)

        it("leaves manifest-active children alone regardless of age", function()
            add_child("child-active", "active", { last_active_at = "2000-01-01T00:00:00Z" })
            assert.are.equal(0, Reaper.sweep())
            assert.are.same({}, closed)
        end)

        it("leaves dormant manifest rows alone", function()
            add_child("child-dormant", "dormant", { last_active_at = "2000-01-01T00:00:00Z" })
            assert.are.equal(0, Reaper.sweep())
            assert.are.same({}, closed)
        end)

        it("skips dead processes even when manifest says settled", function()
            add_child("child-dead", "completed", { last_active_at = "2000-01-01T00:00:00Z", running = false })
            assert.are.equal(0, Reaper.sweep())
            assert.are.same({}, closed)
        end)

        it("skips a settled child a tab is currently showing", function()
            add_child("child-view", "completed", { last_active_at = "2000-01-01T00:00:00Z", bound = true })
            assert.are.equal(0, Reaper.sweep())
            assert.are.same({}, closed)
        end)

        it("is a no-op when reap_after_minutes is 0", function()
            Config.options.subagent.reap_after_minutes = 0
            add_child("child-old", "completed", { last_active_at = "2000-01-01T00:00:00Z" })
            assert.are.equal(0, Reaper.sweep())
            assert.are.same({}, closed)
        end)

        it("covers a live registry child with no manifest row (session-file fallback)", function()
            local path = vim.fn.tempname() .. ".jsonl"
            local f = assert(io.open(path, "w"))
            f:write(vim.json.encode({ type = "message", message = { role = "assistant", content = "done" } }), "\n")
            f:close()
            local old = os.time() - 3600
            vim.uv.fs_utime(path, old, old)

            Sessions._register_for_test({
                id = "child-orphan",
                parent_id = "lineage-a",
                session_file = path,
                rpc = {
                    is_running = function()
                        return true
                    end,
                    stop = function() end,
                },
            })
            assert.are.equal(1, Reaper.sweep())
            assert.are.same({ "child-orphan" }, closed)
            pcall(os.remove, path)
        end)

        it("leaves a manifest-less child alone while its session file is fresh", function()
            local path = vim.fn.tempname() .. ".jsonl"
            local f = assert(io.open(path, "w"))
            f:write(vim.json.encode({ type = "message", message = { role = "assistant", content = "done" } }), "\n")
            f:close()

            Sessions._register_for_test({
                id = "child-fresh",
                parent_id = "lineage-a",
                session_file = path,
                rpc = {
                    is_running = function()
                        return true
                    end,
                    stop = function() end,
                },
            })
            assert.are.equal(0, Reaper.sweep())
            assert.are.same({}, closed)
            pcall(os.remove, path)
        end)

        it("leaves a manifest-less child alone while its transcript has no settled turn", function()
            local path = vim.fn.tempname() .. ".jsonl"
            local f = assert(io.open(path, "w"))
            f:write(vim.json.encode({ type = "message", message = { role = "user", content = "wip" } }), "\n")
            f:close()
            local old = os.time() - 3600
            vim.uv.fs_utime(path, old, old)

            Sessions._register_for_test({
                id = "child-wip",
                parent_id = "lineage-a",
                session_file = path,
                rpc = {
                    is_running = function()
                        return true
                    end,
                    stop = function() end,
                },
            })
            assert.are.equal(0, Reaper.sweep())
            assert.are.same({}, closed)
            pcall(os.remove, path)
        end)
    end)

    describe("start/stop", function()
        it("is a no-op when reap_sweep_minutes is 0", function()
            Config.options.subagent.reap_sweep_minutes = 0
            Reaper.start()
            assert.is_false(Reaper._sweep_running())
        end)

        it("arms the sweep timer, is idempotent, and stop() is idempotent", function()
            Config.options.subagent.reap_sweep_minutes = 10
            Reaper.start()
            assert.is_true(Reaper._sweep_running())
            Reaper.start() -- second start must not leak a second timer
            assert.is_true(Reaper._sweep_running())
            Reaper.stop()
            assert.is_false(Reaper._sweep_running())
            Reaper.stop()
            assert.is_false(Reaper._sweep_running())
        end)
    end)

    describe("config defaults (G19)", function()
        it("resolves both reaper keys from defaults", function()
            Config.setup({})
            assert.are.equal(30, Config.options.subagent.reap_after_minutes)
            assert.are.equal(10, Config.options.subagent.reap_sweep_minutes)
        end)
    end)
end)
