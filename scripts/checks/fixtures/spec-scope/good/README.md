# Good (fixture)

A spec where every `before_each` / `after_each` is lexically inside a
`describe(...)` closure, including a nested `describe` and a `describe` whose
closure is the call's only argument.

Three things must stay quiet, and each is deliberate:

* a **comment** mentioning `before_each` / `after_each` — comments never reach
  the matcher (`lua.code_tokens`);
* a **string literal** containing `before_each` / `after_each`, in a short
  string and in a long bracket — same reason (G24's lesson);
* `for` / `while` / `do` / `if` blocks *inside* a describe: the block stack must
  not turn a compliant hook into a false positive, and the `do` that closes a
  `for` header must not open a second scope.

Expected: 0 findings.
