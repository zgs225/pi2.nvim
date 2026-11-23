-- Turn navigation (`[[` / `]]`): jumping the history window from one user
-- message to the next/previous one.
--
-- Two layers in one spec, because the change has two halves:
--
--   * the motion resolution `History.turn_target_index` is pure, so the
--     off-by-one behaviour (strictly past the cursor, counts, clamping, ends of
--     the list) is asserted directly without a buffer;
--   * the anchor bookkeeping is a buffer property: anchors are extmarks on the
--     user label rows, so a jump must follow the label when lines are inserted
--     above it, and dead anchors must be dropped instead of resurrected.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")

local TAB = 971

local function pump(ms)
    vim.wait(ms or 60)
end

describe("turn motion resolution", function()
    -- Turn starts at rows 0, 10, 20 (0-indexed).
    local rows = { 0, 10, 20 }

    it("moves strictly past the cursor", function()
        assert.are.equal(2, History.turn_target_index(rows, 0, "next", 1))
        assert.are.equal(2, History.turn_target_index(rows, 5, "next", 1))
        assert.are.equal(2, History.turn_target_index(rows, 9, "next", 1))
        assert.are.equal(3, History.turn_target_index(rows, 10, "next", 1))
        assert.are.equal(1, History.turn_target_index(rows, 10, "prev", 1))
        assert.are.equal(2, History.turn_target_index(rows, 15, "prev", 1))
        assert.are.equal(1, History.turn_target_index(rows, 5, "prev", 1))
    end)

    it("returns nil when there is nothing ahead", function()
        assert.is_nil(History.turn_target_index(rows, 20, "next", 1))
        assert.is_nil(History.turn_target_index(rows, 99, "next", 1))
        assert.is_nil(History.turn_target_index(rows, 0, "prev", 1))
        assert.is_nil(History.turn_target_index(rows, 0, "prev", 3))
        assert.is_nil(History.turn_target_index({}, 0, "next", 1))
        assert.is_nil(History.turn_target_index({}, 0, "prev", 1))
    end)

    it("honours counts and clamps at both ends", function()
        assert.are.equal(3, History.turn_target_index(rows, 0, "next", 2))
        assert.are.equal(3, History.turn_target_index(rows, 0, "next", 9))
        assert.are.equal(1, History.turn_target_index(rows, 20, "prev", 2))
        assert.are.equal(1, History.turn_target_index(rows, 20, "prev", 9))
        -- A count of 0/negatives is one move, never a stuck cursor.
        assert.are.equal(2, History.turn_target_index(rows, 0, "next", 0))
        assert.are.equal(2, History.turn_target_index(rows, 0, "next", -3))
    end)

    it("treats a missing count as one", function()
        assert.are.equal(2, History.turn_target_index(rows, 0, "next", nil))
    end)
end)

describe("turn navigation on the history buffer", function()
    ---@type pi.ChatHistory
    local h
    local win

    --- 1-indexed rows of the user message labels in the buffer.
    ---@return integer[]
    local function label_rows()
        local icon = Config.options.labels.user_message
        local out = {}
        for i, line in ipairs(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)) do
            if line:sub(1, #icon) == icon then
                out[#out + 1] = i
            end
        end
        return out
    end

    ---@return integer
    local function cursor_line()
        return vim.api.nvim_win_get_cursor(win)[1]
    end

    --- Render one complete turn: user message, agent label, agent text.
    ---@param text string
    local function turn(text)
        h:add_user_message(text, nil, nil)
        pump(60)
        h:on_agent_start(nil)
        pump(60)
        h:on_text_delta("reply to " .. text .. "\n")
        pump(80)
        h:on_agent_end("done")
        pump(80)
    end

    before_each(function()
        h = History.new(TAB)
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, h:buf())
        h:set_win(win)
    end)

    it("lands on the next/previous user label", function()
        turn("one")
        turn("two")
        turn("three")
        local rows = label_rows()
        assert.are.equal(3, #rows, "sanity: three user labels rendered")

        vim.api.nvim_win_set_cursor(win, { rows[1], 0 })
        assert.is_true(h:goto_turn("next", 1))
        assert.are.equal(rows[2], cursor_line(), "`next` must land on the second turn's label")
        assert.is_true(h:goto_turn("next", 1))
        assert.are.equal(rows[3], cursor_line(), "`next` must land on the third turn's label")

        assert.is_true(h:goto_turn("prev", 1))
        assert.are.equal(rows[2], cursor_line(), "`prev` must land on the second turn's label")
        assert.is_true(h:goto_turn("prev", 1))
        assert.are.equal(rows[1], cursor_line(), "`prev` must land on the first turn's label")
    end)

    it("walks back to the first turn and stops there", function()
        turn("one")
        turn("two")
        local rows = label_rows()
        vim.api.nvim_win_set_cursor(win, { rows[2], 0 })
        assert.is_true(h:goto_turn("prev", 1))
        assert.are.equal(rows[1], cursor_line())
        assert.is_false(h:goto_turn("prev", 1), "`prev` at the first turn must report no move")
        assert.are.equal(rows[1], cursor_line(), "a refused `prev` must not move the cursor")
    end)

    it("counts turns", function()
        turn("one")
        turn("two")
        turn("three")
        local rows = label_rows()
        vim.api.nvim_win_set_cursor(win, { rows[1], 0 })
        assert.is_true(h:goto_turn("next", 2))
        assert.are.equal(rows[3], cursor_line(), "`2]]` must skip the middle turn")
        assert.is_true(h:goto_turn("prev", 2))
        assert.are.equal(rows[1], cursor_line(), "`2[[` must skip the middle turn")
    end)

    it("past the last turn jumps to the bottom and re-attaches the stream", function()
        turn("one")
        turn("two")
        local rows = label_rows()
        vim.api.nvim_win_set_cursor(win, { rows[1], 0 })
        assert.is_true(h:goto_turn("next", 1))
        assert.is_false(h._auto_follow, "a turn jump must detach from the stream")

        assert.is_true(h:goto_turn("next", 1))
        local total = vim.api.nvim_buf_line_count(h:buf())
        assert.are.equal(total, cursor_line(), "running past the last turn must land on the last line")
        assert.is_true(h._auto_follow, "landing at the bottom must re-attach the stream")
    end)

    it("keeps following away from a jumped-to turn while text streams", function()
        turn("one")
        turn("two")
        local rows = label_rows()
        vim.api.nvim_win_set_cursor(win, { rows[1], 0 })
        assert.is_true(h:goto_turn("next", 1))
        local landed = cursor_line()

        h:on_text_delta("more streaming output\n")
        pump(120)
        assert.are.equal(landed, cursor_line(), "reading an older turn must not be yanked to the bottom")
    end)

    it("follows the user label when lines shift above it", function()
        turn("one")
        turn("two")
        local before = label_rows()

        -- Simulate anything that inserts rows above the conversation (a startup
        -- block or a compaction summary expanding). The anchors are extmarks, so
        -- the jump targets must shift with the labels, not stay on old rows.
        h:_with_modifiable(function()
            vim.api.nvim_buf_set_lines(h:buf(), 0, 0, false, { "injected above", "" })
        end)
        local after = label_rows()
        assert.are.equal(before[2] + 2, after[2], "sanity: the labels moved down two rows")

        vim.api.nvim_win_set_cursor(win, { after[1], 0 })
        assert.is_true(h:goto_turn("next", 1))
        assert.are.equal(after[2], cursor_line(), "the anchor must follow its line, not a stored row number")
    end)

    it("drops dead anchors instead of resurrecting them", function()
        turn("one")
        assert.are.equal(1, #h:_live_turn_rows(), "sanity: one anchor")
        h:clear()
        assert.are.equal(0, #h:_live_turn_rows(), "clear() must drop the anchors")
        assert.are.equal(0, #h._turn_anchors, "clear() must empty the anchor list")
        assert.is_false(h:goto_turn("next", 1), "no turns means no move")
    end)
end)
