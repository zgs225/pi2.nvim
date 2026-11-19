# Configuration

All options are optional — `require("pi").setup()` without arguments keeps the
defaults below.

```lua
require("pi").setup({
    -- pi CLI invocation.
    cli = {
        bin = "pi",
        args = {},
    },
    -- Spinner shown while the agent is working.
    spinner = "robot",
    -- Prompt statusline. `left` is a positional array, so its entries are
    -- values, never config paths.
    statusline = {
        layout = {
            left = { "context", "attention" },
        },
    },
})
```

Everything else is documented below.
