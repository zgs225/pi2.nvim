-- Unit + headless-window tests for the subsession viewer's todo display:
-- the footer summary chunk, the `T` todo panel, the live/dormant snapshot
-- resolution, and the auto-open/suppression transitions. Isolation follows
-- subsession_viewer_spec.lua (stub Manifest/Read/Sessions around open()).

local Viewer = require("pi.ui.subsession_viewer")
local TodoToolUi = require("pi.todo.tool_ui")
local Todo = require("pi.todo")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Sessions = require("pi.sessions.manager")
local Config = require("pi.config")

local function pump(ms)
    vim.wait(ms or 50, function()
        return false
    end, 10)
end

describe("pi.ui.subsession_viewer todo display", function()
    local tmp_dir = nil
    ---@type table<string, any>
    local orig = {}

    --- A todo snapshot covering the three states.
    local details_fixture = {
        todos = {
            { content = "done task", status = "completed" },
            { content = "active task", activeForm = "Doing the work", status = "in_progress" },
            { content = "waiting task", status = "pending" },
        },
        completed = 1,
        total = 3,
    }

    --- A dormant JSONL fixture whose latest todo_write result is the fixture
    --- snapshot above.
    ---@return string path
    local function write_todo_jsonl(name)
        local path = tmp_dir .. "/" .. name
        local lines = {
            vim.json.encode({ type = "session_info", name = "Todo Worker" }),
            vim.json.encode({ type = "message", message = { role = "user", content = "do the work" } }),
            vim.json.encode({
                type = "message",
                message = {
                    role = "toolResult",
                    toolName = "todo_write",
                    toolCallId = "call_t1",
                    details = details_fixture,
                },
            }),
        }
        local f = io.open(path, "w")
        assert.is_not_nil(f)
        f:write(table.concat(lines, "\n"))
        f:close()
        return path
    end

    ---@param child_id string
    ---@param path string
    local function stub_dormant(child_id, path)
        Manifest.load = function()
            return { [child_id] = { name = "Todo Worker", status = "dormant", parent_id = "p-1" } }
        end
        Read.find_path = function(id)
            return id == child_id and path or nil
        end
        Sessions.get_by_id = function()
            return nil
        end
    end

    ---@param buf integer
    ---@param lhs string
    ---@return table?
    local function find_keymap(buf, lhs)
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            if map.lhs == lhs then
                return map
            end
        end
        return nil
    end

    --- Mirror of the panel buffer's padding: one blank line above and below
    --- the content, one blank column on the left (the right side pads with
    --- empty cells).
    ---@param lines string[] content lines
    ---@return string[]
    local function pad_panel(lines)
        local padded = { "" }
        for _, line in ipairs(lines) do
            padded[#padded + 1] = " " .. line
        end
        padded[#padded + 1] = ""
        return padded
    end

    before_each(function()
        tmp_dir = vim.fn.tempname()
        vim.fn.mkdir(tmp_dir, "p")
        orig = {
            manifest_load = Manifest.load,
            find_path = Read.find_path,
            get_by_id = Sessions.get_by_id,
            todo_get = Todo.get,
        }
        Config.setup({})
        Viewer.close()
    end)

    after_each(function()
        Viewer.close()
        Manifest.load = orig.manifest_load
        Read.find_path = orig.find_path
        Sessions.get_by_id = orig.get_by_id
        Todo.get = orig.todo_get
        Config.setup({})
        if tmp_dir and vim.fn.isdirectory(tmp_dir) == 1 then
            vim.fn.delete(tmp_dir, "rf")
        end
    end)

    describe("config defaults", function()
        it("ships the documented subagent.viewer.todo defaults", function()
            Config.setup({})
            local todo = Config.options.subagent.viewer.todo
            assert.is_true(todo.enabled)
            assert.is_false(todo.auto_open)
            assert.equals("below", todo.position)
            assert.equals(0.35, todo.height)
            assert.equals(20, todo.max_items)
        end)
    end)

    describe("footer chunk", function()
        it("renders the three states", function()
            assert.same(
                { "✓ 3/3", "PiTodoDone" },
                Viewer._todo_chunk({
                    todos = { { content = "a", status = "completed" } },
                    completed = 3,
                    total = 3,
                })
            )
            assert.same({ "◐ 1/3", "PiTodoInProgress" }, Viewer._todo_chunk(details_fixture))
            assert.same(
                { "○ 0/3", "PiTodoPending" },
                Viewer._todo_chunk({
                    todos = {
                        { content = "a", status = "pending" },
                        { content = "b", status = "pending" },
                        { content = "c", status = "pending" },
                    },
                    completed = 0,
                    total = 3,
                })
            )
        end)

        it("returns nil without details and for an empty list", function()
            assert.is_nil(Viewer._todo_chunk(nil))
            assert.is_nil(Viewer._todo_chunk({ todos = {}, completed = 0, total = 0 }))
            assert.is_nil(Viewer._todo_chunk({}))
        end)
    end)

    describe("snapshot resolution", function()
        it("reads the pi.todo mirror for a live session", function()
            local session = {
                id = "live-1",
                rpc = {
                    is_running = function()
                        return true
                    end,
                },
            }
            Todo.get = function(s)
                assert.equals(session, s)
                return details_fixture
            end
            assert.same(details_fixture, Viewer._resolve_todo_details(session, nil))
        end)

        it("falls back to entries when the live RPC is not running", function()
            local session = {
                id = "dead-1",
                rpc = {
                    is_running = function()
                        return false
                    end,
                },
            }
            Todo.get = function()
                error("pi.todo.get must not be called without a running RPC")
            end
            local entries = {
                {
                    type = "message",
                    message = {
                        role = "toolResult",
                        toolName = "todo_write",
                        details = details_fixture,
                    },
                },
            }
            assert.same(details_fixture, Viewer._resolve_todo_details(session, entries))
        end)

        it("scans decoded entries for a dormant session", function()
            local entries = {
                { type = "session_info", name = "x" },
                {
                    type = "message",
                    message = { role = "user", content = "hi" },
                },
                {
                    type = "message",
                    message = {
                        role = "toolResult",
                        toolName = "todo_write",
                        details = details_fixture,
                    },
                },
            }
            assert.same(details_fixture, Viewer._resolve_todo_details(nil, entries))
            assert.is_nil(Viewer._resolve_todo_details(nil, nil))
            assert.is_nil(Viewer._resolve_todo_details(nil, {}))
        end)
    end)

    describe("panel lines", function()
        it("falls back to the no-todos placeholder", function()
            assert.same({ "no todos" }, Viewer._todo_panel_lines(nil, 20))
            assert.same({ "no todos" }, Viewer._todo_panel_lines({ todos = {}, completed = 0, total = 0 }, 20))
        end)

        it("renders the list through tool_ui.format_lines with max_items applied", function()
            Config.setup({ title = { lang = "en" } })
            assert.same(
                TodoToolUi.format_lines(details_fixture, { max_items = 20 }),
                Viewer._todo_panel_lines(details_fixture, 20)
            )

            local todos = {}
            for i = 1, 30 do
                todos[i] = { content = "task " .. i, status = "pending" }
            end
            local big = { todos = todos, completed = 0, total = 30 }
            local lines = Viewer._todo_panel_lines(big, 20)
            -- header + 20 items + truncation tail
            assert.equals(22, #lines)
            assert.truthy(lines[#lines]:find("…", 1, true))
            assert.equals("○ task 20", lines[21])
        end)

        it("maps line-leading markers to highlight groups", function()
            assert.equals("PiTodoDone", Viewer._todo_line_hl("✓ done task"))
            assert.equals("PiTodoInProgress", Viewer._todo_line_hl("◐ active task"))
            assert.equals("PiTodoPending", Viewer._todo_line_hl("○ waiting task"))
            assert.is_nil(Viewer._todo_line_hl("1/3 completed"))
            assert.is_nil(Viewer._todo_line_hl("  no todos"))
            assert.is_nil(Viewer._todo_line_hl("… 3 more"))
        end)
    end)

    describe("dormant viewer window", function()
        it("shows the todo chunk in the footer and toggles the panel with T", function()
            local path = write_todo_jsonl("todo_dormant.jsonl")
            stub_dormant("child-todo-1", path)

            Viewer.open("child-todo-1")
            pump(100)
            assert.is_true(Viewer.is_open())
            assert.same(details_fixture, Viewer._todo_details())

            -- Footer: the todo chunk rides after the statusline components
            -- (this fixture has no model/usage status, so the todo chunk IS
            -- the whole footer).
            local cfg = vim.api.nvim_win_get_config(Viewer._win())
            assert.is_table(cfg.footer)
            local footer_text = ""
            for _, chunk in ipairs(cfg.footer) do
                footer_text = footer_text .. chunk[1]
            end
            assert.truthy(footer_text:find("◐ 1/3", 1, true), "footer: " .. footer_text)

            -- T opens the panel without stealing focus.
            local buf = Viewer._history():buf()
            local t_map = find_keymap(buf, "T")
            assert.is_not_nil(t_map)
            local prev_win = vim.api.nvim_get_current_win()
            t_map.callback()

            local panel_win = Viewer._todo_panel_win()
            assert.is_not_nil(panel_win)
            assert.is_true(vim.api.nvim_win_is_valid(panel_win))
            assert.equals(prev_win, vim.api.nvim_get_current_win())
            assert.is_false(Viewer._todo_panel_suppressed())

            local panel_buf = vim.api.nvim_win_get_buf(panel_win)
            local panel_cfg = vim.api.nvim_win_get_config(panel_win)
            local expected = TodoToolUi.format_lines(details_fixture, { max_items = 20 })
            -- the buffer holds the padded lines (1 blank row above/below, 1 space indent)
            assert.same(pad_panel(expected), vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false))
            assert.equals("editor", panel_cfg.relative)
            assert.is_false(panel_cfg.focusable)
            local main_cfg = vim.api.nvim_win_get_config(Viewer._win())
            -- width: widest content line + 2 padding columns, capped at 60% of the viewer
            local content_w = 1
            for _, line in ipairs(expected) do
                content_w = math.max(content_w, vim.fn.strdisplaywidth(line))
            end
            local expected_width = math.min(content_w + 2, math.max(1, math.floor(main_cfg.width * 0.6)))
            assert.equals(expected_width, panel_cfg.width)
            -- horizontally anchored to the viewer's right edge
            assert.equals(main_cfg.col + main_cfg.width - expected_width, panel_cfg.col)
            -- height: content lines + 2 padding rows, capped at 35% (cfg.height) of the viewer
            local expected_height = math.max(1, math.min(#expected + 2, math.floor(main_cfg.height * 0.35)))
            assert.equals(expected_height, panel_cfg.height)
            -- vertically pinned to the viewer's bottom edge (position = "below")
            assert.equals(main_cfg.row + main_cfg.height - expected_height, panel_cfg.row)
            -- marker lines carry the todo highlight
            local marker_hl = vim.api.nvim_buf_get_extmarks(
                panel_buf,
                vim.api.nvim_create_namespace("pi-subsession-viewer-todo"),
                0,
                -1,
                { details = true }
            )
            assert.equals(3, #marker_hl)

            -- T closes the panel and suppresses auto_open until reopened.
            t_map.callback()
            assert.is_nil(Viewer._todo_panel_win())
            assert.is_true(vim.api.nvim_win_is_valid(panel_win) == false)
            assert.is_true(Viewer._todo_panel_suppressed())

            Viewer.close()
            assert.is_false(Viewer.is_open())
        end)

        it("hides the footer chunk and refuses the panel when disabled", function()
            Config.setup({ subagent = { viewer = { todo = { enabled = false } } } })
            local path = write_todo_jsonl("todo_disabled.jsonl")
            stub_dormant("child-todo-2", path)

            Viewer.open("child-todo-2")
            pump(100)
            assert.is_true(Viewer.is_open())
            assert.is_not_nil(Viewer._todo_details())

            -- No status components and the todo chunk is gated off: no footer.
            local cfg = vim.api.nvim_win_get_config(Viewer._win())
            assert.is_nil(cfg.footer)

            local warned = false
            local orig_warn = require("pi.notify").warn
            require("pi.notify").warn = function(msg)
                if tostring(msg):find("Todo display is disabled", 1, true) then
                    warned = true
                end
            end
            local t_map = find_keymap(Viewer._history():buf(), "T")
            assert.is_not_nil(t_map)
            t_map.callback()
            require("pi.notify").warn = orig_warn

            assert.is_true(warned)
            assert.is_nil(Viewer._todo_panel_win())
        end)

        it("keeps the footer unchanged for a session without todos", function()
            local path = tmp_dir .. "/no_todos.jsonl"
            local f = io.open(path, "w")
            assert.is_not_nil(f)
            f:write(vim.json.encode({ type = "message", message = { role = "user", content = "plain" } }))
            f:close()
            stub_dormant("child-todo-3", path)

            Viewer.open("child-todo-3")
            pump(50)
            assert.is_nil(Viewer._todo_details())
            local cfg = vim.api.nvim_win_get_config(Viewer._win())
            assert.is_nil(cfg.footer)

            -- The panel still opens on demand with the placeholder.
            local t_map = find_keymap(Viewer._history():buf(), "T")
            t_map.callback()
            local panel_win = Viewer._todo_panel_win()
            assert.is_not_nil(panel_win)
            assert.same(
                pad_panel({ "no todos" }),
                vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panel_win), 0, -1, false)
            )
        end)
    end)

    describe("live viewer refresh", function()
        ---@param calls table<string, fun(res: table)>
        ---@return table
        local function make_rpc(calls)
            return {
                is_running = function()
                    return true
                end,
                send = function(_, payload, cb)
                    calls[payload.type] = cb
                    return true
                end,
            }
        end

        it("refreshes the footer and auto-opens the panel on the first todo", function()
            Config.setup({ subagent = { viewer = { todo = { auto_open = true } } } })
            local child_id = "child-live-todo"
            local calls = {}
            local mock_session = { id = child_id, rpc = make_rpc(calls) }

            Manifest.load = function()
                return { [child_id] = { name = "Live Todo", status = "active", parent_id = "p-1" } }
            end
            Sessions.get_by_id = function(id)
                return id == child_id and mock_session or nil
            end

            Viewer.open(child_id)
            assert.is_not_nil(calls["get_messages"])
            calls["get_messages"]({ success = true, data = { messages = {} } })
            pump(100)
            assert.is_true(Viewer.is_open())
            assert.is_nil(Viewer._todo_details())
            assert.is_nil(Viewer._todo_panel_win())

            -- The manager routes the todo result into the per-session mirror
            -- before the viewer's scheduled refresh reads it.
            Todo.update_from_details(details_fixture, mock_session)
            pump(50)
            Viewer.on_session_event(mock_session, {
                type = "tool_execution_end",
                toolName = "todo_write",
                toolCallId = "call_t1",
                result = { details = details_fixture },
                isError = false,
            })
            pump(100)

            assert.same(details_fixture, Viewer._todo_details())
            local footer_text = ""
            for _, chunk in ipairs(vim.api.nvim_win_get_config(Viewer._win()).footer) do
                footer_text = footer_text .. chunk[1]
            end
            assert.truthy(footer_text:find("◐ 1/3", 1, true), "footer: " .. footer_text)

            local panel_win = Viewer._todo_panel_win()
            assert.is_not_nil(panel_win)
            assert.is_false(Viewer._todo_panel_suppressed())
            assert.same(
                pad_panel(TodoToolUi.format_lines(details_fixture, { max_items = 20 })),
                vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panel_win), 0, -1, false)
            )

            -- Manual T close suppresses the next auto-open.
            local t_map = find_keymap(Viewer._history():buf(), "T")
            assert.is_not_nil(t_map)
            t_map.callback()
            assert.is_nil(Viewer._todo_panel_win())
            assert.is_true(Viewer._todo_panel_suppressed())

            local next_details = {
                todos = {
                    { content = "done task", status = "completed" },
                    { content = "active task", activeForm = "Doing the work", status = "in_progress" },
                    { content = "waiting task", status = "pending" },
                },
                completed = 2,
                total = 3,
            }
            Todo.update_from_details(next_details, mock_session)
            pump(50)
            Viewer.on_session_event(mock_session, {
                type = "tool_execution_end",
                toolName = "todo_write",
                toolCallId = "call_t2",
                result = { details = next_details },
                isError = false,
            })
            pump(100)
            assert.is_nil(Viewer._todo_panel_win())
            assert.is_true(Viewer._todo_panel_suppressed())

            -- T reopens and clears the suppression.
            t_map.callback()
            assert.is_not_nil(Viewer._todo_panel_win())
            assert.is_false(Viewer._todo_panel_suppressed())
            local reopened_buf = vim.api.nvim_win_get_buf(Viewer._todo_panel_win())
            local reopened_lines = vim.api.nvim_buf_get_lines(reopened_buf, 0, -1, false)
            assert.truthy(table.concat(reopened_lines, "\n"):find("Doing the work", 1, true))

            -- Closing the viewer tears the panel down without re-arming the
            -- suppression.
            local open_panel = Viewer._todo_panel_win()
            Viewer.close()
            assert.is_false(vim.api.nvim_win_is_valid(open_panel))
            assert.is_nil(Viewer._todo_panel_win())
            assert.is_false(Viewer._todo_panel_suppressed())
            assert.is_nil(Viewer._todo_details())
        end)

        it("repaints an open panel in place on subsequent todo events", function()
            Config.setup({ subagent = { viewer = { todo = { auto_open = true } } } })
            local child_id = "child-live-repaint"
            local calls = {}
            local mock_session = { id = child_id, rpc = make_rpc(calls) }

            Manifest.load = function()
                return { [child_id] = { name = "Repaint Worker", status = "active", parent_id = "p-1" } }
            end
            Sessions.get_by_id = function(id)
                return id == child_id and mock_session or nil
            end

            Viewer.open(child_id)
            calls["get_messages"]({ success = true, data = { messages = {} } })
            pump(100)

            -- First todo event opens the panel (auto_open): the mirror is
            -- primed AFTER open so the nil -> non-empty transition happens
            -- on this event, not before it.
            Todo.update_from_details(details_fixture, mock_session)
            pump(50)
            Viewer.on_session_event(mock_session, {
                type = "tool_execution_end",
                toolName = "todo_write",
                toolCallId = "call_t1",
                result = { details = details_fixture },
                isError = false,
            })
            pump(100)
            local panel_win = Viewer._todo_panel_win()
            assert.is_not_nil(panel_win)

            -- ...a later event repaints the SAME window with the new list.
            local grown = {
                todos = {
                    { content = "one", status = "completed" },
                    { content = "two", status = "completed" },
                    { content = "three", activeForm = "Doing three", status = "in_progress" },
                },
                completed = 2,
                total = 3,
            }
            Todo.update_from_details(grown, mock_session)
            pump(50)
            Viewer.on_session_event(mock_session, {
                type = "tool_execution_end",
                toolName = "todo_write",
                toolCallId = "call_t2",
                result = { details = grown },
                isError = false,
            })
            pump(100)

            assert.equals(panel_win, Viewer._todo_panel_win())
            local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panel_win), 0, -1, false)
            assert.truthy(table.concat(lines, "\n"):find("Doing three", 1, true))
            assert.is_nil(table.concat(lines, "\n"):find("Doing the work", 1, true))
        end)
    end)
end)
