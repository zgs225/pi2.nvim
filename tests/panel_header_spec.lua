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
end)
