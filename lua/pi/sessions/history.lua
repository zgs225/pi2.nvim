local M = {}

local Config = require("pi.config")

---@class pi.SessionInfo
---@field id string            session id from header
---@field path string          absolute path to .jsonl file
---@field timestamp string     ISO timestamp from header
---@field modified number      file mtime (for sorting)
---@field first_message string first user message (truncated)
---@field name? string         display name from session_info entry

--- Resolve the pi agent directory.
---@return string
local function get_agent_dir()
    if Config.options.agent_dir then
        return Config.options.agent_dir
    end
    local env = vim.env.PI_CODING_AGENT_DIR
    if env and env ~= "" then
        return env
    end
    return vim.fn.expand("~/.pi/agent")
end

---@param ... string
---@return string
local function join_path(...)
    local parts = { ... }
    local path = parts[1] or ""
    local sep = package.config:sub(1, 1)
    for i = 2, #parts do
        local part = parts[i] or ""
        if part ~= "" then
            path = path:gsub("[\\/]+$", "") .. sep .. part:gsub("^[\\/]+", "")
        end
    end
    return path
end

--- Encode a cwd path into the directory name format pi uses.
--- e.g. "/Users/Alex/Dev/project" → "--Users-Alex-Dev-project--"
--- e.g. "C:\\Users\\Alex\\Dev\\project" → "--C--Users-Alex-Dev-project--"
---@param cwd string
---@return string
local function encode_cwd(cwd)
    local encoded = cwd:gsub("^[\\/]", ""):gsub("[\\/:]", "-")
    return "--" .. encoded .. "--"
end

--- Get the sessions directory for the current cwd.
---@return string
function M.get_sessions_dir()
    local agent_dir = get_agent_dir()
    local cwd = vim.fn.getcwd()
    return join_path(agent_dir, "sessions", encode_cwd(cwd))
end

--- Decode a line if it is a `session_info` entry carrying a non-empty name.
---@param line string
---@return string? name trimmed display name, or nil
local function session_info_name(line)
    if not line:find('"session_info"', 1, true) then
        return nil
    end
    local lok, entry = pcall(vim.json.decode, line)
    if lok and entry and entry.type == "session_info" and type(entry.name) == "string" and entry.name ~= "" then
        return entry.name:match("^%s*(.-)%s*$") -- trim
    end
    return nil
end

--- Parse a .jsonl session file: read header + first user message + latest name.
---@param path string
---@return pi.SessionInfo?
function M.parse(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end

    local header_line = file:read("*l")
    if not header_line or header_line == "" then
        file:close()
        return nil
    end
    local ok, header = pcall(vim.json.decode, header_line)
    if not ok or not header or header.type ~= "session" then
        file:close()
        return nil
    end

    -- Single forward pass over the buffered file. The first user message sits
    -- near the top, so stop decoding message lines once it is found. The latest
    -- session name can appear anywhere (latest wins), so every line is visited,
    -- but only rare, small `session_info` lines are JSON-decoded — huge message
    -- and tool-output lines are skipped via a cheap substring prefilter. This
    -- keeps listing I/O-bound rather than decode-bound for multi-MB sessions
    -- (the previous full JSON-decode of every line made it take many seconds).
    local first_message = ""
    local name = nil
    for line in file:lines() do
        if first_message == "" and line:find('"message"', 1, true) then
            local lok, entry = pcall(vim.json.decode, line)
            if lok and entry and entry.type == "message" then
                local msg = entry.message
                if msg and msg.role == "user" then
                    local content = msg.content
                    if type(content) == "string" then
                        first_message = content
                    elseif type(content) == "table" then
                        for _, part in ipairs(content) do
                            if type(part) == "table" and part.type == "text" then
                                first_message = part.text or ""
                                break
                            end
                        end
                    end
                end
            end
        end
        local entry_name = session_info_name(line)
        if entry_name then
            name = entry_name
        end
    end
    file:close()

    -- Truncate to single line, max 80 chars
    first_message = first_message:gsub("\n", " "):sub(1, 80)

    return {
        path = path,
        id = header.id or "",
        timestamp = header.timestamp or "",
        modified = vim.fn.getftime(path),
        first_message = first_message,
        name = name,
    }
end

--- Find a session file by id without scanning every session.
---
--- pi core names session files `<timestamp>_<id>.jsonl`, so a filename glob
--- resolves the path with one readdir and no file reads (a full `list()`
--- parses every file's lines and costs seconds on large session dirs). The
--- glob hit is still verified against the header id before it is returned.
--- Falls back to a full `list()` scan when no filename matches (files written
--- by other tools, or a naming convention that stops holding) — the fallback
--- preserves the old `list()`-scan semantics exactly, including picking the
--- newest file when several share an id.
---@param id string
---@return pi.SessionInfo?
function M.find_by_id(id)
    if type(id) ~= "string" or id == "" then
        return nil
    end
    local dir = M.get_sessions_dir()
    local files = vim.fn.glob(join_path(dir, "*_" .. id .. ".jsonl"), false, true)
    ---@type pi.SessionInfo?
    local best = nil
    for _, file in ipairs(files) do
        local info = M.parse(file)
        if info and info.id == id and (best == nil or info.modified > best.modified) then
            best = info
        end
    end
    if best then
        return best
    end
    for _, info in ipairs(M.list()) do
        if info.id == id then
            return info
        end
    end
    return nil
end

--- List all sessions for the current cwd, sorted by modified time (newest first).
---@return pi.SessionInfo[]
function M.list()
    local dir = M.get_sessions_dir()
    ---@type string[]
    local files = vim.fn.glob(join_path(dir, "*.jsonl"), false, true)
    ---@type pi.SessionInfo[]
    local sessions = {}
    for _, file in ipairs(files) do
        local info = M.parse(file)
        if info then
            sessions[#sessions + 1] = info
        end
    end
    table.sort(sessions, function(a, b)
        return a.modified > b.modified
    end)
    return sessions
end

return M
