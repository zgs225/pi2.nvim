# pi.nvim development helpers.
#
#   make test    — run the plenary unit test suite (hermetic, -u tests/minimal_init.lua)
#   make e2e     — run headless end-to-end scripts (tests/*_e2e.lua)
#   make e2e-reaper — real-pi e2e: subagent idle reaper + max_children cap (needs pi binary + provider; not CI)
#   make e2e-bg-delivery — real-pi e2e: background bash completion delivery into agent context (needs pi + provider; not CI)
#   make e2e-bg-stop — real-pi e2e: stop_task kills the process group, list_tasks sees it (needs pi; fake provider, no account)
#   make e2e-bg-reconcile — real-pi e2e: the task table survives a SIGKILLed pi and is adopted by the next run (needs pi; fake provider)
#   make e2e-bg-stdin — real-pi e2e: a background task keeps its stdin and task_input feeds it (needs pi; fake provider)
#   make e2e-bg-report — real-pi e2e: a completion report is one structured `<background-task>` block (needs pi; fake provider)
#   make e2e-bg-fallback — real-pi e2e: BOTH fallback scenarios — a failed injection retried until the request succeeds, and a run that gives up delivering it yet still wakes with the report (needs pi; fake provider)
#   make e2e-bg-wake — real-pi e2e: two same-tick completions send ONE coalesced wake naming both tasks (needs pi; fake provider)
#   make e2e-bg-wake-gate — real-pi e2e: a held completion starts no turn, says why, and rides the next prompt exactly once (needs pi; fake provider)
#   make e2e-bg-deadline — real-pi e2e: deadline_ms and the lifetime cap send ONE notify-only check-in each, no kill (needs pi; fake provider)
#   make e2e-bg-ownership — real-pi e2e: a fork does not adopt the parent's tasks, a clean quit records its kills
#   make e2e-subagent-failure — real-pi e2e: a failed child run reaches the parent as a failed item (needs pi; not CI)
#   make smoke   — headless end-to-end smoke check (loads the user config, opens the chat)
#   make format  — reformat lua/ and tests/ in place with stylua
#   make style   — check formatting only (stylua --check); non-zero exit on drift, for CI/hooks
#   make lint    — static/type check lua/ with lua-language-server (--check); non-zero on problems
#   make docs-links — validate relative links and anchors in README.md and doc/*.md
#
# The suite is intentionally runnable without the user's full Neovim config so
# it stays fast and deterministic; PLENARY_PATH overrides the plenary location.

NVIM_BIN ?= nvim
PLENARY_PATH ?= $(HOME)/.local/share/nvim/lazy/plenary.nvim
MIN_INIT := tests/minimal_init.lua
STYLUA_BIN ?= stylua
LUA_LS_BIN ?= lua-language-server

.PHONY: test smoke format style lint docs-links e2e e2e-reaper e2e-bg-delivery e2e-bg-stop e2e-bg-reconcile e2e-bg-stdin e2e-bg-report e2e-bg-fallback e2e-bg-wake e2e-bg-wake-gate e2e-bg-deadline e2e-bg-ownership e2e-subagent-failure

test:
	PLENARY_PATH=$(PLENARY_PATH) $(NVIM_BIN) --headless -u $(MIN_INIT) \
		-c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = '$(MIN_INIT)' })"

e2e:
	@for f in tests/*_e2e.lua; do \
		echo "e2e: $$f"; \
		$(NVIM_BIN) --headless -u $(MIN_INIT) -l $$f || exit 1; \
	done

# Real end-to-end against `pi --mode rpc` (scripts/e2e/). None of these are part
# of `make test`. The eight background-task suites that drive a scripted FAKE
# provider run in CI (.github/workflows/e2e.yml); the ones that need a real
# provider stay manual. See .agents/skills/develop/references/testing.md.
e2e-reaper:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/reaper.lua

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

# Real-pi e2e for the idle-wake COST GATE: a completion that would otherwise
# start its own turn is held (`never`, or a spent budget), the hold is announced
# with its reason, the report is not persisted or woken, and it rides the next
# user prompt exactly once. Needs the pi binary only — runs in CI.
e2e-bg-wake-gate:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_wake_gate.lua

# Real-pi e2e for the two NOTIFY-ONLY timers: `deadline_ms` sends ONE
# `check_in="deadline"` message (with an output tail) before the task's exit
# report, the `PI_BG_TASK_MAX_LIFETIME_MS` cap sends ONE `check_in="lifetime"`
# note, and each task still exits `completed` / `exit_code="0"` — neither timer
# kills anything. Needs the pi binary only — runs in CI.
e2e-bg-deadline:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_deadline.lua

# Real-pi e2e for ownership: fork inheritance and the clean-quit shutdown record.
# Needs the pi binary only — runs in CI.
e2e-bg-ownership:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_ownership.lua

# Real-pi e2e for a failed child run (quota/auth/network error) surfacing as a
# failed batch item with the provider reason instead of an empty `ok`. Uses a
# local fake provider, so it needs the pi binary but no account/quota.
e2e-subagent-failure:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/subagent_failure.lua

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

style:
	$(STYLUA_BIN) --check .

# lua-language-server exits non-zero when diagnostics are found, so this gates
# directly. Config is .luarc.json (portable: bundled luv types only; vim runtime
# types are intentionally not loaded so the check is environment-independent).
lint:
	$(LUA_LS_BIN) --check lua --configpath $(CURDIR)/.luarc.json --loglevel error

docs-links:
	python3 scripts/check_docs_links.py
