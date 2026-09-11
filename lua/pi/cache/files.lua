--- Shared file listing with cache for completion and mention validation.
---
--- Refresh is asynchronous (stale-while-revalidate): once a cache exists for
--- the current cwd, readers never block — an expired cache is returned
--- immediately while a single background refresh repopulates it. Only the
--- first (cold) call per cwd fetches synchronously, and even that one never
--- walks the directory tree on the main loop: a non-git cwd answers empty and
--- is repopulated asynchronously with `fd` (or `find`).

---@class pi.FileCache
---@field files string[]
---@field map table<string, true>
---@field cwd string
---@field timestamp number

local M = {}

local Notify = require("pi.notify")

---@type pi.FileCache?
local cache = nil

--- Single-flight guard for the async refresh.
local refreshing = false

--- Number of async refreshes initiated (test observability).
local refresh_spawns = 0

local CACHE_TTL_NS = 5e9 -- 5 seconds

--- Hard cap on a directory walk result, so a huge tree cannot blow up memory.
local MAX_FILES = 20000

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

--- Build and store the cache.
---@param files string[]
---@param cwd string
local function store(files, cwd)
    local map = {}
    for _, f in ipairs(files) do
        map[f] = true
    end
    cache = { files = files, map = map, cwd = cwd, timestamp = vim.uv.hrtime() }
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

--- True if the cache is missing, for another cwd, or past its TTL.
---@param cwd string
---@return boolean
local function is_stale(cwd)
    return not cache or cache.cwd ~= cwd or (vim.uv.hrtime() - cache.timestamp) >= CACHE_TTL_NS
end

--- Second-phase refresh for non-git directories: spawn `fd`/`find` instead of
--- globbing on the main loop. Owns the `refreshing` flag until it completes.
---@param cwd string
---@param args string[]
local function refresh_fallback(cwd, args)
    local stat = vim.uv.fs_stat(cwd)
    if not stat or stat.type ~= "directory" then
        -- The cwd vanished (e.g. a deleted temp dir) while the refresh was
        -- pending: nothing to list, and spawning would only throw.
        refreshing = false
        return
    end
    local ok, err = pcall(vim.system, args, { text = true, cwd = cwd }, function(result)
        -- uv callback: fast event context; all vim.fn work must be deferred.
        vim.schedule(function()
            refreshing = false
            if vim.fn.getcwd() ~= cwd then
                return -- cwd changed; the next reader will refetch
            end
            store(parse_fallback(result.stdout), cwd)
        end)
    end)
    if not ok then
        refreshing = false
        Notify.warn("file cache fallback failed to start: " .. tostring(err))
    end
end

--- Refresh the cache asynchronously (single-flight).
--- No-op if a refresh is already in flight. The result is dropped if the
--- cwd changes before it lands.
---@param cwd? string defaults to the current cwd
function M.refresh(cwd)
    cwd = cwd or vim.fn.getcwd()
    if refreshing then
        return
    end
    refreshing = true
    refresh_spawns = refresh_spawns + 1

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
            refreshing = false
            return
        end
        local ok, err = pcall(vim.system, GIT_LS_FILES_ARGS, { text = true, cwd = cwd }, function(result)
            -- uv callback: fast event context. All vim.fn / API work must
            -- be deferred to the main loop.
            vim.schedule(function()
                if vim.fn.getcwd() ~= cwd then
                    refreshing = false
                    return -- cwd changed; the next reader will refetch
                end
                if result.code == 0 and result.stdout and result.stdout ~= "" then
                    refreshing = false
                    store(parse_ls_files(result.stdout), cwd)
                    return
                end
                -- Not a git repo (or git failed): directory walk via a second
                -- process. `refreshing` stays held until the fallback lands.
                refresh_fallback(cwd, fallback_args)
            end)
        end)
        if not ok then
            refreshing = false
            Notify.warn("file cache refresh failed to start: " .. tostring(err))
        end
    end)
end

--- Get project files (relative paths).
--- Returns the cached list immediately when one exists for the current cwd;
--- if it is expired, a background refresh is kicked off and the stale list is
--- returned (stale-while-revalidate). Only the first call per cwd blocks on
--- a synchronous fetch.
---@return string[]
function M.list()
    local cwd = vim.fn.getcwd()
    if cache and cache.cwd == cwd then
        if is_stale(cwd) then
            M.refresh(cwd)
        end
        return cache.files
    end
    return M._fetch_sync(cwd)
end

--- Synchronous cold-start fetch. Blocks the main loop only on `git ls-files`;
--- a non-git cwd answers empty immediately and is repopulated asynchronously
--- (a recursive glob here could hang the editor on a large tree).
---@param cwd string
---@return string[]
function M._fetch_sync(cwd)
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
--- Never blocks: on a cold or expired cache it kicks off an async refresh
--- and answers from the (possibly stale) map plus an on-disk fallback.
---@param path string
---@return boolean
function M.exists(path)
    if is_stale(vim.fn.getcwd()) then
        M.refresh()
    end
    if cache and cache.map[path] then
        return true
    end
    local abs = vim.fn.fnamemodify(path, ":p")
    return vim.fn.filereadable(abs) == 1 or vim.fn.isdirectory(abs) == 1
end

--- Invalidate the cache. The next `list()` performs a synchronous cold fetch.
function M.invalidate()
    cache = nil
end

--- Current cache entry, if any (test observability).
---@return pi.FileCache?
function M._cache()
    return cache
end

--- Force the cache into the expired state (tests only).
function M._expire()
    if cache then
        cache.timestamp = 0
    end
end

--- Number of async refreshes spawned since the last reset (tests only).
---@return integer
function M._refresh_spawns()
    return refresh_spawns
end

--- Reset all state (tests only).
function M._reset()
    cache = nil
    refreshing = false
    refresh_spawns = 0
end

return M
