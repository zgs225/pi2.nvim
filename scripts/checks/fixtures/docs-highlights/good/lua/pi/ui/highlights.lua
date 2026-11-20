-- Fixture for the docs-highlights rule: must produce ZERO findings.
-- Two groups, both documenting a row in doc/highlight-groups.md. `PiGoodInline`
-- is written on one line; `PiGoodMultiline` is the regression this rule exists
-- for — its name sits two lines below the `nvim_set_hl(` call, so a line-based
-- regex would miss it and the rule would go green while the group was
-- undocumented.
local M = {}

function M.setup()
    vim.api.nvim_set_hl(0, "PiGoodInline", { default = true, fg = "#ffffff" })
    vim.api.nvim_set_hl(
        0,
        "PiGoodMultiline",
        { default = true, fg = "#abcdef", bold = true }
    )
    -- vim.api.nvim_set_hl(0, "PiGhost", { default = true })  -- commented out: not a definition
end

return M
