# No lua (fixture)

A tree with no `lua/` directory at all: this is not a plugin tree, so the
expr-mapping rule cannot locate a single mapping and must refuse the input with a
CheckError (exit 2) instead of reporting a clean or a warned tree.
