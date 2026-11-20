# Bad blocks (fixture)

Three hooks that are neither at column 0 nor inside a `describe` closure, which
is why the detector tracks lexical scopes instead of matching indentation:

1. `before_each` inside a **top-level `if`** block — open blocks are not
   functions, so there is no enclosing closure at all: the hook runs at load
   time and registers on nothing (G14).
2. `after_each` inside a **top-level `do`** block — same defect, and the reason
   the detector keeps `do` / `if` / `for` / `while` frames: without them, `end`
   pairing would attach this hook to the wrong scope.
3. `before_each` inside a **local helper function declared inside a
   `describe`** — it *is* inside a function, but that function is not the
   `describe` callback, so plenary still registers the hook on nothing.

Expected: 3 findings.
