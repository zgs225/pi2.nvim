-- Headless e2e: subagent idle reaper (reap_after_minutes) + max_children live-process cap.
--
-- Unlike tests/*_e2e.lua (mocked RPC), this drives REAL processes end to end:
-- real `pi --mode rpc` children, a real provider/LLM settle, real uv timers
-- (Reaper.schedule / Reaper.sweep) and the real jobstop kill chain.
--
--   S1  spawn -> settle -> assert resident -> reaper fires -> assert dead/dormant/JSONL
--       retained -> revive -> assert new process + old history readable -> close.
--   S2  reaping disabled, max_children=1: settled child stays resident and holds
--       its slot; a second spawn fails with "max 1 ..."; closing frees the slot.
--
-- Needs the pi binary + a configured provider, so it is NOT part of `make test`
-- or CI. Run from the repo root:
--   make e2e-reaper
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/reaper.lua)

local uv = vim.uv

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Reaper = require("pi.subsessions.reaper")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")

local TASK = "Reply with exactly: DONE"
local CHILD_NAME = "e2e-reaper"

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

---@param path string?
---@return string?
local function read_file(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

---@param id string
---@return string? status
local function manifest_status(id)
    local entry = Manifest.load()[id]
    return entry ~= nil and type(entry) == "table" and entry.status or nil
end

--- OS pid behind an Rpc's nvim job (nil when the job is gone).
---@param rpc table?
---@return integer? pid
local function rpc_pid(rpc)
    local job = rpc and rpc._job_id
    if type(job) ~= "number" then
        return nil
    end
    local ok, pid = pcall(vim.fn.jobpid, job)
    if not ok or type(pid) ~= "number" or pid <= 1 then
        return nil
    end
    return pid
end

--- POSIX liveness probe independent of nvim's job table.
---@param pid integer?
---@return boolean
local function os_alive(pid)
    if type(pid) ~= "number" or pid <= 1 then
        return false
    end
    vim.fn.system({ "kill", "-0", tostring(pid) })
    return vim.v.shell_error == 0
end

---@param pid integer
---@param timeout_ms integer
---@return boolean dead
local function wait_os_dead(pid, timeout_ms)
    return vim.wait(timeout_ms, function()
        return not os_alive(pid)
    end, 200)
end

---@param report table { ids: string[], pids: integer[], path_set: table<string, boolean> }
local function record_child(report, child)
    report.ids[#report.ids + 1] = child.id
    local pid = rpc_pid(child.rpc)
    if pid then
        report.pids[#report.pids + 1] = pid
    end
    if type(child.session_file) == "string" and child.session_file ~= "" then
        report.path_set[child.session_file] = true
    end
    return pid
end

--- G31: never mutate options.subagent in place — replace it with a modified deepcopy.
---@param overrides table
local function apply_subagent_cfg(overrides)
    Config.options.subagent = vim.tbl_deep_extend("force", vim.deepcopy(Config.options.subagent), overrides)
    -- Re-arm the sweep timer so it picks up the new interval.
    Reaper.stop()
    Reaper.start()
    check(Reaper._sweep_running(), "sweep timer not armed after config change")
end

---@param parent table
---@return table? child, string? err
local function spawn_child(parent)
    local child, err
    Subsessions.spawn(parent, { task = TASK, name = CHILD_NAME }, function(c, e)
        child, err = c, e
    end)
    local got = vim.wait(60000, function()
        return child ~= nil or err ~= nil
    end, 50)
    check(got, "spawn callback never fired within 60s")
    return child, err
end

--- Wait until the manifest reports the child's run settled (or is already reaped).
---@param id string
---@param timeout_s integer
local function wait_settled(id, timeout_s)
    local ok = vim.wait(timeout_s * 1000, function()
        local s = manifest_status(id)
        return s == "completed" or s == "failed" or s == "interrupted" or s == "dormant"
    end, 50)
    check(ok, ("child did not settle within %ds"):format(timeout_s), { status = manifest_status(id) })
end

--- S1: settled child is auto-reaped, JSONL retained, child revivable.
---@param parent table
---@param report table
local function scenario_s1(parent, report)
    step("S1 spawn child")
    local child, err = spawn_child(parent)
    check(child ~= nil, "S1: spawn failed: " .. tostring(err))
    local id = child.id
    local rpc = child.rpc
    local pid = record_child(report, child)
    check(pid ~= nil, "S1: could not read the child job pid")
    print(("[S1] spawned id=%s pid=%d status=%s"):format(id, pid, tostring(manifest_status(id))))

    step("S1 wait for LLM settle (180s budget)")
    wait_settled(id, 180)
    local st = manifest_status(id)
    print(("[S1] settled status=%s"):format(tostring(st)))
    -- Resident right after settle: nvim job alive AND OS-level kill -0.
    check(rpc:is_running() == true, "S1: child rpc not running right after settle", { status = st })
    local pid_after = rpc_pid(rpc)
    check(pid_after == pid, "S1: job pid changed across settle", { before = pid, after = pid_after })
    check(os_alive(pid), "S1: OS-level kill -0 failed for the settled child", { pid = pid })
    local path = child.session_file or Read.find_path(id)
    check(type(path) == "string" and vim.fn.filereadable(path) == 1, "S1: session JSONL missing after settle", {
        path = path,
    })
    report.path_set[path] = true
    step(("S1 settle confirmed, resident (pid %d)"):format(pid))

    step("S1 wait for idle reaper (60s budget)")
    local reaped = vim.wait(60000, function()
        return manifest_status(id) == "dormant" or rpc:is_running() == false
    end, 200)
    check(reaped, "S1: reaper did not fire within 60s", {
        status = manifest_status(id),
        running = rpc:is_running(),
    })
    local dead = wait_os_dead(pid, 15000)
    check(manifest_status(id) == "dormant", "S1: manifest not dormant after reap", {
        status = manifest_status(id),
    })
    check(rpc:is_running() == false, "S1: rpc still reports running after reap")
    check(dead and not os_alive(pid), "S1: OS process still alive after reap", { pid = pid })
    check(vim.fn.filereadable(path) == 1, "S1: session JSONL deleted by the reap (must be retained)", {
        path = path,
    })
    step("S1 reaped (dormant + process dead + JSONL retained)")

    step("S1 revive the dormant child")
    local revived, rerr
    Subsessions.revive(id, function(s, e)
        revived, rerr = s, e
    end)
    local got = vim.wait(30000, function()
        return revived ~= nil or rerr ~= nil
    end, 50)
    check(got and revived ~= nil, "S1: revive failed: " .. tostring(rerr or "callback timeout"))
    local nrpc = revived.rpc
    check(nrpc:is_running() == true, "S1: revived process not running")
    local npid = rpc_pid(nrpc)
    check(npid ~= nil and npid ~= pid, "S1: revived pid invalid or reused", { old = pid, new = npid })
    report.pids[#report.pids + 1] = npid
    check(os_alive(npid), "S1: revived process not alive at OS level", { pid = npid })
    check(manifest_status(id) == "active", "S1: manifest not active after revive", {
        status = manifest_status(id),
    })

    local rpath = Read.find_path(id) or revived.session_file
    check(type(rpath) == "string" and rpath ~= "", "S1: revived session path unknown")
    report.path_set[rpath] = true
    local content = read_file(rpath)
    check(content ~= nil and #content > 0, "S1: old history unreadable after revive", { path = rpath })
    check(content:find("DONE", 1, true) ~= nil, "S1: history does not contain the DONE exchange", { path = rpath })
    local assistant = Read.last_assistant_message(rpath)
    check(type(assistant) == "string" and assistant ~= "", "S1: last assistant message unreadable", { path = rpath })
    print(("[S1] revived pid=%d old_pid=%d report=%q"):format(npid, pid, assistant:sub(1, 60)))
    print(
        ("[S1] revived.id=%s manifest_key=%s registry_has_key=%s"):format(
            tostring(revived.id),
            tostring(id),
            tostring(Sessions.get_by_id(id) ~= nil)
        )
    )
    step("S1 revived (new process alive + old history readable)")

    step("S1 close the revived child")
    local revived_id = revived.id
    local reg_present = Sessions.get_by_id(id) ~= nil
    local stopped = Subsessions.close(id)
    if not stopped then
        -- Diagnostic: the revived session's pre-switch get_state response can
        -- transiently re-key the registry (capture_session_id -> migrate),
        -- with the post-switch get_state healing it one round-trip later.
        local healed = vim.wait(2000, function()
            return Sessions.get_by_id(id) ~= nil
        end, 50)
        print(
            ("[S1] close=false revived_id=%s reg_present=%s healed_2s=%s running=%s npid_alive=%s status=%s"):format(
                tostring(revived_id),
                tostring(reg_present),
                tostring(healed),
                tostring(nrpc:is_running()),
                tostring(os_alive(npid)),
                tostring(manifest_status(id))
            )
        )
        if healed then
            stopped = Subsessions.close(id)
        end
    end
    check(stopped, "S1: close did not stop the revived process", {
        revived_id = revived_id,
        registry_present = reg_present,
        running = nrpc:is_running(),
        npid_alive = os_alive(npid),
        status = manifest_status(id),
    })
    wait_os_dead(npid, 15000)
    check(nrpc:is_running() == false, "S1: revived rpc still running after close")
    check(not os_alive(npid), "S1: revived OS process alive after close", { pid = npid })
    check(manifest_status(id) == "dormant", "S1: manifest not dormant after close", {
        status = manifest_status(id),
    })
    check(vim.fn.filereadable(rpath) == 1, "S1: history file removed by close", { path = rpath })
    step("S1 closed (dormant, process dead, history retained)")
end

--- S2: reaping disabled + max_children=1 — settled-but-alive child holds its slot.
---@param parent table
---@param report table
local function scenario_s2(parent, report)
    apply_subagent_cfg({ reap_after_minutes = 0, max_children = 1 })
    step("S2 config reap_after_minutes=0 max_children=1 (sweep stays armed)")

    local c1, e1 = spawn_child(parent)
    check(c1 ~= nil, "S2: child-1 spawn failed: " .. tostring(e1))
    local pid1 = record_child(report, c1)
    check(pid1 ~= nil, "S2: could not read child-1 pid")
    wait_settled(c1.id, 180)
    check(manifest_status(c1.id) == "completed", "S2: child-1 not completed after settle", {
        status = manifest_status(c1.id),
    })
    print(("[S2] child-1 settled id=%s pid=%d"):format(c1.id, pid1))
    -- Resident past one full sweep interval: reaping disabled must not kill it.
    vim.wait(14000, function()
        return false
    end, 200)
    check(c1.rpc:is_running() == true, "S2: child-1 rpc died despite reaping being disabled")
    check(os_alive(pid1), "S2: child-1 OS process died despite reaping being disabled", { pid = pid1 })
    check(manifest_status(c1.id) == "completed", "S2: child-1 manifest changed despite reaping disabled", {
        status = manifest_status(c1.id),
    })
    step("S2 child-1 resident 14s after settle (completed + alive)")

    local before = #Sessions.list_all()
    local c2, e2 = spawn_child(parent)
    if c2 ~= nil then
        record_child(report, c2)
    end
    check(c2 == nil, "S2: spawn past max_children=1 unexpectedly succeeded", {
        id = c2 ~= nil and c2.id or nil,
    })
    check(type(e2) == "string" and e2:find("max 1", 1, true) ~= nil, "S2: error lacks 'max 1'", { err = e2 })
    check(e2:find("concurrent sub-sessions", 1, true) ~= nil, "S2: error lacks 'concurrent sub-sessions'", {
        err = e2,
    })
    check(#Sessions.list_all() == before, "S2: capped spawn leaked a registry session", {
        before = before,
        after = #Sessions.list_all(),
    })
    check(c1.rpc:is_running() == true and os_alive(pid1), "S2: child-1 died when the capped spawn failed")
    print(("[S2] capped spawn rejected: %s"):format(e2))
    step("S2 max_children=1 enforced (resident child holds the slot)")

    local stopped = Subsessions.close(c1.id)
    check(stopped, "S2: close did not stop child-1")
    local dead = wait_os_dead(pid1, 15000)
    check(dead and not os_alive(pid1), "S2: child-1 OS process survived close", { pid = pid1 })
    check(manifest_status(c1.id) == "dormant", "S2: child-1 not dormant after close", {
        status = manifest_status(c1.id),
    })
    step("S2 child-1 closed (slot freed)")

    local c3, e3 = spawn_child(parent)
    check(c3 ~= nil, "S2: spawn after closing child-1 failed: " .. tostring(e3))
    local pid3 = record_child(report, c3)
    check(pid3 ~= nil, "S2: could not read child-3 pid")
    wait_settled(c3.id, 180)
    check(manifest_status(c3.id) == "completed", "S2: child-3 not completed after settle", {
        status = manifest_status(c3.id),
    })
    check(c3.rpc:is_running() == true and os_alive(pid3), "S2: child-3 not resident after settle", {
        pid = pid3,
    })
    print(("[S2] child-3 spawned+settled id=%s pid=%d"):format(c3.id, pid3))
    step("S2 child-3 spawned after slot freed")

    local stopped3 = Subsessions.close(c3.id)
    check(stopped3, "S2: close did not stop child-3")
    wait_os_dead(pid3, 15000)
    step("S2 child-3 closed")
end

--- Always-run teardown: kill every spawned process, remove our session files,
--- restore the manifest to its pre-run snapshot, stop timers/singletons.
---@param report table
---@param manifest_path string
---@param snapshot string? Pre-run manifest file content (nil = file did not exist)
---@return string[] notes
local function cleanup(report, manifest_path, snapshot)
    local notes = {}
    pcall(Reaper.stop)

    local closed = {}
    for _, id in ipairs(report.ids) do
        if not closed[id] then
            closed[id] = true
            pcall(Subsessions.close, id)
        end
    end
    pcall(Sessions._reset)

    -- OS-level guarantee: no test process survives the run.
    local seen_pid = {}
    for _, pid in ipairs(report.pids) do
        if not seen_pid[pid] then
            seen_pid[pid] = true
            wait_os_dead(pid, 5000)
            if os_alive(pid) then
                pcall(uv.kill, pid, 9)
                wait_os_dead(pid, 5000)
            end
            if os_alive(pid) then
                notes[#notes + 1] = ("pid %d still alive after SIGKILL"):format(pid)
            end
        end
    end

    -- Our session JSONL files only (exact recorded paths — never grep, G18).
    local removed = 0
    local seen_path = {}
    for _, id in ipairs(report.ids) do
        local p = Read.find_path(id)
        if type(p) == "string" and p ~= "" then
            report.path_set[p] = true
        end
    end
    for p in pairs(report.path_set) do
        if type(p) == "string" and p ~= "" and not seen_path[p] then
            seen_path[p] = true
            if vim.fn.filereadable(p) == 1 and os.remove(p) then
                removed = removed + 1
            end
        end
    end
    notes[#notes + 1] = ("%d session file(s) removed"):format(removed)

    pcall(Reaper._reset)
    pcall(Subsessions._reset_abort_epochs)
    pcall(Subsessions._reset_child_aborts)
    pcall(Manifest._reset)

    -- Restore the manifest snapshot taken before the run (G17: no residue).
    if type(snapshot) == "string" then
        local dir = vim.fn.fnamemodify(manifest_path, ":h")
        if vim.fn.isdirectory(dir) == 0 then
            vim.fn.mkdir(dir, "p")
        end
        local f = io.open(manifest_path, "w")
        if f then
            f:write(snapshot)
            f:close()
            notes[#notes + 1] = "manifest restored to pre-run snapshot"
        else
            notes[#notes + 1] = "FAILED to restore manifest snapshot"
        end
    elseif vim.fn.filereadable(manifest_path) == 1 then
        if os.remove(manifest_path) then
            notes[#notes + 1] = "manifest created by the run removed"
        end
    end
    return notes
end

-- ---------------------------------------------------------------------------

local report = { ids = {}, pids = {}, path_set = {} }

-- Snapshot the manifest BEFORE anything can touch it (pi.setup's
-- rebuild_statuses rewrites it); cleanup restores this exact content.
local manifest_path = Manifest.path()
local manifest_snapshot = read_file(manifest_path)

local ok, failure = pcall(function()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")

    -- Belt and braces for G17: no chat UI is opened, but redirect the draft
    -- store anyway so nothing can touch the user's real files.
    pcall(function()
        require("pi.draft")._set_path(vim.fn.tempname() .. "-e2e-reaper-draft.txt")
    end)

    require("pi").setup({ title = { lang = "en" } })

    -- G31: replace options.subagent with a modified deepcopy; never mutate the
    -- (possibly defaults-aliased) table in place. Short timers for the run.
    apply_subagent_cfg({ reap_after_minutes = 0.1, reap_sweep_minutes = 0.2 })
    print(
        ("[cfg] reap_after_minutes=%s reap_sweep_minutes=%s max_children=%s sweep_running=%s"):format(
            tostring(Config.options.subagent.reap_after_minutes),
            tostring(Config.options.subagent.reap_sweep_minutes),
            tostring(Config.options.subagent.max_children),
            tostring(Reaper._sweep_running())
        )
    )
    step("setup (pi.setup + short reaper timers)")

    -- Fake parent: spawn only needs its id/lineage; no parent process is
    -- required (on_child_settled skips report injection when the parent is
    -- not registered, and arms the reaper regardless).
    local parent = { id = "e2e-reaper-parent-" .. tostring(os.time()), conversation_epoch = 0 }

    scenario_s1(parent, report)
    scenario_s2(parent, report)
end)

local notes = cleanup(report, manifest_path, manifest_snapshot)
local total = (uv.hrtime() - run_started) / 1e9
for _, n in ipairs(notes) do
    print("[cleanup] " .. n)
end

if not ok then
    print(("FAIL: %s (after %.2fs)"):format(tostring(failure), total))
    io.stdout:flush()
    os.exit(1)
end

print(
    ("PASS: reaper e2e OK — S1 spawn/settle/reap/revive/close, S2 max_children=1 slot logic (in %.2fs)"):format(total)
)
os.exit(0)
