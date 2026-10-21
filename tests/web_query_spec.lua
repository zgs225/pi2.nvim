-- Read-only web queries answered by the plugin: attention inbox + models.
-- These back `GET /api/v1/attention` and `GET /api/v1/models` in the daemon.

local Commands = require("pi.web.commands")
local Protocol = require("pi.web.protocol")

--- @param sessions table[]
--- @return table
local function stub_manager(sessions)
    local by_id = {}
    for _, session in ipairs(sessions) do
        if session.id then
            by_id[session.id] = session
        end
    end
    return {
        list_all = function()
            return sessions
        end,
        get_by_id = function(id)
            return by_id[id]
        end,
    }
end

describe("web workspace.query", function()
    local original

    before_each(function()
        original = package.loaded["pi.sessions.manager"]
        -- The models cache is module state shared with `session.setModel`;
        -- reset it so every test starts from the "not fetched yet" state.
        Commands._reset_caches()
    end)

    after_each(function()
        package.loaded["pi.sessions.manager"] = original
        Commands._reset_caches()
    end)

    it("lists pending attention across live sessions", function()
        package.loaded["pi.sessions.manager"] = stub_manager({
            {
                id = "s1",
                attention = {
                    pending = {
                        {
                            id = "att-1",
                            kind = "select",
                            created_at = 1000,
                            expires_at = 61000,
                            msg = {
                                title = "Pick one",
                                message = "Apply diff?",
                                options = { { id = "a", label = "Accept" } },
                                timeout = 60000,
                            },
                        },
                    },
                },
            },
            { id = "s2", attention = { pending = {} } },
        })

        local ok, res = Commands.handlers["workspace.query"]({ kind = "attention" }, {})
        assert.is_true(ok)
        assert.equals(1, #res.attention)
        assert.same({
            requestId = "att-1",
            sessionId = "s1",
            method = "select",
            title = "Pick one",
            message = "Apply diff?",
            options = { { id = "a", label = "Accept" } },
            timeoutSec = 60,
            expiresAt = 61000,
            createdAt = 1000,
        }, res.attention[1])
    end)

    it("returns an empty attention list when nothing is pending", function()
        package.loaded["pi.sessions.manager"] = stub_manager({ { id = "s1" } })
        local ok, res = Commands.handlers["workspace.query"]({ kind = "attention" }, {})
        assert.is_true(ok)
        assert.same({}, res.attention)
    end)

    it("groups available models by provider (fetch is deferred by one schedule)", function()
        local sent = false
        package.loaded["pi.sessions.manager"] = stub_manager({
            {
                id = "s1",
                rpc = {
                    is_running = function()
                        return true
                    end,
                    send = function(_, cmd, callback)
                        sent = true
                        assert.equals("get_available_models", cmd.type)
                        callback({
                            success = true,
                            data = {
                                models = {
                                    {
                                        provider = "anthropic",
                                        id = "claude-x",
                                        contextWindow = 200000,
                                        reasoning = true,
                                    },
                                    { provider = "anthropic", id = "claude-y", contextWindow = 100000 },
                                    { provider = "openai", id = "gpt-z", contextWindow = 128000 },
                                },
                            },
                        })
                    end,
                },
            },
        })

        local ok, first = Commands.handlers["workspace.query"]({ kind = "models" }, {})
        assert.is_true(ok)
        assert.is_true(sent)
        assert.is_true(first.pending)
        assert.same({}, first.providers)

        vim.wait(1000, function()
            local _, res = Commands.handlers["workspace.query"]({ kind = "models" }, {})
            return res.pending == false
        end)

        local _, second = Commands.handlers["workspace.query"]({ kind = "models" }, {})
        assert.is_false(second.pending)
        assert.equals(2, #second.providers)
        assert.equals("anthropic", second.providers[1].provider)
        assert.equals(2, #second.providers[1].models)
        assert.same({
            id = "claude-x",
            contextWindow = 200000,
            reasoning = true,
        }, second.providers[1].models[1])
        assert.equals("openai", second.providers[2].provider)
    end)

    it("rejects unknown query kinds", function()
        package.loaded["pi.sessions.manager"] = stub_manager({})
        local ok, err = Commands.handlers["workspace.query"]({ kind = "nope" }, {})
        assert.is_nil(ok)
        assert.equals(Protocol.ERR.BAD_REQUEST, err.code)
    end)
end)
