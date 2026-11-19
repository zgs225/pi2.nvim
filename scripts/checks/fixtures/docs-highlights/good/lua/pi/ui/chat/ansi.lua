-- The `PiAnsi*` family is generated per ANSI style by string concatenation, so
-- its names cannot be known statically. It is prose-only in the docs and out of
-- scope in both directions: `PiAnsiPending` below is a literal too, and it must
-- NOT be reported as an undocumented group.
local M = {}

function M.apply(style, key)
    local name = "PiAnsi" .. key:gsub("[^%w]", "_")
    vim.api.nvim_set_hl(0, name, { fg = style.fg })
end

M.PENDING = "PiAnsiPending"
vim.api.nvim_set_hl(0, "PiAnsiPending", { default = true, fg = "#ff0000" })

return M
