--- Pending attention state for blocking extension UI requests.
--- Raw pending entries are owned by sessions; this module provides the
--- cross-session API, aggregation, timer pruning, and redraw hooks.

local M = {}

local Dialog = require("pi.ui.dialog")
local Diff = require("pi.ui.diff")
local Notify = require("pi.notify")

---@alias pi.AttentionKind "diff"|"select"|"confirm"|"input"|"editor"

---@class pi.AttentionEntry
---@field id string
---@field seq integer Global arrival order across sessions
---@field kind pi.AttentionKind
---@field created_at? integer Wall-clock arrival time (ms), reported to web clients
---@field expires_at integer? Always set: the request expires (default 120 s)
---@field opened? boolean A local dialog is on screen for this request
---@field msg? pi.RpcEvent Raw `extension_ui_request`, projected into snapshots
---@field open fun(): boolean opened

--- Lifetime of a request the backend gave no `timeout` for. Protocol §6: the
--- plugin cancels such a request after 120 s so no client keeps a phantom.
M.DEFAULT_TIMEOUT_MS = 120 * 1000

---@class pi.AttentionTabState
---@field count integer

---@class pi.AttentionState
---@field current_tab pi.TabId
---@field current_tab_count integer
---@field total_count integer
---@field tabs table<pi.TabId, pi.AttentionTabState>

local uv = vim.uv or vim.loop
local redraw_scheduled = false
local autocmds_set = false
local prune_timer = nil ---@type uv.uv_timer_t?
local next_seq = 0

local prune_stale_queue
local reschedule_timer

--- Whether this Neovim process has an attached UI. Headless instances (the
--- daemon's `pi.host`) must never open a dialog; they only queue + emit.
---@return boolean
local function has_ui()
    return #vim.api.nvim_list_uis() > 0
end

---@return pi.Session[]
local function sessions()
    local ok, manager = pcall(require, "pi.sessions.manager")
    if not ok or not manager then
        return {}
    end
    if manager.list_all then
        return manager.list_all()
    end
    return manager.list()
end

---@return integer
local function now_ms()
    return uv.now()
end

---@param session pi.Session
---@return pi.AttentionEntry[]
local function pending_entries(session)
    if not session.attention then
        session.attention = { pending = {} }
    end
    return session.attention.pending
end

local function request_redraw()
    if redraw_scheduled then
        return
    end
    redraw_scheduled = true
    vim.schedule(function()
        redraw_scheduled = false
        pcall(vim.cmd, "redrawstatus!")
        pcall(vim.cmd, "redrawtabline")
        require("pi.ui.sessions").request_refresh()
        local session = require("pi.sessions.manager").get()
        if session and session.chat then
            session.chat:render_statusline()
            session.chat:refresh_prompt_attention()
        end
    end)
end

local function close_timer()
    if not prune_timer then
        return
    end
    pcall(prune_timer.stop, prune_timer)
    if not prune_timer:is_closing() then
        prune_timer:close()
    end
    prune_timer = nil
end

---@return uv.uv_timer_t
local function ensure_timer()
    if prune_timer and not prune_timer:is_closing() then
        return prune_timer
    end
    prune_timer = assert(uv.new_timer())
    return prune_timer
end

--- Remove one queued entry by identity without announcing it (the caller owns
--- the `pi2:attention_resolved` emission).
---@param session pi.Session
---@param entry pi.AttentionEntry|string|nil table or request id
---@return boolean removed true when the entry was still queued
local function take_entry(session, entry)
    if entry == nil then
        return false
    end
    local pending = pending_entries(session)
    local id = type(entry) == "table" and entry.id or entry
    for i, existing in ipairs(pending) do
        if existing == entry or (id ~= nil and existing.id == id) then
            table.remove(pending, i)
            reschedule_timer(true)
            request_redraw()
            return true
        end
    end
    return false
end

--- Tell every other client that a request is no longer answerable. Every
--- removal path (answered, expired, dropped by a session transition, closed)
--- calls this, so a web client never keeps a phantom `attention[]` entry.
---@param session pi.Session
---@param request_id string|nil
---@param by string client that resolved it
---@param response table|nil
local function emit_resolved(session, request_id, by, response)
    if type(request_id) ~= "string" or request_id == "" then
        return
    end
    local ok, Instance = pcall(require, "pi.web.instance")
    if ok and Instance.active() then
        pcall(Instance.emit_attention_resolved, session, request_id, by, response)
    end
end

---@param tab? pi.TabId|0
---@return pi.TabId
local function resolve_tab(tab)
    if tab == nil or tab == 0 then
        return vim.api.nvim_get_current_tabpage()
    end
    return tab
end

---@return integer
local function next_attention_seq()
    next_seq = next_seq + 1
    return next_seq
end

---@param title string?
---@return table?
local function decode_diff_payload(title)
    local ok, payload = pcall(vim.json.decode, title or "")
    if ok and payload and (payload.toolName == "edit" or payload.toolName == "write") then
        return payload
    end
    return nil
end

---@param session pi.Session
---@param cmd pi.RpcCommand
---@param by? string client that answered (default "nvim")
local function send_response(session, cmd, by)
    if session.rpc:is_running() then
        session.rpc:send(cmd)
    end
    -- Every answer — local dialog, :PiAttention or a web client — resolves the
    -- request for all other clients (protocol §6, first answer wins). Emitting
    -- here (not at each closure) keeps the fanout in one place.
    if type(cmd) == "table" then
        emit_resolved(session, cmd.id, by or "nvim", cmd)
    end
end

--- Answer a request from a local dialog: the queue entry goes first (so the web
--- stops seeing it as answerable), then the response is forwarded, which emits
--- `pi2:attention_resolved` for everyone else.
---@param session pi.Session
---@param entry pi.AttentionEntry|nil
---@param cmd pi.RpcCommand
---@return boolean answered false when another client already answered it
local function answer_entry(session, entry, cmd)
    if type(entry) ~= "table" then
        return false
    end
    entry.opened = nil
    if not take_entry(session, entry) then
        -- Another client answered while our dialog was open: its response is
        -- already on the wire, a second one would be E_ATTENTION_RESOLVED.
        return false
    end
    send_response(session, cmd, "nvim")
    return true
end

--- Drop an expired request and cancel it so the backend unblocks (protocol §6).
---@param session pi.Session
---@param entry pi.AttentionEntry|nil
---@param by? string
---@return boolean expired true when the entry was still queued
local function expire_entry(session, entry, by)
    if type(entry) ~= "table" then
        return false
    end
    entry.opened = nil
    if not take_entry(session, entry) then
        return false
    end
    send_response(session, { type = "extension_ui_response", id = entry.id, cancelled = true }, by or "timeout")
    return true
end

---@param session pi.Session
---@param entry pi.AttentionEntry
---@param now? integer
---@return boolean
local function is_stale(session, entry, now)
    now = now or now_ms()
    if not session.rpc:is_running() then
        return true
    end
    if session.tab ~= nil and not vim.api.nvim_tabpage_is_valid(session.tab) then
        return true
    end
    return entry.expires_at ~= nil and now >= entry.expires_at
end

---@param session pi.Session
---@param entry pi.AttentionEntry
---@param now? integer
---@return boolean
local function is_visible(session, entry, now)
    if entry.opened then
        -- A dialog is already on screen for it: still pending (a web client may
        -- answer it — first answer wins), but not openable a second time.
        return false
    end
    if is_stale(session, entry, now) then
        return false
    end
    local transition_seq = session.attention and session.attention.transition_seq or nil
    return transition_seq == nil or entry.seq > transition_seq
end

---@param current_tab? pi.TabId|0
---@return pi.AttentionState
local function build_state(current_tab)
    local state = {
        current_tab = resolve_tab(current_tab),
        current_tab_count = 0,
        total_count = 0,
        tabs = {},
    }

    local now = now_ms()

    for _, session in ipairs(sessions()) do
        for _, entry in ipairs(pending_entries(session)) do
            if is_visible(session, entry, now) then
                state.total_count = state.total_count + 1
                if session.tab ~= nil then
                    local tab_state = state.tabs[session.tab]
                    if not tab_state then
                        tab_state = {
                            count = 0,
                        }
                        state.tabs[session.tab] = tab_state
                    end
                    tab_state.count = tab_state.count + 1
                end
            end
        end
    end

    local current = state.tabs[state.current_tab]
    state.current_tab_count = current and current.count or 0
    return state
end

---@param session pi.Session
---@param entry pi.AttentionEntry
local function emit_requested(session, entry)
    local state = build_state(session.tab)
    local tab_state = (session.tab and state.tabs[session.tab]) or { count = 0 }
    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "PiAttentionRequested",
        modeline = false,
        data = {
            tab = session.tab,
            kind = entry.kind,
            tab_count = tab_state.count,
            total_count = state.total_count,
        },
    })
end

---@param kind pi.AttentionKind
---@return string
local function kind_label(kind)
    if kind == "diff" then
        return "diff review"
    elseif kind == "confirm" then
        return "confirmation"
    elseif kind == "select" then
        return "selection"
    elseif kind == "editor" then
        return "editor input"
    end
    return "input"
end

--- Build the persistent notification id for a tab.
---@param tab? pi.TabId|0
---@return string
local function attention_notification_id(tab)
    if not tab or tab == 0 then
        return "pi-attention-background"
    end
    return "pi-attention-" .. tostring(tab)
end

--- Show a persistent attention notification for a tab.
---@param tab? pi.TabId|0
---@param msg string
---@param level integer vim.log.levels.*
function M.notify(tab, msg, level)
    Notify.dispatch(msg, level, { id = attention_notification_id(tab), timeout = 0 })
end

--- Whether the "agent finished" toast should fire for this chat.
--- Skipped while replaying history, or when the user is already looking at
--- this chat (history/prompt/attachments) or the :PiSessions list.
---@param chat pi.Chat
---@return boolean
function M.should_notify_on_completion(chat)
    if chat._history and chat._history._replaying then
        return false
    end
    if chat.has_focus and chat:has_focus() then
        return false
    end
    if require("pi.ui.sessions").has_focus() then
        return false
    end
    return true
end

--- Dismiss the persistent attention notification for a tab.
---@param tab? pi.TabId|0
function M.dismiss_notification(tab)
    local ok, snacks = pcall(require, "snacks")
    if ok and snacks and snacks.notifier and snacks.notifier.hide then
        snacks.notifier.hide(attention_notification_id(tab))
    end
end

---@param session pi.Session
---@param entry pi.AttentionEntry
local function notify_pending(session, entry)
    local suffix
    if session.tab == nil then
        suffix = " (background)"
    elseif session.tab == vim.api.nvim_get_current_tabpage() then
        suffix = ""
    else
        suffix = " in another tab"
    end
    M.notify(
        session.tab or 0,
        "Agent needs " .. kind_label(entry.kind) .. suffix .. " — run :PiAttention",
        vim.log.levels.WARN
    )
end

---@param kind pi.AttentionKind
local function notify_expired(kind)
    Notify.warn(kind_label(kind) .. " request expired")
end

---@param expires_at integer?
---@return integer?
local function remaining_timeout_ms(expires_at)
    if expires_at == nil then
        return nil
    end
    return expires_at - now_ms()
end

---@param session pi.Session
---@param msg pi.RpcEvent
---@return pi.AttentionEntry?
local function build_entry(session, msg)
    local id = tostring(msg.id or "")
    -- Every request expires: without a pi-level timeout the plugin cancels it
    -- after `DEFAULT_TIMEOUT_MS` (protocol §6), so no client keeps a phantom
    -- entry forever and the backend never stays blocked.
    local timeout = type(msg.timeout) == "number" and msg.timeout or M.DEFAULT_TIMEOUT_MS
    local expires_at = now_ms() + timeout
    local entry ---@type pi.AttentionEntry?

    --- Answer through the shared path: drop the queue entry, forward the answer.
    ---@param cmd pi.RpcCommand
    local function answer(cmd)
        answer_entry(session, entry, cmd)
    end

    if msg.method == "select" then
        local payload = decode_diff_payload(msg.title)
        if payload then
            entry = {
                id = id,
                seq = next_attention_seq(),
                kind = "diff",
                expires_at = expires_at,
                open = function()
                    local remaining = remaining_timeout_ms(expires_at)
                    if remaining ~= nil and remaining <= 0 then
                        return false
                    end
                    Diff.open(payload, function(result)
                        answer({ type = "extension_ui_response", id = id, value = result })
                    end, {
                        timeout = remaining,
                        on_timeout = function()
                            notify_expired("diff")
                            expire_entry(session, entry)
                        end,
                    })
                    return true
                end,
            }
            return entry
        end

        entry = {
            id = id,
            seq = next_attention_seq(),
            kind = "select",
            expires_at = expires_at,
            open = function()
                local remaining = remaining_timeout_ms(expires_at)
                if remaining ~= nil and remaining <= 0 then
                    return false
                end
                Dialog.select({
                    title = "Select",
                    message = msg.title,
                    options = msg.options or {},
                    kind = "pi-extension-select",
                }, function(choice)
                    local left = remaining_timeout_ms(expires_at)
                    if left ~= nil and left <= 0 then
                        notify_expired("select")
                        expire_entry(session, entry)
                        return
                    end
                    if choice then
                        answer({ type = "extension_ui_response", id = id, value = choice })
                    else
                        answer({ type = "extension_ui_response", id = id, cancelled = true })
                    end
                end)
                return true
            end,
        }
        return entry
    end

    if msg.method == "confirm" then
        entry = {
            id = id,
            seq = next_attention_seq(),
            kind = "confirm",
            expires_at = expires_at,
            open = function()
                local remaining = remaining_timeout_ms(expires_at)
                if remaining ~= nil and remaining <= 0 then
                    return false
                end
                Dialog.confirm({
                    title = msg.title,
                    message = msg.message --[[@as string?]],
                }, function(confirmed)
                    local left = remaining_timeout_ms(expires_at)
                    if left ~= nil and left <= 0 then
                        notify_expired("confirm")
                        expire_entry(session, entry)
                        return
                    end
                    if confirmed then
                        answer({ type = "extension_ui_response", id = id, confirmed = true })
                    else
                        answer({ type = "extension_ui_response", id = id, cancelled = true })
                    end
                end)
                return true
            end,
        }
        return entry
    end

    if msg.method == "input" or msg.method == "editor" then
        entry = {
            id = id,
            seq = next_attention_seq(),
            kind = msg.method,
            expires_at = expires_at,
            open = function()
                local remaining = remaining_timeout_ms(expires_at)
                if remaining ~= nil and remaining <= 0 then
                    return false
                end
                Dialog.input({
                    title = msg.title or "Input",
                    default = msg.prefill or msg.placeholder or "",
                    timeout = remaining,
                    on_timeout = function()
                        notify_expired(msg.method --[[@as pi.AttentionKind]])
                        expire_entry(session, entry)
                    end,
                }, function(value)
                    if value then
                        answer({ type = "extension_ui_response", id = id, value = value })
                    else
                        answer({ type = "extension_ui_response", id = id, cancelled = true })
                    end
                end)
                return true
            end,
        }
        return entry
    end

    return nil
end

---@param session pi.Session
---@param predicate fun(entry: pi.AttentionEntry): boolean
---@param by string|nil client to attribute the resolution to; nil = silent (replaced)
---@return integer removed
local function remove_matching(session, predicate, by)
    local removed = 0
    local pending = pending_entries(session)
    for i = #pending, 1, -1 do
        local entry = pending[i]
        if predicate(entry) then
            table.remove(pending, i)
            removed = removed + 1
            if by then
                emit_resolved(session, entry.id, by)
            end
        end
    end
    return removed
end

---@param session pi.Session
function M.begin_session_transition(session)
    if not session.attention then
        session.attention = { pending = {} }
    end
    if session.attention.transition_seq ~= nil then
        return
    end
    session.attention.transition_seq = next_seq
    request_redraw()
end

---@param session pi.Session
---@param committed boolean
function M.end_session_transition(session, committed)
    local transition_seq = session.attention and session.attention.transition_seq or nil
    if transition_seq == nil then
        return
    end
    if committed then
        -- The session (or its view) is being replaced: those requests can no
        -- longer be answered, so tell the web they are gone.
        remove_matching(session, function(entry)
            return entry.seq <= transition_seq
        end, "session")
    end
    session.attention.transition_seq = nil
    reschedule_timer(true)
    request_redraw()
end

---@param skip_prune? boolean
reschedule_timer = function(skip_prune)
    if prune_timer then
        pcall(prune_timer.stop, prune_timer)
    end

    local now = now_ms()
    local next_delay = nil ---@type integer?
    local has_stale = false

    for _, session in ipairs(sessions()) do
        for _, entry in ipairs(pending_entries(session)) do
            if is_stale(session, entry, now) then
                has_stale = true
            elseif entry.expires_at ~= nil then
                local delay = math.max(0, entry.expires_at - now)
                next_delay = next_delay and math.min(next_delay, delay) or delay
            end
        end
    end

    if has_stale and not skip_prune then
        prune_stale_queue()
        return
    end

    if next_delay == nil then
        return
    end

    ensure_timer():start(
        next_delay,
        0,
        vim.schedule_wrap(function()
            prune_stale_queue()
        end)
    )
end

prune_stale_queue = function()
    local removed = 0
    local now = now_ms()
    for _, session in ipairs(sessions()) do
        local pending = pending_entries(session)
        for i = #pending, 1, -1 do
            local entry = pending[i]
            if is_stale(session, entry, now) then
                table.remove(pending, i)
                removed = removed + 1
                -- Cancel first: the backend is blocked in ctx.ui.*() until it
                -- receives an extension_ui_response (protocol §6). This also
                -- emits `pi2:attention_resolved`, so no phantom stays on the web.
                local expired = entry.expires_at ~= nil and now >= entry.expires_at
                send_response(
                    session,
                    { type = "extension_ui_response", id = entry.id, cancelled = true },
                    expired and "timeout" or "expiry"
                )
            end
        end
    end
    reschedule_timer(true)
    if removed > 0 then
        request_redraw()
    end
end

M.prune_stale_queue = prune_stale_queue
M._prune_stale_queue = prune_stale_queue

--- Present a blocking extension UI request immediately only when the π
--- prompt has focus and there is no draft; otherwise queue it for later.
--- A `pi2:attention_request` event is always emitted first (even headless), so
--- web clients see every request regardless of local UI state.
---@param session pi.Session
---@param msg pi.RpcEvent
---@return boolean handled
function M.present(session, msg)
    local entry = build_entry(session, msg)
    if not entry then
        return false
    end
    entry.created_at = entry.created_at or now_ms()
    entry.msg = entry.msg or msg

    local ok_web, Instance = pcall(require, "pi.web.instance")
    if ok_web and Instance.active() then
        pcall(Instance.emit_attention_request, session, msg, entry)
    end

    -- Queue before opening: the entry must stay answerable by every client
    -- (including the web) while a local dialog is on screen, and the local
    -- dialog must not be opened twice (`opened`).
    remove_matching(session, function(existing)
        return existing.id == entry.id
    end)
    local pending = pending_entries(session)
    pending[#pending + 1] = entry
    reschedule_timer()

    if has_ui() and session.chat and session.chat:has_prompt_focus() and not session.chat:has_draft() then
        entry.opened = true
        request_redraw()
        if not entry.open() then
            notify_expired(entry.kind)
            expire_entry(session, entry)
        end
        return true
    end

    request_redraw()
    if has_ui() then
        notify_pending(session, entry)
    end
    emit_requested(session, entry)
    return true
end

--- Resolve a pending attention request from another client (the web console).
--- First answer wins: an id that is no longer queued returns
--- `E_ATTENTION_RESOLVED` to the caller. Removal happens *before* the response
--- is sent, so a local :PiAttention can never pop a ghost dialog for an entry
--- the web client already answered.
---@param session pi.Session
---@param request_id string
---@param by string|nil client that answered (default "web")
---@param response table|nil { value = any } | { confirmed = boolean } | { cancelled = true }
---@return boolean ok
---@return string|nil code protocol error code when not ok
function M.resolve(session, request_id, by, response)
    if type(request_id) ~= "string" or request_id == "" then
        return false, "E_BAD_REQUEST"
    end
    local pending = pending_entries(session)
    local index
    for i, entry in ipairs(pending) do
        if entry.id == request_id then
            index = i
            break
        end
    end
    if not index then
        return false, "E_ATTENTION_RESOLVED"
    end
    pending[index].opened = nil
    table.remove(pending, index)
    reschedule_timer(true)
    request_redraw()

    ---@type pi.RpcCommand
    local cmd = { type = "extension_ui_response", id = request_id }
    if type(response) == "table" then
        if response.cancelled == true then
            cmd.cancelled = true
        elseif response.confirmed ~= nil then
            cmd.confirmed = response.confirmed == true
        elseif response.value ~= nil then
            cmd.value = response.value
        else
            cmd.cancelled = true
        end
    else
        cmd.cancelled = true
    end
    send_response(session, cmd, by or "web")
    return true
end

---@return pi.Session?, integer?, pi.AttentionEntry?
local function find_oldest_visible_entry()
    local best_session = nil ---@type pi.Session?
    local best_index = nil ---@type integer?
    local best_entry = nil ---@type pi.AttentionEntry?

    for _, session in ipairs(sessions()) do
        for i, entry in ipairs(pending_entries(session)) do
            if is_visible(session, entry) and (not best_entry or entry.seq < best_entry.seq) then
                best_session = session
                best_index = i
                best_entry = entry
            end
        end
    end

    return best_session, best_index, best_entry
end

---@param tab pi.TabId
---@return pi.Session?, integer?, pi.AttentionEntry?
local function find_oldest_visible_entry_for_tab(tab)
    local best_session = nil ---@type pi.Session?
    local best_index = nil ---@type integer?
    local best_entry = nil ---@type pi.AttentionEntry?

    for _, session in ipairs(sessions()) do
        if session.tab == tab then
            for i, entry in ipairs(pending_entries(session)) do
                if is_visible(session, entry) and (not best_entry or entry.seq < best_entry.seq) then
                    best_session = session
                    best_index = i
                    best_entry = entry
                end
            end
        end
    end

    return best_session, best_index, best_entry
end

---@param session pi.Session
---@param entry pi.AttentionEntry
---@param opts? { switch_tab?: boolean }
---@return boolean opened
---@return boolean expired
local function open_pending_entry(session, entry, opts)
    local timeout = remaining_timeout_ms(entry.expires_at)
    if timeout ~= nil and timeout <= 0 then
        notify_expired(entry.kind)
        expire_entry(session, entry)
        return false, true
    end

    if opts and opts.switch_tab and session.tab and session.tab ~= vim.api.nvim_get_current_tabpage() then
        if vim.api.nvim_tabpage_is_valid(session.tab) then
            vim.api.nvim_set_current_tabpage(session.tab)
        end
    end

    -- Keep the entry queued (see `M.present`): `opened` hides it from the
    -- "open next" search while the web can still answer it.
    entry.opened = true
    request_redraw()
    if entry.open() then
        return true, false
    end

    notify_expired(entry.kind)
    expire_entry(session, entry)
    return false, true
end

--- Open the oldest queued attention request for a tab.
--- Returns false silently when the tab has no pending visible requests.
---@param tab? pi.TabId|0
---@return boolean opened
function M.open_next_for_tab(tab)
    local target_tab = resolve_tab(tab)
    M.dismiss_notification(target_tab)
    prune_stale_queue()

    while true do
        local session, _, entry = find_oldest_visible_entry_for_tab(target_tab)
        if not session or not entry then
            return false
        end

        local opened = open_pending_entry(session, entry)
        if opened then
            return true
        end
    end
end

--- Open the oldest queued attention request, switching to its tab if needed.
---@return boolean opened
function M.open_next()
    M.dismiss_notification(resolve_tab(nil))
    M.dismiss_notification(0)
    prune_stale_queue()

    local expired = false

    while true do
        local session, _, entry = find_oldest_visible_entry()
        if not session or not entry then
            if not expired then
                Notify.info("No pending π requests")
            end
            return false
        end

        local opened, entry_expired = open_pending_entry(session, entry, { switch_tab = true })
        if opened then
            return true
        end
        expired = expired or entry_expired
    end
end

--- Remove all queued requests for a session.
---@param session pi.Session
function M.clear_session(session)
    local pending = pending_entries(session)
    local removed = #pending
    if removed == 0 then
        return
    end
    -- Cancel each queued request before dropping it: the backend is blocked in
    -- ctx.ui.*() until it receives an extension_ui_response, and dropping the
    -- queue without one would leave it waiting forever. `send_response` also
    -- emits `pi2:attention_resolved` for every one of them.
    for _, entry in ipairs(pending) do
        entry.opened = nil
        send_response(session, { type = "extension_ui_response", id = entry.id, cancelled = true }, "nvim")
    end
    session.attention.pending = {}
    reschedule_timer(true)
    request_redraw()
end

--- Count active attention requests for a tab.
--- Pass nil or 0 for the current tab.
---@param tab? pi.TabId|0
---@return integer
function M.count(tab)
    return build_state(tab).current_tab_count
end

--- Count active attention requests across all tabs.
---@return integer
function M.total_count()
    return build_state().total_count
end

---@param tab? pi.TabId|0
---@return boolean
function M.has_attention(tab)
    return M.count(tab) > 0
end

--- Return a snapshot of the current attention state.
---@param current_tab? pi.TabId|0
---@return pi.AttentionState
function M.state(current_tab)
    return build_state(current_tab)
end

--- Backwards-compatible alias for global count.
---@return integer
function M.pending_count()
    return M.total_count()
end

function M.setup_autocmds()
    if autocmds_set then
        return
    end
    autocmds_set = true

    vim.api.nvim_create_autocmd("TabEnter", {
        callback = function()
            request_redraw()
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            close_timer()
        end,
    })
end

return M
