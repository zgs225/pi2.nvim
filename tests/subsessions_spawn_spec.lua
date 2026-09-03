local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")

Config.setup({})

describe("subsession spawn limits and flags", function()
    local manifest_tmp
    local real_create
    local real_path
    local created = 0

    before_each(function()
        Config.setup({ subagent = { enabled = true, max_children = 1 } })
        created = 0
        manifest_tmp = vim.fn.tempname() .. "-spawn-manifest.json"
        real_path = Manifest.path
        Manifest._reset()
        Manifest.path = function()
            return manifest_tmp
        end
        real_create = Sessions.create_detached
        Sessions.create_detached = function()
            created = created + 1
            local n = created
            local session = {
                id = "tmp-spawn-" .. n,
                rpc = {
                    is_running = function()
                        return true
                    end,
                    stop = function() end,
                    send = function(_, cmd, cb)
                        if cmd.type == "get_state" and cb then
                            vim.schedule(function()
                                cb({ success = true, data = { sessionId = "child-" .. n } })
                            end)
                        elseif cmd.type == "prompt" and cb then
                            vim.schedule(function()
                                cb({ success = true })
                            end)
                        end
                        return true
                    end,
                },
            }
            Sessions._register_for_test(session)
            return session
        end
    end)

    after_each(function()
        Sessions.create_detached = real_create
        Manifest.path = real_path
        Manifest._reset()
        os.remove(manifest_tmp)
        Sessions._reset()
        Config.setup({})
    end)

    it("reserves occupancy so a second spawn cannot exceed max_children", function()
        local parent = {
            id = "parent-1",
            conversation_epoch = 0,
            rpc = {
                is_running = function()
                    return true
                end,
            },
        }
        local first_err, second_err
        Subsessions.spawn(parent, { task = "one" }, function(_, err)
            first_err = err
        end)
        Subsessions.spawn(parent, { task = "two" }, function(_, err)
            second_err = err
        end)

        assert.is_nil(first_err)
        assert.is_truthy(second_err)
        assert.is_truthy(second_err:find("max", 1, true))
        assert.equals(1, created)

        assert.is_true(
            vim.wait(3000, function()
                return Manifest.load()["child-1"] ~= nil
            end, 10),
            "first child should register"
        )
        assert.is_nil(first_err)

        local entry = Manifest.load()["child-1"]
        assert.is_false(entry.agent_spawned)
        assert.equals(1, entry.run_generation)
    end)

    it("formats available models prioritizing preferred provider and truncating >20", function()
        assert.is_nil(Subsessions._format_available_models(nil, "p"))
        assert.is_nil(Subsessions._format_available_models({}, "p"))

        local models = {
            { provider = "openai", id = "gpt-4o" },
            { provider = "anthropic", id = "claude-3-5-sonnet" },
            { provider = "anthropic", id = "claude-3-7-sonnet" },
            { provider = "google", id = "gemini-2.0-flash" },
        }
        local formatted = Subsessions._format_available_models(models, "anthropic")
        assert.are.equal(
            "anthropic/claude-3-5-sonnet, anthropic/claude-3-7-sonnet, google/gemini-2.0-flash, openai/gpt-4o",
            formatted
        )

        -- Truncation test (>20 models)
        local many = {}
        for i = 1, 25 do
            many[#many + 1] = { provider = "test", id = string.format("m-%02d", i) }
        end
        local trunc = Subsessions._format_available_models(many, "test")
        assert.is_truthy(trunc:find("(+5 more)", 1, true))
        assert.is_nil(trunc:find("m-21", 1, true))
        assert.is_truthy(trunc:find("m-20", 1, true))
    end)

    it("fails fail-fast and releases reservation when specified model does not exist", function()
        local stopped = false
        Sessions.create_detached = function()
            created = created + 1
            local n = created
            local session = {
                id = "tmp-spawn-" .. n,
                rpc = {
                    is_running = function()
                        return not stopped
                    end,
                    stop = function()
                        stopped = true
                    end,
                    send = function(_, cmd, cb)
                        if cmd.type == "get_state" and cb then
                            vim.schedule(function()
                                cb({ success = true, data = { sessionId = "child-fail-" .. n } })
                            end)
                        elseif cmd.type == "set_model" and cb then
                            vim.schedule(function()
                                cb({ success = false, error = "Model not found: mock/nonexistent" })
                            end)
                        elseif cmd.type == "get_available_models" and cb then
                            vim.schedule(function()
                                cb({
                                    success = true,
                                    data = {
                                        models = {
                                            { provider = "mock", id = "valid-model-1" },
                                            { provider = "other", id = "valid-model-2" },
                                        },
                                    },
                                })
                            end)
                        elseif cmd.type == "prompt" and cb then
                            vim.schedule(function()
                                cb({ success = true })
                            end)
                        end
                        return true
                    end,
                },
            }
            Sessions._register_for_test(session)
            return session
        end

        local parent = {
            id = "parent-1",
            conversation_epoch = 0,
            rpc = {
                is_running = function()
                    return true
                end,
            },
        }

        local spawn_child, spawn_err
        Subsessions.spawn(parent, {
            task = "test bad model",
            model = { provider = "mock", id = "nonexistent" },
        }, function(child, err)
            spawn_child = child
            spawn_err = err
        end)

        assert.is_true(
            vim.wait(3000, function()
                return spawn_err ~= nil
            end, 10),
            "spawn should fail with error"
        )

        assert.is_nil(spawn_child)
        assert.is_truthy(spawn_err:find("Model not found: mock/nonexistent", 1, true))
        assert.is_truthy(spawn_err:find("Available models:", 1, true))
        assert.is_truthy(spawn_err:find("mock/valid-model-1", 1, true))
        assert.is_true(stopped, "child session should be closed on model failure")

        local entry = Manifest.load()["child-fail-1"]
        assert.is_truthy(entry)
        assert.are.equal("failed", entry.status)

        -- Occupancy reservation must be released: subsequent spawn should be allowed with max_children = 1
        local second_child, second_err
        Subsessions.spawn(parent, { task = "second attempt without bad model" }, function(child, err)
            second_child = child
            second_err = err
        end)

        assert.is_true(
            vim.wait(3000, function()
                return second_child ~= nil
            end, 10),
            "subsequent spawn should succeed because reservation was released"
        )
        assert.is_nil(second_err)
    end)
end)
