-- :PiSessions `N` opens a fresh π session in a worktree of the repository the
-- row under cursor belongs to: it lists the repository's existing worktrees
-- (pick one) or asks for a name of a new one, created through
-- `pi.worktree_session.open_existing({ name, repo_cwd, create = true })`.
--
-- Covers the keymap/help wiring, managed + external worktrees (the picker
-- opens `entry.path`, not a name-derived path), the empty-list shortcut to the
-- name input, the non-git / list-error guards (warn, never a create prompt),
-- cancel / blank / invalid names, missing checkouts, and the repository
-- snapshot taken at keypress (a cursor or tab switch during the async
-- enumeration must not retarget the create). Also pins that opening/rendering
-- the list never enumerates worktrees.
--
-- `pi.worktree`, `pi.worktree_session`, `pi.ui.dialog`, and `pi.notify` are all
-- stubbed, so this spec never shells out to git.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local SessionList = require("pi.ui.sessions")
local Sidebar = require("pi.ui.sidebar")

--- Real directories: the action bails out on a checkout `isdirectory()` rejects.
---@type string
local MAIN_DIR = vim.fn.tempname() .. "-repo"
---@type string
local MANAGED_DIR = vim.fn.tempname() .. "-wt"
---@type string
local EXTERNAL_DIR = vim.fn.tempname() .. "-ext"
---@type string
local GONE_DIR = vim.fn.tempname() .. "-gone"
--- A real directory outside any repository (`Worktree.detect` returns nil).
---@type string
local PLAIN_DIR = vim.fn.tempname() .. "-plain"
vim.fn.mkdir(MAIN_DIR, "p")
vim.fn.mkdir(MANAGED_DIR, "p")
vim.fn.mkdir(EXTERNAL_DIR, "p")
vim.fn.mkdir(PLAIN_DIR, "p")

---@param opts? { id?: string, tab?: integer, cwd?: string }
---@return pi.Session
local function fake_session(opts)
    opts = opts or {}
    local tab = opts.tab or vim.api.nvim_get_current_tabpage()
    return {
        id = opts.id or "sess-1",
        tab = tab,
        attached_tab = tab,
        cwd = opts.cwd,
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

---@param kind string
---@param name string
---@param path string
---@param extra? table
---@return table
local function entry(kind, name, path, extra)
    return vim.tbl_extend("force", {
        kind = kind,
        name = name,
        path = path,
        repo_root = MAIN_DIR,
        head = "deadbeef",
        detached = true,
        prunable = false,
        missing = false,
    }, extra or {})
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

--- Let scheduled callbacks (the async list continuation) run.
local function flush()
    vim.wait(1000, function()
        return false
    end)
end

---@return string[]
local function buffer_lines()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(0), 0, -1, false)
end

describe(":PiSessions N (new worktree of this checkout)", function()
    local real_worktree
    local real_worktree_session
    local real_dialog
    local real_notify
    local orig_children

    ---@type { cwd?: string, name?: string, repo_cwd?: string, create?: boolean, new_tab?: boolean }[]
    local opened
    ---@type { dir: string, cb: fun(entries: table[]?, err: string?) }[]
    local list_calls
    ---@type { opts: table, cb: fun(choice: string?) }[]
    local selects
    ---@type { opts: table, cb: fun(value: string?) }[]
    local inputs
    ---@type string[]
    local warnings
    ---@type table<string, any>
    local worktrees
    ---@type fun(entries: table[]?, err?: string?)?
    local list_reply

    before_each(function()
        Config.setup({})
        SessionList._reset()
        Sidebar._reset()
        opened = {}
        list_calls = {}
        selects = {}
        inputs = {}
        warnings = {}
        list_reply = nil
        worktrees = {
            [MAIN_DIR] = { kind = "main", name = "repo", path = MAIN_DIR, repo_root = MAIN_DIR },
            [MANAGED_DIR] = { kind = "linked", name = "wt", path = MANAGED_DIR, repo_root = MAIN_DIR },
            [EXTERNAL_DIR] = { kind = "linked", name = "ext", path = EXTERNAL_DIR, repo_root = MAIN_DIR },
            -- Deleted checkout: detected but not a directory.
            [GONE_DIR] = { kind = "linked", name = "gone", path = GONE_DIR, repo_root = MAIN_DIR },
            -- A plain directory outside any repository (detect returns nil).
            [PLAIN_DIR] = nil,
        }

        orig_children = Manifest.children_of
        Manifest.children_of = function()
            return {}
        end

        real_worktree = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            detect = function(dir)
                return worktrees[dir]
            end,
            validate_name = function(name)
                if type(name) ~= "string" or name == "" then
                    return false, "worktree: name must be 1..64 characters"
                end
                if not name:match("^[%w][%w._-]*$") then
                    return false, "worktree: name may only contain letters, digits, '.', '_' and '-'"
                end
                return true, nil
            end,
            list = function(dir, cb)
                list_calls[#list_calls + 1] = { dir = dir, cb = cb }
                if list_reply then
                    list_reply(cb)
                end
            end,
        }

        real_worktree_session = package.loaded["pi.worktree_session"]
        package.loaded["pi.worktree_session"] = {
            open_existing = function(opts)
                opened[#opened + 1] = opts
            end,
        }

        real_dialog = package.loaded["pi.ui.dialog"]
        package.loaded["pi.ui.dialog"] = {
            select = function(opts, cb)
                selects[#selects + 1] = { opts = opts, cb = cb }
            end,
            input = function(opts, cb)
                inputs[#inputs + 1] = { opts = opts, cb = cb }
            end,
        }

        real_notify = package.loaded["pi.notify"]
        package.loaded["pi.notify"] = {
            warn = function(msg)
                warnings[#warnings + 1] = msg
            end,
            error = function(msg)
                warnings[#warnings + 1] = msg
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
        package.loaded["pi.ui.dialog"] = real_dialog
        package.loaded["pi.notify"] = real_notify
    end)

    --- Open the list with a single session in `cwd` and press `N`.
    ---@param cwd string
    ---@param sessions? pi.Session[]
    local function press_new_worktree(cwd, sessions)
        with_manager(sessions or { fake_session({ cwd = cwd }) }, function()
            SessionList.open()
            vim.api.nvim_win_set_cursor(0, { 1, 0 })
            press_key("N")
            flush()
        end)
    end

    describe("keymap and help", function()
        it("registers N with its own description", function()
            press_new_worktree(MAIN_DIR)
            local b = vim.fn.bufnr("pi://sessions")
            assert.is_true(b > 0)
            local map = vim.api.nvim_buf_call(b, function()
                return vim.fn.maparg("N", "n", false, true)
            end)
            assert.is_truthy(map and not vim.tbl_isempty(map))
            assert.are.equal("New worktree of this checkout (new tab)", map.desc)
        end)

        it("keeps n and W as they were", function()
            press_new_worktree(MAIN_DIR)
            local b = vim.fn.bufnr("pi://sessions")
            local n_map = vim.api.nvim_buf_call(b, function()
                return vim.fn.maparg("n", "n", false, true)
            end)
            assert.are.equal("New session in this checkout (new tab)", n_map.desc)
            local w_map = vim.api.nvim_buf_call(b, function()
                return vim.fn.maparg("W", "n", false, true)
            end)
            assert.is_true(vim.tbl_isempty(w_map))
        end)

        it("lists N in the help overlay", function()
            press_new_worktree(MAIN_DIR)
            press_key("?")

            local found = false
            for _, b in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_valid(b) then
                    for _, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
                        if line:find("New worktree of this checkout", 1, true) then
                            found = true
                        end
                    end
                end
            end
            assert.is_true(found, "help overlay should list the N key")
        end)
    end)

    describe("existing worktrees", function()
        it("offers every managed and external worktree", function()
            list_reply = function(cb)
                cb({ entry("linked", "wt", MANAGED_DIR, { branch = "feat/x", detached = false }) })
            end
            press_new_worktree(MANAGED_DIR)

            assert.are.equal(1, #list_calls)
            assert.are.equal(MAIN_DIR, list_calls[1].dir)
            assert.are.equal(1, #selects)
            assert.are.equal(0, #inputs)
            local options = selects[1].opts.options
            assert.are.equal(2, #options)
            assert.is_truthy(options[1]:find("wt", 1, true))
            assert.is_truthy(options[1]:find("feat/x", 1, true))
            assert.are.equal("New worktree…", options[2])
        end)

        it("opens the selected entry by its own path", function()
            list_reply = function(cb)
                cb({ entry("linked", "ext", EXTERNAL_DIR, { detached = true }) })
            end
            press_new_worktree(MAIN_DIR)

            local label = selects[1].opts.options[1]
            assert.is_truthy(label:find("detached", 1, true))
            selects[1].cb(label)
            flush()

            assert.are.equal(1, #opened)
            assert.are.equal(EXTERNAL_DIR, opened[1].cwd)
            assert.is_nil(opened[1].name)
        end)

        it("asks for a name when New worktree… is picked", function()
            list_reply = function(cb)
                cb({ entry("linked", "wt", MANAGED_DIR) })
            end
            press_new_worktree(MAIN_DIR)

            selects[1].cb("New worktree…")
            assert.are.equal(1, #inputs)
            inputs[1].cb("  fresh-name  ")
            assert.are.equal(1, #opened)
            assert.are.equal("fresh-name", opened[1].name)
            assert.are.equal(MAIN_DIR, opened[1].repo_cwd)
            assert.is_true(opened[1].create)
        end)

        it("filters missing checkouts and the main checkout", function()
            list_reply = function(cb)
                cb({
                    entry("linked", "gone", GONE_DIR, { missing = true }),
                    entry("main", "repo", MAIN_DIR),
                })
            end
            press_new_worktree(MAIN_DIR)

            -- Nothing left to pick: straight to the name input.
            assert.are.equal(0, #selects)
            assert.are.equal(1, #inputs)
        end)
    end)

    describe("empty list", function()
        it("goes straight to the name input and creates there", function()
            list_reply = function(cb)
                cb({})
            end
            press_new_worktree(MAIN_DIR)

            assert.are.equal(0, #selects)
            assert.are.equal(1, #inputs)
            assert.is_truthy(inputs[1].opts.title:find("repo", 1, true))
            inputs[1].cb("new-one")
            assert.are.equal(1, #opened)
            assert.are.equal("new-one", opened[1].name)
            assert.are.equal(MAIN_DIR, opened[1].repo_cwd)
            assert.is_true(opened[1].create)
        end)
    end)

    describe("guards", function()
        it("warns without listing when the checkout is not a git repository", function()
            press_new_worktree(PLAIN_DIR)

            assert.are.equal(0, #list_calls)
            assert.are.equal(0, #inputs)
            assert.are.equal(0, #selects)
            assert.are.equal(1, #warnings)
            assert.is_truthy(warnings[1]:find("not inside a git repository", 1, true))
        end)

        it("warns without a create prompt when the list fails", function()
            list_reply = function(cb)
                cb(nil, "list: not a git repository")
            end
            press_new_worktree(MAIN_DIR)

            assert.are.equal(1, #list_calls)
            assert.are.equal(0, #selects)
            assert.are.equal(0, #inputs)
            assert.are.equal(0, #opened)
            assert.are.equal(1, #warnings)
            assert.is_truthy(warnings[1]:find("Cannot list worktrees", 1, true))
        end)

        it("warns when the checkout is gone", function()
            press_new_worktree(GONE_DIR)

            assert.are.equal(0, #list_calls)
            assert.are.equal(0, #inputs)
            assert.are.equal(1, #warnings)
            assert.is_truthy(warnings[1]:find("no longer exists", 1, true))
        end)

        it("cancels on nil and blank names", function()
            list_reply = function(cb)
                cb({})
            end
            press_new_worktree(MAIN_DIR)

            inputs[1].cb(nil)
            assert.are.equal(0, #opened)
            inputs[1].cb("   ")
            assert.are.equal(0, #opened)
        end)

        it("refuses an invalid name without creating", function()
            list_reply = function(cb)
                cb({})
            end
            press_new_worktree(MAIN_DIR)

            inputs[1].cb("bad name")
            assert.are.equal(0, #opened)
            assert.is_true(#warnings >= 1)
        end)
    end)

    describe("repository snapshot", function()
        it("keeps the repository captured at keypress when the view changes", function()
            -- The enumeration hangs until the spec releases it.
            press_new_worktree(MAIN_DIR)
            assert.are.equal(1, #list_calls)
            assert.are.equal(MAIN_DIR, list_calls[1].dir)

            -- The list is re-rendered for a session in another repository (as
            -- a tab switch would do) while git is still running.
            local OTHER_DIR = vim.fn.tempname() .. "-other"
            vim.fn.mkdir(OTHER_DIR, "p")
            worktrees[OTHER_DIR] = { kind = "main", name = "other", path = OTHER_DIR, repo_root = OTHER_DIR }
            with_manager({ fake_session({ cwd = OTHER_DIR }) }, function()
                SessionList._render()
                assert.is_truthy(buffer_lines()[1]:find("●", 1, true))
            end)

            -- Release the pending enumeration: it still answers for the
            -- snapshotted repository.
            list_calls[1].cb({})
            flush()

            assert.are.equal(1, #list_calls)
            assert.are.equal(MAIN_DIR, list_calls[1].dir)
            assert.are.equal(1, #inputs)
            inputs[1].cb("after-switch")
            assert.are.equal(1, #opened)
            assert.are.equal(MAIN_DIR, opened[1].repo_cwd)
        end)

        it("does not enumerate worktrees on open or render", function()
            with_manager({ fake_session({ cwd = MAIN_DIR }) }, function()
                SessionList.open()
                SessionList._render()
                SessionList._render()
                flush()
            end)

            assert.are.equal(0, #list_calls)
            assert.are.equal(0, #selects)
            assert.are.equal(0, #inputs)
        end)
    end)
end)
