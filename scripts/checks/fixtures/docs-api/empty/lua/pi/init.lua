-- Fixture for the docs-api rule: must produce exactly ONE finding (a warn).
-- This module exposes a table field instead of a `function M.<name>`, so the
-- rule has nothing to verify here. That is a warn, not a CheckError: a partial
-- tree must not break a `--root` run for every other rule.
local M = {}

M.state = { visible = false }

return M
