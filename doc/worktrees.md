# Worktrees

π sessions are cheap, and several of them can share one checkout — until they start editing the same files, or until one of them switches a branch under the others. A **git worktree session** gives a conversation its own checkout of the same repository, created under `<repo>/.worktrees/<name>` and left on a **detached HEAD**, so parallel agents never race on one working tree or on a branch.

Worktree support is opt-in per session, not a mode: you start a session in a worktree with `:PiWorktreeNew` or `:PiWorktreeFork` (or reopen a fresh one in an existing checkout with `worktree=<name>`), and everything else — a session started with plain `:Pi` — behaves exactly as before.

- [What a worktree session is](#what-a-worktree-session-is)
- [Creating one](#creating-one)
  - [Naming](#naming)
- [Opening another session in an existing worktree](#opening-another-session-in-an-existing-worktree)
- [Repository hygiene](#repository-hygiene)
  - [`.gitignore`](#gitignore)
  - [`.worktreeinclude`](#worktreeinclude)
  - [`worktree.setup_cmd`](#worktreesetupcmd)
- [Detached HEAD and `:PiWorktreeBranch`](#detached-head-and-piworktreebranch)
- [Applying a patch (`:PiWorktreeApply`)](#applying-a-patch-piworktreeapply)
- [Shipping the work (`:PiWorktreeShip`)](#shipping-the-work-piworktreeship)
- [Removing a worktree (`:PiWorktreeRemove`)](#removing-a-worktree-piworktreeremove)
- [Cleanup when a session closes](#cleanup-when-a-session-closes)
- [Sub-sessions](#sub-sessions)
- [Resuming across worktrees](#resuming-across-worktrees)
- [Where you see it](#where-you-see-it)
- [Configuration](#configuration)
- [What this does not do](#what-this-does-not-do)

Related pages: [Sessions](sessions.md) · [Diff review](diff-review.md) · [Configuration](configuration.md) · [Lua API](api.md) · [Highlight groups](highlight-groups.md#sessions-overview)

## What a worktree session is

A worktree session is an ordinary π session whose process runs with the **worktree directory as its cwd**. Nothing in the chat is different — same prompt, tools, history, statusline — but the backend resolves its project files, tool paths, sessions and git state from that directory:

- The checkout is registered with git, starts on a **detached HEAD** at the repository's current `HEAD` (recorded as the worktree's *base commit*), and shares the repository's object store, refs and remotes.
- The session is a **new process in a new tabpage**. The conversation you started it from keeps running untouched, in its own tab (that is why `:PiWorktree*` do not reuse the RPC `new_session` / `fork` commands, which rebind the current process and keep its cwd).
- Because pi resolves everything from the process cwd and has no `--cwd` flag, a session's workspace is **fixed at spawn**. A conversation cannot be moved into (or out of) a worktree halfway through — start a new session there, or use `:PiWorktreeFork` to carry the conversation along.
- Bookkeeping lives in the **per-worktree git dir** git itself creates (`<repo>/.git/worktrees/<name>/pi2-worktree.json`): the name, path, base commit, mode, and the session id/file bound to the checkout. It is written atomically, never inside the work tree, so it can never appear in `git status` or leak into a clone. Detection is a pure filesystem read (no git subprocess), which is why the chat badge and the sessions list can ask for it on every render.

## Creating one

| Command | Lua | What it does |
| --- | --- | --- |
| `:PiWorktreeNew [name]` | `pi.worktree_new({ name?, layout? })` | Create a worktree from the current repository and start a **fresh** conversation in a new tabpage whose cwd is that worktree. The current tab's session is left untouched. |
| `:PiWorktreeFork [name]` | `pi.worktree_fork({ name?, layout? })` | Same, but the new process is bootstrapped from this conversation with `--fork <session file>`: the new session starts with this conversation's active branch (history) and continues in the worktree. The parent session file is not modified, and the sessions list marks the child `↳ forked from <name>`. |

Both use the current session's cwd to find the repository and report the new checkout's absolute path when the session starts. The commands take only the optional name; from Lua, `opts.layout` (`"side"` / `"float"`) selects the new tab's chat layout.

`worktree_fork` is refused while the agent is streaming (wait for the turn to finish), when the conversation is empty (there is nothing to fork yet), when the session has no file yet, and when `pi.cli.args` contains a session-selecting flag (`--continue` / `-c`, `--resume` / `-r`, `--session`, `--no-session`) — those conflict with the `--fork` it needs to append.

Creation is refused, with an explicit message, when:

- the directory is not inside a git repository, or the repository has **no commits yet** (there is no base commit to detach from),
- the current session **already runs in a worktree** — worktrees are never nested; fork or create from the main checkout instead,
- the target directory already exists,
- the name is invalid (see below).

If the process fails to start after the checkout was created, the fresh worktree is released again instead of being left behind empty.

### Naming

The optional argument names the directory under `<repo>/.worktrees/`. Without one, the name is generated from the current time plus this Neovim process's pid and a spawn counter (`wt-<YYYYmmdd-HHMMSS>-<pid>-<seq>`) — a timestamp alone repeats within the same second, so back-to-back creations would collide on one directory. Sub-agent checkouts use the same idea with a `sub-` prefix (`sub-<YYYYmmdd-HHMMSS>-<n>-<pid>`), so a batch fanned out at once still gets distinct names.

Valid names are 1–64 characters, must not start with `.`, and may only contain letters, digits, `.`, `_` and `-`. A name is always a single directory component — `:PiWorktreeApply` / `:PiWorktreeShip` / `:PiWorktreeRemove` accept one too, and completion offers the existing names of the current repository.

## Opening another session in an existing worktree

A managed checkout outlives the session that created it: it stays on disk until it is released or removed. To open a **fresh** conversation in one that already exists, pass `worktree=<name>` to a start command instead of creating a checkout:

| Command | What it does |
| --- | --- |
| `:PiNewTab worktree=<name>` | Start a fresh conversation in a **new** tabpage whose cwd is `<repo>/.worktrees/<name>`. |
| `:Pi worktree=<name>` | The same, in the **current** tabpage; refused while that tab already runs a session (the message points at `:PiNewTab`). |

From Lua the same entry point is `pi.worktree_open(opts, callback)`:

```lua
pi.worktree_open({ name = "fix-auth", layout = "side" }, function(session, err) ... end)
pi.worktree_open({ cwd = "/repo/.worktrees/fix-auth", new_tab = false })
-- The main checkout (or any project directory) starts an ordinary session there.
pi.worktree_open({ cwd = "/repo" })
```

`new_tab` defaults to `true`; `cwd` wins over `name` and may be **any existing directory** — a linked worktree is attached as worktree metadata (chat badge, `:PiWorktree*` target, session binding), while the **main checkout** or a plain project directory starts an **ordinary** session whose cwd is that path, with no worktree metadata and no binding written. That is also the entry point behind `:PiSessions` → `n`, which passes the selected row's checkout as `cwd`. The flag never creates and never removes a checkout: a name that does not exist is an error pointing at `:PiWorktreeNew <name>`, and a failed process start only closes the empty scratch tab — the checkout is left exactly as you left it, because it holds your work. Starting a session is silent (the chat opening in its tab is the feedback); only failures notify. Names complete from the current repository's `<repo>/.worktrees/*` in both commands, and `:PiContinue` / `:PiResume` reject the flag (they pick their own workspace). A worktree's recorded session binding is written only when it has none, so opening a second session there never steals the first one's binding.

## Repository hygiene

Creating a worktree touches exactly one file outside `.worktrees/`, and only when needed:

### `.gitignore`

`/.worktrees/` is appended to the repository's `.gitignore` (unless git already ignores `.worktrees/` — `/.worktrees`, `.worktrees/` and `.worktrees` count as equivalents). The file is written atomically and **never staged or committed**: the ignore line is yours to review, commit and share (or discard, in which case the checkouts show up as untracked files).

### `.worktreeinclude`

A fresh checkout only contains tracked files, so per-repository local files — a `.env`, a local config override, cache directories — are missing in it. Put one glob per line in a **`.worktreeinclude`** file at the repository root (`#` starts a comment, blank lines are ignored) to copy them into every new worktree of this repository.

Only files git **ignores** are copied: the copy is the intersection of `.gitignore` and `.worktreeinclude`. Tracked files are already in the checkout, and copying them would only risk clobbering the base commit. The `.worktrees/` directory itself is never copied (so the copy cannot recurse), and a pattern matching more than 20 000 files is refused loudly instead of hanging the editor. The same cap bounds how many untracked files a patch capture will include (see [Removing a worktree](#removing-a-worktree-piworktreeremove)).

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

The command's exit status decides what happens: `0` → the session starts in the worktree; non-zero → creation **fails**, the session is not started, and the error notification carries the tail of the command's output. The worktree itself stays on disk (it is already registered with git), so nothing is lost — fix the problem and create the session there again, or remove the checkout with `:PiWorktreeRemove`.

## Detached HEAD and `:PiWorktreeBranch`

Worktrees are created detached on purpose: a branch can only be checked out in one worktree at a time, and the point is not to take the branch away from the main checkout (or from another agent). Your work therefore starts on the base commit, and `git status` / `git diff <base>` are the natural views of it.

When the work needs a branch name — to push it, or because you prefer to commit on a branch — attach one explicitly:

| Command | Lua | What it does |
| --- | --- | --- |
| `:PiWorktreeBranch <branch>` | `pi.worktree_branch(branch)` | Run `git checkout -b <branch>` inside the current session's worktree. If that branch already exists in the repository, it is checked out instead. |

The command operates on the **current session's** worktree (the session must be running in one), validates the name with `git check-ref-format --branch`, and reports success in a notification. It does not touch the session, its tab, or its conversation — only git state.

## Applying a patch (`:PiWorktreeApply`)

Work done in an isolated checkout stays isolated until you move it out. `:PiWorktreeApply [name]` is the deliberate, reviewed way to do that:

1. It collects the worktree's patch relative to its **base commit**, including untracked files (they arrive as full-file additions). Capture is **all or nothing**: if the worktree has more than 20 000 untracked files, or an untracked path that a patch cannot represent (most commonly a directory holding its own git repository — a nested clone, a vendored repo, a submodule checkout), the command reports the error and opens nothing rather than reviewing a partial patch.
2. It opens the [session diff review panel](diff-review.md#session-diff-review-pidiff) with that patch — file list, per-file diff, `<CR>` jumps into the **worktree's** copy of the file. An empty diff is reported and nothing opens.
3. Pressing **`a`** (labeled `a apply to <repo>` in the list hint, where `<repo>` is the main checkout's directory name) applies the whole patch to the **main checkout's working tree** with `git apply`.

**Applying into a live checkout.** If a π session is running in the main checkout, `a` does not write immediately — the agent there may be reading and writing those same files mid-turn. A confirmation (`Apply into a live checkout?`) names the checkout and the session id and explains the risk; cancelling writes **nothing**. Confirming re-checks right before the write: a *different* session that appeared while the dialog was open (or in the gap up to the write) aborts the apply with an error naming it, so consent is tied to the session you were warned about and never extends to a new one.

What it never does: it does not stage files (the index is yours), does not create a commit, and never applies without that explicit accept — closing the panel applies nothing. `git apply` is atomic, so a conflicting or failed apply leaves **both** checkouts exactly as they were: files already modified in the main checkout that the patch would overwrite make the whole patch abort rather than partially apply.

Without a name the target is the current session's worktree (or the linked worktree its cwd lives in, for a resumed session); a name resolves under `<repo>/.worktrees/<name>` and must be a real linked worktree, so it can never point outside the checkout directory.

```vim
:PiWorktreeApply              " review and apply this session's worktree
:PiWorktreeApply fix-auth     " … or the worktree named fix-auth
```

## Shipping the work (`:PiWorktreeShip`)

Once the patch is applied elsewhere, the worktree's own commits (and the branch they live on) still have to reach the remote. `:PiWorktreeShip [name]` prefills the target session's prompt with a plain-text brief for the agent: the worktree's absolute path, the main checkout, `HEAD` and the base commit, whether it is dirty or how many commits ahead it is, and the requirements — create a branch if `HEAD` is still detached (suggested name `pi/<worktree>`), commit inside the worktree only, push, open a pull request, resolve conflicts itself, and never force-push shared branches or rewrite pushed commits.

**The prompt is not sent.** It waits in the prompt buffer for you to review, edit and submit — pi2.nvim neither submits it nor commits anything on your behalf. If the target session lives in another tab that is still attached, the command switches there so you can review the text in place; when that session's chat exists but its tab is gone (or it has no chat at all), it reports how to open it (`:PiSessions` / `:PiSubSwitch`).

## Removing a worktree (`:PiWorktreeRemove`)

`git worktree remove` refuses a dirty checkout, which is the right default but not a workflow: `:PiWorktreeRemove [name]` removes the checkout **explicitly**, with the guards that make that safe.

- **A live session refuses the removal.** If any π process still runs with the worktree as its cwd (a tab session, a sub-session child, or a detached process you cannot see), the command errors out and names the session to close first (`:PiStop`, `:PiSubClose`, or `x` in `:PiSessions`). Deleting a live cwd breaks the agent's next tool call. The guard matches three things: the session's worktree metadata, the session's **process cwd**, and the session id recorded on the worktree — so a child that merely *inherited* the checkout (a sub-session of a session that already ran in a worktree, which owns no worktree metadata of its own) is caught by its cwd and still blocks the removal.
- **You confirm first**, and the dialog tells you what is at risk: uncommitted changes, commits ahead of the base commit, or both.
- **A snapshot is written before anything is deleted** (`worktree.snapshot_before_remove`, default on): the same patch `:PiWorktreeApply` would review — base commit → current state, untracked files included — is saved to `<git common dir>/pi2-worktree-snapshots/<worktree>/<YYYYmmdd-HHMMSS>.patch` (i.e. under `.git/`, which survives the checkout). **If the snapshot fails, nothing is removed** and the error is reported. With `snapshot_before_remove = false` the confirmation warns that the work will be lost instead.
- **Capture fails closed.** A snapshot that silently dropped files would be worse than none, so the patch is only written when it is complete: untracked content beyond the 20 000-file cap, or an untracked path a patch cannot represent (an untracked directory holding its own git repository — a nested clone, a vendored repo, a submodule checkout — produces no diff), aborts the snapshot and therefore the removal, with a message naming the offending path. Commit, ignore or delete that path, then retry. `:PiWorktreeApply` shares the same capture rules.
- Only then does it run `git worktree remove --force` followed by `git worktree prune`, so the metadata and the checkout are both gone. The notification includes the snapshot path.

Snapshots are written, never pruned: they are ordinary patch files you can `git apply` later, and pi2.nvim does not garbage-collect them.

## Cleanup when a session closes

An explicit close is the normal end of a worktree session, and it cleans up after itself:

- Closing the session's process (`:PiStop`, `x` in `:PiSessions`, `:PiSubClose` for a child, or the process exiting on its own) releases its worktree.
- **Release deletes a checkout only when nothing would be lost** — no uncommitted changes and no commits beyond its base commit. A dirty or ahead worktree is **kept**, and a notification names the path (`Worktree kept: <path> …`) so you can inspect, apply or ship it.
- **Release snapshots before deleting**, like every other removal: a clean checkout's patch is empty, so what it leaves behind is an **empty patch plus its `.patch.json` sidecar** — a record of the checkout (name, path, base commit, HEAD, time) that survives the directory and lets the session still be found on resume. If writing that snapshot fails, the checkout is **kept** instead of deleted.
- Closing a tab does **not** close the session (see [Sessions → One chat per tab](sessions.md#one-chat-per-tab)), so it does not release the worktree either — an ordinary background session keeps its checkout.
- `:PiWorktreeRemove` is the explicit path when you want the directory gone regardless of state (subject to its snapshot).

## Sub-sessions

Sub-sessions ([Sessions → Sub-sessions](sessions.md#sub-sessions)) run in the **parent session's cwd**. They are not given a checkout of their own: a spawned child edits the same working tree as its parent, so several children in one batch share those files.

That is a deliberate trade. A checkout per child costs a `git worktree add`, a `.worktreeinclude` copy and a `worktree.setup_cmd` run on every spawn, and the work left in it then has to be moved back into the parent's tree. When a batch must not touch your own checkout, isolate at the **session** level instead: dispatch from a session that already runs in a worktree (`:PiWorktreeNew`, `:PiNewTab worktree=<name>`), and every child inherits that checkout while your main checkout stays clean. For children that only read, constrain them with `subagent.tools` (`{ "read", "grep", "find", "ls" }`) — that is enforcement, not a request.

A child revived from a manifest written by an earlier version keeps running in the checkout recorded on its row while that directory still exists; once it is gone, the revive starts in the parent's workspace cwd and warns instead of failing. `worktree.isolate_subagents` no longer exists, and neither does the per-child system-prompt paragraph about an isolated path.

A `sub-…` checkout recorded by an earlier version is an ordinary directory now: the idle reaper still releases one that no live π session owns, and anything it cannot prove is safe to delete is yours to remove with `git worktree remove`.

## Resuming across worktrees

`:PiResume` lists the sessions of Neovim's cwd **and of every managed worktree of the same repository**, so a worktree session can be reopened without `:cd`-ing into its checkout. Each item carries its checkout's info table, and the picker groups sessions per checkout — a `󰙅 <name>` title per managed worktree and the project name for the main checkout, shown once the list spans two or more checkouts (a single checkout stays a flat list). Opening one restarts the process **in that checkout** (closing the current one first when the cwd differs, and refusing while that session is streaming) instead of loading the transcript in the main checkout; opening into a new tab leaves the current session running. Enumeration covers checkouts git still reports (including prunable ones whose directory is gone) **and** checkouts deleted but still present in the snapshot store (`Worktree.snapshot_worktrees` reads `<git common dir>/pi2-worktree-snapshots/`, including the empty patches a clean release leaves). It only runs when the repository has a `.worktrees/` directory or a snapshot store — a plain project keeps the old single-workspace picker and never spawns git for it.

A listed checkout can be gone by the time you pick it (retention removed it, or it was deleted by hand). Recovery runs **before** any process is touched and never falls back to the main checkout:

- the checkout directory exists → used as-is, with its metadata re-detected;
- the row records an **applied** integration (or a snapshot sidecar says so) → the checkout is recreated at the repository's **current `HEAD`**, because the work is already in the parent;
- the snapshot exists but its **patch is empty** (the checkout was released clean, so there was nothing to preserve) → the checkout is recreated at the recorded base and **nothing is applied**: the restore is a no-op;
- otherwise the **latest snapshot** is required: the checkout is recreated at the recorded base commit and the snapshot patch is applied into it, so the conversation continues with its unintegrated work intact;
- neither an integration record nor a snapshot → the picker reports that it cannot recover the worktree and opens nothing.

`:PiContinue` stays scoped to Neovim's cwd — it is "the most recent session here", not a cross-worktree picker.

## Where you see it

- **Chat history title** — a session running in a linked worktree shows `󰙅 <name>` next to the panel title (in the side-layout winbar and the float border), with a trailing `*` while the checkout is dirty or has commits ahead of its base commit. When the session's cwd is **not** Neovim's cwd — normally the case for every worktree session, since starting one does not change Neovim's cwd, and also for a session resumed from another directory — the badge is prefixed with `⚠` in the warning color, because paths you open from your own buffers and paths the agent touches may diverge; `worktree.warn_on_cwd_mismatch = false` drops that prefix and keeps the plain badge. A session in the repository's main worktree with Neovim's cwd shows no badge.
- **`:PiSessions`** — once the list spans **two or more distinct worktrees**, rows are grouped under a worktree header (`▾ 󰙅 <name> · ~/path`, and `▸ 󰙅 <name> (n) · ~/path` while the group is folded), and `<Tab>` / `za` folds a whole group (`zM` / `zR` collapse or expand everything). The `(n)` is the group's **structural** size — every parent row plus its sub-sessions — and it is displayed while the group is collapsed, does not move when a parent row *inside* the group folds, and only folding the group itself changes what is shown. The header carries the worktree's name for its whole group, and a sub-session row inside it repeats the name in its subtitle (a parent row is already under that header), while a worktree fork carries the `↳ forked from <name>` marker. Sessions whose cwd is not a work tree keep their flat rows, so a single-repository list looks exactly as before. `R` re-detects worktrees along with session names.
- **Highlight groups** — `PiChatHistoryWorktree` (badge in the history title) and `PiSessionsListWorktree` (worktree group header); see [Highlight groups](highlight-groups.md).
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

        -- Snapshot a worktree's patch before :PiWorktreeRemove / Worktree.remove
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
- **No nested worktrees.** A session (or sub-session) that already runs in a worktree never creates another checkout inside it.
- **No automatic commit.** `:PiWorktreeApply` writes to a **working tree** only (never the index, never a commit), and `:PiWorktreeShip` only prefills a prompt — commits and pushes stay yours (or the agent's, once you send that prompt).
- **`:PiContinue` is still cwd-scoped.** It means "the most recent session *here*"; the cross-worktree enumeration lives in `:PiResume`.
