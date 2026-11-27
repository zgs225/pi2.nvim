--- The shared header "shell" of the side panels (:PiTodo, :PiTasks,
--- :PiCompactions).
---
--- Every one of them renders the same container so they read as one column
--- instead of three private layouts:
---
---   line 1: blank spacer (breathing room towards the panel above)
---   line 2: title — 2-space indent, an optional icon, the panel name and its
---           metric (`  󰝖 Todo · 2/5 completed`), all in PiPanelTitle
---   line 3: optional hint line (`? help · q close`), same group
---   line 4: blank spacer (breathing room between the header and the rows)
---   line 5+: the panel's rows, indented by the same 2 spaces, or — when the
---           panel has nothing to list — the panel's EMPTY STATE: either the
---           composed block of `spec.empty` (headline / detail / hint, centred
---           in the panel width) or, for a caller that supplies none, the bare
---           `no <noun>` placeholder in PiPanelTitle
---
--- The empty state is the one part of the shell with a behavioural contract
--- beyond grammar: the panel owns the COPY (the reason it is empty differs per
--- panel), the shell owns the LAYOUT (centring, the blank line before the
--- hint, and the degradation order when the panel is too narrow to hold the
--- whole block). See doc/usage.md#the-pitodo-panel.
---
--- The METRIC is the one thing each panel owns semantically: the todo panel
--- reports its progress fraction, the tasks panel its running/finished split,
--- the compactions panel its record count. The shell only guarantees the
--- grammar around it — `Name · metric` — and that a panel with no rows shows
--- its bare name plus the `no <noun>` placeholder instead of dropping the
--- title (the drift this module exists to prevent: the todo panel used to
--- lose its title entirely when the list emptied, and its header was the only
--- one without a highlight).
---
--- Callers never assemble header noise themselves: build() returns the final
--- lines plus the extmark chunks, and header_lines tells them where their
--- rows start, so the row ↔ buffer-line mapping cannot drift between panels.
--- Pure module: no buffers, no windows, no timers.

local Text = require("pi.ui.chat.text")

local M = {}

--- Width of the shell's indent, applied to the title, the hint, the
--- placeholder and every row.
---@type integer
M.INDENT = 2

--- Highlight group of the whole header block (title, hint, placeholder).
---@type string
M.TITLE_HL = "PiPanelTitle"

--- One content row of a panel.
---@class pi.PanelRow
---@field line string row text WITHOUT the shell indent
---@field chunks? [integer, integer, string][] 0-based byte ranges (start,
---   exclusive end, highlight group) relative to `line`; build() shifts them
---   onto the indented buffer line

--- What a panel's header renders.
--- The composed empty state a panel renders when it has nothing to list.
---
--- The shape Charm's `Empty` overlay popularised — a headline that states what
--- is missing, one quieter line that explains it (or says what it held), and
--- one key worth pressing next — which is also NN/g's empty-state guidance:
--- status, learning cue, direct pathway. The panel supplies the copy, because
--- the REASON a panel is empty differs per panel and the user's next move
--- differs with it; the shell only guarantees the layout (centred, dim, never
--- wrapped) and the degradation below.
---@class pi.PanelEmpty
---@field headline string the line that states what is (not) there. Rendered in
---   the window's own text colour (no highlight chunk), so it reads as content
---   rather than as chrome.
---@field detail? string quieter second line explaining the headline
---@field detail_hl? string highlight of the detail line (default PiPanelTitle;
---   a panel passes a semantic group such as PiTodoDone for a `finished` line)
---@field hint? string the one key worth pressing next; rendered after a blank
---   line, in PiPanelTitle

---@class pi.PanelSpec
---@field name string panel name shown in the title (`Todo`, `Tasks`, …)
---@field noun string what the panel lists, for the legacy empty placeholder
---   (`no <noun>`, used when `empty` is nil); lowercase plural (`todos`,
---   `tasks`, `compactions`)
---@field icon? string nerd font glyph rendered before the name
---@field metric? string the panel-specific count phrase appended after ` · `;
---   nil when there is nothing to count (the title then shows the bare name)
---@field hint? string one-line keybinding hint rendered between the title and
---   the first spacer
---@field width? integer display width of the panel window in cells: the empty
---   block is centred on it and the lines that do not fit are dropped. Nil
---   keeps the legacy placement (2-space indent, nothing dropped), so a caller
---   that cannot know its width still renders correctly.
---@field empty? pi.PanelEmpty composed empty state; nil keeps the bare
---   `no <noun>` placeholder

--- The rendered header plus the panel's rows.
---@class pi.PanelHeader
---@field lines string[] final buffer lines (header + rows, or the placeholder)
---@field chunks table<integer, [integer, integer, string][]> extmark chunks per
---   1-based line index
---@field header_lines integer number of lines above the first row
---@field title string the indented title line, reused by callers that need
---   the width (`Task · …` truncation) or a spec assertion
---@field empty boolean true when the panel rendered its empty state

---@param text string
---@return string
local function indent(text)
    return string.rep(" ", M.INDENT) .. text
end

--- Display width of `text` in cells (a CJK glyph is two, a nerd font icon in
--- a mono font is one).
---@param text string
---@return integer
local function cells(text)
    return vim.fn.strdisplaywidth(text)
end

--- Place one empty-state line: centred in the panel width when the caller
--- knows it, else the shell's 2-space indent (the pre-width behaviour). Trailing
--- padding is never written — the buffer line ends where the text does.
---@param text string
---@param width integer?
---@return string
local function place(text, width)
    if text == "" then
        return ""
    end
    if width == nil or width <= 0 then
        return indent(text)
    end
    local free = width - cells(text)
    if free <= 0 then
        return text
    end
    -- Centre it, but never let a tight panel push the block into column 0 while
    -- the title above it keeps the shell indent: below `2 * INDENT` cells of
    -- slack the indent wins, above it the centring does.
    return string.rep(" ", math.min(free, math.max(M.INDENT, math.floor(free / 2)))) .. text
end

--- Whether an optional empty-state line fits the panel width. An unknown
--- width (`nil` / 0) never drops anything.
---@param text string
---@param width integer?
---@return boolean
local function fits(text, width)
    return width == nil or width <= 0 or cells(text) <= width
end

--- The composed empty block as `{ text, hl }` entries, in render order:
--- headline, the optional detail, then the optional hint after a blank line.
---
--- An optional line that does not fit the panel width is DROPPED rather than
--- wrapped (the panel never wraps): the detail first, because it explains what
--- the headline already states, and the hint last, because it is the only
--- actionable line. The headline always appears; when even it is too wide it
--- is truncated with an ellipsis as the last resort.
---@param empty pi.PanelEmpty
---@param width integer? panel width in cells (nil = place with the shell indent)
---@return { text: string, hl: string? }[]
local function empty_entries(empty, width)
    ---@type { text: string, hl: string? }[]
    local entries = {}
    local headline = tostring(empty.headline or "")
    if width ~= nil and width > 0 and cells(headline) > width then
        headline = Text.thinking_head(headline, width)
    end
    entries[#entries + 1] = { text = headline, hl = nil }
    local detail = empty.detail
    if type(detail) == "string" and detail ~= "" and fits(detail, width) then
        entries[#entries + 1] = { text = detail, hl = empty.detail_hl or M.TITLE_HL }
    end
    local hint = empty.hint
    if type(hint) == "string" and hint ~= "" and fits(hint, width) then
        -- A blank line always separates the hint from whatever survives above
        -- it, so a narrow panel (detail dropped) still reads as two blocks
        -- instead of one run-on paragraph.
        if #entries > 0 then
            entries[#entries + 1] = { text = "" }
        end
        entries[#entries + 1] = { text = hint, hl = M.TITLE_HL }
    end
    return entries
end

--- The title line with the shell indent applied:
--- `  󰝖 Todo · 2/5 completed`. Exposed separately so a caller (and its spec)
--- can reason about the title without building the whole panel.
---@param spec pi.PanelSpec
---@return string
function M.title(spec)
    local text = tostring(spec.name or "?")
    if spec.icon ~= nil and spec.icon ~= "" then
        text = spec.icon .. " " .. text
    end
    if spec.metric ~= nil and spec.metric ~= "" then
        text = text .. " · " .. tostring(spec.metric)
    end
    return indent(text)
end

--- How many lines the shell occupies above the panel's rows: blank spacer,
--- title, optional hint, blank spacer.
---@param spec pi.PanelSpec
---@return integer
function M.header_lines(spec)
    local lines = 3
    if spec.hint ~= nil and spec.hint ~= "" then
        lines = lines + 1
    end
    return lines
end

--- Render the shell and the rows below it.
---@param spec pi.PanelSpec
---@param rows pi.PanelRow[]? the panel's content rows; nil or empty renders
---   the `no <noun>` placeholder under the title
---@return pi.PanelHeader
function M.build(spec, rows)
    rows = type(rows) == "table" and rows or {}
    ---@type string[]
    local lines = {}
    ---@type table<integer, [integer, integer, string][]>
    local chunks = {}

    ---@param line string
    ---@param line_chunks [integer, integer, string][]?
    local function push(line, line_chunks)
        lines[#lines + 1] = line
        local lnum = #lines
        if line_chunks then
            chunks[lnum] = line_chunks
        end
    end

    push("")
    local title = M.title(spec)
    push(title, { { 0, #title, M.TITLE_HL } })
    if spec.hint ~= nil and spec.hint ~= "" then
        local hint = indent(spec.hint)
        push(hint, { { 0, #hint, M.TITLE_HL } })
    end
    push("")

    local header_lines = #lines
    local empty = #rows == 0
    ---@type { text: string, hl: string? }[]
    local block = {}
    local empty_spec = spec.empty
    if empty and type(empty_spec) == "table" then
        block = empty_entries(empty_spec, tonumber(spec.width))
    end
    if empty and #block > 0 then
        local width = tonumber(spec.width)
        for _, entry in ipairs(block) do
            local placed = place(entry.text, width)
            local entry_chunks = nil
            if entry.hl ~= nil and entry.text ~= "" then
                local start = #placed - #entry.text
                entry_chunks = { { start, #placed, entry.hl } }
            end
            push(placed, entry_chunks)
        end
    elseif empty then
        local placeholder = indent("no " .. tostring(spec.noun or "rows"))
        push(placeholder, { { 0, #placeholder, M.TITLE_HL } })
    else
        for _, row in ipairs(rows) do
            local shifted = {}
            for _, chunk in ipairs(row.chunks or {}) do
                shifted[#shifted + 1] = { chunk[1] + M.INDENT, chunk[2] + M.INDENT, chunk[3] }
            end
            push(indent(row.line), shifted)
        end
    end

    return {
        lines = lines,
        chunks = chunks,
        header_lines = header_lines,
        title = title,
        empty = empty,
    }
end

return M
