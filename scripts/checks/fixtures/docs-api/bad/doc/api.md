# Lua API (fixture)

```lua
local pi = require("pi")

pi.setup(opts?)      -- one-time setup
pi.gone(opts?)       -- removed from the module long ago; the doc is stale
```

`pi.setup` is the entrypoint; the prose mention of `pi.gone()` no longer maps to
any `function M.gone`, which is exactly the drift this rule exists for.
