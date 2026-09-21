-- Unit tests for the todo feature's Lua display layer: the pure helpers in
-- lua/pi/todo/tool_ui.lua (labels, locale, result parsing, list formatting,
-- runtime config publication) and the todo_write chat renderer wiring in
-- lua/pi/ui/chat/tools.lua. Pure logic + history rendering; no RPC.

local Config = require("pi.config")
local TodoToolUi = require("pi.todo.tool_ui")
local Tools = require("pi.ui.chat.tools")

describe("todo tool_ui", function()
    after_each(function()
        Config.setup({})
    end)

    describe("is_todo_tool", function()
        it("matches only todo_write", function()
            assert.is_true(TodoToolUi.is_todo_tool("todo_write"))
            assert.is_false(TodoToolUi.is_todo_tool("todo"))
            assert.is_false(TodoToolUi.is_todo_tool("bash"))
            assert.is_false(TodoToolUi.is_todo_tool(nil))
        end)
    end)

    describe("display_name", function()
        it("uses the zh label when title.lang is zh", function()
            Config.setup({ title = { lang = "zh" } })
            assert.are.equal("待办·写", TodoToolUi.display_name("todo_write"))
        end)

        it("uses the en label when title.lang is en", function()
            Config.setup({ title = { lang = "en" } })
            assert.are.equal("todo·write", TodoToolUi.display_name("todo_write"))
        end)

        it("falls back to the tool name for unknown tools", function()
            Config.setup({ title = { lang = "en" } })
            assert.are.equal("other_tool", TodoToolUi.display_name("other_tool"))
        end)

        it("resolves zh from LANG when title.lang is unset", function()
            local old = vim.fn.getenv("LANG")
            vim.fn.setenv("LANG", "zh_CN.UTF-8")
            Config.setup({ title = {} })
            assert.are.equal("待办·写", TodoToolUi.display_name("todo_write"))
            if old == vim.NIL then
                vim.fn.setenv("LANG", "")
            else
                vim.fn.setenv("LANG", old)
            end
        end)
    end)

    describe("result_details", function()
        it("parses a well-shaped details table", function()
            local details = TodoToolUi.result_details({
                details = {
                    todos = {
                        { content = "a", status = "completed" },
                        { content = "b", status = "in_progress" },
                        { content = "c", status = "pending" },
                    },
                    completed = 1,
                    total = 3,
                },
            })
            assert.is_not.is_nil(details)
            assert.are.equal(3, details.total)
            assert.are.equal(1, details.completed)
            assert.are.equal(3, #details.todos)
        end)

        it("counts completed/total when the details table omits them", function()
            local details = TodoToolUi.result_details({
                details = {
                    todos = {
                        { content = "a", status = "completed" },
                        { content = "b", status = "pending" },
                    },
                },
            })
            assert.are.equal(2, details.total)
            assert.are.equal(1, details.completed)
        end)

        it("parses JSON in a string content", function()
            local details = TodoToolUi.result_details({
                content = vim.json.encode({ todos = { { content = "a", status = "pending" } } }),
            })
            assert.is_not.is_nil(details)
            assert.are.equal(1, details.total)
        end)

        it("parses JSON in a text content block", function()
            local details = TodoToolUi.result_details({
                content = {
                    { type = "text", text = vim.json.encode({ todos = { { content = "a", status = "pending" } } }) },
                },
            })
            assert.is_not.is_nil(details)
            assert.are.equal(1, details.total)
        end)

        it("ignores JSON without a todos list", function()
            assert.is_nil(TodoToolUi.result_details({ content = vim.json.encode({ status = "ok" }) }))
        end)

        it("returns nil for garbage content and malformed details", function()
            assert.is_nil(TodoToolUi.result_details({ content = "not json" }))
            assert.is_nil(TodoToolUi.result_details({ content = { { type = "text", text = "not json" } } }))
            assert.is_nil(TodoToolUi.result_details({ details = { status = "ok" } }))
            assert.is_nil(TodoToolUi.result_details({}))
            assert.is_nil(TodoToolUi.result_details(nil))
        end)

        it("drops non-table todo entries", function()
            local details = TodoToolUi.result_details({
                details = { todos = { { content = "a", status = "pending" }, "junk", 42 } },
            })
            assert.are.equal(1, #details.todos)
            assert.are.equal(1, details.total)
        end)
    end)

    describe("progress_text", function()
        it("formats the en progress label", function()
            Config.setup({ title = { lang = "en" } })
            assert.are.equal("2/5 completed", TodoToolUi.progress_text({ completed = 2, total = 5 }))
        end)

        it("formats the zh progress label", function()
            Config.setup({ title = { lang = "zh" } })
            assert.are.equal("2/5 已完成", TodoToolUi.progress_text({ completed = 2, total = 5 }))
        end)

        it("counts from todos when counters are missing", function()
            Config.setup({ title = { lang = "en" } })
            local text = TodoToolUi.progress_text({
                todos = {
                    { content = "a", status = "completed" },
                    { content = "b", status = "in_progress" },
                    { content = "c", status = "pending" },
                },
            })
            assert.are.equal("1/3 completed", text)
        end)

        it("returns nil for empty or invalid details", function()
            assert.is_nil(TodoToolUi.progress_text({ completed = 0, total = 0 }))
            assert.is_nil(TodoToolUi.progress_text({ todos = {} }))
            assert.is_nil(TodoToolUi.progress_text(nil))
            assert.is_nil(TodoToolUi.progress_text("junk"))
        end)
    end)

    describe("format_lines", function()
        local details = {
            todos = {
                { content = "done task", status = "completed" },
                { content = "active task", activeForm = "Doing the work", status = "in_progress" },
                { content = "waiting task", status = "pending" },
            },
            completed = 1,
            total = 3,
        }

        it("renders the three states with the header first", function()
            Config.setup({ title = { lang = "en" } })
            local lines = TodoToolUi.format_lines(details)
            assert.are_same({
                "1/3 completed",
                "✓ done task",
                "◐ Doing the work",
                "○ waiting task",
            }, lines)
        end)

        it("falls back to content when activeForm is missing", function()
            Config.setup({ title = { lang = "en" } })
            local lines = TodoToolUi.format_lines({
                todos = { { content = "working", status = "in_progress" } },
                completed = 0,
                total = 1,
            })
            assert.are_same({ "0/1 completed", "◐ working" }, lines)
        end)

        it("renders zh labels and truncates at max_items", function()
            Config.setup({ title = { lang = "zh" } })
            local todos = {}
            for i = 1, 5 do
                todos[i] = { content = "task " .. i, status = "pending" }
            end
            local lines = TodoToolUi.format_lines({ todos = todos }, { max_items = 2 })
            assert.are_same({
                "0/5 已完成",
                "○ task 1",
                "○ task 2",
                "… 还有 3 项",
            }, lines)
        end)

        it("truncates in en", function()
            Config.setup({ title = { lang = "en" } })
            local todos = {}
            for i = 1, 5 do
                todos[i] = { content = "task " .. i, status = "pending" }
            end
            local lines = TodoToolUi.format_lines({ todos = todos, completed = 0, total = 5 }, { max_items = 2 })
            assert.are_same({
                "0/5 completed",
                "○ task 1",
                "○ task 2",
                "… 3 more",
            }, lines)
        end)

        it("returns no lines for invalid details", function()
            assert.are_same({}, TodoToolUi.format_lines(nil))
            assert.are_same({}, TodoToolUi.format_lines("junk"))
            assert.are_same({}, TodoToolUi.format_lines({}))
            assert.are_same({}, TodoToolUi.format_lines({ todos = {} }))
        end)
    end)
end)

describe("pi.todo.tool_ui state_path / publish", function()
    local dir

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        TodoToolUi._set_path(dir .. "/todo-config")
    end)

    after_each(function()
        TodoToolUi._set_path(nil)
        vim.fn.delete(dir, "rf")
    end)

    it("round-trips the published options", function()
        TodoToolUi.publish({ enabled = true, remind_after_turns = 5, max_items = 10 })
        local cfg = TodoToolUi.published()
        assert.is_true(cfg.enabled)
        assert.are.equal(5, cfg.remind_after_turns)
        assert.are.equal(10, cfg.max_items)
    end)

    it("persists an explicit disable and normalizes non-numeric values", function()
        TodoToolUi.publish({ enabled = false, remind_after_turns = "lots", max_items = nil })
        local cfg = TodoToolUi.published()
        assert.is_false(cfg.enabled)
        assert.are.equal(3, cfg.remind_after_turns)
        assert.are.equal(20, cfg.max_items)
    end)

    it("returns nil without a runtime file and for a corrupt file", function()
        assert.is_nil(TodoToolUi.published())
        local f = io.open(TodoToolUi.state_path(), "w")
        f:write("not json")
        f:close()
        assert.is_nil(TodoToolUi.published())
    end)

    it("embeds the PID in the default path", function()
        TodoToolUi._set_path(nil)
        local path = TodoToolUi.state_path()
        assert.is_truthy(path:find("pi2nvim-todo-config-", 1, true), "unexpected name: " .. path)
        assert.is_truthy(path:find(tostring(vim.fn.getpid()), 1, true), "missing PID: " .. path)
    end)
end)

describe("todo_write renderer", function()
    after_each(function()
        Config.setup({})
    end)

    it("registers the icon and the renderer", function()
        assert.is_not.equal(require("pi.config").options.labels.tool, Tools.get_tool_icon("todo_write"))
        local renderer = Tools.get_renderer("todo_write")
        assert.is_not.is_nil(renderer.on_start)
        assert.is_not.is_nil(renderer.on_end)
    end)

    it("renders the item count on start and the three-state list on end", function()
        local History = require("pi.ui.chat.history")
        Config.setup({ title = { lang = "en" }, render = { engine = "builtin" } })
        local h = History.new(996)
        assert.has_no.errors(function()
            h:on_tool_start("todo_write", "todo-1", {
                todos = {
                    { content = "first", status = "completed" },
                    { content = "second", activeForm = "Doing second", status = "in_progress" },
                    { content = "third", status = "pending" },
                },
            })
        end)
        vim.wait(100)
        local result = {
            content = { { type = "text", text = "Todos updated (1/3 completed)." } },
            details = {
                todos = {
                    { content = "first", status = "completed" },
                    { content = "second", activeForm = "Doing second", status = "in_progress" },
                    { content = "third", status = "pending" },
                },
                completed = 1,
                total = 3,
            },
        }
        assert.has_no.errors(function()
            h:on_tool_end("todo_write", "todo-1", result, false)
        end)
        vim.wait(100)
        local text = table.concat(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false), "\n")
        assert.matches("%(3 items%)", text)
        assert.matches("1/3 completed", text)
        assert.matches("✓ first", text)
        assert.matches("◐ Doing second", text)
        assert.matches("○ third", text)
    end)

    it("renders the extension reply text for an empty list and on error", function()
        local History = require("pi.ui.chat.history")
        Config.setup({ title = { lang = "en" }, render = { engine = "builtin" } })
        local h = History.new(997)
        h:on_tool_start("todo_write", "todo-2", { todos = {} })
        vim.wait(100)
        h:on_tool_end("todo_write", "todo-2", {
            content = { { type = "text", text = "Todos updated (0/0 completed)." } },
            details = { todos = {}, completed = 0, total = 0 },
        }, false)
        vim.wait(100)
        local text = table.concat(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false), "\n")
        assert.matches("Todos updated %(0/0 completed%)", text)
    end)

    it("shows the validation-error text when details.error is set without isError", function()
        -- extensions/todo.ts validation rejections return a NORMAL result
        -- (never isError) whose details.error carries the reason and whose
        -- todos are the unchanged previous list; the block must show the
        -- error text, not silently re-render the old list.
        local History = require("pi.ui.chat.history")
        Config.setup({ title = { lang = "en" }, render = { engine = "builtin" } })
        local h = History.new(999)
        local previous = { { content = "keep me", status = "pending" } }
        h:on_tool_start("todo_write", "todo-4", { todos = { previous[1], previous[1] } })
        vim.wait(100)
        h:on_tool_end("todo_write", "todo-4", {
            content = {
                { type = "text", text = "Error: 2 items are in_progress — keep exactly one item in_progress" },
            },
            details = { todos = previous, completed = 0, total = 1, error = "2 items are in_progress" },
        }, false)
        vim.wait(100)
        local text = table.concat(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false), "\n")
        assert.matches("Error: 2 items are in_progress", text)
        assert.not_matches("keep me", text)
    end)

    it("truncates long lists at todo.max_items", function()
        local History = require("pi.ui.chat.history")
        Config.setup({ title = { lang = "en" }, todo = { max_items = 2 }, render = { engine = "builtin" } })
        local h = History.new(998)
        local todos = {}
        for i = 1, 4 do
            todos[i] = { content = "task " .. i, status = "pending" }
        end
        h:on_tool_start("todo_write", "todo-3", { todos = todos })
        vim.wait(100)
        h:on_tool_end("todo_write", "todo-3", {
            content = { { type = "text", text = "Todos updated." } },
            details = { todos = todos, completed = 0, total = 4 },
        }, false)
        vim.wait(100)
        local text = table.concat(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false), "\n")
        assert.matches("0/4 completed", text)
        assert.matches("… 2 more", text)
    end)
end)
