-- The `ask` chat renderer in lua/pi/ui/chat/tools.lua. An ask block is the
-- answer record: the extension's reply text only counts the answers, so the
-- block renders the questions with the labels the user picked from
-- `result.details`. These specs pin that block shape (cancelled / answered /
-- unanswered), the never-collapse flag, and the fallback to the reply text when
-- a result carries no details at all.

local Config = require("pi.config")
local Tools = require("pi.ui.chat.tools")
local History = require("pi.ui.chat.history")

describe("ask renderer", function()
    after_each(function()
        Config.setup({})
    end)

    it("is registered, block-shaped and always expanded", function()
        local renderer = Tools.get_renderer("ask")
        assert.is_not.is_nil(renderer)
        assert.is_not.is_nil(renderer.on_end)
        -- No on_start: while the dialog is open the window itself is the UI, so
        -- the block must not spend a row on an input line.
        assert.is_nil(renderer.on_start)
        -- Never auto-collapse: a folded answer list hides what the user picked.
        assert.is_true(renderer.always_expanded)
        assert.is_nil(renderer.input_visible)
        assert.is_nil(renderer.output_visible)
    end)

    --- Render one ask block into a fresh history buffer and return its text.
    ---@param tab integer
    ---@param args table?
    ---@param result table?
    ---@param is_error boolean?
    ---@param lang? "en"|"zh"
    ---@return string
    local function render(tab, args, result, is_error, lang)
        Config.setup({ title = { lang = lang or "en" }, render = { engine = "builtin" } })
        local h = History.new(tab)
        assert.has_no.errors(function()
            h:on_tool_start("ask", "ask-1", args or {})
        end)
        vim.wait(100)
        assert.has_no.errors(function()
            h:on_tool_end("ask", "ask-1", result, is_error == true)
        end)
        vim.wait(100)
        return table.concat(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false), "\n")
    end

    it("renders a cancelled ask as one cancelled row", function()
        local text = render(1201, { questions = {} }, {
            content = { { type = "text", text = "User cancelled the questions." } },
            details = { cancelled = true, v = 1 },
        })
        assert.matches("Cancelled", text)
        -- The raw reply text is not the payload for a cancelled ask.
        assert.not_matches("User cancelled the questions", text)
    end)

    it("renders the picked labels and the free-text answer", function()
        local text = render(1202, {}, {
            content = { { type = "text", text = "answered 2/2" } },
            details = {
                v = 1,
                questions = {
                    { id = "q1", header = "Database", question = "Which database?" },
                    { id = "q2", header = "Data dir", question = "Where?" },
                },
                answers = {
                    { id = "q1", answered = true, labels = { "Postgres" }, selected = { 2 } },
                    { id = "q2", answered = true, custom = "pgdata" },
                },
            },
        })
        -- The header counts the questions...
        assert.matches("ask · 2 questions", text)
        -- ...and each answered question carries the answer the user gave.
        assert.matches("Database", text)
        assert.matches("Postgres", text)
        assert.matches("Data dir", text)
        assert.matches("%(wrote%) pgdata", text)
        -- Both answered: no unanswered marker.
        assert.not_matches("Unanswered", text)
    end)

    it("marks an unanswered question", function()
        local text = render(1203, {}, {
            content = { { type = "text", text = "answered 1/2" } },
            details = {
                v = 1,
                questions = {
                    { id = "q1", header = "Database" },
                    { id = "q2", header = "Data dir" },
                },
                answers = {
                    { id = "q1", answered = true, labels = { "SQLite" } },
                    { id = "q2", answered = false },
                },
            },
        })
        assert.matches("ask · 2 questions", text)
        assert.matches("SQLite", text)
        assert.matches("Data dir · Unanswered", text)
        -- Only the unanswered one is marked.
        assert.not_matches("Database · Unanswered", text)
    end)

    it("uses the zh chrome when title.lang is zh", function()
        local text = render(1207, {}, {
            content = { { type = "text", text = "User cancelled the questions." } },
            details = { cancelled = true, v = 1 },
        }, nil, "zh")
        assert.matches("已取消", text)
        assert.not_matches("Cancelled", text)
    end)

    it("falls back to the reply text when the result has no details", function()
        local text = render(1204, {}, {
            content = { { type = "text", text = "User cancelled the questions; assume Postgres." } },
        })
        assert.matches("cancelled", text)
        assert.not_matches("ask · ", text)
    end)

    it("falls back to the reply text when details is not a table", function()
        local text = render(1205, {}, {
            content = { { type = "text", text = "asks are cancelled here" } },
            details = "junk",
        })
        assert.matches("cancelled", text)
        assert.not_matches("ask · ", text)
    end)

    it("renders only the header when details carries no answers", function()
        local text = render(1206, {}, {
            content = { { type = "text", text = "answered 0/1" } },
            details = { v = 1, questions = { { id = "q1", header = "Database" } }, answers = {} },
        })
        assert.matches("ask · 1 question", text)
        assert.not_matches("Unanswered", text)
        assert.not_matches("Database", text)
    end)
end)
