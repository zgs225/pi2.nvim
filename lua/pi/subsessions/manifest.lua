--- Sub-session manifest persistence (`.pi2-subsessions.json`).

local M = {}

local History = require("pi.sessions.history")

local MANIFEST_FILE = ".pi2-subsessions.json"

---@class pi.SubsessionManifestEntry
---@field _id? string Manifest key (child session id)
---@field parent_id string
---@field name string
---@field task_prompt string
---@field config { model: pi.ModelRef, thinking_level?: string, tools?: string[] }
---@field status "active"|"completed"|"failed"|"interrupted"|"dormant"
---@field reported boolean
---@field last_report? string
---@field last_error? string Reason a run failed (provider/auth/quota/network error, or a process exit). Set when a settle books the run as `failed` and cleared on the next successful one, so a later revision of the same child does not inherit a stale error.
---@field name_source? "explicit"|"fallback"|"auto" Where `name` came from: "explicit" (caller-supplied — dispatch `name`, the :PiSubNew dialog) is never overwritten; "fallback" is derived from `task_prompt` and may be replaced by the child's auto-generated title; "auto" is that title. Absent in manifests written before this field existed — see `M.is_derived_name`.
---@field created_at string
---@field last_active_at string
---@field agent_spawned? boolean True when spawned by parent Agent tool (skip prompt injection).
---@field parent_epoch? integer Parent conversation epoch when spawned (default 0).
---@field run_generation? integer Monotonic run counter: 1 on spawn, bumped by every revive/reuse, so a late settle can tell a superseded run from the current one.
---@field workspace? string Workspace cwd that owns this row (the parent session's cwd). Recorded so a row found on disk — whose workspace directory name cannot be decoded — still yields a usable base for revive/rebuild.
---@field session_file? string pi session transcript file reported by the backend at spawn/revive. Authoritative for a child whose JSONL lives in another workspace (its own worktree).
---@field worktree? table Worktree metadata when the child runs in an isolated checkout (recorded by `pi.subsessions.spawn`).

local LINEAGE_KEY = "__lineage__"

--- Characters of `task_prompt` kept when deriving a child name. The dispatch
--- block's display fallback (tool_ui.item_label) uses the same derivation via
--- M.fallback_name, so a derived name always matches what the caller saw.
local FALLBACK_NAME_CHARS = 40

---@type table<string, any>
local cache = {}

--- Manifests that failed to decode, keyed by file path. Callers that rewrite a
--- whole manifest must check this and refuse to save, or one unreadable byte
--- would wipe every sub-session entry.
---@type table<string, boolean>
local decode_failed_paths = {}

--- Path of the most recently loaded/saved manifest (compat for
--- `M.decode_failed()` without a cwd).
---@type string?
local last_path = nil

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

--- Manifest file path for a workspace cwd.
--- The manifest lives next to the session files it describes, so a session
--- running in a git worktree keeps its own manifest there. Callers pass the
--- owning session's cwd; omitting it keeps the process-cwd behaviour.
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return string
function M.path(cwd)
    return History.get_sessions_dir(cwd) .. "/" .. MANIFEST_FILE
end

--- Manifest file that lives next to a batch file (same workspace directory).
--- Lets a caller holding only a batch path reach its workspace manifest.
---@param batch_path string
---@return string
function M.path_for_batch(batch_path)
    return vim.fn.fnamemodify(batch_path, ":h") .. "/" .. MANIFEST_FILE
end

--- The workspace whose manifest owns a session's rows.
---
--- Sub-session bookkeeping belongs to the **owner parent session's** cwd,
--- which is also the cwd the spawned pi process reported as `process.cwd()` —
--- so a child session (running in its own worktree) carries the parent's
--- workspace in `manifest_cwd`. Falls back to the session's own cwd, then to
--- nil (process cwd), which keeps the historical single-workspace behaviour.
---@param session pi.Session|{ cwd?: string, manifest_cwd?: string }?
---@return string?
function M.workspace(session)
    if type(session) ~= "table" then
        return nil
    end
    local cwd = session.manifest_cwd
    if type(cwd) ~= "string" or cwd == "" then
        cwd = session.cwd
    end
    if type(cwd) ~= "string" or cwd == "" then
        return nil
    end
    return cwd
end

--- Where the workspace session files live (one subdirectory per workspace).
---@return string
local function sessions_root()
    return vim.fn.fnamemodify(History.get_sessions_dir(), ":h")
end

--- Every manifest on disk, one per workspace. Cached for the current event
--- loop tick: the render path may ask dozens of times per redraw, and a glob
--- per call would be wasteful.
---@type string[]?
local disk_paths_cache = nil

---@return string[]
local function disk_manifest_paths()
    if disk_paths_cache then
        return disk_paths_cache
    end
    local root = sessions_root()
    local paths = {}
    if vim.fn.isdirectory(root) == 1 then
        paths = vim.fn.glob(root .. "/*/" .. MANIFEST_FILE, false, true)
    end
    disk_paths_cache = paths
    if vim.in_fast_event and vim.in_fast_event() then
        disk_paths_cache = nil
    else
        vim.schedule(function()
            disk_paths_cache = nil
        end)
    end
    return paths
end

---@class pi.SubsessionScope
---@field path string Manifest file path.
---@field cwd? string Workspace cwd when known (nil for a workspace discovered on disk).

--- Manifests worth consulting, in order of authority.
---
--- The caller's workspace comes first, then every live session's workspace,
--- then (unless `opts.disk == false`) every manifest on disk — the backstop that
--- lets a rebuild or sweep find rows of a workspace no live session reports
--- (Neovim restarted in a different checkout).
---@param opts? { cwd?: string, disk?: boolean } `cwd` is the preferred workspace (default: Neovim's cwd)
---@return pi.SubsessionScope[]
function M.scopes(opts)
    opts = opts or {}
    local out = {}
    local seen = {}
    ---@param cwd string?
    ---@param path_or_nil string?
    local function add(cwd, path_or_nil)
        local path = path_or_nil or M.path(cwd)
        if seen[path] then
            return
        end
        seen[path] = true
        out[#out + 1] = { path = path, cwd = cwd }
    end

    -- The process cwd comes first so legacy callers (no explicit workspace)
    -- still resolve their own manifest without a scan.
    add(type(opts.cwd) == "string" and opts.cwd ~= "" and opts.cwd or vim.fn.getcwd())
    local ok_manager, Sessions = pcall(require, "pi.sessions.manager")
    if ok_manager and type(Sessions) == "table" and type(Sessions.list_all) == "function" then
        local ok_list, list = pcall(Sessions.list_all)
        if ok_list and type(list) == "table" then
            for _, session in ipairs(list) do
                local cwd = M.workspace(session)
                if cwd then
                    add(cwd)
                end
            end
        end
    end
    if opts.disk ~= false then
        for _, path in ipairs(disk_manifest_paths()) do
            add(nil, path)
        end
    end
    return out
end

--- Find a session's manifest row across workspaces.
---
--- The row lives in its owner parent's workspace, which is not necessarily the
--- process cwd (a tab may run anywhere). Callers that know the workspace pass it
--- and pay a single file read; the search only kicks in for callers that do not
--- (tool rendering, a session id handed in by the UI).
---@param id string
---@param cwd? string preferred workspace cwd
---@return pi.SubsessionManifestEntry? entry
---@return string? workspace cwd of the scope that holds the row (falls back to the row's own `workspace` record for a manifest discovered on disk)
---@return string? path manifest file that holds the row
function M.locate(id, cwd)
    if type(id) ~= "string" or id == "" then
        return nil, nil, nil
    end
    -- The preferred workspace goes through `M.load` (the one seam tests and
    -- single-workspace callers override); the scan below reads scopes directly.
    local primary = M.load(cwd)
    if type(primary[id]) == "table" then
        return primary[id], cwd, M.path(cwd)
    end
    for _, scope in ipairs(M.scopes({ cwd = cwd, disk = true })) do
        local entry = M.load_at(scope.path)[id]
        if type(entry) == "table" then
            -- A workspace discovered on disk has no decoded cwd, so the row's
            -- own `workspace` record stands in for it (see `M.upsert` callers).
            local entry_row = entry --[[@as table]]
            local workspace = scope.cwd
            if workspace == nil and type(entry_row.workspace) == "string" and entry_row.workspace ~= "" then
                workspace = entry_row.workspace
            end
            return entry, workspace, scope.path
        end
    end
    return nil, nil, nil
end

--- Normalize a child tool allowlist (`subagent.tools`, a spawn item's `tools`
--- field, or a persisted manifest entry's `config.tools`).
---
--- `nil` is the documented default and means "inherit every tool", so it passes
--- through untouched. An empty array is rejected instead of meaning "no tools":
--- a child with no tools at all cannot do the work it was spawned for, which is
--- invariably a caller mistake rather than an intent.
---@param value any
---@return string[]? normalized Fresh array of tool names (safe to mutate), or nil
---@return string? err Human-readable reason when `value` is not a valid allowlist
function M.normalize_tools(value)
    if value == nil then
        return nil, nil
    end
    if type(value) ~= "table" then
        return nil, "tools must be an array of tool names"
    end
    if #value == 0 then
        return nil, "tools must list at least one tool; omit it to inherit every tool"
    end
    local out = {} ---@type string[]
    for i, item in ipairs(value) do
        -- Rejected rather than trimmed: a padded name is a typo, and silently
        -- accepting it would let "read " reach the CLI. The array is a fresh
        -- copy so the caller's table is never aliased through the result.
        if type(item) ~= "string" or item == "" or item:find("%s") or item:find(",", 1, true) then
            return nil, ("tools[%d] must be a single tool name without commas or whitespace"):format(i)
        end
        out[#out + 1] = item
    end
    return out, nil
end

--- Drop the in-memory cache and spawn reservations (tests / path overrides).
function M._reset()
    cache = {}
    decode_failed_paths = {}
    last_path = nil
    disk_paths_cache = nil
    occupy = {}
end

--- True when `load()` hit an existing, non-empty file that failed to decode.
--- In that state the in-memory manifest is not backed by the disk file, so
--- persisting it would overwrite the real (unreadable) manifest — typically
--- with an empty table, destroying all sub-session metadata.
---@param cwd? string workspace cwd (default: the last manifest touched)
---@return boolean
function M.decode_failed(cwd)
    local path = cwd ~= nil and M.path(cwd) or last_path
    return path ~= nil and decode_failed_paths[path] == true
end

--- True when a specific manifest file failed to decode (per-workspace form of
--- `M.decode_failed`, used by the rebuild that walks every workspace).
---@param path string
---@return boolean
function M.decode_failed_at(path)
    return decode_failed_paths[path] == true
end

--- Read a manifest file by path (the primitive behind `M.load`).
---@param path string
---@return table<string, pi.SubsessionManifestEntry>
function M.load_at(path)
    last_path = path
    local cached = cache[path]
    if cached ~= nil then
        return cached
    end
    local file = io.open(path, "r")
    if not file then
        cache[path] = {}
        decode_failed_paths[path] = nil
        return cache[path]
    end
    local content = file:read("*a")
    file:close()
    if type(content) ~= "string" or content == "" then
        cache[path] = {}
        decode_failed_paths[path] = nil
        return cache[path]
    end
    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
        cache[path] = data
        decode_failed_paths[path] = nil
        return cache[path]
    end
    decode_failed_paths[path] = true
    return {}
end

---@param cwd? string workspace cwd whose manifest to read (default: Neovim's current cwd)
---@return table<string, pi.SubsessionManifestEntry>
function M.load(cwd)
    return M.load_at(M.path(cwd))
end

--- Write a manifest file by path (the primitive behind `M.save`).
---@param manifest table<string, pi.SubsessionManifestEntry>
---@param path string
---@return boolean
function M.save_at(manifest, path)
    last_path = path
    cache[path] = manifest
    decode_failed_paths[path] = nil
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

---@param manifest table<string, pi.SubsessionManifestEntry>
---@param cwd? string workspace cwd whose manifest to write (default: Neovim's current cwd)
---@return boolean
function M.save(manifest, cwd)
    return M.save_at(manifest, M.path(cwd))
end

--- Sentinel for `M.patch`: a field set to this value is **deleted** from the
--- entry. `pairs` skips `nil` values, so `{ last_error = nil }` cannot clear a
--- field — this is how a successful run drops a previous failure reason.
M.REMOVE = setmetatable({}, {
    __tostring = function()
        return "pi.Manifest.REMOVE"
    end,
})

---@param id string
---@param entry pi.SubsessionManifestEntry
---@param cwd? string workspace cwd (default: Neovim's current cwd)
function M.upsert(id, entry, cwd)
    local manifest = M.load(cwd)
    manifest[id] = entry
    M.save(manifest, cwd)
end

--- Patch a row in the workspace that owns it.
---
--- Writes to `cwd`'s manifest when the row is there; otherwise locates the row
--- (a child's row lives in the parent's workspace, which may differ from the
--- caller's cwd) and patches it there, so a settle/abort that only knows the
--- child id cannot silently miss the row.
---@param id string
---@param patch table
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return boolean found True when a row was patched.
function M.patch(id, patch, cwd)
    local path = M.path(cwd)
    local manifest = M.load_at(path)
    if type(manifest[id]) ~= "table" then
        local _, _, found_path = M.locate(id, cwd)
        if found_path and found_path ~= path then
            path = found_path
            manifest = M.load_at(path)
        end
    end
    local entry = manifest[id]
    if type(entry) ~= "table" then
        return false
    end
    for k, v in pairs(patch) do
        if v == M.REMOVE then
            entry[k] = nil
        else
            entry[k] = v
        end
    end
    manifest[id] = entry
    M.save_at(manifest, path)
    return true
end

---@param session_id string
---@param lineage_id string
---@param cwd? string workspace cwd (default: Neovim's current cwd)
function M.register_session_lineage(session_id, lineage_id, cwd)
    if type(session_id) ~= "string" or session_id == "" or type(lineage_id) ~= "string" or lineage_id == "" then
        return
    end
    local manifest = M.load(cwd)
    local map = lineage_map(manifest)
    map[session_id] = lineage_id
    manifest[LINEAGE_KEY] = map
    M.save(manifest, cwd)
end

---@param session_id? string
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return string?
function M.resolve_lineage(session_id, cwd)
    if type(session_id) ~= "string" or session_id == "" then
        return nil
    end
    local map = lineage_map(M.load(cwd))
    return map[session_id] or session_id
end

---@param session { id?: string, lineage_id?: string, cwd?: string, manifest_cwd?: string }
---@param cwd? string workspace cwd (default: `session.cwd`, then Neovim's current cwd)
---@return string
function M.lineage_for_session(session, cwd)
    if type(session.lineage_id) == "string" and session.lineage_id ~= "" then
        return session.lineage_id
    end
    local id = session.id
    if type(id) ~= "string" or id == "" then
        return ""
    end
    local workspace = cwd
    if workspace == nil and type(session.cwd) == "string" then
        workspace = session.cwd
    end
    local resolved = M.resolve_lineage(id, workspace)
    if resolved ~= nil and resolved ~= id then
        return resolved
    end
    -- A child session's own cwd is its worktree, not the workspace that owns the
    -- lineage map — so a call without the parent workspace (a manager hook that
    -- only has the session object) resolves against `manifest_cwd` instead.
    local manifest_cwd = session.manifest_cwd
    if type(manifest_cwd) == "string" and manifest_cwd ~= "" and manifest_cwd ~= workspace then
        local again = M.resolve_lineage(id, manifest_cwd)
        if again ~= nil and again ~= id then
            return again
        end
    end
    return resolved or id
end

--- Persist lineage on the session object and in the manifest map.
---@param session { id?: string, lineage_id?: string, cwd?: string }
---@param session_id string
---@param cwd? string workspace cwd (default: `session.cwd`, then Neovim's current cwd)
function M.bind_session_lineage(session, session_id, cwd)
    if not session.lineage_id then
        session.lineage_id = session_id
    end
    local workspace = cwd
    if workspace == nil and type(session.cwd) == "string" then
        workspace = session.cwd
    end
    M.register_session_lineage(session_id, session.lineage_id, workspace)
end

--- Replace lineage after :PiResume / switch_session (tab reuses the session object).
---@param session { id?: string, lineage_id?: string, cwd?: string }
---@param session_id string
---@param cwd? string workspace cwd (default: `session.cwd`, then Neovim's current cwd)
function M.rebind_lineage(session, session_id, cwd)
    if type(session_id) ~= "string" or session_id == "" then
        return
    end
    session.lineage_id = session_id
    local workspace = cwd
    if workspace == nil and type(session.cwd) == "string" then
        workspace = session.cwd
    end
    M.register_session_lineage(session_id, session_id, workspace)
end

---@param parent_id string Lineage id (stable parent key in the manifest).
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return pi.SubsessionManifestEntry[]
function M.children_of(parent_id, cwd)
    local manifest = M.load(cwd)
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
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return boolean
function M.is_child_session(session_id, cwd)
    if type(session_id) ~= "string" or session_id == "" then
        return false
    end
    local entry = M.load(cwd)[session_id]
    return type(entry) == "table" and entry.parent_id ~= nil
end

--- Name derived from the task text when the caller supplies none.
---@param task? string
---@return string?
function M.fallback_name(task)
    if type(task) ~= "string" or task == "" then
        return nil
    end
    return task:sub(1, FALLBACK_NAME_CHARS)
end

--- True when an entry's `name` was derived rather than supplied, i.e. the
--- child's own auto-generated title may replace it (M.on_child_session_name).
---
--- Entries written before `name_source` existed have no provenance to read, so
--- they fall back to an exact comparison with M.fallback_name(task_prompt).
--- The only explicit name that is not protected by that heuristic is one that
--- happens to equal the task prefix — replacing it with a generated title is
--- an improvement there, not a loss.
---@param entry? pi.SubsessionManifestEntry
---@return boolean
function M.is_derived_name(entry)
    if type(entry) ~= "table" then
        return false
    end
    if entry.name_source == "explicit" or entry.name_source == "auto" then
        return false
    end
    local name = entry.name
    if type(name) ~= "string" or name == "" then
        return true
    end
    local fallback = M.fallback_name(entry.task_prompt)
    return fallback ~= nil and name == fallback
end

---@return string
function M.iso_now()
    return tostring(os.date("!%Y-%m-%dT%H:%M:%SZ"))
end

---@param parent_id string Lineage id.
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return integer
function M.count_active_children(parent_id, cwd)
    local manifest = M.load(cwd)
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

---@alias pi.SubsessionChildAlivePred fun(child_id: string): boolean

--- Children of a lineage whose process is still alive, whatever their
--- manifest status. This is the counting behind `subagent.max_children` when
--- the caller supplies a liveness predicate (the Sessions registry check lives
--- in the caller — manifest must not require the sessions manager).
---@param lineage_id string
---@param is_alive pi.SubsessionChildAlivePred
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return integer
function M.count_alive_children(lineage_id, is_alive, cwd)
    local manifest = M.load(cwd)
    local n = 0
    for id, entry in pairs(manifest) do
        if is_child_entry_key(id) and type(entry) == "table" and entry.parent_id == lineage_id and is_alive(id) then
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

--- Occupancy for a lineage: in-flight spawns plus, when `is_alive` is given,
--- every child whose process is still running (any status — a
--- completed-but-alive child keeps holding a slot); otherwise only manifest
--- rows with status "active" (legacy counting, default for callers that do not
--- pass a predicate).
---@param lineage_id string
---@param is_alive? pi.SubsessionChildAlivePred
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return integer
function M.spawn_occupancy(lineage_id, is_alive, cwd)
    if is_alive then
        return M.count_alive_children(lineage_id, is_alive, cwd) + M.pending_spawns(lineage_id)
    end
    return M.count_active_children(lineage_id, cwd) + M.pending_spawns(lineage_id)
end

--- Reserve one spawn slot. Call `release_spawn` after upsert or on failure.
---@param lineage_id string
---@param max_children integer
---@param is_alive? pi.SubsessionChildAlivePred Optional liveness predicate: when given, occupancy counts
--- children of this lineage whose process is still running (any manifest status) instead of only
--- status=="active" rows, so completed-but-alive processes keep occupying slots. Omit for legacy counting.
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return boolean
function M.try_reserve_spawn(lineage_id, max_children, is_alive, cwd)
    if type(lineage_id) ~= "string" or lineage_id == "" then
        return false
    end
    if M.spawn_occupancy(lineage_id, is_alive, cwd) >= max_children then
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
