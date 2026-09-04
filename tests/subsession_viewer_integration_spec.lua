local Pi = require("pi")
local Commands = require("pi.commands")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")
local Manifest = require("pi.subsessions.manifest")
local Dialog = require("pi.ui.dialog")

describe("subsession viewer integration", function()
    before_each(function()
        Commands.setup()
    end)

    it("registers :PiSubView user command with expected description", function()
        local cmds = vim.api.nvim_get_commands({})
        assert.is_not_nil(cmds["PiSubView"])
        assert.equals("View sub-session in a read-only float", cmds["PiSubView"].definition)
    end)

    it("invoking :PiSubView calls Pi.sub_view", function()
        local called = false
        local orig = Pi.sub_view
        Pi.sub_view = function()
            called = true
        end

        vim.cmd("PiSubView")
        Pi.sub_view = orig

        assert.is_true(called)
    end)

    it("Pi.sub_view delegates to Subsessions.sub_view", function()
        local called = false
        local orig = Subsessions.sub_view
        Subsessions.sub_view = function()
            called = true
        end

        Pi.sub_view()
        Subsessions.sub_view = orig

        assert.is_true(called)
    end)

    it("Subsessions.preview delegates to subsession_viewer.open", function()
        local opened_child = nil
        package.loaded["pi.ui.subsession_viewer"] = {
            open = function(child_id)
                opened_child = child_id
            end,
        }

        Subsessions.preview("test-child-123")
        package.loaded["pi.ui.subsession_viewer"] = nil

        assert.equals("test-child-123", opened_child)
    end)

    it("Subsessions.sub_view opens preview when a child is selected", function()
        local orig_get = Sessions.get
        local orig_lineage = Manifest.lineage_for_session
        local orig_children = Manifest.children_of
        local orig_select = Dialog.select
        local orig_preview = Subsessions.preview

        local previewed_child = nil
        local select_opts = nil

        Sessions.get = function()
            return { id = "parent-id" }
        end
        Manifest.lineage_for_session = function()
            return "parent-id"
        end
        Manifest.children_of = function()
            return {
                { _id = "child-1", name = "worker-1", status = "active" },
                { _id = "child-2", name = "worker-2", status = "completed" },
            }
        end
        Dialog.select = function(opts, cb)
            select_opts = opts
            cb(opts.options[1])
        end
        Subsessions.preview = function(child_id)
            previewed_child = child_id
        end

        Subsessions.sub_view()

        Sessions.get = orig_get
        Manifest.lineage_for_session = orig_lineage
        Manifest.children_of = orig_children
        Dialog.select = orig_select
        Subsessions.preview = orig_preview

        assert.is_not_nil(select_opts)
        assert.equals("pi-sub-view", select_opts.kind)
        assert.equals("child-1", previewed_child)
    end)
end)
