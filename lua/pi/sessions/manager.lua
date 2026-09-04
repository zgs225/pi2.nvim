---@alias pi.TabId integer Neovim tabpage handle

---@class pi.SessionAttention
---@field pending pi.AttentionEntry[]
---@field transition_seq? integer Hide queued entries with seq <= this while a session transition is in flight.

---@class pi.StartupAnnouncement
---@field lines string[]

---@class pi.SystemErrorEntry
---@field message string
---@field timestamp integer

---@class pi.ModelRef
---@field provider string
---@field id string

---@class pi.PinnedConfig
---@field model pi.ModelRef Model chosen in this session. Reapplied after `new_session` so model switches made in other sessions (which core persists to global settings) don't leak into this tab's next conversation.
---@field thinking_level? string Thinking level pinned for this session.

---@class pi.Session
---@field id string Session id from backend (`sessionId`) or JSONL header; temporary ids use the `tmp-` prefix until the backend reports the real id.
---@field attached_tab? pi.TabId Tab currently displaying this session (`nil` when detached or running in the background).
---@field tab? pi.TabId Alias for `attached_tab` (backward compatibility).
---@field rpc pi.Rpc
---@field chat? pi.Chat UI bound to this session while `attached_tab` is set; `nil` when detached.
---@field attention pi.SessionAttention
---@field pinned_config? pi.PinnedConfig Per-session model/thinking pin.
---@field pinned_model? pi.ModelRef Deprecated alias for `pinned_config.model`; kept in sync by `update_pinned_config`.
---@field parent_id? string Parent session id when this is a sub-session process.
---@field view_parent_id? string Parent id for breadcrumb navigation while viewing a child in the tab UI.
---@field lineage_id? string Stable parent key for sub-session manifest rows across /new and id migration.
---@field conversation_epoch? integer Incremented on each /new in this tab; sub-sessions tag their parent_epoch.
---@field _detached_busy? boolean Session-level run is active until `agent_settled` (also when a chat is bound).
---@field _detached_compacting? boolean Compaction running (detached or captured on unbind).
---@field _detached_retrying? boolean Auto-retry backoff (detached or captured on unbind).
---@field _busy_started_at? integer Run clock (`vim.uv.hrtime()/1e9`); first `agent_start` of the run.
---@field _busy_verb? string Active-verb snapshot for view-switch restore.
---@field session_file? string Backend-reported session file path (from get_state responses). Lets the resume picker detect "still open in another tab" without extra RPC round-trips.
---@field startup_announcements table<string, pi.StartupAnnouncement> Extension startup data (keys ending with `:startup`) shown in the system preamble. Process-level: persists across session switches.
---@field system_errors pi.SystemErrorEntry[]
---@field cwd string Working directory the session was started in (anchor for changed_files paths).
---@field changed_files table<string, true> Set of file paths modified by edit/write tools during the current session.
---@field _pending_file_change_args? table<string, table> Pending tool args by tool call id for file-changing tools.
---@field _compaction_rebuilding? boolean True while compacted messages are being fetched/replayed.
---@field _view_rebuilding? boolean True while the tab UI is being rebound to this live session (no switch_session).
---@field _models_cache? { fetched_at: integer, list: table[] } Cached get_available_models result for provider-ambiguity detection (TTL-bounded).
---@field _compaction_event_queue? pi.RpcEvent[] Events received while compacted messages are being fetched/replayed.
---@field _view_event_queue? pi.RpcEvent[] Events received while a live view-switch is fetching/replaying messages.

---@class pi.SessionCreateOpts
---@field layout? pi.LayoutMode

local M = {}

local Rpc = require("pi.rpc")
local Chat = require("pi.ui.chat")
local Config = require("pi.config")
local Startup = require("pi.startup")
local Notify = require("pi.notify")
local Attention = require("pi.attention")
local Dialog = require("pi.ui.dialog")
local Extension = require("pi.ui.extension")
local CommandsCache = require("pi.cache.commands")

---@class pi.StartupSection
---@field header string
---@field items string[]
---@field hl? string

---@param session pi.Session
---@param commands? pi.SlashCommand[]
local function show_startup_block(session, commands)
    if not session.chat then
        return
    end
    local sections = Startup.build_startup_sections(session, commands)
    session.chat:show_startup_block({ sections = sections, errors = session.system_errors })
end

--- Fetch commands and render the startup block on a session's chat.
---@param session pi.Session
local function fetch_commands_and_show_startup_block(session)
    CommandsCache.fetch(session.rpc, function(commands)
        show_startup_block(session, commands)
    end)
end

--- All live sessions keyed by session id (including detached/background processes).
---@type table<string, pi.Session>
local registry = {}

--- Chat UI instance per Neovim tabpage (view layer; rebindable across sessions).
---@type table<pi.TabId, pi.Chat>
local tab_chats = {}

--- Which session id each tab's chat is currently bound to.
---@type table<pi.TabId, string>
local tab_session_id = {}

--- Monotonic counter for temporary session ids before the backend reports `sessionId`.
local next_temp_id = 0

--- Load a session file into an existing RPC process (defined below).
---@type fun(session: pi.Session, session_path: string)
local load_session

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

---@return string
local function alloc_temp_session_id()
    next_temp_id = next_temp_id + 1
    return ("tmp-%d"):format(next_temp_id)
end

--- Keep `pinned_model` in sync with `pinned_config.model` for callers not yet migrated.
---@param session pi.Session
---@param opts { model?: pi.ModelRef, thinking_level?: string }
function M.update_pinned_config(session, opts)
    if not opts.model and not opts.thinking_level then
        return
    end
    session.pinned_config = session.pinned_config or {}
    if opts.model then
        session.pinned_config.model = opts.model
        session.pinned_model = opts.model
    end
    if opts.thinking_level then
        session.pinned_config.thinking_level = opts.thinking_level
    end
end

---@param session pi.Session
---@param new_id string
local function migrate_session_id(session, new_id)
    if session.id == new_id then
        return
    end
    local old_id = session.id
    session.id = new_id
    registry[new_id] = session
    if old_id and registry[old_id] == session then
        registry[old_id] = nil
    end
    if session.attached_tab and tab_session_id[session.attached_tab] == old_id then
        tab_session_id[session.attached_tab] = new_id
    end
    require("pi.subsessions.manifest").bind_session_lineage(session, new_id)
    if old_id and old_id:match("^tmp%-") then
        -- Alias temporary session id to the real id so any stale references
        -- (e.g. aborts issued before migration) resolve to the real lineage.
        -- Never rewrite lineage mappings between two real ids.
        require("pi.subsessions.manifest").register_session_lineage(old_id, new_id)
    end
end

---@param rpc pi.Rpc
---@return pi.ChatAgent
local function make_agent(rpc)
    return {
        send = function(msg, callback)
            return rpc:send(msg, callback)
        end,
    }
end

--- Pin the run clock on first `agent_start`; later starts (retry, post-compaction) keep it.
---@param session pi.Session
local function mark_run_start(session)
    if type(session._busy_started_at) ~= "number" then
        session._busy_started_at = math.floor(vim.uv.hrtime() / 1e9)
    end
    session._detached_busy = true
end

--- Authoritative end of the session-level run (`agent_settled` / process exit).
---@param session pi.Session
local function mark_run_end(session)
    session._busy_started_at = nil
    session._detached_busy = false
    session._detached_compacting = false
    session._detached_retrying = false
    session._busy_verb = nil
end

---@param session pi.Session
---@param status pi.Status?
local function set_chat_status(session, status)
    local chat = session.chat
    if not chat then
        return
    end
    chat:set_status(status, session._busy_started_at)
end

--- Remember compacting/retry/verb when unbinding. Busy + clock stay on the
--- session (event-driven); do not clear them from chat streaming state.
---@param session pi.Session
local function capture_detached_run_state(session)
    local chat = session.chat
    if not chat then
        return
    end
    session._detached_compacting = (chat.is_compacting and chat:is_compacting()) or false
    session._detached_retrying = (chat.is_retrying and chat:is_retrying()) or false
    local verb = chat.active_verb and chat:active_verb() or nil
    if type(verb) == "string" and verb ~= "" then
        session._busy_verb = verb
    end
    if (chat.is_streaming and chat:is_streaming()) or session._detached_retrying or session._detached_compacting then
        session._detached_busy = true
        if type(session._busy_started_at) ~= "number" then
            session._busy_started_at = math.floor(vim.uv.hrtime() / 1e9)
        end
    end
end

--- Bind a tab's chat UI to a session process. Detaches any prior bindings on
--- either side without stopping RPC processes.
---@param session pi.Session
---@param chat pi.Chat
---@param tab pi.TabId
local function bind_chat_to_session(session, chat, tab)
    local prev_id = tab_session_id[tab]
    if prev_id and prev_id ~= session.id then
        local prev = registry[prev_id]
        if prev and prev.attached_tab == tab then
            capture_detached_run_state(prev)
            prev.attached_tab = nil
            prev.tab = nil
            prev.chat = nil
        end
    end

    if session.attached_tab and session.attached_tab ~= tab then
        local prev_tab = session.attached_tab
        if tab_session_id[prev_tab] == session.id then
            tab_session_id[prev_tab] = nil
        end
    end

    chat:bind_agent(make_agent(session.rpc))
    session.chat = chat
    session.attached_tab = tab
    session.tab = tab
    tab_chats[tab] = chat
    tab_session_id[tab] = session.id
end

--- Detach a tab's chat from its session without stopping the backend process.
---@param tab pi.TabId
local function detach_tab(tab)
    local session_id = tab_session_id[tab]
    if session_id then
        local session = registry[session_id]
        if session and session.attached_tab == tab then
            if not (session.rpc and session.rpc:is_running()) then
                Attention.clear_session(session)
            end
            session.attached_tab = nil
            session.tab = nil
            session.chat = nil
        end
        tab_session_id[tab] = nil
    end

    local chat = tab_chats[tab]
    if chat then
        chat:hide()
        chat:clear()
        tab_chats[tab] = nil
    end
end

---@param session pi.Session
---@param state table? get_state response data
local function capture_session_id(session, state)
    if type(state) ~= "table" then
        return
    end
    local id = state.sessionId
    if (not id or id == "") and type(state.sessionFile) == "string" and state.sessionFile ~= "" then
        local info = require("pi.sessions.history").parse(state.sessionFile)
        id = info and info.id
    end
    if type(id) ~= "string" or id == "" then
        return
    end
    migrate_session_id(session, id)
end

--- Events we've reviewed and deliberately choose not to handle.
--- turn_start/turn_end: TUI doesn't handle them; lifecycle is fully
--- covered by message_start / message_end / agent_end.
--- thinking_level_changed: pi.nvim refreshes state through command
--- callbacks; this is a redundant notification.
---@type table<string, true>
local ignored_events = {
    turn_start = true,
    turn_end = true,
    thinking_level_changed = true,
}

--- Lifecycle transitions the sessions overview (:PiSessions) tracks. The
--- list module coalesces redraws and is a no-op while no list window is
--- visible, so this stays cheap on the hot path.
---@type table<string, true>
local sessions_list_events = {
    agent_start = true,
    agent_end = true,
    agent_settled = true,
    compaction_start = true,
    compaction_end = true,
    auto_compaction_start = true,
    auto_compaction_end = true,
    _process_exit = true,
}

---@type fun(session: pi.Session, result: table, will_retry: boolean)?
local rebuild_after_compaction

---@type fun(session: pi.Session, flush_queue?: boolean, will_retry?: boolean)?
local finish_compaction_rebuild

---@type fun(session: pi.Session)?
local finish_view_rebuild

---@param session pi.Session
local function restore_active_agent_status(session)
    local chat = session.chat
    if not chat then
        return
    end
    -- Compaction/retry cleanup can fire after agent_end (between turns).
    -- Only restore the spinner if an agent loop is still active.
    local active_verb = chat:active_verb()
    if active_verb then
        chat:set_status({ type = "agent", text = active_verb .. "…" }, session._busy_started_at)
    else
        chat:set_status(nil)
    end
end

---@param args any
---@return table?
local function normalize_tool_args(args)
    if type(args) == "table" then
        return args
    end
    if type(args) ~= "string" or args == "" then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, args)
    if ok and type(decoded) == "table" then
        return decoded
    end
    return nil
end

---@param args table?
---@return string?
local function get_changed_file_path(args)
    if type(args) ~= "table" then
        return nil
    end
    local path = args.path or args.file_path or args.filePath
    if type(path) == "string" and path ~= "" then
        return path
    end
    return nil
end

---@param session pi.Session
---@param args table?
local function track_changed_file(session, args)
    local path = get_changed_file_path(args)
    if path then
        session.changed_files[path] = true
    end
end

---@param session pi.Session
---@param tool_name string?
---@param tool_call_id string?
---@param args any
local function stash_file_tool_args(session, tool_name, tool_call_id, args)
    if (tool_name ~= "edit" and tool_name ~= "write") or type(tool_call_id) ~= "string" or tool_call_id == "" then
        return
    end
    local decoded = normalize_tool_args(args)
    if not decoded then
        return
    end
    session._pending_file_change_args = session._pending_file_change_args or {}
    session._pending_file_change_args[tool_call_id] = decoded
end

--- Remember the backend's current session file path from a get_state
--- response, next to the model pin. The resume picker uses this to warn when
--- a picked conversation is still live in another tab.
---@param session pi.Session
---@param state table? get_state response data
local function capture_session_file(session, state)
    if type(state) == "table" and type(state.sessionFile) == "string" and state.sessionFile ~= "" then
        session.session_file = state.sessionFile
    end
end

--- Seconds the cached get_available_models result stays usable for the
--- provider-ambiguity check before a refetch.
local MODEL_LIST_TTL = 60

--- Reconcile the provider-ambiguity suffix shown by the statusline model
--- component against the backend model list. The list is fetched at most
--- once per TTL per session and cached; the push is keyed by provider/id so
--- the statusline drops it when the model switched while the fetch was in
--- flight. Failure is silent — the suffix just stays nil (bare model id).
---@param session pi.Session
---@param state table? get_state response data
local function refresh_model_ambiguity(session, state)
    local model = type(state) == "table" and state.model or nil
    if type(model) ~= "table" or type(model.id) ~= "string" or type(model.provider) ~= "string" then
        return
    end
    local Models = require("pi.models")
    local cache = session._models_cache
    if cache and type(cache.list) == "table" and os.time() - cache.fetched_at < MODEL_LIST_TTL then
        -- Cache usable only when it still covers the current model; a list
        -- from a different backend config (provider removed) must not decide.
        local covered = false
        for _, m in ipairs(cache.list) do
            if type(m) == "table" and m.id == model.id then
                covered = true
                break
            end
        end
        if covered then
            if session.chat then
                session.chat:set_model_ambiguity_for(
                    model.provider,
                    model.id,
                    Models.ambiguity_suffix(model, cache.list)
                )
            end
            return
        end
    end
    session.rpc:send({ type = "get_available_models" }, function(res)
        vim.schedule(function()
            local list = res.success and res.data and res.data.models or nil
            if type(list) ~= "table" then
                return
            end
            session._models_cache = { fetched_at = os.time(), list = list }
            if session.chat then
                session.chat:set_model_ambiguity_for(model.provider, model.id, Models.ambiguity_suffix(model, list))
            end
        end)
    end)
end

--- Fetch the backend state and update the status line.
---@param session pi.Session
function M.refresh_state(session)
    session.rpc:send({ type = "get_state" }, function(res)
        if res.success and res.data then
            vim.schedule(function()
                capture_session_id(session, res.data)
                capture_session_file(session, res.data)
                if session.chat then
                    session.chat:update_state(res.data)
                    refresh_model_ambiguity(session, res.data)
                end
            end)
        end
    end)
end

--- Capture the backend's current model/thinking as this session's pinned config.
---@param session pi.Session
---@param state table? get_state response data
local function capture_config_pin(session, state)
    if type(state) ~= "table" then
        return
    end
    local model = state.model
    local thinking = state.thinkingLevel
    if type(model) == "table" and type(model.provider) == "string" and type(model.id) == "string" then
        M.update_pinned_config(session, {
            model = { provider = model.provider, id = model.id },
            thinking_level = type(thinking) == "string" and thinking or nil,
        })
    end
end

--- Fetch current state, update the status line, and (re)capture the config pin.
--- Used where the backend's model is authoritative for this tab: session
--- creation (core resolves it from global settings) and session resume
--- (core restores it from the session file).
---@param session pi.Session
local function refresh_state_and_pin(session)
    session.rpc:send({ type = "get_state" }, function(res)
        if res.success and res.data then
            vim.schedule(function()
                capture_config_pin(session, res.data)
                capture_session_id(session, res.data)
                capture_session_file(session, res.data)
                if session.chat then
                    session.chat:update_state(res.data)
                    refresh_model_ambiguity(session, res.data)
                end
            end)
        end
    end)
end

--- Re-apply the session's pinned config after a `new_session`.
--- Core resolves a fresh session's model from global settings — i.e. the last
--- model selected in *any* session — so without this, another tab's model
--- switch would leak into this tab's next conversation. On failure the pinned
--- config is no longer usable (auth revoked, model gone): fall back silently
--- and resync the pin to the model core chose.
---@param session pi.Session
local function reapply_pinned_config(session)
    local pin = session.pinned_config
    if not pin or not pin.model then
        refresh_state_and_pin(session)
        return
    end

    local function after_model()
        if pin.thinking_level then
            local sent_level = session.rpc:send(
                { type = "set_thinking_level", level = pin.thinking_level },
                function(res)
                    vim.schedule(function()
                        if res.success then
                            M.refresh_state(session)
                        else
                            refresh_state_and_pin(session)
                        end
                    end)
                end
            )
            if not sent_level then
                refresh_state_and_pin(session)
            end
        else
            M.refresh_state(session)
        end
    end

    local sent = session.rpc:send(
        { type = "set_model", provider = pin.model.provider, modelId = pin.model.id },
        function(res)
            vim.schedule(function()
                if res.success then
                    after_model()
                else
                    refresh_state_and_pin(session)
                end
            end)
        end
    )
    if not sent then
        refresh_state_and_pin(session)
    end
end

--- Central event handler for a session.
--- Route a raw RPC event into the session's chat and companion modules.
--- Exposed (not just local) so the retry/abort wiring is unit-testable with a
--- fake session; the RPC handler calls it for every decoded message.
---@param session pi.Session
---@param msg pi.RpcEvent
---@return boolean handled
function M.handle_event(session, msg)
    local t = msg.type
    local chat = session.chat

    if sessions_list_events[t] then
        require("pi.ui.sessions").request_refresh()
    end

    local is_subagent_host = (t == "extension_ui_request" and msg.method == "select" and msg.title == "__pi_subagent__")

    -- Buffer inbound events while a get_messages replay is in flight
    -- (compaction rebuild or live view-switch). `response` and subagent host
    -- requests are excluded so RPC callbacks and subagent tunnel still fire.
    if (session._compaction_rebuilding or session._view_rebuilding) and t ~= "response" and not is_subagent_host then
        if t == "_process_exit" then
            if session._compaction_rebuilding and finish_compaction_rebuild then
                finish_compaction_rebuild(session, false)
            end
            if session._view_rebuilding and finish_view_rebuild then
                finish_view_rebuild(session)
            end
        else
            if session._view_rebuilding then
                session._view_event_queue = session._view_event_queue or {}
                session._view_event_queue[#session._view_event_queue + 1] = msg
            else
                session._compaction_event_queue = session._compaction_event_queue or {}
                session._compaction_event_queue[#session._compaction_event_queue + 1] = msg
            end
            return true
        end
    end

    if t == "agent_start" then
        mark_run_start(session)
        session._detached_retrying = false
        require("pi.ui.sessions").on_agent_start(session)
        if chat then
            chat:on_agent_start(nil, session._busy_started_at)
            session._busy_verb = chat:active_verb()
        end
    elseif t == "agent_end" then
        require("pi.ui.sessions").on_agent_end(session)
        CommandsCache.refresh(session.rpc)
        M.refresh_state(session)
        if chat then
            chat:on_agent_end()
        end
    elseif t == "agent_settled" then
        -- Authoritative end of the session-level run: pi emits this only after
        -- no retry, compaction retry, or queued continuation remains. The
        -- compaction/retry branches above restore state piecemeal; this is the
        -- final fallback that converges any leftover spinner.
        mark_run_end(session)
        if session.parent_id then
            require("pi.subsessions").on_child_settled(session)
        end
        if chat then
            chat:set_status(nil)
        end
    elseif t == "message_update" then
        local event = msg.assistantMessageEvent
        if event then
            if event.type == "toolcall_end" then
                local tool_call = event.toolCall
                if type(tool_call) == "table" then
                    stash_file_tool_args(session, tool_call.name, tool_call.id, tool_call.arguments)
                end
            end
            if chat then
                if event.type == "thinking_start" then
                    chat:on_thinking_start()
                elseif event.type == "thinking_delta" then
                    chat:on_thinking_delta(event.delta or "")
                elseif event.type == "thinking_end" then
                    chat:on_thinking_end()
                elseif event.type == "text_delta" then
                    chat:on_thinking_end() -- no-op if not thinking
                    chat:on_text_delta(event.delta or "")
                end
                -- NOTE: Other sub-events stay intentionally ignored:
                --   toolcall_start/delta — we render on tool_execution_start.
                --   start, done — redundant with message_start/end.
                --   text_start, text_end — text_delta suffices.
            end
        end
    elseif t == "tool_execution_start" then
        local args = normalize_tool_args(msg.args) or msg.args
        -- Stash args for file-changing tools; tool_execution_end doesn't carry args.
        stash_file_tool_args(session, msg.toolName, msg.toolCallId, args)
        if chat then
            chat:on_tool_start(msg.toolName or "tool", msg.toolCallId, args)
            -- Stash search-tool args so the quickfix list can be titled with the pattern.
            require("pi.quickfix").on_tool_start(msg.toolName, msg.toolCallId, args)
        end
    elseif t == "tool_execution_end" then
        if chat then
            chat:on_tool_end(msg.toolName or "tool", msg.toolCallId, msg.result, msg.isError)
            vim.schedule(function()
                require("pi.quickfix").on_tool_end(msg.toolName, msg.toolCallId, msg.result, msg.isError)
            end)
        end
        if session._pending_file_change_args and not msg.isError then
            local args = session._pending_file_change_args[msg.toolCallId]
            track_changed_file(session, args)
            session._pending_file_change_args[msg.toolCallId] = nil
            local changed_path = get_changed_file_path(args)
            if changed_path then
                vim.schedule(function()
                    require("pi.reload").on_file_changed(changed_path)
                end)
            end
        end
    elseif t == "compaction_start" or t == "auto_compaction_start" then
        session._detached_compacting = true
        if chat then
            chat:set_compacting(true)
            set_chat_status(session, { type = "compaction" })
        end
    elseif t == "compaction_end" or t == "auto_compaction_end" then
        session._detached_compacting = false
        if type(msg.errorMessage) == "string" and msg.errorMessage ~= "" then
            require("pi.ui.sessions").mark_error(session)
        end
        if chat then
            if msg.aborted then
                chat:set_compacting(false)
                restore_active_agent_status(session)
                chat:on_error("Compaction cancelled", { pad_top = true, pad_bottom = true })
                chat:flush_compaction_queue(msg.willRetry == true)
            elseif type(msg.errorMessage) == "string" and msg.errorMessage ~= "" then
                chat:set_compacting(false)
                restore_active_agent_status(session)
                chat:on_error(msg.errorMessage, { pad_top = true, pad_bottom = true })
                chat:flush_compaction_queue(msg.willRetry == true)
            elseif type(msg.result) == "table" and rebuild_after_compaction then
                rebuild_after_compaction(session, msg.result, msg.willRetry == true)
            else
                chat:set_compacting(false)
                restore_active_agent_status(session)
                chat:flush_compaction_queue(msg.willRetry == true)
            end
        end
    elseif t == "auto_retry_start" then
        session._detached_retrying = true
        mark_run_start(session)
        if chat then
            chat:set_retrying(true)
            set_chat_status(session, { type = "agent", text = "Retrying…" })
        end
    elseif t == "auto_retry_end" then
        session._detached_retrying = false
        if msg.success == false then
            require("pi.ui.sessions").mark_error(session)
            mark_run_end(session)
        end
        if chat then
            chat:set_retrying(false)
            if msg.success == false then
                chat:set_status(nil)
                chat:on_error(
                    "Retry failed after "
                        .. tostring(msg.attempt or 0)
                        .. " attempts: "
                        .. (msg.finalError or "Unknown error"),
                    { pad_top = true, pad_bottom = true }
                )
            else
                restore_active_agent_status(session)
            end
        end
    elseif t == "summarization_retry_scheduled" then
        -- Transient error while generating a compaction or branch summary.
        -- Compaction retries are already covered by the ongoing compaction
        -- status; branch summaries run while the agent is idle, so there is
        -- nothing to restore either way. Surface the error in debug mode only
        -- (on_error would render a scary red block for a transient hiccup).
        if Config.options.debug then
            vim.schedule(function()
                vim.notify(
                    "Summary retry scheduled (attempt "
                        .. tostring(msg.attempt or "?")
                        .. "/"
                        .. tostring(msg.maxAttempts or "?")
                        .. "): "
                        .. (msg.errorMessage or "unknown error"),
                    vim.log.levels.WARN,
                    { title = "pi" }
                )
            end)
        end
    elseif t == "summarization_retry_attempt_start" then
        if chat and msg.source == "branchSummary" then
            -- navigateTree summarization runs while the agent is idle: show a
            -- lightweight busy state. Compaction-source retries keep the
            -- existing compaction status untouched.
            chat:set_status({ type = "summary", text = "Summarizing branch…" })
        end
    elseif t == "summarization_retry_finished" then
        -- Retry loop ended. During compaction, compaction_end restores the
        -- status; only the branchSummary state (agent idle) needs settling.
        if chat and not chat:is_compacting() then
            restore_active_agent_status(session)
        end
    elseif t == "extension_ui_request" then
        vim.schedule(function()
            Extension.handle(session, msg)
        end)
    elseif t == "session_info_changed" then
        require("pi.ui.sessions").on_session_info_changed(session, msg.name)
    elseif t == "extension_error" then
        local extension_path = type(msg.extensionPath) == "string" and msg.extensionPath or "unknown extension"
        local extension_event = type(msg.event) == "string" and msg.event or "unknown event"
        local error_message = type(msg.error) == "string" and msg.error or "Unknown error"
        local formatted = "Extension error ("
            .. vim.fn.fnamemodify(extension_path, ":~:.")
            .. ", "
            .. extension_event
            .. "):\n"
            .. error_message
        session.system_errors = session.system_errors or {}
        session.system_errors[#session.system_errors + 1] = {
            message = formatted,
            timestamp = os.time() * 1000,
        }
        if chat then
            chat:on_system_error(formatted, { pad_top = true, pad_bottom = true })
        end
    elseif t == "_stderr" then
        if type(msg.message) == "string" and msg.message ~= "" then
            session.system_errors = session.system_errors or {}
            session.system_errors[#session.system_errors + 1] = {
                message = msg.message --[[@as string]],
                timestamp = os.time() * 1000,
            }
            if chat then
                chat:on_system_error(msg.message --[[@as string]], { pad_top = true, pad_bottom = true })
            end
        end
    elseif t == "_process_exit" then
        mark_run_end(session)
        if session.id then
            registry[session.id] = nil
        end
        if chat then
            vim.schedule(function()
                chat:set_status(nil)
                if Config.options.debug and msg.code ~= 0 and msg.code ~= 143 then
                    print("Process exited with code " .. (msg.code or "-"))
                end
            end)
        end
    elseif t == "response" then
        -- Normally handled by rpc:send() one-shot callbacks. Late error
        -- responses (e.g. async prompt failures like auth errors) arrive
        -- after the initial success response already consumed the callback.
        if msg.success == false then
            require("pi.ui.sessions").mark_error(session)
            if chat and type(msg.error) == "string" then
                chat:on_error(msg.error, { pad_top = true, pad_bottom = true })
            end
        end
        return false
    elseif t == "message_start" then
        if chat then
            chat:on_message_start(msg)
        end
    elseif t == "message_end" then
        require("pi.ui.sessions").on_message_end(session)
        local message = msg.message
        if type(message) == "table" and message.stopReason == "error" then
            require("pi.ui.sessions").mark_error(session)
        end
        if type(message) == "table" and message.role == "toolResult" and session._pending_file_change_args then
            local tool_call_id = message.toolCallId or message.toolUseId
            if type(tool_call_id) == "string" and tool_call_id ~= "" then
                if message.isError ~= true then
                    local args = session._pending_file_change_args[tool_call_id]
                    track_changed_file(session, args)
                end
                session._pending_file_change_args[tool_call_id] = nil
            end
        end
        if chat then
            chat:on_message_end(msg)
        end
    elseif t == "tool_execution_update" then
        if chat then
            chat:on_tool_update(msg.toolName or "tool", msg.toolCallId, msg)
        end
    elseif t == "queue_update" then
        if chat then
            chat:on_queue_update(msg)
        end
    elseif t == "bash_execution_update" then
        if chat then
            chat:on_bash_update(msg.id, msg.delta or "")
        end
    elseif ignored_events[t] then
        return true
    else
        Rpc.log_unhandled(t)
        return false
    end

    return true
end

---@param session pi.Session
---@param flush_queue? boolean default true
---@param will_retry? boolean
finish_compaction_rebuild = function(session, flush_queue, will_retry)
    local queued = session._compaction_event_queue or {}
    session._compaction_event_queue = {}
    session._compaction_rebuilding = false
    local chat = session.chat
    if not chat then
        for _, queued_msg in ipairs(queued) do
            M.handle_event(session, queued_msg)
        end
        return
    end
    chat:set_compacting(false)
    restore_active_agent_status(session)
    if flush_queue ~= false then
        session.chat:flush_compaction_queue(will_retry == true)
    end

    for i, queued_msg in ipairs(queued) do
        if session._compaction_rebuilding then
            local active_queue = session._compaction_event_queue or {}
            for j = i, #queued do
                active_queue[#active_queue + 1] = queued[j]
            end
            session._compaction_event_queue = active_queue
            return
        end
        M.handle_event(session, queued_msg)
    end
end

---@param session pi.Session
local function restore_view_run_state(session)
    local chat = session.chat
    if not chat then
        return
    end
    local start_time = session._busy_started_at
    if session._detached_compacting then
        chat:set_compacting(true)
        chat:set_status({ type = "compaction" }, start_time)
    elseif session._detached_retrying then
        chat:set_retrying(true)
        chat:set_status({ type = "agent", text = "Retrying…" }, start_time)
    elseif session._detached_busy then
        chat:restore_busy(session._busy_verb, start_time)
    else
        restore_active_agent_status(session)
    end
end

--- Drain events buffered during a live view-switch rebuild.
---@param session pi.Session
finish_view_rebuild = function(session)
    local queued = session._view_event_queue or {}
    session._view_event_queue = {}
    session._view_rebuilding = false
    restore_view_run_state(session)

    for i, queued_msg in ipairs(queued) do
        if session._view_rebuilding or session._compaction_rebuilding then
            local dest
            if session._view_rebuilding then
                dest = session._view_event_queue or {}
                session._view_event_queue = dest
            else
                dest = session._compaction_event_queue or {}
                session._compaction_event_queue = dest
            end
            for j = i, #queued do
                dest[#dest + 1] = queued[j]
            end
            return
        end
        M.handle_event(session, queued_msg)
    end
end

--- Get the session for the current tab. Returns nil if none exists.
---@return pi.Session?
function M.get()
    return M.get_for_tab(current_tab())
end

--- Get the session bound to a tabpage. Returns nil if none exists.
---@param tab pi.TabId
---@return pi.Session?
function M.get_for_tab(tab)
    local session_id = tab_session_id[tab]
    if session_id then
        return registry[session_id]
    end
    return nil
end

--- List sessions currently attached to a tab, in tabline order.
---
--- Tabpage handles reflect creation order, not position: a tab created while
--- tab 1 is current lands between tabs 1 and 2, and :tabmove reorders tabs
--- without touching handles. Sorting by handle would therefore disagree with
--- the tabline; rank by the visual order of nvim_list_tabpages() instead.
---@return pi.Session[]
function M.list()
    ---@type table<pi.TabId, integer> visual position per tab
    local rank = {}
    for i, tab in ipairs(vim.api.nvim_list_tabpages()) do
        rank[tab] = i
    end
    ---@type pi.Session[]
    local result = {}
    for _, session in pairs(registry) do
        if session.attached_tab then
            result[#result + 1] = session
        end
    end
    table.sort(result, function(a, b)
        return (rank[a.attached_tab] or math.huge) < (rank[b.attached_tab] or math.huge)
    end)
    return result
end

--- All live sessions in the registry (attached and detached).
---@return pi.Session[]
function M.list_all()
    ---@type pi.Session[]
    local result = {}
    for _, session in pairs(registry) do
        result[#result + 1] = session
    end
    return result
end

--- Look up a session by id.
---@param id string
---@return pi.Session?
function M.get_by_id(id)
    return registry[id]
end

--- Find a live session whose manifest lineage matches `lineage_id`.
--- Manifest child rows store `parent_id` as lineage, not necessarily the current registry id.
---@param lineage_id string
---@return pi.Session?
function M.find_by_lineage(lineage_id)
    if type(lineage_id) ~= "string" or lineage_id == "" then
        return nil
    end
    local Manifest = require("pi.subsessions.manifest")
    local target = Manifest.resolve_lineage(lineage_id) or lineage_id
    local direct = registry[lineage_id] or registry[target]
    if direct then
        return direct
    end
    for _, session in pairs(registry) do
        if Manifest.lineage_for_session(session) == target then
            return session
        end
    end
    return nil
end

--- Bind a tab's chat UI to a session process (for sub-session switching in later phases).
---@param session pi.Session
---@param chat pi.Chat
---@param tab pi.TabId
function M.bind_chat(session, chat, tab)
    bind_chat_to_session(session, chat, tab)
    require("pi.ui.sessions").request_refresh()
end

--- Migrate or assign a session's registry id.
---@param session pi.Session
---@param id string
function M.ensure_id(session, id)
    migrate_session_id(session, id)
end

--- Create a background session process without binding a tab chat UI.
---@param tab pi.TabId RPC job identity (usually the parent's tab).
---@param opts? { subagent?: boolean }
---@return pi.Session?
function M.create_detached(tab, opts)
    opts = opts or {}
    local rpc = Rpc.new(tab)
    if not rpc:start({ subagent = opts.subagent }) then
        return nil
    end

    ---@type pi.Session
    local session = {
        id = alloc_temp_session_id(),
        rpc = rpc,
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        cwd = vim.fn.getcwd(),
        changed_files = {},
    }

    registry[session.id] = session

    rpc:set_handler(function(msg)
        M.handle_event(session, msg)
    end)

    refresh_state_and_pin(session)
    require("pi.ui.sessions").request_refresh()
    return session
end

--- Stop a session process and remove it from the registry.
---@param session pi.Session
function M.close_session(session)
    if session.attached_tab then
        detach_tab(session.attached_tab)
    end
    Attention.clear_session(session)
    session.rpc:stop()
    if session.id then
        registry[session.id] = nil
    end
    require("pi.ui.sessions").request_refresh()
end

---@class pi.LoadSessionOpts
---@field rebind_parent_context? boolean Reset lineage/view state for :PiResume (default true). Set false for sub-session switches.

--- Load a session file into an existing session (exported for sub-session switching).
---@param session pi.Session
---@param session_path string
---@param callback? fun(ok: boolean)
---@param opts? pi.LoadSessionOpts
function M.load_session_path(session, session_path, callback, opts)
    load_session(session, session_path, opts, callback)
end

--- Open a fresh session in a new tabpage (`:tabnew` then show).
--- Uses `layout.default` from config; no per-invocation layout override.
function M.new_tab()
    vim.cmd("tabnew")
    local session = M.get_or_create()
    if session then
        session.chat:ensure_shown_and_focus_prompt()
    end
end

--- Get or create a session for the current tab.
---@param opts? pi.SessionCreateOpts
---@return pi.Session?
function M.get_or_create(opts)
    opts = opts or {}

    local tab = current_tab()

    local bound_id = tab_session_id[tab]
    if bound_id then
        local existing = registry[bound_id]
        if existing and existing.rpc:is_running() then
            return existing
        end
    end

    local rpc = Rpc.new(tab)

    if not rpc:start() then
        Notify.error("Failed to start process")
        return nil
    end

    local layout = opts.layout or Config.resolve_default_layout_mode()

    local chat = tab_chats[tab]
    if not chat then
        chat = Chat.new(tab, layout, make_agent(rpc))
    else
        chat:bind_agent(make_agent(rpc))
    end

    ---@type pi.Session
    local session = {
        id = alloc_temp_session_id(),
        rpc = rpc,
        attention = { pending = {} },
        startup_announcements = {},
        system_errors = {},
        cwd = vim.fn.getcwd(),
        changed_files = {},
    }

    registry[session.id] = session
    bind_chat_to_session(session, chat, tab)

    -- Prompt history is scoped per workspace: anchor it to the session cwd.
    chat:set_cwd(session.cwd)

    rpc:set_handler(function(msg)
        M.handle_event(session, msg)
    end)

    require("pi.ui.sessions").request_refresh()

    -- Fetch available /commands for completion, highlighting, and system info
    fetch_commands_and_show_startup_block(session)

    -- Fetch initial state for status line (model, thinking level) and
    -- capture the initial config pin.
    refresh_state_and_pin(session)

    return session
end

--- Stop the current tab's session process and detach its chat.
function M.stop()
    local tab = current_tab()
    local session_id = tab_session_id[tab]
    if not session_id then
        return
    end
    local session = registry[session_id]
    if not session then
        return
    end

    Attention.clear_session(session)
    session.rpc:stop()
    detach_tab(tab)
    registry[session_id] = nil
    require("pi.ui.sessions").request_refresh()
end

---@param session pi.Session
local function start_new_session(session)
    if
        not session.attached_tab
        or tab_session_id[session.attached_tab] ~= session.id
        or not session.rpc:is_running()
    then
        return
    end

    Attention.begin_session_transition(session)
    local sent = session.rpc:send({ type = "abort" }, function(abort_res)
        if not abort_res.success then
            vim.schedule(function()
                Attention.end_session_transition(session, false)
                Notify.error(abort_res.error or "Failed to abort current session")
            end)
            return
        end
        local sent_new = session.rpc:send({ type = "new_session" }, function(res)
            local data = res.data or {}
            vim.schedule(function()
                if not res.success then
                    Attention.end_session_transition(session, false)
                    Notify.error(res.error or "Failed to start new session")
                    return
                end
                if data.cancelled then
                    Attention.end_session_transition(session, false)
                    Notify.warn("New session was cancelled")
                    return
                end
                Attention.end_session_transition(session, true)
                require("pi.subsessions").on_parent_new_conversation(session)
                require("pi.ui.sessions").invalidate(session)
                require("pi.ui.sessions").clear_flags(session)
                require("pi.ui.sessions").request_refresh()
                session.startup_announcements = {}
                session.system_errors = {}
                session.changed_files = {}
                session._pending_file_change_args = nil
                session.chat:clear()
                reapply_pinned_config(session)
                fetch_commands_and_show_startup_block(session)
                M.refresh_state(session)
            end)
        end)
        if not sent_new then
            vim.schedule(function()
                Attention.end_session_transition(session, false)
            end)
        end
    end)
    if not sent then
        Attention.end_session_transition(session, false)
    end
end

--- Run `start_new_session` on `session`, prompting when the agent is streaming.
---@param session pi.Session
local function new_session_with_confirm(session)
    if not session.chat:is_streaming() then
        start_new_session(session)
        return
    end

    Dialog.confirm({
        title = "Start new session?",
        message = "This opens a fresh session. You can resume the current conversation later.",
    }, function(confirmed)
        if not confirmed then
            return
        end
        start_new_session(session)
    end)
end

--- Start a new conversation in the current tab's session.
function M.new_session()
    local session = M.get()
    if not session or not session.rpc:is_running() then
        return
    end

    if session.view_parent_id then
        require("pi.subsessions").switch_to_parent(function(ok, err)
            if not ok then
                Notify.error(err or "failed to switch to parent session")
                return
            end
            local parent = M.get()
            if not parent or not parent.rpc:is_running() then
                Notify.error("parent session not running")
                return
            end
            new_session_with_confirm(parent)
        end, { for_new_session = true })
        return
    end

    new_session_with_confirm(session)
end

--- Replay messages from get_messages response into chat.
---@param session pi.Session
---@param messages table[]
local function replay_messages(session, messages)
    session.chat:set_replaying(true)
    local pending_agent_end = false
    local tool_call_args = {} ---@type table<string, table>
    for _, msg in ipairs(messages) do
        local role = msg.role
        -- Flush pending agent_end before a user message
        if pending_agent_end and role == "user" then
            session.chat:on_agent_end()
            pending_agent_end = false
        end
        if role == "user" then
            local text = ""
            local image_count = 0
            if type(msg.content) == "string" then
                text = msg.content
            elseif type(msg.content) == "table" then
                for _, part in ipairs(msg.content) do
                    if type(part) == "string" then
                        text = text .. part
                    elseif type(part) == "table" and part.type == "text" then
                        text = text .. (part.text or "")
                    elseif type(part) == "table" and part.type == "image" then
                        image_count = image_count + 1
                    end
                end
            end
            local parsed = require("pi.vision").parse(text)
            if parsed.model then
                -- Vision-transformed message: original text + description block.
                if parsed.text ~= "" then
                    session.chat:add_user_message(parsed.text, msg.timestamp, nil)
                end
                session.chat:add_vision_block(parsed.model, parsed.description or "")
            elseif text ~= "" or image_count > 0 then
                session.chat:add_user_message(text, msg.timestamp, image_count > 0 and image_count or nil)
            end
        elseif role == "assistant" then
            local text = ""
            local tool_calls = {} ---@type { id: string, name: string, args: table? }[]
            local thinking_parts = {} ---@type string[]
            if type(msg.content) == "string" then
                text = msg.content
            elseif type(msg.content) == "table" then
                for _, part in ipairs(msg.content) do
                    if type(part) == "string" then
                        text = text .. part
                    elseif type(part) == "table" and part.type == "text" then
                        text = text .. (part.text or "")
                    elseif type(part) == "table" and part.type == "thinking" then
                        local t = part.thinking or ""
                        if t ~= "" then
                            thinking_parts[#thinking_parts + 1] = t
                        end
                    elseif type(part) == "table" and part.type == "toolCall" then
                        tool_calls[#tool_calls + 1] = {
                            id = part.toolCallId or part.id or "",
                            name = part.toolName or part.name or "tool",
                            args = normalize_tool_args(part.arguments or part.args or part.input),
                        }
                    end
                end
            end
            -- Replay thinking as a single block (session files store at most
            -- one thinking part per assistant message).
            local thinking_text = table.concat(thinking_parts, "\n")
            if text ~= "" or #tool_calls > 0 or thinking_text ~= "" then
                -- Suppress agent header for tool-only continuation turns:
                -- if previous turn was tool-only and this turn is also tool-only,
                -- skip the header to keep consecutive tool calls visually grouped.
                -- A turn with thinking is NOT tool-only — the thinking block
                -- needs the agent header above it.
                local tool_only = text == "" and #tool_calls > 0 and thinking_text == ""
                if not (tool_only and pending_agent_end) then
                    if pending_agent_end then
                        session.chat:on_agent_end()
                        pending_agent_end = false
                    end
                    session.chat:on_agent_start(msg.timestamp)
                end
                if thinking_text ~= "" then
                    -- Replayed blocks have no timing data; don't fabricate a duration.
                    session.chat:on_thinking_start({ unmeasured = true })
                    session.chat:on_thinking_delta(thinking_text)
                    session.chat:on_thinking_end()
                end
                if text ~= "" then
                    session.chat:on_text_delta(text)
                end
                -- Don't call on_agent_end yet — tool results follow as separate messages.
                -- Store pending tool calls so on_tool_end can fire before on_agent_end.
                for _, tc in ipairs(tool_calls) do
                    session.chat:on_tool_start(tc.name, tc.id, tc.args)
                    if tc.args then
                        tool_call_args[tc.id] = tc.args
                    end
                end
                if #tool_calls == 0 then
                    session.chat:on_agent_end()
                else
                    pending_agent_end = true
                end
            end
            local stop = msg.stopReason
            if stop ~= "aborted" and stop ~= "error" and type(msg.usage) == "table" then
                session.chat:add_usage(msg.usage)
            end
        elseif role == "toolResult" then
            local tool_call_id = msg.toolCallId or msg.toolUseId or ""
            local tool_name = msg.toolName or "tool"
            local is_error = msg.isError == true
            -- msg itself has .content, matching what on_tool_end expects as result
            session.chat:on_tool_end(tool_name, tool_call_id, msg, is_error)
            -- Track files changed by edit/write tools during replay.
            local tc_args = not is_error and tool_call_args[tool_call_id]
            if tc_args then
                track_changed_file(session, tc_args)
            end
        elseif role == "compactionSummary" then
            if pending_agent_end then
                session.chat:on_agent_end()
                pending_agent_end = false
            end
            session.chat:append_compaction_summary(msg.summary or "", tonumber(msg.tokensBefore) or 0)
        elseif role == "bashExecution" then
            if pending_agent_end then
                session.chat:on_agent_end()
                pending_agent_end = false
            end
            session.chat:on_bash_replay(msg)
        end
    end
    -- Flush any remaining pending agent_end
    if pending_agent_end then
        session.chat:on_agent_end()
    end
    session.chat:set_replaying(false)
end

---@param session pi.Session
---@param _result table
---@param will_retry boolean
rebuild_after_compaction = function(session, _result, will_retry)
    session._compaction_rebuilding = true
    session._compaction_event_queue = {}
    if will_retry and session.chat then
        session.chat:flush_compaction_queue(true)
    end

    local sent = session.rpc:send({ type = "get_messages" }, function(res)
        vim.schedule(function()
            if not session.chat then
                finish_compaction_rebuild(session, not will_retry, will_retry)
                return
            end
            if not res.success then
                local err = res.error or "Failed to load compacted session messages"
                Notify.error(err)
                session.chat:on_error(err, { pad_top = true, pad_bottom = true })
                finish_compaction_rebuild(session, not will_retry, will_retry)
                return
            end

            local messages = (res.data or {}).messages or {}
            session.changed_files = {}
            session._pending_file_change_args = nil
            session.chat:clear_for_compaction_rebuild()
            show_startup_block(session, CommandsCache.list())
            replay_messages(session, messages)
            M.refresh_state(session)
            vim.schedule(function()
                finish_compaction_rebuild(session, not will_retry, will_retry)
            end)
        end)
    end)
    if not sent then
        finish_compaction_rebuild(session, false)
    end
end

--- Reload the current session's messages into the chat: clear -> get_messages
--- -> replay. Used after in-place session-tree navigation (:PiTree), where the
--- backend moved the leaf and the active branch's context changed.
---@param session pi.Session
function M.reload_messages(session)
    vim.schedule(function()
        session.changed_files = {}
        session._pending_file_change_args = nil
        session.chat:clear()
        session.chat:show_loading()
    end)

    local sent = session.rpc:send({ type = "get_messages" }, function(res)
        vim.schedule(function()
            session.chat:clear_placeholder()
            if not res.success then
                local err = res.error or "Failed to load session messages"
                Notify.error(err)
                session.chat:on_error(err, { pad_top = true, pad_bottom = true })
                session.chat:ensure_shown_and_focus_prompt()
                return
            end

            local messages = (res.data or {}).messages or {}
            -- Fetch commands, show startup block, then replay.
            CommandsCache.fetch(session.rpc, function(commands)
                show_startup_block(session, commands)
                replay_messages(session, messages)
                M.refresh_state(session)
                session.chat:ensure_shown_and_focus_prompt()
            end)
        end)
    end)
    if not sent then
        vim.schedule(function()
            session.chat:clear()
            Notify.error("Failed to load session messages")
            session.chat:on_error("Failed to load session messages", { pad_top = true, pad_bottom = true })
            session.chat:ensure_shown_and_focus_prompt()
        end)
    end
end

--- Rebind the tab UI to a live session without `switch_session` (which would abort
--- the agent). Mirrors compaction rebuild: queue inbound events, get_messages,
--- clear + replay, flush the queue, restore busy/compacting status.
---@param session pi.Session
---@param callback? fun(ok: boolean)
function M.reattach_view(session, callback)
    ---@param ok boolean
    local function done(ok)
        if callback then
            vim.schedule(function()
                callback(ok)
            end)
        end
    end

    session._view_rebuilding = true
    session._view_event_queue = session._view_event_queue or {}

    local chat = session.chat
    if not chat then
        finish_view_rebuild(session)
        done(true)
        return
    end

    session.changed_files = {}
    session._pending_file_change_args = nil
    chat:clear()
    chat:show_loading()

    local sent = session.rpc:send({ type = "get_messages" }, function(res)
        vim.schedule(function()
            if not session._view_rebuilding then
                done(false)
                return
            end
            local bound = session.chat
            if not bound then
                finish_view_rebuild(session)
                done(false)
                return
            end
            bound:clear_placeholder()
            if not res.success then
                local err = res.error or "Failed to load session messages"
                Notify.error(err)
                bound:on_error(err, { pad_top = true, pad_bottom = true })
                finish_view_rebuild(session)
                bound:ensure_shown_and_focus_prompt()
                done(false)
                return
            end

            local messages = (res.data or {}).messages or {}
            show_startup_block(session, CommandsCache.list())
            replay_messages(session, messages)
            M.refresh_state(session)
            vim.schedule(function()
                finish_view_rebuild(session)
                if session.chat then
                    session.chat:ensure_shown_and_focus_prompt()
                end
                done(true)
            end)
        end)
    end)
    if not sent then
        finish_view_rebuild(session)
        Notify.error("Failed to load session messages")
        if session.chat then
            session.chat:on_error("Failed to load session messages", { pad_top = true, pad_bottom = true })
            session.chat:ensure_shown_and_focus_prompt()
        end
        done(false)
    end
end

--- Load a session by path: switch_session -> clear chat -> get_messages -> replay.
---@param session pi.Session
---@param session_path string
---@param opts? pi.LoadSessionOpts
---@param callback? fun(ok: boolean) Invoked after switch_session succeeds or fails.
function load_session(session, session_path, opts, callback)
    opts = opts or {}
    Attention.begin_session_transition(session)

    local function done(ok)
        if callback then
            vim.schedule(function()
                callback(ok)
            end)
        end
    end

    local sent_switch = session.rpc:send({ type = "switch_session", sessionPath = session_path }, function(msg)
        local data = msg.data or {}
        if not msg.success then
            vim.schedule(function()
                Attention.end_session_transition(session, false)
                Notify.error(msg.error or "Failed to switch session")
            end)
            done(false)
            return
        end
        if data.cancelled then
            vim.schedule(function()
                Attention.end_session_transition(session, false)
                Notify.warn("Session switch was cancelled")
            end)
            done(false)
            return
        end

        Attention.end_session_transition(session, true)
        session.session_file = session_path
        if opts.rebind_parent_context ~= false then
            require("pi.subsessions").on_parent_resumed(session, session_path)
        end
        require("pi.ui.sessions").invalidate(session)
        require("pi.ui.sessions").clear_flags(session)
        require("pi.ui.sessions").request_refresh()
        -- The resumed session's model was restored from its session file by
        -- core; adopt it as this tab's pin.
        refresh_state_and_pin(session)
        done(true)

        -- Revive (and other headless loads) switch the file before the chat is
        -- bound; the caller rebuilds via reattach_view. Sending get_messages
        -- here would race that rebuild once bind_chat lands.
        if not session.chat then
            return
        end

        vim.schedule(function()
            if not session.chat then
                return
            end
            session.changed_files = {}
            session._pending_file_change_args = nil
            session.chat:clear()
            session.chat:show_loading()
        end)

        local sent_messages = session.rpc:send({ type = "get_messages" }, function(res)
            vim.schedule(function()
                if not session.chat then
                    return
                end
                session.chat:clear_placeholder()
                if not res.success then
                    local err = res.error or "Failed to load session messages"
                    Notify.error(err)
                    session.chat:on_error(err, { pad_top = true, pad_bottom = true })
                    session.chat:ensure_shown_and_focus_prompt()
                    return
                end

                local messages = (res.data or {}).messages or {}
                -- Fetch commands, show startup block, then replay.
                CommandsCache.fetch(session.rpc, function(commands)
                    show_startup_block(session, commands)
                    replay_messages(session, messages)
                    session.chat:ensure_shown_and_focus_prompt()
                end)
            end)
        end)
        if not sent_messages then
            vim.schedule(function()
                if not session.chat then
                    return
                end
                session.chat:clear()
                Notify.error("Failed to load session messages")
                session.chat:on_error("Failed to load session messages", { pad_top = true, pad_bottom = true })
                session.chat:ensure_shown_and_focus_prompt()
            end)
        end
    end)

    if not sent_switch then
        Attention.end_session_transition(session, false)
        done(false)
    end
end

--- Shared renderer for resume-picker rows: date + display name or first message.
---@param session pi.SessionInfo
---@return string
local function format_resume_item(session)
    local date = session.timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)") or session.timestamp
    local label = session.name or (session.first_message ~= "" and session.first_message or "(empty)")
    return date .. "  " .. label
end

--- Find a live session in another tab backed by the given session file.
--- Paths stay unknown until the backend's first get_state response, so a
--- freshly spawned process may not match yet — the guard is a safety net
--- against the common "resume what's running over there" case, not a ledger.
---@param session_path string
---@param exclude_tab pi.TabId? Tab whose own live copy never counts as a conflict (the reopen target).
---@return pi.Session?
local function find_live_elsewhere(session_path, exclude_tab)
    for _, s in pairs(registry) do
        if s.attached_tab ~= exclude_tab and s.rpc:is_running() and s.session_file == session_path then
            return s
        end
    end
    return nil
end

--- Open a past session picked from :PiResume: optionally move to a fresh
--- tabpage first, create the destination tab's session when needed, then
--- switch to `session_path`.
---
--- If the conversation is still live in another tab, a confirm dialog guards
--- against spawning a second backend process writing the same session file
--- (the two copies would diverge).
---@param session_path string
---@param opts? pi.SessionCreateOpts
---@param new_tab? boolean
local function open_resume_target(session_path, opts, new_tab)
    local function start()
        if new_tab then
            vim.cmd("tabnew")
        end
        local session = M.get_or_create(opts)
        if not session then
            return
        end
        session.chat:show({ loading = true })
        load_session(session, session_path)
    end

    -- For an in-place open the destination is the current tab: reopening this
    -- tab's own live copy is the normal self-switch, so exclude it from the
    -- conflict check. A new-tab open conflicts with any live copy.
    local live = find_live_elsewhere(session_path, new_tab and nil or current_tab())
    if not live then
        start()
        return
    end
    Dialog.confirm({
        title = "Session already open",
        message = "This conversation is still running in another tab. Opening it again spawns a second"
            .. " process writing the same session file (they will diverge). Continue?",
    }, function(confirmed)
        if confirmed then
            start()
        end
    end)
end

--- Open the resume list through a dedicated telescope picker.
--- Returns false when telescope is unavailable so the caller falls back to
--- the generic vim.ui.select flow below.
---
--- Keybindings (hinted in the picker title): <CR>/o open in the current tab,
--- t/<C-t> open in a new tab, <C-x> delete the selected session(s).
---@param items pi.SessionSelectItem[]
---@param opts? pi.SessionCreateOpts
---@return boolean handled
local function open_with_telescope(items, opts)
    local ok_telescope = pcall(require, "telescope")
    if not ok_telescope then
        return false
    end

    local themes = require("telescope.themes")
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    ---@param item pi.SessionSelectItem
    ---@return table telescope entry
    local function entry_maker(item)
        return { value = item, display = format_resume_item(item.session), ordinal = format_resume_item(item.session) }
    end

    -- NOTE: pickers.new(opts, defaults) lets `opts` (this first table) win on
    -- key conflicts, and get_dropdown pins results_title = false. The titles
    -- must live in that same first table or the key hint gets clobbered.
    pickers
        .new(
            themes.get_dropdown({
                previewer = false,
                prompt_title = "Resume session",
                results_title = " <CR>/o open · t/<C-t> new tab · <C-x> delete ",
            }),
            {
                finder = finders.new_table({ results = items, entry_maker = entry_maker }),
                sorter = conf.generic_sorter(),
                attach_mappings = function(prompt_bufnr, map)
                    local function open(new_tab)
                        local selection = action_state.get_selected_entry(prompt_bufnr)
                        if not selection then
                            return
                        end
                        actions.close(prompt_bufnr)
                        vim.schedule(function()
                            open_resume_target(selection.value.file, opts, new_tab)
                        end)
                    end

                    actions.select_default:replace(function()
                        open(false)
                    end)
                    map("n", "o", function()
                        open(false)
                    end)
                    map("n", "t", function()
                        open(true)
                    end)
                    map("n", "<C-t>", function()
                        open(true)
                    end)
                    map("i", "<C-t>", function()
                        open(true)
                    end)

                    map({ "n", "i" }, "<C-x>", function()
                        local targets = {} ---@type string[]
                        for _, entry in ipairs(action_state.get_multi_selection(prompt_bufnr)) do
                            targets[#targets + 1] = entry.value.file
                        end
                        if #targets == 0 then
                            local selection = action_state.get_selected_entry(prompt_bufnr)
                            if selection then
                                targets[1] = selection.value.file
                            end
                        end
                        if #targets == 0 then
                            return
                        end
                        local msg = #targets == 1 and "Delete session?" or (("Delete %d sessions?"):format(#targets))
                        if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
                            return
                        end
                        ---@type table<string, boolean>
                        local deleted = {}
                        for _, path in ipairs(targets) do
                            deleted[path] = true
                            local ok, err = os.remove(path)
                            if not ok then
                                Notify.warn("Failed to delete session: " .. (err or path))
                            end
                        end
                        local remaining = {}
                        for _, item in ipairs(items) do
                            if not deleted[item.file] then
                                remaining[#remaining + 1] = item
                            end
                        end
                        items = remaining
                        if #remaining == 0 then
                            actions.close(prompt_bufnr)
                            Notify.info("No sessions remaining")
                            return
                        end
                        action_state
                            .get_current_picker(prompt_bufnr)
                            :refresh(finders.new_table({ results = remaining, entry_maker = entry_maker }))
                    end)
                    return true
                end,
            }
        )
        :find()
    return true
end

---@param sessions pi.SessionInfo[]
---@return pi.SessionInfo[]
local function filter_top_level_sessions(sessions)
    local Manifest = require("pi.subsessions.manifest")
    ---@type pi.SessionInfo[]
    local out = {}
    for _, session in ipairs(sessions) do
        if not Manifest.is_child_session(session.id) then
            out[#out + 1] = session
        end
    end
    return out
end

---@param current_session_file? string
---@return string?
local function find_continue_session_path(current_session_file)
    local History = require("pi.sessions.history")
    local sessions_list = filter_top_level_sessions(History.list())
    for _, session in ipairs(sessions_list) do
        if session.path ~= current_session_file then
            return session.path
        end
    end
    return nil
end

---@param session pi.Session
---@param state table?
---@return boolean
local function is_empty_session_state(session, state)
    if type(state) ~= "table" then
        return false
    end

    local message_count = type(state.messageCount) == "number" and state.messageCount or nil
    local pending_count = type(state.pendingMessageCount) == "number" and state.pendingMessageCount or nil
    if message_count == nil or pending_count == nil then
        return false
    end

    return message_count == 0
        and pending_count == 0
        and state.isStreaming ~= true
        and state.isCompacting ~= true
        and not session.chat:has_draft()
end

---@param session pi.Session
local function show_no_previous_sessions(session)
    Notify.info("No previous sessions found")
    session.chat:ensure_shown_and_focus_prompt()
end

--- Continue the most recent session for the current cwd.
---@param opts? pi.SessionCreateOpts
function M.continue_session(opts)
    local session = M.get()
    if not session then
        local session_path = find_continue_session_path(nil)
        session = M.get_or_create(opts)
        if not session then
            return
        end
        if not session_path then
            show_no_previous_sessions(session)
            return
        end
        session.chat:show({ loading = true })
        load_session(session, session_path)
        return
    end

    local sent = session.rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            if M.get() ~= session then
                return
            end
            if not res.success then
                Notify.error(res.error or "Failed to fetch session state")
                return
            end

            local state = res.data or {}
            if not is_empty_session_state(session, state) then
                return
            end

            local session_path = find_continue_session_path(state.sessionFile)
            if not session_path then
                show_no_previous_sessions(session)
                return
            end

            session.chat:show({ loading = true })
            load_session(session, session_path)
        end)
    end)
    if not sent then
        Notify.error("Failed to fetch session state")
    end
end

--- Show a picker to resume a past session.
---@param opts? pi.SessionCreateOpts
function M.resume_session(opts)
    local History = require("pi.sessions.history")
    local sessions_list = filter_top_level_sessions(History.list())
    if #sessions_list == 0 then
        Notify.info("No sessions found")
        return
    end

    ---@class pi.SessionSelectItem
    ---@field session pi.SessionInfo
    ---@field file string

    ---@type pi.SessionSelectItem[]
    local items = {}
    for i, session in ipairs(sessions_list) do
        items[i] = {
            session = session,
            file = session.path,
        }
    end

    -- Telescope gets a purpose-built picker (dedicated keybindings plus a
    -- fixed key-hint title); every other backend keeps the generic
    -- vim.ui.select rendering below.
    if open_with_telescope(items, opts) then
        return
    end

    vim.ui.select(items, {
        prompt = "Resume session",
        kind = "pi-resume-session",
        -- Pass picker items with a `file` field so backends like snacks.nvim
        -- can preview the raw session file when preview is enabled. Other
        -- vim.ui.select implementations ignore extra fields and render via
        -- `format_item`. Same row rendering as the telescope picker above.
        format_item = function(item)
            return format_resume_item(item.session)
        end,
        snacks = {
            -- snacks.nvim (if installed) overrides vim.ui.select with its picker.
            -- It has a bug where the list height can be non-integer, crashing
            -- nvim_win_set_config. This `snacks` key is merged into the picker
            -- config and overrides the broken height calculation with math.floor.
            -- Safe to include even if snacks isn't used — the key is just ignored.
            layout = {
                config = function(layout)
                    for _, box in ipairs(layout.layout) do
                        if box.win == "list" then
                            box.height = math.floor(math.max(math.min(#items, vim.o.lines * 0.8 - 10), 2))
                        end
                    end
                end,
            },
            win = {
                input = {
                    keys = {
                        ["<C-x>"] = { "delete_session", mode = { "i", "n" }, desc = "Delete session" },
                        ["<C-t>"] = { "resume_new_tab", mode = { "i", "n" }, desc = "Open in new tab" },
                    },
                },
                list = {
                    keys = {
                        ["<C-x>"] = { "delete_session", mode = { "n" }, desc = "Delete session" },
                        ["<C-t>"] = { "resume_new_tab", mode = { "n" }, desc = "Open in new tab" },
                    },
                },
            },
            actions = {
                resume_new_tab = function(picker)
                    local selected = picker:selected({ fallback = true })
                    if #selected == 0 then
                        return
                    end
                    picker:close()
                    vim.schedule(function()
                        open_resume_target(selected[1].item.file, opts, true)
                    end)
                end,
                delete_session = function(picker)
                    local selected = picker:selected({ fallback = true })
                    if #selected == 0 then
                        return
                    end
                    local n = #selected
                    local msg = n == 1 and "Delete session?" or ("Delete %d sessions?"):format(n)
                    if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
                        return
                    end
                    ---@type table<string, boolean>
                    local deleted = {}
                    for _, sel in ipairs(selected) do
                        local path = sel.item.file
                        local ok, err = os.remove(path)
                        if ok then
                            deleted[path] = true
                        else
                            Notify.warn("Failed to delete session: " .. (err or path))
                        end
                    end
                    for i = #items, 1, -1 do
                        if deleted[items[i].file] then
                            table.remove(items, i)
                        end
                    end
                    if #items == 0 then
                        picker:close()
                        Notify.info("No sessions remaining")
                    else
                        picker:refresh()
                    end
                end,
            },
        },
    }, function(item)
        if not item then
            return
        end
        open_resume_target(item.file, opts)
    end)
end

--- Detach closed tabs without stopping their backend processes.
function M.cleanup()
    ---@type table<pi.TabId, boolean>
    local valid_tabs = {}
    for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        valid_tabs[t] = true
    end
    local detached = false
    for tab in pairs(tab_session_id) do
        if not valid_tabs[tab] then
            detach_tab(tab)
            detached = true
        end
    end
    for tab in pairs(tab_chats) do
        if not valid_tabs[tab] then
            detach_tab(tab)
            detached = true
        end
    end
    if detached then
        require("pi.ui.sessions").request_refresh()
    end
end

--- Test-only: insert a session into the registry (for bind/detach specs).
---@param session pi.Session
function M._register_for_test(session)
    registry[session.id] = session
end

--- Test-only reset: stop all sessions and clear registry state.
function M._reset()
    for id, session in pairs(registry) do
        if session.rpc:is_running() then
            session.rpc:stop()
        end
        registry[id] = nil
    end
    for tab in pairs(tab_chats) do
        tab_chats[tab] = nil
    end
    for tab in pairs(tab_session_id) do
        tab_session_id[tab] = nil
    end
    next_temp_id = 0
end

--- Set up the TabClosed autocmd (called once from init.setup).
function M.setup_autocmds()
    vim.api.nvim_create_autocmd("TabClosed", {
        callback = function()
            vim.schedule(function()
                M.cleanup()
            end)
        end,
    })

    -- Entering a tab consumes that session's done/error notification: the
    -- user has seen it, so the dot returns to idle.
    vim.api.nvim_create_autocmd("TabEnter", {
        callback = function()
            local session = M.get()
            if session then
                require("pi.ui.sessions").clear_flags(session)
                if session.view_parent_id and session.id then
                    require("pi.ui.sessions").mark_child_completion_seen(session.id)
                else
                    require("pi.ui.sessions").acknowledge_reported_children(session)
                end
            end
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            for _, session in pairs(registry) do
                Attention.clear_session(session)
                session.rpc:stop()
            end
        end,
    })

    vim.api.nvim_create_autocmd("VimResized", {
        callback = function()
            for _, session in pairs(registry) do
                if session.chat and session.chat:is_visible() then
                    session.chat:on_resize()
                end
            end
        end,
    })
end

return M
