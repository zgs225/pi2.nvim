# No lua (fixture)

No `lua/` directory at all — this is not a plugin tree, so the rule cannot
locate its subject (`lua/pi/config.lua`) and must refuse the input with a
`CheckError` (exit 2) instead of reporting a clean tree or a warning.

Expected: `expect_error=True`.
