# No skills tree

This fixture has no `.agents/skills/` directory, so the rule cannot find its
subject tree and must refuse the input with a `CheckError` instead of reporting a
clean tree.
