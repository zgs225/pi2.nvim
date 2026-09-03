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

Crucially, sessions are **scoped to the current working directory**. Sessions started in `~/Dev/project-a` are only visible to continue/resume when pi2.nvim is running from the same directory. This matches how you'd actually want it: you don't want to accidentally resume an unrelated project's conversation just because you opened a chat in a new tab.

## Starting, continuing, resuming

There are three ways to open a chat — each honors the usual `layout=side|float` override:

| Command | Lua | What it does |
| --- | --- | --- |
| `:Pi` | `pi.show()` / `pi.toggle()` | Open the chat. If the current tab has no session yet, starts a fresh conversation. |
| `:PiNewTab` | `pi.new_tab()` | Open a **fresh** conversation in a **new** tabpage (`:tabnew` semantics). Uses `layout.default`; no arguments. |
| `:PiContinue` | `pi.continue_session()` | Load the **most recent** session for the current cwd. Skips the session currently live in another tab, so you can continue a different one. |
| `:PiResume` | `pi.resume_session()` | Open a picker listing **past top-level sessions for the current cwd** (sub-sessions are excluded — use `:PiSubSwitch` to reopen a child). See [Resume picker](#resume-picker) for its keybindings. |

### Resume picker

When [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) is installed, `:PiResume` opens a dedicated picker instead of the generic `vim.ui.select` one. The keybindings are shown as a fixed hint in the picker title:

| Key | Action |
| --- | --- |
| `<CR>` / `o` | Open the session in the **current** tab |
| `t` / `<C-t>` | Open the session in a **new** tab |
| `<C-x>` | Delete the selected session file(s) (multi-select aware) |

`<C-t>` exists because typing in the picker prompt is filtering — plain letters (`o`, `t`) work once you leave insert mode with `<Esc>`.

Other `vim.ui.select` backends keep their generic rendering; with snacks.nvim, `t` / `<C-t>` map to "open in new tab" and `<C-x>` still deletes. Whatever the backend, opening a conversation that is still live in another tab asks for confirmation first — resuming it twice would spawn two backend processes writing the same session file, so the copies would diverge.

And mid-session management:

| Command | Lua | What it does |
| --- | --- | --- |
| `:PiNewSession` | `pi.new_session()` | Discard the current session in this tab and start a fresh one. When viewing a sub-session, switches back to the parent first. Sub-session rows from the previous conversation are hidden in `:PiSessions` (press `H` or use `:PiSubSwitch` to recall them). Extensions can cancel this via the `session_before_switch` hook (e.g. to warn about unsaved draft state). |
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

## Sub-sessions

A parent session can run **sub-sessions** in parallel — each child is an independent `pi --mode rpc` process with its own session file, model, and thinking level. Relationships and bookkeeping live in `<agent_dir>/sessions/<encoded-cwd>/.pi2-subsessions.json`; message content stays in each child's JSONL (the authoritative store). Child processes are **detached from the tab**, same as a parent after `:tabclose`: closing the parent tab does not stop running sub-sessions. Stop them with `:PiSubClose` / `x` in `:PiSessions`, `stop_subagents`, `:PiAbort` (cancels the parent's running batches), or by quitting Neovim.

| Command | What it does |
| --- | --- |
| `:PiSubNew` | Prompt for a task; spawn a child in the background. |
| `:PiSubSwitch` | Pick a child (active or dormant) and bind the current tab's chat to it. |
| `:PiSubParent` / `gp` in history | Switch back to the parent; breadcrumb `◂ 父：…` shows while viewing a child. |
| `:PiSubClose` | Close the current sub-session's RPC process (session file retained). |

Switching parent ↔ child or sibling children **rebinds the tab UI** and rebuilds history from `get_messages`. It does **not** send RPC `switch_session` when the target process already has that session file open, so a running agent on the target is not aborted. The statusline spinner elapsed time continues from that session's first `agent_start` for the current run (it does not restart when you switch). Dormant children are revived in a new process, which still loads the file via `switch_session`.

While viewing a child, `:PiNewSession` / `pi.new_session()` or a bare `/new` in the prompt (e.g. `<C-g>n` in a typical setup) **returns to the parent first**, then starts a fresh parent conversation — same as running `/new` on the parent. Prior-conversation sub-session rows are hidden in `:PiSessions` (press `H` or use `:PiSubSwitch` to recall them).

When a user-spawned child finishes, its last assistant message is injected into the parent as `[子会话「name」已完成] …` or `[Sub-session "name" completed] …` (language follows `title.lang` / UI locale). Agent-spawned children skip this injection — they receive a synchronous tool result instead. Configure via `subagent.*` in [Configuration](configuration.md).

Parent Agent tools are provided by the bundled `extensions/subagent.ts` extension when `subagent.enabled` is true. See [Extensions](extensions.md#bundled-sub-agent-extension-extensionssubagentts).

**Agent workflow:** `list_subagents` to discover children → `dispatch_subagents` for all work (single item or parallel batch). Use `wait: true` on dispatch for one-shot results, or `poll_subagents` / `wait_subagents` with the returned `batch_id`. `stop_subagents` to close processes. Failure policy defaults to **collect_errors**.

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

When you run several sessions across tabs, `:PiSessions` gives you a single dashboard of everything that is live. It lists **active tab sessions** in tabline order, with **indented child rows** underneath each parent for its **active or unread** sub-sessions. Closed (`dormant`), settled agent workers, and acknowledged completions are hidden from this list to keep it clean — recall them with `:PiSubSwitch` (all manifest children, including dormant). The Agent's `list_subagents` tool still sees every child for reuse via `dispatch_subagents({ target, message })`.

- a single **status dot** at the left edge, colored and animated per state: blinking yellow while the agent works (in a background tab), slow-blinking in the compaction color while compacting, steady warning color when the session needs your attention, blinking green when a turn finished while you were in another tab, blinking red when the last turn errored (both consumed — back to idle — when you enter the tab), steady dim when idle, steady error color if the process died. **Sub-session child rows** do not use the green done blink — completion is announced in the parent chat; acknowledged rows are removed from the list (`H` recalls hidden ones).
- the **session name** right after the dot: the backend session name (`:PiSessionName`), falling back to the first user message, then `(unnamed)`,
- the **current session** marked on the dot itself: the dot of the tab you're looking at renders in the agent color — steady when idle, blinking while busy (same rhythm as the other dots, keeping the agent color) — while background sessions blink yellow while working. Each tab's view marks its own session and the marker follows tab switches — no extra text or UI elements.

The list is a single shared buffer (filetype `pi-sessions`): every tab that opens it gets its own window on the same buffer, so a status change redraws all open views at once. Updates are event-driven (agent start/end, compaction, session creation/teardown, attention requests, name changes) — nothing polls.

Keys inside the list: `<CR>` / `o` jump to that session's tab and open its chat (on a child row: bind the tab's chat to that sub-session), `a` / `i` do the same but drop you straight into Insert mode at the very end of that session's prompt draft (multi-line drafts land past the last line — ready to append), `r` renames the session under the cursor (same as `:PiSessionName`, without leaving the list), `s` shows the session's stats dashboard under the cursor (same data as `:PiSessionStats` — tokens, cost, context — in a dialog float, without leaving the list), `c` compacts the session under the cursor in the background (same as `:PiCompact` — the row's status dot switches to the compacting state while it runs, no tab switch), `d` opens the diff review of the session's changed files under the cursor (same panel as `:PiDiff` — the combined git diff in a floating window, without leaving the list), `f` / `C` / `t` fork, clone, or tree-navigate the session under the cursor (same flows as `:PiFork` / `:PiClone` / `:PiTree` — the list jumps to that session's tab first, so the pickers, prefill and streaming guards all run against the right session), `p` previews a sub-session's recent messages in a read-only float (no tab switch), `x` closes a sub-session's RPC process, `H` toggles hidden sub-session rows (dormant / settled), `R` re-fetches session names, `?` toggles a shortcut help overlay, `q` closes the window.

Sub-session child rows are sorted **newest first** by `created_at`, with the session id as a stable tiebreaker so refresh does not reshuffle them.

By default the window follows the current tab's chat layout (a side split when the chat is in side layout, a centered float when it is in float layout); `mode` pins it to one style, and `auto_open` shows the list whenever the chat opens:

```lua
require("pi").setup({
    sessions_list = {
        mode = "follow",   -- "follow" | "side" | "float"
        auto_open = false, -- open the list together with the chat
        position = "left", -- side layout: "left" | "right" | "top" | "bottom"
        width = 40,        -- side layout width for left/right
        height = 12,       -- side layout height for top/bottom
        float = { width = 0.5, height = 0.4, border = "rounded" },
    },
})
```

The dot colors are driven by `PiSessionsList*` highlight groups (`Busy`, `Compacting`, `Pending` (attention), `Done`, `Error`, `Exited`, `Idle`, `DotDim`, `Current`) — see [Highlight groups](highlight-groups.md#sessions-overview).

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
