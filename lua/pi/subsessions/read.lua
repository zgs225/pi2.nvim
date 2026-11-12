--- Project session JSONL entries for parent Agent observation tools.

local M = {}

---@param path string
---@return table[] entries decoded lines (best effort)
local function read_jsonl(path)
    local file = io.open(path, "r")
    if not file then
        return {}
    end
    ---@type table[]
    local entries = {}
    local index = 0
    for line in file:lines() do
        if line ~= "" then
            local ok, entry = pcall(vim.json.decode, line)
            if ok and type(entry) == "table" then
                index = index + 1
                entry._index = index
                entries[#entries + 1] = entry
            end
        end
    end
    file:close()
    return entries
end

---@param content any
---@param max_len integer
---@return string
local function truncate_content(content, max_len)
    if type(content) == "string" then
        if #content > max_len then
            return content:sub(1, max_len) .. "…"
        end
        return content
    end
    if type(content) == "table" then
        for _, part in ipairs(content) do
            if type(part) == "table" and part.type == "text" and type(part.text) == "string" then
                return truncate_content(part.text, max_len)
            end
        end
    end
    return ""
end

---@param entry table
---@return string
local function project_entry(entry)
    local idx = entry._index or 0
    local t = entry.type
    if t == "message" and type(entry.message) == "table" then
        local msg = entry.message
        local role = msg.role or "?"
        local text = truncate_content(msg.content, 2000)
        return ("[%d] %s: %s"):format(idx, role, text)
    end
    if t == "message" and entry.role then
        return ("[%d] %s: %s"):format(idx, entry.role, truncate_content(entry.content, 2000))
    end
    if entry.type == "thinking" or (type(entry.message) == "table" and entry.message.role == "thinking") then
        return ("[%d] (thinking collapsed)"):format(idx)
    end
    if entry.type == "tool_use" or (type(entry.message) == "table" and entry.message.role == "toolUse") then
        local name = entry.name or entry.toolName or "tool"
        return ("[%d] tool %s (call)"):format(idx, name)
    end
    if entry.type == "tool_result" or (type(entry.message) == "table" and entry.message.role == "toolResult") then
        local err = entry.isError == true or (type(entry.message) == "table" and entry.message.isError)
        return ("[%d] tool result: %s"):format(idx, err and "failed" or "ok")
    end
    return ("[%d] %s"):format(idx, t or "entry")
end

---@param path string
---@param tail integer
---@return string[] lines projection
function M.project_tail(path, tail)
    local entries = read_jsonl(path)
    local start = math.max(1, #entries - tail + 1)
    ---@type string[]
    local lines = {}
    for i = start, #entries do
        lines[#lines + 1] = project_entry(entries[i])
    end
    return lines
end

---@param path string
---@param indices integer[]
---@return string[] full text per requested index
function M.entries_at(path, indices)
    local entries = read_jsonl(path)
    ---@type table<integer, table>
    local by_index = {}
    for _, e in ipairs(entries) do
        if e._index then
            by_index[e._index] = e
        end
    end
    ---@type string[]
    local lines = {}
    for _, idx in ipairs(indices) do
        local entry = by_index[idx]
        if entry then
            lines[#lines + 1] = ("--- entry %d ---\n%s"):format(idx, vim.json.encode(entry))
        end
    end
    return lines
end

---@class pi.LastTurn
---@field text string Last assistant text ("" when the turn produced none)
---@field stop_reason? string e.g. "stop", "toolUse", "error", "aborted", "length"
---@field error_message? string Provider/runtime error carried by a failed turn

--- Trailing state of a run in one pass over the session file: the last
--- assistant message's text, its stop reason, and the error message pi recorded
--- when that turn failed.
---
--- One read instead of three: the settle path needs all of them, and a
--- re-read per fact walks the whole JSONL again (sessions grow to megabytes).
---@param path string
---@return pi.LastTurn? turn nil when the file has no assistant message.
function M.last_turn(path)
    local entries = read_jsonl(path)
    for i = #entries, 1, -1 do
        local entry = entries[i]
        local message = entry.message
        if entry.type == "message" and type(message) == "table" and message.role == "assistant" then
            local error_message = message.errorMessage
            return {
                text = truncate_content(message.content, 100000),
                stop_reason = type(message.stopReason) == "string" and message.stopReason or nil,
                error_message = type(error_message) == "string" and error_message ~= "" and error_message or nil,
            }
        end
    end
    return nil
end

---@param path string
---@return string? last assistant text
function M.last_assistant_message(path)
    local turn = M.last_turn(path)
    return turn and turn.text or nil
end

--- Stop reason of the last assistant message in a session file.
---@param path string
---@return string? stop_reason e.g. "aborted", "stop", "error"
function M.last_stop_reason(path)
    local turn = M.last_turn(path)
    return turn and turn.stop_reason or nil
end

--- Infer a child's run status from the last meaningful JSONL entry.
---
--- The stop reason is authoritative for a completed turn: a provider/runtime
--- failure is persisted as an assistant message with `stopReason: "error"`
--- (content usually empty), so a bare "last message is an assistant message"
--- test would book a dead run as `completed`.
---@param path string
---@return "completed"|"interrupted"|"failed"|nil
function M.infer_run_status(path)
    local entries = read_jsonl(path)
    for i = #entries, 1, -1 do
        local entry = entries[i]
        local t = entry.type
        local msg = entry.message
        if t == "message" and type(msg) == "table" then
            if msg.role == "assistant" then
                if msg.stopReason == "error" then
                    return "failed"
                end
                if msg.stopReason == "aborted" then
                    return "interrupted"
                end
                return "completed"
            end
            if msg.role == "toolUse" or msg.role == "toolResult" then
                return "interrupted"
            end
        elseif t == "tool_use" or t == "tool_result" then
            return "interrupted"
        end
    end
    return nil
end

--- Resolve a session id to its JSONL path.
---
--- Delegates to `History.find_by_id`, which resolves by filename convention
--- (one readdir) instead of a full `list()` scan — a full scan parses every
--- session file in the directory and used to make callers like
--- `rebuild_statuses` (one lookup per manifest entry) block the editor for
--- tens of seconds on large session dirs.
---@param session_id string
---@return string?
function M.find_path(session_id)
    local info = require("pi.sessions.history").find_by_id(session_id)
    return info and info.path or nil
end

return M
