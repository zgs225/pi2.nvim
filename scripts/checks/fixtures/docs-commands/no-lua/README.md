# No lua (fixture)

Documentation without any `lua/` directory. This is not a plugin tree at all,
so the docs-commands rule cannot locate its subject tree and must refuse the
input with a CheckError (exit 2) instead of guessing that the tree is in sync.
