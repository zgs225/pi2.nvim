-- Fixture for the docs-api rule: must produce exactly ONE finding.
-- `M.setup` is documented, so the forward direction is quiet. The doc still
-- advertises the `pi.gone_*` family, and no defined function starts with
-- `gone_` — a shorthand is still a claim, so it is exactly one finding.
local M = {}

function M.setup(opts)
    M.opts = opts or {}
end

return M
