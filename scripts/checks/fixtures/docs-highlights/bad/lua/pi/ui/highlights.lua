-- Fixture for the docs-highlights rule: must produce TWO findings.
-- `PiBadDocumented` has a doc row; `PiBadUndocumented` does not, so it is
-- reported at the definition site (its name line — the definition is written
-- across lines on purpose).
local M = {}

function M.setup()
    vim.api.nvim_set_hl(0, "PiBadDocumented", { default = true, fg = "#ffffff" })
    vim.api.nvim_set_hl(
        0,
        "PiBadUndocumented",
        { default = true, fg = "#000000" }
    )
end

return M
