-- Sessions-overview key `c`: compact the session under the cursor in the
-- background — the compact command goes to the row's session (not the
-- current tab's), without leaving the list. Covers the keymap registration,
-- the request routing, the chat's compacting flag, and the
-- streaming / already-compacting / dead-process guards.

local SessionList = require("pi.ui.sessions")

--- Fake session with a scripted rpc:send: answers get_state through
--- vim.schedule like a real backend would, and records every request in
--- `sent`. The chat records set_compacting calls; streaming/compacting
--- states are scripted via opts.
---@param opts? { running?: boolean, tab?: integer, streaming?: boolean, compacting?: boolean }
local function compact_session(opts)
    opts = opts or {}
    local s = {
        tab = opts.tab or 1000,
        sent = {},
        compacting = false,
        rpc = {
            is_running = function()
                return opts.running ~= false
            end,
        },
        chat = {
            is_streaming = function()
                return opts.streaming == true
            end,
            is_compacting = function()
                return opts.compacting == true
            end,
            set_status = function() end,
        },
    }
    -- Assigned after construction: a closure inside the `local s = { … }`
    -- initializer would resolve `s` as a global under LuaJIT (5.2-style
    -- declaration scoping), not the in-progress local.
    s.chat.set_compacting = function(_, value)
        s.compacting = value
    end
    s.rpc.send = function(_, req, cb)
        table.insert(s.sent, req)
        if req.type == "get_state" then
            vim.schedule(function()
                cb({ success = true, data = { sessionName = "compact session" } })
            end)
        elseif req.type == "compact" then
            vim.schedule(function()
                cb({ success = true })
            end)
        end
        return true
    end
    return s
end

--- The compact request recorded by a fake session, if any.
---@param s table
---@return table?
local function compact_req(s)
    for _, req in ipairs(s.sent) do
        if req.type == "compact" then
            return req
        end
    end
    return nil
end

--- Run fn with the session manager stubbed to `sessions` and no current
--- session, so the list renders exactly those rows and a fallback to the
--- current tab's session would resolve to nothing.
---@param sessions pi.Session[]
---@param fn fun()
local function with_manager(sessions, fn)
    local real_manager = package.loaded["pi.sessions.manager"]
    package.loaded["pi.sessions.manager"] = {
        list = function()
            return sessions
        end,
        get = function()
            return nil
        end,
    }
    local ok, err = pcall(fn)
    package.loaded["pi.sessions.manager"] = real_manager
    if not ok then
        error(err)
    end
end

local function press_key(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
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

describe("session list compact key", function()
    before_each(function()
        SessionList._reset()
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
    end)

    it("binds c to the compact action in the list buffer", function()
        SessionList.open()
        local map = vim.fn.maparg("c", "n", false, true)
        assert.equals(1, map.buffer)
        assert.equals("Compact this session", map.desc)
    end)

    it("sends the compact command to the session under the cursor", function()
        local s = compact_session({ tab = vim.api.nvim_get_current_tabpage() })
        with_manager({ s }, function()
            SessionList.open()
            vim.wait(1000, function()
                return SessionList._name_of(s) ~= nil
            end)
            press_key("c")

            local req
            vim.wait(1000, function()
                req = compact_req(s)
                return req ~= nil
            end)
            assert.is_not_nil(req, "compact command was not sent")
            assert.is_nil(req.customInstructions, "list compaction carries no custom instructions")
            -- The chat's compacting flag flips on immediately (the backend
            -- clears it when the compaction completes).
            assert.is_true(s.compacting, "chat compacting flag was not set")
        end)
    end)

    it("targets the row's session, not the current tab's", function()
        -- Two listed sessions; the current tab's is a different one. Pressing
        -- c on the second row must query the second session's RPC. The
        -- manager stub's get() returns nil, so any fallback to the current
        -- tab's session would send nothing at all.
        local a = compact_session({ tab = 1000 })
        local b = compact_session({ tab = vim.api.nvim_get_current_tabpage() })
        with_manager({ a, b }, function()
            SessionList.open()
            vim.wait(1000, function()
                return SessionList._name_of(a) ~= nil and SessionList._name_of(b) ~= nil
            end)
            -- Row 1 belongs to the fake tab 1000 (not a real tabpage), so
            -- compact on it would silently no-op; only row 2 can send.
            assert.are.equal(2, #vim.api.nvim_buf_get_lines(0, 0, -1, false))
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            press_key("c")

            local req
            vim.wait(1000, function()
                req = compact_req(b)
                return req ~= nil
            end)
            assert.is_not_nil(req, "compact command did not reach the row's session")
            assert.is_nil(compact_req(a))
            assert.is_true(b.compacting)
            assert.is_false(a.compacting)
        end)
    end)

    it("warns on a dead session instead of sending the command", function()
        local s = compact_session({ running = false, tab = vim.api.nvim_get_current_tabpage() })
        local warnings
        with_manager({ s }, function()
            SessionList.open()
            -- The dead process never gets the name fetch; the row renders the
            -- (unnamed) placeholder instead.
            assert.is_nil(SessionList._name_of(s))
            warnings = capture_warnings(function()
                press_key("c")
            end)
            vim.wait(200, function()
                return false
            end)
        end)

        assert.equals(1, #warnings)
        assert.is_truthy(warnings[1]:find("not running", 1, true))
        assert.is_nil(compact_req(s))
        assert.is_false(s.compacting)
    end)

    it("warns while the target session is streaming", function()
        local s = compact_session({ streaming = true, tab = vim.api.nvim_get_current_tabpage() })
        local warnings
        with_manager({ s }, function()
            SessionList.open()
            vim.wait(1000, function()
                return SessionList._name_of(s) ~= nil
            end)
            warnings = capture_warnings(function()
                press_key("c")
            end)
            vim.wait(200, function()
                return false
            end)
        end)

        assert.equals(1, #warnings)
        assert.is_truthy(warnings[1]:find("streaming", 1, true))
        assert.is_nil(compact_req(s))
        assert.is_false(s.compacting)
    end)

    it("is a no-op while the target session is already compacting", function()
        local s = compact_session({ compacting = true, tab = vim.api.nvim_get_current_tabpage() })
        local warnings
        with_manager({ s }, function()
            SessionList.open()
            vim.wait(1000, function()
                return SessionList._name_of(s) ~= nil
            end)
            warnings = capture_warnings(function()
                press_key("c")
            end)
            vim.wait(200, function()
                return false
            end)
        end)

        assert.equals(1, #warnings)
        assert.is_truthy(warnings[1]:find("already running", 1, true))
        assert.is_nil(compact_req(s))
    end)

    it("is a silent no-op when passed an explicit dead session", function()
        -- Direct pi.compact(instructions, session) contract: a session whose
        -- process is not running returns without a request or a warning (the
        -- list layer owns the user-facing warning).
        local s = compact_session({ running = false, tab = vim.api.nvim_get_current_tabpage() })
        local warnings = capture_warnings(function()
            require("pi").compact(nil, s)
        end)
        vim.wait(200, function()
            return false
        end)

        assert.is_nil(compact_req(s))
        assert.are.equal(0, #warnings)
        assert.is_false(s.compacting)
    end)
end)
