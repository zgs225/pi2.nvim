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

        assert.is_true(vim.wait(3000, function()
            return Manifest.load()["child-1"] ~= nil
        end, 10), "first child should register")
        assert.is_nil(first_err)

        local entry = Manifest.load()["child-1"]
        assert.is_false(entry.agent_spawned)
        assert.equals(1, entry.run_generation)
    end)
end)
