-- No keymaps (fixture): a Lua module that binds nothing. The tree exists, but it
-- has nothing for the expr-mapping rule to check, so the rule warns once instead
-- of reporting a clean run (contract 3 / G25).

local M = {}

---@param text string
---@return string
function M.echo(text)
    return text
end

return M
