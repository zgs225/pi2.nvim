-- Fixture for the docs-commands rule: must produce TWO findings.
-- `PiAlpha` is registered but never documented, and the doc's `:PiBeta` names
-- a command that does not exist.
local M = {}

function M.setup()
    vim.api.nvim_create_user_command("PiAlpha", function() end, {})
end

return M
