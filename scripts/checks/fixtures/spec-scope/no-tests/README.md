# No tests (fixture)

No `tests/` directory at all — this is not a tree the rule can reason about, so
it cannot distinguish "every hook is scoped" from "there is nothing to scan" and
must refuse the input with a `CheckError` (exit 2) rather than report a clean
tree or a warning.

Expected: `expect_error=True`.
