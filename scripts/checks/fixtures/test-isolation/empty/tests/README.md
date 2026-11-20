# Empty subject tree

`tests/` exists but holds no `*.lua` file, so `test-isolation` has nothing to
scan. That is a fact about the tree, not a pass: the rule returns exactly one
`warn` finding (exit 1) instead of reporting green.

This README also keeps the directory in git — an empty directory cannot be
committed, and a fixture path that vanishes after checkout would break
`--self-test`.
