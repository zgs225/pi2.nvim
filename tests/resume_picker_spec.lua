-- :PiResume picker interactions — layered UI over the same opening logic.
--
-- With telescope installed the resume list gets a purpose-built picker:
-- <CR>/o open in the current tab, t/<C-t> open in a new tab, <C-x> delete,
-- plus a fixed key-hint title. Without telescope it falls back to the
-- generic vim.ui.select flow (unchanged behavior); there the snacks backend
-- customization additionally maps <C-t>. Opening a conversation that is
-- still live in another tab asks for confirmation first (two processes would
-- write one session file).
--
-- These specs drive the session manager against a stubbed Rpc with canned
-- responses — no real pi process, no real telescope (a fake module tree is
-- injected into package.loaded for the telescope-branch specs).

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")
local History = require("pi.sessions.history")
local Pi = require("pi")

Config.setup({})
Pi.setup({})

local T_TARGET = "/tmp/pi-resume-spec/target.jsonl"
local T_OTHER = "/tmp/pi-resume-spec/other.jsonl"

--- Fabricated history listing (history.list scans disk; stubbed here).
local fake_sessions_list

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }
local real_history_list = History.list
local real_notify = vim.notify
local real_select = vim.ui.select

--- Commands sent through the stub, in order.
local sent = {}
--- type -> fun(cmd): pi.RpcEvent; nil responder = never answered.
local responders = {}
--- vim.notify spy records.
local notes = {}
--- vim.ui.select spy: calls in order plus a one-shot answer() for the
--- most recent picker.
local select_spy

local function install_stub()
    sent = {}
    responders = {}
    notes = {}
    select_spy = { calls = {}, pending = nil }

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
        sent[#sent + 1] = vim.deepcopy(cmd)
        local responder = responders[cmd.type]
        if callback and responder then
            local res = responder(cmd)
            vim.schedule(function()
                callback(res)
            end)
        end
        return true
    end

    vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
    end

    vim.ui.select = function(items, opts, on_choice)
        select_spy.calls[#select_spy.calls + 1] = { items = items, opts = opts, on_choice = on_choice }
        select_spy.pending = on_choice
    end

    responders.get_commands = function()
        return { type = "response", success = true, data = { commands = {} } }
    end
    responders.get_state = function()
        return {
            type = "response",
            success = true,
            data = { model = { provider = "test", id = "m" }, autoCompactionEnabled = false, sessionFile = T_OTHER },
        }
    end
    responders.switch_session = function(_cmd)
        return { type = "response", success = true, data = { cancelled = false } }
    end
    responders.get_messages = function()
        return {
            type = "response",
            success = true,
            data = {
                messages = {
                    { role = "user", content = "original ask" },
                    { role = "assistant", content = "original answer" },
                },
            },
        }
    end
end

--- Drop into a pristine single-tab state; sweep stale sessions afterwards.
local function settle_tabs(first_tab)
    if vim.api.nvim_get_current_tabpage() ~= first_tab then
        vim.api.nvim_set_current_tabpage(first_tab)
    end
    vim.cmd("silent! tabonly!")
    Sessions._reset()
end

local function restore_stub(first_tab)
    settle_tabs(first_tab)
    Rpc.start = real_rpc.start
    Rpc.stop = real_rpc.stop
    Rpc.send = real_rpc.send
    History.list = real_history_list
    vim.notify = real_notify
    vim.ui.select = real_select
end

--- Wait until fn() is truthy; fail the spec with `what` otherwise.
local function wait_or_fail(fn, what)
    assert(vim.wait(3000, fn, 10), what)
end

--- First command of `type` sent after index `from` (0 = from start).
---@return table? cmd
---@return integer idx
local function find_after(from, type)
    for i = from + 1, #sent do
        if sent[i].type == type then
            return sent[i], i
        end
    end
    return nil, #sent
end

--- Most recent vim.ui.select call whose opts.kind matches.
---@return table?
local function last_select_call(kind)
    for i = #select_spy.calls, 1, -1 do
        if select_spy.calls[i].opts.kind == kind then
            return select_spy.calls[i]
        end
    end
    return nil
end

--- Create the fake telescope module tree and return recording state.
local function install_fake_telescope()
    ---@class FakeTeleState
    local state = { new_cfgs = {}, maps = {}, themes = {}, entry = nil }

    package.loaded["telescope"] = {}
    package.loaded["telescope.themes"] = {
        -- Record the theme input: pickers.new(opts, defaults) gives `opts`
        -- precedence, so the titles passed here are the ones telescope uses.
        get_dropdown = function(opts)
            state.themes[#state.themes + 1] = opts
            return opts or {}
        end,
    }
    package.loaded["telescope.pickers"] = {
        new = function(_, cfg)
            state.new_cfgs[#state.new_cfgs + 1] = cfg
            return { find = function() end }
        end,
    }
    package.loaded["telescope.finders"] = {
        new_table = function(tbl)
            return tbl
        end,
    }
    package.loaded["telescope.config"] = {
        values = {
            generic_sorter = function()
                return "sorter"
            end,
        },
    }
    package.loaded["telescope.actions"] = {
        -- Called as a method: replace(self, replacement_fn).
        select_default = {
            replace = function(_self, fn)
                state.select_default = fn
            end,
        },
        close = function(bufnr)
            state.closed_bufnr = bufnr
        end,
    }
    package.loaded["telescope.actions.state"] = {
        get_selected_entry = function(_bufnr)
            return state.entry
        end,
        get_multi_selection = function(_bufnr)
            return {}
        end,
        get_current_picker = function(_bufnr)
            return {
                refresh = function(_, finder)
                    state.refreshed_finder = finder
                end,
            }
        end,
    }
    return state
end

local FAKE_MODULES = {
    "telescope",
    "telescope.themes",
    "telescope.pickers",
    "telescope.finders",
    "telescope.config",
    "telescope.actions",
    "telescope.actions.state",
}

local function remove_fake_telescope()
    for _, name in ipairs(FAKE_MODULES) do
        package.loaded[name] = nil
    end
end

describe("pi resume picker", function()
    local first_tab

    before_each(function()
        install_stub()
        History.list = function()
            return fake_sessions_list
                or {
                    {
                        path = T_TARGET,
                        name = nil,
                        timestamp = "2025-06-01T10:00:00.000Z",
                        first_message = "original ask",
                    },
                    {
                        path = T_OTHER,
                        name = "named session",
                        timestamp = "2025-06-02T11:00:00.000Z",
                        first_message = "",
                    },
                }
        end
        fake_sessions_list = nil
        first_tab = vim.api.nvim_get_current_tabpage()
    end)

    after_each(function()
        remove_fake_telescope()
        restore_stub(first_tab)
    end)

    it("falls back to vim.ui.select without telescope and carries item/file data", function()
        Sessions.resume_session()

        assert.is_not_nil(select_spy.pending)
        local call = last_select_call("pi-resume-session")
        assert.is_not_nil(call)
        assert.equals("Resume session", call.opts.prompt)
        assert.equals(2, #call.items)
        assert.equals(T_TARGET, call.items[1].file)
        assert.equals("named session", call.items[2].session.name)

        -- Row rendering stays date + label.
        local label = call.opts.format_item(call.items[1])
        assert.truthy(label:find("2025%-06%-01  original ask", 1, false))
        local label2 = call.opts.format_item(call.items[2])
        assert.truthy(label2:find("2025%-06%-02  named session", 1, false))
    end)

    it("opening from the fallback picker loads the session in the current tab", function()
        local before_tabs = #vim.api.nvim_list_tabpages()

        Sessions.resume_session()
        local call = last_select_call("pi-resume-session")
        call.on_choice(call.items[1])

        wait_or_fail(function()
            local switch, sidx = find_after(0, "switch_session")
            return switch ~= nil and sidx ~= nil and find_after(sidx, "get_messages") ~= nil
        end, "switch_session was not sent")

        local switch, sidx = find_after(0, "switch_session")
        assert.equals(T_TARGET, switch.sessionPath)
        assert.not_nil(find_after(sidx, "get_messages"))
        assert.equals(before_tabs, #vim.api.nvim_list_tabpages())
    end)

    it("snacks action resume_new_tab opens the picked session in a new tab", function()
        local before_tabs = #vim.api.nvim_list_tabpages()

        Sessions.resume_session()
        local call = last_select_call("pi-resume-session")
        assert.is_not_nil(call.opts.snacks and call.opts.snacks.actions.resume_new_tab)

        local closed = false
        call.opts.snacks.actions.resume_new_tab({
            selected = function()
                return { { item = call.items[1] } }
            end,
            close = function()
                closed = true
            end,
        })

        wait_or_fail(function()
            return #vim.api.nvim_list_tabpages() == before_tabs + 1
        end, "new tab was not opened")
        assert.is_true(closed)

        wait_or_fail(function()
            local sess = Sessions.get()
            return sess ~= nil and find_after(0, "switch_session") ~= nil
        end, "session was not loaded into the new tab")

        local switch = find_after(0, "switch_session")
        assert.equals(T_TARGET, switch.sessionPath)
        -- The live session belongs to the fresh tabpage, not the original one.
        assert.not_equals(first_tab, Sessions.get().tab)
    end)

    it("reopening a conversation that lives in another tab asks for confirmation and honours decline", function()
        -- Tab 2 hosts the very conversation being picked.
        vim.cmd("tabnew")
        local elsewhere = Sessions.get_or_create()
        assert.is_not_nil(elsewhere)
        wait_or_fail(function()
            return elsewhere.session_file == T_OTHER
        end, "live session did not capture its backend file")
        vim.cmd("tabprevious")
        assert.equals(first_tab, vim.api.nvim_get_current_tabpage())

        Sessions.resume_session()
        local call = last_select_call("pi-resume-session")
        call.on_choice(call.items[2]) -- T_OTHER, live in tab 2

        wait_or_fail(function()
            return last_select_call("pi-confirm") ~= nil
        end, "confirmation dialog was not shown")

        select_spy.pending("No")
        assert.equals(nil, find_after(0, "switch_session"), "declined open must not switch sessions")
    end)

    it("confirming the duplicate-open warning switches in place", function()
        vim.cmd("tabnew")
        local elsewhere = Sessions.get_or_create()
        assert.is_not_nil(elsewhere)
        wait_or_fail(function()
            return elsewhere.session_file == T_OTHER
        end, "live session did not capture its backend file")
        vim.cmd("tabprevious")

        Sessions.resume_session()
        local call = last_select_call("pi-resume-session")
        call.on_choice(call.items[2]) -- T_OTHER, live in tab 2

        wait_or_fail(function()
            return last_select_call("pi-confirm") ~= nil
        end, "confirmation dialog was not shown")
        select_spy.pending("Yes")

        wait_or_fail(function()
            return find_after(0, "switch_session") ~= nil
        end, "confirmed open must switch sessions")
        local switch = find_after(0, "switch_session")
        assert.equals(T_OTHER, switch.sessionPath)
    end)

    it("picking a session with no live copy elsewhere skips the confirmation entirely", function()
        vim.cmd("tabnew")
        local elsewhere = Sessions.get_or_create()
        assert.is_not_nil(elsewhere)
        wait_or_fail(function()
            return elsewhere.session_file == T_OTHER
        end, "live session did not capture its backend file")
        vim.cmd("tabprevious")

        Sessions.resume_session()
        local call = last_select_call("pi-resume-session")
        call.on_choice(call.items[1]) -- T_TARGET: nowhere live

        wait_or_fail(function()
            return find_after(0, "switch_session") ~= nil
        end, "uncontended open must go straight through")
        assert.is_nil(last_select_call("pi-confirm"), "no confirmation expected for a non-live session")
    end)

    describe("with telescope installed", function()
        local tele

        before_each(function()
            tele = install_fake_telescope()
        end)

        it("builds a dedicated picker instead of calling vim.ui.select", function()
            Sessions.resume_session()

            assert.equals(1, #tele.new_cfgs)
            assert.equals(nil, select_spy.pending, "fallback vim.ui.select must not be used")

            -- Titles live in the theme table (first pickers.new arg), which
            -- wins over get_dropdown's own results_title = false.
            local theme = tele.themes[1]
            assert.is_not_nil(theme)
            assert.equals("Resume session", theme.prompt_title)
            assert.truthy(theme.results_title:find("<CR>/o open", 1, true))
            assert.truthy(theme.results_title:find("t/<C%-t> new tab", 1, false))
            assert.truthy(theme.results_title:find("<C%-x> delete", 1, false))

            local cfg = tele.new_cfgs[1]
            assert.equals(false, theme.previewer)
            assert.equals(2, #cfg.finder.results)
            assert.equals(T_TARGET, cfg.finder.results[1].file)
        end)

        it("maps o/t/<C-t> and opens rows via select_default and <C-t>", function()
            local before_tabs = #vim.api.nvim_list_tabpages()

            Sessions.resume_session()
            local cfg = tele.new_cfgs[1]
            cfg.attach_mappings(7, function(_modes, lhs, fn)
                tele.maps[lhs] = fn
            end)

            -- select_default -> current tab.
            tele.entry = { value = cfg.finder.results[1] }
            tele.select_default()
            wait_or_fail(function()
                local switch, sidx = find_after(0, "switch_session")
                return switch ~= nil and sidx ~= nil and find_after(sidx, "get_messages") ~= nil
            end, "select_default did not open in place")
            local switch = find_after(0, "switch_session")
            assert.equals(T_TARGET, switch.sessionPath)
            assert.equals(before_tabs, #vim.api.nvim_list_tabpages())
            assert.equals(7, tele.closed_bufnr)

            -- normal-mode o -> current tab too.
            install_stub()
            local base_o = #sent
            Sessions.resume_session()
            cfg = tele.new_cfgs[2]
            cfg.attach_mappings(8, function(_modes, lhs, fn)
                tele.maps[lhs] = fn
            end)
            tele.entry = { value = cfg.finder.results[1] }
            local o_target_path = tele.entry.value.file
            assert.equals(T_TARGET, o_target_path)
            tele.maps["o"]()
            wait_or_fail(function()
                return find_after(base_o, "switch_session") ~= nil
            end, "o did not open in place")

            -- normal-mode t -> new tab.
            local tabs_before_t = #vim.api.nvim_list_tabpages()
            install_stub()
            local base_t = #sent
            Sessions.resume_session()
            cfg = tele.new_cfgs[3]
            cfg.attach_mappings(9, function(_modes, lhs, fn)
                tele.maps[lhs] = fn
            end)
            tele.entry = { value = cfg.finder.results[1] }
            tele.maps["t"]()

            wait_or_fail(function()
                return #vim.api.nvim_list_tabpages() == tabs_before_t + 1
                    and find_after(base_t, "switch_session") ~= nil
            end, "t did not open a new tab")

            -- <C-t> (bound in insert mode, n mode is the same opener) -> new tab.
            local tabs_before_ct = #vim.api.nvim_list_tabpages()
            install_stub()
            local base_ct = #sent
            Sessions.resume_session()
            cfg = tele.new_cfgs[4]
            cfg.attach_mappings(10, function(_modes, lhs, fn)
                tele.maps[lhs] = fn
            end)
            tele.entry = { value = cfg.finder.results[1] }
            tele.maps["<C-t>"]()
            wait_or_fail(function()
                return #vim.api.nvim_list_tabpages() == tabs_before_ct + 1
                    and find_after(base_ct, "switch_session") ~= nil
            end, "<C-t> did not open a new tab")
        end)
    end)

    it("excludes sub-sessions registered in the manifest", function()
        local Manifest = require("pi.subsessions.manifest")
        local orig_is_child = Manifest.is_child_session
        Manifest.is_child_session = function(id)
            return id == "child-session-id"
        end

        History.list = function()
            return {
                {
                    path = T_TARGET,
                    id = "parent-session-id",
                    name = "parent",
                    timestamp = "2025-06-01T10:00:00.000Z",
                    first_message = "parent ask",
                },
                {
                    path = T_OTHER,
                    id = "child-session-id",
                    name = "child worker",
                    timestamp = "2025-06-02T11:00:00.000Z",
                    first_message = "child task",
                },
            }
        end

        Sessions.resume_session()
        local call = last_select_call("pi-resume-session")
        Manifest.is_child_session = orig_is_child

        assert.equals(1, #call.items)
        assert.equals("parent-session-id", call.items[1].session.id)
    end)
end)
