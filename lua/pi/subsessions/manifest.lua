--- Sub-session manifest persistence (`.pi2-subsessions.json`).

local M = {}

local History = require("pi.sessions.history")

local MANIFEST_FILE = ".pi2-subsessions.json"

---@class pi.SubsessionManifestEntry
---@field parent_id string
---@field name string
---@field task_prompt string
---@field config { model: pi.ModelRef, thinking_level?: string }
---@field status "active"|"completed"|"failed"|"interrupted"|"dormant"
---@field reported boolean
---@field last_report? string
---@field created_at string
---@field last_active_at string
---@field agent_spawned? boolean True when spawned by parent Agent tool (skip prompt injection).
---@field run_generation? integer Monotonic run counter; incremented on each prompt to a child.
---@field parent_epoch? integer Parent conversation epoch when spawned (default 0).

local LINEAGE_KEY = "__lineage__"

---@param manifest table<string, any>
---@return table<string, string>
local function lineage_map(manifest)
    local meta = manifest[LINEAGE_KEY]
    if type(meta) == "table" then
        return meta
    end
    return {}
end

---@param id string
---@return boolean
local function is_child_entry_key(id)
    return type(id) == "string" and id ~= "" and not id:match("^__")
end
---@return string
function M.path()
    return History.get_sessions_dir() .. "/" .. MANIFEST_FILE
end

---@return table<string, pi.SubsessionManifestEntry>
function M.load()
    local path = M.path()
    local file = io.open(path, "r")
    if not file then
        return {}
    end
    local content = file:read("*a")
    file:close()
    if type(content) ~= "string" or content == "" then
        return {}
    end
    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

---@param manifest table<string, pi.SubsessionManifestEntry>
---@return boolean
function M.save(manifest)
    local path = M.path()
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "w")
    if not file then
        return false
    end
    file:write(vim.json.encode(manifest))
    file:close()
    local ok = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
    end
    return ok == true
end

---@param id string
---@param entry pi.SubsessionManifestEntry
function M.upsert(id, entry)
    local manifest = M.load()
    manifest[id] = entry
    M.save(manifest)
end

---@param id string
---@param patch table
function M.patch(id, patch)
    local manifest = M.load()
    local entry = manifest[id]
    if not entry then
        return
    end
    for k, v in pairs(patch) do
        entry[k] = v
    end
    manifest[id] = entry
    M.save(manifest)
end

---@param session_id string
---@param lineage_id string
function M.register_session_lineage(session_id, lineage_id)
    if type(session_id) ~= "string" or session_id == "" or type(lineage_id) ~= "string" or lineage_id == "" then
        return
    end
    local manifest = M.load()
    local map = lineage_map(manifest)
    map[session_id] = lineage_id
    manifest[LINEAGE_KEY] = map
    M.save(manifest)
end

---@param session_id? string
---@return string?
function M.resolve_lineage(session_id)
    if type(session_id) ~= "string" or session_id == "" then
        return nil
    end
    local map = lineage_map(M.load())
    return map[session_id] or session_id
end

---@param session { id?: string, lineage_id?: string }
---@return string
function M.lineage_for_session(session)
    if type(session.lineage_id) == "string" and session.lineage_id ~= "" then
        return session.lineage_id
    end
    if type(session.id) == "string" and session.id ~= "" then
        return M.resolve_lineage(session.id) or session.id
    end
    return ""
end

--- Persist lineage on the session object and in the manifest map.
---@param session { id?: string, lineage_id?: string }
---@param session_id string
function M.bind_session_lineage(session, session_id)
    if not session.lineage_id then
        session.lineage_id = session_id
    end
    M.register_session_lineage(session_id, session.lineage_id)
end

--- Replace lineage after :PiResume / switch_session (tab reuses the session object).
---@param session { id?: string, lineage_id?: string }
---@param session_id string
function M.rebind_lineage(session, session_id)
    if type(session_id) ~= "string" or session_id == "" then
        return
    end
    session.lineage_id = session_id
    M.register_session_lineage(session_id, session_id)
end

---@param parent_id string Lineage id (stable parent key in the manifest).
---@return pi.SubsessionManifestEntry[]
function M.children_of(parent_id)
    local manifest = M.load()
    ---@type pi.SubsessionManifestEntry[]
    local result = {}
    for id, entry in pairs(manifest) do
        if is_child_entry_key(id) and type(entry) == "table" and entry.parent_id == parent_id then
            local row = vim.deepcopy(entry)
            ---@diagnostic disable-next-line: inject-field
            row._id = id
            result[#result + 1] = row
        end
    end
    table.sort(result, function(a, b)
        local ca = a.created_at or ""
        local cb = b.created_at or ""
        if ca ~= cb then
            return ca > cb
        end
        return (a._id or "") < (b._id or "")
    end)
    return result
end

--- True when `session_id` is registered as a sub-session child in the manifest.
---@param session_id? string
---@return boolean
function M.is_child_session(session_id)
    if type(session_id) ~= "string" or session_id == "" then
        return false
    end
    local entry = M.load()[session_id]
    return type(entry) == "table" and entry.parent_id ~= nil
end

---@return string
function M.iso_now()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

return M
