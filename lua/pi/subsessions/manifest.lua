--- Sub-session manifest persistence (`.pi2-subsessions.json`).

local M = {}

local History = require("pi.sessions.history")

local MANIFEST_FILE = ".pi2-subsessions.json"

---@class pi.SubsessionManifestEntry
---@field _id? string Manifest key (child session id)
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

---@type table<string, any>?
local cache = nil
---@type string?
local cache_path = nil

--- In-flight spawn reservations per lineage (not yet upserted as active).
---@type table<string, integer>
local occupy = {}

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

--- True when `id` is a child row key (not metadata like `__lineage__`).
---@param id string
---@return boolean
function M.is_entry_id(id)
    return is_child_entry_key(id)
end

---@return string
function M.path()
    return History.get_sessions_dir() .. "/" .. MANIFEST_FILE
end

--- Drop the in-memory cache and spawn reservations (tests / path overrides).
function M._reset()
    cache = nil
    cache_path = nil
    occupy = {}
end

---@return table<string, pi.SubsessionManifestEntry>
function M.load()
    local path = M.path()
    if cache ~= nil and cache_path == path then
        return cache
    end
    local file = io.open(path, "r")
    if not file then
        cache = {}
        cache_path = path
        return cache
    end
    local content = file:read("*a")
    file:close()
    if type(content) ~= "string" or content == "" then
        cache = {}
        cache_path = path
        return cache
    end
    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
        cache = data
        cache_path = path
        return cache
    end
    return {}
end

---@param manifest table<string, pi.SubsessionManifestEntry>
---@return boolean
function M.save(manifest)
    local path = M.path()
    cache = manifest
    cache_path = path
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

---@param parent_id string Lineage id.
---@return integer
function M.count_active_children(parent_id)
    local manifest = M.load()
    local n = 0
    for id, entry in pairs(manifest) do
        if
            is_child_entry_key(id)
            and type(entry) == "table"
            and entry.parent_id == parent_id
            and entry.status == "active"
        then
            n = n + 1
        end
    end
    return n
end

---@param lineage_id string
---@return integer
function M.pending_spawns(lineage_id)
    return occupy[lineage_id] or 0
end

--- Active children plus in-flight spawns for a lineage.
---@param lineage_id string
---@return integer
function M.spawn_occupancy(lineage_id)
    return M.count_active_children(lineage_id) + M.pending_spawns(lineage_id)
end

--- Reserve one spawn slot. Call `release_spawn` after upsert or on failure.
---@param lineage_id string
---@param max_children integer
---@return boolean
function M.try_reserve_spawn(lineage_id, max_children)
    if type(lineage_id) ~= "string" or lineage_id == "" then
        return false
    end
    if M.spawn_occupancy(lineage_id) >= max_children then
        return false
    end
    occupy[lineage_id] = (occupy[lineage_id] or 0) + 1
    return true
end

---@param lineage_id string
function M.release_spawn(lineage_id)
    local n = occupy[lineage_id] or 0
    if n <= 1 then
        occupy[lineage_id] = nil
    else
        occupy[lineage_id] = n - 1
    end
end

return M
