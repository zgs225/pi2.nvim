# pi.nvim — Agent Guidelines

Neovim plugin (Lua) — a frontend for the [pi coding agent](https://github.com/earendil-works/pi). Provides a chat UI, diff review, session management, and extension handling inside Neovim.

## Working Principles

- Be concise. Prefer small, targeted edits over full-file rewrites.
- Ask before broad, multi-file, or potentially destructive changes. State assumptions and tradeoffs briefly when they matter.
- Match the existing style and conventions of the file/project. Don't reformat unrelated code and avoid unrelated cleanup.
- Treat `lua/` as the source of truth; `README.md` and `doc/` are user-facing documentation, not authority over behavior.
- **Every code change must keep the documentation consistent with the code.** Any change to `lua/` (and `extensions/`) requires checking the docs against it: user-visible changes — public API, commands, keymaps, config defaults, highlight groups, or any documented behavior — must update the docs **in the same change**; purely internal changes must still verify the docs remain accurate and fix any drift found. `README.md` is the landing page (overview only); detailed guides live in `doc/` (`usage.md`, `sessions.md`, `diff-review.md`, `attention.md`, `extensions.md`, `configuration.md`, `keymaps.md`, `api.md`, `highlight-groups.md`, `troubleshooting.md`). Run `make docs-links` to validate relative links and anchors.
- Re-read a file immediately before editing it. Never rely on content from an earlier read — it may be stale.
- Handle errors explicitly. Don't swallow them or mask them with odd defaults. Use `pcall` for Neovim API calls that may fail (invalid windows/buffers) and `Notify.error/warn/info` for user-facing messages.

> **Developing or testing a feature?** Read `.agents/skills/develop/SKILL.md` first. It is the operational playbook: the three-layer test stack (unit / headless-e2e / GUI automation), the non-obvious Neovim-Lua gotchas, the standard places a change lands, and the verification discipline. `AGENTS.md` (this file) stays the authority on architecture and style.

## Startup cost is a hard budget (iron rule)

`pi` is **lazy-loaded inside the first `<leader>ap`**, so everything `pi.setup()` does synchronously is time the user spends staring at a frozen editor — on every Neovim start, over state that only grows (`~/.pi/agent/sessions` is routinely multi-GB and thousands of files on a long-lived machine). A startup freeze is a **bug**, never an acceptable trade-off.

1. **Nothing on the setup path may scale with stored history.** `pi.setup()` registers autocmds/commands and nothing else. The startup status rebuild (`pi.subsessions.rebuild_statuses`) is the single exception and must stay in the hundreds of milliseconds, never seconds: no `History.parse` / `History.list` per file, no full-JSONL decode per manifest row, no `git` call, no synchronous child process.
2. **Budget cost per row and per file, not per call.** One extra read per manifest row becomes 1.4 k reads of files up to 12 MB. A full decode per row cost 5–9 s on the author's tree; reading transcript tails plus a filename index brought it to ~0.5 s.
3. **Cheap answer first.** Session ids resolve from the `<timestamp>_<id>.jsonl` filename convention (verify with the one-line header, not a parse); an unchanged mtime means the status inferred last time still holds; only then read content.
4. **Never read a transcript end-to-end to look at its end.** Use `pi.subsessions.read`'s tail reader (`open_tail`) instead of `read_jsonl` for "last entry / run status / last assistant turn": it walks backwards, reads each byte once, and skips lines that cannot describe a turn before decoding them.
5. **What cannot be made cheap is deferred, not blocking** — schedule it off the keypress path so the delay stays invisible.
6. **Measure when you touch the path**, and put the number in the change: time `require("pi.sessions.manager")` plus `require("pi").setup({})` under the real config (a `PI_DEV_DIR` run does not run `setup` by itself, so call it). A few added milliseconds need a reason in the description.

`tests/subsessions_rebuild_spec.lua` and `tests/subsessions_read_spec.lua` encode this contract (no per-file parse on the fast path, no re-decode of an unchanged transcript, decode counts bounded by the tail window); `doc/troubleshooting.md` documents the user-visible side.

## Layout

Use `find lua -type f` for the authoritative file list — don't rely on any snapshot. Directory-level map:

- `lua/pi/` — core: `init.lua` (public API), `config.lua`, `commands.lua` (:Pi* commands), `rpc.lua` (JSON-RPC to `pi --mode rpc`), plus feature modules (models, thinking, paste, quickfix, draft, prompt_history, reload, …)
- `lua/pi/sessions/` — session lifecycle (`manager.lua`, central event dispatch) and resume parsing (`history.lua`)
- `lua/pi/ui/` — all UI: `ui/chat/` holds the Chat class, history rendering, prompt, tool blocks, layout modes; `diff.lua` is the pre-execution diff review; `dialog.lua` / `extension.lua` handle blocking extension UI; `render.lua` is the optional render-markdown.nvim integration
- `lua/pi/completion/` — @-mention / slash-command completion (blink.cmp source + omnifunc fallback, shared fuzzy matching)
- `lua/pi/cache/` — project file listing and slash-command caches
- `tests/` — plenary specs (`make test`); `make smoke` = headless boot check

## Key Patterns

### Event Flow
`rpc.lua` dispatches raw JSON events → `sessions/manager.lua:handle_event()` routes them → `Chat` → `ChatHistory` renders into the buffer. All UI mutations go through `vim.schedule()`.

### Buffer Modifications
History buffer is `modifiable=false` by default. All writes go through `History:_with_modifiable(fn)` which toggles modifiable, runs `fn`, then restores it.

### Extmarks
Extmarks (namespace `pi-chat`) are used extensively for: tool block borders (virtual text), highlighting, status spinners, thinking block anchors, and tool block expand/collapse range tracking. When replacing lines, extmarks must be captured before and restored after (`capture_extmarks` / `restore_extmarks` in history.lua).

### Tool Renderers
Each tool has a renderer in `tools.lua` (`pi.ToolRenderer`). Renderers define `on_start`/`on_end` for content, plus `input_visible`/`output_visible` thresholds for auto-collapse; a renderer sets `always_expanded = true` to never auto-collapse (line count *and* window width). Inline tools (like `read`) render as a single line. Custom renderers can be added to the `renderers` table.

### Layout Modes
Side layout uses `vsplit`/`split`. Float layout uses `nvim_open_win` with a stacked vertical arrangement (history float → prompt float → attachments float). Both are managed by `layout.lua` and share the same buffer instances.

### Session Per Tab
Each Neovim tabpage gets at most one session (`sessions[tab]`). Session owns an `Rpc` instance and a `Chat` instance. Cleanup happens on `TabClosed` and `VimLeavePre`.

## Reference Implementation

Before implementing a new feature, always consult the pi TUI interactive mode source first. The TUI is the reference frontend. Study how it handles the same feature (event flow, state tracking, edge cases) and mirror the approach, adapting for Neovim's buffer/extmark model.

Key source files (under `$(npm root -g)/@earendil-works/pi-coding-agent/`):
- `dist/modes/interactive/interactive-mode.js` — TUI frontend
- `dist/core/agent-session.js` / `agent-session.d.ts` — session layer shared by all frontends
- `dist/modes/rpc/rpc-types.d.ts` — RPC protocol types
- `docs/rpc.md` — RPC protocol documentation

## Conventions

- **Type annotations**: use `---@class`, `---@param`, `---@return`, `---@type`, `---@alias` (LuaLS/EmmyLua style) on all public and internal functions and fields.
- **Module pattern**: each file returns a single table/class. Classes use `setmetatable({}, Class)` with `Class.__index = Class`.
- **Private fields/methods**: prefixed with `_` (e.g., `self._buf`, `History:_append_lines`).
- **Scheduling**: any code touching Neovim UI from an RPC callback must be wrapped in `vim.schedule()`.
- **Config access**: always go through `require("pi.config").options`, never cache config values at module load time.
- **No globals**: all state lives in module-level locals or class fields.
- **Formatting**: stylua, configured in `.stylua.toml` (4-space indent, double quotes, 120 cols). Run `make format` to apply and `make style` to check. stylua's built-in default indent is **Tabs**, so the config file pins Spaces — never run a bare `stylua .` without it.

## Verification

- There **is** a test harness now: hermetic plenary unit tests (`make test`, specs in `tests/`) and a headless boot check (`make smoke`). For keymap / insert-mode / visual behavior there is also an xdotool+wmctrl+maim GUI-automation stack over the nvim RPC socket. The full playbook — when to use each layer, the pitfalls, the isolation recipe, and the gotchas — is in `.agents/skills/develop/` (see its `references/testing.md` and `references/gotchas.md`). Verify changes at the cheapest layer that can observe the behavior, and escalate to a GUI screenshot for anything visual.
- Formatting and static checks are gated too: `make style` (stylua `--check`) and `make lint` (lua-language-server `--check` over `lua/`, config `.luarc.json`). Both run in CI and must stay green; `make lint` is environment-independent (bundled luv types only, no vim runtime dependency).
- Reading files or reviewing diffs is not verification.
- If a change can only be checked through interactive UI behavior, say so clearly instead of claiming success — or prove it with a GUI screenshot per the skill.
- In the final report, state exactly what was verified and what could not be verified in this environment.
