# Lua API (fixture)

The whole fixture API, one call at a time:

```lua
local pi = require("pi")

pi.setup(opts?)      -- one-time setup; opts is the config table
pi.is_visible()      -- boolean: is the chat shown in the current tab?
```

`pi.setup` accepts the config table described in the [README](../README.md);
`pi.is_visible()` answers whether the chat is currently shown.
