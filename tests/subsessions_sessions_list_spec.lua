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

    it("hides agent-spawned completed children when process is idle", function()
        Config.setup({ subagent = { sessions_list = {} } })
        assert.is_false(Filter.child_visible(
            entry({
                status = "completed",
                agent_spawned = true,
            }),
            {
                process_running = function()
                    return false
                end,
            }
        ))
    end)

    it("respects show_completed = none for idle children", function()
        Config.setup({ subagent = { sessions_list = { show_completed = "none" } } })
        assert.is_false(Filter.child_visible(
            entry({
                status = "completed",
                agent_spawned = false,
            }),
            {
                process_running = function()
                    return false
                end,
            }
        ))
    end)

    it("remembers a completion acknowledgement once", function()
        Filter._reset_completion_seen()
        assert.is_false(Filter.is_completion_seen("child-1"))
        assert.is_true(Filter.mark_completion_seen("child-1"))
        assert.is_false(Filter.mark_completion_seen("child-1"))
        assert.is_true(Filter.is_completion_seen("child-1"))
        assert.is_false(Filter.mark_completion_seen(""))
        Filter._reset_completion_seen()
        assert.is_false(Filter.is_completion_seen("child-1"))
    end)

    it("acknowledges only reported completed children of a lineage", function()
        Filter._reset_completion_seen()
        local Manifest = require("pi.subsessions.manifest")
        local original = Manifest.children_of
        Manifest.children_of = function()
            return {
                entry({ _id = "reported", status = "completed", reported = true }),
                entry({ _id = "silent", status = "completed", reported = false }),
                entry({ _id = "failed", status = "failed", reported = true }),
            }
        end
        local ok, changed, again = pcall(function()
            local first = Filter.acknowledge_reported("parent")
            local second = Filter.acknowledge_reported("parent")
            return first, second
        end)
        Manifest.children_of = original
        assert.is_true(ok)
        assert.is_true(changed)
        assert.is_false(again)
        assert.is_true(Filter.is_completion_seen("reported"))
        assert.is_false(Filter.is_completion_seen("silent"))
        assert.is_false(Filter.is_completion_seen("failed"))
        assert.is_false(Filter.acknowledge_reported(""))
        Filter._reset_completion_seen()
    end)

    it("keeps the row the view is showing visible", function()
        Config.setup({ subagent = { sessions_list = {} } })
        local dormant = entry({ status = "dormant" })
        assert.is_false(Filter.row_visible(dormant))
        assert.is_true(Filter.row_visible(dormant, { is_current = true }))
    end)

    it("keeps rows visible when hidden rows are toggled on", function()
        Config.setup({ subagent = { sessions_list = {} } })
        assert.is_false(Filter.row_visible(entry({ status = "dormant" })))
        assert.is_true(Filter.row_visible(entry({ status = "dormant" }), { hidden = true }))
    end)

    it("shows an active child whose process is alive even across epochs", function()
        Config.setup({ subagent = { sessions_list = {} } })
        local ctx = {
            process_alive = function()
                return true
            end,
        }
        assert.is_false(Filter.row_visible(entry({ status = "active" }), { same_epoch = false }))
        assert.is_true(Filter.row_visible(entry({ status = "active" }), { same_epoch = false, ctx = ctx }))
    end)

    it("hides children spawned by another conversation epoch", function()
        Config.setup({ subagent = { sessions_list = { show_dormant = true } } })
        local dormant = entry({ status = "dormant" })
        assert.is_true(Filter.row_visible(dormant))
        assert.is_false(Filter.row_visible(dormant, { same_epoch = false }))
        -- The running override is inside the policy, so the epoch gate still wins.
        assert.is_false(Filter.row_visible(dormant, {
            same_epoch = false,
            ctx = {
                process_running = function()
                    return true
                end,
            },
        }))
    end)
end)
