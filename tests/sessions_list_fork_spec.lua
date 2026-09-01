-- Sessions-overview keys f / C / t: fork, clone, or tree-navigate the session
-- under the cursor. The list jumps to that session's tab first (showing its
-- chat), so the existing :PiFork / :PiClone / :PiTree flows resolve the
-- target session via Sessions.get() untouched. Covers the keymap
-- registration, the jump-then-trigger wiring, and the stale-row no-op.

local SessionList = require("pi.ui.sessions")

--- Fake session living in `tab`, with chat focus recorders and a scripted
--- rpc:send for the list's name fetch.
---@param tab integer
local function action_session(tab)
    local s = {
        tab = tab,
        chat = {
            is_compacting = function()
                return false
            end,
            is_streaming = function()
                return false
            end,
        },
        rpc = {
            is_running = function()
                return true
            end,
        },
    }
    s.chat.ensure_shown_and_focus_prompt = function(self)
        self._ensures = (self._ensures or 0) + 1
    end
    s.chat.ensure_shown_and_focus_prompt_at_end = function(self)
        self._ensures_end = (self._ensures_end or 0) + 1
    end
    s.rpc.send = function(_, req, cb)
        if req.type == "get_state" then
            vim.schedule(function()
                cb({ success = true, data = { sessionName = "action session" } })
            end)
        end
        return true
    end
    return s
end

--- Run fn with the session manager stubbed to `sessions` and no current
--- session, so the list renders exactly those rows.
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

local tab_a, tab_b

--- Stub the pi API module with per-entry spies, run `key` against a
--- one-session list (the session lives in the second tab), then restore.
---@param key string
---@return table<string, integer> call counts per pi entry
---@return table fake session
local function run_action(key)
    local real_pi = package.loaded["pi"]
    local spies = {}
    package.loaded["pi"] = setmetatable({}, {
        __index = function(_, name)
            return function()
                spies[name] = (spies[name] or 0) + 1
            end
        end,
    })
    local s = action_session(tab_b)
    with_manager({ s }, function()
        SessionList.open()
        vim.wait(1000, function()
            return SessionList._name_of(s) ~= nil
        end)
        press_key(key)
        vim.wait(200, function()
            return false
        end)
    end)
    package.loaded["pi"] = real_pi
    return spies, s
end

describe("session list fork/clone/tree keys", function()
    before_each(function()
        SessionList._reset()
        tab_a = vim.api.nvim_get_current_tabpage()
        vim.cmd("tabnew")
        tab_b = vim.api.nvim_get_current_tabpage()
        vim.api.nvim_set_current_tabpage(tab_a)
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
        if vim.api.nvim_tabpage_is_valid(tab_a) then
            vim.api.nvim_set_current_tabpage(tab_a)
        end
        if tab_b and vim.api.nvim_tabpage_is_valid(tab_b) then
            pcall(vim.api.nvim_tabpage_delete, tab_b, true)
        end
    end)

    it("binds f, C and t to the action keys in the list buffer", function()
        SessionList.open()
        for _, entry in ipairs({
            { "f", "Fork this session" },
            { "C", "Clone this session" },
            { "t", "Navigate this session's tree" },
        }) do
            local map = vim.fn.maparg(entry[1], "n", false, true)
            assert.equals(1, map.buffer, entry[1] .. " should be buffer-local")
            assert.equals(entry[2], map.desc)
        end
    end)

    it("f jumps to the row's tab and forks via pi.fork", function()
        local spies, s = run_action("f")
        assert.are.equal(tab_b, vim.api.nvim_get_current_tabpage(), "should land on the row's tab")
        assert.equals(1, spies.fork)
        assert.is_nil(spies.clone)
        assert.is_nil(spies.tree)
        -- The jump shows the target session's chat (plain prompt focus, not
        -- the append variant).
        assert.equals(1, s.chat._ensures)
        assert.is_nil(s.chat._ensures_end)
    end)

    it("C jumps to the row's tab and clones via pi.clone", function()
        local spies, s = run_action("C")
        assert.are.equal(tab_b, vim.api.nvim_get_current_tabpage())
        assert.equals(1, spies.clone)
        assert.is_nil(spies.fork)
        assert.is_nil(spies.tree)
        assert.equals(1, s.chat._ensures)
    end)

    it("t jumps to the row's tab and opens the tree via pi.tree", function()
        local spies, s = run_action("t")
        assert.are.equal(tab_b, vim.api.nvim_get_current_tabpage())
        assert.equals(1, spies.tree)
        assert.is_nil(spies.fork)
        assert.is_nil(spies.clone)
        assert.equals(1, s.chat._ensures)
    end)

    it("is a no-op on a stale row: no jump, no entry call", function()
        local real_pi = package.loaded["pi"]
        local spies = {}
        package.loaded["pi"] = setmetatable({}, {
            __index = function(_, name)
                return function()
                    spies[name] = (spies[name] or 0) + 1
                end
            end,
        })
        with_manager({ action_session(9999) }, function()
            SessionList.open()
            vim.wait(200, function()
                return false
            end)
            press_key("f")
        end)
        package.loaded["pi"] = real_pi

        assert.are.equal(tab_a, vim.api.nvim_get_current_tabpage())
        assert.is_nil(spies.fork)
    end)
end)
