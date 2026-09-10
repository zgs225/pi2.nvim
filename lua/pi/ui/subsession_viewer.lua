--- Read-only session viewer — a floating window that displays the full
--- rendered chat history of a sub-session or of a parent/tab session without
--- taking over the tab's session binding.

local M = {}

local Config = require("pi.config")
local Notify = require("pi.notify")
local Highlights = require("pi.ui.highlights")
local History = require("pi.ui.chat.history")
local Render = require("pi.ui.render")
local Manifest = require("pi.subsessions.manifest")
local Sessions = require("pi.sessions.manager")
local Read = require("pi.subsessions.read")
local Vision = require("pi.vision")
local Stats = require("pi.stats")

---@class pi.SubsessionViewerOpts
---@field on_close? fun()
---@field name? string Display-name override (beats manifest entry and JSONL session_info)
---@field width? number Width in columns (>=1) or fraction of editor width (<1)
---@field height? number Height in lines (>=1) or fraction of editor height (<1)
---@field border? string|string[] Float border style
---@field statusline? boolean Whether to show statusline in viewer footer

---@class pi.SubsessionViewerStatus
---@field model_id string?
---@field model_provider string?
---@field model_context_window integer?
---@field model_reasoning boolean?
---@field thinking_level string?
---@field context_tokens integer?

-- Module state
---@type integer?
local viewer_win = nil
---@type pi.ChatHistory?
local viewer_history = nil
---@type string?
local viewer_child_id = nil
---@type boolean
local viewer_is_child = false
---@type pi.Session?
local viewer_live_session = nil
---@type string?
local viewer_session_name = nil
---@type boolean
local viewer_loading = false
---@type pi.RpcEvent[]?
local viewer_event_queue = nil
---@type integer
local viewer_tab_counter = -100
---@type fun()?
local viewer_on_close = nil
---@type boolean
local viewer_statusline_enabled = true
---@type pi.SubsessionViewerStatus
local viewer_status = {
    model_id = nil,
    model_provider = nil,
    model_context_window = nil,
    model_reasoning = nil,
    thinking_level = nil,
    context_tokens = nil,
}

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

--- Get status line config for a built-in component.
---@param name string
---@return table
local function component_config(name)
    local components = ((Config.options.statusline or {}).components or {})
    local cfg = components[name]
    return type(cfg) == "table" and cfg or {}
end

---@param status pi.SubsessionViewerStatus
---@return string[]?
local function build_context_chunk(status)
    local text = nil
    local hl = "PiStatusLine"
    local cfg = component_config("context")
    if status.model_context_window and status.model_context_window > 0 then
        local total = Stats.format_tokens(status.model_context_window)
        if status.context_tokens and status.context_tokens > 0 then
            local pct = (status.context_tokens / status.model_context_window) * 100
            text = string.format("%.1f%%/%s", pct, total)
            if cfg.error and pct > cfg.error then
                hl = "PiStatusLineError"
            elseif cfg.warn and pct > cfg.warn then
                hl = "PiStatusLineWarning"
            end
        else
            text = "-/" .. total
        end
    elseif status.context_tokens and status.context_tokens > 0 then
        text = Stats.format_tokens(status.context_tokens)
    end
    if not text then
        return nil
    end
    local icon = cfg.icon
    if type(icon) == "string" and icon ~= "" then
        text = icon .. " " .. text
    end
    return { text, hl }
end

---@param status pi.SubsessionViewerStatus
---@return string[]?
local function build_model_chunk(status)
    if not status.model_id or status.model_id == "" then
        return nil
    end
    local cfg = component_config("model")
    local text = status.model_id
    if cfg.provider == "always" and status.model_provider and status.model_provider ~= "" then
        text = text .. "  [" .. status.model_provider .. "]"
    end
    local icon = cfg.icon
    if type(icon) == "string" and icon ~= "" then
        text = icon .. " " .. text
    end
    return { text, "PiStatusLine" }
end

---@param status pi.SubsessionViewerStatus
---@return string[]?
local function build_thinking_chunk(status)
    if not status.thinking_level or status.thinking_level == "" then
        return nil
    end
    local cfg = component_config("thinking")
    local text = status.thinking_level == "off" and "thinking off" or status.thinking_level
    local icon = cfg.icon
    if type(icon) == "string" and icon ~= "" then
        text = icon .. " " .. text
    end
    return { text, "PiThinking" }
end

--- Build statusline chunks and plain text for subsession viewer footer.
---@param status pi.SubsessionViewerStatus
---@return string[][]? chunks
---@return string plain
local function format_statusline(status)
    if viewer_statusline_enabled == false then
        return nil, ""
    end

    local items = {}
    local c = build_context_chunk(status)
    if c then
        items[#items + 1] = c
    end
    local m = build_model_chunk(status)
    if m then
        items[#items + 1] = m
    end
    local th = build_thinking_chunk(status)
    if th then
        items[#items + 1] = th
    end

    if #items == 0 then
        return nil, ""
    end

    ---@type string[][]
    local chunks = { { " ", "PiStatusLine" } }
    local plain_parts = {}
    for i, item in ipairs(items) do
        if i > 1 then
            chunks[#chunks + 1] = { "  ·  ", "PiStatusLine" }
            plain_parts[#plain_parts + 1] = "  ·  "
        end
        chunks[#chunks + 1] = item
        plain_parts[#plain_parts + 1] = item[1]
    end
    chunks[#chunks + 1] = { " ", "PiStatusLine" }

    local plain = " " .. table.concat(plain_parts, "") .. " "
    return chunks, plain
end

--- Try to find contextWindow for a model across known sessions / cache.
---@param model_id string?
---@param provider string?
---@return integer?
local function resolve_context_window(model_id, provider)
    if not model_id or model_id == "" then
        return nil
    end
    for _, sess in ipairs(Sessions.list_all()) do
        if sess._models_cache and type(sess._models_cache.list) == "table" then
            for _, m in ipairs(sess._models_cache.list) do
                if m.id == model_id and (not provider or m.provider == provider) then
                    if type(m.contextWindow) == "number" and m.contextWindow > 0 then
                        return m.contextWindow
                    end
                end
            end
        end
    end
    return nil
end

---@param name string
---@param status string
---@return string
local function format_title(name, status)
    return string.format(" %s [%s] ", name, status)
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

---@param history pi.ChatHistory
---@param replaying boolean
local function set_replaying(history, replaying)
    history._replaying = replaying
    local buf = history:buf()
    if replaying then
        Render.pause_history(buf)
    else
        Render.resume_history(buf)
    end
end

--- Replay structured messages into the viewer's history instance.
--- Mirrors replay_messages from lua/pi/sessions/manager.lua.
---@param history pi.ChatHistory
---@param messages table[]
local function replay(history, messages)
    if not history or not history:buf() or not vim.api.nvim_buf_is_valid(history:buf()) then
        return
    end

    set_replaying(history, true)
    local pending_agent_end = false
    local tool_call_args = {} ---@type table<string, table>
    local tool_names = {} ---@type table<string, string>

    for _, msg in ipairs(messages) do
        local role = msg.role

        -- Flush pending agent_end before a user message
        if pending_agent_end and role == "user" then
            history:on_agent_end()
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

            local parsed = Vision.parse(text)
            if parsed.model then
                if parsed.text ~= "" then
                    history:add_user_message(parsed.text, msg.timestamp, nil)
                end
                history:add_vision_block(parsed.model, parsed.description or "")
            elseif text ~= "" or image_count > 0 then
                history:add_user_message(text, msg.timestamp, image_count > 0 and image_count or nil)
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
                        local id = part.toolCallId or part.id or ""
                        local name = part.toolName or part.name or "tool"
                        local args = normalize_tool_args(part.arguments or part.args or part.input)
                        tool_calls[#tool_calls + 1] = {
                            id = id,
                            name = name,
                            args = args,
                        }
                    end
                end
            end

            local thinking_text = table.concat(thinking_parts, "\n")
            if text ~= "" or #tool_calls > 0 or thinking_text ~= "" then
                local tool_only = text == "" and #tool_calls > 0 and thinking_text == ""
                if not (tool_only and pending_agent_end) then
                    if pending_agent_end then
                        history:on_agent_end()
                        pending_agent_end = false
                    end
                    history:on_agent_start(msg.timestamp)
                end

                if thinking_text ~= "" then
                    history:on_thinking_start({ unmeasured = true })
                    history:on_thinking_delta(thinking_text)
                    history:on_thinking_end()
                end

                if text ~= "" then
                    history:on_text_delta(text)
                end

                for _, tc in ipairs(tool_calls) do
                    history:on_tool_start(tc.name, tc.id, tc.args)
                    if tc.id ~= "" then
                        tool_names[tc.id] = tc.name
                    end
                    if tc.args then
                        tool_call_args[tc.id] = tc.args
                    end
                end

                if #tool_calls == 0 then
                    history:on_agent_end()
                else
                    pending_agent_end = true
                end
            end
        elseif role == "toolResult" or role == "tool" then
            local tool_call_id = msg.toolCallId or msg.toolUseId or ""
            local tool_name = msg.toolName or tool_names[tool_call_id] or "tool"
            local is_error = msg.isError == true
            history:on_tool_end(tool_name, tool_call_id, msg, is_error)
        elseif role == "compactionSummary" or role == "compaction_summary" then
            if pending_agent_end then
                history:on_agent_end()
                pending_agent_end = false
            end
            history:append_compaction_summary(msg.summary or "", tonumber(msg.tokensBefore) or 0)
        elseif role == "bashExecution" then
            if pending_agent_end then
                history:on_agent_end()
                pending_agent_end = false
            end
            history:on_bash_replay(msg)
        end
    end

    if pending_agent_end then
        history:on_agent_end()
    end

    set_replaying(history, false)

    vim.schedule(function()
        if history and history:win() and vim.api.nvim_win_is_valid(history:win()) then
            history:scroll_to_bottom()
        end
    end)
end

---@param path string
---@return table[] messages, string? session_name, table status
local function load_messages_from_jsonl(path)
    local file = io.open(path, "r")
    if not file then
        return {}, nil, {}
    end
    ---@type table[]
    local messages = {}
    ---@type string?
    local session_name = nil
    local status = {}
    for line in file:lines() do
        if line ~= "" then
            local ok, entry = pcall(vim.json.decode, line)
            if ok and type(entry) == "table" then
                local t = entry.type
                if t == "message" and type(entry.message) == "table" then
                    local msg = entry.message
                    messages[#messages + 1] = msg
                    if msg.role == "assistant" then
                        local u = (type(msg.usage) == "table" and msg.usage)
                            or (type(entry.usage) == "table" and entry.usage)
                        if u and (u.input or 0) > 0 then
                            status.context_tokens = (u.input or 0)
                                + (u.output or 0)
                                + (u.cacheRead or 0)
                                + (u.cacheWrite or 0)
                        end
                        local m = msg.model or entry.model or entry.modelId
                        if m and type(m) == "string" and m ~= "" then
                            status.model_id = m
                        end
                        local p = msg.provider or entry.provider
                        if p and type(p) == "string" and p ~= "" then
                            status.model_provider = p
                        end
                    end
                elseif t == "model_change" then
                    local m = entry.modelId or entry.model
                    if m and type(m) == "string" and m ~= "" then
                        status.model_id = m
                    end
                    local p = entry.provider
                    if p and type(p) == "string" and p ~= "" then
                        status.model_provider = p
                    end
                elseif t == "thinking_level_change" then
                    if entry.thinkingLevel and type(entry.thinkingLevel) == "string" then
                        status.thinking_level = entry.thinkingLevel
                    end
                elseif t == "compaction_summary" then
                    messages[#messages + 1] = {
                        role = "compactionSummary",
                        summary = entry.summary or (type(entry.data) == "table" and entry.data.summary) or "",
                        tokensBefore = entry.tokensBefore
                            or (type(entry.data) == "table" and entry.data.tokensBefore)
                            or 0,
                    }
                elseif t == "session_info" and type(entry.name) == "string" and entry.name ~= "" then
                    session_name = entry.name
                end
            end
        end
    end
    file:close()
    return messages, session_name, status
end

--- Close the viewer float and clean up resources.
function M.close()
    viewer_loading = false
    viewer_event_queue = nil
    viewer_session_name = nil
    viewer_child_id = nil
    viewer_is_child = false
    viewer_live_session = nil
    viewer_statusline_enabled = true
    viewer_status = {
        model_id = nil,
        model_provider = nil,
        model_context_window = nil,
        model_reasoning = nil,
        thinking_level = nil,
        context_tokens = nil,
    }

    if viewer_win == nil and viewer_history == nil then
        return
    end

    local win = viewer_win
    local hist = viewer_history
    local on_close = viewer_on_close

    viewer_win = nil
    viewer_history = nil
    viewer_on_close = nil

    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
    end

    if hist then
        hist:set_win(nil)
        hist:clear()
        local buf = hist:buf()
        if buf and vim.api.nvim_buf_is_valid(buf) then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end

    if on_close then
        pcall(on_close)
    end
end

--- Check if viewer is currently open.
---@return boolean
function M.is_open()
    return viewer_win ~= nil and vim.api.nvim_win_is_valid(viewer_win)
end

--- Check if viewer is currently open for a specific child session id.
---@param child_id? string
---@return boolean
function M.is_open_for(child_id)
    return M.is_open() and child_id ~= nil and viewer_child_id == child_id
end

--- Check if the viewer is open for a specific live session object.
--- Robust against id migration (`tmp-N` -> real id): the string gate above goes
--- stale while the object identity is stable.
---@param session pi.Session
---@return boolean
function M.is_open_for_session(session)
    return M.is_open() and session ~= nil and viewer_live_session == session
end

--- True when the viewer is currently displaying `session`, matching either the
--- id captured when it was opened or (after an id migration) the object identity.
---@param session pi.Session?
---@return boolean
local function viewer_shows_session(session)
    if not session then
        return false
    end
    return (session.id ~= nil and M.is_open_for(session.id)) or M.is_open_for_session(session)
end

--- Update the viewer window title.
---@param name? string
---@param status string
function M.update_title(name, status)
    if not viewer_win or not vim.api.nvim_win_is_valid(viewer_win) then
        return
    end
    if name and name ~= "" then
        viewer_session_name = name
    end
    local title_name = (viewer_session_name and viewer_session_name ~= "") and viewer_session_name
        or (viewer_child_id or "subsession")
    pcall(vim.api.nvim_win_set_config, viewer_win, {
        title = format_title(title_name, status),
        title_pos = "center",
    })
end

--- Update the viewer window statusline / footer.
function M.update_statusline()
    if not viewer_win or not vim.api.nvim_win_is_valid(viewer_win) then
        return
    end
    if viewer_statusline_enabled == false then
        pcall(vim.api.nvim_win_set_config, viewer_win, {
            footer = "",
            footer_pos = "center",
        })
        pcall(function()
            if viewer_win and vim.api.nvim_win_is_valid(viewer_win) then
                vim.wo[viewer_win].statusline = ""
            end
        end)
        return
    end

    local chunks, plain = format_statusline(viewer_status)
    if chunks and #chunks > 0 then
        pcall(vim.api.nvim_win_set_config, viewer_win, {
            footer = chunks,
            footer_pos = "center",
        })
        pcall(function()
            if viewer_win and vim.api.nvim_win_is_valid(viewer_win) then
                vim.wo[viewer_win].statusline = plain or ""
            end
        end)
    else
        pcall(vim.api.nvim_win_set_config, viewer_win, {
            footer = "",
            footer_pos = "center",
        })
        pcall(function()
            if viewer_win and vim.api.nvim_win_is_valid(viewer_win) then
                vim.wo[viewer_win].statusline = ""
            end
        end)
    end
end

--- Handle a live session event for the active viewer.
---@param session pi.Session
---@param msg pi.RpcEvent
local function handle_live_event(session, msg)
    local history = viewer_history
    if not history then
        return
    end

    local t = msg.type
    if t == "agent_start" then
        history:on_agent_start(nil)
        M.update_title(viewer_session_name, "active")
    elseif t == "message_start" then
        local message = msg.message
        if message and message.role == "user" then
            local text = ""
            local image_count = 0
            if type(message.content) == "string" then
                text = message.content
            elseif type(message.content) == "table" then
                for _, part in ipairs(message.content) do
                    if type(part) == "string" then
                        text = text .. part
                    elseif type(part) == "table" and part.type == "text" then
                        text = text .. (part.text or "")
                    elseif type(part) == "table" and part.type == "image" then
                        image_count = image_count + 1
                    end
                end
            end

            local parsed = Vision.parse(text)
            if parsed.model then
                if parsed.text ~= "" then
                    history:add_user_message(parsed.text, message.timestamp, nil)
                end
                history:add_vision_block(parsed.model, parsed.description or "")
            elseif text ~= "" or image_count > 0 then
                history:add_user_message(text, message.timestamp, image_count > 0 and image_count or nil)
            end
        end
    elseif t == "message_update" then
        local ev = msg.assistantMessageEvent
        if ev then
            if ev.type == "thinking_start" then
                history:on_thinking_start()
            elseif ev.type == "thinking_delta" then
                history:on_thinking_delta(ev.delta or "")
            elseif ev.type == "thinking_end" then
                history:on_thinking_end()
            elseif ev.type == "text_delta" then
                history:on_thinking_end()
                history:on_text_delta(ev.delta or "")
            end
        end
    elseif t == "tool_execution_start" then
        local args = normalize_tool_args(msg.args) or msg.args
        history:on_tool_start(msg.toolName or "tool", msg.toolCallId, args)
    elseif t == "tool_execution_end" then
        history:on_tool_end(msg.toolName or "tool", msg.toolCallId, msg.result, msg.isError)
    elseif t == "tool_execution_update" then
        history:on_tool_update(msg.toolName or "tool", msg.toolCallId, msg)
    elseif t == "bash_execution_update" or msg.type == "bash_execution_update" then
        history:on_bash_update(msg.id, msg.delta or "")
    elseif t == "message_end" then
        local message = msg.message
        if message and message.role == "assistant" then
            local stop = message.stopReason
            if stop ~= "aborted" and stop ~= "error" and type(message.usage) == "table" then
                local u = message.usage
                if (u.input or 0) > 0 then
                    viewer_status.context_tokens = (u.input or 0)
                        + (u.output or 0)
                        + (u.cacheRead or 0)
                        + (u.cacheWrite or 0)
                    M.update_statusline()
                end
            end
            if stop == "aborted" or stop == "error" then
                local error_message
                if stop == "aborted" then
                    error_message = "[aborted] Operation aborted"
                else
                    error_message = message.errorMessage or "Error"
                end
                if type(history.mark_pending_tools_errored) == "function" then
                    history:mark_pending_tools_errored(error_message)
                end
            end
        end
    elseif t == "agent_end" or t == "agent_settled" then
        history:on_agent_end()
        -- Only sub-sessions are manifest-patched on settle; a parent/tab session
        -- returns to idle instead of claiming a completion it never reports.
        M.update_title(viewer_session_name, viewer_is_child and "completed" or "idle")
        M.update_statusline()
    elseif t == "model_change" then
        if msg.modelId then
            viewer_status.model_id = msg.modelId
        end
        if msg.provider then
            viewer_status.model_provider = msg.provider
        end
        if msg.contextWindow then
            viewer_status.model_context_window = msg.contextWindow
        else
            viewer_status.model_context_window =
                resolve_context_window(viewer_status.model_id, viewer_status.model_provider)
        end
        M.update_statusline()
    elseif t == "thinking_level_change" then
        if msg.thinkingLevel then
            viewer_status.thinking_level = msg.thinkingLevel
            M.update_statusline()
        end
    end

    if history:win() and vim.api.nvim_win_is_valid(history:win()) then
        if type(history._maybe_scroll) == "function" then
            history:_maybe_scroll()
        elseif type(history.scroll_to_bottom) == "function" then
            history:scroll_to_bottom()
        end
    end
end

--- Handle a live session event for the active viewer.
---@param session pi.Session
---@param msg pi.RpcEvent
function M.on_session_event(session, msg)
    if not viewer_shows_session(session) then
        return
    end

    if viewer_loading then
        viewer_event_queue = viewer_event_queue or {}
        viewer_event_queue[#viewer_event_queue + 1] = msg
        return
    end

    vim.schedule(function()
        if not viewer_shows_session(session) then
            return
        end
        handle_live_event(session, msg)
    end)
end

--- Get the child_id currently being viewed.
---@return string?
function M.viewed_child_id()
    return M.is_open() and viewer_child_id or nil
end

--- Open the viewer for a session id — a sub-session child (promotable) or a
--- parent/tab session (read-only, jumped to with `<CR>`).
---@param child_id string
---@param opts? pi.SubsessionViewerOpts
function M.open(child_id, opts)
    opts = opts or {}

    -- 1. Close any existing viewer
    M.close()

    -- 2. Look up manifest entry for name/status
    local manifest = Manifest.load()
    local entry = manifest[child_id]

    -- Name precedence: opts.name > manifest entry name > JSONL session_info > raw id.
    ---@type string?
    local entry_name
    if entry and type(entry.name) == "string" and entry.name ~= "" then
        entry_name = entry.name
    end
    ---@type string?
    local opts_name
    if type(opts.name) == "string" and opts.name ~= "" then
        opts_name = opts.name
    end
    local name = opts_name or entry_name or child_id

    viewer_status = {
        model_id = nil,
        model_provider = nil,
        model_context_window = nil,
        model_reasoning = nil,
        thinking_level = nil,
        context_tokens = nil,
    }

    if entry and entry.config then
        local cfg = entry.config
        if cfg.model then
            viewer_status.model_id = cfg.model.id
            viewer_status.model_provider = cfg.model.provider
        end
        if cfg.thinking_level then
            viewer_status.thinking_level = cfg.thinking_level
        end
    end

    -- 3. Determine if live (Sessions.get_by_id) or dormant (disk)
    local session = Sessions.get_by_id(child_id)
    local is_live = session ~= nil and session.rpc ~= nil and session.rpc:is_running()
    local status = (entry and entry.status) or (is_live and "active" or "dormant")

    if session then
        local pin = session.pinned_config
        if pin then
            if pin.model then
                viewer_status.model_id = pin.model.id
                viewer_status.model_provider = pin.model.provider
            end
            if pin.thinking_level then
                viewer_status.thinking_level = pin.thinking_level
            end
        end
    end

    -- For dormant sessions, verify the session file exists before opening window
    local dormant_messages = nil
    if not is_live then
        local path = (session and session.session_file) or Read.find_path(child_id)
        if not path and vim.fn.filereadable(child_id) == 1 then
            path = child_id
        end
        if not path then
            Notify.warn("Session file not found")
            return
        end
        local msgs, session_name, jsonl_status = load_messages_from_jsonl(path)
        dormant_messages = msgs
        -- The JSONL fallback only applies while no name is known yet.
        if session_name and session_name ~= "" and not opts_name and not entry_name then
            name = session_name
        end
        if jsonl_status then
            if jsonl_status.model_id then
                viewer_status.model_id = jsonl_status.model_id
            end
            if jsonl_status.model_provider then
                viewer_status.model_provider = jsonl_status.model_provider
            end
            if jsonl_status.thinking_level then
                viewer_status.thinking_level = jsonl_status.thinking_level
            end
            if jsonl_status.context_tokens then
                viewer_status.context_tokens = jsonl_status.context_tokens
            end
        end
    end

    if not viewer_status.model_context_window and viewer_status.model_id then
        viewer_status.model_context_window =
            resolve_context_window(viewer_status.model_id, viewer_status.model_provider)
    end

    -- 4. Create ChatHistory with fake tab id
    viewer_tab_counter = viewer_tab_counter - 1
    local fake_tab = viewer_tab_counter
    local history = History.new(fake_tab)
    local buf = history:buf()
    vim.bo[buf].bufhidden = "wipe"

    -- 5. Open float window, set keymaps
    local subagent_cfg = Config.options.subagent or {}
    local viewer_cfg = subagent_cfg.viewer or {}
    if opts.statusline ~= nil then
        viewer_statusline_enabled = opts.statusline
    else
        viewer_statusline_enabled = (viewer_cfg.statusline ~= false)
    end

    local raw_w = opts.width or viewer_cfg.width or 0.7
    local raw_h = opts.height or viewer_cfg.height or 0.75
    local border = opts.border or viewer_cfg.border or "rounded"

    local editor_w = vim.o.columns
    local editor_h = vim.o.lines - vim.o.cmdheight - 1
    local total_w = resolve_dimension(raw_w, editor_w)
    local total_h = resolve_dimension(raw_h, editor_h)
    local width = math.max(20, math.min(editor_w - 4, total_w))
    local height = math.max(5, math.min(editor_h - 2, total_h))
    local row = math.max(0, math.floor((editor_h - height) / 2))
    local col = math.floor((editor_w - width) / 2)
    local title = format_title(name, status)
    local initial_chunks, initial_plain = format_statusline(viewer_status)

    local win_opts = {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = border,
        title = title,
        title_pos = "center",
    }
    if viewer_statusline_enabled and initial_chunks and #initial_chunks > 0 then
        win_opts.footer = initial_chunks
        win_opts.footer_pos = "center"
    end

    local win = vim.api.nvim_open_win(buf, true, win_opts)
    if viewer_statusline_enabled and initial_plain and initial_plain ~= "" then
        pcall(function()
            vim.wo[win].statusline = initial_plain
        end)
    else
        pcall(function()
            vim.wo[win].statusline = ""
        end)
    end

    viewer_win = win
    viewer_history = history
    viewer_child_id = child_id
    viewer_is_child = Manifest.is_child_session(child_id)
    viewer_session_name = name
    viewer_loading = false
    viewer_event_queue = nil
    viewer_on_close = opts.on_close
    history:set_win(win)

    vim.wo[win].wrap = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].foldenable = false
    vim.wo[win].list = false
    vim.wo[win].spell = false
    vim.wo[win].cursorline = false
    vim.wo[win].winhighlight = Highlights.CHAT_HISTORY_WINHIGHLIGHT

    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            M.close()
        end,
    })

    -- Keymaps (buffer-local on the history buffer)
    vim.keymap.set("n", "q", function()
        M.close()
    end, { buffer = buf, nowait = true, desc = "Close subsession viewer" })

    vim.keymap.set("n", "<Esc>", function()
        M.close()
    end, { buffer = buf, nowait = true, desc = "Close subsession viewer" })

    -- <CR> promotes a sub-session into the tab, or jumps to the chat of a
    -- parent/tab session. Parent semantics differ: switch_to() sets
    -- view_parent_id on the target and may patch the manifest lineage, so it
    -- must never run for a non-child.
    vim.keymap.set("n", "<CR>", function()
        if viewer_is_child then
            M.close()
            require("pi.subsessions").switch_to(child_id, function(ok, err)
                if not ok and err then
                    Notify.error(err)
                end
            end)
            return
        end

        ---@param tab? pi.TabId
        ---@return boolean
        local function valid_tab(tab)
            if not tab then
                return false
            end
            local ok, valid = pcall(vim.api.nvim_tabpage_is_valid, tab)
            if not ok then
                return false
            end
            return valid and true or false
        end

        --- Resolve the tab showing `id`: the session's own tab when attached,
        --- otherwise the tab of one of its children (a detached parent currently
        --- shown through a child view).
        ---@param target pi.Session
        ---@return pi.TabId?
        local function resolve_target_tab(target)
            if valid_tab(target.attached_tab) then
                return target.attached_tab
            end
            if valid_tab(target.tab) then
                return target.tab
            end
            for _, other in ipairs(Sessions.list() or {}) do
                if other.view_parent_id == child_id and valid_tab(other.attached_tab) then
                    return other.attached_tab
                end
            end
            return nil
        end

        -- `viewer_live_session` is the fallback for a live session whose id
        -- migrated while the viewer was open (`get_by_id` no longer finds the
        -- id captured at open time, object identity still resolves).
        local session = Sessions.get_by_id(child_id) or viewer_live_session
        if not session or not session.rpc or not session.rpc:is_running() then
            Notify.warn("Cannot switch: the session process is not running")
            return
        end

        local target_tab = resolve_target_tab(session)
        if not target_tab then
            Notify.warn("Cannot switch: the session is not attached to a tab")
            return
        end

        M.close()
        local switched = pcall(vim.api.nvim_set_current_tabpage, target_tab)
        if not switched then
            Notify.warn("Cannot switch: the session tab is no longer available")
            return
        end

        local bound = Sessions.get_for_tab(target_tab)
        if bound and bound.view_parent_id then
            -- The tab is showing one of this session's children: switch the tab
            -- back to the parent first.
            require("pi.subsessions").switch_to_parent(function(ok, err)
                if not ok then
                    if err then
                        Notify.error(err)
                    end
                    return
                end
                local parent = Sessions.get_for_tab(target_tab)
                if parent and parent.chat then
                    parent.chat:ensure_shown_and_focus_prompt()
                end
            end)
        else
            local target = bound or session
            if target and target.chat then
                target.chat:ensure_shown_and_focus_prompt()
            end
        end
    end, { buffer = buf, nowait = true, desc = "Open this session in chat" })

    vim.keymap.set("n", "<Tab>", function()
        if not history then
            return
        end
        if history:toggle_startup_block() then
            return
        elseif history:toggle_compaction_block() then
            return
        elseif history:toggle_thinking_block() then
            return
        elseif history:toggle_tool_block() then
            return
        end
    end, { buffer = buf, nowait = true, desc = "Toggle block under cursor" })

    vim.keymap.set("n", "gf", function()
        if not history then
            return
        end
        history:goto_path_at_cursor()
    end, { buffer = buf, nowait = true, desc = "Open file under cursor" })

    -- 6. Load messages (RPC or JSONL) and replay into ChatHistory
    if is_live and session and session.rpc then
        local current_child = child_id
        local live_session = session
        viewer_live_session = session
        viewer_loading = true
        viewer_event_queue = {}

        session.rpc:send({ type = "get_state" }, function(state_res)
            vim.schedule(function()
                if not M.is_open_for(current_child) and viewer_live_session ~= live_session then
                    return
                end
                local d = state_res.data
                if state_res.success and type(d) == "table" then
                    local m = d.model
                    if type(m) == "table" then
                        viewer_status.model_id = m.id
                        viewer_status.model_provider = m.provider
                        viewer_status.model_context_window = m.contextWindow
                        viewer_status.model_reasoning = m.reasoning == true
                    end
                    if d.thinkingLevel then
                        viewer_status.thinking_level = d.thinkingLevel
                    end
                    M.update_statusline()
                end
            end)
        end)

        local sent = session.rpc:send({ type = "get_messages" }, function(res)
            vim.schedule(function()
                if not M.is_open() or (viewer_child_id ~= current_child and viewer_live_session ~= live_session) then
                    return
                end
                if not res.success then
                    viewer_loading = false
                    viewer_event_queue = nil
                    local err = res.error or "Failed to load subsession messages"
                    Notify.error(err)
                    return
                end
                local messages = (res.data or {}).messages or {}
                for _, msg in ipairs(messages) do
                    if msg.role == "assistant" then
                        local u = msg.usage
                        if type(u) == "table" and (u.input or 0) > 0 then
                            viewer_status.context_tokens = (u.input or 0)
                                + (u.output or 0)
                                + (u.cacheRead or 0)
                                + (u.cacheWrite or 0)
                        end
                        if msg.model and not viewer_status.model_id then
                            viewer_status.model_id = msg.model
                        end
                        if msg.provider and not viewer_status.model_provider then
                            viewer_status.model_provider = msg.provider
                        end
                    end
                end
                if not viewer_status.model_context_window and viewer_status.model_id then
                    viewer_status.model_context_window =
                        resolve_context_window(viewer_status.model_id, viewer_status.model_provider)
                end
                M.update_statusline()
                replay(history, messages)
                viewer_loading = false
                local queue = viewer_event_queue or {}
                viewer_event_queue = nil
                for _, queued_msg in ipairs(queue) do
                    if not M.is_open_for(current_child) and viewer_live_session ~= live_session then
                        break
                    end
                    handle_live_event(session, queued_msg)
                end
            end)
        end)
        if not sent then
            viewer_loading = false
            viewer_event_queue = nil
            Notify.error("Failed to request messages from subsession RPC")
        end
    else
        replay(history, dormant_messages or {})
    end
end

-- Test hooks
---@return integer?
function M._win()
    return viewer_win
end

---@return pi.ChatHistory?
function M._history()
    return viewer_history
end

---@param history pi.ChatHistory
---@param messages table[]
function M._replay(history, messages)
    replay(history, messages)
end

---@param path string
---@return table[] messages, string? session_name, table? status
function M._load_messages_from_jsonl(path)
    return load_messages_from_jsonl(path)
end

---@return boolean
function M._loading()
    return viewer_loading
end

---@return pi.RpcEvent[]?
function M._event_queue()
    return viewer_event_queue
end

---@return pi.SubsessionViewerStatus
function M._status()
    return viewer_status
end

---@param status? pi.SubsessionViewerStatus
---@return string[][]? chunks, string plain
function M._format_statusline(status)
    return format_statusline(status or viewer_status)
end

return M
