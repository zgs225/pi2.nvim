# docs-config fixture: no-lua

There is no `lua/` directory, so this is not a plugin tree: the rule refuses the
input with a `CheckError` (exit 2) instead of guessing. Expected: CheckError.
