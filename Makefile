# pi.nvim development helpers.
#
#   make test    — run the plenary unit test suite (hermetic, -u tests/minimal_init.lua)
#   make check   — static gates: LuaJIT parse (G24) + docs sync; `check-selftest`
#                  proves each gate can still fail. Needs `luajit` (mise install)
#                  and python3; see .mise.toml.
#   make e2e     — run headless end-to-end scripts (tests/*_e2e.lua)
#   make e2e-reaper — real-pi e2e: subagent idle reaper + max_children cap (needs pi binary + provider; not CI)
#   make e2e-bg-delivery — real-pi e2e: background bash completion delivery into agent context (needs pi + provider; not CI)
#   make e2e-subagent-failure — real-pi e2e: a failed child run reaches the parent as a failed item (needs pi; not CI)
#   make smoke   — headless end-to-end smoke check (loads the user config, opens the chat)
#   make format  — reformat in place: stylua (Lua) + ruff format (Python under scripts/)
#   make style   — check formatting only (stylua --check + ruff format --check); for CI/hooks
#   make lint    — static analysis: lua-language-server over lua/ + ruff check over scripts/
#   make docs-links — validate relative links and anchors in README.md and doc/*.md
#
# The suite is intentionally runnable without the user's full Neovim config so
# it stays fast and deterministic; PLENARY_PATH overrides the plenary location.

NVIM_BIN ?= nvim
PYTHON_BIN ?= python3
LUAJIT_BIN ?= luajit
PLENARY_PATH ?= $(HOME)/.local/share/nvim/lazy/plenary.nvim
MIN_INIT := tests/minimal_init.lua
STYLUA_BIN ?= stylua
LUA_LS_BIN ?= lua-language-server
RUFF_BIN ?= ruff

export LUAJIT_BIN

.PHONY: test smoke format style lint docs-links check check-selftest check-list parse e2e e2e-reaper e2e-bg-delivery e2e-subagent-failure

test:
	PLENARY_PATH=$(PLENARY_PATH) $(NVIM_BIN) --headless -u $(MIN_INIT) \
		-c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = '$(MIN_INIT)' })"

e2e:
	@for f in tests/*_e2e.lua; do \
		echo "e2e: $$f"; \
		$(NVIM_BIN) --headless -u $(MIN_INIT) -l $$f || exit 1; \
	done

# Real end-to-end against `pi --mode rpc` + live provider calls (scripts/e2e/).
# Deliberately excluded from CI and `make test`: needs the pi binary and a
# configured provider. See .agents/skills/develop/references/testing.md.
e2e-reaper:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/reaper.lua

# Real-pi e2e for the background bash delivery ladder (idle wake / turn
# boundary / aborted run / aggregation). Needs the pi binary + a provider, so it
# stays out of CI and `make test`.
e2e-bg-delivery:
	$(NVIM_BIN) --headless -u $(MIN_INIT) -l scripts/e2e/bg_tasks_delivery.lua

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
lint:
	$(LUA_LS_BIN) --check lua --configpath $(CURDIR)/.luarc.json --loglevel error
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
# Neovim stable". Any LuaJIT 2.1 build works; mise pins one for parity.
parse:
	$(PYTHON_BIN) -m scripts.checks --only parse-luajit
