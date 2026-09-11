local Config = require("pi.config")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")

Config.setup({})

describe("switch_to_parent for_new_session", function()
    after_each(function()
        Sessions._reset()
    end)

    it("binds parent, clears chat, and skips load_session_path", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local cleared = false
        local load_called = false
        local orig_load = Sessions.load_session_path
        Sessions.load_session_path = function()
            load_called = true
        end

        local chat = {
            bind_agent = function() end,
            clear_subsession_breadcrumb = function() end,
            clear = function()
                cleared = true
            end,
        }
        local parent = {
            id = "parent-id",
            session_file = "/tmp/parent.jsonl",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        }
        local child = {
            id = "child-id",
            view_parent_id = "parent-id",
            attached_tab = tab,
            tab = tab,
            chat = chat,
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        }
        Sessions._register_for_test(parent)
        Sessions._register_for_test(child)
        Sessions.bind_chat(child, chat, tab)

        local ok
        Subsessions.switch_to_parent(function(result)
            ok = result
        end, { for_new_session = true })

        assert.is_true(ok)
        assert.is_true(cleared)
        assert.is_false(load_called)
        assert.are.equal("parent-id", Sessions.get_for_tab(tab).id)
        assert.is_nil(parent.view_parent_id)

        Sessions.load_session_path = orig_load
    end)

    it("sub_close treats view_parent_id as a child view without parent_id", function()
        local tab = vim.api.nvim_get_current_tabpage()
        -- Recorded order: switching back to the parent MUST run before close(),
        -- which detaches the tab and would strand switch_to_parent.
        local events = {}
        local orig_close = Subsessions.close
        local orig_switch = Subsessions.switch_to_parent
        Subsessions.close = function(id)
            events[#events + 1] = "close:" .. id
            return true
        end
        Subsessions.switch_to_parent = function(cb)
            events[#events + 1] = "switch"
            if cb then
                cb(true)
            end
        end

        local chat = {
            bind_agent = function() end,
            clear_subsession_breadcrumb = function() end,
            clear = function() end,
        }
        local child = {
            id = "child-id",
            view_parent_id = "parent-id",
            attached_tab = tab,
            tab = tab,
            chat = chat,
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        }
        Sessions._register_for_test(child)
        Sessions.bind_chat(child, chat, tab)

        Subsessions.sub_close()

        assert.are.same({ "switch", "close:child-id" }, events)

        Subsessions.close = orig_close
        Subsessions.switch_to_parent = orig_switch
    end)

    it("sub_close keeps the child running when the switch back to the parent fails", function()
        local tab = vim.api.nvim_get_current_tabpage()
        local events = {}
        local orig_close = Subsessions.close
        local orig_switch = Subsessions.switch_to_parent
        Subsessions.close = function(id)
            events[#events + 1] = "close:" .. id
            return true
        end
        Subsessions.switch_to_parent = function(cb)
            events[#events + 1] = "switch"
            if cb then
                cb(false, "parent session not running")
            end
        end

        local chat = {
            bind_agent = function() end,
            clear_subsession_breadcrumb = function() end,
            clear = function() end,
        }
        local child = {
            id = "child-id",
            view_parent_id = "parent-id",
            attached_tab = tab,
            tab = tab,
            chat = chat,
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        }
        Sessions._register_for_test(child)
        Sessions.bind_chat(child, chat, tab)

        Subsessions.sub_close()

        assert.are.same({ "switch" }, events)

        Subsessions.close = orig_close
        Subsessions.switch_to_parent = orig_switch
    end)
end)
