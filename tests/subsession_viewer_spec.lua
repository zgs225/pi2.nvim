local Viewer = require("pi.ui.subsession_viewer")
local History = require("pi.ui.chat.history")
local Manifest = require("pi.subsessions.manifest")
local Sessions = require("pi.sessions.manager")
local Read = require("pi.subsessions.read")
local Subsessions = require("pi.subsessions")
local Notify = require("pi.notify")

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
end)
