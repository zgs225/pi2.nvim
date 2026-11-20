-- G1 fixture: an <expr> callback writes the buffer with no vim.schedule around
-- it. Neovim drops the write without an error, so the prompt silently keeps its
-- old text. One warn finding, at this call.

local M = {}

function M.setup(buf)
    vim.keymap.set("i", "<Down>", function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "recalled" })
        return "<Down>"
    end, { buffer = buf, expr = true, desc = "recall" })
end

return M
