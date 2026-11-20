-- Fixture for the docs-highlights rule: must produce ONE finding, the warning.
-- There is no `nvim_set_hl(0, "Pi…", …)` literal here — only runtime-computed
-- names, which are skipped silently — so the rule has nothing to compare and
-- says so instead of reporting a clean tree.
local M = {}

function M.repaint(name)
    vim.api.nvim_set_hl(0, name, {})
end

M.GROUP = "PiRuntimeOnly"

return M
