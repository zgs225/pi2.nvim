local M = {}

function M.setup(opts)
    if opts.disable then
        return
    end
    vim.g.pi_setup = true
end

return M
