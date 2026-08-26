--- Fork / clone (:PiFork / :PiClone) — start a new session from a past user
--- message, or duplicate the current active branch into a new session file.
--- Mirrors the pi TUI's built-in /fork and /clone commands over the RPC
--- protocol's fork / clone / get_fork_messages commands:
---
---   fork(entryId)      → new session whose history ends before the selected
---                        user message; the message text is returned so the
---                        client can place it back in the prompt (re-ask).
---   clone              → new session duplicating the whole active branch at
---                        the current position; no selection, no prefill.
---
--- Both rebind the RPC session to the new file and can be cancelled by a
--- session_before_fork extension event handler (response carries cancelled).
--- While :PiTree branches *inside* the current session file, fork and clone
--- always produce a separate session file.

local M = {}

local Notify = require("pi.notify")
local Dialog = require("pi.ui.dialog")

--- Max characters of a forkable message shown in the picker preview.
local MAX_FRAG = 120

--- Collapse a string to a single trimmed line, truncated to MAX_FRAG.
---@param s string
---@return string
local function one_line(s)
    local flat = vim.trim((s or ""):gsub("%s+", " "))
    if #flat > MAX_FRAG then
        return flat:sub(1, MAX_FRAG) .. "…"
    end
    return flat
end

---@class pi.ForkMessage
---@field entryId string backend entry id of the user message
---@field text string message text

--- Session guard shared by fork and clone: an active, running, idle session,
--- or nil when one of the guards failed (a warning was already shown).
---@param verb string gerund for the "wait for the agent" message
---@return pi.Session?
local function require_idle_session(verb)
    local Sessions = require("pi.sessions.manager")
    local session = Sessions.get()
    if not session or not session.rpc:is_running() then
        Notify.warn("No active session")
        return nil
    end
    if session.chat:is_streaming() then
        Notify.warn("Wait for the agent to finish before " .. verb)
        return nil
    end
    return session
end

--- Refresh the sessions overview after the backend rebound this session to a
--- new session file (the same plumbing new_session uses to refresh the list).
---@param session pi.Session
local function refresh_sessions_list(session)
    local UI = require("pi.ui.sessions")
    UI.invalidate(session)
    UI.clear_flags(session)
    UI.request_refresh()
end

--- One-line picker label for a forkable user message (a [user] kind tag plus
--- a truncated preview of the message text).
---@param msg pi.ForkMessage
---@return string
function M.format_message(msg)
    return "[user] " .. one_line(msg.text or "")
end

--- :PiFork — pick a past user message and start a new session from it. The
--- new session replays history up to (excluding) the selected message, whose
--- text is placed back in the prompt for editing and resending.
function M.fork()
    local session = require_idle_session("forking")
    if not session then
        return
    end

    session.rpc:send({ type = "get_fork_messages" }, function(res)
        vim.schedule(function()
            if not res.success then
                Notify.error(res.error or "Failed to get fork messages")
                return
            end
            local messages = (res.data and res.data.messages) or {}
            if #messages == 0 then
                Notify.info("No messages to fork from")
                return
            end
            M._pick(session, messages)
        end)
    end)
end

--- Pick a fork point from the user-message list via Dialog.select (kind
--- pi-fork-select), mirroring the TUI's user-message selector.
---@param session pi.Session
---@param messages pi.ForkMessage[]
function M._pick(session, messages)
    local options = {}
    local ids = {}
    for _, msg in ipairs(messages) do
        options[#options + 1] = M.format_message(msg)
        ids[#ids + 1] = msg.entryId
    end
    Dialog.select({
        title = "Fork from message",
        options = options,
        kind = "pi-fork-select",
    }, function(choice)
        if not choice then
            return
        end
        for i, option in ipairs(options) do
            if option == choice then
                M._do_fork(session, ids[i])
                return
            end
        end
    end)
end

--- Send the fork command. On success the backend rebinds this session to the
--- new fork file: refresh the sessions overview, reload the chat from the new
--- branch, and prefill the prompt with the forked message text (mirrors the
--- TUI's editor.setText(result.selectedText)). A failed or cancelled fork
--- leaves the session untouched.
---@param session pi.Session
---@param entry_id string
function M._do_fork(session, entry_id)
    session.chat:set_status({ type = "agent", text = "Forking…" })
    local sent = session.rpc:send({ type = "fork", entryId = entry_id }, function(res)
        vim.schedule(function()
            session.chat:set_status(nil)
            if not res.success then
                Notify.error(res.error or "Fork failed")
                return
            end
            local data = res.data or {}
            if data.cancelled then
                return -- an extension refused the fork; nothing changed
            end
            refresh_sessions_list(session)
            require("pi.sessions.manager").reload_messages(session)
            local text = data.text
            if type(text) == "string" and text ~= "" then
                session.chat:_set_prompt_draft(text)
            end
            Notify.info("Forked to new session")
        end)
    end)
    if not sent then
        session.chat:set_status(nil)
        Notify.error("Failed to send fork command")
    end
end

--- :PiClone — duplicate the current active branch into a new session at the
--- current position. The chat keeps its content; only the backing session
--- file (and the sessions overview) changes.
function M.clone()
    local session = require_idle_session("cloning")
    if not session then
        return
    end

    session.chat:set_status({ type = "agent", text = "Cloning…" })
    local sent = session.rpc:send({ type = "clone" }, function(res)
        vim.schedule(function()
            session.chat:set_status(nil)
            if not res.success then
                Notify.error(res.error or "Clone failed")
                return
            end
            local data = res.data or {}
            if data.cancelled then
                return -- an extension refused the clone; nothing changed
            end
            refresh_sessions_list(session)
            require("pi.sessions.manager").reload_messages(session)
            Notify.info("Cloned to new session")
        end)
    end)
    if not sent then
        session.chat:set_status(nil)
        Notify.error("Failed to send clone command")
    end
end

return M
