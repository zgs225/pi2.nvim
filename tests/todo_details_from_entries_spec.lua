-- Unit tests for the todo data layer: the JSONL snapshot extractor
-- (pi.todo.tool_ui.details_from_entries — pure parsing over decoded session
-- entries) and the per-session snapshot getter (pi.todo.get, exercised only
-- through the public API).

local TodoToolUi = require("pi.todo.tool_ui")
local Todo = require("pi.todo")

--- A decoded `message` toolResult entry in the pi session JSONL shape, with
--- role/toolName defaulted to a todo_write result.
---@param fields table extra entry.message fields (details, content, toolName, ...)
---@return table
local function tool_result(fields)
    return {
        type = "message",
        message = vim.tbl_extend("force", { role = "toolResult", toolName = "todo_write" }, fields),
    }
end

--- The extension's pi2-todo checkpoint entry (extensions/todo.ts appendEntry).
---@param data table entry.data ({ todos, completed, total })
---@return table
local function checkpoint(data)
    return { type = "custom", customType = "pi2-todo", data = data }
end

--- Entries that never carry todo details, reusable across tests.
---@return table[]
local function unrelated_entries()
    return {
        { type = "session_info", data = { cwd = "/tmp" } },
        { type = "message", message = { role = "user", content = "hello" } },
        { type = "message", message = { role = "assistant", content = "on it" } },
        -- Right shape, wrong tool: must not match.
        tool_result({ toolName = "bash", details = { todos = { { content = "x", status = "pending" } } } }),
        -- Right entry kind, wrong customType: must not match.
        { type = "custom", customType = "pi-vision-usage", data = { model = "m" } },
    }
end

describe("todo details_from_entries", function()
    it("returns nil for an empty entry list", function()
        assert.is_nil(TodoToolUi.details_from_entries({}))
        assert.is_nil(TodoToolUi.details_from_entries(nil))
    end)

    it("returns nil when no entry carries todo details", function()
        assert.is_nil(TodoToolUi.details_from_entries(unrelated_entries()))
    end)

    it("extracts the details from a todo_write toolResult", function()
        local entries = unrelated_entries()
        entries[#entries + 1] = tool_result({
            details = {
                todos = {
                    { content = "a", status = "completed" },
                    { content = "b", activeForm = "Doing b", status = "in_progress" },
                    { content = "c", status = "pending" },
                },
                completed = 1,
                total = 3,
            },
        })
        local details = TodoToolUi.details_from_entries(entries)
        assert.is_not.is_nil(details)
        assert.are.equal(3, details.total)
        assert.are.equal(1, details.completed)
        assert.are.equal(3, #details.todos)
        assert.are.equal("b", details.todos[2].content)
        assert.are.equal("Doing b", details.todos[2].activeForm)
    end)

    it("fills in completed/total when the details omit them", function()
        local details = TodoToolUi.details_from_entries({
            tool_result({
                details = {
                    todos = {
                        { content = "a", status = "completed" },
                        { content = "b", status = "pending" },
                    },
                },
            }),
        })
        assert.is_not.is_nil(details)
        assert.are.equal(1, details.completed)
        assert.are.equal(2, details.total)
    end)

    it("falls back to parsing JSON content when details are absent", function()
        -- Same behavior as result_details: no details field, todos live in a
        -- text block of the result content.
        local text = vim.json.encode({ todos = { { content = "a", status = "pending" } } })
        local entry = tool_result({ content = { { type = "text", text = text } } })
        local details = TodoToolUi.details_from_entries({ entry })
        assert.is_not.is_nil(details)
        assert.are.equal(1, details.total)
        assert.are.equal(0, details.completed)
        assert.are.same(TodoToolUi.result_details(entry.message), details)
    end)

    it("keeps the last of several todo_write results", function()
        local details = TodoToolUi.details_from_entries({
            tool_result({
                details = { todos = { { content = "old", status = "pending" } }, completed = 0, total = 1 },
            }),
            tool_result({
                details = { todos = { { content = "new", status = "completed" } }, completed = 1, total = 1 },
            }),
        })
        assert.is_not.is_nil(details)
        assert.are.equal("new", details.todos[1].content)
        assert.are.equal(1, details.completed)
    end)

    it("uses the pi2-todo custom checkpoint when no toolResult exists", function()
        local entries = unrelated_entries()
        -- Counters omitted: normalization fills them from the todo statuses.
        entries[#entries + 1] = checkpoint({ todos = { { content = "ckpt", status = "completed" } } })
        local details = TodoToolUi.details_from_entries(entries)
        assert.is_not.is_nil(details)
        assert.are.equal("ckpt", details.todos[1].content)
        assert.are.equal(1, details.completed)
        assert.are.equal(1, details.total)
    end)

    it("takes the entry-order last match when custom and toolResult mix", function()
        local result_entry = tool_result({
            details = { todos = { { content = "from result", status = "pending" } }, completed = 0, total = 1 },
        })
        local checkpoint_entry = checkpoint({
            todos = { { content = "from checkpoint", status = "completed" } },
            completed = 1,
            total = 1,
        })
        local custom_last = TodoToolUi.details_from_entries({ result_entry, checkpoint_entry })
        assert.are.equal("from checkpoint", custom_last.todos[1].content)
        assert.are.equal(1, custom_last.completed)
        local result_last = TodoToolUi.details_from_entries({ checkpoint_entry, result_entry })
        assert.are.equal("from result", result_last.todos[1].content)
        assert.are.equal(0, result_last.completed)
    end)

    it("skips malformed entries without raising", function()
        local malformed = {
            "junk string entry",
            42,
            { type = "message" }, -- no message at all
            { type = "message", message = "not a table" },
            tool_result({ details = "not a table" }), -- details is a string, no content
            tool_result({ details = { todos = "not an array" } }), -- todos is a string
            checkpoint("not a table"), -- data is a string
            checkpoint({ todos = "not an array" }), -- data.todos is a string
            { type = "custom", customType = "pi2-todo" }, -- no data
        }
        local details
        assert.has_no.errors(function()
            details = TodoToolUi.details_from_entries(malformed)
        end)
        assert.is_nil(details)
        -- Malformed entries after a good one never clobber the kept match.
        local good = tool_result({
            details = { todos = { { content = "keep", status = "pending" } }, completed = 0, total = 1 },
        })
        local kept
        assert.has_no.errors(function()
            kept = TodoToolUi.details_from_entries(vim.list_extend({ good }, malformed))
        end)
        assert.is_not.is_nil(kept)
        assert.are.equal("keep", kept.todos[1].content)
    end)
end)

describe("todo get", function()
    before_each(function()
        Todo._reset()
    end)

    after_each(function()
        Todo._reset()
    end)

    it("returns nil for a nil session", function()
        assert.is_nil(Todo.get(nil))
    end)

    it("returns nil for a session that never wrote todos", function()
        assert.is_nil(Todo.get({}))
    end)

    it("returns the snapshot recorded for that session only", function()
        -- No attached tab: a detached session's snapshot is still reachable.
        local session = { id = "todo-get-spec" }
        Todo.update_from_details({
            todos = {
                { content = "a", status = "completed" },
                { content = "b", status = "pending" },
            },
            completed = 1,
            total = 2,
        }, session)
        local snapshot = Todo.get(session)
        assert.is_not.is_nil(snapshot)
        assert.are.equal(2, snapshot.total)
        assert.are.equal(1, snapshot.completed)
        assert.are.equal("a", snapshot.todos[1].content)
        -- A session that never wrote stays nil.
        assert.is_nil(Todo.get({}))
    end)
end)
