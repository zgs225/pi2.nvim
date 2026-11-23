-- Generation speed (`58 tok/s`) on the turn's completion marker.
--
-- π reports no throughput: `usage.output` arrives once per assistant message on
-- `message_end`, and the clock is ours. `pi.turn_rate` sums output tokens and
-- decode windows (first streamed delta -> `message_end`) per timed message, so
-- tool execution time is never charged to the model and time-to-first-token is
-- excluded. The history appends the ratio to the existing completion marker
-- (`· 2s · 60 tok/s`), gated by `turn_stats`.

local TurnRate = require("pi.turn_rate")
local Config = require("pi.config")
local History = require("pi.ui.chat.history")

local TAB = 971

local function pump(ms)
    vim.wait(ms or 60)
end

--- Every inline virt_text chunk in the buffer, concatenated per extmark.
---@param h pi.ChatHistory
---@return string[]
local function virt_texts(h)
    local out = {}
    for _, em in ipairs(vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })) do
        local vt = (em[4] or {}).virt_text
        if type(vt) == "table" then
            local parts = {}
            for _, chunk in ipairs(vt) do
                parts[#parts + 1] = type(chunk[1]) == "string" and chunk[1] or ""
            end
            out[#out + 1] = table.concat(parts)
        end
    end
    return out
end

--- First inline virt_text containing `needle`.
---@param h pi.ChatHistory
---@param needle string
---@return string? text
---@return string? hl
local function inline_chunk(h, needle)
    for _, em in ipairs(vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })) do
        local vt = (em[4] or {}).virt_text
        if type(vt) == "table" then
            for _, chunk in ipairs(vt) do
                if type(chunk[1]) == "string" and chunk[1]:find(needle, 1, true) then
                    return chunk[1], chunk[2]
                end
            end
        end
    end
    return nil, nil
end

local function delete(h)
    pcall(vim.api.nvim_buf_delete, h:buf(), { force = true })
end

describe("pi.turn_rate", function()
    it("banks output tokens against the first-delta -> message_end window", function()
        local meter = TurnRate.new()
        meter:on_message_start()
        meter:on_update(100)
        meter:on_message_end({ output = 120 }, "stop", 102)

        assert.are.same({ tokens = 120, secs = 2 }, meter:summary())
    end)

    it("keeps the first delta as the window start", function()
        local meter = TurnRate.new()
        meter:on_message_start()
        meter:on_update(10)
        meter:on_update(40) -- later deltas must not move the start
        meter:on_message_end({ output = 50 }, "stop", 20)

        assert.are.same({ tokens = 50, secs = 10 }, meter:summary())
    end)

    it("sums the tool loop of one run and never charges tool time", function()
        local meter = TurnRate.new()
        -- Message 1: decode 1s, 100 tokens. Then 30s of tool execution (no window).
        meter:on_message_start()
        meter:on_update(0)
        meter:on_message_end({ output = 100 }, "toolUse", 1)
        -- Message 2 starts at t=31 and decodes for 3s.
        meter:on_message_start()
        meter:on_update(31)
        meter:on_message_end({ output = 300 }, "stop", 34)

        assert.are.same({ tokens = 400, secs = 4 }, meter:summary())
    end)

    it("starts a fresh window per message", function()
        local meter = TurnRate.new()
        meter:on_message_start()
        meter:on_update(0)
        meter:on_message_end({ output = 10 }, "stop", 1)
        -- No delta for this message: no window, so nothing is banked.
        meter:on_message_start()
        meter:on_message_end({ output = 999 }, "stop", 5)

        assert.are.same({ tokens = 10, secs = 1 }, meter:summary())
    end)

    it("skips aborted and errored messages", function()
        local meter = TurnRate.new()
        for _, stop in ipairs({ "aborted", "error" }) do
            meter:on_message_start()
            meter:on_update(0)
            meter:on_message_end({ output = 500 }, stop, 1)
        end

        assert.is_nil(meter:summary())
    end)

    it("skips a message whose usage reports no output tokens", function()
        local meter = TurnRate.new()
        for _, usage in ipairs({ { output = 0 }, {}, nil }) do
            meter:on_message_start()
            meter:on_update(0)
            meter:on_message_end(usage, "stop", 1)
        end

        assert.is_nil(meter:summary())
    end)

    it("skips a non-positive window instead of dividing by it", function()
        local meter = TurnRate.new()
        meter:on_message_start()
        meter:on_update(5)
        meter:on_message_end({ output = 100 }, "stop", 5)

        assert.is_nil(meter:summary())
    end)

    it("reset drops everything (a new agent run)", function()
        local meter = TurnRate.new()
        meter:on_message_start()
        meter:on_update(0)
        meter:on_message_end({ output = 100 }, "stop", 1)
        meter:reset()

        assert.is_nil(meter:summary())
    end)

    it("formats a rate: integer >= 10, one decimal below, nil when meaningless", function()
        assert.are.equal("60 tok/s", TurnRate.format(600, 10))
        assert.are.equal("10 tok/s", TurnRate.format(20, 2))
        assert.are.equal("4.2 tok/s", TurnRate.format(42, 10))
        assert.is_nil(TurnRate.format(5, 10), "under 1 tok/s says nothing about speed")
        assert.is_nil(TurnRate.format(10, 1), "fewer than MIN_TOKENS tokens is sampling noise")
        assert.is_nil(TurnRate.format(0, 10))
        assert.is_nil(TurnRate.format(100, 0))
        assert.is_nil(TurnRate.format(nil, 1))
    end)
end)

describe("completion marker: generation speed", function()
    --- A history whose run started `secs` seconds ago, with one streamed line.
    ---@param secs number
    ---@return pi.ChatHistory
    local function run_with_elapsed(secs)
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        h:on_text_delta("streamed answer")
        pump(30)
        h._agent_start_time = vim.uv.hrtime() / 1e9 - secs
        return h
    end

    it("appends the rate to the completion marker", function()
        local h = run_with_elapsed(2)
        h:on_agent_end("Done", { rate = { tokens = 600, secs = 10 } })
        pump(80)

        local text, hl = inline_chunk(h, "tok/s")
        assert.are.equal("  · 2s · 60 tok/s", text)
        assert.are.equal("PiBusyTime", hl)
        -- one marker: the rate is part of the same suffix, after the duration
        local marker = inline_chunk(h, "· 2s")
        assert.is_not_nil(marker)
        delete(h)
    end)

    it("prints the rate alone when the stream lasted under a second", function()
        -- A fast run used to produce no marker at all (`secs < 1`); a rate that
        -- is worth measuring now justifies one on its own.
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        h:on_text_delta("streamed answer")
        pump(30)
        h:on_agent_end("Done", { rate = { tokens = 250, secs = 1 } })
        pump(80)

        assert.are.equal("  · <1s · 250 tok/s", inline_chunk(h, "tok/s"))
        delete(h)
    end)

    it("stays silent for a sub-second stream with too few tokens to time", function()
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        h:on_text_delta("ok")
        pump(30)
        h:on_agent_end("Done", { rate = { tokens = 3, secs = 0.03 } })
        pump(80)

        assert.is_nil(inline_chunk(h, "tok/s"))
        assert.is_nil(inline_chunk(h, "<1s"), "no duration marker either — the run was instant")
        delete(h)
    end)

    it("carries the rate on the standalone line when the last line has no room", function()
        local h = History.new(TAB)
        h:on_agent_start(nil)
        pump(30)
        -- Wider than the 80-column threshold once the suffix is added, so the
        -- marker takes the standalone fallback (`<verb> in 2s`) instead of
        -- inline virtual text.
        h:on_text_delta(string.rep("x", 90))
        pump(30)
        h._agent_start_time = vim.uv.hrtime() / 1e9 - 2
        h:on_agent_end("Shipped", { rate = { tokens = 600, secs = 10 } })
        pump(80)

        local found
        for _, line in ipairs(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)) do
            if line:find("Shipped in 2s", 1, true) then
                found = line
            end
        end
        assert.are.equal("Shipped in 2s · 60 tok/s", found)
        delete(h)
    end)

    it("renders no rate when none was measured (replay, abort, no usage)", function()
        local h = run_with_elapsed(2)
        h:on_agent_end("Done")
        pump(80)

        assert.is_nil(inline_chunk(h, "tok/s"))
        assert.is_not_nil(inline_chunk(h, "· 2s"), "the duration marker is unaffected")
        delete(h)
    end)

    it("honours turn_stats = false", function()
        local previous = Config.options.turn_stats
        Config.options.turn_stats = false
        local h = run_with_elapsed(2)
        h:on_agent_end("Done", { rate = { tokens = 600, secs = 10 } })
        pump(80)

        for _, text in ipairs(virt_texts(h)) do
            assert.is_nil(text:find("tok/s", 1, true), "turn_stats = false hides the rate")
        end
        delete(h)
        Config.options.turn_stats = previous
    end)
end)

describe("manager wiring: generation speed", function()
    local Sessions = require("pi.sessions.manager")

    --- A chat stub that records the rate handed over at `agent_end`.
    ---@return table
    local function fake_chat()
        local chat = { ended = 0 }
        function chat:on_agent_start() end
        function chat:on_message_start() end
        function chat:on_message_end() end
        function chat:on_thinking_end() end
        function chat:on_text_delta() end
        function chat:active_verb()
            return "Working"
        end
        function chat:set_status() end
        function chat:on_agent_end(rate)
            self.ended = self.ended + 1
            self.rate = rate
        end
        return chat
    end

    --- A bare session, enough for the event branches under test.
    ---@param chat table
    ---@return pi.Session
    local function fake_session(chat)
        return {
            id = "turn-rate-session",
            attention = { pending = {} },
            rpc = {
                send = function() end,
                is_running = function()
                    return false
                end,
            },
            chat = chat,
        }
    end

    it("hands the run's measured rate to the chat at agent_end", function()
        local chat = fake_chat()
        local session = fake_session(chat)

        Sessions.handle_event(session, { type = "agent_start" })
        Sessions.handle_event(session, {
            type = "message_start",
            message = { role = "assistant", content = {}, stopReason = "pending" },
        })
        Sessions.handle_event(session, {
            type = "message_update",
            assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = "hello" },
        })
        pump(60)
        Sessions.handle_event(session, {
            type = "message_end",
            message = { role = "assistant", stopReason = "stop", usage = { output = 120 } },
        })
        Sessions.handle_event(session, { type = "agent_end", messages = {} })

        assert.are.equal(1, chat.ended)
        assert.are.same({ tokens = 120 }, { tokens = chat.rate and chat.rate.tokens })
        assert.is_true((chat.rate and chat.rate.secs or 0) > 0, "the decode window was measured")
    end)

    it("resets the meter on a new run, so a retry does not inherit it", function()
        local chat = fake_chat()
        local session = fake_session(chat)

        Sessions.handle_event(session, { type = "agent_start" })
        Sessions.handle_event(session, {
            type = "message_start",
            message = { role = "assistant", content = {}, stopReason = "pending" },
        })
        Sessions.handle_event(session, {
            type = "message_update",
            assistantMessageEvent = { type = "text_delta", contentIndex = 0, delta = "first" },
        })
        pump(40)
        Sessions.handle_event(session, {
            type = "message_end",
            message = { role = "assistant", stopReason = "stop", usage = { output = 120 } },
        })
        Sessions.handle_event(session, { type = "agent_end", messages = {} })

        -- Retry: a fresh agent_start, then an error before any delta.
        Sessions.handle_event(session, { type = "agent_start" })
        Sessions.handle_event(session, {
            type = "message_end",
            message = { role = "assistant", stopReason = "error", usage = { output = 999 } },
        })
        Sessions.handle_event(session, { type = "agent_end", messages = {} })

        assert.are.equal(2, chat.ended)
        assert.is_nil(chat.rate, "an errored run with no streamed delta has nothing to report")
    end)
end)
