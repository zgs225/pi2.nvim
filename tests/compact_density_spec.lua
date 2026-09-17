-- Compact history density (`density = "compact"`).
--
-- Comfortable (default) keeps the legacy breathing-blank rhythm and is
-- covered by the per-feature specs (agent_label_spacing_spec, thinking_
-- spacing_spec, history_style_spec, ...). This file pins the compact
-- behavior: zero extra blank lines within a turn, a one-line collapsed
-- summary for completed tool blocks (diff counts when available), inline
-- read/ls, suppressed live updates, and replay-safe degradation.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")

local function pump(ms)
    vim.wait(ms or 60)
end

local function lines_of(h)
    return vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
end

--- Rows (0-indexed) of every buffer line containing `sub` (plain match).
local function rows_with(h, sub)
    local out = {}
    for i, l in ipairs(lines_of(h)) do
        if l:find(sub, 1, true) then
            out[#out + 1] = i - 1
        end
    end
    return out
end

--- Live-event shaped tool result.
local function result_text(text)
    return { content = { { type = "text", text = text } } }
end

--- Blank-line rhythm helpers: {0} = row, {1} = true when blank.
local function blanks(h)
    local out = {}
    for i, l in ipairs(lines_of(h)) do
        out[i] = l == ""
    end
    return out
end

describe("compact density", function()
    before_each(function()
        Config.options.density = "compact"
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    after_each(function()
        Config.options.density = "comfortable"
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    describe("spacing", function()
        it("renders a user message with no leading blank in an empty buffer", function()
            local h = History.new(60)
            h:add_user_message("hello", os.time() * 1000)
            pump()
            local lines = lines_of(h)
            assert.is_truthy(lines[1]:find(Config.options.labels.user_message, 1, true), "label is line 1")
            assert.is_truthy(lines[1]:find("%d%d:%d%d"), "timestamp kept on the label")
            assert.are_equal("  hello", lines[2], "body directly below the label")
        end)

        it("uses zero blank lines between label, body, thinking and tool blocks", function()
            local h = History.new(61)
            h:add_user_message("hello", os.time() * 1000)
            pump()
            h:on_tool_start("bash", "t1", { command = "ls" })
            pump()
            local lines = lines_of(h)
            -- label / body / header, no breathing blanks
            assert.are_equal("  hello", lines[2])
            assert.is_truthy(lines[3]:find("bash", 1, true))
        end)

        it("puts exactly one blank line between turns (turn_separator on)", function()
            local h = History.new(62)
            h:add_user_message("first", os.time() * 1000)
            pump()
            h:on_agent_start(os.time() * 1000)
            pump()
            h:on_text_delta("reply")
            pump()
            h:on_agent_end("Completed", { force_completion = true })
            pump()
            h:add_user_message("second", os.time() * 1000)
            pump()
            local lines = lines_of(h)
            -- find the second label; the previous line must be blank and the
            -- line before that must be content (exactly one gap line)
            local r0 = rows_with(h, Config.options.labels.user_message)[2] -- 0-indexed row of the 2nd label
            assert.is_truthy(r0 and r0 >= 2)
            -- the line before the second label (1-indexed lines[r0]) is the gap
            assert.are_equal("", lines[r0], "exactly one blank gap line before the label")
            assert.is_not_equal("", lines[r0 - 1], "content above the gap")
        end)

        it("adds no gap between turns when turn_separator is off", function()
            Config.options.turn_separator = false
            local h = History.new(63)
            h:add_user_message("first", os.time() * 1000)
            pump()
            h:on_agent_start(os.time() * 1000)
            pump()
            h:on_text_delta("reply")
            pump()
            h:on_agent_end("Completed", { force_completion = true })
            pump()
            h:add_user_message("second", os.time() * 1000)
            pump()
            local lines = lines_of(h)
            local r0 = rows_with(h, Config.options.labels.user_message)[2]
            assert.is_truthy(r0, "second user label exists")
            assert.is_not_equal("", lines[r0], "no gap line before the label")
        end)

        it("keeps the tool block's structural footer blank between tool blocks", function()
            local h = History.new(64)
            h:on_tool_start("bash", "t1", { command = "echo one" })
            pump()
            h:on_tool_end("bash", "t1", result_text("out"), false)
            pump()
            h:on_tool_start("bash", "t2", { command = "echo two" })
            pump()
            h:on_tool_end("bash", "t2", result_text("out2"), false)
            pump()
            local lines = lines_of(h)
            -- Each collapsed block is header/input/summary + its footer blank
            assert.are_equal(8, #lines, "two collapsed blocks of 3 lines + footer each")
            assert.are_equal("", lines[4])
            assert.are_equal("", lines[8])
        end)

        it("shows the agent label with a timestamp once per turn", function()
            local h = History.new(65)
            h:on_agent_start(os.time() * 1000)
            pump()
            h:on_text_delta("reply body")
            pump()
            local lines = lines_of(h)
            assert.is_truthy(lines[1]:find(Config.options.labels.agent_response, 1, true), "label is line 1")
            assert.is_truthy(lines[1]:find("%d%d:%d%d"), "timestamp kept on the label")
            assert.are_equal("reply", (lines[2]:match("^reply")), "text starts below the label")
        end)

        it("renders no label row for later assistant messages of the same turn", function()
            local h = History.new(77)
            h:add_user_message("ask", os.time() * 1000)
            pump()
            -- first agent message: text only
            h:on_agent_start(os.time() * 1000)
            pump()
            h:on_text_delta("first reply")
            pump()
            -- second agent message of the same turn: tool-only (no text)
            h:on_tool_start("read", "r1", { path = "src/a.lua" })
            pump()
            h:on_tool_end("read", "r1", result_text("body"), false)
            pump()
            local lines = lines_of(h)
            local labels = rows_with(h, Config.options.labels.agent_response)
            assert.are_equal(1, #labels, "exactly one agent label row in the turn")
            -- no icon-only row (label rows all carry the timestamp)
            for _, l in ipairs(lines) do
                assert.is_false(vim.trim(l) == Config.options.labels.agent_response, "bare icon-only row: " .. l)
            end
            h:on_agent_start(os.time() * 1000)
            pump()
            h:on_text_delta("second reply")
            pump()
            labels = rows_with(h, Config.options.labels.agent_response)
            assert.are_equal(1, #labels, "still one label after a second agent start")
            local second = rows_with(h, "second reply")
            assert.are_equal(1, #second, "second reply visible")
        end)

        it("labels the agent response of a new turn again", function()
            local h = History.new(78)
            h:add_user_message("ask 1", os.time() * 1000)
            pump()
            h:on_agent_start(os.time() * 1000)
            pump()
            h:on_text_delta("reply 1")
            pump()
            h:on_agent_end("Completed", { force_completion = true })
            pump()
            h:add_user_message("ask 2", os.time() * 1000)
            pump()
            h:on_agent_start(os.time() * 1000)
            pump()
            h:on_text_delta("reply 2")
            pump()
            local labels = rows_with(h, Config.options.labels.agent_response)
            assert.are_equal(2, #labels, "one label per turn")
        end)
    end)

    describe("thinking blocks", function()
        it("freezes to a single header line (no duplicate header rows)", function()
            local h = History.new(66)
            h:on_thinking_start()
            h:on_thinking_delta("deep thoughts ")
            pump()
            h:on_thinking_end()
            pump()
            local lines = lines_of(h)
            -- The header is the block's only content line; a trailing blank
            -- may remain from the pre-existing buffer tail.
            assert.are_equal(1, #rows_with(h, "Thought"), "single header row")
            assert.are_equal(0, #rows_with(h, "Thinking…"), "no duplicate streaming header")
            assert.is_truthy(lines[1]:find("Thought", 1, true))
        end)

        it("keeps single-line geometry through toggle_thinking hide/show", function()
            local h = History.new(67)
            h:on_thinking_start()
            h:on_thinking_delta("deep thoughts ")
            pump()
            h:on_thinking_end()
            pump()
            Config.options.show_thinking = false
            h:toggle_thinking()
            pump()
            local hidden = lines_of(h)
            assert.are_equal(0, #rows_with(h, "Thought"), "hidden removes the header")
            Config.options.show_thinking = true
            h:toggle_thinking()
            pump()
            local lines = lines_of(h)
            assert.are_equal(1, #rows_with(h, "Thought"), "shown again as a single header line")
        end)

        it("expands and collapses around the single-line header", function()
            local h = History.new(68)
            h:on_thinking_start()
            h:on_thinking_delta("deep thoughts ")
            pump()
            h:on_thinking_end()
            pump()
            h:set_blocks_expanded(true)
            pump()
            assert.are_equal(1, #rows_with(h, "deep thoughts"), "content visible when expanded")
            h:set_blocks_expanded(false)
            pump()
            lines = lines_of(h)
            assert.are_equal(1, #rows_with(h, "Thought"), "collapsed back to a single header row")
            assert.is_truthy(lines[1]:find("Thought", 1, true))
        end)
    end)

    describe("tool collapse", function()
        it("collapses a completed bash block to header + input + summary", function()
            local h = History.new(69)
            h:on_tool_start("bash", "t1", { command = "ls -la" })
            pump()
            h:on_tool_end("bash", "t1", result_text("out1\nout2\nout3\nout4"), false)
            pump()
            local lines = lines_of(h)
            assert.are_equal(4, #lines, "header + input + summary + footer")
            assert.is_truthy(lines[1]:find("bash", 1, true))
            assert.are_equal("ls -la", lines[2])
            assert.are_equal(Config.options.labels.tool_summary .. " (4 lines)", lines[3])
            assert.are_equal("", lines[4])
        end)

        it("suppresses live updates while running (collapsed from the start)", function()
            local h = History.new(70)
            h:on_tool_start("bash", "t1", { command = "tail -f" })
            pump()
            h:on_tool_update("bash", "t1", { partialResult = { content = "live1\nlive2" } })
            pump()
            h:on_tool_update("bash", "t1", { partialResult = { content = "live3" } })
            pump()
            -- Only header + input: no live partial output lines
            assert.are_equal(2, #lines_of(h))
            h:on_tool_end("bash", "t1", result_text("final"), false)
            pump()
            assert.are_equal(4, #lines_of(h))
        end)

        it("keeps errored blocks expanded with the error footer visible", function()
            local h = History.new(71)
            h:on_tool_start("bash", "t1", { command = "boom" })
            pump()
            h:on_tool_end("bash", "t1", result_text("error text line"), true)
            pump()
            local lines = lines_of(h)
            assert.is_truthy(#lines >= 4)
            assert.is_truthy(rows_with(h, "error") and #rows_with(h, "error") >= 1, "error status visible")
            assert.is_truthy(#rows_with(h, "error text line") >= 1, "error message visible (not collapsed)")
        end)

        it("shows (+N −M) for an edit whose target file exists", function()
            local path = vim.fn.tempname() .. ".lua"
            vim.fn.writefile({ "a", "b", "c" }, path)
            local h = History.new(72)
            h:on_tool_start("edit", "e1", {
                path = path,
                edits = { { oldText = "b", newText = "x\ny" } },
            })
            pump()
            h:on_tool_end("edit", "e1", result_text("[accepted] applied"), false)
            pump()
            local summary = rows_with(h, "(+2 −1)")
            assert.are_equal(1, #summary, "expected one (+2 −1) summary row")
            os.remove(path)
        end)

        it("degrades a replayed write to path only (no diff data)", function()
            local h = History.new(73)
            h._replaying = true
            h:on_tool_start("write", "w1", { path = "src/bar.lua" })
            pump()
            h:on_tool_end("write", "w1", result_text("written"), false)
            pump()
            local lines = lines_of(h)
            assert.is_truthy(#rows_with(h, "src/bar.lua") >= 1)
            for _, l in ipairs(lines) do
                assert.is_false(l:find("⎿", 1, true) ~= nil, "no summary without diff data: " .. l)
            end
        end)

        it("renders ls inline like read", function()
            local h = History.new(74)
            h:on_tool_start("ls", "l1", { path = "src" })
            pump()
            local lines = lines_of(h)
            assert.are_equal(1, #lines)
            assert.is_truthy(lines[1]:find("ls", 1, true))
            assert.is_truthy(lines[1]:find("src", 1, true))
            h:on_tool_end("ls", "l1", result_text("a\nb"), false)
            pump()
            assert.are_equal(1, #lines_of(h))
        end)

        it("keeps grep result expandable via set_blocks_expanded", function()
            local h = History.new(75)
            h:on_tool_start("grep", "g1", { pattern = "main" })
            pump()
            h:on_tool_end(
                "grep",
                "g1",
                result_text("src/a.lua:1: main here\nsrc/b.lua:5: main again\nsrc/c.lua:9: main more"),
                false
            )
            pump()
            -- collapsed: header + input + ⎿ summary + footer
            local collapsed = lines_of(h)
            assert.are_equal(4, #collapsed)
            assert.are_equal(Config.options.labels.tool_summary .. " (3 lines)", collapsed[3])
            h:set_blocks_expanded(true)
            pump()
            local expanded = lines_of(h)
            assert.is_truthy(#rows_with(h, "main here") >= 1, "grep hits visible when expanded")
            h:set_blocks_expanded(false)
            pump()
            assert.are_equal(4, #lines_of(h))
        end)

        it("keeps the dispatch_subagents task tree expanded in compact", function()
            local h = History.new(76)
            local items = { { ref = "a", task = "do a" } }
            h:on_tool_start("dispatch_subagents", "d1", { items = items })
            pump()
            h:on_tool_end("dispatch_subagents", "d1", {
                content = {
                    {
                        type = "text",
                        text = vim.json.encode({ status = "completed", items = { { ref = "a", status = "ok" } } }),
                    },
                },
            }, false)
            pump()
            local lines = lines_of(h)
            local found_tree = false
            for _, l in ipairs(lines) do
                if l:find("do a", 1, true) then
                    found_tree = true
                end
            end
            assert.is_true(found_tree, "item task line stays visible")
            for _, l in ipairs(lines) do
                assert.is_false(l:find("⎿", 1, true) ~= nil, "no collapsed summary line: " .. l)
            end
        end)
    end)
end)
