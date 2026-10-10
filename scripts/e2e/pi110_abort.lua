-- Headless e2e: pi 1.1.0 agent_settled.aborted wire verification & subsession cancel detection (#114).
--
-- Drives real `pi 1.1.0` binary processes end to end with LLM tool invocation:
--
--   Scenario A (Normal session abort):
--     Real session -> prompt "Use the bash tool to run: sleep 30." ->
--     wait for tool_execution_start (bash executing) ->
--     call require("pi").abort() -> wait for agent_settled.
--     - Assertion 1 (wire): msg.aborted == true on agent_settled event.
--     - Assertion 2 (UI convergence): chat busy state cleared, no leftover spinner
--       (statusline busy nil, session._detached_busy nil/false, chat not streaming).
--
--   Scenario B (Subsession abort -> manifest interrupted, #114 main path):
--     Real parent session -> Subsessions.spawn(parent, {task=..., name="e2e-abort"}) ->
--     wait for child's tool_execution_start ->
--     call require("pi").abort() -> wait for child agent_settled + manifest settle.
--     - Assertion 1 (wire): child's agent_settled msg.aborted == true.
--     - Assertion 2 (#114 behavior): manifest status == "interrupted" and NO
--       completion report prompt injected into parent.
--     - Assertion 3: parent session itself is still healthy (parent.rpc:is_running() == true).
--
-- How to run (from worktree root):
--   nvim --headless -u tests/minimal_init.lua -l scripts/e2e/pi110_abort.lua
--
-- Exit code:
--   0 = SUCCESS (all scenarios PASS, or PASS + SKIP)
--   non-zero (1) = FAIL
--
-- Budget: < 420s (abort immediately settles sleep 30).

local uv = vim.uv or vim.loop

local Config = require("pi.config")
local Draft = require("pi.draft")
local Manifest = require("pi.subsessions.manifest")
local PromptHistory = require("pi.prompt_history")
local Read = require("pi.subsessions.read")
local Reaper = require("pi.subsessions.reaper")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")

io.stdout:setvbuf("no")
local run_started = uv.hrtime()
local last_step = run_started

---@return number elapsed seconds since the previous step marker
local function step(name)
    local t = uv.hrtime()
    print(string.format("[step] %-58s +%6.2fs (total %7.2fs)", name, (t - last_step) / 1e9, (t - run_started) / 1e9))
    last_step = t
end

--- Assert with context: on failure prints FAIL + context via outer handler.
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

--- OS pid behind an Rpc's nvim job (nil when gone).
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

---@param pid integer?
---@param timeout_ms integer
---@return boolean dead
local function wait_os_dead(pid, timeout_ms)
    if type(pid) ~= "number" or pid <= 1 then
        return true
    end
    return vim.wait(timeout_ms, function()
        return not os_alive(pid)
    end, 100)
end

--- Find buffer by filetype.
---@param ft string
---@return integer? bufnr
local function find_buf(ft)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == ft then
            return b
        end
    end
    return nil
end

--- Record session id, pid, session_file into report.
---@param rep table
---@param s table?
---@return integer? pid
local function record_session(rep, s)
    if not s then
        return nil
    end
    if type(s.id) == "string" and s.id ~= "" then
        rep.ids[#rep.ids + 1] = s.id
    end
    local pid = rpc_pid(s.rpc)
    if pid then
        rep.pids[#rep.pids + 1] = pid
    end
    if type(s.session_file) == "string" and s.session_file ~= "" then
        rep.path_set[s.session_file] = true
    end
    return pid
end

--- Find event matching `event_type` in event list.
---@param events_list table[]
---@param event_type string
---@return table?
local function find_event(events_list, event_type)
    for _, ev in ipairs(events_list) do
        if type(ev) == "table" and ev.type == event_type then
            return ev
        end
    end
    return nil
end

--- Check if events list contains rate limiting indication.
---@param events_list table[]
---@return boolean
local function is_rate_limited(events_list)
    for _, ev in ipairs(events_list) do
        local str = vim.inspect(ev):lower()
        if str:find("429") or str:find("rate limit") or str:find("too many requests") then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Setup report, snapshots, isolation
-- ---------------------------------------------------------------------------

local report = {
    ids = {},
    pids = {},
    path_set = {},
}

local scenarios = {
    scenario_a = { name = "Scenario A (normal session abort)", status = "PENDING", detail = "" },
    scenario_b = { name = "Scenario B (subsession abort -> manifest interrupted)", status = "PENDING", detail = "" },
}

local wire_results = {
    scenario_a_aborted = nil,
    scenario_b_aborted = nil,
}

local orig_config = vim.deepcopy(Config.options)
local orig_handle_event = Sessions.handle_event
local orig_parent_rpc_send = nil

-- Snapshot the manifest BEFORE anything can touch it (G17)
local manifest_path = Manifest.path()
local manifest_snapshot = read_file(manifest_path)

-- G17: Isolated draft and prompt history in /tmp
local tmp_draft = vim.fn.tempname() .. "-e2e-abort-draft.txt"
local tmp_history_dir = vim.fn.tempname() .. "-e2e-abort-hist"
vim.fn.mkdir(tmp_history_dir, "p")
pcall(Draft._set_path, tmp_draft)
pcall(PromptHistory._set_base_dir, tmp_history_dir)

--- Always-run teardown.
local function cleanup()
    local notes = {}
    print("\n[teardown] Running cleanup...")

    -- 1. Restore monkeypatches
    if orig_handle_event then
        Sessions.handle_event = orig_handle_event
    end
    if orig_parent_rpc_send and Sessions.get() and Sessions.get().rpc then
        Sessions.get().rpc.send = orig_parent_rpc_send
    end

    -- 2. Stop reaper & close sub-sessions
    pcall(Reaper.stop)
    local closed = {}
    for _, id in ipairs(report.ids) do
        if not closed[id] then
            closed[id] = true
            pcall(Subsessions.close, id)
        end
    end
    pcall(Sessions._reset)

    -- 3. Kill all OS child processes (G18: never leave zombies)
    local seen_pid = {}
    for _, pid in ipairs(report.pids) do
        if not seen_pid[pid] then
            seen_pid[pid] = true
            wait_os_dead(pid, 2000)
            if os_alive(pid) then
                pcall(uv.kill, pid, 15)
                wait_os_dead(pid, 2000)
            end
            if os_alive(pid) then
                pcall(uv.kill, pid, 9)
                wait_os_dead(pid, 2000)
            end
            if os_alive(pid) then
                notes[#notes + 1] = ("PID %d still alive after SIGKILL"):format(pid)
            else
                notes[#notes + 1] = ("PID %d dead"):format(pid)
            end
        end
    end

    -- 4. Delete our session JSONL files only (exact recorded paths — G18)
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
    notes[#notes + 1] = ("%d session JSONL file(s) removed"):format(removed)

    -- 5. Restore manifest snapshot (G17)
    pcall(Reaper._reset)
    pcall(Subsessions._reset_abort_epochs)
    pcall(Subsessions._reset_child_aborts)
    pcall(Manifest._reset)

    if type(manifest_snapshot) == "string" then
        local dir = vim.fn.fnamemodify(manifest_path, ":h")
        if vim.fn.isdirectory(dir) == 0 then
            vim.fn.mkdir(dir, "p")
        end
        local f = io.open(manifest_path, "w")
        if f then
            f:write(manifest_snapshot)
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

    -- 6. Clean up temp files
    if vim.fn.filereadable(tmp_draft) == 1 then
        pcall(os.remove, tmp_draft)
    end
    if vim.fn.isdirectory(tmp_history_dir) == 1 then
        pcall(vim.fn.delete, tmp_history_dir, "rf")
    end

    -- 7. Restore Config
    if orig_config then
        Config.options = vim.deepcopy(orig_config)
    end

    for _, n in ipairs(notes) do
        print("[teardown] " .. n)
    end
end

-- ---------------------------------------------------------------------------
-- Main execution
-- ---------------------------------------------------------------------------

local run_ok, run_failure = pcall(function()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH")

    -- Step 0: Setup plugin & launch real session
    require("pi").setup({ title = { lang = "en" } })
    step("plugin setup (pi.setup)")

    require("pi").show({ layout = "side" })
    local bufs_ok = vim.wait(15000, function()
        return find_buf("pi-chat-history") ~= nil and find_buf("pi-chat-prompt") ~= nil
    end, 50)
    check(bufs_ok, "chat buffers (history + prompt) failed to appear within 15s")

    local parent = Sessions.get()
    check(parent ~= nil, "parent session was not created")
    local rpc_up = vim.wait(15000, function()
        return parent.rpc:is_running()
    end, 50)
    check(rpc_up, "parent RPC backend process failed to start within 15s")
    record_session(report, parent)

    -- Wait for backend to report real sessionId
    local id_ready = vim.wait(10000, function()
        return type(parent.id) == "string" and parent.id ~= "" and not parent.id:match("^tmp%-")
    end, 50)
    check(id_ready, "parent session id not ready within 10s")
    record_session(report, parent)
    step(("parent session ready (id=%s pid=%s)"):format(tostring(parent.id), tostring(rpc_pid(parent.rpc))))

    -- Event recorder: intercepts events across parent and child sessions
    local parent_events = {}
    local child_events = {}
    local child_ref = nil

    Sessions.handle_event = function(sess, msg)
        if sess == parent or (parent and sess.id == parent.id) then
            parent_events[#parent_events + 1] = vim.deepcopy(msg)
        elseif child_ref and (sess == child_ref or sess.id == child_ref.id) then
            child_events[#child_events + 1] = vim.deepcopy(msg)
        end
        return orig_handle_event(sess, msg)
    end

    -- =======================================================================
    -- Scenario A: Normal session abort
    -- =======================================================================
    step("Scenario A: start prompt 'Use the bash tool to run: sleep 30.'")
    parent.chat._prompt:set_text("Use the bash tool to run: sleep 30.")
    parent.chat:submit()

    -- Wait for tool_execution_start (with LLM delay / retry robustness)
    step("Scenario A: wait for tool_execution_start (up to 120s budget)")
    local tool_start_ev = nil
    local wait_start_t = uv.hrtime()
    local retried_prompt = false

    local wait_tool_ok = vim.wait(60000, function()
        tool_start_ev = find_event(parent_events, "tool_execution_start")
        return tool_start_ev ~= nil or is_rate_limited(parent_events)
    end, 100)

    if not wait_tool_ok and not tool_start_ev then
        if is_rate_limited(parent_events) then
            print("[Scenario A] rate limit detected, waiting 10s backoff and retrying...")
            vim.wait(10000, function()
                return false
            end, 1000)
            parent.chat._prompt:set_text("Immediately run bash tool: sleep 30. No explanation.")
            parent.chat:submit()
            retried_prompt = true
        elseif parent.chat:is_streaming() then
            print("[Scenario A] model still streaming/thinking after 60s, extending wait to 120s...")
        else
            print("[Scenario A] no tool start in 60s, submitting direct instruction...")
            parent.chat._prompt:set_text("Immediately run bash tool: sleep 30. No explanation.")
            parent.chat:submit()
            retried_prompt = true
        end

        vim.wait(60000, function()
            tool_start_ev = find_event(parent_events, "tool_execution_start")
            return tool_start_ev ~= nil
        end, 100)
    end

    if not tool_start_ev then
        scenarios.scenario_a.status = "SKIP"
        scenarios.scenario_a.detail = "model did not emit tool_execution_start within 120s budget"
        print("[Scenario A] SKIP: " .. scenarios.scenario_a.detail)
    else
        step("Scenario A: tool_execution_start observed -> calling pi.abort()")
        require("pi").abort()

        step("Scenario A: waiting for agent_settled event (up to 30s)")
        local settled_ok = vim.wait(30000, function()
            return find_event(parent_events, "agent_settled") ~= nil
        end, 50)
        check(settled_ok, "Scenario A: agent_settled event did not arrive within 30s after abort")

        local settled_ev = find_event(parent_events, "agent_settled")
        check(settled_ev ~= nil, "Scenario A: agent_settled event object missing")
        wire_results.scenario_a_aborted = settled_ev.aborted

        -- Assertion 1 (wire): msg.aborted == true
        check(settled_ev.aborted == true, "Scenario A Assertion 1 FAIL: wire msg.aborted is not true", {
            event = settled_ev,
        })
        print(("[Scenario A] Assertion 1 PASS: wire agent_settled.aborted = %s"):format(tostring(settled_ev.aborted)))

        -- Flush vim.schedule UI convergence
        vim.wait(1000, function()
            return false
        end, 100)

        -- Assertion 2 (UI convergence): chat busy cleared, no leftover spinner
        local streaming = parent.chat:is_streaming()
        local detached_busy = parent._detached_busy
        local status_text = parent.chat._history._status_text
        local statusline_busy = parent.chat._prompt:statusline()._state.busy

        check(not streaming, "Scenario A Assertion 2 FAIL: chat._streaming still true", { streaming = streaming })
        check(
            not detached_busy,
            "Scenario A Assertion 2 FAIL: parent._detached_busy still true",
            { detached_busy = detached_busy }
        )
        check(
            status_text == nil,
            "Scenario A Assertion 2 FAIL: history._status_text not nil",
            { status_text = status_text }
        )
        check(
            statusline_busy == nil,
            "Scenario A Assertion 2 FAIL: statusline busy state not nil",
            { busy = statusline_busy }
        )
        print("[Scenario A] Assertion 2 PASS: chat busy state cleared, no leftover spinner")

        scenarios.scenario_a.status = "PASS"
        scenarios.scenario_a.detail = "wire msg.aborted==true and UI converged to idle"
    end
    record_session(report, parent)

    -- =======================================================================
    -- Scenario B: Subsession abort -> manifest interrupted (#114 main path)
    -- =======================================================================
    step("Scenario B: prepare parent RPC spy and spawn child")
    check(parent.rpc:is_running() == true, "parent rpc is not running before Scenario B")

    -- Spy on parent's rpc.send to detect any completion report injection
    local parent_sent_prompts = {}
    orig_parent_rpc_send = parent.rpc.send
    parent.rpc.send = function(self, cmd, cb)
        if type(cmd) == "table" and cmd.type == "prompt" then
            table.insert(parent_sent_prompts, vim.deepcopy(cmd))
        end
        return orig_parent_rpc_send(self, cmd, cb)
    end

    local child, spawn_err
    Subsessions.spawn(parent, { task = "Use the bash tool to run: sleep 30.", name = "e2e-abort" }, function(c, err)
        child = c
        spawn_err = err
    end)

    local spawn_ok = vim.wait(30000, function()
        return child ~= nil or spawn_err ~= nil
    end, 50)
    check(spawn_ok and child ~= nil, "Scenario B: Subsessions.spawn failed", { err = spawn_err })

    child_ref = child
    record_session(report, child)
    local child_pid = rpc_pid(child.rpc)
    step(("Scenario B: child spawned (id=%s pid=%s)"):format(tostring(child.id), tostring(child_pid)))

    -- Wait for child's tool_execution_start
    step("Scenario B: wait for child tool_execution_start (up to 120s budget)")
    local child_tool_start_ev = nil

    local child_wait_ok = vim.wait(60000, function()
        child_tool_start_ev = find_event(child_events, "tool_execution_start")
        return child_tool_start_ev ~= nil or is_rate_limited(child_events)
    end, 100)

    if not child_wait_ok and not child_tool_start_ev then
        if is_rate_limited(child_events) then
            print("[Scenario B] child rate limit detected, backing off...")
            vim.wait(10000, function()
                return false
            end, 1000)
        else
            print("[Scenario B] model still thinking after 60s, extending wait to 120s...")
        end

        vim.wait(60000, function()
            child_tool_start_ev = find_event(child_events, "tool_execution_start")
            return child_tool_start_ev ~= nil
        end, 100)
    end

    if not child_tool_start_ev then
        scenarios.scenario_b.status = "SKIP"
        scenarios.scenario_b.detail = "child did not emit tool_execution_start within 120s budget"
        print("[Scenario B] SKIP: " .. scenarios.scenario_b.detail)
    else
        step("Scenario B: child tool_execution_start observed -> calling pi.abort()")
        -- Call plugin's sub-session abort path: pi.abort() from parent triggers
        -- interrupt_children for active children in lineage
        require("pi").abort()

        step("Scenario B: waiting for child agent_settled event (up to 30s)")
        local child_settled_ok = vim.wait(30000, function()
            return find_event(child_events, "agent_settled") ~= nil
        end, 50)
        check(child_settled_ok, "Scenario B: child agent_settled did not arrive within 30s after abort")

        local child_settled_ev = find_event(child_events, "agent_settled")
        check(child_settled_ev ~= nil, "Scenario B: child agent_settled event missing")
        wire_results.scenario_b_aborted = child_settled_ev.aborted

        -- Assertion 1 (wire): child's agent_settled msg.aborted == true
        check(child_settled_ev.aborted == true, "Scenario B Assertion 1 FAIL: child wire msg.aborted is not true", {
            event = child_settled_ev,
        })
        print(
            ("[Scenario B] Assertion 1 PASS: child wire agent_settled.aborted = %s"):format(
                tostring(child_settled_ev.aborted)
            )
        )

        step("Scenario B: waiting for manifest child status to settle")
        local manifest_settled = vim.wait(10000, function()
            local m = Manifest.load()
            local entry = m[child.id]
            return entry and (entry.status == "interrupted" or entry.status == "completed" or entry.status == "failed")
        end, 50)
        check(manifest_settled, "Scenario B: manifest entry did not settle within 10s")

        -- Assertion 2 (#114 behavior): manifest status == "interrupted" & no report injection
        local m_entry = Manifest.load()[child.id]
        check(m_entry ~= nil, "Scenario B Assertion 2 FAIL: child entry missing in manifest")
        check(
            m_entry.status == "interrupted",
            "Scenario B Assertion 2 FAIL: child status is not 'interrupted'",
            { status = m_entry.status, entry = m_entry }
        )
        check(
            m_entry.reported ~= true,
            "Scenario B Assertion 2 FAIL: child manifest reported flag unexpectedly true",
            { entry = m_entry }
        )
        check(
            #parent_sent_prompts == 0,
            "Scenario B Assertion 2 FAIL: completion report prompt was injected into parent",
            { prompts = parent_sent_prompts }
        )
        print(
            ("[Scenario B] Assertion 2 PASS: manifest status='%s', reported=%s, parent_prompts=%d"):format(
                m_entry.status,
                tostring(m_entry.reported),
                #parent_sent_prompts
            )
        )

        -- Assertion 3: parent session itself is still healthy
        check(parent.rpc:is_running() == true, "Scenario B Assertion 3 FAIL: parent rpc died during child abort")

        -- Verify parent rpc responds to get_state
        local state_received = false
        local state_resp = nil
        parent.rpc:send({ type = "get_state" }, function(res)
            state_received = true
            state_resp = res
        end)
        local state_ok = vim.wait(5000, function()
            return state_received
        end, 50)
        check(state_ok and state_resp and state_resp.success, "Scenario B Assertion 3 FAIL: parent rpc unresponsive", {
            resp = state_resp,
        })
        print("[Scenario B] Assertion 3 PASS: parent session is still healthy and responsive")

        scenarios.scenario_b.status = "PASS"
        scenarios.scenario_b.detail = "child aborted==true, manifest status=='interrupted', parent healthy"
    end
    record_session(report, child)
end)

-- ---------------------------------------------------------------------------
-- Teardown & Final Report
-- ---------------------------------------------------------------------------

local total_elapsed = (uv.hrtime() - run_started) / 1e9
cleanup()

print("\n=======================================================================")
print("                      E2E TEST RUN SUMMARY")
print("=======================================================================")
print(string.format("Total Duration: %.2fs (budget: < 420s)", total_elapsed))
print(string.format("Wire Results:   Scenario A aborted: %s", tostring(wire_results.scenario_a_aborted)))
print(string.format("                Scenario B aborted: %s", tostring(wire_results.scenario_b_aborted)))

local any_failed = false
for key, sc in pairs(scenarios) do
    print(string.format("[%s] %-50s — %s", sc.status, sc.name, sc.detail))
    if sc.status == "FAIL" then
        any_failed = true
    end
end

if not run_ok then
    print("\n[CRITICAL FAILURE] Test run threw an unhandled error:")
    print(tostring(run_failure))
    any_failed = true
end

print("=======================================================================")

if any_failed then
    print("\nRESULT: FAIL")
    os.exit(1)
else
    print("\nRESULT: PASS")
    os.exit(0)
end
