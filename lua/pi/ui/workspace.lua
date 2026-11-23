--- pi.ui.workspace — per-tab three-column layout owner.
---
--- A tab that runs π UI is a single row of columns:
---
---     [ left column ][ chat column ][ right column ]
---
--- The side columns exist only while at least one panel (`:PiSessions`,
--- `:PiTasks`, `:PiTodo`) is registered on them; the chat column is created by
--- `pi.ui.chat.layout` from the window `acquire_center()` hands out. The panel
--- registry and the stacking math live in `pi.ui.sidebar`; this module owns the
--- chat column, the tab takeover (full-tab mode) and the single `apply()` pass
--- that pins every width and height of the tab's π windows.
---
--- Why one owner: chat windows and panels used to issue their own `:vsplit`
--- commands from four modules, so every change recomputed geometry from a
--- different starting point (a leftover editor window in the middle of the tab,
--- a panel column squeezed by a chat re-open, heights off by the tabline). All
--- placement decisions now go through `workspace`, and every mutation ends in a
--- deferred `apply(tab)` — `WinClosed` fires before Neovim hands the freed space
--- back to the frame tree, so a synchronous pass would be overwritten (issue
--- #31).
---
--- Placement invariants:
---   * side columns are the outermost windows of the tab (left edge / right
---     edge); the chat column sits inboard of them;
---   * the side column width is owned by the panel that opened it and is
---     re-applied on every pass, so an external split shrinks the chat column,
---     never a π column;
---   * in split mode the chat column keeps the configured width and the
---     leftover editor window absorbs the rest (historical behaviour, and what
---     `layout.side.position` selects); in full-tab mode the chat column is the
---     flexible one.

local M = {}

local Sidebar = require("pi.ui.sidebar")
local Winfix = require("pi.ui.winfix")

--- Below this width the chat column stops being usable; side columns are
--- shrunk proportionally so the floor wins (full-tab mode only).
local MIN_CHAT_WIDTH = 40

--- A side column never takes more than this share of the editor width, however
--- it was configured, so a typo cannot leave the chat with nothing.
local MAX_COLUMN_FRACTION = 0.4

--- Column width used when a panel opens a column without naming a width.
local DEFAULT_COLUMN_WIDTH = 40

---@alias pi.WorkspaceMode "full"|"split"

---@class pi.WorkspaceBorrowed
---@field win integer Window taken over from the tab
---@field buf integer Buffer that window showed before the takeover
---@field view table Cursor/scroll view to restore with `winrestview`

---@class pi.WorkspaceChat
---@field history integer
---@field prompt integer
---@field attachments? integer
---@field prompt_height? fun(): integer Content height of the prompt window
---@field attachments_height? fun(): integer Target height of the attachments window

---@class pi.WorkspaceState
---@field mode pi.WorkspaceMode
---@field borrowed? pi.WorkspaceBorrowed
---@field chat? pi.WorkspaceChat

---@class pi.WorkspaceCenter
---@field win integer Window to use for the chat history
---@field borrowed boolean The window is the tab's own (restore on release)
---@field created boolean Workspace split the window out (close on release)

---@class pi.WorkspacePanelSpec
---@field edge "left"|"right" Side column to place the panel in
---@field width? number Width spec for the column when this panel opens it (fraction when < 1)
---@field weight? number Stacking weight inside the column (default 1)
---@field order? number Stacking order inside the column (default: the sidebar ORDER map)
---@field configure? fun(win: integer) Caller-owned window options (winfixwidth, cursorline, …)

---@type table<pi.TabId, pi.WorkspaceState>
local states = {}

---@type table<pi.TabId, boolean>
local dirty = {}

local scheduled = false
local autocmds_ready = false

---@param win integer?
---@return boolean
local function win_valid(win)
    return win ~= nil and vim.api.nvim_win_is_valid(win)
end

---@param tab pi.TabId
---@return boolean
local function tab_valid(tab)
    return vim.api.nvim_tabpage_is_valid(tab)
end

---@param tab pi.TabId
---@return pi.WorkspaceState
local function state(tab)
    local st = states[tab]
    if not st then
        st = { mode = "split" }
        states[tab] = st
    end
    return st
end

--- Resolve a configured column width (fraction when < 1) to columns.
---@param spec number
---@param available integer
---@return integer
local function resolve_width(spec, available)
    if spec < 1 then
        return math.max(1, math.floor(available * spec))
    end
    return math.max(1, math.floor(spec))
end

---@param st pi.WorkspaceState
---@param win integer
---@return boolean
local function owns_window(st, win)
    local chat = st.chat
    if chat and (chat.history == win or chat.prompt == win or chat.attachments == win) then
        return true
    end
    if st.borrowed and st.borrowed.win == win then
        return true
    end
    return false
end

--- Resolve the side-column widths and the flexible remainder for a given
--- editor width. Pure (no window access), so `:checkhealth pi` can report what
--- the current config produces without opening anything.
---
--- Each side column is capped at 40% of the editor; in full-tab mode the chat
--- column is the only flexible one, so two wide columns are shrunk
--- proportionally to keep at least `min_chat` columns for the chat. In split
--- mode the leftover editor window is the flexible one, exactly as always.
---@param left number? width spec of the left column (fraction when < 1)
---@param right number? width spec of the right column
---@param available integer editor width in columns
---@param mode pi.WorkspaceMode
---@return { left?: integer, right?: integer, flex: integer, min_chat: integer }
function M.resolve_columns(left, right, available, mode)
    local out = { flex = available, min_chat = math.min(MIN_CHAT_WIDTH, available) }
    local ncols = 0
    local cap = math.max(1, math.floor(available * MAX_COLUMN_FRACTION))
    if left then
        out.left = math.min(resolve_width(left, available), cap)
        ncols = ncols + 1
    end
    if right then
        out.right = math.min(resolve_width(right, available), cap)
        ncols = ncols + 1
    end
    if ncols > 0 then
        if mode == "full" and out.left and out.right then
            local room = available - ncols -- one separator per side column
            local budget = room - MIN_CHAT_WIDTH
            if budget < 2 then
                budget = 2
            end
            local sum = out.left + out.right
            if sum > budget then
                out.left = math.max(1, math.floor(budget * out.left / sum))
                out.right = math.max(1, budget - out.left)
            end
        end
        out.flex = available - ncols - (out.left or 0) - (out.right or 0)
    end
    return out
end

--- Width of every open side column in `tab`, clamped to the chat floor.
--- Only `left`/`right` keys are ever present.
---@param tab pi.TabId
---@param st pi.WorkspaceState
---@return table<string, integer>
local function column_widths(tab, st)
    local resolved =
        M.resolve_columns(Sidebar.width_spec(tab, "left"), Sidebar.width_spec(tab, "right"), vim.o.columns, st.mode)
    local out = {}
    if resolved.left then
        out.left = resolved.left
    end
    if resolved.right then
        out.right = resolved.right
    end
    return out
end

--- Pin the chat column's own windows to the column height: history takes what
--- the prompt and the attachments window leave over.
---@param st pi.WorkspaceState
local function apply_chat_heights(st)
    local chat = st.chat
    if not chat or not win_valid(chat.history) or not win_valid(chat.prompt) then
        return
    end
    local awin = win_valid(chat.attachments) and chat.attachments or nil
    local n = 2 + (awin and 1 or 0)
    local total = Sidebar.height_budget(n)
    local ph = chat.prompt_height and chat.prompt_height() or vim.api.nvim_win_get_height(chat.prompt)
    local ah = 0
    if awin then
        ah = chat.attachments_height and chat.attachments_height() or vim.api.nvim_win_get_height(awin)
    end
    ph = math.max(1, ph)
    ah = math.max(0, ah)
    local hh = total - ph - ah
    -- Too little room: shrink the prompt first (it re-grows with its content),
    -- then the attachments window, never the history below three lines.
    if hh < 3 then
        local deficit = 3 - hh
        local take = math.min(deficit, ph - 1)
        ph = ph - take
        deficit = deficit - take
        if deficit > 0 and ah > 0 then
            local from_attach = math.min(deficit, ah)
            ah = ah - from_attach
            deficit = deficit - from_attach
        end
        hh = total - ph - ah
    end
    if hh < 1 then
        hh = 1
    end
    pcall(vim.api.nvim_win_set_height, chat.history, hh)
    pcall(vim.api.nvim_win_set_height, chat.prompt, ph)
    if awin and ah > 0 then
        pcall(vim.api.nvim_win_set_height, awin, ah)
    end
end

--- One geometry pass: side column widths, per-column stacking, chat heights.
--- Idempotent and safe to call at any time.
---@param tab pi.TabId
function M.apply(tab)
    local st = states[tab]
    if not st or not tab_valid(tab) then
        return
    end
    local widths = column_widths(tab, st)
    for edge, width in pairs(widths) do
        local panels = Sidebar.panels(tab, edge)
        if #panels > 0 and win_valid(panels[1].win) then
            pcall(vim.api.nvim_win_set_width, panels[1].win, width)
        end
    end
    for _, edge in ipairs({ "left", "right", "top", "bottom" }) do
        if #Sidebar.panels(tab, edge) > 0 then
            Sidebar.restack(tab, edge)
        end
    end
    local chat = st.chat
    if chat then
        -- In full-tab mode the chat column is flexible; split mode keeps the
        -- configured width it was opened with.
        for _, win in ipairs({ chat.history, chat.prompt, chat.attachments }) do
            if win_valid(win) then
                pcall(vim.api.nvim_set_option_value, "winfixwidth", st.mode == "split", { win = win })
            end
        end
    end
    apply_chat_heights(st)
end

--- Run the pending applies on the next event-loop tick. Window-creating
--- commands and `WinClosed` need this: Neovim redistributes the freed space
--- after the event returns, so a synchronous pass would be overwritten.
---@param tab pi.TabId
local function schedule_apply(tab)
    dirty[tab] = true
    if scheduled then
        return
    end
    scheduled = true
    vim.schedule(function()
        scheduled = false
        local pending = dirty
        dirty = {}
        for target in pairs(pending) do
            if tab_valid(target) and states[target] then
                M.apply(target)
            end
        end
    end)
end

--- Run pending geometry now (test/automation hook).
function M.flush()
    local pending = dirty
    dirty = {}
    scheduled = false
    for target in pairs(pending) do
        if tab_valid(target) and states[target] then
            M.apply(target)
        end
    end
end

--- The workspace state of `tab`, or nil when the tab never ran π UI.
---@param tab pi.TabId
---@return pi.WorkspaceState?
function M.state(tab)
    return states[tab]
end

--- The chat windows of `tab`, or nil when the chat is not shown.
---@param tab pi.TabId
---@return pi.WorkspaceChat?
function M.chat(tab)
    local st = states[tab]
    return st and st.chat or nil
end

---@param tab pi.TabId
---@return pi.WorkspaceMode?
function M.mode(tab)
    local st = states[tab]
    return st and st.mode or nil
end

--- Handle a closed window: drop dead panel claims / chat fields, then
--- re-normalize the column it lived in (the tab at event time, since the
--- closed window's tab may not be the current one any more).
---@param win integer? closed window id
---@param event_tab pi.TabId tab the window lived in, at event time
function M._on_win_closed(win, event_tab)
    if win then
        for tab, st in pairs(states) do
            if tab_valid(tab) then
                local panel_key = Sidebar.panel_key(tab, win)
                if owns_window(st, win) or panel_key then
                    local chat = st.chat
                    if chat then
                        if chat.history == win then
                            chat.history = nil
                        end
                        if chat.prompt == win then
                            chat.prompt = nil
                        end
                        if chat.attachments == win then
                            chat.attachments = nil
                        end
                    end
                    if panel_key then
                        Sidebar.release_win(tab, win)
                    end
                    schedule_apply(tab)
                    return
                end
            end
        end
    end
    -- An external window closed in a tab π lives in: the freed space was
    -- redistributed by the frame tree, so pin our columns again.
    if event_tab and states[event_tab] then
        schedule_apply(event_tab)
    end
end

--- Drop a tab's layout state (the tab is gone or its session was detached).
---@param tab pi.TabId
function M.forget(tab)
    states[tab] = nil
    dirty[tab] = nil
end

--- Whether a full-tab takeover is allowed for `tab`.
---
--- `layout.side.full_tab`:
---   "never"  (default) — historical split behaviour.
---   "always"           — take over a single-window tab whatever it shows.
---   "auto"             — take over only a single window showing an untouched
---                        scratch buffer (what `:tabnew` leaves behind), so
---                        `:PiNewTab` fills the tab without stealing a file
---                        view from an ordinary `:Pi`.
--- A tab with several windows is never taken over: destroying the user's
--- split layout is not something a layout pass can undo.
---@param tab pi.TabId
---@param side_cfg pi.SideLayout
---@return pi.WorkspaceMode
function M.plan(tab, side_cfg)
    local requested = side_cfg and side_cfg.full_tab or "never"
    if requested ~= "always" and requested ~= "auto" then
        return "split"
    end
    local single
    local count = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_win_get_config(win).relative == "" then
            count = count + 1
            single = win
        end
    end
    if count ~= 1 or not single then
        return "split"
    end
    if requested == "always" then
        return "full"
    end
    -- "auto" takes over a single window that is not a user's editing view: an
    -- unnamed, unmodified buffer. That covers a `:tabnew` window and a plugin
    -- start screen (NvChad's nvdash, alpha, the snacks dashboard — all `nofile`
    -- buffers with no name), which is the state `<leader>ap` usually meets on a
    -- fresh editor. The window is borrowed, so its buffer comes back on hide;
    -- a named buffer (a file, a plugin sidebar) or a modified scratch stays,
    -- because covering those would hide work the user is looking at.
    local buf = vim.api.nvim_win_get_buf(single)
    local disposable = vim.api.nvim_buf_get_name(buf) == "" and not vim.bo[buf].modified
    return disposable and "full" or "split"
end

--- The window the chat column is carved out of in split mode: the outermost
--- regular window on the requested side, so the new column lands *inside* an
--- already-open panel column instead of outside it.
---
--- Side panels are tab-level and outlive a session: after a cross-checkout
--- `:PiResume` — or any hide/show of the chat while a panel is focused — the
--- chat reopens while the previous session's panels still hold the configured
--- edge. `:topleft`/`:botright` would then put the new column at the *outer*
--- edge (flipping the layout), and splitting a narrow panel window would
--- squeeze that column to a single cell.
---@param position "left"|"right"
---@return integer? win window to split (nil: keep the current window)
---@return string prefix split command prefix
local function resolve_side_split(position)
    local fallback = position == "left" and "topleft" or "botright"
    local best, best_col = nil, nil
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(win).relative == "" and not Sidebar.is_panel(win) then
            local col = vim.fn.win_screenpos(win)[2]
            if not best_col or (position == "left" and col < best_col) or (position == "right" and col > best_col) then
                best, best_col = win, col
            end
        end
    end
    if not best then
        return nil, fallback
    end
    return best, (position == "left" and "leftabove" or "rightbelow")
end

--- Resolve the window the chat column must start from.
---
--- Split mode carves a new column out of the editor; full-tab mode borrows the
--- tab's only window (buffer + view saved for `release_chat`), which is what
--- makes the tab belong entirely to π.
---@param tab pi.TabId
---@param side_cfg pi.SideLayout
---@return pi.WorkspaceCenter
function M.acquire_center(tab, side_cfg)
    ensure_autocmds()
    local st = state(tab)
    st.mode = M.plan(tab, side_cfg)
    if st.mode == "full" then
        local frame = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            if vim.api.nvim_win_get_config(win).relative == "" then
                frame[#frame + 1] = win
            end
        end
        if #frame == 1 then
            local win = frame[1]
            st.borrowed = {
                win = win,
                buf = vim.api.nvim_win_get_buf(win),
                view = vim.fn.winsaveview(),
            }
            vim.api.nvim_set_option_value("winfixbuf", false, { win = win })
            return { win = win, borrowed = true, created = false }
        end
        st.mode = "split"
    end
    local side = side_cfg and side_cfg.position == "left" and "left" or "right"
    local target, prefix = resolve_side_split(side)
    if target and vim.api.nvim_get_current_win() ~= target then
        vim.api.nvim_set_current_win(target)
    end
    local width = resolve_width(side_cfg and side_cfg.width or 80, vim.o.columns)
    vim.cmd(prefix .. " " .. width .. "vsplit")
    return { win = vim.api.nvim_get_current_win(), borrowed = false, created = true }
end

--- Register the chat windows of `tab` (after the layout created them) and run
--- a geometry pass.
---@param tab pi.TabId
---@param chat pi.WorkspaceChat
function M.register_chat(tab, chat)
    ensure_autocmds()
    local st = state(tab)
    st.chat = chat
    M.apply(tab)
end

--- Update the attachments window of `tab`'s chat (nil when it closed).
---@param tab pi.TabId
---@param win integer?
function M.set_attachments(tab, win)
    local st = states[tab]
    if not st or not st.chat then
        return
    end
    st.chat.attachments = win
    schedule_apply(tab)
end

--- Release the chat column: restore a borrowed window (full-tab mode) or close
--- the history window the workspace split out (split mode). The prompt and
--- attachments windows are closed by `pi.ui.chat.layout`, which owns them.
---@param tab pi.TabId
function M.release_chat(tab)
    local st = states[tab]
    if not st then
        return
    end
    local chat = st.chat
    if not chat then
        return
    end
    st.chat = nil
    local borrowed = st.borrowed
    st.borrowed = nil
    if borrowed and borrowed.win and vim.api.nvim_win_is_valid(borrowed.win) then
        local win = borrowed.win
        -- winfixbuf blocks nvim_win_set_buf (E1513); the layout set it on the
        -- borrowed window because it rendered the history buffer.
        vim.api.nvim_set_option_value("winfixbuf", false, { win = win })
        vim.api.nvim_set_option_value("winfixwidth", false, { win = win })
        vim.api.nvim_set_option_value("winfixheight", false, { win = win })
        pcall(vim.api.nvim_win_set_buf, win, borrowed.buf)
        if Winfix.restore then
            Winfix.restore(win)
        end
        pcall(vim.fn.winrestview, borrowed.view)
    elseif chat.history then
        M.close_window(chat.history)
    end
    schedule_apply(tab)
end

--- Close `win` unless it is the last frame window of its tab — closing that
--- would close the tabpage itself (E444 in the last tab). Returns true when the
--- window was closed.
---@param win integer?
---@return boolean
function M.close_window(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return false
    end
    local tab = vim.api.nvim_win_get_tabpage(win)
    local frames = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_win_get_config(w).relative == "" then
            frames = frames + 1
        end
    end
    if frames <= 1 then
        return false
    end
    return pcall(vim.api.nvim_win_close, win, false)
end

--- Insert a new panel window into `edge`'s column at its ORDER position.
---@param edge pi.SidebarEdge
---@param key string
---@param order number
---@param panels pi.SidebarPanel[] existing panels, in stacking order
---@return integer?
local function open_in_column(edge, key, order, panels)
    local new_order = order or Sidebar.order_of(key)
    local index
    for i, p in ipairs(panels) do
        if (p.order or math.huge) > (new_order or math.huge) then
            index = i
            break
        end
    end
    local anchor, cmd
    if index == 1 then
        -- New panel sorts before the current first one: place it above it.
        anchor = panels[1].win
        cmd = "leftabove split"
    else
        local prev = panels[index and (index - 1) or #panels]
        anchor = prev.win
        cmd = "rightbelow split"
    end
    if not win_valid(anchor) then
        return nil
    end
    vim.api.nvim_set_current_win(anchor)
    vim.cmd(cmd)
    return vim.api.nvim_get_current_win()
end

--- Create a new side column at the tab's outer edge.
---@param edge pi.SidebarEdge
---@param width number width spec
---@return integer
local function open_column(edge, width)
    local w = resolve_width(width or DEFAULT_COLUMN_WIDTH, vim.o.columns)
    vim.cmd((edge == "left" and "topleft " or "botright ") .. w .. "vsplit")
    return vim.api.nvim_get_current_win()
end

--- The chat history window, used as the anchor for a new side column so the
--- column lands next to the chat column instead of inside an editor split.
---@param tab pi.TabId
---@return integer?
local function chat_anchor(tab)
    local st = states[tab]
    local chat = st and st.chat
    if chat and win_valid(chat.history) then
        return chat.history
    end
    return nil
end

--- Map a panel's configured placement to a side column.
---
--- `left`/`right` pass through. A legacy `top`/`bottom` row is only honored in
--- split mode: a full-tab layout is built from left/right columns, so such a
--- panel falls back to the left column there instead of breaking the layout.
---@param tab pi.TabId
---@param position string?
---@return "left"|"right"|nil column; nil keeps the legacy row placement
function M.column_for(tab, position)
    if position == "left" or position == "right" then
        return position
    end
    if position == "top" or position == "bottom" then
        if M.mode(tab) == "full" then
            return "left"
        end
        return nil
    end
    return "left"
end

--- Open a panel window in its side column and register it.
---
--- The column is created at the tab's outer edge when it does not exist, and
--- the panel is inserted at its ORDER position when it does — so a column keeps
--- a stable stacking order no matter in which order the panels were opened.
---@param tab pi.TabId
---@param key string panel key ("sessions" | "tasks" | "todo")
---@param buf integer buffer to show
---@param spec pi.WorkspacePanelSpec
---@return integer? win
function M.claim_panel(tab, key, buf, spec)
    ensure_autocmds()
    state(tab)
    local edge = spec.edge or "left"
    local panels = Sidebar.panels(tab, edge)
    local win
    if #panels > 0 then
        win = open_in_column(edge, key, spec.order or Sidebar.order_of(key), panels)
    else
        local anchor = chat_anchor(tab)
        if anchor then
            vim.api.nvim_set_current_win(anchor)
        end
        win = open_column(edge, spec.width)
    end
    if not win or not win_valid(win) then
        return nil
    end
    vim.api.nvim_set_option_value("winfixbuf", false, { win = win })
    pcall(vim.api.nvim_win_set_buf, win, buf)
    if edge == "left" or edge == "right" then
        -- The side column width belongs to the workspace: pin it so an
        -- external split can only take space from the flexible column.
        vim.wo[win].winfixwidth = true
    end
    if spec.configure then
        spec.configure(win)
    end
    Sidebar.claim(tab, edge, key, win, {
        weight = spec.weight,
        order = spec.order,
        width = #panels == 0 and (spec.width or DEFAULT_COLUMN_WIDTH) or nil,
    })
    -- The new panel window keeps focus (historical behaviour: opening a panel
    -- lands the cursor in it), and the geometry is pinned immediately so the
    -- column is right before rendering.
    schedule_apply(tab)
    M.apply(tab)
    return win
end

--- Close a panel window and drop its column claim. Safe when the window is
--- already gone (then it only releases the stale claim).
---@param tab pi.TabId
---@param key string
function M.release_panel(tab, key)
    local win = Sidebar.panel_win(tab, key)
    Sidebar.release(tab, key)
    if win and win_valid(win) then
        pcall(vim.api.nvim_win_close, win, false)
    end
    schedule_apply(tab)
    M.apply(tab)
end

--- Re-apply geometry after the editor was resized.
---@param tab pi.TabId
function M.on_resize(tab)
    schedule_apply(tab)
    M.apply(tab)
end

--- Create the tab-level autocmds once, on first use (nothing on the
--- `pi.setup()` startup path).
function ensure_autocmds()
    if autocmds_ready then
        return
    end
    autocmds_ready = true
    local group = vim.api.nvim_create_augroup("pi-workspace", { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        desc = "pi: keep the tab's columns consistent after a window closes",
        callback = function(ev)
            -- WinClosed carries the closed window id only as <afile>.
            M._on_win_closed(tonumber(ev.file), vim.api.nvim_get_current_tabpage())
        end,
    })
    vim.api.nvim_create_autocmd("VimResized", {
        group = group,
        desc = "pi: re-pin the tab's columns after a resize",
        callback = function()
            for tab in pairs(states) do
                schedule_apply(tab)
            end
        end,
    })
    vim.api.nvim_create_autocmd("TabClosed", {
        group = group,
        desc = "pi: drop layout state for a closed tab",
        callback = function()
            vim.schedule(function()
                for tab in pairs(states) do
                    if not tab_valid(tab) then
                        states[tab] = nil
                        dirty[tab] = nil
                    end
                end
            end)
        end,
    })
end

--- Clear all state. Test-only.
function M._reset()
    states = {}
    dirty = {}
    scheduled = false
end

return M
