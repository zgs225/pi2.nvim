# Bad both (fixture)

Both `before_each` and `after_each` are at the chunk top level. Neither attaches
to a suite, so setup and teardown both silently vanish and the file fails with
no assertion message (G14).

Two findings prove the rule reports **every** misplaced hook, not just the first
one it meets in a file — a detector that stopped at the first hit would leave
half the defect in place.

Expected: 2 findings.
