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
| `list_subagents` | Read manifest; list children of the current session (including dormant / settled) |
| `read_subagent` | Project the tail of a child's JSONL (observation, no host round-trip; lossy projection, default 50 entries, `tail` overrides) |
| `list_batches` | List dispatch batches for the current parent session |
| `dispatch_subagents` | Fan out parallel work (mixed `{ task }` spawn + `{ target, message }` reuse). Dormant/settled ids still work — the host revives the process. Optional `wait: true` blocks until done. A `{ task }` item takes an optional `name` (short label for the child, see [Sessions → Sub-session names](sessions.md#sub-session-names)) plus optional `model` / `thinking_level`; a `{ target, message }` item accepts only `ref`, `target` and `message`. |
| `poll_subagents` | Poll batch progress by `batch_id` (idempotent) |
| `wait_subagents` | Block until a batch reaches a terminal state |
| `stop_subagents` | Close one or more child RPC processes (`targets: string[]`) |

**Chat rendering:** sub-agent tools use localized short labels (`子·派发` / `sub·dispatch`, from `title.lang` or your UI locale), Material Design outline nerd-font icons, and manifest **names** for child targets (same source as `:PiSessions` child rows; UUIDs truncate to `…suffix` unless `subagent.show_full_ids` is true). A `{ task }` item renders the `name` it was dispatched with; without one the label falls back to the first 40 task characters (the same derivation the manifest stores, and which the child's own generated title later replaces — see [Sub-session names](sessions.md#sub-session-names)). `dispatch_subagents` renders as a **block** when `items` has more than one entry or `wait` is not `true`; a single item with `wait: true` stays **inline** like `read` or `bash`. The block body is a compact status list that always occupies **one line per item** (plus the generic footer) — a tree-shaped row per item instead of the former task tree + `status:` line + separate result list: `  ├─ ✓ name` for every item but the last, `  └─ ✗ name — <first 80 characters of the error>` for it. The mark encodes the item state: `✓` ok, `✗` failed, `⊘` cancelled, `◐` spawning/running, `·` queued — and while every item is still `queued` no marks are drawn at all (a plain tree). The row label is the same name derivation described above (explicit `name`, else the manifest name, else the first 40 task characters), prefixed with `[ref] ` **only** when the caller passed an explicit `ref` on the item — the default index ref is never rendered. The batch status summary lives only in the block header's inline status (`0/4 running`; terminal states are localized, e.g. `4/4 已完成` / `2/4 部分失败` / `3/4 失败` / `1/4 已取消`) — the body draws no `status:` line — and the header's detail part omits zero counts (`4 items (spawn×4)` rather than `spawn×4 · msg×0`). `ok` rows no longer show a child-output summary; error detail appears only at the tail of a failed/cancelled row, and a tool-level error appends one `! …` line after the tree. None of this is configurable: `subagent.*` options are unchanged, and no new configuration option or highlight group is involved. When items specify an explicit `model` and/or `thinking_level` (or reuse a child with manifest configuration), the model id and thinking level are rendered alongside the item label in the running-phase task tree and in the single-item inline rendering (e.g. `(claude-3-7-sonnet · think: high)`); the final per-item status rows keep just the name derivation above.

Action tools tunnel through a silent `ctx.ui.select` with title `__pi_subagent__`, handled in `lua/pi/ui/extension.lua` without showing a picker. That path requires a host UI (`ctx.hasUI`); without it the tools return `{ error: "host UI not available" }` instead of dispatching. When `dispatch_subagents` specifies an explicit `model` that does not exist on the backend, spawn fails fast and the item error reports available models to enable self-correction. `stop_subagents` reports `stopped` as the number of child RPC processes that were actually running (invalid ids are ignored). See [Sessions → Sub-sessions](sessions.md#sub-sessions).

**Item validation:** `dispatch_subagents` accepts at most `subagent.max_batch_size` items (default 5) and refuses to exceed `subagent.max_children` children per parent lineage (default 5). A slot is held by every child whose RPC process is still alive in this Neovim instance — whatever its manifest status, so completed-but-alive children keep occupying slots while dead processes do not — plus spawns still in flight. A call whose manifest-active children plus new spawn items would exceed the limit fails with `{ error }` and no `batch_id`; an individual spawn item that reaches the live-children limit fails with `max N concurrent sub-sessions`. A `{ target, message }` reuse item keeps the revived child's own model, thinking level and name, so `name`, `model` and `thinking_level` are spawn-only and are **rejected** on reuse items rather than silently ignored (other unknown keys are still dropped — the schema does not set `additionalProperties: false`, so `normalize_item` is the enforcement point). Item `ref`s must be **unique within a batch** (an omitted ref defaults to the item's 0-based index): a duplicate is rejected, because `patch_item` and `on_child_settled` resolve an item by ref with first-match-wins, so a duplicate would misroute a child's completion and leave the batch permanently non-terminal. The tool schemas document every parameter, return shape and status enumeration (batch statuses `running` / `completed` / `partial` / `failed` / `cancelled`, item statuses `queued` / `spawning` / `running` / `ok` / `failed` / `cancelled`, child statuses `active` / `completed` / `failed` / `interrupted` / `dormant`), so the Agent does not need to guess them.

**System-prompt notes:** both extensions append a short, **byte-constant** note to the system prompt on every turn via the `before_agent_start` hook. `subagent.ts` adds a compact delegation policy: spawn subagents for parallelizable, modular, or context-heavy work (independent modules, broad exploration, large migrations, batch fixes, separate review/testing); keep architecture, interfaces and final integration; avoid subagents for small edits, tightly coupled changes, sequential dependencies or shared runtime context; give each subagent clear scope, exclusive files, acceptance criteria and concise reports; spawn only when coordination cost beats doing it yourself. Tool existence is taught by the `Available tools` entries below, not by the note. The per-child `model` / `thinking_level` choice heuristics live in the `dispatch_subagents` field descriptions, not the note, so there is a single source of truth; `subagent-child.ts` adds a worker note (no interactive user, never ask questions, the last assistant message is the final report, stay strictly within the task, no nested sub-agents). The text is byte-identical on every submission, so it does not invalidate pi's prompt-cache prefix — same rationale as the [vision fallback](usage.md#vision-fallback) capability note. Per-turn state (like the live child inventory) deliberately stays out of the prompt; `list_subagents` is the live source.

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

