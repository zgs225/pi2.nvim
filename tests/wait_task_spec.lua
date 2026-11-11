-- wait_task rendering (bundled bg-tasks extension) plus the model-facing
-- contract that lives in extensions/bg-tasks.ts. The renderer half runs against
-- a real history buffer; the .ts half is a source contract check, because the
-- tool itself only ever executes inside pi.

local History = require("pi.ui.chat.history")
local Tools = require("pi.ui.chat.tools")

local TAB = 903

local function pump(ms)
    vim.wait(ms or 30)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function text_of(buf)
    return table.concat(lines_of(buf), "\n")
end

--- Rows (0-based) of every buffer line containing `sub` (plain match).
local function rows_with(buf, sub)
    local out = {}
    for i, l in ipairs(lines_of(buf)) do
        if l:find(sub, 1, true) then
            out[#out + 1] = i - 1
        end
    end
    return out
end

---@return string
local function repo_root()
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
end

local function read_extension()
    local path = repo_root() .. "/extensions/bg-tasks.ts"
    local fh = assert(io.open(path, "r"))
    local text = fh:read("*a")
    fh:close()
    return text
end

describe("wait_task renderer", function()
    it("renders as a block, not an inline one-liner", function()
        local renderer = Tools.get_renderer("wait_task")
        assert.is_table(renderer)
        -- The result body carries the backgrounded command's output — the only
        -- place it reaches the chat — so an inline renderer would hide it.
        assert.is_falsy(Tools.is_inline(renderer, { task_id = "b1" }))
        assert.is_true(renderer.output_visible > 0)
    end)

    it("shows the task id and the attach window as the block body", function()
        local h = History.new(TAB)
        h:on_tool_start("wait_task", "wt1", { task_id = "b3f2a1", timeout_ms = 60000 })
        pump(50)
        local buf = h:buf()
        assert.is_true(#rows_with(buf, "wait_task") == 1, "expected the tool name in the header")
        assert.is_true(#rows_with(buf, "b3f2a1") == 1, "expected the task id")
        assert.is_true(#rows_with(buf, "(timeout 60s)") == 1, "expected the attach window in seconds")
    end)

    it("omits the window when the call did not pass one", function()
        local h = History.new(TAB)
        h:on_tool_start("wait_task", "wt2", { task_id = "b3f2a1" })
        pump(50)
        local buf = h:buf()
        assert.is_true(#rows_with(buf, "b3f2a1") == 1)
        assert.is_true(#rows_with(buf, "timeout") == 0)
    end)

    it("renders the waited task's output as the result body", function()
        local h = History.new(TAB)
        h:on_tool_start("wait_task", "wt3", { task_id = "b3f2a1" })
        pump(50)
        h:on_tool_end(
            "wait_task",
            "wt3",
            { content = { { type = "text", text = "Task b3f2a1 exited with code 0 after 6.0s.\n\nDONE-MARKER" } } },
            false
        )
        pump(60)
        local text = text_of(h:buf())
        assert.is_truthy(text:find("exited with code 0", 1, true), "expected the exit line")
        assert.is_truthy(text:find("DONE-MARKER", 1, true), "expected the task output")
    end)
end)

describe("bg-tasks extension contract", function()
    it("registers a wait_task tool and points bash at it", function()
        local src = read_extension()
        assert.is_truthy(src:find('name: "wait_task"', 1, true), "wait_task must be registered")
        assert.is_truthy(src:find("call wait_task", 1, true), "the bash result must offer wait_task")
        assert.is_truthy(src:find("run_in_background", 1, true))
    end)

    it("never tells the model to sleep, and authorizes ending the turn", function()
        local src = read_extension()
        assert.is_truthy(src:find("Never wait with `sleep`", 1, true))
        assert.is_truthy(src:find("ending your turn is the correct", 1, true))
        assert.is_truthy(src:find("is not a failure", 1, true))
    end)

    it("hands an outlived foreground command to the background instead of killing it", function()
        local src = read_extension()
        assert.is_truthy(src:find("detachedByTimeout", 1, true), "detach must be reported in details")
        assert.is_truthy(
            src:find("keeps running as background task", 1, true),
            "the result must say the command survived"
        )
    end)

    it("marks the wake report as a system notification, not user input", function()
        local src = read_extension()
        assert.is_truthy(src:find("[SYSTEM NOTIFICATION - NOT USER INPUT]", 1, true))
    end)

    it("keeps completion delivery exactly-once through an observer lease", function()
        local src = read_extension()
        -- The lease is what stops a waited-on task from also producing a wake.
        assert.is_truthy(src:find("observers", 1, true))
        assert.is_truthy(src:find("task.observers > 0", 1, true))
    end)
end)
