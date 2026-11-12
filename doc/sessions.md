# Sessions

π is session-oriented: every conversation is persisted to disk as it happens, you can leave one in the middle of a turn and pick it up later, and pi2.nvim gives you a few ways to navigate between them.

## One chat per tab

pi2.nvim keeps **one live chat UI per Neovim tabpage**, bound to a session process. Two different tabs give you two independent conversations with their own history, prompt buffer, attachments, model, and thinking level. Closing a tab **detaches** the chat UI but leaves the backing RPC process running in the background (explicit `:PiStop` or Neovim exit still tears processes down). Sub-sessions spawned from a parent also run as detached background processes until you switch to them or close them explicitly.

Each session owns an underlying `pi --mode rpc` subprocess (one tab = one session = one process). The process lifecycle and how to stop/abort it are covered in [Health & debugging → Process lifecycle](troubleshooting.md#process-lifecycle).

## Storage and scoping

Session files are JSONL documents stored under:

```
<agent_dir>/sessions/<encoded-cwd>/*.jsonl
```

where `<agent_dir>` is resolved in this order:

1. `agent_dir` in `require("pi").setup(...)`
2. `$PI_CODING_AGENT_DIR` environment variable
3. `~/.pi/agent` (default)

Crucially, sessions are **scoped to the working directory the session runs in**. Sessions started in `~/Dev/project-a` are only visible to continue/resume when pi2.nvim is running from the same directory. This matches how you'd actually want it: you don't want to accidentally resume an unrelated project's conversation just because you opened a chat in a new tab. Each session object carries its own cwd (`session.cwd`), and it — not `vim.fn.getcwd()` — is the anchor for everything workspace-scoped: session storage, diff review anchors, quickfix paths, `@mention` resolution and prompt history/drafts. A [worktree session](worktrees.md#what-a-worktree-session-is) therefore keeps its own session directory next to its own checkout, and a resumed session adopts the cwd recorded in its session file, so it keeps pointing at the workspace it belongs to.

The one bookkeeping subtlety is **who owns a sub-session row**. Sub-session manifests and batch records belong to the *owner parent session's* workspace (`session.manifest_cwd`, which is the parent's cwd at spawn — the cwd its pi process reported), not to the child's cwd: a child runs in its parent's cwd, and its row stays in the parent's manifest. A child session therefore carries both, and row lookups (close, revive, the reaper, a name update) search across workspaces — the parent's, every live session's, and every manifest found on disk — so they still work when Neovim's cwd is in a completely different checkout.

## Starting, continuing, resuming

There are three ways to open a chat — each honors the usual `layout=side|float` override, and `:Pi` / `:PiNewTab` additionally take `worktree=<name>` to start the fresh conversation in an **existing** managed worktree (see [Worktrees → Opening another session in an existing worktree](worktrees.md#opening-another-session-in-an-existing-worktree)):

| Command | Lua | What it does |
| --- | --- | --- |
| `:Pi` | `pi.show()` / `pi.toggle()` / `pi.worktree_open()` | Open the chat. If the current tab has no session yet, starts a fresh conversation. With `worktree=<name>` that conversation starts in the named worktree's checkout instead, in the **current** tabpage — refused while this tab already runs a session (use `:PiNewTab worktree=<name>`). |
| `:PiNewTab [worktree=<name>]` | `pi.new_tab()` / `pi.worktree_open({ new_tab = true })` | Open a **fresh** conversation in a **new** tabpage (`:tabnew` semantics). Uses `layout.default`, and `worktree=<name>` opens it in that existing worktree. |
| `:PiContinue` | `pi.continue_session()` | Load the **most recent** session for the current cwd. Skips the session currently live in another tab, so you can continue a different one. |
| `:PiResume` | `pi.resume_session()` | Open a picker listing **past top-level sessions for the current cwd and of every managed worktree of the same repository**, grouped per checkout (`󰙅 <worktree>` titles, the project name for the main checkout; a single checkout keeps a flat list with no per-row marker) and opening each session in its own checkout (see [Worktrees → Resuming across worktrees](worktrees.md#resuming-across-worktrees)). Sub-sessions are excluded — use `:PiSubSwitch` to reopen a child. See [Resume picker](#resume-picker) for its keybindings and search behavior. |

### Resume picker

When [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) is installed, `:PiResume` opens a dedicated picker instead of the generic `vim.ui.select` one. The keybindings are shown as a fixed hint in the picker title:

| Key | Action |
| --- | --- |
| `<CR>` / `o` | Open the session in the **current** tab |
| `t` / `<C-t>` | Open the session in a **new** tab |
| `<C-x>` | Delete the selected session file(s) (multi-select aware) |

`<C-t>` exists because typing in the picker prompt is filtering — plain letters (`o`, `t`) work once you leave insert mode with `<Esc>`.

Rows are **partitioned by checkout** once the list spans two or more checkouts: each partition starts with a title row — `󰙅 <worktree>` for a linked worktree, the project name for the main checkout — followed by that checkout's sessions, newest first (partitions are ordered by their newest session). A single-checkout list stays flat, exactly as before, and rows no longer carry a per-row `· 󰙅 <name>` suffix. Title rows are not sessions: `<CR>`, `o`, `t`, `<C-t>` and `<C-x>` skip them (opening moves on to the next session row, deletion ignores them), and the `vim.ui.select` fallback simply reopens the picker when you pick one.

Typing in the prompt filters with a case-insensitive substring match over the row text, the partition title, the worktree name and the checkout path. Matched sessions stay under their partition title, and titles of partitions without a match disappear. Grouping is decided before filtering, so narrowing to one checkout still shows its title.

Other `vim.ui.select` backends keep their generic rendering; with snacks.nvim, `t` / `<C-t>` map to "open in new tab" and `<C-x>` still deletes. Whatever the backend, opening a conversation that is still live in another tab asks for confirmation first — resuming it twice would spawn two backend processes writing the same session file, so the copies would diverge.

And mid-session management:

| Command | Lua | What it does |
| --- | --- | --- |
| `:PiNewSession` | `pi.new_session()` | Discard the current session in this tab and start a fresh one. When viewing a sub-session, switches back to the parent first. Sub-session rows from the previous conversation are hidden in `:PiSessions` (press `H` or use `:PiSubSwitch` to recall them), and its todo list is dropped as well — an auto-opened `:PiTodo` panel closes, an explicitly opened one shows the `no todos` placeholder. Extensions can cancel this via the `session_before_switch` hook (e.g. to warn about unsaved draft state). |
| `:PiTree` | `pi.tree()` | Navigate the session tree: jump back to any past conversation point, optionally summarizing the abandoned branch. See [Session tree navigation](#session-tree-navigation-pitree). |
| `:PiFork` | `pi.fork()` | Start a new session from a past user message. See [Fork and clone](#fork-and-clone). |
| `:PiClone` | `pi.clone()` | Duplicate the current branch into a new session file. See [Fork and clone](#fork-and-clone). |
| `:PiSessions` | `pi.sessions()` | Toggle the live overview of all active sessions (name + busy/idle/attention). See [Sessions overview](#sessions-overview-pisessions). |
| `:PiSessionName [name]` | `pi.set_session_name(name?)` | Set a human-readable display name for the current session. Without an argument, opens an input dialog prefilled with the current name. Names appear in the `:PiResume` picker so you can identify long-running conversations at a glance. |
| `:PiStop` | `pi.stop()` | Tear down the current session entirely, killing the backing `pi --mode rpc` process. Different from `:PiToggleChat`, which just hides the windows while the session keeps running. |
| `:PiSubNew` | `pi.sub_new()` | Spawn a background sub-session with a task prompt (inherits model/thinking by default). |
| `:PiSubSwitch` | `pi.sub_switch()` | Picker to switch the current tab's chat to a child sub-session (including dormant). |
| `:PiSubParent` | `pi.sub_parent()` | Return from a child sub-session view to the parent. |
| `:PiSubClose` | `pi.sub_close()` | Close the current sub-session's RPC process (session file retained). |
| `:PiSubView` | `pi.sub_view()` | View a sub-session in a read-only float viewer (with real-time streaming for running children). |

Sessions can also be started in an **isolated git worktree** — `:PiWorktreeNew` for a fresh conversation, `:PiWorktreeFork` to carry this one along — with `:PiWorktreeBranch` / `Apply` / `Ship` / `Remove` for the git side. See [Worktrees](worktrees.md).

## Sub-sessions

A parent session can run **sub-sessions** in parallel — each child is an independent `pi --mode rpc` process with its own session file, model, and thinking level. Relationships and bookkeeping live in `<agent_dir>/sessions/<encoded-cwd>/.pi2-subsessions.json` (the parent session's workspace); message content stays in each child's JSONL (the authoritative store). Child processes are **detached from the tab**, same as a parent after `:tabclose`: closing the parent tab does not stop running sub-sessions. Interrupt them with `:PiAbort`; close their processes with `:PiSubClose` / `x` in `:PiSessions`, `stop_subagents`, or by quitting Neovim. `:PiAbort` is scoped to the view you are in: issued on the parent, it interrupts the parent itself and cascades to all of its sub-sessions and their batches — including a batch the parent is currently waiting on, even one recorded under an older lineage — while every child that has already received its task keeps its RPC process alive (abort is not stop, so interrupted children can be sent new prompts or reused). Issued while viewing a child, it interrupts only that child — and any sub-sessions the child itself spawned with `:PiSubNew` — and is **not** forwarded to the parent: the parent's turn, its batches, and the sibling children all keep running undisturbed. What the parent does observe is accounting: the aborted child's pending batch items are settled immediately as `cancelled` (rather than left hanging or booked as `ok`), which wakes a parent blocked in `wait_subagents` right away instead of letting it hang until `subagent.batch_timeout_ms` — this settlement runs even when the child was already idle, where an abort produces no new agent events. A batch item aborted while its child is still spawning is the exception: that late child is aborted and its process reclaimed, since it never received a task and would otherwise linger as an orphan holding a `subagent.max_children` slot, whereas a child that already has its task is abort-only and keeps its process — an explicit close still only happens via `:PiSubClose` / `x` / `stop_subagents` / `Batch.cancel`, so no orphan process is left in either case.

| Command | What it does |
| --- | --- |
| `:PiSubNew` | Prompt for a task; spawn a child in the background. |
| `:PiSubSwitch` | Pick a child (active or dormant) and bind the current tab's chat to it. |
| `:PiSubParent` / `gp` in history | Switch back to the parent; breadcrumb `◂ 父：…` shows while viewing a child. |
| `:PiSubClose` | Close the current sub-session's RPC process (session file retained). |
| `:PiSubView` | Picker to view a child sub-session in a read-only float viewer (with real-time streaming for running children). |

Switching parent ↔ child or sibling children **rebinds the tab UI** and rebuilds history from `get_messages`. It does **not** send RPC `switch_session` when the target process already has that session file open, so a running agent on the target is not aborted. The statusline spinner elapsed time continues from that session's first `agent_start` for the current run (it does not restart when you switch). Dormant children are revived in a new process, which still loads the file via `switch_session` (subject to `subagent.max_children`: reaching the cap auto-closes the oldest settled child to make room, failing with `max N concurrent sub-sessions` if all slots are active or in view).

Each spawned child runs in the **parent session's cwd**: sub-sessions are no longer given a checkout of their own, so parallel children in one batch share that working tree. Give them disjoint files, a read-only `tools` allowlist, or dispatch from a [session-level worktree](worktrees.md#sub-sessions) so the whole batch stays out of your own checkout. The automatic-integration engine and its `worktree.integration` knobs are gone with the per-child checkout. Manual control (review before applying, shipping a branch) stays with [`:PiWorktreeApply` / `:PiWorktreeShip`](worktrees.md#applying-a-patch-piworktreeapply).

While viewing a child, `:PiNewSession` / `pi.new_session()` or a bare `/new` in the prompt (e.g. `<C-g>n` in a typical setup) **returns to the parent first**, then starts a fresh parent conversation — same as running `/new` on the parent. Prior-conversation sub-session rows are hidden in `:PiSessions` (press `H` or use `:PiSubSwitch` to recall them), and the parent's todo list is dropped the same way.

When a user-spawned child finishes, its last assistant message is injected into the parent as `[子会话「name」已完成] …` or `[Sub-session "name" completed] …` (language follows `title.lang` / UI locale); a child that closed with a `STATUS:` line gets that status in the header instead (`completed: blocked`) — see [Reporting contract](#reporting-contract). A child interrupted by a user abort is recorded as `interrupted` in the manifest instead and injects no completion report. From pi 1.1.0 the cancel detection prefers the `agent_settled.aborted` event field (authoritative) and only falls back to the session file's last stop reason on older pi. Agent-spawned children skip this injection — they receive a synchronous tool result instead. Configure via `subagent.*` in [Configuration](configuration.md).

### Failed runs

A child run can also end without finishing: the provider rejects the call (quota exhausted, invalid key, rate limit) or the network dies. pi persists that turn as an assistant message with `stopReason: "error"`, **no content**, and the reason in `errorMessage` — a shape that looks exactly like a finished turn to anything that only asks "is the last message from the assistant?". It is read as what it is:

- The batch item settles as `failed` (never `ok`), with the provider's own text in `error` — `429: {"message":"You exceeded your current quota…","type":"insufficient_quota"}` — so `dispatch_subagents` / `poll_subagents` / `wait_subagents` hand the parent something it can act on (switch model, retry, ask you). The batch status becomes `failed`, or `partial` when siblings succeeded. A run that failed *after* producing text keeps that text in `output`, so the parent still sees how far the child got.
- The manifest records `status = "failed"` plus `last_error`, which is what `list_subagents` returns as `error` and what `read_subagent` shows as `(error: …)` on the projected turn. After a Neovim restart the `last_error` is what `rebuild` restores, and a startup status rebuild infers `failed` from the same stop reason.
- A user-spawned child (`:PiSubNew`) injects `[Sub-session "x" failed] …` / `[子会话「x」失败] …` instead of a completion notice, carrying the same reason.
- The child process is **not** closed: it stays reusable with `{ target, message }` (the natural next move once the quota is restored) and the idle reaper handles it like any other settled child. `:PiSessions` marks the row with its error dot and, under the default `subagent.sessions_list.show_failed = "unread"`, keeps showing it until you have seen it — unlike a cleanly finished agent worker, which disappears when done.

A prompt the backend rejects before a run even starts fails the item with that answer too — `failed to send task to sub-session: No API key found for …`, `prompt failed: …` — and an unexpected child-process exit books the run as `failed` (`sub-agent process exited`) because a crash leaves no assistant turn to read.

### Idle process reaping

A settled child's RPC process does **not** exit on its own — it stays alive so `dispatch_subagents` can reuse it without a respawn. To keep long sessions from accumulating dozens of idle `pi` processes, pi2.nvim closes them automatically once they have been idle for `subagent.reap_after_minutes` (default 30): the manifest row turns `dormant`, the child's session JSONL is kept on disk, and the child stays fully revivable via `:PiSubSwitch` or `dispatch_subagents({ target, message })`. A periodic sweep every `subagent.reap_sweep_minutes` (default 10) is the backstop: it also catches children settled before the last restart or whose manifest row went missing, and it skips anything still `active` (revived / running a new task), any process that is already gone, and any child that is the current session of an open tab. Set both options to `0` to disable reaping entirely (`reap_after_minutes = 0` alone disables the event-driven close; `reap_sweep_minutes = 0` alone disables only the periodic sweep). In addition, when `dispatch_subagents`, spawn, or revive reaches `subagent.max_children`, settled-but-alive children are immediately auto-reaped oldest-first (by `last_active_at` LRU, skipping children currently viewed in an open tab and targets scheduled for reuse in the current batch) to make room, failing only if all live children are active or viewed.

### Constraining a child's tools

A child starts with the full tool surface of its backend, which is the wrong default for a scout: asked to "only read", a model will usually still reach for `bash` or an edit tool when a prompt makes that convenient. `subagent.tools` moves the constraint to the process level — a list of tool names forwarded to the child as `pi --tools read,grep,find,ls`, so the restricted tools are not merely discouraged but missing from the list the model is given:

```lua
require("pi").setup({
    subagent = {
        tools = { "read", "grep", "find", "ls" }, -- every child spawned from now on
    },
})
```

The list **replaces** the child's whole tool selection, so it has to contain everything that child needs: a search task whose allowlist omits `grep` cannot search, and one that omits `read` has nothing to look at. An empty array is an error (`tools must list at least one tool; omit it to inherit every tool`), never "no tools at all" — a child that can do nothing is invariably a caller mistake. The allowlist is also soft in one direction that bites: pi's `--tools` only filters the tools *declared to the model*, so MCP tools stay callable no matter what the list says and cannot be switched off from here. Leave the option unset (`nil`, the default — it is intentionally not in the defaults table) and every child inherits every tool, exactly as before. The `:PiSubNew` dialog has no tools field, so it can only spawn with whatever `subagent.tools` says; a one-off restriction comes from the Agent tool below, or from Lua via `require("pi.subsessions").spawn(parent, { task = "…", tools = { … } })`.

For a single child, pass `tools` on the spawn item instead of changing the global setting: `dispatch_subagents({ items = { { task = "…", tools = { "read", "grep", "find", "ls" } } } })`. Precedence is item `tools` → `subagent.tools` → `nil` (inherit all), so one read-only scout can sit in the same batch as a sibling that may edit. A reuse item (`{ target, message }`) **refuses** `tools`, just like `name`, `model` and `thinking_level`, and fails the item instead of silently dropping it: the child already has a configuration, and reviving it keeps that one.

The resolved allowlist is persisted in the manifest entry's `config.tools`, so the restriction outlives the process: after [idle reaping](#idle-process-reaping), `:PiSubSwitch` and `dispatch_subagents({ target, message })` revive the child with the same `--tools` it was spawned with, and a later `setup()` change only applies to children spawned afterwards. A manifest written before this feature has no `config.tools` and revives unrestricted; a corrupted value is ignored with a warning (`sub-session tool allowlist ignored on revive: …`) rather than blocking the revival. If your `cli.args` carries its own `--tools` / `-t`, the child's command line drops it in favour of the resolved allowlist and warns once (`subagent.tools overrides --tools from cli.args for child processes`) — the parent process keeps the flag untouched, so a parent can still run with a different selection.

This has to be a flag rather than a sentence because a prompt is advice: the orchestrator note now tells the parent *Constrain a read-only child with `tools: [...]` so it cannot edit — a prompt alone will not stop it*, and that sentence is static text so the parent's system prompt stays byte-constant (prompt cache intact). The note teaches the mechanism; the mechanism does the restricting.

### Reporting contract

A child's report is not a document, it is **one message**: the parent reads the child's last assistant message and nothing else, so every failure mode worth naming here is a way to produce a report that never arrives. Three of them are common enough to be worth spelling out — writing the report to a file and pointing at it (the parent opens no file it was not asked to open, so the work is invisible however good that file is), quoting relative paths (the parent resolves them against *its own* cwd, which for a child spawned from a different directory silently names the wrong file), and burying the conclusion under a chronological account of the investigation (the parent has a context budget and a batch of siblings to read, so a report that opens with "first I looked at…" gets skimmed to its first lines and its outcome lost).

`extensions/subagent-child.ts` turns that into four static rules appended to the child's system prompt (see [Extensions → System-prompt notes](extensions.md#bundled-sub-agent-extension-extensionssubagentts)): write the report in the last message, never in a file you point at; give absolute paths only; lead with the outcome and then the evidence, staying under roughly 200 words unless the task asked for detail; and close with exactly one status line — `STATUS: ok`, `STATUS: blocked` or `STATUS: failed`, with `blocked` (plus what you are stuck on) when unsure. The last rule is what makes the report machine-readable: for a **user-spawned** child the host parses that trailing line off the final message before injecting the completion notice, so the header carries the outcome — `[Sub-session "x" completed: blocked] …` / `[子会话「x」已完成：blocked] …` — and the marker line itself is dropped from the body instead of being repeated back (agent-spawned children take the synchronous tool-result path and get no such notice; see [Sub-sessions](#sub-sessions)).

Two boundaries keep that honest, and both are deliberate. The parse is **lenient in one direction only**: `split_report_status` inspects the last non-empty line, matches `STATUS:` case-insensitively and accepts only those three values, so a missing marker, an unknown value, and a marker with no report above it all return `nil` with the report byte-for-byte unchanged — a child that never learned the marker renders exactly as it did before, and the host never fabricates an `ok` out of silence. And a `STATUS` value is a **self-declaration, not a verification result**: `ok` means the child believed it was done, not that the work was checked, so the parent still reads the evidence, runs the test or opens the file before treating a sibling's `ok` as fact. Trust but verify: the marker reports what the child claims, while the evidence in the same message is what makes the claim checkable — and checking it stays the parent's job. The contract is a cheap signal that makes a batch readable at a glance; it is not a substitute for review.

### Sub-session names

A child's label — its row in `:PiSessions`, the entries of the `:PiSubSwitch` / `:PiSubView` pickers, the `dispatch_subagents` block header, and the completion notice above — resolves in this order:

1. **Explicit**: the `name` you pass on a `dispatch_subagents` `{ task }` item, or a name you actually type in the `:PiSubNew` dialog. Always wins and is **never overwritten**.
2. **Generated**: otherwise the child names *itself* — the bundled [auto session titles](#auto-session-titles) extension asks the child's model for a short title after its first turn and persists it. Because that is the same label a top-level session gets, an unnamed child ends up readable instead of being stuck at its task prefix.
3. **Derived**: until the generated title arrives (and whenever `title.enabled = false`), the label is the first 40 characters of the task.

The distinction between 1 and 2/3 is recorded in the manifest (`name_source`), so accepting the prefilled default in `:PiSubNew` stays replaceable while a typed name does not. Set `title = { enabled = false }` to opt out of generation — children then stay on the task prefix unless you name them.

Parent Agent tools are provided by the bundled `extensions/subagent.ts` extension when `subagent.enabled` is true. See [Extensions](extensions.md#bundled-sub-agent-extension-extensionssubagentts). Both sides also get a **system-prompt note** per turn (`before_agent_start`): parents learn the orchestration discipline, children learn the worker contract (no interactive user, last message = final report, no questions, strict task scope, no nested sub-agents). The text is static — for children it is byte-identical, which keeps pi's prompt-cache prefix stable across turns.

**Agent workflow:** `list_subagents` to discover children (including dormant / completed after a parent resume) → `dispatch_subagents` for all work. Prefer `{ target, message }` when a matching child already exists — the host revives a closed process. Use `{ task }` only to spawn a new child, and give each new child a short descriptive `name` (2–5 words) — it is the label shown in `:PiSessions`, the dispatch block and the completion notice; omit it only for `{ target, message }` reuse items, which keep the existing child's name (see [Sub-session names](#sub-session-names)). When spawning with an explicit `model`, pi2.nvim validates model availability fail-fast: if the model is not found, spawn aborts and the item fails with an error listing available models (`Model not found: ... Available models: [...]`), enabling the agent to self-correct. `wait: true` on dispatch for one-shot results, or `poll_subagents` / `wait_subagents` with the returned `batch_id`. `stop_subagents` to close processes. Failure policy defaults to **collect_errors**. If the parent stays busy after children have finished, see [Troubleshooting → Sub-agent wait stuck](troubleshooting.md#sub-agent-wait-stuck-after-children-finish).

## Session tree navigation (:PiTree)

A pi session is not a linear log but a **tree** of entries: going back to an earlier point and continuing from there creates a new branch, while the abandoned branch stays on disk. `:PiTree` (or typing `/tree` in the prompt) is the π equivalent of the TUI's `/tree` command:

1. A picker lists the session's conversation entries (user/assistant messages, branch summaries, compactions), indented by *branch* depth — a linear conversation stays flat at the left edge (no per-message indent), only real forks nest — with `●` marking the current point and any branch label shown right after the entry's kind tag (before its preview text, so it survives truncation). Text-less assistant turns are never blank: a tool-only turn shows a compact tool-call summary (the chat's per-tool nerd-font icon as a lightweight marker, plus the first argument — the bash command, edited path, search pattern, …; extra tools on the same turn fold into `(+N)`), and an aborted or errored turn shows `(aborted)` / `(error: …)`. This mirrors the pi TUI's `/tree`, where every line carries content.
2. After picking an entry you're asked whether to **summarize the abandoned branch** — `No summary`, `Summarize`, or `Summarize with custom prompt` (mirrors the TUI; `Esc` backs out to the picker).
3. The backend moves the session leaf and the chat is rebuilt from the new branch. If you picked a user message, its text lands back in the prompt for editing and resending (the leaf moves to that message's *parent*).

Navigation is refused while the agent is streaming. Summarizing requires a selected model.

How it works: the RPC protocol has no `navigate_tree` command, so pi2.nvim bundles a tiny pi extension (`extensions/tree.ts`) and injects it into every RPC process via `--extension`. It registers a `/tree` command whose handler calls pi's `ctx.navigateTree()`; extension commands are awaited end-to-end over RPC, so the chat rebuilds exactly when navigation (and any summarization) completes.

```lua
require("pi").setup({
    tree = {
        enabled = true, -- set false to stop injecting the extension and disable :PiTree
    },
})
```

Requires a pi version whose extension API exposes `ctx.navigateTree` — on older versions the command fails with an explicit error telling you to upgrade or disable the feature.

## Fork and clone

`:PiTree` creates new branches **inside** the current session file. Sometimes you want a **separate session file** instead — pi offers two operations for this, mirroring the TUI's built-in `/fork` and `/clone` (typing `/fork` or `/clone` in the prompt works too):

| | `:PiFork` | `:PiClone` |
| --- | --- | --- |
| Selects | one past **user message** (a picker lists all forkable messages with a `[user]` kind tag and a one-line preview) | nothing (current position) |
| New file starts | the fork replays history **up to** the selected message, then places the message text back in the prompt — edit and resend to re-ask | the **entire active branch** is duplicated up to the current leaf; the chat keeps its content |
| Typical use | "rewind to that earlier question and ask it differently" | "snapshot all my work so far into a fresh file and continue there" |
| New session file | ✓ | ✓ |

The difference in one line: **fork** rewinds to an earlier turn and lets you re-ask (a new narrative from a chosen message), **clone** duplicates everything so far and lets you continue the same narrative in a separate file. In both cases the current tab's session rebinds to the new session file — the original file stays on disk untouched — and the [sessions overview](#sessions-overview-pisessions) refreshes so the new file is reachable from `:PiResume`.

Both operations are refused while the agent is streaming, and both can be **cancelled by extensions** via the `session_before_fork` hook: when an extension refuses the operation (the response carries `cancelled`), nothing happens — no new session, no error.

## Sessions overview (:PiSessions)

When you run several sessions across tabs, `:PiSessions` gives you a single dashboard of everything that is live. It lists **active tab sessions** in tabline order, with **indented child rows** underneath each parent for its **active or unread** sub-sessions. Closed (`dormant`), settled agent workers, and acknowledged completions are hidden from this list to keep it clean — recall them with `:PiSubSwitch` (all manifest children, including dormant). The Agent's `list_subagents` tool still sees every child for reuse via `dispatch_subagents({ target, message })` (dormant children are revived).

- a single **status dot** at the left edge, colored and animated per state: blinking yellow while the agent works (in a background tab), slow-blinking in the compaction color while compacting, steady warning color when the session needs your attention, blinking green when a turn finished while you were in another tab, blinking red when the last turn errored (both consumed — back to idle — when you enter the tab), steady dim when idle, steady error color if the process died. **Sub-session child rows** do not use the green done blink — completion is announced in the parent chat; acknowledged rows are removed from the list (`H` recalls hidden ones).
- the **session name** right after the dot: the backend session name (`:PiSessionName`), falling back to the first user message, then `(unnamed)`,
- the **current session** marked on the dot itself: the dot of the tab you're looking at renders in the agent color — steady when idle, blinking while busy (same rhythm as the other dots, keeping the agent color) — while background sessions blink yellow while working. Each tab's view marks its own session and the marker follows tab switches — no extra text or UI elements.

The list is a single shared buffer (filetype `pi-sessions`): every tab that opens it gets its own window on the same buffer, so a status change redraws all open views at once. Updates are event-driven (agent start/end, compaction, session creation/teardown, attention requests, name changes) — nothing polls.

Keys inside the list: `<CR>` / `o` jump to that session's tab and open its chat (on a child row: bind the tab's chat to that sub-session), `a` / `i` do the same but drop you straight into Insert mode at the very end of that session's prompt draft (multi-line drafts land past the last line — ready to append), `r` renames the session under the cursor (same as `:PiSessionName`, without leaving the list), `s` shows the session's stats dashboard under the cursor (same data as `:PiSessionStats` — tokens, cost, context — in a dialog float, without leaving the list), `c` compacts the session under the cursor in the background (same as `:PiCompact` — the row's status dot switches to the compacting state while it runs, no tab switch), `d` opens the diff review of the session's changed files under the cursor (same panel as `:PiDiff` — the combined git diff in a floating window, without leaving the list), `f` / `C` / `t` fork, clone, or tree-navigate the session under the cursor (same flows as `:PiFork` / `:PiClone` / `:PiTree` — the list jumps to that session's tab first, so the pickers, prefill and streaming guards all run against the right session), `p` previews the session under the cursor — a parent/tab row or a sub-session child row — in the same read-only float viewer with rendered chat history, the session's display name as the title, and a statusline in the footer (context tokens/window, model, thinking level, and a `✓`/`◐`/`○` todo summary when the viewed session has todos; no tab switch): live sessions stream in real time, sessions whose process is gone replay from that session's JSONL file on disk, and inside the viewer `<CR>` promotes a sub-session child row into the tab's chat, while on a parent/tab row it closes the viewer and jumps to that session's tab with its chat prompt focused (warning instead if the session's process is not running), `T` inside the viewer toggles the viewed session's todo list panel, `x` closes a sub-session's RPC process, `n` starts a new π session in a new tab rooted at the project under the cursor — the worktree group it is listed under (the group header or any member row, the main checkout included, which opens an ordinary session there), else the session's own worktree, else its cwd — and warns instead when that directory no longer exists, `<Tab>` / `za` fold or unfold a worktree group or the sub-sessions under a parent (on a child row: collapse its parent and jump to it), `zM` / `zR` collapse or expand all groups and sub-sessions, `H` toggles hidden sub-session rows globally (dormant / settled, every session at once), `h` does the same for the session under the cursor only — on a child row it toggles that child's parent (the subagent's own rows live under its parent), `R` re-fetches session names (and re-detects worktrees), `?` toggles a shortcut help overlay, `q` closes the window.

When the listed sessions span **two or more distinct git worktrees** (see [Worktrees](worktrees.md#where-you-see-it)), rows are grouped under a worktree header — `▾ 󰙅 <name> · ~/path`, and `▸ 󰙅 <name> (n) · ~/path` while the group is folded — instead of staying flat, and the header folds/unfolds its members like a parent row. The `(n)` counts the group's **structural** size (every parent row plus its sub-sessions), is shown while the group is collapsed, and is not changed by folding a parent row *inside* the group — only folding the group does that. The header names the worktree for its whole group, and a sub-session row inside it repeats the name in its subtitle; a session started with `:PiWorktreeFork` carries a `↳ forked from <name>` marker. A single-worktree or non-git list keeps exactly the flat shape it had before.

Sub-session child rows are sorted **newest first** by `created_at`, with the session id as a stable tiebreaker so refresh does not reshuffle them.

Each sub-session is listed under exactly one parent **session**. Two live sessions can share a lineage — a conversation started with `/new` and the original session resumed in another tab — and both would otherwise claim the same child: the conversation that spawned the child (matching conversation epoch) wins, otherwise the conversation the lineage originates from, and failing both, the first live session in tabline order. `H` / `h` never attribute a child to a second session.

A tab that views a sub-session still renders it under its parent's row, marked as that tab's current view — the same parent session, so the marker survives without the child being attributed to a second one.

By default the window follows the current tab's chat layout (a side split when the chat is in side layout, a centered float when it is in float layout); `mode` pins it to one style, and `auto_open` shows the list whenever the chat opens:

```lua
require("pi").setup({
    sessions_list = {
        mode = "follow",   -- "follow" | "side" | "float"
        auto_open = false, -- open the list together with the chat
        collapse_subsessions = false, -- collapse sub-sessions by default
        position = "left", -- side layout: "left" | "right" | "top" | "bottom"
        width = 40,        -- side layout width for left/right
        height = 12,       -- side layout height for top/bottom
        float = { width = 0.5, height = 0.4, border = "rounded" },
    },
})
```

The dot colors are driven by `PiSessionsList*` highlight groups (`Busy`, `Compacting`, `Pending` (attention), `Done`, `Error`, `Exited`, `Idle`, `DotDim`, `Current`, `Worktree`) — see [Highlight groups](highlight-groups.md#sessions-overview).

While the backend is generating a session name (see [Auto session titles](#auto-session-titles)), the session's row animates a spinner between the status dot and the displayed name. The label under the dot stays provisional (the pending placeholder or `(unnamed)`) — the first-message fallback is held back during generation, so the row makes exactly **one** visible change: `(unnamed)` → the generated title (or → the fallback, when generation fails).

## Auto session titles

pi itself does not name sessions: `session_info.name` is only written when someone calls `setSessionName`. With `title` enabled (on by default), pi2.nvim injects a small extension (`extensions/title.ts`) into every RPC process that closes this gap: once per session, right after the **first turn** of a run, it asks the session's own model for a short title and persists it with `pi.setSessionName()`. The name then flows through the normal `session_info_changed` path — `:PiSessions` / `:PiResume` pick it up with no extra plumbing.

Behavior and knobs (`title.*`, see [Configuration](configuration.md)):

- **Generates at most once per session** — the extension skips sessions that already have a name, which also means **user-set names are never overwritten** (`:PiSessionName` / `r` in the sessions list).
- **Language follows the conversation** — the prompt tells the model to title in the language of the user's message; set `title.lang` (e.g. `"zh-CN"`) to pin a language instead.
- **Generation model** — by default the session's own model titles the session; set `title.model` (e.g. `"openai/gpt-4o-mini"`) to pin a separate (e.g. cheaper/faster) model. An unresolvable pin silently falls back to the session model.
- **Length hard-capped** — `title.max_chars` (default 40) is enforced in code: the model hint asks for a short title, the completion is token-capped conservatively, and the final clamp truncates by character with an ellipsis.
- **Never blocks the agent** — generation is fire-and-forget: the `turn_end` handler only schedules the model call and returns, so the agent loop is not stalled between turns.
- **Silent** — no toasts or notifications; progress is visible only as the spinner in `:PiSessions`. Failures keep the session unnamed, falling back to the first user message.
- **Live config** — the options travel through a runtime file re-read on every `turn_end`, so a `setup()` change applies to already-running RPC processes.

Requires **pi 0.44.0+** (the `turn_end` extension event and `setSessionName` were introduced there; on older versions the extension fails to load and sessions stay unnamed — no crash).

## Compaction

Long sessions eventually run into the model's context window limit. pi delegates this to a **compaction** step: the backend summarizes older parts of the conversation and replaces them with the summary, freeing up tokens for new turns. pi supports both automatic and manual compaction.

- **Automatic compaction** is enabled at the backend level. When the conversation approaches the context threshold, pi compacts on its own and the `compaction` statusline component lights up (see [Statusline](usage.md#statusline)) — it renders the same 󰏗 icon as the compaction summary label while auto-compaction is on. `:PiToggleAutoCompaction` / `pi.toggle_auto_compaction()` flips the setting on/off for the current session — the icon appears/disappears immediately and the backend session file records the change. With no active session the command is a silent no-op.
- **Manual compaction** — `:PiCompact [instructions]` / `pi.compact(instructions?)` — triggers compaction immediately. If you pass custom instructions, they're forwarded to the summarizer to guide what gets kept:

```vim
:PiCompact focus on architectural decisions and the reasoning behind them; drop intermediate tool outputs
```

Compaction can't run while the agent is streaming — wait for the current turn to finish (or abort it) first. Message submits during compaction are queued and sent after compaction finishes.

After successful compaction, pi2.nvim renders a collapsed summary block in chat history. Focus the block and press `<Tab>` to expand the backend-generated summary.
