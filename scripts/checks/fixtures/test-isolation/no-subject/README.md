# Missing subject tree

Neither `tests/` nor `scripts/e2e/` exists here, so `test-isolation` cannot tell
a plugin tree from an arbitrary directory: it raises `CheckError` (exit 2)
instead of reporting a clean run over nothing. Kept in git so the fixture path
exists after checkout.
