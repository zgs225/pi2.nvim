local Config = require("pi.config")
local SessionList = require("pi.ui.sessions")

local function fake_session(opts)
    opts = opts or {}
    local tab = opts.tab or vim.api.nvim_get_current_tabpage()
    local id = opts.id or ("sess-" .. tostring(math.random(1000, 9999)))
    local s = {
        id = id,
        tab = tab,
        attached_tab = tab,
        view_parent_id = opts.view_parent_id,
        conversation_epoch = opts.conversation_epoch or 0,
        rpc = {
            is_running = function()
                return opts.running ~= false
            end,
            stop = function() end,
            send = function(_, _, cb)
                if cb then
                    cb({ success = true })
                end
                return true
            end,
        },
        chat = {
            is_streaming = function()
                return opts.streaming == true
            end,
            is_compacting = function()
                return opts.compacting == true
            end,
            layout = function()
                return "side"
            end,
            set_status = function() end,
        },
    }
    return s
end

local function press_key(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
end

describe("sub-session fold/unfold in :PiSessions", function()
    local orig_children
    local Manifest

    before_each(function()
        Config.setup({})
        SessionList._reset()
        Manifest = require("pi.subsessions.manifest")
        orig_children = Manifest.children_of
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
        Manifest.children_of = orig_children
    end)

    describe("row building and formatting", function()
        it("default expanded builds parent + child rows with ▾ prefix", function()
            Config.setup({ sessions_list = { collapse_subsessions = false } })
            local parent = fake_session({ id = "parent-1" })

            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return {
                        { _id = "c1", name = "worker-1", status = "active", parent_id = "parent-1", config = {} },
                        { _id = "c2", name = "worker-2", status = "active", parent_id = "parent-1", config = {} },
                    }
                end
                return {}
            end

            local rows = SessionList.build_rows({ parent }, function()
                return 0
            end, function()
                return "Parent"
            end)

            assert.are.equal(3, #rows)
            -- Parent row
            assert.is_true(rows[1].has_children)
            assert.is_false(rows[1].collapsed)
            assert.are.equal(2, rows[1].child_count)

            -- Format parent line
            local line, chunks = SessionList.format_line(rows[1], 0)
            assert.are.equal("▾ ● Parent", line)
            assert.are.equal(3, #chunks)
            -- chunks[1] is dot
            assert.are.equal(4, chunks[1][1])
            assert.are.equal(4 + #"●", chunks[1][2])
            assert.are.equal("●", line:sub(chunks[1][1] + 1, chunks[1][2]))
            -- fold prefix chunk
            assert.are.equal(0, chunks[3][1])
            assert.are.equal(4, chunks[3][2])
            assert.are.equal("PiSessionsListDotDim", chunks[3][3])
            assert.are.equal("▾ ", line:sub(chunks[3][1] + 1, chunks[3][2]))

            -- Format child line
            local child_line, child_chunks = SessionList.format_line(rows[2], 0)
            assert.are.equal("  └─ ● worker-1", child_line)
            assert.are.equal(2, #child_chunks)
        end)

        it("default collapsed builds only parent row with ▸ prefix and (N) count", function()
            Config.setup({ sessions_list = { collapse_subsessions = true } })
            local parent = fake_session({ id = "parent-1" })

            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return {
                        { _id = "c1", name = "worker-1", status = "active", parent_id = "parent-1", config = {} },
                        { _id = "c2", name = "worker-2", status = "active", parent_id = "parent-1", config = {} },
                        { _id = "c3", name = "worker-3", status = "active", parent_id = "parent-1", config = {} },
                    }
                end
                return {}
            end

            local rows = SessionList.build_rows({ parent }, function()
                return 0
            end, function()
                return "Parent"
            end)

            assert.are.equal(1, #rows)
            assert.is_true(rows[1].has_children)
            assert.is_true(rows[1].collapsed)
            assert.are.equal(3, rows[1].child_count)

            local line, chunks = SessionList.format_line(rows[1], 0)
            assert.are.equal("▸ ● Parent (3)", line)
            -- chunks: dot, name, fold prefix, count suffix
            assert.are.equal(4, #chunks)
            -- chunks[1] is dot
            assert.are.equal(4, chunks[1][1])
            assert.are.equal(4 + #"●", chunks[1][2])
            assert.are.equal("●", line:sub(chunks[1][1] + 1, chunks[1][2]))
            -- fold prefix chunk
            assert.are.equal(0, chunks[3][1])
            assert.are.equal(4, chunks[3][2])
            assert.are.equal("PiSessionsListDotDim", chunks[3][3])
            assert.are.equal("▸ ", line:sub(chunks[3][1] + 1, chunks[3][2]))
            -- count suffix chunk
            assert.are.equal(#line - 4, chunks[4][1])
            assert.are.equal(#line, chunks[4][2])
            assert.are.equal("PiSessionsListDotDim", chunks[4][3])
            assert.are.equal(" (3)", line:sub(chunks[4][1] + 1, chunks[4][2]))
        end)

        it("respects subagent.sessions_list.collapse_children config", function()
            Config.setup({ subagent = { sessions_list = { collapse_children = true } } })
            local parent = fake_session({ id = "parent-1" })
            Manifest.children_of = function()
                return {
                    { _id = "c1", name = "worker-1", status = "active", parent_id = "parent-1", config = {} },
                }
            end

            local rows = SessionList.build_rows({ parent }, function()
                return 0
            end, function()
                return "Parent"
            end)
            assert.are.equal(1, #rows)
            assert.is_true(rows[1].collapsed)
        end)

        it("respects subagent.sessions_list.collapsed config alias", function()
            Config.setup({ subagent = { sessions_list = { collapsed = true } } })
            local parent = fake_session({ id = "parent-1" })
            Manifest.children_of = function()
                return {
                    { _id = "c1", name = "worker-1", status = "active", parent_id = "parent-1", config = {} },
                }
            end

            local rows = SessionList.build_rows({ parent }, function()
                return 0
            end, function()
                return "Parent"
            end)
            assert.are.equal(1, #rows)
            assert.is_true(rows[1].collapsed)
        end)

        it("sessions with no sub-sessions format normally with 1 space prefix", function()
            local parent = fake_session({ id = "parent-solo" })
            Manifest.children_of = function()
                return {}
            end

            local rows = SessionList.build_rows({ parent }, function()
                return 0
            end, function()
                return "Solo"
            end)

            assert.are.equal(1, #rows)
            assert.is_false(rows[1].has_children)
            assert.is_false(rows[1].collapsed)
            assert.are.equal(0, rows[1].child_count)

            local line, chunks = SessionList.format_line(rows[1], 0)
            assert.are.equal(" ● Solo", line)
            assert.are.equal(2, #chunks)
            assert.are.equal(1, chunks[1][1])
            assert.are.equal("Normal", chunks[2][3])
        end)

        it("active child view keeps parent expanded by default", function()
            Config.setup({ sessions_list = { collapse_subsessions = true } })
            local cur_tab = vim.api.nvim_get_current_tabpage()
            local parent = fake_session({ id = "parent-1", tab = cur_tab })
            local child = fake_session({ id = "child-1", tab = cur_tab, view_parent_id = "parent-1" })

            local Sessions = require("pi.sessions.manager")
            Sessions._register_for_test(parent)

            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return {
                        { _id = "child-1", name = "c1", status = "active", parent_id = "parent-1", config = {} },
                    }
                end
                return {}
            end

            local rows = SessionList.build_rows({ child }, function()
                return 0
            end, function()
                return "Parent"
            end)

            Sessions._reset()

            -- Parent should be expanded because current tab is actively viewing child-1
            assert.are.equal(2, #rows)
            assert.is_true(rows[1].has_children)
            assert.is_false(rows[1].collapsed)
            assert.are.equal(1, rows[1].child_count)
            assert.are.equal(1, rows[2].depth)
        end)
    end)

    describe("interactive keymaps", function()
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
                    for _, s in ipairs(sessions) do
                        if s.id == id then
                            return s
                        end
                    end
                    return nil
                end,
                get_for_tab = function(tab)
                    for _, s in ipairs(sessions) do
                        if s.tab == tab then
                            return s
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

        it("toggles fold on parent row via <Tab> and za", function()
            local cur_tab = vim.api.nvim_get_current_tabpage()
            local parent = fake_session({ id = "parent-1", tab = cur_tab })

            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return {
                        { _id = "c1", name = "worker-1", status = "active", parent_id = "parent-1", config = {} },
                    }
                end
                return {}
            end

            with_manager({ parent }, function()
                SessionList.open()
                vim.api.nvim_win_set_cursor(0, { 1, 0 })

                -- Initially expanded
                local buf = vim.api.nvim_win_get_buf(0)
                local lines1 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                assert.are.equal(2, #lines1)
                assert.is_truthy(lines1[1]:find("▾", 1, true))

                -- Press <Tab> on parent row -> collapses
                press_key("<Tab>")
                local lines2 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                assert.are.equal(1, #lines2)
                assert.is_truthy(lines2[1]:find("▸", 1, true))
                assert.is_truthy(lines2[1]:find("(1)", 1, true))

                -- Press za on parent row -> expands again
                press_key("za")
                local lines3 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                assert.are.equal(2, #lines3)
                assert.is_truthy(lines3[1]:find("▾", 1, true))
            end)
        end)

        it("toggling on child row collapses parent and lands cursor on parent", function()
            local cur_tab = vim.api.nvim_get_current_tabpage()
            local parent = fake_session({ id = "parent-1", tab = cur_tab })

            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return {
                        { _id = "c1", name = "worker-1", status = "active", parent_id = "parent-1", config = {} },
                        { _id = "c2", name = "worker-2", status = "active", parent_id = "parent-1", config = {} },
                    }
                end
                return {}
            end

            with_manager({ parent }, function()
                SessionList.open()
                -- Move cursor to child row (line 2)
                vim.api.nvim_win_set_cursor(0, { 2, 0 })

                -- Press <Tab> on child row
                press_key("<Tab>")

                -- Parent is now collapsed
                local buf = vim.api.nvim_win_get_buf(0)
                local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                assert.are.equal(1, #lines)
                assert.is_truthy(lines[1]:find("▸", 1, true))
                assert.is_truthy(lines[1]:find("(2)", 1, true))

                -- Cursor was repositioned on parent row (line 1)
                assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])
            end)
        end)

        it("zM collapses all and zR expands all", function()
            local p1 = fake_session({ id = "parent-1", tab = 100 })
            local p2 = fake_session({ id = "parent-2", tab = 200 })

            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return {
                        { _id = "c1", name = "worker-1", status = "active", parent_id = "parent-1", config = {} },
                    }
                elseif lineage == "parent-2" then
                    return {
                        { _id = "c2", name = "worker-2", status = "active", parent_id = "parent-2", config = {} },
                    }
                end
                return {}
            end

            with_manager({ p1, p2 }, function()
                SessionList.open()
                local buf = vim.api.nvim_win_get_buf(0)

                -- Initially both expanded (4 lines total)
                local lines1 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                assert.are.equal(4, #lines1)

                -- zM collapses all
                press_key("zM")
                local lines2 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                assert.are.equal(2, #lines2)
                assert.is_truthy(lines2[1]:find("▸", 1, true))
                assert.is_truthy(lines2[2]:find("▸", 1, true))

                -- zR expands all
                press_key("zR")
                local lines3 = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                assert.are.equal(4, #lines3)
                assert.is_truthy(lines3[1]:find("▾", 1, true))
                assert.is_truthy(lines3[3]:find("▾", 1, true))
            end)
        end)
    end)

    describe("state tracking and test hooks", function()
        it("tracks fold state and responds to test hooks", function()
            local parent = fake_session({ id = "parent-test" })

            assert.is_false(SessionList._is_parent_collapsed(parent))

            SessionList._toggle_parent_collapsed(parent)
            assert.is_true(SessionList._is_parent_collapsed(parent))

            SessionList._toggle_parent_collapsed(parent)
            assert.is_false(SessionList._is_parent_collapsed(parent))

            SessionList._toggle_parent_collapsed(parent)
            assert.is_true(SessionList._is_parent_collapsed(parent))

            SessionList._reset_folds()
            assert.is_false(SessionList._is_parent_collapsed(parent))
        end)
    end)
end)
