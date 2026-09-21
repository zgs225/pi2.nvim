--- Todo tool display helpers (labels, locale, result parsing, list rendering).
---
--- Pure module: no state, no editor UI. Shared by the chat tool renderer
--- (lua/pi/ui/chat/tools.lua) and the todo side panel (lua/pi/todo/init.lua),
--- per DESIGN-todo.md §7. The runtime config file (state_path/publish)
--- follows the title.lua pattern: the process env is frozen at spawn, so the
--- bundled extension (extensions/todo.ts) re-reads the file on every context
--- event and live setup() calls apply without respawning the RPC process.

local Config = require("pi.config")

local M = {}

---@type string?
local state_path_override = nil

--- Runtime file conveying the configured todo options to already-spawned
--- RPC processes, as JSON:
--- {"enabled":bool,"remind_after_turns":number,"max_items":number}.
--- The PID is part of the name because stdpath("run") is per-user, not
--- per-process: without it two concurrently running nvim instances would
--- clobber each other's todo config.
---@return string
function M.state_path()
    if state_path_override then
        return state_path_override
    end
    return vim.fn.stdpath("run") .. "/pi2nvim-todo-config-" .. tostring(vim.fn.getpid())
end

--- Override the state file path (tests).
---@param path string?
function M._set_path(path)
    state_path_override = path
end

--- Publish the configured todo options for the extension. Always writes the
--- file: an explicit `enabled = false` must reach the extension so live
--- setup() calls disable the tool without a respawn (same rationale as
--- title.lua).
---@param cfg pi.TodoConfig?
function M.publish(cfg)
    local path = M.state_path()
    cfg = cfg or {}
    local payload = vim.json.encode({
        enabled = cfg.enabled ~= false,
        remind_after_turns = type(cfg.remind_after_turns) == "number" and cfg.remind_after_turns or 3,
        max_items = type(cfg.max_items) == "number" and cfg.max_items or 20,
    })
    local f = io.open(path, "w")
    if f then
        f:write(payload)
        f:close()
    end
end

--- The published todo options, if the file exists (mirrors what the
--- extension sees).
---@return { enabled: boolean, remind_after_turns: integer, max_items: integer }?
function M.published()
    local f = io.open(M.state_path(), "r")
    if not f then
        return nil
    end
    local content = f:read("*a") or ""
    f:close()
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    return {
        enabled = decoded.enabled ~= false,
        remind_after_turns = type(decoded.remind_after_turns) == "number" and decoded.remind_after_turns or 3,
        max_items = type(decoded.max_items) == "number" and decoded.max_items or 20,
    }
end

--- Reset cached state (tests). The module is stateless today; kept as a
--- stable hook so future caches have a canonical test teardown.
function M._reset() end

---@param tool_name string
---@return boolean
function M.is_todo_tool(tool_name)
    return tool_name == "todo_write"
end

---@return string
local function locale_hint()
    local parts = {}
    for _, key in ipairs({ "LANG", "LC_ALL", "LC_MESSAGES" }) do
        local v = vim.fn.getenv(key)
        if v and v ~= vim.NIL then
            local s = tostring(v)
            if s ~= "" then
                parts[#parts + 1] = s
            end
        end
    end
    local ok, helplang = pcall(function()
        return vim.o.helplang
    end)
    if ok and type(helplang) == "string" and helplang ~= "" then
        parts[#parts + 1] = helplang
    end
    return table.concat(parts, " ")
end

--- Auto language: title.lang when set, else `zh` for Chinese UI locales.
--- Same resolution as subsessions/tool_ui.lua.
---@return "zh"|"en"
function M.resolve_lang()
    local title = Config.options.title or {}
    local lang = title.lang
    if type(lang) == "string" and lang ~= "" then
        if lang:match("^zh") then
            return "zh"
        end
        return "en"
    end
    if locale_hint():match("zh") then
        return "zh"
    end
    return "en"
end

---@type table<string, table<string, string>>
local LABELS = {
    zh = {
        todo_write = "待办·写",
    },
    en = {
        todo_write = "todo·write",
    },
}

---@param tool_name string
---@return string
function M.display_name(tool_name)
    local lang = M.resolve_lang()
    local table_for_lang = LABELS[lang] or LABELS.en
    return table_for_lang[tool_name] or tool_name
end

--- Best-effort JSON decode of a content payload; returns the parsed table
--- only when it looks like todo details (a `todos` array is present).
---@param text string
---@return table?
local function decode_todo_json(text)
    if type(text) ~= "string" or vim.trim(text) == "" then
        return nil
    end
    local ok, parsed = pcall(vim.json.decode, text)
    if ok and type(parsed) == "table" and type(parsed.todos) == "table" then
        return parsed
    end
    return nil
end

---@param content any
---@return table?
local function details_from_content(content)
    if type(content) == "string" then
        return decode_todo_json(content)
    end
    if type(content) == "table" then
        for _, block in ipairs(content) do
            if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
                local parsed = decode_todo_json(block.text)
                if parsed then
                    return parsed
                end
            end
        end
    end
    return nil
end

--- Normalize a raw details table into the canonical shape
--- { todos = table[], completed = integer, total = integer }.
--- completed/total fall back to counting the todos when absent, so a
--- hand-written details table still renders correctly.
---@param details table
---@return { todos: table[], completed: integer, total: integer }
function M._normalize(details)
    local todos = {}
    for _, todo in ipairs(details.todos) do
        if type(todo) == "table" then
            todos[#todos + 1] = todo
        end
    end
    local total = type(details.total) == "number" and details.total or #todos
    local completed = type(details.completed) == "number" and details.completed or 0
    if type(details.completed) ~= "number" then
        for _, todo in ipairs(todos) do
            if todo.status == "completed" then
                completed = completed + 1
            end
        end
    end
    return { todos = todos, completed = completed, total = total }
end

--- Safe-parse the todo details from a tool result: a well-shaped
--- `result.details` table, or JSON in the result content (string or text
--- blocks). Returns nil for anything that does not carry a todos list.
---@param result? table
---@return { todos: table[], completed: integer, total: integer }?
function M.result_details(result)
    if type(result) ~= "table" then
        return nil
    end
    if type(result.details) == "table" and type(result.details.todos) == "table" then
        return M._normalize(result.details)
    end
    local parsed = details_from_content(result.content)
    if parsed then
        return M._normalize(parsed)
    end
    return nil
end

--- Resolve the completed/total counters from a details table.
---@param details? table
---@return integer? completed
---@return integer? total
local function counters(details)
    if type(details) ~= "table" then
        return nil, nil
    end
    local total = type(details.total) == "number" and details.total or nil
    local completed = type(details.completed) == "number" and details.completed or nil
    if (not total or not completed) and type(details.todos) == "table" then
        local t, c = 0, 0
        for _, todo in ipairs(details.todos) do
            if type(todo) == "table" then
                t = t + 1
                if todo.status == "completed" then
                    c = c + 1
                end
            end
        end
        total = total or t
        completed = completed or c
    end
    return completed, total
end

--- Compact progress label, e.g. "2/5 completed" (zh: "2/5 已完成").
--- nil when there is nothing to count.
---@param details? table
---@return string?
function M.progress_text(details)
    local completed, total = counters(details)
    if not total or total <= 0 then
        return nil
    end
    local lang = M.resolve_lang()
    if lang == "zh" then
        return ("%d/%d 已完成"):format(completed or 0, total)
    end
    return ("%d/%d completed"):format(completed or 0, total)
end

--- Display text for one todo item: the in-progress form (`activeForm`)
--- when present, else the imperative content.
---@param todo table
---@return string
local function todo_text(todo)
    local text = todo.activeForm or todo.content
    if type(text) ~= "string" or text == "" then
        return "?"
    end
    return (text:gsub("[\r\n]+", " "))
end

---@param todo table
---@return string
local function todo_line(todo)
    if todo.status == "completed" then
        return "✓ " .. todo_text(todo)
    elseif todo.status == "in_progress" then
        return "◐ " .. todo_text(todo)
    end
    return "○ " .. todo_text(todo)
end

--- Plain-text rendering of a todo list: a header line with the progress
--- count, then one line per todo — "✓ content" (completed), "◐
--- activeForm-or-content" (in_progress), "○ content" (pending). Truncation
--- via opts.max_items keeps the first max_items item lines and appends a
--- "… N more" tail. Returns {} when the details carry no todos.
---@param details? table
---@param opts? { max_items?: integer }
---@return string[]
function M.format_lines(details, opts)
    local lines = {}
    if type(details) ~= "table" or type(details.todos) ~= "table" then
        return lines
    end
    local progress = M.progress_text(details)
    if progress then
        lines[#lines + 1] = progress
    end

    local item_lines = {}
    for _, todo in ipairs(details.todos) do
        item_lines[#item_lines + 1] = todo_line(type(todo) == "table" and todo or {})
    end

    local max_items = type(opts) == "table" and type(opts.max_items) == "number" and opts.max_items or nil
    if max_items and #item_lines > max_items then
        local more = #item_lines - max_items
        for i = 1, max_items do
            lines[#lines + 1] = item_lines[i]
        end
        if M.resolve_lang() == "zh" then
            lines[#lines + 1] = ("… 还有 %d 项"):format(more)
        else
            lines[#lines + 1] = ("… %d more"):format(more)
        end
    else
        vim.list_extend(lines, item_lines)
    end
    return lines
end

return M
