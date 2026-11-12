-- :PiSessions worktree grouping: rows are grouped under a
-- `▾ 󰙅 name · path` header only when the listed sessions span at least two
-- distinct git worktrees — a single-worktree (or non-git) list keeps exactly
-- the flat shape it always had. Covers the threshold, the group header
-- format, fold reuse (`▸`/`▾ (n)` over `parent_folds`), group-header key
-- safety, the sub-session worktree suffix, and the `↳ forked from` marker.
--
-- `pi.worktree` is stubbed through package.loaded, so this spec never shells
-- out to git; the module's own spec covers detection against real
-- repositories.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local SessionList = require("pi.ui.sessions")
local Sidebar = require("pi.ui.sidebar")

local GLYPH = "󰙅"
local TAB = 873

---@type table<string, { kind: string, name: string, path: string, repo_root: string }>
local WORKTREES = {
    ["/repo/main"] = { kind = "main", name = "main", path = "/repo/main", repo_root = "/repo/main" },
    ["/repo/wt"] = { kind = "linked", name = "wt", path = "/repo/wt", repo_root = "/repo/main" },
}

---@param opts? { id?: string, tab?: integer, cwd?: string, forked_from?: any }
---@return pi.Session
local function fake_session(opts)
    opts = opts or {}
    local tab = opts.tab or TAB
    return {
        id = opts.id or ("sess-" .. tostring(math.random(1000, 9999))),
        tab = tab,
        attached_tab = tab,
        cwd = opts.cwd,
        forked_from = opts.forked_from,
        conversation_epoch = 0,
        rpc = {
            is_running = function()
                return true
            end,
            stop = function() end,
            send = function(_, _, cb)
                if cb then
                    cb({ success = true, data = {} })
                end
                return true
            end,
        },
        chat = {
            is_streaming = function()
                return false
            end,
            is_compacting = function()
                return false
            end,
            layout = function()
                return "side"
            end,
            set_status = function() end,
        },
    }
end

--- Build rows with the plain `id` name source and no attention.
---@param sessions pi.Session[]
---@return pi.SessionsListRow[]
local function build(sessions)
    return SessionList.build_rows(sessions, function()
        return 0
    end, function(session)
        return session.id
    end)
end

local function press_key(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
end

--- Run `fn` with the session manager stubbed to `sessions`.
---@param sessions pi.Session[]
---@param fn fun()
local function with_manager(sessions, fn)
    local real_manager = package.loaded["pi.sessions.manager"]
    package.loaded["pi.sessions.manager"] = {
        list = function()
            return sessions
        end,
        get = function()
            return sessions[1]
        end,
        get_by_id = function(id)
            for _, session in ipairs(sessions) do
                if session.id == id then
                    return session
                end
            end
            return nil
        end,
        get_for_tab = function(tab)
            for _, session in ipairs(sessions) do
                if session.tab == tab then
                    return session
                end
            end
            return nil
        end,
    }
    local ok, err = pcall(fn)
    package.loaded["pi.sessions.manager"] = real_manager
    if not ok then
        error(err)
    end
end

---@return string[]
local function buffer_lines()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(0), 0, -1, false)
end

describe(":PiSessions worktree grouping", function()
    local real_worktree_module
    local orig_children

    before_each(function()
        Config.setup({})
        SessionList._reset()
        Sidebar._reset()
        Manifest = require("pi.subsessions.manifest")
        orig_children = Manifest.children_of
        real_worktree_module = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            detect = function(dir)
                return WORKTREES[dir]
            end,
            status = function() end,
        }
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
        Sidebar._reset()
        Manifest.children_of = orig_children
        package.loaded["pi.worktree"] = real_worktree_module
    end)

    describe("threshold", function()
        it("keeps the flat list when every session shares one worktree", function()
            local a = fake_session({ id = "A", cwd = "/repo/wt" })
            local b = fake_session({ id = "B", cwd = "/repo/wt" })

            local rows = build({ a, b })

            assert.are.equal(2, #rows)
            assert.is_nil(rows[1].is_group)
            assert.is_nil(rows[2].is_group)
            assert.are.equal("  ● A", (SessionList.format_line(rows[1], 0)))
            assert.are.equal("  ● B", (SessionList.format_line(rows[2], 0)))
        end)

        it("keeps the flat list for sessions outside any worktree", function()
            local a = fake_session({ id = "A", cwd = "/tmp/one" })
            local b = fake_session({ id = "B", cwd = "/tmp/two" })

            local rows = build({ a, b })

            assert.are.equal(2, #rows)
            assert.is_nil(rows[1].is_group)
            assert.is_nil(rows[1].worktree)
        end)

        it("groups once two distinct worktrees are listed", function()
            local main = fake_session({ id = "A", cwd = "/repo/main" })
            local linked = fake_session({ id = "B", cwd = "/repo/wt" })

            local rows = build({ main, linked })

            assert.are.equal(4, #rows)
            assert.is_true(rows[1].is_group)
            assert.are.equal("/repo/main", rows[1].group_id)
            assert.are.equal("main", rows[1].worktree)
            assert.are.equal(1, rows[1].child_count)
            assert.are.equal("A", rows[2].session_id)
            assert.are.equal("/repo/main", rows[2].group_id)
            assert.is_true(rows[3].is_group)
            assert.are.equal("/repo/wt", rows[3].group_id)
            assert.are.equal("B", rows[4].session_id)
            assert.are.equal("/repo/wt", rows[4].group_id)
        end)

        it("keeps groups in first-appearance order and ungrouped rows last", function()
            local linked = fake_session({ id = "B", cwd = "/repo/wt" })
            local outside = fake_session({ id = "C", cwd = "/tmp/none" })
            local main = fake_session({ id = "A", cwd = "/repo/main" })

            local rows = build({ linked, outside, main })

            assert.are.equal(5, #rows)
            assert.are.equal("/repo/wt", rows[1].group_id)
            assert.are.equal("B", rows[2].session_id)
            assert.are.equal("/repo/main", rows[3].group_id)
            assert.are.equal("A", rows[4].session_id)
            assert.are.equal("C", rows[5].session_id)
            assert.is_nil(rows[5].group_id)
            assert.is_nil(rows[5].worktree)
        end)
    end)

    describe("group header format", function()
        it("renders glyph, worktree name and display path", function()
            local main = fake_session({ id = "A", cwd = "/repo/main" })
            local linked = fake_session({ id = "B", cwd = "/repo/wt" })
            local rows = build({ main, linked })

            local line, chunks = SessionList.format_line(rows[1], 0)
            local path = vim.fn.fnamemodify("/repo/main", ":~")
            assert.are.equal("▾ " .. GLYPH .. " main · " .. path, line)

            -- Prefix is dim, glyph + name carry the worktree group, and the
            -- (long) path is the dim trailing part that clipping may cut.
            assert.are.equal(0, chunks[1][1])
            assert.are.equal("PiSessionsListDotDim", chunks[1][3])
            assert.are.equal("PiSessionsListWorktree", chunks[2][3])
            assert.are.equal(GLYPH, line:sub(chunks[2][1] + 1, chunks[2][2]))
            assert.are.equal("PiSessionsListWorktree", chunks[3][3])
            assert.are.equal("main", line:sub(chunks[3][1] + 1, chunks[3][2]))
            assert.are.equal("PiSessionsListDotDim", chunks[4][3])
            assert.are.equal(" · " .. path, line:sub(chunks[4][1] + 1, chunks[4][2]))
        end)

        it("renders a collapsed group with ▸ and its member count before the path", function()
            local line, chunks = SessionList.format_group_line({
                is_group = true,
                collapsed = true,
                child_count = 3,
                worktree = "wt",
                worktree_path = "~/wt",
            })
            assert.are.equal("▸ " .. GLYPH .. " wt (3) · ~/wt", line)

            -- The count sits in the worktree-colored label, ahead of the path:
            -- a clipped header loses the path, never the fold count.
            local label = line:sub(chunks[3][1] + 1, chunks[3][2])
            assert.are.equal("wt (3)", label)
            assert.are.equal(" · ~/wt", line:sub(chunks[4][1] + 1, chunks[4][2]))
        end)

        it("keeps the member count when a parent inside the group folds", function()
            local main = fake_session({ id = "A", cwd = "/repo/main" })
            local parent = fake_session({ id = "parent-1", cwd = "/repo/wt" })

            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return {
                        { _id = "c1", name = "worker-1", status = "active", parent_id = "parent-1", config = {} },
                        { _id = "c2", name = "worker-2", status = "active", parent_id = "parent-1", config = {} },
                    }
                end
                return {}
            end

            local rows = build({ main, parent })
            -- header(main), A, header(wt), parent, c1, c2
            assert.are.equal(6, #rows)
            assert.is_true(rows[3].is_group)
            assert.are.equal(3, rows[3].child_count)

            -- Folding the parent removes its child rows from the list; the
            -- group's fixed size (parent + 2 sub-sessions) must not change.
            SessionList._toggle_parent_collapsed(parent, false)
            local folded = build({ main, parent })
            assert.are.equal(4, #folded)
            assert.is_true(folded[3].is_group)
            assert.are.equal(3, folded[3].child_count)
            assert.is_true(folded[4].collapsed)
            assert.are.equal(2, folded[4].child_count)

            -- Collapsed header still reports the unchanged 3.
            local header_line = (
                SessionList.format_group_line({
                    is_group = true,
                    collapsed = true,
                    child_count = folded[3].child_count,
                    worktree = folded[3].worktree,
                    worktree_path = folded[3].worktree_path,
                })
            )
            assert.is_truthy(header_line:find("wt (3) · ", 1, true))
        end)

        it("renders an expanded group without the count", function()
            local line = (
                SessionList.format_group_line({
                    is_group = true,
                    collapsed = false,
                    child_count = 3,
                    worktree = "wt",
                    worktree_path = "~/wt",
                })
            )
            assert.are.equal("▾ " .. GLYPH .. " wt · ~/wt", line)
        end)
    end)

    describe("row body", function()
        it("appends the worktree to a sub-session subtitle", function()
            local main = fake_session({ id = "A", cwd = "/repo/main" })
            local parent = fake_session({ id = "parent-1", cwd = "/repo/wt" })

            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return {
                        { _id = "c1", name = "worker-1", status = "active", parent_id = "parent-1", config = {} },
                    }
                end
                return {}
            end

            local rows = build({ main, parent })

            -- header(main), A, header(wt), parent, child
            assert.are.equal(5, #rows)
            local child = rows[5]
            assert.are.equal(1, child.depth)
            assert.are.equal("wt", child.worktree)
            assert.are.equal("  └─ ● worker-1 · " .. GLYPH .. " wt", (SessionList.format_line(child, 0)))
            -- Parent rows name their worktree in the header, not in the body.
            assert.is_nil(rows[4].worktree)
        end)

        it("marks a forked session with ↳ forked from", function()
            local forked = fake_session({ id = "F", forked_from = { name = "original session" } })

            local rows = build({ forked })

            assert.are.equal("original session", rows[1].forked_from)
            assert.are.equal("  ● F ↳ forked from original session", (SessionList.format_line(rows[1], 0)))
        end)

        it("accepts a plain-string forked_from", function()
            local line = (
                SessionList.format_line({
                    depth = 0,
                    status = "idle",
                    attention = 0,
                    name = "F",
                    forked_from = "orig",
                }, 0)
            )
            assert.are.equal("  ● F ↳ forked from orig", line)
        end)
    end)

    describe("folding", function()
        it("folds a worktree group with <Tab>, za, zM and zR", function()
            local main = fake_session({ id = "A", tab = vim.api.nvim_get_current_tabpage(), cwd = "/repo/main" })
            local linked = fake_session({ id = "B", tab = vim.api.nvim_get_current_tabpage() + 1, cwd = "/repo/wt" })

            with_manager({ main, linked }, function()
                SessionList.open()
                vim.api.nvim_win_set_cursor(0, { 1, 0 })

                local lines = buffer_lines()
                assert.are.equal(4, #lines)
                assert.is_truthy(lines[1]:find("▾ " .. GLYPH, 1, true))

                -- Collapse the first group on its header row.
                press_key("<Tab>")
                lines = buffer_lines()
                assert.are.equal(3, #lines)
                assert.is_truthy(lines[1]:find("▸ " .. GLYPH, 1, true))
                assert.is_truthy(lines[1]:find("(1)", 1, true))
                -- Cursor stays on the header it folded.
                assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])

                -- za expands it again.
                press_key("za")
                lines = buffer_lines()
                assert.are.equal(4, #lines)
                assert.is_truthy(lines[1]:find("▾ " .. GLYPH, 1, true))

                -- zM folds every group, zR expands them.
                press_key("zM")
                lines = buffer_lines()
                assert.are.equal(2, #lines)
                assert.is_truthy(lines[1]:find("▸ " .. GLYPH, 1, true))
                assert.is_truthy(lines[2]:find("▸ " .. GLYPH, 1, true))

                press_key("zR")
                lines = buffer_lines()
                assert.are.equal(4, #lines)
                assert.is_truthy(lines[1]:find("▾ " .. GLYPH, 1, true))
            end)
        end)

        it("keeps the count identical after folding the group and after zM", function()
            local main = fake_session({ id = "A", tab = vim.api.nvim_get_current_tabpage(), cwd = "/repo/main" })
            local parent =
                fake_session({ id = "parent-1", tab = vim.api.nvim_get_current_tabpage() + 1, cwd = "/repo/wt" })

            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return {
                        { _id = "c1", name = "worker-1", status = "active", parent_id = "parent-1", config = {} },
                        { _id = "c2", name = "worker-2", status = "active", parent_id = "parent-1", config = {} },
                    }
                end
                return {}
            end

            with_manager({ main, parent }, function()
                SessionList.open()
                local lines = buffer_lines()
                assert.are.equal(6, #lines)

                -- Fold the worktree group on its header row (line 3).
                vim.api.nvim_win_set_cursor(0, { 3, 0 })
                press_key("<Tab>")
                lines = buffer_lines()
                assert.are.equal(3, #lines)
                assert.is_truthy(lines[3]:find("wt (3) · ", 1, true))

                -- zM collapses every group: same fixed counts, no re-count.
                press_key("zR")
                assert.are.equal(6, #buffer_lines())
                press_key("zM")
                lines = buffer_lines()
                assert.are.equal(2, #lines)
                assert.is_truthy(lines[1]:find("(1)", 1, true))
                assert.is_truthy(lines[2]:find("wt (3) · ", 1, true))
            end)
        end)

        it("leaves the group fold independent from a parent row fold", function()
            local main = fake_session({ id = "A", tab = vim.api.nvim_get_current_tabpage(), cwd = "/repo/main" })
            local parent =
                fake_session({ id = "parent-1", tab = vim.api.nvim_get_current_tabpage() + 1, cwd = "/repo/wt" })

            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return {
                        { _id = "c1", name = "worker-1", status = "active", parent_id = "parent-1", config = {} },
                    }
                end
                return {}
            end

            with_manager({ main, parent }, function()
                SessionList.open()
                local lines = buffer_lines()
                assert.are.equal(5, #lines)

                -- Fold the worktree group holding the parent row: both the
                -- parent and its sub-session disappear.
                vim.api.nvim_win_set_cursor(0, { 3, 0 })
                press_key("<Tab>")
                lines = buffer_lines()
                assert.are.equal(3, #lines)
                assert.is_truthy(lines[3]:find("▸ " .. GLYPH .. " wt", 1, true))
                assert.is_truthy(lines[3]:find("(2)", 1, true))
            end)
        end)
    end)

    describe("group header rows", function()
        it("ignore session actions instead of erroring", function()
            local main = fake_session({ id = "A", tab = vim.api.nvim_get_current_tabpage(), cwd = "/repo/main" })
            local linked = fake_session({ id = "B", tab = vim.api.nvim_get_current_tabpage() + 1, cwd = "/repo/wt" })

            with_manager({ main, linked }, function()
                SessionList.open()
                vim.api.nvim_win_set_cursor(0, { 1, 0 })
                local wins_before = #vim.api.nvim_list_wins()
                local lines_before = buffer_lines()

                for _, key in ipairs({ "<CR>", "x", "p", "c", "d", "f", "s" }) do
                    press_key(key)
                end

                assert.are.equal(wins_before, #vim.api.nvim_list_wins())
                assert.are.same(lines_before, buffer_lines())
            end)
        end)
    end)
end)
