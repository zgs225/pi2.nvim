--- Repository-level worktree configuration: `<repo>/.pi-worktrees.toml`.
---
--- A worktree's creation happens before the agent has read a single file, so
--- per-repository settings cannot come from the agent: they are a file at the
--- repository root that the user can commit and share, exactly like
--- `.worktreeinclude`. This module is the reader and validator for it; the
--- consumers are `pi.worktree.create` (base commit, include patterns, setup
--- commands), `Worktree.resolve_base`, and `pi.worktree_retention`.
---
--- ```toml
--- base_ref = "fresh"                   # "head" | "fresh" | any revision
--- include = [".env", "*.local"]        # patterns added to .worktreeinclude
---
--- [setup]                              # argv commands, no shell
--- unix = [["npm", "ci"], ["./scripts/setup.sh"]]
--- windows = [["npm.cmd", "ci"]]
---
--- [retention]
--- max_count = 40
--- max_age_days = 30
--- snapshot_days = 45
--- ```
---
--- Two rules shape it:
---
--- - **Data, never code.** This module only reads and validates; it never
---   executes anything. `setup` commands are a list the *worktree* module runs,
---   and only when the user opted in (`worktree.repo_setup`), because a cloned
---   repository is untrusted input.
--- - **Cheap and filesystem-only.** `read()` is a `stat` plus a cached parse, so
---   callers on a rendering or keypress path stay free of subprocesses. The
---   cache key is the file's size + mtime, so an edit is picked up immediately.

local M = {}

local Toml = require("pi.toml")
local Notify = require("pi.notify")

local uv = vim.uv

--- File name at the repository root.
local FILE = ".pi-worktrees.toml"

--- Public name of the file, for messages (`pi.worktree` prefixes its setup errors
--- with it).
M.FILE = FILE

--- Top-level keys the file may declare. Anything else is an error: a typo in a
--- repository config must be reported, not silently ignored.
local KNOWN_KEYS = {
    base_ref = true,
    include = true,
    setup = true,
    retention = true,
}

--- Keys `[setup]` may select a platform with (`all` is the shared fallback).
local SETUP_KEYS = {
    all = true,
    unix = true,
    windows = true,
}

--- Retention knobs a repository may override (`enabled` stays a user-level
--- switch: the sweep reads it before it knows which repository it is in).
local RETENTION_KEYS = {
    max_count = true,
    max_age_days = true,
    snapshot_days = true,
}

---@class pi.WorktreeRepoConfig
---@field path string Absolute path of the file this was read from
---@field base_ref? string `"head"`, `"fresh"` or any revision
---@field include? string[] Globs added to `.worktreeinclude`
---@field setup? string[][] Commands for the *current* platform (each an argv list)
---@field retention? table<string, number> Per-repository retention overrides

---@class pi.WorktreeRepoConfigCacheEntry
---@field stamp string `size:mtime` identity of the bytes the entry was parsed from
---@field cfg? pi.WorktreeRepoConfig
---@field err? string

--- Cache keyed by absolute file path. `false` platform override for tests.
---@type table<string, pi.WorktreeRepoConfigCacheEntry>
local cache = {}

--- Stamps whose parse error was already reported to the user, so a broken file
--- warns once per edit instead of once per worktree creation.
---@type table<string, true>
local warned = {}

---@type boolean?
local platform_override

--- Absolute path of the configuration file for a repository root.
---@param repo_root string
---@return string
function M.path(repo_root)
    return repo_root .. "/" .. FILE
end

--- True when this build runs on Windows (the `[setup] windows` selector).
---@return boolean
local function is_windows()
    if type(platform_override) == "boolean" then
        return platform_override
    end
    return package.config:sub(1, 1) == "\\"
end

---@param value any
---@return boolean
local function is_array(value)
    return type(value) == "table" and #value > 0
end

---@param value any
---@return boolean
local function all_strings(value)
    if type(value) ~= "table" then
        return false
    end
    for _, item in ipairs(value) do
        if type(item) ~= "string" or item == "" then
            return false
        end
    end
    return true
end

--- Normalize one `setup` value into a list of argv commands.
---
--- Accepted shapes, both unwrapped to `string[][]`:
---   `["npm", "ci"]`        one command
---   `[["npm", "ci"], …]`   several commands
---@param value any
---@param key string Key name, for the error message
---@return string[][]? commands
---@return string? err
local function normalize_commands(value, key)
    if type(value) ~= "table" then
        return nil, string.format("%s: expected an array of commands", key)
    end
    if all_strings(value) then
        return { value }, nil
    end
    local commands = {}
    for index, item in ipairs(value) do
        if not all_strings(item) or #item == 0 then
            return nil, string.format("%s: entry %d is not a list of non-empty strings", key, index)
        end
        commands[#commands + 1] = item
    end
    if #commands == 0 then
        return nil, string.format("%s: expected at least one command", key)
    end
    return commands, nil
end

--- Validate a decoded document. Unknown keys, wrong types and negative numbers
--- are errors: the file is reviewed like code, so a silent typo is worse than a
--- refusal.
---@param document table Decoded TOML
---@param path string Absolute path, recorded on the result
---@return pi.WorktreeRepoConfig? cfg
---@return string? err
function M._validate(document, path)
    if type(document) ~= "table" then
        return nil, "config: expected a table"
    end
    for key in pairs(document) do
        if not KNOWN_KEYS[key] then
            return nil,
                string.format("config: unknown key '%s' (known: base_ref, include, setup, retention)", tostring(key))
        end
    end

    ---@type pi.WorktreeRepoConfig
    local cfg = { path = path }

    if document.base_ref ~= nil then
        local ref = document.base_ref
        if type(ref) ~= "string" or vim.trim(ref) == "" then
            return nil, "config: base_ref must be a non-empty string"
        end
        cfg.base_ref = vim.trim(ref)
    end

    if document.include ~= nil then
        if not all_strings(document.include) or #document.include == 0 then
            return nil, "config: include must be a non-empty array of strings"
        end
        ---@type string[]
        local patterns = {}
        for _, pattern in ipairs(document.include) do
            patterns[#patterns + 1] = pattern
        end
        cfg.include = patterns
    end

    --- `[setup]` is either a plain command list (every platform) or a table of
    --- platform lists — `unix`, `windows`, `all`. The platform list wins, `all`
    --- is the shared fallback, so a repository that only cares about one
    --- platform writes one key and everyone else still gets something sane.
    if document.setup ~= nil then
        local setup = document.setup
        ---@type string[][]?
        local unix_cmds, windows_cmds, all_cmds
        if is_array(setup) then
            local commands, cmd_err = normalize_commands(setup, "setup")
            if not commands then
                return nil, "config: " .. tostring(cmd_err)
            end
            all_cmds = commands
        elseif type(setup) == "table" then
            for key, value in pairs(setup) do
                if not SETUP_KEYS[key] then
                    return nil,
                        string.format("config: unknown setup key '%s' (known: unix, windows, all)", tostring(key))
                end
                local commands, cmd_err = normalize_commands(value, "setup." .. tostring(key))
                if not commands then
                    return nil, "config: " .. tostring(cmd_err)
                end
                if key == "unix" then
                    unix_cmds = commands
                elseif key == "windows" then
                    windows_cmds = commands
                else
                    all_cmds = commands
                end
            end
        else
            return nil, "config: setup must be a command list or a table of platform lists"
        end
        -- Not the `a and b or c` idiom: on Windows `windows_cmds` is nil and
        -- that ternary would fall through to the *unix* list.
        local selected
        if is_windows() then
            selected = windows_cmds
        else
            selected = unix_cmds
        end
        cfg.setup = selected or all_cmds
    end

    if document.retention ~= nil then
        local retention = document.retention
        if type(retention) ~= "table" then
            return nil, "config: retention must be a table"
        end
        local out = {}
        for key, value in pairs(retention) do
            if not RETENTION_KEYS[key] then
                return nil,
                    string.format(
                        "config: unknown retention key '%s' (known: max_count, max_age_days, snapshot_days)",
                        tostring(key)
                    )
            end
            if type(value) ~= "number" or value < 0 then
                return nil, string.format("config: retention.%s must be a non-negative number", tostring(key))
            end
            if key == "max_count" and value % 1 ~= 0 then
                return nil, "config: retention.max_count must be an integer"
            end
            out[key] = value
        end
        if next(out) ~= nil then
            cfg.retention = out
        end
    end

    if
        next(cfg) ~= nil
        and cfg.base_ref == nil
        and cfg.include == nil
        and cfg.setup == nil
        and cfg.retention == nil
    then
        -- A file that only has comments (or an empty `[setup]` table) configures
        -- nothing: answer like a missing file rather than an empty table.
        return nil, nil
    end

    return cfg
end

--- Parse configuration text (pure; the unit-testable half of `read`).
---@param text string
---@return pi.WorktreeRepoConfig? cfg
---@return string? err
function M.parse(text)
    if type(text) ~= "string" or vim.trim(text) == "" then
        return nil, nil
    end
    local document, parse_err = Toml.decode(text)
    if not document then
        return nil, tostring(parse_err)
    end
    return M._validate(document, FILE)
end

--- Identity of the bytes on disk, so an edit invalidates the cache without a
--- read. `nil` when the file does not exist.
---@param path string
---@return string?
local function stamp_of(path)
    local st = uv.fs_stat(path)
    if not st then
        return nil
    end
    local mtime = st.mtime or {}
    return string.format("%d:%d:%d", st.size or 0, mtime.sec or 0, mtime.nsec or 0)
end

---@param path string
---@return string?
local function read_text(path)
    local fd = uv.fs_open(path, "r", 420)
    if not fd then
        return nil
    end
    local st = uv.fs_fstat(fd)
    local data = st and uv.fs_read(fd, st.size, 0) or nil
    uv.fs_close(fd)
    return data
end

--- Read (and cache) a repository's configuration.
---
--- A missing file is not an error: `(nil, nil)`. A file that cannot be parsed or
--- validated answers `(nil, err)` **and warns once per edit**, because the
--- caller is usually a creation path where failing the whole worktree over a
--- typo would be worse than ignoring the file — but silence would be worse than
--- either.
---@param repo_root string?
---@param opts? { quiet?: boolean } `quiet` suppresses the warning (retention sweep)
---@return pi.WorktreeRepoConfig? cfg
---@return string? err
function M.read(repo_root, opts)
    if type(repo_root) ~= "string" or repo_root == "" then
        return nil, nil
    end
    local path = M.path(repo_root)
    local stamp = stamp_of(path)
    if not stamp then
        cache[path] = nil
        return nil, nil
    end

    local entry = cache[path]
    if entry and entry.stamp == stamp then
        return entry.cfg, entry.err
    end

    ---@type pi.WorktreeRepoConfigCacheEntry
    local fresh = { stamp = stamp }
    local text = read_text(path)
    if text == nil then
        fresh.err = "config: cannot read " .. path
    else
        local cfg, err = M.parse(text)
        local cfg_ok = cfg
        if cfg_ok and cfg_ok.path == FILE then
            -- `parse` is path-agnostic (and tested that way); the cached entry
            -- carries the real path the caller can report.
            cfg_ok.path = path
        end
        fresh.cfg = cfg
        fresh.err = err
    end
    cache[path] = fresh

    if fresh.err then
        local key = path .. "\0" .. stamp
        if not warned[key] then
            warned[key] = true
            local line = fresh.err
            if type(opts) ~= "table" or opts.quiet ~= true then
                Notify.warn(path .. ": " .. line)
            end
        end
    end
    return fresh.cfg, fresh.err
end

--- Report, once per file stamp, that a repository declares setup commands the
--- user has not trusted (`worktree.repo_setup` off).
---
--- Silence would be the worst outcome: the repository looks set up, the checkout
--- is missing whatever those commands would have installed, and nothing says
--- why. Running them unasked is worse (a cloned repository would be executing
--- code on checkout), so the switch stays off by default and this is its voice.
---@param repo_root string?
function M.note_setup_skipped(repo_root)
    if type(repo_root) ~= "string" or repo_root == "" then
        return
    end
    local commands = M.setup_commands(repo_root)
    if #commands == 0 then
        return
    end
    local path = M.path(repo_root)
    local stamp = stamp_of(path) or ""
    local key = path .. "\0" .. stamp .. "\0setup"
    if warned[key] then
        return
    end
    warned[key] = true
    Notify.info(
        string.format(
            "%s declares %d setup command(s); not run (set `worktree.repo_setup = true` to trust this repository)",
            path,
            #commands
        )
    )
end

--- Configured base strategy of a repository, if any.
---@param repo_root string?
---@return string? base_ref
function M.base_ref(repo_root)
    local cfg = M.read(repo_root)
    return cfg and cfg.base_ref or nil
end

--- Extra `.worktreeinclude` patterns declared by the repository config.
---@param repo_root string?
---@return string[]
function M.include_patterns(repo_root)
    local cfg = M.read(repo_root)
    return (cfg and cfg.include) or {}
end

--- Setup commands for this platform (each an argv list, run in the checkout).
---@param repo_root string?
---@return string[][]
function M.setup_commands(repo_root)
    local cfg = M.read(repo_root)
    return (cfg and cfg.setup) or {}
end

--- Per-repository retention overrides (`max_count`, `max_age_days`,
--- `snapshot_days`).
---@param repo_root string?
---@return table<string, number>
function M.retention(repo_root)
    local cfg = M.read(repo_root, { quiet = true })
    return (cfg and cfg.retention) or {}
end

--- Drop every cached parse (tests, and after a file is deleted by hand).
function M._reset()
    cache = {}
    warned = {}
    platform_override = nil
end

--- Test hook: force the `[setup] unix` / `[setup] windows` selector.
---@param name "unix"|"windows"|nil
function M._set_platform(name)
    if name == "unix" then
        platform_override = false
    elseif name == "windows" then
        platform_override = true
    else
        platform_override = nil
    end
end

return M
