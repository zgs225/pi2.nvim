# pi.nvim development helpers.
#
#   make test    — run the plenary spec suite via `scripts/run_tests.lua` (hermetic,
#                  -u tests/minimal_init.lua for every child).
#                  This is the CI unit gate (`.github/workflows/tests.yml`, pushed to
#                  main + every PR, judged by exit code only).
#                  Concurrency is CAPPED (`TEST_JOBS`, default 8): plenary's
#                  `test_directory` spawns one child nvim per spec file and joins
#                  them all at once, which at ~170 files kills children and makes
#                  every wall-clock assertion flaky. tests/worktree_git_spec.lua
#                  alone spends ~50 s on real git commits, so the per-child budget
#                  is `TEST_TIMEOUT` (default 300 s), not plenary's 50 s default.
#                  `TEST_FILTER=tests/prompt_*_spec.lua` runs a subset.
#                  render-markdown.nvim is OPTIONAL (RENDER_MARKDOWN_PATH): the
#                  render-contract spec skips itself when the checkout is missing.
#   make check   — static gates: LuaJIT parse (G24) + docs sync; `check-selftest`
#                  proves each gate can still fail. Needs `luajit` (mise install)
#                  and python3; see .mise.toml.
#   make e2e     — run headless end-to-end scripts (tests/*_e2e.lua). Runs EVERY
#                  script, prints each one's exit code, and fails only at the end:
#                  a first-failure abort hid a broken assertion for a month
#                  (Gitea #121), so triage is driven by the summary now
#   make e2e-reaper — real-pi e2e: subagent idle reaper + max_children cap (needs pi binary + provider; not CI)
#   make e2e-worktrees — real-git e2e: worktree create/apply/remove/ship/release (needs pi binary; no provider calls)
#   make e2e-bg-delivery — real-pi e2e: background bash completion delivery into agent context (needs pi + provider; not CI)
#   make e2e-bg-stop — real-pi e2e: stop_task kills the process group, list_tasks sees it (needs pi; fake provider, no account)
#   make e2e-bg-reconcile — real-pi e2e: the task table survives a SIGKILLed pi and is adopted by the next run (needs pi; fake provider)
#   make e2e-bg-stdin — real-pi e2e: a background task keeps its stdin and task_input feeds it (needs pi; fake provider)
#   make e2e-bg-report — real-pi e2e: a completion report is one structured `<background-task>` block (needs pi; fake provider)
#   make e2e-bg-fallback — real-pi e2e: BOTH fallback scenarios — a failed injection retried until the request succeeds, and a run that gives up delivering it yet still wakes with the report (needs pi; fake provider)
#   make e2e-bg-wake — real-pi e2e: two same-tick completions send ONE coalesced wake naming both tasks (needs pi; fake provider)
#   make e2e-bg-wake-gate — real-pi e2e: a held completion starts no turn, says why, and rides the next prompt exactly once (needs pi; fake provider)
#   make e2e-bg-deadline — real-pi e2e: deadline_ms and the lifetime cap send ONE notify-only check-in each, no kill (needs pi; fake provider)
#   make e2e-bg-until — real-pi e2e: wait_task(until) returns on a printed line, the exit report still arrives once (needs pi; fake provider)
#   make e2e-bg-logs — real-pi e2e: the startup log sweep removes only stale, unknown pi-bash logs (needs pi; fake provider)
#   make e2e-bg-ownership — real-pi e2e: a fork does not adopt the parent's tasks, a clean quit records its kills
#   make e2e-subagent-failure — real-pi e2e: a failed child run reaches the parent as a failed item (needs pi; not CI)
#   make e2e-subagent-worktree — real-pi e2e: a spawn item's assigned worktree is the child's real cwd (needs pi; not CI)
#   make smoke   — headless end-to-end smoke check (loads the user config, opens the chat)
#   make format  — reformat in place: stylua (Lua) + ruff format (Python under scripts/)
#   make style   — check formatting only (stylua --check + ruff format --check); for CI/hooks
#   make lint    — static analysis: lua-language-server over lua/ (strict, .luarc.json)
#                  + tests/ and scripts/e2e/ (.luarc-tests.json, narrower) + ruff check over scripts/
#   make docs-links — validate relative links and anchors in README.md and doc/*.md
#
# The suite is intentionally runnable without the user's full Neovim config so
# it stays fast and deterministic; PLENARY_PATH overrides the plenary location.

NVIM_BIN ?= nvim
PYTHON_BIN ?= python3
LUAJIT_BIN ?= luajit
PLENARY_PATH ?= $(HOME)/.local/share/nvim/lazy/plenary.nvim
# OPTIONAL: render-markdown.nvim, used only by tests/render_contract_spec.lua.
# When the checkout is absent, minimal_init skips it and that spec skips itself.
RENDER_MARKDOWN_PATH ?= $(HOME)/.local/share/nvim/lazy/render-markdown.nvim
# OPTIONAL locally, REQUIRED in CI: telescope.nvim, used only by
# tests/resume_partitions_e2e.lua — the one layer that renders the resume picker
# with the REAL picker. A missing checkout makes that script exit 3 (skipped); the
# `e2e` CI job installs the pinned checkout and sets PI_E2E_REQUIRE_DEPS=1, which
# turns the same absence into exit 2 (failure) instead of a false green (#125).
TELESCOPE_PATH ?= $(HOME)/.local/share/nvim/lazy/telescope.nvim
MIN_INIT := tests/minimal_init.lua
# Concurrent child editors for `make test` (see scripts/run_tests.lua). Raise it
# locally for speed; CI keeps it low so timing-sensitive specs are not raced.
TEST_JOBS ?= 8
# Per-child budget in seconds; a child that hangs is killed and reported red.
TEST_TIMEOUT ?= 300
STYLUA_BIN ?= stylua
LUA_LS_BIN ?= lua-language-server
RUFF_BIN ?= ruff

export LUAJIT_BIN

.PHONY: test smoke format style lint docs-links check check-selftest check-list parse e2e e2e-reaper e2e-worktrees e2e-bg-delivery e2e-bg-stop e2e-bg-reconcile e2e-bg-stdin e2e-bg-report e2e-bg-ownership e2e-subagent-failure e2e-subagent-worktree e2e-bg-fallback e2e-bg-wake e2e-bg-wake-gate e2e-bg-deadline e2e-bg-until e2e-bg-logs

test:
	PLENARY_PATH=$(PLENARY_PATH) RENDER_MARKDOWN_PATH=$(RENDER_MARKDOWN_PATH) \
		NVIM_BIN=$(NVIM_BIN) MIN_INIT=$(MIN_INIT) TEST_JOBS=$(TEST_JOBS) TEST_TIMEOUT=$(TEST_TIMEOUT) \
		$(NVIM_BIN) --headless -u NONE -l scripts/run_tests.lua

# Every script runs; the summary — never a single script's line — is the verdict.
# Exit codes are the protocol (`tests/e2e_deps.lua`): 0 pass, 1 assertion failure,
# 2 a prerequisite is missing in gate mode (`PI_E2E_REQUIRE_DEPS=1`), 3 skipped
# locally. A skip is counted and named, never folded into "passed": the `e2e` CI
# job sets the gate mode, so a script that goes dark there fails the job (#125).
e2e:
	@failed=0; skipped=0; total=0; \
	for f in tests/*_e2e.lua; do \
		total=$$((total + 1)); \
		printf '%s\n' "e2e: $$f"; \
		TELESCOPE_PATH=$(TELESCOPE_PATH) PLENARY_PATH=$(PLENARY_PATH) \
			$(NVIM_BIN) --headless -u $(MIN_INIT) -l $$f; \
		code=$$?; \
		printf '%s\n' "e2e: $$f exit=$$code"; \
		if [ $$code -eq 3 ]; then skipped=$$((skipped + 1)); \
		elif [ $$code -ne 0 ]; then failed=$$((failed + 1)); fi; \
	done; \
	if [ $$failed -ne 0 ]; then \
		printf 'e2e: %d of %d script(s) FAILED, %d SKIPPED\n' "$$failed" "$$total" "$$skipped"; \
		exit 1; \
	fi; \
	if [ $$skipped -ne 0 ]; then \
		printf 'e2e: %d of %d script(s) passed, %d SKIPPED — a skip is not a pass (CI sets PI_E2E_REQUIRE_DEPS=1)\n' \
			"$$((total - skipped))" "$$total" "$$skipped"; \
		exit 0; \
	fi; \
	printf 'e2e: all %d script(s) passed\n' "$$total"

# Real end-to-end against `pi --mode rpc` (scripts/e2e/). None of these are part
# of `make test`. The nine background-task suites that drive a scripted FAKE
# provider run in CI (.github/workflows/e2e.yml); the ones that need a real
# provider stay manual. See .agents/skills/develop/references/testing.md.
e2e-reaper:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/reaper.lua

e2e-worktrees:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/worktrees.lua

# Real-pi e2e for the background bash delivery ladder (idle wake / turn
# boundary / aborted run / aggregation). Needs the pi binary + a provider, so it
# stays out of CI and `make test`.
e2e-bg-delivery:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_delivery.lua

# Real-pi e2e for `stop_task` / `list_tasks`: a scripted fake provider drives the
# real extension against a real process tree. Needs the pi binary only — runs in
# CI.
e2e-bg-stop:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_stop.lua

# Real-pi e2e for the task-table snapshot: run pi, start a background task, SIGKILL
# pi, then start pi again on the same session and let it adopt the orphan.
# Needs the pi binary only — runs in CI.
e2e-bg-reconcile:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_reconcile.lua

# Real-pi e2e for stdin: a background shell reads a line, `task_input` writes it.
# Needs the pi binary only — runs in CI.
e2e-bg-stdin:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_stdin.lua

# Real-pi e2e for the shape of a completion report: the banner, the
# `<system-reminder>` / `<background-task …>` block, its attributes, and that the
# model's next request actually carries it. Needs the pi binary only — runs in CI.
e2e-bg-report:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_report.lua

# Real-pi e2e for the last-resort `context` fallback: a report injected into a
# request that then fails with a 5xx must be injected AGAIN on the retry and be
# confirmed only by the attempt that completes. Needs the pi binary only — runs
# in CI.
e2e-bg-fallback:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_fallback.lua

# Real-pi e2e for the coalesced idle wake: two completions in one tick must
# send ONE report naming both tasks and start ONE turn. Needs the pi binary only
# — runs in CI.
e2e-bg-wake:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_wake.lua

# Real-pi e2e for the completion-wake COST GATE: a completion that would
# otherwise buy a turn — while idle, or at the final answer's boundary — is held
# (`never`, a spent budget, or the per-run continuation cap), the hold is
# announced with its reason, and the report rides the next user prompt exactly
# once. Needs the pi binary only — runs in CI.
e2e-bg-wake-gate:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_wake_gate.lua

# Real-pi e2e for the two NOTIFY-ONLY timers: `deadline_ms` sends ONE
# `check_in="deadline"` message (with an output tail) before the task's exit
# report, the `PI_BG_TASK_MAX_LIFETIME_MS` cap sends ONE `check_in="lifetime"`
# note, and each task still exits `completed` / `exit_code="0"` — neither timer
# kills anything. Needs the pi binary only — runs in CI.
e2e-bg-deadline:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_deadline.lua

# Real-pi e2e for the conditional wait: `wait_task({ until = … })` returns on a
# literal line with the process still running, that match does NOT consume the
# task's exit report (it still arrives, exactly once), and a needle that never
# appears times out without a kill. Needs the pi binary only — runs in CI.
e2e-bg-until:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_until.lua

# Real-pi e2e for the log lifetime: the sweep at session start deletes ONLY stale
# `pi-bash-b<hex>.log` files this process does not know about — a fresh unknown
# one, a non-hex id and a foreign name all survive, and a task this process
# started keeps its log both while running and after it exits. TMPDIR is
# redirected into the run root so it can never touch real /tmp logs. Needs the pi
# binary only — runs in CI.
e2e-bg-logs:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_logs.lua

# Real-pi e2e for ownership: fork inheritance and the clean-quit shutdown record.
# Needs the pi binary only — runs in CI.
e2e-bg-ownership:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_ownership.lua

# Real-pi e2e for a failed child run (quota/auth/network error) surfacing as a
# failed batch item with the provider reason instead of an empty `ok`. Uses a
# local fake provider, so it needs the pi binary but no account/quota.
e2e-subagent-failure:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/subagent_failure.lua

# Real-pi e2e for a spawn item that assigns an existing linked worktree: a real
# child process must really run in that checkout (model-driven sentinel + RPC
# pwd), the manifest must record the assignment, close must keep the checkout,
# and a deleted checkout must fail a revive closed. Uses a local fake provider,
# so it needs the pi binary but no account/quota.
e2e-subagent-worktree:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/subagent_worktree.lua

smoke:
	$(NVIM_BIN) --headless -u $(HOME)/.config/nvim/init.lua -l scripts/smoke.lua

# NOTE: stylua's built-in default indent is Tabs; .stylua.toml pins the 4-space
# convention used here, so always format through this target (or `stylua .` with
# the config present), never a bare `stylua` invocation that ignores the config.
#
# Runs stylua twice: 2.5.2 is not single-pass idempotent on some constructs
# (e.g. `require "x"` -> `require("x")` changes line width and triggers a
# re-wrap), so a second pass is needed to reach the stable fixed point that
# `make style` checks against.
format:
	$(STYLUA_BIN) .
	$(STYLUA_BIN) .
	$(RUFF_BIN) format scripts
	$(RUFF_BIN) check --fix scripts

# Formatting only. Ruff sees `scripts/` — the check harness itself, which had no
# gate at all before ruff (stylua only reads Lua, lua-language-server only reads
# lua/). Config: ruff.toml.
style:
	$(STYLUA_BIN) --check .
	$(RUFF_BIN) format --check scripts

# lua-language-server exits non-zero when diagnostics are found, so this gates
# directly. Config is .luarc.json (portable: bundled luv types only; vim runtime
# types are intentionally not loaded so the check is environment-independent).
# ruff check is the analysis half for Python (imports, unused names, bug patterns).
# lua/ is checked with the full diagnostic set (.luarc.json), while tests/ and
# scripts/e2e/ are checked with .luarc-tests.json, a documented narrower set
# (busted/plenary globals; the diagnostic classes that are pure harness noise are
# disabled there) — because those trees ship nothing and are run only by a
# developer's Neovim, so their annotations must not be held to library quality.
lint:
	$(LUA_LS_BIN) --check lua --configpath $(CURDIR)/.luarc.json --loglevel error
	$(LUA_LS_BIN) --check tests --configpath $(CURDIR)/.luarc-tests.json --loglevel error
	$(LUA_LS_BIN) --check scripts/e2e --configpath $(CURDIR)/.luarc-tests.json --loglevel error
	$(RUFF_BIN) check scripts

docs-links:
	$(PYTHON_BIN) scripts/check_docs_links.py

# Static gates that can be decided by a machine (scripts/checks/): the LuaJIT
# parse gate, docs sync, and every rule added later. `check-selftest` proves the
# gates can still fail (fixtures), which is the guard against a check that
# reports green because it never matches anything.
check:
	$(PYTHON_BIN) -m scripts.checks

check-selftest:
	$(PYTHON_BIN) -m scripts.checks --self-test

check-list:
	$(PYTHON_BIN) -m scripts.checks --list

# LuaJIT syntax gate alone (G24): the cheapest way to answer "does this load on
# Neovim stable". The binary is probed first — a build that accepts Lua 5.3
# syntax is refused with exit 2 instead of reporting green — so any LuaJIT 2.1
# build works exactly when it passes that probe; mise pins one for parity.
parse:
	$(PYTHON_BIN) -m scripts.checks --only parse-luajit
