-- Fixture for the docs-api rule: must produce ZERO findings.
-- Two public functions, both documented as `pi.<name>`. The third definition is
-- commented out, so the lexer must not see it (and the docs must not need it).
local M = {}

---@param opts table|nil
function M.setup(opts)
    M.opts = opts or {}
end

---@return boolean
function M.is_visible()
    return M.opts.visible == true
end

-- function M.gone() end  -- deliberately commented out: not a definition

return M
