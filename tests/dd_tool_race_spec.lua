local Chat = require("pi.ui.chat")
local Config = require("pi.config")
local History = require("pi.ui.chat.history")

local TAB = 1490

local function pump(ms)
    vim.wait(ms or 80)
end

local function teardown_chat(chat)
    pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
end

local function setup_chat()
    local sent = {}
    local clear_cb
    local chat = Chat.new(TAB, "side", {
        send = function(cmd, cb)
            sent[#sent + 1] = cmd
            if cmd.type == "clear_queue" then
                clear_cb = cb
            end
            return true
        end,
    })
    return chat, sent, function()
        return clear_cb
    end
end

describe("dd pending queue race with tool on_end", function()
    local orig_schedule
    local scheduled_errors
    local saved_flush_ms

    before_each(function()
        saved_flush_ms = History._stream_flush_ms
        History._stream_flush_ms = 1
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()

        scheduled_errors = {}
        orig_schedule = vim.schedule
        vim.schedule = function(fn)
            return orig_schedule(function()
                local ok, err = xpcall(fn, debug.traceback)
                if not ok then
                    scheduled_errors[#scheduled_errors + 1] = err
                end
            end)
        end
    end)

    after_each(function()
        vim.schedule = orig_schedule
        History._stream_flush_ms = saved_flush_ms
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    it("variant 1: tool streaming + 2 steer entries + remove_pending_queue_entry_at(1) + on_tool_end", function()
        local chat = setup_chat()
        chat._streaming = true
        local h = chat._history

        h:on_agent_start(nil)
        h:on_text_delta(" working on task...\n")
        h:on_tool_start("todo_write", "t1", {
            todos = {
                { content = "First task item", status = "in_progress", activeForm = "Working on first task" },
                { content = "Second task item", status = "pending" },
            },
        })
        pump(40)

        h:add_pending_queue_entry("steer", "steer message 1", "steer message 1")
        h:add_pending_queue_entry("steer", "steer message 2", "steer message 2")

        h:remove_pending_queue_entry_at(1)

        h:on_tool_end("todo_write", "t1", {
            content = { { type = "text", text = "Updated todo list" } },
            details = {
                total = 2,
                completed = 0,
                in_progress = 1,
                pending = 1,
                todos = {
                    { content = "First task item", status = "in_progress", activeForm = "Working on first task" },
                    { content = "Second task item", status = "pending" },
                },
            },
        }, false)
        pump(80)

        teardown_chat(chat)
        assert.are.same({}, scheduled_errors)
    end)

    it(
        "variant 1b: bash tool with on_tool_update + 2 steer entries + remove_pending_queue_entry_at(1) + on_tool_end",
        function()
            local chat = setup_chat()
            chat._streaming = true
            local h = chat._history

            h:on_agent_start(nil)
            h:on_text_delta("running build...\n")
            h:on_tool_start("bash", "b1", { command = "make build" })
            pump(40)
            h:on_tool_update("bash", "b1", {
                partialResult = { content = { { type = "text", text = "compiling...\nlinking..." } } },
            })
            pump(40)

            h:add_pending_queue_entry("steer", "steer 1", "steer 1")
            h:add_pending_queue_entry("steer", "steer 2", "steer 2")

            h:remove_pending_queue_entry_at(1)

            h:on_tool_end("bash", "b1", {
                content = {
                    { type = "text", text = "build line 1 with long output text\nbuild line 2 with more output" },
                },
            }, false)
            pump(80)

            teardown_chat(chat)
            assert.are.same({}, scheduled_errors)
        end
    )

    it("variant 3: full chat:delete_pending_at_cursor() transaction + on_tool_end", function()
        local chat, _, get_clear_cb = setup_chat()
        chat._streaming = true
        local h = chat._history

        h:on_agent_start(nil)
        h:on_text_delta("working...\n")
        h:on_tool_start("todo_write", "t2", {
            todos = {
                { content = "Task A", status = "in_progress", activeForm = "Running Task A" },
                { content = "Task B", status = "pending" },
            },
        })
        pump(40)

        h:add_pending_queue_entry("steer", "steer 1", "steer 1")
        h:add_pending_queue_entry("steer", "steer 2", "steer 2")

        local buf = h:buf()
        vim.api.nvim_win_set_buf(0, buf)
        local line_count = vim.api.nvim_buf_line_count(buf)
        -- Pending block is at buffer end: [line_count-2] = steer 1, [line_count-1] = steer 2 (1-indexed: line_count-1)
        vim.api.nvim_win_set_cursor(0, { line_count - 1, 0 })
        assert.are.equal(1, h:pending_index_at(line_count - 2))

        chat:delete_pending_at_cursor()
        local clear_cb = get_clear_cb()
        assert.is_not_nil(clear_cb)
        clear_cb({
            type = "response",
            command = "clear_queue",
            success = true,
            data = { steering = { "steer 1", "steer 2" }, followUp = {} },
        })
        pump(40)

        h:on_tool_end("todo_write", "t2", {
            content = { { type = "text", text = "Updated todo list" } },
            details = {
                total = 2,
                completed = 0,
                in_progress = 1,
                pending = 1,
                todos = {
                    { content = "Task A", status = "in_progress", activeForm = "Running Task A" },
                    { content = "Task B", status = "pending" },
                },
            },
        }, false)
        pump(80)

        teardown_chat(chat)
        assert.are.same({}, scheduled_errors)
    end)
end)
