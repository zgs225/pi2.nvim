local Config = require("pi.config")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")

Config.setup({})

describe("new_session from sub-session view", function()
    local orig_switch
    local sent = {}

    local function make_rpc(owner)
        return {
            is_running = function()
                return true
            end,
            stop = function() end,
            send = function(_, cmd, cb)
                if cmd.type == "abort" or cmd.type == "new_session" then
                    sent[owner] = sent[owner] or {}
                    sent[owner][#sent[owner] + 1] = cmd.type
                end
                if cb then
                    if cmd.type == "abort" then
                        cb({ success = true })
                    elseif cmd.type == "new_session" then
                        cb({ success = true, data = {} })
                    elseif cmd.type == "get_commands" then
                        cb({ success = true, data = { commands = {} } })
                    end
                end
                return true
            end,
        }
    end

    before_each(function()
        sent = {}
        orig_switch = Subsessions.switch_to_parent
    end)

    after_each(function()
        Subsessions.switch_to_parent = orig_switch
        Sessions._reset()
    end)

    it("switches to parent before starting a new parent conversation", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local chat = {
            clear = function() end,
            bind_agent = function() end,
            clear_subsession_breadcrumb = function() end,
            is_streaming = function()
                return false
            end,
        }
        local parent = {
            id = "parent-id",
            rpc = make_rpc("parent"),
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }
        local child = {
            id = "child-id",
            view_parent_id = "parent-id",
            rpc = make_rpc("child"),
            attention = { pending = {} },
            startup_announcements = {},
            system_errors = {},
            changed_files = {},
        }
        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        Sessions.bind_chat(child, chat, tab)

        local switched = false
        Subsessions.switch_to_parent = function(cb, opts)
            switched = true
            assert.is_true(opts and opts.for_new_session)
            Sessions.bind_chat(parent, chat, tab)
            parent.view_parent_id = nil
            chat:clear()
            cb(true)
        end

        Sessions.new_session()

        assert.is_true(vim.wait(3000, function()
            return switched and sent.parent ~= nil
        end, 10), "expected parent switch and new_session RPC")
        assert.are.same({ "abort", "new_session" }, sent.parent)
        assert.is_nil(sent.child)
    end)
end)
