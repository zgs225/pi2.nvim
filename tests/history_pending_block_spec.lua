-- History pending-queue block: real-line rendering at the buffer end.
--
-- The pending queue renders as REAL buffer lines (1 blank margin + one row
-- per entry) so the cursor can rest on a queued message and `dd` it. Content
-- appends strip the block first and re-anchor it at the new buffer end.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")

local ns = vim.api.nvim_create_namespace("pi-chat")
local TAB = 1320

local function pump(ms)
    vim.wait(ms or 30)
end

describe("history pending block rendering", function()
    local function setup_history(content_lines)
        local h = History.new(TAB)
        vim.api.nvim_win_set_buf(0, h:buf())
        h:set_win(0)
        if content_lines then
            h:_with_modifiable(function()
                vim.api.nvim_buf_set_lines(h:buf(), 0, -1, false, content_lines)
            end)
        end
        return h
    end

    ---@param h table
    ---@return string[] lines from the blank margin to the buffer end
    local function block_lines(h)
        if not h._pending_block_extmark then
            return {}
        end
        local pos = vim.api.nvim_buf_get_extmark_by_id(h:buf(), ns, h._pending_block_extmark, {})
        if not pos or not pos[1] then
            return {}
        end
        return vim.api.nvim_buf_get_lines(h:buf(), pos[1], -1, false)
    end

    local function teardown(h)
        pcall(vim.api.nvim_buf_delete, h:buf(), { force = true })
    end

    it("renders the block as real lines at the buffer end with queue labels", function()
        local h = setup_history({ "content line" })
        h:add_pending_queue_entry("steer", "steer text", "steer text")
        h:add_pending_queue_entry("follow_up", "follow text", "follow text")

        local lines = block_lines(h)
        assert.are.equal(3, #lines) -- blank margin + 2 rows
        assert.are.equal("", lines[1])
        assert.are.equal(2, vim.fn.stridx(lines[2], Config.options.labels.steer_message))
        assert.is_not_nil(lines[2]:find("steer text", 1, true))
        assert.are.equal(2, vim.fn.stridx(lines[3], Config.options.labels.follow_up_message))
        assert.is_not_nil(lines[3]:find("follow text", 1, true))

        teardown(h)
    end)

    it("re-anchors the block below content appended after queuing", function()
        local h = setup_history({ "content line" })
        h:add_pending_queue_entry("steer", "queued", "queued")

        h:_append_lines({ "new content" })

        local lines = vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
        -- content order preserved: original, new content, then the block.
        assert.are.equal("content line", lines[1])
        assert.are.equal("new content", lines[2])
        local block = block_lines(h)
        assert.are.equal(2, #block)
        assert.is_not_nil(block[2]:find("queued", 1, true))

        teardown(h)
    end)

    it("pending_index_at maps block rows to 1-based indices", function()
        local h = setup_history({ "content line" })
        h:add_pending_queue_entry("steer", "one", "one")
        h:add_pending_queue_entry("steer", "two", "two")
        h:add_pending_queue_entry("follow_up", "three", "three")

        local pos = vim.api.nvim_buf_get_extmark_by_id(h:buf(), ns, h._pending_block_extmark, {})
        local margin = pos[1]
        assert.is_nil(h:pending_index_at(margin)) -- blank margin
        assert.is_nil(h:pending_index_at(0)) -- content
        assert.are.equal(1, h:pending_index_at(margin + 1))
        assert.are.equal(2, h:pending_index_at(margin + 2))
        assert.are.equal(3, h:pending_index_at(margin + 3))
        assert.is_nil(h:pending_index_at(margin + 4)) -- past the end

        teardown(h)
    end)

    it("accounts for the vision-pending row in pending_index_at", function()
        local h = setup_history({ "content line" })
        h:set_vision_pending({ text = "describing", image_count = 1, model = "m" })
        h:add_pending_queue_entry("steer", "one", "one")

        local pos = vim.api.nvim_buf_get_extmark_by_id(h:buf(), ns, h._pending_block_extmark, {})
        local margin = pos[1]
        assert.is_nil(h:pending_index_at(margin + 1)) -- vision row
        assert.are.equal(1, h:pending_index_at(margin + 2)) -- first queue row

        teardown(h)
    end)

    it("remove_pending_queue_entry_at removes by position and re-renders", function()
        local h = setup_history({ "content line" })
        h:add_pending_queue_entry("steer", "one", "one")
        h:add_pending_queue_entry("steer", "two", "two")
        h:add_pending_queue_entry("follow_up", "three", "three")

        local removed = h:remove_pending_queue_entry_at(2)
        assert.is_not_nil(removed)
        assert.are.equal("two", removed.expanded_text)

        local queue = h:get_pending_queue()
        assert.are.equal(2, #queue)
        assert.are.equal("one", queue[1].expanded_text)
        assert.are.equal("three", queue[2].expanded_text)

        local block = block_lines(h)
        assert.are.equal(3, #block) -- margin + 2 rows
        assert.is_nil(block[3]:find("two", 1, true))

        assert.is_nil(h:remove_pending_queue_entry_at(0))
        assert.is_nil(h:remove_pending_queue_entry_at(99))

        teardown(h)
    end)

    it("keeps images on the entry for later re-enqueue", function()
        local h = setup_history({ "content line" })
        local images = { { type = "image", data = "QUJD", mimeType = "image/png" } }
        h:add_pending_queue_entry("steer", "look", "look", 1, images)

        local entry = h:get_pending_queue()[1]
        assert.are.same(images, entry.images)

        teardown(h)
    end)

    it("clears the block on clear()", function()
        local h = setup_history({ "content line" })
        h:add_pending_queue_entry("steer", "queued", "queued")
        assert.is_not_nil(h._pending_block_extmark)

        h:clear()
        assert.is_nil(h._pending_block_extmark)
        assert.are.equal(0, #h:get_pending_queue())

        teardown(h)
    end)
end)
