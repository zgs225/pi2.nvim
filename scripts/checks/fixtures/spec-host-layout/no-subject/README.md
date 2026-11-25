# Wrong tree

There is no `tests/` and no `scripts/e2e/` here, so `spec-host-layout` cannot
tell a plugin tree from a random one: it must refuse the input with a
`CheckError` (exit 2) instead of reporting a clean tree.
