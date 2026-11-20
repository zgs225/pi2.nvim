# Lua API

Everything exposed by the [user commands](../README.md#commands) is also available from Lua. Grab the module once and call into it directly:

```lua
local pi = require("pi")

-- Setup (called once from your config entrypoint)
pi.setup(opts?)

-- Chat lifecycle
pi.show(opts?)                -- open the chat; opts: { layout = "side"|"float" }
pi.toggle(opts?)              -- open or hide the chat
pi.toggle_chat()              -- hide/show the chat windows for the current tab
pi.toggle_layout(cb?)         -- swap side ↔ float; cb runs after the swap completes
pi.is_visible()               -- boolean: is the chat shown in the current tab?
pi.layout()                   -- "side" | "float" | nil

-- Sessions
pi.new_tab()                  -- open a fresh conversation in a new tabpage (:PiNewTab)
pi.continue_session(opts?)    -- load the most recent session for the current cwd
pi.resume_session(opts?)      -- pick a past session for the current cwd
pi.new_session()              -- start a fresh conversation in the current tab
pi.tree()                     -- navigate the session tree (:PiTree)
pi.fork()                     -- new session from a past user message; picks forkable
                              -- messages, then prefills the prompt for re-asking (:PiFork)
pi.clone()                    -- duplicate the current branch into a new session (:PiClone)
pi.sessions()                 -- toggle the live sessions overview (:PiSessions)
pi.worktree_new(opts?)        -- start a fresh session in a new git worktree; opts: { name?, layout? }
pi.worktree_fork(opts?)       -- fork the current conversation into a new git worktree;
                              -- opts: { name?, layout? }
pi.worktree_open(opts?, cb?)  -- start a fresh session in an EXISTING directory (:Pi worktree=<name> /
                              -- :PiNewTab worktree=<name>; `:PiSessions` → n / N); opts:
                              -- { name?, cwd?, repo_cwd?, layout?, new_tab?, create?, tab_after? }. `name` is a managed
                              -- linked checkout; `repo_cwd` scopes it to an explicit repository;
                              -- `create = true` makes it first when it does not exist (the :Pi* commands
                              -- pass it); `tab_after` is the tabpage the new tab is inserted after
                              -- (default: its checkout's block via pi.sessions.tab_order — right after that
                              -- block's last tab, or the end of the tabline while the list is flat);
                              -- `cwd` may be any existing directory — a linked
                              -- worktree (attached as worktree metadata) or the main checkout / plain dir
pi.worktree_branch(branch)    -- put the current worktree session on `branch`, creating it
                              -- when it does not exist
pi.worktree_apply(opts?)      -- review a worktree's patch in the diff-review panel and apply it to
                              -- the main checkout's working tree on accept; opts: { name? }
pi.worktree_ship(opts?)       -- prefill a worktree session's prompt with commit/push/PR
                              -- instructions — never sent; opts: { name? }
pi.worktree_remove(opts?)     -- confirm, snapshot, then remove a worktree; opts: { name? }
pi.worktree_gc(opts?, cb?)    -- run the worktree retention sweep now (also scheduled, deferred,
                              -- after every create); opts: { cwd?, enabled?, max_count?,
                              -- max_age_days?, snapshot_days?, dry_run?, quiet?, skip? }
pi.worktree_sweep_locks(opts?, cb?) -- release `git worktree lock`s THIS plugin set whose owning
                              -- processes are gone; opts: { cwd? }
pi.tasks()                    -- toggle the background tasks panel (:PiTasks): the
                              -- background bash tasks reported by the bg-tasks
                              -- extension, with status and durations (see
                              -- doc/usage.md#background-tasks)
pi.session_stats(session?)  -- show the stats dashboard for a session: identity, tokens, cost, cache
                              -- waste, context: current tab's session by default; `s` in :PiSessions
                              -- shows the stats of the session under the cursor (:PiSessionStats)
pi.diff_review(session?)      -- review the git diff of every file changed by a session (:PiDiff);
                              -- `d` in :PiSessions reviews the session under the cursor
pi.set_session_name(name?)    -- set the session display name; without an arg, opens an
                              -- input dialog prefilled with the current name
pi.compact(instructions?, session?) -- manually compact a session (optional guidance); `c` in
                              -- :PiSessions compacts the session under the cursor
pi.toggle_auto_compaction()   -- flip automatic compaction on/off; the statusline
                              -- `compaction` component (a 󰏗 icon) shows the state
pi.changed_files()            -- string[]: files modified by edit/write tools this session

-- Agent control
pi.abort()                    -- cancel the current agent turn, keep the session alive.
                              -- On a parent session it cascades: all of its sub-sessions
                              -- and their batches are interrupted too; a child that
                              -- already received its task keeps its RPC process, while
                              -- one still spawning is reclaimed. While viewing a
                              -- sub-session it aborts only that child (plus any children
                              -- it spawned);
                              -- the parent is NOT interrupted — a parent blocked in
                              -- wait_subagents wakes up because the child's pending
                              -- batch items are settled as `cancelled`
pi.abort_bash()               -- cancel the running direct bash (!) command
pi.abort_retry()              -- cancel the auto-retry backoff ("Retrying…" state); only
                              -- takes effect while the core is between retry attempts
pi.set_steering_mode(mode)    -- how queued steering messages are delivered: "all" (every
                              -- queued steer after the current turn and its tool calls) or
                              -- "one-at-a-time" (one per turn boundary; backend default)
pi.set_follow_up_mode(mode)   -- how queued follow-up messages are delivered: "all" (every
                              -- queued follow-up at completion) or "one-at-a-time" (one
                              -- per completion; backend default)
pi.stop()                     -- kill the RPC process and close the chat for the current tab

-- Sub-sessions
pi.sub_new()                  -- spawn a background sub-session (:PiSubNew)
pi.sub_switch()               -- picker to switch to a child sub-session
pi.sub_parent()               -- return to parent session from child view
pi.sub_close()                -- close current sub-session process (file retained)
pi.sub_view()                 -- picker to view a child sub-session in a read-only float with live streaming (:PiSubView)

-- Prompt input
pi.send_mention(args?, opts?) -- insert an @-mention for the current buffer / selection
pi.attach_image(path)         -- queue an image file as an attachment
pi.paste_image()              -- queue an image from the clipboard (requires img-clip.nvim)
pi.invoke("/command")         -- invoke a backend slash command programmatically

-- Models
pi.cycle_model()              -- step to the next model in the configured (or all) list
pi.select_model()             -- dialog: pick from configured models, then pi's model scope
                              -- (--models/enabledModels), then all models
pi.select_model_all()         -- dialog: pick from every backend-available model

-- Thinking
pi.toggle_thinking()          -- show/hide thinking blocks in the history
pi.cycle_thinking_level()     -- step to the next thinking level
pi.select_thinking_level()    -- dialog: pick a thinking level

-- History blocks
pi.toggle_startup_details()   -- collapse/expand the startup block
pi.toggle_history_blocks()    -- collapse/expand all expandable history blocks

-- Attention queue
pi.attention()                -- open the oldest queued request, switching tab if needed
pi.attention_count(tab?)      -- integer: pending requests in a tab (current tab if omitted)
pi.attention_total()          -- integer: pending requests across all tabs
pi.attention_state(tab?)      -- full state snapshot for custom UI
pi.has_attention(tab?)        -- boolean shortcut for attention_count > 0

-- Navigation inside the chat
pi.focus_chat_history()
pi.focus_chat_prompt()
pi.focus_chat_attachments()
pi.scroll_chat_history(direction, lines?)          -- direction: "up" | "down"; lines defaults to 15
pi.scroll_chat_history_to_bottom()
pi.scroll_chat_history_to_first_agent_response()
pi.scroll_chat_history_to_last_agent_response()
pi.goto_file_under_cursor()   -- open the file referenced on the history line under the cursor

-- Debug
pi.toggle_debug()             -- toggle RPC debug logging for the current Neovim session
```

Most functions are no-ops (or warn) when no session is active in the current tab — safe to bind unconditionally. See [Usage](usage.md) and [Keymaps](keymaps.md) for how these fit into a working setup.

## Worktrees

The nine `pi.worktree_*` entry points above are the **only** worktree surface — pi2.nvim ships no worktree-verb user command (the `PiWorktree*` commands were removed), and the user-facing entry point for the first four is the `worktree=<name>` start flag (`:Pi` / `:PiNewTab`). They share their rules: a session inside a worktree refuses to create a nested one, creation releases the fresh checkout again when the session fails to start, creation locks the checkout (`worktree.lock`) and a removal releases that lock, `worktree_apply` never commits and never touches the index, `worktree_ship` never sends the prompt, `worktree_remove` refuses while a live session runs in the checkout and refuses a checkout locked by something other than π, and `worktree_gc` and `worktree_sweep_locks` are the only two with no user-facing entry point at all (no command, no keymap, no row) — they exist for scripts, tests and manual cleanup, and both are silent unless they changed something. `worktree_open` removes nothing — it opens an existing checkout, or creates one when `create = true` and the name is new. `worktree_open` is also the entry point behind `:PiSessions` → `n` / `N`: its `cwd` may be any existing directory, and only a linked worktree becomes worktree metadata (the main checkout, or a directory outside a repository, starts an ordinary session there). With `repo_cwd`, `name` resolution and creation use that explicit repository rather than the current tab's repository; this lets `N` create a sibling from the row's main checkout without treating the current tab's worktree as nested. A linked `repo_cwd` is still refused by `Worktree.create`.

```lua
local pi = require("pi")

-- Start a fresh conversation in <repo>/.worktrees/fix-auth, detached at HEAD.
pi.worktree_new({ name = "fix-auth", layout = "side" })

-- Carry this conversation into a new checkout (parent session left untouched).
pi.worktree_fork({ name = "spike" })

-- Fresh session in a checkout that already exists (no create, no remove).
pi.worktree_open({ name = "fix-auth", layout = "side" }, function(session, err) ... end)

-- Same, creating the checkout first when it does not exist (what the :Pi*
-- commands pass) — a taken tab is refused before anything is created.
pi.worktree_open({ name = "fix-auth", create = true, new_tab = false })

-- Resolve/create in an explicit repository, independent of the current tab.
pi.worktree_open({ name = "fix-auth", repo_cwd = "/repo", create = true })

-- An existing directory: a linked worktree keeps its metadata, the main
-- checkout (or a plain project dir) starts an ordinary session there.
pi.worktree_open({ cwd = "/repo/.worktrees/fix-auth", new_tab = false })
pi.worktree_open({ cwd = "/repo" })

-- Git side of the current worktree session.
pi.worktree_branch("feat/auth")

-- These act on the current session's worktree by default, or on a named one.
pi.worktree_apply({ name = "fix-auth" })
pi.worktree_ship()
pi.worktree_remove({ name = "spike" })
```

Each accepts an optional **second argument** — `fun(ok: boolean, err?: string)` — called on the terminal path (except a user-cancelled review or a cancelled removal, which simply report `false`). `pi.worktree_new` / `pi.worktree_fork` / `pi.worktree_open` take `fun(session: pi.Session?, err?: string)` instead, so a script can follow the session they started.

The git layer is a separate module, `require("pi.worktree")`, which is what `pi.worktree_*` and the sub-session spawner call. It never touches buffers, windows or notifications; every function takes a node-style callback `cb(result, err)` and runs git asynchronously:

| Function | Contract |
| --- | --- |
| `Worktree.create(opts, cb)` | `opts { cwd, name?, mode?, base?, setup?, session_id? }` → `cb(info, err)`; creates `<repo>/.worktrees/<name>` detached at `base` (default `HEAD`; a `mode = "subagent"` checkout gets a generated `sub-…` name), ensures `/.worktrees/` is in `.gitignore`, writes the metadata, **locks the checkout** (unless `worktree.lock = false`; a failed lock removes the fresh checkout and fails the create), copies `.worktreeinclude` ∩ gitignored files and runs `worktree.setup_cmd` unless `setup = false`. `session_id` is recorded in the lock reason. Refuses nested creation, a missing repository/commit and an invalid or existing name. |
| `Worktree.resolve_base(opts, cb)` | `opts { kind?, cwd?, repo? }` → `cb(sha, err)`. `kind = "head"` (default) is the commit `cwd`'s checkout is on, `"fresh"` is the repository's remote default branch (`origin/HEAD`, re-fetched at most once per 24 h with a 5 s cap, falling back to the cached ref then local `HEAD`), anything else is a revision (`<rev>^{commit}`). Backs `worktree.base_ref` and a dispatch item's `create.base`. |
| `Worktree.detect(cwd?)` | `pi.WorktreeInfo?` — pure filesystem read (no git subprocess, cached with cheap `stat` revalidation), safe on rendering paths. `kind` is `"linked"` or `"main"`. |
| `Worktree.lock_state(info)` | Synchronous, filesystem only, never errors: `{ locked, ours, reason? }` from `<git dir>/locked`. `ours` means the reason starts with `pi2 `. Asking whether a checkout is locked never shells out to git. |
| `Worktree.lock(info, opts, cb)` | `opts { session_id?, pid? }` → `cb(ok, err)`; takes the lock, or refreshes it (unlock, then lock with the new reason). A foreign lock is never touched: `cb(nil, "lock: … is locked (…)")`. Backs the create-time lock and the once-per-session relock that fills in `session` / `pid`. |
| `Worktree.unlock(info, cb)` | `cb(ok, err)` — releases **our** lock; an already-unlocked checkout is success (git's `is not locked` exit 128 is swallowed), a foreign lock is `cb(nil, "unlock: …")` and nothing runs. |
| `Worktree.list(cwd?, cb)` | `cb(entries, err)` — every linked worktree of the repository containing `cwd` (from `git worktree list --porcelain`), each as its `detect()` info plus `head` / `branch` / `detached` / `prunable` / `locked` / `locked_reason` / `managed`, sorted by path. Bare checkouts are skipped; a `.worktrees/` checkout whose directory is gone (which git reports as prunable) is still reported with `missing = true` (retention and the resume picker need it). Backs the cross-worktree `:PiResume` rows. |
| `Worktree.sweep_locks(cwd, cb)` | `cb({ released, kept, foreign }, err)` — releases the `pi2 ` locks WE set whose recorded pids (`pid`, `nvim`; `0` skipped) are all dead. Keeps a foreign reason, a lock taken on another host, and a lock with no pid field at all. Backs `pi.worktree_sweep_locks` and runs before every retention prune. |
| `Worktree.status(info, cb)` | `cb({ dirty, ahead, head }, err)` — uncommitted changes, commits beyond `base_sha`, current `HEAD`. |
| `Worktree.diff(info, cb, opts?)` | `cb(patch, err)` — `base_sha` → now (untracked files included), or `opts.from` → now for an incremental capture (a reused checkout's new work only). Capture is all-or-nothing: it errors (rather than returning a partial patch) when the worktree has more than 20 000 untracked files or an untracked path a patch cannot represent (a directory holding its own repository). |
| `Worktree.snapshot(info, cb)` | `cb(path, err)` — writes that patch under `<git common dir>/pi2-worktree-snapshots/<name>/`, with the same all-or-nothing capture rules, so a failed snapshot never yields a truncated patch. A `<patch>.json` sidecar (`WorktreeSnapshotMeta`: name, path, repo_root, base_sha, head, created_at) keeps the snapshot self-describing after the checkout is gone. |
| `Worktree.snapshot_gc(repo_root, opts, cb)` | `opts { keep_days?, live_names?, now? }` → `cb(removed, err)` — prunes snapshots of checkouts that are gone: `live_names[name]` keeps every patch of a still-registered checkout, otherwise the newest patch and its sidecar survive while younger than `keep_days`, and older ones (plus the emptied `<name>/` directory) are deleted. Missing directory → `cb(0, nil)`; nothing outside `pi2-worktree-snapshots/` is touched, and only names that pass `validate_name`. |
| `Worktree.latest_snapshot(repo_root, name)` | `{ path, meta? }` — newest snapshot of a worktree (used to restore a missing checkout on resume). |
| `Worktree.probe(target_dir, patch, cb)` | `cb("clean"\|"already"\|"conflict", err)` — `git apply --check`, then `--reverse --check`; nothing is written. Backs `pi.worktree_apply`'s checked apply. |
| `Worktree.apply_patch(target_dir, patch, cb)` | `cb(ok, err)` — `git apply` into `target_dir`'s **working tree only** (no index, no 3-way, no commit). Atomic: a conflicting hunk aborts the whole patch. |
| `Worktree.branch(info, branch, cb)` | Attaches `branch` (creating it, or checking out the existing one). |
| `Worktree.release(info, cb)` | `cb(removed, err)` — removes the checkout **only** when clean, not ahead of base and not locked by something other than π. |
| `Worktree.remove(info, opts, cb)` | `opts { force?, snapshot? }` → `cb(removed, err, snapshot_path)`; `snapshot` defaults to `worktree.snapshot_before_remove`. A foreign lock refuses the removal (nothing is unlocked, nothing removed); our own lock is released first, and a failing unlock aborts. |
| `Worktree.bind(info, fields)` | Synchronous; publishes `{ session_id, session_file }` onto the worktree metadata. |

`WorktreeInfo` is the table every one of these accepts and returns (`kind`, `name`, `path`, `repo_root`, `git_dir`, `common_dir?`, `base_sha?`, `mode?`, `owned?`, `reused?`, `session_id?`, `session_file?`, `managed?`, `locked?`, `lock_reason?`) — persist it (it is JSON-encodable) and hand it back to `status` / `diff` / `remove` later. `owned` marks a checkout the caller created (and may release); `reused` marks one adopted by name instead of created. `managed` is true when the per-worktree git dir carries π's `pi2-worktree.json` metadata — the **only** checkouts retention may prune (`Worktree.list` entries carry it as `managed` plus `locked` / `locked_reason`; a hand-made `git worktree add` checkout is `managed = false` and is never touched). `locked` / `lock_reason` come from `lock_state`. `validate_name(name)` returns `ok, err` for the directory-name rules; `pi.worktree` also exposes `_reset` / `_set_runner` test hooks. Full guide: [Worktrees](worktrees.md) — locks and retention in [Locking and retention](worktrees.md#locking-and-retention).

## Queue modes

`pi.set_steering_mode(mode)` and `pi.set_follow_up_mode(mode)` map to the backend's
`set_steering_mode` / `set_follow_up_mode` RPC commands and mirror the
`:PiSteeringMode [mode]` / `:PiFollowUpMode [mode]` user commands. An invalid
mode is rejected (an error notification), and a success notification reports the
mode now in effect.

- **Steering** controls messages queued while the agent is running (the `steer`
  RPC / `streamingBehavior = "steer"`). `"all"` delivers every queued steer
  after the current assistant turn's tool calls; `"one-at-a-time"` (backend
  default) delivers one steer per turn boundary.
- **Follow-up** controls messages queued for after completion (the `follow_up`
  RPC). `"all"` delivers every queued message once the agent finishes;
  `"one-at-a-time"` (backend default) delivers one per completion.

With no argument the commands read the backend's current value (`get_state`)
and switch to the other mode. The mode is per-session backend state, so — like
thinking level, model, and auto-compaction — it applies to the current tab's
session and is not cascaded to sub-sessions; a sub-session keeps its own mode
and can be changed from its view.
