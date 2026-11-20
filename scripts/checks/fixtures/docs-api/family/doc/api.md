# Lua API (fixture)

```lua
local pi = require("pi")

-- Start a fresh conversation in <repo>/.worktrees/fix-auth.
pi.worktree_new({ name = "fix-auth", layout = "side" })

-- Open (or create) a checkout, optionally following the session it started.
pi.worktree_open({ name = "fix-auth" }, function(session, err) ... end)
```

The two `pi.worktree_*` entry points are the whole worktree surface; the family
shorthand is a claim about the module, not a stale name.

The git layer is a separate module, `require("pi").worktree`, which is what the
`pi.worktree_*` functions call. That module path is not an API mention: it names
a Lua module, not a function on the module table.

`pi.worktree` also exposes the `Worktree` table, so the bare name is a module
path again — not a claim that the module table carries a `worktree` function.
