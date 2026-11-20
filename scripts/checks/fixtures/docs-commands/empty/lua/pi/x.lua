-- Fixture for the docs-commands rule: must produce exactly ONE finding.
-- This module registers no user command at all, so the rule has nothing to
-- verify on this tree. That is a `warn` finding, not a CheckError: a partial
-- tree must not break a `--root` run for every other rule.
local M = {}

function M.setup() end

return M
