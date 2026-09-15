-- Chat submission when `_agent.send()` fails (RPC process gone): the message
-- must never be silently dropped — the prompt text and attachments are
-- restored and the user gets an error notification.

local Chat = require("pi.ui.chat")
local Prompt = require("pi.ui.chat.prompt")

local TAB = 1201

local function pump(ms)
    vim.wait(ms or 60)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function buf_contains(buf, sub)
    for _, l in ipairs(lines_of(buf)) do
        if l:find(sub, 1, true) then
            return true
        end
    end
    return false
end

local function teardown_chat(chat)
    pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
end

local function set_prompt(chat, text)
    vim.api.nvim_buf_set_lines(chat._prompt:buf(), 0, -1, false, vim.split(text, "\n", { plain = true }))
end

local function attach(chat, n)
    for i = 1, n do
        chat._attachments:_add_item(("img%d.png"):format(i), "QUJD", "image/png", 3)
    end
end

--- Chat whose agent always reports a failed send.
local function setup_failing_chat()
    local sent = {}
    local chat = Chat.new(TAB, "side", {
        send = function(cmd)
            sent[#sent + 1] = cmd
            return false
        end,
    })
    return chat, sent
end

describe("chat send failure", function()
    local notices
    local orig_notify

    before_each(function()
        notices = {}
        orig_notify = vim.notify
        vim.notify = function(msg)
            notices[#notices + 1] = msg
        end
    end)

    after_each(function()
        vim.notify = orig_notify
    end)

    it("restores the prompt text and attachments when send() returns false", function()
        local chat, sent = setup_failing_chat()

        set_prompt(chat, "keep my message")
        attach(chat, 2)
        chat:_send_message(nil)
        pump()

        -- The command was attempted exactly once.
        assert.are.equal(1, #sent)
        assert.are.equal("prompt", sent[1].type)
        -- …and the user's input is back in the prompt, ready to retry.
        assert.are.equal("keep my message", chat._prompt:text())
        assert.are.equal(2, chat._attachments:count())
        assert.is_nil(chat._vision_inflight)

        local notified = false
        for _, msg in ipairs(notices) do
            if msg:find("restored to the prompt", 1, true) then
                notified = true
            end
        end
        assert.is_true(notified, "expected an error notification about the failed send")

        teardown_chat(chat)
    end)

    it("restores images-only submissions (empty text)", function()
        local chat, sent = setup_failing_chat()

        attach(chat, 1)
        chat:_send_message(nil)
        pump()

        assert.are.equal(1, #sent)
        assert.are.equal("", chat._prompt:text())
        assert.are.equal(1, chat._attachments:count())

        teardown_chat(chat)
    end)

    it("drops the pending queue entry of a failed steer", function()
        local chat, sent = setup_failing_chat()

        set_prompt(chat, "queued message")
        chat:_send_message("steer")
        pump()

        assert.are.equal(1, #sent)
        assert.are.equal(0, #chat._history:get_pending_queue())
        assert.are.equal("queued message", chat._prompt:text())

        teardown_chat(chat)
    end)

    it("leaves the prompt untouched when send() succeeds", function()
        local chat = Chat.new(TAB, "side", {
            send = function()
                return true
            end,
        })

        set_prompt(chat, "delivered")
        chat:_send_message(nil)
        pump()

        assert.are.equal("", chat._prompt:text())
        assert.is_true(buf_contains(chat._history:buf(), "delivered"))

        teardown_chat(chat)
    end)

    it("Prompt:set_workspace keeps each prompt on its own draft file", function()
        local PH = require("pi.prompt_history")
        local Draft = require("pi.draft")
        local attachments = require("pi.ui.chat.attachments").new()
        local draft_base = vim.fn.tempname()
        vim.fn.mkdir(draft_base, "p")
        Draft._reset()
        PH._set_base_dir(draft_base)

        local prompt = Prompt.new(TAB, attachments)
        local a = vim.fn.tempname()
        local b = vim.fn.tempname()
        vim.fn.mkdir(a, "p")
        vim.fn.mkdir(b, "p")

        prompt:set_workspace(a)
        local pa = prompt._draft_path
        vim.api.nvim_buf_set_lines(prompt:buf(), 0, -1, false, { "draft A" })
        prompt:_save_draft()
        assert.are.equal("draft A", Draft.load(pa))

        prompt:set_workspace(b)
        local pb = prompt._draft_path
        assert.is_not_nil(pa)
        assert.are_not.equal(pa, pb)
        vim.api.nvim_buf_set_lines(prompt:buf(), 0, -1, false, { "draft B" })
        prompt:_save_draft()
        assert.are.equal("draft B", Draft.load(pb))
        -- Tab B's save/clear must never touch tab A's file.
        assert.are.equal("draft A", Draft.load(pa))
        Draft.clear(pb)
        assert.are.equal("draft A", Draft.load(pa))

        pcall(vim.api.nvim_buf_delete, prompt:buf(), { force = true })
        pcall(vim.api.nvim_buf_delete, attachments:buf(), { force = true })
        Draft._reset()
        PH._reset()
    end)
end)
