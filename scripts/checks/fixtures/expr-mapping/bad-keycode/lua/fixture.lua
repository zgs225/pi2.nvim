-- G2 fixture: the <expr> fallback returns the internal keycode bytes instead of
-- the literal "<Up>", so pressing <Up> off the top line types `\x80ku` into the
-- buffer instead of moving the cursor. One error finding, at this call.

local M = {}

function M.setup(buf)
    vim.keymap.set("i", "<Up>", function()
        if vim.api.nvim_win_get_cursor(0)[1] > 1 then
            return vim.keycode("<Up>")
        end
        return "<Up>"
    end, { buffer = buf, expr = true, desc = "pass through" })
end

return M
