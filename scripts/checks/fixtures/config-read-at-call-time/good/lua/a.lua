-- Safe module: the alias lives at chunk top level, every `.options` read happens
-- inside the function that needs it, i.e. after `setup()` has run.
local Config = require("pi.config")

local M = {}

-- Banned form, for the record (a commented-out capture must never be a finding):
-- local cfg = Config.options.labels.tool
local BANNED_TEXT = 'a capture looks like `local x = Config.options.labels.tool`'

---@return string
function M.label()
    local cfg = Config.options.labels.tool
    return cfg or BANNED_TEXT
end

---@return string
function M.verb()
    local pairs = Config.options.verbs and Config.options.verbs.pairs
    if not pairs then
        return ""
    end
    return pairs[1] and pairs[1].verb or ""
end

---@return table
function M.local_alias()
    -- An alias created inside a function is not a chunk-level snapshot, so
    -- capturing from it here is still a call-time read.
    local Alias = require("pi.config")
    return Alias.options.labels
end

return M
