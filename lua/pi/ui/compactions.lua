--- Compaction timeline panel (:PiCompactions) — every compaction of a session,
--- newest first, with the numbers pi reported.
---
--- One shared scratch buffer: blank spacer, a dimmed `  󰏗 Compactions (N)` title,
--- a `  ? help · q close` hint, a spacer, then one row per record —
--- `#seq  hh:mm  reason  before → after  duration  cost  read/modified files
--- "summary excerpt"  󰏗pi2`. An aborted/failed record ends with `aborted` /
--- `failed` and renders in `PiStatusLineWarning`; a session without compactions
--- keeps the header and shows a dim `  No compactions in this session` row.
---
--- Records come from the live `pi.CompactionState` (rich: estimate, duration,
--- focus text) and, once per session and never per render, from a `get_entries`
--- backfill of persisted `compaction` entries (`records_from_entries`), merged
--- and deduped by `summary .. "\0" .. tokens_before`.
---
--- The panel is the tasks panel's structure (lua/pi/ui/tasks.lua) minus the
--- animation: shared buffer, per-tab window table, `Workspace.claim_panel` for
--- the side layout, per-window `?` overlay, coalesced `request_refresh()`,
--- `M._reset()`. Rows are the current tab's *session's* compactions.

local M = {}

local Config = require("pi.config")
local Ft = require("pi.filetypes")
local Highlights = require("pi.ui.highlights")
local Workspace = require("pi.ui.workspace")

local ns = vim.api.nvim_create_namespace("pi-compactions-list")

---@class pi.CompactionRowCells Formatted pieces of one timeline row
---@field fixed { col: integer, text: string }[] present fixed columns (1..7), in order
---@field summary string? quoted, flattened summary excerpt
---@field engine boolean render the `󰏗pi2` marker
---@field status string? "aborted" / "failed" suffix
---@field warn boolean render the row in PiStatusLineWarning

---@type integer? shared list buffer
local buf = nil
---@type table<pi.TabId, integer> list window per tab
local wins = {}
--- Buffer lines above the rows: spacer, title, hint, spacer. Row i is line i+N.
local HEADER_LINES = 4
--- Display columns a summary excerpt may occupy (the `…` included).
local SUMMARY_COLS = 48
---@type pi.CompactionRecord[] rows of the last render, newest first
local records = {}
---@type boolean
local refresh_scheduled = false
--- Session keys (session file or id) whose `get_entries` backfill was requested.
---@type table<string, true>
local backfill_requested = {}
--- Records recovered from persisted `compaction` entries, per session key.
---@type table<string, pi.CompactionRecord[]>
local backfill_records = {}

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

-- Panel config ----------------------------------------------------------------

--- Panel config, degrading to the contract defaults when config has not landed.
---@return { mode: "float"|"side", position: string, width: integer, height: integer }
local function panel_cfg()
    ---@type table
    local defaults = { mode = "float", position = "right", width = 100, height = 22 }
    local compaction = Config.options.compaction
    local panel = type(compaction) == "table" and compaction.panel or nil
    if type(panel) ~= "table" then
        return defaults
    end
    return vim.tbl_deep_extend("keep", panel, defaults)
end

--- Window-local highlight chain: the tasks chain, falling back to the sessions
--- list chain (same shape) — exactly the tasks panel's fallback.
---@return string
local function list_winhighlight()
    return Highlights.TASKS_LIST_WINHIGHLIGHT or Highlights.SESSIONS_LIST_WINHIGHLIGHT
end

-- Session access ---------------------------------------------------------------

--- The current tab's session (nil without one, or when the manager is absent).
---@return pi.Session?
local function current_session()
    local ok, Sessions = pcall(require, "pi.sessions.manager")
    if not ok then
        return nil
    end
    local got, session = pcall(Sessions.get)
    return got and session or nil
end

--- Cache key of a session's backfill: its session file, else its id.
---@param session pi.Session
---@return string?
local function session_key(session)
    for _, candidate in ipairs({ session.session_file, session.id }) do
        if type(candidate) == "string" and candidate ~= "" then
            return candidate
        end
    end
    return nil
end

--- Live records of the session's compaction state (empty without one).
---@param session pi.Session?
---@return pi.CompactionRecord[]
local function live_records(session)
    if not session then
        return {}
    end
    local ok, Sessions = pcall(require, "pi.sessions.manager")
    if ok and type(Sessions.get_compaction_state) == "function" then
        local got, state = pcall(Sessions.get_compaction_state, session)
        if got and type(state) == "table" and type(state.records) == "table" then
            return state.records
        end
    end
    -- Fallback: read the session field directly (states assembled by specs).
    local state = session.compaction
    if type(state) == "table" and type(state.records) == "table" then
        return state.records
    end
    return {}
end

-- Persisted entries ------------------------------------------------------------

--- A JSON null decodes to the truthy `vim.NIL`; drop it so `x or fallback` works.
---@param value any
---@return any
local function non_null(value)
    if value == vim.NIL then
        return nil
    end
    return value
end

--- Non-empty string or nil (JSON null, "", numbers all become nil).
---@param value any
---@return string?
local function optional_string(value)
    value = non_null(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

--- Length of a details file list, or nil when the entry carried none.
---@param list any
---@return integer?
local function list_len(list)
    list = non_null(list)
    return type(list) == "table" and #list or nil
end

--- Parse an entry timestamp (`2025-01-02T03:04:05Z`); time now when unparsable.
---@param timestamp any
---@return integer
local function parse_timestamp(timestamp)
    if type(timestamp) == "string" and timestamp ~= "" then
        local ok, parsed = pcall(vim.fn.strptime, "%Y-%m-%dT%H:%M:%SZ", timestamp)
        if ok and type(parsed) == "number" and parsed > 0 then
            return parsed
        end
    end
    return os.time()
end

--- Map persisted `{ type = "compaction" }` entries to records (pure).
---
--- A persisted entry has no duration, no token estimate and no focus text, so
--- those stay nil / `estimated = false`; `seq` counts the mapped entries.
---@param entries table[]? SessionEntry list from a `get_entries` response
---@return pi.CompactionRecord[]
function M.records_from_entries(entries)
    ---@type pi.CompactionRecord[]
    local out = {}
    if type(entries) ~= "table" then
        return out
    end
    for _, entry in ipairs(entries) do
        if type(entry) == "table" and non_null(entry.type) == "compaction" then
            local details = non_null(entry.details)
            if type(details) ~= "table" then
                details = nil
            end
            local usage = non_null(entry.usage)
            if type(usage) ~= "table" then
                usage = nil
            end
            local summary = optional_string(entry.summary) or ""
            local before = non_null(entry.tokensBefore)
            if type(before) ~= "number" then
                before = 0
            end
            local ts = parse_timestamp(non_null(entry.timestamp))
            out[#out + 1] = {
                seq = #out + 1,
                ts = ts,
                started_at = ts,
                reason = (details and optional_string(details.reason)) or "unknown",
                tokens_before = before,
                tokens_after = nil,
                estimated = false,
                usage = usage,
                read_files = details and list_len(details.readFiles) or nil,
                modified_files = details and list_len(details.modifiedFiles) or nil,
                first_kept_entry_id = optional_string(entry.firstKeptEntryId),
                summary = summary,
                summary_chars = #summary,
                aborted = false,
                will_retry = false,
                engine = details and optional_string(details.engine) or nil,
                custom_instructions = nil,
                turn = 0,
            }
        end
    end
    return out
end

--- Fire the one-off `get_entries` backfill of a session (first open only).
---@param session pi.Session?
local function request_backfill(session)
    local key = session and session_key(session) or nil
    if not key or backfill_requested[key] then
        return
    end
    local rpc = session and session.rpc or nil
    if type(rpc) ~= "table" or type(rpc.send) ~= "function" then
        return
    end
    backfill_requested[key] = true
    local ok = pcall(rpc.send, rpc, { type = "get_entries" }, function(res)
        local data = type(res) == "table" and res.success and res.data or nil
        local entries = type(data) == "table" and non_null(data.entries) or nil
        if type(entries) ~= "table" then
            return
        end
        backfill_records[key] = M.records_from_entries(entries)
        vim.schedule(function()
            M.request_refresh()
        end)
    end)
    if not ok then
        backfill_requested[key] = nil -- a failed request retries on a later open
    end
end

-- Row collection ---------------------------------------------------------------

---@param rec pi.CompactionRecord
---@return string
local function dedupe_key(rec)
    return tostring(rec.summary) .. "\0" .. tostring(rec.tokens_before)
end

--- Merge live and backfilled records, newest first.
---
--- A compaction present in both (the live one is the persisted one) is reported
--- once, the live record winning: it has the estimate and the duration.
---@param session pi.Session?
---@return pi.CompactionRecord[]
local function collect(session)
    ---@type pi.CompactionRecord[]
    local merged = {}
    ---@type table<string, true>
    local seen = {}
    local live = live_records(session)
    for _, rec in ipairs(live) do
        -- Two identical live records are two real compactions (a retry keeps
        -- summary and tokensBefore), so the live set is never deduped itself.
        merged[#merged + 1] = rec
        seen[dedupe_key(rec)] = true
    end
    local key = session and session_key(session) or nil
    for _, rec in ipairs((key and backfill_records[key]) or {}) do
        local dedupe = dedupe_key(rec)
        if not seen[dedupe] then
            seen[dedupe] = true
            merged[#merged + 1] = rec
        end
    end
    table.sort(merged, function(a, b)
        if (a.ts or 0) ~= (b.ts or 0) then
            return (a.ts or 0) > (b.ts or 0)
        end
        return (a.seq or 0) > (b.seq or 0)
    end)
    return merged
end

-- Row formatting ---------------------------------------------------------------

---@param rec pi.CompactionRecord
---@return string
local function tokens_cell(rec)
    local Stats = require("pi.stats")
    local after = rec.tokens_after and Stats.format_tokens(rec.tokens_after) or "?"
    return Stats.format_tokens(rec.tokens_before or 0) .. " → " .. after
end

---@param rec pi.CompactionRecord
---@return string?
local function duration_cell(rec)
    if type(rec.duration_ms) ~= "number" or rec.duration_ms < 0 then
        return nil
    end
    return string.format("%ds", math.floor(rec.duration_ms / 1000))
end

---@param rec pi.CompactionRecord
---@return string?
local function cost_cell(rec)
    local usage = rec.usage
    local cost = type(usage) == "table" and usage.cost or nil
    local total = type(cost) == "table" and non_null(cost.total) or nil
    return type(total) == "number" and string.format("$%.3f", total) or nil
end

---@param rec pi.CompactionRecord
---@return string?
local function files_cell(rec)
    if rec.read_files == nil and rec.modified_files == nil then
        return nil
    end
    return tostring(rec.read_files or "?") .. "/" .. tostring(rec.modified_files or "?") .. " files"
end

--- The summary excerpt: flattened to single spaces, quoted, cut to SUMMARY_COLS.
---@param rec pi.CompactionRecord
---@return string?
local function summary_cell(rec)
    local flat = ((type(rec.summary) == "string" and rec.summary or ""):gsub("%s+", " "))
    if flat == "" then
        return nil
    end
    if vim.fn.strdisplaywidth(flat) > SUMMARY_COLS then
        flat = vim.fn.strcharpart(flat, 0, SUMMARY_COLS - 1) .. "…"
    end
    return '"' .. flat .. '"'
end

--- Format one record into its row cells (pure; the renderer pads and joins).
---@param rec pi.CompactionRecord
---@return pi.CompactionRowCells
function M.row_cells(rec)
    ---@type { col: integer, text: string }[]
    local fixed = {
        { col = 1, text = "#" .. tostring(rec.seq or 0) },
        { col = 2, text = tostring(os.date("%H:%M", rec.ts or os.time())) },
        { col = 3, text = type(rec.reason) == "string" and rec.reason or "unknown" },
        { col = 4, text = tokens_cell(rec) },
    }
    local optional = { duration_cell(rec), cost_cell(rec), files_cell(rec) }
    for i, text in ipairs(optional) do
        if text then
            fixed[#fixed + 1] = { col = i + 4, text = text }
        end
    end
    local status = rec.aborted and "aborted" or (rec.error and "failed" or nil)
    return {
        fixed = fixed,
        summary = summary_cell(rec),
        engine = rec.engine == "pi2",
        status = status,
        warn = status ~= nil,
    }
end

--- Pad and join rows, two spaces apart, with per-line highlight chunks (byte
--- ranges; the chunk's third element is its highlight group).
---@param rows pi.CompactionRowCells[]
---@return string[] lines
---@return table<integer, any[]> chunks_by_line
local function build_lines(rows)
    ---@type table<integer, integer> widest text per column
    local widths = {}
    for _, row in ipairs(rows) do
        for _, cell in ipairs(row.fixed) do
            widths[cell.col] = math.max(widths[cell.col] or 0, vim.fn.strdisplaywidth(cell.text))
        end
    end

    local lines, chunks_by_line = {}, {}
    for i, row in ipairs(rows) do
        local line = "  "
        ---@type any[]
        local chunks = {}

        ---@param text string
        ---@param hl string?
        local function append(text, hl)
            local start = #line
            line = line .. text
            if hl then
                chunks[#chunks + 1] = { start, #line, hl }
            end
        end

        local following = row.summary ~= nil or row.engine or row.status ~= nil
        for index, cell in ipairs(row.fixed) do
            if index > 1 then
                line = line .. "  "
            end
            local text = cell.text
            if index < #row.fixed or following then
                text = text .. string.rep(" ", (widths[cell.col] or 0) - vim.fn.strdisplaywidth(text))
            end
            append(text, row.warn and "PiStatusLineWarning" or nil)
        end
        if row.summary then
            line = line .. "  "
            append(row.summary, row.warn and "PiStatusLineWarning" or "PiSessionsListDotDim")
        end
        if row.engine then
            line = line .. "  "
            append("󰏗pi2", row.warn and "PiStatusLineWarning" or "PiSessionsListDotDim")
        end
        if row.status then
            line = line .. "  "
            append(row.status, "PiStatusLineWarning")
        end
        lines[i] = line
        chunks_by_line[i] = chunks
    end
    return lines, chunks_by_line
end

-- Rendering -------------------------------------------------------------------

--- Rebuild the buffer contents from the live state.
function M._render()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    records = collect(current_session())

    local title = "  󰏗 Compactions (" .. #records .. ")"
    local hint = "  ? help · q close"
    local lines = { "", title, hint, "" }
    ---@type table<integer, any[]>
    local line_chunks = {
        [2] = { { 0, #title, "PiSessionsListDotDim" } },
        [3] = { { 0, #hint, "PiSessionsListDotDim" } },
    }
    if #records == 0 then
        local empty = "  No compactions in this session"
        lines[#lines + 1] = empty
        line_chunks[#lines] = { { 0, #empty, "PiSessionsListDotDim" } }
    else
        ---@type pi.CompactionRowCells[]
        local rows = {}
        for i, rec in ipairs(records) do
            rows[i] = M.row_cells(rec)
        end
        local rendered, chunks_by_line = build_lines(rows)
        for i, line in ipairs(rendered) do
            lines[#lines + 1] = line
            line_chunks[#lines] = chunks_by_line[i]
        end
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for lnum, chunks in pairs(line_chunks) do
        for _, chunk in ipairs(chunks) do
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, chunk[1], {
                end_col = chunk[2],
                hl_group = chunk[3],
                priority = 10,
            })
        end
    end
    vim.bo[buf].modifiable = false

    -- Keep cursors inside the (possibly shrunk) buffer.
    for _, win in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            local cursor = vim.api.nvim_win_get_cursor(win)
            if cursor[1] > #lines then
                pcall(vim.api.nvim_win_set_cursor, win, { #lines, 0 })
            end
        end
    end
end

--- Re-render the panel from the live state (no-op without a buffer).
function M.refresh()
    M._render()
end

---@return boolean
local function any_win_visible()
    for _, win in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            return true
        end
    end
    return false
end

--- Coalesced redraw; no-op unless a list window is visible.
function M.request_refresh()
    if refresh_scheduled then
        return
    end
    refresh_scheduled = true
    vim.schedule(function()
        refresh_scheduled = false
        if any_win_visible() then
            M._render()
        end
    end)
end

-- Row lookup ------------------------------------------------------------------

--- The record under the cursor, or nil after telling the user there is none.
---@return pi.CompactionRecord?
local function record_under_cursor()
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
    local rec = ok and records[cursor[1] - HEADER_LINES] or nil
    if not rec then
        require("pi.notify").info("No compaction on this line")
    end
    return rec
end

-- Row actions -----------------------------------------------------------------

--- `<CR>`: jump the chat history to this compaction. The panel stays open.
local function jump_under_cursor()
    local rec = record_under_cursor()
    if not rec then
        return
    end
    local Notify = require("pi.notify")
    local session = current_session()
    local chat = session and session.chat or nil
    if not chat or type(chat.jump_to_compaction) ~= "function" then
        Notify.info("That compaction is not in the loaded history")
        return
    end
    local ok, jumped = pcall(chat.jump_to_compaction, chat, rec.summary, rec.tokens_before)
    if not ok or not jumped then
        Notify.info("That compaction is not in the loaded history")
    end
end

--- `gp`: the full summary in an info dialog.
local function show_summary_under_cursor()
    local rec = record_under_cursor()
    if not rec then
        return
    end
    local lines = vim.split(type(rec.summary) == "string" and rec.summary or "", "\n", { plain = true })
    require("pi.ui.dialog").info({ title = "Compaction summary", lines = lines })
end

--- `d`: unified diff against the previous (older) compaction's summary.
local function diff_under_cursor()
    local rec = record_under_cursor()
    if not rec then
        return
    end
    local Notify = require("pi.notify")
    local index = nil
    for i, candidate in ipairs(records) do
        if candidate == rec then
            index = i
            break
        end
    end
    -- Rows are newest first, so the previous compaction is the next row down.
    local previous = index and records[index + 1] or nil
    if not previous then
        Notify.info("No earlier compaction to diff")
        return
    end
    local ok, diff = pcall(vim.diff, tostring(previous.summary or ""), tostring(rec.summary or ""), {
        result_type = "unified",
    })
    if not ok or type(diff) ~= "string" then
        Notify.error("Could not diff the compaction summaries")
        return
    end
    require("pi.ui.dialog").info({
        title = "Compaction diff (previous → this)",
        lines = vim.split(diff, "\n", { plain = true }),
    })
end

--- `y`: copy the summary to the clipboard register, falling back to `"`.
local function yank_under_cursor()
    local rec = record_under_cursor()
    if not rec then
        return
    end
    local text = type(rec.summary) == "string" and rec.summary or ""
    -- A build without a clipboard provider accepts `+` silently but keeps
    -- nothing, so verify the write before trusting it.
    local ok = pcall(vim.fn.setreg, "+", text)
    if not ok or vim.fn.getreg("+") ~= text then
        pcall(vim.fn.setreg, '"', text)
    end
    require("pi.notify").info("Compaction summary copied")
end

--- `r`: request a new compaction, reusing this record's focus instructions.
local function recompact_under_cursor()
    local rec = record_under_cursor()
    if not rec then
        return
    end
    require("pi").compact(rec.custom_instructions)
    require("pi.notify").info("Compaction requested")
end

-- Help overlay (?) ------------------------------------------------------------

--- Shortcuts shown by the help overlay: { key(s), description } pairs.
---@type [string, string][]
local HELP_ENTRIES = {
    { "<CR>", "Jump to this compaction in the chat history" },
    { "gp", "Show the full compaction summary" },
    { "d", "Diff this summary against the previous compaction" },
    { "y", "Copy the summary to the clipboard" },
    { "r", "Request a new compaction with this one's focus instructions" },
    { "q", "Close the panel" },
    { "?", "Toggle this help" },
}

--- Help float per list window (the buffer is shared, windows are per tab).
---@type table<integer, integer>
local help_wins = {}

---@param list_win integer
local function close_help(list_win)
    local help = help_wins[list_win]
    if help and vim.api.nvim_win_is_valid(help) then
        vim.api.nvim_win_close(help, true)
    end
    help_wins[list_win] = nil
end

--- Toggle the help overlay. The float never takes focus and dies with its list.
---@param list_win integer
local function toggle_help(list_win)
    if not vim.api.nvim_win_is_valid(list_win) then
        return
    end
    local existing = help_wins[list_win]
    if existing and vim.api.nvim_win_is_valid(existing) then
        close_help(list_win)
        return
    end

    local key_width = 0
    for _, entry in ipairs(HELP_ENTRIES) do
        key_width = math.max(key_width, vim.fn.strdisplaywidth(entry[1]))
    end
    local lines, width = {}, 0
    for _, entry in ipairs(HELP_ENTRIES) do
        local line = string.format("%-" .. key_width .. "s  %s", entry[1], entry[2])
        lines[#lines + 1] = line
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = width + 2

    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].filetype = Ft.dialog

    local cfg = Config.options.dialog
    local editor_w, editor_h = vim.o.columns, vim.o.lines - vim.o.cmdheight
    local win = vim.api.nvim_open_win(b, false, {
        relative = "editor",
        row = math.max(0, math.floor((editor_h - #lines) / 2)),
        col = math.max(0, math.floor((editor_w - width) / 2)),
        width = width,
        height = #lines,
        style = "minimal",
        border = cfg and cfg.border or "rounded",
        title = " compactions ",
        title_pos = "center",
        focusable = false,
    })
    vim.wo[win].winhighlight = Highlights.DIALOG_WINHIGHLIGHT
    help_wins[list_win] = win

    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            help_wins[list_win] = nil
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(list_win),
        once = true,
        callback = function()
            close_help(list_win)
        end,
    })
end

-- Buffer & windows ------------------------------------------------------------

---@return integer
local function ensure_buf()
    if buf and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, "pi://compactions")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].buflisted = false
    vim.bo[buf].filetype = "pi-compactions"
    vim.bo[buf].modifiable = false

    ---@type table
    local opts = { buffer = buf, nowait = true }
    ---@param lhs string
    ---@param rhs function
    ---@param desc string
    local function map(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, vim.tbl_extend("force", opts, { desc = desc }))
    end
    map("<CR>", jump_under_cursor, "Jump to this compaction in the chat history")
    map("gp", show_summary_under_cursor, "Show the full compaction summary")
    map("d", diff_under_cursor, "Diff against the previous compaction")
    map("y", yank_under_cursor, "Copy the summary to the clipboard")
    map("r", recompact_under_cursor, "Request a new compaction with this one's focus instructions")
    map("q", function()
        M.close()
    end, "Close the compaction panel")
    map("?", function()
        toggle_help(vim.api.nvim_get_current_win())
    end, "Toggle help")

    return buf
end

---@param win integer
local function set_list_win_opts(win)
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].foldenable = false
    vim.wo[win].list = false
    vim.wo[win].spell = false
    vim.wo[win].cursorline = true
    vim.wo[win].winfixbuf = true
end

--- Side layout: the workspace owns placement, stacking and width.
---@param b integer
---@return integer?
local function open_side_win(b)
    local cfg = panel_cfg()
    local tab = current_tab()
    -- A legacy top/bottom row has no compaction column: use the right column
    -- instead of inventing a horizontal timeline.
    local column = Workspace.column_for(tab, cfg.position) or "right"
    return Workspace.claim_panel(tab, "compactions", b, {
        edge = column,
        width = cfg.width,
        weight = 1,
        configure = function(win)
            set_list_win_opts(win)
            vim.wo[win].winfixwidth = true
        end,
    })
end

--- Float layout: editor-centered, geometry from `compaction.panel`, clamped.
---@param b integer
---@return integer
local function open_float_win(b)
    local cfg = panel_cfg()
    local width = math.max(1, math.min(cfg.width or 100, math.max(1, vim.o.columns - 2)))
    local height = math.max(1, math.min(cfg.height or 22, math.max(1, vim.o.lines - vim.o.cmdheight - 2)))
    local win = vim.api.nvim_open_win(b, true, {
        relative = "editor",
        width = width,
        height = height,
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - 1 - height) / 2)),
        style = "minimal",
        border = "rounded",
        title = " compactions ",
        title_pos = "center",
    })
    set_list_win_opts(win)
    vim.wo[win].winhighlight = list_winhighlight()
    return win
end

---@param tab pi.TabId
---@return integer?
local function win_for(tab)
    local win = wins[tab]
    if win and vim.api.nvim_win_is_valid(win) then
        return win
    end
    wins[tab] = nil
    return nil
end

--- Open (or focus) the panel in the current tab.
function M.open()
    local tab = current_tab()
    local existing = win_for(tab)
    if existing then
        vim.api.nvim_set_current_win(existing)
        return
    end

    request_backfill(current_session())

    local win
    if panel_cfg().mode == "side" then
        win = open_side_win(ensure_buf()) or open_float_win(ensure_buf())
    else
        win = open_float_win(ensure_buf())
    end
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    wins[tab] = win
    M._render()
    -- Land on the first record so the row keys work right after open.
    if #records > 0 and vim.api.nvim_win_get_cursor(win)[1] <= HEADER_LINES then
        pcall(vim.api.nvim_win_set_cursor, win, { HEADER_LINES + 1, 0 })
    end
end

--- Close the panel in `tab` (no-op when absent). Safe for a background tab:
--- closing a window never touches the current tabpage or focus.
---@param tab pi.TabId
function M.close_tab(tab)
    local win = win_for(tab)
    wins[tab] = nil
    if win then
        close_help(win)
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, false)
        end
    end
    -- Release the sidebar claim so the remaining edge panels re-expand.
    if vim.api.nvim_tabpage_is_valid(tab) then
        pcall(Workspace.release_panel, tab, "compactions")
    end
end

--- Close the panel in the current tab (no-op when absent).
function M.close()
    M.close_tab(current_tab())
end

--- Toggle the panel in the current tab.
function M.toggle()
    if win_for(current_tab()) then
        M.close()
    else
        M.open()
    end
end

--- True when the current window shows the panel (its window or its buffer).
---@return boolean
function M.has_focus()
    local win = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(win) then
        return false
    end
    for _, list_win in pairs(wins) do
        if list_win == win then
            return true
        end
    end
    local b = vim.api.nvim_win_get_buf(win)
    if buf and vim.api.nvim_buf_is_valid(buf) and b == buf then
        return true
    end
    return vim.bo[b].filetype == "pi-compactions"
end

-- Test hooks ------------------------------------------------------------------

--- Test hook: lines above the rows (row i renders at buffer line i + N).
---@return integer
function M._header_lines()
    return HEADER_LINES
end

--- Test hook: records of the last render, newest first.
---@return pi.CompactionRecord[]
function M._records()
    return records
end

--- Test hook: the panel window open in `tab` (nil when none).
---@param tab pi.TabId
---@return integer?
function M._win(tab)
    return win_for(tab)
end

--- Test hook: the help-overlay shortcut table.
---@return [string, string][]
function M._help_entries()
    return HELP_ENTRIES
end

--- Test hook: drop all module state (windows, buffer, backfill caches).
function M._reset()
    for list_win in pairs(help_wins) do
        close_help(list_win)
    end
    for tab, win in pairs(wins) do
        wins[tab] = nil
        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, true)
        end
        if vim.api.nvim_tabpage_is_valid(tab) then
            pcall(Workspace.release_panel, tab, "compactions")
        end
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    buf = nil
    records = {}
    refresh_scheduled = false
    backfill_requested = {}
    backfill_records = {}
end

return M
