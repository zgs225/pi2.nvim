# Lua API (fixture)

```lua
local pi = require("pi")

pi.state.visible   -- a table field, not a documented function
```

A partial checkout can look like this: the module exists but defines no public
function, so the docs have nothing to be compared against.
