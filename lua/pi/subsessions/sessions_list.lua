--- Filter rules for sub-session rows in :PiSessions (manifest is never deleted).

local Config = require("pi.config")

local M = {}

---@class pi.SessionsListChildFilterCtx
---@field completion_seen? fun(child_id: string): boolean
---@field process_running? fun(child_id: string): boolean

--- Whether a manifest child should appear under its parent in :PiSessions.
--- Dormant / settled children stay in the manifest for :PiSubSwitch and list_subagents.
---@param entry pi.SubsessionManifestEntry
---@param ctx? pi.SessionsListChildFilterCtx
---@return boolean
function M.child_visible(entry, ctx)
    if type(entry) ~= "table" then
        return false
    end
    local child_id = entry._id
    local seen = function(id)
        if ctx and ctx.completion_seen then
            return ctx.completion_seen(id) == true
        end
        return false
    end
    local running = function(id)
        if ctx and ctx.process_running then
            return ctx.process_running(id) == true
        end
        return false
    end

    if type(child_id) == "string" and running(child_id) then
        return true
    end

    local cfg = (Config.options.subagent or {}).sessions_list or {}
    local show_dormant = cfg.show_dormant == true
    local show_completed = cfg.show_completed or "unread"
    local show_failed = cfg.show_failed
    if show_failed == nil then
        show_failed = "unread"
    end

    local status = entry.status
    if status == "dormant" then
        return show_dormant
    end
    if status == "completed" then
        if show_completed == "all" then
            return true
        end
        if show_completed == "none" then
            return false
        end
        -- unread: agent-spawned workers disappear when done; user-spawned stay until acknowledged
        if entry.agent_spawned then
            return false
        end
        if type(child_id) ~= "string" then
            return false
        end
        if not entry.reported then
            return true
        end
        return not seen(child_id)
    end
    if status == "failed" then
        if show_failed == "all" then
            return true
        end
        if show_failed == "none" then
            return false
        end
        if type(child_id) ~= "string" then
            return true
        end
        return not seen(child_id)
    end
    return true
end

return M
