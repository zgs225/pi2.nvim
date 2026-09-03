local Manifest = require("pi.subsessions.manifest")
local Subsessions = require("pi.subsessions")
local SessionList = require("pi.ui.sessions")
local History = require("pi.sessions.history")

describe("subsession lineage on resume", function()
    local manifest_tmp
    local real_parse = History.parse

    before_each(function()
        manifest_tmp = vim.fn.tempname() .. ".json"
        Manifest.path = function()
            return manifest_tmp
        end
    end)

    after_each(function()
        History.parse = real_parse
        os.remove(manifest_tmp)
    end)

    it("rebind_lineage replaces stale tab lineage", function()
        local session = { id = "session-b", lineage_id = "session-a" }
        Manifest.rebind_lineage(session, "session-b")
        assert.are.equal("session-b", session.lineage_id)
        assert.are.equal("session-b", Manifest.lineage_for_session(session))
        assert.are.equal("session-b", Manifest.resolve_lineage("session-b"))
    end)

    it("on_parent_resumed updates PiSessions child rows for the new parent", function()
        Manifest.upsert("child-a", {
            parent_id = "session-a",
            parent_epoch = 0,
            name = "worker-a",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
        })
        Manifest.upsert("child-b", {
            parent_id = "session-b",
            parent_epoch = 0,
            name = "worker-b",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
        })

        History.parse = function()
            return { id = "session-b", path = "/fake/b.jsonl" }
        end

        local parent = {
            tab = 42,
            id = "session-a",
            lineage_id = "session-a",
            conversation_epoch = 2,
            view_parent_id = "session-a",
            rpc = {
                is_running = function()
                    return true
                end,
            },
            chat = {
                is_streaming = function()
                    return false
                end,
                is_compacting = function()
                    return false
                end,
                active_verb = function()
                    return nil
                end,
                extension_status = function()
                    return nil
                end,
            },
        }

        Subsessions.on_parent_resumed(parent, "/fake/b.jsonl")

        assert.is_nil(parent.view_parent_id)
        assert.are.equal(0, parent.conversation_epoch)
        assert.are.equal("session-b", parent.lineage_id)

        local rows = SessionList.build_rows({ parent }, function()
            return 0
        end, function()
            return "resumed"
        end)

        assert.are.equal(2, #rows)
        assert.are.equal("worker-b", rows[2].name)
        assert.are.equal("child-b", rows[2].child_id)
    end)
end)
