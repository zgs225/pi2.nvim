-- G2 fixture, second callback shape: the mapping passes a same-file function by
-- name, and *that* function returns vim.keycode(...). The detector must resolve
-- the name to the function body in this file, or the defect stays invisible.
-- One error finding, at the vim.keymap.set call.

local M = {}

local function pass_down()
    return vim.api.nvim_replace_termcodes("<Down>", true, false, true)
end

function M.setup(buf)
    vim.keymap.set("i", "<Down>", pass_down, { buffer = buf, expr = true, desc = "pass through" })
end

return M
