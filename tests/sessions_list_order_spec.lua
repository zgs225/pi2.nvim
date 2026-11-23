-- :PiSessions list order must follow the tabline, not tabpage handles (issue #63).
--
-- Tabpage handles reflect creation order: `:tabnew` from tab 1 inserts the new
-- tab between tabs 1 and 2, and :tabmove reorders tabs without touching
-- handles. Sessions.list() used to sort by handle, so the sessions list could
-- disagree with the tabline (e.g. tabs 2 and 3 swapped). These specs pin the
-- visual-order invariant. They drive the session manager against a stubbed
-- Rpc: no real pi process, canned responses (see session_model_pin_spec.lua).

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")
local TabOrder = require("pi.sessions.tab_order")

Config.setup({})

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }

local function install_stub()
    Rpc.start = function(self)
        self._job_id = 999
        return true
    end
    Rpc.stop = function(self)
        self._job_id = nil
        self._pending = {}
    end
    Rpc.send = function(self, cmd, callback)
        if not self._job_id then
            return false
        end
        if not cmd.id then
            cmd.id = self._tab .. ":" .. self._req_id
            self._req_id = self._req_id + 1
        end
        if callback then
            vim.schedule(function()
                callback({ type = "response", success = true, data = {} })
            end)
        end
        return true
    end
end

local function restore_stub()
    Rpc.start = real_rpc.start
    Rpc.stop = real_rpc.stop
    Rpc.send = real_rpc.send
end

--- Tabpage handles in current visual order.
local function visual_tabs()
    return vim.api.nvim_list_tabpages()
end

--- Tab handles of Sessions.list(), in listing order.
local function listed_tabs()
    local tabs = {}
    for _, session in ipairs(Sessions.list()) do
        tabs[#tabs + 1] = session.tab
    end
    return tabs
end

describe("sessions list order (issue #63)", function()
    local start_tab

    before_each(function()
        install_stub()
        start_tab = vim.api.nvim_get_current_tabpage()
    end)

    after_each(function()
        -- Stop every session first, then close the tabs we created; closing
        -- tabs with live sessions would trigger TabClosed cleanup too, so
        -- doing sessions first keeps teardown deterministic.
        for _, tab in ipairs(visual_tabs()) do
            vim.api.nvim_set_current_tabpage(tab)
            Sessions.stop()
        end
        for _, tab in ipairs(visual_tabs()) do
            if tab ~= start_tab and vim.api.nvim_tabpage_is_valid(tab) then
                vim.api.nvim_set_current_tabpage(tab)
                vim.cmd("tabclose!")
            end
        end
        vim.api.nvim_set_current_tabpage(start_tab)
        restore_stub()
    end)

    it("lists sessions in tabline order", function()
        Sessions.get_or_create()
        vim.cmd("tabnew")
        Sessions.get_or_create()
        vim.cmd("tabnew")
        Sessions.get_or_create()

        assert.are.same(visual_tabs(), listed_tabs())
    end)

    it("follows the tabline when a new tab is inserted mid-list", function()
        Sessions.get_or_create()
        vim.cmd("tabnew")
        Sessions.get_or_create()

        -- A tab created from tab 1 lands between tabs 1 and 2: its handle is
        -- the largest one, but visually it comes second. Handle-order listing
        -- would swap it with the last tab.
        vim.cmd("tabfirst")
        vim.cmd("tabnew")
        Sessions.get_or_create()

        local visual = visual_tabs()
        assert.is_true(#visual == 3, "expected three tabs")
        -- Precondition: visual order differs from handle order, so this
        -- scenario actually exercises the bug.
        local by_handle = { unpack(visual) }
        table.sort(by_handle)
        assert.are_not.same(by_handle, visual)
        assert.are.same(visual, listed_tabs())
    end)

    it("drops a session whose tabpage is gone", function()
        -- TabClosed cleanup runs on vim.schedule, so a just-closed tab's session
        -- is briefly still attached to an invalid handle. It must not render as a
        -- phantom row at the end of the list.
        Sessions._register_for_test({
            id = "stale-tab",
            attached_tab = 987654,
            tab = 987654,
            cwd = "/tmp",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        })

        assert.are.equal(0, #Sessions.list())
    end)

    it("places a new tab inside its checkout's block", function()
        local main_dir = vim.fn.tempname() .. "-main"
        local wt_dir = vim.fn.tempname() .. "-wt"
        vim.fn.mkdir(main_dir, "p")
        vim.fn.mkdir(wt_dir, "p")
        -- Compare real paths: macOS keeps tempname() under the `/var` ->
        -- `/private/var` symlink while `session.cwd` is already resolved, so a
        -- plain string compare never matches and the placement silently looks
        -- like a no-op (only the tabline order assertion catches it).
        local main_real = vim.uv.fs_realpath(main_dir) or main_dir
        local wt_real = vim.uv.fs_realpath(wt_dir) or wt_dir
        local real_worktree = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            detect = function(dir)
                if dir == main_real then
                    return { kind = "main", name = "main", path = main_real, repo_root = main_real }
                end
                if dir == wt_real then
                    return { kind = "linked", name = "wt", path = wt_real, repo_root = main_real }
                end
                return nil
            end,
        }
        TabOrder.reset()
        local original_cwd = vim.fn.getcwd()
        local ok, err = pcall(function()
            vim.cmd("cd " .. vim.fn.fnameescape(main_dir))
            Sessions.get_or_create()
            vim.cmd("tabnew")
            vim.cmd("cd " .. vim.fn.fnameescape(wt_dir))
            Sessions.get_or_create()
            vim.cmd("tabnew")
            vim.cmd("cd " .. vim.fn.fnameescape(main_dir))
            Sessions.get_or_create()
            local main_last = vim.api.nvim_get_current_tabpage()

            -- Open a new main-checkout session from tab 1: `:tabnew` inserts the
            -- tab at position 2, outside its block, so placement has to move it.
            vim.cmd("tabfirst")
            Sessions.new_tab()

            local visual = visual_tabs()
            assert.are.equal(4, #visual, "expected four tabs")
            local new_tab = vim.api.nvim_get_current_tabpage()
            assert.are.equal(main_last, visual[3], "the pre-existing block keeps its tabs")
            assert.are.equal(new_tab, visual[4], "the new tab joined its block's last tab")
            assert.are.same(visual, listed_tabs())
        end)
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        package.loaded["pi.worktree"] = real_worktree
        TabOrder.reset()
        if not ok then
            error(err)
        end
    end)

    it("follows the tabline after :tabmove", function()
        Sessions.get_or_create()
        vim.cmd("tabnew")
        Sessions.get_or_create()
        vim.cmd("tabnew")
        Sessions.get_or_create()

        vim.cmd("tabfirst")
        vim.cmd("tabnext 3")
        vim.cmd("tabmove 0") -- move the last tab to the front

        assert.are.same(visual_tabs(), listed_tabs())
    end)
end)
