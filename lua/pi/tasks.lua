--- Background task state for the pi2_bg_task extension events.
---
--- The pi extension runs background bash processes and pushes pi2_bg_task
--- events over RPC; the session event pipeline forwards them here. This
--- module is the pure logic layer: it owns the task registry, transitions
--- state, and coalesces refresh notifications for the panel UI
--- (lua/pi/ui/tasks.lua registers a redraw callback via on_refresh()).
--- No windows, buffers, or vim.notify here.

local M = {}

---@class pi.Task
---@field id string            e.g. "b3f2a1"
---@field command string       full command line
---@field status "running"|"completed"|"failed"|"stopped"
---@field start_time integer   ms timestamp (from the event payload)
---@field end_time integer|nil ms timestamp
---@field exit_code integer|nil
---@field output_file string|nil
---@field pid integer|nil

---@class pi.TasksRow
---@field task pi.Task
---@field status_label "running"|"done"|"failed"|"stopped"
---@field duration_ms integer|nil running = now-start_time; done = end-start

---@type table<string, pi.Task>
local store = {}

---@type fun()[]
local listeners = {}

---@type boolean
local refresh_scheduled = false

--- Bumped by _reset(): a refresh callback queued before the reset must not
--- fire afterwards, so specs cannot leak scheduled work into each other.
---@type integer
local generation = 0

---@return integer
local function current_ms()
    return vim.uv.now()
end

--- Convert an event timestamp to the uv clock. Core stamps custom messages
--- with Date.now() (Unix epoch ms, ~1.7e12) while uv.now() is the small
--- event-loop clock; mixing the two makes age math go negative and clamp to
--- zero (finished rows would show a frozen "0s ago"). Epoch stamps are
--- rebased onto the uv clock at receipt, preserving the delta from now.
---@param ts any
---@return integer
local function normalize_ts(ts)
    if type(ts) ~= "number" or ts <= 0 then
        return current_ms()
    end
    if ts > 1e12 then
        return current_ms() - math.max(0, math.floor(os.time() * 1000 - ts))
    end
    return ts
end

--- Clear all module state. Test-only: also drops registered refresh
--- listeners so specs cannot leak callbacks into each other.
function M._reset()
    store = {}
    listeners = {}
    refresh_scheduled = false
    generation = generation + 1
end

--- Insert a task, or replace the existing record with the same id wholesale.
---@param t pi.Task
function M.upsert(t)
    store[t.id] = t
end

---@param id string
---@return pi.Task|nil
function M.get(id)
    return store[id]
end

--- All tasks sorted for the panel: running first (start_time ascending),
--- then everything else by end_time descending (newest first). Terminal
--- tasks without an end_time sort last.
---@return pi.Task[]
function M.list()
    ---@type pi.Task[]
    local tasks = {}
    for _, t in pairs(store) do
        tasks[#tasks + 1] = t
    end
    table.sort(tasks, function(a, b)
        local a_running = a.status == "running" and 0 or 1
        local b_running = b.status == "running" and 0 or 1
        if a_running ~= b_running then
            return a_running < b_running
        end
        if a_running == 0 then
            return (a.start_time or 0) < (b.start_time or 0)
        end
        local a_end = a.end_time or -1
        local b_end = b.end_time or -1
        if a_end ~= b_end then
            return a_end > b_end
        end
        return (a.id or "") < (b.id or "")
    end)
    return tasks
end

---@type table<string, "running"|"done"|"failed"|"stopped">
local STATUS_LABELS = {
    running = "running",
    completed = "done",
    failed = "failed",
    stopped = "stopped",
}

--- Build the panel rows: one per task in list() order, with a display label
--- and duration. Running durations are measured against now_ms; a terminal
--- task without end_time degrades to now-start. Pure: never mutates state.
---@param now_ms? integer Defaults to vim.uv.now().
---@return pi.TasksRow[]
function M.build_rows(now_ms)
    now_ms = now_ms or current_ms()
    ---@type pi.TasksRow[]
    local rows = {}
    for _, t in ipairs(M.list()) do
        local duration
        if t.start_time then
            local stop = t.end_time or now_ms
            duration = math.max(0, stop - t.start_time)
        end
        rows[#rows + 1] = {
            task = t,
            status_label = STATUS_LABELS[t.status] or "stopped",
            duration_ms = duration,
        }
    end
    return rows
end

--- Consume a pi2_bg_task event. Recognized events update the registry and
--- return true; anything else returns false with no side effects.
--- Payload shapes (extension JS contract, in ev.details):
---   {kind="started",  taskId, command, pid?, outputFile?}
---   {kind="completed", taskId, exitCode?}
---   {kind="failed",   taskId, exitCode?}
---   {kind="stopped",  taskId, exitCode?}
---@param ev table
---@return boolean
function M.handle_event(ev)
    if type(ev) ~= "table" or ev.type ~= "pi2_bg_task" then
        return false
    end
    local d = ev.details
    if type(d) ~= "table" then
        return false
    end
    local id = d.taskId
    if type(id) ~= "string" or id == "" then
        return false
    end
    local ts = normalize_ts(ev.timestamp)

    if d.kind == "started" then
        ---@type pi.Task
        local task = {
            id = id,
            command = d.command or "",
            status = "running",
            start_time = ts,
            pid = d.pid,
            output_file = d.outputFile,
        }
        store[id] = task
        M.request_refresh()
        return true
    end

    if d.kind == "completed" or d.kind == "failed" then
        local task = store[id]
        if not task then
            -- Terminal event for a task we never saw start: synthesize a
            -- minimal record so the panel reflects reality.
            ---@type pi.Task
            task = {
                id = id,
                command = d.command or "",
                status = "running",
                start_time = ts,
            }
            store[id] = task
        end
        task.status = d.kind
        task.end_time = ts
        task.exit_code = d.exitCode or (d.kind == "completed" and 0 or 1)
        M.request_refresh()
        return true
    end

    if d.kind == "stopped" then
        -- Idempotent: only a currently-running task transitions. A repeat
        -- stopped event (or one for an unknown/already-finished task) is
        -- recognized but changes nothing.
        local task = store[id]
        if task and task.status == "running" then
            task.status = "stopped"
            task.end_time = ts
            task.exit_code = d.exitCode
            M.request_refresh()
        end
        return true
    end

    return false
end

--- Local stop from the panel (x key): transitions a running task to stopped.
--- Returns false (no side effects) for unknown ids or non-running tasks.
---@param id string
---@param now_ms? integer Defaults to vim.uv.now().
---@return boolean
function M.mark_stopped(id, now_ms)
    local task = store[id]
    if not task or task.status ~= "running" then
        return false
    end
    task.status = "stopped"
    task.end_time = now_ms or current_ms()
    M.request_refresh()
    return true
end

--- Debounced refresh: any burst of state transitions collapses into a single
--- scheduled notification to the registered listeners.
function M.request_refresh()
    if refresh_scheduled then
        return
    end
    refresh_scheduled = true
    local gen = generation
    vim.schedule(function()
        if gen ~= generation then
            return
        end
        refresh_scheduled = false
        for _, fn in ipairs(listeners) do
            fn()
        end
    end)
end

--- Register a refresh callback (the panel registers its redraw here).
---@param fn fun()
---@return fun() cancel Unregisters the callback when called.
function M.on_refresh(fn)
    listeners[#listeners + 1] = fn
    return function()
        for i, other in ipairs(listeners) do
            if other == fn then
                table.remove(listeners, i)
                return
            end
        end
    end
end

--- Whether a refresh notification is pending (test assertions).
---@return boolean
function M.refresh_due()
    return refresh_scheduled
end

return M
