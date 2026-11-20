-- Background-task records folded by the sub-session viewer.
--
-- A child's `wait_task` / `stop_task` / `task_input` blocks resolve their label
-- (the command, then the id) from the frontend task registry, exactly like the
-- parent's. The live path already folds the child's `pi2_bg_task` messages
-- (sessions/manager.lua routes every `message_start` custom message into
-- pi.tasks, chat or no chat); these specs cover the two replay paths the viewer
-- owns: the RPC `get_messages` transcript (role="custom") and a dormant
-- session's JSONL file.

local Viewer = require("pi.ui.subsession_viewer")
local History = require("pi.ui.chat.history")
local Tasks = require("pi.tasks")
local Manifest = require("pi.subsessions.manifest")
local Sessions = require("pi.sessions.manager")
local Read = require("pi.subsessions.read")

local function pump(ms)
    vim.wait(ms or 50, function()
        return false
    end, 10)
end

---@param buf integer
---@return string
local function text_of(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- A `pi2_bg_task` record as `get_messages` serves it: role="custom", display
--- off, payload under `details` (shape copied from a real RPC snapshot).
---@param details table
---@param timestamp integer
---@return table
local function custom_message(details, timestamp)
    return {
        role = "custom",
        customType = "pi2_bg_task",
        content = "[Background task " .. tostring(details.taskId) .. " " .. tostring(details.kind) .. "]",
        display = false,
        timestamp = timestamp,
        details = details,
    }
end

--- A wait_task call and its result for `task_id`. The result text deliberately
--- avoids the id: the point is what the *block* names, not what the output says.
---@param task_id string
---@param timeout_s integer
---@return table call, table result
local function wait_task_pair(task_id, timeout_s)
    return {
        role = "assistant",
        content = {
            {
                type = "toolCall",
                toolCallId = "call_wait_" .. task_id,
                toolName = "wait_task",
                arguments = { task_id = task_id, timeout_ms = timeout_s * 1000 },
            },
        },
        timestamp = 20,
    }, {
        role = "toolResult",
        toolCallId = "call_wait_" .. task_id,
        toolName = "wait_task",
        content = { { type = "text", text = "exited with code 0 after 5.0s\n\nsleep finished" } },
        timestamp = 21,
    }
end

--- Assert that every rendered line naming `task_id` also names the command:
--- a block body reads `<command> · <id>`, never the bare id.
---@param text string whole buffer text
---@param command string expected command
---@param task_id string expected task id
local function assert_labelled(text, command, task_id)
    local labelled = false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:find(task_id, 1, true) then
            assert.is_truthy(line:find(command, 1, true), "task id without its command: " .. line)
            labelled = true
        end
    end
    assert.is_true(labelled, "no line names " .. task_id)
end

describe("sub-session viewer background tasks", function()
    local tmp_dir = nil

    before_each(function()
        Tasks._reset()
        tmp_dir = vim.fn.tempname()
        vim.fn.mkdir(tmp_dir, "p")
        Viewer.close()
    end)

    after_each(function()
        Viewer.close()
        if tmp_dir and vim.fn.isdirectory(tmp_dir) == 1 then
            vim.fn.delete(tmp_dir, "rf")
        end
    end)

    describe("pi.tasks.absorb_message", function()
        it("folds both lifecycle records of one task into one record, scoped to the child", function()
            local started = custom_message({
                kind = "started",
                taskId = "b4f7a21",
                command = "sleep 5",
                pid = 424242,
            }, 4)
            assert.is_true(Tasks.absorb_message(started, "child-1", nil))

            local task = Tasks.get("b4f7a21")
            assert.is_not_nil(task)
            assert.equals("sleep 5", task.command)
            assert.equals("running", task.status)
            assert.equals("child-1", task.session_id)
            assert.is_nil(task.tab)

            local completed = custom_message({ kind = "completed", taskId = "b4f7a21", exitCode = 0 }, 9)
            assert.is_true(Tasks.absorb_message(completed, "child-1", nil))

            task = Tasks.get("b4f7a21")
            assert.equals("completed", task.status)
            assert.equals(0, task.exit_code)
            -- The terminal payload also carries the command; the record keeps it.
            assert.equals("sleep 5", task.command)

            -- The parent's panel is untouched: the row belongs to the child.
            assert.equals(0, #Tasks.list("parent"))
            assert.equals(1, #Tasks.list("child-1"))
        end)

        it("folds a JSONL entry's `data` payload", function()
            assert.is_true(Tasks.absorb_message({
                type = "custom",
                customType = "pi2_bg_task",
                data = { kind = "started", taskId = "b7a6e1e", command = "make test" },
            }, "child-2", nil))

            local task = Tasks.get("b7a6e1e")
            assert.is_not_nil(task)
            assert.equals("make test", task.command)
            assert.equals("running", task.status)
            assert.equals("child-2", task.session_id)
        end)

        it("returns false for input it cannot fold", function()
            assert.is_false(Tasks.absorb_message(nil, "child-1", nil))
            assert.is_false(Tasks.absorb_message("b4f7a21", "child-1", nil))
            -- A record with no payload at all.
            assert.is_false(Tasks.absorb_message({
                role = "custom",
                customType = "pi2_bg_task",
            }, "child-1", nil))
            -- Another extension's custom entry is not a task record.
            assert.is_false(Tasks.absorb_message({
                type = "custom",
                customType = "pi2-todo",
                data = { todos = {} },
            }, "child-1", nil))
            assert.is_nil(Tasks.get("b4f7a21"))
        end)

        it("does not un-finish a tracked record when `started` is folded again", function()
            local started = custom_message({
                kind = "started",
                taskId = "b4f7a21",
                command = "sleep 5",
            }, 4)
            Tasks.absorb_message(started, "child-1", nil)
            Tasks.absorb_message(
                custom_message({ kind = "completed", taskId = "b4f7a21", exitCode = 0 }, 9),
                "child-1",
                nil
            )
            local finished = Tasks.get("b4f7a21")
            assert.equals("completed", finished.status)

            -- A reopened viewer / compaction rebuild replays the same transcript,
            -- started entry included: consumed, but the record is left alone.
            assert.is_true(Tasks.absorb_message(started, "child-1", nil))
            assert.is_true(finished == Tasks.get("b4f7a21"))
            assert.equals("completed", Tasks.get("b4f7a21").status)
            assert.equals(0, Tasks.get("b4f7a21").exit_code)
        end)
    end)

    it("names the command in a child's replayed wait_task block (live transcript)", function()
        local call, result = wait_task_pair("b4f7a21", 5)
        local messages = {
            { role = "user", content = { { type = "text", text = "run it in the background" } }, timestamp = 1 },
            custom_message({ kind = "started", taskId = "b4f7a21", command = "sleep 5", pid = 424242 }, 4),
            call,
            result,
        }

        local h = History.new(-999)
        Viewer._replay(h, messages, "child-live-1")
        pump(100)

        local text = text_of(h:buf())
        assert_labelled(text, "sleep 5", "b4f7a21")

        -- Ownership: the row is the child's, never the parent's tab/session.
        local task = Tasks.get("b4f7a21")
        assert.is_not_nil(task)
        assert.equals("child-live-1", task.session_id)
        assert.is_nil(task.tab)
        assert.equals(0, #Tasks.list("parent"))
        assert.equals(1, #Tasks.list("child-live-1"))

        local buf = h:buf()
        h:clear()
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    it("names the command in a dormant session's wait_task blocks (JSONL)", function()
        local child_id = "child-dormant-tasks"
        local call, result = wait_task_pair("b7a6e1e", 5)
        local stop_call, stop_result = wait_task_pair("c0ffee1", 3)
        stop_call.content[1].toolName = "stop_task"
        stop_call.content[1].toolCallId = "call_stop_c0ffee1"
        stop_result.toolCallId = "call_stop_c0ffee1"
        stop_result.toolName = "stop_task"

        local file_path = tmp_dir .. "/child.jsonl"
        local lines = {
            vim.json.encode({ type = "session", sessionId = child_id, cwd = tmp_dir }),
            vim.json.encode({
                type = "message",
                message = { role = "user", content = "build it", timestamp = 1 },
            }),
            -- The tool block comes FIRST: the pre-pass folds every record before
            -- the transcript is rendered, so file order cannot matter.
            vim.json.encode({ type = "message", message = call }),
            vim.json.encode({ type = "message", message = result }),
            vim.json.encode({ type = "message", message = stop_call }),
            vim.json.encode({ type = "message", message = stop_result }),
            -- A `custom_message` record: the shape real session files carry.
            vim.json.encode({
                type = "custom_message",
                customType = "pi2_bg_task",
                content = "[Background task b7a6e1e started]",
                display = false,
                details = { kind = "started", taskId = "b7a6e1e", command = "make test", pid = 4242 },
            }),
            -- A raw `custom` record, payload under `data` (the older shape).
            vim.json.encode({
                type = "custom",
                customType = "pi2_bg_task",
                data = { kind = "started", taskId = "c0ffee1", command = "npm run dev" },
            }),
        }
        local f = assert(io.open(file_path, "w"))
        f:write(table.concat(lines, "\n"))
        f:close()

        local orig_load = Manifest.load
        local orig_find_path = Read.find_path
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return {
                [child_id] = {
                    name = "Worker Beta",
                    status = "dormant",
                    task_prompt = "build it",
                    parent_id = "p-1",
                    reported = true,
                    created_at = "now",
                    last_active_at = "now",
                },
            }
        end
        Read.find_path = function(id)
            return id == child_id and file_path or nil
        end
        Sessions.get_by_id = function()
            return nil
        end

        local ok, err = pcall(Viewer.open, child_id)
        Manifest.load = orig_load
        Read.find_path = orig_find_path
        Sessions.get_by_id = orig_get_by_id
        assert.is_true(ok, tostring(err))
        pump(100)

        local h = assert(Viewer._history())
        local text = text_of(h:buf())
        assert_labelled(text, "make test", "b7a6e1e")
        assert_labelled(text, "npm run dev", "c0ffee1")

        -- Scoped to the viewed child, not to the parent that spawned it.
        for _, id in ipairs({ "b7a6e1e", "c0ffee1" }) do
            local task = Tasks.get(id)
            assert.is_not_nil(task)
            assert.equals(child_id, task.session_id)
            assert.is_nil(task.tab)
        end
        assert.equals(0, #Tasks.list("p-1"))
        assert.equals(2, #Tasks.list(child_id))
    end)

    it("renders a child's list_tasks rows command-first, like the parent's chat", function()
        -- `get_messages` serves a replayed toolResult with its `details` at the
        -- top level (not nested), which is the shape the viewer meets.
        local messages = {
            { role = "user", content = { { type = "text", text = "what is running?" } }, timestamp = 1 },
            {
                role = "assistant",
                content = {
                    {
                        type = "toolCall",
                        toolCallId = "call_list_1",
                        toolName = "list_tasks",
                        arguments = { include_finished = true },
                    },
                },
                timestamp = 2,
            },
            {
                role = "toolResult",
                toolCallId = "call_list_1",
                toolName = "list_tasks",
                content = {
                    {
                        type = "text",
                        text = '1 of 1 background task, 1 running:\n- b3f2a1 [running, stdin open] 1m04s "npm run dev" (output: /tmp/pi-bash-b3f2a1.log)',
                    },
                },
                details = {
                    total = 1,
                    running = 1,
                    listed = 1,
                    tasks = {
                        { id = "b3f2a1", command = "npm run dev", state = "running, stdin open", elapsed = "1m04s" },
                    },
                },
                timestamp = 3,
            },
        }

        local h = History.new(-998)
        Viewer._replay(h, messages, "child-live-2")
        pump(100)

        local text = text_of(h:buf())
        assert_labelled(text, "npm run dev", "b3f2a1")
        assert.is_truthy(text:find("npm run dev · b3f2a1 · running, stdin open · 1m04s", 1, true), text)
        -- The extension's id-first line is the model's copy, not the viewer's.
        assert.is_falsy(text:find("- b3f2a1 [running", 1, true), text)

        local buf = h:buf()
        h:clear()
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)
end)
