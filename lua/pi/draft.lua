--- Unsent-prompt draft persistence, scoped per workspace.
--
-- The prompt buffer already survives layout toggles and tab switches within a
-- session, but an unsent draft is lost when Neovim restarts. This module saves
-- the draft to disk (debounced by the caller) and restores it once per Neovim
-- process, so a restart brings back what you were typing — without re-restoring
-- a stale draft on every in-session `:PiNewSession`.
--
-- Drafts are partitioned by workspace (the session cwd), exactly like prompt
-- history: the file lives next to the workspace's history file
-- (`<hash>.draft`), so a draft typed in one project never resurfaces in
-- another. Callers must invoke `set_workspace(cwd)` before saving/restoring.

local M = {}

-- Whether a restore has already been attempted this process.
local restored = false

-- Test hook: override the draft file location (nil => workspace/default path).
local path_override = nil

-- Resolved per-workspace draft path (set by set_workspace).
local workspace_path = nil

-- Whether the legacy global draft file has been removed this process.
local legacy_removed = false

---@param p string?
function M._set_path(p)
    path_override = p
end

--- Point draft persistence at a workspace cwd. Uses the same normalization and
--- hash key as prompt history, so the draft sits next to the workspace's
--- history file. The legacy global draft file is silently removed once.
---@param cwd string?
function M.set_workspace(cwd)
    local PH = require("pi.prompt_history")
    if not legacy_removed then
        legacy_removed = true
        os.remove(PH.base_dir() .. "/draft.txt")
    end
    local normalized = PH.normalize_cwd(cwd) or PH.normalize_cwd(vim.fn.getcwd()) or vim.fn.getcwd()
    workspace_path = PH.history_dir() .. "/" .. PH.workspace_key(normalized) .. ".draft"
end

---@return string
local function draft_path()
    if path_override then
        return path_override
    end
    if workspace_path then
        return workspace_path
    end
    -- Fallback before set_workspace (tests, or a chat without a cwd yet):
    -- honor the prompt_history base-dir override so specs stay hermetic.
    return require("pi.prompt_history").base_dir() .. "/draft.txt"
end

--- Persist the current draft text. An empty string clears the stored draft.
---@param text string
function M.save(text)
    local p = draft_path()
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    if text == nil or text == "" then
        os.remove(p)
        return
    end
    local f = io.open(p, "w")
    if not f then
        return
    end
    f:write(text)
    f:close()
end

---@return string? the stored draft, or nil when there is none
function M.load()
    local f = io.open(draft_path(), "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    if content == nil or content == "" then
        return nil
    end
    return content
end

--- Remove the stored draft.
function M.clear()
    os.remove(draft_path())
end

--- Return the stored draft at most once per process. The first call consumes
--- the "once" slot; later calls in the same process return nil (so an
--- in-session `:PiNewSession` doesn't re-restore a stale draft). The stored
--- file is left in place — the caller's continuous save keeps it current and
--- clears it when the draft is sent, so an unsent draft survives restarts.
---@return string?
function M.restore_once()
    if restored then
        return nil
    end
    restored = true
    return M.load()
end

--- Reset module state (used by tests).
function M._reset()
    restored = false
    path_override = nil
    workspace_path = nil
    legacy_removed = false
end

return M
