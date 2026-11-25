# Health & debugging

When something misbehaves — the agent doesn't respond, a tool doesn't render correctly, an extension event doesn't arrive — pi2.nvim gives you a few places to look.

## `:checkhealth pi`

The health check verifies:

- **Neovim version** — 0.10 or newer.
- **The `pi` executable** (from `cli.bin`, defaults to `"pi"`) exists and is in `$PATH`, and its version against the plugin's tracked range:
    - minimum supported: `0.65.2`
    - last validated: `1.1.0`
    - older versions are a hard error; newer versions are reported as unvalidated (warning), not hard-failed.
- **Vision fallback version floor** — when `vision.model` is configured, the check also verifies the pi version against the vision fallback minimum (`0.81.0`): older versions are a hard error, matching versions report OK, and an undetectable pi version is a warning. The floor exists because the bundled vision extension needs `ctx.sessionManager.buildContextEntries()` (pi 0.80.4+) and a public `ModelRegistry.getProvider()` (pi 0.81.0+); 0.81–0.83.x runs through the `provider.streamSimple()` fallback path (validated on 0.83.0), 0.84.0+ uses `ModelRegistry.complete()`. On pi versions below the floor a configured `vision.model` does not crash anything — every image submission fast-fails with a `[pi-vision] …` error notification and the prompt text/attachments are restored. Unset `vision.model` to silence the error without upgrading.
- **Auto-title version floor** — when `title.enabled` is on, the check also verifies the pi version against the auto-title minimum (`0.44.0`) and that the bundled extension (`extensions/title.ts`) is present. Below the floor (or with the file missing) sessions simply stay unnamed and keep the first-message fallback — no crash. Set `title.enabled = false` to silence the error without upgrading.
- **Model-scope bridge check** — always-on: verifies that `extensions/scoped-models.ts` is present (warning if missing) and that the pi version satisfies the bridge minimum (`0.83.0`). Below the floor the bridge stays silent — pi's `--models` / `enabledModels` scope is still honored by `:PiCycleModel` via the backend, but `:PiSelectModel` cannot mirror it and falls back to the configured `models` subset or all models. This severity is a warning rather than an error because without backend scoping the layer is inert anyway; upgrading pi clears it.
- **Background bash tasks check** — always-on: verifies that `extensions/bg-tasks.ts` is present (warning if missing) and that the pi version satisfies the background-tasks minimum (`0.85.1` — the version its package-root re-exports are verified against). Below the floor the extension fails to load and pi logs the error: sessions keep stock bash (no `run_in_background`, no `deadline_ms` check-in, no `wait_task` / `stop_task` / `list_tasks` / `task_input`, `&` prefix inert, no advisory lifetime note), `:PiTasks` stays empty — no crash. Upgrade pi to clear it.
- **Compaction extension check** — when `compaction.extension.enabled` is on (the default): verifies that `extensions/compaction.ts` is present (warning if missing) and that the pi version satisfies the compaction minimum (`1.6.0` — the shapes its cleaner/checkpoint/state layers use). Below the floor the extension fails to load and pi logs the error: compaction keeps pi's stock behaviour (no bounded file lists, no checkpoint, no `[pi2 state]` snapshot), `:PiCompactions` still shows the live numbers but no `󰏗pi2` marker — no crash. It also prints the resolved layers (`cleaner on (read≤50, modified≤100) · checkpoint off · state on · prune off`), the global pi compaction settings (`reserveTokens` / `keepRecentTokens` / `enabled`) and warns on an invalid value, names the checkpoint model when one is pinned, and reports the runtime file the extension reads (`PI_NVIM_COMPACTION_FILE`). A statusline `context` suffix of `· keep ≥ budget` or `· ?` is explained by the same section.
- **Treesitter parsers** — `markdown` and `markdown_inline` (info-only; chat highlighting is limited without them).
- **Optional plugins** — `img-clip.nvim` (clipboard image paste), `render-markdown.nvim` (warned when it's the configured engine but missing), `blink.cmp` (info-only).
- **The bundled tree extension** — `extensions/tree.ts` exists when `tree.enabled` is on (`:PiTree` depends on it).
- **Image compression tools** — when `prompt.image_compress` is enabled, at least one of `sips` / `magick` / `ffmpeg` is found (warns if you pinned a specific `tool` that's missing).
- **Three-column layout** — `layout.side.full_tab` holds a supported value (`never` / `auto` / `always`), the side columns leave the chat column at least 40 columns at the current editor width (the warning names the width and the knobs: `sessions_list.width` / `tasks_panel.width` / `todo.panel.width`), `layout.side.position = "bottom"` is reported as unsupported (the chat column opens on the right instead), and a panel configured as `top`/`bottom` is reported when the tab is taken over (it moves into the left column then).

Run it any time you suspect something is off with the install:

```vim
:checkhealth pi
```

If the executable isn't found, either install pi or set `cli = { bin = "/absolute/path/to/pi" }` in `setup()`.

## RPC debug logging

pi2.nvim communicates with the backend over a JSONL RPC protocol on the pi process's stdin/stdout. When that conversation goes wrong, the best diagnostic is a transcript of the protocol traffic.

There are two ways to enable it:

- **Statically**, from the start of every session: `debug = true` in `setup()`.
- **At runtime**, toggled on/off without restarting anything: `:PiToggleDebug` / `pi.toggle_debug()`. This override is in-memory only and lasts for the current Neovim session; restart clears it back to whatever `setup()` said.

Logs are written to:

```
<stdpath("log")>/pi/<cwd-slug>/rpc.log
```

where `<cwd-slug>` is the current working directory with `/` replaced by `--`. On a typical Linux setup that's something like `~/.local/state/nvim/log/pi/home--you--Dev--myproject/rpc.log`. The log is **reset** every time debug is enabled, so each session starts with a clean transcript.

The log contains every RPC command pi2.nvim sends and every event it receives, including any unhandled event types (useful when the pi protocol evolves and pi2.nvim hasn't caught up yet). Tailing the file in another terminal while reproducing the bug is usually the fastest way to pinpoint where things diverge:

```sh
tail -f ~/.local/state/nvim/log/pi/*/rpc.log
```

When filing an issue, attaching the relevant section of `rpc.log` is by far the most useful thing you can include.

## The first open is slow

pi2.nvim loads on first use, so the first `<leader>ap` (`:Pi`, `pi.toggle()`, …) also runs the **startup status rebuild**: every sub-session manifest under `~/.pi/agent/sessions` is reconciled, and each child's transcript is consulted to recover its run status. That work is kept off the byte path — session ids resolve from the `<timestamp>_<id>.jsonl` filename convention, a transcript is read from its **end** (the last JSONL entry is the answer), and a transcript whose mtime has not changed since the last rebuild is not read again — so on a multi-GB sessions tree the rebuild costs a few hundred milliseconds, not seconds.

Two costs are still expected:

- **The first start after upgrading** re-infers every recorded child once, because the previous build left no mtime stamp to short-circuit on. That pass costs roughly a millisecond per sub-session row and stamps the mtime, so the next start skips them: a one-off, not a leak.
- **A large history tree costs more.** `ls ~/.pi/agent/sessions | wc -l` counts workspaces — one per project *and* one per git worktree. Abandoned ones keep their manifests in the scan; deleting a `--…--` directory you no longer need removes that project's session history, sub-session metadata included.

If the first open still takes seconds, the rebuild — not the chat UI — is what to measure: time `require("pi.sessions.manager")` (which lazy-loads the plugin) and `require("pi").setup({})` under your config, then report the numbers. Pushing the first open back into the seconds range is a bug: the budget is an iron rule (`AGENTS.md` → *Startup cost is a hard budget*), and `tests/subsessions_rebuild_spec.lua` / `tests/subsessions_read_spec.lua` pin it.

## Sub-agent wait stuck after children finish

`wait_subagents` / `dispatch_subagents({ wait = true })` blocks the parent pi process on a host `select` until Neovim replies with `extension_ui_response`. The tunneled sub-agent tools forward the tool `AbortSignal` to that select, so `:PiAbort` interrupts a pending wait immediately instead of hanging until `subagent.batch_timeout_ms`. If a reply is dropped (encode/send failure), the parent may still stay busy even though the child row looks idle and `.pi2-sub-batches.json` already says `completed` — abort the parent (`:PiAbort`) and retry the wait. With `debug = true` or `:PiToggleDebug`, `rpc.log` should show the `extension_ui_response` (or `Failed to encode RPC command` / `Failed to send RPC command`).

## Sub-agent failed: quota, auth or network error

When a child's model call is rejected — exhausted quota, invalid API key, rate limit, dead network — the run ends with an assistant turn carrying `stopReason: "error"` and the reason in `errorMessage`, and no content. pi2.nvim reports that as a **failure**, not as an empty success:

- The batch item comes back `status = "failed"` with the provider message in `error` (e.g. `429: {"message":"You exceeded your current quota…","type":"insufficient_quota"}`), and the batch status is `failed`, or `partial` when siblings finished.
- `list_subagents` shows `status = "failed"` plus `error`, and `read_subagent` renders the failed turn as `[n] assistant: [] (error: …)`.
- A user-spawned child injects `[Sub-session "x" failed] …` / `[子会话「x」失败] …` into the parent chat.

Nothing is broken and nothing needs closing: the child process stays alive and reusable. Fix the cause (top up the quota, `/login` or set the provider key) and reuse the child with `dispatch_subagents({ items = { { target = "<id>", message = "…" } } })`, or dispatch again with a different `model`. The same report appears when the prompt itself is rejected (`failed to send task to sub-session: No API key found for …`) and when the child process dies unexpectedly (`sub-agent process exited`).

## The model still greps through bash

The [search-tools extension](extensions.md#bundled-search-tools-extension-extensionssearch-toolsts) steers the model from `bash` to the dedicated `grep` / `find` / `ls` / `read` tools by rewriting the prompt pi assembles for each run. When the model keeps shelling out to `rg`/`grep`/`find`, check these three things first:

1. **Is the extension loaded?** `search_tools.enabled` must not be `false` (it defaults to `true`). The value is read when the RPC process is spawned (`lua/pi/cli.lua`), so flip it and start a new session — an already-running session keeps whatever it was started with. The config option is the only switch: `cli.args` containing `--no-extensions` does **not** disable this extension, because pi still loads the explicit `--extension` paths pi2.nvim passes. If pi could not load the file, it prints `Failed to load extension …` to the RPC process's stderr — that line is the other thing to look for.
2. **Do the tools actually exist in this session?** The extension writes a guideline only for a tool that is currently **active** (`pi.getActiveTools()`). If `grep` / `find` / `ls` are excluded — by pi's own `defaultTools` setting, by `--tools`/`--exclude-tools` in `cli.args`, or (most often) by a sub-agent `tools` allowlist — the model is correctly never told to use them, and bash keeps being the only way to search. That is the intended behaviour, not a failure.
3. **Is a sub-agent's allowlist the culprit?** Children inherit nothing: a `dispatch_subagents` item's `tools` array **replaces** the child's entire tool selection. A scout dispatched with `tools = { "read", "bash" }` gets no `grep`, no `find`, and no steering. Add them to the list ([Constraining a child's tools](sessions.md#constraining-a-childs-tools)).

To see the rewritten prompt with your own eyes, export the session: `pi --export <session.jsonl> out.html` renders its first system message as **System Prompt** + **Available Tools**, where the bash entry reads `Execute shell commands (build, test, git, network, pipelines)` when the extension is active and the old `Execute bash commands (ls, grep, find, etc.)` when it is not. For the byte-level proof, `make e2e-search-tools` drives a real `pi --mode rpc` against a fake provider and asserts both the request body the model receives and the system message persisted in the session JSONL, with a negative control run without the extension.

Expectations, so this is not chased as a bug: **steering is a hint layer, not a hard constraint**. The prompt gains a mapping table and a guideline; nothing stops the model from typing `rg -n` into bash, and a model falling back to the shell occasionally is normal — especially for a search whose shape the dedicated tools express badly (a pipeline, a count per directory, a one-off awk). The only hard constraints are a sub-agent `tools` allowlist or `--exclude-tools bash`, and both cost the shell entirely.

Finally, the extension lives in the **RPC** process pi2.nvim spawns: a CLI session (`pi`, `pi -p "…"`) has no steering at all. There the escape hatch is pi's own `pi --append-system-prompt "<text or file>"` (repeatable, see `pi --help`) — pi2.nvim does not add it for you.

## Process lifecycle

Each π session owns an underlying `pi --mode rpc` subprocess. One tab = one session = one process. The lifecycle is:

- **Spawned** lazily, the first time you open the chat in a tab (via `:Pi`, `:PiNewTab`, `:PiContinue`, `:PiResume`, `pi.toggle()`, etc.). There is no background daemon; nothing runs until you ask for it.
- **Alive** until explicitly stopped or Neovim exits. Hiding the chat (`:PiToggleChat`) or switching away from the tab does **not** stop the process — the session keeps running in the background, and any queued [attention](attention.md) requests keep being tracked.
- **Detached** on `TabClosed` for the owning tab: pi2.nvim only unbinds the session from the closed tab — it does **not** shut the process down; the `pi --mode rpc` process keeps running in the background and stays available for re-attachment. The process is **torn down** only by an explicit `:PiStop` / `pi.stop()` for that session, or on `VimLeavePre`, where every remaining RPC process is stopped at once when Neovim exits.
- **Stopped explicitly** via `:PiStop` / `pi.stop()` — kills the RPC process for the current tab's session immediately and closes the chat windows. Use this when you want to reclaim resources without closing the tab, or to force a clean restart (a subsequent `:Pi` will spawn a fresh process).
- **Aborted** via `:PiAbort` / `pi.abort()` — cancels whatever the agent is currently doing mid-turn but keeps the session and process alive, so you can immediately send a new prompt. On a parent session the abort also cascades to its sub-sessions, and the processes of children that already received their task stay alive and reusable (a child still spawning is reclaimed); inside a child view only that child is interrupted, never the parent. Different from `:PiStop`: abort stops the _agent_, stop kills the _process_.

## What to check when something's wrong

A rough triage checklist for common symptoms:

| Symptom | First thing to check |
| --- | --- |
| `:Pi` does nothing / reports no executable | `:checkhealth pi` — is `bin` resolvable? |
| Chat opens but never gets a response | Enable debug logging and watch `rpc.log` — are commands going out? Are events coming back? |
| Diff review doesn't open on edit/write | Is a permission extension loaded? See [Diff review](diff-review.md). |
| Extension UI request ignored | Check the extension's `widgetKey` / method — is it something pi2.nvim knows how to route? See [Extensions](extensions.md). |
| Slash command not highlighted | The command cache may not be populated yet (fetched on first chat open, refreshed every 30 seconds). |
| Session doesn't continue with `:PiContinue` | Are you in the same cwd as when the session was started? Sessions are cwd-scoped — a [worktree session](worktrees.md#what-a-worktree-session-is) keeps its sessions in its own directory, and `:PiContinue` lists sessions for Neovim's cwd only. `:PiResume` is the broader entry point: it lists the current cwd plus every linked worktree of the repository. See [Sessions](sessions.md). |
| Worktree session closed but the checkout is still on disk | That is deliberate: a worktree is released only when it is clean and has no commits beyond its base commit. The notification names the path — inspect it, `pi.worktree_apply` / `pi.worktree_ship` it, or `pi.worktree_remove` it. See [Worktrees](worktrees.md#cleanup-when-a-session-closes). A **borrowed** sub-session checkout (`worktree = { path }`, or a `create` that adopted an existing name) is never released at all; an **owned** child checkout follows the same clean-only rule. |
| `dispatch_subagents` fails with `worktree.path …` | The borrow form is a reference to an existing linked worktree, not a create request: the path must be absolute, exist, be a linked checkout (not the main checkout) and belong to the parent's repository. The resolved root is used even if you pass a subdirectory or symlink. Prepare the checkout with `git worktree add` or `N` in `:PiSessions`, or use the other form — `worktree = { create = true }` / `{ create = { base, name } }` — then retry; nothing was spawned. See [Worktrees → Sub-sessions](worktrees.md#sub-sessions). |
| A revived sub-session fails because its worktree is gone | Only an **owned** checkout (one a `worktree.create` spawn made) is recreated — in place, at the recorded base commit, retried at `HEAD`, and only then replaced by the parent's workspace plus a warning. An **assigned/adopted** checkout is borrowed and never recreated: a revive revalidates the recorded path and fails closed instead of running the child in the parent's cwd. Recreate or attach that checkout at the same path, or dispatch a new child without `worktree`. |
| A finished sub-session left a `.worktrees/<name>` checkout behind | The checkout was **owned** and had work in it (uncommitted changes or commits of its own), so it was kept instead of released. Inspect it, `pi.worktree_apply` it into the main checkout or ship it as a branch, then `pi.worktree_remove` it. A clean owned checkout is released automatically on settle and close. |
| A sub-agent started from `origin/main` instead of my current code | The item's `create.base` or `worktree.base_ref` is `"fresh"` (the remote default branch). Use `base = "head"` (the default) to start from the commit your checkout is on; note that uncommitted changes never travel into a child checkout — commit first, or reuse an existing checkout by `path`/`name`. |
| A sub-agent's base cannot be resolved | A `create.base` git cannot resolve fails the item with `invalid base commit: <rev>` and nothing is spawned; pick a ref that exists (`git rev-parse <rev>`). On **revive**, an owned checkout whose recorded base is gone is retried at the repository `HEAD` before giving up. |
| Two children overwrite each other in one worktree | Items that name the same `worktree.path` (or the same `create.name`, which adopts the existing checkout) deliberately share one checkout; assignment isolates files, not privileges, and is **not a sandbox**. Give each child a distinct checkout or disjoint files (plus a read-only `tools` allowlist for scouts). |
| `:PiResume` reports it cannot recover a worktree | The session's checkout is gone and there is neither an applied integration record nor a snapshot to rebuild it from, so the picker refuses rather than opening the transcript in the main checkout. See [Resuming across worktrees](worktrees.md#resuming-across-worktrees). |
| `pi.worktree_remove()` refuses to remove a worktree | A π process is still running with that checkout as its cwd. Close it first (`:PiStop`, `:PiSubClose`, `x` in `:PiSessions`) — check `:PiSessions` for a session you forgot, and the notification names the session. The guard also catches a child that only *inherited* the checkout (a sub-session of a session that already ran in a worktree): it owns no worktree metadata, so it is matched by its process cwd. |
| Snapshot failed / worktree NOT removed | The snapshot runs before any deletion and aborts the removal when it cannot be **written** (the path is under the repository's git dir — check permissions and free space) or when the patch cannot be captured **completely**: more than 20 000 untracked files, or an untracked path a patch cannot represent (typically a directory holding its own git repository). The error names the offending path — commit, ignore or delete it and retry; `pi.worktree_apply` shares the same capture rules. With `worktree.snapshot_before_remove = false` removal skips the snapshot. |
| `pi.worktree_apply()` reports "Failed to read the worktree diff" | The worktree's patch cannot be captured completely (same rules as a snapshot: too many untracked files, or an untracked nested repository). Nothing is applied — commit, ignore or delete that path, then retry. See [Worktrees](worktrees.md#applying-a-patch). |
| `pi.worktree_apply()` asks "Apply into a live checkout?" | Expected, not an error: a π session is running **in the main checkout**, so the apply would rewrite files its agent may be using mid-turn. Cancelling writes nothing; confirming applies, after re-checking that the session you were warned about is still the only one there. Close that session (`:PiStop`) first if you want the write to go through without the extra prompt. See [Worktrees](worktrees.md#applying-a-patch). |
| `pi.worktree_apply()` says the main checkout "now has a running π session" | The re-check before the write found a *different* session than the one you confirmed (it started while the dialog was open, or in the gap up to the write). Nothing was applied — retry once that session is closed, or after the checkout is free. |
| Statusline component shows stale data | The statusline is pushed from RPC events; if they stopped flowing, `rpc.log` will show the gap. |
| Unhandled event warning | pi2.nvim doesn't yet know about a new event type the backend is sending. Please [open an issue](https://github.com/zgs225/pi2.nvim/issues) with the event name and a snippet of `rpc.log`. |
| Prompt paste shows `^[[106;5u` instead of a line break | The terminal pasted Ctrl+J as Kitty CSI-u (or `^[[27;5;106~` / `^[[13;2u`) instead of LF. π rewrites those sequences in the prompt paste handler. Type a newline with `<S-CR>` (or `<C-j>`); `<CR>` still submits. |
| `:PiTree` shows "Failed to decode RPC message: Found too many nested data structures" | The `get_tree` response for a very long session (roughly 500+ messages) is deeper than Neovim's built-in JSON decoder allows. See [Deep RPC payloads](#deep-rpc-payloads) below. |


## Deep RPC payloads

Neovim's `vim.json` (the bundled lua-cjson library) hard-caps JSON nesting at 1000 levels, which cannot be raised at runtime. The pi backend nests the session tree one level **per message**, so `get_tree` responses for long sessions — and with it `:PiTree` — used to fail with `Failed to decode RPC message: Found too many nested data structures (1001) at character N`, and the tree picker never opened.

Since 2026-08-11 pi2.nvim ships its own depth-tolerant JSON decoder (`pi.json`) as a fallback: incoming RPC lines that cjson refuses are re-decoded with it, so `:PiTree` works for sessions up to roughly 4000 messages (the fallback's defensive depth cap). Only when both decoders fail does the warning still appear — normally a sign of a genuinely malformed line; enable [RPC debug logging](#rpc-debug-logging) and check `rpc.log` in that case.
