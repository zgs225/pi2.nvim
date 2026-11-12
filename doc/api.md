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
pi.worktree_new(opts?)        -- start a fresh session in a new git worktree (:PiWorktreeNew);
                              -- opts: { name?, layout? }
pi.worktree_fork(opts?)       -- fork the current conversation into a new git worktree (:PiWorktreeFork);
                              -- opts: { name?, layout? }
pi.worktree_open(opts?, cb?)  -- start a fresh session in an EXISTING directory (:Pi worktree=<name> /
                              -- :PiNewTab worktree=<name>; `:PiSessions` → W); opts: { name?, cwd?,
                              -- layout?, new_tab? }. `name` must be a managed linked checkout;
                              -- `cwd` may be any existing directory — a linked worktree (attached as
                              -- worktree metadata) or the main checkout / plain dir (ordinary session)
pi.worktree_branch(branch)    -- put the current worktree session on `branch`, creating it
                              -- when it does not exist (:PiWorktreeBranch)
pi.worktree_apply(opts?)      -- review a worktree's patch in the diff-review panel and apply it to
                              -- the main checkout's working tree on accept (:PiWorktreeApply);
                              -- opts: { name? }
pi.worktree_ship(opts?)       -- prefill a worktree session's prompt with commit/push/PR
                              -- instructions — never sent (:PiWorktreeShip); opts: { name? }
pi.worktree_remove(opts?)     -- confirm, snapshot, then remove a worktree (:PiWorktreeRemove);
                              -- opts: { name? }
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

The seven `pi.worktree_*` entry points above cover the [`:PiWorktree*` commands](worktrees.md) and the `worktree=<name>` start flag, and share their rules: a session inside a worktree refuses to create a nested one, `worktree_apply` never commits and never touches the index, `worktree_ship` never sends the prompt, `worktree_remove` refuses while a live session runs in the checkout, and `worktree_open` never creates or removes a checkout — an existing one only. `worktree_open` is also the entry point behind `:PiSessions` → `W`: its `cwd` may be any existing directory, and only a linked worktree becomes worktree metadata (the main checkout, or a directory outside a repository, starts an ordinary session there).

```lua
local pi = require("pi")

-- Start a fresh conversation in <repo>/.worktrees/fix-auth, detached at HEAD.
pi.worktree_new({ name = "fix-auth", layout = "side" })

-- Carry this conversation into a new checkout (parent session left untouched).
pi.worktree_fork({ name = "spike" })

-- Fresh session in a checkout that already exists (no create, no remove).
pi.worktree_open({ name = "fix-auth", layout = "side" }, function(session, err) ... end)

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
| `Worktree.create(opts, cb)` | `opts { cwd, name?, mode?, base? }` → `cb(info, err)`; creates `<repo>/.worktrees/<name>` detached at `base` (default `HEAD`), ensures `/.worktrees/` is in `.gitignore`, writes the metadata, copies `.worktreeinclude` ∩ gitignored files and runs `worktree.setup_cmd`. Refuses nested creation, a missing repository/commit and an invalid or existing name. |
| `Worktree.detect(cwd?)` | `pi.WorktreeInfo?` — pure filesystem read (no git subprocess, cached with cheap `stat` revalidation), safe on rendering paths. `kind` is `"linked"` or `"main"`. |
| `Worktree.list(cwd?, cb)` | `cb(entries, err)` — every live linked worktree of the repository containing `cwd` (from `git worktree list --porcelain`), each as its `detect()` info plus `head` / `branch` / `detached` / `prunable`, sorted by path. Bare, prunable and vanished checkouts are skipped. Backs the cross-worktree `:PiResume` rows. |
| `Worktree.status(info, cb)` | `cb({ dirty, ahead, head }, err)` — uncommitted changes, commits beyond `base_sha`, current `HEAD`. |
| `Worktree.diff(info, cb, opts?)` | `cb(patch, err)` — `base_sha` → now (untracked files included), or `opts.from` → now for an incremental capture (a reused checkout's new work only). Capture is all-or-nothing: it errors (rather than returning a partial patch) when the worktree has more than 20 000 untracked files or an untracked path a patch cannot represent (a directory holding its own repository). |
| `Worktree.snapshot(info, cb)` | `cb(path, err)` — writes that patch under `<git common dir>/pi2-worktree-snapshots/<name>/`, with the same all-or-nothing capture rules, so a failed snapshot never yields a truncated patch. A `<patch>.json` sidecar (`WorktreeSnapshotMeta`: name, path, repo_root, base_sha, head, created_at) keeps the snapshot self-describing after the checkout is gone. |
| `Worktree.latest_snapshot(repo_root, name)` | `{ path, meta? }` — newest snapshot of a worktree (used to restore a missing checkout on resume). |
| `Worktree.probe(target_dir, patch, cb)` | `cb("clean"\|"already"\|"conflict", err)` — `git apply --check`, then `--reverse --check`; nothing is written. Backs `:PiWorktreeApply`'s checked apply. |
| `Worktree.apply_patch(target_dir, patch, cb)` | `cb(ok, err)` — `git apply` into `target_dir`'s **working tree only** (no index, no 3-way, no commit). Atomic: a conflicting hunk aborts the whole patch. |
| `Worktree.branch(info, branch, cb)` | Attaches `branch` (creating it, or checking out the existing one). |
| `Worktree.release(info, cb)` | `cb(removed, err)` — removes the checkout **only** when clean and not ahead of base. |
| `Worktree.remove(info, opts, cb)` | `opts { force?, snapshot? }` → `cb(removed, err, snapshot_path)`; `snapshot` defaults to `worktree.snapshot_before_remove`. |
| `Worktree.bind(info, fields)` | Synchronous; publishes `{ session_id, session_file }` onto the worktree metadata. |

`WorktreeInfo` is the table every one of these accepts and returns (`kind`, `name`, `path`, `repo_root`, `git_dir`, `common_dir?`, `base_sha?`, `mode?`, `session_id?`, `session_file?`) — persist it (it is JSON-encodable) and hand it back to `status` / `diff` / `remove` later. `validate_name(name)` returns `ok, err` for the directory-name rules; `pi.worktree` also exposes `_reset` / `_set_runner` test hooks. Full guide: [Worktrees](worktrees.md).

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
