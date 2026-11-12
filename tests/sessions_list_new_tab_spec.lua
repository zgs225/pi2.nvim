-- :PiSessions `n` opens a fresh π session in a new tab rooted at the checkout
-- of the row under the cursor: a worktree group header, any row inside a
-- grouped list (the main-checkout partition included), or a flat row whose
-- session carries the worktree/cwd. A row whose checkout is gone warns and
-- does nothing, and a build without `pi.worktree_session` must not crash.
--
-- `pi.worktree` is stubbed (no git) and `pi.worktree_session` is captured, so
-- the spec asserts the resolved target only — spawning is that module's own
-- concern. The checkouts are real temporary directories because the action
-- bails out on a path `isdirectory()` rejects.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local SessionList = require("pi.ui.sessions")
local Sidebar = require("pi.ui.sidebar")

local GLYPH = "󰙅"

---@type string
local MAIN_DIR = vim.fn.tempname() .. "-main"
---@type string
local WT_DIR = vim.fn.tempname() .. "-wt"
---@type string
local GONE_DIR = vim.fn.tempname() .. "-gone"
vim.fn.mkdir(MAIN_DIR, "p")
vim.fn.mkdir(WT_DIR, "p")

---@type table<string, pi.SessionsListWorktree>
local WORKTREES = {
    [MAIN_DIR] = { kind = "main", name = "main", path = MAIN_DIR, repo_root = MAIN_DIR },
    [WT_DIR] = { kind = "linked", name = "wt", path = WT_DIR, repo_root = MAIN_DIR },
    -- Deleted checkout: still detected (a stale list row), no directory left.
    [GONE_DIR] = { kind = "linked", name = "gone", path = GONE_DIR, repo_root = MAIN_DIR },
}

---@param opts? { id?: string, tab?: integer, cwd?: string, worktree?: table }
---@return pi.Session
local function fake_session(opts)
    opts = opts or {}
    local tab = opts.tab or vim.api.nvim_get_current_tabpage()
    return {
        id = opts.id or ("sess-" .. tostring(math.random(1000, 9999))),
        tab = tab,
        attached_tab = tab,
        cwd = opts.cwd,
        worktree = opts.worktree,
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

---@return { main: pi.Session, wt: pi.Session }
local function worktree_env()
    return {
        main = fake_session({ id = "A", cwd = MAIN_DIR, tab = vim.api.nvim_get_current_tabpage() + 1 }),
        wt = fake_session({ id = "B", cwd = WT_DIR, tab = vim.api.nvim_get_current_tabpage() + 2 }),
    }
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

--- Collect warnings from a warn-stubbed pi.notify.
---@param with_warn fun()
---@return string[]
local function capture_warnings(with_warn)
    local real_notify = package.loaded["pi.notify"]
    local warnings = {}
    package.loaded["pi.notify"] = {
        warn = function(msg)
            table.insert(warnings, msg)
        end,
    }
    local ok, err = pcall(with_warn)
    package.loaded["pi.notify"] = real_notify
    if not ok then
        error(err)
    end
    return warnings
end

---@return string[]
local function buffer_lines()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(0), 0, -1, false)
end

--- Put the cursor on `lnum` of the open list and press `n`.
---@param lnum integer
local function open_under_cursor(lnum)
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    press_key("n")
end

describe(":PiSessions n (new session in this checkout)", function()
    local real_worktree
    local real_worktree_session
    local orig_children
    ---@type { cwd?: string }[] captured open_existing targets
    local opened

    before_each(function()
        Config.setup({})
        SessionList._reset()
        Sidebar._reset()
        opened = {}
        orig_children = Manifest.children_of
        Manifest.children_of = function()
            return {}
        end
        real_worktree = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            detect = function(dir)
                return WORKTREES[dir]
            end,
            status = function() end,
        }
        real_worktree_session = package.loaded["pi.worktree_session"]
        package.loaded["pi.worktree_session"] = {
            open_existing = function(opts)
                opened[#opened + 1] = opts
            end,
        }
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
        Sidebar._reset()
        Manifest.children_of = orig_children
        package.loaded["pi.worktree"] = real_worktree
        package.loaded["pi.worktree_session"] = real_worktree_session
    end)

    describe("row_checkout", function()
        it("prefers the worktree group of the row", function()
            local row = { group_id = "/group", session = { cwd = "/cwd" } }
            assert.are.equal("/group", (SessionList.row_checkout(row)))
        end)

        it("falls back to the session worktree and then its cwd", function()
            local with_worktree = { session = { worktree = { path = "/wt" }, cwd = "/cwd" } }
            assert.are.equal("/wt", (SessionList.row_checkout(with_worktree)))

            local with_cwd = { session = { cwd = "/cwd" } }
            assert.are.equal("/cwd", (SessionList.row_checkout(with_cwd)))

            assert.is_nil(SessionList.row_checkout(nil))
            assert.is_nil(SessionList.row_checkout({ is_group = true }))
        end)
    end)

    describe("target resolution", function()
        it("opens the linked worktree from its group header", function()
            local env = worktree_env()
            with_manager({ env.main, env.wt }, function()
                SessionList.open()
                local lines = buffer_lines()
                assert.are.equal(4, #lines)
                assert.is_truthy(lines[3]:find(GLYPH .. " wt", 1, true))

                open_under_cursor(3)

                assert.are.equal(1, #opened)
                assert.are.equal(WT_DIR, opened[1].cwd)
            end)
        end)

        it("opens the linked worktree from a member row of the group", function()
            local env = worktree_env()
            with_manager({ env.main, env.wt }, function()
                SessionList.open()
                local lines = buffer_lines()
                assert.are.equal(4, #lines)
                -- Line 4 is the member row: no group glyph, indented beneath
                -- the `wt` header on line 3.
                assert.is_nil(lines[4]:find(GLYPH, 1, true))
                assert.is_truthy(lines[3]:find(GLYPH .. " wt", 1, true))

                open_under_cursor(4)

                assert.are.equal(1, #opened)
                assert.are.equal(WT_DIR, opened[1].cwd)
            end)
        end)

        it("opens the main checkout from a row of the main partition", function()
            local env = worktree_env()
            with_manager({ env.main, env.wt }, function()
                SessionList.open()

                open_under_cursor(2)

                assert.are.equal(1, #opened)
                assert.are.equal(MAIN_DIR, opened[1].cwd)
            end)
        end)

        it("opens the main checkout from the main group header", function()
            local env = worktree_env()
            with_manager({ env.main, env.wt }, function()
                SessionList.open()

                open_under_cursor(1)

                assert.are.equal(1, #opened)
                assert.are.equal(MAIN_DIR, opened[1].cwd)
            end)
        end)

        it("uses the session's detected worktree when the list stays flat", function()
            local session = fake_session({ id = "A", cwd = "/nowhere", worktree = { path = WT_DIR } })
            with_manager({ session }, function()
                SessionList.open()
                assert.are.equal(1, #buffer_lines())

                open_under_cursor(1)

                assert.are.equal(1, #opened)
                assert.are.equal(WT_DIR, opened[1].cwd)
            end)
        end)

        it("falls back to the session cwd without a worktree", function()
            local session = fake_session({ id = "A", cwd = WT_DIR })
            with_manager({ session }, function()
                SessionList.open()
                assert.are.equal(1, #buffer_lines())

                open_under_cursor(1)

                assert.are.equal(1, #opened)
                assert.are.equal(WT_DIR, opened[1].cwd)
            end)
        end)
    end)

    describe("guards", function()
        it("warns and does nothing when the checkout is gone", function()
            local env = worktree_env()
            local gone = fake_session({ id = "C", cwd = GONE_DIR, tab = vim.api.nvim_get_current_tabpage() + 3 })
            local warnings
            with_manager({ env.main, gone }, function()
                SessionList.open()
                local lines = buffer_lines()
                assert.are.equal(4, #lines)
                assert.is_truthy(lines[3]:find(GLYPH .. " gone", 1, true))
                -- Let the initial name fetch settle so the comparison below
                -- cannot race the placeholder redraw.
                vim.wait(1000, function()
                    return not table.concat(buffer_lines(), "\n"):find("● …", 1, true)
                end)
                lines = buffer_lines()

                warnings = capture_warnings(function()
                    open_under_cursor(3)
                    vim.wait(100, function()
                        return false
                    end)
                end)

                -- The list is untouched: no refresh, no jump.
                assert.are.same(lines, buffer_lines())
            end)

            assert.are.equal(0, #opened)
            assert.are.equal(1, #warnings)
            assert.is_truthy(warnings[1]:find("no longer exists", 1, true))
        end)

        it("warns instead of crashing when open_existing is unavailable", function()
            package.loaded["pi.worktree_session"] = {}
            local env = worktree_env()
            local warnings
            with_manager({ env.main, env.wt }, function()
                SessionList.open()

                warnings = capture_warnings(function()
                    open_under_cursor(3)
                    vim.wait(100, function()
                        return false
                    end)
                end)
            end)

            assert.are.equal(0, #opened)
            assert.are.equal(1, #warnings)
            assert.is_truthy(warnings[1]:find("unavailable", 1, true))
        end)
    end)

    describe("keymap", function()
        it("registers n on the list buffer", function()
            local env = worktree_env()
            with_manager({ env.main, env.wt }, function()
                SessionList.open()
                local b = vim.fn.bufnr("pi://sessions")
                assert.is_true(b > 0)
                local map = vim.api.nvim_buf_call(b, function()
                    return vim.fn.maparg("n", "n", false, true)
                end)
                assert.is_truthy(map and not vim.tbl_isempty(map))
                assert.are.equal("New session in this checkout (new tab)", map.desc)
            end)
        end)

        it("leaves W unmapped", function()
            local env = worktree_env()
            with_manager({ env.main, env.wt }, function()
                SessionList.open()
                local b = vim.fn.bufnr("pi://sessions")
                assert.is_true(b > 0)
                local map = vim.api.nvim_buf_call(b, function()
                    return vim.fn.maparg("W", "n", false, true)
                end)
                assert.is_true(vim.tbl_isempty(map))
            end)
        end)

        it("lists n in the help overlay", function()
            local env = worktree_env()
            with_manager({ env.main, env.wt }, function()
                SessionList.open()
                press_key("?")

                local found = false
                for _, b in ipairs(vim.api.nvim_list_bufs()) do
                    if vim.api.nvim_buf_is_valid(b) then
                        for _, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
                            if line:find("New session in this checkout", 1, true) then
                                found = true
                            end
                        end
                    end
                end
                assert.is_true(found, "help overlay should list the W key")
            end)
        end)
    end)
end)
