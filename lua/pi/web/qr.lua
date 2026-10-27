-- Floating QR view for the web-console pairing link.
--
-- The matrix is produced by the daemon's `POST /api/v1/pair` mint (`qr.rows`,
-- byte mode ECC M), so
-- this module is presentation only: two module rows per buffer line via
-- `▀`/`▄`/`█`/` `, a forced black-on-white highlight (`PiWebQr`) that does not
-- depend on the colorscheme, and a four-module quiet zone on every side.
--
-- Keys: `q`/`<Esc>` close, `r` mint a fresh code, `y` copy the link. `refresh`
-- is injected by the caller (`pi.web.ctl`) so the view owns no RPC of its own.

local M = {}

local Notify = require("pi.notify")

--- Quiet zone in modules (the spec asks for 4).
M.QUIET = 4
--- Highlight group for the symbol cells (dark modules on a white field).
M.HL = "PiWebQr"
--- Highlight groups for the metadata lines under the symbol.
M.HL_INFO = "PiWebQrInfo"
M.HL_HINT = "PiWebQrHint"
--- Float title.
M.TITLE = " π² web console · scan to pair "
M.FILETYPE = "pi-web-qr"

local DARK = "█"
local UPPER = "▀"
local LOWER = "▄"
local BLANK = " "

--- @type { win: integer, buf: integer, url: string|nil, refresh: fun()|nil }|nil
local state = nil

--- Half-block rendering of the module matrix, one buffer line per two rows.
---
--- `rows` are `1`/`0` strings (dark/light) as carried by the mint response.
--- The quiet zone is part of the result so the symbol scans reliably.
--- @param rows string[]
--- @param quiet? integer modules of margin (default `M.QUIET`)
--- @return string[] lines
function M.lines(rows, quiet)
    quiet = quiet or M.QUIET
    local width = 0
    for _, row in ipairs(rows) do
        width = math.max(width, #row)
    end
    local pad = string.rep(BLANK, quiet)
    local edge = string.rep(BLANK, width + quiet * 2)
    local lines = {}
    for _ = 1, math.ceil(quiet / 2) do
        lines[#lines + 1] = edge
    end
    for index = 1, #rows, 2 do
        local top = rows[index] or ""
        local bottom = rows[index + 1]
        local cells = {}
        for col = 1, width do
            local upper = top:sub(col, col) == "1"
            local lower = bottom ~= nil and bottom:sub(col, col) == "1"
            if upper and lower then
                cells[#cells + 1] = DARK
            elseif upper then
                cells[#cells + 1] = UPPER
            elseif lower then
                cells[#cells + 1] = LOWER
            else
                cells[#cells + 1] = BLANK
            end
        end
        lines[#lines + 1] = pad .. table.concat(cells) .. pad
    end
    -- An odd module count leaves the last line's lower half light, so the bottom
    -- margin is one module taller than the top one; keep it symmetric.
    local bottom_lines = math.ceil(quiet / 2) + (#rows % 2)
    for _ = 1, bottom_lines do
        lines[#lines + 1] = edge
    end
    return lines
end

--- `9:58`-style label for the code's remaining lifetime.
--- @param expires_at? number epoch milliseconds
--- @param now? number epoch seconds (default `os.time()`)
--- @return string|nil
function M.expiry_label(expires_at, now)
    if type(expires_at) ~= "number" then
        return nil
    end
    local remaining = math.floor(expires_at / 1000) - (now or os.time())
    if remaining <= 0 then
        return "expired"
    end
    return ("expires in %d:%02d"):format(math.floor(remaining / 60), remaining % 60)
end

--- Metadata lines rendered under the symbol.
--- @param opts { url: string, code: string, expires_at?: number }
--- @param now? number
--- @return string[]
function M.meta_lines(opts, now)
    local lines = { "", opts.url }
    local expiry = M.expiry_label(opts.expires_at, now)
    local code = ("code %s"):format(opts.code)
    lines[#lines + 1] = expiry and (code .. " · " .. expiry) or code
    lines[#lines + 1] = "q close · r new code · y copy link"
    return lines
end

--- @return boolean
function M.is_open()
    return state ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- @return integer|nil
function M.win()
    local current = state
    if current == nil or not vim.api.nvim_win_is_valid(current.win) then
        return nil
    end
    return current.win
end

--- @return integer|nil
function M.buf()
    local current = state
    if current == nil or not vim.api.nvim_buf_is_valid(current.buf) then
        return nil
    end
    return current.buf
end

--- Close the view (idempotent).
function M.close()
    if state == nil then
        return
    end
    local win, buf = state.win, state.buf
    state = nil
    if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
end

--- @param lines string[]
--- @return integer display width
local function widest(lines)
    local width = 1
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    return width
end

--- Open (or replace) the floating view.
--- @param opts { rows: string[], url: string, code: string, expires_at?: number, refresh?: fun() }
function M.open(opts)
    local rows = type(opts.rows) == "table" and opts.rows or {}
    if #rows == 0 then
        Notify.error("web console: empty QR matrix")
        return
    end
    M.close()

    -- Shrink the quiet zone on narrow terminals instead of overflowing the screen.
    local available = math.max(1, (tonumber(vim.o.columns) or 80) - 4)
    local quiet = M.QUIET
    local body = M.lines(rows, quiet)
    while quiet > 0 and widest(body) > available do
        quiet = quiet - 1
        body = M.lines(rows, quiet)
    end

    local meta = M.meta_lines({ url = opts.url, code = opts.code, expires_at = opts.expires_at })
    local lines = {}
    vim.list_extend(lines, body)
    vim.list_extend(lines, meta)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = M.FILETYPE
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false

    local width = math.min(widest(lines), available)
    local height = math.min(#lines, math.max(1, (tonumber(vim.o.lines) or 24) - 4))
    local winhl = "NormalFloat:PiFloat,FloatBorder:PiFloatBorder,FloatTitle:PiDialogTitle"
    local ok_hl, highlights = pcall(require, "pi.ui.highlights")
    if ok_hl and type(highlights.DIALOG_WINHIGHLIGHT) == "string" then
        winhl = highlights.DIALOG_WINHIGHLIGHT
    end

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.max(0, math.floor(((tonumber(vim.o.lines) or 24) - height) / 2) - 2),
        col = math.max(0, math.floor(((tonumber(vim.o.columns) or 80) - width) / 2)),
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = M.TITLE,
        title_pos = "center",
    })
    vim.wo[win].winhighlight = winhl
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false

    -- The symbol needs a hard black/white contrast, so set both colors explicitly
    -- and let the user override `PiWebQr` (defaults never win).
    vim.api.nvim_set_hl(0, M.HL, { fg = "#000000", bg = "#ffffff", default = true })
    vim.api.nvim_set_hl(0, M.HL_INFO, { link = "Normal", default = true })
    vim.api.nvim_set_hl(0, M.HL_HINT, { link = "Comment", default = true })

    local ns = vim.api.nvim_create_namespace("pi-web-qr")
    for index, line in ipairs(body) do
        vim.api.nvim_buf_set_extmark(buf, ns, index - 1, 0, {
            end_col = #line,
            hl_group = M.HL,
        })
    end
    for index = 1, #meta do
        local line_index = #body + index - 1
        local text = lines[line_index + 1]
        vim.api.nvim_buf_set_extmark(buf, ns, line_index, 0, {
            end_col = #text,
            hl_group = index == 1 and M.HL_HINT or M.HL_INFO,
        })
    end

    state = { win = win, buf = buf, url = opts.url, refresh = opts.refresh }
    local this_win = win
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            if state ~= nil and state.win == this_win then
                state = nil
            end
        end,
    })

    local function close()
        M.close()
    end
    vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "π² Close the QR code" })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, desc = "π² Close the QR code" })
    vim.keymap.set("n", "y", function()
        local url = state and state.url or opts.url
        pcall(vim.fn.setreg, "+", url)
        pcall(vim.fn.setreg, '"', url)
        Notify.info("web console: copied the pairing link")
    end, { buffer = buf, nowait = true, desc = "π² Copy the pairing link" })
    if type(opts.refresh) == "function" then
        vim.keymap.set("n", "r", function()
            local refresh = state and state.refresh or opts.refresh
            M.close()
            if type(refresh) ~= "function" then
                return
            end
            local ok, err = pcall(refresh)
            if not ok then
                Notify.error("web console: could not mint a new code: " .. tostring(err))
            end
        end, { buffer = buf, nowait = true, desc = "π² Mint a new pairing code" })
    end
end

return M
