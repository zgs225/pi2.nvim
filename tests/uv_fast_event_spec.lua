-- Pattern contract for libuv timers (gotcha G26) — NOT a product spec.
--
-- Three traps live in every uv callback, and each one is silent when violated:
--   1. uv callbacks run in *fast-event* context, so most `vim.api`/`vim.fn`
--      calls throw `E5560: ... must not be called in a lua loop callback`;
--   2. `timer:start(timeout, repeat, cb)` with `repeat = 0` fires ONCE — a
--      periodic tick needs `repeat > 0`;
--   3. uv handles must be held by something long-lived (module local or class
--      field), and closed explicitly on teardown.
-- The product depends on all three (the 30ms coalescing flush in
-- `lua/pi/ui/chat/history.lua`, the deferred refresh in `lua/pi/cache/files.lua`,
-- the subagent reaper sweep timer in `lua/pi/subsessions/reaper.lua`).
--
-- Case 3 pins the *mitigation* side only. Asserting that an unscheduled editor
-- call raises E5560 would pin a property of the nvim/luv build (it is a
-- build-time check inside nvim) and would go red on a different vintage, so
-- this file asserts the shape that must hold everywhere instead: pure-Lua work
-- in the callback, editor work behind `vim.schedule`.
--
-- Case 4 from G26 — "a handle kept only by a local dies after GC" — is
-- deliberately absent: it is not reproducible on this build. luv keeps a
-- registry reference to each handle, so two full `collectgarbage("collect")`
-- cycles do not free a local-only timer and its callback keeps firing
-- (`vim.uv.walk` still lists it). A spec asserting the death would fail here,
-- and one asserting the survival would be vacuous. The fix (hold the handle)
-- is pinned by the reaper case at the bottom, which asserts the handle is
-- reachable through the module after a GC cycle and stays armed.

local Config = require("pi.config")
local Reaper = require("pi.subsessions.reaper")

--- Timer tick in milliseconds: fast enough for a handful of ticks in a test.
local TICK_MS = 10

--- Upper bound for every wait. CI runs ~168 spec files in parallel on 2 cores,
--- so a 100-500ms budget is a coin flip; wait on a condition with a wide cap.
local BUDGET_MS = 10000

--- Sweep interval used by the reaper case, in minutes (repeat = minutes * 60000).
local SWEEP_MINUTES = 5

--- Pump the event loop for `ms` without an early-exit condition.
---@param ms integer
local function pump(ms)
    vim.wait(ms, function()
        return false
    end)
end

describe("uv fast-event timers (G26)", function()
    --- Timers created by the current case, closed by after_each.
    ---@type uv.uv_timer_t[]
    local timers

    local saved_notify
    local saved_errmsg

    before_each(function()
        timers = {}
        saved_notify = vim.notify
        saved_errmsg = vim.v.errmsg
        vim.v.errmsg = ""
    end)

    after_each(function()
        for _, timer in ipairs(timers) do
            if not timer:is_closing() then
                timer:stop()
                timer:close()
            end
        end
        timers = {}
        vim.notify = saved_notify
        vim.v.errmsg = saved_errmsg
    end)

    --- Remember a timer so teardown can close it.
    ---@param timer uv.uv_timer_t
    ---@return uv.uv_timer_t
    local function track(timer)
        timers[#timers + 1] = timer
        return timer
    end

    --- Stop and close every tracked timer, then assert none is left open.
    ---@return nil
    local function close_all()
        for _, timer in ipairs(timers) do
            if not timer:is_closing() then
                timer:stop()
                timer:close()
            end
            assert.is_true(timer:is_closing(), "every timer must be closed")
        end
    end

    it("a repeating timer fires more than once", function()
        local fired = 0
        local timer = track(assert(vim.uv.new_timer()))
        timer:start(TICK_MS, TICK_MS, function()
            fired = fired + 1
        end)

        assert.is_true(
            vim.wait(BUDGET_MS, function()
                return fired >= 3
            end),
            "a timer started with repeat > 0 must fire repeatedly, fired " .. fired .. " time(s)"
        )

        timer:stop()
        timer:close()
        assert.is_true(timer:is_closing(), "the timer must be closed after the case")
        close_all()
    end)

    it("repeat = 0 is a one-shot", function()
        local fired = 0
        local timer = track(assert(vim.uv.new_timer()))
        timer:start(TICK_MS, 0, function()
            fired = fired + 1
        end)

        assert.is_true(
            vim.wait(BUDGET_MS, function()
                return fired >= 1
            end),
            "the one-shot timer must fire at least once"
        )

        pump(200)
        assert.are.equal(1, fired, "repeat = 0 must fire exactly once, never re-arm")

        timer:stop()
        timer:close()
        close_all()
    end)

    it("editor work is scheduled out of the callback instead of run inside it", function()
        local notified = {}
        vim.notify = function(msg, ...)
            notified[#notified + 1] = tostring(msg)
            return saved_notify(msg, ...)
        end

        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "read from the scheduled callback" })

        local ticks = 0
        local read_back
        local timer = track(assert(vim.uv.new_timer()))
        timer:start(TICK_MS, 0, function()
            -- Fast-event context: pure-Lua bookkeeping is legal here, editor
            -- work is not — it must be handed to the main loop.
            ticks = ticks + 1
            vim.schedule(function()
                read_back = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            end)
        end)

        assert.is_true(
            vim.wait(BUDGET_MS, function()
                return read_back ~= nil
            end),
            "the scheduled callback must run and read the buffer"
        )
        assert.are.same({ "read from the scheduled callback" }, read_back)
        assert.are.equal(1, ticks, "the one-shot callback must run once")

        timer:stop()
        timer:close()
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        close_all()

        assert.are.same({}, notified, "a scheduled callback must not surface an error notification")
        assert.are.equal("", vim.v.errmsg, "no error must be left behind by the scheduled reread")
    end)
end)

describe("subagent reaper sweep timer is a held, repeating timer", function()
    local saved_notify
    local saved_subagent
    local created

    before_each(function()
        Config.setup({})
        saved_subagent = Config.options.subagent
        -- G31: never write into the nested options table in place (it aliases
        -- the module-local defaults); replace it with a deepcopy.
        Config.options.subagent =
            vim.tbl_deep_extend("force", vim.deepcopy(saved_subagent or {}), { reap_sweep_minutes = SWEEP_MINUTES })
        Reaper._reset()
        saved_notify = vim.notify
        created = {}
    end)

    after_each(function()
        Reaper._reset()
        Config.options.subagent = saved_subagent
        vim.notify = saved_notify
        for _, timer in ipairs(created) do
            if not timer:is_closing() then
                timer:stop()
                timer:close()
            end
        end
        created = {}
    end)

    --- Snapshot every live uv timer handle, keyed by its Lua identity.
    ---@return table<string, uv.uv_timer_t>
    local function timer_snapshot()
        local seen = {}
        vim.uv.walk(function(handle)
            local is_timer = pcall(function()
                return handle:get_repeat()
            end)
            if is_timer then
                seen[tostring(handle)] = handle
            end
        end)
        return seen
    end

    it("start() arms one repeating timer, keeps it across GC, and stop() closes it", function()
        local before = timer_snapshot()

        local ok_start, err_start = pcall(Reaper.start)
        assert.is_true(ok_start, "reaper start() must not raise: " .. tostring(err_start))
        assert.is_true(Reaper._sweep_running(), "start() must record the timer in the module-local handle")

        local sweep
        for key, handle in pairs(timer_snapshot()) do
            if not before[key] then
                sweep = handle
                created[#created + 1] = handle
            end
        end
        assert.is_not_nil(sweep, "start() must create a uv timer")
        assert.are.equal(
            SWEEP_MINUTES * 60 * 1000,
            sweep:get_repeat(),
            "the interval must be passed as `repeat` — repeat = 0 would make the periodic sweep a one-shot"
        )
        assert.is_true(sweep:is_active(), "the sweep timer must be armed")

        -- The handle lives at module scope: a GC cycle must not disarm it (the
        -- opposite of losing it to a callback-local that went out of scope).
        collectgarbage("collect")
        collectgarbage("collect")
        pump(50)
        assert.is_true(Reaper._sweep_running(), "the module must still hold the sweep timer after GC")
        assert.is_true(sweep:is_active(), "the sweep timer must stay armed after GC")

        Reaper.stop()
        assert.is_false(Reaper._sweep_running(), "stop() must drop the handle")
    end)
end)
