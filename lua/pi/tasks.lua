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
---@field status "running"|"completed"|"failed"|"stopped"|"unknown"
---@field start_time integer   ms timestamp (from the event payload)
---@field end_time integer|nil ms timestamp
---@field exit_code integer|nil
---@field signal string|nil
---@field output_file string|nil
---@field pid integer|nil
---@field session_id string?  owning session id (passed in at event routing; nil = unknown ownership)
---@field tab integer?        owning tabpage handle (passed in at event routing; panel display)
---@field held_reason string? why the paid turn for this task's report is held
---                          for the next user turn (see the bg-tasks
---                          extension's completion-wake gate); nil once delivered
---@field log_removed? boolean true once the panel deleted this task's log

---@class pi.TasksRow
---@field task pi.Task
---@field status_label "running"|"done"|"failed"|"stopped"|"unknown"
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

local uv = vim.uv or vim.loop

--- Grace window before a local stop escalates SIGTERM to SIGKILL. Matches the
--- extension's `stop_task` default, so the panel and the model behave the same.
local DEFAULT_ESCALATE_MS = 5000

---@type integer
local escalate_ms = DEFAULT_ESCALATE_MS

--- Pending SIGKILL escalations, by task id. Presence means "SIGTERM was sent
--- and the backend has not reported a terminal state yet" — which is why a row
--- that already reads `stopped` (marked optimistically by M.stop) still
--- escalates: the authoritative `pi2_bg_task` event is what cancels this.
---@type table<string, uv.uv_timer_t>
local escalations = {}

--- Cancel a pending escalation for one task. Safe for unknown ids.
---@param id string
local function cancel_escalation(id)
    local timer = escalations[id]
    if not timer then
        return
    end
    escalations[id] = nil
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
end

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
    escalate_ms = DEFAULT_ESCALATE_MS
    focused = true
    published_cfg = nil
    if presence_group then
        pcall(vim.api.nvim_del_augroup_by_id, presence_group)
        presence_group = nil
    end
    for id in pairs(escalations) do
        cancel_escalation(id)
    end
end

--- Override the SIGTERM→SIGKILL grace window. Test-only: specs must not wait
--- the real five seconds. Passing nil (or an invalid value) restores the
--- default; _reset() restores it too.
---@param ms integer|nil
function M._set_escalate_ms(ms)
    escalate_ms = type(ms) == "number" and ms >= 1 and math.floor(ms) or DEFAULT_ESCALATE_MS
end

-- Idle-wake policy plumbing ---------------------------------------------------
--
-- The bundled bg-tasks extension owns the wake decision (it is the process that
-- can start a turn), but the policy belongs to the user's config, which lives
-- here. The two are in different processes, so the policy travels through a
-- runtime file — the same pattern as title.lua and todo/tool_ui.lua, and for the
-- same reason: the child process env is frozen at spawn, so a live setup() call
-- must reach an already-running backend without a respawn.

---@type string?
local state_path_override = nil

--- Last config published, so a focus change can republish `present` alone.
---@type pi.BackgroundTasksConfig?
local published_cfg = nil

--- Whether a human is at the editor right now: `nvim_list_uis()` is empty for
--- headless and `--embed` instances, where nobody can be looking at a wake.
---@type boolean
local focused = true

---@type integer?
local presence_group = nil

-- Mirror the extension's clamping (extensions/bg-tasks.ts) so a published value
-- means exactly what the backend will do with it.
local DEFAULT_WAKE_POLICY = "never"
local DEFAULT_WAKE_BUDGET = 2
local MAX_WAKE_BUDGET = 10
local DEFAULT_WAKE_CACHE_WINDOW_MS = 300000
local MAX_WAKE_CACHE_WINDOW_MS = 86400000

--- Runtime file conveying the configured completion-wake policy to
--- already-spawned RPC processes, as JSON:
--- `{wake_on_completion:string, wake_budget:number, wake_cache_window_ms:number, present:boolean}`.
--- The PID is part of the name because stdpath("run") is per-user, not
--- per-process: without it two concurrently running nvim instances would clobber
--- each other's policy.
---@return string
function M.state_path()
    if state_path_override then
        return state_path_override
    end
    return vim.fn.stdpath("run") .. "/pi2nvim-bg-tasks-config-" .. tostring(vim.fn.getpid())
end

--- Override the state file path (tests).
---@param path string?
function M._set_path(path)
    state_path_override = path
end

---@param value any
---@param default integer
---@param max integer
---@return integer
local function clamp_int(value, default, max)
    if type(value) ~= "number" or value ~= value then
        return default
    end
    return math.max(0, math.min(max, math.floor(value)))
end

--- Whether a human is at the editor right now.
---@return boolean
function M.present()
    local ok, uis = pcall(vim.api.nvim_list_uis)
    if not ok or type(uis) ~= "table" or #uis == 0 then
        return false
    end
    return focused
end

--- Watch focus once per process. The extension only ever sees the resulting
--- `present` flag; a lost wake costs a whole turn, so an unfocused editor is
--- enough to hold it for the next prompt.
local function watch_presence()
    if presence_group then
        return
    end
    local ok, group = pcall(vim.api.nvim_create_augroup, "PiTasksPresence", { clear = true })
    if not ok then
        return
    end
    ---@param value boolean
    ---@return fun()
    local function set(value)
        return function()
            focused = value
            M.publish()
        end
    end
    local gained = pcall(vim.api.nvim_create_autocmd, "FocusGained", { group = group, callback = set(true) })
    local lost = pcall(vim.api.nvim_create_autocmd, "FocusLost", { group = group, callback = set(false) })
    if gained and lost then
        presence_group = group
    else
        pcall(vim.api.nvim_del_augroup_by_id, group)
    end
end

--- Publish the completion-wake policy for the extension. Always writes the file,
--- so a live setup() change (or an explicit `wake_on_completion = "never"`)
--- reaches a backend that was spawned earlier.
---@param cfg pi.BackgroundTasksConfig?
function M.publish(cfg)
    if cfg ~= nil then
        published_cfg = cfg
    end
    watch_presence()
    local c = published_cfg or {}
    ---@diagnostic disable-next-line: undefined-field -- deprecated alias, kept for one update
    local policy = c.wake_on_completion or c.wake_on_idle
    if policy ~= "always" and policy ~= "failure" and policy ~= "never" then
        policy = DEFAULT_WAKE_POLICY
    end
    local ok, payload = pcall(vim.json.encode, {
        wake_on_completion = policy,
        wake_budget = clamp_int(c.wake_budget, DEFAULT_WAKE_BUDGET, MAX_WAKE_BUDGET),
        wake_cache_window_ms = clamp_int(
            c.wake_cache_window_ms,
            DEFAULT_WAKE_CACHE_WINDOW_MS,
            MAX_WAKE_CACHE_WINDOW_MS
        ),
        present = M.present(),
    })
    if not ok then
        return
    end
    local f = io.open(M.state_path(), "w")
    if f then
        f:write(payload)
        f:close()
    end
end

--- The published policy, if the file exists and decodes (what the extension
--- sees). Useful to the panel and to specs; never required for behavior.
---@return table?
function M.published()
    local f = io.open(M.state_path(), "r")
    if not f then
        return nil
    end
    local content = f:read("*a") or ""
    f:close()
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    return decoded
end

--- Insert a task, or replace the existing record with the same id wholesale.
---@param t pi.Task
function M.upsert(t)
    if t.status ~= "running" then
        -- A finished record cannot have a stop in flight.
        cancel_escalation(t.id)
    end
    store[t.id] = t
end

---@param id string
---@return pi.Task|nil
function M.get(id)
    return store[id]
end

--- True while any task owned by `session_id` is still running. Drives the
--- panel auto-close: the moment the last running task of a session reaches
--- a terminal state the session is idle.
---@param session_id string?
---@return boolean
function M.has_running(session_id)
    for _, t in pairs(store) do
        if t.status == "running" and t.session_id == session_id then
            return true
        end
    end
    return false
end

--- All tasks sorted for the panel: running first (start_time ascending),
--- then everything else by end_time descending (newest first). Terminal
--- tasks without an end_time sort last. With a session_id, only tasks owned
--- by that session are returned (nil/omitted = all sessions).
---@param session_id string?
---@return pi.Task[]
function M.list(session_id)
    ---@type pi.Task[]
    local tasks = {}
    for _, t in pairs(store) do
        if session_id == nil or t.session_id == session_id then
            tasks[#tasks + 1] = t
        end
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

---@type table<string, "running"|"done"|"failed"|"stopped"|"unknown">
local STATUS_LABELS = {
    running = "running",
    completed = "done",
    failed = "failed",
    stopped = "stopped",
    unknown = "unknown",
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

--- Drop a JSON null (`vim.NIL`, which is truthy in Lua) down to nil so an
--- `x or fallback` / `if x == nil` test behaves as intended; other values
--- pass through untouched.
---@param value any
---@return any
local function non_null(value)
    if value == vim.NIL then
        return nil
    end
    return value
end

--- Adopt the payload's output path when the record has none yet. A JSON
--- null decodes to the truthy vim.NIL, which must not be stored as a path.
---@param current string|nil
---@param value any
---@return string|nil
local function merge_output_file(current, value)
    if current ~= nil then
        return current
    end
    if value == nil or value == vim.NIL then
        return nil
    end
    return value
end

--- Idempotently fill the fields a terminal payload carries onto an existing
--- record: only nil fields are adopted, so an earlier event (or a local stop
--- via mark_stopped) is never clobbered. JSON nulls are normalized away.
---@param task pi.Task
---@param d table
---@return boolean changed whether any field was newly adopted
local function merge_terminal_fields(task, d)
    local changed = false
    local output_file = merge_output_file(task.output_file, d.outputFile)
    if output_file ~= task.output_file then
        task.output_file = output_file
        changed = true
    end
    if task.pid == nil then
        local pid = non_null(d.pid)
        if pid ~= nil then
            task.pid = pid
            changed = true
        end
    end
    if task.signal == nil then
        local signal = non_null(d.signal)
        if signal ~= nil then
            task.signal = signal
            changed = true
        end
    end
    return changed
end

--- Consume a pi2_bg_task event. Recognized events update the registry and
--- return true; anything else returns false with no side effects. Ownership
--- (session_id/tab) is stamped onto NEW records only (started, and the
--- synthesized record for a terminal event on an unknown task); terminal
--- and stopped events for an existing task never rewrite its owner.
--- Payload shapes (extension JS contract, in ev.details):
---   {kind="started",   taskId, command, pid?, outputFile?}
---   {kind="completed", taskId, command?, pid?, outputFile?, exitCode?, signal?}
---   {kind="failed",    taskId, command?, pid?, outputFile?, exitCode?, signal?}
---   {kind="stopped",   taskId, command?, pid?, outputFile?, exitCode?, signal?}
---   {kind="unknown",   taskId, command?, pid?, outputFile?, exitCode?, signal?}
---
--- An `unknown` terminal event carries NO exit code: the exit nobody observed
--- is genuinely unknowable, so the record keeps exit_code nil rather than
--- borrowing `failed`'s default of 1.
---@param ev table
---@param session_id string? Owning session id (event routing; nil = unknown ownership)
---@param tab integer? Owning tabpage handle (panel display)
---@return boolean
function M.handle_event(ev, session_id, tab)
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
    -- A held report is announced by a repeat panel message, not by a state
    -- change: the task is terminal and only its report is waiting for the user.
    -- Handled before the kind switches so a replayed terminal event cannot
    -- re-stamp end_time just to carry the reason.
    local held = non_null(d.held)
    if type(held) == "string" and held ~= "" then
        local waiting = store[id]
        if waiting then
            waiting.held_reason = held
            M.request_refresh()
        end
        return true
    end
    local ts = normalize_ts(ev.timestamp)
    -- An adopted task (one a previous pi process started, reported again on
    -- session start) would otherwise be timestamped at the moment the message
    -- was sent, so the panel's clock would restart at zero for a process that
    -- has been running for minutes. The payload's own `startedAt` wins.
    local started = non_null(d.startedAt)
    local start_ts = type(started) == "number" and started > 0 and normalize_ts(started) or ts

    if d.kind == "started" then
        -- A fresh start for an id with a stop in flight replaces the record.
        cancel_escalation(id)
        ---@type pi.Task
        local task = {
            id = id,
            command = non_null(d.command) or "",
            status = "running",
            start_time = start_ts,
            pid = non_null(d.pid),
            output_file = merge_output_file(nil, d.outputFile),
            session_id = session_id,
            tab = tab,
        }
        store[id] = task
        M.request_refresh()
        return true
    end

    if d.kind == "completed" or d.kind == "failed" or d.kind == "unknown" then
        -- A JSON null decodes to vim.NIL, which is truthy: a bare
        -- `d.exitCode or fallback` would keep the NIL instead of falling back.
        local exit_code = non_null(d.exitCode)
        ---@type pi.Task
        local task = store[id]
        if not task then
            -- Terminal event for a task we never saw start: synthesize a
            -- minimal record so the panel reflects reality.
            task = {
                id = id,
                command = non_null(d.command) or "",
                status = "running",
                start_time = start_ts,
                session_id = session_id,
                tab = tab,
            }
            store[id] = task
        end
        -- Merge outside any status guard: a locally-stopped task still gets the
        -- payload's output path/pid/signal.
        merge_terminal_fields(task, d)
        task.status = d.kind
        task.end_time = ts
        -- Only the kinds that actually observed an exit may fabricate a code:
        -- `completed` without one defaulted to 0 and `failed` to 1, but an
        -- `unknown` event means nobody saw the exit — defaulting it would
        -- spell "failed" for a task whose exit status is simply unknowable.
        if d.kind == "completed" then
            task.exit_code = exit_code or 0
        elseif d.kind == "failed" then
            task.exit_code = exit_code or 1
        end
        -- The authoritative terminal state: a stop that was still escalating
        -- has succeeded (or was never needed).
        cancel_escalation(id)
        M.request_refresh()
        return true
    end

    if d.kind == "stopped" then
        -- The `x` panel key marks a task stopped locally before the backend's
        -- stopped event arrives, so the field merge must run for an already
        -- stopped (or any existing) record too — the status guard below must
        -- not gate it. A local stop keeps its mark_stopped end_time.
        ---@type pi.Task
        local task = store[id]
        if not task then
            return true
        end
        local changed = merge_terminal_fields(task, d)
        -- The transition (and only the transition) stamps exit_code/end_time:
        -- a repeat stopped event is idempotent and must not add either.
        if task.status == "running" then
            task.status = "stopped"
            task.end_time = ts
            task.exit_code = non_null(d.exitCode)
            changed = true
        end
        if changed then
            M.request_refresh()
        end
        cancel_escalation(id)
        return true
    end

    return false
end

--- Fold one transcript `pi2_bg_task` record into the registry. Accepts either
--- wire shape a transcript keeps it in:
---   * `msg.details` — an RPC `get_messages` message (role="custom");
---   * `msg.data` — a JSONL `type="custom"` entry's payload.
---
--- One fold shared by the parent's transcript replay (sessions/manager.lua)
--- and the sub-session viewer, so the two tables cannot disagree about a
--- task's command or state. A record is not conversation content: it renders
--- nothing, but it is the only place a task's command is written down, and a
--- tool block replayed later (`wait_task` / `stop_task` / `task_input`) names
--- the command from this registry — without the fold it falls back to a bare
--- task id.
---
--- A `started` record for a task the registry already tracks is inert: replay
--- runs more than once per view (a compaction rebuild, :PiTree, a reopened
--- viewer), and a rebuilt window can hold a task's `started` entry without the
--- terminal one — folding that again would turn a finished row back into a
--- running one (spinner and all). Terminal records are always folded: they
--- carry the exit status and are idempotent.
---@param msg table? transcript entry carrying a pi2_bg_task payload
---@param session_id string? owning session id (nil = unknown ownership)
---@param tab integer? owning tabpage handle (panel display)
---@return boolean consumed true when the record was folded
function M.absorb_message(msg, session_id, tab)
    if type(msg) ~= "table" then
        return false
    end
    local custom_type = msg.customType
    if custom_type ~= nil and custom_type ~= "pi2_bg_task" then
        return false
    end
    local details = msg.details
    if type(details) ~= "table" then
        details = msg.data
    end
    if type(details) ~= "table" then
        return false
    end
    if details.kind == "started" then
        local id = details.taskId
        if type(id) == "string" and store[id] ~= nil then
            return true
        end
    end
    return M.handle_event({ type = "pi2_bg_task", details = details, timestamp = msg.timestamp }, session_id, tab)
end

--- Drop every task owned by the given session (tab closed / session
--- destroyed, so its rows don't linger as zombies). Returns the number of
--- removed records; schedules a panel refresh only when something was
--- actually removed. Tasks with unknown ownership (session_id nil) survive.
---@param session_id string
---@return integer
function M.remove_session(session_id)
    local removed = 0
    for id, t in pairs(store) do
        if t.session_id == session_id then
            store[id] = nil
            cancel_escalation(id)
            removed = removed + 1
        end
    end
    if removed > 0 then
        M.request_refresh()
    end
    return removed
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

--- Signal a background task's process GROUP.
---
--- The extension spawns every task `detached: true`, so the child is its own
--- process-group leader (pgid == pid) and its children live in that group:
--- `node` under `npm run dev`, the compiler under `make`, every stage of a
--- pipeline. Signalling the bare pid stops only the shell — the children are
--- orphaned, keep the port bound, and the row reads "stopped" while the work
--- goes on. The group is the unit that was started, so it is the unit that is
--- stopped.
---
--- Falls back to the bare pid when the group is gone (a task started by a pi
--- process that already exited, or a record replayed from a session file).
---@param pid integer|nil
---@param signum? integer|string Signal number or name. Defaults to "sigterm".
---@return boolean signalled
function M.kill_group(pid, signum)
    -- A nil/0/1 pid would address no task: pid 0 is OUR process group, so a
    -- negative-program-id kill there would signal this Neovim.
    if type(pid) ~= "number" or pid <= 1 then
        return false
    end
    -- A JSON-decoded pid is an integer, but a replayed record can carry a
    -- float; luv wants an integer pid.
    local target = math.floor(pid)
    local uv = vim.uv or vim.loop
    signum = signum or "sigterm"
    local ok, res = pcall(uv.kill, -target, signum)
    if ok and res == 0 then
        return true
    end
    ok, res = pcall(uv.kill, target, signum)
    return ok and res == 0
end

--- Arm the SIGKILL escalation for a task whose SIGTERM has just been sent.
---
--- The timer is registered in `escalations` before it starts, and its own
--- firing re-checks that registration: a terminal `pi2_bg_task` event (or a
--- reset, or the tab closing) removes the entry, so a task the backend already
--- settled is never killed behind its back. Closing the handle from inside the
--- callback is the canonical luv timer teardown.
---
--- The residual exposure is the one every "SIGKILL after a grace window" has:
--- the backend's event is what proves the process is gone, so an event that is
--- lost (the pi process died without reporting) could address a pid the OS has
--- since recycled. The window is one grace period and the registration lives
--- only while the row is still unconfirmed; the model's `stop_task` has the
--- same shape, with the child handle's liveness as its extra guard.
---@param id string
---@param pid integer
local function schedule_escalation(id, pid)
    cancel_escalation(id)
    local timer = uv.new_timer()
    if not timer then
        return
    end
    escalations[id] = timer
    timer:start(escalate_ms, 0, function()
        pcall(timer.stop, timer)
        if escalations[id] == timer then
            escalations[id] = nil
            local task = store[id]
            M.kill_group(task and task.pid or pid, "sigkill")
        end
        pcall(timer.close, timer)
    end)
end

--- Stop a running task (the panel's `x`): SIGTERM its process group, then mark
--- it stopped locally so the row reacts immediately, then arm a SIGKILL for the
--- case where the process traps or ignores SIGTERM — a row that reads
--- `stopped` must not stand for a process that is still running. The
--- authoritative terminal state still arrives from the extension's
--- `pi2_bg_task` event, which carries the real exit signal and disarms the
--- escalation.
--- Returns false (no side effects) for unknown ids or non-running tasks.
---@param id string
---@param now_ms? integer Defaults to vim.uv.now().
---@return boolean stopped
function M.stop(id, now_ms)
    local task = store[id]
    if not task or task.status ~= "running" then
        return false
    end
    local signalled = M.kill_group(task.pid)
    M.mark_stopped(id, now_ms)
    -- Only arm when a signal actually landed: nothing to escalate otherwise
    -- (the process is already gone, so its terminal event is on its way).
    if signalled and type(task.pid) == "number" and task.pid > 1 then
        schedule_escalation(id, task.pid)
    end
    return true
end

--- Delete a finished task's log file from disk.
---
--- The extension keeps a finished task's log until its TTL sweep (7 days by
--- default), because `wait_task` / a panel row may still point at it — but a
--- 300 MB build log the user is done with should not have to wait for that.
--- Running tasks are refused: the writer still holds the file, and the row's
--- preview follows it.
---@param id string
---@return boolean ok
---@return string? err
function M.delete_log(id)
    local task = store[id]
    if not task then
        return false, "unknown task"
    end
    if task.status == "running" then
        return false, "still running"
    end
    local path = task.output_file
    if type(path) ~= "string" or path == "" then
        return false, "no output file"
    end
    -- Synchronous form: no callback means luv blocks and returns the result.
    local ok, err = uv.fs_unlink(path)
    if not ok then
        -- ENOENT is the caller's desired end state: an already-collected file
        -- (a TTL sweep, a manual rm, a previous delete) is not a failure.
        if not tostring(err):find("ENOENT", 1, true) then
            return false, tostring(err)
        end
    end
    task.log_removed = true
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
