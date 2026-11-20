# Empty (fixture)

`lua/pi/config.lua` exists but carries no `---@class pi.Options` annotation (and
no `---@field` block at all), so the rule has no annotation side to compare the
`defaults` table against.

That is a fact about this tree, not a broken gate: it warns exactly once instead
of raising `CheckError`, so a `--root` run over a partial checkout stays usable
and the gap is still visible in the output.

Expected: 1 finding (`severity="warn"`).
