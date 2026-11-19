---@class pi.Options
---@field enabled boolean Inject the bundled extension (default: true)
---@field vision pi.VisionConfig Image description fallback
---@field status_message? string Statusline text (no default: the feature is off when unset)

---@class pi.VisionConfig
---@field model? string Vision model as "provider/modelId" (no default: feature off when unset)
---@field timeout? integer Per-request timeout in milliseconds

local M = {}

---@type pi.Options
local defaults = {
    enabled = true,
    vision = {
        timeout = 15000,
    },
}

M.options = defaults

return M
