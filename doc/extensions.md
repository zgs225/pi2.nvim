# Extensions & custom rendering

pi extensions are small TypeScript (or Node-compatible) modules that the backend loads at session start. They can intercept tool calls, register slash commands, expose keybindings, surface UI to the user, and inject arbitrary content into the chat. The permission extension in [Diff review](diff-review.md) is one example; the `rules:load` / progressive-disclosure hooks in [agentic-af](https://github.com/alex35mil/agentic-af) are others.

pi2.nvim is extension-aware. When pi runs under `--mode rpc`, extensions can address the client (pi2.nvim) via the [extension UI protocol](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md#extension-ui-protocol), and pi2.nvim routes each method to the right surface in your editor:

| Extension UI method | Where pi2.nvim surfaces it |
| --- | --- |
| `notify` | `vim.notify` via the configured notify dispatcher |
| `setStatus` | `state.extensions[key]` in the statusline state (readable by custom [statusline](usage.md#statusline) components) |
| `setWidget` with key ending in `:startup` | [Startup block](#extension-startup-announcements) announcement |
| `setWidget` with any other key | Your `on_widget` config hook (see below) |
| `select` | Dialog or [diff review](diff-review.md), depending on the payload |
| `confirm` | Confirmation dialog |
| `input` / `editor` | Input dialog |
| `setTitle`, `set_editor_text` | Currently ignored (warned once) |

Dialog-style methods (`select`, `confirm`, `input`, `editor`) flow through the [Attention & dialogs](attention.md) queue described above. This page focuses on the pieces that aren't covered there: startup announcements, `on_widget`, and adapting non-upstream RPC backends.

## Extension startup announcements

Extensions can add their own sections to the [startup block](usage.md#startup-block) by calling `ctx.ui.setWidget` with a **widget key ending in `:startup`**. pi2.nvim routes those widgets into the startup block instead of rendering them inline, and the `:startup` suffix is stripped from the key for display.

For example, an extension calling:

```ts
ctx.ui.setWidget("permission:startup", [
    "defaultMode: ask",
    "allow: read, bash(git *)",
    "deny:  bash(rm -rf *)",
])
```

renders in the startup block as:

```
[Extension: permission]
  defaultMode: ask
  allow: read, bash(git *)
  deny:  bash(rm -rf *)
```

This is the intended surface for extensions that want to show session-relevant state the user should see up-front (current mode, loaded rules, active hooks, etc.) without cluttering the conversation itself.

Note the distinction from regular widgets: `setWidget` calls with keys that **don't** end in `:startup` are passed to your `on_widget` config hook instead and can be rendered inline in the history — the next section.

## Inline custom blocks via `on_widget`

> [!NOTE]
> Conceptually, this is a hack. `setWidget` was designed in the upstream pi protocol as a way for extensions to surface UI widgets in the TUI, not as a general extension ↔ pi2.nvim communication channel. pi2.nvim piggybacks on it because it's currently the **best handle pi provides** for an extension to push arbitrary data into the client. If/when pi gets a dedicated extension-to-client message type, this mechanism will likely be revisited. For now, treat `on_widget` as the escape hatch where "extension wants to say something to pi2.nvim" becomes possible at all.

When an extension calls `ctx.ui.setWidget(key, lines)` with a key that **doesn't** end in `:startup`, pi2.nvim passes it to your `on_widget` config function. The hook gets a chance to return a **custom block** that pi2.nvim will render inline in the history — right at the point in the conversation where the extension fired.

The signature:

```lua
---@param key string            -- the widgetKey the extension sent
---@param lines string[]|nil    -- widgetLines (nil when the extension cleared the widget)
---@param placement string|nil  -- "aboveEditor" / "belowEditor" (as sent by the extension)
---@return pi.CustomBlock|nil
function(key, lines, placement)
    -- return a block, or nil to ignore this widget
end
```

Return `nil` to ignore a widget and let it vanish quietly. Return a `pi.CustomBlock` to render it inline:

```lua
---@class pi.CustomBlock
---@field target  "history"          -- only "history" is supported today
---@field block   "custom"           -- discriminator; always "custom"
---@field content pi.CustomBlockLine[]
```

A `pi.CustomBlockLine` is a list of styled chunks, and each chunk is a `{ text, hl_group? }` pair:

```lua
-- One line, two chunks with different highlights:
{
    { "    ╰  rule: ", "Comment" },
    { ".agents/rules/ts.md", "PiMention" },
}
```

### Example

Let's walk through a concrete case. My [rules extension](https://github.com/alex35mil/agentic-af/tree/main/extensions/rules) discovers Markdown rule files under `~/.pi/agent/rules/` (global) and `<repo>/.agents/rules/` (project). Some rules are always-on — their bodies are injected into the system prompt on every turn. Others are **path-scoped**: they have a `paths:` glob list in the frontmatter and are only delivered when the agent reads a file that matches one of those globs. In that case the extension appends the rule body to the `read` tool result (so the agent sees it) _and_ fires a `setWidget("rules:load", [...rule paths])` so **you** can see, inline in the chat, which rules just got loaded for which file.

Without `on_widget`, that widget would simply be ignored by pi2.nvim. With `on_widget`, it becomes a small annotation attached to the read tool call, telling you exactly which rules the agent now has in its context for the file it just read. It's the difference between trusting that the rules extension is doing its job and being able to _see_ it do its job.

Here's the hook that turns that widget into an inline annotation:

```lua
require("pi").setup({
    on_widget = function(key, lines)
        if key == "rules:load" and lines then
            local content = {}
            for _, line in ipairs(lines) do
                content[#content + 1] = {
                    { "   ╰  rule: " .. line, "Comment" },
                }
            end
            return {
                target = "history",
                block = "custom",
                content = content,
            }
        end
        return nil
    end,
})
```

On the extension side, the rules extension watches tool calls (`read`, `edit`, `write`, etc.) and, when it matches a file against one of its rule definitions, fires a widget listing the **paths of the rule files** that apply:

```ts
ctx.ui.setWidget("rules:load", [
    ".agents/rules/lua.md",
    ".agents/rules/neovim.md",
])
```

pi2.nvim calls your `on_widget`, sees the returned block, and writes it into the history buffer at the current insertion point — so the list appears directly underneath the tool call that triggered it, making it obvious which rules the agent should have loaded for that particular file.

The payload the extension sends is deliberately minimal (just rule file paths); turning that into a nicely-formatted inline block — prefix, icon, highlight — is entirely the job of `on_widget` on the Neovim side. Different users can present the same widget data however they want without the extension having to know anything about styling.

### Limitations

Same upstream constraint as the [startup block](usage.md#startup-block): `setWidget` in RPC mode only carries string arrays. Styling and structure are added _in pi2.nvim_ by your `on_widget` hook — the extension can't pre-style the output. Give `on_widget` everything it needs to make decisions (the `key` namespaces widgets from different extensions, and `lines` carries the payload) and do the formatting there.

## Adapting non-upstream RPC backends

pi2.nvim targets upstream pi RPC. If you point `cli.bin` at a fork with a different protocol, use `rpc.map_command` / `rpc.map_event` to translate in user config instead of patching pi2.nvim core.

Both hooks receive the message plus a context table and return the mapped message, or `nil` to drop it. The context currently exposes `ctx.set_commands(commands)`, which replaces pi2.nvim's shared slash-command cache (the same cache populated by upstream `get_commands` responses — it feeds completion, prompt decorators, and command-aware chat behavior; it does not re-render the already-visible startup block).

<details>
<summary>Example: adapt `omp` command-list compatibility</summary>

```lua
local function normalize_omp_commands(commands)
    local result = {}
    for _, command in ipairs(commands or {}) do
        local cmd = vim.deepcopy(command)
        if cmd.source == "file" or cmd.source == "custom" or cmd.source == "mcp_prompt" then
            cmd.source = "prompt"
        elseif cmd.source == "builtin" then
            cmd.source = "extension"
        end
        result[#result + 1] = cmd
    end
    return result
end

local function strip_ansi(text)
    return text:gsub("\27%[[0-9;]*m", "")
end

require("pi").setup({
    cli = { bin = "omp" },
    rpc = {
        map_command = function(cmd)
            if cmd.type == "get_commands" then
                local mapped = vim.deepcopy(cmd)
                mapped.type = "get_available_commands"
                return mapped
            end
            return cmd
        end,
        map_event = function(msg, ctx)
            if msg.type == "command_output" then
                local text = strip_ansi(msg.text or "")
                if text ~= "" then
                    vim.schedule(function()
                        require("pi.notify").info(text)
                    end)
                end
                return nil
            end
            if msg.type == "ready" then
                return nil
            end
            if msg.type == "response" and msg.command == "get_available_commands" then
                local mapped = vim.deepcopy(msg)
                mapped.command = "get_commands"
                if mapped.data then
                    mapped.data.commands = normalize_omp_commands(mapped.data.commands)
                end
                return mapped
            end
            if msg.type == "available_commands_update" then
                ctx.set_commands(normalize_omp_commands(msg.commands))
                return nil
            end
            return msg
        end,
    },
})
```

</details>

## Bundled sub-agent extension (`extensions/subagent.ts`)

When `subagent.enabled` is true (default), pi2.nvim injects `extensions/subagent.ts` into **parent** RPC processes (child sub-session processes get `extensions/subagent-child.ts` instead — see below; `subagent.enabled = false` injects neither). The extension registers Agent-callable tools:

| Tool | Role |
| --- | --- |
| `list_subagents` | Read manifest; list children of the current session (including dormant / settled). A child whose last run failed carries the backend's reason in `error`, so the orchestration agent does not have to re-run it to find out why. |
| `read_subagent` | Project the tail of a child's JSONL (observation, no host round-trip; lossy projection, default 50 entries, `tail` overrides). A failed assistant turn appends ` (error: <errorMessage>)` — its content is empty, so the reason would otherwise be invisible. |
| `list_batches` | List dispatch batches for the current parent session |
| `dispatch_subagents` | Fan out parallel work (mixed `{ task }` spawn + `{ target, message }` reuse). Dormant/settled ids still work — the host revives the process (subject to `subagent.max_children`). Optional `wait: true` blocks until done. A `{ task }` item takes an optional `name` (short label for the child, see [Sessions → Sub-session names](sessions.md#sub-session-names)) plus optional `model` / `thinking_level` and an optional `tools` allowlist, which **replaces** the child's whole tool selection (`pi --tools …`, see [Constraining a child's tools](sessions.md#constraining-a-childs-tools)); a `{ target, message }` item accepts only `ref`, `target` and `message`. |
| `poll_subagents` | Poll batch progress by `batch_id` (idempotent) |
| `wait_subagents` | Block until a batch reaches a terminal state |
| `stop_subagents` | Close one or more child RPC processes (`targets: string[]`) |

**Chat rendering:** sub-agent tools use localized short labels (`子·派发` / `sub·dispatch`, from `title.lang` or your UI locale), Material Design outline nerd-font icons, and manifest **names** for child targets (same source as `:PiSessions` child rows; UUIDs truncate to `…suffix` unless `subagent.show_full_ids` is true). A `{ task }` item renders the `name` it was dispatched with; without one the label falls back to the first 40 task characters (the same derivation the manifest stores, and which the child's own generated title later replaces — see [Sub-session names](sessions.md#sub-session-names)). `dispatch_subagents` renders as a **block** when `items` has more than one entry or `wait` is not `true`; a single item with `wait: true` stays **inline** like `read` or `bash`. The block body is a compact status list that always occupies **one line per item** (plus the generic footer) — a tree-shaped row per item instead of the former task tree + `status:` line + separate result list: `  ├─ ✓ name` for every item but the last, `  └─ ✗ name — <first 80 characters of the error>` for it. The mark encodes the item state: `✓` ok, `✗` failed, `⊘` cancelled, `◐` spawning/running, `·` queued — and while every item is still `queued` no marks are drawn at all (a plain tree). The row label is the same name derivation described above (explicit `name`, else the manifest name, else the first 40 task characters), prefixed with `[ref] ` **only** when the caller passed an explicit `ref` on the item — the default index ref is never rendered. The batch status summary lives only in the block header's inline status (`0/4 running`; terminal states are localized, e.g. `4/4 已完成` / `2/4 部分失败` / `3/4 失败` / `1/4 已取消`) — the body draws no `status:` line — and the header's detail part omits zero counts (`4 items (spawn×4)` rather than `spawn×4 · msg×0`). `ok` rows no longer show a child-output summary; error detail appears only at the tail of a failed/cancelled row, and a tool-level error appends one `! …` line after the tree. `poll_subagents` and `wait_subagents` are inline rows with no body, so their detail names the batch by its **items** instead of its id: up to three labels, elided as `+N` (`auth-review, schema-fix, docs-sweep, +2`), read from the persisted batch record — the same source `:PiSessions` batch rows use, so a replayed block resolves too, with `batch …123456` as the fallback when the record is gone. `wait_subagents` appends the wait window when the caller passed one (`(timeout 300s)`). Their header status appends the items that did not come back cleanly (`5/5 partial · ✗ schema-fix, ✗ docs-sweep`, glyphs as in the block marks), because the counters alone say how many failed but never which ones. None of this is configurable: `subagent.*` options are unchanged, and no new configuration option or highlight group is involved. When items specify an explicit `model` and/or `thinking_level` (or reuse a child with manifest configuration), the model id and thinking level are rendered alongside the item label in the running-phase task tree and in the single-item inline rendering (e.g. `(claude-3-7-sonnet · think: high)`); the final per-item status rows keep just the name derivation above.

Action tools tunnel through a silent `ctx.ui.select` with title `__pi_subagent__`, handled in `lua/pi/ui/extension.lua` without showing a picker. That path requires a host UI (`ctx.hasUI`); without it the tools return `{ error: "host UI not available" }` instead of dispatching. When `dispatch_subagents` specifies an explicit `model` that does not exist on the backend, spawn fails fast and the item error reports available models to enable self-correction. `stop_subagents` reports `stopped` as the number of child RPC processes that were actually running (invalid ids are ignored). See [Sessions → Sub-sessions](sessions.md#sub-sessions).

**Item validation:** `dispatch_subagents` accepts at most `subagent.max_batch_size` items (default 5) and refuses to exceed `subagent.max_children` children per parent lineage (default 5). A slot is held by every child whose RPC process is still alive in this Neovim instance (dead processes do not count) plus spawns still in flight. When dispatching, required slots count every spawn item plus distinct dormant reuse targets whose RPC process is not running (reviving them spins up a new process; reusing an already-alive child process consumes no new slot). When dispatching, spawning, or reviving would exceed the cap, pi2.nvim automatically reaps the oldest settled-but-alive children in the lineage to make room (ordered by `last_active_at` LRU; only settled children not currently viewed in any tab and not scheduled for reuse in the current batch are closed — the session file is retained, status turns `dormant`, and the child remains revivable). Only when all live children are active, viewed, or reserved for reuse with no settled child to reap does it fail: a dispatch call whose required slots still exceed the limit fails with `{ error: "would exceed max N concurrent sub-sessions" }` and no `batch_id`; an individual spawn or revive attempt that reaches the live-children limit fails with `max N concurrent sub-sessions`. A `{ target, message }` reuse item pre-checks that `target` exists and belongs to the current session's lineage: an unknown child target fails fast at dispatch entry with `item N: unknown sub-agent target`, and a child belonging to another parent session fails with `item N: target X is not a sub-agent of this session` (both returning `{ error }` with no `batch_id`). A reuse item keeps the revived child's own model, thinking level and name, so `name`, `model`, `thinking_level` and `tools` are spawn-only and are **rejected** on reuse items rather than silently ignored (other unknown keys are still dropped — the schema does not set `additionalProperties: false`, so `normalize_item` is the enforcement point). `tools` is validated like the config option: it replaces the child's whole tool selection, so an empty array or a malformed name fails the item instead of handing the child everything. Item `ref`s must be **unique within a batch** (an omitted ref defaults to the item's 0-based index): a duplicate is rejected, because `patch_item` and `on_child_settled` resolve an item by ref with first-match-wins, so a duplicate would misroute a child's completion and leave the batch permanently non-terminal. The tool schemas document every parameter, return shape and status enumeration (batch statuses `running` / `completed` / `partial` / `failed` / `cancelled`, item statuses `queued` / `spawning` / `running` / `ok` / `failed` / `cancelled`, child statuses `active` / `completed` / `failed` / `interrupted` / `dormant`), so the Agent does not need to guess them. A run that fails on the backend (quota/auth/network — `stopReason: "error"`) settles its item as `failed` with the provider's message in `error`, which is what the failed row's excerpt renders; see [Sessions → Failed runs](sessions.md#failed-runs).

**System-prompt notes:** both extensions append a short, **byte-constant** note to the system prompt on every turn via the `before_agent_start` hook. `subagent.ts` adds a compact delegation policy: spawn subagents for parallelizable, modular, or context-heavy work (independent modules, broad exploration, large migrations, batch fixes, separate review/testing); keep architecture, interfaces and final integration; avoid subagents for small edits, tightly coupled changes, sequential dependencies or shared runtime context; give each subagent clear scope, exclusive files, acceptance criteria and concise reports; spawn only when coordination cost beats doing it yourself; and constrain a read-only child with `tools: [...]` so it cannot edit, since *a prompt alone will not stop it* (the allowlist is the enforcement, the note only points at it — see [Constraining a child's tools](sessions.md#constraining-a-childs-tools)). Tool existence is taught by the `Available tools` entries below, not by the note. The per-child `model` / `thinking_level` choice heuristics live in the `dispatch_subagents` field descriptions, not the note, so there is a single source of truth; `subagent-child.ts` adds a worker note (no interactive user, never ask questions, the last assistant message is the final report, stay strictly within the task, no nested sub-agents) plus the four rules of the [reporting contract](sessions.md#reporting-contract) — the report goes in that last message rather than in a file the parent is only pointed at, file paths are absolute because the parent resolves them against its own cwd, the outcome leads and the whole thing stays under roughly 200 words unless detail was asked for, and the report closes with exactly one `STATUS: ok` / `STATUS: blocked` / `STATUS: failed` line. The contract lands reliably precisely because that last message *is* the delivery channel: there is no second artifact the report could live in, a child that skips the marker still has its report delivered verbatim (only the notice header lacks a status), and no rule can change what the host actually reads. The text is byte-identical on every submission, so it does not invalidate pi's prompt-cache prefix — same rationale as the [vision fallback](usage.md#vision-fallback) capability note. Per-turn state (like the live child inventory) deliberately stays out of the prompt; `list_subagents` is the live source.

**`Available tools` entries:** each of the seven tools also declares a one-line `promptSnippet`, so pi lists it in the default system prompt's `Available tools` section (`- dispatch_subagents: Run sub-agent tasks in parallel (fan out, or reuse an existing child)`). This is required, not cosmetic: pi builds that section from `toolSnippets[name]`, so a registered custom tool **without** a snippet is omitted from the list entirely — models that discover tools by reading it would never learn these exist. The snippets are static text taken from the tool definitions, so they stay byte-constant across turns.

## Bundled todo extension (`extensions/todo.ts`)

When `todo.enabled` is true (default), pi2.nvim injects `extensions/todo.ts` into every RPC process — **both** parent and sub-session child processes (unlike the sub-agent tools there is no nesting risk; same unconditional pattern as the [auto-title](sessions.md#auto-session-titles) extension). `todo.enabled = false` skips the injection at spawn time, and because the options travel via a runtime file (see below) a later `setup()` flip applies to already-running sessions without a respawn.

**Tool:** the extension registers a single Agent-callable tool, `todo_write`, with **full-replacement semantics** — every call submits the complete list (an empty array clears it), and items are identified by their content rather than ids. The `execute` handler is the enforcement point for the list discipline: a call is rejected with an explanatory error (and the previous list left unchanged) when an item lacks a non-empty imperative `content`, carries an invalid `status`, exceeds `todo.max_items` items (default 20), or marks more than one item `in_progress`. The result carries the canonical state in its `details` field — `{ todos, completed, total }` (plus an `error` string on rejected writes) — which is both the branch-correct persistence source and what pi2.nvim renders.

**Context management** is layered (static vs dynamic — same rationale as the sub-agent system-prompt notes):

- **L1 · `before_agent_start`** appends a **byte-constant** discipline note to the system prompt (when to keep a list, full-replacement semantics, exactly one `in_progress`, mark completions immediately, the `content`/`activeForm` phrasing). The text is byte-identical on every submission so it does not invalidate pi's prompt-cache prefix; tool existence is taught by the tool's `promptSnippet` in the `Available tools` section, not by the note.
- **L2 · `context`** runs before every LLM call but only fires while the list is non-empty: it appends a compact synthetic status message (`[todo] 2/5 completed — in progress: …`, plus up to ten incomplete items) and — predicate-gated — a stale-list reminder once more than `todo.remind_after_turns` turns (default 3; `0` disables) have passed since the last `todo_write` call. `event.messages` is a deep copy, so the injection is non-destructive: nothing is persisted to the session, and because it is re-computed on every call it survives compaction.
- **L3 · persistence:** state is reconstructed from the branch's `todo_write` tool results on `session_start` / `session_tree` (the latest successful `details` wins, so branch switches are automatically correct); if compaction has dropped those results, the latest `pi.appendEntry` checkpoint (custom type `pi2-todo`, written on every successful call) is the fallback.

**Config transport:** `enabled` / `remind_after_turns` / `max_items` are published by pi2.nvim to the `PI_NVIM_TODO_FILE` runtime file (a JSON file under `stdpath("run")`, named per Neovim instance so concurrent nvim processes don't clobber each other). The process env is frozen at spawn, so the extension re-reads the file on every relevant event — live `setup()` calls apply without respawning the RPC process (same pattern as the [auto-title](sessions.md#auto-session-titles) extension).

**Chat rendering:** pi2.nvim gives `todo_write` a dedicated tool-block renderer (the three-state ✓/◐/○ checklist) and mirrors the latest list into the `:PiTodo` side panel — see [Usage → Todo list](usage.md#todo-list).

## Bundled background-tasks extension (`extensions/bg-tasks.ts`)

pi core deliberately has no background bash. This extension fills the gap by **overriding the built-in `bash` tool** — extension tools with the same name win over the builtin registry entry — adding two optional parameters to the schema the model sees, `run_in_background` and `deadline_ms`. The tool name stays `bash`, so pi2.nvim keeps rendering it with the existing bash renderer.

**Loading.** `bg-tasks.ts` is injected into every RPC process unconditionally (like the vision/title extensions) — the override is inert until the model passes `run_in_background` or a user command uses the `&` prefix. It requires pi **0.85.1+** (the version its package-root re-exports are verified against); below the floor the extension fails to load, pi logs the error, and sessions keep stock bash — no crash, `:PiTasks` just stays empty. `:checkhealth pi` reports both the file presence and the version floor. To opt out entirely, pass `--no-extensions` via `cli.args` (applies to all bundled extensions).

**One spawn routine, two attach policies.** Both paths below run through the same `startTask()`: the command spawns detached (`shell -c <command>`, unref'd) with stdout/stderr streamed to `pi-bash-<taskId>.log` in the system temp directory. What differs is only how long the tool call stays **attached** to that process.

**Foreground (default).** The call stays attached for the attach window — the `timeout` parameter, default **2 minutes** (clamped to 1s…10min) — so anything that finishes quickly behaves like stock `bash`: the output comes back as the tool result, truncated to pi's usual 50 KiB / 2000 lines with the standard spill-file footer, and a non-zero exit renders as `Command exited with code N` with the error flag set. Two deliberate differences from stock pi: (1) a command that **outlives its window is not killed** — it keeps running as a background task and the call returns `[still running]` plus the task id and the output so far (the way Claude Code treats a command that outlives its timeout); (2) abort (Esc) still SIGKILLs the process group and returns `[cancelled]`. The log of a command that finished inside its window is deleted unless the footer points at it, so `/tmp` stays proportional to *running* tasks rather than to every call.

**Background (`run_in_background: true`).** Intended for long-running commands — dev servers, watchers, long builds, slow test suites. The tool returns immediately with the task id and output file path; the `timeout` parameter does not apply. The `started` row appears in `:PiTasks` at that moment, and the command is a normal wake target from then on.

**Checking in on a long task (`deadline_ms`) and the lifetime note.** A background task that never exits used to mean the agent was simply never told anything: `timeout` is the attach window, not a deadline. Two timers now cover that hole, and **both only notify — neither kills, signals or finishes anything**. `deadline_ms` (model-facing, next to `run_in_background`, clamped to 0.5 s…24 h) arms when a task *becomes* a background task, and on expiry sends **one** check-in carrying the task id, `status="running"`, the elapsed time and an output tail (last 20 lines / 2 KiB), after which the process keeps running untouched. It arms in both places a task becomes a background task — the `run_in_background: true` return path and the path where a foreground command outlives its attach window and detaches — but only the first has a deadline to arm (there `timeout` was the attach window, not a check-in deadline), so a detached command gets only the lifetime note. Separately, **every** background task (including the `&` prefix path) gets an advisory lifetime note: `DEFAULT_MAX_LIFETIME_MS` (24 h, or `PI_BG_TASK_MAX_LIFETIME_MS` in the child process's environment, in milliseconds, read when the timer is armed) sends **one** message saying the task is still running after the cap, that it is **not** being killed, and that `stop_task` ends it. Both are one-shot (`deadlineNoted` / `lifetimeNoted`), both are `unref()`'d so they never hold the process open, and both are cleared when the task finishes, so a check-in about a task that already exited is impossible. A check-in is **advisory and best-effort**, deliberately outside the delivery ladder below: it carries no `details` (so it cannot fabricate a `:PiTasks` row) and marks no delivery state, which is why the exit report still arrives exactly once, through the ladder, after any number of check-ins.

**Waiting: `wait_task`.** A companion tool, `wait_task(task_id, timeout_ms?)` (default 120s, max 30min), blocks server-side until the process exits, its own deadline passes, or the call is aborted — event-driven, no polling, so a task that exits in 3 seconds returns in 3 seconds instead of after whatever `sleep` the model would have picked. Hitting the deadline does **not** kill the process and is reported as `[still running]` plus the output so far, explicitly labelled as *not* a failure so the model retries the wait or ends its turn. The tool exists so that `sleep` stops being the model's only blocking primitive: a model that wants the result before it can say anything else has somewhere to block, and a model with other work is told to do that instead.

**Feeding a task: `task_input`.** Every task used to be spawned with `stdio: ["ignore", "pipe", "pipe"]` — stock pi's answer — so a command that asks a question reads an **EOF**: an interactive tool either aborts or blocks forever, the precise shape of the "never exits, never notifies" failure. Background paths (`run_in_background`, and the `&` prefix on an interactive `!` command) now get a **stdin pipe** and a companion `task_input(task_id, data, newline?)` that writes to it and returns the output produced so far: `newline` defaults to `true` (Enter, for a line-oriented prompt) and `false` sends raw characters. Foreground commands keep `ignore`, so their behaviour stays byte-for-byte stock — which also means a foreground command that outlives its window and detaches has no stdin, and `task_input` answers `no usable stdin` (naming the reason) rather than dropping the text silently; the same is true of an **adopted** task, whose pipe died with the process that owned it. Writing to a pipe the process closed is not an error path anyone has to catch: the stream's `error` handler marks it closed and the next write reports it. The pipe is **not a TTY**, and that is the boundary of this feature: line-oriented reads (`read`, a prompt that wants a value, a REPL) work, while a tool that insists on a terminal (`isatty`, arrow-key menus, curses) still sees a pipe and may refuse or fall back to a non-interactive mode — a PTY per task is what it would take to cover those, and it is not what this does.

**Stopping and listing: `stop_task` / `list_tasks`.** The panel's `x` used to be the only way to end a task — a model that no longer wanted one (a dev server holding its port, a watcher for a file it had already fixed) could only wait for it or ignore it for the rest of the session. `stop_task(task_id, timeout_ms?)` gives the model the same control: it signals the task's **process group** with SIGTERM — every task is spawned `detached: true`, so the child is its own group leader and `npm run dev`'s `node` child is in the group; signalling the bare pid would orphan it, holding the port while the row read "stopped" — and escalates to SIGKILL when the task has not exited within the grace window (default 5s, clamped to 0.5s…30s). The exit a stop causes is claimed before the signal is sent, so the stop's own tool result reports it and `markConfirmed` keeps it from also arriving as a wake report. `list_tasks(include_finished?)` lists this session's task table (adopted records included, marked as such) (running by default, oldest first; finished ones newest first, capped at 40 rows) with id, state, elapsed, command and output file, so the model can recover an id it no longer has in front of it instead of guessing one.

**Completion is delivered exactly once through a durable channel.** The tool layer holds an *observer lease*: while a call is attached to a task (a foreground call that finished inside its window, a `wait_task`, or a `stop_task` waiting for the process to die), that call returns the terminal state itself and the wake report is suppressed. A deadline or an abort releases the lease, which re-arms the wake for the later exit. The release is why an aborted `wait_task` cannot swallow a result: the report is not "consumed" at exit, it is only *claimed*, and a claim that never delivers leaves the report pending for the next channel. A boundary entry, a wake message or a tool result is durable; a `context` injection is not, so that one channel can legitimately reach the model twice (see the ladder below) and a run that never completes re-arms it instead of ending silently.

**Delivery ladder.** When a process exits with nobody attached, the report walks `none → sent → confirmed`, and only `confirmed` stops delivery. Confirmation is *evidence*, never intent: either the exact text was observed in the request about to be sent, or — for a report only the `context` fallback could carry — the turn the injection was added to ended with outcome `completed`. The channels:

1. **Panel first.** A `pi2_bg_task` status message (`display: false`, no options) goes out at exit so the `:PiTasks` row leaves its spinner state right away — appended at once when idle, deferred to the next turn end while streaming. It never triggers a turn.
2. **Idle → wake.** With no run active, one `pi2_bg_task` message with `triggerTurn: true` starts a turn immediately: a completion that lands while the agent is quiet is the only thing left to do. The wake is **coalesced**: a short (40 ms) timer is armed by **every non-aborted `agent_settled`** as well as by a completion that lands while the session is idle, and it fires once, so every completion of the same burst — two tasks exiting in the same event-loop tick, or one landing while `agent_settled` is about to flush anyway — shares ONE message and ONE turn. This replaces one-wake-per-task, where each exit paid a full context read for what was really a single burst; a report that becomes eligible after the timer fired simply arms a fresh one. The timer waits for an **idle** session: if a run became active inside the 40 ms window (a user prompt, or another wake), the flush is **skipped** — `triggerTurn` would queue the report as a follow-up *turn* instead of letting it arrive at a boundary of the run that is already going — and the reports stay `none` for item 3 or the next `agent_settled` to carry. A queued wake is dropped when its session goes away (`session_shutdown`) or when the process exits, so it can never deliver a replaced session's report.
3. **Busy → turn boundary.** With a run active, the report is appended as a `custom_message` **entry at the next actionable boundary** (`turn_end`, else `agent_before_settle`) together with `continue: true`, so a model that ended its turn while a task was still running picks the result up in the same run instead of going quiet. Entries are committed with the turn **even when the turn ends in an abort**; a steering message is not — it is discarded with the run. That is why delivery does not use `steer`.
4. **Abort wakes nothing.** A run that was aborted keeps its report (committed entry, or still pending) and is read on the next turn: Esc still stops the run, it does not start a new one.
5. **`context` is the receipt and the last resort.** The exact text handed over is looked for in the message list about to be sent: found → `confirmed`. Missing (a dropped message, a stale extension context, a report nothing else could carry) → injected before that request — with one caveat that decides when it counts as delivered: `event.messages` is a per-request deep copy that is **never persisted**, so an injection is not a delivery. A report injected into a request that then fails (provider error, abort, crash) stays `sent` and is injected again on the next attempt; it becomes `confirmed` only when the turn it was added to ends with outcome `completed`. That trades repeats for never losing it: the same report may be injected into up to `1 + retry.maxRetries` attempts (four with pi's default of three retries) — each request that fails after the injection takes the text with it — so the model can see it more than once before a request finally succeeds, and a report can no longer be marked delivered by a request that never arrived. Since only `none` reports are carried by the durable channels, a run that settles **without a completed turn** (retries exhausted, hard provider failure) would leave such a report `sent` with nothing left to deliver it: `agent_settled` therefore **re-arms** every `sent` + `fallback` report as `none` first, and the settle's own wake sends it as a persisted message. Only a **non-aborted** settle re-arms — an aborted one leaves the report `sent` for the next turn, exactly like every other abort — and the re-arm is capped at `MAX_REARMS` (3) per report: a provider that fails in a way that keeps producing fresh runs could otherwise cycle settle → re-arm → wake → settle with no user input at all. Past the cap the report stays `sent` and still rides the `context` fallback on the next user turn, so it is delayed, never lost. A failed request can delay a report, never swallow it.
6. **One message per window.** Several tasks finishing together share ONE message: a single task keeps its output tail (last 40 lines / 4 KiB), a batch carries one `<background-task>` element per task and omits the tails (read the file, or `wait_task` on an id, when the output matters), so a burst of completions cannot flood the context. This holds on **both** paths — the boundary aggregation of item 3 and the coalesced idle wake of item 2: completions that land in the same burst (same tick, same settle window) end up in one message naming every task, and therefore one turn, never one wake per task.

**The report text is a structured block, not prose.** Line 1 is `[SYSTEM NOTIFICATION - NOT USER INPUT]`; line 2 is one sentence saying this is an automated task notification. The payload sits in `<system-reminder>` … `</system-reminder>` and holds one `<background-task>` element per task with the attributes `id`, `status`, `exit_code`, `signal`, `duration_ms` and `output` — `status` is `running`, `completed`, `failed`, `stopped` or `unknown` (stopped when a signal ended it, failed for a non-zero exit or a spawn error, and unknown for an adopted task that vanished with nobody watching, where there is no exit code and no signal to report) — so the reader gets the facts from the element instead of having to parse a sentence, and a test can assert on them. A single task's element also carries the human line (command, exit summary, elapsed time) followed by `Output tail:` and the last 40 lines / 4 KiB; a batch keeps one element per task whose text is the command and omits the tails. Attribute values and the quoted command are escaped (`&` `<` `>` `"`), because a command is arbitrary shell text — `awk '{print $1}' && echo "<done>"` must not be able to close a tag; element text (the command, the exit summary, the output tail) is escaped as **text** (`&` `<`), so a command whose output prints `</system-reminder>` or `<background-task …>` cannot end the block or forge a second element.

The banner is what keeps the report from being read as human input: custom messages map to the user role, and without it models read the report as a person speaking — sometimes as approval for whatever they had proposed before going quiet. Delivering the panel update through the followUp path alone would strand the row on "running" for the whole remainder of a streaming run (followUp queues drain only at run end, and a run that exits via abort/error does not drain them at all).

**Model-facing guidance.** The overridden tool description and every result that starts or hands off a task state the same three rules, phrased as permissions rather than bans: never `sleep` and never poll the output file; if you have other work, do that; if this result is all that is left, **ending your turn is the correct move** (the wake report starts a new turn) or call `wait_task`. The last one exists because the observed failure mode is a model that treats ending its turn while work is still running as giving up on the task. The same description names the control tools: a task you no longer need is stopped with `stop_task`, and `list_tasks` shows what is still running. It also says what a deadline is: `deadline_ms` gives ONE `still running` check-in (with an output tail) at the deadline and does **not** kill the process — a check-in is never a result.

**User path (`&` prefix).** The extension also handles pi's `user_bash` event: an interactive `!`-command whose first token is `&` (`!& npm run dev`) routes to the same background path and returns a `BashResult` immediately instead of streaming output into the chat. Everything else falls through to core's normal foreground execution.

**Process lifetime.** Every spawned process group is tracked; a `process.on("exit")` hook SIGKILLs all of them best-effort when the pi process exits (mirroring core's detached-child cleanup), and the streams are unref'd so a running background task never keeps the agent process alive.

**Task state lives in the transcript (`session_start` fold).** pi core's own background-bash tracking is in-memory and dies with the process; this extension does better, because the alternative is a model that loses every id across a `/reload`. Rather than keep a sidecar file in sync, the extension **folds the session transcript**: every state transition already reaches it as a `pi2_bg_task` custom message (`started` carries `taskId` / `command` / `pid` / `outputFile` / `startedAt` / `sessionId`, a terminal one the exit status), so `session_start` walks `ctx.sessionManager.getEntries()` — every entry, all branches, in append order — and rebuilds the table. There is no second source of truth, nothing can drift, no file has to be written atomically, and the history travels with the session wherever it is copied, exported or forked. Folding deliberately mirrors `lua/pi/tasks.lua:handle_event`, so the model-facing table and the frontend panel cannot disagree about what happened. Two `type: "custom"` entries carry bookkeeping that is ours alone (persisted, never model context): an adoption **claim** and the ids a quitting process **killed**.

**Ownership is the session id that produced a record, never the pid.** A fork or clone copies the parent's entries, so a forked session can read records for processes it never started — and which may still be running. Adopting those would make two sessions report one exit and let a `stop_task` in the fork signal a process the parent is watching (Claude Code has the same class of bug in its forked skill contexts, #110519). So a record whose `sessionId` is not this session's is **foreign**: `list_tasks` shows it only with `include_finished: true`, marked `running elsewhere (session <id>)`, and `wait_task` / `stop_task` / `task_input` refuse it by name. `running elsewhere` is also what a task looks like when *another live pi process* on the same session has claimed it — pi takes no lock on the session file, so the process that adopts a task appends a claim entry naming its pid, and a second process honours an unexpired claim from a pid that is still alive instead of adopting the task twice. On `quit` the instance appends the ids it is about to SIGKILL (`pi2_bg_task_shutdown`), so the next process reads `stopped (SIGKILL)` rather than having to guess; if that write is lost, the pid-liveness check still gives the truthful (if vaguer) "exit status unknown". One `[SYSTEM NOTIFICATION …]` message summarises what the fold found — running in this session / belonging to another session / watched by another process / unverifiable — and finished records stay silent (a resumed session has hundreds, and `list_tasks(include_finished: true)` is where they belong).

**Known limitations.** Spawns build their env from the parent environment plus the current session's `PI_*` metadata and prepend pi's own binary directory to `PATH` (derived from `process.execPath`, since core's `getShellEnv()` is not exported); a custom `shellPath` from pi's settings.json is still invisible to the extension, so the shell comes from the exported `getShellConfig()`. Reconciling a crashed process is best-effort by design: a record is adopted only when its pid is alive **and** is still the same process — identity is the pid's start time, recorded at spawn (`pidStartTime`), so a recycled pid is refused rather than repaired, and a record written before that fingerprint existed has no way to prove itself and is treated as unverifiable; an adopted task has no stdin (its pipe died with the process that owned it), the exit status of a task that died unobserved is genuinely unknown, a `/tree` branch edit rewrites the session file to the active path and can therefore drop records of tasks that were started on an abandoned branch, an adopted task's log keeps growing with nobody reading it the same way as any other background log — and background log files are never cleaned up (only foreground logs are, on a clean attached exit). A report that only the `context` fallback carried does not survive a `/reload` or a crash: it was never persisted, and folding the transcript marks a record that looks completed as confirmed, so it is not re-injected afterwards. Aborting a `wait_task` stops the *wait*, not the process. A check-in is advisory and best-effort by design: it is not part of the exit report's exactly-once delivery, so it may be delayed by a busy run, be dropped by a stale extension context after a `/reload`, or be answered by a turn that immediately ends — the exit report is the contract, the check-in is a nudge. The lifetime cap only notifies: it never ends a task, and a task that outlives it keeps running until `stop_task` or its own exit. An **adopted** task (one rebuilt from the transcript after a reload or a crash) is never armed with either timer — the timers died with the process that armed them, and a successor that re-armed them would repeat a note this session already sent. Two reporting limits are inherent to the delivery model: the `:PiTasks` panel cannot express `unknown` (its `kind` vocabulary is `started` / `completed` / `failed` / `stopped`, so a task that vanished unobserved reads as **failed** in the panel while the report says `status="unknown"`), and a report that becomes due in the last ~40 ms before pi quits is dropped with the queued wake — `session_shutdown` and the exit hook clear the timer, so nothing fires, and the next start sees the finished record through the fold (`list_tasks(include_finished: true)`) rather than an incoming report.

**pi2.nvim side.** Custom messages with `customType "pi2_bg_task"` never render in chat history: the session pipeline (`sessions/manager.lua`) routes their `details` payloads (`started` / `completed` / `failed` / `stopped`, carrying `taskId`, `command`, `pid`, `pidStartTime`, `outputFile`, `exitCode`, `signal` and `startedAt`) into the in-memory task registry (`pi.tasks`, module `lua/pi/tasks.lua`); a terminal state is reported by the agent itself from the delivery ladder above, so no separate `vim.notify` fires. **History replay folds the same payloads**, in transcript order: a resumed session (and a `:PiTree` branch switch, and a compaction rebuild) re-renders its blocks from `get_messages` instead of from live events, and those `role="custom"` entries are the only record of a task's command — without the fold every replayed `wait_task` / `stop_task` / `task_input` block fell back to a bare task id, which is exactly the state a resumed session is in (pi folds the transcript too, so the tasks in front of it have already exited). Replay deliberately skips the panel side effects — auto-open and auto-close — so rebuilding a session cannot pop panels (the rows themselves do land, so `:PiTasks` lists a resumed session's tasks, the same records `list_tasks(include_finished: true)` reports). A batched report deliberately carries **no** `details` — the registry keys on `details.taskId`, so a batched message would fabricate a task row; the per-task status messages are what drive the panel. Reports appended through the boundary are entries, not messages, so they never reach the frontend at all (the panel already knows from the per-task status message). The registry is pure logic — no windows or notifications of its own; the `:PiTasks` panel (`lua/pi/ui/tasks.lua`) subscribes to its debounced refresh callback and redraws. `wait_task` calls get their own tool-block renderer (`tools.lua`): the body leads with the command the task runs (looked up in the registry, which the `started` event — or, after a resume, the transcript fold — populates) followed by the task id and the attach window, and the header carries the outcome — `still running` for a deadline hit, `exit N` / `signal SIG…` for an abnormal exit, nothing for a clean one; the waited task's output is the result body, so a backgrounded command's output is visible in the chat and not only in the panel. `stop_task` renders the same way (command · id, plus the grace window) and badges only what needs attention: `still running` when the stop did not take, `stop cancelled`, `already exited`, and `killed` when SIGTERM had to be escalated; `list_tasks` renders the list as its body. The panel's `x` goes through the same `pi.tasks` helper as the model's `stop_task` (`lua/pi/tasks.lua` `stop`/`kill_group`), so both stop the process group, both escalate SIGTERM to SIGKILL after a grace window (5 s by default for each), and neither can signal pid 0/1. The panel's escalation is disarmed by the backend's own terminal event, so a task that is already settled is never killed behind its back. Other `customType`s are dropped, matching the previous de-facto behavior for custom messages. Panel UI, keymaps, and config: [Usage → Background tasks](usage.md#background-tasks).

