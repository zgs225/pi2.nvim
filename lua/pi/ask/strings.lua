--- Localized strings for the bundled ask tool: the float chrome
--- (lua/pi/ui/ask.lua) and the chat renderer (lua/pi/ui/chat/tools.lua).
---
--- Same language resolution as lua/pi/todo/tool_ui.lua: `title.lang` when set,
--- otherwise `zh` for a Chinese UI locale, else `en`. Configuration is read at
--- call time, so a live setup() applies without reloading the module.

local M = {}

---@return string
local function locale_hint()
    local parts = {}
    for _, key in ipairs({ "LANG", "LC_ALL", "LC_MESSAGES" }) do
        local value = vim.fn.getenv(key)
        if value and value ~= vim.NIL then
            local text = tostring(value)
            if text ~= "" then
                parts[#parts + 1] = text
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

--- Auto language: `title.lang` when set, else `zh` for Chinese UI locales.
---@return "zh"|"en"
function M.resolve_lang()
    local title = require("pi.config").options.title or {}
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
local STRINGS = {
    zh = {
        float_title = "ask",
        progress = "ask · %d/%d",
        review = "复核",
        free_text = "自己输入…",
        wrote = "(wrote) ",
        unanswered = "未答",
        answered_mark = "■",
        unanswered_mark = "□",
        hint_move = "j/k 移动",
        hint_switch = "h/l 切题",
        hint_select = "⏎ 确认",
        hint_toggle = "Space 多选",
        hint_clear = "x 清空",
        hint_free = "i 输入",
        hint_submit = "ZZ 提交",
        hint_cancel = "Esc 取消",
        hint_review = "⏎/ZZ 提交 · h/l 切题 · Esc 取消",
        confirm_unanswered = "%d 题未答，仍要提交？",
        confirm_buttons = "&提交\n&取消",
        answer_title = "回答 · %s",
        cancelled = "⊘ 已取消",
        questions_header = "ask · %d 个问题",
        questions_header_one = "ask · %d 个问题",
    },
    en = {
        float_title = "ask",
        progress = "ask · %d/%d",
        review = "Review",
        free_text = "Type your own answer…",
        wrote = "(wrote) ",
        unanswered = "Unanswered",
        answered_mark = "■",
        unanswered_mark = "□",
        hint_move = "j/k move",
        hint_switch = "h/l question",
        hint_select = "⏎ confirm",
        hint_toggle = "Space toggle",
        hint_clear = "x clear",
        hint_free = "i type",
        hint_submit = "ZZ submit",
        hint_cancel = "Esc cancel",
        hint_review = "⏎/ZZ submit · h/l question · Esc cancel",
        confirm_unanswered = "%d unanswered — submit anyway?",
        confirm_buttons = "&Submit\n&Cancel",
        answer_title = "Answer · %s",
        cancelled = "⊘ Cancelled",
        questions_header = "ask · %d questions",
        questions_header_one = "ask · %d question",
    },
}

--- A localized string, formatted when extra arguments are given.
---@param key string
---@param ... any
---@return string
function M.t(key, ...)
    local lang = M.resolve_lang()
    local text = (STRINGS[lang] or STRINGS.en)[key]
    if text == nil then
        text = STRINGS.en[key] or key
    end
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, text, ...)
        if ok then
            return formatted
        end
    end
    return text
end

--- The block header: the localized count, singular when there is one question.
---@param count integer
---@return string
function M.questions_header(count)
    local lang = M.resolve_lang()
    local table_for_lang = STRINGS[lang] or STRINGS.en
    local key = count == 1 and table_for_lang.questions_header_one and "questions_header_one" or "questions_header"
    return M.t(key, count)
end

return M
