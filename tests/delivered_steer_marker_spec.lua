-- Delivered steer/follow-up messages keep a subdued tag on the user-message
-- label line so you can tell how a past message entered the conversation.
-- The tag uses the dedicated PiSteerDelivered / PiFollowUpDelivered groups
-- (previously the shared PiMessageQueueTag).

local Config = require("pi.config")
local History = require("pi.ui.chat.history")
local Highlights = require("pi.ui.highlights")

local TAB = 1311

local function pump(ms)
    vim.wait(ms or 60)
end

describe("delivered steer/follow-up marker", function()
    before_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
        Highlights.setup()
    end)

    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    local function setup_history()
        local h = History.new(TAB)
        vim.api.nvim_win_set_buf(0, h:buf())
        h:set_win(0)
        return h
    end

    local function lines_of(h)
        return vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
    end

    ---@param h pi.ChatHistory
    ---@return table<string, boolean>
    local function hl_groups(h)
        local set = {}
        for _, em in ipairs(vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })) do
            local hl = (em[4] or {}).hl_group
            if hl then
                set[hl] = true
            end
        end
        return set
    end

    ---@param h pi.ChatHistory
    ---@param sub string
    ---@return string?
    local function line_containing(h, sub)
        for _, line in ipairs(lines_of(h)) do
            if line:find(sub, 1, true) then
                return line
            end
        end
        return nil
    end

    it("tags a delivered steer with the steer icon and PiSteerDelivered", function()
        local h = setup_history()
        h:add_user_message("redirect please", nil, nil, "steer")
        pump()

        local line = line_containing(h, Config.options.labels.steer_message)
        assert.is_not_nil(line, "expected the steer label on the message line")

        local groups = hl_groups(h)
        assert.is_true(groups["PiSteerDelivered"] == true)
        assert.is_nil(groups["PiFollowUpDelivered"])
    end)

    it("tags a delivered follow-up with the follow-up icon and PiFollowUpDelivered", function()
        local h = setup_history()
        h:add_user_message("and then this", nil, nil, "follow_up")
        pump()

        assert.is_not_nil(line_containing(h, Config.options.labels.follow_up_message))

        local groups = hl_groups(h)
        assert.is_true(groups["PiFollowUpDelivered"] == true)
        assert.is_nil(groups["PiSteerDelivered"])
    end)

    it("leaves a plain user message untagged", function()
        local h = setup_history()
        h:add_user_message("just a prompt", nil, nil, nil)
        pump()

        local groups = hl_groups(h)
        assert.is_nil(groups["PiSteerDelivered"])
        assert.is_nil(groups["PiFollowUpDelivered"])
        assert.is_nil(line_containing(h, Config.options.labels.steer_message))
        assert.is_nil(line_containing(h, Config.options.labels.follow_up_message))
    end)

    it("marks a message delivered through the pending-queue path", function()
        local h = setup_history()
        h:add_pending_queue_entry("steer", "queued steer", "queued steer")

        -- Delivery: message_start removes the pending entry and hands its
        -- queue_type to the normal user-message renderer.
        local entry = h:remove_pending_queue_entry("queued steer")
        assert.is_not_nil(entry)
        h:add_user_message(entry.text, nil, nil, entry.queue_type)
        pump()

        assert.is_true(hl_groups(h)["PiSteerDelivered"] == true)
    end)

    it("defines both delivered-tag highlight groups", function()
        local steer = vim.api.nvim_get_hl(0, { name = "PiSteerDelivered", link = false })
        local follow = vim.api.nvim_get_hl(0, { name = "PiFollowUpDelivered", link = false })
        local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
        assert.are.equal(comment.fg, steer.fg)
        assert.are.equal(comment.fg, follow.fg)
    end)
end)
