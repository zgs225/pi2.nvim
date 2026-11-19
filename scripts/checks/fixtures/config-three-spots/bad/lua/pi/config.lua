---@class pi.Options
---@field enabled boolean Inject the bundled extension (default: true)
---@field timeout integer Per-request timeout in milliseconds

local M = {}

---@type pi.Options
local defaults = {
    enabled = true,
    retries = 3,
}

M.options = defaults

return M
