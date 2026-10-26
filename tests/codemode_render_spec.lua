-- Renderer specs for the codemode tool block (lua/pi/ui/chat/tools.lua
-- `codemode` renderer + lua/pi/codemode/tool_ui.lua rows), driven through the
-- real History event path so the collapse engine is exercised too.
--
-- The result fixtures mirror records extracted from a real pi session
-- (`/tmp/codemode-sample/`): live `tool_execution_end` results and replayed
-- toolResult messages have the same shape (content[] + details).

local Config = require("pi.config")
local History = require("pi.ui.chat.history")
local Tools = require("pi.ui.chat.tools")

local TAB = 930

local function pump(ms)
    vim.wait(ms or 60)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Rows (0-indexed) of every buffer line containing `sub` (plain match).
---@return integer[]
local function rows_with(buf, sub)
    local out = {}
    for i, l in ipairs(lines_of(buf)) do
        if l:find(sub, 1, true) then
            out[#out + 1] = i - 1
        end
    end
    return out
end

--- Rows (0-indexed) of every buffer line matching the Lua pattern `pat`.
---@return integer[]
local function rows_match(buf, pat)
    local out = {}
    for i, l in ipairs(lines_of(buf)) do
        if l:match(pat) then
            out[#out + 1] = i - 1
        end
    end
    return out
end

--- The highlight of the first extmark that starts at column 0 of `row`.
---@return string?
local function row_hl(h, row)
    local ems = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), { row, 0 }, { row, -1 }, { details = true })
    for _, em in ipairs(ems) do
        local d = em[4] or {}
        if d.hl_group and em[3] == 0 then
            return d.hl_group
        end
    end
    return nil
end

--- All `hl_group`s painted somewhere on `row`.
---@return table<string, boolean>
local function row_hl_set(h, row)
    local set = {}
    local ems = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), { row, 0 }, { row, -1 }, { details = true })
    for _, em in ipairs(ems) do
        local hl = (em[4] or {}).hl_group
        if hl then
            set[hl] = true
        end
    end
    return set
end

--- Every syntax extmark (tool-input treesitter capture) in the buffer. The
--- default extmark priority is 4096 — anything at or below that is invisible
--- under the flat PiToolCall span render_input() paints.
---@return integer[]
local function syntax_rows(h)
    local out = {}
    local ems = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })
    for _, em in ipairs(ems) do
        local d = em[4] or {}
        if d.priority and d.priority > 4096 then
            out[#out + 1] = em[2]
        end
    end
    return out
end

---@param text string
---@return table
local function text_block(text)
    return { type = "text", text = text }
end

--- Real fixture 1 shape: `details.calls` carries a JSON-string `args`,
--- `nestedCalls.calls` the raw `arguments` table.
---@return table
local function nested_call_result()
    return {
        role = "toolResult",
        toolCallId = "call_00_d7eketxyhv5vgdwn3vsz40om",
        toolName = "codemode",
        content = {
            text_block("Script completed\nWall time 0.5 seconds\nOutput:\n"),
            text_block("==> text 1/2 <==\nisError=false blocks=1\n==> text 2/2 <==\n" .. '{"totalResults":1288}'),
        },
        details = {
            calls = {
                {
                    name = "mcp__trilium__search_notes",
                    args = '{"query":"note.type = text","limit":3,"fastSearch":true}',
                    status = "ok",
                    durationMs = 421.29069800000434,
                },
            },
        },
        isError = false,
        durationMs = 517,
        nestedCalls = {
            calls = {
                {
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

--- Real fixture 0 shape: no nested calls, one numbered output pair.
---@return table
local function no_call_result()
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

--- Script input matching fixture 1 (`args.code`).
local SCRIPT = 'const r = await tools.mcp__trilium__search_notes({ query: "note.type = text", limit: 3, fastSearch: true });\n'
    .. 'const txt = (r.content || []).filter(c => c.type === "text").map(c => c.text).join("\\n");\n'
    .. "text(`isError=${!!r.isError} blocks=${(r.content||[]).length}`);\n"
    .. "text(txt.slice(0, 900));"

--- Create a History with tool-block collapsing disabled, so buffer lines are
--- the raw rendered rows.
---@return pi.ChatHistory
local function new_history()
    local h = History.new(TAB)
    h._blocks_expanded = true
    return h
end

--- Fire a codemode call through on_tool_start / on_tool_end.
---@param h pi.ChatHistory
---@param result table?
---@param is_error boolean?
---@param id string?
local function codemode_tool(h, result, is_error, id)
    h:on_tool_start("codemode", id or "cm1", { code = SCRIPT })
    pump()
    h:on_tool_end("codemode", id or "cm1", result, is_error == true)
    pump()
end

describe("codemode renderer", function()
    before_each(function()
        Config.options.render = { engine = "builtin" }
    end)

    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    describe("renderer lookup", function()
        it("registers dedicated collapse thresholds", function()
            local renderer = Tools.get_renderer("codemode")
            local default = Tools.get_renderer("__no_such_tool__")
            assert.is_not(renderer, default, "codemode must not fall through to default_renderer")
            assert.are.equal(1, renderer.input_visible)
            assert.are.equal(3, renderer.output_visible)
            assert.is_nil(renderer.inline)
        end)

        it("provides a dedicated icon", function()
            assert.are.equal(vim.fn.nr2char(0xF031E, 1), Tools.get_tool_icon("codemode"))
            assert.is_not(Config.options.labels.tool, Tools.get_tool_icon("codemode"))
        end)
    end)

    describe("block body", function()
        it("renders the script, the call rows and the numbered sections", function()
            local h = new_history()
            codemode_tool(h, nested_call_result())
            local buf = h:buf()

            -- input: the script lines, painted as tool input
            local script_rows = rows_with(buf, "const r = await tools.mcp__trilium__search_notes")
            assert.are.equal(1, #script_rows)
            assert.are.equal("PiToolCall", row_hl(h, script_rows[1]))
            assert.are.equal(1, #rows_with(buf, "text(txt.slice(0, 900));"))

            -- nested call row + numbered section headers
            local call_rows = rows_with(buf, "↳ ✓ mcp__trilium__search_notes")
            assert.are.equal(1, #call_rows)
            assert.are.equal(1, #rows_with(buf, "── text 1/2 ──"))
            assert.are.equal(1, #rows_with(buf, "── text 2/2 ──"))
            assert.are.equal(1, #rows_with(buf, "isError=false blocks=1"))

            -- ... and none of the wire artifacts
            assert.are.equal(0, #rows_with(buf, "==>"))
            assert.are.equal(0, #rows_with(buf, "<console_output>"))
            assert.are.equal(0, #rows_with(buf, "Script completed"))
            assert.are.equal(0, #rows_with(buf, "Wall time"))
        end)

        it("renders a replay result without nested calls", function()
            local h = new_history()
            codemode_tool(h, no_call_result())
            local buf = h:buf()
            assert.are.equal(1, #rows_with(buf, '{"name":"mcp__trilium"}'))
            assert.are.equal(1, #rows_with(buf, "── text 2/2 ──"))
            assert.are.equal(0, #rows_with(buf, "↳ "))
            -- summary omits the badge for a single output
            assert.are.equal(0, #rows_with(buf, "outputs"))
        end)

        it("renders console output without its tags", function()
            local h = new_history()
            codemode_tool(h, {
                content = {
                    text_block("Script completed\nWall time 0.2 seconds\nOutput:\n"),
                    text_block("the answer"),
                    text_block("<console_output>\nconsole.log line\n</console_output>"),
                },
                details = { calls = {} },
            })
            local buf = h:buf()
            assert.are.equal(1, #rows_with(buf, "── console ──"))
            assert.are.equal(1, #rows_with(buf, "console.log line"))
            assert.are.equal(0, #rows_with(buf, "<console_output>"))
            assert.are.equal(0, #rows_with(buf, "</console_output>"))
        end)

        it("colors the error section rows with PiToolError", function()
            local h = new_history()
            codemode_tool(h, {
                content = {
                    text_block("Script failed\nWall time 0.1 seconds\nOutput:\n"),
                    text_block(
                        "Script error:\nTypeError: boom is not a function\n"
                            .. "Tool calls made before the failure (they are not undone): "
                            .. "mcp__trilium__get_note (ok)"
                    ),
                },
                details = { calls = {} },
                isError = true,
            }, true)
            local buf = h:buf()
            local header = rows_with(buf, "── error ──")
            assert.are.equal(1, #header)
            assert.is_true(row_hl_set(h, header[1]).PiToolError == true)

            local message = rows_with(buf, "TypeError: boom is not a function")
            assert.are.equal(1, #message)
            assert.are.equal("PiToolError", row_hl(h, message[1]))

            assert.are.equal(1, #rows_with(buf, "Tool calls made before the failure (they are not undone)"))
            assert.are.equal(0, #rows_with(buf, "Script error:"))
        end)

        it("shows the header badge from inline_status", function()
            local h = new_history()
            codemode_tool(h, nested_call_result())
            local header_rows = rows_with(h:buf(), "codemode")
            assert.is_true(#header_rows >= 1)
            local found = false
            local ems = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })
            for _, em in ipairs(ems) do
                for _, chunk in ipairs((em[4] or {}).virt_text or {}) do
                    if type(chunk[1]) == "string" and chunk[1]:find("1 call · 2 outputs", 1, true) then
                        found = true
                    end
                end
            end
            assert.is_true(found, "expected the `1 call · 2 outputs` badge as header virtual text")
        end)

        it("falls back to the default renderer for a foreign result", function()
            local h = new_history()
            codemode_tool(h, { content = 42 })
            -- no throw, and no codemode body rows
            assert.are.equal(0, #rows_with(h:buf(), "↳ "))
            assert.are.equal(0, #rows_with(h:buf(), "── "))
        end)
    end)

    describe("collapse", function()
        it("collapses to the first script line plus the last 3 output rows", function()
            local h = History.new(TAB + 1) -- _blocks_expanded defaults to false
            assert.are.equal(false, h._blocks_expanded)
            -- 4 script lines + 1 call row + 2 section headers + 4 body rows
            codemode_tool(h, {
                content = {
                    text_block("Script completed\nWall time 0.5 seconds\nOutput:\n"),
                    text_block("==> text 1/2 <==\nfirst-section-line\n==> text 2/2 <==\nL1\nL2\nL3"),
                },
                details = { calls = { { name = "mcp__x", args = "{}", status = "ok" } } },
            })
            local buf = h:buf()
            -- input collapsed to its first line + "+N lines" marker
            assert.are.equal(1, #rows_with(buf, "const r = await tools.mcp__trilium__search_notes"))
            assert.are.equal(0, #rows_with(buf, "text(txt.slice(0, 900));"))
            assert.are.equal(1, #rows_match(buf, "^ %+%d+ lines$"))
            -- output collapsed to its last 3 rows + "…N lines" marker
            assert.are.equal(1, #rows_with(buf, "L3"))
            assert.are.equal(0, #rows_with(buf, "first-section-line"))
            assert.is_true(#rows_match(buf, "^…%d+ lines$") >= 1, "expected the output elision marker")
        end)
    end)

    describe("render-markdown engine", function()
        before_each(function()
            Config.options.render = { engine = "render-markdown" }
            require("pi.ui.render")._reset()
        end)

        it("fences the script and does not duplicate the ts highlights", function()
            local h = new_history()
            codemode_tool(h, nested_call_result())
            local buf = h:buf()
            assert.are.equal(1, #rows_with(buf, "```javascript"))
            assert.is_true(#rows_match(buf, "^`+$") >= 1, "closing fence")
            assert.are.same({}, syntax_rows(h), "render-markdown already colors fenced code")
            -- the body rows are still rendered
            assert.are.equal(1, #rows_with(buf, "── text 1/2 ──"))
        end)
    end)
end)

-- ---------------------------------------------------------------------------
-- Fixtures copied verbatim from real session records (`/tmp/codemode-sample/`):
-- each file is `{ args, result }`. Fixture 0 has no nested calls and its second
-- output embeds a ```ts … ``` snippet; fixture 1 carries one MCP call (418ms in
-- `nestedCalls`, 421.29ms in `details`) and two numbered outputs.
-- ---------------------------------------------------------------------------

--- @type table codemode fixture 0: `args` (live tool_execution_start payload).
local FIXTURE_0_ARGS = {
    code = [[const ns = await describeNamespace("mcp__trilium");
text(typeof ns === "string" ? ns : JSON.stringify(ns).slice(0, 1500));
const t = await describeTool("mcp__trilium__search_notes");
text(typeof t === "string" ? t : JSON.stringify(t).slice(0, 1200));]],
}

--- @type table codemode fixture 0: `result` (tool_execution_end / replayed toolResult).
local FIXTURE_0_RESULT = {
    content = {
        text_block([[Script completed
Wall time 0.3 seconds
Output:
]]),
        text_block([[==> text 1/2 <==
{"name":"mcp__trilium","description":"Trilium Notes 个人知识库：检索、阅读与写入笔记","tools":["mcp__trilium__search_notes","mcp__trilium__get_note","mcp__trilium__get_note_content","mcp__trilium__set_note_content","mcp__trilium__append_to_note","mcp__trilium__edit_note_content","mcp__trilium__create_note","mcp__trilium__rename_note","mcp__trilium__delete_note","mcp__trilium__get_attributes","mcp__trilium__get_attribute","mcp__trilium__set_attribute","mcp__trilium__delete_attribute","mcp__trilium__get_attachment","mcp__trilium__get_attachment_content","mcp__trilium__get_child_notes","mcp__trilium__get_subtree","mcp__trilium__move_note","mcp__trilium__clone_note","mcp__trilium__search_icons","mcp__trilium__load_skill","mcp__trilium__search_help","mcp__trilium__get_help_toc"]}
==> text 2/2 <==
Search for notes in the user's knowledge base using Trilium search syntax. For complex queries (boolean logic, relations, regex, ordering), load the 'search_syntax' skill first via load_skill. Common patterns: - Full-text: 'rings tolkien' (notes containing both words) - By label: '#book', '#status = done', '#year >= 2000' - By type: 'note.type = code' - By relation: '~author', '~author.title *= Tolkien' - Combined: 'tolkien #book' (full-text + label filter) - Negation: '#!archived' (notes WITHOUT label)

codemode tool declaration:
```ts
declare const tools: { mcp__trilium__search_notes(args: {
  // Limit search to a subtree rooted at this note ID.
  ancestorNoteId?: string;
  // If true, skip content search (only titles and attributes). Faster for large databases.
  fastSearch?: boolean;
  // If true, include archived notes in results.
  includeArchivedNotes?: boolean;
  // Maximum number of results to return. Defaults to 10.
  limit?: number;
  // Search query in Trilium search syntax
  query: string;
}): Promise<{ content: Array<{ data?: string; mimeType?: string; text?: string; type: "text" | "image" | "audio" | "resource_link" | "resource"; [key: string]: unknown; }>; isError?: boolean; structuredContent?: unknown; [key: string]: unknown; }>; };
```]]),
    },
    details = { calls = {} },
    isError = false,
    durationMs = 297,
}

--- @type table codemode fixture 1: `args` (live tool_execution_start payload).
local FIXTURE_1_ARGS = {
    code = [[const r = await tools.mcp__trilium__search_notes({ query: "note.type = text", limit: 3, fastSearch: true });
const txt = (r.content || []).filter(c => c.type === "text").map(c => c.text).join("\n");
text(`isError=${!!r.isError} blocks=${(r.content||[]).length}`);
text(txt.slice(0, 900));]],
}

--- @type table codemode fixture 1: `result` (tool_execution_end / replayed toolResult).
local FIXTURE_1_RESULT = {
    content = {
        text_block([[Script completed
Wall time 0.5 seconds
Output:
]]),
        text_block(
            [[==> text 1/2 <==
isError=false blocks=1
==> text 2/2 <==
{"totalResults":1288,"results":[{"noteId":"kVi9C0DRgXPj","title":"","type":"text","parentTitle":"21 - Friday","contentPreview":null},{"noteId":"root","title":"root","type":"text","parentTitle":null,"contentPreview":null},{"noteId":"lRZgmZpth2wZ","title":"Trilium Demo","type":"text","parentTitle":"root","contentPreview":"<figure class=\"image image-style-align-right\"><img src=\"api/attachments/ZUllbBfcpaPD/image/Trilium Demo_trilium-icon.png\"></figure>\n\n**Welcome to Trilium Notes!**\n\nThis is initial \"demo\" document provided by default Trilium to showcase some of its features and also give you some ideas how you might structure your notes. You can play with it, modify note content and tree structure as you wish.\n\nIf you need any help, visit Trilium website: [https://github.com/zadam/trilium](https://github.com/zada…"}]}]]
        ),
    },
    details = {
        calls = {
            {
                name = "mcp__trilium__search_notes",
                args = '{"query":"note.type = text","limit":3,"fastSearch":true}',
                status = "ok",
                durationMs = 421.29069800000434,
            },
        },
    },
    isError = false,
    durationMs = 517,
    nestedCalls = {
        calls = {
            {
                name = "mcp__trilium__search_notes",
                status = "ok",
                arguments = { query = "note.type = text", limit = 3, fastSearch = true },
                durationMs = 418,
            },
        },
        complete = true,
    },
}

-- ---------------------------------------------------------------------------
-- Real fixtures: replay parity, fence balance, indentation, round trip, badge
-- ---------------------------------------------------------------------------

--- Line count of fence rows (`^%s*``` …`) in `lines`.
---@param lines string[]
---@return integer
local function fence_row_count(lines)
    local n = 0
    for _, l in ipairs(lines) do
        if l:match("^%s*```") then
            n = n + 1
        end
    end
    return n
end

--- Backtick run of the fence still open at the end of `lines` (nil when every
--- fence is closed). Mirrors tools.lua's open_fence_length(): a shorter fence
--- inside a longer one is content, so raw row parity is not the invariant for
--- render-markdown's ```` wrapper around a ``` tail.
---@param lines string[]
---@return integer?
local function open_fence(lines)
    local open = nil ---@type integer?
    for _, l in ipairs(lines) do
        local ticks = l:match("^%s*(`+)")
        if ticks then
            if not open then
                open = #ticks
            elseif #ticks >= open then
                open = nil
            end
        end
    end
    return open
end

--- The rows strictly inside a tool block (header and footer excluded).
---@param h pi.ChatHistory
---@param block pi.ToolBlock
---@return string[]
local function body_rows(h, block)
    local header = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), block.icon_extmark, {})[1]
    local footer = vim.api.nvim_buf_get_extmark_by_id(h:buf(), h:ns(), block.end_extmark, {})[1]
    if not header or not footer then
        return {}
    end
    return vim.api.nvim_buf_get_lines(h:buf(), header + 1, footer, false)
end

--- Render one real fixture through the history event path.
---@param n integer 0|1
---@param expanded boolean keep the block expanded (no auto-collapse)?
---@return pi.ChatHistory h
---@return pi.ToolBlock block
local function render_fixture(n, expanded)
    local h = History.new(TAB + 100 + n)
    h._blocks_expanded = expanded
    local args = n == 0 and FIXTURE_0_ARGS or FIXTURE_1_ARGS
    local result = n == 0 and FIXTURE_0_RESULT or FIXTURE_1_RESULT
    local id = "cm" .. n
    h:on_tool_start("codemode", id, args)
    pump()
    h:on_tool_end("codemode", id, result, false)
    pump(150)
    return h, h._tool_blocks[id]
end

describe("codemode real fixtures", function()
    before_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    describe("replay parity", function()
        for _, n in ipairs({ 0, 1 }) do
            it(("renders fixture %d without wire artifacts"):format(n), function()
                local h = render_fixture(n, true)
                local buf = h:buf()
                local args = n == 0 and FIXTURE_0_ARGS or FIXTURE_1_ARGS

                -- the script is the block input, line for line
                for _, line in ipairs(vim.split(args.code, "\n", { plain = true })) do
                    assert.are.equal(1, #rows_with(buf, line), "script line missing: " .. line)
                end

                -- numbered sections, never the raw markers
                assert.are.equal(1, #rows_with(buf, "── text 1/2 ──"))
                assert.are.equal(1, #rows_with(buf, "── text 2/2 ──"))

                -- no raw wire artifacts
                for _, artifact in ipairs({
                    "==>",
                    "<console_output>",
                    "Script completed",
                    "Wall time",
                    "Script error:",
                }) do
                    assert.are.equal(0, #rows_with(buf, artifact), "wire artifact leaked: " .. artifact)
                end
            end)
        end

        it("renders fixture 1's nested call row with its duration", function()
            local h = render_fixture(1, true)
            local rows = rows_match(h:buf(), "^↳ ✓ mcp__trilium__search_notes .*  418ms$")
            assert.are.equal(1, #rows, "expected `↳ ✓ mcp__trilium__search_notes …  418ms`")
            assert.are.equal("PiToolCall", row_hl(h, rows[1]))
            -- args preview cut at 40 bytes, not the TUI's 80 (F4)
            local line = lines_of(h:buf())[rows[1] + 1]
            local args = line:match("^↳ ✓ mcp__trilium__search_notes (.*)  418ms$")
            assert.is_not_nil(args)
            assert.is_true(#args <= 40, ("args preview is %d bytes"):format(#args))
        end)
    end)

    describe("fence balance", function()
        it("collapses fixture 0 with an even fence count", function()
            -- fixture 0's second text section embeds a ```ts … ``` snippet; with
            -- output_visible = 3 the collapsed view keeps only its closing fence,
            -- so build_collapsed_view() has to close it again.
            local h, block = render_fixture(0, false)
            assert.is_false(block.expanded, "fixture 0 exceeds input_visible = 1")

            local body = body_rows(h, block)
            assert.is_nil(open_fence(body), "an unmatched ``` would swallow the footer")
            assert.are.equal(0, fence_row_count(body) % 2, "collapsed fence rows must pair up")

            -- the visible tail is real content, and the fences are the last rows
            assert.is_true(#rows_with(h:buf(), "  query: string;") == 1, "tail row stays visible")
            assert.are.equal("```", body[#body])
        end)

        it("keeps the expanded fixture-0 buffer fence-balanced", function()
            local h, block = render_fixture(0, true)
            assert.is_true(block.expanded)
            local lines = lines_of(h:buf())
            assert.is_nil(open_fence(lines))
            assert.are.equal(0, fence_row_count(lines) % 2)
            -- the snippet's own pair survived, tagged with its language
            assert.are.equal(1, #rows_with(h:buf(), "```ts"))
        end)

        it("auto-closes an output that ends inside a fence, as virtual text", function()
            local h = new_history()
            h:on_tool_start("codemode", "cmopen", { code = "text(x)" })
            pump()
            h:on_tool_end("codemode", "cmopen", {
                content = {
                    text_block("Script completed\nWall time 0.1 seconds\nOutput:\n"),
                    text_block("==> text 1/2 <==\na\n==> text 2/2 <==\ndeclaration:\n```ts\ndeclare const x: 1;"),
                },
                details = { calls = {} },
            }, false)
            pump(120)

            local body = body_rows(h, h._tool_blocks.cmopen)
            assert.is_nil(open_fence(body), "the renderer must close the open fence")
            assert.are.equal(0, fence_row_count(body) % 2)
            -- the closing row is exactly a fence row: the hint must be virtual
            -- text, never part of the fence line (that would break ``` matching)
            assert.are.equal("```", body[#body])

            -- the opening row carries the ```ts language tag, so match the run,
            -- not the bare fence
            local fence_rows = rows_match(h:buf(), "^```")
            assert.is_true(#fence_rows >= 2, "opening and closing fence rows")
            assert.are.equal("```", lines_of(h:buf())[fence_rows[#fence_rows] + 1])
            local hint_rows = rows_match(h:buf(), "auto-closed")
            assert.are.same({}, hint_rows, "the hint is not buffer text")

            local found = false
            for _, em in
                ipairs(
                    vim.api.nvim_buf_get_extmarks(
                        h:buf(),
                        h:ns(),
                        { fence_rows[#fence_rows], 0 },
                        { fence_rows[#fence_rows], -1 },
                        { details = true }
                    )
                )
            do
                for _, chunk in ipairs((em[4] or {}).virt_text or {}) do
                    if type(chunk[1]) == "string" and chunk[1]:find("auto-closed", 1, true) then
                        found = true
                    end
                end
            end
            assert.is_true(found, "expected the ` ← auto-closed` hint on the closing fence row")
        end)
    end)

    describe("indentation", function()
        it("keeps the indentation of a codemode section row", function()
            local h = new_history()
            h:on_tool_start("codemode", "cmind", { code = "console.log(x)" })
            pump()
            h:on_tool_end("codemode", "cmind", {
                content = {
                    text_block("Script completed\nWall time 0.1 seconds\nOutput:\n"),
                    text_block('payload:\n{\n  "a": 1,\n  "b": [\n    2, 3\n  ]\n}'),
                },
                details = { calls = {} },
            }, false)
            pump(120)

            local lines = lines_of(h:buf())
            local function present(text)
                for _, l in ipairs(lines) do
                    if l == text then
                        return true
                    end
                end
                return false
            end
            -- render_body_line()'s flatten_line() would collapse these to
            -- `"a": 1,` / `"b": [` / `2, 3` — render_code_row() must not.
            assert.is_true(present('  "a": 1,'), 'expected `  "a": 1,` with its 2-space indent')
            assert.is_true(present('  "b": ['), 'expected `  "b": [` with its 2-space indent')
            assert.is_true(present("    2, 3"), "expected `    2, 3` with its 4-space indent")
            assert.is_true(present("  ]"), "expected `  ]` with its 2-space indent")
        end)
    end)

    describe("collapse round trip", function()
        it("survives expand → collapse through the <Tab> path", function()
            local h, block = render_fixture(1, false)
            local buf = h:buf()
            assert.is_false(block.expanded, "fixture 1 exceeds input_visible = 1")
            -- the collapse clears the namespace over the inner range, which
            -- deletes the output anchor: history.lua drops the stale id.
            assert.is_nil(block.output_extmark, "the collapsed block carries no output anchor")

            local collapsed = vim.deepcopy(block.collapsed_inner_lines)
            local expanded = vim.deepcopy(block.expanded_inner_lines)
            assert.is_true(#collapsed > 0, "collapse captured its view")
            assert.is_true(#expanded > #collapsed, "the expanded view holds more rows")

            vim.api.nvim_win_set_buf(0, buf)
            h:set_win(0)
            local function cursor_on_header()
                local row = vim.api.nvim_buf_get_extmark_by_id(buf, h:ns(), block.icon_extmark, {})[1]
                assert.is_not_nil(row, "header anchor must stay resolvable")
                vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
            end

            cursor_on_header()
            assert.is_true(h:toggle_tool_block(), "expand via the <Tab> entry point")
            assert.is_true(block.expanded)
            assert.are.same(expanded, body_rows(h, block), "expand restores the captured view verbatim")
            assert.are.equal(1, #rows_with(buf, "↳ ✓ mcp__trilium__search_notes"))
            assert.are.equal(1, #rows_with(buf, "── text 1/2 ──"))

            -- Extraction after the round trip. history.lua's collapse drops
            -- block.output_extmark (`= nil`) without recording where it was, so
            -- a re-expanded block reports has_output = false and classifies the
            -- whole body as input. The guard: nothing is lost, and the input
            -- half still leads with the script.
            local input, output, has_output = Tools.extract_tool_sections(h, block)
            local script = vim.split(FIXTURE_1_ARGS.code, "\n", { plain = true })
            for i, line in ipairs(script) do
                assert.are.equal(line, input[i], ("script line %d is still the input section"):format(i))
            end
            local joined = table.concat(input, "\n") .. "\n" .. table.concat(output, "\n")
            assert.is_true(joined:find("↳ ✓ mcp__trilium__search_notes", 1, true) ~= nil, "call rows survive")
            assert.is_true(joined:find("── text 2/2 ──", 1, true) ~= nil, "section rows survive")
            if has_output then
                assert.is_true(
                    table.concat(output, "\n"):find("↳ ✓ mcp__trilium__search_notes", 1, true) ~= nil,
                    "a live output anchor means the call rows are the output section"
                )
            end

            cursor_on_header()
            assert.is_true(h:toggle_tool_block(), "collapse via the <Tab> entry point")
            assert.is_false(block.expanded)
            assert.are.same(collapsed, body_rows(h, block), "the collapsed view is stable across a round trip")
            assert.is_true(#rows_match(buf, "^ %+%d+ lines$") >= 1, "the collapsed summary is back")

            cursor_on_header()
            assert.is_true(h:toggle_tool_block(), "expand once more")
            assert.is_true(block.expanded)
            assert.are.same(expanded, body_rows(h, block))
            assert.are.equal(1, #rows_with(buf, "↳ ✓ mcp__trilium__search_notes"))
        end)
    end)

    describe("badge", function()
        it("reports the call and output counts through inline_status", function()
            local renderer = Tools.get_renderer("codemode")
            assert.are.equal("1 call · 2 outputs", renderer.inline_status(FIXTURE_1_RESULT, false))
            assert.are.equal("2 outputs", renderer.inline_status(FIXTURE_0_RESULT, false))
        end)
    end)
end)
