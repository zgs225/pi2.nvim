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
end)

describe("subagent sessions_list integration visibility", function()
    ---@param overrides table
    ---@return pi.SubsessionManifestEntry
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

    local seen = function()
        return true
    end

    it("keeps un-integrated children visible after the completion was read", function()
        Config.setup({ subagent = { sessions_list = { show_completed = "unread", show_failed = "unread" } } })
        for _, state in ipairs({ "queued", "applying", "resolving", "needs_attention" }) do
            -- Agent-spawned + reported + already-seen: every other rule would hide
            -- it, but the row is the only place the integration badge lives.
            local completed = entry({
                status = "completed",
                agent_spawned = true,
                reported = true,
                integration = { state = state },
            })
            assert.is_true(
                Filter.child_visible(completed, { completion_seen = seen }),
                state .. " must stay visible after the completion was read"
            )
            local failed = entry({
                status = "failed",
                agent_spawned = true,
                reported = true,
                integration = { state = state },
            })
            assert.is_true(
                Filter.child_visible(failed, { completion_seen = seen }),
                state .. " (failed) must stay visible"
            )
        end
    end)

    it("shows a dormant child whose integration still owes a result", function()
        Config.setup({ subagent = { sessions_list = { show_dormant = false, show_completed = "none" } } })
        assert.is_true(Filter.child_visible(entry({ status = "dormant", integration = { state = "needs_attention" } })))
        assert.is_true(Filter.child_visible(entry({ status = "dormant", integration = { state = "queued" } })))
    end)

    it("still hides integrated (applied) children once the completion was read", function()
        Config.setup({ subagent = { sessions_list = {} } })
        local entry_applied = entry({ status = "completed", reported = true, integration = { state = "applied" } })
        assert.is_true(Filter.child_visible(entry_applied, {
            completion_seen = function()
                return false
            end,
        }))
        assert.is_false(Filter.child_visible(entry_applied, { completion_seen = seen }))

        local spawned = entry({
            status = "completed",
            agent_spawned = true,
            reported = true,
            integration = { state = "applied" },
        })
        assert.is_false(Filter.child_visible(spawned, { completion_seen = seen }))
    end)

    it("keeps a failed child with an un-integrated checkout visible", function()
        Config.setup({ subagent = { sessions_list = { show_failed = "unread" } } })
        local failure = entry({ status = "failed", reported = true, integration = { state = "needs_attention" } })
        assert.is_true(Filter.child_visible(failure, { completion_seen = seen }))
    end)
end)
