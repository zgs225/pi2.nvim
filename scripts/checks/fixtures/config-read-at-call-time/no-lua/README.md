# no-lua fixture

This tree deliberately has **no `lua/` directory**, so `run(root)` must refuse the
input with a `CheckError` (exit 2) instead of reporting a clean tree. A missing
subject tree is a broken gate, not a verdict: without `lua/` the rule cannot even
tell whether this is a plugin tree.
