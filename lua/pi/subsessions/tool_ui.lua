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
        -- Same derivation the manifest stores as name_source = "fallback".
        return Manifest.fallback_name(item.task) or "?"
    end
    if type(item.target) == "string" and item.target ~= "" then
        return M.child_name(item.target) or M.short_id(item.target) or item.target
    end
    return "?"
end

--- Format model and thinking level for a dispatch item, e.g. "claude-3-7-sonnet · think: high".
--- Checks item.model and item.thinking_level (or item.think_level), and falls back
--- to manifest config for target sub-agents when not explicitly supplied.
---@param item table
---@return string?
function M.item_config_label(item)
    if type(item) ~= "table" then
        return nil
    end

    local model = item.model
    local thinking_level = item.thinking_level or item.think_level

    if (not model or not thinking_level) and type(item.target) == "string" and item.target ~= "" then
        local entry = Manifest.load()[item.target]
        local cfg = entry and entry.config
        if cfg then
            if not model and cfg.model then
                model = cfg.model
            end
            if not thinking_level and cfg.thinking_level then
                thinking_level = cfg.thinking_level
            end
        end
    end

    local model_id
    if type(model) == "table" then
        if type(model.id) == "string" and model.id ~= "" then
            model_id = model.id
        elseif type(model.name) == "string" and model.name ~= "" then
            model_id = model.name
        end
    elseif type(model) == "string" and model ~= "" then
        model_id = model
    end

    local tl_str
    if type(thinking_level) == "string" and thinking_level ~= "" then
        tl_str = "think: " .. thinking_level
    end

    if model_id and tl_str then
        return model_id .. " · " .. tl_str
    elseif model_id then
        return model_id
    elseif tl_str then
        return tl_str
    end
    return nil
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
        local label = M.item_label(args.items[1])
        local cfg = M.item_config_label(args.items[1])
        if cfg then
            return label .. " (" .. cfg .. ")"
        end
        return label
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
        if spawn_n > 0 and msg_n > 0 then
            return ("%d 项 (新建×%d · 续聊×%d)"):format(n, spawn_n, msg_n)
        elseif spawn_n > 0 then
            return ("%d 项 (新建×%d)"):format(n, spawn_n)
        elseif msg_n > 0 then
            return ("%d 项 (续聊×%d)"):format(n, msg_n)
        end
        return ("%d 项"):format(n)
    end
    if spawn_n > 0 and msg_n > 0 then
        return ("%d items (spawn×%d · msg×%d)"):format(n, spawn_n, msg_n)
    elseif spawn_n > 0 then
        return ("%d items (spawn×%d)"):format(n, spawn_n)
    elseif msg_n > 0 then
        return ("%d items (msg×%d)"):format(n, msg_n)
    end
    return ("%d items"):format(n)
end

---@class pi.DispatchRow
---@field prefix string  tree prefix incl. indent ("  ├─ " / "  └─ ")
---@field mark string  "" | "·" | "◐" | "✓" | "✗" | "⊘"
---@field mark_hl string|nil  highlight group for the mark (nil when no mark)
---@field label string
---@field excerpt? string  flattened, at most 80 chars

---@class pi.DispatchMark
---@field glyph string
---@field hl string

---@type table<string, pi.DispatchMark>
local DISPATCH_MARKS = {
    queued = { glyph = "·", hl = "Comment" },
    spawning = { glyph = "◐", hl = "PiToolRunning" },
    running = { glyph = "◐", hl = "PiToolRunning" },
    ok = { glyph = "✓", hl = "PiToolStatus" },
    failed = { glyph = "✗", hl = "PiToolError" },
    cancelled = { glyph = "⊘", hl = "PiToolError" },
}

---@param text string
---@return string
local function flatten(text)
    -- Lazy require: pi.ui.chat.tools requires this module at load time.
    return require("pi.ui.chat.tools").flatten_line(text)
end

--- Final body rows for a dispatch_subagents block: exactly one row per args
--- item, carrying the tree prefix, the item's state mark, its label and (for
--- failed/cancelled items) a truncated error excerpt. details.items and
--- args.items correspond by index (normalize_item preserves order).
---@param args? table  tool input (block mode always carries `items`)
---@param details? table  parsed tool result details
---@return pi.DispatchRow[]|nil rows  nil when details has no `items` table
function M.dispatch_rows(args, details)
    if type(args) ~= "table" or type(args.items) ~= "table" then
        return nil
    end
    if type(details) ~= "table" or type(details.items) ~= "table" then
        return nil
    end
    local ditems = details.items
    local n = #args.items

    ---@param ditem any
    ---@return string
    local function status_of(ditem)
        if type(ditem) == "table" and type(ditem.status) == "string" then
            return ditem.status
        end
        return "queued"
    end

    -- While every item is still queued no marks are drawn at all: the row
    -- collapses back to the plain on_start tree (zero information, no ink).
    local all_queued = true
    for i = 1, n do
        if status_of(ditems[i]) ~= "queued" then
            all_queued = false
            break
        end
    end

    local rows = {} ---@type pi.DispatchRow[]
    for i = 1, n do
        local aitem = args.items[i]
        local ditem = ditems[i]
        local status = status_of(ditem)
        local mark, mark_hl = "", nil ---@type string, string?
        if not all_queued then
            local spec = DISPATCH_MARKS[status] or DISPATCH_MARKS.queued
            mark, mark_hl = spec.glyph, spec.hl
        end
        -- Only a ref the caller passed explicitly is shown; the default
        -- 0-based index ref (normalize_item's fallback) is noise.
        local ref ---@type string?
        if
            type(aitem) == "table"
            and type(aitem.ref) == "string"
            and aitem.ref ~= ""
            and aitem.ref ~= tostring(i - 1)
        then
            ref = aitem.ref
        end
        local label = (ref and ("[%s] "):format(ref) or "") .. M.item_label(ditem or aitem)
        local excerpt ---@type string?
        if
            (status == "failed" or status == "cancelled")
            and type(ditem) == "table"
            and type(ditem.error) == "string"
            and ditem.error ~= ""
        then
            excerpt = flatten(ditem.error:sub(1, 80))
        end
        rows[i] = {
            prefix = i == n and "  └─ " or "  ├─ ",
            mark = mark,
            mark_hl = mark_hl,
            label = label,
            excerpt = excerpt,
        }
    end
    return rows
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
                ---@type table<string, string>
                local zh_words = {
                    completed = "已完成",
                    partial = "部分失败",
                    failed = "失败",
                    cancelled = "已取消",
                }
                return ("%d/%d %s"):format(done, total, zh_words[status] or status)
            end
            return ("%d/%d %s"):format(done, total, status)
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
