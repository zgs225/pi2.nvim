# uv-fast-event, `no-lua`

No `lua/` directory: the subject tree is missing, so the rule refuses the input
with a `CheckError` (exit 2) rather than reporting a clean or a warned tree.
