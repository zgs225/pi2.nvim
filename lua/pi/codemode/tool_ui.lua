--- codemode tool display helpers: result parsing and body-row formatting.
---
--- `codemode` is a pi core tool whose input is raw JavaScript executed in a
--- QuickJS sandbox. Its result body is a concatenation of wire artifacts:
---
---   Script completed          <- header block: dropped, the tool header
---   Wall time 0.3 seconds        already prints its own "Took 1.2s"
---   Output:
---   ==> text 1/2 <==          <- per-output markers: turned into section headers
---   <console_output>          <- console.* capture: tags stripped
---   Script error:             <- failure trailer: marker line dropped
---
--- plus structured `details.calls` (nested tool invocations) and
--- `details.fullOutputPath` (set when pi spilled a truncated output to disk).
---
--- Pure module: no editor/buffer access beyond vim.split / vim.json, so both
--- the chat renderer (lua/pi/ui/chat/tools.lua) and the specs can drive it.
--- Mirrors pi's own TUI renderer (dist/extensions/codemode/renderer.js).

local M = {}

--- Marker appended to every elided preview.
local ELLIPSIS = "…"

--- Args preview budget for one call row.
--- 40, not the TUI's 80: a call row already carries `↳ ✓ <tool name>` and a
--- duration, and long MCP names put an 80-char args preview past a normal
--- 80-column chat width — which then trips should_collapse()'s width rule and
--- folds the block, hiding the call rows it is meant to show.
local COLLAPSED_ARGS_CHARS = 40
--- Hard cap on call rows rendered per block; elided rows are announced, never
--- silently dropped.
local CALL_ROW_LIMIT = 50
--- Budget for the continuation row carrying a failed call's error.
local ERROR_EXCERPT_CHARS = 160

---@class pi.CodemodeCall
---@field name string
---@field args string compact args text, "" when none
---@field status "running"|"ok"|"error"|"cancelled"
---@field duration_ms number?
---@field cost number?
---@field error string?

---@class pi.CodemodeSection
---@field kind "text"|"console"|"error"
---@field label string? "text 1/2" for numbered text sections, "console", "error"
---@field lines string[] display lines (verbatim content)

---@class pi.CodemodeOutput
---@field calls pi.CodemodeCall[]
---@field calls_complete boolean false when a nestedCalls record was capped/incomplete
---@field sections pi.CodemodeSection[]
---@field failed boolean
---@field truncated_path string? details.fullOutputPath, when pi spilled the output
---@field outputs integer #text sections + 1 when a console section exists

---@class pi.CodemodeRow
---@field text string
---@field hl? string highlight group name, nil = default PiToolCall

---@class pi.CodemodeMark
---@field glyph string
---@field hl string

--- Same glyph vocabulary as SubToolUi.DISPATCH_MARKS (lua/pi/subsessions/
--- tool_ui.lua), so nested tool calls read consistently across tools.
---@type table<string, pi.CodemodeMark>
local STATUS_MARKS = {
    running = { glyph = "◐", hl = "PiToolRunning" },
    ok = { glyph = "✓", hl = "PiToolStatus" },
    error = { glyph = "✗", hl = "PiToolError" },
    cancelled = { glyph = "⊘", hl = "PiToolStatus" },
}

--- Unknown statuses degrade to "ok": the script got a result either way.
local DEFAULT_STATUS = "ok"

---@param value any
---@return string
local function to_string(value)
    if type(value) == "string" then
        return value
    end
    if type(value) == "number" or type(value) == "boolean" then
        return tostring(value)
    end
    return ""
end

--- Flatten to a single display line (a JSON payload or a stack trace must not
--- break the one-row-per-call layout).
---@param text string
---@return string
local function flatten(text)
    return vim.trim((text:gsub("[\r\n]+", " "):gsub("%s+", " ")))
end

--- Byte-safe truncation: never split a multi-byte UTF-8 sequence, so a CJK
--- search query in the args does not decode to garbage in the buffer.
---@param text string
---@param max integer byte budget including the appended "…"
---@return string
local function truncate(text, max)
    if #text <= max then
        return text
    end
    local cut = text:sub(1, max - #ELLIPSIS)
    local lead_at = #cut
    while lead_at > 0 do
        local b = cut:byte(lead_at)
        if not b or b < 0x80 or b > 0xBF then
            break
        end
        lead_at = lead_at - 1
    end
    if lead_at > 0 then
        local lead = cut:byte(lead_at)
        local need = 1
        if lead >= 0xF0 then
            need = 4
        elseif lead >= 0xE0 then
            need = 3
        elseif lead >= 0xC0 then
            need = 2
        end
        if lead_at + need - 1 > #cut then
            cut = cut:sub(1, lead_at - 1)
        end
    end
    return cut .. ELLIPSIS
end

--- `421ms` / `1.2s` — same split point as the TUI's formatDuration.
---@param ms number
---@return string
local function format_duration(ms)
    if ms < 1000 then
        return ("%dms"):format(math.floor(ms + 0.5))
    end
    return ("%.1fs"):format(ms / 1000)
end

--- `$0.12` / `$0.0012` — two decimals at >= 1 cent, two significant digits
--- below it (same thresholds as the TUI's formatCost).
---@param cost number
---@return string
local function format_cost(cost)
    if cost >= 0.01 then
        return ("$%.2f"):format(cost)
    end
    return ("$%.2g"):format(cost)
end

--- Collect the body text of a codemode result: every `{type="text"}` block
--- joined with newlines (image blocks are dropped — pi emits a
--- `[Image saved to …]` text line next to each one).
---@param content any
---@return string? text nil when `content` is not text-shaped
---@return integer text_blocks how many text-bearing blocks were seen
local function collect_body_text(content)
    if type(content) == "string" then
        return content, 1
    end
    if type(content) ~= "table" then
        return nil, 0
    end
    local parts = {} ---@type string[]
    local text_blocks = 0
    for _, block in ipairs(content) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            parts[#parts + 1] = block.text
            text_blocks = text_blocks + 1
        elseif type(block) == "string" then
            -- legacy replay records store bare strings in content[]
            parts[#parts + 1] = block
            text_blocks = text_blocks + 1
        end
    end
    return table.concat(parts, "\n"), text_blocks
end

--- Drop the leading SCRIPT_HEADER block (`Script completed|failed`,
--- `Wall time … seconds`, `Output:`), tolerating trailing blank lines.
---@param lines string[]
---@return string[] body
---@return boolean failed
local function strip_header(lines)
    local first = lines[1]
    if not first or not (first:match("^Script%s+completed$") or first:match("^Script%s+failed$")) then
        return lines, false
    end
    local failed = first:match("^Script%s+failed$") ~= nil
    local body = {} ---@type string[]
    local i = 2
    if lines[i] and lines[i]:match("^Wall time [%d.]+ seconds$") then
        i = i + 1
    end
    if lines[i] and lines[i]:match("^Output:$") then
        i = i + 1
    end
    while lines[i] == "" do
        i = i + 1
    end
    for j = i, #lines do
        body[#body + 1] = lines[j]
    end
    return body, failed
end

---@param lines string[]
---@return string[]
local function trim_trailing_blanks(lines)
    local last = #lines
    while last > 0 and vim.trim(lines[last]) == "" do
        last = last - 1
    end
    local out = {} ---@type string[]
    for i = 1, last do
        out[i] = lines[i]
    end
    return out
end

--- Split the body into text / console / error sections, dropping the
--- `==> text N/M <==` and `<console_output>` wire markers.
---@param lines string[]
---@return pi.CodemodeSection[]
local function split_sections(lines)
    local sections = {} ---@type pi.CodemodeSection[]
    local current = nil ---@type pi.CodemodeSection?

    local function flush()
        if not current then
            return
        end
        local kept = trim_trailing_blanks(current.lines)
        if #kept > 0 then
            current.lines = kept
            sections[#sections + 1] = current
        end
        current = nil
    end

    for _, line in ipairs(lines) do
        local n, m = line:match("^==> text (%d+)/(%d+) <==$")
        if n then
            flush()
            current = { kind = "text", lines = {} }
            -- A single output item never carries a marker; be defensive about
            -- a wire record that still sends "1/1".
            if (tonumber(m) or 1) > 1 then
                current.label = ("text %s/%s"):format(n, m)
            end
        elseif line == "<console_output>" then
            flush()
            current = { kind = "console", label = "console", lines = {} }
        elseif line == "</console_output>" then
            flush()
        elseif line:match("^Script error:") then
            flush()
            -- The marker line itself is noise; the message and the
            -- "Tool calls made before the failure …" trailer are kept.
            current = { kind = "error", label = "error", lines = {} }
        else
            if not current then
                current = { kind = "text", lines = {} }
            end
            table.insert(current.lines, line)
        end
    end
    flush()
    return sections
end

--- Encode a call's arguments: `details.calls[]` carries a JSON string,
--- session `nestedCalls.calls[]` carries the raw table.
---@param call table
---@return string
local function call_args(call)
    if type(call.args) == "string" then
        return call.args
    end
    local arguments = call.args
    if arguments == nil then
        arguments = call.arguments
    end
    if type(arguments) == "string" then
        return arguments
    end
    if type(arguments) ~= "table" then
        return ""
    end
    local ok, encoded = pcall(vim.json.encode, arguments)
    if not ok or type(encoded) ~= "string" then
        return ""
    end
    return encoded
end

---@param status any
---@return "running"|"ok"|"error"|"cancelled"
local function call_status(status)
    if status == "running" or status == "ok" or status == "error" or status == "cancelled" then
        return status
    end
    return DEFAULT_STATUS
end

--- Normalize the call records of a result. Real session records carry
--- `nestedCalls` next to `details` on the message itself, while the documented
--- RPC shape nests it under `details` — accept both, and fall back to
--- `details.calls` (which carries a JSON-string `args`).
---@param result table
---@return pi.CodemodeCall[] calls
---@return boolean calls_complete
local function collect_calls(result)
    local calls = {} ---@type pi.CodemodeCall[]
    local details = result.details
    local nested = nil ---@type any
    if type(details) == "table" and type(details.nestedCalls) == "table" then
        nested = details.nestedCalls
    elseif type(result.nestedCalls) == "table" then
        nested = result.nestedCalls
    end
    local records ---@type any
    local complete = true
    if type(nested) == "table" and type(nested.calls) == "table" and #nested.calls > 0 then
        records = nested.calls
        complete = nested.complete ~= false
    elseif type(details) == "table" then
        records = details.calls
    end
    if type(records) ~= "table" then
        return calls, complete
    end
    for _, record in ipairs(records) do
        if type(record) == "table" then
            local duration = record.durationMs
            if type(duration) ~= "number" then
                duration = record.duration_ms
            end
            calls[#calls + 1] = {
                name = to_string(record.name),
                args = call_args(record),
                status = call_status(record.status),
                duration_ms = type(duration) == "number" and duration or nil,
                cost = type(record.cost) == "number" and record.cost or nil,
                error = type(record.error) == "string" and record.error or nil,
            }
        end
    end
    return calls, complete
end

---@param result table?
---@return pi.CodemodeOutput? parsed nil when `result` is not a parseable codemode result
function M.parse(result)
    if type(result) ~= "table" then
        return nil
    end
    local text, text_blocks = collect_body_text(result.content)
    if not text then
        return nil
    end
    local calls, calls_complete = collect_calls(result)
    -- A result with neither text nor nested calls is not codemode-shaped
    -- (e.g. a blocked/foreign call): let the caller fall back.
    if text_blocks == 0 and #calls == 0 then
        return nil
    end

    local lines = vim.split(text, "\n", { plain = true })
    local body, header_failed = strip_header(lines)
    local sections = split_sections(body)

    local outputs, has_console = 0, false
    for _, section in ipairs(sections) do
        if section.kind == "text" then
            outputs = outputs + 1
        elseif section.kind == "console" then
            has_console = true
        end
    end
    if has_console then
        outputs = outputs + 1
    end

    local truncated_path = nil
    if type(result.details) == "table" then
        local path = result.details.fullOutputPath
        if type(path) == "string" and path ~= "" then
            truncated_path = path
        end
    end

    return {
        calls = calls,
        calls_complete = calls_complete,
        sections = sections,
        failed = header_failed or result.isError == true,
        truncated_path = truncated_path,
        outputs = outputs,
    }
end

--- Nested-call rows, one per call:
--- `↳ ✓ mcp__trilium__search_notes {"query":"…"}  421ms`
---@param parsed pi.CodemodeOutput
---@param opts? { limit?: integer }
---@return pi.CodemodeRow[]
function M.format_calls(parsed, opts)
    local rows = {} ---@type pi.CodemodeRow[]
    if type(parsed) ~= "table" or type(parsed.calls) ~= "table" then
        return rows
    end
    local limit = CALL_ROW_LIMIT
    if type(opts) == "table" and type(opts.limit) == "number" and opts.limit > 0 then
        limit = math.floor(opts.limit)
    end

    local calls = parsed.calls
    local shown = math.min(#calls, limit)
    for i = 1, shown do
        local call = calls[i]
        local mark = STATUS_MARKS[call.status] or STATUS_MARKS[DEFAULT_STATUS]
        local text = "↳ " .. mark.glyph .. " " .. call.name
        if call.args ~= "" then
            text = text .. " " .. truncate(call.args, COLLAPSED_ARGS_CHARS)
        end
        if call.duration_ms then
            text = text .. "  " .. format_duration(call.duration_ms)
        end
        if call.cost and call.cost > 0 then
            text = text .. " " .. format_cost(call.cost)
        end
        rows[#rows + 1] = { text = text }
        if call.error and vim.trim(call.error) ~= "" then
            local first_line = call.error:match("^[^\r\n]*") or ""
            rows[#rows + 1] = {
                text = "      " .. truncate(flatten(first_line), ERROR_EXCERPT_CHARS),
                hl = "PiToolError",
            }
        end
    end
    if #calls > shown then
        rows[#rows + 1] = { text = ("… %d more calls"):format(#calls - shown), hl = "PiToolStatus" }
    end
    return rows
end

--- Output-section rows: a `── <label> ──` header per section that carries a
--- label, then the section content; a trailing `Full output: <path>` row when
--- pi truncated the output to a file.
---@param parsed pi.CodemodeOutput
---@return pi.CodemodeRow[]
function M.format_sections(parsed)
    local rows = {} ---@type pi.CodemodeRow[]
    if type(parsed) ~= "table" or type(parsed.sections) ~= "table" then
        return rows
    end
    for _, section in ipairs(parsed.sections) do
        local header ---@type string?
        local header_hl = "PiToolStatus"
        local body_hl = "PiToolOutput"
        if section.kind == "error" then
            header = "── error ──"
            header_hl = "PiToolError"
            body_hl = "PiToolError"
        elseif section.kind == "console" then
            header = "── console ──"
        elseif section.label then
            header = "── " .. section.label .. " ──"
        end
        if header then
            rows[#rows + 1] = { text = header, hl = header_hl }
        end
        for _, line in ipairs(section.lines or {}) do
            rows[#rows + 1] = { text = line, hl = body_hl }
        end
    end
    if parsed.truncated_path then
        rows[#rows + 1] = { text = "Full output: " .. parsed.truncated_path, hl = "PiToolStatus" }
    end
    return rows
end

--- Header badge next to the tool name: `3 calls · 2 outputs`.
---@param result table?
---@return string?
function M.summary(result)
    local parsed = M.parse(result)
    if not parsed then
        return nil
    end
    local call_n = #parsed.calls
    local parts = {} ---@type string[]
    if call_n > 0 then
        parts[#parts + 1] = call_n == 1 and "1 call" or (call_n .. " calls")
    end
    -- The output count is only worth a badge when it disambiguates: a lone
    -- output next to no calls says nothing a reader needs.
    if not (call_n == 0 and parsed.outputs <= 1) then
        parts[#parts + 1] = parsed.outputs == 1 and "1 output" or (parsed.outputs .. " outputs")
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, " · ")
end

return M
