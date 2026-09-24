-- subagent.max_children counts LIVE child processes (any manifest status),
-- not just status=="active" rows: a completed child whose RPC process lingers
-- must keep holding a slot, while a dead process frees its.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")

describe("manifest alive occupancy (is_alive predicate)", function()
    local real_path
    local tmp

    before_each(function()
        tmp = vim.fn.tempname() .. "-alive-manifest.json"
        real_path = Manifest.path
        Manifest._reset()
        Manifest.path = function()
            return tmp
        end
    end)

    after_each(function()
        Manifest.path = real_path
        Manifest._reset()
        os.remove(tmp)
    end)

    ---@param id string
    ---@param parent string
    ---@param status string
    local function row(id, parent, status)
        Manifest.upsert(id, {
            parent_id = parent,
            name = id,
            task_prompt = "task",
            config = {},
            status = status,
            reported = false,
            created_at = Manifest.iso_now(),
            last_active_at = Manifest.iso_now(),
        })
    end

    ---@param alive table<string, boolean>
    ---@return pi.SubsessionChildAlivePred
    local function predicate(alive)
        return function(id)
            return alive[id] == true
        end
    end

    it("without a predicate keeps legacy counting: only status==active rows", function()
        row("c1", "L", "completed")
        row("c2", "L", "active")
        assert.equals(1, Manifest.spawn_occupancy("L"))
        -- completed-but-alive does not occupy without a predicate
        assert.is_true(Manifest.try_reserve_spawn("L", 2))
        assert.is_false(Manifest.try_reserve_spawn("L", 2))
    end)

    it("with a predicate counts completed-but-alive children toward the limit", function()
        row("c1", "L", "completed")
        row("c2", "L", "active")
        local is_alive = predicate({ c1 = true, c2 = true })
        assert.equals(2, Manifest.spawn_occupancy("L", is_alive))
        assert.equals(2, Manifest.count_alive_children("L", is_alive))
        assert.is_false(Manifest.try_reserve_spawn("L", 2, is_alive))
    end)

    it("counts interrupted-but-alive children regardless of status", function()
        row("c1", "L", "interrupted")
        local is_alive = predicate({ c1 = true })
        assert.equals(1, Manifest.spawn_occupancy("L", is_alive))
        assert.is_false(Manifest.try_reserve_spawn("L", 1, is_alive))
    end)

    it("does not count dead children (predicate false / no registry record)", function()
        row("c1", "L", "completed") -- alive process: occupies
        row("c2", "L", "failed") -- dead: freed
        row("c3", "L", "dormant") -- dead: freed
        row("c4", "L", "active") -- status active but process gone: freed
        local is_alive = predicate({ c1 = true })
        assert.equals(1, Manifest.spawn_occupancy("L", is_alive))
        assert.is_true(Manifest.try_reserve_spawn("L", 2, is_alive))
    end)

    it("still counts in-flight reservations with a predicate", function()
        local is_alive = predicate({})
        assert.is_true(Manifest.try_reserve_spawn("L", 1, is_alive))
        assert.equals(1, Manifest.pending_spawns("L"))
        assert.is_false(Manifest.try_reserve_spawn("L", 1, is_alive))
        Manifest.release_spawn("L")
        assert.is_true(Manifest.try_reserve_spawn("L", 1, is_alive))
    end)

    it("scopes counting to the lineage", function()
        row("c1", "other", "active")
        row("c2", "other", "completed")
        local is_alive = predicate({ c1 = true, c2 = true })
        assert.equals(0, Manifest.spawn_occupancy("L", is_alive))
        assert.is_true(Manifest.try_reserve_spawn("L", 1, is_alive))
    end)
end)

describe("spawn enforces max_children over live children", function()
    local manifest_tmp
    local real_create
    local real_path
    local created = 0

    before_each(function()
        Config.setup({ subagent = { enabled = true, max_children = 1 } })
        created = 0
        manifest_tmp = vim.fn.tempname() .. "-alive-spawn-manifest.json"
        real_path = Manifest.path
        Manifest._reset()
        Manifest.path = function()
            return manifest_tmp
        end
        real_create = Sessions.create_detached
        Sessions.create_detached = function()
            created = created + 1
            local n = created
            local session = {
                id = "tmp-spawn-" .. n,
                rpc = {
                    is_running = function()
                        return true
                    end,
                    stop = function() end,
                    send = function(_, cmd, cb)
                        if cmd.type == "get_state" and cb then
                            vim.schedule(function()
                                cb({ success = true, data = { sessionId = "child-" .. n } })
                            end)
                        elseif cmd.type == "prompt" and cb then
                            vim.schedule(function()
                                cb({ success = true })
                            end)
                        end
                        return true
                    end,
                },
            }
            Sessions._register_for_test(session)
            return session
        end
    end)

    after_each(function()
        Sessions.create_detached = real_create
        Manifest.path = real_path
        Manifest._reset()
        os.remove(manifest_tmp)
        Sessions._reset()
        Config.setup({})
    end)

    local function make_parent()
        return {
            id = "parent-1",
            conversation_epoch = 0,
            rpc = {
                is_running = function()
                    return true
                end,
            },
        }
    end

    ---@param task string
    ---@return pi.Session?, string?
    local function spawn_sync(task)
        local child, err
        Subsessions.spawn(make_parent(), { task = task }, function(c, e)
            child = c
            err = e
        end)
        assert.is_true(
            vim.wait(3000, function()
                return child ~= nil or err ~= nil
            end, 10),
            "spawn should settle"
        )
        return child, err
    end

    it("blocks a new spawn while a completed child process is still alive", function()
        local child, err = spawn_sync("one")
        assert.is_nil(err)
        assert.is_truthy(child)
        assert.is_true(
            vim.wait(3000, function()
                return Manifest.load()["child-1"] ~= nil
            end, 10),
            "first child should register"
        )

        -- Simulate on_child_settled: task done, status completed, process still running.
        Manifest.patch("child-1", { status = "completed", last_active_at = Manifest.iso_now() })
        assert.is_truthy(Sessions.get_by_id("child-1"))

        local _, second_err = spawn_sync("two")
        assert.is_truthy(second_err, "second spawn must be refused while the completed child is alive")
        assert.is_truthy(second_err:find("max", 1, true))
        assert.equals(1, created)
    end)

    it("frees the slot once the completed child's process is gone", function()
        local child, err = spawn_sync("one")
        assert.is_nil(err)
        assert.is_truthy(child)
        assert.is_true(
            vim.wait(3000, function()
                return Manifest.load()["child-1"] ~= nil
            end, 10),
            "first child should register"
        )
        Manifest.patch("child-1", { status = "completed", last_active_at = Manifest.iso_now() })

        -- Process death: registry row removed (close_session / on_exit).
        local first = Sessions.get_by_id("child-1")
        assert.is_truthy(first)
        Sessions.close_session(first)
        assert.is_nil(Sessions.get_by_id("child-1"))

        local second, second_err = spawn_sync("two")
        assert.is_nil(second_err)
        assert.is_truthy(second, "dead completed child must not hold a slot")
        assert.is_true(
            vim.wait(3000, function()
                return Manifest.load()["child-2"] ~= nil
            end, 10),
            "second child should register"
        )
    end)

    it("keeps the in-flight reservation race guard (parallel spawn)", function()
        -- With the registry empty, two back-to-back spawns race only through
        -- the in-flight reservation: the second must fail while the first is
        -- still reserving (before its registry row exists).
        local first_child, first_err
        Subsessions.spawn(make_parent(), { task = "one" }, function(c, e)
            first_child = c
            first_err = e
        end)
        local second_child, second_err
        Subsessions.spawn(make_parent(), { task = "two" }, function(c, e)
            second_child = c
            second_err = e
        end)
        assert.is_nil(first_err)
        assert.is_truthy(second_err)
        assert.is_truthy(second_err:find("max", 1, true))
        assert.is_true(
            vim.wait(3000, function()
                return first_child ~= nil
            end, 10),
            "first spawn should complete"
        )
        assert.equals(1, created)
    end)
end)
