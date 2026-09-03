local Extension = require("pi.ui.extension")
local Config = require("pi.config")
local Subsessions = require("pi.subsessions")

describe("Extension.handle with session.chat == nil (detached session)", function()
    it("setStatus does not error when session.chat == nil", function()
        local session = { chat = nil }

        assert.has_no.errors(function()
            Extension.handle(session, {
                method = "setStatus",
                statusKey = "provider-status",
                statusText = "indexing repository...",
            })
        end)

        assert.has_no.errors(function()
            Extension.handle(session, {
                method = "setStatus",
                statusKey = "pi-title",
                statusText = "generating title...",
            })
        end)

        assert.has_no.errors(function()
            Extension.handle(session, {
                method = "setStatus",
                statusKey = "provider-status",
                statusText = nil,
            })
        end)
    end)

    it("setWidget does not error when session.chat == nil and still updates session.startup_announcements", function()
        local session = {
            chat = nil,
            startup_announcements = {},
            system_errors = {},
        }

        -- Adding startup announcement
        assert.has_no.errors(function()
            Extension.handle(session, {
                method = "setWidget",
                widgetKey = "custom-extension:startup",
                widgetLines = { "Preamble line 1", "Preamble line 2" },
            })
        end)
        assert.same(
            { lines = { "Preamble line 1", "Preamble line 2" } },
            session.startup_announcements["custom-extension:startup"]
        )

        -- Clearing startup announcement
        assert.has_no.errors(function()
            Extension.handle(session, {
                method = "setWidget",
                widgetKey = "custom-extension:startup",
                widgetLines = {},
            })
        end)
        assert.is_nil(session.startup_announcements["custom-extension:startup"])

        -- Non-startup widget when on_widget returns a custom block
        local orig_on_widget = Config.options.on_widget
        Config.options.on_widget = function(_key, lines, _placement)
            return { target = "history", block = "custom", lines = lines }
        end

        assert.has_no.errors(function()
            Extension.handle(session, {
                method = "setWidget",
                widgetKey = "custom-extension:sidebar",
                widgetLines = { "Widget line" },
            })
        end)

        Config.options.on_widget = orig_on_widget
    end)

    it("notify does not error when session.chat == nil", function()
        local session = { chat = nil }

        assert.has_no.errors(function()
            Extension.handle(session, {
                method = "notify",
                notifyType = "info",
                message = "Information notice",
            })
            Extension.handle(session, {
                method = "notify",
                notifyType = "warning",
                message = "Warning notice",
            })
            Extension.handle(session, {
                method = "notify",
                notifyType = "error",
                message = "Standard error notice",
            })
            -- Vision failure notification (falls back cleanly instead of calling chat:_on_vision_failure)
            Extension.handle(session, {
                method = "notify",
                notifyType = "error",
                message = "[pi-vision] vision model failed to process image",
            })
        end)
    end)

    it(
        "__pi_subagent__ select successfully invokes host handler and sends response when session.chat == nil",
        function()
            local orig_handle_host = Subsessions.handle_host
            local host_called = false
            local host_parent = nil
            local host_payload = nil

            Subsessions.handle_host = function(parent, payload, on_done)
                host_called = true
                host_parent = parent
                host_payload = payload
                on_done({ status = "completed", output = "subagent finished" })
            end

            local sent_cmd = nil
            local session = {
                chat = nil,
                rpc = {
                    send = function(_self, cmd)
                        sent_cmd = cmd
                        return true
                    end,
                },
            }

            local req_payload = vim.json.encode({ action = "stop_subagents", params = { targets = { "sub-1" } } })
            Extension.handle(session, {
                method = "select",
                id = "subagent-select-req-1",
                title = "__pi_subagent__",
                options = { req_payload },
            })

            assert.is_true(
                vim.wait(1000, function()
                    return sent_cmd ~= nil
                end, 10),
                "timed out waiting for scheduled subagent host response"
            )

            assert.is_true(host_called)
            assert.equals(session, host_parent)
            assert.equals(req_payload, host_payload)
            assert.equals("extension_ui_response", sent_cmd.type)
            assert.equals("subagent-select-req-1", sent_cmd.id)
            assert.is_nil(sent_cmd.cancelled)
            local decoded = vim.json.decode(sent_cmd.value)
            assert.equals("completed", decoded.status)
            assert.equals("subagent finished", decoded.output)

            Subsessions.handle_host = orig_handle_host
        end
    )
end)
