local M = {}

function M.attach(buf)
    vim.keymap.set("n", "<C-f>", function()
        M.scroll(buf, "down")
    end, { buffer = buf })
end

return M
