# Testing — the layers in depth

The repo ships `tests/minimal_init.lua` and a `Makefile` with `test` (hermetic plenary), `e2e` (the hermetic `tests/*_e2e.lua` scripts, also under `tests/minimal_init.lua`), `smoke` (headless boot of the user config + open the chat), plus the static gates `style`/`lint`/`check`/`docs-links` (stylua + ruff for formatting; lua-language-server over `lua/` strictly and `tests/` + `scripts/e2e/` with `.luarc-tests.json`, plus ruff for analysis; `scripts/checks/` for the LuaJIT/docs gates; all four gate CI — see `SKILL.md` § CI verification and `references/checks.md`). This file explains each runtime layer, the pitfalls unique to it, and how the `scripts/` templates sidestep them. Pick the cheapest layer that can observe the behavior; escalate only when it cannot.

**Before any layer:** run the static gates (`make check`, `make style`, `make lint`). They are seconds, they catch whole classes of defect (a LuaJIT parse error means the plugin does not load at all; a stale doc claim means the docs lie), and they are what CI will judge first.

## Layer 1 — Unit tests (hermetic plenary)

**What it's for:** pure Lua with no UI — stores, parsers, config resolution, pure transforms. Examples in repo: `tests/prompt_history_spec.lua`, `tests/draft_spec.lua`, `tests/render_spec.lua`, `tests/sanity_spec.lua`.

**How it runs:** `make test` → `scripts/run_tests.lua`, which spawns one headless nvim per `tests/*_spec.lua` with **capped concurrency** (`TEST_JOBS`, default 8) and exits non-zero if any child failed, was killed, or if no spec matched. `minimal_init.lua` prepends plenary + the repo root to `runtimepath` *without* loading the user's config, so each child is fast and deterministic. `PLENARY_PATH` overrides the plenary location. Because the repo root is resolved from `minimal_init.lua`'s **own file path**, this layer runs against the current **worktree's** code — it is worktree-safe (G23). It is also the **CI unit gate**: the `unit` job of `.github/workflows/tests.yml` runs `make test` on every push to `main` and on every PR, judged by **exit code only** (never by grepping the coloured output — G25) with a pinned toolchain (Neovim v0.12.6, plenary / render-markdown.nvim commits), because the specs assert version-specific behaviour. The same workflow's `e2e` job gates `make e2e` (Layer 2) under the same rule; nothing runs on the Gitea mirror, where Actions are disabled.

**`make test` knobs** (all env vars, all optional): `TEST_JOBS=12` for a faster local run; `TEST_FILTER='tests/prompt_*_spec.lua'` for a subset (also how you triage a red run); `TEST_TIMEOUT=600` for the per-child budget in seconds (default 300 — `tests/worktree_git_spec.lua` alone spends ~50 s on real git commits); `TEST_RUN_DIR=<path>` to hand the children a specific run dir. A child that overruns is killed and reported `[FAILED] <file> (killed after the timeout, signal 9)`, so a hang costs one file, not the whole job.

**The run-dir probe (G34).** Every child runs with `XDG_RUNTIME_DIR` set to a generated directory whose path contains no `/run/` component, so `stdpath("run")` is *not* `/run/user/<uid>/…` on any machine — the shape a systemd Linux box produces and macOS never does. That is what makes a spec which spells the Linux answer red here and in CI instead of only on the author's laptop (`tests/compaction_extension_spec.lua` shipped exactly that). The static half of the same rule is `make check`'s `spec-host-layout`, which reads the source; the probe catches the indirections the matcher cannot see. Neovim does not create `XDG_RUNTIME_DIR`, so the harness creates it; `TEST_RUN_DIR` is the explicit override, never a silent fallback to the real dir. The e2e layer (`make e2e`) is not probed — a run-dir assumption there is a `spec-host-layout` catch or nothing.

**Why a dedicated runner and not plenary's `test_directory`:** that helper starts **one child per spec file and joins them all at once**, so ~170 headless editors ran simultaneously. On a laptop that killed children outright and made every wall-clock assertion flaky — the RPC reassembly perf guard, a replay-path spec and a batch-settle poll each failed *only* in the full run and passed standalone. A CI gate built on that is red at random, which is the fake-green problem inverted. The reassembly perf guard stopped asserting a wall-clock bound at all for the same reason: it now calibrates against the machine it runs on, in the same process right before the assertion — it reassembles a 20 MB single-line response in 64 KB chunks and requires that time to stay within 5× a one-shot `vim.json.decode` of the very same line, the irreducible cost the chunked path also pays. A correct implementation measured 1.2×-1.7× that baseline; the O(n²) version measured ~43×. The old `ms < 800` bound went red on a *correct* linear implementation (913 ms) under the runner's parallel children, because a fixed millisecond budget asserts machine speed; a baseline taken back to back moves with the load. The runner keeps the same child environment (plenary reproduces it: `--noplugin -u minimal_init` plus `set rtp+=.,<plenary> | runtime plugin/plenary.vim` and a direct `plenary.busted.run(<abs path>)` — `:PlenaryBustedFile` is *not* equivalent, two cwd-changing specs fail under it) and adds bounding, per-file exit codes and aligned output.

**Rules / pitfalls:**
- `before_each` / `after_each` **must be inside a `describe`**. At the top level they silently no-op *and* the run exits non-zero (`make: Error 1`) with no clear message — the spec just never executes (G14). Always wrap.
- Make stateful modules testable: a `_reset()` to clear singletons and a path-override hook (`_set_path`) so tests use a `vim.fn.tempname()` file, never the real `stdpath`. See `draft.lua` / `prompt_history.lua`.
- Don't name a Makefile variable `NVIM` — nvim injects `$NVIM` (its server socket) into the environment and `?=` won't override it; use `NVIM_BIN` (G15).
- Assert with `assert.are.equal` / `assert.are.same` / `assert.is_nil` / `assert.is_true`. Keep each `it` focused on one behavior.
- **Budget every polled assertion for a loaded machine.** `make test` runs several spec files at once (`TEST_JOBS`, 8 by default, on a 4-vCPU CI runner), so a `vim.wait(…, pred, …)` window that is comfortable standalone is a flake in the full run — and CI sees only the flake. Use `vim.wait(10000, pred, 5)`, never 100–500 ms. `tests/render_contract_spec.lua` uses this for the async treesitter render (G9).
- **render-markdown.nvim is an *optional* test dependency.** `tests/minimal_init.lua` prepends it to `runtimepath` only when the checkout exists (`RENDER_MARKDOWN_PATH`, default `~/.local/share/nvim/lazy/render-markdown.nvim`), the `Makefile`'s `test` target exports that variable, and a spec that needs it skips itself with `pending()` when the checkout is absent — verified: `RENDER_MARKDOWN_PATH=/nonexistent` gives 2 successes + 4 pending and exit 0, and CI installs the pinned commit so "we cannot test this here" never silently reads as green. Plenary's child nvims run with `--noplugin`, so being on `runtimepath` is *not* the same as being loaded: a spec must call `require("render-markdown").setup{...}` and `require("render-markdown.core.manager").init()` itself (G8), and must set `Config.options.render.engine` **before** the chat opens, because the layout reads the engine when it creates the history window (G7).

**Template:** `scripts/unit_spec_template.lua`.

## Layer 2 — Headless end-to-end

**What it's for:** the real plugin loading under the real config, the real chat opening, the RPC backend spawning, buffer/extmark wiring, keymap *registration*, and method-level behavior — everything that doesn't need pixels or real key events.

**How it runs:** `nvim --headless -u ~/.config/nvim/init.lua -l script.lua`. The script drives `require("pi").show{layout="side"}`, `vim.wait(...)` for buffers, mutates buffers, calls chat methods, and exits `cq 0`/`cq 1`. `make smoke` is the minimal version of this, committed at `scripts/smoke.lua` (open the chat, assert the history/prompt buffers exist and the session's RPC backend process started). **Worktree caveat:** this boots the user's real config, so lazy loads pi from the **main checkout** (`~/.local/share/nvim/lazy/pi2.nvim`), not a feature worktree. To exercise worktree code headless, run the script under `-u tests/minimal_init.lua` instead (path-relative, worktree-safe); see G23.

**Real-binary e2e (`scripts/e2e/`).** Every one of these spawns a real `pi --mode rpc`; what differs is where the model answer comes from.

- **Fake provider → runs in CI** (`.github/workflows/e2e.yml`, one step per suite, targets `make e2e-bg-stop|stdin|report|panel|fallback|wake|wake-gate|deadline|until|reconcile|ownership|logs` — the list and the workflow's steps must stay in step: twelve suites, twelve steps): the script starts a **scripted OpenAI-compatible server** on 127.0.0.1, hands pi an isolated `PI_CODING_AGENT_DIR` with its own `models.json` and sets `PI_OFFLINE=1`, so there is no account, no quota and no model call. That hermeticity is the whole reason they can gate a PR. Assertions are behavioural and the **session transcript JSONL is the ground truth** (not the extension's own account of itself): a real process tree really dies, a recycled pid is really refused, a report really appears exactly once **through a durable channel** (a boundary entry, a wake message or a tool result — a `context` injection is per-request and may ride two attempts, and a run that settles without completing re-arms it as a persisted message instead of losing it). The job pins pi, Neovim and plenary because the scripts assert version-specific RPC behaviour.

**Never inherit the developer's editor.** The child `pi` inherits the shell environment, and a developer who runs `make e2e-bg-*` from inside pi.nvim's own `bash` tool carries `PI_NVIM_BG_TASKS_FILE` — the runtime file `pi.tasks.publish()` writes, which holds the editor's idle-wake policy. An unfocused editor publishes `present: false`, and `wake_on_completion = "never"` publishes `never`; either one makes `idleWakeHold` **hold** every idle completion instead of waking it, which is precisely what the report / wake / fallback / deadline / logs assertions measure. Symptom: `make e2e-bg-report` reports "the completion report reached the transcript" red on a laptop while CI is green, and the report really is missing from the JSONL because it was held for the next user turn. Every fake-provider script therefore clears the variable in its `main()` (`-- Hermetic: never inherit the developer's editor.`); a new suite that spawns `pi` directly must do the same, or run it with `env -u PI_NVIM_BG_TASKS_FILE` to reproduce CI.

- **No provider turn at all** — `scripts/e2e/worktrees.lua` (`make e2e-worktrees`) covers the git-worktree lifecycle end to end — create/refusals/`.worktreeinclude`/`setup_cmd`, diff-review apply, branch/ship, remove/snapshots/release and sessions-list grouping — against real `pi --mode rpc` children and real git repos. It needs the pi binary but no account, so it stays out of CI for now.

- **Provider-backed → manual only** (`make e2e-bg-delivery`, `make e2e-reaper`, plus `scripts/e2e/bg_tasks_notify.lua`, which has no target): the delivery ladder needs a real model answer long enough for a task to exit mid-run, and the reaper needs real settle events. None of these are in CI or in `make test`.
- To run a CI suite the way CI runs it, put a pi **release binary** first on `PATH` (`pi-linux-x64.tar.gz` from the GitHub release) — that is the toolchain the workflow installs, not a local package.

**Stub the backend** at the top of any script that submits: `chat._agent.send = function(_) end` (get `chat` via `require("pi.sessions.manager").get().chat`). This prevents real model calls *and*, because the stub returns before the RPC send, prevents the pi backend from writing a session transcript — so sessions stay clean.

**Pitfalls unique to headless:**
- **`TextChanged` / `TextChangedI` do NOT fire for programmatic edits in `-l` mode** — not for `nvim_buf_set_lines`, not for `setline`. So a debounced "save on edit" autocmd will never run in the test. Fix: factor the save body into a callable method (e.g. `Prompt:_save_draft()`) that the autocmd calls; the test calls the method directly (G4). The autocmd path is then trusted by construction (it's a one-line call to a unit-covered method).
- **Insert mode does not persist across separate `feedkeys`/`wait` calls.** An `<Up>` expr mapping bound insert-only will look dead because by the time the key is processed the mode reverted to normal. Either feed the whole sequence in one call (`"i<Up>"`) or bind the key in `{ "i", "n" }` (G5). The `<C-p>`/`<C-n>` recall keys use `{ "i", "n" }` precisely so they are robust here *and* for real users who happen to be in normal mode on the prompt.
- **You cannot see rendering.** Treesitter/extmark *counts* are observable (`nvim_buf_get_extmarks`), but whether it *looks right* is not. Visual proof is Layer 3 only (G6).
- **`vim.keycode`/`nvim_replace_termcodes` for a special key, returned from an `<expr>` mapping, inserts raw bytes** (`\x80ku`) as text in this environment. The correct fallback return is the literal angle-bracket string `"<Up>"` (G2). A headless e2e that types into a multi-line prompt and presses `<Up>` on line 2 is exactly the test that catches this.

**Committed headless e2e scripts.** The key/ordering gotchas are pinned in-tree, not only described: `make e2e` runs every `tests/*_e2e.lua` under `nvim --headless -u tests/minimal_init.lua -l <file>` (worktree-safe, no user config). `tests/prompt_up_e2e.lua` drives the real prompt buffer for G5/G2 (`"i" .. vim.keycode("<Up>")` in ONE `nvim_feedkeys(..., "x", false)` call: a 3-line draft stays byte-identical, the cursor moves up, no `\x80ku` appears, and on line 1 the same key recalls the newest history entry), and `tests/side_focus_e2e.lua` pins both halves of G11. Both isolate themselves **before `require("pi")`** (`PI_CODING_AGENT_DIR`, `pi.prompt_history._set_base_dir`, `pi.draft._set_path` on temp dirs, backend send stubbed), so a `make e2e` run leaves the user's `~/.pi/agent/sessions` untouched (G17/G18) — and since G18 is an assertion now, not a measurement, both scripts also count the real `~/.pi/agent/sessions` `*.jsonl` files before the isolation lines and re-count them before the summary (`G18: real sessions dir jsonl count unchanged`, `delta=+0`) and require the temp `PI_CODING_AGENT_DIR` to hold no `*.jsonl` at all, which goes red (exit 1) if a single file is injected there. `make e2e` is the `e2e` job in `.github/workflows/tests.yml` (all nine scripts, exit code only). **Triage by file, not by colour:** the `e2e` loop runs **every** script, prints `e2e: <file> exit=<code>` for each, and fails only after the last one with `e2e: N of M script(s) FAILED`. It used to end each script with `|| exit 1`, so a single red script hid every later script — one broken assertion survived a month that way (Gitea #121). Read the summary, then re-run the failing files individually.

**Template:** `scripts/headless_e2e_template.lua`.

**Prerequisites are not a pass (Gitea #125).** `make e2e` is a CI gate, so a script that prints `[SKIP] …` and exits 0 reports coverage that never ran — `tests/resume_partitions_e2e.lua`, the only layer that renders the resume picker with the **real** telescope picker, did exactly that on every CI run while the job printed `all 9 script(s) passed`. The protocol lives in `tests/e2e_deps.lua` (loaded as `require("e2e_deps")`; `minimal_init.lua` puts `tests/` on `package.path`) and is expressed as **exit codes**, never as output grepping:

| code | meaning |
|------|---------|
| 0 | every assertion ran and passed |
| 1 | at least one assertion failed |
| 2 | a prerequisite is missing and `PI_E2E_REQUIRE_DEPS=1` (gate mode) |
| 3 | a prerequisite is missing, gate mode off (a local run may skip) |

Use `deps.skip(reason)` when the whole script cannot run, `deps.skip_part(reason)` for a prerequisite of one later assertion (it returns `false` in gate mode so the caller records a failure), and `deps.require_dir` / `deps.require_executable` for the common “is this checkout / binary there” case. `make e2e` counts exit 3 separately and reports `e2e: N of M script(s) passed, K SKIPPED — a skip is not a pass`, and the `e2e` CI job sets `PI_E2E_REQUIRE_DEPS=1`, so the same absence is a red job there. The optional checkouts are `PLENARY_PATH` (also `make test`), `RENDER_MARKDOWN_PATH` (unit layer) and `TELESCOPE_PATH` (this layer); CI installs all three at pinned commits. Do **not** add telescope to `'runtimepath'` in `minimal_init.lua` — the unit specs inject a fake telescope module tree into `package.loaded`, and a real checkout on `'runtimepath'` loads the real `telescope/pickers.lua` alongside it (`attempt to call field 'on_close_prompt' (a nil value)`), so the script that needs the real picker must prepend it itself. Verify the gate itself with a mutation, not by reading it: `PI_E2E_REQUIRE_DEPS=1 TELESCOPE_PATH=/nonexistent make e2e` must fail.

## Layer 3 — GUI automation (xdotool + wmctrl + maim + RPC)

**What it's for:** the only layer that exercises real keybindings through the terminal emulator, real insert mode, and **visual rendering**. This is where G1, G2, G3, G11, G12 were actually caught. Like `make smoke`, it boots the user config and loads pi from the **main checkout**, so a GUI run does not see a feature worktree's code (G23) — verify worktree changes via unit / headless-`minimal_init`, or point lazy at the worktree first.

**Topology.** A dedicated WezTerm window runs `nvim --listen <SOCK>` on its own i3 workspace (so it tiles full-screen and screenshots are legible — a shared workspace splits the screen and the UI is tiny). `xdotool` sends keys to that window id; `wmctrl` enumerates windows; `maim -i <WID>` screenshots; the nvim **RPC socket** is ground truth (`nvim --server $SOCK --remote-expr 'luaeval("...")'`).

**Why RPC is ground truth, not the screenshot.** The screenshot proves pixels; RPC proves state (cursor line, buffer text, mode, extmark counts, whether render-markdown attached). Assert state over RPC; capture a screenshot as the human-readable artifact and as the only way to confirm visual rendering.

**The harness (`scripts/gui_harness.sh`).** `source` it. Key helpers:
- `q '<lua-expr>'` — evaluate one expression, print it. **Single-quote** the expression in bash.
- `qlua <<'LUA' ... RESULT = ... LUA` — run a multi-line block that sets `RESULT`; printed. Use this whenever the expression has quotes/loops — it writes Lua to a file and `:luafile`s it over RPC, which **avoids shell-quoting hell entirely**. Prefer `qlua`/`runlua` over clever quoting.
- `runlua <<'LUA' ... LUA` — same, side effects only.
- `find_buf <filetype>` — bufnr or `-1`.
- `send <keys>` / `type_text <text>` — xdotool to `$WIN` with inter-key delays.
- `normal` — send `Esc` until mode is normal/visual (G12: the prompt is in insert mode, so any leader/normal key needs this first).
- `shot <name>` — `maim -i $WIN`. Every success increments `SHOTS_OK`; every failure branch (maim error, a missing/unmapped window, or a **blank-file floor**: fewer than 20000 bytes means the capture is an all-one-color PNG) increments `SHOTS_FAIL` and returns nonzero — on **both** the Linux and the macOS harness (G27).
- `summary` — prints `PASS=<n> FAIL=<n> SHOTS_OK=<n> SHOTS_FAIL=<n>` and **returns nonzero when `SHOTS_FAIL > 0`**, so a run whose screenshots all failed can no longer end green. A run that legitimately takes zero screenshots stays green (no shot attempted, no failure). Every run script must therefore end with `summary || exit 1` — that line is the accounting's only teeth.
- `check <name> <got> <want>` / `wait_for '<lua-bool>' <tries>`.

**Isolation recipe (do this, every GUI run, or you corrupt the user's data — G17):**
1. Before opening the chat, the user's `~/.local/share/nvim/pi/draft.txt` (if present) is moved to a backup; restored at the end. This stops `restore_once` from pulling a real in-progress draft into the test prompt.
2. Right after the chat opens, redirect the test instance's storage to `/tmp`:
   ```lua
   require("pi.draft")._set_path("/tmp/<run>/draft.txt")
   require("pi.config").options.prompt.history.path = "/tmp/<run>/history.json"
   ```
   The history store is lazy, so setting the path before the first recall/send makes it use the temp file; the user's `prompt_history.json` is never opened by the test instance → no concurrent-write race.
3. Assert at the end: user's draft untouched, user's history has zero test-residue (`grep -c` of your sentinel strings == 0).
4. Delete the temp files; restore the user's workspace (`i3-msg workspace <saved>`).

**Driving real keybindings — the gotchas that matter here:**
- Leader is whatever `vim.g.mapleader` is (in the user's config it is `,`); send it as `comma`. Always `normal` (Esc) first (G12).
- lazy may only *load* the plugin on the first keypress; `wait_for` the `pi-chat-prompt` buffer instead of assuming the toggle completed (G13).
- side layout's `WinEnter` redirect (G11) is created by `Chat:_set_keymaps` in `lua/pi/ui/chat/init.lua`, **not** by the layout module: to focus history programmatically without a bounce, enter it from the prompt window (that is the `prev == pwin` exemption; float layout is exempt entirely); or use the real `<C-g>h` binding which the user presses from the prompt anyway.
- `gf` and other normal-mode keys on the history buffer: the history window has `winfixbuf`, so never `:edit` *inside* it in a test; the jump code switches to a non-pi window first.

**Reading a screenshot as proof.** Open the `maim` PNG and confirm the *rendered* form, not the source: headings show as styled text with the `##` concealed; `**bold**`/`*italic*` show as bold/italic with markers gone; list lines show bullets; a fenced block shows a language label + box with the fence concealed; links show an icon + label with the `(...)` gone. If any raw markdown punctuation is visible, rendering did not engage for that region.

**Cleanup (`scripts/gui_cleanup.sh`).** Kills *only* processes whose cmdline contains the test socket string (the test wezterm-gui and nvim), never the user's bare `wezterm-gui` (whose child is a shell) or the user's nvim. It is a **script file on purpose**: an inline `bash -c "…pgrep -f 'wezterm-gui.*pi_gui_test'…"` contains the feature string in its own cmdline and `pgrep -f` matches *itself*, so the cleanup kills its own shell mid-run (G16). The `[p]attern` trick also fails if you put the string on the right-hand side of a variable assignment. Keep cleanup/observation in files, or build the pattern so the literal never appears in the process cmdline.

**Templates:** `scripts/gui_harness.sh`, `scripts/gui_launch.sh`, `scripts/gui_cleanup.sh`.

### Layer 3 on macOS — `scripts/macos/`

Same topology, same RPC ground truth, same isolation recipe (G17) and verification discipline — only the OS-facing tools differ. The three scripts mirror the Linux ones (`gui_launch.sh` / `gui_harness.sh` / `gui_cleanup.sh`) and take the same `$RUN` wiring, so a run script written against the helper names (`send`/`type_text`/`shot`/`q`/`qlua`/`wait_for`/`check`) works under both.

| purpose | Linux (X11) | macOS |
|---|---|---|
| send keys | `xdotool key --window` | `wezterm cli send-text --pane-id <N> --no-paste` over the instance's own mux socket (`WEZTERM_UNIX_SOCKET=~/.local/share/wezterm/gui-sock-<pid>`) — injects the byte stream a keypress produces; focus-independent, no Accessibility (G28). `type_text` focuses the prompt + `startinsert` via RPC first (byte injection fires no OS focus events) |
| window discovery | `wmctrl -l` | `pgrep -f "wezterm-gui.*$SOCK"` for the pid (G29); CGWindowID via an embedded Swift helper calling `CGWindowListCopyWindowInfo` by owner pid over ALL windows, largest area wins (G27) |
| screenshot | `maim -i WID` | `screencapture -x -o -l <CGWindowID>`; needs **Screen Recording** (G27) — and the window on the ACTIVE Space, which no background CLI can arrange, so the test instance **self-fullscreens at launch** (G30) |
| workspace isolation | `i3-msg workspace` | the generated `--config-file` fullscreens the test window onto its own Space (`gui-startup` + delayed `toggle_fullscreen`); cleanup kills the GUI and the Space vanishes |
| launch / cleanup / RPC | `wezterm start --always-new-process`, pgrep-by-socket kill, `nvim --server` — identical | |

**Permissions checklist (the macOS-specific part, G27).** Granted to the *host terminal app* (the app owning your shell) and takes effect only after that app **restarts**:
- **Screen Recording** — required for `shot` *and* for the CGWindowID lookup. Probe: `screencapture -x -R0,0,50,50 /tmp/probe.png` (errors when denied; the window list silently hides other apps' windows when denied).
- Accessibility is **not** needed: input goes through the mux socket, not System Events (G28).

Degradation is deliberate and loud: without Screen Recording everything except `shot` still works — launch prints the remedy, `shot` SKIP/FAILs, and a tiny-file check rejects blank PNGs. Screenshots are also 2x pixels on Retina displays. The accounting is the same as on Linux and is what makes "every screenshot silently failed" impossible to report green: `shot()` increments `SHOTS_FAIL` on each of its three failure branches (no CGWindowID, `screencapture` error, a file under the 20000-byte floor — the floor exists in both variants) and `SHOTS_OK` on success, `summary()` prints `PASS=/FAIL=/SHOTS_OK=/SHOTS_FAIL=` and returns nonzero when `SHOTS_FAIL > 0`, and run scripts end with `summary || exit 1`. Verified by eight stubbed scenarios (success / capture error / blank file / no shot, per harness) driving the real `shot()`/`summary()` with fake `maim`/`screencapture`/`stat`; a real macOS pixel capture is still unverified.

**Templates (macOS):** `scripts/macos/gui_harness.sh`, `scripts/macos/gui_launch.sh`, `scripts/macos/gui_cleanup.sh`.

## Choosing a layer — quick guide

- New pure function / store / parser → **unit**.
- New buffer wiring / extmark logic / config resolution / keymap *exists* → **headless e2e**.
- New keymap *behavior* in insert mode, multi-line editing interaction, anything the user *sees* → **GUI**.
- A change that touches rendering → unit/headless for "extmarks produced + text intact", **GUI screenshot** for "it looks right".

When in doubt, add the cheaper test *and* the GUI screenshot; the screenshot is cheap insurance against the class of bug that only pixels reveal.

## Verification discipline (how to avoid stacking errors)

1. **Lock a baseline first (M0).** Before any feature work, confirm `make test` + `make smoke` + `make check` are green on a clean checkout and create a feature branch. Every later step re-runs these; a regression fails fast.
2. **Small steps, each verified, each committed.** Build a feature as: pure module → unit test (green) → commit; wire it in → headless e2e (green) → commit; if key/visual → GUI e2e (green) → commit. Each commit is a rollback point.
3. **Milestone gates.** Group steps into milestones; do not start the next milestone until the gate (unit + smoke + relevant e2e, all green) passes. The risky rendering work goes *after* the low-risk input work is locked.
4. **Stub the LLM.** In any e2e that submits a prompt, replace the backend so no real model call and no transcript write happen: `chat._agent.send = function(_) end`. Because the stub short-circuits *before* the RPC send, the pi backend never writes a session file — so sessions are not polluted. (Do **not** `grep` your way to "test sessions" to delete: a match can be inside an *assistant* quote of your test text, i.e. a real session. See gotcha G18.)
5. **Isolate from the user's data.** A test instance shares the user's `stdpath` history/draft files and races with their live pi. Redirect both to `/tmp` (gotcha G17) and assert the user's files stayed untouched.
6. **State exactly what you verified and what you could not**, per `AGENTS.md`.
7. **End the verification section with a manual-test command.** Every final report's 验证情况 / verification section must include a complete, copy-pasteable command the user can run to launch nvim and check the change by hand, plus the exact in-editor steps (command/keymap to trigger the behavior, what to look at):
   - Change still in a **worktree** → use the G23 env gate so the user's real config loads the worktree code:
     ```bash
     PI_DEV_DIR="$WT_ROOT/<name>" nvim
     ```
     (requires the one-time `dir = vim.env.PI_DEV_DIR or nil` line in the user's pi lazy spec — present in this setup). Mention that a plain `nvim` (no `PI_DEV_DIR`) shows the pre-change behavior for comparison.
   - Change already **merged to `main`** → plain `nvim` (the live lazy checkout tracks `main`; restart nvim so lazy reloads, G21).
8. **Confirm CI is green post-merge.** After pushing `main`, check the GitHub Actions runs for the merge commit — `.github/workflows/lint.yml` (`make style` + `make lint` + `make check` + `make docs-links`) **and** `.github/workflows/tests.yml` (`unit` = `make test`, `e2e` = `make e2e`). Both workflows run on GitHub Actions only: the canonical Gitea instance has Actions disabled and is the issue tracker, so a commit that only reaches Gitea runs nothing. The runner is a clean environment, so a local pass does not guarantee a CI pass — the run is the authoritative reproducibility gate, and the feature is not done until it is green. Commands in `SKILL.md` § CI verification.

## How to use the bundled scripts

The `scripts/` directory holds **templates** — copy into `/tmp/<run>/`, fill the few placeholders, run. They are deliberately parameterized (socket path, window id, workspace come from env/files, never hard-coded) so they are reusable across runs and machines.

- `scripts/unit_spec_template.lua` — plenary spec skeleton (note the `describe`-scoping rule, G14).
- `scripts/smoke.lua` — the committed smoke script behind `make smoke` (open chat + assert buffers and the RPC backend; no submit, no transcript write).
- `scripts/headless_e2e_template.lua` — headless `-l` skeleton (stub backend, `find_buf`, callable-save pattern for G4).
- `scripts/gui_harness.sh` — `source` this; gives `q`/`qlua`/`runlua`/`find_buf`/`send`/`normal`/`type_text`/`shot`/`check`/`wait_for` over the RPC socket. Lua goes through files (`:luafile`) to dodge shell-quoting hell.
- `scripts/gui_launch.sh` — starts a **dedicated, full-screen** WezTerm+nvim (`--listen`) on its own i3 workspace so screenshots are large; remembers the user's workspace to restore later.
- `scripts/gui_cleanup.sh` — kills *only* the test instance (matched by the socket string in the cmdline), never the user's wezterm/nvim; safe against G16.
- `scripts/macos/` — the same three scripts for macOS (AppleScript keys, `screencapture`, no i3); see "Layer 3 on macOS" above for the permission checklist.
- `scripts/makefile.snippet` — the `test`/`smoke` targets already in the repo `Makefile`, for reference when adding targets.

A typical GUI run:

```bash
RUN=/tmp/pi_run; mkdir -p "$RUN"
cp scripts/gui_harness.sh scripts/gui_launch.sh scripts/gui_cleanup.sh "$RUN"/
# (write your run_all.sh in $RUN, sourcing $RUN/gui_harness.sh)
bash "$RUN/gui_launch.sh"     # full-screen isolated instance, prints WIN
bash "$RUN/run_all.sh"        # drives real keybindings, asserts over RPC, screenshots
bash "$RUN/gui_cleanup.sh"    # removes only the test instance
```
