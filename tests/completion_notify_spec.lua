-- Completion toast: skip replay and when the user is already looking at π.

local Attention = require("pi.attention")
local SessionList = require("pi.ui.sessions")

---@param opts { replaying?: boolean, chat_focus?: boolean }
---@return pi.Chat
local function stub_chat(opts)
    return {
        _history = { _replaying = opts.replaying == true },
        has_focus = function()
            return opts.chat_focus == true
        end,
    }
end

describe("attention.should_notify_on_completion", function()
    before_each(function()
        SessionList._reset()
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
    end)

    it("allows a live turn when the user is elsewhere", function()
        assert.is_true(Attention.should_notify_on_completion(stub_chat({})))
    end)

    it("skips while history is being replayed", function()
        assert.is_false(Attention.should_notify_on_completion(stub_chat({ replaying = true })))
    end)

    it("skips when the chat already has focus", function()
        assert.is_false(Attention.should_notify_on_completion(stub_chat({ chat_focus = true })))
    end)

    it("skips when :PiSessions has focus", function()
        SessionList.open()
        assert.is_true(SessionList.has_focus())
        assert.is_false(Attention.should_notify_on_completion(stub_chat({})))
    end)

    it("does not treat an unrelated window as :PiSessions focus", function()
        assert.is_false(SessionList.has_focus())
        assert.is_true(Attention.should_notify_on_completion(stub_chat({})))
    end)
end)
