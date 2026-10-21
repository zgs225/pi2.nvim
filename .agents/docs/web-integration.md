# Web console — plugin integration plan (W9 brief)

> Status: plan only. Owner of this doc: orchestrator. Line numbers are from `feat/web-console`
> (base `854c210`). Verify before editing — they drift.
> Contract: `pi2d/docs/protocol.md`. Transport: `lua/pi/web/bridge.lua` (W4).
> State model: `lua/pi/web/state.lua` (W5).

## 0. Non-negotiables

1. **The plugin is the only authority.** The web path must call the *same* functions the TUI uses;
   no parallel orchestration, no direct `Rpc:send` from web handlers when a UI path exists.
2. **One nvim per workspace.** The instance's cwd is the workspace cwd. Do not introduce per-session cwd.
3. **Data lives once.** The web receives snapshots/events; it never owns state. No caching in the daemon.
4. **Headless must not crash on missing UI.** Gate local dialogs/windows on `#vim.api.nvim_list_uis() > 0`,
   never on `session.chat ~= nil` (web-created sessions do have a tab/Chat but no UI).
5. **No `print`.** Log to `vim.notify`/`pi.web.log` (file) — stdout is the RPC channel of the daemon.

## 1. Module layout to add

```
lua/pi/web/
  protocol.lua   (done)   constants, JSONL helpers
  bridge.lua     (W4)     socket transport, framing, reconnect, throttle
  state.lua      (W5)     authoritative reducer per session
  instance.lua   (W9)     instance identity, bridge wiring, event fanout, snapshot cache
  commands.lua   (W9)     cmd method table (manager/attention/tasks/subsessions)
  history.lua    (W6)     jsonl pagination + line-offset index
  host.lua       (W9)     headless bootstrap (`nvim --headless --listen …`)
  init.lua       (W9)     setup(), start/stop, status, :PiWeb* commands
```

## 2. Where to hook (minimal edits to existing files)

| Hook | Location | Change |
|---|---|---|
| Event fanout | `lua/pi/sessions/manager.lua:752` `M.handle_event` | At the **end** of the function (after all existing handling, before `return`), call `pi.web.instance.on_event(session, msg)`. Do not hook at the top: view/compaction rebuilds queue events and replay them through `handle_event`, which would double-emit. Verify the replay path still passes through the tail. |
| Attention requested | `lua/pi/ui/extension.lua:161` → `Attention.present` | Always emit a `pi2:attention_request` event (via instance), regardless of UI. Keep the local dialog only when `has_ui()` and the gate below passes. |
| Attention local gate | `lua/pi/attention.lua:541` `M.present` | Add `pi.web.instance.has_ui()` to the "present immediately" condition; headless always queues + emits. |
| Attention resolution | new `M.resolve(session, request_id, by, response)` in `attention.lua` | Remove the matching pending entry (today `open_pending_entry` removes only when locally opened → ghost dialog/counter), close the dialog if it is open for that id, and emit `pi2:attention_resolved`. |
| Todo | already per-session (`manager.lua:462` `update_todo_mirror` → `pi.todo.update_from_details(details, session)`) | Emit `pi2:todo` after the mirror update (read `require("pi.todo").state_for_session(session)`; if no such accessor exists, add one in `pi.todo`). |
| Queue | `Chat` queue (`ui/chat/init.lua`) + `queue_update` events from pi | Emit `pi2:` queue via the `queue_update` passthrough; the web renders `state.queue`. Prompt/steer from web must go through the same send path as `Chat:submit` (see §3). |
| Tasks | `lua/pi/tasks.lua` (registry) + `manager.lua:493` `handle_bg_task_message` | Emit `pi2:task` on create/update/exit. `Tasks.on_refresh` is already a listener registry — use it. |
| Subagents | `lua/pi/subsessions/*` + manifest | Emit `pi2:subagents` (full list per session) after dispatch/stop/settle; build the tree from the manifest (`subsessions/manifest.lua`). |
| Session state | `manager.lua` transitions (`agent_start`/`agent_settled`/`_process_exit`/compaction) | Emit `pi2:session` patches (status, model, thinking, usage, contextUsage, name). Keep the reducer as the only place that composes state. |
| Session lifecycle | `M.create_detached` (:1299), `M.load_session_path` (:1351), `M.close_session` (:1330), `M.stop` (:1431) | Notify the instance: sessions added/removed → `instance_state`, snapshot on demand, `pi2:process_exit`. |

## 3. Commands (web → plugin)

Implement `lua/pi/web/commands.lua` as `M.handlers[method](params, ctx)`; the bridge calls it. **Every handler must
delegate to existing plugin paths**:

| method | Delegate to | Notes |
|---|---|---|
| `session.create {workspaceId}` | `manager.create_detached(tab, {})` + create a tab? | **Decision:** web-created sessions default to a tab. Use `manager.new_tab()`/`get_or_create` on the *current* tab only if an instance tab is free; headless fallback must still create a tab object. Add `manager.create_for_web()` that reuses `get_or_create` semantics without stealing focus (`nvim_set_current_tabpage` guarded). |
| `session.open {sessionFile}` | `manager.create_detached` + `manager.load_session_path` | Lease check first (see §5). |
| `session.close {mode}` | `manager.close_session(session)` (stop) / stop rpc but keep file (hibernate) | |
| `prompt.send {text, images, mode}` | **extract** `Chat:_send_message` core into `manager.prompt(session, text, opts)` and make `Chat:submit` call it | Must preserve queue/steer/follow-up semantics and pending-queue rendering. |
| `prompt.abort` | existing abort path (`Chat`/manager) | Idempotent. |
| `queue.remove` / `queue.setSteer` | `Chat` queue methods | If Chat is absent for a headless session, move the queue into the session model first. |
| `session.setModel` / `setThinking` | `manager.refresh_state_and_pin` + RPC `set_model`/`set_thinking_level` | Reuse the exact RPC command builder used by the UI. |
| `attention.respond` | `Attention.respond`/`send_response` (`attention.lua:129`) then `Attention.resolve` | First-answer-wins; second returns `E_ATTENTION_RESOLVED`. |
| `subagent.dispatch/stop/steer/read` | `subsessions.batch` / `init.lua` host tunnel | The web is just another host caller; keep idempotency by `clientRequestId`. |
| `task.stop` | `tasks.stop` | |
| `workspace.query {kind="sessions"}` | `history.list(cwd)` + live registry merge | |
| `workspace.query {kind="entries", before, limit}` | `web.history` (W6) | |

**Never** call `rpc:send` directly from a web handler when the TUI has a higher-level path; that is how the two
renderers drift.

## 4. Snapshot construction

`instance.lua` builds `SessionState` from:
- the W5 state model (events applied since the session was opened),
- the session object (`id`, `cwd`, `name`, `model`, `thinking`, `tab`, `rpc` state),
- todos (`pi.todo`), tasks (`pi.tasks`), subagents (manifest), attention (`Attention` pending),
- `entries`: replay `get_messages` once at snapshot time (already used at `manager.lua:1556`) **or**
  leave entries empty and let the web page history via `entries?before=` (W6). Prefer the latter for big sessions;
  include the last N entries only when the file is small (< 2 MB) to make first paint instant.

Snapshot invariants: `seq` and `epoch` come from the instance's per-session counters (bridge), not from the state.

## 5. Lease / ownership (multi-instance safety)

- Key: `realpath(sessionFile)` (the file is only known after `get_state`, `manager.lua:1974`).
- File: `<runtime>/leases/<sha256(file)[:16]>.json` with `{instanceId, pid, bootId, heartbeatAt}`.
- Acquire before `Rpc:start` for a resume; release on `close_session`/`VimLeavePre`; heartbeat every 5s.
- Stale if pid missing, starttime mismatch (Linux `/proc`, macOS `ps -o lstart=`), or bootId differs.
- Conflict → `E_LEASE` with the owner instance; takeover is an explicit user action (stop the old one first).
- External sessions (no lease, recent mtime) → read-only, `E_EXTERNAL_SESSION` on write.

## 6. Headless host (`lua/pi/web/host.lua`)

```
nvim --headless --listen <runtime>/i/<hash>.sock -u <user-init> -c 'lua require("pi.web.host").start()'
```

- `start()`: read the workspace from `vim.fn.getcwd()`, start `web.init.setup({lazy=false})`, then keep the loop
  alive (`--headless --listen` already stays alive — verified; do not use `-l script`).
- The daemon spawns this with `cwd = workspace` and records the returned `listenAddr`.
- TUI attach: `nvim --server <sock> --remote-ui` (nvim ≥ 0.9, verified present).
- `has_ui()` = `#vim.api.nvim_list_uis() > 0` (not `has("gui_running")`).

## 7. Risks / open questions

1. **Double-emit on rebuild replay** — confirm the replay loop calls `M.handle_event` again; if so, emit at the tail.
2. **Prompt extraction** — `Chat:_send_message` is entangled with the prompt buffer (draft clearing, history).
   Extract carefully and keep `Chat:submit` behaviour byte-identical; add specs for both paths.
3. **Queue without Chat** — web-created sessions have a tab/Chat, but a TUI may never open it. Ensure queue
   operations do not require a visible window.
4. **Attention while headless** — `entry.open()` creates a dialog; headless must never call it. Only mark pending.
5. **`rpc.log_path`** — currently derived from `getcwd()` (`rpc.lua:164`), so all sessions in a workspace share a log
   file and truncate each other. Change to a per-session path (accept a small behavior change; document it).
6. **`session.chat` assumptions** — grep for `session.chat:` before shipping; every hit must be nil-safe.
