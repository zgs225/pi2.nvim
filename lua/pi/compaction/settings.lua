--- pi's own compaction settings, resolved for this session and cached per file stamp.
---
--- pi keeps its compaction knobs in two JSON files (pi ≥ 1.6):
---
---   <agent_dir>/settings.json        global   (agent_dir = Config.options.agent_dir,
---                                               $PI_CODING_AGENT_DIR, ~/.pi/agent)
---   <cwd>/.pi/settings.json          project  (wins per key over the global file)
---
--- ```json
--- {"compaction":{"enabled":true,"reserveTokens":16384,"keepRecentTokens":20000,
---  "modelOverrides":{"openai/gpt-5":{"reserveTokens":10000}}}}
--- ```
---
--- Two rules shape this module:
---
--- - **Never throws, never blocks.** The callers are a statusline component and
---   the session/compaction path, so a malformed file must degrade to the next
---   layer with `source = "invalid"` and a dotted path the user can act on, not
---   an error. Nothing is read at `require` time; the cache is keyed by the
---   file's `size:mtime.sec:mtime.nsec` stamp, so an edit is picked up on the
---   next call and an untouched file is never re-read (G20: options are read at
---   call time, never captured at load).
--- - **Only `uv.fs_*`.** `resolve` runs on every statusline refresh; a
---   subprocess or `vim.fn.readfile` there would be a per-redraw syscall storm.
---
--- Layer order per field is `modelOverrides[<provider>/<id>] -> settings
--- (project, then global) -> default`. A value that is present but is not a
--- positive integer is *invalid*: the next layer answers for that field and the
--- effective settings keep `source = "invalid"` plus the first dotted offending
--- path. Only layers actually consulted are inspected, so a broken entry for a
--- different model does not taint this session's settings.

local Config = require("pi.config")
local Json = require("pi.json")
local Notify = require("pi.notify")

local uv = vim.uv

local M = {}

---@class pi.CompactionEffectiveSettings
---@field reserve integer Tokens pi leaves free for the response (`compaction.reserveTokens`)
---@field keep integer Tokens of recent conversation kept verbatim (`compaction.keepRecentTokens`)
---@field enabled boolean Whether pi's automatic compaction is armed (`compaction.enabled`)
---@field source "default"|"settings"|"override"|"invalid" Which layer answered (invalid wins over all)
---@field invalid? string Dotted path of the first invalid value met while resolving, e.g. "compaction.reserveTokens"
---@field model_override? boolean True when `compaction.modelOverrides` matched this exact model

---@class pi.CompactionBudget
---@field window integer Context window of the session's model, in tokens
---@field reserve integer Effective `reserveTokens`
---@field keep integer Effective `keepRecentTokens`
---@field threshold integer `window - reserve`: the occupancy at which pi's auto-compaction triggers
---@field pathological boolean `keep >= threshold`, i.e. nothing is cuttable; automatic compaction cannot help
---@field enabled boolean Whether automatic compaction is armed at all
---@field invalid? string Forwarded from the effective settings

--- pi's documented defaults (no file, no override).
---@type { reserve: integer, keep: integer }
M.DEFAULTS = { reserve = 16384, keep = 20000 }

---@class pi.CompactionOverrideEntry
---@field reserve? integer
---@field keep? integer
---@field invalid? string The entry itself is not an object (e.g. `"modelOverrides": {"a/b": 5}`)
---@field reserve_invalid? string `reserveTokens` was present but invalid
---@field keep_invalid? string `keepRecentTokens` was present but invalid

---@class pi.CompactionSettingsFile
---@field present boolean The file exists on disk
---@field reserve? integer
---@field keep? integer
---@field enabled? boolean
---@field overrides table<string, pi.CompactionOverrideEntry>
---@field invalid string[] Dotted paths of invalid values, in document order (empty when clean)

---@class pi.CompactionCandidate One layer that may answer for one field
---@field value any
---@field invalid string[]
---@field override boolean True when this layer is `compaction.modelOverrides`

---@class pi.CompactionSettingsCacheEntry
---@field stamp string `size:mtime.sec:mtime.nsec` identity of the bytes this entry was parsed from ("" = missing)
---@field file pi.CompactionSettingsFile

--- Cache keyed by absolute file path.
---@type table<string, pi.CompactionSettingsCacheEntry>
local cache = {}

--- Files whose invalid content was already reported, keyed by `path\0stamp\0path`.
---@type table<string, true>
local warned = {}

--- Test hook: pin the agent directory (`M._set_agent_dir`).
---@type string?
local agent_dir_override

---@return pi.CompactionSettingsFile
local function empty_file(present)
    return { present = present, overrides = {}, invalid = {} }
end

---@param value any
---@return boolean
local function is_positive_integer(value)
    return type(value) == "number" and value >= 1 and value % 1 == 0 and value < math.huge
end

---@param table_to_sort table
---@return string[]
local function sorted_keys(table_to_sort)
    ---@type string[]
    local keys = {}
    for key in pairs(table_to_sort) do
        if type(key) == "string" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    return keys
end

---@param value any
---@return boolean
local function is_absent(value)
    return value == nil or value == vim.NIL
end

---@param value any
---@param invalid_path string
---@param file pi.CompactionSettingsFile
---@return integer?
local function take_positive_integer(value, invalid_path, file)
    if is_absent(value) then
        return nil
    end
    if is_positive_integer(value) then
        return value
    end
    file.invalid[#file.invalid + 1] = invalid_path
    return nil
end

--- Parse one decoded settings document into the compaction slice we care about.
--- Never throws: every shape/type problem is recorded as a dotted path and the
--- value is dropped, so the resolver falls through to the next layer.
---@param document any Decoded JSON (anything; not necessarily a table)
---@return pi.CompactionSettingsFile
local function parse_document(document)
    ---@type pi.CompactionSettingsFile
    local file = empty_file(true)
    if type(document) ~= "table" or document == vim.NIL then
        -- Unparseable JSON and a non-object root both land here: there is no
        -- field-level path to name, so the section itself is the invalid path.
        file.invalid[#file.invalid + 1] = "compaction"
        return file
    end
    local section = document.compaction
    if is_absent(section) then
        return file
    end
    if type(section) ~= "table" or section == vim.NIL then
        file.invalid[#file.invalid + 1] = "compaction"
        return file
    end

    file.reserve = take_positive_integer(section.reserveTokens, "compaction.reserveTokens", file)
    file.keep = take_positive_integer(section.keepRecentTokens, "compaction.keepRecentTokens", file)

    if not is_absent(section.enabled) then
        if type(section.enabled) == "boolean" then
            file.enabled = section.enabled
        else
            file.invalid[#file.invalid + 1] = "compaction.enabled"
        end
    end

    local overrides = section.modelOverrides
    if is_absent(overrides) then
        return file
    end
    if type(overrides) ~= "table" or overrides == vim.NIL then
        file.invalid[#file.invalid + 1] = "compaction.modelOverrides"
        return file
    end
    for _, key in ipairs(sorted_keys(overrides)) do
        local base = "compaction.modelOverrides." .. key
        ---@type pi.CompactionOverrideEntry
        local entry = {}
        local raw = overrides[key]
        if type(raw) ~= "table" or raw == vim.NIL then
            entry.invalid = base
        else
            ---@type pi.CompactionSettingsFile
            local scratch = empty_file(true)
            entry.reserve = take_positive_integer(raw.reserveTokens, base .. ".reserveTokens", scratch)
            entry.keep = take_positive_integer(raw.keepRecentTokens, base .. ".keepRecentTokens", scratch)
            entry.reserve_invalid = scratch.invalid[1]
            entry.keep_invalid = scratch.invalid[2]
        end
        file.overrides[key] = entry
    end
    return file
end

--- Identity of the bytes on disk, so an edit invalidates the cache without a read.
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

--- Read a whole file with libuv only (no subprocess, no `vim.fn.readfile`).
---@param path string
---@return string?
local function read_text(path)
    local fd = uv.fs_open(path, "r", 420)
    if not fd then
        return nil
    end
    local st = uv.fs_fstat(fd)
    local data = (st and st.size and uv.fs_read(fd, st.size, 0)) or nil
    uv.fs_close(fd)
    return data
end

--- Read (and cache) one settings file. A missing file is cached as missing.
---@param path string
---@return pi.CompactionSettingsFile
local function load_file(path)
    local stamp = stamp_of(path)
    local entry = cache[path]
    if not stamp then
        -- A missing file is cached as missing: the statusline asks on every
        -- refresh and "no settings.json" is the common case.
        if entry and entry.stamp == "" then
            return entry.file
        end
        ---@type pi.CompactionSettingsCacheEntry
        local missing = { stamp = "", file = empty_file(false) }
        cache[path] = missing
        return missing.file
    end
    if entry and entry.stamp == stamp then
        return entry.file
    end

    ---@type pi.CompactionSettingsFile
    local file
    local text = read_text(path)
    if not text then
        file = empty_file(false)
    else
        local document = Json.decode(text)
        file = parse_document(document)
    end

    if #file.invalid > 0 then
        local key = path .. "\0" .. stamp .. "\0" .. file.invalid[1]
        if not warned[key] then
            warned[key] = true
            Notify.warn(
                string.format("compaction settings: %s in %s is invalid; using the next layer", file.invalid[1], path)
            )
        end
    end

    ---@type pi.CompactionSettingsCacheEntry
    local fresh = { stamp = stamp, file = file }
    cache[path] = fresh
    return file
end

--- Resolve pi's agent directory (override -> config -> env -> `~/.pi/agent`).
---@return string
local function agent_dir()
    if type(agent_dir_override) == "string" and agent_dir_override ~= "" then
        return agent_dir_override
    end
    local configured = Config.options.agent_dir
    if type(configured) == "string" and configured ~= "" then
        return configured
    end
    local env = vim.env.PI_CODING_AGENT_DIR
    if type(env) == "string" and env ~= "" then
        return env
    end
    return vim.fn.expand("~/.pi/agent")
end

---@param cwd string
---@return string
local function project_path(cwd)
    return (cwd:gsub("[/\\]+$", "")) .. "/.pi/settings.json"
end

--- Resolve the compaction settings that apply to a workspace/model.
---
--- `cwd` is the session's working directory: a nil/empty value skips the
--- project layer (the caller is expected to know its workspace). `provider` and
--- `model_id` select `compaction.modelOverrides["<provider>/<modelId>"]` by exact
--- match; either being absent disables the override layer.
---@param cwd string?
---@param provider string?
---@param model_id string?
---@return pi.CompactionEffectiveSettings
function M.resolve(cwd, provider, model_id)
    local global = load_file(agent_dir() .. "/settings.json")
    local project = empty_file(false)
    if type(cwd) == "string" and cwd ~= "" then
        project = load_file(project_path(cwd))
    end

    ---@type string?
    local key
    if type(provider) == "string" and provider ~= "" and type(model_id) == "string" and model_id ~= "" then
        key = provider .. "/" .. model_id
    end

    ---@type string[]
    local invalid = {}
    ---@type table<string, true>
    local seen = {}

    ---@param path any
    local function record(path)
        if type(path) == "string" and path ~= "" and not seen[path] then
            seen[path] = true
            invalid[#invalid + 1] = path
        end
    end

    ---@param list string[]
    local function record_all(list)
        for _, path in ipairs(list) do
            record(path)
        end
    end

    -- Every file that was loaded has been consulted for every field, so its
    -- document-level problems are reported regardless of which layer answers:
    -- a typo is worth naming even when a model override hides its effect.
    -- Per-entry problems stay entry-local, so a broken override for a model
    -- this session does not run never taints it.
    record_all(project.invalid)
    record_all(global.invalid)

    ---@param name "reserve"|"keep"
    ---@param default integer
    ---@return integer value
    ---@return boolean from_override
    ---@return boolean from_settings
    local function pick_number(name, default)
        ---@type pi.CompactionCandidate[]
        local candidates = {}
        local function add_override(file)
            if not key then
                return
            end
            local entry = file.overrides[key]
            if not entry then
                return
            end
            local problems = {}
            if entry.invalid then
                problems[#problems + 1] = entry.invalid
            end
            local field_invalid = name == "reserve" and entry.reserve_invalid or entry.keep_invalid
            if field_invalid then
                problems[#problems + 1] = field_invalid
            end
            candidates[#candidates + 1] = {
                value = name == "reserve" and entry.reserve or entry.keep,
                invalid = problems,
                override = true,
            }
        end
        add_override(project)
        add_override(global)
        candidates[#candidates + 1] = { value = project[name], invalid = {}, override = false }
        candidates[#candidates + 1] = { value = global[name], invalid = {}, override = false }

        for _, candidate in ipairs(candidates) do
            record_all(candidate.invalid)
            if type(candidate.value) == "number" then
                return candidate.value, candidate.override, not candidate.override
            end
        end
        return default, false, false
    end

    ---@return boolean value
    ---@return boolean from_settings
    local function pick_enabled()
        ---@type pi.CompactionCandidate[]
        local candidates = {
            { value = project.enabled, invalid = {}, override = false },
            { value = global.enabled, invalid = {}, override = false },
        }
        for _, candidate in ipairs(candidates) do
            record_all(candidate.invalid)
            if type(candidate.value) == "boolean" then
                return candidate.value, true
            end
        end
        return true, false
    end

    local reserve, reserve_override, reserve_settings = pick_number("reserve", M.DEFAULTS.reserve)
    local keep, keep_override, keep_settings = pick_number("keep", M.DEFAULTS.keep)
    local enabled, enabled_settings = pick_enabled()

    ---@type "default"|"settings"|"override"|"invalid"
    local source
    if #invalid > 0 then
        source = "invalid"
    elseif reserve_override or keep_override then
        source = "override"
    elseif reserve_settings or keep_settings or enabled_settings then
        source = "settings"
    else
        source = "default"
    end

    local matched = key ~= nil and (project.overrides[key] ~= nil or global.overrides[key] ~= nil)

    return {
        reserve = reserve,
        keep = keep,
        enabled = enabled,
        source = source,
        invalid = invalid[1],
        model_override = matched or nil,
    }
end

--- Derive the number the statusline and the auto-compaction hint need from an
--- effective-settings record.
---
--- `threshold` is the occupancy at which pi's automatic compaction fires. When
--- `keep >= threshold` nothing is cuttable — every turn exceeds the window again
--- immediately — which is the pathological combination behind pi #12076, so it is
--- flagged rather than silently hinted at.
---@param effective pi.CompactionEffectiveSettings?
---@param window integer? The model's context window, in tokens
---@return pi.CompactionBudget? budget `nil` when `window` is not a usable number
function M.budget(effective, window)
    if type(effective) ~= "table" then
        return nil
    end
    if type(window) ~= "number" or window ~= window then
        return nil
    end
    local size = math.floor(window)
    if size < 1 then
        return nil
    end
    local reserve = type(effective.reserve) == "number" and effective.reserve or M.DEFAULTS.reserve
    local keep = type(effective.keep) == "number" and effective.keep or M.DEFAULTS.keep
    local enabled = effective.enabled ~= false
    local threshold = size - reserve
    return {
        window = size,
        reserve = reserve,
        keep = keep,
        threshold = threshold,
        pathological = enabled and keep >= threshold,
        enabled = enabled,
        invalid = effective.invalid,
    }
end

--- Drop every cached parse and warn-once mark, and restore the agent directory
--- resolution (tests, and after a settings file is moved by hand).
function M._reset()
    cache = {}
    warned = {}
    agent_dir_override = nil
end

--- Test hook: pin the agent directory. `nil` restores the
--- config/env/`~/.pi/agent` resolution.
---@param path string?
function M._set_agent_dir(path)
    if type(path) == "string" and path ~= "" then
        agent_dir_override = path
    else
        agent_dir_override = nil
    end
end

return M
