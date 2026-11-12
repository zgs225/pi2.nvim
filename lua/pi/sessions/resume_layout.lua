--- Resume picker layout: partitions `:PiResume` sessions by checkout.
---
--- Pure module (no picker, no git, no session state): feed it the collected
--- `pi.SessionSelectItem` list and it decides every row — grouping, ordering
--- and filtering. Both picker backends (telescope and `vim.ui.select`) render
--- the rows this module returns, so they can never drift apart.
---
--- Below the partition threshold the list stays exactly the historical flat
--- one (`<date>  <label>` rows in the incoming order); from two partitions up
--- each checkout gets a title row and its sessions follow underneath. The
--- threshold always counts the **unfiltered** partitions, so typing a query
--- never changes the layout mid-pick.

---@class pi.ResumeRow
---@field kind "group"|"session"
---@field partition string Absolute checkout path, or "main" for the main checkout
---@field title? string Group title (only for `kind == "group"`)
---@field worktree? boolean The group title belongs to a linked worktree
---@field item? pi.SessionSelectItem Session behind a session row
---@field text string Display text

local M = {}

local MAIN_PARTITION = "main"
local WORKTREE_ICON = "󰙅 "
--- Distinct partitions needed before the list is split into groups.
local DEFAULT_THRESHOLD = 2

--- Row text for one session: `<date>  <name|first message|(empty)>`.
---@param session pi.ResumeSessionInfo
---@return string
function M.format_session(session)
    local date = session.timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)") or session.timestamp
    local label = session.name or (session.first_message ~= "" and session.first_message or "(empty)")
    return date .. "  " .. label
end

--- Normalized checkout path used as the partition key.
---@param path any
---@return string?
local function normalize_path(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local normalized = path
    if vim and vim.fs and type(vim.fs.normalize) == "function" then
        local ok, result = pcall(vim.fs.normalize, path)
        if ok and type(result) == "string" and result ~= "" then
            normalized = result
        end
    end
    -- Trailing slashes would split one checkout into two partitions.
    normalized = normalized:gsub("/+$", "")
    return normalized ~= "" and normalized or nil
end

---@param path string
---@return string
local function basename(path)
    local name = path:gsub("/+$", ""):match("([^/]+)$")
    return name ~= nil and name ~= "" and name or path
end

--- Worktree metadata of a picker item. `:PiResume` items carry the info table
--- in `worktree` (the resume target), so accept both spellings.
---@param item pi.SessionSelectItem
---@return table?
local function worktree_info_of(item)
    if type(item.worktree_info) == "table" then
        return item.worktree_info
    end
    return type(item.worktree) == "table" and item.worktree or nil
end

--- Display name of the main checkout: the caller's repo name, else the
--- repository root named by a worktree record, else Neovim's cwd.
---@param items pi.SessionSelectItem[]
---@param repo_name? string
---@return string
local function resolve_repo_name(items, repo_name)
    if type(repo_name) == "string" and repo_name ~= "" then
        return repo_name
    end
    for _, item in ipairs(items) do
        local info = type(item) == "table" and worktree_info_of(item) or nil
        local root = info and normalize_path(info.repo_root) or nil
        if root then
            return basename(root)
        end
    end
    local cwd = normalize_path(vim.fn.getcwd())
    return cwd and basename(cwd) or MAIN_PARTITION
end

---@class pi.ResumePartition
---@field key string
---@field title string
---@field worktree boolean
---@field name? string Worktree name (nil for the main checkout)
---@field newest number Newest `modified` in the partition (unfiltered)
---@field items pi.SessionSelectItem[]

--- Partition an item belongs to: its checkout path, or "main".
---@param item pi.SessionSelectItem
---@param repo_name string
---@return string key
---@return string title
---@return boolean worktree
---@return string? name
local function partition_of(item, repo_name)
    local info = worktree_info_of(item)
    -- `kind == "main"` (or no path at all) means the main checkout: an item
    -- that only remembers the worktree *name* cannot be partitioned by path.
    if not info or info.kind == "main" then
        return MAIN_PARTITION, repo_name, false, nil
    end
    local path = normalize_path(info.path)
    if not path then
        return MAIN_PARTITION, repo_name, false, nil
    end
    local wname = info.name
    local name = (type(wname) == "string" and wname ~= "") and wname or basename(path)
    return path, WORKTREE_ICON .. name, true, name
end

--- Newest first, stable tiebreak on the session file so equal mtimes (a
--- second-resolution `getftime`) never reorder between renders.
---@param a pi.SessionSelectItem
---@param b pi.SessionSelectItem
---@return boolean
local function newer(a, b)
    local am = tonumber(a.session.modified) or 0
    local bm = tonumber(b.session.modified) or 0
    if am ~= bm then
        return am > bm
    end
    return tostring(a.file) < tostring(b.file)
end

--- Case-insensitive substring test over every haystack the row can match:
--- its own text, its partition title, the worktree name, the checkout path.
---@param needle string Lower-cased query (`""` matches everything)
---@param haystacks (string|nil)[]
---@return boolean
local function matches(needle, haystacks)
    if needle == "" then
        return true
    end
    for _, haystack in ipairs(haystacks) do
        if type(haystack) == "string" and haystack ~= "" then
            if haystack:lower():find(needle, 1, true) ~= nil then
                return true
            end
        end
    end
    return false
end

--- Build the picker rows for the collected resume items.
---@param items pi.SessionSelectItem[]
---@param opts? { query?: string, repo_name?: string, threshold?: integer }
---@return pi.ResumeRow[] rows Rows in display order (group rows are inert)
---@return integer partition_count Distinct partitions in the unfiltered set
function M.rows(items, opts)
    opts = opts or {}
    local repo_name = resolve_repo_name(items, opts.repo_name)
    local threshold = tonumber(opts.threshold) or DEFAULT_THRESHOLD
    local query = type(opts.query) == "string" and opts.query or ""
    local needle = query:lower()

    ---@type pi.ResumePartition[]
    local partitions = {}
    ---@type table<string, pi.ResumePartition>
    local by_key = {}
    --- Session rows in the incoming order, for the flat (below-threshold) list.
    ---@type { row: pi.ResumeRow, title: string, name: string? }[]
    local flat = {}

    for _, item in ipairs(items) do
        if type(item) == "table" and type(item.session) == "table" then
            local key, title, worktree, name = partition_of(item, repo_name)
            local partition = by_key[key]
            if not partition then
                partition = { key = key, title = title, worktree = worktree, name = name, newest = 0, items = {} }
                by_key[key] = partition
                partitions[#partitions + 1] = partition
            end
            partition.items[#partition.items + 1] = item
            local modified = tonumber(item.session.modified) or 0
            if modified > partition.newest then
                partition.newest = modified
            end
            flat[#flat + 1] = {
                row = { kind = "session", partition = key, item = item, text = M.format_session(item.session) },
                title = title,
                name = name,
            }
        end
    end

    local partition_count = #partitions
    ---@type pi.ResumeRow[]
    local rows = {}

    if partition_count < threshold then
        -- Historical flat list: no group rows, incoming order, unchanged text.
        for _, entry in ipairs(flat) do
            local row = entry.row
            if matches(needle, { row.text, entry.title, entry.name, row.partition }) then
                rows[#rows + 1] = row
            end
        end
        return rows, partition_count
    end

    -- Partitions keep their position while the query is typed (ordering uses
    -- the unfiltered newest mtime), so filtering only removes rows.
    table.sort(partitions, function(a, b)
        if a.newest ~= b.newest then
            return a.newest > b.newest
        end
        if a.title ~= b.title then
            return a.title < b.title
        end
        return a.key < b.key
    end)

    for _, partition in ipairs(partitions) do
        local surviving = {}
        for _, item in ipairs(partition.items) do
            local text = M.format_session(item.session)
            if matches(needle, { text, partition.title, partition.name, partition.key }) then
                surviving[#surviving + 1] = { item = item, text = text }
            end
        end
        if #surviving > 0 then
            table.sort(surviving, function(a, b)
                return newer(a.item, b.item)
            end)
            rows[#rows + 1] = {
                kind = "group",
                partition = partition.key,
                title = partition.title,
                worktree = partition.worktree,
                text = partition.title,
            }
            for _, entry in ipairs(surviving) do
                rows[#rows + 1] = {
                    kind = "session",
                    partition = partition.key,
                    item = entry.item,
                    text = entry.text,
                }
            end
        end
    end

    return rows, partition_count
end

return M
