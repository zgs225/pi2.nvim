local M = {}

function M.attach(buf)
    vim.keymap.set("n", "q", M.close, { buffer = buf })
end

return M
