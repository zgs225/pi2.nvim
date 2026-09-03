local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")
local SessionList = require("pi.ui.sessions")

Config.setup({})

describe("subsession completion reporting", function()
    local manifest_tmp
    local real_read = Read.last_assistant_message
    local real_manifest_path = Manifest.path
    local tab

    before_each(function()
        tab = vim.api.nvim_get_current_tabpage()
        manifest_tmp = vim.fn.tempname() .. ".json"
        Manifest.path = function()
            return manifest_tmp
        end
        Manifest._reset()
        SessionList._reset()
    end)

    after_each(function()
        Read.last_assistant_message = real_read
        Manifest.path = real_manifest_path
        os.remove(manifest_tmp)
        Sessions._reset()
        Manifest._reset()
    end)

    it("find_by_lineage resolves parent after session id migration", function()
        Manifest.register_session_lineage("session-b", "session-b")
        Manifest.register_session_lineage("session-a", "session-b")
        local parent = {
            id = "session-b",
            lineage_id = "session-b",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        }
        Sessions._register_for_test(parent)
        assert.are.equal(parent, Sessions.find_by_lineage("session-a"))
        assert.are.equal(parent, Sessions.find_by_lineage("session-b"))
    end)

    it("marks reported and acknowledges when parent is on the current tab", function()
        Read.last_assistant_message = function()
            return "done report"
        end

        Manifest.upsert("child-1", {
            parent_id = "lineage-a",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
        })

        local parent = {
            id = "parent-live",
            lineage_id = "lineage-a",
            attached_tab = tab,
            tab = tab,
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
                send = function(_, cmd, cb)
                    if cmd.type == "prompt" and cb then
                        vim.schedule(function()
                            cb({ success = true })
                        end)
                    end
                    return true
                end,
            },
        }
        local child = {
            id = "child-1",
            parent_id = "parent-live",
            session_file = "/tmp/child.jsonl",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        }
        Sessions._register_for_test(parent)
        Sessions.bind_chat(parent, {
            bind_agent = function() end,
            clear = function() end,
            is_streaming = function()
                return false
            end,
            is_compacting = function()
                return false
            end,
        }, tab)

        Subsessions.on_child_settled(child)

        assert.is_true(vim.wait(3000, function()
            local entry = Manifest.load()["child-1"]
            return entry and entry.reported == true
        end, 10), "completion report was not marked reported")

        local rows = SessionList.build_rows({ parent }, function()
            return 0
        end, function()
            return "parent"
        end)
        assert.are.equal(1, #rows)
    end)

    it("injects a completion prompt for user-spawned children", function()
        Read.last_assistant_message = function()
            return "done report"
        end

        Manifest.upsert("child-user", {
            parent_id = "lineage-a",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
            agent_spawned = false,
            run_generation = 1,
        })

        local prompted
        local parent = {
            id = "parent-live",
            lineage_id = "lineage-a",
            attached_tab = tab,
            tab = tab,
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
                send = function(_, cmd, cb)
                    if cmd.type == "prompt" then
                        prompted = cmd.message
                        if cb then
                            vim.schedule(function()
                                cb({ success = true })
                            end)
                        end
                    end
                    return true
                end,
            },
        }
        Sessions._register_for_test(parent)
        Sessions.bind_chat(parent, {
            bind_agent = function() end,
            clear = function() end,
            is_streaming = function()
                return false
            end,
            is_compacting = function()
                return false
            end,
        }, tab)

        Subsessions.on_child_settled({
            id = "child-user",
            parent_id = "parent-live",
            session_file = "/tmp/child.jsonl",
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        })

        assert.is_true(vim.wait(3000, function()
            local entry = Manifest.load()["child-user"]
            return entry and entry.reported == true
        end, 10), "user-spawned completion was not reported")
        assert.is_truthy(prompted)
        assert.is_truthy(prompted:find("worker", 1, true))
        assert.is_truthy(prompted:find("done report", 1, true))
    end)
end)
