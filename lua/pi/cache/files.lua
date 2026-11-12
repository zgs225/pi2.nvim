--- Shared file listing with cache for completion and mention validation.
---
--- Refresh is asynchronous (stale-while-revalidate): once a cache exists for a
--- workspace, readers never block — an expired cache is returned immediately
--- while a background refresh repopulates it. Only the first (cold) call per
--- workspace fetches synchronously, and even that one never walks the directory
--- tree on the main loop: a non-git cwd answers empty and is repopulated
--- asynchronously with `fd` (or `find`).
---
--- State is partitioned **per normalized workspace cwd**, not kept in one slot.
--- Two tabs may legitimately read different workspaces (a session in a git
--- worktree next to one in the main checkout); with a single slot every read in
--- one workspace evicted the other's listing and — worse — the single-flight
--- guard silently dropped a second workspace's refresh, so alternating readers
--- paid a blocking `git ls-files` on each turn. Per-workspace slots make
--- concurrent refreshes independent: a result is always stored under the
--- workspace it was fetched for, and readers only ever cancel their own
--- workspace's in-flight refresh.

---@class pi.FileCache
---@field files string[]
---@field map table<string, true>
---@field cwd string
---@field timestamp number

local M = {}

local Notify = require("pi.notify")

--- Cached listings, keyed by normalized workspace cwd.
---@type table<string, pi.FileCache>
local caches = {}

--- Single-flight guard per workspace.
---@type table<string, boolean>
local refreshing = {}

--- Monotonic generation per workspace, bumped by `invalidate()`. A refresh that
--- started before an invalidation must not repopulate the slot with a listing
--- fetched from the pre-invalidation directory state.
---@type table<string, integer>
local generation = {}

--- Workspace most recently requested by a reader (test observability).
---@type string?
local last_cwd = nil

--- Async refreshes initiated, globally and per workspace (test observability).
local refresh_spawns = 0
---@type table<string, integer>
local refresh_spawns_by_cwd = {}

--- Synchronous cold fetches performed, globally and per workspace (test
--- observability: alternating warm workspaces must not re-enter this path).
local sync_fetches = 0
---@type table<string, integer>
local sync_fetches_by_cwd = {}

local CACHE_TTL_NS = 5e9 -- 5 seconds

--- Hard cap on a directory walk result, so a huge tree cannot blow up memory.
local MAX_FILES = 20000

--- Hard cap on cached workspaces, so a long editor session touching many
--- projects cannot grow the table without bound. The least recently refreshed
--- entry is dropped first.
local MAX_WORKSPACES = 16

local GIT_LS_FILES_ARGS = { "git", "ls-files", "--cached", "--others", "--exclude-standard" }
local FALLBACK_FD_ARGS = { "fd", "--type", "f" }
local FALLBACK_FIND_ARGS = { "find", ".", "-type", "f" }

--- Check if a buffer is a pi prompt buffer.
---@param buf? integer
---@return boolean
function M.is_pi_prompt_buf(buf)
    buf = buf or vim.api.nvim_get_current_buf()
    local ft = require("pi.filetypes")
    return vim.bo[buf].filetype == ft.prompt
end

--- Resolve a workspace cwd: expand `~`/relative input, resolve symlinks, and
--- fall back to Neovim's cwd when the argument is unusable. Normalizing here
--- keeps the cache key, the spawned `git`/`fd` cwd, and the paths the pi process
--- reports pointing at the same directory.
---@param cwd? string
---@return string
local function resolve_cwd(cwd)
    if type(cwd) ~= "string" or vim.trim(cwd) == "" then
        return vim.fn.getcwd()
    end
    local path = vim.trim(cwd)
    local is_absolute = path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil or path:sub(1, 2) == "\\\\"
    if not is_absolute then
        path = vim.fn.fnamemodify(path, ":p")
    end
    return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

--- Record which workspace the reader is looking at (test observability only).
---@param cwd string
local function touch(cwd)
    last_cwd = cwd
end

--- Drop the least recently refreshed workspace while the table is over its cap.
--- Evicting a workspace also forgets its generation, which makes any in-flight
--- refresh for it drop itself (`generation[cwd] ~= gen`).
local function evict_over_cap()
    local count = 0
    for _ in pairs(caches) do
        count = count + 1
    end
    while count > MAX_WORKSPACES do
        local oldest ---@type string?
        local oldest_ts = math.huge
        for cwd, entry in pairs(caches) do
            if entry.timestamp < oldest_ts then
                oldest = cwd
                oldest_ts = entry.timestamp
            end
        end
        if not oldest then
            return
        end
        caches[oldest] = nil
        generation[oldest] = nil
        count = count - 1
    end
end

--- Build and store one workspace's cache entry.
---@param files string[]
---@param cwd string
local function store(files, cwd)
    local map = {}
    for _, f in ipairs(files) do
        map[f] = true
    end
    caches[cwd] = { files = files, map = map, cwd = cwd, timestamp = vim.uv.hrtime() }
    evict_over_cap()
end

--- Parse `git ls-files` stdout into a file list.
---@param stdout string
---@return string[]
local function parse_ls_files(stdout)
    if stdout == "" then
        return {}
    end
    return vim.split(vim.trim(stdout), "\n", { plain = true, trimempty = true })
end

--- Parse an `fd`/`find` stdout into a file list: one path per line, normalized
--- to relative paths without a leading `./`, capped at MAX_FILES.
---@param stdout string
---@return string[]
local function parse_fallback(stdout)
    local files = {}
    if not stdout or stdout == "" then
        return files
    end
    for _, line in ipairs(vim.split(vim.trim(stdout), "\n", { plain = true, trimempty = true })) do
        local path = vim.startswith(line, "./") and line:sub(3) or line
        if path ~= "" then
            files[#files + 1] = path
            if #files >= MAX_FILES then
                break
            end
        end
    end
    return files
end

--- True if the workspace has no cache entry or its entry is past the TTL.
--- Other workspaces' entries are irrelevant here — that is the point of the
--- per-workspace partition.
---@param cwd string
---@return boolean
local function is_stale(cwd)
    local entry = caches[cwd]
    return entry == nil or (vim.uv.hrtime() - entry.timestamp) >= CACHE_TTL_NS
end

--- True when a refresh result for `cwd` is still valid: same workspace, same
--- generation (no invalidation since the refresh started).
---@param cwd string
---@param gen integer
---@return boolean
local function is_result_live(cwd, gen)
    return (generation[cwd] or 0) == gen
end

--- Second-phase refresh for non-git directories: spawn `fd`/`find` instead of
--- globbing on the main loop. Owns this workspace's `refreshing` flag until it
--- completes.
---@param cwd string
---@param gen integer
---@param args string[]
local function refresh_fallback(cwd, gen, args)
    local stat = vim.uv.fs_stat(cwd)
    if not stat or stat.type ~= "directory" then
        -- The cwd vanished (e.g. a deleted temp dir) while the refresh was
        -- pending: nothing to list, and spawning would only throw.
        refreshing[cwd] = nil
        return
    end
    local ok, err = pcall(vim.system, args, { text = true, cwd = cwd }, function(result)
        -- uv callback: fast event context; all vim.fn work must be deferred.
        vim.schedule(function()
            refreshing[cwd] = nil
            if not is_result_live(cwd, gen) then
                return -- invalidated mid-flight; the next reader refetches
            end
            store(parse_fallback(result.stdout), cwd)
        end)
    end)
    if not ok then
        refreshing[cwd] = nil
        Notify.warn("file cache fallback failed to start: " .. tostring(err))
    end
end

--- Refresh one workspace asynchronously (single-flight **per workspace**).
--- No-op while a refresh for the same workspace is in flight; a refresh for
--- another workspace neither waits on nor cancels it.
---@param cwd? string workspace cwd (default: Neovim's current cwd)
function M.refresh(cwd)
    cwd = resolve_cwd(cwd)
    touch(cwd)
    if refreshing[cwd] then
        return
    end
    refreshing[cwd] = true
    refresh_spawns = refresh_spawns + 1
    refresh_spawns_by_cwd[cwd] = (refresh_spawns_by_cwd[cwd] or 0) + 1
    local gen = generation[cwd] or 0

    -- Resolve the fallback argv on the main loop: only vim.fn may decide
    -- whether `fd` is available.
    local fallback_args = vim.fn.executable("fd") == 1 and FALLBACK_FD_ARGS or FALLBACK_FIND_ARGS

    -- Defer the process spawn to the next event loop turn: uv spawn itself
    -- costs a few ms, and readers on the expired path should pay nothing.
    vim.schedule(function()
        local stat = vim.uv.fs_stat(cwd)
        if not stat or stat.type ~= "directory" then
            -- The cwd vanished while the refresh was pending (e.g. a deleted
            -- temp dir): skip silently, the next reader starts over.
            refreshing[cwd] = nil
            return
        end
        local ok, err = pcall(vim.system, GIT_LS_FILES_ARGS, { text = true, cwd = cwd }, function(result)
            -- uv callback: fast event context. All vim.fn / API work must
            -- be deferred to the main loop.
            vim.schedule(function()
                if not is_result_live(cwd, gen) then
                    refreshing[cwd] = nil
                    return -- invalidated mid-flight; the next reader refetches
                end
                if result.code == 0 and result.stdout and result.stdout ~= "" then
                    refreshing[cwd] = nil
                    store(parse_ls_files(result.stdout), cwd)
                    return
                end
                -- Not a git repo (or git failed): directory walk via a second
                -- process. `refreshing` stays held until the fallback lands.
                refresh_fallback(cwd, gen, fallback_args)
            end)
        end)
        if not ok then
            refreshing[cwd] = nil
            Notify.warn("file cache refresh failed to start: " .. tostring(err))
        end
    end)
end

--- Get project files (relative paths) for a workspace.
--- Returns that workspace's cached list immediately when one exists; if it is
--- expired, a background refresh is kicked off and the stale list is returned
--- (stale-while-revalidate). Only the first call per workspace blocks on a
--- synchronous fetch, and only when no other workspace can be served from its
--- own slot.
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return string[]
function M.list(cwd)
    cwd = resolve_cwd(cwd)
    touch(cwd)
    local entry = caches[cwd]
    if entry then
        if is_stale(cwd) then
            M.refresh(cwd)
        end
        return entry.files
    end
    return M._fetch_sync(cwd)
end

--- Synchronous cold-start fetch for one workspace. Blocks the main loop only on
--- `git ls-files`; a non-git cwd answers empty immediately and is repopulated
--- asynchronously (a recursive glob here could hang the editor on a large tree).
---@param cwd string
---@return string[]
function M._fetch_sync(cwd)
    cwd = resolve_cwd(cwd)
    touch(cwd)
    sync_fetches = sync_fetches + 1
    sync_fetches_by_cwd[cwd] = (sync_fetches_by_cwd[cwd] or 0) + 1
    local result = vim.system(GIT_LS_FILES_ARGS, { text = true, cwd = cwd }):wait()
    if result.code == 0 and result.stdout and result.stdout ~= "" then
        local files = parse_ls_files(result.stdout)
        store(files, cwd)
        return files
    end
    store({}, cwd)
    vim.schedule(function()
        M.refresh(cwd)
    end)
    return {}
end

--- Check if a relative path exists in the project.
--- Never blocks and never cancels another workspace's in-flight refresh: it
--- reads the requested workspace's own slot (stale or not), may schedule that
--- workspace's own refresh, and falls back to disk when the slot has no answer
--- yet. The on-disk fallback resolves `path` against the requested workspace, so
--- a worktree session validates its own files instead of the main checkout's.
---@param path string project-relative (or absolute) path
---@param cwd? string workspace cwd (default: Neovim's current cwd)
---@return boolean
function M.exists(path, cwd)
    cwd = resolve_cwd(cwd)
    touch(cwd)
    local entry = caches[cwd]
    if is_stale(cwd) then
        M.refresh(cwd)
    end
    if entry and entry.map[path] then
        return true
    end
    local is_absolute = path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil or path:sub(1, 2) == "\\\\"
    local abs = is_absolute and vim.fn.fnamemodify(path, ":p") or vim.fn.fnamemodify(cwd .. "/" .. path, ":p")
    return vim.fn.filereadable(abs) == 1 or vim.fn.isdirectory(abs) == 1
end

--- Invalidate every cached listing. The next `list()` per workspace performs a
--- synchronous cold fetch, and any refresh that started before this call is
--- discarded instead of repopulating the slot with pre-invalidation data.
function M.invalidate()
    for cwd in pairs(refreshing) do
        generation[cwd] = (generation[cwd] or 0) + 1
    end
    caches = {}
end

--- Cached entry for a workspace, if any (test observability).
---@param cwd? string workspace cwd (default: the workspace the last reader touched)
---@return pi.FileCache?
function M._cache(cwd)
    if cwd ~= nil then
        return caches[resolve_cwd(cwd)]
    end
    return last_cwd and caches[last_cwd] or nil
end

--- Force one workspace's entry into the expired state (tests only).
---@param cwd? string workspace cwd (default: the workspace the last reader touched)
function M._expire(cwd)
    local key = cwd ~= nil and resolve_cwd(cwd) or last_cwd
    if key and caches[key] then
        caches[key].timestamp = 0
    end
end

--- Number of async refreshes initiated since the last reset (tests only).
---@param cwd? string workspace cwd (default: global count)
---@return integer
function M._refresh_spawns(cwd)
    if cwd ~= nil then
        return refresh_spawns_by_cwd[resolve_cwd(cwd)] or 0
    end
    return refresh_spawns
end

--- Number of synchronous cold fetches performed since the last reset (tests only).
---@param cwd? string workspace cwd (default: global count)
---@return integer
function M._sync_fetches(cwd)
    if cwd ~= nil then
        return sync_fetches_by_cwd[resolve_cwd(cwd)] or 0
    end
    return sync_fetches
end

--- Reset all state (tests only).
function M._reset()
    caches = {}
    refreshing = {}
    generation = {}
    last_cwd = nil
    refresh_spawns = 0
    refresh_spawns_by_cwd = {}
    sync_fetches = 0
    sync_fetches_by_cwd = {}
end

return M
