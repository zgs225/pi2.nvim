local Sessions = require("pi.sessions.manager")
local Extension = require("pi.ui.extension")
local Subsessions = require("pi.subsessions")
local Manifest = require("pi.subsessions.manifest")
local Batch = require("pi.subsessions.batch")
local Reload = require("pi.reload")
local Quickfix = require("pi.quickfix")
local Attention = require("pi.attention")
local Rpc = require("pi.rpc")

describe("subsessions detached protocol handling", function()
    local batch_tmp
    local manifest_tmp
    local real_manifest_path
    local real_spawn

    before_each(function()
        batch_tmp = vim.fn.tempname() .. "-batches.json"
        manifest_tmp = vim.fn.tempname() .. "-manifest.json"
        Batch._set_path(batch_tmp)
        real_manifest_path = Manifest.path
        Manifest.path = function()
            return manifest_tmp
        end
        Manifest._reset()
        Batch._reset()
        real_spawn = Subsessions.spawn
    end)

    after_each(function()
        Subsessions.spawn = real_spawn
        Batch._reset()
        Manifest.path = real_manifest_path
        Manifest._reset()
        pcall(os.remove, batch_tmp)
        pcall(os.remove, manifest_tmp)
    end)

    it(
        "when session.chat == nil, extension_ui_request for __pi_subagent__ is NOT dropped and calls Extension.handle",
        function()
            local real_handle = Extension.handle
            local handled_session = nil
            local handled_msg = nil

            Extension.handle = function(session, msg)
                handled_session = session
                handled_msg = msg
            end

            local session = {
                id = "parent-detached-1",
                chat = nil,
                rpc = {
                    is_running = function()
                        return true
                    end,
                    send = function()
                        return true
                    end,
                },
                changed_files = {},
            }

            local req = {
                type = "extension_ui_request",
                id = "req-1",
                method = "select",
                title = "__pi_subagent__",
                options = { '{"action":"list_subagents"}' },
            }

            local handled = Sessions.handle_event(session, req)
            assert.is_true(handled)

            assert.is_true(
                vim.wait(1000, function()
                    return handled_session ~= nil
                end, 10),
                "timed out waiting for scheduled Extension.handle"
            )

            assert.are.equal(session, handled_session)
            assert.are.equal("req-1", handled_msg.id)
            assert.are.equal("__pi_subagent__", handled_msg.title)

            Extension.handle = real_handle
        end
    )

    it(
        "when session._view_rebuilding == true, __pi_subagent__ is not queued into _view_event_queue but handled immediately",
        function()
            local real_handle = Extension.handle
            local handled_msg = nil

            Extension.handle = function(_session, msg)
                handled_msg = msg
            end

            local session = {
                id = "parent-rebuilding-1",
                chat = nil,
                _view_rebuilding = true,
                _view_event_queue = {},
                rpc = {
                    is_running = function()
                        return true
                    end,
                    send = function()
                        return true
                    end,
                },
                changed_files = {},
            }

            local host_req = {
                type = "extension_ui_request",
                id = "req-fastpath",
                method = "select",
                title = "__pi_subagent__",
                options = { '{"action":"list_subagents"}' },
            }

            local normal_msg = {
                type = "message_start",
                message = { role = "assistant" },
            }

            Sessions.handle_event(session, normal_msg)
            assert.are.equal(1, #session._view_event_queue)
            assert.are.equal("message_start", session._view_event_queue[1].type)

            Sessions.handle_event(session, host_req)
            assert.are.equal(1, #session._view_event_queue, "__pi_subagent__ must not be queued into _view_event_queue")

            assert.is_true(
                vim.wait(1000, function()
                    return handled_msg ~= nil
                end, 10),
                "timed out waiting for immediate Extension.handle"
            )

            assert.are.equal("req-fastpath", handled_msg.id)

            Extension.handle = real_handle
        end
    )

    it(
        "when session.chat == nil, tool_execution_start and tool_execution_end track file changes and call pi.reload.on_file_changed, but do not touch quickfix",
        function()
            local real_reload = Reload.on_file_changed
            local real_qf_start = Quickfix.on_tool_start
            local real_qf_end = Quickfix.on_tool_end

            local reloaded_path = nil
            local qf_start_called = false
            local qf_end_called = false

            Reload.on_file_changed = function(path)
                reloaded_path = path
            end
            Quickfix.on_tool_start = function()
                qf_start_called = true
            end
            Quickfix.on_tool_end = function()
                qf_end_called = true
            end

            local session = {
                id = "detached-tools-session",
                chat = nil,
                changed_files = {},
                rpc = {
                    is_running = function()
                        return true
                    end,
                    send = function()
                        return true
                    end,
                },
            }

            Sessions.handle_event(session, {
                type = "tool_execution_start",
                toolName = "edit",
                toolCallId = "call-edit-99",
                args = vim.json.encode({ path = "lua/pi/example.lua" }),
            })

            assert.is_false(qf_start_called, "quickfix.on_tool_start must not be called when chat is nil")

            Sessions.handle_event(session, {
                type = "tool_execution_end",
                toolName = "edit",
                toolCallId = "call-edit-99",
                result = { success = true },
                isError = false,
            })

            assert.is_false(qf_end_called, "quickfix.on_tool_end must not be called when chat is nil")
            assert.is_true(session.changed_files["lua/pi/example.lua"])

            assert.is_true(
                vim.wait(1000, function()
                    return reloaded_path == "lua/pi/example.lua"
                end, 10),
                "timed out waiting for pi.reload.on_file_changed"
            )

            Reload.on_file_changed = real_reload
            Quickfix.on_tool_start = real_qf_start
            Quickfix.on_tool_end = real_qf_end
        end
    )

    it("detached parent session running batch receives host select and does not hang", function()
        Subsessions.spawn = function(_parent, opts, callback)
            local id = "child-" .. (opts.name or "worker")
            Manifest.upsert(id, {
                parent_id = "parent-batch-1",
                name = opts.name or "worker",
                task_prompt = opts.task,
                config = {},
                status = "active",
                reported = false,
                created_at = Manifest.iso_now(),
                last_active_at = Manifest.iso_now(),
                agent_spawned = true,
                run_generation = 1,
            })
            callback({
                id = id,
                rpc = {
                    is_running = function()
                        return true
                    end,
                },
            }, nil)
        end

        local sent_cmd = nil
        local parent_session = {
            id = "parent-batch-1",
            chat = nil,
            changed_files = {},
            rpc = {
                is_running = function()
                    return true
                end,
                send = function(_self, cmd)
                    sent_cmd = cmd
                    return true
                end,
            },
        }

        Sessions._register_for_test(parent_session)

        local host_req = {
            type = "extension_ui_request",
            id = "batch-select-1",
            method = "select",
            title = "__pi_subagent__",
            options = {
                vim.json.encode({
                    action = "dispatch_subagents",
                    params = {
                        items = { { task = "run task", name = "worker-1" } },
                        wait = true,
                        timeout_ms = 5000,
                    },
                }),
            },
        }

        local handled = Sessions.handle_event(parent_session, host_req)
        assert.is_true(handled)

        vim.wait(1000, function()
            local manifest = Manifest.load()
            return manifest and manifest["child-worker-1"] ~= nil
        end, 10)

        Manifest.patch("child-worker-1", { status = "completed" })
        Batch.on_child_settled("child-worker-1")

        assert.is_true(
            vim.wait(2000, function()
                return sent_cmd ~= nil
            end, 10),
            "parent session hung and failed to send subagent host response"
        )

        assert.are.equal("extension_ui_response", sent_cmd.type)
        assert.are.equal("batch-select-1", sent_cmd.id)
        assert.is_nil(sent_cmd.cancelled)
        assert.is_string(sent_cmd.value)

        local ok, decoded = pcall(vim.json.decode, sent_cmd.value)
        assert.is_true(ok)
        assert.are.equal("completed", decoded.status)
        assert.are.equal(1, decoded.summary.ok)
    end)

    it(
        "when tab is detached, does not call Attention.clear_session if session.rpc:is_running(), but clears when closed",
        function()
            local real_clear = Attention.clear_session
            local real_rpc_start = Rpc.start
            local real_rpc_stop = Rpc.stop
            local real_rpc_send = Rpc.send
            local cleared = {}

            Attention.clear_session = function(sess)
                cleared[#cleared + 1] = sess.id
            end
            Rpc.start = function(self)
                self._job_id = 1
                return true
            end
            Rpc.stop = function(self)
                self._job_id = nil
            end
            Rpc.send = function(self, cmd, cb)
                return true
            end

            vim.cmd("tabnew")
            local session = Sessions.get_or_create()
            assert.is_not_nil(session)
            local session_id = session.id

            vim.cmd("tabclose")
            Sessions.cleanup()

            assert.is_true(session.rpc:is_running())
            assert.is_nil(session.attached_tab)
            assert.is_nil(session.chat)
            assert.is_false(
                vim.tbl_contains(cleared, session_id),
                "Attention.clear_session must not be called when tab is detached while rpc is running"
            )

            Sessions.close_session(session)
            assert.is_true(
                vim.tbl_contains(cleared, session_id),
                "Attention.clear_session must be called when session is closed"
            )

            Attention.clear_session = real_clear
            Rpc.start = real_rpc_start
            Rpc.stop = real_rpc_stop
            Rpc.send = real_rpc_send
        end
    )
end)
