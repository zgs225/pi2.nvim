# Empty subject tree

`tests/` exists here but holds no `*.lua` file, so `spec-host-layout` has nothing
to verify: it must warn (one finding, exit 1) instead of reporting a clean tree.
