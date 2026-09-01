--- Session diff review (:PiDiff) — review every file the current session
--- changed, as one unified `git diff`.
---
--- One outer float is the review panel: a shared border, title and
--- background frame two inner borderless floats — the file list on the left
--- (`pi-diff-review` filetype) and the selected file's diff on the right
--- (`diff` filetype, native syntax highlighting). Moving the cursor in the
--- list shows that file's diff; <CR>/o jumps to the file and line under the
--- cursor, q closes. Untracked files are shown as full-file additions (git's
--- no-index mode). Geometry comes from the `diff_review` config.

local M = {}

local Config = require("pi.config")
local Ft = require("pi.filetypes")
local Highlights = require("pi.ui.highlights")

local ns = vim.api.nvim_create_namespace("pi-diff-review")

---@type integer? outer container float (border/title)
local shell_win = nil
local shell_buf = nil
---@type integer? diff float (selected file)
local win = nil
local buf = nil
---@type integer? file-list float
local list_win = nil
local list_buf = nil
---@type pi.DiffReviewSection[] collected sections (list row = index + 1)
local sections = {}
---@type integer index of the section shown in the float
local current_idx = 1
---@type integer number of changed files skipped (outside the git repo)
local skipped_outside = 0
---@type table<integer, { path: string, line: integer }> jump target per float buffer line
local jump_targets = {}
---@type pi.DiffReviewGroup[] ordered groups (display order)
local groups = {}
---@type table<string, string> work tree root -> display label
local toplevel_branch = {}
---@type table<integer, { group: integer, section: integer? }> list row (1-based) -> entry; header rows point at their group's first section
local row_entries = {}

--- Forward-declared (defined in the Jump section): <CR>/o handlers.
local jump_to_target
local list_jump

---@class pi.DiffReviewSection
---@field path string Display path (relative to the work tree root).
---@field abs string Absolute path used for jumping.
---@field toplevel string Work tree root the file lives in.
---@field deleted boolean Whether the file was deleted (no jump target).
---@field status "A"|"M"|"D" File status shown in the list (added/modified/deleted).
---@field body string[] Diff body lines (everything after the `diff --git` header).

---@class pi.DiffReviewGroup
---@field toplevel string Work tree root.
---@field branch string Display label (branch name, short HEAD, or toplevel basename).
---@field rel_files string[] Changed-file paths relative to the work tree root.
---@field abs_files string[] Absolute changed-file paths.
---@field sections integer[] Indices into the flat `sections` list (1-based).

--- Diff context (lines of surrounding context per hunk). Mirrors the
--- pre-execution diff review: `'diffopt' context:` wins, default 6.
---@return integer
local function diff_context()
    for _, item in ipairs(vim.split(vim.go.diffopt, ",", { plain = true, trimempty = true })) do
        local value = item:match("^context:(%d+)$")
        if value then
            local n = tonumber(value)
            if n then
                return n
            end
        end
    end
    return 6
end

---@param value number
---@param available integer
---@return integer
local function resolve_dimension(value, available)
    if value < 1 then
        return math.max(1, math.floor(available * value))
    end
    return math.max(1, math.floor(value))
end

-- Pure parsing (unit-tested) ------------------------------------------------

--- Split raw `git diff` output into per-file sections.
--- The `diff --git a/... b/...` header line becomes the section itself;
--- everything after it (index / --- / +++ / @@ / ± lines) goes into `body`.
--- `a/dev/null` means the file is new, `b/dev/null` means deleted.
---@param output string Raw `git diff` output.
---@return pi.DiffReviewSection[]
function M.parse_sections(output)
    ---@type pi.DiffReviewSection[]
    local sections = {}
    local current = nil
    for _, line in ipairs(vim.split(output or "", "\n", { plain = true })) do
        local a_path, b_path = line:match("^diff %-%-git a/(.*) b/(.*)$")
        if a_path then
            local deleted = b_path == "/dev/null"
            local display = deleted and a_path or b_path
            current = {
                path = display,
                abs = vim.fn.fnamemodify(display, ":p"),
                deleted = deleted,
                status = "M",
                body = {},
            }
            sections[#sections + 1] = current
        elseif current then
            -- Deletions keep the same path on both sides of `diff --git`;
            -- the `+++ b/dev/null` body line marks them.
            if line == "+++ b/dev/null" then
                current.deleted = true
                current.status = "D"
            elseif vim.startswith(line, "new file mode") then
                current.status = "A"
            elseif vim.startswith(line, "deleted file mode") then
                current.deleted = true
                current.status = "D"
            end
            current.body[#current.body + 1] = line
        end
    end
    -- Drop the empty line left by the trailing newline of the output.
    for _, section in ipairs(sections) do
        while #section.body > 0 and section.body[#section.body] == "" do
            section.body[#section.body] = nil
        end
    end
    return sections
end

--- Map each body line to the line number it refers to in the new file.
--- Walk the `@@ -a,b +c,d @@` hunk headers: an added (`+`) or context (` `)
--- line advances the counter, a removed (`-`) line keeps it (the deletion
--- point). Lines before the first hunk (index / --- / +++ / new file mode)
--- are not mapped. Non-hunk metadata lines (`\ No newline at end of file`)
--- keep the current counter.
---@param body string[] Section body lines (see pi.DiffReviewSection.body).
---@return table<integer, integer> body line index (1-based) -> new-file line
function M.compute_hunk_lines(body)
    ---@type table<integer, integer>
    local out = {}
    local new_line = nil
    for i, line in ipairs(body) do
        local start = line:match("^@@ .- %+(%d+)")
        if start then
            new_line = tonumber(start)
            out[i] = new_line
        elseif new_line then
            out[i] = new_line
            local prefix = line:sub(1, 1)
            if prefix == "+" or prefix == " " then
                new_line = new_line + 1
            end
        end
    end
    return out
end

--- Resolve session-relative changed-file paths to absolute, anchored at the
--- session's working directory (the cwd the pi process inherited at spawn).
--- Symlinks are resolved so the result can be prefix-matched against the
--- canonical work tree root `git rev-parse` returns.
---@param files string[] raw paths from changed_files
---@param base string session cwd
---@return string[]
local function resolve_abs_paths(files, base)
    local out = {}
    for _, f in ipairs(files) do
        if vim.startswith(f, "/") then
            out[#out + 1] = vim.fn.resolve(f)
        else
            out[#out + 1] = vim.fn.resolve(vim.fn.simplify(base .. "/" .. f))
        end
    end
    return out
end

--- Order groups for display: the work tree containing `home` (the session cwd)
--- first, the rest sorted by toplevel path.
---@param by_tl table<string, pi.DiffReviewGroup>
---@param tls string[]
---@param home string
---@return pi.DiffReviewGroup[]
local function order_groups(by_tl, tls, home)
    local home_tl = nil
    for _, tl in ipairs(tls) do
        if home == tl or vim.startswith(home, tl .. "/") then
            home_tl = tl
            break
        end
    end
    table.sort(tls, function(a, b)
        if home_tl then
            if a == home_tl then
                return true
            end
            if b == home_tl then
                return false
            end
        end
        return a < b
    end)
    local ordered = {}
    for _, tl in ipairs(tls) do
        ordered[#ordered + 1] = by_tl[tl]
    end
    return ordered
end

--- Close the float window and wipe its buffer.
local function close_float()
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, false)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    win = nil
    buf = nil
end

--- Close the list window and wipe its buffer.
local function close_list()
    if list_win and vim.api.nvim_win_is_valid(list_win) then
        pcall(vim.api.nvim_win_close, list_win, false)
    end
    if list_buf and vim.api.nvim_buf_is_valid(list_buf) then
        pcall(vim.api.nvim_buf_delete, list_buf, { force = true })
    end
    list_win = nil
    list_buf = nil
end

--- Close the outer container float and wipe its buffer.
local function close_shell()
    if shell_win and vim.api.nvim_win_is_valid(shell_win) then
        pcall(vim.api.nvim_win_close, shell_win, false)
    end
    if shell_buf and vim.api.nvim_buf_is_valid(shell_buf) then
        pcall(vim.api.nvim_buf_delete, shell_buf, { force = true })
    end
    shell_win = nil
    shell_buf = nil
end

-- Rendering -----------------------------------------------------------------

---@param path string
---@param width integer
---@return string
local function header_line(path, width)
    local left = "── "
    local left_w = vim.fn.strdisplaywidth(left)
    local path_w = vim.fn.strdisplaywidth(path)
    local budget = width - left_w - 2
    if path_w > budget then
        return left .. vim.fn.strcharpart(path, 0, math.max(1, budget - 1)) .. "…"
    end
    local fill = string.rep("─", math.max(1, budget - path_w))
    return left .. path .. " " .. fill
end

--- Build the float lines for one section: the file header plus the diff body.
---@param section pi.DiffReviewSection
---@param width integer
---@param label string Display label (path, branch-prefixed when several work trees)
---@return string[]
---@return table<integer, { path: string, line: integer }>
local function build_file_lines(section, width, label)
    ---@type string[]
    local lines = { header_line(label, width) }
    ---@type table<integer, { path: string, line: integer }>
    local targets = {}
    if not section.deleted then
        targets[1] = { path = section.abs, line = 1 }
    end
    local hunk_lines = M.compute_hunk_lines(section.body)
    for i, body_line in ipairs(section.body) do
        lines[#lines + 1] = body_line
        local new_line = hunk_lines[i]
        if new_line and not section.deleted then
            targets[#lines] = { path = section.abs, line = new_line }
        end
    end
    return lines, targets
end

--- List line for a work tree group header: `branch · ~/path/to/worktree`.
---@param group pi.DiffReviewGroup
---@return string
local function group_header_line(group)
    local path = vim.fn.fnamemodify(group.toplevel, ":~")
    return group.branch .. " · " .. path
end

--- Build the file list: the hint line, then per group a header line followed
--- by its sections. Returns a row map (1-based list row -> entry) so header
--- rows behave like their group's first section for follow/jump.
---@param groups pi.DiffReviewGroup[]
---@param sections pi.DiffReviewSection[]
---@return string[] lines
---@return table<integer, { group: integer, section: integer? }>
local function build_list_layout(groups, sections)
    local count = #sections
    local hint = string.format("─ %d file%s · <CR> jump · q close", count, count == 1 and "" or "s")
    if #groups > 1 then
        hint = hint .. string.format(" · %d worktrees", #groups)
    end
    if skipped_outside > 0 then
        hint = hint .. string.format(" · %d outside", skipped_outside)
    end
    ---@type string[]
    local lines = { hint }
    ---@type table<integer, { group: integer, section: integer? }>
    local map = {}
    if #groups == 0 then
        for i, section in ipairs(sections) do
            lines[#lines + 1] = section.status .. " " .. section.path
            map[#lines] = { group = 1, section = i }
        end
        return lines, map
    end
    for gi, group in ipairs(groups) do
        if gi > 1 then
            -- Blank separator between work tree groups (not mapped: the
            -- cursor on it keeps the current file).
            lines[#lines + 1] = ""
        end
        lines[#lines + 1] = group_header_line(group)
        map[#lines] = { group = gi, section = group.sections[1] }
        for _, si in ipairs(group.sections) do
            lines[#lines + 1] = sections[si].status .. " " .. sections[si].path
            map[#lines] = { group = gi, section = si }
        end
    end
    return lines, map
end

---@param section pi.DiffReviewSection
---@return string highlight group for the status letter
local function status_hl(section)
    if section.status == "A" then
        return "PiDiffAddSign"
    end
    if section.status == "D" then
        return "PiDiffDeleteSign"
    end
    return "PiDiffReviewFile"
end

--- Fill the list buffer (hint line, group headers, status letters).
local function render_list()
    if not list_buf or not vim.api.nvim_buf_is_valid(list_buf) then
        return
    end
    local lines, map = build_list_layout(groups, sections)
    row_entries = map
    vim.bo[list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
    vim.bo[list_buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(list_buf, ns, 0, 0, { hl_group = "PiDiffReviewHint", end_col = #lines[1] })
    for row, entry in pairs(map) do
        local section = entry.section and sections[entry.section]
        local hl = section and status_hl(section) or "PiDiffReviewWorktree"
        vim.api.nvim_buf_set_extmark(
            list_buf,
            ns,
            row - 1,
            0,
            { hl_group = hl, end_col = section and 1 or #lines[row] }
        )
    end
end

--- Show the diff of the section at `idx` in the float.
---@param idx integer 1-based section index
function M._show_file(idx)
    if idx < 1 or idx > #sections then
        return
    end
    current_idx = idx
    if not win or not vim.api.nvim_win_is_valid(win) or not buf or not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local section = sections[idx]
    local width = vim.api.nvim_win_get_width(win)
    local label = section.path
    if #groups > 1 then
        local branch = toplevel_branch[section.toplevel]
        if branch and branch ~= "" then
            label = branch .. " · " .. section.path
        end
    end
    local lines, targets = build_file_lines(section, width, label)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { hl_group = "PiDiffReviewFile", end_col = #lines[1] })
    jump_targets = targets
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
end

--- List cursor moved: follow the selection into the float.
--- Factored out of the CursorMoved autocmd so tests can call it directly
--- (headless -l mode does not dispatch CursorMoved, see G4).
local function on_list_cursor_moved()
    if not list_win or not vim.api.nvim_win_is_valid(list_win) then
        return
    end
    local entry = row_entries[vim.api.nvim_win_get_cursor(list_win)[1]]
    local idx = entry and entry.section or nil
    if idx and idx >= 1 and idx <= #sections and idx ~= current_idx then
        M._show_file(idx)
    end
end

--- Scroll the diff float from the file list (normal-mode motion in the
--- float's context), keeping focus in the list.
---@param keys string normal-mode keys, e.g. "<C-f>"
function M._scroll_diff(keys)
    if not win or not vim.api.nvim_win_is_valid(win) then
        return
    end
    local lhs = vim.api.nvim_replace_termcodes(keys, true, false, true)
    vim.api.nvim_win_call(win, function()
        vim.cmd("silent normal! " .. lhs)
    end)
end

--- Open the review panel: one outer float (border/title/background) framing
--- two inner borderless floats — the file list and the selected file's diff.
--- All three share the PiFloat background, so the panel reads as one UI.
local function open_review_windows()
    local cfg = Config.options.diff_review
    local list_cfg = cfg.list
    local total_w = resolve_dimension(cfg.width, vim.o.columns)
    local total_h = resolve_dimension(cfg.height, vim.o.lines - vim.o.cmdheight - 1)
    local list_w = math.max(10, math.floor(list_cfg.width))
    local inner_h = math.max(1, total_h - 2)
    local diff_w = math.max(10, total_w - 2 - list_w - 1)
    local col0 = math.floor((vim.o.columns - total_w) / 2)
    local row0 = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - 1 - total_h) / 2))

    -- Outer container: draws the panel border/title and the shared background.
    -- zindex below the inner floats (default 50): in Neovim, a
    -- focusable=false float draws above focusable=true floats with the same
    -- zindex, which would make the container cover (and hide) the diff float.
    local sb = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(sb, "pi://diff-review")
    vim.bo[sb].buftype = "nofile"
    vim.bo[sb].bufhidden = "wipe"
    vim.bo[sb].swapfile = false
    vim.bo[sb].buflisted = false
    vim.bo[sb].filetype = Ft.diff_review
    local sw = vim.api.nvim_open_win(sb, false, {
        relative = "editor",
        width = total_w,
        height = total_h,
        col = col0,
        row = row0,
        style = "minimal",
        focusable = false,
        zindex = 40,
        border = cfg.border or "rounded",
        title = " diff review ",
        title_pos = "center",
    })
    vim.wo[sw].winfixbuf = true
    vim.wo[sw].winhighlight = Highlights.DIFF_REVIEW_WINHIGHLIGHT
    shell_win = sw
    shell_buf = sb

    -- File list (left) and diff (right), borderless, inside the container.
    local list_col = col0 + 1
    local diff_col = col0 + 1 + list_w + 1
    if list_cfg.position == "right" then
        list_col, diff_col = diff_col, list_col
    end

    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, "pi://diff-review-files")
    vim.bo[b].buftype = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].swapfile = false
    vim.bo[b].buflisted = false
    vim.bo[b].filetype = Ft.diff_review
    vim.bo[b].modifiable = false
    local w = vim.api.nvim_open_win(b, true, {
        relative = "editor",
        width = list_w,
        height = inner_h,
        col = list_col,
        row = row0 + 1,
        style = "minimal",
        border = "none",
    })
    vim.wo[w].wrap = false
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].signcolumn = "no"
    vim.wo[w].foldcolumn = "0"
    vim.wo[w].foldenable = false
    vim.wo[w].spell = false
    vim.wo[w].cursorline = true
    vim.wo[w].winfixbuf = true
    vim.wo[w].winhighlight = "NormalFloat:PiFloat"
    list_win = w
    list_buf = b

    local db = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(db, "pi://diff-review-diff")
    vim.bo[db].buftype = "nofile"
    vim.bo[db].bufhidden = "wipe"
    vim.bo[db].swapfile = false
    vim.bo[db].buflisted = false
    vim.bo[db].filetype = "diff"
    vim.bo[db].modifiable = false
    local dw = vim.api.nvim_open_win(db, true, {
        relative = "editor",
        width = diff_w,
        height = inner_h,
        col = diff_col,
        row = row0 + 1,
        style = "minimal",
        border = "none",
    })
    vim.wo[dw].cursorline = true
    vim.wo[dw].number = false
    vim.wo[dw].relativenumber = false
    vim.wo[dw].signcolumn = "no"
    vim.wo[dw].foldcolumn = "0"
    vim.wo[dw].foldenable = false
    vim.wo[dw].spell = false
    vim.wo[dw].winfixbuf = true
    vim.wo[dw].winhighlight = "NormalFloat:PiFloat"
    win = dw
    buf = db

    vim.keymap.set("n", "q", M.close, { buffer = db, nowait = true, desc = "Close diff review" })
    vim.keymap.set("n", "<CR>", jump_to_target, { buffer = db, nowait = true, desc = "Jump to file" })
    vim.keymap.set("n", "o", jump_to_target, { buffer = db, nowait = true, desc = "Jump to file" })
end

--- Render the collected sections into the review panel: outer container
--- float framing the file list and the diff of the first file.
--- Closes any existing review first.
---@param rendered pi.DiffReviewSection[]
---@param opts? { skipped?: integer, groups?: pi.DiffReviewGroup[] } skipped: changed files outside any git work tree; groups: ordered work-tree groups (empty for a flat list)
function M.render(rendered, opts)
    opts = opts or {}
    M.close()
    sections = rendered
    current_idx = 1
    skipped_outside = opts.skipped or 0
    groups = opts.groups or {}
    toplevel_branch = {}
    for _, group in ipairs(groups) do
        toplevel_branch[group.toplevel] = group.branch
    end

    open_review_windows()
    render_list()
    M._show_file(1)
    -- The diff float takes focus on open; hand it back to the file list.
    pcall(vim.api.nvim_set_current_win, list_win)

    vim.keymap.set("n", "q", M.close, { buffer = list_buf, nowait = true, desc = "Close diff review" })
    vim.keymap.set("n", "<CR>", list_jump, { buffer = list_buf, nowait = true, desc = "Jump to file" })
    vim.keymap.set("n", "o", list_jump, { buffer = list_buf, nowait = true, desc = "Jump to file" })
    vim.keymap.set("n", "<C-f>", function()
        M._scroll_diff("<C-f>")
    end, { buffer = list_buf, nowait = true, desc = "Scroll diff forward" })
    vim.keymap.set("n", "<C-b>", function()
        M._scroll_diff("<C-b>")
    end, { buffer = list_buf, nowait = true, desc = "Scroll diff backward" })
    vim.keymap.set("n", "<C-d>", function()
        M._scroll_diff("<C-d>")
    end, { buffer = list_buf, nowait = true, desc = "Scroll diff half page down" })
    vim.keymap.set("n", "<C-u>", function()
        M._scroll_diff("<C-u>")
    end, { buffer = list_buf, nowait = true, desc = "Scroll diff half page up" })
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = list_buf,
        callback = on_list_cursor_moved,
    })
    -- Closing any of the three windows closes the whole review.
    for _, w in ipairs({ shell_win, list_win, win }) do
        vim.api.nvim_create_autocmd("WinClosed", {
            pattern = tostring(w),
            once = true,
            callback = M.close,
        })
    end

    -- Land the cursor on the first file row.
    pcall(vim.api.nvim_win_set_cursor, list_win, { 2, 0 })
end

---@return boolean
function M.is_open()
    return shell_win ~= nil and vim.api.nvim_win_is_valid(shell_win)
end

---@return integer? the diff float window handle when the review is open
function M._float_win()
    if win and vim.api.nvim_win_is_valid(win) then
        return win
    end
    return nil
end

---@return integer? the outer container float handle when the review is open
function M._shell_win()
    if shell_win and vim.api.nvim_win_is_valid(shell_win) then
        return shell_win
    end
    return nil
end

--- Close the review (both windows) and clear all state.
function M.close()
    close_float()
    close_list()
    close_shell()
    sections = {}
    current_idx = 1
    skipped_outside = 0
    jump_targets = {}
    groups = {}
    toplevel_branch = {}
    row_entries = {}
end

-- Jump ----------------------------------------------------------------------

---@return integer? a non-π, non-winfixbuf window in the current tab
local function find_editor_win()
    local panel_fts = {
        [Ft.history] = true,
        [Ft.prompt] = true,
        [Ft.attachments] = true,
        [Ft.dialog] = true,
        [Ft.sessions] = true,
        [Ft.diff_review] = true,
    }
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local b = vim.api.nvim_win_get_buf(w)
        if not panel_fts[vim.bo[b].filetype] and not vim.wo[w].winfixbuf then
            return w
        end
    end
    return nil
end

--- Open `path` in an editor window (preferring an existing non-π window,
--- mirroring the chat history's gf behavior) and jump to `line`.
---@param path string
---@param line integer
local function open_at(path, line)
    local editor_win = find_editor_win()
    if editor_win then
        vim.api.nvim_set_current_win(editor_win)
    else
        vim.cmd("botright vsplit")
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    if line > 0 then
        pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    end
end

--- First changed line of a section in the new file (the first hunk target),
--- or 1 for files with no hunks. nil for deleted files.
---@param section pi.DiffReviewSection
---@return integer?
local function first_changed_line(section)
    if section.deleted then
        return nil
    end
    local hunk_lines = M.compute_hunk_lines(section.body)
    for i, line in ipairs(section.body) do
        local new_line = hunk_lines[i]
        if new_line and new_line > 0 then
            return new_line
        end
    end
    return 1
end

--- Float <CR>/o: jump to the file/line under the cursor, closing the review.
jump_to_target = function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local target = jump_targets[lnum]
    if not target then
        return
    end
    M.close()
    open_at(target.path, target.line)
end

--- List <CR>/o: jump to the selected file's first changed line (a group
--- header jumps to its first section).
list_jump = function()
    local entry = row_entries[vim.api.nvim_win_get_cursor(0)[1]]
    local idx = entry and entry.section or nil
    if not idx or idx < 1 or idx > #sections then
        return
    end
    local section = sections[idx]
    local line = first_changed_line(section)
    if not line then
        return
    end
    M.close()
    open_at(section.abs, line)
end

-- Collection -----------------------------------------------------------------

---@param group pi.DiffReviewGroup
---@param sections pi.DiffReviewSection[] global flat list (append target)
local function append_parsed(parsed, group, sections)
    for _, section in ipairs(parsed) do
        section.toplevel = group.toplevel
        section.abs = group.toplevel .. "/" .. section.path
        group.sections[#group.sections + 1] = #sections + 1
        sections[#sections + 1] = section
    end
end

--- For changed files that produced no diff vs. HEAD (or the index in a fresh
--- repository): tracked files with no diff have nothing to show; untracked
--- files render as full-file additions via `git diff --no-index`.
---@param uncovered string[] paths relative to the work tree root
---@param group pi.DiffReviewGroup
---@param sections pi.DiffReviewSection[] global flat list
---@param done fun()
local function fetch_untracked(uncovered, group, sections, done)
    local idx = 1
    local function step()
        if idx > #uncovered then
            done()
            return
        end
        local rel = uncovered[idx]
        vim.system({ "git", "-C", group.toplevel, "ls-files", "--error-unmatch", "--", rel }, {}, function(res)
            vim.schedule(function()
                if res.code == 0 then
                    -- Tracked but identical to HEAD/index: nothing to show.
                    idx = idx + 1
                    step()
                    return
                end
                vim.system(
                    { "git", "-C", group.toplevel, "diff", "--no-index", "--no-color", "--", "/dev/null", rel },
                    {},
                    function(res2)
                        vim.schedule(function()
                            append_parsed(M.parse_sections(res2.stdout or ""), group, sections)
                            idx = idx + 1
                            step()
                        end)
                    end
                )
            end)
        end)
    end
    step()
end

local diff_group_content

--- Diff one work tree group: branch label, then `git diff HEAD` (the union of
--- staged and unstaged changes; `--cached` in a fresh repository without a
--- HEAD), then untracked fallbacks.
---@param group pi.DiffReviewGroup
---@param sections pi.DiffReviewSection[] global flat list
---@param done fun()
local function diff_group(group, sections, done)
    vim.system({ "git", "-C", group.toplevel, "branch", "--show-current" }, {}, function(res)
        vim.schedule(function()
            group.branch = vim.trim(res.stdout or "")
            if group.branch ~= "" then
                diff_group_content(group, sections, done)
                return
            end
            -- Detached HEAD or no commits yet: fall back to the short hash,
            -- then to the toplevel basename for a fresh repository.
            vim.system({ "git", "-C", group.toplevel, "rev-parse", "--short", "HEAD" }, {}, function(res2)
                vim.schedule(function()
                    group.branch = vim.trim(res2.stdout or "")
                    if group.branch == "" then
                        group.branch = vim.fn.fnamemodify(group.toplevel, ":t")
                    end
                    diff_group_content(group, sections, done)
                end)
            end)
        end)
    end)
end

---@param group pi.DiffReviewGroup
---@param sections pi.DiffReviewSection[] global flat list
---@param done fun()
diff_group_content = function(group, sections, done)
    local ctx = diff_context()
    local args = { "git", "-C", group.toplevel, "diff", "--no-color", "-U" .. ctx }
    vim.system({ "git", "-C", group.toplevel, "rev-parse", "--verify", "-q", "HEAD" }, {}, function(res)
        vim.schedule(function()
            if res.code == 0 then
                args[#args + 1] = "HEAD"
            else
                -- Fresh repository (no commits yet): the index vs the empty tree.
                args[#args + 1] = "--cached"
            end
            args[#args + 1] = "--"
            for _, rel in ipairs(group.rel_files) do
                args[#args + 1] = rel
            end
            vim.system(args, {}, function(res2)
                vim.schedule(function()
                    append_parsed(M.parse_sections(res2.stdout or ""), group, sections)
                    local covered = {}
                    for _, si in ipairs(group.sections) do
                        covered[sections[si].path] = true
                    end
                    ---@type string[]
                    local uncovered = {}
                    for _, rel in ipairs(group.rel_files) do
                        if not covered[rel] then
                            uncovered[#uncovered + 1] = rel
                        end
                    end
                    fetch_untracked(uncovered, group, sections, done)
                end)
            end)
        end)
    end)
end

--- Collect the diff of the session's changed files, grouped by the git work
--- tree each file actually lives in. Files that resolve to no work tree are
--- counted as `outside` (skipped, like before).
---@param files string[] raw changed-file paths from the session
---@param session_cwd string session working directory (path anchor)
---@param done fun(sections: pi.DiffReviewSection[], groups: pi.DiffReviewGroup[], outside: integer)
local function collect(files, session_cwd, done)
    local abs_files = resolve_abs_paths(files, session_cwd)
    ---@type table<string, string> dirname -> work tree root ("" = outside)
    local dir_tl = {}
    ---@type table<string, pi.DiffReviewGroup>
    local by_tl = {}
    ---@type string[]
    local tls = {}
    local outside = 0
    local sections = {} ---@type pi.DiffReviewSection[]

    local file_i = 1
    local assign
    local resolve_next
    local collect_groups
    assign = function(tl)
        local abs = abs_files[file_i]
        if tl == "" then
            outside = outside + 1
        else
            local group = by_tl[tl]
            if not group then
                group = { toplevel = tl, branch = "", rel_files = {}, abs_files = {}, sections = {} }
                by_tl[tl] = group
                tls[#tls + 1] = tl
            end
            group.rel_files[#group.rel_files + 1] = abs:sub(#tl + 2)
            group.abs_files[#group.abs_files + 1] = abs
        end
        file_i = file_i + 1
        resolve_next()
    end
    resolve_next = function()
        if file_i > #abs_files then
            collect_groups()
            return
        end
        local abs = abs_files[file_i]
        local dir = vim.fn.fnamemodify(abs, ":h")
        local cached = dir_tl[dir]
        if cached ~= nil then
            assign(cached)
            return
        end
        vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, {}, function(res)
            vim.schedule(function()
                local tl = ""
                if res.code == 0 then
                    tl = vim.fn.resolve(vim.trim(res.stdout or ""))
                end
                dir_tl[dir] = tl
                assign(tl)
            end)
        end)
    end
    local group_i = 1
    collect_groups = function()
        if group_i > #tls then
            local ordered = order_groups(by_tl, tls, vim.fn.resolve(session_cwd))
            done(sections, ordered, outside)
            return
        end
        local group = by_tl[tls[group_i]]
        diff_group(group, sections, function()
            group_i = group_i + 1
            collect_groups()
        end)
    end
    resolve_next()
end

--- Open the diff review for a session's changed files.
--- No-op with a warning when there is no session or nothing was changed.
--- Paths are anchored at the session's cwd and grouped by the git work tree
--- they actually live in; files outside any work tree are counted and
--- skipped. Re-opening refreshes.
---@param session? pi.Session session whose changed files to review (default: the current tab's)
function M.open(session)
    local Notify = require("pi.notify")
    local Sessions = require("pi.sessions.manager")
    if session == nil then
        session = Sessions.get()
    end
    if not session then
        Notify.warn(":PiDiff — no active session")
        return
    end
    local files = vim.tbl_keys(session.changed_files)
    if #files == 0 then
        Notify.warn(":PiDiff — no files changed in this session yet")
        return
    end
    M.close()
    collect(files, session.cwd or vim.uv.cwd(), function(collected, ordered, outside)
        vim.schedule(function()
            if #collected == 0 then
                Notify.warn(":PiDiff — no diff output for this session's changed files")
                return
            end
            M.render(collected, { groups = ordered, skipped = outside })
        end)
    end)
end

--- Test hook: run the collection pipeline.
---@param files string[]
---@param session_cwd string
---@param done fun(sections: pi.DiffReviewSection[], groups: pi.DiffReviewGroup[], outside: integer)
function M._collect(files, session_cwd, done)
    collect(files, session_cwd, done)
end

--- Test hook: list cursor moved (drives the float follow; the CursorMoved
--- autocmd calls the same handler).
function M._on_list_cursor_moved()
    on_list_cursor_moved()
end

--- Test hook: jump-target map of the float (buffer line -> { path, line }).
---@return table<integer, { path: string, line: integer }>
function M._targets()
    return jump_targets
end

--- Test hook: index of the section currently shown in the float.
---@return integer
function M._current_idx()
    return current_idx
end

--- Test hook: list row map (row -> { group, section }).
---@return table<integer, { group: integer, section: integer? }>
function M._row_entries()
    return row_entries
end

--- Test hook: close the review windows and clear all state.
function M._reset()
    M.close()
end

return M
