--- Backend model-scope bridge (nvim side).
---
--- The bundled pi extension (extensions/scoped-models.ts) serializes the
--- session's resolved model scope — pi's `--models` / `enabledModels` — to a
--- runtime file on every session_start; the RPC protocol itself never
--- exposes that list. This module reads and validates what the extension
--- wrote. Pure helpers so `:PiSelectModel` can fall back from its own
--- config.models to the backend scope (mirroring cycle and the TUI picker).
local M = {}

--- Test override for state_path(). Declared up front so the functions below
--- capture this local instead of accidentally writing to a global of the
--- same name.
---@type string?
local state_path_override = nil

--- Per-tab state file path: sessions in different tabs may run under
--- different cwds, so project-level `.pi/settings.json` scopes can differ.
---@param tab pi.TabId
---@return string
function M.state_path(tab)
    if state_path_override then
        return state_path_override
    end
    return vim.fn.stdpath("run") .. "/pi2nvim-scope-" .. tostring(tab)
end

--- Override the state file path (tests). Passing nil restores the default.
---@param path string?
function M._set_path(path)
    state_path_override = path
end

--- Read a scope file written by extensions/scoped-models.ts.
--- Returns the `{provider, id}` list (possibly empty when no scoping is
--- configured), or nil when the file is absent or not valid JSON of the
--- expected shape.
---@param path string
---@return { provider: string, id: string }[]?
function M.read(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a") or ""
    f:close()
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" or type(decoded.models) ~= "table" then
        return nil
    end
    ---@type { provider: string, id: string }[]
    local models = {}
    for _, entry in ipairs(decoded.models) do
        if type(entry) == "table" and type(entry.provider) == "string" and type(entry.id) == "string" then
            models[#models + 1] = { provider = entry.provider, id = entry.id }
        end
    end
    return models
end

--- Intersect scope entries with available backend models, preserving scope
--- order and dropping entries that are currently unavailable (e.g. auth
--- failed at snapshot time). Duplicates collapse onto the first occurrence.
---@param scope { provider: string, id: string }[]? nil acts as empty scope
---@param all_models table[] models from get_available_models
---@return table[]
function M.filter(scope, all_models)
    local filtered = {} ---@type table[]
    if not scope or #scope == 0 then
        return filtered
    end
    ---@type table<string, boolean>
    local known = {}
    for _, m in ipairs(all_models) do
        if type(m.provider) == "string" and type(m.id) == "string" then
            known[m.provider .. "/" .. m.id] = true
        end
    end
    ---@type table<string, boolean>
    local seen = {}
    for _, entry in ipairs(scope) do
        local key = entry.provider .. "/" .. entry.id
        if known[key] and not seen[key] then
            for _, m in ipairs(all_models) do
                if m.provider == entry.provider and m.id == entry.id then
                    filtered[#filtered + 1] = m
                    seen[key] = true
                    break
                end
            end
        end
    end
    return filtered
end

return M
