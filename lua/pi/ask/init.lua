--- Runtime config bridge for the bundled `ask` extension (extensions/ask.ts).
---
--- The process env is frozen at spawn, so the extension cannot read the
--- `ask` options from it: the configured values travel through a
--- per-process runtime file that the extension re-reads on every tool call and
--- on every before_agent_start event. Live setup() calls therefore apply to
--- already-spawned RPC processes without a respawn (same rationale and shape as
--- lua/pi/todo/tool_ui.lua and lua/pi/title.lua).
---
--- The file is JSON:
--- {"enabled":bool,"max_questions":int,"max_options":int,
---  "allow_free_text":bool,"timeout_ms":int|null}

local M = {}

---@type string?
local state_path_override = nil

--- Runtime file conveying the configured ask options to already-spawned RPC
--- processes. The PID is part of the name because stdpath("run") is per-user,
--- not per-process: without it two concurrently running nvim instances would
--- clobber each other's ask config.
---@return string
function M.state_path()
    if state_path_override then
        return state_path_override
    end
    return vim.fn.stdpath("run") .. "/pi2nvim-ask-config-" .. tostring(vim.fn.getpid())
end

--- Override the state file path (tests).
---@param path string?
function M._set_path(path)
    state_path_override = path
end

--- Positive integer timeout, or nil (the extension reads nil as "wait
--- forever").
---@param value any
---@return integer?
local function normalize_timeout(value)
    if type(value) == "number" and value > 0 and value == math.floor(value) then
        return math.floor(value)
    end
    return nil
end

--- Positive integer, else the fallback.
---@param value any
---@param fallback integer
---@return integer
local function normalize_positive(value, fallback)
    if type(value) == "number" and value > 0 and value == math.floor(value) then
        return math.floor(value)
    end
    return fallback
end

--- Publish the configured ask options for the extension. Always writes the
--- file: an explicit `enabled = false` must reach the extension so live
--- setup() calls disable the tool without a respawn (same rationale as
--- todo/title).
---@param cfg pi.AskConfig?
function M.publish(cfg)
    local path = M.state_path()
    cfg = cfg or {}
    -- `timeout_ms` is encoded as JSON null when unset, which is what the
    -- extension reads as "no timeout" (vim.NIL encodes to null; a plain nil
    -- value would drop the key instead).
    local payload = vim.json.encode({
        enabled = cfg.enabled ~= false,
        max_questions = normalize_positive(cfg.max_questions, 4),
        max_options = normalize_positive(cfg.max_options, 4),
        allow_free_text = cfg.allow_free_text ~= false,
        timeout_ms = normalize_timeout(cfg.timeout_ms) or vim.NIL,
    })
    local f = io.open(path, "w")
    if f then
        f:write(payload)
        f:close()
    end
end

--- The published ask options, if the file exists (mirrors what the extension
--- sees). A JSON null timeout decodes to the truthy vim.NIL, so it is dropped
--- back to nil.
---@return { enabled: boolean, max_questions: integer, max_options: integer, allow_free_text: boolean, timeout_ms: integer? }?
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
        max_questions = normalize_positive(decoded.max_questions, 4),
        max_options = normalize_positive(decoded.max_options, 4),
        allow_free_text = decoded.allow_free_text ~= false,
        timeout_ms = normalize_timeout(decoded.timeout_ms),
    }
end

--- Reset cached state (tests). The module only holds the path override, which
--- tests set through `_set_path(nil)`; kept as a stable hook so future caches
--- have a canonical teardown.
function M._reset() end

return M
