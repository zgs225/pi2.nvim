--- pi.ui.sidebar — side-panel registry and stacking math.
---
--- Side panels (sessions list, todo panel, tasks panel) each open a window in a
--- tab's side column. When several panels share an edge they must share that
--- column instead of opening competing ones: this module is the registry —
--- panels claim an edge when their window is placed and release it when it
--- closes, and every claim/release restacks the edge, dividing the
--- perpendicular dimension (height for left/right columns, width for top/bottom
--- rows) among the registered windows proportionally to their weights.
---
--- `pi.ui.workspace` owns *where* the windows go (the column's existence, its
--- width, the chat column next to it) and calls into this module for the
--- registry and the stacking pass; this file never creates, moves or closes a
--- window.
---
--- Float windows never stack and must not claim. The column/row size along the
--- edge (width for left/right, height for top/bottom) is owned by the opening
--- panel's config — restack only adjusts the perpendicular dimension.
local M = {}

---@alias pi.SidebarEdge "left"|"right"|"top"|"bottom"

---@class pi.SidebarPanel
---@field key string panel identifier ("sessions" | "todo" | "tasks")
---@field win integer panel window
---@field weight number share of the perpendicular dimension (default 1)
---@field edge pi.SidebarEdge
---@field tab integer
---@field seq integer claim sequence (stable sort tiebreak for unknown keys)
---@field order number effective stacking order (ORDER map or opts.order)
---@field width? number width spec the column was opened with (fraction when < 1)

--- Fixed stacking order within an edge; unknown keys sort last, by claim order.
--- Sessions top the left column; on the right the tasks panel sits above the
--- todo checklist. Unknown keys sort last, by claim order.
local ORDER = { sessions = 1, tasks = 2, todo = 3 }

local VALID_EDGES = { left = true, right = true, top = true, bottom = true }

---@type table<integer, table<string, pi.SidebarPanel[]>> tab -> edge -> panels
local registry = {}

---@type integer
local seq = 0

--- Tabline rows currently on screen (mirrors `pi.ui.chat.zen`).
---@return integer
local function tabline_height()
    local stl = vim.o.showtabline
    if stl == 2 then
        return 1
    end
    if stl == 1 and #vim.api.nvim_list_tabpages() > 1 then
        return 1
    end
    return 0
end

--- Rows consumed by statuslines for `n` stacked windows. `laststatus=1` draws
--- a single statusline for the whole tab, `3` one global statusline.
---@param n integer
---@return integer
local function statusline_rows(n)
    local ls = vim.o.laststatus
    if ls == 0 then
        return 0
    end
    if ls >= 2 and ls ~= 3 then
        return n
    end
    return 1
end

--- Window lines available to a column of `n` stacked windows: the editor
--- minus the command line, the tabline and the statuslines the stacked windows
--- themselves consume. Getting this wrong by one row per stacked window makes
--- Neovim squeeze the column (observed: a two-panel column asking for 27 rows
--- in a 26-row budget, one panel ending up a line shorter than its neighbour).
---@param n integer
---@return integer
function M.height_budget(n)
    local total = vim.o.lines - vim.o.cmdheight - tabline_height() - statusline_rows(n)
    return math.max(n, total)
end

--- Resolve the edge a panel should stack at. Panel configs keep the edge in
--- their `position` field ("left"/"right"/"top"/"bottom"); the layout *mode*
--- ("follow"/"side"/"float") decides side-vs-float upstream and is not an
--- edge. Anything unexpected falls back to "left".
---@param tab integer unused in this version, kept for future per-tab layout
---@param position string?
---@return pi.SidebarEdge
function M.effective_edge(tab, position)
    if type(position) == "string" and VALID_EDGES[position] then
        return position
    end
    return "left"
end

--- Stacking order of a panel key (unknown keys sort last).
---@param key string
---@return number
function M.order_of(key)
    return ORDER[key] or math.huge
end

--- Distribute `total` proportionally to `weights`, each at least 1 line/col,
--- remainder spread front-to-back deterministically. When total < #weights
--- every entry still gets its minimum (the column overflows; the caller's
--- windows get squeezed by Neovim, which is the best we can do).
---@param total integer
---@param weights number[]
---@return integer[]
function M.distribute(total, weights)
    local n = #weights
    local sum = 0
    for _, w in ipairs(weights) do
        sum = sum + w
    end
    if sum <= 0 then
        sum = n
    end

    local sizes = {}
    local acc = 0
    for i, w in ipairs(weights) do
        local sz = math.floor(total * w / sum)
        if sz < 1 then
            sz = 1
        end
        sizes[i] = sz
        acc = acc + sz
    end

    local guard = 0
    local i = 1
    while acc < total and guard < total * 2 do
        sizes[i] = sizes[i] + 1
        acc = acc + 1
        i = i % n + 1
        guard = guard + 1
    end
    guard = 0
    i = 1
    while acc > total and guard < total * 2 do
        if sizes[i] > 1 then
            sizes[i] = sizes[i] - 1
            acc = acc - 1
        end
        i = i % n + 1
        guard = guard + 1
    end
    return sizes
end

---@param panels pi.SidebarPanel[]
---@return pi.SidebarPanel[]
local function sorted(panels)
    local copy = {}
    for i, p in ipairs(panels) do
        copy[i] = p
    end
    table.sort(copy, function(a, b)
        local oa = a.order or ORDER[a.key] or math.huge
        local ob = b.order or ORDER[b.key] or math.huge
        if oa ~= ob then
            return oa < ob
        end
        return a.seq < b.seq
    end)
    return copy
end

--- Drop entries whose window is gone.
---@param panels pi.SidebarPanel[]
---@return pi.SidebarPanel[]
local function prune(panels)
    local alive = {}
    for _, p in ipairs(panels) do
        if p.win and vim.api.nvim_win_is_valid(p.win) then
            alive[#alive + 1] = p
        end
    end
    return alive
end

--- Registered panels at tab+edge, in stacking order. Dead windows are pruned
--- from the registry as a side effect (an externally closed panel window must
--- not keep owning the column width).
---@param tab integer
---@param edge pi.SidebarEdge
---@return pi.SidebarPanel[]
function M.panels(tab, edge)
    local by_edge = registry[tab]
    if not by_edge or not by_edge[edge] then
        return {}
    end
    local alive = prune(by_edge[edge])
    if #alive == 0 then
        by_edge[edge] = nil
        return {}
    end
    by_edge[edge] = alive
    return sorted(alive)
end

--- The panel registered on `edge` under `key`, or nil.
---@param tab integer
---@param key string
---@return pi.SidebarPanel?
function M.panel(tab, edge, key)
    for _, p in ipairs(M.panels(tab, edge)) do
        if p.key == key then
            return p
        end
    end
    return nil
end

--- The live window of the panel registered under `key` in any edge of `tab`.
---@param tab integer
---@param key string
---@return integer?
function M.panel_win(tab, key)
    local by_edge = registry[tab]
    if not by_edge then
        return nil
    end
    for _, panels in pairs(by_edge) do
        for i = #panels, 1, -1 do
            local p = panels[i]
            if not vim.api.nvim_win_is_valid(p.win) then
                table.remove(panels, i)
            elseif p.key == key then
                return p.win
            end
        end
    end
    return nil
end

--- The key owning `win` in any edge of `tab`, or nil when the window is not a
--- registered panel (or already gone).
---@param tab integer
---@param win integer?
---@return string?
function M.panel_key(tab, win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return nil
    end
    local by_edge = registry[tab]
    if not by_edge then
        return nil
    end
    for edge, panels in pairs(by_edge) do
        for i = #panels, 1, -1 do
            local p = panels[i]
            if not vim.api.nvim_win_is_valid(p.win) then
                table.remove(panels, i)
                if #panels == 0 then
                    by_edge[edge] = nil
                end
            elseif p.win == win then
                return p.key
            end
        end
    end
    return nil
end

--- The width spec the column at `edge` was opened with: the first panel in
--- stacking order that named one. A column exists only while a panel owns it,
--- so its width belongs to that panel (`sessions_list.width` for the left
--- column, `tasks_panel.width` for the right one, `todo.panel.width` when the
--- todo panel opens a column alone).
---@param tab integer
---@param edge pi.SidebarEdge
---@return number?
function M.width_spec(tab, edge)
    local by_edge = registry[tab]
    if not by_edge or not by_edge[edge] then
        return nil
    end
    for _, p in ipairs(M.panels(tab, edge)) do
        if type(p.width) == "number" then
            return p.width
        end
    end
    return nil
end

--- Recompute geometry for every panel registered at tab+edge.
--- Vertical edges: divide the column height among windows (each stacked
--- window costs one statusline row); set winfixheight. Horizontal edges: divide
--- the full editor width among windows (vsplits abut without separator
--- columns); set winfixwidth.
---@param tab integer
---@param edge pi.SidebarEdge
function M.restack(tab, edge)
    local by_edge = registry[tab]
    if not by_edge or not by_edge[edge] then
        return
    end
    local panels = prune(by_edge[edge])
    by_edge[edge] = panels
    if #panels == 0 then
        return
    end
    panels = sorted(panels)
    by_edge[edge] = panels

    local n = #panels
    local weights = {}
    for i, p in ipairs(panels) do
        weights[i] = p.weight or 1
    end

    local vertical = edge == "left" or edge == "right"
    local total
    if vertical then
        total = M.height_budget(n)
    else
        total = vim.o.columns - (n - 1)
        total = math.max(n, total)
    end

    local sizes = M.distribute(total, weights)
    -- Pin the perpendicular dimension only while actually sharing the edge:
    -- a sole panel keeps its natural size without a winfix pin, so a
    -- standalone column window stays height-flexible (and a panel left
    -- alone after a sibling closes is unpinned again).
    local pin = n >= 2
    for i, p in ipairs(panels) do
        if vim.api.nvim_win_is_valid(p.win) then
            if vertical then
                pcall(vim.api.nvim_win_set_height, p.win, sizes[i])
                pcall(function()
                    vim.wo[p.win].winfixheight = pin
                end)
            else
                pcall(vim.api.nvim_win_set_width, p.win, sizes[i])
                pcall(function()
                    vim.wo[p.win].winfixwidth = pin
                end)
            end
        end
    end
end

---@class pi.SidebarClaimOpts
---@field weight? number share of the perpendicular dimension (default 1)
---@field order? number stacking order override (default: the ORDER map)
---@field width? number width spec the panel opens the column with (fraction when < 1)

--- Register a panel window at an edge and restack. Re-claiming an existing
--- key replaces its previous registration (idempotent). `opts.order`
--- overrides the fixed ORDER map for this panel; `opts.width` is the column
--- width spec the panel opened the column with.
---@param tab integer
---@param edge pi.SidebarEdge
---@param key string
---@param win integer
---@param opts? pi.SidebarClaimOpts
function M.claim(tab, edge, key, win, opts)
    if not (win and vim.api.nvim_win_is_valid(win)) then
        return
    end
    edge = M.effective_edge(tab, edge)
    registry[tab] = registry[tab] or {}
    local by_edge = registry[tab]

    -- Drop any previous registration of this key (any edge of this tab).
    for e, panels in pairs(by_edge) do
        for i = #panels, 1, -1 do
            if panels[i].key == key then
                table.remove(panels, i)
                if #panels == 0 then
                    by_edge[e] = nil
                end
            end
        end
    end

    seq = seq + 1
    by_edge[edge] = by_edge[edge] or {}
    table.insert(by_edge[edge], {
        key = key,
        win = win,
        weight = (opts and opts.weight) or 1,
        edge = edge,
        tab = tab,
        seq = seq,
        order = (opts and opts.order) or ORDER[key] or math.huge,
        width = opts and opts.width or nil,
    })
    M.restack(tab, edge)
end

--- Unregister a panel by key and restack its former edge. Unknown keys are
--- a no-op.
---@param tab integer
---@param key string
function M.release(tab, key)
    local by_edge = registry[tab]
    if not by_edge then
        return
    end
    for edge, panels in pairs(by_edge) do
        for i = #panels, 1, -1 do
            if panels[i].key == key then
                table.remove(panels, i)
                if #panels == 0 then
                    by_edge[edge] = nil
                else
                    M.restack(tab, edge)
                end
                return
            end
        end
    end
end

--- Unregister whichever panel owns `win` and restack its edge. Used when a
--- panel window is closed by something other than its own `close()`.
---@param tab integer
---@param win integer
function M.release_win(tab, win)
    local key = M.panel_key(tab, win)
    if key then
        M.release(tab, key)
    end
end

--- Whether `win` is a registered side-panel window (sessions list, todo or
--- tasks panel) in any tab. The chat's side-column anchor uses it to keep its
--- own column out of a panel frame.
---@param win integer?
---@return boolean
function M.is_panel(win)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return false
    end
    for _, by_edge in pairs(registry) do
        for _, panels in pairs(by_edge) do
            for _, p in ipairs(panels) do
                if p.win == win and vim.api.nvim_win_is_valid(p.win) then
                    return true
                end
            end
        end
    end
    return false
end

--- Clear all state. Test-only.
function M._reset()
    registry = {}
    seq = 0
end

return M
