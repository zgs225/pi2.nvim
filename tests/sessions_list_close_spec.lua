-- `x` in :PiSessions closes what is under the cursor: a sub-session's RPC
-- process on a child row (unchanged), a session's **PiTab** on a session row —
-- the process stops and its tabpage closes — or every PiTab of a worktree group
-- on a group header. Each scope asks for confirmation first unless its own
-- switch is off (`sessions_list.confirm_close_child` / `_session` / `_group`;
-- all three default to `true`).
--
-- `pi.worktree` and the session manager are stubbed (no git, no real process),
-- and confirmations are answered through a stubbed `vim.ui.select`, so the spec
-- observes exactly which sessions were closed and which tabs disappeared.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local SessionList = require("pi.ui.sessions")
local Sidebar = require("pi.ui.sidebar")

---@type table<string, { kind: string, name: string, path: string, repo_root: string }>
local WORKTREES = {
    ["/repo/main"] = { kind = "main", name = "main", path = "/repo/main", repo_root = "/repo/main" },
    ["/repo/wt"] = { kind = "linked", name = "wt", path = "/repo/wt", repo_root = "/repo/main" },
}

---@param opts? { id?: string, tab?: integer, cwd?: string, view_parent_id?: string }
---@return pi.Session
local function fake_session(opts)
    opts = opts or {}
    local tab = opts.tab or vim.api.nvim_get_current_tabpage()
    return {
        id = opts.id or ("sess-" .. tostring(math.random(1000, 9999))),
        tab = tab,
        attached_tab = tab,
        cwd = opts.cwd,
        view_parent_id = opts.view_parent_id,
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
            hide = function() end,
            clear = function() end,
        },
    }
end

--- Run `fn` with the session manager stubbed to `sessions`; every
--- `close_session` call is recorded in the table handed to `fn`.
---@param sessions pi.Session[]
---@param fn fun(closed: pi.Session[])
local function with_manager(sessions, fn)
    local real = package.loaded["pi.sessions.manager"]
    local closed = {}
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
        close_session = function(session)
            closed[#closed + 1] = session
        end,
    }
    local ok, err = pcall(fn, closed)
    package.loaded["pi.sessions.manager"] = real
    if not ok then
        error(err)
    end
end

--- Run `fn` answering every `vim.ui.select` (the confirmation picker) with
--- `choice`; the prompts are recorded and handed to `fn`.
---@param choice string?
---@param fn fun(prompts: { prompt: string }[])
local function with_picker(choice, fn)
    local real = vim.ui.select
    local prompts = {}
    vim.ui.select = function(_, opts, on_choice)
        prompts[#prompts + 1] = { prompt = opts and opts.prompt or "" }
        on_choice(choice)
    end
    local ok, err = pcall(fn, prompts)
    vim.ui.select = real
    if not ok then
        error(err)
    end
end

--- Replace `pi.notify` for one test, recording calls.
---@param fn fun(messages: string[])
local function with_notify(fn)
    local real = package.loaded["pi.notify"]
    local messages = {}
    package.loaded["pi.notify"] = {
        info = function(msg)
            messages[#messages + 1] = msg
        end,
        warn = function(msg)
            messages[#messages + 1] = msg
        end,
        error = function(msg)
            messages[#messages + 1] = msg
        end,
    }
    local ok, err = pcall(fn, messages)
    package.loaded["pi.notify"] = real
    if not ok then
        error(err)
    end
end

local function press_key(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
end

---@return string[]
local function buffer_lines()
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(0), 0, -1, false)
end

--- Create a real tabpage bound to a fake session (so `x` has a tab to close).
---@param opts { id: string, cwd?: string }
---@return pi.Session
local function session_in_new_tab(opts)
    vim.cmd("tabnew")
    return fake_session({ id = opts.id, cwd = opts.cwd, tab = vim.api.nvim_get_current_tabpage() })
end

describe("session list close key", function()
    local real_worktree
    local orig_children
    local first_tab

    before_each(function()
        Config.setup({ sessions_list = { mode = "side" } })
        SessionList._reset()
        Sidebar._reset()
        first_tab = vim.api.nvim_get_current_tabpage()
        orig_children = Manifest.children_of
        real_worktree = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            detect = function(dir)
                return WORKTREES[dir]
            end,
        }
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
        Sidebar._reset()
        Manifest.children_of = orig_children
        package.loaded["pi.worktree"] = real_worktree
        if vim.api.nvim_tabpage_is_valid(first_tab) then
            vim.api.nvim_set_current_tabpage(first_tab)
        end
        local guard = 0
        while #vim.api.nvim_list_tabpages() > 1 and guard < 20 do
            guard = guard + 1
            vim.cmd("tabclose")
        end
    end)

    it("binds x to the close action in the list buffer", function()
        SessionList.open()
        local map = vim.fn.maparg("x", "n", false, true)
        assert.equals(1, map.buffer)
        assert.equals("Close sub-session, session tab, or worktree group", map.desc)
    end)

    describe("sub-session rows", function()
        it("asks before closing a child's RPC process and closes it on yes", function()
            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return { { _id = "c1", name = "worker", status = "active", parent_id = "parent-1", config = {} } }
                end
                return {}
            end
            local parent = fake_session({ id = "parent-1", tab = first_tab })
            local real_subsessions = package.loaded["pi.subsessions"]
            local closed_children = {}
            package.loaded["pi.subsessions"] = {
                close = function(id)
                    closed_children[#closed_children + 1] = id
                end,
            }
            local exited = false
            pcall(function()
                with_manager({ parent }, function()
                    SessionList.open()
                    -- line 1 = parent row, line 2 = the child row
                    vim.api.nvim_win_set_cursor(0, { 2, 0 })

                    -- No: nothing closes.
                    with_picker("No", function(prompts)
                        press_key("x")
                        assert.equals(1, #prompts)
                        assert.is_truthy(prompts[1].prompt:find("Close sub-session", 1, true))
                    end)
                    assert.are.same({}, closed_children)

                    -- Yes: the child process closes, no tab is touched.
                    with_picker("Yes", function()
                        press_key("x")
                    end)
                    assert.are.same({ "c1" }, closed_children)
                    assert.are.equal(1, #vim.api.nvim_list_tabpages())
                end)
                exited = true
            end)
            package.loaded["pi.subsessions"] = real_subsessions
            assert.is_true(exited)
        end)

        it("closes without asking when confirm_close_child is false", function()
            Manifest.children_of = function(lineage)
                if lineage == "parent-1" then
                    return { { _id = "c1", name = "worker", status = "active", parent_id = "parent-1", config = {} } }
                end
                return {}
            end
            Config.setup({ sessions_list = { mode = "side", confirm_close_child = false } })
            local parent = fake_session({ id = "parent-1", tab = first_tab })
            local real_subsessions = package.loaded["pi.subsessions"]
            local closed_children = {}
            package.loaded["pi.subsessions"] = {
                close = function(id)
                    closed_children[#closed_children + 1] = id
                end,
            }
            local exited = false
            pcall(function()
                with_manager({ parent }, function()
                    SessionList.open()
                    vim.api.nvim_win_set_cursor(0, { 2, 0 })
                    with_picker(nil, function(prompts)
                        press_key("x")
                        assert.are.same({}, prompts)
                    end)
                end)
                exited = true
            end)
            package.loaded["pi.subsessions"] = real_subsessions
            assert.is_true(exited)
            assert.are.same({ "c1" }, closed_children)
        end)
    end)

    describe("session rows", function()
        it("asks by default, then stops the session and closes its tab on yes", function()
            local a = fake_session({ id = "A", tab = first_tab })
            local b = session_in_new_tab({ id = "B" })
            local b_tab = b.tab
            vim.api.nvim_set_current_tabpage(first_tab)

            with_manager({ a, b }, function(closed)
                SessionList.open()
                assert.are.equal(2, #buffer_lines())
                vim.api.nvim_win_set_cursor(0, { 2, 0 })

                with_picker("No", function(prompts)
                    press_key("x")
                    assert.equals(1, #prompts)
                    assert.is_truthy(prompts[1].prompt:find("Close session", 1, true))
                end)
                assert.are.same({}, closed)
                assert.is_true(vim.api.nvim_tabpage_is_valid(b_tab))

                with_picker("Yes", function()
                    press_key("x")
                end)
                assert.are.same({ b }, closed)
                assert.is_false(vim.api.nvim_tabpage_is_valid(b_tab))
                -- Focus returns to the tab that was current before the close.
                assert.are.equal(first_tab, vim.api.nvim_get_current_tabpage())
            end)
        end)

        it("closes without asking when confirm_close_session is false", function()
            Config.setup({ sessions_list = { mode = "side", confirm_close_session = false } })
            local a = fake_session({ id = "A", tab = first_tab })
            local b = session_in_new_tab({ id = "B" })
            local b_tab = b.tab
            vim.api.nvim_set_current_tabpage(first_tab)

            with_manager({ a, b }, function(closed)
                SessionList.open()
                vim.api.nvim_win_set_cursor(0, { 2, 0 })
                with_picker(nil, function(prompts)
                    press_key("x")
                    assert.are.same({}, prompts)
                end)
                assert.are.same({ b }, closed)
                assert.is_false(vim.api.nvim_tabpage_is_valid(b_tab))
            end)
        end)

        it("keeps the last tab and reports it", function()
            Config.setup({ sessions_list = { mode = "side", confirm_close_session = false } })
            local a = fake_session({ id = "A", tab = first_tab })

            with_notify(function(messages)
                with_manager({ a }, function(closed)
                    SessionList.open()
                    assert.are.equal(1, #buffer_lines())
                    press_key("x")
                    assert.are.same({ a }, closed)
                    assert.is_true(vim.api.nvim_tabpage_is_valid(first_tab))
                    assert.equals(1, #messages)
                    assert.is_truthy(messages[1]:find("kept 1 tab", 1, true))
                end)
            end)
        end)
    end)

    describe("worktree group headers", function()
        it("asks by default and closes every PiTab of the group on yes", function()
            local main = fake_session({ id = "M", tab = first_tab, cwd = "/repo/main" })
            local w1 = session_in_new_tab({ id = "W1", cwd = "/repo/wt" })
            local w2 = session_in_new_tab({ id = "W2", cwd = "/repo/wt" })
            local w1_tab, w2_tab = w1.tab, w2.tab
            vim.api.nvim_set_current_tabpage(first_tab)

            with_manager({ main, w1, w2 }, function(closed)
                SessionList.open()
                -- 1 main header, 2 main row, 3 wt header, 4 W1, 5 W2
                -- (the current checkout is pinned first).
                assert.are.equal(5, #buffer_lines())
                vim.api.nvim_win_set_cursor(0, { 3, 0 })

                with_picker("No", function(prompts)
                    press_key("x")
                    assert.equals(1, #prompts)
                    assert.is_truthy(prompts[1].prompt:find("Close worktree group", 1, true))
                    assert.is_truthy(prompts[1].prompt:find("all 2", 1, true))
                end)
                assert.are.same({}, closed)
                assert.is_true(vim.api.nvim_tabpage_is_valid(w1_tab))
                assert.is_true(vim.api.nvim_tabpage_is_valid(w2_tab))

                with_picker("Yes", function()
                    press_key("x")
                end)
                assert.are.same({ w1, w2 }, closed)
                assert.is_false(vim.api.nvim_tabpage_is_valid(w1_tab))
                assert.is_false(vim.api.nvim_tabpage_is_valid(w2_tab))
                assert.is_true(vim.api.nvim_tabpage_is_valid(first_tab))
            end)
        end)

        it("closes a folded group from its header (members come from the live sessions)", function()
            local main = fake_session({ id = "M", tab = first_tab, cwd = "/repo/main" })
            local w1 = session_in_new_tab({ id = "W1", cwd = "/repo/wt" })
            local w2 = session_in_new_tab({ id = "W2", cwd = "/repo/wt" })
            local w1_tab, w2_tab = w1.tab, w2.tab
            vim.api.nvim_set_current_tabpage(first_tab)

            with_manager({ main, w1, w2 }, function(closed)
                SessionList.open()
                vim.api.nvim_win_set_cursor(0, { 3, 0 })
                press_key("<Tab>")
                -- The folded group renders no member rows.
                assert.are.equal(3, #buffer_lines())

                Config.setup({ sessions_list = { mode = "side", confirm_close_group = false } })
                with_picker(nil, function(prompts)
                    press_key("x")
                    assert.are.same({}, prompts)
                end)
                assert.are.same({ w1, w2 }, closed)
                assert.is_false(vim.api.nvim_tabpage_is_valid(w1_tab))
                assert.is_false(vim.api.nvim_tabpage_is_valid(w2_tab))
            end)
        end)

        it("keeps the session confirmation switch independent", function()
            local main = fake_session({ id = "M", tab = first_tab, cwd = "/repo/main" })
            local w1 = session_in_new_tab({ id = "W1", cwd = "/repo/wt" })
            local w1_tab = w1.tab
            vim.api.nvim_set_current_tabpage(first_tab)

            -- Group confirmations off, session confirmations still on.
            Config.setup({ sessions_list = { mode = "side", confirm_close_group = false } })

            with_manager({ main, w1 }, function(closed)
                SessionList.open()
                -- 1 main header, 2 main row, 3 wt header, 4 W1
                assert.are.equal(4, #buffer_lines())
                -- The group header closes without asking.
                vim.api.nvim_win_set_cursor(0, { 3, 0 })
                with_picker(nil, function(prompts)
                    press_key("x")
                    assert.are.same({}, prompts)
                end)
                assert.are.same({ w1 }, closed)
                assert.is_false(vim.api.nvim_tabpage_is_valid(w1_tab))

                -- The surviving session row still asks.
                vim.api.nvim_win_set_cursor(0, { 2, 0 })
                with_picker("No", function(prompts)
                    press_key("x")
                    assert.equals(1, #prompts)
                    assert.is_truthy(prompts[1].prompt:find("Close session", 1, true))
                end)
                assert.are.same({ w1 }, closed)
            end)
        end)
    end)
end)
