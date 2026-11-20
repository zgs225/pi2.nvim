# tests/ but no spec

This directory exists so the `empty` fixture has a real `tests/` subject tree
with no `*_spec.lua` in it — git cannot track an empty directory, and the rule
must see the directory to decide between "nothing to check" (one `warn`) and
"wrong tree" (`CheckError`).

The rule globs `tests/*_spec.lua` and never reads this file.
