local Viewer = require("pi.ui.subsession_viewer")
local History = require("pi.ui.chat.history")
local Manifest = require("pi.subsessions.manifest")
local Sessions = require("pi.sessions.manager")
local Read = require("pi.subsessions.read")
local Subsessions = require("pi.subsessions")
local Notify = require("pi.notify")
local Config = require("pi.config")

local function pump(ms)
    vim.wait(ms or 50, function()
        return false
    end, 10)
end

describe("pi.ui.subsession_viewer", function()
    local tmp_dir = nil

    before_each(function()
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

    it("reports not open when idle", function()
        assert.is_false(Viewer.is_open())
        assert.is_nil(Viewer.viewed_child_id())
    end)

    it("parses dormant session JSONL entries including session_info and compaction_summary", function()
        local file_path = tmp_dir .. "/session.jsonl"
        local lines = {
            vim.json.encode({ type = "session", sessionId = "sess-123" }),
            vim.json.encode({ type = "session_info", name = "Test Worker Session" }),
            vim.json.encode({ type = "message", message = { role = "user", content = "Hello world" } }),
            vim.json.encode({
                type = "message",
                message = {
                    role = "assistant",
                    content = {
                        { type = "text", text = "Hi there" },
                        {
                            type = "toolCall",
                            toolCallId = "call_1",
                            toolName = "read",
                            arguments = { path = "foo.lua" },
                        },
                    },
                },
            }),
            vim.json.encode({
                type = "message",
                message = { role = "toolResult", toolCallId = "call_1", content = "file content", isError = false },
            }),
            vim.json.encode({
                type = "compaction_summary",
                summary = "Compacted previous context",
                tokensBefore = 4500,
            }),
            "invalid json line that should be ignored",
            "",
        }

        local f = io.open(file_path, "w")
        assert.is_not_nil(f)
        f:write(table.concat(lines, "\n"))
        f:close()

        local msgs, session_name = Viewer._load_messages_from_jsonl(file_path)
        assert.equals("Test Worker Session", session_name)
        assert.equals(4, #msgs)
        assert.equals("user", msgs[1].role)
        assert.equals("Hello world", msgs[1].content)
        assert.equals("assistant", msgs[2].role)
        assert.equals("toolResult", msgs[3].role)
        assert.equals("compactionSummary", msgs[4].role)
        assert.equals("Compacted previous context", msgs[4].summary)
        assert.equals(4500, msgs[4].tokensBefore)
    end)

    it("replays messages into ChatHistory without error", function()
        local h = History.new(-999)
        local messages = {
            { role = "user", content = "Please inspect files" },
            {
                role = "assistant",
                content = {
                    { type = "thinking", thinking = "Thinking step 1" },
                    { type = "text", text = "I will check the directory." },
                    {
                        type = "toolCall",
                        toolCallId = "call_read_1",
                        toolName = "read",
                        arguments = { path = "init.lua" },
                    },
                },
            },
            {
                role = "toolResult",
                toolCallId = "call_read_1",
                toolName = "read",
                content = "return {}",
                isError = false,
            },
            {
                role = "compactionSummary",
                summary = "Compacted 1000 tokens",
                tokensBefore = 1000,
            },
            {
                role = "bashExecution",
                command = "ls -la",
                output = "total 0\n",
                exitCode = 0,
            },
        }

        Viewer._replay(h, messages)
        pump(100)

        local buf = h:buf()
        local line_count = vim.api.nvim_buf_line_count(buf)
        assert.is_true(line_count > 1)

        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("Please inspect files", 1, true))
        assert.is_truthy(text:find("I will check the directory.", 1, true))
        assert.is_truthy(text:find("ls -la", 1, true))

        h:clear()
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    it("opens dormant subsession in a centered float with expected title, options, and keymaps", function()
        local child_id = "child-dormant-1"
        local file_path = tmp_dir .. "/dormant.jsonl"
        local lines = {
            vim.json.encode({ type = "message", message = { role = "user", content = "Task prompt" } }),
            vim.json.encode({ type = "message", message = { role = "assistant", content = "Completed task" } }),
        }
        local f = io.open(file_path, "w")
        assert.is_not_nil(f)
        f:write(table.concat(lines, "\n"))
        f:close()

        local orig_load = Manifest.load
        local orig_find_path = Read.find_path
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return {
                [child_id] = {
                    name = "Worker Alpha",
                    status = "dormant",
                    task_prompt = "Task prompt",
                    parent_id = "p-1",
                    config = { model = { provider = "anthropic", id = "claude-3-5-sonnet" } },
                    reported = true,
                    created_at = "now",
                    last_active_at = "now",
                },
            }
        end
        Read.find_path = function(id)
            if id == child_id then
                return file_path
            end
            return nil
        end
        Sessions.get_by_id = function()
            return nil
        end

        local closed_called = false
        Viewer.open(child_id, {
            on_close = function()
                closed_called = true
            end,
        })

        Manifest.load = orig_load
        Read.find_path = orig_find_path
        Sessions.get_by_id = orig_get_by_id

        assert.is_true(Viewer.is_open())
        assert.equals(child_id, Viewer.viewed_child_id())

        local win = Viewer._win()
        assert.is_not_nil(win)
        assert.is_true(vim.api.nvim_win_is_valid(win))

        local cfg = vim.api.nvim_win_get_config(win)
        assert.is_table(cfg.border)
        assert.equals("╭", cfg.border[1])
        assert.equals(" Worker Alpha [dormant] ", cfg.title[1][1])
        local expected_w = math.max(20, math.min(vim.o.columns - 4, math.floor(vim.o.columns * 0.7)))
        local expected_h = math.max(
            5,
            math.min(vim.o.lines - vim.o.cmdheight - 3, math.floor((vim.o.lines - vim.o.cmdheight - 1) * 0.75))
        )
        assert.equals(expected_w, cfg.width)
        assert.equals(expected_h, cfg.height)

        -- Window options
        assert.is_true(vim.wo[win].wrap)
        assert.is_false(vim.wo[win].number)
        assert.is_false(vim.wo[win].relativenumber)
        assert.equals("no", vim.wo[win].signcolumn)
        assert.is_false(vim.wo[win].foldenable)

        local history = Viewer._history()
        assert.is_not_nil(history)
        local buf = history:buf()
        assert.equals("pi-chat-history", vim.bo[buf].filetype)
        assert.equals("nofile", vim.bo[buf].buftype)

        pump(100)
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("Task prompt", 1, true))
        assert.is_truthy(text:find("Completed task", 1, true))

        -- Close
        Viewer.close()
        assert.is_false(Viewer.is_open())
        assert.is_nil(Viewer.viewed_child_id())
        assert.is_false(vim.api.nvim_win_is_valid(win))
        assert.is_false(vim.api.nvim_buf_is_valid(buf))
        assert.is_true(closed_called)
    end)

    it("respects custom width, height, and border from subagent.viewer config and opts", function()
        local child_id = "child-dim-1"
        local file_path = tmp_dir .. "/dim.jsonl"
        local f = io.open(file_path, "w")
        assert.is_not_nil(f)
        f:write(vim.json.encode({ type = "message", message = { role = "user", content = "dim test" } }))
        f:close()

        local orig_load = Manifest.load
        local orig_find_path = Read.find_path
        Manifest.load = function()
            return {
                [child_id] = {
                    name = "Dim Worker",
                    status = "dormant",
                    task_prompt = "dim test",
                    parent_id = "p-1",
                    config = { model = { provider = "anthropic", id = "claude-3-5-sonnet" } },
                    reported = true,
                    created_at = "now",
                    last_active_at = "now",
                },
            }
        end
        Read.find_path = function()
            return file_path
        end

        -- 1. Test via config options
        Config.setup({
            subagent = {
                viewer = {
                    width = 60,
                    height = 20,
                    border = "single",
                },
            },
        })

        Viewer.open(child_id)
        assert.is_true(Viewer.is_open())
        local win = Viewer._win()
        local win_cfg = vim.api.nvim_win_get_config(win)
        assert.equals(60, win_cfg.width)
        assert.equals(20, win_cfg.height)
        assert.equals("┌", win_cfg.border[1])
        Viewer.close()

        -- 2. Test via opts override
        Viewer.open(child_id, {
            width = 45,
            height = 15,
            border = "double",
        })
        assert.is_true(Viewer.is_open())
        win = Viewer._win()
        win_cfg = vim.api.nvim_win_get_config(win)
        assert.equals(45, win_cfg.width)
        assert.equals(15, win_cfg.height)
        assert.equals("╔", win_cfg.border[1])
        Viewer.close()

        Manifest.load = orig_load
        Read.find_path = orig_find_path
        Config.setup({})
    end)

    it("promotes on <CR> keymap", function()
        local child_id = "child-promote-1"
        local file_path = tmp_dir .. "/promote.jsonl"
        local f = io.open(file_path, "w")
        assert.is_not_nil(f)
        f:write(vim.json.encode({ type = "message", message = { role = "user", content = "hi" } }))
        f:close()

        local orig_load = Manifest.load
        local orig_find_path = Read.find_path
        local orig_switch_to = Subsessions.switch_to

        local switched_child = nil
        Manifest.load = function()
            return {
                [child_id] = {
                    name = "Worker Beta",
                    status = "dormant",
                    task_prompt = "hi",
                    parent_id = "p-1",
                    config = { model = { provider = "anthropic", id = "claude-3-5-sonnet" } },
                    reported = true,
                    created_at = "now",
                    last_active_at = "now",
                },
            }
        end
        Read.find_path = function()
            return file_path
        end
        Subsessions.switch_to = function(target, cb)
            switched_child = target
            if cb then
                cb(true)
            end
        end

        Viewer.open(child_id)
        assert.is_true(Viewer.is_open())

        local history = Viewer._history()
        local buf = history:buf()

        -- Trigger <CR> keymap on buffer
        local keymaps = vim.api.nvim_buf_get_keymap(buf, "n")
        local cr_map = nil
        for _, m in ipairs(keymaps) do
            if m.lhs == "<CR>" then
                cr_map = m
                break
            end
        end
        assert.is_not_nil(cr_map)
        cr_map.callback()

        Manifest.load = orig_load
        Read.find_path = orig_find_path
        Subsessions.switch_to = orig_switch_to

        assert.equals(child_id, switched_child)
        assert.is_false(Viewer.is_open())
    end)

    it("warns and returns when dormant session file is not found", function()
        local orig_load = Manifest.load
        local orig_find_path = Read.find_path
        local orig_get_by_id = Sessions.get_by_id
        local orig_warn = Notify.warn

        local warned = false
        Manifest.load = function()
            return {}
        end
        Read.find_path = function()
            return nil
        end
        Sessions.get_by_id = function()
            return nil
        end
        Notify.warn = function(msg)
            if msg:find("Sub-session file not found", 1, true) then
                warned = true
            end
        end

        Viewer.open("nonexistent-child")

        Manifest.load = orig_load
        Read.find_path = orig_find_path
        Sessions.get_by_id = orig_get_by_id
        Notify.warn = orig_warn

        assert.is_true(warned)
        assert.is_false(Viewer.is_open())
    end)

    it("opens live session and queries RPC get_messages", function()
        local child_id = "child-live-1"

        local rpc_sent = false
        local rpc_cb = nil
        local mock_session = {
            id = child_id,
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(self, payload, cb)
                    if payload.type == "get_messages" then
                        rpc_sent = true
                        rpc_cb = cb
                        return true
                    end
                    return false
                end,
            },
        }

        local orig_load = Manifest.load
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return {
                [child_id] = {
                    name = "Live Worker",
                    status = "active",
                    task_prompt = "run live",
                    parent_id = "p-1",
                    config = { model = { provider = "anthropic", id = "claude-3-5-sonnet" } },
                    reported = false,
                    created_at = "now",
                    last_active_at = "now",
                },
            }
        end
        Sessions.get_by_id = function(id)
            if id == child_id then
                return mock_session
            end
            return nil
        end

        Viewer.open(child_id)

        Manifest.load = orig_load
        Sessions.get_by_id = orig_get_by_id

        assert.is_true(Viewer.is_open())
        assert.is_true(rpc_sent)
        assert.is_not_nil(rpc_cb)

        -- Deliver response
        rpc_cb({
            success = true,
            data = {
                messages = {
                    { role = "user", content = "Live input prompt" },
                    { role = "assistant", content = "Live output response" },
                },
            },
        })

        pump(100)

        local history = Viewer._history()
        local buf = history:buf()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("Live input prompt", 1, true))
        assert.is_truthy(text:find("Live output response", 1, true))

        Viewer.close()
        assert.is_false(Viewer.is_open())
    end)

    it("re-opening closes previous viewer without leaking buffers or windows", function()
        local file_1 = tmp_dir .. "/s1.jsonl"
        local file_2 = tmp_dir .. "/s2.jsonl"
        local f1 = io.open(file_1, "w")
        assert.is_not_nil(f1)
        f1:write(vim.json.encode({ type = "message", message = { role = "user", content = "s1 text" } }))
        f1:close()
        local f2 = io.open(file_2, "w")
        assert.is_not_nil(f2)
        f2:write(vim.json.encode({ type = "message", message = { role = "user", content = "s2 text" } }))
        f2:close()

        local orig_load = Manifest.load
        local orig_find_path = Read.find_path
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return {
                ["child-1"] = { name = "Child 1", status = "dormant" },
                ["child-2"] = { name = "Child 2", status = "dormant" },
            }
        end
        Read.find_path = function(id)
            return id == "child-1" and file_1 or file_2
        end
        Sessions.get_by_id = function()
            return nil
        end

        Viewer.open("child-1")
        local win1 = Viewer._win()
        local buf1 = Viewer._history():buf()
        assert.equals("child-1", Viewer.viewed_child_id())

        Viewer.open("child-2")
        local win2 = Viewer._win()
        local buf2 = Viewer._history():buf()
        assert.equals("child-2", Viewer.viewed_child_id())

        Manifest.load = orig_load
        Read.find_path = orig_find_path
        Sessions.get_by_id = orig_get_by_id

        assert.is_not_equal(win1, win2)
        assert.is_false(vim.api.nvim_win_is_valid(win1))
        assert.is_false(vim.api.nvim_buf_is_valid(buf1))
        assert.is_true(vim.api.nvim_win_is_valid(win2))
        assert.is_true(vim.api.nvim_buf_is_valid(buf2))

        Viewer.close()
    end)

    it("handles q and Esc to close the viewer", function()
        local file_path = tmp_dir .. "/keys.jsonl"
        local f = io.open(file_path, "w")
        assert.is_not_nil(f)
        f:write(vim.json.encode({ type = "message", message = { role = "user", content = "hello" } }))
        f:close()

        local orig_load = Manifest.load
        local orig_find_path = Read.find_path
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return { ["c-keys"] = { name = "Worker Keys", status = "dormant" } }
        end
        Read.find_path = function()
            return file_path
        end
        Sessions.get_by_id = function()
            return nil
        end

        Viewer.open("c-keys")
        assert.is_true(Viewer.is_open())
        local buf = Viewer._history():buf()

        local keymaps = vim.api.nvim_buf_get_keymap(buf, "n")
        local q_map = nil
        local esc_map = nil
        for _, m in ipairs(keymaps) do
            if m.lhs == "q" then
                q_map = m
            elseif m.lhs == "<Esc>" then
                esc_map = m
            end
        end
        assert.is_not_nil(q_map)
        assert.is_not_nil(esc_map)

        q_map.callback()
        assert.is_false(Viewer.is_open())

        -- Reopen to test Esc
        Viewer.open("c-keys")
        assert.is_true(Viewer.is_open())
        esc_map.callback()
        assert.is_false(Viewer.is_open())

        Manifest.load = orig_load
        Read.find_path = orig_find_path
        Sessions.get_by_id = orig_get_by_id
    end)

    it("ignores RPC response if viewer was closed before response arrives", function()
        local child_id = "child-race"
        local rpc_cb = nil
        local mock_session = {
            id = child_id,
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(self, payload, cb)
                    rpc_cb = cb
                    return true
                end,
            },
        }

        local orig_load = Manifest.load
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return { [child_id] = { name = "Live Race", status = "active" } }
        end
        Sessions.get_by_id = function()
            return mock_session
        end

        Viewer.open(child_id)
        assert.is_true(Viewer.is_open())
        assert.is_not_nil(rpc_cb)

        -- Close before RPC completes
        Viewer.close()
        assert.is_false(Viewer.is_open())

        -- Deliver response after close - should not throw
        rpc_cb({
            success = true,
            data = { messages = { { role = "user", content = "late message" } } },
        })
        pump(50)

        Manifest.load = orig_load
        Sessions.get_by_id = orig_get_by_id
    end)

    it("updates buffer on live streaming events", function()
        local child_id = "child-stream-1"
        local rpc_cb = nil
        local mock_session = {
            id = child_id,
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(self, payload, cb)
                    if payload.type == "get_messages" then
                        rpc_cb = cb
                        return true
                    end
                    return false
                end,
            },
        }

        local orig_load = Manifest.load
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return { [child_id] = { name = "Stream Worker", status = "active" } }
        end
        Sessions.get_by_id = function(id)
            if id == child_id then
                return mock_session
            end
            return nil
        end

        Viewer.open(child_id)
        assert.is_true(Viewer.is_open())
        assert.is_not_nil(rpc_cb)

        -- Initial load finishes
        rpc_cb({
            success = true,
            data = { messages = { { role = "user", content = "Initial prompt" } } },
        })
        pump(100)

        -- Stream events arrive
        Viewer.on_session_event(mock_session, { type = "agent_start" })
        Viewer.on_session_event(mock_session, {
            type = "message_update",
            assistantMessageEvent = { type = "thinking_start" },
        })
        Viewer.on_session_event(mock_session, {
            type = "message_update",
            assistantMessageEvent = { type = "thinking_delta", delta = "Thinking deeply..." },
        })
        Viewer.on_session_event(mock_session, {
            type = "message_update",
            assistantMessageEvent = { type = "thinking_end" },
        })
        Viewer.on_session_event(mock_session, {
            type = "message_update",
            assistantMessageEvent = { type = "text_delta", delta = "I found the answer." },
        })
        Viewer.on_session_event(mock_session, {
            type = "tool_execution_start",
            toolName = "read",
            toolCallId = "call_99",
            args = { path = "foo.lua" },
        })
        Viewer.on_session_event(mock_session, {
            type = "tool_execution_end",
            toolName = "read",
            toolCallId = "call_99",
            result = "file content",
            isError = false,
        })
        Viewer.on_session_event(mock_session, { type = "agent_end" })
        pump(150)

        local buf = Viewer._history():buf()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("Initial prompt", 1, true))
        assert.is_truthy(text:find("I found the answer.", 1, true))
        assert.is_truthy(text:find("foo.lua", 1, true))

        Viewer.close()
        Manifest.load = orig_load
        Sessions.get_by_id = orig_get_by_id
    end)

    it("buffers events arriving during get_messages loading and flushes them in order", function()
        local child_id = "child-buffer-1"
        local rpc_cb = nil
        local mock_session = {
            id = child_id,
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(self, payload, cb)
                    if payload.type == "get_messages" then
                        rpc_cb = cb
                        return true
                    end
                    return false
                end,
            },
        }

        local orig_load = Manifest.load
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return { [child_id] = { name = "Buffer Worker", status = "active" } }
        end
        Sessions.get_by_id = function(id)
            if id == child_id then
                return mock_session
            end
            return nil
        end

        Viewer.open(child_id)
        assert.is_true(Viewer.is_open())
        assert.is_true(Viewer._loading())

        -- Arrive while loading
        Viewer.on_session_event(mock_session, {
            type = "message_update",
            assistantMessageEvent = { type = "text_delta", delta = "first queued chunk" },
        })
        Viewer.on_session_event(mock_session, {
            type = "message_update",
            assistantMessageEvent = { type = "text_delta", delta = " second queued chunk" },
        })

        local queue = Viewer._event_queue()
        assert.is_not_nil(queue)
        assert.equals(2, #queue)

        -- Deliver response
        rpc_cb({
            success = true,
            data = { messages = { { role = "user", content = "Queued base prompt" } } },
        })
        pump(100)

        assert.is_false(Viewer._loading())
        assert.is_nil(Viewer._event_queue())

        local buf = Viewer._history():buf()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("Queued base prompt", 1, true))
        assert.is_truthy(text:find("first queued chunk second queued chunk", 1, true))

        Viewer.close()
        Manifest.load = orig_load
        Sessions.get_by_id = orig_get_by_id
    end)

    it("updates window title when agent_start or agent_end arrives", function()
        local child_id = "child-title-1"
        local rpc_cb = nil
        local mock_session = {
            id = child_id,
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(self, payload, cb)
                    if payload.type == "get_messages" then
                        rpc_cb = cb
                        return true
                    end
                    return false
                end,
            },
        }

        local orig_load = Manifest.load
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return { [child_id] = { name = "Title Worker", status = "idle" } }
        end
        Sessions.get_by_id = function(id)
            if id == child_id then
                return mock_session
            end
            return nil
        end

        Viewer.open(child_id)
        rpc_cb({ success = true, data = { messages = {} } })
        pump(100)

        local win = Viewer._win()
        local cfg = vim.api.nvim_win_get_config(win)
        assert.equals(" Title Worker [idle] ", cfg.title[1][1])

        -- agent_start
        Viewer.on_session_event(mock_session, { type = "agent_start" })
        pump(100)
        cfg = vim.api.nvim_win_get_config(win)
        assert.equals(" Title Worker [active] ", cfg.title[1][1])

        -- agent_end
        Viewer.on_session_event(mock_session, { type = "agent_end" })
        pump(100)
        cfg = vim.api.nvim_win_get_config(win)
        assert.equals(" Title Worker [completed] ", cfg.title[1][1])

        Viewer.close()
        Manifest.load = orig_load
        Sessions.get_by_id = orig_get_by_id
    end)

    it("ignores events for a different session id or after viewer is closed", function()
        local child_id = "child-target-1"
        local other_id = "child-other-2"
        local rpc_cb = nil
        local mock_session = {
            id = child_id,
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(self, payload, cb)
                    if payload.type == "get_messages" then
                        rpc_cb = cb
                        return true
                    end
                    return false
                end,
            },
        }
        local other_session = {
            id = other_id,
            rpc = {
                is_running = function()
                    return true
                end,
                send = function()
                    return true
                end,
            },
        }

        local orig_load = Manifest.load
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return { [child_id] = { name = "Target Worker", status = "active" } }
        end
        Sessions.get_by_id = function(id)
            if id == child_id then
                return mock_session
            end
            return nil
        end

        Viewer.open(child_id)
        rpc_cb({
            success = true,
            data = { messages = { { role = "user", content = "Target only" } } },
        })
        pump(100)

        -- Event for different session should be ignored
        Viewer.on_session_event(other_session, {
            type = "message_update",
            assistantMessageEvent = { type = "text_delta", delta = "UNWANTED_OTHER" },
        })
        pump(100)

        local buf = Viewer._history():buf()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        assert.is_nil(text:find("UNWANTED_OTHER", 1, true))

        -- Close viewer and send event for target session
        Viewer.close()
        Viewer.on_session_event(mock_session, {
            type = "message_update",
            assistantMessageEvent = { type = "text_delta", delta = "UNWANTED_CLOSED" },
        })
        pump(100)

        assert.is_false(Viewer.is_open())
        assert.is_false(Viewer.is_open_for(child_id))

        Manifest.load = orig_load
        Sessions.get_by_id = orig_get_by_id
    end)

    it("Sessions.handle_event forwards live events to subsession viewer", function()
        local child_id = "child-fwd-1"
        local rpc_cb = nil
        local mock_session = {
            id = child_id,
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(self, payload, cb)
                    if payload.type == "get_messages" then
                        rpc_cb = cb
                        return true
                    end
                    return false
                end,
            },
        }

        local orig_load = Manifest.load
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return { [child_id] = { name = "Forward Worker", status = "active" } }
        end
        Sessions.get_by_id = function(id)
            if id == child_id then
                return mock_session
            end
            return nil
        end

        Viewer.open(child_id)
        rpc_cb({
            success = true,
            data = { messages = { { role = "user", content = "Start forward test" } } },
        })
        pump(100)

        -- Dispatch through Sessions.handle_event
        Sessions.handle_event(mock_session, {
            type = "message_update",
            assistantMessageEvent = { type = "text_delta", delta = "forwarded stream text" },
        })
        pump(100)

        local buf = Viewer._history():buf()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("forwarded stream text", 1, true))

        Viewer.close()
        Manifest.load = orig_load
        Sessions.get_by_id = orig_get_by_id
    end)

    it("handles live user message_start and aborted message_end", function()
        local child_id = "child-user-msg-1"
        local rpc_cb = nil
        local mock_session = {
            id = child_id,
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(self, payload, cb)
                    if payload.type == "get_messages" then
                        rpc_cb = cb
                        return true
                    end
                    return false
                end,
            },
        }

        local orig_load = Manifest.load
        local orig_get_by_id = Sessions.get_by_id

        Manifest.load = function()
            return { [child_id] = { name = "User Msg Worker", status = "active" } }
        end
        Sessions.get_by_id = function(id)
            if id == child_id then
                return mock_session
            end
            return nil
        end

        Viewer.open(child_id)
        rpc_cb({ success = true, data = { messages = {} } })
        pump(100)

        -- Live user message arrives
        Viewer.on_session_event(mock_session, {
            type = "message_start",
            message = { role = "user", content = "Subsequent user instruction" },
        })
        pump(100)

        -- Tool starts then gets aborted
        Viewer.on_session_event(mock_session, {
            type = "tool_execution_start",
            toolName = "bash",
            toolCallId = "call_abort_1",
            args = { command = "sleep 10" },
        })
        Viewer.on_session_event(mock_session, {
            type = "message_end",
            message = { role = "assistant", stopReason = "aborted" },
        })
        pump(100)

        local buf = Viewer._history():buf()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("Subsequent user instruction", 1, true))
        assert.is_truthy(text:find("sleep 10", 1, true))

        Viewer.close()
        Manifest.load = orig_load
        Sessions.get_by_id = orig_get_by_id
    end)
end)
