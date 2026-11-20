# Family (fixture)

Two legitimate doc styles that are not drift: the `pi.worktree_*` family
shorthand (a claim about every function with that prefix, and this tree defines
two of them) and the `require("pi").worktree` module path (a module, not a
function). A *bare* `pi.worktree` also appears, naming the published
`lua/pi/worktree.lua` submodule — a module path, not a missing function.
`worktree_open` is documented only through the shorthand, which must count in
the forward direction.
