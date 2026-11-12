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
- **Background bash tasks check** — always-on: verifies that `extensions/bg-tasks.ts` is present (warning if missing) and that the pi version satisfies the background-tasks minimum (`0.85.1` — the version its package-root re-exports are verified against). Below the floor the extension fails to load and pi logs the error: sessions keep stock bash (no `run_in_background` or `wait_task`, `&` prefix inert), `:PiTasks` stays empty — no crash. Upgrade pi to clear it.
- **Treesitter parsers** — `markdown` and `markdown_inline` (info-only; chat highlighting is limited without them).
- **Optional plugins** — `img-clip.nvim` (clipboard image paste), `render-markdown.nvim` (warned when it's the configured engine but missing), `blink.cmp` (info-only).
- **The bundled tree extension** — `extensions/tree.ts` exists when `tree.enabled` is on (`:PiTree` depends on it).
- **Image compression tools** — when `prompt.image_compress` is enabled, at least one of `sips` / `magick` / `ffmpeg` is found (warns if you pinned a specific `tool` that's missing).

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
| Session doesn't continue with `:PiContinue` | Are you in the same cwd as when the session was started? Sessions are cwd-scoped — a [worktree session](worktrees.md#what-a-worktree-session-is) keeps its sessions in its own directory, and `:PiResume` / `:PiContinue` list sessions for Neovim's cwd. See [Sessions](sessions.md). |
| Worktree session closed but the checkout is still on disk | That is deliberate: a worktree is released only when it is clean and has no commits beyond its base commit. The notification names the path — inspect it, `:PiWorktreeApply` / `:PiWorktreeShip` it, or `:PiWorktreeRemove` it. See [Worktrees](worktrees.md#cleanup-when-a-session-closes). |
| A sub-session finished but its changes are not in the parent checkout | [Automatic integration](worktrees.md#automatic-integration) only writes at a safe window (parent blocked in `wait_subagents` or idle) — otherwise the row stays `⧗` queued and is retried on the next readiness signal (wait start/end, turn end, resume). Check the integration glyph on the child row (`⧗` queued, `…` applying/resolving, `✓` applied, `!` needs attention) and the `󰙅 …` line in the parent chat for the reason; `!` means a human decision is required. |
| Integration stuck at `needs_attention` | The chat record names the reason. `patch_conflict` / `base_drift` / `apply_failed` mean the patch does not apply cleanly — the child got its one resolving round unless `worktree.integration.auto_resolve = false` or `max_attempts = 0`, or its process was gone; rebase/resolve in the checkout, then `:PiWorktreeApply` (or raise `max_attempts` and re-dispatch). `modified_buffer` clears when you save or revert the buffer, `other_session` when the other π process in that checkout is closed. `delta_baseline_missing` means the previous round is still uncommitted in the checkout — commit it or start a fresh checkout. |
| Child checkout kept after a successful apply | Deliberate: it is only deleted when nothing else would be lost. `checkout_changed` = the directory changed after the integration (a background writer), `ignored` = it holds git-ignored files a patch never carries, `live_session` = a π process is still rooted there, `generation_changed` = the child was revived for a newer run. The `applied` row keeps the checkout for [retention](worktrees.md#managing-disk-usage) or for you. |
| Applied checkouts accumulate under `.worktrees/` | `worktree.integration.keep_count` (default 15) is a soft cap: only `applied`, verified, inactive and unpinned checkouts are removed, oldest first. Parked (`queued`/`applying`/`resolving`), `needs_attention` and deliberately kept checkouts count toward the total but are never removed for quota — clean them up with `:PiWorktreeRemove` once you have dealt with them. |
| `:PiResume` reports it cannot recover a worktree | The session's checkout is gone and there is neither an applied integration record nor a snapshot to rebuild it from, so the picker refuses rather than opening the transcript in the main checkout. See [Resuming across worktrees](worktrees.md#resuming-across-worktrees). |
| `:PiWorktreeRemove` refuses to remove a worktree | A π process is still running with that checkout as its cwd. Close it first (`:PiStop`, `:PiSubClose`, `x` in `:PiSessions`) — check `:PiSessions` for a session you forgot, and the notification names the session. The guard also catches a child that only *inherited* the checkout (a sub-session of a session that already ran in a worktree): it owns no worktree metadata, so it is matched by its process cwd. |
| Snapshot failed / worktree NOT removed | The snapshot runs before any deletion and aborts the removal when it cannot be **written** (the path is under the repository's git dir — check permissions and free space) or when the patch cannot be captured **completely**: more than 20 000 untracked files, or an untracked path a patch cannot represent (typically a directory holding its own git repository). The error names the offending path — commit, ignore or delete it and retry; `:PiWorktreeApply` shares the same capture rules. With `worktree.snapshot_before_remove = false` removal skips the snapshot. |
| `:PiWorktreeApply` reports "Failed to read the worktree diff" | The worktree's patch cannot be captured completely (same rules as a snapshot: too many untracked files, or an untracked nested repository). Nothing is applied — commit, ignore or delete that path, then retry. See [Worktrees](worktrees.md#applying-a-patch-piworktreeapply). |
| `:PiWorktreeApply` asks "Apply into a live checkout?" | Expected, not an error: a π session is running **in the main checkout**, so the apply would rewrite files its agent may be using mid-turn. Cancelling writes nothing; confirming applies, after re-checking that the session you were warned about is still the only one there. Close that session (`:PiStop`) first if you want the write to go through without the extra prompt. See [Worktrees](worktrees.md#applying-a-patch-piworktreeapply). |
| `:PiWorktreeApply` says the main checkout "now has a running π session" | The re-check before the write found a *different* session than the one you confirmed (it started while the dialog was open, or in the gap up to the write). Nothing was applied — retry once that session is closed, or after the checkout is free. |
| Statusline component shows stale data | The statusline is pushed from RPC events; if they stopped flowing, `rpc.log` will show the gap. |
| Unhandled event warning | pi2.nvim doesn't yet know about a new event type the backend is sending. Please [open an issue](https://github.com/zgs225/pi2.nvim/issues) with the event name and a snippet of `rpc.log`. |
| Prompt paste shows `^[[106;5u` instead of a line break | The terminal pasted Ctrl+J as Kitty CSI-u (or `^[[27;5;106~` / `^[[13;2u`) instead of LF. π rewrites those sequences in the prompt paste handler. Type a newline with `<S-CR>` (or `<C-j>`); `<CR>` still submits. |
| `:PiTree` shows "Failed to decode RPC message: Found too many nested data structures" | The `get_tree` response for a very long session (roughly 500+ messages) is deeper than Neovim's built-in JSON decoder allows. See [Deep RPC payloads](#deep-rpc-payloads) below. |

## Deep RPC payloads

Neovim's `vim.json` (the bundled lua-cjson library) hard-caps JSON nesting at 1000 levels, which cannot be raised at runtime. The pi backend nests the session tree one level **per message**, so `get_tree` responses for long sessions — and with it `:PiTree` — used to fail with `Failed to decode RPC message: Found too many nested data structures (1001) at character N`, and the tree picker never opened.

Since 2026-08-11 pi2.nvim ships its own depth-tolerant JSON decoder (`pi.json`) as a fallback: incoming RPC lines that cjson refuses are re-decoded with it, so `:PiTree` works for sessions up to roughly 4000 messages (the fallback's defensive depth cap). Only when both decoders fail does the warning still appear — normally a sign of a genuinely malformed line; enable [RPC debug logging](#rpc-debug-logging) and check `rpc.log` in that case.
