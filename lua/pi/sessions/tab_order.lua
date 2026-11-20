--- Canonical tab order for π session tabs — one shared ordering model for
--- `:PiSessions` row grouping and every code path that opens a session tab.
---
--- The tabline is the only authority for row order: `pi.sessions.manager.list()`
--- returns the live sessions ranked by `nvim_list_tabpages()`. Worktree grouping
--- then prints the sessions of one checkout as a **contiguous block**, which is
--- a permutation of that sequence — so the block invariant can only hold if the
--- tabline is permuted the same way. This module is that half: it classifies
--- sessions into checkout blocks (`M.model`), answers where a checkout's block
--- ends (`M.anchor`), places a freshly opened tab inside its block (`M.place`),
--- and can rewrite the π tabs into the canonical sequence on request
--- (`M.reconcile`).
---
--- Rules this module pins down:
---
--- * A **block** is every session whose cwd is the same work tree (main checkout
---   included); blocks appear in **first tabline appearance** order. Sessions
---   whose cwd is not a work tree (a plain directory, no repository) form the
---   trailing ungrouped bucket.
--- * Grouping applies only from **two distinct work trees** on (a flat list keeps
---   plain tabline order), so a single-repository session list is never moved.
--- * `M.place` only ever moves the tab it is given: it is called right after a
---   session tab is created, so the pre-existing tabline is the user's layout and
---   must not be rewritten behind their back. That is `M.reconcile`'s job, and
---   only on an explicit request (`:PiSessionsSync` / `S` in the list) — Neovim
---   has no event for a user `:tabmove`, so automatic reconciliation could not
---   tell the two apart and would keep undoing deliberate reordering.
---
--- Detection is filesystem-only (`pi.worktree.detect`, no git call) and memoized
--- per directory: `:PiSessions` renders on the blink/spinner timers (every
--- 120–500 ms), so this must stay cheap. `M.reset()` drops the cache for the `R`
--- key and for tests.

local M = {}

---@class pi.SessionsListWorktree
---@field kind "main"|"linked"
---@field name string worktree directory name
---@field path string worktree root
---@field repo_root? string main checkout root (linked worktrees)

---@class pi.TabOrderGroup
---@field path string worktree root (the block's identity)
---@field info pi.SessionsListWorktree detected worktree metadata (label source)
---@field sessions pi.Session[] sessions of this checkout, input (tabline) order

---@class pi.TabOrderModel
---@field sessions pi.Session[] sessions the model was built from, input order
---@field groups pi.TabOrderGroup[] checkout blocks, first-appearance order
---@field ungrouped pi.Session[] sessions outside any work tree, input order
---@field grouped boolean rows are grouped (at least two distinct work trees)
---@field tabs pi.TabId[] canonical distinct tab sequence (reconcile target)

---@class pi.TabOrderOpts
---@field sessions? pi.Session[] session list to model (default: the live tab sessions)
---@field exclude_tab? pi.TabId tab that must not appear in the model (the tab being placed)

--- Memoized `pi.worktree.detect` per directory (`false` = known non-worktree).
---@type table<string, pi.SessionsListWorktree|false>
local worktree_cache = {}

--- Drop the cached worktree detection (new repository, `git worktree add` while
--- the list is open, and specs).
function M.reset()
    worktree_cache = {}
end

--- Detect the work tree a directory belongs to, memoized.
---@param dir string?
---@return pi.SessionsListWorktree?
function M.detect(dir)
    if type(dir) ~= "string" or dir == "" then
        return nil
    end
    local cached = worktree_cache[dir]
    if cached ~= nil then
        return cached or nil
    end
    local info = nil
    local ok, mod = pcall(require, "pi.worktree")
    if ok and type(mod) == "table" and type(mod.detect) == "function" then
        local detected = mod.detect(dir)
        if type(detected) == "table" and type(detected.path) == "string" and type(detected.name) == "string" then
            info = detected
        end
    end
    worktree_cache[dir] = info or false
    return info
end

--- Work tree of a session, keyed by its cwd (nil for non-git directories).
---@param session pi.Session?
---@return pi.SessionsListWorktree?
function M.worktree_of(session)
    local cwd = session and session.cwd
    if type(cwd) ~= "string" or cwd == "" then
        return nil
    end
    return M.detect(cwd)
end

--- The tab a session is displayed in (`tab` and `attached_tab` are aliases).
---@param session pi.Session?
---@return pi.TabId?
local function session_tab(session)
    if type(session) ~= "table" then
        return nil
    end
    local tab = session.tab or session.attached_tab
    if type(tab) == "number" and tab ~= 0 then
        return tab
    end
    return nil
end

--- Visual position of every tabpage (`nil` for a handle that is no longer a tab).
---@return table<pi.TabId, integer>
function M.rank()
    ---@type table<pi.TabId, integer>
    local rank = {}
    for index, tab in ipairs(vim.api.nvim_list_tabpages()) do
        rank[tab] = index
    end
    return rank
end

--- Sessions to model: the given list, or the live tab sessions in tabline order.
---@param opts pi.TabOrderOpts?
---@return pi.Session[]
local function sessions_of(opts)
    opts = opts or {}
    local sessions = opts.sessions
    if sessions == nil then
        sessions = require("pi.sessions.manager").list()
    end
    if opts.exclude_tab == nil then
        return sessions
    end
    ---@type pi.Session[]
    local filtered = {}
    for _, session in ipairs(sessions) do
        if session_tab(session) ~= opts.exclude_tab then
            filtered[#filtered + 1] = session
        end
    end
    return filtered
end

--- Group sessions into checkout blocks.
---
--- Group order is first appearance in the input order (tabline order for the
--- live list), nothing else: no transcript mtime, no focus-dependent pin — both
--- would move headers underneath the reader. The canonical tab sequence used by
--- `reconcile` is the block order with the ungrouped bucket last; a flat list
--- (fewer than two work trees) keeps the input order untouched.
---@param opts pi.TabOrderOpts?
---@return pi.TabOrderModel
function M.model(opts)
    local sessions = sessions_of(opts)

    ---@type table<string, pi.TabOrderGroup>
    local buckets = {}
    ---@type string[] block roots in first-appearance order
    local order = {}
    ---@type pi.Session[]
    local ungrouped = {}

    for _, session in ipairs(sessions) do
        local info = M.worktree_of(session)
        if info then
            local root = info.path
            local group = buckets[root]
            if not group then
                group = { path = root, info = info, sessions = {} }
                buckets[root] = group
                order[#order + 1] = root
            end
            group.sessions[#group.sessions + 1] = session
        else
            ungrouped[#ungrouped + 1] = session
        end
    end

    ---@type pi.TabOrderGroup[]
    local groups = {}
    for _, root in ipairs(order) do
        groups[#groups + 1] = buckets[root]
    end
    local grouped = #groups >= 2

    ---@type pi.TabId[]
    local tabs = {}
    ---@type table<pi.TabId, true>
    local seen = {}
    ---@param session pi.Session
    local function add_tab(session)
        local tab = session_tab(session)
        if tab and not seen[tab] then
            seen[tab] = true
            tabs[#tabs + 1] = tab
        end
    end
    if grouped then
        for _, group in ipairs(groups) do
            for _, session in ipairs(group.sessions) do
                add_tab(session)
            end
        end
        for _, session in ipairs(ungrouped) do
            add_tab(session)
        end
    else
        for _, session in ipairs(sessions) do
            add_tab(session)
        end
    end

    return {
        sessions = sessions,
        groups = groups,
        ungrouped = ungrouped,
        grouped = grouped,
        tabs = tabs,
    }
end

--- Last tab of a block in tabline order.
---@param group pi.TabOrderGroup
---@param rank table<pi.TabId, integer>
---@return pi.TabId?
local function block_tail(group, rank)
    local tail, tail_rank = nil, 0
    for _, session in ipairs(group.sessions) do
        local tab = session_tab(session)
        local position = tab and rank[tab] or nil
        if position and position > tail_rank then
            tail, tail_rank = tab, position
        end
    end
    return tail
end

--- Tab a session opened in `checkout` belongs after.
---
--- The anchor is the last tab of that checkout's block (grouped list), so the new
--- tab joins its block in both the list and the tabline. A checkout with no tab
--- yet is inserted after the *last existing block*, i.e. before the trailing
--- ungrouped rows — the place the list gives a newly appearing block. nil when
--- nothing should move: a flat list already prints plain tabline order, and a
--- checkout with no sibling block has no anchor at all.
---
--- The tab being placed must be excluded from the model (`opts.exclude_tab`):
--- it is already attached by the time placement runs, and counting it as its own
--- block's tail would make the anchor the tab itself.
---@param checkout string? worktree root (`pi.TabOrderModel.groups[].path`)
---@param opts pi.TabOrderOpts?
---@return pi.TabId?
function M.anchor(checkout, opts)
    if type(checkout) ~= "string" or checkout == "" then
        return nil
    end
    local model = M.model(opts)
    if not model.grouped then
        return nil
    end
    local rank = M.rank()
    for _, group in ipairs(model.groups) do
        if group.path == checkout then
            return block_tail(group, rank)
        end
    end
    local last = model.groups[#model.groups]
    return last and block_tail(last, rank) or nil
end

--- Run `fn` with autocmds suspended (`eventignore`), restoring it afterwards.
---
--- Reordering tabs moves focus, and a `TabEnter` is exactly what consumes a
--- session's unseen done/error badge and re-renders the todo panel — a placement or
--- sync pass must not mark tabs the user never looked at as seen.
---@generic T
---@param fn fun(): T
---@return T
local function ignoring_events(fn)
    local saved = vim.o.eventignore
    vim.o.eventignore = "all"
    local ok, result = pcall(fn)
    vim.o.eventignore = saved
    if not ok then
        error(result)
    end
    return result
end

--- Move `tab` to sit directly after `anchor` in the tabline.
---
--- The mechanical half of `M.place`, also used for an explicit anchor a caller
--- already resolved (`pi.WorktreeOpenOpts.tab_after`). A no-op for an invalid or
--- identical pair and when the tab already sits directly after the anchor.
--- `:tabmove N` moves the *current* tabpage to after tabpage N, so the tab is
--- focused first; it starts as the newly created (last) tabpage.
---@param tab pi.TabId?
---@param anchor pi.TabId?
---@return boolean moved
function M.move_after(tab, anchor)
    if type(tab) ~= "number" or type(anchor) ~= "number" or tab == anchor then
        return false
    end
    if not vim.api.nvim_tabpage_is_valid(tab) or not vim.api.nvim_tabpage_is_valid(anchor) then
        return false
    end
    local rank = M.rank()
    local here, there = rank[tab], rank[anchor]
    if not here or not there or here == there + 1 then
        return false
    end
    return ignoring_events(function()
        if not pcall(vim.api.nvim_set_current_tabpage, tab) then
            return false
        end
        return (pcall(vim.cmd, "tabmove " .. there))
    end)
end

--- Move the tab `tab` right after the anchor of `checkout` (`M.anchor`).
---
--- Only that one tab moves: the rest of the tabline is the user's layout and is
--- left alone (see `M.reconcile` for the explicit reordering).
---@param tab pi.TabId?
---@param checkout string?
---@param opts pi.TabOrderOpts?
---@return boolean moved
function M.place(tab, checkout, opts)
    if type(tab) ~= "number" or not vim.api.nvim_tabpage_is_valid(tab) then
        return false
    end
    opts = opts or {}
    local pole = M.anchor(checkout, { sessions = opts.sessions, exclude_tab = tab })
    if not pole then
        return false
    end
    return M.move_after(tab, pole)
end

--- Place a freshly opened session tab inside its checkout's block. The
--- convenience wrapper every creation path calls: the checkout comes from the
--- session's own cwd (worktree detection), the tab from the session.
---@param session pi.Session?
---@return boolean moved
function M.place_for(session)
    local tab = session_tab(session)
    if not tab then
        return false
    end
    local info = M.worktree_of(session)
    return M.place(tab, info and info.path or nil, { exclude_tab = tab })
end

--- Rewrite the tabline into the canonical sequence (`M.model().tabs`).
---
--- π tabs are permuted **among the slots they already occupy**, so a tab that is
--- not a π session (a plain buffer, the diff review) keeps its place; only the π
--- order inside that subsequence changes. Idempotent: a second call on a
--- canonical tabline moves nothing. Returns the number of tabs actually moved
--- (0 = already in list order).
---
--- This is an explicit user action, never automatic: Neovim has no event for
--- `:tabmove`, so an automatic pass could not distinguish a deliberate reorder
--- from drift and would keep snapping tabs back.
---@param opts pi.TabOrderOpts?
---@return integer moved
function M.reconcile(opts)
    local model = M.model(opts)
    ---@type table<pi.TabId, true>
    local wanted = {}
    for _, tab in ipairs(model.tabs) do
        wanted[tab] = true
    end

    ---@type pi.TabId[]
    local present = {}
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if wanted[tab] then
            present[#present + 1] = tab
        end
    end
    if #present ~= #model.tabs then
        -- A session outlived its tab between the two reads; not our call.
        return 0
    end

    local origin = vim.api.nvim_get_current_tabpage()
    local moved = ignoring_events(function()
        local count = 0
        for index, target in ipairs(model.tabs) do
            -- Position of the index-th π tab *now* (earlier moves shift the ones
            -- to the right), i.e. the slot the canonical tab must occupy.
            local slot, seen = nil, 0
            for position, tab in ipairs(vim.api.nvim_list_tabpages()) do
                if wanted[tab] then
                    seen = seen + 1
                    if seen == index then
                        slot = position
                        break
                    end
                end
            end
            if slot and vim.api.nvim_list_tabpages()[slot] ~= target then
                if pcall(vim.api.nvim_set_current_tabpage, target) then
                    if pcall(vim.cmd, "tabmove " .. (slot - 1)) then
                        count = count + 1
                    end
                end
            end
        end
        if vim.api.nvim_tabpage_is_valid(origin) then
            pcall(vim.api.nvim_set_current_tabpage, origin)
        end
        return count
    end)
    return moved
end

return M
