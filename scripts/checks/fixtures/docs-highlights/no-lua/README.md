# Fixture: no-lua

Must **not** report findings: with no `lua/` directory the rule cannot tell
whether this is a plugin tree at all, so `run()` raises `CheckError`
(`expect_error=True`, exit 2) instead of reporting a clean or a warned tree.
