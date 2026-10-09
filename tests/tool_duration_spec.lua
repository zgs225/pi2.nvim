-- Tool execution duration (pi 1.1.0+ `durationMs`).
--
-- pi 1.1.0 adds a millisecond `durationMs` field to the `tool_execution_end`
-- event (and to replayed ToolResultMessages). The completed tool block shows
-- it as inline status text: `Took 1.5s` for >= 1s, `Took 234ms` below that.
-- The field is absent on pi < 1.1.0 and in legacy session records — then no
-- duration text is rendered at all (old-pi behavior is byte-identical).

local History = require("pi.ui.chat.history")

local TAB = 970

local function pump(ms)
    vim.wait(ms or 60)
end

--- First inline virt_text chunk containing `Took`, with its highlight group.
---@param h pi.ChatHistory
---@return string? text
---@return string? hl
local function duration_chunk(h)
    for _, em in ipairs(vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })) do
        local vt = (em[4] or {}).virt_text
        if vt then
            for _, chunk in ipairs(vt) do
                if type(chunk[1]) == "string" and chunk[1]:find("Took", 1, true) then
                    return vim.trim(chunk[1]), chunk[2]
                end
            end
        end
    end
    return nil, nil
end

local function delete(h)
    pcall(vim.api.nvim_buf_delete, h:buf(), { force = true })
end

describe("tool execution duration (durationMs)", function()
    it("shows Took <x.x>s on a block tool when durationMs >= 1000", function()
        local h = History.new(TAB)
        h:on_tool_start("mystery_tool", "b1", {})
        pump(60)
        h:on_tool_end("mystery_tool", "b1", { durationMs = 1500 }, false)
        pump(80)

        local text, hl = duration_chunk(h)
        assert.are.equal("Took 1.5s", text)
        assert.are.equal("PiToolStatus", hl)
        delete(h)
    end)

    it("shows Took <n>ms on a block tool when durationMs < 1000", function()
        local h = History.new(TAB)
        h:on_tool_start("mystery_tool", "b2", {})
        pump(60)
        h:on_tool_end("mystery_tool", "b2", { durationMs = 234 }, false)
        pump(80)

        local text, hl = duration_chunk(h)
        assert.are.equal("Took 234ms", text)
        assert.are.equal("PiToolStatus", hl)
        delete(h)
    end)

    it("shows no duration text on a block tool when durationMs is absent", function()
        local h = History.new(TAB)
        h:on_tool_start("mystery_tool", "b3", {})
        pump(60)
        h:on_tool_end("mystery_tool", "b3", {}, false)
        pump(80)

        assert.is_nil(duration_chunk(h))
        delete(h)
    end)

    it("shows Took <x.x>s on an inline tool when durationMs >= 1000", function()
        local h = History.new(TAB)
        h:on_tool_start("read", "i1", { path = "x.lua" })
        pump(60)
        h:on_tool_end("read", "i1", { durationMs = 1500, content = { { type = "text", text = "a\nb" } } }, false)
        pump(80)

        local text, hl = duration_chunk(h)
        assert.are.equal("Took 1.5s", text)
        assert.are.equal("PiToolStatus", hl)
        delete(h)
    end)

    it("shows no duration text on an inline tool when durationMs is absent", function()
        local h = History.new(TAB)
        h:on_tool_start("read", "i2", { path = "x.lua" })
        pump(60)
        h:on_tool_end("read", "i2", { content = { { type = "text", text = "a\nb" } } }, false)
        pump(80)

        assert.is_nil(duration_chunk(h))
        delete(h)
    end)

    it("keeps the duration on the header across a replay-style result", function()
        -- Replay passes the ToolResultMessage itself as `result`; its
        -- durationMs must reach the same render path.
        local h = History.new(TAB)
        h:on_tool_start("mystery_tool", "r1", {})
        pump(60)
        h:on_tool_end("mystery_tool", "r1", { durationMs = 1000, content = {} }, false)
        pump(80)

        local text = duration_chunk(h)
        assert.are.equal("Took 1.0s", text)
        delete(h)
    end)
end)
