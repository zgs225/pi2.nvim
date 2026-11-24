--- Focus picker for a manual compaction (bare `:PiCompact`).
---
--- The menu offers the five presets, then the focus texts this session already
--- used (newest first, `↺ `), then an inline "Custom focus…" input, then an
--- explicit "no focus" row — so the user can always say what the summarizer
--- must keep, or say nothing at all.
---
--- The context line above the menu is derived from `get_session_stats` (usage
--- percent + window) and the resolved compaction budget. That request is
--- deliberately fire-and-forget: opening the dialog must never wait for the
--- backend, so the first open shows the generic line and the numbers appear the
--- next time the dialog opens (the cached payload is per session).

---@class pi.CompactionFocusDialog
---@field open fun() Open the focus picker for the current session.
---@field presets fun(): string[] The five focus presets, in menu order.
---@field _reset fun() Drop the cached context numbers (tests).

local M = {}

--- The five focus presets, in menu order.
---@type string[]
local PRESETS = {
    "Preserve architectural decisions",
    "Drop intermediate tool outputs",
    "Preserve test failures and exact errors",
    "Preserve user constraints and rejected approaches",
    "Keep next steps and open questions",
}

--- Shown until a `get_session_stats` answer is cached.
local FALLBACK_MESSAGE = "Current context will be summarized; the most recent turns are kept."

local CUSTOM = "Custom focus…"
local NO_FOCUS = "No focus (summarize everything)"
local HISTORY_PREFIX = "↺ "

--- One menu row's effect.
---@class pi.CompactionDialogAction
---@field text? string Focus text to compact with (nil = no focus)
---@field custom? boolean Ask for the text inline instead

--- Last `get_session_stats` payload, kept only to build the next open's line.
---@type table?
local cached_stats = nil
---@type string? Session id the cached payload belongs to.
local cached_session = nil
---@type boolean A stats request is in flight.
local stats_pending = false

--- Ask the backend for the session's context usage, best-effort and never
--- blocking: the answer only lands in the cache for the next open, and each
--- open refreshes it so the numbers cannot go stale while the dialog is used.
---@param session pi.Session
local function request_stats(session)
    if stats_pending then
        return
    end
    local rpc = session.rpc
    if not rpc or not rpc:is_running() then
        return
    end
    stats_pending = true
    rpc:send({ type = "get_session_stats" }, function(res)
        stats_pending = false
        if res and res.success and type(res.data) == "table" then
            cached_stats = res.data
            cached_session = session.id
        end
    end)
end

--- The one-line context summary above the menu: `context <pct>% of <window> ·
--- keep ~<keep> · <threshold> to compact`, or the generic fallback while the
--- numbers are unknown.
---@param session pi.Session
---@return string
local function context_message(session)
    local stats = cached_stats
    if not stats or cached_session ~= session.id then
        return FALLBACK_MESSAGE
    end

    local usage = type(stats.contextUsage) == "table" and stats.contextUsage or nil
    local model_state = session.model_state
    local model = type(model_state) == "table" and model_state.model or nil
    local window = tonumber(usage and usage.contextWindow or nil)
        or tonumber(type(model) == "table" and model.contextWindow or nil)
    local percent = tonumber(usage and usage.percent or nil)
    if not window or not percent then
        return FALLBACK_MESSAGE
    end

    local Settings = require("pi.compaction.settings")
    local effective = Settings.resolve(
        session.cwd or session._process_cwd,
        type(model) == "table" and model.provider or nil,
        type(model) == "table" and model.id or nil
    )
    local budget = Settings.budget(effective, window)
    if not budget then
        return FALLBACK_MESSAGE
    end

    local format_tokens = require("pi.stats").format_tokens
    return string.format(
        "context %d%% of %s · keep ~%s · %s to compact",
        math.floor(percent),
        format_tokens(budget.window),
        format_tokens(budget.keep),
        format_tokens(budget.threshold)
    )
end

--- The five presets offered by the dialog, in menu order.
---@return string[]
function M.presets()
    return vim.deepcopy(PRESETS)
end

--- Drop the cached context numbers (tests, and after a compaction).
function M._reset()
    cached_stats = nil
    cached_session = nil
    stats_pending = false
end

--- Open the focus picker. Each choice compacts the current session through
--- `pi.compact`; cancelling any step leaves the session untouched.
function M.open()
    local Notify = require("pi.notify")
    local Sessions = require("pi.sessions.manager")
    local session = Sessions.get()
    if not session then
        Notify.warn("No active session")
        return
    end

    local state = Sessions.get_compaction_state(session)

    ---@type table<string, pi.CompactionDialogAction>
    local actions = {}
    ---@type string[]
    local options = {}

    for _, preset in ipairs(PRESETS) do
        options[#options + 1] = preset
        actions[preset] = { text = preset }
    end

    for _, text in ipairs(state and state.focus_history or {}) do
        local label = HISTORY_PREFIX .. text
        if not actions[label] then
            options[#options + 1] = label
            actions[label] = { text = text }
        end
    end

    options[#options + 1] = CUSTOM
    actions[CUSTOM] = { custom = true }
    options[#options + 1] = NO_FOCUS
    actions[NO_FOCUS] = {}

    local message = context_message(session)
    request_stats(session)

    require("pi.ui.dialog").select({
        title = "Compact with focus",
        message = message,
        options = options,
        kind = "compaction_focus",
    }, function(choice)
        local action = type(choice) == "string" and actions[choice] or nil
        if not action then
            return
        end
        if action.custom then
            require("pi.ui.dialog").input({
                title = "Compaction focus",
                default = state and state.last_focus or "",
                multiline = false,
            }, function(value)
                if value == nil then
                    return
                end
                local focus = vim.trim(value)
                require("pi").compact(focus ~= "" and focus or nil)
            end)
            return
        end
        require("pi").compact(action.text)
    end)
end

return M
