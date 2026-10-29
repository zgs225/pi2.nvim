# Web console — plugin integration plan (W9 brief)

> Status: **historical plan / decision log.** The implementation has landed (branch `feat/web-console`);
> the current wire-level contract is documented in `doc/usage.md#web-console` and
> `pi2d/docs/protocol.md`, not here. Line numbers quoted below are from the planning base
> (`854c210`) and are stale — check the code, not this page, before editing.
> Drift between plan and reality is marked **[LANDED]**, **[CHANGED]** or **[NOT IMPLEMENTED]**
> at the affected section, with a summary in §8.
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

**[LANDED, one move]** `lua/pi/web/` has `protocol.lua`, `bridge.lua`, `state.lua`, `instance.lua`,
`commands.lua`, `history.lua`, `init.lua` — plus `runtime.lua` (hex/dir helpers, token read). The
headless bootstrap shipped as **`lua/pi/host.lua`** (module `pi.host`), not `lua/pi/web/host.lua`.

```
lua/pi/web/
  protocol.lua   (done)   constants, JSONL helpers
  runtime.lua    (done)   hex ids, runtime dirs, token, daemon log dir,
                          resolve_daemon() ladder (config → env → PATH → plugin
                          data → checkout; no npx)
  ops.lua        (done)   daemon process + user service: attach → `pi2 service
                          start` → spawn `<bin> daemon` (log redirect), `pi2
                          service status|start|stop|enable|disable`, log lines
  bridge.lua     (W4)     socket transport, framing, reconnect, throttle
  state.lua      (W5)     authoritative reducer per session (MAX_ENTRIES = 500)
  instance.lua   (W9)     instance identity, bridge wiring, event fanout, snapshots
  commands.lua   (W9)     cmd method table (manager/attention/tasks/subsessions)
  history.lua    (W6)     jsonl pagination + line-offset index
  init.lua       (W9)     setup(), start/stop, status, :PiWeb* commands
  ctl.lua        (done)   :PiWeb* entry points (install/service/log/pair/doctor)
  login.lua      (done)   loopback console-session handshake
  qr.lua         (done)   pairing QR renderer
lua/pi/host.lua  (W9)     headless bootstrap (`nvim --headless --listen …`)
```

### Daemon lifecycle ownership (pi2d ADR 0002)

- `runtime.resolve_daemon()` is a **lookup**. `npx` is gone; a miss is reported
  with the install commands, never bootstrapped.
- `ops.ensure()` is the only start path: **attach** (a published `daemon.json`
  is sufficient — a service-managed daemon must be usable even when no `pi2`
  is resolvable) → **service** (`pi2 service status` to see whether a unit is
  installed, then `pi2 service start`) → **spawn** (`<bin> daemon` detached,
  stdout/stderr appended to `$PI2_STATE_DIR/daemon.log`). `web.autostart`
  (`"auto"` | `"spawn"` | `false`, deprecated alias `web.auto_start`) gates it.
- `pi2 service …` is the only thing that talks to systemd/launchd. `:PiWebStop`
  stops the bridge only; stopping the daemon is `pi2 service stop` / `pi2 stop`.
- `:checkhealth pi` has a web section: binary source, daemon port, autostart,
  unit installed/enabled/active — file probes only (no subprocesses).


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

**[LANDED, with two changes]** The fanout is `pi.web.instance.on_event` at the tail of `M.handle_event`.
Attention hooks live in `attention.lua` itself (no `ui/extension.lua` edit): `M.present` emits
`pi2:attention_request` before queueing (headless included) and the local gate is `has_ui()` + prompt focus +
no draft. `M.resolve(session, request_id, by, response)` exists and removes the entry *before* forwarding the
response; `send_response` emits `pi2:attention_resolved` from one place, so every removal path (answer, expiry,
session transition, `clear_session`) announces it. The dialog is **not** closed by a remote answer — the local
entry only loses the race (`answer_entry` returns false and sends nothing).

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

**[LANDED, several shape changes]** The implemented surface (details in `doc/usage.md#command-contracts`):

- `session.create` uses `manager.create_for_web` (opens a tab, then restores the previous tab/win — not
  `create_detached`), and `session.create`/`open`/`resume` ack only after the backend id settles: up to 5 s of
  waiting for `get_state`, `pending = true` on timeout. The id migration (`tmp-N` → real id) is announced as
  `pi2:session {sessionId, previousSessionId}` **on the old id**, then the subscription/seq move to the new id and
  `instance_state` is refreshed (`instance:_migrate_session`).
- `session.setModel` takes `{model = {provider, id}}` (validated against the cached model list), `session.setThinking`
  `{level}` (validated against the pi thinking-level union).
- `queue.setSteer` takes `{mode = "all"|"one-at-a-time"}` and sends `set_steering_mode`; it is **session-wide**, so the
  web client's `{queueId, steer}` shape is accepted with the id ignored. `queue.remove` accepts `{id = "q:steer:N" |
  "q:follow:N"}` (1-based inside the kind, `0` = 0-based first entry), `{index}`, or the raw queued text.
- `attention.respond` normalizes `{response = {value | confirmed | cancelled}}` (string/`optionId`/`params.optionId`
  still accepted).
- `subagent.dispatch` takes `{items, wait, cancel_siblings_on_fail}` (a flat single-task shorthand is accepted);
  `task.output {taskId}` was added; `subagent.steer`/`subagent.read` are implemented too.
- Idempotency by `clientRequestId` is **not** implemented in the plugin: the daemon dedupes for 5 minutes
  (`pi2d/docs/protocol.md` §3.2). The plugin just ignores the field.

## 4. Snapshot construction

`instance.lua` builds `SessionState` from:
- the W5 state model (events applied since the session was opened),
- the session object (`id`, `cwd`, `name`, `model`, `thinking`, `tab`, `rpc` state),
- todos (`pi.todo`), tasks (`pi.tasks`), subagents (manifest), attention (`Attention` pending),
- `entries`: **[CHANGED]** the snapshot always carries a transcript **tail** — the newest entries that fit
  `MAX_SNAPSHOT_ENTRIES = 50` and `MAX_SNAPSHOT_ENTRY_BYTES = 256 KB` — instead of "empty unless the file is small".
  Anything older is paged through `workspace.query{kind="entries", before=…}` (`pi.web.history`, default limit 50).
- `attention`: **[LANDED]** always present as an array, full fields (`requestId`, `method`, `title`, `message`,
  `options`, `timeoutSec`, `createdAt`, `receivedAt`); a diff review is projected as `method = "diff"` with
  `payload` = the decoded JSON the extension put in `title` (the plugin does not reshape it; the web diff view reads
  the files from it). `flags.attention` mirrors "queue is non-empty", so an empty array clears a phantom.

Snapshot invariants: `seq` and `epoch` come from the instance's per-session counters (bridge), not from the state.
**[CHANGED]** `seq` is strictly increasing on the wire per session; coalesced frames (50 ms deltas, 100 ms tool
updates) get their seq **at flush**, so a reserved-but-later frame cannot overtake a newer one. The reducer keeps at
most 500 entries per session (`state.MAX_ENTRIES`). Clients may subscribe with `since: {sessionId, epoch, seq}`;
`resync_required` is the daemon's answer when that pair is gone.

## 5. Lease / ownership (multi-instance safety)

**[NOT IMPLEMENTED]** Kept as the design note. No lease file, no `E_LEASE`/`E_EXTERNAL_SESSION` in `commands.lua`;
opening the same session file from two places is allowed and the processes diverge (`doc/usage.md` says so).

The original rules, for reference:

- Key: `realpath(sessionFile)` (the file is only known after `get_state`, `manager.lua:1974`).
- File: `<runtime>/leases/<sha256(file)[:16]>.json` with `{instanceId, pid, bootId, heartbeatAt}`.
- Acquire before `Rpc:start` for a resume; release on `close_session`/`VimLeavePre`; heartbeat every 5s.
- Stale if pid missing, starttime mismatch (Linux `/proc`, macOS `ps -o lstart=`), or bootId differs.
- Conflict → `E_LEASE` with the owner instance; takeover is an explicit user action (stop the old one first).
- External sessions (no lease, recent mtime) → read-only, `E_EXTERNAL_SESSION` on write.

## 6. Headless host (`lua/pi/host.lua`)

**[LANDED, path changed]**

```
nvim --headless --listen <runtime>/i/<hash>.sock -u <user-init> -c 'lua require("pi.host").start()'
```

- `start()`: read the workspace from `vim.fn.getcwd()`, start `web.init.setup({lazy=false})`, then keep the loop
  alive (`--headless --listen` already stays alive — verified; do not use `-l script`).
- The daemon spawns this with `cwd = workspace` and records the returned `listenAddr`.
- TUI attach: `nvim --server <sock> --remote-ui` (nvim ≥ 0.9, verified present).
- `has_ui()` = `#vim.api.nvim_list_uis() > 0` (not `has("gui_running")`).

## 7. Risks / open questions

1. **Double-emit on rebuild replay** — confirmed the replay loop calls `M.handle_event` again; the fanout sits at
   the tail. **[LANDED]**
2. **Prompt extraction** — landed as `manager.prompt(session, text, opts)` (mention expansion, queue type, images),
   called by the web handler; `Chat:submit` keeps its own prompt-buffer path. **[LANDED]**
3. **Queue without Chat** — still true: `queue.remove`/`queue.setSteer` return `E_UNSUPPORTED` on a session without an
   attached chat, and web-created sessions are normal tab-backed sessions. **[NOT IMPLEMENTED]**
4. **Attention while headless** — `present` only calls `entry.open()` when `has_ui()`; headless queues + emits.
   **[LANDED]**
5. **`rpc.log_path`** — still derived from `getcwd()` (`rpc.lua:164`), i.e. one `rpc.log` per workspace. **[NOT IMPLEMENTED]**
6. **`session.chat` assumptions** — the web command paths guard `session.chat` before touching it. **[LANDED]**

## 8. Status summary (plan → reality)

| Plan area | Reality |
|---|---|
| §1 module layout | Landed; `runtime.lua` added, headless host is `lua/pi/host.lua` |
| §2 hooks | Landed; attention hooks live in `attention.lua` (`present`/`resolve`), `pi2:attention_resolved` is emitted from `send_response` for every removal path |
| §3 commands | Landed with shape changes (see the note there); `session.*` acks wait for the real backend id and announce the migration |
| §4 snapshots | Landed as a capped tail (≤ 50 entries / ≤ 256 KB), entries paged separately, `attention[]` always present |
| §5 leases | Not implemented — document-only design |
| §6 headless host | Landed as `pi.host` |
| §7 risks | 1, 2, 4, 6 resolved; 3 (queue without Chat → `E_UNSUPPORTED`) and 5 (per-workspace `rpc.log`) stand |

Daemon-side decisions the plugin now depends on (documented in `pi2d/docs/protocol.md`, not here):
pairing redeem is public (`POST /api/v1/pair {code, kind, deviceName}`) while *creating* a code is authenticated,
`GET /api/v1/devices` returns a bare array, `GET /api/v1/info` reports `hostname`/`os`/`version`/`uptimeMs`/`pid`/`port`,
and a WS `subscribe` may carry `since: {sessionId, epoch, seq}`.
