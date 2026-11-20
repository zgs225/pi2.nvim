-- Fixture for the docs-commands rule: must produce exactly ONE finding.
-- One real registration but no README.md and no doc/ directory: the docs corpus
-- is empty, which is a `warn` finding (nothing to compare against), not a
-- CheckError.
local M = {}

function M.setup()
    vim.api.nvim_create_user_command("PiFoo", function() end, {})
end

return M
