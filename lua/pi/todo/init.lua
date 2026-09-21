--- Todo panel (:PiTodo) — persistent sidebar view of the session's todo list.
---
--- The state is a read-only mirror of the agent's `todo_write` tool results:
--- sessions/manager.lua routes every tool_execution_end (live and replay) with
--- a todo tool through update_from_details(), which stores the latest
--- { todos, completed, total } snapshot and re-renders any open panel window.
---
--- The mirror is keyed to the tab that OWNS the session (its attached tab),
--- not the tab the keyboard focus happens to be on: RPC events are processed
--- while any tab may be focused. Callers pass the session's tab explicitly;
--- direct/legacy callers omit it and get the current tab. Auto-open on the
--- empty→non-empty transition is per-tab too: a panel window can only be
--- created in the CURRENT tab (a split in another tabpage would steal focus),
--- so when the event arrives while the session's tab is in the background the
--- pending marker stays set and the TabEnter autocmd below opens the panel as
--- soon as the user enters that tab.
---
--- Window layout mirrors pi.ui.sessions: one window per tab in `wins[tab]`.
--- Unlike the sessions list (whose rows are global, so one shared buffer
--- serves every window), todo state is per-tab: each tab gets its own scratch
--- buffer in `bufs[tab]`, and a refresh writes only that tab's buffer.
--- When the sessions sidebar (pi.ui.sessions) is open in the tab, the todo
--- panel stacks in the same column (focus the sessions window, then `split`
--- below/above it); otherwise it opens as its own vertical-split column sized
--- after the sessions-list config. Stacked height follows the sessions-list
--- dimension convention (values < 1 are fractions): todo.panel.height < 1 is
--- the panel's fraction of the shared sessions+todo column (default 0.5, an
--- even split), >= 1 is absolute lines; the ratio is re-evaluated on every
--- refresh, so manual resizes of the column are corrected back to the
--- configured split. Stacked windows are winfixheight; standalone columns are
--- winfixwidth, so the column width survives layout churn.

local M = {}

local Config = require("pi.config")
local Ft = require("pi.filetypes")

---@class pi.TodoItem
---@field content string
---@field status "pending"|"in_progress"|"completed"
---@field activeForm? string

---@class pi.TodoDetails
---@field todos pi.TodoItem[]
---@field completed integer
---@field total integer

--- Panel configuration with the documented defaults applied inline.
--- Config.options.todo is owned by another change (G19); everything here is
--- defensive so the panel works even before the key lands in config.lua.
---@class pi.TodoPanelResolvedConfig
---@field auto_open boolean
---@field height number
---@field position "below"|"above"
---@field hide_when_empty boolean

--- How the panel window in a tab came to be open.
---   manual: the user ran :PiTodo (M.open()/M.toggle()) — the panel stays open
---           and shows a one-line "no todos" placeholder when the list empties
---           (unless hide_when_empty = false, same behavior).
---   auto:   opened by the empty→non-empty transition when
---           todo.panel.auto_open is set — when the list clears and
---           hide_when_empty is true, the panel closes instead of lingering.
---@alias pi.TodoOpenedBy "auto"|"manual"

--- Latest todo snapshot per tab (one state per session, one session per tab).
---@type table<pi.TabId, pi.TodoDetails>
local state = {}

---@type table<pi.TabId, integer> panel window per tab
local wins = {}

---@type table<pi.TabId, integer> panel scratch buffer per tab (todo state is
--- per-tab, so two tabs with the panel open must not share one buffer)
local bufs = {}

--- How each open panel was opened (see pi.TodoOpenedBy).
---@type table<pi.TabId, pi.TodoOpenedBy>
local opened_by = {}

--- Non-nil while a scheduled refresh is pending.
local refresh_scheduled = false

--- Set per tab when an empty→non-empty transition should auto-open that tab's
--- panel. Consumed by the scheduled refresh when the tab is also the current
--- tab, or by the TabEnter autocmd below once the user enters the tab.
---@type table<pi.TabId, boolean>
local auto_open_pending = {}

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

--- Read the panel config with the documented defaults applied defensively.
---@return pi.TodoPanelResolvedConfig
local function panel_config()
    local todo_cfg = Config.options.todo or {}
    local panel = todo_cfg.panel or {}
    return {
        auto_open = panel.auto_open == true,
        height = (type(panel.height) == "number" and panel.height > 0) and panel.height or 0.5,
        position = panel.position == "above" and "above" or "below",
        hide_when_empty = panel.hide_when_empty ~= false,
    }
end

--- Whether `details` describes a non-empty todo list.
---@param details pi.TodoDetails?
---@return boolean
local function has_todos(details)
    return details ~= nil and details.total ~= nil and details.total > 0 and type(details.todos) == "table"
end

--- Content lines of the panel for the current state, with the DESIGN.md
--- "whitespace over lines" treatment applied:
---
---   line 1: blank spacer — breathing room between the sessions list and the
---           todo panel (stacked layout reads as one column; without it the
---           todo list collides with the sessions list above)
---   line 2: calm header — 2-space indent + title + progress count
---   line 3: blank — breathing room between header and list
---   line 4+: one line per todo, consistently 2-space indented
---
--- The empty-list placeholder follows the same shape (spacer + indented
--- "no todos"). The returned list is the FINAL render: every height
--- computation consumes its length, so padding is never clipped.
--- Returns nil when the panel should render nothing. An empty list renders
--- the placeholder only for manually-opened panels (or when hide_when_empty
--- is false); auto-opened panels are closed by refresh() instead.
---@param tab pi.TabId
---@return string[]?
local function panel_lines(tab)
    local details = state[tab]
    local cfg = panel_config()
    if not has_todos(details) then
        if cfg.hide_when_empty and opened_by[tab] ~= "manual" then
            return nil
        end
        return { "", "  no todos" }
    end
    -- pi.todo.tool_ui is developed in a separate change; degrade gracefully
    -- (plain list) instead of erroring while it is absent or broken.
    local lines
    local ok, result = pcall(function()
        return require("pi.todo.tool_ui").format_lines(details)
    end)
    if ok and type(result) == "table" then
        lines = result
    else
        lines = {}
        local header = tostring(details.completed or 0) .. "/" .. tostring(details.total or #details.todos)
        lines[#lines + 1] = header
        for _, t in ipairs(details.todos) do
            lines[#lines + 1] = t.content
        end
    end
    -- format_lines leads with its own progress header; the panel replaces it
    -- with the calmer "Todo · <progress>" title line and keeps the rows.
    local progress = tostring(details.completed or 0) .. "/" .. tostring(details.total or #details.todos)
    local p_ok, text = pcall(function()
        return require("pi.todo.tool_ui").progress_text(details)
    end)
    if p_ok and type(text) == "string" and text ~= "" then
        progress = text
    end
    local out = { "", "  Todo · " .. progress, "" }
    for i = 2, #lines do
        out[#out + 1] = "  " .. tostring(lines[i])
    end
    return out
end

--- Height of the stacked panel window inside the shared sessions+todo column.
--- `cfg.height < 1` is a fraction of `column_height` (the column total, which
--- is the sessions window's height at open time and sessions+todo on refresh
--- — re-evaluating on every refresh also corrects manual :resize drift back
--- to the configured ratio); `>= 1` is absolute lines. The result is bounded
--- so the neighboring window keeps at least one line. Content taller than the
--- panel just scrolls — the height is never shrink-to-content.
--- Exported for tests.
---@param cfg pi.TodoPanelResolvedConfig
---@param column_height integer total height of the shared sessions+todo column
---@return integer
function M._height_for(cfg, column_height)
    local target = cfg.height < 1 and math.floor(column_height * cfg.height) or math.floor(cfg.height)
    return math.max(1, math.min(target, math.max(1, column_height - 1)))
end

--- Rebuild `tab`'s panel buffer contents from `tab`'s state (no-op when there
--- is nothing to show).
---@param tab pi.TabId
---@return boolean true when lines were written
local function render_buf(tab)
    local b = bufs[tab]
    if not b or not vim.api.nvim_buf_is_valid(b) then
        return false
    end
    local lines = panel_lines(tab)
    if not lines then
        return false
    end
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    vim.bo[b].modifiable = false
    return true
end

--- The sessions sidebar window in `tab`, when valid (nil otherwise).
---@param tab pi.TabId
---@return integer?
local function sessions_win(tab)
    local ok, Sessions = pcall(require, "pi.ui.sessions")
    if not ok or not Sessions or type(Sessions.win) ~= "function" then
        return nil
    end
    local win = Sessions.win(tab)
    if win and vim.api.nvim_win_is_valid(win) then
        return win
    end
    return nil
end

--- Buffer-local options for the tab's scratch panel buffer.
---@param b integer
---@param tab pi.TabId
local function setup_buf(b, tab)
    -- Buffer names must be unique; the per-tab suffix keeps several open
    -- panels distinguishable in :ls.
    vim.api.nvim_buf_set_name(b, ("pi://todo-%d"):format(tab))
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "hide"
    vim.bo[b].swapfile = false
    vim.bo[b].buflisted = false
    vim.bo[b].filetype = Ft.sessions
    vim.bo[b].modifiable = false
    vim.keymap.set("n", "q", function()
        M.close()
    end, { buffer = b, nowait = true, desc = "Close todo panel" })
end

---@param tab pi.TabId
---@return integer
local function ensure_buf(tab)
    local b = bufs[tab]
    if b and vim.api.nvim_buf_is_valid(b) then
        return b
    end
    b = vim.api.nvim_create_buf(false, true)
    bufs[tab] = b
    setup_buf(b, tab)
    return b
end

--- Window-local options for the panel window.
---@param win integer
---@param stacked boolean true when the panel is a split inside the sessions column
local function set_win_opts(win, stacked)
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].foldenable = false
    vim.wo[win].list = false
    vim.wo[win].spell = false
    vim.wo[win].cursorline = false
    vim.wo[win].winfixbuf = true
    if stacked then
        vim.wo[win].winfixheight = true
        vim.wo[win].winfixwidth = true
    else
        vim.wo[win].winfixwidth = true
    end
end

--- Open the panel stacked in the sessions sidebar column (same width): focus
--- the sessions window and split below/above it according to panel.position.
--- The sessions window keeps the rest of the column; the new todo window is
--- winfixheight. The height is a fraction of the column (sessions owns the
--- whole column before the split) or absolute lines, never content-sized.
---@param tab pi.TabId
---@param b integer
---@return integer?
local function open_stacked(tab, b)
    local cfg = panel_config()
    local sess = sessions_win(tab)
    if not sess then
        return nil
    end
    local ok, err = pcall(vim.api.nvim_set_current_win, sess)
    if not ok then
        require("pi.notify").warn("Cannot open todo panel: " .. tostring(err))
        return nil
    end
    -- Sessions owns the whole column before the split, so its height IS the
    -- column height the fraction is taken from.
    local height = M._height_for(cfg, vim.api.nvim_win_get_height(sess))
    local cmd = (cfg.position == "above" and "leftabove " or "rightbelow ") .. height .. "split"
    vim.cmd(cmd)
    local win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_win_set_buf, win, b)
    set_win_opts(win, true)
    -- The :split count is not sticky: 'equalalways' (on by default) equalizes
    -- the column whenever the layout is (re)processed before winfixheight is
    -- consulted, collapsing the column to 50/50. After pinning winfixheight,
    -- re-assert the target height explicitly.
    pcall(vim.api.nvim_win_set_height, win, height)
    return win
end

--- Open the panel as its own sidebar column, sized after the sessions-list
--- config (position left → topleft vsplit, right → botright vsplit).
--- Falls back to the documented defaults when sessions_list is absent.
---@param tab pi.TabId
---@param b integer
---@return integer?
local function open_standalone(tab, b)
    local sl = Config.options.sessions_list or {}
    local position = sl.position == "right" and "right" or "left"
    local width = (type(sl.width) == "number" and sl.width > 0) and math.floor(sl.width) or 40
    local cmd = (position == "right" and "botright " or "topleft ") .. width .. "vsplit"
    vim.cmd(cmd)
    local win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_win_set_buf, win, b)
    set_win_opts(win, false)
    return win
end

--- Whether the panel window is open in the current tab.
---@return boolean
function M.is_open()
    return M.win(current_tab()) ~= nil
end

--- The valid panel window for `tab`, cleaning stale entries.
---@param tab pi.TabId
---@return integer?
function M.win(tab)
    local win = wins[tab]
    if win and vim.api.nvim_win_is_valid(win) then
        return win
    end
    wins[tab] = nil
    return nil
end

--- Open the todo panel in the current tab. When the sessions sidebar is open
--- in this tab, the panel stacks in its column; otherwise it opens as its own
--- sidebar column. The panel shows a "no todos" placeholder even when the
--- list is empty (manually-opened windows ignore hide_when_empty).
--- `how` records how the panel came to be open ("auto" for the auto_open
--- transition, default "manual" for :PiTodo); see pi.TodoOpenedBy.
---@param how? pi.TodoOpenedBy
function M.open(how)
    local tab = current_tab()
    local existing = M.win(tab)
    if existing then
        pcall(vim.api.nvim_set_current_win, existing)
        return
    end
    opened_by[tab] = how == "auto" and "auto" or "manual"
    local b = ensure_buf(tab)
    render_buf(tab)
    local lines = panel_lines(tab)
    if not lines then
        -- Nothing to show (e.g. format_lines produced no lines): do not open
        -- an empty window; the marker stays for a subsequent refresh.
        opened_by[tab] = nil
        return
    end
    local sess = sessions_win(tab)
    local win = (sess and open_stacked(tab, b)) or open_standalone(tab, b)
    if win then
        wins[tab] = win
    end
end

--- Close `tab`'s panel window, if any, and drop its opened_by marker.
---@param tab pi.TabId
local function close_for_tab(tab)
    local win = M.win(tab)
    if not win then
        return
    end
    wins[tab] = nil
    opened_by[tab] = nil
    if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, false)
    end
end

--- Close the panel window in the current tab (no-op when absent).
function M.close()
    close_for_tab(current_tab())
end

--- Toggle the todo panel in the current tab (:PiTodo).
function M.toggle()
    if M.win(current_tab()) then
        M.close()
    else
        M.open()
    end
end

--- Coalesced re-render of all open panel windows; each window renders its own
--- tab's state into its own buffer. Auto-opened panels whose list has cleared
--- (and hide_when_empty is on) are closed instead of showing an empty list.
--- Called from update_from_details (after vim.schedule) and after open().
function M.refresh()
    for tab, win in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            local cfg = panel_config()
            local cleared = not has_todos(state[tab])
            if cleared and cfg.hide_when_empty and opened_by[tab] ~= "manual" then
                close_for_tab(tab)
            else
                render_buf(tab)
                -- Stacked windows: re-assert the pinned height after EVERY
                -- render, computed from the column total (sessions + todo as
                -- they stand now). The :split count is not sticky
                -- ('equalalways' can re-equalize the column; a neighbor resize
                -- can redistribute it), and re-deriving the ratio from the
                -- current column height also corrects manual :resize drift
                -- back to the configured split (absolute heights stay
                -- absolute). Standalone columns stay full-height — no height
                -- is forced there.
                local sess = sessions_win(tab)
                if sess then
                    local column = vim.api.nvim_win_get_height(sess) + vim.api.nvim_win_get_height(win)
                    pcall(vim.api.nvim_win_set_height, win, M._height_for(cfg, column))
                end
            end
        end
    end
end

--- Update the mirror from parsed tool-result details and refresh/open panels.
--- Called from sessions/manager.lua on tool_execution_end (live and replay)
--- for todo tools, keyed to the tab that owns the session. Safe to call from
--- an RPC callback: UI work is scheduled.
---
--- Transitions:
---   - non-empty details: store + refresh open panels; on empty→non-empty with
---     todo.panel.auto_open, open the panel in `tab` (opened_by = "auto") —
---     immediately when `tab` is also the current tab, otherwise deferred to
---     the TabEnter autocmd (a split window cannot be created in a
---     non-current tabpage without stealing focus).
---   - total == 0 (cleared): store the empty state. Auto-opened panels then
---     close on the next refresh (when hide_when_empty is true); panels the
---     user opened explicitly stay open and show a one-line "no todos"
---     placeholder instead of an empty list.
---@param details pi.TodoDetails
---@param tab? pi.TabId tab the details belong to (the session's attached tab
---   when routed through sessions/manager.lua); nil defaults to the current
---   tab (single-tab behavior for direct/legacy callers)
function M.update_from_details(details, tab)
    if type(details) ~= "table" or type(details.todos) ~= "table" then
        return
    end
    tab = tab or current_tab()
    local was_empty = not has_todos(state[tab])
    state[tab] = {
        todos = details.todos,
        completed = tonumber(details.completed) or 0,
        total = tonumber(details.total) or #details.todos,
    }
    if was_empty and has_todos(state[tab]) and panel_config().auto_open then
        auto_open_pending[tab] = true
    end
    if refresh_scheduled then
        return
    end
    refresh_scheduled = true
    vim.schedule(function()
        refresh_scheduled = false
        -- Consume an auto_open transition even though the details arrived from
        -- an RPC callback (update_from_details itself is a fast event). Only
        -- when the owning tab is also the current tab, though: a split window
        -- cannot be created in a non-current tabpage without stealing focus, so
        -- a background tab keeps its marker pending for the TabEnter autocmd.
        if auto_open_pending[tab] and tab == current_tab() then
            auto_open_pending[tab] = nil
            if not M.win(tab) then
                M.open("auto")
            end
        end
        M.refresh()
    end)
end

--- The latest todo snapshot of the current tab's session.
---@return pi.TodoDetails?
function M.current()
    return state[current_tab()]
end

--- Test hook: how the current tab's open panel came to be open.
---@return pi.TodoOpenedBy?
function M._opened_by()
    return opened_by[current_tab()]
end

--- Test hook: drop all module state and close every panel window.
function M._reset()
    for _, win in pairs(wins) do
        if vim.api.nvim_win_is_valid(win) then
            pcall(vim.api.nvim_win_close, win, false)
        end
    end
    for _, b in pairs(bufs) do
        if vim.api.nvim_buf_is_valid(b) then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
    wins = {}
    bufs = {}
    state = {}
    opened_by = {}
    refresh_scheduled = false
    auto_open_pending = {}
end

--- Autocmd group for the per-tab auto-open bookkeeping. Created at module
--- load; clear = true makes a re-require (tests drop package.loaded) replace
--- the previous group's autocmds instead of stacking duplicates.
local augroup = vim.api.nvim_create_augroup("pi-todo-panel", { clear = true })

--- Deferred auto-open: entering a tab consumes its pending auto_open marker.
--- The marker is only left pending when the event arrived while the tab was
--- in the background (the scheduled refresh cannot open a split there), so
--- the panel opens exactly here, with the tab as the current one.
vim.api.nvim_create_autocmd("TabEnter", {
    group = augroup,
    callback = function()
        local tab = current_tab()
        if not auto_open_pending[tab] then
            return
        end
        auto_open_pending[tab] = nil
        if M.win(tab) or not panel_config().auto_open then
            return
        end
        M.open("auto")
    end,
})

--- TabClosed reports the closed tab's NUMBER, not its handle (the key used
--- here), so prune pending markers whose handle is no longer alive. Only the
--- pending markers are cleaned up here — full per-tab state cleanup is not.
vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
        local alive = {}
        for _, t in ipairs(vim.api.nvim_list_tabpages()) do
            alive[t] = true
        end
        for t in pairs(auto_open_pending) do
            if not alive[t] then
                auto_open_pending[t] = nil
            end
        end
    end,
})

return M
