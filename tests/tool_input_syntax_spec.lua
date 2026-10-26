-- Builtin-engine treesitter highlighting for tool *input* code lines.
--
-- render_input() only used its `lang` argument for the render-markdown fence,
-- so under the builtin engine every code input (codemode's JavaScript, bash's
-- shell) rendered flat. apply_code_syntax() now paints the language's
-- treesitter captures as priority-4100 extmarks — but only when the parser and
-- the highlight query are installed, so these specs skip gracefully on a
-- Neovim without them.
--
-- The priority matters: the flat PiToolCall span that render_input() paints
-- over the whole line carries *no* priority, so it uses Neovim's default of
-- 4096. A capture with a lower priority (250 originally) is simply invisible.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")

local TAB = 950

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

--- Whether a language's parser *and* highlight query are usable here.
---@param lang string
---@return boolean
local function lang_available(lang)
    if type(vim.treesitter.require_language) == "function" and not vim.treesitter.require_language(lang, nil, true) then
        return false
    end
    if not pcall(vim.treesitter.language.add, lang) then
        return false
    end
    local ok_query, query = pcall(vim.treesitter.query.get, lang, "highlights")
    if not ok_query or not query then
        return false
    end
    local ok_parser, parser = pcall(vim.treesitter.get_string_parser, "x", lang)
    return ok_parser and parser ~= nil
end

--- Neovim's default extmark priority (the flat PiToolCall span render_input()
--- paints without one). Anything at or below this is invisible under it.
local DEFAULT_PRIORITY = 4096

--- Every syntax extmark (tool-input treesitter capture) in the history buffer.
---@param h pi.ChatHistory
---@return { row: integer, start_col: integer, hl: string, priority: integer }[]
local function syntax_marks(h)
    local out = {}
    local ems = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })
    for _, em in ipairs(ems) do
        local d = em[4] or {}
        if d.priority and d.priority > DEFAULT_PRIORITY then
            out[#out + 1] = { row = em[2], start_col = em[3], hl = d.hl_group or "", priority = d.priority }
        end
    end
    return out
end

--- Extmarks on `row` painted with the default priority (the flat PiToolCall
--- container span).
---@param h pi.ChatHistory
---@param row integer
---@return integer
local function default_priority_marks_on(h, row)
    local n = 0
    local ems = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), { row, 0 }, { row, -1 }, { details = true })
    for _, em in ipairs(ems) do
        local p = (em[4] or {}).priority
        if not p or p <= DEFAULT_PRIORITY then
            n = n + 1
        end
    end
    return n
end

--- The code-input fixture per language, tried in order.
---@type { lang: string, tool: string, args: table, first_line: string }[]
local CODE_CASES = {
    {
        lang = "javascript",
        tool = "codemode",
        args = { code = 'const r = await tools.mcp__x({ q: "y" });\ntext(r);' },
        first_line = "const r = await tools.mcp__x",
    },
    {
        lang = "bash",
        tool = "bash",
        args = { command = "for i in 1 2; do echo $i; done" },
        first_line = "for i in 1 2",
    },
}

describe("tool input syntax highlighting", function()
    before_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    it("paints treesitter captures on builtin-engine code input", function()
        local case ---@type table?
        for _, candidate in ipairs(CODE_CASES) do
            if lang_available(candidate.lang) then
                case = candidate
                break
            end
        end
        if not case then
            -- No parser/query for either language in this environment: the
            -- feature is a no-op here (ts_highlights returns an empty map).
            assert.is_true(true)
            return
        end

        local h = History.new(TAB)
        h._blocks_expanded = true
        h:on_tool_start(case.tool, "s1", case.args)
        pump()

        local marks = syntax_marks(h)
        assert.is_true(#marks > 0, "expected treesitter extmarks for " .. case.lang .. " input")

        local code_rows = rows_with(h:buf(), case.first_line)
        assert.are.equal(1, #code_rows)
        local on_first_line = {}
        for _, mark in ipairs(marks) do
            if mark.row == code_rows[1] then
                on_first_line[#on_first_line + 1] = mark
            end
        end
        assert.is_true(#on_first_line > 0, "captures must land on the code line itself")

        -- F1 regression: the capture must OUTRANK the flat PiToolCall span,
        -- otherwise the code stays visually uncoloured.
        local beats_default = false
        for _, mark in ipairs(on_first_line) do
            if mark.priority > DEFAULT_PRIORITY then
                beats_default = true
            end
        end
        assert.is_true(beats_default, "a capture on the code line must have priority > " .. DEFAULT_PRIORITY)
        assert.is_true(
            default_priority_marks_on(h, code_rows[1]) > 0,
            "the flat PiToolCall span is still there — that is what the capture has to outrank"
        )

        local ts_capture = false
        for _, mark in ipairs(on_first_line) do
            if mark.hl:sub(1, 1) == "@" then
                ts_capture = true
            end
        end
        assert.is_true(ts_capture, "highlight groups are treesitter capture names")
    end)

    it("adds no syntax extmarks under the render-markdown engine", function()
        Config.options.render = { engine = "render-markdown" }
        require("pi.ui.render")._reset()

        local h = History.new(TAB + 1)
        h._blocks_expanded = true
        h:on_tool_start("codemode", "s2", { code = "const a = 1;" })
        pump()

        assert.are.same({}, syntax_marks(h), "the fence already colors the code block")
        assert.are.equal(1, #rows_with(h:buf(), "```javascript"))
    end)
end)
