--- Sessions overview (:PiSessions) — a live list of all active pi sessions.
---
--- One shared scratch buffer lists every active session (one per Neovim tab)
--- with its display name and status (busy / compacting / idle / attention).
--- The buffer is global: each tab that opens the list gets its own window on
--- the same buffer, so content and highlights are shared and a single redraw
--- updates every view at once. Window geometry is per-tab.
---
--- Updates are event-driven: the session manager and the attention module
--- call request_refresh() on lifecycle transitions. Redraws are coalesced via
--- vim.schedule and only run while a list window is visible.

local M = {}

local Config = require("pi.config")
local Ft = require("pi.filetypes")
local Highlights = require("pi.ui.highlights")
local ChildFilter = require("pi.subsessions.sessions_list")

local ns = vim.api.nvim_create_namespace("pi-sessions-list")

--- When true, :PiSessions shows filtered-out sub-session rows (dormant, settled, etc.).
local show_hidden_children = false

---@alias pi.SessionsListStatus "busy"|"compacting"|"idle"|"exited"

---@class pi.SessionsListRow
---@field tab? pi.TabId
---@field session_id? string
---@field child_id? string Manifest child id when no live session
---@field depth integer 0 = parent tab row, 1 = sub-session
---@field status pi.SessionsListStatus
---@field attention integer pending attention request count
---@field done boolean last turn finished while the user was elsewhere
---@field error boolean last turn failed and the user hasn't seen it yet
---@field name string? display name (nil while still fetching)
---@field title_generating boolean backend auto-title generation in progress
---@field subtitle? string model · thinking badge for sub-rows
---@field dormant? boolean process not running (disk only)
---@field session? pi.Session live session reference when available
---@field is_current_view? boolean row is the tab's focused session (parent or child)
---@field is_tree_parent? boolean parent row shown while viewing a child in the tab
---@field marker_col? integer 1-based byte column of the status dot (for current-tab marker)
---@field marker_len? integer byte length of the status dot glyph

---@type integer? shared list buffer
local buf = nil

---@type table<pi.TabId, integer> list window per tab
local wins = {}

---@type pi.SessionsListRow[] rows of the last render (index == buffer line)
local rows = {}

--- Per-session name cache. Weak keys drop entries together with dead
--- sessions. A string entry marks a fetch in flight.
---   name:          backend sessionName (false = fetched, none set)
---   first_message: fallback from the session file (false = none)
---@type table<pi.Session, { name: string|false, first_message: string|false, pending: boolean? }|string>
local name_cache = setmetatable({}, { __mode = "k" })

local refresh_scheduled = false

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

--- Current status of a session.
---@param session pi.Session
---@return pi.SessionsListStatus
function M.status_of(session)
    if not session.rpc:is_running() then
        return "exited"
    end
    if session.chat then
        if session.chat:is_compacting() then
            return "compacting"
        end
        if session.chat:is_streaming() then
            return "busy"
        end
        return "idle"
    end
    if session._detached_compacting then
        return "compacting"
    end
    if session._detached_busy then
        return "busy"
    end
    return "idle"
end

---@param row pi.SessionsListRow
---@return boolean
local function is_child_row(row)
    return row.depth ~= nil and row.depth > 0
end

--- Status dot colors for sub-session rows (depth > 0).
--- Active (`is_current_view`) uses the current-tab blue overlay in
--- `refresh_current_markers`; this function supplies the buffer-level base.
---@param row pi.SessionsListRow
---@param tick integer
---@return string
local function child_dot_hl(row, tick)
    local active = row.is_current_view == true

    if row.status == "exited" or row.dormant then
        return "PiSessionsListIdle"
    end
    if row.error then
        if active then
            return "PiSessionsListError"
        end
        return tick % 2 == 0 and "PiSessionsListError" or "PiSessionsListDotDim"
    end
    if row.done then
        if active then
            return "PiSessionsListDone"
        end
        return tick % 2 == 0 and "PiSessionsListDone" or "PiSessionsListDotDim"
    end
    if row.status == "busy" or row.status == "compacting" then
        return tick % 2 == 0 and "PiSessionsListBusy" or "PiSessionsListDotDim"
    end
    return "PiSessionsListIdle"
end

--- Highlight group of a row's status dot at a given animation tick.
--- Busy blinks every tick, compacting at half speed; attention, idle and
--- exited are steady (their color alone carries the state).
--- Sub-session rows follow a separate active/inactive matrix; see child_dot_hl.
---@param row pi.SessionsListRow
---@param tick integer
---@return string
function M.dot_hl(row, tick)
    if is_child_row(row) then
        return child_dot_hl(row, tick)
    end
    if row.status == "exited" then
        return "PiSessionsListExited"
    end
    if row.error then
        return tick % 2 == 0 and "PiSessionsListError" or "PiSessionsListDotDim"
    end
    if row.attention > 0 then
        return "PiStatusLineAttention"
    end
    if row.done then
        return tick % 2 == 0 and "PiSessionsListDone" or "PiSessionsListDotDim"
    end
    if row.status == "busy" then
        return tick % 2 == 0 and "PiSessionsListBusy" or "PiSessionsListDotDim"
    end
    if row.status == "compacting" then
        return math.floor(tick / 2) % 2 == 0 and "PiSessionsListCompacting" or "PiSessionsListDotDim"
    end
    return "PiSessionsListIdle"
end

--- Extension status key the auto-title extension uses while generating a
--- session name (extensions/title.ts). Any non-empty value = generating.
local TITLE_STATUS_KEY = "pi-title"

--- Whether the backend is currently generating a session name for a session.
---@param session pi.Session
---@return boolean
local function title_generating(session)
    local read = session.chat and session.chat.extension_status
    if type(read) ~= "function" then
        return false
    end
    local value = read(session.chat, TITLE_STATUS_KEY)
    return value ~= nil and value ~= ""
end

--- Spinner frames for the auto-title animation, rendered in place of the
--- pending placeholder while the backend generates a session name.
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Spinner frame at an animation tick (pure; drives the test hook too).
---@param tick integer
---@return string
function M.spinner_frame(tick)
    return SPINNER_FRAMES[(tick % #SPINNER_FRAMES) + 1]
end

--- Format a row: the status dot at the left edge, the name right after it.
--- While the backend generates a title the pending placeholder is animated.
--- Chunks are byte ranges: { col_start, col_end, hl_group }.
---@param row pi.SessionsListRow
---@param tick integer
---@return string line
---@return integer[][] chunks
function M.format_line(row, tick)
    local indent = row.depth and row.depth > 0 and "  " or " "
    local branch = row.depth and row.depth > 0 and "└─ " or ""
    local dot = row.dormant and "◌" or "●"
    local name = row.name or "…"
    local pending = row.name == nil
    local subtitle = row.subtitle and (" · " .. row.subtitle) or ""
    local provisional = pending or name == "(unnamed)"
    local spinner = row.title_generating and provisional and M.spinner_frame(tick)
    local line = indent .. branch .. dot .. " " .. (spinner and spinner .. " " or "") .. name .. subtitle
    local prefix = indent .. branch
    local dot_start = #prefix
    local name_start = dot_start + #dot + 1 + (spinner and #spinner + 1 or 0)
    local chunks = {
        { dot_start, dot_start + #dot, M.dot_hl(row, tick) },
        { name_start, name_start + #name + #subtitle, pending and "PiSessionsListPending" or "Normal" },
    }
    if spinner then
        table.insert(chunks, 2, { name_start - #spinner - 1, name_start - 1, "PiSessionsListSpinner" })
    end
    return line, chunks
end

--- Child rows whose completion green blink was acknowledged by the user.
---@type table<string, true>
local child_completion_seen = {}

--- Acknowledge a sub-session's completion notification (stops the green blink).
---@param child_id string
function M.mark_child_completion_seen(child_id)
    if type(child_id) ~= "string" or child_id == "" then
        return
    end
    if not child_completion_seen[child_id] then
        child_completion_seen[child_id] = true
        M.request_refresh()
    end
end

--- Acknowledge completed sub-sessions whose report was already injected into the parent.
--- Called on TabEnter while viewing the parent (mirrors parent `clear_flags` for children).
---@param parent pi.Session
function M.acknowledge_reported_children(parent)
    if not parent then
        return
    end
    local Manifest = require("pi.subsessions.manifest")
    local lineage = Manifest.lineage_for_session(parent)
    if lineage == "" then
        return
    end
    local changed = false
    for _, entry in ipairs(Manifest.children_of(lineage)) do
        local child_id = entry._id
        if entry.status == "completed" and entry.reported and type(child_id) == "string" and child_id ~= "" then
            if not child_completion_seen[child_id] then
                child_completion_seen[child_id] = true
                changed = true
            end
        end
    end
    if changed then
        M.request_refresh()
    end
end

--- Acknowledge reported children when `parent` is the focused session on the current tab.
---@param parent pi.Session?
function M.acknowledge_reported_children_for_current_tab(parent)
    if not parent or parent.view_parent_id then
        return
    end
    local tab = parent.attached_tab
    if not tab or tab ~= vim.api.nvim_get_current_tabpage() then
        return
    end
    M.acknowledge_reported_children(parent)
end

---@param out pi.SessionsListRow[]
---@param entry pi.SubsessionManifestEntry
---@param tab pi.TabId
---@param opts { is_current_view?: boolean }
local function append_child_row(out, entry, tab, opts)
    local Sessions = require("pi.sessions.manager")
    local child_id = entry._id
    local child = child_id and Sessions.get_by_id(child_id)
    local cfg = entry.config or {}
    local model = cfg.model
    local subtitle = model and (model.id .. (cfg.thinking_level and (" · " .. cfg.thinking_level) or "")) or ""
    local dormant = entry.status == "dormant" or (child and not child.rpc:is_running())
    out[#out + 1] = {
        tab = tab,
        child_id = child_id,
        session_id = child_id,
        depth = 1,
        status = dormant and "exited" or (child and M.status_of(child) or "idle"),
        attention = 0,
        -- Sub-session rows never use the parent-style green "done" blink; completion is
        -- surfaced in the parent chat instead. `child_completion_seen` only controls list visibility.
        done = false,
        error = entry.status == "failed",
        name = entry.name,
        title_generating = false,
        subtitle = subtitle,
        dormant = dormant,
        session = child,
        is_current_view = opts.is_current_view == true,
    }
end

---@return pi.SessionsListChildFilterCtx
local function child_filter_ctx()
    local Sessions = require("pi.sessions.manager")
    return {
        completion_seen = function(id)
            return child_completion_seen[id] == true
        end,
        process_running = function(id)
            local child = Sessions.get_by_id(id)
            return child ~= nil and child.rpc:is_running()
        end,
    }
end

--- Append manifest child rows that pass the sessions-list visibility filter.
---@param out pi.SessionsListRow[]
---@param parent_sess pi.Session?
---@param tab pi.TabId
---@param current_child_id? string
local function append_visible_children(out, parent_sess, tab, current_child_id)
    if not parent_sess then
        return
    end
    local Manifest = require("pi.subsessions.manifest")
    local lineage = Manifest.lineage_for_session(parent_sess)
    if lineage == "" then
        return
    end
    local epoch = parent_sess.conversation_epoch or 0
    local ctx = child_filter_ctx()
    for _, entry in ipairs(Manifest.children_of(lineage)) do
        local child_id = entry._id
        local is_current = type(current_child_id) == "string" and child_id == current_child_id
        local same_epoch = (entry.parent_epoch or 0) == epoch
        local visible = is_current or show_hidden_children or (same_epoch and ChildFilter.child_visible(entry, ctx))
        if visible then
            append_child_row(out, entry, tab, { is_current_view = is_current })
        end
    end
end

--- Toggle whether hidden sub-session rows are shown in :PiSessions.
---@return boolean new_state
function M.toggle_show_hidden_children()
    show_hidden_children = not show_hidden_children
    M.request_refresh()
    return show_hidden_children
end

---@return boolean
function M.show_hidden_children()
    return show_hidden_children
end

--- Build a parent (depth 0) row for a live session process.
---@param out pi.SessionsListRow[]
---@param session pi.Session
---@param tab pi.TabId
---@param opts { is_current_view?: boolean, is_tree_parent?: boolean, name?: string? }
local function append_parent_row(out, session, tab, opts, attention_count, name_of, flags_of, generating_of)
    local sid = session.id
    local f = flags_of and flags_of(session) or nil
    out[#out + 1] = {
        tab = tab,
        session_id = sid,
        depth = 0,
        status = M.status_of(session),
        attention = attention_count(session.tab or 0) or 0,
        done = f ~= nil and f.done == true,
        error = f ~= nil and f.error == true,
        name = opts.name or name_of(session),
        title_generating = generating_of ~= nil and generating_of(session) == true,
        session = session,
        is_current_view = opts.is_current_view == true,
        is_tree_parent = opts.is_tree_parent == true,
    }
end

--- Fallback display name for a detached parent process (no tab chat).
---@param session pi.Session
---@return string?
local function name_from_session_file(session)
    if type(session.session_file) ~= "string" or session.session_file == "" then
        return nil
    end
    local info = require("pi.sessions.history").parse(session.session_file)
    if not info then
        return nil
    end
    if info.name and info.name ~= "" then
        return info.name
    end
    if info.first_message and info.first_message ~= "" then
        return info.first_message
    end
    return nil
end

--- Build display rows from live sessions.
---@param sessions pi.Session[]
---@param attention_count fun(tab: pi.TabId): integer
---@param name_of fun(session: pi.Session): string?
---@param flags_of? fun(session: pi.Session): { done: boolean, error: boolean }
---@param generating_of? fun(session: pi.Session): boolean
---@return pi.SessionsListRow[]
function M.build_rows(sessions, attention_count, name_of, flags_of, generating_of)
    local Sessions = require("pi.sessions.manager")
    ---@type pi.SessionsListRow[]
    local out = {}
    for _, session in ipairs(sessions) do
        local tab = session.tab
        local root_id = session.view_parent_id or session.id
        local in_child_view = session.view_parent_id ~= nil

        if in_child_view and root_id then
            local parent_sess = Sessions.get_by_id(root_id)
            if parent_sess then
                append_parent_row(out, parent_sess, tab, {
                    is_current_view = false,
                    is_tree_parent = true,
                    name = name_of(parent_sess) or name_from_session_file(parent_sess),
                }, attention_count, name_of, flags_of, generating_of)
            end
            append_visible_children(out, parent_sess, tab, session.id)
        else
            append_parent_row(
                out,
                session,
                tab,
                { is_current_view = true },
                attention_count,
                name_of,
                flags_of,
                generating_of
            )
            append_visible_children(out, session, tab, nil)
        end
    end
    return out
end

-- Turn flags (done / error) -----------------------------------------------------

---@type fun(session: pi.Session)
local fetch_name

--- Per-session turn flags, weak-keyed like the name cache.
---   done:  the agent finished a turn while the session's tab was not current;
---          cleared when the user enters the tab (or a new turn starts).
---   error: the last turn failed; cleared the same way.
---@type table<pi.Session, { done: boolean, error: boolean }>
local flags = setmetatable({}, { __mode = "k" })

---@param session pi.Session
---@return { done: boolean, error: boolean }
local function session_flags(session)
    local f = flags[session]
    if not f then
        f = { done = false, error = false }
        flags[session] = f
    end
    return f
end

--- A new turn starts: the user is about to see fresh activity, so both
--- notifications are consumed.
---@param session pi.Session
function M.on_agent_start(session)
    local f = session_flags(session)
    f.done = false
    f.error = false
end

--- The turn failed (stopReason error, retry exhausted, async prompt error,
--- compaction error). Blinks red until the user looks at the tab.
---@param session pi.Session
function M.mark_error(session)
    session_flags(session).error = true
    M.request_refresh()
end

--- A turn finished. If it ended in error, keep the error flag; otherwise mark
--- the session "done" (green blink) only when the user is looking elsewhere.
---@param session pi.Session
function M.on_agent_end(session)
    local f = session_flags(session)
    if not f.error and session.tab ~= current_tab() then
        f.done = true
    end
    -- A finished turn may have produced the first user message or a backend
    -- name; retry unresolved entries here instead of on every redraw.
    fetch_name(session)
    M.request_refresh()
end

--- A message was finalized. The backend only flushes the session file to disk
--- when the first assistant message completes (earlier entries are buffered),
--- so this is when the first-message fallback becomes readable — well before
--- agent_end on long turns. Retry unresolved names here; resolved entries
--- make this a no-op. The agent_end retry remains as a backstop.
---@param session pi.Session
function M.on_message_end(session)
    fetch_name(session)
end

--- The user is now looking at this session (TabEnter): both notifications are
--- consumed and the dot returns to idle.
---@param session pi.Session
function M.clear_flags(session)
    local f = flags[session]
    if f then
        f.done = false
        f.error = false
    end
    M.request_refresh()
end

-- Name cache ------------------------------------------------------------------

---@param session pi.Session
---@return string?
local function resolve_name(session)
    local entry = name_cache[session]
    if type(entry) ~= "table" then
        return nil
    end
    if entry.name then
        return entry.name --[[@as string]]
    end
    -- While the backend generates a session name, keep the provisional
    -- first-message fallback off the row so the label goes straight from
    -- "(unnamed)" to the generated title — one visible change, not two
    -- (the fallback is pi data, usually similar to the title; the jump is
    -- the flicker this suppresses).
    if title_generating(session) then
        return "(unnamed)"
    end
    if entry.first_message then
        return entry.first_message --[[@as string]]
    end
    return "(unnamed)"
end

--- Ask the backend for the session's display name (and fall back to the first
--- user message from its session file). Successful non-empty results are
--- cached; lifecycle transitions invalidate the cache (M.invalidate).
--- Entries that resolved empty stay retryable — a brand-new session has no
--- sessionName and its file does not exist yet, so the first-message fallback
--- only becomes available after the first turn — but retries happen only on
--- lifecycle hooks (M.on_message_end, M.on_agent_end, invalidation, manual
--- `R`), never on every redraw. While a retry is in flight the resolved
--- "(unnamed)" stays on screen; only the very first fetch shows the pending
--- placeholder.
---@param session pi.Session
fetch_name = function(session)
    local entry = name_cache[session]
    local retryable = entry == nil
        or (type(entry) == "table" and not entry.name and not entry.first_message and not entry.pending)
    if not retryable or not session.rpc:is_running() then
        return
    end
    if type(entry) ~= "table" then
        -- First fetch: show the pending placeholder until the answer arrives.
        name_cache[session] = "pending"
    else
        -- Retry of an empty resolution: keep the row on "(unnamed)" while the
        -- background fetch runs so it does not flicker back to the placeholder.
        entry.pending = true
    end
    local sent = session.rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            local data = res.success and res.data or {}
            local name = type(data.sessionName) == "string" and data.sessionName ~= "" and data.sessionName or false
            ---@type string|false
            local first_message = false
            if not name and type(data.sessionFile) == "string" then
                local info = require("pi.sessions.history").parse(data.sessionFile)
                if info and info.first_message ~= "" then
                    first_message = info.first_message
                end
            end
            local current = name_cache[session]
            if type(current) == "table" and current.name then
                -- A name arrived via session_info_changed while this fetch was
                -- in flight; keep it instead of clobbering it with possibly
                -- stale backend state.
                current.pending = nil
                M.request_refresh()
                return
            end
            name_cache[session] = { name = name, first_message = first_message }
            M.request_refresh()
        end)
    end)
    if not sent then
        if type(entry) == "table" then
            entry.pending = nil
        else
            name_cache[session] = nil
        end
    end
end

--- Drop the cached name for a session (new session, resumed session).
---@param session pi.Session
function M.invalidate(session)
    name_cache[session] = nil
end

--- Backend reports the session name changed (e.g. :PiSessionName).
---@param session pi.Session
---@param name string?
function M.on_session_info_changed(session, name)
    local entry = name_cache[session]
    if type(entry) ~= "table" then
        entry = { name = false, first_message = false }
        name_cache[session] = entry
    end
    entry.name = type(name) == "string" and name ~= "" and name or false
    M.request_refresh()
end

-- Rendering -------------------------------------------------------------------

---@return boolean
local function any_win_visible()
    for _, win in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            return true
        end
    end
    return false
end

-- Blink animation -------------------------------------------------------------

local uv = vim.uv or vim.loop
local blink_tick = 0
---@type uv.uv_timer_t?
local blink_timer = nil

--- Spinner animation state (auto-title generation). Drives its own faster
--- timer so the frame rate is not tied to the 500ms dot blink.
local spinner_tick = 0
---@type uv.uv_timer_t?
local spinner_timer = nil

---@return boolean whether any row animates (busy/compacting/done/error)
local function has_animated_row()
    for _, row in ipairs(rows) do
        if is_child_row(row) then
            if row.is_current_view then
                if row.status == "busy" or row.status == "compacting" then
                    return true
                end
            elseif row.error or row.done or row.status == "busy" or row.status == "compacting" then
                return true
            end
        elseif row.status == "busy" or row.status == "compacting" or row.done or row.error then
            return true
        end
    end
    return false
end

---@return boolean whether any row shows the auto-title spinner
local function has_spinner_row()
    for _, row in ipairs(rows) do
        if row.title_generating then
            return true
        end
    end
    return false
end

local function stop_blink()
    if not blink_timer then
        return
    end
    pcall(blink_timer.stop, blink_timer)
    if not blink_timer:is_closing() then
        blink_timer:close()
    end
    blink_timer = nil
end

--- Run the blink timer only while an animated row is on screen.
local function ensure_blink()
    if not has_animated_row() then
        stop_blink()
        return
    end
    if blink_timer and not blink_timer:is_closing() then
        return
    end
    blink_timer = assert(uv.new_timer())
    blink_timer:start(
        500,
        500,
        vim.schedule_wrap(function()
            if not any_win_visible() or not has_animated_row() then
                vim.schedule(stop_blink)
                return
            end
            blink_tick = blink_tick + 1
            M._render()
        end)
    )
end

--- Stop the auto-title spinner timer, if running.
local function stop_spinner()
    if not spinner_timer then
        return
    end
    pcall(spinner_timer.stop, spinner_timer)
    if not spinner_timer:is_closing() then
        spinner_timer:close()
    end
    spinner_timer = nil
end

--- Run the spinner timer only while a title-generating row is on screen.
local function ensure_spinner()
    if not any_win_visible() or not has_spinner_row() then
        stop_spinner()
        return
    end
    if spinner_timer and not spinner_timer:is_closing() then
        return
    end
    spinner_timer = assert(uv.new_timer())
    spinner_timer:start(
        120,
        120,
        vim.schedule_wrap(function()
            if not any_win_visible() or not has_spinner_row() then
                vim.schedule(stop_spinner)
                return
            end
            spinner_tick = spinner_tick + 1
            M._render()
        end)
    )
end

---@type fun()
local refresh_current_markers

--- Rebuild the buffer contents from live session state.
function M._render()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    local Sessions = require("pi.sessions.manager")
    local Attention = require("pi.attention")
    local sessions = Sessions.list()

    rows = M.build_rows(sessions, function(tab)
        return Attention.count(tab)
    end, function(session)
        local name = resolve_name(session)
        -- A dead process will never answer the name fetch; stop showing the
        -- pending placeholder for it.
        if name == nil and not session.rpc:is_running() then
            return "(unnamed)"
        end
        return name
    end, function(session)
        return flags[session] or { done = false, error = false }
    end, function(session)
        return title_generating(session)
    end)

    ---@type string[]
    local lines = {}
    ---@type table<integer, integer[][]>
    local line_chunks = {}
    for i, row in ipairs(rows) do
        local line, chunks = M.format_line(row, blink_tick)
        lines[i] = line
        line_chunks[i] = chunks
        row.marker_col = chunks[1][1] + 1
        row.marker_len = chunks[1][2] - chunks[1][1]
    end
    if #lines == 0 then
        lines = { "  (no active sessions)" }
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for lnum, chunks in ipairs(line_chunks) do
        for _, chunk in ipairs(chunks) do
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, chunk[1], {
                end_col = chunk[2],
                hl_group = chunk[3],
                -- below the window-local current-tab match (priority 20)
                priority = 10,
            })
        end
    end
    vim.bo[buf].modifiable = false

    -- Keep cursors inside the (possibly shrunk) buffer.
    for _, win in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            local cursor = vim.api.nvim_win_get_cursor(win)
            if cursor[1] > #lines then
                pcall(vim.api.nvim_win_set_cursor, win, { #lines, 0 })
            end
        end
    end

    -- Kick off the initial name fetch only; resolved entries (including
    -- empty "(unnamed)" ones) are re-checked on lifecycle hooks, not redraws.
    for _, row in ipairs(rows) do
        if row.session and name_cache[row.session] == nil then
            fetch_name(row.session)
        end
    end

    ensure_blink()
    ensure_spinner()
    refresh_current_markers()
end

--- Window-local "you are here" marker: a background under the dot cell of the
--- row whose session lives in the window's tab. The buffer is shared across
--- tabs but matches are window-local, so every tab marks its own session.
---@type table<integer, integer> matchaddpos id per list window
local current_matches = {}

refresh_current_markers = function()
    for tab, win in pairs(wins) do
        local old_id = current_matches[win]
        if old_id and vim.api.nvim_win_is_valid(win) then
            pcall(vim.fn.matchdelete, old_id, win)
        end
        current_matches[win] = nil
        if vim.api.nvim_win_is_valid(win) then
            for lnum, row in ipairs(rows) do
                if row.tab == tab and row.is_current_view then
                    -- Current-tab marker: blue overlay on the focused session dot
                    -- (parent or child). Steady while idle; blinks while busy.
                    local markable = (row.status == "idle" or row.status == "busy" or row.status == "compacting")
                        and row.attention == 0
                        and not row.done
                        and not row.error
                    local marker_on = row.status == "idle" or blink_tick % 2 == 0
                    if markable and marker_on then
                        local col = row.marker_col or 2
                        local len = row.marker_len or 1
                        local ok, id = pcall(vim.api.nvim_win_call, win, function()
                            return vim.fn.matchaddpos("PiSessionsListCurrent", { { lnum, col, len } }, 20)
                        end)
                        if ok then
                            current_matches[win] = id
                        end
                    end
                    break
                end
            end
        end
    end
end

--- Coalesced live redraw; no-op unless a list window is visible.
function M.request_refresh()
    if refresh_scheduled then
        return
    end
    refresh_scheduled = true
    vim.schedule(function()
        refresh_scheduled = false
        if any_win_visible() then
            M._render()
        end
    end)
end

-- Help overlay (?) -------------------------------------------------------------

--- Shortcuts shown by the help overlay: { key(s), description } pairs.
---@type [string, string][]
local HELP_ENTRIES = {
    { "<CR>, o", "Switch to / open the session in chat" },
    { "a, i", "Open the session and type at its prompt's end" },
    { "r", "Rename the session under the cursor" },
    { "s", "Show this session's stats (:PiSessionStats)" },
    { "c", "Compact this session in the background" },
    { "d", "Review this session's changed files (:PiDiff)" },
    { "f", "Fork this session from a past message (:PiFork)" },
    { "C", "Clone this session (:PiClone)" },
    { "t", "Navigate this session's tree (:PiTree)" },
    { "p", "Preview sub-session (rich viewer)" },
    { "x", "Close sub-session process (:PiSubClose)" },
    { "H", "Toggle hidden / prior-conversation sub-sessions" },
    { "R", "Refresh the list" },
    { "q", "Close the list" },
    { "?", "Toggle this help" },
}

--- Help float per list window. The list buffer is shared across tabs but
--- windows are per-tab, so each window toggles its own overlay.
---@type table<integer, integer>
local help_wins = {}

---@param list_win integer
local function close_help(list_win)
    local help = help_wins[list_win]
    if help and vim.api.nvim_win_is_valid(help) then
        vim.api.nvim_win_close(help, true)
    end
    help_wins[list_win] = nil
end

--- Toggle the help overlay listing the session list shortcuts. The float
--- never takes focus and closes automatically with its list window.
---@param list_win integer
local function toggle_help(list_win)
    if not vim.api.nvim_win_is_valid(list_win) then
        return
    end
    local existing = help_wins[list_win]
    if existing and vim.api.nvim_win_is_valid(existing) then
        close_help(list_win)
        return
    end

    local key_width = 0
    for _, entry in ipairs(HELP_ENTRIES) do
        key_width = math.max(key_width, vim.fn.strdisplaywidth(entry[1]))
    end
    local lines = {}
    local width = 0
    for _, entry in ipairs(HELP_ENTRIES) do
        local line = string.format("%-" .. key_width .. "s  %s", entry[1], entry[2])
        lines[#lines + 1] = line
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = width + 2

    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].filetype = Ft.dialog

    local cfg = Config.options.dialog
    local editor_w = vim.o.columns
    local editor_h = vim.o.lines - vim.o.cmdheight
    local win = vim.api.nvim_open_win(b, false, {
        relative = "editor",
        row = math.floor((editor_h - #lines) / 2),
        col = math.floor((editor_w - width) / 2),
        width = width,
        height = #lines,
        style = "minimal",
        border = cfg.border,
        title = " session list ",
        title_pos = "center",
        focusable = false,
    })
    vim.wo[win].winhighlight = Highlights.DIALOG_WINHIGHLIGHT
    help_wins[list_win] = win

    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            help_wins[list_win] = nil
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(list_win),
        once = true,
        callback = function()
            close_help(list_win)
        end,
    })
end

-- Buffer & windows ------------------------------------------------------------

--- Find the live session owning a row's tab.
---@param tab pi.TabId
---@return pi.Session?
local function session_for_tab(tab)
    local Sessions = require("pi.sessions.manager")
    for _, session in ipairs(Sessions.list()) do
        if session.tab == tab then
            return session
        end
    end
    return nil
end

--- Row and session under the cursor. nil, nil when the row is gone, its tab
--- is no longer valid, or the tab holds no live session.
---@return pi.SessionsListRow?, pi.Session?
local function row_session_under_cursor()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local row = rows[lnum]
    if not row then
        return nil, nil
    end
    if row.session then
        return row, row.session
    end
    if row.tab and vim.api.nvim_tabpage_is_valid(row.tab) then
        return row, session_for_tab(row.tab)
    end
    return row, nil
end

local function jump_under_cursor(at_end)
    local row, session = row_session_under_cursor()
    if not row then
        return
    end
    local Subsessions = require("pi.subsessions")
    local Sessions = require("pi.sessions.manager")
    local target_tab = row.tab or vim.api.nvim_get_current_tabpage()

    if row.is_tree_parent and row.session then
        if vim.api.nvim_get_current_tabpage() ~= target_tab then
            vim.api.nvim_set_current_tabpage(target_tab)
        end
        Subsessions.switch_to_parent(function(ok, err)
            if ok then
                local parent = Sessions.get_for_tab(target_tab)
                if parent and parent.chat then
                    if at_end then
                        parent.chat:ensure_shown_and_focus_prompt_at_end()
                    else
                        parent.chat:ensure_shown_and_focus_prompt()
                    end
                end
            elseif err then
                require("pi.notify").error(err)
            end
        end)
        return
    end

    if row.depth and row.depth > 0 and row.child_id then
        Subsessions.switch_to(row.child_id, function(ok, err)
            if ok then
                local child = Sessions.get_for_tab(target_tab)
                if child and child.chat then
                    if at_end then
                        child.chat:ensure_shown_and_focus_prompt_at_end()
                    else
                        child.chat:ensure_shown_and_focus_prompt()
                    end
                end
            elseif err then
                require("pi.notify").error(err)
            end
        end, { tab = target_tab })
        return
    end
    if not row.tab or not session then
        return
    end
    vim.api.nvim_set_current_tabpage(row.tab)
    if at_end then
        session.chat:ensure_shown_and_focus_prompt_at_end()
    else
        session.chat:ensure_shown_and_focus_prompt()
    end
end

--- Rename the session under the cursor: prompt for a display name and send it
--- to that session's backend (works for any listed session, not just the
--- current tab's). The backend's session_info_changed event updates the row
--- via M.on_session_info_changed.
local function rename_under_cursor()
    local _, session = row_session_under_cursor()
    if not session then
        return
    end
    local Notify = require("pi.notify")
    if not session.rpc:is_running() then
        Notify.warn("Cannot rename: the session process is not running")
        return
    end
    local entry = name_cache[session]
    local current = type(entry) == "table" and entry.name or ""
    require("pi.ui.dialog").input({ title = "Session Name", default = current }, function(value)
        if not value or value == "" then
            return
        end
        session.rpc:send({ type = "set_session_name", name = value }, function(res)
            vim.schedule(function()
                if not res.success then
                    Notify.error("Failed to set session name: " .. (res.error or "unknown error"))
                end
            end)
        end)
    end)
end

--- Show the stats dashboard for the session under the cursor (:PiSessionStats
--- data — tokens, cost, context — in a dialog float, without leaving the
--- list). Works for any listed session, not just the current tab's, same as
--- the rename key.
local function stats_under_cursor()
    local _, session = row_session_under_cursor()
    if not session then
        return
    end
    local Notify = require("pi.notify")
    if not session.rpc:is_running() then
        Notify.warn("Cannot show stats: the session process is not running")
        return
    end
    require("pi").session_stats(session)
end

--- Compact the session under the cursor: send the compact command straight to
--- that session's backend, without leaving the list — the compaction runs in
--- the background and the row's status dot switches to the compacting state.
--- Works for any listed session, not just the current tab's, same as the
--- rename key.
local function compact_under_cursor()
    local _, session = row_session_under_cursor()
    if not session then
        return
    end
    local Notify = require("pi.notify")
    if not session.rpc:is_running() then
        Notify.warn("Cannot compact: the session process is not running")
        return
    end
    require("pi").compact(nil, session)
end

--- Open the diff review for the session under the cursor (:PiDiff data — the
--- combined git diff of the session's changed files), without leaving the
--- list. Works for any listed session, not just the current tab's, same as
--- the rename key.
local function diff_under_cursor()
    local _, session = row_session_under_cursor()
    if not session then
        return
    end
    local Notify = require("pi.notify")
    if not session.rpc:is_running() then
        Notify.warn("Cannot review diff: the session process is not running")
        return
    end
    require("pi").diff_review(session)
end

--- Fork / clone / tree actions: jump to the target session's tab first, then
--- run the module entry — Sessions.get() resolves to the target session, so
--- the pickers, prefill and streaming guards all run unchanged against it
--- (the interplay is chat-centered, so being on that session's tab is the
--- right UX).
local function fork_under_cursor()
    local _, session = row_session_under_cursor()
    if not session then
        return
    end
    jump_under_cursor()
    require("pi").fork()
end

local function clone_under_cursor()
    local _, session = row_session_under_cursor()
    if not session then
        return
    end
    jump_under_cursor()
    require("pi").clone()
end

local function tree_under_cursor()
    local _, session = row_session_under_cursor()
    if not session then
        return
    end
    jump_under_cursor()
    require("pi").tree()
end

---@return integer
local function ensure_buf()
    if buf and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "pi://sessions")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].buflisted = false
    vim.bo[buf].filetype = Ft.sessions
    vim.bo[buf].modifiable = false

    local map_opts = { buffer = buf, nowait = true }
    vim.keymap.set("n", "<CR>", function()
        jump_under_cursor()
    end, vim.tbl_extend("force", map_opts, { desc = "Open this session" }))
    vim.keymap.set("n", "o", function()
        jump_under_cursor()
    end, vim.tbl_extend("force", map_opts, { desc = "Open this session" }))
    vim.keymap.set("n", "a", function()
        jump_under_cursor(true)
    end, vim.tbl_extend("force", map_opts, { desc = "Open this session and append to its prompt" }))
    vim.keymap.set("n", "i", function()
        jump_under_cursor(true)
    end, vim.tbl_extend("force", map_opts, { desc = "Open this session and append to its prompt" }))
    vim.keymap.set("n", "r", rename_under_cursor, vim.tbl_extend("force", map_opts, { desc = "Rename this session" }))
    vim.keymap.set(
        "n",
        "s",
        stats_under_cursor,
        vim.tbl_extend("force", map_opts, { desc = "Show this session's stats" })
    )
    vim.keymap.set("n", "c", compact_under_cursor, vim.tbl_extend("force", map_opts, { desc = "Compact this session" }))
    vim.keymap.set(
        "n",
        "d",
        diff_under_cursor,
        vim.tbl_extend("force", map_opts, { desc = "Review this session's diff" })
    )
    vim.keymap.set("n", "f", fork_under_cursor, vim.tbl_extend("force", map_opts, { desc = "Fork this session" }))
    vim.keymap.set("n", "C", clone_under_cursor, vim.tbl_extend("force", map_opts, { desc = "Clone this session" }))
    vim.keymap.set(
        "n",
        "t",
        tree_under_cursor,
        vim.tbl_extend("force", map_opts, { desc = "Navigate this session's tree" })
    )
    vim.keymap.set("n", "p", function()
        local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
        if row and row.child_id then
            require("pi.subsessions").preview(row.child_id)
        end
    end, vim.tbl_extend("force", map_opts, { desc = "Preview sub-session (rich viewer)" }))
    vim.keymap.set("n", "x", function()
        local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
        if row and row.child_id then
            require("pi.subsessions").close(row.child_id)
        end
    end, vim.tbl_extend("force", map_opts, { desc = "Close sub-session process" }))
    vim.keymap.set("n", "H", function()
        M.toggle_show_hidden_children()
        M._render()
    end, vim.tbl_extend("force", map_opts, { desc = "Toggle hidden sub-sessions" }))
    vim.keymap.set("n", "R", function()
        name_cache = setmetatable({}, { __mode = "k" })
        M._render()
    end, vim.tbl_extend("force", map_opts, { desc = "Refresh session list" }))
    vim.keymap.set("n", "q", function()
        M.close()
    end, vim.tbl_extend("force", map_opts, { desc = "Close session list" }))
    vim.keymap.set("n", "?", function()
        toggle_help(vim.api.nvim_get_current_win())
    end, vim.tbl_extend("force", map_opts, { desc = "Toggle help" }))

    return buf
end

--- Resolve a dimension (columns/lines) from a config value; values < 1 are
--- fractions of the available space.
---@param value number
---@param available integer
---@return integer
local function resolve_dimension(value, available)
    if value < 1 then
        return math.max(1, math.floor(available * value))
    end
    return math.max(1, math.floor(value))
end

---@param win integer
local function set_list_win_opts(win)
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].foldenable = false
    vim.wo[win].list = false
    vim.wo[win].spell = false
    vim.wo[win].cursorline = true
    vim.wo[win].winfixbuf = true
end

---@param b integer
---@return integer
local function open_side_win(b)
    local cfg = Config.options.sessions_list
    local position = cfg.position or "left"
    local cmd
    if position == "right" then
        cmd = "botright " .. cfg.width .. "vsplit"
    elseif position == "top" then
        cmd = "topleft " .. cfg.height .. "split"
    elseif position == "bottom" then
        cmd = "botright " .. cfg.height .. "split"
    else
        cmd = "topleft " .. cfg.width .. "vsplit"
    end
    vim.cmd(cmd)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, b)
    set_list_win_opts(win)
    if position == "top" or position == "bottom" then
        vim.wo[win].winfixheight = true
    else
        vim.wo[win].winfixwidth = true
    end
    return win
end

---@param b integer
---@return integer
local function open_float_win(b)
    local cfg = Config.options.sessions_list.float
    local width = resolve_dimension(cfg.width, vim.o.columns)
    local height = resolve_dimension(cfg.height, vim.o.lines - vim.o.cmdheight - 1)
    local col = math.floor((vim.o.columns - width) / 2)
    local row = math.floor((vim.o.lines - vim.o.cmdheight - 1 - height) / 2)
    local win = vim.api.nvim_open_win(b, true, {
        relative = "editor",
        width = width,
        height = height,
        col = col,
        row = math.max(0, row),
        style = "minimal",
        border = cfg.border or "rounded",
        title = " sessions ",
        title_pos = "center",
    })
    set_list_win_opts(win)
    vim.wo[win].winhighlight = Highlights.SESSIONS_LIST_WINHIGHLIGHT
    return win
end

--- Layout mode for the list window. `sessions_list.mode` wins when set to
--- "side"/"float"; "follow" (default) matches the current tab's chat layout,
--- falling back to the configured default layout mode.
---@return pi.LayoutMode
local function resolve_mode()
    local mode = Config.options.sessions_list.mode or "follow"
    if mode == "side" then
        return "side"
    end
    if mode == "float" then
        return "float"
    end
    local Sessions = require("pi.sessions.manager")
    local session = Sessions.get()
    if session then
        return session.chat:layout()
    end
    return Config.resolve_default_layout_mode()
end

---@param tab pi.TabId
---@return integer?
local function win_for(tab)
    local win = wins[tab]
    if win and vim.api.nvim_win_is_valid(win) then
        return win
    end
    wins[tab] = nil
    return nil
end

--- Open (or focus) the sessions list in the current tab.
function M.open()
    local tab = current_tab()
    local existing = win_for(tab)
    if existing then
        vim.api.nvim_set_current_win(existing)
        return
    end

    local b = ensure_buf()
    local win
    if resolve_mode() == "float" then
        win = open_float_win(b)
    else
        win = open_side_win(b)
    end
    wins[tab] = win
    M._render()
end

--- Close the sessions list window in the current tab (no-op when absent).
function M.close()
    show_hidden_children = false
    local tab = current_tab()
    local win = win_for(tab)
    if not win then
        return
    end
    wins[tab] = nil
    if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, false)
    end
end

--- True when the current window is a `:PiSessions` list.
---@return boolean
function M.has_focus()
    local win = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(win) then
        return false
    end
    for _, list_win in pairs(wins) do
        if list_win == win then
            return true
        end
    end
    local b = vim.api.nvim_win_get_buf(win)
    if buf and vim.api.nvim_buf_is_valid(buf) and b == buf then
        return true
    end
    return vim.bo[b].filetype == Ft.sessions
end

--- Toggle the sessions list in the current tab.
function M.toggle()
    if win_for(current_tab()) then
        M.close()
    else
        M.open()
    end
end

--- Test hook: set the blink animation tick (drives dot/marker blink phase).
---@param tick integer
function M._set_blink_tick(tick)
    blink_tick = tick
end

--- Test hook: set the spinner animation tick (drives the auto-title frames).
---@param tick integer
function M._set_spinner_tick(tick)
    spinner_tick = tick
end

--- Test hook: resolved display name for a session (nil while fetching).
---@param session pi.Session
---@return string?
function M._name_of(session)
    return resolve_name(session)
end

--- Test hook: trigger a name fetch for a session (initial fetch, or retry of
--- an entry that resolved empty).
---@param session pi.Session
function M._fetch_name(session)
    fetch_name(session)
end

--- Test hook: drop all module state.
function M._reset()
    stop_blink()
    stop_spinner()
    blink_tick = 0
    spinner_tick = 0
    for list_win in pairs(help_wins) do
        close_help(list_win)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    buf = nil
    wins = {}
    rows = {}
    name_cache = setmetatable({}, { __mode = "k" })
    refresh_scheduled = false
    child_completion_seen = {}
end

return M
