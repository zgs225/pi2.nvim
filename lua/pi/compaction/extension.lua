--- Runtime config file for the bundled `extensions/compaction.ts`.
---
--- The process environment is frozen at spawn, so the extension re-reads this
--- file on every compaction event: a live `setup()` call applies the new
--- options without respawning `pi` (same rationale as `pi.title` /
--- `pi.todo.tool_ui`). The file is keyed by PID because `stdpath("run")` is
--- per-user, not per-process — two nvim instances must not clobber each other.
---
--- Written with `uv.fs_*` only: publishing happens from `config.setup()` and
--- from a re-publish on focus changes, both on the editor's main loop, and it
--- must never block on a subprocess.
---
--- Every value is normalized here rather than in the extension: the TypeScript
--- side gets a shape it can trust (all keys present, numbers already clamped),
--- so an out-of-range option degrades to a usable value instead of a summariser
--- that asks for "0 words".

local Notify = require("pi.notify")

local uv = vim.uv

local M = {}

--- Languages the checkpoint summariser understands.
---@type table<string, true>
local LANGUAGES = { auto = true, english = true, conversation = true }

---@type string?
local state_path_override

---@class pi.CompactionExtensionCleanerPublished
---@field enabled boolean
---@field max_read integer
---@field max_modified integer
---@field drop_temp boolean
---@field drop_build boolean
---@field strip_previous_lists boolean

---@class pi.CompactionExtensionCheckpointPublished
---@field enabled boolean
---@field model string?
---@field thinking_level string?
---@field language "auto"|"english"|"conversation"
---@field max_words integer

---@class pi.CompactionExtensionStatePublished
---@field enabled boolean
---@field max_tokens integer

---@class pi.CompactionExtensionPrunePublished
---@field enabled boolean
---@field high_water number
---@field min_turns integer

---@class pi.CompactionExtensionOwnerPublished
---@field detect boolean

---@class pi.CompactionExtensionPublished The exact JSON shape the extension reads
---@field enabled boolean
---@field cleaner pi.CompactionExtensionCleanerPublished
---@field checkpoint pi.CompactionExtensionCheckpointPublished
---@field state pi.CompactionExtensionStatePublished
---@field prune pi.CompactionExtensionPrunePublished
---@field owner pi.CompactionExtensionOwnerPublished

---@param value any
---@return boolean
local function is_number(value)
    return type(value) == "number" and value == value
end

--- Positive integer with a fallback: a fractional number is floored, a
--- non-positive one falls back (there is no useful clamp below 1 here).
---@param value any
---@param default integer
---@return integer
local function positive_integer(value, default)
    if not is_number(value) then
        return default
    end
    local floored = math.floor(value)
    if floored < 1 then
        return default
    end
    return floored
end

--- Clamp a number into `[min, max]`; a non-number falls back to `default`.
---@param value any
---@param default number
---@param min number
---@param max number
---@return number
local function clamp(value, default, min, max)
    if not is_number(value) then
        return default
    end
    if value < min then
        return min
    end
    if value > max then
        return max
    end
    return value
end

---@param value any
---@return string?
local function optional_string(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

---@param value any
---@param default boolean
---@return boolean
local function boolean_or(value, default)
    if type(value) == "boolean" then
        return value
    end
    return default
end

---@param value any
---@return table
local function as_table(value)
    if type(value) == "table" and value ~= vim.NIL then
        return value
    end
    return {}
end

--- The normalized defaults, i.e. what a nil `cfg` publishes.
---@return pi.CompactionExtensionPublished
function M.defaults()
    return {
        enabled = true,
        cleaner = {
            enabled = true,
            max_read = 50,
            max_modified = 100,
            drop_temp = true,
            drop_build = true,
            strip_previous_lists = true,
        },
        checkpoint = {
            enabled = false,
            model = nil,
            thinking_level = nil,
            language = "auto",
            max_words = 1500,
        },
        state = {
            enabled = true,
            max_tokens = 1000,
        },
        prune = {
            enabled = false,
            high_water = 0.7,
            min_turns = 8,
        },
        owner = {
            detect = true,
        },
    }
end

--- Runtime file conveying the normalized compaction extension options to
--- already-spawned RPC processes, as JSON (see `pi.CompactionExtensionPublished`).
---@return string
function M.state_path()
    if state_path_override then
        return state_path_override
    end
    return vim.fn.stdpath("run") .. "/pi2nvim-compaction-config-" .. tostring(vim.fn.getpid())
end

--- Override the state file path (tests).
---@param path string?
function M._set_path(path)
    if type(path) == "string" and path ~= "" then
        state_path_override = path
    else
        state_path_override = nil
    end
end

--- Normalize a config tree into the published shape (all keys present).
---@param cfg pi.CompactionExtensionConfig?
---@return pi.CompactionExtensionPublished
function M._normalize(cfg)
    local root = as_table(cfg)
    local cleaner = as_table(root.cleaner)
    local checkpoint = as_table(root.checkpoint)
    local state = as_table(root.state)
    local prune = as_table(root.prune)
    local owner = as_table(root.owner)

    local language = checkpoint.language
    if type(language) ~= "string" or not LANGUAGES[language] then
        language = "auto"
    end

    local max_words = clamp(checkpoint.max_words, 1500, 200, 6000)
    local max_tokens = clamp(state.max_tokens, 1000, 100, 4000)
    local high_water = clamp(prune.high_water, 0.7, 0.3, 0.95)

    return {
        enabled = boolean_or(root.enabled, true),
        cleaner = {
            enabled = boolean_or(cleaner.enabled, true),
            max_read = positive_integer(cleaner.max_read, 50),
            max_modified = positive_integer(cleaner.max_modified, 100),
            drop_temp = boolean_or(cleaner.drop_temp, true),
            drop_build = boolean_or(cleaner.drop_build, true),
            strip_previous_lists = boolean_or(cleaner.strip_previous_lists, true),
        },
        checkpoint = {
            enabled = boolean_or(checkpoint.enabled, false),
            model = optional_string(checkpoint.model),
            thinking_level = optional_string(checkpoint.thinking_level),
            language = language,
            max_words = math.floor(max_words + 0.5),
        },
        state = {
            enabled = boolean_or(state.enabled, true),
            max_tokens = math.floor(max_tokens + 0.5),
        },
        prune = {
            enabled = boolean_or(prune.enabled, false),
            high_water = high_water,
            min_turns = math.floor(clamp(prune.min_turns, 8, 1, 100) + 0.5),
        },
        owner = {
            detect = boolean_or(owner.detect, true),
        },
    }
end

---@param path string
---@return string?
local function parent_dir(path)
    local dir = path:match("^(.*)[/\\][^/\\]*$")
    if dir and dir ~= "" then
        return dir
    end
    return nil
end

--- Create `path` and any missing parent, with libuv only.
---@param path string
---@return boolean ok
local function mkdir_p(path)
    if uv.fs_stat(path) then
        return true
    end
    local parent = parent_dir(path)
    if parent and not mkdir_p(parent) then
        return false
    end
    local ok = uv.fs_mkdir(path, 448)
    if ok then
        return true
    end
    -- EEXIST after a race (another instance publishing) is success.
    return uv.fs_stat(path) ~= nil
end

--- Write `payload` to `path` with libuv, creating missing parent directories.
---@param path string
---@param payload string
---@return boolean ok
---@return string? err
local function write_file(path, payload)
    local dir = parent_dir(path)
    if dir and not mkdir_p(dir) then
        return false, "cannot create " .. dir
    end
    local fd, open_err = uv.fs_open(path, "w", 420)
    if not fd then
        return false, tostring(open_err or "cannot open")
    end
    local ok, write_err = uv.fs_write(fd, payload, 0)
    uv.fs_close(fd)
    if not ok then
        return false, tostring(write_err or "cannot write")
    end
    return true, nil
end

--- JSON payload for a normalized tree: every key present, absent strings as
--- explicit `null` (the extension distinguishes "unset" from a missing key).
---@param normalized pi.CompactionExtensionPublished
---@return table
local function to_payload(normalized)
    return {
        enabled = normalized.enabled,
        cleaner = normalized.cleaner,
        checkpoint = {
            enabled = normalized.checkpoint.enabled,
            model = normalized.checkpoint.model or vim.NIL,
            thinking_level = normalized.checkpoint.thinking_level or vim.NIL,
            language = normalized.checkpoint.language,
            max_words = normalized.checkpoint.max_words,
        },
        state = normalized.state,
        prune = normalized.prune,
        owner = normalized.owner,
    }
end

--- Publish the configured extension options for `extensions/compaction.ts`.
---
--- Always writes the file, including for an explicit `enabled = false` and for a
--- nil `cfg`: a live `setup()` call must be able to turn the extension off (or
--- reset it to defaults) without respawning the RPC process.
---@param cfg pi.CompactionExtensionConfig?
function M.publish(cfg)
    local payload = to_payload(M._normalize(cfg))
    local ok, encoded = pcall(vim.json.encode, payload)
    if not ok then
        Notify.warn("compaction: cannot encode the extension config: " .. tostring(encoded))
        return
    end
    local written, err = write_file(M.state_path(), encoded)
    if not written then
        Notify.warn("compaction: cannot publish the extension config to " .. M.state_path() .. ": " .. tostring(err))
    end
end

--- The published options, if the file exists and decodes (mirrors what the
--- extension sees).
---@return pi.CompactionExtensionPublished?
function M.published()
    local path = M.state_path()
    local fd = uv.fs_open(path, "r", 420)
    if not fd then
        return nil
    end
    local st = uv.fs_fstat(fd)
    local content = (st and st.size and uv.fs_read(fd, st.size, 0)) or nil
    uv.fs_close(fd)
    if type(content) ~= "string" then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" or decoded == vim.NIL then
        return nil
    end
    -- Re-normalize: the file may have been written by an older version (or by
    -- hand), and readers should get the same shape `publish` would have written.
    return M._normalize(decoded)
end

--- Drop the path override (tests).
function M._reset()
    state_path_override = nil
end

return M
