--- UI-only display lines for a background-task delivery report.
---
--- The bundled bg-tasks extension already delivers every completion and every
--- check-in to the MODEL as a `pi2_bg_task` custom message (`display = false`),
--- and the frontend deliberately never renders a custom message as conversation
--- content. That leaves the USER blind to a report the model just received, so
--- this module derives ONE dim line per reported task from the very text the
--- model already gets. It is a display concern only: nothing here is sent
--- anywhere, so the model's context is untouched and no second delivery
--- channel exists.
---
--- The discriminator is the extension's stable contract, not the customType
--- alone: every report and check-in opens with the `[SYSTEM NOTIFICATION ...]`
--- banner and carries one `<background-task ...>` element per task (see
--- `buildWakeNote` / `buildBatchNote` / `buildCheckInNote` / the startup summary
--- in `extensions/bg-tasks.ts`). The banner check is what keeps the panel pings
--- silent — they share the same `customType` but their content is a short
--- marker (`[Background task b3f2a1 started]`) with no banner. The panel is
--- their visible surface, and a task STARTING is not a report.
---
---@class pi.TasksNote
local M = {}

--- Leading glyph of every note line, so a report reads as a system remark
--- rather than as something the user or the agent said.
local PREFIX = "⚑ "

--- The banner every report/check-in/startup note opens with. Everything else
--- under `customType == "pi2_bg_task"` is a panel ping.
local BANNER = "[SYSTEM NOTIFICATION"

--- No note line is wider than this; a long command or a batch of tasks must
--- not push the chat into horizontal scrolling.
local MAX_COLS = 120

---@param s string
---@return string
local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Approximate display columns of `s` by its UTF-8 codepoint count. The note
--- only ever carries `⚑` / `·` / `…`, task ids and short English words, so no
--- double-width character can show up. Pure string math: no Neovim API here.
---@param s string
---@return integer
local function display_cols(s)
    local _, count = s:gsub("[^\128-\191]", "")
    return count
end

--- Cut `s` to `max` display columns, ending with `…`.
---
--- The walk is per codepoint, so the cut never lands inside a multi-byte
--- character (`⚑` is three bytes; a half-cut one renders as garbage).
---@param s string
---@param max integer
---@return string
local function truncate(s, max)
    if display_cols(s) <= max then
        return s
    end
    local out = {} ---@type string[]
    local cols, i = 0, 1
    while i <= #s and cols < max - 1 do
        local b = s:byte(i) or 0
        local len = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
        out[#out + 1] = s:sub(i, i + len - 1)
        i = i + len
        cols = cols + 1
    end
    return table.concat(out) .. "…"
end

--- Attributes of one `<background-task ...>` element. The extension escapes
--- attribute values (`&quot;` / `&gt;` / `&amp;`), so a value can never smuggle
--- a quote in and the lazy `(.-)` match cannot run past it.
---@param raw string attribute text of one element
---@return table<string, string>
local function parse_attrs(raw)
    local attrs = {} ---@type table<string, string>
    for name, value in raw:gmatch('([%w_%-]+)="(.-)"') do
        attrs[name] = value
    end
    return attrs
end

---@param value string?
---@return integer?
local function num(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    local n = tonumber(value)
    if not n then
        return nil
    end
    return math.floor(n)
end

--- Compact human duration: `1.2s` under ten seconds, `12s` under a minute,
--- `3m12s` beyond, `1h05m` beyond an hour. Deliberately coarser than the
--- extension's own `formatSeconds` — a note is a glance at the chat, not a
--- measurement.
---@param ms integer
---@return string
local function format_duration(ms)
    if ms < 0 then
        ms = 0
    end
    if ms < 10000 then
        return string.format("%.1fs", ms / 1000)
    end
    local seconds = math.floor(ms / 1000)
    if seconds < 60 then
        return string.format("%ds", seconds)
    end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then
        return string.format("%dm%02ds", minutes, seconds % 60)
    end
    return string.format("%dh%02dm", math.floor(minutes / 60), minutes % 60)
end

--- The state words for one element.
---
--- `unknown` says nothing about an exit code or a signal on purpose: an adopted
--- task whose pids vanished was never observed ending, and that absence IS the
--- state — printing `(exit )` or a signal it never had would invent one.
---@param attrs table<string, string>
---@return string
local function state_text(attrs)
    local status = attrs.status or ""
    local exit_code = attrs.exit_code or ""
    local signal = attrs.signal or ""
    if status == "running" then
        if attrs.check_in == "deadline" then
            return "still running (deadline check-in)"
        elseif attrs.check_in == "lifetime" then
            return "still running (lifetime cap passed)"
        end
        return "still running"
    elseif status == "completed" then
        return exit_code ~= "" and ("completed (exit " .. exit_code .. ")") or "completed"
    elseif status == "failed" then
        return exit_code ~= "" and ("failed (exit " .. exit_code .. ")") or "failed"
    elseif status == "stopped" then
        return signal ~= "" and ("stopped (signal " .. signal .. ")") or "stopped"
    elseif status == "unknown" then
        return "exit status unknown"
    end
    return status ~= "" and status or "report"
end

--- One note line for one `<background-task ...>` element:
--- `⚑ b3f2a1 · completed (exit 0) · 1.2s`.
---@param attrs table<string, string>
---@return string
local function element_line(attrs)
    local parts = {} ---@type string[]
    local id = attrs.id
    if id and id ~= "" then
        parts[#parts + 1] = id
    end
    parts[#parts + 1] = state_text(attrs)
    -- A report carries `duration_ms`, a check-in carries `elapsed_ms`; either
    -- way it is the only timing attribute present.
    local ms = num(attrs.duration_ms) or num(attrs.elapsed_ms)
    if ms then
        parts[#parts + 1] = format_duration(ms)
    end
    return truncate(PREFIX .. table.concat(parts, " · "), MAX_COLS)
end

--- Line for the startup orphan summary: the banner, then ONE bracketed line
--- (`[Background bash tasks found in this session's transcript: 3 — 2 still
--- running]`) and no `<background-task>` element. The bracket text is the
--- extension's own summary verbatim (bar its capital letter), so a reader
--- recognizes what it is reading.
---@param content string
---@return string?
local function summary_line(content)
    local first = true
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        if first then
            first = false
        else
            local trimmed = trim(line)
            if trimmed:sub(1, 1) == "[" and trimmed:sub(-1) == "]" and #trimmed > 2 then
                local inner = trimmed:sub(2, -2)
                return truncate(PREFIX .. inner:sub(1, 1):lower() .. inner:sub(2), MAX_COLS)
            end
        end
    end
    return nil
end

--- Display lines for one `pi2_bg_task` custom-message content.
---
--- Returns `{}` for anything that is not a report: a non-string content, an
--- empty one, and — the point of the banner check — a panel ping
--- (`[Background task b3f2a1 started]`), which shares the customType.
---@param content any custom-message content
---@return string[]
function M.lines(content)
    if type(content) ~= "string" or content == "" then
        return {}
    end
    local first_line = content:match("^([^\n]*)") or ""
    if first_line:sub(1, #BANNER) ~= BANNER then
        return {}
    end
    local out = {} ---@type string[]
    -- One line per element, in payload order: a coalesced batch reports several
    -- tasks in ONE message. Everything outside the elements (the prose line,
    -- the output tail) is model-facing detail and stays out of the note.
    for raw in content:gmatch("<background%-task([^>]*)>") do
        out[#out + 1] = element_line(parse_attrs(raw))
    end
    if #out > 0 then
        return out
    end
    return { summary_line(content) or (PREFIX .. "background task report") }
end

return M
