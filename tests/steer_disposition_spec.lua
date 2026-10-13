-- Disposition reconciliation for queued sends (pi >= 1.1.0).
--
-- `steer`/`follow_up` responses carry `data.disposition`:
--   * "queued"  — pi queued the message; the optimistic pending entry stands.
--   * "handled" — an input handler consumed it; no message will follow.
--   * "started" — pi processed it immediately rather than queueing.
-- Older pi omits `data`, in which case nothing is reconciled.

local Chat = require("pi.ui.chat")

local TAB = 1312

local function pump(ms)
    vim.wait(ms or 60)
end

local function teardown_chat(chat)
    pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
end

--- Chat whose send captures the command and its response callback.
local function setup_chat()
    local sent = {}
    local callback
    local chat = Chat.new(TAB, "side", {
        send = function(cmd, cb)
            sent[#sent + 1] = cmd
            callback = cb
            return true
        end,
    })
    return chat, sent, function()
        return callback
    end
end

local function set_prompt(chat, text)
    vim.api.nvim_buf_set_lines(chat._prompt:buf(), 0, -1, false, vim.split(text, "\n", { plain = true }))
end

local function has_hl(history, group)
    for _, em in ipairs(vim.api.nvim_buf_get_extmarks(history:buf(), history:ns(), 0, -1, { details = true })) do
        if (em[4] or {}).hl_group == group then
            return true
        end
    end
    return false
end

describe("queued-send disposition reconciliation", function()
    before_each(function()
        require("pi.config").options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    after_each(function()
        require("pi.config").options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    it("keeps the pending entry when disposition is queued", function()
        local chat, sent, get_cb = setup_chat()
        set_prompt(chat, "redirect")
        chat:_send_message("steer")
        pump()

        assert.are.equal("steer", sent[1].type)
        assert.are.equal(1, #chat._history:get_pending_queue())

        get_cb()({ type = "response", success = true, data = { disposition = "queued" } })
        pump()

        assert.are.equal(1, #chat._history:get_pending_queue())

        teardown_chat(chat)
    end)

    it("drops the pending entry when disposition is handled", function()
        local chat, _, get_cb = setup_chat()
        set_prompt(chat, "consumed by handler")
        chat:_send_message("steer")
        pump()

        get_cb()({ type = "response", success = true, data = { disposition = "handled" } })
        pump()

        assert.are.equal(0, #chat._history:get_pending_queue())

        teardown_chat(chat)
    end)

    it("drops the pending entry when disposition is started", function()
        local chat, _, get_cb = setup_chat()
        set_prompt(chat, "started immediately")
        chat:_send_message("follow_up")
        pump()

        get_cb()({ type = "response", success = true, data = { disposition = "started" } })
        pump()

        assert.are.equal(0, #chat._history:get_pending_queue())

        teardown_chat(chat)
    end)

    it("keeps the pending entry when the response has no data (old pi)", function()
        local chat, _, get_cb = setup_chat()
        set_prompt(chat, "legacy pi")
        chat:_send_message("steer")
        pump()

        get_cb()({ type = "response", success = true })
        pump()

        assert.are.equal(1, #chat._history:get_pending_queue())

        teardown_chat(chat)
    end)

    it("keeps the pending entry when the response has no disposition field", function()
        local chat, _, get_cb = setup_chat()
        set_prompt(chat, "no disposition")
        chat:_send_message("follow_up")
        pump()

        get_cb()({ type = "response", success = true, data = {} })
        pump()

        assert.are.equal(1, #chat._history:get_pending_queue())

        teardown_chat(chat)
    end)

    it("renders a handled message as a normal (untagged) user message", function()
        local chat, _, get_cb = setup_chat()
        set_prompt(chat, "redirect")
        chat:_send_message("steer")
        pump()

        get_cb()({ type = "response", success = true, data = { disposition = "handled" } })
        pump()
        assert.are.equal(0, #chat._history:get_pending_queue())

        -- A late/transformative message_start still renders — but with no steer
        -- tag, since it never sat in the queue.
        chat:on_message_start({ message = { role = "user", content = "redirect" } })
        pump()

        assert.is_false(has_hl(chat._history, "PiSteerDelivered"))

        teardown_chat(chat)
    end)

    it("tags the message when a queued steer is actually delivered", function()
        local chat, _, get_cb = setup_chat()
        set_prompt(chat, "redirect")
        chat:_send_message("steer")
        pump()

        get_cb()({ type = "response", success = true, data = { disposition = "queued" } })
        pump()

        chat:on_message_start({ message = { role = "user", content = "redirect" } })
        pump()

        assert.are.equal(0, #chat._history:get_pending_queue())
        assert.is_true(has_hl(chat._history, "PiSteerDelivered"))

        teardown_chat(chat)
    end)
end)
