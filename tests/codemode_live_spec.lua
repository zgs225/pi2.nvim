-- Live progress rows for a running codemode script (phase 2).
--
-- pi's codemode tool publishes `onUpdate({ content = {}, details = snapshot() })`,
-- so the `tool_execution_update` message for a running script carries the nested
-- call records in `partialResult.details.calls` and NO text. The renderer's
-- `on_update` hook (lua/pi/ui/chat/tools.lua) turns that into rows for the
-- block's live-update region (lua/pi/ui/chat/history.lua `_apply_tool_update`),
-- which `on_tool_end` replaces with the final rendering.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")

local TAB = 941

local SCRIPT = "const a = await tools.first({ x: 1 });\ntext(a);"

--- The history calls are `vim.schedule`d and live updates ride a coalescing
--- timer (History._stream_flush_ms), so every step needs a real wait.
local function pump(ms)
    vim.wait(ms or 120)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Rows (0-indexed) containing `sub` (plain match).
---@return integer[]
local function rows_with(buf, sub)
    local out = {}
    for i, line in ipairs(lines_of(buf)) do
        if line:find(sub, 1, true) then
            out[#out + 1] = i - 1
        end
    end
    return out
end

--- Number of rows containing `sub` (plain match).
---@return integer
local function count_rows(buf, sub)
    return #rows_with(buf, sub)
end

---@return pi.ChatHistory
local function new_history(tab)
    local h = History.new(tab or TAB)
    h._blocks_expanded = true
    return h
end

--- A live `tool_execution_update` message with the codemode wire shape:
--- empty content, calls in `partialResult.details.calls`.
---@param calls table[]
---@return table
local function live_update(calls)
    return { partialResult = { content = {}, details = { calls = calls } } }
end

---@param name string
---@param status string
---@param args string?
---@return table
local function call(name, status, args)
    return { name = name, args = args or "", status = status }
end

--- A real-looking final codemode result (SCRIPT_HEADER + one unlabelled section).
---@param calls table[]
---@return table
local function final_result(calls)
    return {
        role = "toolResult",
        toolName = "codemode",
        content = {
            {
                type = "text",
                text = "Script completed\nWall time 0.2 seconds\nOutput:\n" .. '{"ok":true}',
            },
        },
        details = { calls = calls },
        isError = false,
        durationMs = 210,
    }
end

describe("codemode live progress", function()
    before_each(function()
        Config.options.render = { engine = "builtin" }
    end)

    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    it("renders the calls a running script has made", function()
        local h = new_history()
        h:on_tool_start("codemode", "cm-live", { code = SCRIPT })
        pump()
        h:on_tool_update("codemode", "cm-live", live_update({ call("alpha_call", "running", '{"x":1}') }))
        pump()

        local buf = h:buf()
        local rows = rows_with(buf, "↳ ◐ alpha_call")
        assert.are.equal(1, #rows)
        assert.is_true(rows_with(buf, '{"x":1}')[1] == rows[1], "args must share the call row")
        -- The live rows sit below the script line of the block.
        assert.is_true(rows[1] > rows_with(buf, "const a = await tools.first")[1])
    end)

    it("replaces the region instead of accumulating on the next update", function()
        local h = new_history()
        h:on_tool_start("codemode", "cm-live", { code = SCRIPT })
        pump()
        h:on_tool_update("codemode", "cm-live", live_update({ call("alpha_call", "running") }))
        pump()
        h:on_tool_update(
            "codemode",
            "cm-live",
            live_update({
                call("alpha_call", "ok", '{"x":1}'),
                call("beta_call", "running"),
            })
        )
        pump()

        local buf = h:buf()
        assert.are.equal(1, count_rows(buf, "alpha_call"))
        assert.are.equal(1, count_rows(buf, "beta_call"))
        assert.are.equal(0, count_rows(buf, "◐ alpha_call"))
        assert.are.equal(1, count_rows(buf, "↳ ✓ alpha_call"))
        assert.are.equal(1, count_rows(buf, "↳ ◐ beta_call"))
        -- Exactly two call rows: nothing accumulated from update 1.
        assert.are.equal(2, count_rows(buf, "↳ "))
    end)

    it("drops the live rows when the script finishes", function()
        local h = new_history()
        h:on_tool_start("codemode", "cm-live", { code = SCRIPT })
        pump()
        local before = #lines_of(h:buf())

        h:on_tool_update(
            "codemode",
            "cm-live",
            live_update({
                call("alpha_call", "ok", '{"x":1}'),
                call("beta_call", "running"),
            })
        )
        pump()
        assert.is_true(#lines_of(h:buf()) > before, "live rows must reach the buffer")

        h:on_tool_end(
            "codemode",
            "cm-live",
            final_result({
                call("alpha_call", "ok", '{"x":1}'),
                call("beta_call", "ok"),
            })
        )
        pump()

        local buf = h:buf()
        assert.are.equal(0, count_rows(buf, "◐"))
        assert.are.equal(1, count_rows(buf, "↳ ✓ beta_call"))
        assert.are.equal(1, count_rows(buf, '{"ok":true}'))

        -- No leftover live region: the block ends up exactly as it would have
        -- without any update in between.
        -- Separate tab so a second History never reuses (and clears) the first buffer.
        local control = new_history(TAB + 1)
        control:on_tool_start("codemode", "cm-live", { code = SCRIPT })
        pump()
        control:on_tool_end(
            "codemode",
            "cm-live",
            final_result({
                call("alpha_call", "ok", '{"x":1}'),
                call("beta_call", "ok"),
            })
        )
        pump()
        assert.are.equal(#lines_of(control:buf()), #lines_of(buf))
        -- ... and no doubled blank row where the region used to be.
        local blank_run = 0
        for _, line in ipairs(lines_of(buf)) do
            if vim.trim(line) == "" then
                blank_run = blank_run + 1
                assert.is_true(blank_run < 2, "live region left an empty row behind")
            else
                blank_run = 0
            end
        end
    end)

    it("keeps streaming text for a tool without on_update", function()
        local h = new_history()
        h:on_tool_start("bash", "b-live", { command = "cat /tmp/whatever" })
        pump()
        h:on_tool_update("bash", "b-live", {
            partialResult = { content = { { type = "text", text = "line one\nline two" } } },
        })
        pump()

        local buf = h:buf()
        assert.are.equal(1, #rows_with(buf, "line one"))
        assert.are.equal(1, #rows_with(buf, "line two"))
    end)

    it("keeps the most recent eight calls and announces the elided ones", function()
        local h = new_history()
        h:on_tool_start("codemode", "cm-live", { code = SCRIPT })
        pump()

        local calls = {}
        for i = 1, 10 do
            calls[i] = call(("k%02d"):format(i), i < 10 and "ok" or "running")
        end
        h:on_tool_update("codemode", "cm-live", live_update(calls))
        pump()

        local buf = h:buf()
        assert.are.equal(1, count_rows(buf, "… 2 earlier calls"))
        assert.are.equal(0, count_rows(buf, "k01"))
        assert.are.equal(0, count_rows(buf, "k02"))
        -- Ten calls, eight rows: the newest ones survive.
        for i = 3, 10 do
            assert.are.equal(1, count_rows(buf, ("k%02d"):format(i)))
        end
        assert.are.equal(1, count_rows(buf, "↳ ◐ k10"))
    end)
end)
