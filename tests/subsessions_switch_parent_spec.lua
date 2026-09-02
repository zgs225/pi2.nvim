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
end)
