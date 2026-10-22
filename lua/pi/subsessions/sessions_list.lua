--- Filter rules for sub-session rows in :PiSessions (manifest is never deleted).
---
--- This module is the single home of the sub-session list policy: the
--- `child_visible` row rule, the composed per-row visibility predicate, the
--- completion-acknowledgement store and the ctx (liveness) factory. Frontends
--- (:PiSessions, `workspace.query{kind="sessions"}`, the `pi2:subagents`
--- payload) must call in here instead of re-deriving the rule.

local Config = require("pi.config")

local M = {}

---@class pi.SessionsListChildFilterCtx
---@field completion_seen? fun(child_id: string): boolean
---@field process_alive? fun(child_id: string): boolean
---@field process_running? fun(child_id: string): boolean True when child task is actively executing (busy/compacting).

--- Child rows whose completion was already acknowledged by the user. Owned
--- here (not in the view layer) so every frontend sees the same state; only a
--- user action (opening the parent, `:PiSessions` keys) may add to it.
---@type table<string, true>
local completion_seen = {}

--- Drop the acknowledgement store (tests / reload).
function M._reset_completion_seen()
    completion_seen = {}
end

--- Acknowledge a sub-session's completion notification.
---@param child_id string
---@return boolean changed True when the id was not acknowledged before.
function M.mark_completion_seen(child_id)
    if type(child_id) ~= "string" or child_id == "" then
        return false
    end
    if completion_seen[child_id] then
        return false
    end
    completion_seen[child_id] = true
    return true
end

---@param child_id string
---@return boolean
function M.is_completion_seen(child_id)
    if type(child_id) ~= "string" or child_id == "" then
        return false
    end
    return completion_seen[child_id] == true
end

--- Acknowledge completed children of `lineage` whose report was already
--- injected into the parent (mirrors the parent's `clear_flags` on TabEnter).
---@param lineage string Manifest lineage id.
---@return boolean changed True when at least one child became acknowledged.
function M.acknowledge_reported(lineage)
    if type(lineage) ~= "string" or lineage == "" then
        return false
    end
    local ok, Manifest = pcall(require, "pi.subsessions.manifest")
    if not ok or type(Manifest.children_of) ~= "function" then
        return false
    end
    local changed = false
    for _, entry in ipairs(Manifest.children_of(lineage)) do
        local child_id = entry._id
        if entry.status == "completed" and entry.reported and type(child_id) == "string" and child_id ~= "" then
            if not completion_seen[child_id] then
                completion_seen[child_id] = true
                changed = true
            end
        end
    end
    return changed
end

---@class pi.SessionsListCtxOpts
---@field status_of? fun(child: pi.Session): string Live status of a child session (busy/compacting/idle/exited).
---@field manager? table Session registry to use instead of `pi.sessions.manager` (tests).

--- Build the liveness ctx for `child_visible` / `row_visible`. The manager is
--- required lazily so this module stays loadable without the session layer.
---@param opts? pi.SessionsListCtxOpts
---@return pi.SessionsListChildFilterCtx
function M.make_ctx(opts)
    opts = opts or {}
    local manager = opts.manager
    ---@return table|nil
    local function sessions()
        if manager ~= nil then
            return manager
        end
        local ok, mod = pcall(require, "pi.sessions.manager")
        if ok and type(mod) == "table" then
            manager = mod
        end
        return manager
    end
    ---@param child_id string
    ---@return pi.Session|nil
    local function get(child_id)
        local Sessions = sessions()
        if type(Sessions) ~= "table" or type(Sessions.get_by_id) ~= "function" then
            return nil
        end
        return Sessions.get_by_id(child_id)
    end

    local status_of = opts.status_of
    if type(status_of) ~= "function" then
        status_of = function(child)
            local ok, View = pcall(require, "pi.ui.sessions")
            if ok and type(View.status_of) == "function" then
                return View.status_of(child)
            end
            return "idle"
        end
    end

    return {
        completion_seen = M.is_completion_seen,
        process_alive = function(id)
            local child = get(id)
            local rpc = child and child.rpc
            if not rpc or type(rpc.is_running) ~= "function" then
                return false
            end
            return rpc:is_running() == true
        end,
        process_running = function(id)
            local child = get(id)
            if not child then
                return false
            end
            local rpc = child.rpc
            if not rpc or type(rpc.is_running) ~= "function" or not rpc:is_running() then
                return false
            end
            local st = status_of(child)
            return st == "busy" or st == "compacting"
        end,
    }
end

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

---@class pi.SessionsListRowVisibleOpts
---@field is_current? boolean The row is the session the view is showing.
---@field same_epoch? boolean|nil False when the child was spawned by another conversation epoch.
---@field hidden? boolean The user toggled hidden rows on.
---@field ctx? pi.SessionsListChildFilterCtx

--- The composed per-row rule used by :PiSessions: current view, "show
--- hidden", a still-running child process, then the configured
--- `child_visible` policy within the same conversation epoch.
---@param entry pi.SubsessionManifestEntry
---@param opts? pi.SessionsListRowVisibleOpts
---@return boolean
function M.row_visible(entry, opts)
    if type(entry) ~= "table" then
        return false
    end
    opts = opts or {}
    if opts.is_current == true or opts.hidden == true then
        return true
    end
    local ctx = opts.ctx
    local child_id = entry._id
    if entry.status == "active" and type(child_id) == "string" and ctx and ctx.process_alive then
        if ctx.process_alive(child_id) then
            return true
        end
    end
    if opts.same_epoch == false then
        return false
    end
    return M.child_visible(entry, ctx)
end

return M
