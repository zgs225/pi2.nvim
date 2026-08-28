-- :PiNewTab / pi.new_tab() — fresh session in a new tabpage.
--
-- Drives the session manager against a stubbed Rpc (no real pi process).

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")
local Pi = require("pi")

Config.setup({})
Pi.setup({})

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }

--- type -> fun(cmd): pi.RpcEvent
local responders = {}

local function install_stub()
    responders = {}

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
        local responder = responders[cmd.type]
        if callback and responder then
            local res = responder(cmd)
            vim.schedule(function()
                callback(res)
            end)
        end
        return true
    end

    responders.get_commands = function()
        return { type = "response", success = true, data = { commands = {} } }
    end
    responders.get_state = function()
        return {
            type = "response",
            success = true,
            data = { model = { provider = "qwen", id = "qwen3-max" }, thinkingLevel = "off" },
        }
    end
end

local function restore_stub()
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if vim.api.nvim_get_current_tabpage() ~= tab then
            vim.api.nvim_set_current_tabpage(tab)
        end
        Sessions.stop()
    end
    while #vim.api.nvim_list_tabpages() > 1 do
        vim.cmd("tabclose")
    end
    Rpc.start = real_rpc.start
    Rpc.stop = real_rpc.stop
    Rpc.send = real_rpc.send
end

describe("PiNewTab", function()
    before_each(function()
        install_stub()
    end)

    after_each(function()
        restore_stub()
    end)

    it("creates a new tabpage with a fresh visible session", function()
        local first_tab = vim.api.nvim_get_current_tabpage()
        local before_tabs = #vim.api.nvim_list_tabpages()

        Pi.new_tab()

        assert.equals(before_tabs + 1, #vim.api.nvim_list_tabpages())
        local new_tab = vim.api.nvim_get_current_tabpage()
        assert.not_equals(first_tab, new_tab)

        local session = Sessions.get()
        assert.truthy(session)
        assert.equals(new_tab, session.tab)
        assert.is_true(session.chat:is_visible())

        vim.api.nvim_set_current_tabpage(first_tab)
        assert.is_nil(Sessions.get())
    end)

    it("leaves the original tab's session untouched", function()
        local first_tab = vim.api.nvim_get_current_tabpage()
        local original = Sessions.get_or_create()
        assert.truthy(original)

        Pi.new_tab()

        vim.api.nvim_set_current_tabpage(first_tab)
        assert.equals(original, Sessions.get())
    end)
end)
