-- Pure unit specs for lua/pi/codemode/tool_ui.lua: the codemode result parser
-- (header stripping, text/console/error section splitting, nested-call
-- normalization) and the row formatters the chat renderer drives.
--
-- The fixtures mirror records extracted from a real pi session
-- (`/tmp/codemode-sample/` in the issue report): `details.calls[].args` is a
-- JSON *string*, while session `nestedCalls.calls[].arguments` is a raw table.

local CodemodeToolUi = require("pi.codemode.tool_ui")

--- The `Script completed` / `Wall time` / `Output:` header pi always sends first.
local SCRIPT_HEADER = "Script completed\nWall time 0.5 seconds\nOutput:\n"

--- @param text string
--- @return table
local function text_block(text)
    return { type = "text", text = text }
end

--- Fixture 1 shape: one nested MCP call, two numbered text outputs.
---@return table
local function fixture_nested_call_result()
    return {
        role = "toolResult",
        toolCallId = "call_00_d7eketxyhv5vgdwn3vsz40om",
        toolName = "codemode",
        content = {
            text_block(SCRIPT_HEADER),
            text_block(
                "==> text 1/2 <==\nisError=false blocks=1\n==> text 2/2 <==\n"
                    .. '{"totalResults":1288,"results":[{"noteId":"kVi9C0DRgXPj","title":"","type":"text"}]}'
            ),
        },
        details = {
            calls = {
                {
                    id = "call_00_d7eketxyhv5vgdwn3vsz40om|fc_call_00_d7eketxyhv5vgdwn3vsz40om/1",
                    name = "mcp__trilium__search_notes",
                    args = '{"query":"note.type = text","limit":3,"fastSearch":true}',
                    status = "ok",
                    durationMs = 421.29069800000434,
                },
            },
        },
        isError = false,
        durationMs = 517,
        -- Session replay records also carry nestedCalls with raw `arguments`.
        nestedCalls = {
            calls = {
                {
                    id = "call_00_d7eketxyhv5vgdwn3vsz40om|fc",
                    name = "mcp__trilium__search_notes",
                    status = "ok",
                    arguments = { query = "note.type = text", limit = 3, fastSearch = true },
                    durationMs = 418,
                },
            },
            complete = true,
        },
    }
end

--- Fixture 0 shape: no calls at all, one numbered output pair.
---@return table
local function fixture_no_call_result()
    return {
        role = "toolResult",
        toolName = "codemode",
        content = {
            text_block("Script completed\nWall time 0.3 seconds\nOutput:\n"),
            text_block('==> text 1/2 <==\n{"name":"mcp__trilium"}\n==> text 2/2 <==\nSearch for notes.'),
        },
        details = { calls = {} },
        isError = false,
        durationMs = 297,
    }
end

--- All section display lines, flattened into one list (for absence asserts).
---@param parsed pi.CodemodeOutput
---@return string[]
local function all_lines(parsed)
    local out = {}
    for _, section in ipairs(parsed.sections) do
        for _, line in ipairs(section.lines) do
            out[#out + 1] = line
        end
    end
    return out
end

---@param lines string[]
---@param needle string
---@return boolean
local function any_line_contains(lines, needle)
    for _, line in ipairs(lines) do
        if line:find(needle, 1, true) then
            return true
        end
    end
    return false
end

--- Row texts as `{ row.text, row.hl }` pairs, for readable assertions.
---@param rows pi.CodemodeRow[]
---@return string[]
local function texts(rows)
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = row.text
    end
    return out
end

describe("codemode tool_ui", function()
    describe("parse", function()
        it("returns nil for a nil or content-less result", function()
            assert.is_nil(CodemodeToolUi.parse(nil))
            assert.is_nil(CodemodeToolUi.parse({}))
            assert.is_nil(CodemodeToolUi.parse({ details = { calls = {} } }))
        end)

        it("drops the script header block", function()
            local parsed = CodemodeToolUi.parse(fixture_nested_call_result())
            assert.is_not_nil(parsed)
            local lines = all_lines(parsed)
            assert.is_false(any_line_contains(lines, "Script completed"))
            assert.is_false(any_line_contains(lines, "Wall time"))
            assert.is_false(any_line_contains(lines, "Output:"))
            assert.is_false(parsed.failed)
        end)

        it("never keeps the raw ==> / <console_output> wire markers", function()
            local parsed = CodemodeToolUi.parse(fixture_nested_call_result())
            local lines = all_lines(parsed)
            assert.is_false(any_line_contains(lines, "==>"))
            assert.is_false(any_line_contains(lines, "<console_output>"))
        end)

        it("labels numbered text sections from the ==> text N/M markers", function()
            local parsed = CodemodeToolUi.parse(fixture_nested_call_result())
            assert.are.equal(2, #parsed.sections)
            assert.are.equal("text", parsed.sections[1].kind)
            assert.are.equal("text 1/2", parsed.sections[1].label)
            assert.are.same({ "isError=false blocks=1" }, parsed.sections[1].lines)
            assert.are.equal("text 2/2", parsed.sections[2].label)
            assert.is_true(parsed.sections[2].lines[1]:find("totalResults", 1, true) ~= nil)
            assert.are.equal(2, parsed.outputs)
        end)

        it("gives a single unmarked text item no label", function()
            local parsed = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("just the answer") },
                details = { calls = {} },
            })
            assert.are.equal(1, #parsed.sections)
            assert.is_nil(parsed.sections[1].label)
            assert.are.same({ "just the answer" }, parsed.sections[1].lines)
            assert.are.equal(1, parsed.outputs)
        end)

        it("strips the <console_output> tags into a console section", function()
            local parsed = CodemodeToolUi.parse({
                content = {
                    text_block(SCRIPT_HEADER),
                    text_block("==> text 1/2 <==\nfirst\n==> text 2/2 <==\nsecond"),
                    text_block("<console_output>\nlog line 1\nlog line 2\n</console_output>"),
                },
                details = { calls = {} },
            })
            assert.are.equal(3, #parsed.sections)
            local console = parsed.sections[3]
            assert.are.equal("console", console.kind)
            assert.are.equal("console", console.label)
            assert.are.same({ "log line 1", "log line 2" }, console.lines)
            -- 2 text outputs + 1 console output
            assert.are.equal(3, parsed.outputs)
        end)

        it("turns the Script error: trailer into an error section", function()
            local parsed = CodemodeToolUi.parse({
                content = {
                    text_block("Script failed\nWall time 0.1 seconds\nOutput:\n"),
                    text_block(
                        "Script error:\nTypeError: boom is not a function\n"
                            .. "    at <anonymous>:1:1\n"
                            .. "Tool calls made before the failure (they are not undone): "
                            .. "mcp__trilium__get_note (ok)"
                    ),
                },
                details = { calls = {} },
            })
            assert.is_true(parsed.failed)
            assert.are.equal(1, #parsed.sections)
            local section = parsed.sections[1]
            assert.are.equal("error", section.kind)
            assert.are.equal("error", section.label)
            assert.are.equal("TypeError: boom is not a function", section.lines[1])
            assert.is_false(any_line_contains(section.lines, "Script error:"))
            assert.is_true(any_line_contains(section.lines, "Tool calls made before the failure (they are not undone)"))
            assert.is_true(any_line_contains(section.lines, "at <anonymous>:1:1"))
        end)

        it("keeps trailing blank lines out of the sections", function()
            local parsed = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("payload\n\n\n") },
                details = { calls = {} },
            })
            assert.are.same({ "payload" }, parsed.sections[1].lines)
        end)

        it("reads calls from details.calls (JSON string args)", function()
            local result = fixture_nested_call_result()
            result.nestedCalls = nil
            local parsed = CodemodeToolUi.parse(result)
            assert.are.equal(1, #parsed.calls)
            local call = parsed.calls[1]
            assert.are.equal("mcp__trilium__search_notes", call.name)
            assert.are.equal('{"query":"note.type = text","limit":3,"fastSearch":true}', call.args)
            assert.are.equal("ok", call.status)
            assert.is_true(math.abs(call.duration_ms - 421.29) < 0.01)
            assert.is_true(parsed.calls_complete)
        end)

        it("prefers nestedCalls.calls and encodes the raw arguments table", function()
            local parsed = CodemodeToolUi.parse(fixture_nested_call_result())
            assert.are.equal(1, #parsed.calls)
            local call = parsed.calls[1]
            assert.are.equal("mcp__trilium__search_notes", call.name)
            assert.is_true(call.args:find('"note.type = text"', 1, true) ~= nil, "arguments table encoded as JSON")
            assert.are.equal(418, call.duration_ms, "nestedCalls record wins over details.calls")
        end)

        it("reports an incomplete nestedCalls record", function()
            local result = fixture_nested_call_result()
            result.nestedCalls.complete = false
            assert.is_false(CodemodeToolUi.parse(result).calls_complete)
        end)

        it("normalizes every status and defaults unknown ones to ok", function()
            local parsed = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("x") },
                details = {
                    calls = {
                        { name = "a", status = "running" },
                        { name = "b", status = "ok" },
                        { name = "c", status = "error", error = "boom" },
                        { name = "d", status = "cancelled" },
                        { name = "e", status = "something-new" },
                        { name = "f" },
                    },
                },
            })
            local got = {}
            for _, call in ipairs(parsed.calls) do
                got[#got + 1] = call.status
            end
            assert.are.same({ "running", "ok", "error", "cancelled", "ok", "ok" }, got)
        end)

        it("keeps fullOutputPath as the truncation hint", function()
            local parsed = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("x") },
                details = { calls = {}, fullOutputPath = "/tmp/pi-codemode-abc.txt" },
            })
            assert.are.equal("/tmp/pi-codemode-abc.txt", parsed.truncated_path)

            local no_path = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("x") },
                details = { calls = {}, fullOutputPath = "" },
            })
            assert.is_nil(no_path.truncated_path)
        end)

        it("accepts a string content payload", function()
            local parsed = CodemodeToolUi.parse({ content = "plain replay body" })
            assert.is_not_nil(parsed)
            assert.are.equal(1, #parsed.sections)
            assert.are.same({ "plain replay body" }, parsed.sections[1].lines)
            assert.are.equal(0, #parsed.calls)
        end)

        it("never throws on malformed input", function()
            local garbage = {
                { content = 42 },
                { content = { { type = "text", text = 42 } } },
                { content = { { type = "image", data = "AA", mimeType = "image/png" } } },
                { content = "x", details = "not a table" },
                { content = { text_block("==> text z/z <==") } },
                { content = { text_block("<console_output>") } },
                { content = { text_block("Script error:") } },
                { content = {}, details = { calls = { 42, "nope", { name = 7, args = 7 } } } },
                {
                    content = { text_block("x") },
                    details = { calls = { { name = "a", arguments = { n = 1 } } } },
                },
            }
            for _, result in ipairs(garbage) do
                local ok, err = pcall(CodemodeToolUi.parse, result)
                assert.is_true(ok, "parse must not throw: " .. tostring(err))
            end
            -- content = 42 has no usable body and no calls: not codemode-shaped.
            assert.is_nil(CodemodeToolUi.parse({ content = 42 }))
            -- An unterminated <console_output> still yields a (console) section.
            local open_console = CodemodeToolUi.parse({ content = { text_block("<console_output>\ntail") } })
            assert.are.equal("console", open_console.sections[1].kind)
            assert.are.same({ "tail" }, open_console.sections[1].lines)
        end)
    end)

    describe("format_calls", function()
        it("renders one row per call with glyph, args and duration", function()
            local parsed = CodemodeToolUi.parse(fixture_nested_call_result())
            local rows = CodemodeToolUi.format_calls(parsed)
            assert.are.equal(1, #rows)
            assert.is_true(rows[1].text:find("↳ ✓ mcp__trilium__search_notes ", 1, true) == 1)
            assert.is_true(rows[1].text:find("418ms", 1, true) ~= nil)
            assert.is_nil(rows[1].hl, "call rows use the default PiToolCall highlight")
        end)

        it("uses the shared status glyph vocabulary", function()
            local parsed = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("x") },
                details = {
                    calls = {
                        { name = "run", status = "running" },
                        { name = "good", status = "ok" },
                        { name = "bad", status = "error" },
                        { name = "gone", status = "cancelled" },
                    },
                },
            })
            local rows = CodemodeToolUi.format_calls(parsed)
            assert.is_true(rows[1].text:find("↳ ◐ run", 1, true) == 1)
            assert.is_true(rows[2].text:find("↳ ✓ good", 1, true) == 1)
            assert.is_true(rows[3].text:find("↳ ✗ bad", 1, true) == 1)
            assert.is_true(rows[4].text:find("↳ ⊘ gone", 1, true) == 1)
        end)

        it("appends an indented first-error-line row in PiToolError", function()
            local parsed = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("x") },
                details = {
                    calls = { { name = "bad", status = "error", error = "boom\n    at <anonymous>:2:3" } },
                },
            })
            local rows = CodemodeToolUi.format_calls(parsed)
            assert.are.equal(2, #rows)
            assert.are.equal("      boom", rows[2].text, "only the first error line, indented")
            assert.are.equal("PiToolError", rows[2].hl)
        end)

        it("cuts args at 40 chars", function()
            local parsed = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("x") },
                details = { calls = { { name = "tool", status = "ok", args = string.rep("a", 120) } } },
            })
            local row = CodemodeToolUi.format_calls(parsed)[1]
            local args = row.text:sub(#"↳ ✓ tool " + 1)
            -- 40, not the TUI's 80: `↳ ✓ <long mcp tool name>` plus an 80-char
            -- args preview overflows a normal 80-column chat and the width rule
            -- in Tools.should_collapse() then folds the block.
            assert.are.equal(40, #args, "args preview budget is 40 bytes")
            assert.is_true(args:find("…$") ~= nil, "elision marker appended")

            -- Short args are left untouched.
            local short = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("x") },
                details = { calls = { { name = "tool", status = "ok", args = '{"a":1}' } } },
            })
            assert.are.equal('↳ ✓ tool {"a":1}', CodemodeToolUi.format_calls(short)[1].text)
        end)

        it("does not split a multi-byte character while cutting to the budget", function()
            -- 30 CJK chars = 90 bytes; the cut must land on a character
            -- boundary, otherwise the buffer shows a broken sequence.
            local parsed = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("x") },
                details = { calls = { { name = "tool", status = "ok", args = string.rep("知", 30) } } },
            })
            local row = CodemodeToolUi.format_calls(parsed)[1]
            local args = row.text:sub(#"↳ ✓ tool " + 1)
            assert.is_true(#args <= 40, ("preview stays within the budget (%d bytes)"):format(#args))
            assert.is_true(args:find("…$") ~= nil)
            local body = args:sub(1, #args - #"…")
            assert.are.equal(0, #body % 3, "whole 3-byte characters only")
            assert.is_true(vim.fn.strchars(body) * 3 == #body)
        end)

        it("formats sub-second, second and cost values", function()
            local parsed = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("x") },
                details = {
                    calls = {
                        { name = "fast", status = "ok", durationMs = 421.29 },
                        { name = "slow", status = "ok", durationMs = 1200 },
                        { name = "priced", status = "ok", durationMs = 1500, cost = 0.0012 },
                        { name = "cheap", status = "ok", durationMs = 1500, cost = 0.12 },
                    },
                },
            })
            local rows = CodemodeToolUi.format_calls(parsed)
            assert.is_true(rows[1].text:find("  421ms", 1, true) ~= nil)
            assert.is_true(rows[2].text:find("  1.2s", 1, true) ~= nil)
            assert.is_true(rows[3].text:find("$0.0012", 1, true) ~= nil)
            assert.is_true(rows[4].text:find("$0.12", 1, true) ~= nil)
        end)

        it("elides past the row limit but announces the remainder", function()
            local calls = {}
            for i = 1, 60 do
                calls[i] = { name = ("tool%d"):format(i), status = "ok" }
            end
            local parsed = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("x") },
                details = { calls = calls },
            })
            local rows = CodemodeToolUi.format_calls(parsed)
            assert.are.equal(51, #rows, "50 call rows + 1 elision row")
            local last = rows[#rows]
            assert.are.equal("… 10 more calls", last.text)
            assert.are.equal("PiToolStatus", last.hl)

            local capped = CodemodeToolUi.format_calls(parsed, { limit = 3 })
            assert.are.equal(4, #capped)
            assert.are.equal("… 57 more calls", capped[4].text)
        end)

        it("returns an empty list for a result without calls", function()
            assert.are.same({}, CodemodeToolUi.format_calls(CodemodeToolUi.parse(fixture_no_call_result())))
            assert.are.same({}, CodemodeToolUi.format_calls({}))
        end)
    end)

    describe("format_sections", function()
        it("heads numbered text sections with ── text N/M ──", function()
            local parsed = CodemodeToolUi.parse(fixture_nested_call_result())
            local rows = CodemodeToolUi.format_sections(parsed)
            assert.are.same(
                { "── text 1/2 ──", "isError=false blocks=1", "── text 2/2 ──" },
                texts({ rows[1], rows[2], rows[3] })
            )
            assert.are.equal("PiToolStatus", rows[1].hl)
            assert.are.equal("PiToolOutput", rows[2].hl)
            assert.is_true(rows[4].text:find("totalResults", 1, true) ~= nil)
            assert.are.equal("PiToolOutput", rows[4].hl)
        end)

        it("heads console and error sections and colors their bodies", function()
            local parsed = CodemodeToolUi.parse({
                content = {
                    text_block("Script failed\nWall time 0.1 seconds\nOutput:\n"),
                    text_block("<console_output>\nlog\n</console_output>"),
                    text_block("Script error:\nnope"),
                },
                details = { calls = {} },
            })
            local rows = CodemodeToolUi.format_sections(parsed)
            assert.are.equal("── console ──", rows[1].text)
            assert.are.equal("PiToolStatus", rows[1].hl)
            assert.are.equal("PiToolOutput", rows[2].hl)
            assert.are.equal("── error ──", rows[3].text)
            assert.are.equal("PiToolError", rows[3].hl)
            assert.are.equal("nope", rows[4].text)
            assert.are.equal("PiToolError", rows[4].hl)
        end)

        it("adds the full-output path row when pi truncated the output", function()
            local parsed = CodemodeToolUi.parse({
                content = { text_block(SCRIPT_HEADER), text_block("x") },
                details = { calls = {}, fullOutputPath = "/tmp/pi-codemode-abc.txt" },
            })
            local rows = CodemodeToolUi.format_sections(parsed)
            assert.are.equal("Full output: /tmp/pi-codemode-abc.txt", rows[#rows].text)
            assert.are.equal("PiToolStatus", rows[#rows].hl)
        end)

        it("emits no header row for an unlabeled text section", function()
            -- legacy replay records keep bare strings in content[]
            local parsed = CodemodeToolUi.parse({ content = { "plain body" } })
            local rows = CodemodeToolUi.format_sections(parsed)
            assert.are.same({ "plain body" }, texts(rows))
            assert.are.equal("PiToolOutput", rows[1].hl)
        end)
    end)

    describe("summary", function()
        it("counts calls and outputs", function()
            assert.are.equal("1 call · 2 outputs", CodemodeToolUi.summary(fixture_nested_call_result()))
        end)

        it("counts many calls", function()
            local calls = {}
            for i = 1, 3 do
                calls[i] = { name = "t" .. i, status = "ok" }
            end
            local parsed = {
                content = { text_block(SCRIPT_HEADER), text_block("==> text 1/2 <==\na\n==> text 2/2 <==\nb") },
                details = { calls = calls },
            }
            assert.are.equal("3 calls · 2 outputs", CodemodeToolUi.summary(parsed))
        end)

        it("omits the output part for a single output and no calls", function()
            local single = { content = { text_block(SCRIPT_HEADER), text_block("only line") } }
            assert.is_nil(CodemodeToolUi.summary(single))
        end)

        it("shows only the output part when there are no calls", function()
            local two = {
                content = { text_block(SCRIPT_HEADER), text_block("==> text 1/2 <==\na\n==> text 2/2 <==\nb") },
            }
            assert.are.equal("2 outputs", CodemodeToolUi.summary(two))
        end)

        it("returns nil when nothing is worth saying", function()
            assert.is_nil(CodemodeToolUi.summary(nil))
            assert.is_nil(CodemodeToolUi.summary({}))
            assert.is_nil(CodemodeToolUi.summary({ content = 42 }))
        end)
    end)
end)
