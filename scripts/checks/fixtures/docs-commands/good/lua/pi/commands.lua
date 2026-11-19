-- Fixture for the docs-commands rule: must produce ZERO findings.
-- Two registered commands, both documented; one registration is commented out
-- (the lexer must not see it); the doc also uses a family shorthand `:PiSub`,
-- which is a prefix of real commands and therefore allowed.
local M = {}

function M.setup()
    vim.api.nvim_create_user_command("PiAlpha", function() end, {})
    vim.api.nvim_create_user_command("PiSubNew", function() end, {})
    vim.api.nvim_create_user_command("PiSubClose", function() end, {})
    -- vim.api.nvim_create_user_command("PiGhost", function() end, {})  -- deliberately commented out
end

return M
