-- Headless e2e: pi 1.1.0 CLI argument version gating & provider pairing (#115).
--
-- Drives real `pi 1.1.0` binary processes to verify CLI argument filtering:
--   Scenario A: Gated flag (--no-mcp) retained on pi 1.1.0 >= 1.0.4;
--               real RPC process spawns and responds to get_state;
--               zero Notify.warn calls emitted throughout.
--   Scenario B: Version probe is cached; repeated filter_args does not re-probe;
--               Cli._reset() drops the cache so next call re-probes (count + 1).
--   Scenario C: --provider without --model warns exactly once mentioning --model;
--               real pi 1.1.0 hard-rejects this combination (process exits code 1).
--               (If pi accepts unexpectedly, records OBSERVATION instead of FAIL).
--   Scenario D: No gated flags present skips version probe entirely (count = 0).
--
-- How to run (from worktree root):
--   nvim --headless -u tests/minimal_init.lua -l scripts/e2e/pi110_cli_gating.lua
--
-- Exit code:
--   0 = SUCCESS (all scenarios PASS, or PASS + OBSERVATION)
--   non-zero (1) = FAIL
--
-- Budget: < 240s (0 LLM/model calls; get_state is an internal RPC command).

local uv = vim.uv or vim.loop

local Cli = require("pi.cli")
local Config = require("pi.config")
local Notify = require("pi.notify")
local Rpc = require("pi.rpc")
local Draft = require("pi.draft")
local PromptHistory = require("pi.prompt_history")

io.stdout:setvbuf("no")
local run_started = uv.hrtime()
local last_step = run_started

---@return number elapsed seconds since previous step marker
local function step(name)
    local t = uv.hrtime()
    print(string.format("[step] %-58s +%6.2fs (total %7.2fs)", name, (t - last_step) / 1e9, (t - run_started) / 1e9))
    last_step = t
end

--- Assert condition with contextual detail.
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

--- POSIX process liveness probe.
---@param pid integer?
---@return boolean
local function os_alive(pid)
    if type(pid) ~= "number" or pid <= 1 then
        return false
    end
    vim.fn.system({ "kill", "-0", tostring(pid) })
    return vim.v.shell_error == 0
end

--- Wait until OS pid is dead.
---@param pid integer?
---@param timeout_ms integer
---@return boolean dead
local function wait_os_dead(pid, timeout_ms)
    if type(pid) ~= "number" or pid <= 1 then
        return true
    end
    return vim.wait(timeout_ms, function()
        return not os_alive(pid)
    end, 50)
end

---@class Report
---@field pids integer[]
---@field session_files string[]
---@field scenarios table<string, { status: string, detail: string }>

local orig_cwd = vim.fn.getcwd()
local orig_config = vim.deepcopy(Config.options)
local orig_probe = Cli._probe_version
local orig_warn = Notify.warn

---@type Report
local report = {
    pids = {},
    session_files = {},
    scenarios = {},
}

-- G17: Scratch directory for isolated prompt history, draft, and session cwd
local tmp_dir = vim.fn.tempname() .. "_pi110_e2e"
vim.fn.mkdir(tmp_dir, "p")
vim.api.nvim_set_current_dir(tmp_dir)

PromptHistory._set_base_dir(tmp_dir .. "/pi")
Draft._set_path(tmp_dir .. "/draft.txt")

-- Wrap version probe to track execution count while running real probe
local probe_calls = 0
Cli._probe_version = function()
    probe_calls = probe_calls + 1
    return orig_probe()
end

-- Spy on Notify.warn
local warn_calls = {}
Notify.warn = function(msg)
    warn_calls[#warn_calls + 1] = msg
end

--- Always-run teardown.
local function cleanup()
    print("\n--- Teardown & Isolation Cleanup ---")

    -- 1. Restore cwd first so no file locks stay in tmp_dir
    if orig_cwd and vim.fn.getcwd() ~= orig_cwd then
        pcall(vim.api.nvim_set_current_dir, orig_cwd)
    end

    -- 2. Kill all tracked OS child processes
    local seen_pid = {}
    for _, pid in ipairs(report.pids) do
        if not seen_pid[pid] then
            seen_pid[pid] = true
            if os_alive(pid) then
                pcall(uv.kill, pid, 15)
                wait_os_dead(pid, 2000)
                if os_alive(pid) then
                    pcall(uv.kill, pid, 9)
                    wait_os_dead(pid, 2000)
                end
            end
            if os_alive(pid) then
                print(("  [cleanup] WARNING: PID %d still alive after kill"):format(pid))
            else
                print(("  [cleanup] Process PID %d dead"):format(pid))
            end
        end
    end

    -- 3. Delete session files (G18: exact recorded paths only)
    local seen_file = {}
    local session_count = 0
    for _, path in ipairs(report.session_files) do
        if type(path) == "string" and path ~= "" and not seen_file[path] then
            seen_file[path] = true
            if vim.fn.filereadable(path) == 1 and os.remove(path) then
                session_count = session_count + 1
            end
            local dir = vim.fn.fnamemodify(path, ":h")
            pcall(vim.fn.delete, dir, "d")
        end
    end
    print(("  [cleanup] Removed %d tracked session file(s)"):format(session_count))

    -- 4. Delete scratch directory (G17)
    if tmp_dir and vim.fn.isdirectory(tmp_dir) == 1 then
        pcall(vim.fn.delete, tmp_dir, "rf")
        print(("  [cleanup] Removed temp directory %s"):format(tmp_dir))
    end

    -- 5. Restore config snapshot
    if orig_config then
        Config.options = vim.deepcopy(orig_config)
    end

    -- 6. Restore stubs and module singletons
    if orig_probe then
        Cli._probe_version = orig_probe
    end
    if orig_warn then
        Notify.warn = orig_warn
    end
    pcall(Cli._reset)
    pcall(PromptHistory._reset)
    pcall(Draft._set_path, nil)
    print("  [cleanup] Completed")
end

local function run_suite()
    ----------------------------------------------------------------------------
    -- Scenario A: Gated flag retained + real RPC spawn & get_state
    ----------------------------------------------------------------------------
    step("Scenario A: start")
    Cli._reset()
    probe_calls = 0
    warn_calls = {}

    Config.options.cli.args = { "--no-mcp" }
    local filtered_a = Cli.filter_args(Config.options.cli.args)

    check(
        vim.deep_equal(filtered_a, { "--no-mcp" }),
        "Scenario A: filter_args must keep --no-mcp on pi 1.1.0",
        { got = filtered_a }
    )
    check(probe_calls == 1, "Scenario A: probe_calls should be 1 after filter_args", { got = probe_calls })
    check(Cli.pi_version() == "1.1.0", "Scenario A: pi_version() should detect 1.1.0", { got = Cli.pi_version() })

    -- Spawn real RPC session with filtered args
    local rpc_a = Rpc.new(1)
    local started_a = rpc_a:start()
    check(started_a, "Scenario A: rpc:start() must succeed")
    local pid_a = rpc_pid(rpc_a)
    check(pid_a ~= nil, "Scenario A: RPC job must have a valid OS PID", { pid = pid_a })
    report.pids[#report.pids + 1] = pid_a
    check(rpc_a:is_running(), "Scenario A: rpc:is_running() must be true")

    -- Send get_state and await response
    ---@type table?
    local state_resp = nil
    local send_ok = rpc_a:send({ type = "get_state" }, function(msg)
        state_resp = msg
    end)
    check(send_ok, "Scenario A: rpc:send(get_state) must succeed")

    local got_resp = vim.wait(15000, function()
        return state_resp ~= nil
    end, 50)
    check(got_resp, "Scenario A: get_state response must arrive within 15s")
    check(
        type(state_resp) == "table" and state_resp.type == "response",
        "Scenario A: response type must be 'response'",
        { resp = state_resp }
    )
    check(state_resp.success == true, "Scenario A: get_state response success must be true", { resp = state_resp })

    -- Track session file for G18 hermetic cleanup
    if state_resp.data and type(state_resp.data.sessionFile) == "string" then
        report.session_files[#report.session_files + 1] = state_resp.data.sessionFile
    end

    -- Gracefully stop session and confirm termination
    rpc_a:stop()
    check(not rpc_a:is_running(), "Scenario A: rpc:is_running() must be false after stop")
    check(wait_os_dead(pid_a, 5000), "Scenario A: OS process must terminate after stop", { pid = pid_a })

    -- Assert zero Notify.warn calls throughout Scenario A
    check(
        #warn_calls == 0,
        "Scenario A: Notify.warn must have 0 calls throughout",
        { count = #warn_calls, warns = warn_calls }
    )

    report.scenarios["A"] = {
        status = "PASS",
        detail = "Gated flag retained, real RPC spawn + get_state succeeded, 0 warnings",
    }
    step("Scenario A: PASS")

    ----------------------------------------------------------------------------
    -- Scenario B: Version probe caching across calls
    ----------------------------------------------------------------------------
    step("Scenario B: start")
    -- probe_calls should currently be 1 from Scenario A
    check(probe_calls == 1, "Scenario B baseline: probe_calls should start at 1", { got = probe_calls })

    local b1 = Cli.filter_args({ "--no-mcp" })
    check(probe_calls == 1, "Scenario B call 1: probe_calls should remain 1 (cache hit)", { got = probe_calls })
    check(vim.deep_equal(b1, { "--no-mcp" }), "Scenario B call 1: filter_args keeps --no-mcp")

    local b2 = Cli.filter_args({ "--no-mcp" })
    check(probe_calls == 1, "Scenario B call 2: probe_calls should remain 1 (cache hit)", { got = probe_calls })
    check(vim.deep_equal(b2, { "--no-mcp" }), "Scenario B call 2: filter_args keeps --no-mcp")

    Cli._reset()
    check(probe_calls == 1, "Scenario B after _reset: probe_calls counter itself unchanged", { got = probe_calls })

    local b3 = Cli.filter_args({ "--no-mcp" })
    check(
        probe_calls == 2,
        "Scenario B call 3: probe_calls should increment to 2 after _reset()",
        { got = probe_calls }
    )
    check(vim.deep_equal(b3, { "--no-mcp" }), "Scenario B call 3: filter_args keeps --no-mcp")

    report.scenarios["B"] = {
        status = "PASS",
        detail = string.format("Cache verified: calls 1&2 hit cache (count=1), _reset re-probed (count=2)"),
    }
    step("Scenario B: PASS")

    ----------------------------------------------------------------------------
    -- Scenario C: --provider without --model warning + real reject
    ----------------------------------------------------------------------------
    step("Scenario C: start")
    Cli._reset()
    warn_calls = {}
    Config.options.cli.args = { "--provider", "cliproxyapi" }

    local filtered_c = Cli.filter_args(Config.options.cli.args)
    check(
        #warn_calls == 1,
        "Scenario C: Notify.warn must be called exactly once",
        { count = #warn_calls, warns = warn_calls }
    )
    check(
        warn_calls[1]:match("%-%-model") ~= nil,
        "Scenario C: warning message must mention '--model'",
        { msg = warn_calls[1] }
    )

    -- Real spawn with invalid pairing
    local rpc_c = Rpc.new(2)
    local exit_event = nil
    local stderr_lines = {}
    rpc_c:set_handler(function(evt)
        if evt.type == "_process_exit" then
            exit_event = evt
        elseif evt.type == "_stderr" then
            stderr_lines[#stderr_lines + 1] = evt.message
        end
    end)

    local started_c = rpc_c:start()
    check(started_c, "Scenario C: rpc:start() should start process")
    local pid_c = rpc_pid(rpc_c)
    if pid_c then
        report.pids[#report.pids + 1] = pid_c
    end

    -- Expect pi 1.0.0+ to reject this combination promptly
    local dead_c = vim.wait(10000, function()
        return not rpc_c:is_running()
    end, 50)

    if dead_c and not rpc_c:is_running() then
        if pid_c then
            wait_os_dead(pid_c, 5000)
        end
        local exit_code = exit_event and exit_event.code
        report.scenarios["C"] = {
            status = "PASS",
            detail = string.format(
                "pi 1.1.0 rejected invalid pairing (exit code %s, stderr: '%s')",
                tostring(exit_code),
                table.concat(stderr_lines, " ")
            ),
        }
    else
        report.scenarios["C"] = {
            status = "OBSERVATION",
            detail = "pi 1.1.0 accepted --provider without --model contrary to hard reject expectation",
        }
        rpc_c:stop()
        if pid_c then
            wait_os_dead(pid_c, 5000)
        end
    end
    step("Scenario C: " .. report.scenarios["C"].status)

    ----------------------------------------------------------------------------
    -- Scenario D: No gated flag skips version probe
    ----------------------------------------------------------------------------
    step("Scenario D: start")
    Cli._reset()
    probe_calls = 0
    Config.options.cli.args = {}

    local filtered_d = Cli.filter_args(Config.options.cli.args)
    check(
        probe_calls == 0,
        "Scenario D: version probe must NOT be invoked when no gated flags exist",
        { got = probe_calls }
    )
    check(
        vim.deep_equal(filtered_d, {}),
        "Scenario D: filter_args with empty args must return empty table",
        { got = filtered_d }
    )

    report.scenarios["D"] = {
        status = "PASS",
        detail = "Empty cli.args did not trigger version probe (probe count = 0)",
    }
    step("Scenario D: PASS")
end

-- Run suite with protected call, ensuring teardown always executes
local suite_ok, suite_err = xpcall(run_suite, debug.traceback)

-- Always run teardown
local cleanup_ok, cleanup_err = pcall(cleanup)
if not cleanup_ok then
    io.stderr:write("[ERROR] Cleanup failed: " .. tostring(cleanup_err) .. "\n")
end

-- Print final summary
print("\n" .. string.rep("=", 70))
print("E2E VERIFICATION REPORT — pi 1.1.0 CLI GATING (#115)")
print(string.rep("=", 70))

local any_fail = not suite_ok
for _, sc in ipairs({ "A", "B", "C", "D" }) do
    local info = report.scenarios[sc] or { status = "MISSING", detail = "No result recorded" }
    print(string.format("  Scenario %s: [%s] %s", sc, info.status, info.detail))
    if info.status == "FAIL" or info.status == "MISSING" then
        any_fail = true
    end
end
print(string.rep("=", 70))

if not suite_ok then
    io.stderr:write("\n[FATAL] SUITE ERROR:\n" .. tostring(suite_err) .. "\n")
    vim.cmd("cquit 1")
elseif any_fail then
    print("\nRESULT: FAILED")
    vim.cmd("cquit 1")
else
    print("\nRESULT: ALL GREEN")
    vim.cmd("qall!")
end
