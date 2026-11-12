--- ANSI escape handling for the chat history buffer.
---
--- Tool results (and anything else a producer hands us) can carry terminal
--- control sequences: SGR colour codes from `ls --color`, OSC title updates,
--- cursor movement from progress bars. Neovim stores whatever bytes we write,
--- so raw escapes would show up as caret notation (`^[[1;32m`) and would count
--- as two display columns each — polluting copy/search and inflating every
--- width computation (`should_collapse`, thinking truncation).
---
--- Two jobs, both display-only:
---
---   1. `strip()` — remove ANSI escapes and stray C0 control bytes from a text
---      chunk. Every rendering path funnels through `Tools.sanitize_text`, so
---      this alone keeps the buffer escape-free.
---   2. `scan()` + `apply()` — turn SGR sequences into per-span extmark
---      highlights, so bash output keeps its colours instead of going flat.
---
--- Degradation is automatic and permanent: if a highlight/extmark call fails
--- (older Neovim, a broken buffer, a pathological style count), the module
--- disables itself for the rest of the session and callers keep rendering the
--- stripped text. Colour is a nicety; never a reason to lose output.
---
--- This is display-only: the pi backend keeps the raw escapes in the session
--- transcript, so nothing here changes what the model sees or what a resumed
--- session replays.

local M = {}

--- Set to false by `M._degrade()` after the first failure.
M.enabled = true

--- Reason for the last degradation (nil while healthy); exposed for tests and
--- `:checkhealth` style diagnostics.
---@type string?
M.disabled_reason = nil

local ESC = "\27"

--- C0 control bytes that must not reach the buffer, plus DEL. `\t`, `\n` are
--- meaningful to Neovim; `\r` is mapped to a space (a bare CR inside a buffer
--- line renders as `^M`, and every caller splits lines on `\n` already).
local C0_PATTERN = "[%z\1-\8\11\12\14-\31\127]"

--- Any byte that needs the slow path in `strip()`: escapes, C0 controls
--- (including CR, which is mapped to a space) and DEL.
local DIRTY_PATTERN = "[\27%z\1-\8\11-\12\13-\31\127]"

--- Replace C0 control bytes with "" and `\r` with a space.
---@param s string
---@return string
local function scrub_controls(s)
    return (s:gsub("\r", " "):gsub(C0_PATTERN, ""))
end

--- Length, final byte and parameter string of the escape sequence starting at
--- byte `i` (1-based), or nil when `s` has no sequence at `i`.
---
--- Covers the families a shell tool can realistically emit: CSI (SGR and
--- everything else), OSC (title/hyperlink), DCS/SOS/PM/APC, two-byte escapes
--- and ESC-prefixed charset selection.
---@param s string
---@param i integer
---@return integer? length
---@return string? final_byte
---@return string? params
local function escape_at(s, i)
    local n = #s
    if s:byte(i) ~= 0x1b then
        return nil
    end
    local next_byte = s:byte(i + 1)
    if next_byte == nil then
        -- A lone trailing ESC: drop it rather than let it render.
        return 1, "", nil
    end
    if next_byte == 0x5b then -- '[' CSI
        local j = i + 2
        while j <= n + 1 do
            local c = s:byte(j)
            if c == nil then
                -- Unterminated: swallow the rest of the chunk.
                return n - i + 1, "", nil
            end
            if c >= 0x40 and c <= 0x7e then
                return j - i + 1, string.char(c), s:sub(i + 2, j - 1)
            end
            if not ((c >= 0x30 and c <= 0x3f) or (c >= 0x20 and c <= 0x2f)) then
                -- Malformed: just drop the ESC and keep the rest readable.
                return 1, "", nil
            end
            j = j + 1
        end
        return n - i + 1, "", nil
    end
    if next_byte == 0x5d then -- ']' OSC
        local j = i + 2
        while j <= n do
            local c = s:byte(j)
            if c == 0x07 or c == 0x9c then
                return j - i + 1
            end
            if c == 0x1b and s:byte(j + 1) == 0x5c then
                return j - i + 2
            end
            j = j + 1
        end
        return n - i + 1
    end
    if next_byte == 0x50 or next_byte == 0x58 or next_byte == 0x5e or next_byte == 0x5f then
        -- DCS / SOS / PM / APC: terminated by ST (ESC \ or 0x9c).
        local j = i + 2
        while j <= n do
            local c = s:byte(j)
            if c == 0x9c then
                return j - i + 1
            end
            if c == 0x1b and s:byte(j + 1) == 0x5c then
                return j - i + 2
            end
            j = j + 1
        end
        return n - i + 1
    end
    if next_byte >= 0x20 and next_byte <= 0x2f then
        -- Intermediate byte: 3-byte form (`ESC ( B` charset selection).
        if s:byte(i + 2) == nil then
            return 2
        end
        return 3
    end
    if next_byte >= 0x30 and next_byte <= 0x7e then
        return 2
    end
    -- Unknown after ESC: drop the ESC only.
    return 1
end

--- Remove every ANSI escape sequence and stray control byte from `text`.
---
--- NUL is rendered as `␀` (it used to be the only scrubbed byte) so binary
--- garbage in tool output stays visible instead of silently vanishing.
---@param text string? anything else is coerced through `tostring`
---@return string
function M.strip(text)
    if type(text) ~= "string" then
        text = text == nil and "" or tostring(text)
    end
    text = text:gsub("%z", "␀")
    if not text:find(DIRTY_PATTERN) then
        return text
    end
    if not text:find(ESC, 1, true) then
        return scrub_controls(text)
    end
    local out = {}
    local pos = 1
    local n = #text
    while pos <= n do
        local start = text:find(ESC, pos, true)
        if not start then
            out[#out + 1] = scrub_controls(text:sub(pos))
            break
        end
        if start > pos then
            out[#out + 1] = scrub_controls(text:sub(pos, start - 1))
        end
        local len = escape_at(text, start) or 1
        pos = start + len
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- SGR state
-- ---------------------------------------------------------------------------

--- An SGR colour: an ANSI palette index (0-255) or a 24-bit value.
---@class pi.AnsiColor
---@field idx? integer
---@field rgb? integer[] {r,g,b}

---@class pi.AnsiStyle
---@field fg? pi.AnsiColor
---@field bg? pi.AnsiColor
---@field bold? boolean
---@field dim? boolean
---@field italic? boolean
---@field underline? boolean
---@field strikethrough? boolean
---@field reverse? boolean

--- Style object used while accumulating spans; cheap to reset on SGR 0.
---@return pi.AnsiStyle
local function new_style()
    return {}
end

---@param style pi.AnsiStyle
---@return boolean active
local function style_active(style)
    return next(style) ~= nil
end

---@param style pi.AnsiStyle
---@return string canonical key
local function style_key(style)
    local fg, bg = style.fg, style.bg
    local function color_key(c)
        if not c then
            return "-"
        end
        if c.idx then
            return "i" .. c.idx
        end
        return "r" .. table.concat(c.rgb, ",")
    end
    return table.concat({
        color_key(fg),
        color_key(bg),
        style.bold and "b" or "-",
        style.dim and "d" or "-",
        style.italic and "o" or "-",
        style.underline and "u" or "-",
        style.strikethrough and "s" or "-",
        style.reverse and "v" or "-",
    }, "|")
end

--- Parse an SGR parameter string into a style mutation.
--- `params` is the raw text between `ESC [` and the final `m`.
---@param style pi.AnsiStyle
---@param params string
local function apply_sgr(style, params)
    local codes = {}
    for piece in (params .. ";"):gmatch("([^;]*);") do
        codes[#codes + 1] = tonumber(piece) or 0
    end
    if #codes == 0 then
        codes[1] = 0
    end
    local i = 1
    while i <= #codes do
        local p = codes[i]
        if p == 0 then
            for k in pairs(style) do
                style[k] = nil
            end
        elseif p == 1 then
            style.bold = true
        elseif p == 2 then
            style.dim = true
        elseif p == 3 then
            style.italic = true
        elseif p == 4 then
            style.underline = true
        elseif p == 7 then
            style.reverse = true
        elseif p == 9 then
            style.strikethrough = true
        elseif p == 22 then
            style.bold, style.dim = nil, nil
        elseif p == 23 then
            style.italic = nil
        elseif p == 24 then
            style.underline = nil
        elseif p == 27 then
            style.reverse = nil
        elseif p == 29 then
            style.strikethrough = nil
        elseif p >= 30 and p <= 37 then
            style.fg = { idx = p - 30 }
        elseif p == 39 then
            style.fg = nil
        elseif p >= 40 and p <= 47 then
            style.bg = { idx = p - 40 }
        elseif p == 49 then
            style.bg = nil
        elseif p >= 90 and p <= 97 then
            style.fg = { idx = p - 90 + 8 }
        elseif p >= 100 and p <= 107 then
            style.bg = { idx = p - 100 + 8 }
        elseif p == 38 or p == 48 or p == 58 then
            local key = p == 38 and "fg" or (p == 48 and "bg" or nil)
            local mode = codes[i + 1]
            if mode == 5 then
                if key then
                    style[key] = { idx = codes[i + 2] or 7 }
                end
                i = i + 2
            elseif mode == 2 then
                if key then
                    style[key] = { rgb = { codes[i + 2] or 0, codes[i + 3] or 0, codes[i + 4] or 0 } }
                end
                i = i + 4
            else
                i = i + 1
            end
        end
        i = i + 1
    end
end

-- ---------------------------------------------------------------------------
-- Scan
-- ---------------------------------------------------------------------------

--- One rendered buffer row.
---@class pi.AnsiItem
---@field text string escape-free text
---@field spans pi.AnsiSpan[]
---@field styled boolean true when at least one span was produced

---@class pi.AnsiSpan
---@field from integer 0-indexed byte col (inclusive)
---@field to integer 0-indexed byte col (exclusive)
---@field style pi.AnsiStyle

--- Lex `lines` into escape-free text plus per-line colour spans.
---
--- SGR state carries across lines: a colour opened on one row and closed on a
--- later one colours the rows in between, exactly like a terminal. Line count
--- is preserved one-for-one, so callers can write `items[i].text` in place of
--- the original lines and apply spans at the same row offsets.
---@param lines string[]
---@return pi.AnsiItem[]
function M.scan(lines)
    local items = {}
    local style = new_style()
    for li, line in ipairs(lines) do
        local text = type(line) == "string" and line or ""
        -- Keep NUL visible as `␀` (the pre-existing sanitize_text behaviour)
        -- instead of letting the control scrubber silently delete it.
        text = text:gsub("%z", "␀")
        local out = {}
        local spans = {}
        local col = 0 -- byte offset in the escape-free output of this line
        local span_start = 0
        local pos = 1
        local n = #text

        local function close_span()
            if col > span_start and style_active(style) then
                spans[#spans + 1] = { from = span_start, to = col, style = vim.deepcopy(style) }
            end
            span_start = col
        end

        while pos <= n do
            local start = text:find(ESC, pos, true)
            if not start then
                local rest = scrub_controls(text:sub(pos))
                out[#out + 1] = rest
                col = col + #rest
                break
            end
            if start > pos then
                local chunk = scrub_controls(text:sub(pos, start - 1))
                out[#out + 1] = chunk
                col = col + #chunk
            end
            local len, final, params = escape_at(text, start)
            len = len or 1
            if final == "m" then
                close_span()
                apply_sgr(style, params or "")
            end
            pos = start + len
        end
        close_span()

        items[li] = {
            text = table.concat(out),
            spans = spans,
            styled = #spans > 0,
        }
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Highlight groups
-- ---------------------------------------------------------------------------

--- xterm's base 16 colours: the fallback when the colorscheme has no semantic
--- group to borrow from.
local XTERM_16 = {
    [0] = "#1c1c1c",
    [1] = "#c93b3b",
    [2] = "#3fae5a",
    [3] = "#c9a227",
    [4] = "#4a7fd4",
    [5] = "#b06bc8",
    [6] = "#3fa9b0",
    [7] = "#c9c9c9",
    [8] = "#6b6b6b",
    [9] = "#f05a5a",
    [10] = "#61d47f",
    [11] = "#f0c95a",
    [12] = "#6b9cf0",
    [13] = "#d68ae6",
    [14] = "#61cfd6",
    [15] = "#ffffff",
}

--- Semantic groups borrowed from the active colorscheme, per ANSI palette
--- entry. The first group with a foreground colour wins; a theme that defines
--- none of them falls back to the xterm palette (still readable, just not
--- theme-matched).
local THEME_FOR = {
    [0] = { "Normal" },
    [1] = { "DiagnosticError", "ErrorMsg" },
    [2] = { "DiagnosticOk", "String" },
    [3] = { "DiagnosticWarn", "WarningMsg" },
    [4] = { "DiagnosticInfo", "Function" },
    [5] = { "Constant", "Special" },
    [6] = { "DiagnosticHint", "Special" },
    [7] = { "Normal", "NormalFloat" },
    [8] = { "Comment" },
    [9] = { "DiagnosticError", "ErrorMsg" },
    [10] = { "DiagnosticOk", "String" },
    [11] = { "DiagnosticWarn", "WarningMsg" },
    [12] = { "DiagnosticInfo", "Function" },
    [13] = { "Constant", "Special" },
    [14] = { "DiagnosticHint", "Special" },
    [15] = { "Normal", "NormalFloat" },
}

---@param n integer
---@return string hex
---@return integer cterm
local function xterm_color(n)
    if XTERM_16[n] then
        return XTERM_16[n], n
    end
    if n >= 232 then
        local v = 8 + (n - 232) * 10
        return string.format("#%02x%02x%02x", v, v, v), n
    end
    local m = n - 16
    local r, g, b = math.floor(m / 36), math.floor(m % 36 / 6), m % 6
    local function v(x)
        return x == 0 and 0 or 55 + x * 40
    end
    return string.format("#%02x%02x%02x", v(r), v(g), v(b)), n
end

--- Resolve one SGR colour to a hex string plus a cterm index.
---@param color pi.AnsiColor
---@return string? hex
---@return integer? cterm
local function resolve_color(color)
    if color.rgb then
        local r, g, b = color.rgb[1] or 0, color.rgb[2] or 0, color.rgb[3] or 0
        return string.format("#%02x%02x%02x", r, g, b), nil
    end
    local idx = color.idx or 0
    for _, group in ipairs(THEME_FOR[idx] or {}) do
        local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
        if hl and hl.fg then
            return string.format("#%06x", hl.fg), idx
        end
    end
    return xterm_color(idx)
end

---@param hex string
---@return string
local function blend_dim(hex)
    local r = math.floor(tonumber(hex:sub(2, 3), 16) * 0.65)
    local g = math.floor(tonumber(hex:sub(4, 5), 16) * 0.65)
    local b = math.floor(tonumber(hex:sub(6, 7), 16) * 0.65)
    return string.format("#%02x%02x%02x", r, g, b)
end

--- Cached highlight-group attrs, keyed by group name, so a colorscheme change
--- can re-apply them (the 16-colour palette is theme-derived).
---@type table<string, { style: pi.AnsiStyle, seq: integer }>
local cached = {}

--- Monotonic counter: group names are stable per style key, so extmarks keep
--- resolving after a cache refresh.
local name_seq = 0

---@type table<string, string>
local name_by_key = {}

---@param style pi.AnsiStyle
---@return table attrs nvim_set_hl attributes
local function attrs_for(style)
    local fg, bg = style.fg, style.bg
    if style.reverse then
        fg, bg = bg, fg
    end
    local attrs = {}
    if fg then
        local hex, cterm = resolve_color(fg)
        if style.dim and hex then
            hex = blend_dim(hex)
            cterm = nil
        end
        attrs.fg = hex
        attrs.ctermfg = cterm
    elseif style.dim then
        attrs.ctermfg = 8
    end
    if bg then
        local hex, cterm = resolve_color(bg)
        attrs.bg = hex
        attrs.ctermbg = cterm
    end
    if style.bold then
        attrs.bold = true
    end
    if style.italic then
        attrs.italic = true
    end
    if style.underline then
        attrs.underline = true
    end
    if style.strikethrough then
        attrs.strikethrough = true
    end
    return attrs
end

--- Turn the module off for the rest of the session (stripped text only).
---@param reason string
function M._degrade(reason)
    if not M.enabled then
        return
    end
    M.enabled = false
    M.disabled_reason = reason
end

--- Re-apply every cached group against the current colorscheme.
function M.refresh_highlights()
    if not M.enabled then
        return
    end
    for name, entry in pairs(cached) do
        local ok = pcall(vim.api.nvim_set_hl, 0, name, attrs_for(entry.style))
        if not ok then
            M._degrade("nvim_set_hl failed while refreshing " .. name)
            return
        end
    end
end

--- Highlight group for one SGR style, creating it on demand.
---@param style pi.AnsiStyle
---@return string? hl_group nil when colorization is disabled
function M.hl_for(style)
    if not M.enabled then
        return nil
    end
    local key = style_key(style)
    local name = name_by_key[key]
    if name and cached[name] then
        return name
    end
    name = "PiAnsi" .. key:gsub("[^%w]", "_")
    local ok = pcall(vim.api.nvim_set_hl, 0, name, attrs_for(style))
    if not ok then
        M._degrade("nvim_set_hl failed for " .. name)
        return nil
    end
    name_seq = name_seq + 1
    name_by_key[key] = name
    cached[name] = { style = vim.deepcopy(style), seq = name_seq }
    return name
end

--- Extmark priority: above treesitter (100) and render-markdown, above the
--- block-wide `PiToolOutput`/`PiBashOutput` base highlight (200).
M.PRIORITY = 300

-- ---------------------------------------------------------------------------
-- Buffer rendering
-- ---------------------------------------------------------------------------

--- Apply `items` starting at `start_row`.
---
--- The buffer rows must already contain the escape-free texts (`items[i].text`):
--- an extmark's `end_col` has to land inside existing text. Callers therefore
--- lex first, write, then apply.
---
--- `opts.row_offset` shifts the first item down (e.g. past an inserted code
--- fence) and `opts.col_offset` shifts span columns (body indent). Every span
--- is applied independently and failures degrade the whole module, so a
--- partially written block is never left with stale highlights.
---@param buf integer
---@param ns integer
---@param start_row integer 0-indexed
---@param items pi.AnsiItem[]
---@param opts? { row_offset?: integer, col_offset?: integer }
function M.apply(buf, ns, start_row, items, opts)
    if not M.enabled then
        return
    end
    local row_offset = (opts and opts.row_offset) or 0
    local col_offset = (opts and opts.col_offset) or 0
    for i, item in ipairs(items) do
        if item.styled then
            local row = start_row + row_offset + i - 1
            for _, span in ipairs(item.spans) do
                local hl = M.hl_for(span.style)
                if not hl then
                    -- Colorization degraded mid-block: stop rather than leave
                    -- a half-highlighted line behind.
                    return
                end
                local ok = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, span.from + col_offset, {
                    end_col = span.to + col_offset,
                    hl_group = hl,
                    priority = M.PRIORITY,
                })
                if not ok then
                    M._degrade("nvim_buf_set_extmark failed")
                    return
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Wire a `ColorScheme` refresh (idempotent; called on first use).
local hooked = false
local function hook_colorscheme()
    if hooked then
        return
    end
    hooked = true
    local ok = pcall(vim.api.nvim_create_autocmd, "ColorScheme", {
        group = vim.api.nvim_create_augroup("PiAnsiColors", { clear = true }),
        callback = function()
            M.refresh_highlights()
        end,
        desc = "pi.nvim: re-resolve ANSI span colours for the new colorscheme",
    })
    if not ok then
        M._degrade("could not attach the ColorScheme refresh")
    end
end

--- Test hook: forget cached groups and re-enable the module.
function M._reset()
    cached = {}
    name_by_key = {}
    name_seq = 0
    M.enabled = true
    M.disabled_reason = nil
end

hook_colorscheme()

return M
