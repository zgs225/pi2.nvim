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
---           panel has nothing to list — a `no <noun>` placeholder in
---           PiPanelTitle
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
---@class pi.PanelSpec
---@field name string panel name shown in the title (`Todo`, `Tasks`, …)
---@field noun string what the panel lists, for the empty placeholder
---   (`no <noun>`); lowercase plural (`todos`, `tasks`, `compactions`)
---@field icon? string nerd font glyph rendered before the name
---@field metric? string the panel-specific count phrase appended after ` · `;
---   nil when there is nothing to count (the title then shows the bare name)
---@field hint? string one-line keybinding hint rendered between the title and
---   the first spacer

--- The rendered header plus the panel's rows.
---@class pi.PanelHeader
---@field lines string[] final buffer lines (header + rows, or the placeholder)
---@field chunks table<integer, [integer, integer, string][]> extmark chunks per
---   1-based line index
---@field header_lines integer number of lines above the first row
---@field title string the indented title line, reused by callers that need
---   the width (`Task · …` truncation) or a spec assertion
---@field empty boolean true when the panel rendered the placeholder

---@param text string
---@return string
local function indent(text)
    return string.rep(" ", M.INDENT) .. text
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
    if empty then
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
