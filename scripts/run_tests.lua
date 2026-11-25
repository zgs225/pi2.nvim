-- Bounded-concurrency runner for tests/*_spec.lua (used by `make test`).
--
-- Why not `plenary.test_harness.test_directory`? It spawns ONE child nvim per
-- spec file and joins them all at once (`Job.join(unpack(jobs))`), so the suite
-- runs ~170 headless editors simultaneously with no cap. On a laptop that
-- occasionally kills children (a file prints `Testing:` and never a summary —
-- G33's silent kill) and it makes every wall-clock assertion flaky: the RPC
-- reassembly perf guard, a replay-path spec and a batch-settle poll all failed
-- only in the full run and passed standalone. A CI runner has fewer cores than
-- that, so a gate built on it would be red at random.
--
-- This runner keeps the two properties the gate needs:
--   * EXIT CODE PER FILE is the assertion (G25): plenary's `:PlenaryBustedFile`
--     exits 0 on success and 1 on any failure, so nothing parses coloured output;
--   * output is aligned — a passing file is one line, a failing file echoes its
--     own log, so a red run names the spec instead of interleaving 170 streams.
-- Running zero files is a failure, not a pass (a runner that matches nothing
-- must never report green).
--
-- Usage (from `make test`, which supplies the env):
--   NVIM_BIN=nvim MIN_INIT=tests/minimal_init.lua TEST_JOBS=8 \
--     nvim --headless -u NONE -l scripts/run_tests.lua
--
-- Env:
--   TEST_JOBS    concurrent children (default 8)
--   TEST_FILTER  glob for a subset, e.g. TEST_FILTER='tests/prompt_*_spec.lua'
--   NVIM_BIN     nvim to spawn (default: this nvim)
--   MIN_INIT     the hermetic init for the children (default tests/minimal_init.lua)
--   TEST_RUN_DIR run dir to hand the children (default: a generated path without a
--                `/run/` component — see the probe below, G34)

local uv = vim.uv

--- Repo root, resolved from this script's own path (worktree-safe: G23).
---@return string
local function repo_root()
    local src = debug.getinfo(1, "S").source:sub(2)
    return vim.fn.fnamemodify(src, ":p:h:h")
end

local root = repo_root()
local nvim_bin = vim.env.NVIM_BIN or vim.v.progpath
local min_init = vim.env.MIN_INIT or (root .. "/tests/minimal_init.lua")
local jobs = tonumber(vim.env.TEST_JOBS or "") or 8
if jobs < 1 then
    jobs = 1
end
-- Per-child budget. plenary's own per-file timeout only exists inside
-- `test_directory`; a child spawned here that hangs would otherwise hold the
-- whole gate (and a CI job) until the job timeout with no diagnosis.
local child_timeout_ms = (tonumber(vim.env.TEST_TIMEOUT or "") or 300) * 1000
-- The children must be spawned EXACTLY the way plenary's own harness spawns
-- them (`test_harness.lua`): `--noplugin`, `-u <minimal_init>`, then
-- `set rtp+=.,<plenary> | runtime plugin/plenary.vim` and a direct
-- `plenary.busted.run(<abs path>)`. `:PlenaryBustedFile` looks equivalent and is
-- not: two specs (`session_cwd_diff_spec`, `subsession_workspace_spec`) change
-- cwd and then `require("pi.…")` from a write autocmd, which fails in that
-- environment and passes in this one — the suite was written against the
-- harness invocation, so reproduce it rather than inventing a second one.
local plenary_dir = vim.env.PLENARY_PATH or vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")
local filter = vim.env.TEST_FILTER

-- Run-dir probe (G34): no spec may assume where `stdpath("run")` points. It is
-- `/run/user/<uid>/nvim…` on a systemd Linux box and
-- `$TMPDIR/nvim.<user>/<random>` on macOS (or wherever the user put
-- `$XDG_RUNTIME_DIR`), so a spec that asserts the first shape passes in CI and is
-- red only on the author's laptop — which is exactly how
-- `tests/compaction_extension_spec.lua` shipped an `assert.matches("[/\\]run[/\\]")`
-- assertion. Every child therefore runs with an `XDG_RUNTIME_DIR` whose path has
-- no `/run/` component, so the same assumption fails on Linux, in CI, before the
-- push. The static half of this gate is `make check`'s `spec-host-layout`; this
-- half also catches the shapes a matcher cannot see (a path built at runtime, an
-- expectation derived through another module).
--
-- Two measured facts shaped this: Neovim does NOT create `XDG_RUNTIME_DIR` (with
-- it set but absent, `stdpath("run")` is that path and `isdirectory()` is 0), so
-- the harness creates it here; and `TEST_RUN_DIR` overrides the generated path
-- explicitly rather than falling back to the real dir, because a gate that
-- silently checks nothing is the failure mode the probe exists to prevent.
local run_dir = vim.env.TEST_RUN_DIR or (vim.fn.tempname() .. "-xdg-runtime")
if vim.fn.isdirectory(run_dir) == 0 then
    vim.fn.mkdir(run_dir, "p")
end
if vim.fn.isdirectory(run_dir) == 0 then
    io.stderr:write("run_tests: cannot create the run-dir probe at " .. run_dir .. "\n")
    vim.cmd("cq 1")
end
vim.env.XDG_RUNTIME_DIR = run_dir
local owns_run_dir = vim.env.TEST_RUN_DIR == nil

---@return string[] sorted absolute spec paths
local function collect()
    local pattern = root .. "/" .. (filter or "tests/*_spec.lua")
    local files = vim.fn.glob(pattern, false, true)
    table.sort(files)
    return files
end

local files = collect()
if #files == 0 then
    io.stderr:write("run_tests: no spec files matched " .. (filter or "tests/*_spec.lua") .. "\n")
    vim.cmd("cq 1")
end

local started = uv.hrtime()
local total = #files
local next_index = 1
local done = 0
local failed = {}
---@type table<string, { child: vim.SystemObj?, started: integer, killed: boolean }>
local handles = {}

---@param path string
---@return string relative to the repo root, for a readable line
local function rel(path)
    return (path:gsub("^" .. vim.pesc(root) .. "/", ""))
end

---@param path string
local function start_one(path)
    -- The record exists before the spawn so the sweeper and the exit handler
    -- agree on `killed`; a SIGKILLed child reports `code = 0` with a non-zero
    -- `signal`, which is why the exit verdict below cannot look at `code` alone.
    local rec = { started = uv.hrtime(), killed = false }
    handles[path] = rec

    rec.child = vim.system({
        nvim_bin,
        "--headless",
        "--noplugin",
        "-u",
        min_init,
        "-c",
        "set rtp+=.," .. plenary_dir .. " | runtime plugin/plenary.vim",
        "-c",
        string.format('lua require("plenary.busted").run("%s")', (path:gsub("\\", "\\\\"))),
    }, {
        cwd = root,
        text = true,
    }, function(out)
        done = done + 1
        local name = rel(path)
        local signal = out.signal or 0
        local bad = out.code ~= 0 or signal ~= 0 or rec.killed
        if bad then
            local why = rec.killed and "killed after the timeout" or string.format("exit %d", out.code)
            if signal ~= 0 then
                why = string.format("%s, signal %d", why, signal)
            end
            failed[#failed + 1] = { name = name, why = why, out = out }
            io.write(string.format("[FAILED] %s (%s)\n", name, why))
        else
            io.write(string.format("ok       %s\n", name))
        end
        io.flush()
        handles[path] = nil
        if next_index <= total then
            local nxt = files[next_index]
            next_index = next_index + 1
            start_one(nxt)
        end
    end)
end

-- Sweep for a child that never exits: kill it and let its exit handler report
-- the failure (a killed child exits non-zero, so it lands in `failed`).
local sweeper = uv.new_timer()
sweeper:start(5000, 5000, function()
    local now = uv.hrtime()
    for path, h in pairs(handles) do
        if not h.killed and (now - h.started) / 1e6 > child_timeout_ms then
            h.killed = true
            io.stderr:write(
                string.format(
                    "run_tests: %s exceeded %ds, killing it\n",
                    rel(path),
                    math.floor(child_timeout_ms / 1000)
                )
            )
            io.stderr:flush()
            pcall(function()
                h.child:kill(9)
            end)
        end
    end
end)

io.write(string.format("run_tests: %d spec files, %d at a time\n", total, jobs))
io.write(string.format("run_tests: run dir %s (no /run/ component — a spec may not assume one, G34)\n", run_dir))
io.flush()

for _ = 1, math.min(jobs, total) do
    local path = files[next_index]
    next_index = next_index + 1
    start_one(path)
end

-- Pump the loop until every child has reported.
vim.wait(0, function()
    return done >= total
end, 100)
-- vim.wait(0, …) only pumps once; loop explicitly so the driver stays dumb.
while done < total do
    vim.wait(1000, function()
        return done >= total
    end, 50)
end

sweeper:stop()
sweeper:close()

local elapsed = (uv.hrtime() - started) / 1e9
io.write(
    string.format("\nrun_tests: %d files, %d passed, %d failed, %.1fs\n", total, total - #failed, #failed, elapsed)
)

for _, f in ipairs(failed) do
    io.write(string.format("\n===== %s (%s) =====\n", f.name, f.why))
    local lines = vim.split((f.out.stdout or "") .. (f.out.stderr or ""), "\n", { plain = true })
    local from = math.max(1, #lines - 80)
    for i = from, #lines do
        io.write(lines[i], "\n")
    end
end
io.flush()

if owns_run_dir then
    pcall(vim.fn.delete, run_dir, "rf")
end

vim.cmd("cq " .. (#failed > 0 and 1 or 0))
