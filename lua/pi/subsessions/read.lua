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

--- Bytes read per backward window when walking a transcript from its end.
local TAIL_WINDOW_BYTES = 64 * 1024

---@class pi.JsonlTail
---@field next fun(): table? next decoded entry, newest first (nil once the file is exhausted)
---@field close fun() release the file handle

--- Walk a JSONL file's entries from the end, decoding only what it touches.
---
--- A session transcript grows to tens of megabytes and one line can be hundreds
--- of kilobytes, so decoding every line to look at the *last* meaningful entry is
--- an O(file size) cost — and it also means decoding payloads no caller wants. The
--- startup status rebuild used to pay that once per manifest row and froze the
--- first Pi open for seconds (startup-cost iron rule in `AGENTS.md`). This reader
---
---   * reads backwards in fixed 64 KiB windows, each byte at most once (a window
---     that starts mid-line hands its fragment to the next, older window; nothing
---     is re-read or enlarged);
---   * skips a line without a `message` / `tool` payload before decoding it —
---     session headers, `session_info` names, thinking and system entries can
---     never describe a turn, and they are often the largest lines in the file.
---
--- Every line handed to the decoder is whole. Undecodable lines are skipped,
--- exactly like the forward scan.
---@param path string
---@return pi.JsonlTail? tail nil when the file cannot be read
local function open_tail(path)
    local handle = io.open(path, "rb")
    if not handle then
        return nil
    end
    local pos = handle:seek("end")
    if type(pos) ~= "number" then
        handle:close()
        return nil
    end

    ---@type string[] lines of the current window, in file order
    local pending = {}
    ---@type integer index of the next line to pop (pops from the end = newest)
    local pending_index = 0
    --- Start of the oldest line already read but not yet complete: the next,
    --- older window contributes its beginning.
    local carry = ""
    local exhausted = false
    local closed = false

    local function close()
        if not closed then
            closed = true
            handle:close()
        end
    end

    --- Queue one more window of whole lines, older than the previously queued
    --- ones. Returns false once the whole file has been read.
    ---@return boolean queued
    local function fill()
        while not exhausted do
            if pos <= 0 then
                exhausted = true
                if carry ~= "" then
                    pending = { carry }
                    pending_index = 1
                    carry = ""
                    return true
                end
                return false
            end
            local start = math.max(0, pos - TAIL_WINDOW_BYTES)
            handle:seek("set", start)
            local chunk = handle:read(pos - start) or ""
            pos = start
            if start > 0 then
                -- The window begins mid-line: that head fragment belongs to the
                -- line whose tail is already in `carry`, and the rest of the
                -- window starts on a boundary.
                local newline = chunk:find("\n", 1, true)
                if newline then
                    carry = chunk:sub(1, newline - 1) .. carry
                    chunk = chunk:sub(newline + 1)
                else
                    carry = chunk .. carry
                    chunk = ""
                end
            end
            local lines = {}
            for line in chunk:gmatch("[^\n]+") do
                line = line:gsub("\r$", "")
                if line ~= "" then
                    lines[#lines + 1] = line
                end
            end
            if start == 0 and carry ~= "" then
                local line = carry:gsub("\r$", "")
                if line ~= "" then
                    table.insert(lines, 1, line)
                end
                carry = ""
            end
            if #lines > 0 then
                pending = lines
                pending_index = #lines
                return true
            end
        end
        return false
    end

    ---@param line string
    ---@return table? entry
    local function decode(line)
        -- Cheap prefilter: an entry that can describe a turn always carries a
        -- `message` (type=message, or its role) or a tool payload. Skipping the
        -- decode keeps multi-hundred-KB session_info/system lines free.
        if not (line:find("message", 1, true) or line:find("tool", 1, true)) then
            return nil
        end
        local ok, entry = pcall(vim.json.decode, line)
        if ok and type(entry) == "table" then
            return entry
        end
        return nil
    end

    ---@return table? entry
    local function next_entry()
        while true do
            if pending_index > 0 then
                local line = pending[pending_index]
                pending_index = pending_index - 1
                local entry = decode(line)
                if entry then
                    return entry
                end
            elseif not fill() then
                close()
                return nil
            end
        end
    end

    return { next = next_entry, close = close }
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
--- re-read per fact walks the whole JSONL again. The read starts at the end of
--- the file (see `open_tail`) — the answer always lives in the trailing entries.
---@param path string
---@return pi.LastTurn? turn nil when the file has no assistant message.
function M.last_turn(path)
    local tail = open_tail(path)
    if not tail then
        return nil
    end
    while true do
        local entry = tail.next()
        if not entry then
            tail.close()
            return nil
        end
        local message = entry.message
        if entry.type == "message" and type(message) == "table" and message.role == "assistant" then
            tail.close()
            local error_message = message.errorMessage
            return {
                text = truncate_content(message.content, 100000),
                stop_reason = type(message.stopReason) == "string" and message.stopReason or nil,
                error_message = type(error_message) == "string" and error_message ~= "" and error_message or nil,
            }
        end
    end
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

--- Status one JSONL entry implies for a child run, or nil when the entry says
--- nothing about the run's outcome (session header, session_info, thinking or
--- system entries).
---@param entry table
---@return "completed"|"interrupted"|"failed"|nil
local function entry_run_status(entry)
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
    return nil
end

--- Infer a child's run status from the last meaningful JSONL entry.
---
--- The stop reason is authoritative for a completed turn: a provider/runtime
--- failure is persisted as an assistant message with `stopReason: "error"`
--- (content usually empty), so a bare "last message is an assistant message"
--- test would book a dead run as `completed`.
---
--- Reads backwards from the end of the file and stops at the first decisive
--- entry (`open_tail`), so the cost is the trailing window, not the transcript.
---@param path string
---@return "completed"|"interrupted"|"failed"|nil
function M.infer_run_status(path)
    local tail = open_tail(path)
    if not tail then
        return nil
    end
    while true do
        local entry = tail.next()
        if not entry then
            tail.close()
            return nil
        end
        local status = entry_run_status(entry)
        if status then
            tail.close()
            return status
        end
    end
end

--- Resolve a session id to its JSONL path.
---
--- Delegates to `History.find_by_id`, which resolves by filename convention
--- (one readdir) instead of a full `list()` scan — a full scan parses every
--- session file in the directory and used to make callers like
--- `rebuild_statuses` (one lookup per manifest entry) block the editor for
--- tens of seconds on large session dirs.
---
--- `opts.session_file` short-circuits the lookup when the caller already knows
--- the path (a live session's backend-reported file); it is only trusted while
--- the file is still readable, otherwise the id lookup runs as before.
---@param session_id string
---@param opts? { cwd?: string, session_file?: string }|string `cwd` (or the shorthand
---   string form) selects the workspace whose session directory to search;
---   `session_file` is a known path to reuse.
---@return string?
function M.find_path(session_id, opts)
    local cwd, session_file
    if type(opts) == "string" then
        cwd = opts
    elseif type(opts) == "table" then
        cwd = opts.cwd
        session_file = opts.session_file
    end
    if type(session_file) == "string" and session_file ~= "" and vim.fn.filereadable(session_file) == 1 then
        return session_file
    end
    local info = require("pi.sessions.history").find_by_id(session_id, cwd)
    return info and info.path or nil
end

return M
