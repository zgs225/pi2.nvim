---@type pi.Options
local defaults = {
    cli = {
        bin = "pi",
        args = {},
    },
    spinner = "robot",
    statusline = {
        layout = {
            left = { "context", "attention" },
        },
    },
}

---@type pi.Options
local M = {}

---@param opts? pi.Options
function M.setup(opts)
    M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

return M
