--- Background tasks panel (:PiTasks) — a live list of background bash tasks.
---
--- One shared scratch buffer lists every task known to pi.tasks (running
--- first, then newest terminal), one row per task: status dot, spinner,
--- command summary and an `id · status · duration` subtitle. The buffer is
--- global: each tab that opens the panel gets its own window on the same
--- buffer, so a single redraw updates every view at once. Window geometry is
--- per-tab.
---
--- The panel is a straight adaptation of the sessions overview
--- (lua/pi/ui/sessions.lua): same shared-buffer model, same blink/spinner
--- timers (running only while a window is visible), same coalesced
--- request_refresh(), same help overlay and current-row marker mechanics.
--- Differences: rows come from pi.tasks instead of the session manager, the
--- current-row marker covers every running task (tasks carry no tab
--- association), and a 1s duration timer keeps running `mm:ss` clocks and
--- the spinner frame ticking.

local M = {}

local Config = require("pi.config")
local Ft = require("pi.filetypes")
local Highlights = require("pi.ui.highlights")
local Tasks = require("pi.tasks")

local ns = vim.api.nvim_create_namespace("pi-tasks-list")

local uv = vim.uv or vim.loop

--- Render-time extensions to a pi.TasksRow (the row class is owned by
--- pi.tasks): the byte range of the status dot, for the window-local
--- running-row marker (matchaddpos).
---@class pi.TasksRow
---@field marker_col integer? 1-based byte column of the status dot
---@field marker_len integer? byte length of the status dot glyph

---@type integer? shared list buffer
local buf = nil

---@type table<pi.TabId, integer> list window per tab
local wins = {}

---@type pi.TasksRow[] rows of the last render (index == buffer line)
local rows = {}

---@type boolean
local refresh_scheduled = false

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

-- Panel config ----------------------------------------------------------------

--- Panel configuration with defensive defaults: the config/highlights half of
--- this feature may not have landed yet, so every lookup degrades to the
--- frozen contract values.
---@return { mode: "follow"|"side"|"float", position: string, width: integer, height: integer }
local function panel_cfg()
    ---@type table
    local defaults = { mode = "follow", position = "left", width = 40, height = 12 }
    return vim.tbl_deep_extend("keep", Config.options.tasks_panel or {}, defaults)
end

--- Window-local highlight chain: prefers the tasks-specific chain, falling
--- back to the sessions list chain (same value shape) when undefined.
---@return string
local function list_winhighlight()
    return Highlights.TASKS_LIST_WINHIGHLIGHT or Highlights.SESSIONS_LIST_WINHIGHLIGHT
end

-- Formatting ------------------------------------------------------------------

--- Spinner frames for running tasks (same braille set as the sessions list).
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- Spinner frame at an animation tick (pure; drives the test hook too).
---@param tick integer
---@return string
function M.spinner_frame(tick)
    return SPINNER_FRAMES[(tick % #SPINNER_FRAMES) + 1]
end

--- `mm:ss` clock for a running duration; hours grow a `h:mm:ss` prefix.
---@param ms integer
---@return string
local function format_duration(ms)
    local s = math.max(0, math.floor(ms / 1000))
    if s >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60)
    end
    return string.format("%02d:%02d", math.floor(s / 60), s % 60)
end

--- Relative age of a finished task from its end_time (`3m ago`).
---@param ms integer
---@return string
local function format_ago(ms)
    local s = math.max(0, math.floor(ms / 1000))
    if s < 60 then
        return s .. "s ago"
    end
    local m = math.floor(s / 60)
    if m < 60 then
        return m .. "m ago"
    end
    local h = math.floor(m / 60)
    if h < 24 then
        return h .. "h ago"
    end
    return math.floor(h / 24) .. "d ago"
end

--- Highlight group of a row's status dot at a given animation tick. Running
--- blinks every tick; failure is a steady red, success/stopped a dim ◌.
---@param row pi.TasksRow
---@param tick integer
---@return string
function M.dot_hl(row, tick)
    local status = row.task.status
    if status == "running" then
        return tick % 2 == 0 and "PiTasksListRunning" or "PiTasksListDotDim"
    end
    if status == "failed" then
        return "PiTasksListFailure"
    end
    if status == "completed" then
        return "PiTasksListSuccess"
    end
    return "PiTasksListStopped"
end

--- Format a row: the status dot at the left edge, a spinner while running,
--- the (truncated) command summary, then the `id · status · duration`
--- subtitle. Running rows show a live `mm:ss` duration; terminal rows show
--- the age since end_time (`3m ago`). Chunks are byte ranges:
--- { col_start, col_end, hl_group }.
---@param row pi.TasksRow
---@param tick integer
---@param width integer? available display width (defaults to 80)
---@param now_ms integer? reference time for relative ages (defaults to uv.now())
---@return string line
---@return integer[][] chunks
function M.format_line(row, tick, width, now_ms)
    width = width or 80
    now_ms = now_ms or uv.now()
    local task = row.task
    local running = task.status == "running"
    local dot = (task.status == "completed" or task.status == "stopped") and "◌" or "●"
    local spinner = running and M.spinner_frame(tick) or nil

    local subtitle = task.id .. " · " .. row.status_label
    if row.duration_ms then
        local time
        if running then
            time = format_duration(row.duration_ms)
        elseif task.end_time then
            time = format_ago(now_ms - task.end_time)
        else
            time = format_duration(row.duration_ms)
        end
        subtitle = subtitle .. " · " .. time
    end

    local prefix = dot .. " " .. (spinner and spinner .. " " or "")
    local sep = " · "
    local budget = width
        - vim.fn.strdisplaywidth(prefix)
        - vim.fn.strdisplaywidth(sep)
        - vim.fn.strdisplaywidth(subtitle)
    if budget < 1 then
        budget = 1
    end
    local summary = (task.command or ""):gsub("%s+", " ")
    if vim.fn.strdisplaywidth(summary) > budget then
        summary = vim.fn.strcharpart(summary, 0, math.max(1, budget - 1)) .. "…"
    end

    local line = prefix .. summary .. sep .. subtitle
    local chunks = {
        { 0, #dot, M.dot_hl(row, tick) },
    }
    local text_start = #prefix
    local summary_end = text_start + #summary
    local subtitle_start = summary_end + #sep
    table.insert(chunks, { text_start, subtitle_start, "Normal" })
    table.insert(chunks, { subtitle_start, #line, "PiTasksListDotDim" })
    if spinner then
        table.insert(chunks, 2, { #dot + 1, text_start - 1, "PiTasksListSpinner" })
    end
    return line, chunks
end

-- Animation timers ------------------------------------------------------------

--- Dot blink phase; drives both the running-dot blink and the marker.
local blink_tick = 0
---@type uv.uv_timer_t?
local blink_timer = nil

--- Spinner/duration phase; drives the braille frame of running rows.
local spinner_tick = 0
---@type uv.uv_timer_t?
local spinner_timer = nil

---@return boolean
local function any_win_visible()
    for _, win in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            return true
        end
    end
    return false
end

---@return boolean whether any row is still running
local function has_running_row()
    for _, row in ipairs(rows) do
        if row.task.status == "running" then
            return true
        end
    end
    return false
end

local function stop_blink()
    if not blink_timer then
        return
    end
    pcall(blink_timer.stop, blink_timer)
    if not blink_timer:is_closing() then
        blink_timer:close()
    end
    blink_timer = nil
end

--- Run the dot blink timer only while a running row is on screen.
local function ensure_blink()
    if not any_win_visible() or not has_running_row() then
        stop_blink()
        return
    end
    if blink_timer and not blink_timer:is_closing() then
        return
    end
    blink_timer = assert(uv.new_timer())
    blink_timer:start(
        500,
        500,
        vim.schedule_wrap(function()
            if not any_win_visible() or not has_running_row() then
                vim.schedule(stop_blink)
                return
            end
            blink_tick = blink_tick + 1
            M._render()
        end)
    )
end

local function stop_spinner()
    if not spinner_timer then
        return
    end
    pcall(spinner_timer.stop, spinner_timer)
    if not spinner_timer:is_closing() then
        spinner_timer:close()
    end
    spinner_timer = nil
end

--- Run the 1s duration timer only while a running row is on screen: it keeps
--- `mm:ss` clocks and the spinner frame advancing.
local function ensure_spinner()
    if not any_win_visible() or not has_running_row() then
        stop_spinner()
        return
    end
    if spinner_timer and not spinner_timer:is_closing() then
        return
    end
    spinner_timer = assert(uv.new_timer())
    spinner_timer:start(
        1000,
        1000,
        vim.schedule_wrap(function()
            if not any_win_visible() or not has_running_row() then
                vim.schedule(stop_spinner)
                return
            end
            spinner_tick = spinner_tick + 1
            M._render()
        end)
    )
end

-- Rendering -------------------------------------------------------------------

---@type table<integer, integer> matchaddpos id per list window
local current_matches = {}

--- Window-local marker: a background under the status dot of every running
--- row (tasks carry no tab association, so each window marks the same rows).
--- The buffer is shared across tabs but matches are window-local.
local function refresh_current_markers()
    for _, win in pairs(wins) do
        local old_id = current_matches[win]
        if old_id and vim.api.nvim_win_is_valid(win) then
            pcall(vim.fn.matchdelete, old_id, win)
        end
        current_matches[win] = nil
        if vim.api.nvim_win_is_valid(win) then
            for lnum, row in ipairs(rows) do
                if row.task.status == "running" then
                    local col = row.marker_col or 1
                    local len = row.marker_len or 1
                    local ok, id = pcall(vim.api.nvim_win_call, win, function()
                        return vim.fn.matchaddpos("PiTasksListCurrent", { { lnum, col, len } }, 20)
                    end)
                    if ok then
                        current_matches[win] = id
                    end
                end
            end
        end
    end
end

--- Rebuild the buffer contents from live task state.
function M._render()
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    rows = Tasks.build_rows()

    ---@type string[]
    local lines = {}
    ---@type table<integer, integer[][]>
    local line_chunks = {}
    for i, row in ipairs(rows) do
        local width = 80
        for _, win in pairs(wins) do
            if vim.api.nvim_win_is_valid(win) then
                width = math.max(width, vim.api.nvim_win_get_width(win))
            end
        end
        local line, chunks = M.format_line(row, blink_tick + spinner_tick, width)
        lines[i] = line
        line_chunks[i] = chunks
        row.marker_col = chunks[1][1] + 1
        row.marker_len = chunks[1][2] - chunks[1][1]
    end
    if #lines == 0 then
        lines = { "  (no background tasks)" }
    end

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for lnum, chunks in ipairs(line_chunks) do
        for _, chunk in ipairs(chunks) do
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, chunk[1], {
                end_col = chunk[2],
                hl_group = chunk[3],
                -- below the window-local running-row marker (priority 20)
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

    ensure_blink()
    ensure_spinner()
    refresh_current_markers()
end

--- Coalesced live redraw; no-op unless a list window is visible.
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

--- Row and task under the cursor. nil, nil when the cursor is off the rows.
---@return pi.TasksRow?, pi.Task?
local function row_task_under_cursor()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local row = rows[lnum]
    if not row then
        return nil, nil
    end
    return row, row.task
end

-- Help overlay (?) ------------------------------------------------------------

--- Shortcuts shown by the help overlay: { key(s), description } pairs.
---@type [string, string][]
local HELP_ENTRIES = {
    { "<CR>, o", "Open this task's output (vsplit)" },
    { "a, i", "Open the output and focus it" },
    { "p", "Preview the output tail in a float" },
    { "x", "Stop the task under the cursor" },
    { "R", "Redraw the list" },
    { "q", "Close the list" },
    { "?", "Toggle this help" },
}

--- Help float per list window. The list buffer is shared across tabs but
--- windows are per-tab, so each window toggles its own overlay.
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

--- Toggle the help overlay listing the panel shortcuts. The float never
--- takes focus and closes automatically with its list window.
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
    local lines = {}
    local width = 0
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
    local editor_w = vim.o.columns
    local editor_h = vim.o.lines - vim.o.cmdheight
    local win = vim.api.nvim_open_win(b, false, {
        relative = "editor",
        row = math.floor((editor_h - #lines) / 2),
        col = math.floor((editor_w - width) / 2),
        width = width,
        height = #lines,
        style = "minimal",
        border = cfg.border,
        title = " tasks ",
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

-- Task output -----------------------------------------------------------------

--- Maximum lines read from an output file (large outputs tail only).
local MAX_OUTPUT_LINES = 10000

--- Files larger than this are tail-read instead of slurped whole.
local TAIL_READ_BYTES = 256 * 1024

--- Read an output file as lines, keeping only the tail beyond max_lines.
---@param path string
---@param max_lines integer
---@return string[]?
local function read_output_lines(path, max_lines)
    local stat = uv.fs_stat(path)
    if not stat then
        return nil
    end
    local lines
    if stat.size > TAIL_READ_BYTES then
        -- Tail read: seek back one chunk from the end and drop the first
        -- (partial) line so the buffer starts on a clean boundary.
        local f = io.open(path, "r")
        if not f then
            return nil
        end
        f:seek("end", -math.min(stat.size, TAIL_READ_BYTES))
        local chunk = f:read("*a") or ""
        f:close()
        chunk = chunk:gsub("^[^\n]*\n", "", 1)
        lines = vim.split(chunk, "\n", { plain = true })
    else
        lines = vim.fn.readfile(path)
    end
    if #lines > max_lines then
        lines = vim.list_slice(lines, #lines - max_lines + 1, #lines)
    end
    return lines
end

--- Open the output of the task under the cursor in a vsplit. Focuses the
--- output window when `focus` is true (a/i), otherwise returns focus to the
--- list window (<CR>/o).
---@param focus boolean
local function open_output_under_cursor(focus)
    local row, task = row_task_under_cursor()
    if not row or not task then
        return
    end
    local Notify = require("pi.notify")
    if not task.output_file or task.output_file == "" then
        Notify.warn("Task " .. task.id .. " has no output file")
        return
    end
    local lines = read_output_lines(task.output_file, MAX_OUTPUT_LINES)
    if not lines then
        Notify.warn("Cannot read output for task " .. task.id .. ": " .. task.output_file)
        return
    end

    local list_win = vim.api.nvim_get_current_win()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    pcall(vim.api.nvim_buf_set_name, b, "pi://task-output/" .. task.id)
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].swapfile = false
    vim.bo[b].buflisted = false
    vim.bo[b].filetype = "pi-task-output"
    vim.bo[b].modifiable = false
    vim.keymap.set("n", "q", function()
        pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), false)
    end, { buffer = b, nowait = true, desc = "Close task output" })

    vim.cmd("vsplit")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, b)
    vim.wo[win].wrap = false
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, #lines), 0 })
    if not focus and vim.api.nvim_win_is_valid(list_win) then
        vim.api.nvim_set_current_win(list_win)
    end
end

--- Preview floats per list window: `p` opens the output tail (200 lines) in a
--- centered, focusable float so it can be scrolled; pressing `p` again
--- closes it.
---@type table<integer, integer>
local preview_wins = {}

---@param list_win integer
local function close_preview(list_win)
    local preview = preview_wins[list_win]
    if preview and vim.api.nvim_win_is_valid(preview) then
        vim.api.nvim_win_close(preview, true)
    end
    preview_wins[list_win] = nil
end

--- Toggle the read-only output-tail preview float for the task under cursor.
---@param list_win integer
local function toggle_preview(list_win)
    if not vim.api.nvim_win_is_valid(list_win) then
        return
    end
    local existing = preview_wins[list_win]
    if existing and vim.api.nvim_win_is_valid(existing) then
        close_preview(list_win)
        return
    end
    local row, task = row_task_under_cursor()
    if not row or not task then
        return
    end
    local Notify = require("pi.notify")
    if not task.output_file or task.output_file == "" then
        Notify.warn("Task " .. task.id .. " has no output file")
        return
    end
    local lines = read_output_lines(task.output_file, 200)
    if not lines then
        Notify.warn("Cannot read output for task " .. task.id .. ": " .. task.output_file)
        return
    end

    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    pcall(vim.api.nvim_buf_set_name, b, "pi://task-preview/" .. task.id)
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].swapfile = false
    vim.bo[b].buflisted = false
    vim.bo[b].filetype = "pi-task-output"
    vim.bo[b].modifiable = false
    vim.keymap.set("n", "q", function()
        pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), false)
    end, { buffer = b, nowait = true, desc = "Close task preview" })

    local editor_w = vim.o.columns
    local editor_h = vim.o.lines - vim.o.cmdheight - 1
    local width = math.floor(editor_w * 0.6)
    local height = math.floor(editor_h * 0.4)
    local win = vim.api.nvim_open_win(b, true, {
        relative = "editor",
        row = math.max(0, math.floor((editor_h - height) / 2)),
        col = math.max(0, math.floor((editor_w - width) / 2)),
        width = width,
        height = height,
        style = "minimal",
        border = "rounded",
        title = " task " .. task.id .. " ",
        title_pos = "center",
    })
    vim.wo[win].winhighlight = list_winhighlight()
    vim.wo[win].wrap = false
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, #lines), 0 })
    preview_wins[list_win] = win

    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            preview_wins[list_win] = nil
        end,
    })
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(list_win),
        once = true,
        callback = function()
            close_preview(list_win)
        end,
    })
end

-- Stop (x) --------------------------------------------------------------------

--- Stop the task under the cursor: confirm first, then optimistically mark it
--- stopped locally and signal the process. The authoritative stopped state
--- arrives later from the backend's pi2_bg_task event.
local function stop_under_cursor()
    local row, task = row_task_under_cursor()
    if not row or not task then
        return
    end
    local Notify = require("pi.notify")
    if task.status ~= "running" then
        Notify.info("Task " .. task.id .. " is not running (" .. row.status_label .. ")")
        return
    end
    local choice = vim.fn.confirm("Stop task " .. task.id .. " (" .. task.command .. ")?", "&Yes\n&No", 2)
    if choice ~= 1 then
        return
    end
    Tasks.mark_stopped(task.id)
    if task.pid then
        pcall(uv.kill, task.pid, "sigterm")
    end
end

-- Buffer & windows ------------------------------------------------------------

---@return integer
local function ensure_buf()
    if buf and vim.api.nvim_buf_is_valid(buf) then
        return buf
    end
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, "pi://tasks")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].buflisted = false
    vim.bo[buf].filetype = "pi-tasks"
    vim.bo[buf].modifiable = false

    local map_opts = { buffer = buf, nowait = true }
    vim.keymap.set("n", "<CR>", function()
        open_output_under_cursor(false)
    end, vim.tbl_extend("force", map_opts, { desc = "Open this task's output" }))
    vim.keymap.set("n", "o", function()
        open_output_under_cursor(false)
    end, vim.tbl_extend("force", map_opts, { desc = "Open this task's output" }))
    vim.keymap.set("n", "a", function()
        open_output_under_cursor(true)
    end, vim.tbl_extend("force", map_opts, { desc = "Open the output and focus it" }))
    vim.keymap.set("n", "i", function()
        open_output_under_cursor(true)
    end, vim.tbl_extend("force", map_opts, { desc = "Open the output and focus it" }))
    vim.keymap.set("n", "p", function()
        toggle_preview(vim.api.nvim_get_current_win())
    end, vim.tbl_extend("force", map_opts, { desc = "Preview the output tail in a float" }))
    vim.keymap.set("n", "x", function()
        stop_under_cursor()
    end, vim.tbl_extend("force", map_opts, { desc = "Stop the task under the cursor" }))
    vim.keymap.set("n", "R", function()
        M._render()
    end, vim.tbl_extend("force", map_opts, { desc = "Redraw task list" }))
    vim.keymap.set("n", "q", function()
        M.close()
    end, vim.tbl_extend("force", map_opts, { desc = "Close task list" }))
    vim.keymap.set("n", "?", function()
        toggle_help(vim.api.nvim_get_current_win())
    end, vim.tbl_extend("force", map_opts, { desc = "Toggle help" }))

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

---@param b integer
---@return integer
local function open_side_win(b)
    local cfg = panel_cfg()
    local position = cfg.position or "left"
    local cmd
    if position == "right" then
        cmd = "botright " .. cfg.width .. "vsplit"
    elseif position == "top" then
        cmd = "topleft " .. cfg.height .. "split"
    elseif position == "bottom" then
        cmd = "botright " .. cfg.height .. "split"
    else
        cmd = "topleft " .. cfg.width .. "vsplit"
    end
    vim.cmd(cmd)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, b)
    set_list_win_opts(win)
    if position == "top" or position == "bottom" then
        vim.wo[win].winfixheight = true
    else
        vim.wo[win].winfixwidth = true
    end
    return win
end

---@param b integer
---@return integer
local function open_float_win(b)
    -- Float geometry is fixed by the panel contract: editor-centered at
    -- 0.5 x 0.4 with a rounded border (unlike the side layout, which reads
    -- width/height/position straight from config).
    local width = math.max(1, math.floor(vim.o.columns * 0.5))
    local height = math.max(1, math.floor((vim.o.lines - vim.o.cmdheight - 1) * 0.4))
    local col = math.floor((vim.o.columns - width) / 2)
    local row = math.floor((vim.o.lines - vim.o.cmdheight - 1 - height) / 2)
    local win = vim.api.nvim_open_win(b, true, {
        relative = "editor",
        width = width,
        height = height,
        col = col,
        row = math.max(0, row),
        style = "minimal",
        border = "rounded",
        title = " tasks ",
        title_pos = "center",
    })
    set_list_win_opts(win)
    vim.wo[win].winhighlight = list_winhighlight()
    return win
end

--- Layout mode for the panel window. `tasks_panel.mode` wins when set to
--- "side"/"float"; "follow" (default) matches the current tab's chat layout,
--- degrading to "side" when no chat layout is available (tasks have no tab
--- binding of their own, so this mirrors the sessions-list fallback).
---@return pi.LayoutMode
local function resolve_mode()
    local mode = panel_cfg().mode
    if mode == "side" then
        return "side"
    end
    if mode == "float" then
        return "float"
    end
    local ok, Sessions = pcall(require, "pi.sessions.manager")
    if ok then
        local session = Sessions.get()
        if session and session.chat then
            return session.chat:layout()
        end
    end
    return "side"
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

--- Public accessor: the tasks-panel window open in `tab` (nil when none).
--- Used by other panels (e.g. the todo panel) to stack in the same sidebar
--- column, mirroring the sessions-list usage.
---@param tab pi.TabId
---@return integer?
function M.win(tab)
    return win_for(tab)
end

--- Open (or focus) the tasks panel in the current tab.
function M.open()
    local tab = current_tab()
    local existing = win_for(tab)
    if existing then
        vim.api.nvim_set_current_win(existing)
        return
    end

    local b = ensure_buf()
    local win
    if resolve_mode() == "float" then
        win = open_float_win(b)
    else
        win = open_side_win(b)
    end
    wins[tab] = win
    M._render()
end

--- Close the tasks panel window in the current tab (no-op when absent).
function M.close()
    local tab = current_tab()
    local win = win_for(tab)
    if not win then
        return
    end
    wins[tab] = nil
    if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, false)
    end
end

--- True when the current window is a `:PiTasks` panel.
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
    return vim.bo[b].filetype == "pi-tasks"
end

--- Toggle the tasks panel in the current tab.
function M.toggle()
    if win_for(current_tab()) then
        M.close()
    else
        M.open()
    end
end

-- Data flow -------------------------------------------------------------------

---@type fun()? cancel for the tasks refresh subscription
local refresh_cancel = nil

--- (Re)subscribe the panel redraw to pi.tasks refresh notifications.
--- Tasks._reset() drops listeners, so specs re-arm via M._resubscribe().
local function subscribe()
    if refresh_cancel then
        refresh_cancel()
    end
    refresh_cancel = Tasks.on_refresh(function()
        M.request_refresh()
    end)
end

subscribe()

-- Test hooks ------------------------------------------------------------------

--- Test hook: set the blink animation tick (drives dot/marker blink phase).
---@param tick integer
function M._set_blink_tick(tick)
    blink_tick = tick
end

--- Test hook: set the spinner/duration tick (drives running-row frames).
---@param tick integer
function M._set_spinner_tick(tick)
    spinner_tick = tick
end

--- Test hook: row and task under the cursor (nil, nil when off the rows).
---@return pi.TasksRow?, pi.Task?
function M._row_task_under_cursor()
    return row_task_under_cursor()
end

--- Test hook: the rows of the last render (index == buffer line).
---@return pi.TasksRow[]
function M._rows()
    return rows
end

--- Test hook: the help-overlay shortcut table.
---@return [string, string][]
function M._help_entries()
    return HELP_ENTRIES
end

--- Test hook: re-arm the pi.tasks refresh subscription after Tasks._reset().
function M._resubscribe()
    subscribe()
end

--- Test hook: drop all module state.
function M._reset()
    stop_blink()
    stop_spinner()
    blink_tick = 0
    spinner_tick = 0
    for list_win in pairs(help_wins) do
        close_help(list_win)
    end
    for list_win in pairs(preview_wins) do
        close_preview(list_win)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    buf = nil
    wins = {}
    rows = {}
    refresh_scheduled = false
end

return M
