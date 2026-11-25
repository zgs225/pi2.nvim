-- The same defect in the other subject directory: scripts/e2e/*.lua is a spec
-- tree too, and a run-dir assumption there is the same trap.
local path = require("pi.title").state_path()
assert.matches("[/\\]run[/\\]", path)
