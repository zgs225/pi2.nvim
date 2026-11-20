-- A config module that predates the `---@class pi.Options` annotation: only the
-- runtime table exists, so there is no annotation side to compare against.
local M = {}

local defaults = {
    enabled = true,
}

M.options = defaults

return M
