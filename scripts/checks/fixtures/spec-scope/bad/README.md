# Bad (fixture)

One `before_each` sits at the chunk top level, before the file's first
`describe`. Plenary evaluates it while loading the file, attaches it to no
suite, and silently drops it — the spec body then runs without the setup it
declares, and `make test` exits 1 with no assertion to point at (G14).

The second `before_each` / `after_each` inside `describe("compliant", ...)` are
correct and must not be reported: the rule reports the misplaced hook only.

Expected: 1 finding, at the line of the top-level `before_each`.
