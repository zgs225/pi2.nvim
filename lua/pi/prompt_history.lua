--- Prompt input history with readline-style recall, scoped per workspace.
--
-- History is partitioned by workspace: the cwd captured when a session starts.
-- Each workspace gets its own file under `stdpath("data")/pi/history/`, named
-- by a short sha256 hash of the normalized cwd, plus an `index.json` mapping
-- hash -> cwd (for debugging and cleanup). Entries are multi-line safe and
-- persisted as JSON.
--
-- Two responsibilities live in separate classes so they can be unit-tested
-- without any UI:
--   * `Store` — the durable archive (entries + persistence). Pass
--     `path = false` for an in-memory store, or a path string to persist.
--   * `Nav` — the transient per-chat readline cursor (position + stashed
--     draft). Multiple chats sharing one workspace store never interfere.

local M = {}

---@class pi.PromptHistoryStore
---@field _entries string[] oldest first, newest last
---@field _max integer
---@field _path string? nil => in-memory
local Store = {}
Store.__index = Store

---@class pi.PromptHistoryOpts
---@field max integer?

--- Create a new store.
---@param opts? pi.PromptHistoryOpts|{path: string|false|nil}
---@return pi.PromptHistoryStore
function Store.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Store)
    self._entries = {}
    self._max = (opts.max and opts.max > 0) and opts.max or 500
    self._path = (type(opts.path) == "string") and opts.path or nil
    if self._path then
        self:load()
    end
    return self
end

---@return string[] copy of entries, oldest first
function Store:entries()
    return vim.deepcopy(self._entries)
end

---@return integer
function Store:size()
    return #self._entries
end

--- Add a submitted prompt. Ignores empty/whitespace-only entries and skips an
--- entry identical to the most recent one (readline consecutive-dedupe).
--- Enforces the cap by dropping the oldest. Persists when file-backed.
---@param entry string
function Store:add(entry)
    if type(entry) ~= "string" or vim.trim(entry) == "" then
        return
    end
    if self._entries[#self._entries] == entry then
        return
    end
    table.insert(self._entries, entry)
    while #self._entries > self._max do
        table.remove(self._entries, 1)
    end
    self:save()
end

--- Persist entries to disk (no-op for in-memory stores). Writes atomically via
--- a temp file + rename so a crash mid-write can't corrupt the history.
function Store:save()
    if not self._path then
        return
    end
    local dir = vim.fn.fnamemodify(self._path, ":h")
    vim.fn.mkdir(dir, "p")
    local ok, encoded = pcall(vim.json.encode, self._entries)
    if not ok then
        return
    end
    local tmp = self._path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        return
    end
    f:write(encoded)
    f:close()
    os.rename(tmp, self._path)
end

--- Load entries from disk (no-op for in-memory stores or missing files).
--- Silently ignores corrupt/unreadable files.
function Store:load()
    if not self._path then
        return
    end
    local f = io.open(self._path, "r")
    if not f then
        return
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
        return
    end
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return
    end
    local list = {}
    for _, v in ipairs(decoded) do
        if type(v) == "string" and vim.trim(v) ~= "" then
            table.insert(list, v)
        end
    end
    while #list > self._max do
        table.remove(list, 1)
    end
    self._entries = list
end

--- Clear all entries and persist the empty state.
function Store:clear()
    self._entries = {}
    self:save()
end

-- ---------------------------------------------------------------------------
-- Per-chat readline navigation cursor
-- ---------------------------------------------------------------------------

---@class pi.PromptHistoryNav
---@field _store pi.PromptHistoryStore
---@field _index integer? nil => not navigating (at present/draft)
---@field _draft string? stashed in-progress text while navigating
local Nav = {}
Nav.__index = Nav

--- Create a navigation cursor over a store.
---@param store pi.PromptHistoryStore
---@return pi.PromptHistoryNav
function Nav.new(store)
    local self = setmetatable({}, Nav)
    self._store = store
    self._index = nil
    self._draft = nil
    return self
end

--- Step toward older entries. On the first call, stashes `draft` (the text the
--- user is currently typing) so it can be restored by walking back down.
---@param draft string? current prompt text, stashed on the first call
---@return string? entry to display, or nil if there is nothing older to show
function Nav:prev(draft)
    local entries = self._store:entries()
    local n = #entries
    if n == 0 then
        return nil
    end
    if self._index == nil then
        self._draft = draft or ""
        self._index = n
        return entries[n]
    end
    if self._index > 1 then
        self._index = self._index - 1
        return entries[self._index]
    end
    return nil -- already at oldest: no change
end

--- Step toward newer entries. When already at the newest entry, leaves
--- navigation mode and restores the stashed draft.
---@return string? entry (or the stashed draft) to display, or nil if no change
function Nav:next()
    if self._index == nil then
        return nil
    end
    local entries = self._store:entries()
    local n = #entries
    if self._index < n then
        self._index = self._index + 1
        return entries[self._index]
    end
    local draft = self._draft or ""
    self:reset()
    return draft
end

---@return boolean whether the user is currently browsing history
function Nav:navigating()
    return self._index ~= nil
end

--- Leave navigation mode (e.g. after a send, or when the user edits by hand).
function Nav:reset()
    self._index = nil
    self._draft = nil
end

-- ---------------------------------------------------------------------------
-- Workspace registry
-- ---------------------------------------------------------------------------

--- Test hook: override the base directory (default: stdpath("data") .. "/pi").
local base_dir_override = nil

--- Registry of live stores, keyed by normalized cwd.
---@type table<string, pi.PromptHistoryStore>
local stores = {}

--- Whether the legacy global history file has been removed this process.
local legacy_removed = false

---@return string
function M.base_dir()
    return base_dir_override or (vim.fn.stdpath("data") .. "/pi")
end

--- Directory holding per-workspace history files.
---@return string
function M.history_dir()
    return M.base_dir() .. "/history"
end

--- Normalize a cwd into a canonical absolute path: expand, resolve symlinks
--- via realpath (falling back to the plain path when the dir doesn't exist),
--- then `vim.fs.normalize`. Returns nil for unusable input.
---@param cwd string?
---@return string?
function M.normalize_cwd(cwd)
    if type(cwd) ~= "string" or vim.trim(cwd) == "" then
        return nil
    end
    local path = vim.trim(cwd)
    if not vim.startswith(path, "/") and not vim.startswith(path, "~") then
        path = vim.fn.fnamemodify(path, ":p")
    end
    if vim.startswith(path, "~") then
        path = (vim.uv or vim.loop).os_homedir() .. path:sub(2)
    end
    local realpath = (vim.uv or vim.loop).fs_realpath(path)
    return vim.fs.normalize(realpath or path)
end

--- Stable per-workspace file key: sha256 of the normalized cwd, truncated.
---@param normalized_cwd string
---@return string
function M.workspace_key(normalized_cwd)
    return vim.fn.sha256(normalized_cwd):sub(1, 16)
end

--- Write a file atomically (temp file + rename).
---@param path string
---@param content string
local function write_atomic(path, content)
    local dir = vim.fn.fnamemodify(path, ":h")
    vim.fn.mkdir(dir, "p")
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        return
    end
    f:write(content)
    f:close()
    os.rename(tmp, path)
end

--- Read the hash -> cwd index; silently tolerates missing/corrupt files.
---@return table<string, string>
local function read_index()
    local f = io.open(M.history_dir() .. "/index.json", "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, content or "")
    if not ok or type(decoded) ~= "table" then
        return {}
    end
    local index = {}
    for k, v in pairs(decoded) do
        if type(k) == "string" and type(v) == "string" then
            index[k] = v
        end
    end
    return index
end

--- Record hash -> cwd in index.json (no-op when already present).
---@param key string
---@param cwd string
local function update_index(key, cwd)
    local index = read_index()
    if index[key] == cwd then
        return
    end
    index[key] = cwd
    local ok, encoded = pcall(vim.json.encode, index)
    if not ok then
        return
    end
    write_atomic(M.history_dir() .. "/index.json", encoded)
end

--- Remove the legacy process-wide history file (pre-workspace behavior).
--- Called lazily on first workspace access; failures are silently ignored.
local function remove_legacy_file()
    if legacy_removed then
        return
    end
    legacy_removed = true
    os.remove(M.base_dir() .. "/prompt_history.json")
end

--- Get (or lazily create) the history store for a workspace cwd. Stores are
--- cached per normalized cwd, so all chats in the same workspace share one.
--- Falls back to the process cwd when the argument is unusable.
---@param cwd string?
---@param opts? pi.PromptHistoryOpts
---@return pi.PromptHistoryStore
function M.get_for_workspace(cwd, opts)
    remove_legacy_file()
    local normalized = M.normalize_cwd(cwd) or M.normalize_cwd(vim.fn.getcwd()) or vim.fn.getcwd()
    local store = stores[normalized]
    if store then
        return store
    end
    local key = M.workspace_key(normalized)
    store = Store.new({ path = M.history_dir() .. "/" .. key .. ".json", max = opts and opts.max })
    stores[normalized] = store
    update_index(key, normalized)
    return store
end

--- Drop cached stores and test overrides (used by tests and config reloads).
function M._reset()
    stores = {}
    legacy_removed = false
    base_dir_override = nil
end

--- Test hook: point the registry at a scratch base directory.
---@param dir string?
function M._set_base_dir(dir)
    base_dir_override = dir
end

M.Store = Store
M.Nav = Nav
return M
