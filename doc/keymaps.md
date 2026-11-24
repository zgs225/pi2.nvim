# Keymaps

`pi2.nvim` intentionally ships with a very small default keymap set. Keymaps tend to be highly personal, and many users already have their own conventions, leader-based layouts, or other mapping systems. Pi tries to provide the API and a few sensible defaults, while leaving the final keymap design to you.

What the plugin does bind on its own:

- Submission keys in the prompt buffer (`<CR>`, `<A-CR>`, `<S-CR>` — see [Usage → Prompt](usage.md#prompt)).
- `<Esc>` / double-`<Esc>` abort gestures (see [Usage → Aborting](usage.md#aborting-with-double-esc)). A single `<Esc>` while a compaction is running aborts that compaction instead of arming the double-`<Esc>` gesture.
- `<C-p>` / `<C-n>` / `<Up>` / `<Down>` prompt-history recall (see [Usage → Prompt history](usage.md#prompt-history)).
- `<Tab>` block expand/collapse, `gf` open-file-under-cursor, `dd` delete-queued-message and `yy` copy-message in the history buffer.
- `yy` on a message copies its **source** text (see [Usage → Copying messages](usage.md#copying-messages)); `[count]yy` copies that many consecutive messages. The `y` operator itself stays native, so `y{motion}` and `V`+`y` keep yanking what is on screen, and [`:` `'<,'>PiCopy`](usage.md#copying-messages) does the source-text copy for a visual range.
- `[[` / `]]` turn navigation in the history buffer and in the prompt buffer (normal mode): previous / next turn, count-aware (`3]]`), and `]]` past the last turn returns to the live bottom and resumes following (see [Usage → Turn navigation](usage.md#turn-navigation)).
- `dd` on a queued steer/follow-up message in the history buffer deletes just that message (from pi's queue too) and yanks its text into the unnamed register (see [Usage → Deleting queued messages](usage.md#deleting-queued-messages)).
- `gp` return to parent session when viewing a sub-session (see [Sessions → Sub-sessions](sessions.md#sub-sessions)).
- `T` inside the sub-session viewer float toggles the viewed session's todo list panel (see [Usage → In the sub-session viewer](usage.md#in-the-sub-session-viewer)).
- `dd` / `x` to remove an entry in the attachments buffer.
- The [diff review](diff-review.md) keys inside the diff tab.
- The `:PiDiff` session diff review: in the panel's file list, moving the cursor previews the file's diff, `<CR>`/`o` jumps to its first changed line, `<C-f>`/`<C-b>`/`<C-d>`/`<C-u>` scroll the diff on the right; in the diff area, `<CR>`/`o` jumps to the line under the cursor; `q` closes the whole review (see [Session diff review](diff-review.md#session-diff-review-pidiff)). When the panel was opened by [`pi.worktree_apply`](worktrees.md#applying-a-patch), an extra `a` applies the reviewed patch to the main checkout.
- The [sessions overview](sessions.md#sessions-overview-pisessions) keys inside the list, including `x` to close the sub-session under the cursor, the session's π tab, or every π tab of a worktree group (each scope asks first unless its `sessions_list.confirm_close_*` switch is off), `n` for a fresh session in the row's checkout and `N` to open the row's main checkout or pick/create one of its worktrees (both insert the new tab next to that checkout's worktree group instead of at the end of the tabline), and `S` to reorder the tabline into the list's order (same as `:PiSessionsSync`).
- The [background tasks](#background-tasks-panel-pitasks) panel keys inside the list.
- The [compactions timeline](#compactions-panel-picompactions) keys inside the list.

## Background tasks panel (`:PiTasks`)

`:PiTasks` lists the background bash tasks reported by the bg-tasks extension (see [Usage → Background tasks](usage.md#background-tasks)). All of these are **buffer-local** mappings on the shared tasks list buffer (filetype `pi-tasks`) — they only fire inside the tasks panel, never in your own buffers:

| Key | Action |
| --- | --- |
| `<CR>` / `o` | Open this task's output in a vsplit (cursor stays in the list) |
| `a` / `i` | Open the output and focus it |
| `p` | Preview the output live in a float (command + metadata header); press `p` again to close |
| `x` | Stop the task under the cursor (asks for confirmation, then SIGTERMs its process group and SIGKILLs it if it has not exited after 5 s) |
| `D` | Delete the task's log file from disk (asks for confirmation; finished tasks only — a running task is refused, stop it with `x` first) |
| `A` | Toggle between the current session's tasks (default) and all sessions' tasks |
| `R` | Redraw the list |
| `q` | Close the panel |
| `?` | Toggle a help overlay listing these keys |

The output and preview buffers are read-only (`pi-task-output` filetype) and carry a buffer-local `q` that closes their window.

## Compactions panel (`:PiCompactions`)

`:PiCompactions` lists every compaction of the current session, newest first (see [Usage → Compaction timeline](usage.md#compaction-timeline-picompactions)). All mappings are **buffer-local** on the shared list buffer (filetype `pi-compactions`):

| Key | Action |
| --- | --- |
| `<CR>` | Jump to this compaction's block in the chat history |
| `gp` | Show the full summary in a float |
| `d` | Diff this summary against the previous compaction |
| `y` | Copy the summary to the clipboard |
| `r` | Request a new compaction with this one's focus instructions |
| `q` | Close the panel |
| `?` | Toggle a help overlay listing these keys |

## Key specs

Several config fields (`diff.keys`, `dialog.keys`, `zen.keys`) accept a **key spec** instead of a plain string, so you can pin mappings to specific modes and bind multiple keys to the same action. A key spec is one of:

```lua
-- 1. A plain string — single mapping in the default modes for that field.
accept = "<Leader>da"

-- 2. A table with `.modes` — single mapping in the given modes.
accept = { "<C-CR>", modes = { "n", "i", "v" } }

-- 3. A list of the above — multiple keys bound to the same action.
accept = {
    "<Leader>da",
    { "<C-CR>", modes = { "n", "i", "v" } },
}
```

All three forms are accepted anywhere a key spec is expected. A table is interpreted as a single spec when it has a `.modes` field, and as a list of specs otherwise.

## Stable filetypes

Every π buffer gets a stable filetype, so you can target them from your own `FileType` autocmds:

| Filetype | Buffer |
| --- | --- |
| `pi-chat-history` | Chat history panel |
| `pi-chat-prompt` | Prompt panel |
| `pi-chat-attachments` | Attachments panel |
| `pi-dialog` | Input and info dialog floats (completion plugins can be disabled here without affecting the prompt) |
| `pi-sessions` | The [sessions overview](sessions.md#sessions-overview-pisessions) list |
| `pi-tasks` | The [background tasks](#background-tasks-panel-pitasks) panel (`:PiTasks`) |
| `pi-diff-review` | The `:PiDiff` session diff review file list (left area of the panel) |

## Example setup

A reasonable starting point looks like this:

```lua
local pi = require("pi")

-- Global mappings — open / toggle / resume from anywhere.
vim.keymap.set({ "n", "v" }, "<Leader>pp", function() vim.cmd("Pi layout=side")  end, { desc = "Pi side"  })
vim.keymap.set({ "n", "v" }, "<Leader>pf", function() vim.cmd("Pi layout=float") end, { desc = "Pi float" })
vim.keymap.set({ "n", "v" }, "<Leader>pl", "<Cmd>PiToggleLayout<CR>",                 { desc = "Pi toggle layout" })
vim.keymap.set({ "n", "v" }, "<Leader>pc", "<Cmd>PiContinue<CR>",                     { desc = "Pi continue last session" })
vim.keymap.set({ "n", "v" }, "<Leader>pr", "<Cmd>PiResume<CR>",                       { desc = "Pi resume past session" })
vim.keymap.set({ "n", "v" }, "<Leader>pm", "<Cmd>PiSendMention<CR>",                  { desc = "Pi mention file/selection" })
vim.keymap.set({ "n", "v" }, "<Leader>pa", "<Cmd>PiAttention<CR>",                    { desc = "Pi open next attention request" })
vim.keymap.set({ "n", "v" }, "<Leader>pF", "<Cmd>PiFork<CR>",                       { desc = "Pi fork session from a past message" })
vim.keymap.set({ "n", "v" }, "<Leader>pC", "<Cmd>PiClone<CR>",                      { desc = "Pi clone session into a new file" })
```

The `<S-Up>` / `<S-Down>` mappings below are sort of placeholders — replace them with whatever keys you already use to move between windows in the rest of Neovim. The idea is that focus navigation inside π windows should match your normal buffer/window navigation, not introduce new conventions.

```lua
-- Buffer-local mappings inside π windows.
-- Filetypes: "pi-chat-history", "pi-chat-prompt", "pi-chat-attachments".
local group = vim.api.nvim_create_augroup("pi-keymaps", { clear = true })

local function map(buf, key, action, modes)
    vim.keymap.set(modes or { "n", "i", "v" }, key, action, { buffer = buf })
end

-- Shared across all π windows.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "pi-chat-history", "pi-chat-prompt", "pi-chat-attachments" },
    callback = function(event)
        map(event.buf, "<C-q>", "<Cmd>PiToggleChat<CR>")
        map(event.buf, "<M-c>", "<Cmd>PiAbort<CR>")
        map(event.buf, "<C-o>", pi.toggle_history_blocks)
    end,
})

-- History window: jump to prompt.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "pi-chat-history",
    callback = function(event)
        map(event.buf, "<S-Down>", pi.focus_chat_prompt)
    end,
})

-- Prompt window: navigation, scrolling, model & thinking, sessions, attachments.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "pi-chat-prompt",
    callback = function(event)
        -- focus
        map(event.buf, "<S-Up>",   pi.focus_chat_history)
        map(event.buf, "<S-Down>", pi.focus_chat_attachments)
        -- scroll history from the prompt
        map(event.buf, "<C-Up>",   function() pi.scroll_chat_history("up", 2) end)
        map(event.buf, "<C-Down>", function() pi.scroll_chat_history("down", 2) end)
        -- model & thinking
        map(event.buf, "<M-m>", pi.cycle_model)
        map(event.buf, "<M-M>", pi.select_model)
        map(event.buf, "<M-t>", pi.cycle_thinking_level)
        map(event.buf, "<M-T>", pi.select_thinking_level)
        -- sessions & context
        map(event.buf, "<M-n>", pi.new_session)
        map(event.buf, "<M-x>", pi.compact)
        -- attachments
        map(event.buf, "<C-v>", pi.paste_image)
    end,
})

-- Attachments window: jump back to prompt, paste image.
vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "pi-chat-attachments",
    callback = function(event)
        map(event.buf, "<S-Up>", pi.focus_chat_prompt)
        map(event.buf, "<C-v>", pi.paste_image)
    end,
})
```
