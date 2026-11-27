--- Pure string helpers for single-line thinking preview truncation.
--- Extracted from history.lua for unit-testability.

local M = {}

--- Collapse thinking lines into a single whitespace-normalized string.
---@param lines string[]
---@return string
function M.thinking_flat(lines)
    local s = table.concat(lines, " ")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

--- Length in bytes of the utf-8 char starting at byte index i.
---@param b integer
---@return integer
function M.utf8_len(b)
    if b < 0x80 then
        return 1
    elseif b < 0xe0 then
        return 2
    elseif b < 0xf0 then
        return 3
    else
        return 4
    end
end

--- Keep the leading slice of s that fits in w display columns; append "…" if cut.
---@param s string
---@param w integer
---@return string
function M.thinking_head(s, w)
    local dw = vim.fn.strdisplaywidth
    if dw(s) <= w then
        return s
    end
    if w <= 1 then
        return "…"
    end
    local target = w - 1
    local acc, end_byte, i, n = 0, 0, 1, #s
    while i <= n do
        local len = M.utf8_len(s:byte(i))
        local cw = dw(s:sub(i, i + len - 1))
        if acc + cw > target then
            break
        end
        acc = acc + cw
        end_byte = i + len - 1
        i = i + len
    end
    return s:sub(1, end_byte) .. "…"
end

--- Hard-wrap one line into chunks of at most `w` display columns.
---
--- Error blocks put a rail/indent on every buffer line via extmarks; a soft
--- (window) wrap would leave continuation screen lines at column 0 with no
--- rail, breaking the block apart. Wrapping here makes every screen line a
--- real buffer line. Width uses strdisplaywidth (tab-aware, column-relative);
--- a single char wider than `w` is placed on a line of its own.
---@param s string
---@param w integer
---@return string[]
function M.wrap(s, w)
    local dw = vim.fn.strdisplaywidth
    if w <= 0 or dw(s) <= w then
        return { s }
    end
    local chunks, cur, cur_w = {}, "", 0
    local i, n = 1, #s
    while i <= n do
        local len = M.utf8_len(s:byte(i))
        local ch = s:sub(i, i + len - 1)
        local cw = dw(ch, cur_w)
        if cur_w + cw > w and cur ~= "" then
            chunks[#chunks + 1] = cur
            cur, cur_w = "", 0
            cw = dw(ch, 0)
        end
        cur = cur .. ch
        cur_w = cur_w + cw
        i = i + len
    end
    if cur ~= "" then
        chunks[#chunks + 1] = cur
    end
    return chunks
end

--- Word-boundary hard-wrap: like `wrap`, but a break is taken at the last
--- space/tab that fits instead of mid-word. A word wider than `w` has no break
--- to take and is broken by display width (a long URL, a CJK run).
---
--- The whitespace a break consumes is dropped from the rendered chunks, so no
--- chunk begins with padding of its own: a right-aligned block lines its rows
--- up on one left column, and a leading space would read as a stray indent.
--- Display-only, like every rendered row — `gy` / `:PiCopy` return the authored
--- source text, never these chunks.
---@param s string
---@param w integer
---@return string[]
function M.wrap_words(s, w)
    local dw = vim.fn.strdisplaywidth
    if w <= 0 or dw(s) <= w then
        return { s }
    end
    local chunks = {}
    local rest = s
    while rest ~= "" do
        if dw(rest) <= w then
            chunks[#chunks + 1] = rest
            break
        end
        -- Widest prefix that fits, measured column-relative so a tab expands
        -- the way the renderer will see it (same walk as M.wrap).
        local fit_end, fit_w, i = 0, 0, 1
        while i <= #rest do
            local len = M.utf8_len(rest:byte(i))
            local cw = dw(rest:sub(i, i + len - 1), fit_w)
            if fit_w + cw > w then
                break
            end
            fit_w = fit_w + cw
            fit_end = i + len - 1
            i = i + len
        end
        if fit_end == 0 then
            -- One character wider than `w`: it gets a line of its own.
            fit_end = M.utf8_len(rest:byte(1))
        end
        -- Greedy word wrap: keep everything that fits, and only look for a
        -- break when the next character is inside a word. A whitespace right
        -- after the fitting prefix IS the break (cut there), otherwise fall
        -- back to the last space/tab at or before it (cut before the word that
        -- does not fit); with neither, a word wider than `w` is hard-broken.
        -- A UTF-8 continuation byte is never 32/9, so the byte walk is safe.
        local head, tail
        local next_byte = rest:byte(fit_end + 1)
        if next_byte == 32 or next_byte == 9 then
            head = rest:sub(1, fit_end)
            tail = rest:sub(fit_end + 1):gsub("^[ \t]+", "")
        else
            local cut
            for j = fit_end, 1, -1 do
                local b = rest:byte(j)
                if b == 32 or b == 9 then
                    cut = j
                    break
                end
            end
            if cut and cut > 1 then
                head = rest:sub(1, cut - 1)
                tail = rest:sub(cut + 1):gsub("^[ \t]+", "")
            else
                head = rest:sub(1, fit_end)
                tail = rest:sub(fit_end + 1)
            end
        end
        if head == "" then
            -- Only whitespace fitted (a run of spaces longer than `w`).
            head = rest:sub(1, fit_end)
            tail = rest:sub(fit_end + 1)
        end
        chunks[#chunks + 1] = head
        rest = tail
    end
    return chunks
end

--- Keep the trailing slice of s that fits in w display columns (rolling window).
---@param s string
---@param w integer
---@return string
function M.thinking_tail(s, w)
    local dw = vim.fn.strdisplaywidth
    if w <= 0 then
        return ""
    end
    if dw(s) <= w then
        return s
    end
    local acc, start_byte, i = 0, #s + 1, #s
    while i >= 1 do
        -- walk back to the start byte of the char ending at i
        -- (range check = UTF-8 continuation byte; avoids Lua 5.3 bitwise `&`,
        -- which the LuaJIT bundled with Neovim stable releases cannot parse)
        local cs = i
        while cs > 1 and s:byte(cs) >= 0x80 and s:byte(cs) <= 0xbf do
            cs = cs - 1
        end
        local cw = dw(s:sub(cs, i))
        if acc + cw > w then
            break
        end
        acc = acc + cw
        start_byte = cs
        i = cs - 1
    end
    return s:sub(start_byte)
end

return M
