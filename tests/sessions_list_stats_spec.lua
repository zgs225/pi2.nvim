-- Sessions-overview key `s`: show the stats dashboard (:PiSessionStats data)
-- for the session under the cursor. Covers the keymap registration, the RPC
-- requests fanning out to the targeted row's session (not the current tab's),
-- the dialog content, and the dead-process guard.

local SessionList = require("pi.ui.sessions")

--- Canned get_session_stats payload for the fake RPC.
local STATS_DATA = {
    sessionId = "s1",
    userMessages = 2,
    assistantMessages = 3,
    toolCalls = 0,
    toolResults = 0,
    tokens = { input = 1000, output = 500, cacheRead = 0, cacheWrite = 0 },
    cost = 0.005,
}

--- Fake session with a scripted rpc:send: answers get_state / get_session_stats
--- / get_entries through vim.schedule like a real backend would, and records
--- every request type in `sent.
---@param opts? { running?: boolean, tab?: integer }
local function stats_session(opts)
    opts = opts or {}
    local s = {
        tab = opts.tab or 1000,
        sent = {},
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
    -- Assigned after construction: a closure inside the `local s = { … }`
    -- initializer would resolve `s` as a global under LuaJIT (5.2-style
    -- declaration scoping), not the in-progress local.
    s.rpc.send = function(_, req, cb)
        table.insert(s.sent, req.type)
        if req.type == "get_state" then
            vim.schedule(function()
                cb({ success = true, data = { sessionName = "stats session" } })
            end)
        elseif req.type == "get_session_stats" then
            vim.schedule(function()
                cb({ success = true, data = STATS_DATA })
            end)
        elseif req.type == "get_entries" then
            vim.schedule(function()
                cb({ success = true, data = { entries = {} } })
            end)
        end
        return true
    end
    return s
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

--- Find the stats dialog float: the pi-dialog buffer whose body carries the
--- stats dashboard's Tokens section (the float title lives in the window
--- border, not the buffer).
---@return integer?, integer?
local function find_stats_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.bo[buf].filetype == "pi-dialog" then
            local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            if text:find("Tokens", 1, true) and text:find("ID", 1, true) then
                return win, buf
            end
        end
    end
    return nil, nil
end

describe("session list stats key", function()
    before_each(function()
        SessionList._reset()
    end)

    after_each(function()
        pcall(SessionList.close)
        -- The stats dialog is a focusable float; close any leftovers so the
        -- next test splits from a normal window, not from a float.
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "pi-dialog" then
                pcall(vim.api.nvim_win_close, win, true)
            end
        end
        SessionList._reset()
    end)

    it("binds s to the stats action in the list buffer", function()
        SessionList.open()
        local map = vim.fn.maparg("s", "n", false, true)
        assert.equals(1, map.buffer)
        assert.equals("Show this session's stats", map.desc)
    end)

    it("opens the stats dashboard for the session under the cursor", function()
        local s = stats_session({ tab = vim.api.nvim_get_current_tabpage() })
        with_manager({ s }, function()
            SessionList.open()
            -- The initial render kicks off the name fetch; let it resolve so
            -- the row is stable before pressing the key.
            vim.wait(1000, function()
                return SessionList._name_of(s) ~= nil
            end)
            press_key("s")

            local win, buf
            vim.wait(1000, function()
                win, buf = find_stats_win()
                return win ~= nil
            end)
            assert.is_not_nil(win, "stats dialog did not open")

            -- The requests went to the row's own session, not the current tab's.
            assert.is_truthy(vim.tbl_contains(s.sent, "get_session_stats"))
            assert.is_truthy(vim.tbl_contains(s.sent, "get_entries"))

            local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
            assert.is_truthy(text:find("ID    s1", 1, true), "session id shown")
            assert.is_truthy(text:find("Messages", 1, true), "messages section shown")
            assert.is_truthy(text:find("Cost", 1, true), "cost section shown")
        end)
    end)

    it("targets the row's session, not the current tab's", function()
        -- Two listed sessions; the current tab's is a different one. Pressing
        -- s on the second row must query the second session's RPC.
        local a = stats_session({ tab = 1000 })
        local b = stats_session({ tab = vim.api.nvim_get_current_tabpage() })
        with_manager({ a, b }, function()
            SessionList.open()
            vim.wait(1000, function()
                return SessionList._name_of(a) ~= nil and SessionList._name_of(b) ~= nil
            end)
            -- Both rows resolved; move to row 2 and press s. row 1 belongs to
            -- the fake tab 1000 (not a real tabpage), so stats on it would
            -- silently no-op — only the row-2 session can produce a dialog.
            assert.are.equal(2, #vim.api.nvim_buf_get_lines(0, 0, -1, false))
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            press_key("s")

            local win
            vim.wait(1000, function()
                win = find_stats_win()
                return win ~= nil
            end)
            assert.is_not_nil(win, "stats dialog did not open for the row under the cursor")
            assert.is_truthy(vim.tbl_contains(b.sent, "get_session_stats"))
            assert.is_falsy(vim.tbl_contains(a.sent, "get_session_stats"))
        end)
    end)

    it("warns on a dead session instead of opening the dialog", function()
        local real_notify = package.loaded["pi.notify"]
        local warnings = {}
        package.loaded["pi.notify"] = {
            warn = function(msg)
                table.insert(warnings, msg)
            end,
        }
        local s = stats_session({ running = false, tab = vim.api.nvim_get_current_tabpage() })
        with_manager({ s }, function()
            SessionList.open()
            -- The dead process never gets the name fetch; the row renders the
            -- (unnamed) placeholder instead.
            assert.is_nil(SessionList._name_of(s))
            press_key("s")
            vim.wait(200, function()
                return false
            end)
        end)
        package.loaded["pi.notify"] = real_notify

        assert.equals(1, #warnings)
        assert.is_truthy(warnings[1]:find("not running", 1, true))
        assert.is_nil(find_stats_win())
        -- The dead session never received the stats requests.
        assert.is_falsy(vim.tbl_contains(s.sent, "get_session_stats"))
    end)
end)
