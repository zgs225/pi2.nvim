-- The published submodule that `pi.worktree` names in doc/api.md. It is not the
-- module table's API: `require("pi.worktree")` is a module path, so a bare
-- `pi.worktree` mention must not be reported as a stale API function.
local M = {}

function M.create(opts, cb)
    cb({ path = opts.name }, nil)
end

return M
