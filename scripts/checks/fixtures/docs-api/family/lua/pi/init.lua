-- Fixture for the docs-api rule: must produce ZERO findings.
-- Two public functions. `worktree_new` is documented by name, `worktree_open`
-- only falls under the `pi.worktree_*` family shorthand — both are documented.
local M = {}

function M.worktree_new(opts)
    M.last = opts
end

function M.worktree_open(opts, cb)
    if cb then
        cb(M.last, nil)
    end
end

return M
