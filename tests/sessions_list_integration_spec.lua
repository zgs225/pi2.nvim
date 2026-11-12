-- :PiSessions shows a manifest child's automatic worktree integration as a
-- single glyph at the end of the row body — `queued ⧗`, `applying`/`resolving …`,
-- `applied ✓`, `needs_attention !` — so the integration text (which can be long)
-- can never widen the list or shift the dot/name columns. Rows without an
-- integration record stay byte-identical, and worktree grouping is unaffected.
--
-- `pi.worktree` is stubbed through package.loaded for the grouping case; no git
-- is involved.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local SessionList = require("pi.ui.sessions")
local Sidebar = require("pi.ui.sidebar")

local TAB = 1401
local GLYPH = "󰙅"

---@param opts? { id?: string, tab?: integer, cwd?: string }
---@return pi.Session
local function fake_session(opts)
    opts = opts or {}
    local tab = opts.tab or TAB
    return {
        id = opts.id or "parent-1",
        tab = tab,
        attached_tab = tab,
        cwd = opts.cwd,
        conversation_epoch = 0,
        rpc = {
            is_running = function()
                return true
            end,
            stop = function() end,
            send = function(_, _, cb)
                if cb then
                    cb({ success = true, data = {} })
                end
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
            layout = function()
                return "side"
            end,
            set_status = function() end,
        },
    }
end

--- One active manifest child with an optional integration record.
---@param integration table?
---@param cfg table?
---@return table
local function child_entry(integration, cfg)
    return {
        _id = "c1",
        name = "worker-1",
        status = "active",
        parent_id = "parent-1",
        config = cfg or {},
        integration = integration,
    }
end

---@param entries table[]
local function stub_children(entries)
    Manifest.children_of = function(lineage)
        if lineage == "parent-1" then
            return entries
        end
        return {}
    end
end

---@param entries table[]
---@param session? pi.Session
---@return pi.SessionsListRow[] rows, string child_line, string parent_line
local function build_child(entries, session)
    stub_children(entries)
    local rows = SessionList.build_rows({ session or fake_session() }, function()
        return 0
    end, function()
        return "Parent"
    end)
    assert.are.equal(2, #rows, "expected parent + child rows")
    local child_line, child_chunks = SessionList.format_line(rows[2], 0)
    local parent_line = (SessionList.format_line(rows[1], 0))
    return rows, child_line, parent_line, child_chunks
end

describe(":PiSessions worktree integration status", function()
    local real_worktree_module
    local orig_children

    before_each(function()
        Config.setup({})
        SessionList._reset()
        Sidebar._reset()
        Manifest = require("pi.subsessions.manifest")
        orig_children = Manifest.children_of
        real_worktree_module = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            detect = function()
                return nil
            end,
            status = function() end,
        }
    end)

    after_each(function()
        SessionList._reset()
        Sidebar._reset()
        Manifest.children_of = orig_children
        package.loaded["pi.worktree"] = real_worktree_module
    end)

    it("appends one glyph per integration state", function()
        local cases = {
            { state = "queued", glyph = "⧗", hl = "PiSessionsListIntegrationQueued" },
            { state = "applying", glyph = "…", hl = "PiSessionsListIntegrationRunning" },
            { state = "resolving", glyph = "…", hl = "PiSessionsListIntegrationRunning" },
            { state = "applied", glyph = "✓", hl = "PiSessionsListIntegrationApplied" },
            { state = "needs_attention", glyph = "!", hl = "PiSessionsListIntegrationAttention" },
        }
        for _, case in ipairs(cases) do
            local _, line, _, chunks = build_child({ child_entry({ state = case.state }) })
            assert.are.equal("  └─ ● worker-1 " .. case.glyph, line, case.state)
            local glyph_chunk
            for _, chunk in ipairs(chunks) do
                if chunk[3] == case.hl then
                    glyph_chunk = chunk
                end
            end
            assert.is_truthy(glyph_chunk, case.state .. " highlight chunk")
            assert.are.equal(case.glyph, line:sub(glyph_chunk[1] + 1, glyph_chunk[2]))
        end
    end)

    it("keeps a row without an integration record byte-identical", function()
        local _, line, parent_line = build_child({ child_entry(nil) })
        assert.are.equal("▾ ● Parent", parent_line)
        assert.are.equal("  └─ ● worker-1", line)

        -- An unknown state renders nothing either (forward compatible).
        local _, unknown = build_child({ child_entry({ state = "unknown_state" }) })
        assert.are.equal("  └─ ● worker-1", unknown)
    end)

    it("keeps the dot and name columns of an integration row unchanged", function()
        stub_children({ child_entry(nil) })
        local plain_rows = SessionList.build_rows({ fake_session() }, function()
            return 0
        end, function()
            return "Parent"
        end)
        local plain_line, plain_chunks = SessionList.format_line(plain_rows[2], 0)

        local _, line, _, chunks = build_child({ child_entry({ state = "applied" }) })

        -- The glyph is appended: the row grows by exactly " ✓".
        assert.are.equal(plain_line .. " ✓", line)
        -- Dot and name keep their byte offsets, so nothing shifts.
        assert.are.equal(plain_chunks[1][1], chunks[1][1])
        assert.are.equal(plain_chunks[1][2], chunks[1][2])
        assert.are.equal(plain_chunks[2][1], chunks[2][1])
        assert.are.equal(plain_chunks[2][2], chunks[2][2])
    end)

    it("never widens the row with the integration text or error", function()
        local long_error = string.rep("conflict at src/very/long/path/file.lua; ", 8)
        local _, line = build_child({ child_entry({ state = "needs_attention", error = long_error }) })
        assert.are.equal("  └─ ● worker-1 !", line)
        assert.is_nil(line:find("conflict", 1, true))
    end)

    it("puts the glyph after the model subtitle", function()
        local _, line = build_child({
            child_entry({ state = "queued" }, { model = { id = "claude-x" }, thinking_level = "high" }),
        })
        assert.are.equal("  └─ ● worker-1 · claude-x · high ⧗", line)
    end)

    it("keeps worktree grouping and the worktree suffix intact", function()
        local worktrees = {
            ["/repo/main"] = { kind = "main", name = "main", path = "/repo/main", repo_root = "/repo/main" },
            ["/repo/wt"] = { kind = "linked", name = "wt", path = "/repo/wt", repo_root = "/repo/main" },
        }
        package.loaded["pi.worktree"] = {
            detect = function(dir)
                return worktrees[dir]
            end,
            status = function() end,
        }
        local main = fake_session({ id = "A", cwd = "/repo/main" })
        local linked = fake_session({ id = "parent-1", cwd = "/repo/wt" })

        stub_children({ child_entry({ state = "applied" }) })
        local rows = SessionList.build_rows({ main, linked }, function()
            return 0
        end, function(session)
            return session.id
        end)

        -- header(main), A, header(wt), parent, child
        assert.are.equal(5, #rows)
        assert.is_true(rows[1].is_group)
        assert.is_true(rows[3].is_group)
        local child_line = (SessionList.format_line(rows[5], 0))
        assert.are.equal("  └─ ● worker-1 · " .. GLYPH .. " wt ✓", child_line)
    end)
end)
