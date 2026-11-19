# Worktrees

π sessions are cheap, and several of them can share one checkout — until they start editing the same files, or until one of them switches a branch under the others. A **git worktree session** gives a conversation its own checkout of the same repository, created under `<repo>/.worktrees/<name>` and left on a **detached HEAD** at the repository's current `HEAD` (or, with `worktree.base_ref = "fresh"` / an explicit base, at the remote default branch or any revision), so parallel agents never race on one working tree or on a branch.

Worktree support is opt-in per session, not a mode: you start a session in a new worktree with `:PiNewTab worktree=<name>` (a name that does not exist yet is created), open an existing checkout with `:Pi worktree=<name>`, or use the `pi.worktree_new()` / `pi.worktree_fork()` Lua API, and everything else — a session started with plain `:Pi` — behaves exactly as before.

- [What a worktree session is](#what-a-worktree-session-is)
- [Creating one](#creating-one)
  - [Naming](#naming)
- [Opening a session in a worktree](#opening-a-session-in-a-worktree)
- [Repository hygiene](#repository-hygiene)
  - [`.gitignore`](#gitignore)
  - [`.worktreeinclude`](#worktreeinclude)
  - [`worktree.setup_cmd`](#worktreesetupcmd)
- [Detached HEAD and attaching a branch](#detached-head-and-attaching-a-branch)
- [Applying a patch](#applying-a-patch)
- [Shipping the work](#shipping-the-work)
- [Removing a worktree](#removing-a-worktree)
- [Cleanup when a session closes](#cleanup-when-a-session-closes)
- [Sub-sessions](#sub-sessions)
  - [Creating a checkout for a child](#creating-a-checkout-for-a-child)
  - [Owning vs borrowing](#owning-vs-borrowing)
  - [Visibility and revive](#visibility-and-revive)
- [Resuming across worktrees](#resuming-across-worktrees)
- [Where you see it](#where-you-see-it)
- [Configuration](#configuration)
- [What this does not do](#what-this-does-not-do)

Related pages: [Sessions](sessions.md) · [Diff review](diff-review.md) · [Configuration](configuration.md) · [Lua API](api.md) · [Highlight groups](highlight-groups.md#sessions-overview)

## What a worktree session is

A worktree session is an ordinary π session whose process runs with the **worktree directory as its cwd**. Nothing in the chat is different — same prompt, tools, history, statusline — but the backend resolves its project files, tool paths, sessions and git state from that directory:

- The checkout is registered with git, starts on a **detached HEAD** at the repository's current `HEAD` (recorded as the worktree's *base commit*), and shares the repository's object store, refs and remotes.
- The session is a **new process in a new tabpage**. The conversation you started it from keeps running untouched, in its own tab (that is why the worktree entry points do not reuse the RPC `new_session` / `fork` commands, which rebind the current process and keep its cwd).
- Because pi resolves everything from the process cwd and has no `--cwd` flag, a session's workspace is **fixed at spawn**. A conversation cannot be moved into (or out of) a worktree halfway through — start a new session there, or use `pi.worktree_fork()` to carry the conversation along.
- Bookkeeping lives in the **per-worktree git dir** git itself creates (`<repo>/.git/worktrees/<name>/pi2-worktree.json`): the name, path, base commit, mode, and the session id/file bound to the checkout. It is written atomically, never inside the work tree, so it can never appear in `git status` or leak into a clone. Detection is a pure filesystem read (no git subprocess), which is why the chat badge and the sessions list can ask for it on every render.

## Creating one

| How | What it does |
| --- | --- |
| `:PiNewTab worktree=<name>` | Create the checkout (when it does not exist yet) and start a **fresh** conversation in a new tabpage whose cwd is `<repo>/.worktrees/<name>`. `:Pi worktree=<name>` does the same in the current tabpage. |
| `pi.worktree_new({ name?, layout? })` | The Lua form, always in a new tabpage. Without a name the checkout gets a generated one. |
| `pi.worktree_fork({ name?, layout? })` | Same, but the new process is bootstrapped from this conversation with `--fork <session file>`: the new session starts with this conversation's active branch (history) and continues in the worktree. The parent session file is not modified, and the sessions list marks the child `↳ forked from <name>`. |

There is no worktree-verb user command (the `PiWorktree*` commands were removed): the flag is the user entry point, the `pi.worktree_*` functions are the API, and binding one is a keymap:

```lua
vim.keymap.set("n", "<leader>aw", function() require("pi").worktree_new() end)
vim.keymap.set("n", "<leader>aF", function() require("pi").worktree_fork({ name = "fix-auth" }) end)
```

All of them use the current session's cwd to find the repository. `layout` (`"side"` / `"float"`) selects the new tab's chat layout.

A checkout created by hand works just as well: `git worktree add .worktrees/<name>` from the repository root, then `:PiNewTab worktree=<name>`. Nothing else is required — the badge, the `:PiSessions` group and the resume partition come from git's own metadata.

`worktree_fork` is refused while the agent is streaming (wait for the turn to finish), when the conversation is empty (there is nothing to fork yet), when the session has no file yet, and when `pi.cli.args` contains a session-selecting flag (`--continue` / `-c`, `--resume` / `-r`, `--session`, `--no-session`) — those conflict with the `--fork` it needs to append.

Creation is refused, with an explicit message, when:

- the directory is not inside a git repository, or the repository has **no commits yet** (there is no base commit to detach from),
- the current session **already runs in a worktree** — worktrees are never nested; fork or create from the main checkout instead,
- the target directory already exists,
- the name is invalid (see below).

If the process fails to start after the checkout was created, the fresh worktree is released again instead of being left behind empty.
### Naming

The optional argument names the directory under `<repo>/.worktrees/`. Without one, the name is generated from the current time plus this Neovim process's pid and a spawn counter (`wt-<YYYYmmdd-HHMMSS>-<pid>-<seq>`) — a timestamp alone repeats within the same second, so back-to-back creations would collide on one directory.

Valid names are 1–64 characters, must not start with `.`, and may only contain letters, digits, `.`, `_` and `-`. A name is always a single directory component — `pi.worktree_apply` / `pi.worktree_ship` / `pi.worktree_remove` accept one too, and `worktree=<name>` completion offers the existing names of the current repository.

## Opening a session in a worktree

A managed checkout outlives the session that created it: it stays on disk until it is released or removed. To open a **fresh** conversation in it, pass `worktree=<name>` to a start command:

| Command | What it does |
| --- | --- |
| `:PiNewTab worktree=<name>` | Start a fresh conversation in a **new** tabpage whose cwd is `<repo>/.worktrees/<name>`. |
| `:Pi worktree=<name>` | The same, in the **current** tabpage; refused while that tab already runs a session (the message points at `:PiNewTab`). |

**A name that does not exist is created**, so the same two commands are also the normal way to start a worktree session (a fresh conversation, exactly like `pi.worktree_new()`; use `pi.worktree_fork()` when the conversation should be carried along). Creation is skipped when the tab is taken — `:Pi worktree=<new>` in a busy tab reports the conflict and writes nothing. An existing checkout is opened as it stands, never reset or cleaned.

In `:PiSessions`, **`N`** performs the same fresh-session flow for the repository of the row under the cursor. It lists the repository's **main checkout** first — `git worktree list` never reports the main work tree, so that row is built from the repository root and labelled `· main checkout` — then every live linked worktree reported by git — including a checkout created by hand outside `.worktrees/` — with its path and branch/detached state, plus **New worktree…**. Selecting an existing checkout opens it by `cwd` without resetting or cleaning it (the main checkout as an ordinary session there); choosing **New worktree…** asks for a name and creates `<repo>/.worktrees/<name>` from the main checkout's current `HEAD`, detached, before opening the new tab. Cancelling either dialog does nothing, and missing checkouts are not offered. Enumeration happens only on this keypress, never while the sessions list renders.

From Lua the same entry point is `pi.worktree_open(opts, callback)`:

```lua
pi.worktree_open({ name = "fix-auth", layout = "side" }, function(session, err) ... end)
-- `create = true` is what the :Pi* commands pass: a missing checkout is made first.
pi.worktree_open({ name = "fix-auth", create = true, new_tab = false })
-- Scope name resolution and creation to an explicit repository.
pi.worktree_open({ name = "fix-auth", repo_cwd = "/repo", create = true })
pi.worktree_open({ cwd = "/repo/.worktrees/fix-auth", new_tab = false })
-- The main checkout (or any project directory) starts an ordinary session there.
pi.worktree_open({ cwd = "/repo" })
```

`repo_cwd` scopes `name` resolution and creation to an explicit repository instead of the current tab's repository; it is how `:PiSessions` → `N` creates a sibling from the row's main checkout even when the current tab already runs in a worktree. A linked `repo_cwd` is still refused by `Worktree.create`, and `cwd` takes precedence and ignores `repo_cwd`. `new_tab` defaults to `true`; `cwd` wins over `name` and may be **any existing directory** — a linked worktree is attached as worktree metadata (chat badge, `pi.worktree_*` target, session binding), while the **main checkout** or a plain project directory starts an **ordinary** session whose cwd is that path, with no worktree metadata and no binding written. That is also the entry point behind `:PiSessions` → `n`, which passes the selected row's checkout as `cwd`. `tab_after` places the new tabpage right after an existing one instead of at the end of the tabline: `:PiSessions` passes the last tab of the row's worktree group — whose rows that list keeps contiguous — so the session it opens does not land behind every other checkout's tabs (an invalid handle is ignored, and `new_tab = false` has no tab to move). `create` defaults to `false` and never applies to `cwd`: the [`:Pi*` commands](#opening-a-session-in-a-worktree) pass `create = true`, while a plain `pi.worktree_open({ name = … })` still insists on an existing checkout and reports how to create one. Nothing is ever *removed*: a failed process start closes the empty scratch tab and leaves a pre-existing checkout exactly as you left it (only a checkout created by that same call is released again). Starting a session is silent (the chat opening in its tab is the feedback); only failures notify. Names complete from the current repository's `<repo>/.worktrees/*` in both commands, and `:PiContinue` / `:PiResume` reject the flag (they pick their own workspace). A worktree's recorded session binding is written only when it has none, so opening a second session there never steals the first one's binding.

## Repository hygiene

Creating a worktree touches exactly one file outside `.worktrees/`, and only when needed:

### `.gitignore`

`/.worktrees/` is appended to the repository's `.gitignore` (unless git already ignores `.worktrees/` — `/.worktrees`, `.worktrees/` and `.worktrees` count as equivalents). The file is written atomically and **never staged or committed**: the ignore line is yours to review, commit and share (or discard, in which case the checkouts show up as untracked files).

### `.worktreeinclude`

A fresh checkout only contains tracked files, so per-repository local files — a `.env`, a local config override, cache directories — are missing in it. Put one glob per line in a **`.worktreeinclude`** file at the repository root (`#` starts a comment, blank lines are ignored) to copy them into every new worktree of this repository.

Only files git **ignores** are copied: the copy is the intersection of `.gitignore` and `.worktreeinclude`. Tracked files are already in the checkout, and copying them would only risk clobbering the base commit. The `.worktrees/` directory itself is never copied (so the copy cannot recurse), and a pattern matching more than 20 000 files is refused loudly instead of hanging the editor. The same cap bounds how many untracked files a patch capture will include (see [Removing a worktree](#removing-a-worktree)).

```
# <repo>/.worktreeinclude
.env
.env.local
config/settings.local.json
```

### `worktree.setup_cmd`

Projects that need a build/bootstrap step in a fresh checkout (install dependencies, generate a local config, prime a cache) can name one command to run inside the new worktree:

```lua
require("pi").setup({
    worktree = {
        -- Run directly (no shell) with the worktree root as cwd, before the
        -- session process starts.
        setup_cmd = { "mise", "install" },
    },
})
```

The command's exit status decides what happens: `0` → the session starts in the worktree; non-zero → creation **fails**, the session is not started, and the error notification carries the tail of the command's output. The worktree itself stays on disk (it is already registered with git), so nothing is lost — fix the problem and create the session there again, or remove the checkout with `pi.worktree_remove()`.

## Detached HEAD and attaching a branch

Worktrees are created detached on purpose: a branch can only be checked out in one worktree at a time, and the point is not to take the branch away from the main checkout (or from another agent). Your work therefore starts on the base commit, and `git status` / `git diff <base>` are the natural views of it.

When the work needs a branch name — to push it, or because you prefer to commit on a branch — attach one explicitly:

| Lua | What it does |
| --- | --- |
| `pi.worktree_branch(branch)` | Run `git checkout -b <branch>` inside the current session's worktree. If that branch already exists in the repository, it is checked out instead. |

The call operates on the **current session's** worktree (the session must be running in one), validates the name with `git check-ref-format --branch`, and reports success in a notification. It does not touch the session, its tab, or its conversation — only git state. `git switch -c <branch>` inside the checkout does the same thing.

## Applying a patch

Work done in an isolated checkout stays isolated until you move it out. `pi.worktree_apply({ name? })` is the deliberate, reviewed way to do that:

1. It collects the worktree's patch relative to its **base commit**, including untracked files (they arrive as full-file additions). Capture is **all or nothing**: if the worktree has more than 20 000 untracked files, or an untracked path that a patch cannot represent (most commonly a directory holding its own git repository — a nested clone, a vendored repo, a submodule checkout), the call reports the error and opens nothing rather than reviewing a partial patch.
2. It opens the [session diff review panel](diff-review.md#session-diff-review-pidiff) with that patch — file list, per-file diff, `<CR>` jumps into the **worktree's** copy of the file. An empty diff is reported and nothing opens.
3. Pressing **`a`** (labeled `a apply to <repo>` in the list hint, where `<repo>` is the main checkout's directory name) applies the whole patch to the **main checkout's working tree** with `git apply`.

**Applying into a live checkout.** If a π session is running in the main checkout, `a` does not write immediately — the agent there may be reading and writing those same files mid-turn. A confirmation (`Apply into a live checkout?`) names the checkout and the session id and explains the risk; cancelling writes **nothing**. Confirming re-checks right before the write: a *different* session that appeared while the dialog was open (or in the gap up to the write) aborts the apply with an error naming it, so consent is tied to the session you were warned about and never extends to a new one.

What it never does: it does not stage files (the index is yours), does not create a commit, and never applies without that explicit accept — closing the panel applies nothing. `git apply` is atomic, so a conflicting or failed apply leaves **both** checkouts exactly as they were: files already modified in the main checkout that the patch would overwrite make the whole patch abort rather than partially apply.

Without a name the target is the current session's worktree (or the linked worktree its cwd lives in, for a resumed session); a name resolves under `<repo>/.worktrees/<name>` and must be a real linked worktree, so it can never point outside the checkout directory.

```lua
require("pi").worktree_apply()                          -- this session's worktree
require("pi").worktree_apply({ name = "fix-auth" })     -- … or the worktree named fix-auth
```

## Shipping the work

Once the patch is applied elsewhere, the worktree's own commits (and the branch they live on) still have to reach the remote. `pi.worktree_ship({ name? })` prefills the target session's prompt with a plain-text brief for the agent: the worktree's absolute path, the main checkout, `HEAD` and the base commit, whether it is dirty or how many commits ahead it is, and the requirements — create a branch if `HEAD` is still detached (suggested name `pi/<worktree>`), commit inside the worktree only, push, open a pull request, resolve conflicts itself, and never force-push shared branches or rewrite pushed commits.

**The prompt is not sent.** It waits in the prompt buffer for you to review, edit and submit — pi2.nvim neither submits it nor commits anything on your behalf. If the target session lives in another tab that is still attached, the call switches there so you can review the text in place; when that session's chat exists but its tab is gone (or it has no chat at all), it reports how to open it (`:PiSessions` / `:PiSubSwitch`).

## Removing a worktree

`git worktree remove` refuses a dirty checkout, which is the right default but not a workflow: `pi.worktree_remove({ name? })` removes the checkout **explicitly**, with the guards that make that safe.

- **A live session refuses the removal.** If any π process still runs with the worktree as its cwd (a tab session, a sub-session child, or a detached process you cannot see), the call errors out and names the session to close first (`:PiStop`, `:PiSubClose`, or `x` in `:PiSessions`). Deleting a live cwd breaks the agent's next tool call. The guard matches three things: the session's worktree metadata, the session's **process cwd**, and the session id recorded on the worktree — so a child that merely *inherited* the checkout (a sub-session of a session that already ran in a worktree, which owns no worktree metadata of its own) is caught by its cwd and still blocks the removal.
- **You confirm first**, and the dialog tells you what is at risk: uncommitted changes, commits ahead of the base commit, or both.
- **A snapshot is written before anything is deleted** (`worktree.snapshot_before_remove`, default on): the same patch `pi.worktree_apply` would review — base commit → current state, untracked files included — is saved to `<git common dir>/pi2-worktree-snapshots/<worktree>/<YYYYmmdd-HHMMSS>.patch` (i.e. under `.git/`, which survives the checkout). **If the snapshot fails, nothing is removed** and the error is reported. With `snapshot_before_remove = false` the confirmation warns that the work will be lost instead.
- **Capture fails closed.** A snapshot that silently dropped files would be worse than none, so the patch is only written when it is complete: untracked content beyond the 20 000-file cap, or an untracked path a patch cannot represent (an untracked directory holding its own git repository — a nested clone, a vendored repo, a submodule checkout — produces no diff), aborts the snapshot and therefore the removal, with a message naming the offending path. Commit, ignore or delete that path, then retry. `pi.worktree_apply` shares the same capture rules.
- Only then does it run `git worktree remove --force` followed by `git worktree prune`, so the metadata and the checkout are both gone. The notification includes the snapshot path.

Snapshots are written, never pruned: they are ordinary patch files you can `git apply` later, and pi2.nvim does not garbage-collect them.

## Cleanup when a session closes

An explicit close is the normal end of a worktree session, and it cleans up after itself:

- Closing the session's process (`:PiStop`, `x` in `:PiSessions`, `:PiSubClose` for a child, or the process exiting on its own) releases its worktree. Only a checkout the session **owns** is released: a linked worktree explicitly assigned to a sub-session is borrowed and never touched by close, crash, reaping or Neovim exit (see [Sub-sessions](#sub-sessions)). `x` on a session row of the sessions list is an explicit close like `:PiStop` (it also closes the tab), and `x` on a worktree group header closes every session of that checkout the same way, so an owned checkout is released once its last session stops.
- **Release deletes a checkout only when nothing would be lost** — no uncommitted changes and no commits beyond its base commit. A dirty or ahead worktree is **kept**, and a notification names the path (`Worktree kept: <path> …`) so you can inspect, apply or ship it.
- **Release snapshots before deleting**, like every other removal: a clean checkout's patch is empty, so what it leaves behind is an **empty patch plus its `.patch.json` sidecar** — a record of the checkout (name, path, base commit, HEAD, time) that survives the directory and lets the session still be found on resume. If writing that snapshot fails, the checkout is **kept** instead of deleted.
- Closing a tab (`:tabclose`) does **not** close the session (see [Sessions → One chat per tab](sessions.md#one-chat-per-tab)), so it does not release the worktree either — an ordinary background session keeps its checkout. Closing it from the sessions list (`x`) is the explicit close that does.
- `pi.worktree_remove()` is the explicit path when you want the directory gone regardless of state (subject to its snapshot).

## Sub-sessions

Sub-sessions ([Sessions → Sub-sessions](sessions.md#sub-sessions)) run in the **parent session's cwd by default**. A spawned child edits the same working tree as its parent, so several children in one batch share those files unless you give them their own checkouts.

A `dispatch_subagents` **spawn** item chooses its child's checkout with `worktree`, in one of two mutually exclusive shapes:

```lua
dispatch_subagents({ items = {
    -- create (or adopt) a checkout for this child
    { task = "…", name = "auth-review", worktree = { create = { base = "head" } } },
    -- borrow an existing linked worktree
    { task = "…", name = "schema-fix",  worktree = { path = "/repo/.worktrees/schema-fix" } },
} })
```

The same field is accepted by the Lua spawner (`require("pi.subsessions").spawn(parent, { task = "…", worktree = { create = true } })`). Omitting it keeps the default: the child inherits the parent's cwd.

### Creating a checkout for a child

`worktree = { create = true }` (or `create = { … }`) lets π prepare the checkout:

| `create` field | Meaning |
| --- | --- |
| `base` | Where the new checkout starts: `"head"` (default — the commit the parent's checkout has checked out), `"fresh"` (the repository's **remote default branch**, `origin/HEAD`), or any revision git accepts (`"origin/main"`, a tag, a sha). Omitted: `worktree.base_ref`, which defaults to `"head"`. |
| `name` | Checkout name under `<repo>/.worktrees/` (1–64 chars: letters, digits, `.`, `_`, `-`). Omitted: a generated `sub-<timestamp>-<pid>-<n>` name. |
| `setup` | Run `worktree.setup_cmd` in the new checkout (default: `subagent.worktree.setup`, i.e. **off**). Ignored when an existing checkout is adopted. |

- **Why `head` is the default.** A child normally works on the code you are looking at, including the commit that checkout is on. `fresh` starts from the released state (right for "fix this on current main"): it reuses the cached `origin/HEAD` and re-fetches the default branch at most once per 24 h, capped at 5 s, falling back to the cached ref and then to local `HEAD` — a spawn never hangs on a dead or slow remote.
- **Uncommitted changes do not travel.** The checkout starts at a commit; your dirty files stay in your tree. Commit first, or point the child at a checkout that already exists (`path`, or a `name` you prepared).
- **Creation never nests.** The checkout is always created from the repository's **main work tree**, even when the parent session itself runs in a worktree. `/.worktrees/` is added to the repository `.gitignore`, `.worktreeinclude` matches are copied, and — only with `setup = true`, since a dependency install per child is expensive — `worktree.setup_cmd` runs.
- **Adoption by name.** If `name` already resolves to a linked worktree of the **same repository**, π **adopts** it instead of creating: nothing is reset, rebased, re-checked-out or cleaned, and `base` is ignored (reported back as `base_ignored`), so a follow-up dispatch lands in the work an earlier child left behind. A same-named directory that is not a linked worktree of this repository is an error — it is never replaced.

### Owning vs borrowing

Only a checkout **this spawn created** is *owned*: it is released when the child settles (or is closed) with no uncommitted changes and no commits of its own, and kept — with its path reported — otherwise. An owned checkout is recreated **in place** on revive when its directory vanished (at the recorded base commit, retried at `HEAD` when that commit no longer resolves); if even that fails, the child runs in the parent's workspace with one warning instead of failing the revive. A checkout recorded by a version that predates ownership carries no `owned` flag: it is used while it exists and never recreated.

A `{ path }` assignment and an adopted `{ create = { name } }` checkout are **borrowed**, never owned by the child or by π: no release, no reset, no bind, no snapshot, no cleanup. Closing the child, its process crashing, idle reaping and quitting Neovim all leave them exactly as they are — commits and uncommitted work stay for you to inspect and ship with git or `pi.worktree_apply` / `pi.worktree_ship`.

A `{ path }` must be **absolute**, already exist, be a **linked** worktree (the main checkout is refused), belong to the **same repository** as the parent's workspace, and is canonicalized to the checkout's real root, so a subdirectory or a symlinked path still resolves to it. Dirty state and checkouts created by hand (`git worktree add …`) are fine.

Giving several items (or several children over time) the **same** `path` or `name` deliberately shares one checkout. No isolation is enforced between those children, so give them disjoint files; use a distinct checkout per child when they must not see each other's working tree. A worktree is **file-level isolation only, not a sandbox**: the child can still read absolute paths elsewhere, run commands, reach the network, and use the credentials its process inherited. Constrain tools with `subagent.tools` when that matters — that is enforcement, not a request.

### Visibility and revive

`worktree` is **spawn-only**. A reuse item (`{ target, message }`) rejects it and keeps the checkout the child already runs in. A revived child keeps its recorded checkout; an **assignment** that is gone, moved, no longer linked, or now belongs to another repository fails the revival with that error and does **not** fall back to the parent's workspace (an owned checkout is recreated first, as described above).

`list_subagents` reports the child's checkout as `{ path, name?, owned?, reused? }` (absent for a child running in the parent's cwd), a dispatch block badges the item with `󰙅 <name>` — the checkout its result recorded, or, until that result exists, the request itself (`{ path }`, a `create.name`, or `󰙅 +new` for an anonymous `create`) — and `read_subagent` reads the transcript recorded for the child (`session_file`) — for a child in another checkout that JSONL lives in that checkout's own session directory. `:PiSessions` and the `p` viewer show or replay the child's actual cwd. No row claims the parent's workspace.

To keep a whole batch out of your own checkout, isolate at the **session** level instead: dispatch from a session that already runs in a worktree (`pi.worktree_new()`, `:PiNewTab worktree=<name>`), and every child inherits that checkout while your main checkout stays clean.

The automatic-integration engine and its `worktree.integration` knobs are gone; manual control (review before applying, shipping a branch) stays with [`pi.worktree_apply` / `pi.worktree_ship`](#applying-a-patch). Nothing is ever merged or applied for an owned child checkout automatically.

## Resuming across worktrees

`:PiResume` lists the sessions of Neovim's cwd **and of every linked worktree of the same repository** — git's own view, so a checkout you created yourself (`git worktree add ../x`, or a worktree root of your own) is listed exactly like one π created under `<repo>/.worktrees/`. A worktree session can therefore be reopened without `:cd`-ing into its checkout. Each item carries its checkout's info table, and the picker groups sessions per checkout — a `󰙅 <name>` title per linked worktree and the project name for the main checkout, shown once the list spans two or more checkouts (a single checkout stays a flat list). The checkout the calling tab's session runs in leads the list (its session cwd — a worktree session never moves Neovim's cwd — falling back to Neovim's cwd), and the remaining partitions follow by their newest session. Opening one restarts the process **in that checkout** (closing the current one first when the cwd differs, and refusing while that session is streaming) instead of loading the transcript in the main checkout; opening into a new tab leaves the current session running. Being π-managed is not a filter: it decides the badge, `pi.worktree_ship` / `pi.worktree_apply` and the session binding, never whether a checkout is listed.

Enumeration covers checkouts git still reports (including prunable ones whose directory is gone) **and** checkouts deleted but still present in the snapshot store (`Worktree.snapshot_worktrees` reads `<git common dir>/pi2-worktree-snapshots/`, including the empty patches a clean release leaves). A checkout only earns a title while a **top-level** session lives there, so a checkout holding nothing but a sub-session transcript contributes no row at all (sub-sessions belong to `:PiSessions` / `:PiSubSwitch`). Enumeration runs only when the repository shows it has other checkouts — git's linked-worktree registry (`<git common dir>/worktrees/`, a pure directory probe), a `<repo>/.worktrees/` directory, or a snapshot store — so a single-checkout project keeps the old single-workspace picker and never spawns git for it.

A listed checkout can be gone by the time you pick it (retention removed it, or it was deleted by hand). Recovery runs **before** any process is touched and never falls back to the main checkout:

- the checkout directory exists → used as-is, with its metadata re-detected;
- the row records an **applied** integration (or a snapshot sidecar says so) → the checkout is recreated at the repository's **current `HEAD`**, because the work is already in the parent;
- the snapshot exists but its **patch is empty** (the checkout was released clean, so there was nothing to preserve) → the checkout is recreated at the recorded base and **nothing is applied**: the restore is a no-op;
- otherwise the **latest snapshot** is required: the checkout is recreated at the recorded base commit and the snapshot patch is applied into it, so the conversation continues with its unintegrated work intact;
- neither an integration record nor a snapshot → the picker reports that it cannot recover the worktree and opens nothing.

`:PiContinue` stays scoped to Neovim's cwd — it is "the most recent session here", not a cross-worktree picker.

## Where you see it

- **Chat history title** — a session running in a linked worktree shows `󰙅 <name>` next to the panel title (in the side-layout winbar and the float border), with a trailing `*` while the checkout is dirty or has commits ahead of its base commit. When the session's cwd is **not** Neovim's cwd — normally the case for every worktree session, since starting one does not change Neovim's cwd, and also for a session resumed from another directory — the badge is prefixed with `⚠` in the warning color, because paths you open from your own buffers and paths the agent touches may diverge; `worktree.warn_on_cwd_mismatch = false` drops that prefix and keeps the plain badge. A session in the repository's main worktree with Neovim's cwd shows no badge.
- **`:PiSessions`** — once the list spans **two or more distinct worktrees**, rows are grouped under a worktree header (`▾ 󰙅 <name> · ~/path`, and `▸ 󰙅 <name> (n) · ~/path` while the group is folded), and `<Tab>` / `za` folds a whole group (`zM` / `zR` collapse or expand everything). Group order is **fixed by the tabline**: each group sits where its **first tab** sits, so the headers never move on their own — no transcript activity and no focus-dependent pin reorders them (`:PiResume` keeps its own recency + current-checkout partition order). The `(n)` is the group's **structural** size — every parent row plus its sub-sessions — and it is displayed while the group is collapsed, does not move when a parent row *inside* the group folds, and only folding the group itself changes what is shown. The header carries the worktree's name for its whole group, and a sub-session row inside it repeats that name in its subtitle (a parent row is already under that header) — unless the child was assigned a different checkout, whose own name and path it shows instead — while a worktree fork carries the `↳ forked from <name>` marker. Sessions whose cwd is not a work tree keep their flat rows, so a single-repository list looks exactly as before. `R` re-detects worktrees along with session names.
- **Highlight groups** — `PiChatHistoryWorktree` (badge in the history title) and `PiSessionsListWorktree` (worktree group header, and the badge in the `p` viewer footer); see [Highlight groups](highlight-groups.md).
- **Sub-session viewer** — the `p` preview float carries the checkout the viewed session ran in as a `󰙅 <name>` footer badge, first in the statusline strip and styled like the group header. It comes from the row's own label when the list already resolved one (a child's *assigned* checkout, or the group a parent row is listed under — a parent's subtitle deliberately omits the name because the header above says it, and the header is not inside the float) and otherwise from the cwd recorded in the session (`Worktree.detect`, a cached filesystem read done once per `open`, never per streamed event). Only a **linked** worktree is badged — a session in the repository's main checkout shows none, matching the chat title — and `subagent.viewer.worktree = false` drops the badge while keeping the rest of the footer (`subagent.viewer.statusline = false` drops the whole footer, badge included).
- **Sub-session visibility** — `list_subagents` reports a child's checkout as `{ path, name?, owned?, reused? }` (absent for a child running in the parent's cwd), a dispatch block badges that item with `󰙅 <name>`, and the single-item inline row is upgraded from the request badge (`create.name`, or `+new` for an anonymous `create`) to the created checkout once the tool ends; `read_subagent` reads the transcript recorded for the child (`session_file`) — for a child in its own checkout that JSONL lives in that checkout's session directory. `:PiSessions` and the `p` viewer show or replay the child's actual cwd. No row claims the parent's workspace.
- **Workspace-scoped features follow the session cwd, not Neovim's**: [`:PiDiff`](diff-review.md#session-diff-review-pidiff) anchors each changed file at the session's directory, [quickfix](usage.md#quickfix) resolves `grep`/`find` paths against it, [`@mentions`](usage.md#mentions) (`@git-diff`, `@git-log`, file existence) and `gf`/buffer reload resolve paths there, and [prompt history](usage.md#prompt-history) / [drafts](usage.md#draft-persistence) are keyed per workspace. A resumed session adopts the cwd recorded in its session file, so a resumed worktree session keeps pointing at its worktree.
- **Session storage is per cwd** — the worktree's own session files (and therefore its `.pi2-subsessions.json` manifest and batch records, which it owns when its sessions spawn children) live in the session directory of *that* cwd, separate from the main checkout's (see [Sessions → Storage and scoping](sessions.md#storage-and-scoping)). A child started *by* a worktree session records its row in the worktree session's workspace, next to that directory, even though the child's own transcript lives in the child's checkout.

## Configuration

```lua
require("pi").setup({
    worktree = {
        -- Command run inside a freshly created worktree, before its session
        -- starts. Executed directly (no shell) with the worktree root as cwd;
        -- a non-zero exit keeps the checkout but fails the creation.
        setup_cmd = nil, -- e.g. { "mise", "install" }

        -- Base commit new checkouts start from: "head" (default; the checkout
        -- the creating session runs in), "fresh" (the repository's remote
        -- default branch, origin/HEAD, re-fetched at most once per 24h with a
        -- 5s cap), or a per-dispatch-item `create.base` revision.
        base_ref = "head",

        -- Snapshot a worktree's patch before pi.worktree_remove / Worktree.remove
        -- deletes it (default true).
        snapshot_before_remove = true,

        -- Prefix the chat-title badge with ⚠ when the session's cwd differs
        -- from Neovim's cwd (default true). false keeps the plain 󰙅 <name>
        -- badge; the editor and the agent may then anchor paths differently.
        warn_on_cwd_mismatch = true,
    },
})
```

Full annotated reference: [Configuration](configuration.md). The `pi.worktree*` functions and the git-side module (`pi.worktree`) are documented in the [Lua API](api.md#worktrees).

## What this does not do

- **No moving a live conversation.** A session cannot be relocated into or out of a worktree mid-conversation; its cwd is fixed at spawn.
- **No nested worktrees.** A session never creates a checkout *inside* a worktree: creation always uses the repository's main work tree, so a sub-session of a worktree session gets a sibling checkout under `<repo>/.worktrees/`.
- **No sandbox.** A worktree separates files, not privileges: the agent can still read absolute paths elsewhere, run shell commands, reach the network, and use the credentials its process inherited. Use `subagent.tools` for a read-only child; the checkout is a workspace, not a security boundary.
- **No lifecycle on a borrowed checkout.** A `worktree = { path = … }` assignment and a `create` that adopted an existing name never create, reset, merge, apply or remove that checkout; the path is only attached to the child's process. Only a checkout the spawn itself created is released (and only when clean).
- **No automatic merge for a child checkout.** A finished child leaves its work in its checkout; review and apply it with `pi.worktree_apply` / `pi.worktree_ship` like any other worktree.
- **No automatic commit.** `pi.worktree_apply` writes to a **working tree** only (never the index, never a commit), and `pi.worktree_ship` only prefills a prompt — commits and pushes stay yours (or the agent's, once you send that prompt).
- **`:PiContinue` is still cwd-scoped.** It means "the most recent session *here*"; the cross-worktree enumeration lives in `:PiResume`.
