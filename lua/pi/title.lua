--- Auto session titles: shared helpers for backend-side title generation.
---
--- The bundled pi extension (extensions/title.ts) generates a display name
--- for unnamed sessions after the first turn (turn_index 0) and persists it
--- via pi.setSessionName(). The backend emits session_info_changed, which the
--- plugin already routes into :PiSessions / :PiResume — no new data channel.
---
--- This module is pure: it publishes the title configuration to a runtime
--- file the extension re-reads on every turn_end event (the process env is
--- frozen at spawn, so live setup() calls apply without respawning the RPC
--- process), and mirrors back what the extension sees.
local M = {}

--- Runtime file conveying the configured title options to already-spawned
--- RPC processes, as JSON: {"enabled":bool,"maxChars":number,"lang":string|null}.
---@return string
function M.state_path()
    if state_path_override then
        return state_path_override
    end
    return vim.fn.stdpath("run") .. "/pi2nvim-title-config"
end

--- Override the state file path (tests).
---@param path string?
function M._set_path(path)
    state_path_override = path
end

--- Publish (or clear) the configured title options for the extension.
--- Always writes the file: an explicit `enabled = false` must reach the
--- extension so live setup() calls disable generation without a respawn.
---@param cfg pi.TitleConfig?
function M.publish(cfg)
    local path = M.state_path()
    cfg = cfg or {}
    local payload = vim.json.encode({
        enabled = cfg.enabled ~= false,
        maxChars = type(cfg.max_chars) == "number" and cfg.max_chars or 40,
        lang = type(cfg.lang) == "string" and cfg.lang ~= "" and cfg.lang or nil,
        model = type(cfg.model) == "string" and cfg.model ~= "" and cfg.model or nil,
    })
    local f = io.open(path, "w")
    if f then
        f:write(payload)
        f:close()
    end
end

--- The published title options, if the file exists (mirrors what the
--- extension sees).
---@return { enabled: boolean, maxChars: integer, lang: string?, model: string? }?
function M.published()
    local f = io.open(M.state_path(), "r")
    if not f then
        return nil
    end
    local content = f:read("*a") or ""
    f:close()
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    return {
        enabled = decoded.enabled ~= false,
        maxChars = type(decoded.maxChars) == "number" and decoded.maxChars or 40,
        lang = type(decoded.lang) == "string" and decoded.lang ~= "" and decoded.lang or nil,
        model = type(decoded.model) == "string" and decoded.model ~= "" and decoded.model or nil,
    }
end

---@type string?
local state_path_override = nil

return M
