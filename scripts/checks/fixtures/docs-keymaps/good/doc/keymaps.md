# Keymaps

What the plugin does bind on its own:

- `<CR>` submits the prompt (see `usage.md`).
- `<C-n>` recalls the next prompt-history entry.
- `<C-f>` scrolls the diff review to the next change.

## Example setup

The `<S-Up>` placeholder below is yours to rebind — it is not a plugin default:

```lua
map(event.buf, "<S-Up>", pi.focus_chat_history)
```
