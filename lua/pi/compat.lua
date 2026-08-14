---@class pi.Compat
---@field min_supported string minimum pi version supported by this plugin
---@field validated string latest pi version manually validated against this plugin
---@field vision_min_supported string minimum pi version for the bundled vision fallback extension (extensions/vision.ts)
local M = {
    -- Keep these in sync with release validation notes.
    min_supported = "0.65.2",
    validated = "0.79.3",
    -- The vision extension needs ctx.sessionManager.buildContextEntries()
    -- (pi 0.80.4+) and a public ModelRegistry.getProvider() (pi 0.81.0+);
    -- 0.81-0.83.x goes through provider.streamSimple(), 0.84.0+ through
    -- ModelRegistry.complete(). Validated on 0.83.0 (see git log for
    -- extensions/vision.ts).
    vision_min_supported = "0.81.0",
}

---@param version string
---@return integer[]?
local function parse_version(version)
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then
        return nil
    end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

---Extract `x.y.z` from arbitrary version output (e.g. `pi v0.65.2`).
---@param text string
---@return string?
function M.extract_version(text)
    return text:match("(%d+%.%d+%.%d+)")
end

---Compare two semantic versions (`x.y.z`).
---@param a string
---@param b string
---@return integer? cmp returns -1, 0, 1; nil when parsing fails
function M.compare_versions(a, b)
    local av = parse_version(a)
    local bv = parse_version(b)
    if not av or not bv then
        return nil
    end

    for i = 1, 3 do
        if av[i] < bv[i] then
            return -1
        elseif av[i] > bv[i] then
            return 1
        end
    end

    return 0
end

return M
