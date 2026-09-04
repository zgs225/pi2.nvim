--- Read-only subsession viewer — a floating window that displays the full
--- rendered chat history of a sub-session without taking over the tab's
--- session binding.

local M = {}

local Notify = require("pi.notify")
local Highlights = require("pi.ui.highlights")
local History = require("pi.ui.chat.history")
local Render = require("pi.ui.render")
local Manifest = require("pi.subsessions.manifest")
local Sessions = require("pi.sessions.manager")
local Read = require("pi.subsessions.read")
local Vision = require("pi.vision")

---@class pi.SubsessionViewerOpts
---@field on_close? fun()

-- Module state
---@type integer?
local viewer_win = nil
---@type pi.ChatHistory?
local viewer_history = nil
---@type string?
local viewer_child_id = nil
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
---@return table[] messages, string? session_name
local function load_messages_from_jsonl(path)
    local file = io.open(path, "r")
    if not file then
        return {}, nil
    end
    ---@type table[]
    local messages = {}
    ---@type string?
    local session_name = nil
    for line in file:lines() do
        if line ~= "" then
            local ok, entry = pcall(vim.json.decode, line)
            if ok and type(entry) == "table" then
                local t = entry.type
                if t == "message" and type(entry.message) == "table" then
                    messages[#messages + 1] = entry.message
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
    return messages, session_name
end

--- Close the viewer float and clean up resources.
function M.close()
    viewer_loading = false
    viewer_event_queue = nil
    viewer_session_name = nil

    if viewer_win == nil and viewer_history == nil then
        return
    end

    local win = viewer_win
    local hist = viewer_history
    local on_close = viewer_on_close

    viewer_win = nil
    viewer_history = nil
    viewer_child_id = nil
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
        M.update_title(viewer_session_name, "completed")
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
    if not session or not session.id or not M.is_open_for(session.id) then
        return
    end

    if viewer_loading then
        viewer_event_queue = viewer_event_queue or {}
        viewer_event_queue[#viewer_event_queue + 1] = msg
        return
    end

    vim.schedule(function()
        if not session or not session.id or not M.is_open_for(session.id) then
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

--- Open the viewer for a given child_id.
---@param child_id string
---@param opts? pi.SubsessionViewerOpts
function M.open(child_id, opts)
    opts = opts or {}

    -- 1. Close any existing viewer
    M.close()

    -- 2. Look up manifest entry for name/status
    local manifest = Manifest.load()
    local entry = manifest[child_id]
    local name = (entry and entry.name and entry.name ~= "") and entry.name or child_id

    -- 3. Determine if live (Sessions.get_by_id) or dormant (disk)
    local session = Sessions.get_by_id(child_id)
    local is_live = session ~= nil and session.rpc ~= nil and session.rpc:is_running()
    local status = (entry and entry.status) or (is_live and "active" or "dormant")

    -- For dormant sessions, verify the session file exists before opening window
    local dormant_messages = nil
    if not is_live then
        local path = (session and session.session_file) or Read.find_path(child_id)
        if not path and vim.fn.filereadable(child_id) == 1 then
            path = child_id
        end
        if not path then
            Notify.warn("Sub-session file not found")
            return
        end
        local msgs, session_name = load_messages_from_jsonl(path)
        dormant_messages = msgs
        if session_name and (not entry or not entry.name or entry.name == "") then
            name = session_name
        end
    end

    -- 4. Create ChatHistory with fake tab id
    viewer_tab_counter = viewer_tab_counter - 1
    local fake_tab = viewer_tab_counter
    local history = History.new(fake_tab)
    local buf = history:buf()
    vim.bo[buf].bufhidden = "wipe"

    -- 5. Open float window, set keymaps
    local editor_w = vim.o.columns
    local editor_h = vim.o.lines - vim.o.cmdheight
    local width = math.max(20, math.min(editor_w - 4, math.floor(editor_w * 0.85)))
    local height = math.max(5, math.min(editor_h - 4, math.floor(editor_h * 0.8)))
    local row = math.floor((editor_h - height) / 2)
    local col = math.floor((editor_w - width) / 2)
    local title = format_title(name, status)

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = title,
        title_pos = "center",
    })

    viewer_win = win
    viewer_history = history
    viewer_child_id = child_id
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

    vim.keymap.set("n", "<CR>", function()
        M.close()
        require("pi.subsessions").switch_to(child_id, function(ok, err)
            if not ok and err then
                Notify.error(err)
            end
        end)
    end, { buffer = buf, nowait = true, desc = "Promote subsession to active view" })

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
        viewer_loading = true
        viewer_event_queue = {}
        local sent = session.rpc:send({ type = "get_messages" }, function(res)
            vim.schedule(function()
                if not M.is_open() or viewer_child_id ~= current_child then
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
                replay(history, messages)
                viewer_loading = false
                local queue = viewer_event_queue or {}
                viewer_event_queue = nil
                for _, queued_msg in ipairs(queue) do
                    if not M.is_open_for(current_child) then
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
---@return table[] messages, string? session_name
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

return M
