-- Fixture for the docs-api rule: must produce exactly TWO findings.
-- `M.hidden` has no `pi.hidden` mention in doc/api.md (finding at this file),
-- and doc/api.md still documents `pi.gone`, which no longer exists (finding at
-- doc/api.md). Two documented functions are in sync and must stay quiet.
local M = {}

function M.setup(opts)
    M.opts = opts or {}
end

function M.hidden()
    return "not documented anywhere"
end

return M
