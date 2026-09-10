-- Sessions-list `p` key (issue #107): preview ANY row — parent/tab rows
-- included — in the read-only sub-session viewer. The target id prefers the
-- live session object's id (freshest across the tmp-N → real-id migration) and
-- the row's resolved display name is forwarded to the viewer. `x` stays
-- sub-session-only. The viewer module is stubbed so this spec does not depend
-- on the viewer's own generalization landing first.

local SessionList = require("pi.ui.sessions")

--- Fake session with just enough surface for the list render and the preview
--- key. Answers the get_state name fetch like the real backend (scheduled), so
--- rows resolve to `opts.name` through the normal name path.
---@param opts? { tab?: integer, id?: string, name?: string, running?: boolean }
---@return table
local function fake_session(opts)
    opts = opts or {}
    local s = {
        tab = opts.tab or vim.api.nvim_get_current_tabpage(),
        id = opts.id or "session-id",
        rpc = {
            is_running = function()
                return opts.running ~= false
            end,
        },
        chat = {
            is_streaming = function()
                return false
            end,
            is_compacting = function()
                return false
            end,
            extension_status = function()
                return nil
            end,
        },
    }
    -- Assigned after construction: a closure inside the initializer would
    -- resolve `s` as a global under LuaJIT, not the in-progress local.
    s.rpc.send = function(_, req, cb)
        if req.type == "get_state" then
            vim.schedule(function()
                cb({ success = true, data = { sessionName = opts.name or "fake session" } })
            end)
        end
        return true
    end
    return s
end

--- Stub the viewer and pi.subsessions with call recorders while fn runs;
--- both are restored afterwards (even on error). `preview` is recorded
--- separately so a regression that routes `p` back through the
--- sub-session-only helper is visible rather than silently passing.
---@param fn fun(calls: { viewer: { id: string, opts: table? }[], close: string[], preview: string[] })
local function with_key_stubs(fn)
    local real_viewer = package.loaded["pi.ui.subsession_viewer"]
    local real_subsessions = package.loaded["pi.subsessions"]
    local calls = { viewer = {}, close = {}, preview = {} }
    package.loaded["pi.ui.subsession_viewer"] = {
        ---@param id string
        ---@param opts? table
        open = function(id, opts)
            calls.viewer[#calls.viewer + 1] = { id = id, opts = opts }
        end,
        close = function() end,
    }
    package.loaded["pi.subsessions"] = {
        ---@param child_id string
        close = function(child_id)
            -- A nil id is recorded as a sentinel: a plain `t[#t+1] = nil`
            -- leaves no hole to count, hiding a regression.
            calls.close[#calls.close + 1] = child_id == nil and "<nil>" or child_id
        end,
        ---@param child_id string
        preview = function(child_id)
            calls.preview[#calls.preview + 1] = child_id
        end,
    }
    local ok, err = pcall(fn, calls)
    package.loaded["pi.ui.subsession_viewer"] = real_viewer
    package.loaded["pi.subsessions"] = real_subsessions
    if not ok then
        error(err)
    end
end

--- Stub pi.sessions.manager to a fixed session list plus an optional id →
--- session lookup while fn runs; restored afterwards (even on error).
---@param sessions table[]
---@param fn fun()
---@param by_id? table<string, table>
local function with_manager(sessions, fn, by_id)
    local real_manager = package.loaded["pi.sessions.manager"]
    package.loaded["pi.sessions.manager"] = {
        list = function()
            return sessions
        end,
        get = function()
            return nil
        end,
        ---@param id string
        ---@return table?
        get_by_id = function(id)
            if by_id then
                return by_id[id]
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

--- Temporarily replace the manifest's child listing; restored afterwards.
---@param fn fun(parent_id: string): pi.SubsessionManifestEntry[]
---@param body fun()
local function with_manifest_children(fn, body)
    local Manifest = require("pi.subsessions.manifest")
    local real_children_of = Manifest.children_of
    Manifest.children_of = fn
    local ok, err = pcall(body)
    Manifest.children_of = real_children_of
    if not ok then
        error(err)
    end
end

--- Press a normal-mode key through the real key path.
---@param key string
local function press_key(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
end

--- Pump the event loop until the scheduled name fetches have landed and any
--- refresh they queued has been rendered (keeps the row state settled).
---@param sessions table[]
local function settle_names(sessions)
    vim.wait(1000, function()
        for _, session in ipairs(sessions) do
            if SessionList._name_of(session) == nil then
                return false
            end
        end
        return true
    end, 10)
    -- The name handler schedules a coalesced refresh right after the cache
    -- write; drain it so no render is left pending for the key press.
    vim.wait(100, function()
        return false
    end)
end

--- Canned child entry for the manifest stub (nil id models a manifest entry
--- with no id).
---@param id string?
---@param name string
---@return pi.SubsessionManifestEntry
local function child_entry(id, name)
    return {
        _id = id,
        name = name,
        status = "active",
        parent_id = "parent-id",
        parent_epoch = 0,
        reported = false,
        config = {},
    }
end

describe("sessions list preview key", function()
    before_each(function()
        -- Isolate from the user's real pi data (gotcha G17); minimal_init
        -- already redirects the prompt-history base dir.
        require("pi.draft")._set_path(vim.fn.tempname() .. "-draft.txt")
        require("pi.prompt_history")._set_base_dir(vim.fn.tempname())
        SessionList._reset()
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
    end)

    it("binds p to the read-only preview in the list buffer", function()
        SessionList.open()
        local map = vim.fn.maparg("p", "n", false, true)
        assert.are.equal(1, map.buffer)
        assert.are.equal("Preview session (read-only viewer)", map.desc)
    end)

    it("previews a parent/tab row with its live id and displayed name", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local s = fake_session({ tab = tab, id = "parent-live-id", name = "Parent task" })
        with_manager({ s }, function()
            with_key_stubs(function(calls)
                SessionList.open()
                settle_names({ s })
                -- The row really displays the resolved name we forward.
                assert.are.equal("  ● Parent task", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
                vim.api.nvim_win_set_cursor(0, { 1, 0 })
                press_key("p")

                assert.are.equal(1, #calls.viewer)
                assert.are.equal("parent-live-id", calls.viewer[1].id)
                assert.are.equal("Parent task", calls.viewer[1].opts.name)
            end)
        end)
    end)

    it("prefers the live session id over a stale render-time session_id", function()
        local s = fake_session({ tab = vim.api.nvim_get_current_tabpage(), id = "tmp-1", name = "Migrating" })
        with_manager({ s }, function()
            with_key_stubs(function(calls)
                local renders = 0
                local real_render = SessionList._render
                SessionList._render = function(...)
                    renders = renders + 1
                    return real_render(...)
                end
                local ok, err = pcall(function()
                    SessionList.open()
                    settle_names({ s })
                    vim.api.nvim_win_set_cursor(0, { 1, 0 })
                    local renders_before = renders
                    -- The backend migrated tmp-1 → real-id after the row was
                    -- rendered (manager.migrate_session_id); the row object
                    -- still carries the old session_id.
                    s.id = "real-id"
                    press_key("p")
                    assert.are.equal(renders_before, renders, "the key press must not re-render the row")
                    assert.are.equal(1, #calls.viewer)
                    assert.are.equal("real-id", calls.viewer[1].id)
                end)
                SessionList._render = real_render
                if not ok then
                    error(err)
                end
            end)
        end)
    end)

    it("previews a sub-session child row with the child id", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local parent = fake_session({ tab = tab, id = "parent-id", name = "Parent chat" })
        parent.lineage_id = "parent-id"
        local child = fake_session({ tab = tab, id = "child-id", name = "Child task" })
        child.view_parent_id = "parent-id"

        with_manifest_children(function(parent_id)
            if parent_id ~= "parent-id" then
                return {}
            end
            return { child_entry("child-id", "Child task") }
        end, function()
            with_manager({ child }, function()
                with_key_stubs(function(calls)
                    SessionList.open()
                    settle_names({ parent, child })
                    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
                    assert.are.equal(2, #lines)
                    assert.is_truthy(lines[2]:find("Child task", 1, true))

                    vim.api.nvim_win_set_cursor(0, { 2, 0 })
                    press_key("p")

                    assert.are.equal(1, #calls.viewer)
                    assert.are.equal("child-id", calls.viewer[1].id)
                    assert.are.equal("Child task", calls.viewer[1].opts.name)
                end)
            end, { ["parent-id"] = parent, ["child-id"] = child })
        end)
    end)

    it("does nothing for a row that resolves to no id at all", function()
        local parent = fake_session({ id = "parent-id", name = "Parent chat" })
        parent.lineage_id = "parent-id"
        parent.tab = nil
        -- A child row with no manifest id and no live session: nothing to
        -- preview, so the handler must bail out instead of opening with nil.
        local child = fake_session({ id = "child-id", name = "Orphan" })
        child.view_parent_id = "parent-id"
        child.tab = nil

        with_manifest_children(function()
            return { child_entry(nil, "Orphan") }
        end, function()
            with_manager({ child }, function()
                with_key_stubs(function(calls)
                    SessionList.open()
                    assert.are.equal(2, #vim.api.nvim_buf_get_lines(0, 0, -1, false))
                    vim.api.nvim_win_set_cursor(0, { 2, 0 })

                    press_key("p")
                    assert.are.equal(0, #calls.viewer)

                    local handler = vim.fn.maparg("p", "n", false, true).callback
                    local ok, err = pcall(handler)
                    assert.is_true(ok, tostring(err))
                    assert.are.equal(0, #calls.viewer)
                end)
            end, { ["parent-id"] = parent, ["child-id"] = child })
        end)
    end)

    it("does nothing on the empty-list placeholder", function()
        with_manager({}, function()
            with_key_stubs(function(calls)
                SessionList.open()
                assert.same({ "  (no active sessions)" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
                vim.api.nvim_win_set_cursor(0, { 1, 0 })

                -- The real key path: rows[1] is nil here.
                press_key("p")
                assert.are.equal(0, #calls.viewer)

                -- Neovim swallows errors raised inside a mapping, so the key
                -- path alone cannot observe a crash. Invoke the registered
                -- callback directly to make that failure loud.
                local handler = vim.fn.maparg("p", "n", false, true).callback
                assert.is_function(handler)
                local ok, err = pcall(handler)
                assert.is_true(ok, tostring(err))
                assert.are.equal(0, #calls.viewer)
            end)
        end)
    end)

    it("leaves x sub-session-only: a parent row performs no close", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local s = fake_session({ tab = tab, id = "parent-live-id", name = "Parent task" })
        with_manager({ s }, function()
            with_key_stubs(function(calls)
                SessionList.open()
                settle_names({ s })
                vim.api.nvim_win_set_cursor(0, { 1, 0 })
                press_key("x")

                assert.are.equal(0, #calls.close)
                assert.are.equal(0, #calls.viewer)
            end)
        end)
    end)

    it("still closes a child row's process with x", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local parent = fake_session({ tab = tab, id = "parent-id", name = "Parent chat" })
        parent.lineage_id = "parent-id"
        local child = fake_session({ tab = tab, id = "child-id", name = "Child task" })
        child.view_parent_id = "parent-id"

        with_manifest_children(function(parent_id)
            if parent_id ~= "parent-id" then
                return {}
            end
            return { child_entry("child-id", "Child task") }
        end, function()
            with_manager({ child }, function()
                with_key_stubs(function(calls)
                    SessionList.open()
                    settle_names({ parent, child })
                    assert.are.equal(2, #vim.api.nvim_buf_get_lines(0, 0, -1, false))

                    vim.api.nvim_win_set_cursor(0, { 2, 0 })
                    press_key("x")

                    assert.same({ "child-id" }, calls.close)
                end)
            end, { ["parent-id"] = parent, ["child-id"] = child })
        end)
    end)
end)
