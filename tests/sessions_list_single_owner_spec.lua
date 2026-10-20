-- Unit tests for :PiSessions child attribution when several live sessions share
-- one manifest lineage (a `/new` conversation plus the original session resumed
-- in another tab, or a tab viewing a child): every manifest child must render
-- under exactly one parent row.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local SessionList = require("pi.ui.sessions")
local Sessions = require("pi.sessions.manager")

local ORIG = "01a15300-0000-7000-8000-000000000001"
local NEW = "01a15300-0000-7000-8000-000000000002"
local OTHER = "01a15300-0000-7000-8000-000000000003"
local CHILD = "01a15300-0000-7000-8000-0000000000c1"
local CHILD2 = "01a15300-0000-7000-8000-0000000000c2"

--- Build a fake pi.Session with just enough surface for the list.
---@param opts { id: string, lineage?: string, epoch?: integer, tab?: integer, view_parent_id?: string, running?: boolean }
---@return table
local function fake_session(opts)
    local tab = opts.tab or 1000
    return {
        id = opts.id,
        lineage_id = opts.lineage,
        conversation_epoch = opts.epoch or 0,
        tab = tab,
        attached_tab = tab,
        view_parent_id = opts.view_parent_id,
        rpc = {
            is_running = function()
                return opts.running ~= false
            end,
            stop = function() end,
        },
        chat = {
            is_streaming = function()
                return false
            end,
            is_compacting = function()
                return false
            end,
        },
    }
end

--- Build a manifest child entry.
---@param opts { id: string, parent_id: string, parent_epoch?: integer, status?: string }
---@return pi.SubsessionManifestEntry
local function entry(opts)
    return {
        _id = opts.id,
        parent_id = opts.parent_id,
        parent_epoch = opts.parent_epoch or 0,
        name = opts.id,
        task_prompt = "task",
        config = {},
        status = opts.status or "active",
        reported = false,
        created_at = "2026-01-01T00:00:00Z",
        last_active_at = "2026-01-01T00:00:00Z",
    }
end

---@param sessions table[]
---@return pi.SessionsListRow[]
local function build_rows(sessions)
    return SessionList.build_rows(sessions, function()
        return 0
    end, function(session)
        return session.id
    end)
end

--- Parent row id that owns each child row (nearest preceding depth-0 row).
---@param rows pi.SessionsListRow[]
---@return { child_id: string, parent_id: string? }[]
local function carriers(rows)
    local out = {}
    local current_parent = nil
    for _, row in ipairs(rows) do
        if row.depth == 0 then
            current_parent = row.session_id
        elseif row.depth == 1 then
            out[#out + 1] = { child_id = row.child_id, parent_id = current_parent }
        end
    end
    return out
end

--- Parent row ids that render `child_id` (must be 0 or 1 after the fix).
---@param rows pi.SessionsListRow[]
---@param child_id string
---@return string?[]
local function parents_of(rows, child_id)
    local ids = {}
    for _, carrier in ipairs(carriers(rows)) do
        if carrier.child_id == child_id then
            ids[#ids + 1] = carrier.parent_id
        end
    end
    return ids
end

--- Distinct parent session ids carrying `child_id` (the ownership invariant, as
--- opposed to the row count: rows of the same parent session may repeat it).
---@param rows pi.SessionsListRow[]
---@param child_id string
---@return integer
local function distinct_parent_count(rows, child_id)
    local seen = {}
    local count = 0
    for _, parent_id in ipairs(parents_of(rows, child_id)) do
        if parent_id ~= nil and not seen[parent_id] then
            seen[parent_id] = true
            count = count + 1
        end
    end
    return count
end

--- Parent rows paired with the child rows rendered underneath them.
---@param rows pi.SessionsListRow[]
---@return { parent: pi.SessionsListRow, children: pi.SessionsListRow[] }[]
local function row_groups(rows)
    local out = {}
    local current = nil
    for _, row in ipairs(rows) do
        if row.depth == 0 then
            current = { parent = row, children = {} }
            out[#out + 1] = current
        elseif row.depth == 1 and current then
            current.children[#current.children + 1] = row
        end
    end
    return out
end

describe(":PiSessions single-owner sub-session rows", function()
    local orig_children

    before_each(function()
        Config.setup({})
        SessionList._reset()
        Sessions._reset()
        if SessionList.show_hidden_children() then
            SessionList.toggle_show_hidden_children()
        end
        orig_children = Manifest.children_of
    end)

    after_each(function()
        Manifest.children_of = orig_children
        Manifest._reset()
        SessionList._reset()
        Sessions._reset()
        if SessionList.show_hidden_children() then
            SessionList.toggle_show_hidden_children()
        end
    end)

    it("renders a shared-lineage child under the epoch-1 row only (/new + resume)", function()
        local orig = fake_session({ id = ORIG, lineage = ORIG, epoch = 0, tab = 1 })
        local new = fake_session({ id = NEW, lineage = ORIG, epoch = 1, tab = 2 })
        Sessions._register_for_test(fake_session({ id = CHILD, tab = 2, running = true }))
        Manifest.children_of = function(lineage)
            if lineage ~= ORIG then
                return {}
            end
            return { entry({ id = CHILD, parent_id = ORIG, parent_epoch = 1, status = "active" }) }
        end

        local rows = build_rows({ orig, new })

        assert.are.equal(3, #rows)
        assert.are.same({ NEW }, parents_of(rows, CHILD))
    end)

    it("keeps hidden children under the epoch-1 row when H shows them", function()
        local orig = fake_session({ id = ORIG, lineage = ORIG, epoch = 0, tab = 1 })
        local new = fake_session({ id = NEW, lineage = ORIG, epoch = 1, tab = 2 })
        Manifest.children_of = function(lineage)
            if lineage ~= ORIG then
                return {}
            end
            return {
                entry({ id = CHILD, parent_id = ORIG, parent_epoch = 1, status = "dormant" }),
                entry({ id = CHILD2, parent_id = ORIG, parent_epoch = 1, status = "completed" }),
            }
        end

        local rows = build_rows({ orig, new })
        assert.are.same({}, parents_of(rows, CHILD))
        assert.are.same({ NEW }, parents_of(rows, CHILD2))
        assert.are.equal(3, #rows)

        SessionList.toggle_show_hidden_children()
        local shown = build_rows({ orig, new })
        assert.are.same({ NEW }, parents_of(shown, CHILD))
        assert.are.same({ NEW }, parents_of(shown, CHILD2))
        assert.are.equal(4, #shown)
    end)

    it("keeps a running pre-/new child visible in the same tab (e9dd801)", function()
        local new = fake_session({ id = NEW, lineage = ORIG, epoch = 1, tab = 1 })
        Sessions._register_for_test(fake_session({ id = CHILD, tab = 1, running = true }))
        Manifest.children_of = function()
            return { entry({ id = CHILD, parent_id = ORIG, parent_epoch = 0, status = "active" }) }
        end

        local rows = build_rows({ new })

        assert.are.equal(2, #rows)
        assert.are.same({ NEW }, parents_of(rows, CHILD))
    end)

    it("keeps a resumed conversation's own running child visible", function()
        local orig = fake_session({ id = ORIG, lineage = ORIG, epoch = 0, tab = 1 })
        Sessions._register_for_test(fake_session({ id = CHILD, tab = 1, running = true }))
        Manifest.children_of = function()
            return { entry({ id = CHILD, parent_id = ORIG, parent_epoch = 1, status = "active" }) }
        end

        local rows = build_rows({ orig })

        assert.are.equal(2, #rows)
        assert.are.same({ ORIG }, parents_of(rows, CHILD))
    end)

    it("leaves distinct lineages untouched", function()
        local orig = fake_session({ id = ORIG, lineage = ORIG, epoch = 0, tab = 1 })
        local other = fake_session({ id = OTHER, lineage = OTHER, epoch = 0, tab = 2 })
        Sessions._register_for_test(fake_session({ id = CHILD, tab = 1, running = true }))
        Sessions._register_for_test(fake_session({ id = CHILD2, tab = 2, running = true }))
        Manifest.children_of = function(lineage)
            if lineage == ORIG then
                return { entry({ id = CHILD, parent_id = ORIG, parent_epoch = 0, status = "active" }) }
            end
            if lineage == OTHER then
                return { entry({ id = CHILD2, parent_id = OTHER, parent_epoch = 0, status = "active" }) }
            end
            return {}
        end

        local rows = build_rows({ orig, other })

        assert.are.equal(4, #rows)
        assert.are.same({ ORIG }, parents_of(rows, CHILD))
        assert.are.same({ OTHER }, parents_of(rows, CHILD2))
    end)

    -- Regression guard: the dedup used to be keyed only by child id across the
    -- whole call, so the parent's own row (first) swallowed the child and the
    -- viewer row rendered its parent as a leaf, losing the current-view marker.
    it("keeps the viewed child marked when the parent tab is also open", function()
        local parent = fake_session({ id = ORIG, lineage = ORIG, epoch = 0, tab = 1 })
        local viewer =
            fake_session({ id = CHILD, lineage = ORIG, epoch = 0, tab = 2, view_parent_id = ORIG, running = true })
        Sessions._register_for_test(parent)
        Manifest.children_of = function(lineage)
            if lineage ~= ORIG then
                return {}
            end
            return { entry({ id = CHILD, parent_id = ORIG, parent_epoch = 0, status = "completed" }) }
        end

        local rows = build_rows({ parent, viewer })

        assert.are.equal(4, #rows)
        -- Rows of the same parent session repeat the child...
        assert.are.same({ ORIG, ORIG }, parents_of(rows, CHILD))
        -- ...but it is still attributed to exactly one parent session.
        assert.are.equal(1, distinct_parent_count(rows, CHILD))

        local viewer_group = nil
        for _, group in ipairs(row_groups(rows)) do
            if group.parent.is_tree_parent then
                viewer_group = group
            end
        end
        assert.is_not_nil(viewer_group)
        assert.is_true(viewer_group.parent.has_children)
        assert.is_true((viewer_group.parent.child_count or 0) >= 1)
        local marked = false
        for _, child_row in ipairs(viewer_group.children) do
            if child_row.child_id == CHILD and child_row.is_current_view then
                marked = true
            end
        end
        assert.is_true(marked, "the viewer row must mark its viewed child as the current view")
    end)

    it("marks each viewed child when two tabs view different children of one parent", function()
        local parent = fake_session({ id = ORIG, lineage = ORIG, epoch = 0, tab = 1 })
        local viewer1 =
            fake_session({ id = CHILD, lineage = ORIG, epoch = 0, tab = 2, view_parent_id = ORIG, running = true })
        local viewer2 =
            fake_session({ id = CHILD2, lineage = ORIG, epoch = 0, tab = 3, view_parent_id = ORIG, running = true })
        Sessions._register_for_test(parent)
        Manifest.children_of = function(lineage)
            if lineage ~= ORIG then
                return {}
            end
            return {
                entry({ id = CHILD, parent_id = ORIG, parent_epoch = 0, status = "completed" }),
                entry({ id = CHILD2, parent_id = ORIG, parent_epoch = 0, status = "completed" }),
            }
        end

        local rows = build_rows({ parent, viewer1, viewer2 })

        -- 3 parent rows, each rendering both visible children.
        assert.are.equal(9, #rows)
        assert.are.equal(1, distinct_parent_count(rows, CHILD))
        assert.are.equal(1, distinct_parent_count(rows, CHILD2))

        ---@type table<integer, pi.SessionsListRow[]>
        local viewer_children = {}
        for _, group in ipairs(row_groups(rows)) do
            if group.parent.is_tree_parent then
                viewer_children[group.parent.tab] = group
            end
        end
        for tab, viewed_child in pairs({ [2] = CHILD, [3] = CHILD2 }) do
            local group = viewer_children[tab]
            assert.is_not_nil(group, "missing viewer row for tab " .. tab)
            local marked = {}
            for _, child_row in ipairs(group.children) do
                if child_row.is_current_view then
                    marked[#marked + 1] = child_row.child_id
                end
            end
            assert.are.same({ viewed_child }, marked)
        end
    end)

    -- Rows are `{other, orig}` on purpose: the child-id claim alone would hand
    -- the child to `other`, so this asserts the epoch/ownership tie-break.
    it("attributes a same-epoch shared lineage to the conversation it is named after", function()
        local orig = fake_session({ id = ORIG, lineage = ORIG, epoch = 0, tab = 1 })
        local other = fake_session({ id = OTHER, lineage = ORIG, epoch = 0, tab = 2 })
        Sessions._register_for_test(fake_session({ id = CHILD, tab = 1, running = true }))
        Manifest.children_of = function(lineage)
            if lineage ~= ORIG then
                return {}
            end
            return { entry({ id = CHILD, parent_id = ORIG, parent_epoch = 0, status = "active" }) }
        end

        local rows = build_rows({ other, orig })

        assert.are.equal(3, #rows)
        assert.are.same({ ORIG }, parents_of(rows, CHILD))
    end)

    it("falls back to the first live session in tabline order", function()
        local orig = fake_session({ id = ORIG, lineage = ORIG, epoch = 3, tab = 1 })
        local new = fake_session({ id = NEW, lineage = ORIG, epoch = 4, tab = 2 })
        Sessions._register_for_test(fake_session({ id = CHILD, tab = 1, running = true }))
        Manifest.children_of = function(lineage)
            if lineage ~= ORIG then
                return {}
            end
            -- Epoch matches neither root and the spawning conversation is gone.
            return { entry({ id = CHILD, parent_id = OTHER, parent_epoch = 9, status = "active" }) }
        end

        local rows = build_rows({ orig, new })

        assert.are.equal(3, #rows)
        assert.are.same({ ORIG }, parents_of(rows, CHILD))
    end)

    it("does not duplicate a hidden child when h is toggled on the non-owner row", function()
        local orig = fake_session({ id = ORIG, lineage = ORIG, epoch = 0, tab = 1 })
        local new = fake_session({ id = NEW, lineage = ORIG, epoch = 1, tab = 2 })
        Manifest.children_of = function(lineage)
            if lineage ~= ORIG then
                return {}
            end
            return { entry({ id = CHILD, parent_id = ORIG, parent_epoch = 1, status = "dormant" }) }
        end

        SessionList.toggle_show_hidden_children(orig)
        local rows = build_rows({ orig, new })

        assert.are.equal(3, #rows)
        assert.are.same({ NEW }, parents_of(rows, CHILD))
        assert.are.equal(1, distinct_parent_count(rows, CHILD))
    end)
end)
