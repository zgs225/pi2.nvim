# Empty (fixture)

`tests/` exists but holds no `*_spec.lua` file, so the rule has nothing to check
hook scoping on.

That is a fact about this tree, not a broken gate: it warns exactly once (and
exits 1) instead of raising `CheckError`, so a `--root` run over a partial
checkout stays usable for every other rule and the gap is still visible in the
output.

Expected: 1 finding (`severity="warn"`).
