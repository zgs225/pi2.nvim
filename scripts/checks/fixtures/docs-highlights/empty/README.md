# Fixture: empty

Must produce **1** finding — the `severity="warn"` finding for "no literal
`nvim_set_hl(0, "Pi…", …)` under `lua/`". A tree with `lua/` but no highlight
definitions is not "in sync"; it is a tree where the rule has nothing to verify,
and the warning keeps a `--root` run over a partial checkout usable. The
stale `PiGhost` doc row proves the early return: the comparison never runs, so
that row adds no second finding.
