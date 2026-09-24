-- Background task state machine (lua/pi/tasks.lua).
--
-- Hermetic: feeds synthetic pi2_bg_task events through handle_event and
-- exercises the pure registry/row logic. No real pi process, no UI.

local Tasks = require("pi.tasks")

--- Build a pi2_bg_task event envelope the way the session pipeline forwards it.
---@param kind string
---@param fields table?
---@param timestamp integer?
---@return table
local function ev(kind, fields, timestamp)
    return {
        type = "pi2_bg_task",
        timestamp = timestamp,
        details = vim.tbl_extend("force", { kind = kind, taskId = "t1" }, fields or {}),
    }
end

--- Build a started event for an arbitrary task id.
---@param id string
---@param start_time integer
---@return table
local function started_ev(id, start_time, fields)
    return {
        type = "pi2_bg_task",
        timestamp = start_time,
        details = vim.tbl_extend("force", { kind = "started", taskId = id, command = "echo hi" }, fields or {}),
    }
end

local function pump(ms)
    vim.wait(ms or 50)
end

describe("pi.tasks registry", function()
    before_each(function()
        Tasks._reset()
    end)

    it("upserts and gets by id", function()
        local t = { id = "a", command = "ls", status = "running", start_time = 10 }
        Tasks.upsert(t)
        assert.are.equal(t, Tasks.get("a"))
        assert.is_nil(Tasks.get("missing"))
    end)

    it("upsert replaces the record wholesale", function()
        Tasks.upsert({ id = "a", command = "ls", status = "running", start_time = 10 })
        Tasks.upsert({ id = "a", command = "pwd", status = "failed", start_time = 20, exit_code = 2 })
        local t = Tasks.get("a")
        assert.are.equal("pwd", t.command)
        assert.are.equal("failed", t.status)
        assert.are.equal(2, t.exit_code)
    end)

    it("sorts running first by start_time ascending, then terminal by end_time descending", function()
        Tasks.upsert({ id = "r2", command = "", status = "running", start_time = 200 })
        Tasks.upsert({ id = "done_old", command = "", status = "completed", start_time = 100, end_time = 150 })
        Tasks.upsert({ id = "r1", command = "", status = "running", start_time = 50 })
        Tasks.upsert({ id = "failed_new", command = "", status = "failed", start_time = 120, end_time = 500 })
        Tasks.upsert({ id = "stopped_mid", command = "", status = "stopped", start_time = 110, end_time = 300 })

        local ids = vim.tbl_map(function(t)
            return t.id
        end, Tasks.list())
        assert.are.same({ "r1", "r2", "failed_new", "stopped_mid", "done_old" }, ids)
    end)

    it("sorts terminal tasks with a missing end_time last", function()
        Tasks.upsert({ id = "done", command = "", status = "completed", start_time = 1, end_time = 10 })
        Tasks.upsert({ id = "no_end", command = "", status = "completed", start_time = 2 })

        local ids = vim.tbl_map(function(t)
            return t.id
        end, Tasks.list())
        assert.are.same({ "done", "no_end" }, ids)
    end)
end)

describe("pi.tasks handle_event", function()
    before_each(function()
        Tasks._reset()
    end)

    it("registers a started task as running with the event timestamp", function()
        assert.is_true(Tasks.handle_event(started_ev("a", 1000, { pid = 42, outputFile = "/tmp/out" })))
        local t = Tasks.get("a")
        assert.is_not_nil(t)
        assert.are.equal("running", t.status)
        assert.are.equal(1000, t.start_time)
        assert.are.equal("echo hi", t.command)
        assert.are.equal(42, t.pid)
        assert.are.equal("/tmp/out", t.output_file)
        assert.is_nil(t.end_time)
    end)

    it("falls back to vim.uv.now() when the event has no timestamp", function()
        local before = vim.uv.now()
        Tasks.handle_event(started_ev("a", nil))
        local t = Tasks.get("a")
        assert.is_true(t.start_time >= before, "start_time must come from vim.uv.now()")
    end)

    it("rebases Unix-epoch timestamps onto the uv clock", function()
        -- Core stamps custom messages with Date.now(); storing it verbatim
        -- makes age math (uv.now() - end_time) go negative and clamp to zero.
        local epoch_ms = os.time() * 1000 - 5000 -- 5s ago
        Tasks.handle_event(started_ev("a", epoch_ms))
        local t = Tasks.get("a")
        local age = vim.uv.now() - t.start_time
        -- os.time() has 1s resolution, so allow a tolerant window around 5s.
        assert.is_true(age >= 4000 and age <= 7000, "epoch ts rebased to the uv clock, got age " .. age)

        Tasks.handle_event(ev("completed", { taskId = "a" }, os.time() * 1000 - 2000))
        local t2 = Tasks.get("a")
        local end_age = vim.uv.now() - t2.end_time
        assert.is_true(end_age >= 1000 and end_age <= 4000, "terminal ts rebased too, got " .. end_age)
    end)

    it("completed defaults exit_code to 0 and failed to 1", function()
        Tasks.handle_event(started_ev("a", 1000))
        Tasks.handle_event(ev("completed", { taskId = "a" }, 1500))
        assert.are.equal("completed", Tasks.get("a").status)
        assert.are.equal(1500, Tasks.get("a").end_time)
        assert.are.equal(0, Tasks.get("a").exit_code)

        Tasks.handle_event(started_ev("b", 2000))
        Tasks.handle_event(ev("failed", { taskId = "b" }, 2600))
        assert.are.equal("failed", Tasks.get("b").status)
        assert.are.equal(2600, Tasks.get("b").end_time)
        assert.are.equal(1, Tasks.get("b").exit_code)
    end)

    it("keeps an explicit exit_code", function()
        Tasks.handle_event(started_ev("a", 1000))
        Tasks.handle_event(ev("completed", { taskId = "a", exitCode = 3 }, 1500))
        assert.are.equal(3, Tasks.get("a").exit_code)

        Tasks.handle_event(started_ev("b", 2000))
        Tasks.handle_event(ev("failed", { taskId = "b", exitCode = 137 }, 2600))
        assert.are.equal(137, Tasks.get("b").exit_code)
    end)

    it("synthesizes a record for a terminal event on an unknown task", function()
        assert.is_true(Tasks.handle_event(ev("completed", { taskId = "ghost", exitCode = 9 }, 700)))
        local t = Tasks.get("ghost")
        assert.is_not_nil(t)
        assert.are.equal("completed", t.status)
        assert.are.equal(700, t.start_time)
        assert.are.equal(700, t.end_time)
        assert.are.equal(9, t.exit_code)
    end)

    it("stopped transitions only from running and is idempotent", function()
        Tasks.handle_event(started_ev("a", 1000))
        assert.is_true(Tasks.handle_event(ev("stopped", { taskId = "a" }, 1800)))
        assert.are.equal("stopped", Tasks.get("a").status)
        assert.are.equal(1800, Tasks.get("a").end_time)

        -- Repeat stopped: recognized (true) but no state change.
        assert.is_true(Tasks.handle_event(ev("stopped", { taskId = "a", exitCode = 1 }, 9999)))
        assert.are.equal(1800, Tasks.get("a").end_time, "end_time must not move on a repeat stopped")
        assert.is_nil(Tasks.get("a").exit_code, "exit_code must not appear on a repeat stopped")
    end)

    it("stopped for an unknown or finished task changes nothing", function()
        assert.is_true(Tasks.handle_event(ev("stopped", { taskId = "ghost" }, 100)))

        Tasks.handle_event(started_ev("a", 1000))
        Tasks.handle_event(ev("completed", { taskId = "a" }, 1500))
        assert.is_true(Tasks.handle_event(ev("stopped", { taskId = "a" }, 9999)))
        assert.are.equal("completed", Tasks.get("a").status, "completed must not regress to stopped")
    end)

    it("ignores unknown kinds, missing taskId, and other event types without side effects", function()
        assert.is_false(Tasks.handle_event({ type = "agent_start" }))
        assert.is_false(Tasks.handle_event({ type = "pi2_bg_task", details = { kind = "mystery", taskId = "a" } }))
        assert.is_false(Tasks.handle_event({ type = "pi2_bg_task", details = { kind = "started" } }))
        assert.is_false(Tasks.handle_event({ type = "pi2_bg_task", details = { kind = "started", taskId = "" } }))
        assert.is_false(Tasks.handle_event({ type = "pi2_bg_task" }))
        assert.is_false(Tasks.handle_event(nil))

        assert.are.equal(0, #Tasks.list(), "no task may be registered by unrecognized events")
    end)

    it("requests a refresh after a real transition", function()
        Tasks.handle_event(started_ev("a", 1000))
        assert.is_true(Tasks.refresh_due())

        -- A recognized no-op (stopped on a finished task) must not schedule
        -- a new burst on its own, but the first refresh is still pending.
        Tasks.handle_event(ev("completed", { taskId = "a" }, 1500))
        Tasks.handle_event(ev("stopped", { taskId = "a" }, 1600))
        assert.is_true(Tasks.refresh_due())
    end)
end)

describe("pi.tasks per-session ownership", function()
    before_each(function()
        Tasks._reset()
    end)

    it("stores session_id/tab on a started record", function()
        assert.is_true(Tasks.handle_event(started_ev("a", 1000), "A", 7))
        local t = Tasks.get("a")
        assert.are.equal("A", t.session_id)
        assert.are.equal(7, t.tab)
    end)

    it("stores session_id/tab on a synthesized terminal record", function()
        assert.is_true(Tasks.handle_event(ev("failed", { taskId = "ghost", exitCode = 9 }, 700), "B", 3))
        local t = Tasks.get("ghost")
        assert.is_not_nil(t)
        assert.are.equal("B", t.session_id)
        assert.are.equal(3, t.tab)
    end)

    it("started without ownership leaves session_id/tab nil (unknown ownership)", function()
        Tasks.handle_event(started_ev("a", 1000))
        assert.is_nil(Tasks.get("a").session_id)
        assert.is_nil(Tasks.get("a").tab)
    end)

    it("terminal/stopped events never rewrite an existing task's owner", function()
        Tasks.handle_event(started_ev("a", 1000), "A", 1)
        Tasks.handle_event(ev("completed", { taskId = "a" }, 1500), "B", 2)
        local t = Tasks.get("a")
        assert.are.equal("completed", t.status)
        assert.are.equal("A", t.session_id, "completed event must not rewrite the owner")
        assert.are.equal(1, t.tab)

        Tasks.handle_event(started_ev("b", 2000), "A", 1)
        Tasks.handle_event(ev("stopped", { taskId = "b" }, 2600), "B", 2)
        assert.are.equal("stopped", Tasks.get("b").status)
        assert.are.equal("A", Tasks.get("b").session_id, "stopped event must not rewrite the owner")
        assert.are.equal(1, Tasks.get("b").tab)
    end)

    it("list(nil) returns everything; list(session_id) filters by owner", function()
        Tasks.handle_event(started_ev("a", 100), "A", 1)
        Tasks.handle_event(started_ev("b", 200), "B", 2)
        Tasks.handle_event(ev("completed", { taskId = "a" }, 300), "B", 9) -- owner stays A
        Tasks.handle_event(started_ev("c", 50)) -- unknown ownership

        assert.are.equal(3, #Tasks.list())
        assert.are.equal(3, #Tasks.list(nil))

        local a_ids = vim.tbl_map(function(t)
            return t.id
        end, Tasks.list("A"))
        assert.are.same({ "a" }, a_ids)

        local b_ids = vim.tbl_map(function(t)
            return t.id
        end, Tasks.list("B"))
        assert.are.same({ "b" }, b_ids)

        assert.are.equal(0, #Tasks.list("missing"))
    end)

    it("list(session_id) keeps the panel sort order within the filter", function()
        Tasks.handle_event(started_ev("a", 100), "A", 1)
        Tasks.handle_event(started_ev("b", 200), "A", 1)
        Tasks.handle_event(ev("completed", { taskId = "a" }, 300), "A", 1)

        -- running (b) first, then terminal (a) by end_time desc.
        local ids = vim.tbl_map(function(t)
            return t.id
        end, Tasks.list("A"))
        assert.are.same({ "b", "a" }, ids)
    end)

    it("remove_session drops the owner's tasks, returns the count, refreshes", function()
        Tasks.handle_event(started_ev("a", 100), "A", 1)
        Tasks.handle_event(started_ev("b", 200), "A", 1)
        Tasks.handle_event(started_ev("c", 300), "B", 2)
        Tasks.handle_event(started_ev("d", 400)) -- unknown owner survives

        assert.are.equal(2, Tasks.remove_session("A"))
        assert.is_nil(Tasks.get("a"))
        assert.is_nil(Tasks.get("b"))
        assert.is_not_nil(Tasks.get("c"))
        assert.is_not_nil(Tasks.get("d"))
        assert.is_true(Tasks.refresh_due())
    end)

    it("remove_session returns 0 without refreshing for an unknown session", function()
        Tasks.upsert({ id = "a", command = "", status = "running", start_time = 1, session_id = "A" })
        assert.is_false(Tasks.refresh_due())
        assert.are.equal(0, Tasks.remove_session("ghost"))
        assert.is_false(Tasks.refresh_due(), "no deletions means no refresh")
        assert.is_not_nil(Tasks.get("a"))
    end)
end)

describe("pi.tasks build_rows", function()
    before_each(function()
        Tasks._reset()
    end)

    it("computes running, done, and degraded durations", function()
        Tasks.upsert({ id = "run", command = "", status = "running", start_time = 1000 })
        Tasks.upsert({ id = "done", command = "", status = "completed", start_time = 2000, end_time = 2500 })
        Tasks.upsert({ id = "noend", command = "", status = "failed", start_time = 3000 })

        local rows = Tasks.build_rows(4000)
        assert.are.equal(3, #rows)

        -- list() order: running first, terminal by end_time desc (nil last).
        assert.are.equal("run", rows[1].task.id)
        assert.are.equal("running", rows[1].status_label)
        assert.are.equal(3000, rows[1].duration_ms)

        assert.are.equal("done", rows[2].task.id)
        assert.are.equal("done", rows[2].status_label)
        assert.are.equal(500, rows[2].duration_ms)

        -- Missing end_time degrades to now-start.
        assert.are.equal("noend", rows[3].task.id)
        assert.are.equal("failed", rows[3].status_label)
        assert.are.equal(1000, rows[3].duration_ms)
    end)

    it("maps statuses to labels and uses vim.uv.now() when now is omitted", function()
        Tasks.upsert({ id = "s", command = "", status = "stopped", start_time = 0 })
        Tasks.upsert({ id = "f", command = "", status = "failed", start_time = 0, end_time = 10 })

        -- Terminal rows sort by end_time descending: failed (10) before stopped (2).
        local before = vim.uv.now()
        local rows = Tasks.build_rows()
        assert.is_true(rows[1].duration_ms <= before, "omitted now must come from vim.uv.now()")
        assert.are.equal("failed", rows[1].status_label)
        assert.are.equal("stopped", rows[2].status_label)
    end)

    it("clamps negative durations to zero", function()
        Tasks.upsert({ id = "weird", command = "", status = "completed", start_time = 500, end_time = 100 })
        local rows = Tasks.build_rows(1000)
        assert.are.equal(0, rows[1].duration_ms)
    end)

    it("does not mutate task state", function()
        Tasks.upsert({ id = "r", command = "", status = "running", start_time = 1000 })
        Tasks.build_rows(5000)
        assert.is_nil(Tasks.get("r").end_time)
        assert.are.equal("running", Tasks.get("r").status)
    end)
end)

describe("pi.tasks mark_stopped", function()
    before_each(function()
        Tasks._reset()
    end)

    it("stops a running task and stamps end_time", function()
        Tasks.upsert({ id = "a", command = "", status = "running", start_time = 1000 })
        assert.is_true(Tasks.mark_stopped("a", 1800))
        local t = Tasks.get("a")
        assert.are.equal("stopped", t.status)
        assert.are.equal(1800, t.end_time)
        assert.is_true(Tasks.refresh_due())
    end)

    it("falls back to vim.uv.now() for end_time", function()
        Tasks.upsert({ id = "a", command = "", status = "running", start_time = 0 })
        local before = vim.uv.now()
        assert.is_true(Tasks.mark_stopped("a"))
        assert.is_true(Tasks.get("a").end_time >= before)
    end)

    it("returns false for unknown ids and non-running tasks", function()
        assert.is_false(Tasks.mark_stopped("ghost"))

        Tasks.upsert({ id = "done", command = "", status = "completed", start_time = 1, end_time = 2 })
        assert.is_false(Tasks.mark_stopped("done"))
        assert.are.equal("completed", Tasks.get("done").status)

        Tasks.upsert({ id = "already", command = "", status = "stopped", start_time = 1, end_time = 2 })
        assert.is_false(Tasks.mark_stopped("already"))

        assert.is_false(Tasks.refresh_due(), "a no-op stop must not schedule a refresh")
    end)
end)

describe("pi.tasks refresh debounce", function()
    before_each(function()
        Tasks._reset()
    end)

    it("coalesces a burst of request_refresh calls into one callback run", function()
        local calls = 0
        Tasks.on_refresh(function()
            calls = calls + 1
        end)

        Tasks.request_refresh()
        Tasks.request_refresh()
        Tasks.request_refresh()
        assert.is_true(Tasks.refresh_due())

        assert.is_true(
            vim.wait(1000, function()
                return calls > 0
            end),
            "refresh callback never ran"
        )
        pump(20)
        assert.are.equal(1, calls, "the burst must collapse into a single run")
        assert.is_false(Tasks.refresh_due())
    end)

    it("schedules a new run after the previous one fired", function()
        local calls = 0
        Tasks.on_refresh(function()
            calls = calls + 1
        end)

        Tasks.request_refresh()
        assert.is_true(vim.wait(1000, function()
            return calls == 1
        end))
        assert.is_false(Tasks.refresh_due())

        Tasks.request_refresh()
        assert.is_true(Tasks.refresh_due())
        assert.is_true(vim.wait(1000, function()
            return calls == 2
        end))
    end)

    it("on_refresh returns a cancel function", function()
        local calls = 0
        local cancel = Tasks.on_refresh(function()
            calls = calls + 1
        end)
        cancel()

        Tasks.request_refresh()
        pump(50)
        assert.are.equal(0, calls, "a canceled listener must not run")
    end)
end)

describe("pi.tasks _reset", function()
    it("clears tasks, listeners, and pending state for test isolation", function()
        Tasks.upsert({ id = "a", command = "", status = "running", start_time = 1 })
        local calls = 0
        Tasks.on_refresh(function()
            calls = calls + 1
        end)
        Tasks.request_refresh()
        assert.is_true(Tasks.refresh_due())

        Tasks._reset()

        assert.are.equal(0, #Tasks.list())
        assert.is_nil(Tasks.get("a"))
        assert.is_false(Tasks.refresh_due())
        pump(50)
        assert.are.equal(0, calls, "listeners registered before _reset must not fire")
    end)
end)
