# No lua (fixture)

A tree with no `lua/` directory at all. The parse-luajit rule cannot know
whether this is a plugin tree, so it refuses the input with a `CheckError`
(exit 2) instead of reporting a clean run: a gate that reports green on a tree
it cannot find is the fake-green failure mode.
