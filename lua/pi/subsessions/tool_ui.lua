--- Sub-agent tool display helpers (labels, manifest names, result parsing).

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")

local M = {}

---@type table<string, boolean>
local SUBAGENT_TOOLS = {
    list_subagents = true,
    read_subagent = true,
    list_batches = true,
    dispatch_subagents = true,
    poll_subagents = true,
    wait_subagents = true,
    stop_subagents = true,
}

---@type table<string, table<string, string>>
local LABELS = {
    zh = {
        list_subagents = "子·列表",
        read_subagent = "子·读",
        list_batches = "子·批次",
        dispatch_subagents = "子·派发",
        poll_subagents = "子·轮询",
        wait_subagents = "子·等待",
        stop_subagents = "子·停止",
    },
    en = {
        list_subagents = "sub·list",
        read_subagent = "sub·read",
        list_batches = "sub·batches",
        dispatch_subagents = "sub·dispatch",
        poll_subagents = "sub·poll",
        wait_subagents = "sub·wait",
        stop_subagents = "sub·stop",
    },
}

---@param tool_name string
---@return boolean
function M.is_subagent_tool(tool_name)
    return SUBAGENT_TOOLS[tool_name] == true
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

---@param tool_name string
---@return string
function M.display_name(tool_name)
    local lang = M.resolve_lang()
    local table_for_lang = LABELS[lang] or LABELS.en
    return table_for_lang[tool_name] or tool_name
end

---@param id? string
---@return string?
function M.short_id(id)
    if type(id) ~= "string" or id == "" then
        return nil
    end
    local subcfg = Config.options.subagent or {}
    if subcfg.show_full_ids == true then
        return id
    end
    if #id <= 8 then
        return id
    end
    return "…" .. id:sub(-6)
end

--- Manifest display name (same source as :PiSessions child rows).
---@param child_id? string
---@return string?
function M.child_name(child_id)
    if type(child_id) ~= "string" or child_id == "" then
        return nil
    end
    local entry = Manifest.load()[child_id]
    if entry and type(entry.name) == "string" and entry.name ~= "" then
        return entry.name
    end
    return nil
end

---@param item table
---@return string
function M.item_label(item)
    if type(item) ~= "table" then
        return "?"
    end
    if type(item.task) == "string" and item.task ~= "" then
        if type(item.name) == "string" and item.name ~= "" then
            return item.name
        end
        return item.task:sub(1, 40)
    end
    if type(item.target) == "string" and item.target ~= "" then
        return M.child_name(item.target) or M.short_id(item.target) or item.target
    end
    return "?"
end

---@param args? table
---@return string?
function M.dispatch_header_detail(args)
    if type(args) ~= "table" or type(args.items) ~= "table" then
        return nil
    end
    local n = #args.items
    if n == 0 then
        return nil
    end
    if n == 1 then
        return M.item_label(args.items[1])
    end
    local spawn_n, msg_n = 0, 0
    for _, item in ipairs(args.items) do
        if type(item.task) == "string" and item.task ~= "" then
            spawn_n = spawn_n + 1
        elseif type(item.target) == "string" then
            msg_n = msg_n + 1
        end
    end
    local lang = M.resolve_lang()
    if lang == "zh" then
        return ("%d 项 (新建×%d · 续聊×%d)"):format(n, spawn_n, msg_n)
    end
    return ("%d items (spawn×%d · msg×%d)"):format(n, spawn_n, msg_n)
end

---@param result? table
---@return table?
function M.result_details(result)
    if type(result) ~= "table" then
        return nil
    end
    if type(result.details) == "table" then
        return result.details
    end
    local content = result.content
    if type(content) == "string" then
        local ok, parsed = pcall(vim.json.decode, content)
        if ok and type(parsed) == "table" then
            return parsed
        end
    elseif type(content) == "table" then
        for _, block in ipairs(content) do
            if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
                local ok, parsed = pcall(vim.json.decode, block.text)
                if ok and type(parsed) == "table" then
                    return parsed
                end
            end
        end
    end
    return nil
end

---@param details? table
---@return string?
function M.batch_status_text(details)
    if type(details) ~= "table" then
        return nil
    end
    local summary = details.summary
    local status = details.status
    local lang = M.resolve_lang()
    if type(summary) == "table" and type(summary.total) == "number" and summary.total > 0 then
        local done = summary.done or 0
        local total = summary.total
        if status == "completed" or status == "partial" or status == "failed" or status == "cancelled" then
            if lang == "zh" then
                return ("%d/%d %s"):format(done, total, status or "")
            end
            return ("%d/%d %s"):format(done, total, status or "")
        end
        if lang == "zh" then
            return ("%d/%d 进行中"):format(done, total)
        end
        return ("%d/%d running"):format(done, total)
    end
    if type(status) == "string" and status ~= "" then
        return status
    end
    return nil
end

---@param details? table
---@return string?
function M.list_subagents_status(details)
    if type(details) ~= "table" or type(details.subagents) ~= "table" then
        return nil
    end
    local total = #details.subagents
    local active = 0
    for _, row in ipairs(details.subagents) do
        if row.status == "active" then
            active = active + 1
        end
    end
    local lang = M.resolve_lang()
    if lang == "zh" then
        return ("(%d 个，%d 活跃)"):format(total, active)
    end
    return ("(%d total, %d active)"):format(total, active)
end

---@param details? table
---@return string?
function M.list_batches_status(details)
    if type(details) ~= "table" or type(details.batches) ~= "table" then
        return nil
    end
    local running = 0
    for _, batch in ipairs(details.batches) do
        if batch.status == "running" or batch.status == "pending" then
            running = running + 1
        end
    end
    local lang = M.resolve_lang()
    if lang == "zh" then
        return ("(%d 个批次，%d 进行中)"):format(#details.batches, running)
    end
    return ("(%d batches, %d running)"):format(#details.batches, running)
end

--- Completion report injected into the parent chat (user-spawned children).
---@param name string
---@param report string
---@return string
function M.completion_report(name, report)
    if M.resolve_lang() == "zh" then
        return ("[子会话「%s」已完成] %s"):format(name, report)
    end
    return ('[Sub-session "%s" completed] %s'):format(name, report)
end

--- dispatch uses inline rendering only for a single item with wait:true.
---@param args? table
---@return boolean
function M.dispatch_inline(args)
    if type(args) ~= "table" or type(args.items) ~= "table" then
        return true
    end
    if #args.items ~= 1 then
        return false
    end
    return args.wait == true
end

return M
