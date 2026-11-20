-- uv-fast-event, `bad-system`: a `vim.system` callback that calls the editor
-- without `vim.schedule`. Two unguarded calls means two findings (lines 11 and
-- 12), one per call, because each is a separate line to fix.

local M = {}

---@param cwd string
function M.load(cwd)
    vim.system({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, { text = true }, function(res)
        M.root = vim.trim(res.stdout or "")
        vim.fn.writefile({ M.root }, cwd .. "/.root")
        vim.api.nvim_echo({ { M.root, "None" } }, false, {})
    end)
end

return M
