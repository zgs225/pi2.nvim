local Config = require("pi.config")
local Filter = require("pi.subsessions.sessions_list")

describe("subagent sessions_list filter", function()
    local function entry(overrides)
        return vim.tbl_extend("force", {
            _id = "child-1",
            parent_id = "parent",
            name = "worker",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
        }, overrides or {})
    end

    it("hides dormant children by default", function()
        Config.setup({ subagent = { sessions_list = {} } })
        assert.is_false(Filter.child_visible(entry({ status = "dormant" })))
    end)

    it("shows dormant when configured", function()
        Config.setup({ subagent = { sessions_list = { show_dormant = true } } })
        assert.is_true(Filter.child_visible(entry({ status = "dormant" })))
    end)

    it("hides agent-spawned completed children", function()
        Config.setup({ subagent = { sessions_list = {} } })
        assert.is_false(Filter.child_visible(entry({
            status = "completed",
            agent_spawned = true,
        })))
    end)

    it("shows user completed until reported and seen", function()
        Config.setup({ subagent = { sessions_list = {} } })
        local e = entry({ status = "completed", reported = false })
        assert.is_true(Filter.child_visible(e))
        e.reported = true
        assert.is_true(Filter.child_visible(e, {
            completion_seen = function()
                return false
            end,
        }))
        assert.is_false(Filter.child_visible(e, {
            completion_seen = function()
                return true
            end,
        }))
    end)

    it("shows running children even when dormant in manifest", function()
        Config.setup({ subagent = { sessions_list = {} } })
        assert.is_true(Filter.child_visible(entry({ status = "dormant" }), {
            process_running = function()
                return true
            end,
        }))
    end)
end)
