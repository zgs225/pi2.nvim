--- pi.ui.sidebar — side-panel stacking coordinator.
---
--- Side panels (sessions list, todo panel, tasks panel) each open their own
--- `topleft/botright` split at a configured edge. When several panels share
--- an edge they must share that edge's space instead of opening competing
--- columns. This module is the registry: panels claim an edge when they
--- open a side window and release it when they close; every claim/release
--- restacks the edge, dividing the perpendicular dimension (height for
--- left/right columns, width for top/bottom rows) among the registered
--- windows proportionally to their weights.
---
--- Float windows never stack and must not claim. The column/row size along
--- the edge (width for left/right, height for top/bottom) is owned by the
--- opening panel's own config — restack only adjusts the perpendicular
--- dimension.
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

--- Fixed stacking order within an edge; unknown keys sort last, by claim order.
local ORDER = { sessions = 1, todo = 2, tasks = 3 }

local VALID_EDGES = { left = true, right = true, top = true, bottom = true }

---@type table<integer, table<string, pi.SidebarPanel[]>> tab -> edge -> panels
local registry = {}

---@type integer
local seq = 0

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

--- Distribute `total` proportionally to `weights`, each at least 1 line/col,
--- remainder spread front-to-back deterministically. When total < #weights
--- every entry still gets its minimum (the column overflows; the caller's
--- windows get squeezed by Neovim, which is the best we can do).
---@param total integer
---@param weights number[]
---@return integer[]
local function distribute(total, weights)
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

--- Recompute geometry for every panel registered at tab+edge.
--- Vertical edges: divide the column height among windows (each stacked
--- window costs one statusline row, so the budget is lines - cmdheight - N);
--- set winfixheight. Horizontal edges: divide the full editor width among
--- windows (vsplits abut without separator columns); set winfixwidth.
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

    -- Each stacked window costs one statusline row (verified across
    -- laststatus 0-3); side-by-side vsplits additionally lose one separator
    -- column per adjacent pair.
    local vertical = edge == "left" or edge == "right"
    local total
    if vertical then
        total = vim.o.lines - vim.o.cmdheight - n
    else
        total = vim.o.columns - (n - 1)
    end
    total = math.max(n, total)

    local sizes = distribute(total, weights)
    for i, p in ipairs(panels) do
        if vim.api.nvim_win_is_valid(p.win) then
            if vertical then
                pcall(vim.api.nvim_win_set_height, p.win, sizes[i])
                pcall(function()
                    vim.wo[p.win].winfixheight = true
                end)
            else
                pcall(vim.api.nvim_win_set_width, p.win, sizes[i])
                pcall(function()
                    vim.wo[p.win].winfixwidth = true
                end)
            end
        end
    end
end

--- Register a panel window at an edge and restack. Re-claiming an existing
--- key replaces its previous registration (idempotent). `opts.order`
--- overrides the fixed ORDER map for this panel.
---@param tab integer
---@param edge pi.SidebarEdge
---@param key string
---@param win integer
---@param opts? { weight?: number, order?: number }
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

--- Registered panels at tab+edge, in stacking order. Test/introspection use.
---@param tab integer
---@param edge pi.SidebarEdge
---@return pi.SidebarPanel[]
function M.panels(tab, edge)
    local by_edge = registry[tab]
    if not by_edge or not by_edge[edge] then
        return {}
    end
    return sorted(prune(by_edge[edge]))
end

--- Clear all state. Test-only.
function M._reset()
    registry = {}
    seq = 0
end

return M
