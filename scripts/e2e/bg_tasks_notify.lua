-- Headless e2e: bg-tasks completion notification reaches the frontend promptly.
--
-- Drives the REAL stack end to end — the plugin spawns a real `pi --mode rpc`
-- with the bundled `extensions/bg-tasks.ts` injected, a real background bash
-- task runs, and the terminal `pi2_bg_task` event must be routed through
-- sessions/manager.lua into the `pi.tasks` registry (and the panel row
-- builder) at process exit, not delayed behind an agent run.
--
-- Steps:
--   S1  open session            -> chat buffers + live RPC backend
--   S2  bg task via RPC bash    -> `started` event lands in pi.tasks as
--       (&-prefix, no LLM)         "running" promptly
--   S3  task exits (sleep 2)    -> pi.tasks row turns "done", exit_code 0,
--       with the agent idle        within a few seconds of the send, i.e. at
--                                  process exit (the old followUp-only path
--                                  was also fast here; the latency-vs-run
--                                  discrimination is covered by the
--                                  RPC-level A/B e2e — this script verifies
--                                  the full lua routing and panel rows)
--   S4  panel rows              -> build_rows() exposes the terminal row with
--                                  status_label "done"; no running tasks left
--
-- Needs the pi binary + a configured provider (the followUp wake report
-- triggers one cheap agent turn at idle; we wait for it before teardown).
-- NOT part of `make test`/CI. Run from a throwaway cwd so the session file
-- the backend writes lands under /tmp, not a real project:
--
--   cd /tmp/<run-dir> && nvim --headless -u <worktree>/tests/minimal_init.lua \
--       -l <worktree>/scripts/e2e/bg_tasks_notify.lua

local uv = vim.uv

local Tasks = require("pi.tasks")
local Sessions = require("pi.sessions.manager")

io.stdout:setvbuf("no")
local run_started = uv.hrtime()
local last_step = run_started

---@return number elapsed seconds since the previous step marker
local function step(name)
	local t = uv.hrtime()
	print(string.format("[step] %-52s +%6.2fs (total %7.2fs)", name, (t - last_step) / 1e9, (t - run_started) / 1e9))
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

local function ft_bufs()
	return vim.tbl_map(function(b)
		return vim.bo[b].filetype
	end, vim.api.nvim_list_bufs())
end

local function main()
	-- S1: open the session. The plugin spawns the pi backend with cwd = nvim's
	-- cwd (the caller runs this from /tmp), so the transcript it writes lands
	-- under a throwaway tree, not a real project.
	require("pi").show({ layout = "side" })
	check(vim.wait(15000, function()
		local fts = ft_bufs()
		return vim.tbl_contains(fts, "pi-chat-history") and vim.tbl_contains(fts, "pi-chat-prompt")
	end, 100), "S1 chat buffers exist (history + prompt)")
	local session = Sessions.get()
	check(session ~= nil, "S1 session created")
	step("S1 session up (chat buffers + RPC)")

	-- S2: start a background task through the REAL bash-command path. The `&`
	-- prefix routes via core's user_bash event into bg-tasks' background
	-- spawn — deterministic, no model call involved.
	local sent_at = uv.hrtime()
	local resp_done = false
	local resp_data = nil
	session.rpc:send({ type = "bash", command = "& sleep 2; echo BG_DONE" }, function(msg)
		resp_data = msg
		resp_done = true
	end)
	check(vim.wait(15000, function()
		return resp_done
	end, 100), "S2 bash command response arrived", { resp = resp_data and vim.inspect(resp_data, { newline = " ", indent = "" }) })
	check(type(resp_data) == "table" and resp_data.success ~= false, "S2 bash response success", { data = resp_data })
	step("S2 background task sent")

	-- The started event should have landed by now; pick up the newest task.
	---@type pi.Task|nil
	local task
	check(vim.wait(5000, function()
		local list = Tasks.list()
		task = list[1]
		return task ~= nil and task.status == "running"
	end, 50), "S2 task registered as running", { task = task })
	local started_lag_ms = (uv.hrtime() - sent_at) / 1e6
	check(started_lag_ms < 5000, "S2 started event landed promptly", { lag_ms = started_lag_ms })
	step("S2 started event routed into pi.tasks")

	-- S3: the row must flip to its terminal status at process exit (~2s sleep).
	-- Registry states are "completed"/"failed"/"stopped"; "done" is the panel label.
	check(vim.wait(12000, function()
		local current = Tasks.get(task.id)
		return current ~= nil and current.status == "completed"
	end, 50), "S3 task row terminal at exit", { task = task })
	local done_ms = (uv.hrtime() - sent_at) / 1e6
	check(done_ms < 8000, "S3 terminal event at process exit, not behind an agent run", { total_ms = done_ms })
	task = Tasks.get(task.id)
	check(task.exit_code == 0, "S3 exit code 0", { task = task })
	check(Tasks.has_running(nil) == false, "S3 no running tasks left", { rows = vim.inspect(Tasks.list()) })
	step("S3 task terminal — registry routed to done")

	-- S4: the panel's own row projection reflects it.
	local rows = Tasks.build_rows()
	local row = rows[1]
	check(row ~= nil, "S4 panel row present", { rows = vim.inspect(rows) })
	check(row.status_label == "done", "S4 panel row label done", { label = row.status_label })
	check(row.duration_ms ~= nil and row.duration_ms > 0, "S4 row duration measured", { duration_ms = row.duration_ms })
	step("S4 panel rows reflect terminal state")

	-- Teardown: the followUp wake report triggers one cheap agent turn (agent
	-- was idle); wait bounded for it to settle so VimLeavePre doesn't kill a
	-- mid-run backend and strand a half-written transcript.
	vim.wait(90000, function()
		local chat = session and session.chat
		return chat ~= nil and chat._streaming ~= true and chat._compacting ~= true
	end, 500)
	step("S5 agent settled (wake turn) — teardown")
	vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
	io.stderr:write("e2e bg_tasks_notify: " .. tostring(err) .. "\n")
	vim.cmd("cq 1")
end
