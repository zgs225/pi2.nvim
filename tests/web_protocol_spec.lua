-- Protocol version negotiation: every record carries `v` (protocol §1), and a
-- mismatch is permanent — the daemon's wire version is a property of the
-- installed binary, so the bridge reports once and stops instead of retrying.
--
-- No socket is involved: `_dispatch` is driven directly with decoded records,
-- which is exactly what `_drain` hands it after `Protocol.decode`.

local Bridge = require("pi.web.bridge")
local Protocol = require("pi.web.protocol")

describe("pi.web.protocol.is_compatible", function()
    it("accepts this plugin's version", function()
        assert.is_true(Protocol.is_compatible(Protocol.VERSION))
        assert.is_true(Protocol.is_compatible(tostring(Protocol.VERSION)))
    end)

    it("tolerates a producer that omitted the field", function()
        assert.is_true(Protocol.is_compatible(nil))
    end)

    it("rejects any other version, including garbage", function()
        assert.is_false(Protocol.is_compatible(Protocol.VERSION + 1))
        assert.is_false(Protocol.is_compatible(0))
        assert.is_false(Protocol.is_compatible("nope"))
        assert.is_false(Protocol.is_compatible({}))
    end)

    it("explains the mismatch with both versions and the upgrade command", function()
        local message = Protocol.mismatch_message(2)
        assert.is_truthy(message:find("v2", 1, true))
        assert.is_truthy(message:find("v" .. tostring(Protocol.VERSION), 1, true))
        assert.is_truthy(message:find("npm i -g @yuez/pi2d", 1, true))
        assert.is_nil(message:find("\n", 1, true), "the notify must stay one line")
    end)
end)

describe("pi.web.bridge protocol mismatch", function()
    local function new_bridge(opts)
        return Bridge.new(vim.tbl_deep_extend("force", {
            workspace_id = "ws-1",
            cwd = "/repo",
            plugin_version = "1.0.0",
            has_ui = true,
            backoff_initial = 20,
            backoff_max = 60,
        }, opts or {}))
    end

    it("stops itself and reports once when the daemon speaks another version", function()
        local fatal, ready = {}, {}
        local bridge = new_bridge({
            on_fatal = function(message)
                fatal[#fatal + 1] = message
            end,
            on_ready = function()
                ready[#ready + 1] = true
            end,
        })

        bridge:_dispatch({ v = Protocol.VERSION + 1, type = "hello_ack", daemonId = "d-1" })

        assert.equals(1, #fatal)
        assert.is_truthy(fatal[1]:find("protocol", 1, true))
        assert.equals(0, #ready, "a mismatched hello_ack must not mark the bridge ready")
        assert.is_true(bridge._stopped)
        assert.is_truthy(bridge:status().fatal)
        assert.is_false(bridge:status().started)

        -- Idempotent: further records on the same (dead) connection say nothing.
        bridge:_dispatch({ v = Protocol.VERSION + 1, type = "ping" })
        assert.equals(1, #fatal)
    end)

    it("accepts this plugin's version and marks the bridge ready", function()
        local fatal, ready = {}, {}
        local bridge = new_bridge({
            on_fatal = function(message)
                fatal[#fatal + 1] = message
            end,
            on_ready = function(limits)
                ready[#ready + 1] = limits
            end,
        })

        bridge:_dispatch({
            v = Protocol.VERSION,
            type = "hello_ack",
            daemonId = "d-1",
            limits = { maxFrameBytes = 4096 },
        })

        assert.equals(0, #fatal)
        assert.equals(1, #ready)
        assert.equals(4096, ready[1].maxFrameBytes)
        assert.is_false(bridge._stopped)
        assert.is_nil(bridge:status().fatal)
        bridge:stop()
    end)

    it("tolerates a record without a version field", function()
        local fatal, ready = {}, {}
        local bridge = new_bridge({
            on_fatal = function(message)
                fatal[#fatal + 1] = message
            end,
            on_ready = function()
                ready[#ready + 1] = true
            end,
        })

        bridge:_dispatch({ type = "hello_ack", daemonId = "d-1" })

        assert.equals(0, #fatal)
        assert.equals(1, #ready)
        bridge:stop()
    end)
end)
