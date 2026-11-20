# Empty (fixture)

`lua/pi/init.lua` exists but defines no `function M.<name>`, so the docs-api
rule has nothing to verify on this tree and must warn instead of reporting a
clean run.
