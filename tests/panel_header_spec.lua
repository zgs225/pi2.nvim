-- Unit tests for the shared panel header shell (lua/pi/ui/panel_header.lua).
--
-- The shell is what keeps :PiTodo, :PiTasks and :PiCompactions looking like
-- one column: spacer / title / optional hint / spacer, every chrome line in
-- PiPanelTitle, the panel's rows indented under it, and a title that survives
-- an empty list (with a `no <noun>` placeholder instead of dropped chrome).
-- These tests pin the contract itself, so a panel cannot re-invent its own
-- header again without failing here.

local PanelHeader = require("pi.ui.panel_header")

--- The todo panel's icon (nf-md-format-list-checks), by codepoint so the PUA
--- glyph never gets lost in edits.
local TODO_ICON = vim.fn.nr2char(0xF0756, 1)

describe("panel header shell", function()
    describe("title", function()
        it("indents, prefixes the icon and appends the metric", function()
            assert.equals(
                "  " .. TODO_ICON .. " Todo · 2/5 completed",
                PanelHeader.title({
                    name = "Todo",
                    noun = "todos",
                    icon = TODO_ICON,
                    metric = "2/5 completed",
                })
            )
        end)

        it("omits the metric when there is nothing to count", function()
            assert.equals(
                "  " .. TODO_ICON .. " Todo",
                PanelHeader.title({
                    name = "Todo",
                    noun = "todos",
                    icon = TODO_ICON,
                })
            )
            assert.equals("  Tasks", PanelHeader.title({ name = "Tasks", noun = "tasks", metric = "" }))
        end)

        it("keeps a multi-segment metric verbatim", function()
            assert.equals(
                "  Tasks · 2 running · 1 finished",
                PanelHeader.title({ name = "Tasks", noun = "tasks", metric = "2 running · 1 finished" })
            )
        end)
    end)

    describe("header_lines", function()
        it("counts spacer, title and spacer without a hint", function()
            assert.equals(3, PanelHeader.header_lines({ name = "Todo", noun = "todos" }))
        end)

        it("adds the hint line under the title", function()
            assert.equals(4, PanelHeader.header_lines({ name = "Compactions", noun = "compactions", hint = "q close" }))
            assert.equals(3, PanelHeader.header_lines({ name = "Compactions", noun = "compactions", hint = "" }))
        end)
    end)

    describe("build", function()
        --- The three chrome chunks a plain (hint-less) header owns.
        ---@param header pi.PanelHeader
        ---@return string[]
        local function chrome_groups(header)
            local groups = {}
            for _, chunk in ipairs(header.chunks[2] or {}) do
                groups[#groups + 1] = chunk[3]
            end
            return groups
        end

        it("renders spacer / title / spacer, then the indented rows", function()
            local header = PanelHeader.build({ name = "Todo", noun = "todos", metric = "1/2 completed" }, {
                { line = "✓ first" },
                { line = "○ second" },
            })
            assert.same({ "", "  Todo · 1/2 completed", "", "  ✓ first", "  ○ second" }, header.lines)
            assert.equals(3, header.header_lines)
            assert.is_false(header.empty)
            assert.equals("  Todo · 1/2 completed", header.title)
            assert.same({ "PiPanelTitle" }, chrome_groups(header))
        end)

        it("shifts row chunks onto the indented line", function()
            local header = PanelHeader.build({ name = "Tasks", noun = "tasks" }, {
                { line = "● cmd · t1", chunks = { { 0, 1, "PiTasksListRunning" }, { 2, 5, "Normal" } } },
            })
            assert.equals("  ● cmd · t1", header.lines[4])
            assert.same({ { 2, 3, "PiTasksListRunning" }, { 4, 7, "Normal" } }, header.chunks[4])
        end)

        it("keeps the title on an empty list and adds the placeholder", function()
            local header = PanelHeader.build({ name = "Compactions", noun = "compactions", metric = nil }, {})
            assert.same({ "", "  Compactions", "", "  no compactions" }, header.lines)
            assert.is_true(header.empty)
            assert.equals(3, header.header_lines)
            assert.equals("PiPanelTitle", header.chunks[4][1][3], "placeholder is dim chrome, not row content")
        end)

        it("renders the hint line between the title and the spacer", function()
            local header = PanelHeader.build({ name = "Compactions", noun = "compactions", hint = "? help · q close" })
            assert.same({
                "",
                "  Compactions",
                "  ? help · q close",
                "",
                "  no compactions",
            }, header.lines)
            assert.equals(4, header.header_lines)
            assert.equals("PiPanelTitle", header.chunks[3][1][3])
        end)

        it("treats a missing row list like an empty one", function()
            local header = PanelHeader.build({ name = "Todo", noun = "todos" }, nil)
            assert.is_true(header.empty)
            assert.equals("  no todos", header.lines[4])
        end)

        it("falls back to a generic noun when the spec omits one", function()
            local header = PanelHeader.build({ name = "Panel" })
            assert.equals("  no rows", header.lines[4])
        end)
    end)

    describe("empty state", function()
        it("centres the headline and puts the hint after a blank line", function()
            local header = PanelHeader.build({
                name = "Todo",
                noun = "todos",
                width = 24,
                empty = { headline = "nothing planned", detail = "ask me", hint = "q close" },
            })
            assert.same({
                "",
                "  Todo",
                "",
                "    nothing planned",
                "         ask me",
                "",
                "        q close",
            }, header.lines)
            assert.equals(3, header.header_lines, "the empty block sits below the header")
            assert.is_true(header.empty)
        end)

        it("renders the headline as content and the detail as dim chrome", function()
            local header = PanelHeader.build({
                name = "Todo",
                noun = "todos",
                width = 24,
                empty = { headline = "nothing planned", detail = "ask me", hint = "q close" },
            })
            assert.is_nil(header.chunks[4], "the headline carries no chunk: it inherits the window text colour")
            assert.equals("PiPanelTitle", header.chunks[5][1][3])
            assert.equals("PiPanelTitle", header.chunks[7][1][3])
        end)

        it("lets the panel paint the detail with a semantic group", function()
            local header = PanelHeader.build({
                name = "Todo",
                noun = "todos",
                width = 24,
                empty = { headline = "the list was cleared", detail = "5/5 completed", detail_hl = "PiTodoDone" },
            })
            assert.equals("PiTodoDone", header.chunks[5][1][3])
        end)

        it("drops the detail first when it does not fit, keeping the hint", function()
            local header = PanelHeader.build({
                name = "Todo",
                noun = "todos",
                width = 20,
                empty = { headline = "nothing planned yet", detail = "ask, and I'll track it", hint = "q close" },
            })
            -- 1 cell of slack: the block keeps the shell indent instead of
            -- hugging column 0.
            assert.same({ "", "  Todo", "", " nothing planned yet", "", "      q close" }, header.lines)
        end)

        it("keeps only the headline when nothing else fits, truncating it last", function()
            local header = PanelHeader.build({
                name = "Todo",
                noun = "todos",
                width = 6,
                empty = { headline = "nothing planned yet", detail = "ask, and I'll track it", hint = "q close" },
            })
            assert.same({ "", "  Todo", "", "nothi…" }, header.lines)
        end)

        it("centres a CJK line by display width, not by character count", function()
            local header = PanelHeader.build({
                name = "Todo",
                noun = "todos",
                width = 20,
                -- 7 glyphs = 14 cells, so 3 cells of padding on the left
                empty = { headline = "还没有任务清单", detail = "说要做什么，我拆给你看" },
            })
            assert.equals("   还没有任务清单", header.lines[4])
            -- 12 glyphs = 24 cells: the detail does not fit and is dropped
            assert.equals(4, #header.lines)
        end)

        it("keeps the shell indent when the caller does not know its width", function()
            local header = PanelHeader.build({
                name = "Todo",
                noun = "todos",
                empty = { headline = "nothing planned yet", hint = "q close" },
            })
            assert.same({ "", "  Todo", "", "  nothing planned yet", "", "  q close" }, header.lines)
        end)

        it("leaves the legacy placeholder alone when no empty state is supplied", function()
            local header = PanelHeader.build({ name = "Compactions", noun = "compactions", width = 24 }, {})
            assert.equals("  no compactions", header.lines[4])
            assert.equals(4, #header.lines, "a width alone does not turn the placeholder into a block")
        end)
    end)
end)
