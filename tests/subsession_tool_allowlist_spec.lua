-- Sub-agent tool allowlist (`pi --tools a,b,c` for child processes).
--
-- Three surfaces are covered:
--   1. `Manifest.normalize_tools` — validation + fresh-copy semantics.
--   2. `Cli.command` — `--tools` injection before `--mode rpc`, stripping the
--      user's own `--tools` from a *copy* of `cli.args` with a warn-once.
--   3. `Batch.dispatch` — spawn items accept `tools`, reuse items reject it.
--
-- `vim.notify` is spied (no real notifications) and the version probe is
-- stubbed, so no pi binary is spawned. Batch/manifest paths are redirected to
-- temp files so nothing touches the real `~/.pi`.

local Batch = require("pi.subsessions.batch")
local Cli = require("pi.cli")
local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Reaper = require("pi.subsessions.reaper")
local Sessions = require("pi.sessions.manager")

Config.setup({})

--- vim.notify spy records.
local notes = {}

--- Index of `needle` in `list` (exact match), or nil.
---@param list string[]
---@param needle string
---@return integer?
local function index_of(list, needle)
    for i, value in ipairs(list) do
        if value == needle then
            return i
        end
    end
    return nil
end

--- Count exact matches of `needle` in `list`.
---@param list string[]
---@param needle string
---@return integer
local function count_of(list, needle)
    local n = 0
    for _, value in ipairs(list) do
        if value == needle then
            n = n + 1
        end
    end
    return n
end

describe("Manifest.normalize_tools", function()
    before_each(function()
        Manifest._reset()
    end)

    after_each(function()
        Manifest._reset()
    end)

    it("treats nil as inherit-every-tool", function()
        local tools, err = Manifest.normalize_tools(nil)
        assert.is_nil(tools)
        assert.is_nil(err)
    end)

    it("rejects a non-table value", function()
        for _, value in ipairs({ "read", 42, true }) do
            local tools, err = Manifest.normalize_tools(value)
            assert.is_nil(tools)
            assert.equals("tools must be an array of tool names", err)
        end
    end)

    it("rejects an empty array", function()
        local tools, err = Manifest.normalize_tools({})
        assert.is_nil(tools)
        assert.equals("tools must list at least one tool; omit it to inherit every tool", err)
    end)

    it("rejects entries that are not single bare tool names", function()
        local cases = {
            { { "" }, "tools[1] must be a single tool name without commas or whitespace" },
            { { 42 }, "tools[1] must be a single tool name without commas or whitespace" },
            { { "read", "grep all" }, "tools[2] must be a single tool name without commas or whitespace" },
            { { "read", "a,b" }, "tools[2] must be a single tool name without commas or whitespace" },
            { { "read", "grep " }, "tools[2] must be a single tool name without commas or whitespace" },
        }
        for _, case in ipairs(cases) do
            local value = case[1]
            local tools, err = Manifest.normalize_tools(value)
            assert.is_nil(tools)
            assert.equals(case[2], err)
        end
    end)

    it("returns an equal but distinct copy that never aliases the input", function()
        local input = { "read", "grep" }
        local tools, err = Manifest.normalize_tools(input)
        assert.is_nil(err)
        assert.are.same({ "read", "grep" }, tools)
        assert.is_false(rawequal(input, tools), "the result must be a fresh array")

        -- Mutating the result must not leak back into the caller's table.
        tools[1] = "bash"
        tools[3] = "write"
        assert.are.same({ "read", "grep" }, input)
    end)

    it("accepts a single tool name", function()
        local tools, err = Manifest.normalize_tools({ "read" })
        assert.is_nil(err)
        assert.are.same({ "read" }, tools)
    end)
end)

describe("Cli.command tools allowlist", function()
    local real_cli
    local orig_notify
    local orig_probe

    before_each(function()
        notes = {}
        Cli._reset()
        real_cli = vim.deepcopy(Config.options.cli or {})
        Config.options.cli = { bin = "pi", args = {} }
        orig_notify = vim.notify
        orig_probe = Cli._probe_version
        vim.notify = function(msg, level)
            notes[#notes + 1] = { msg = msg, level = level }
        end
        -- No gated flags are used here; keep the probe inert regardless.
        Cli._probe_version = function()
            return "pi 1.1.0"
        end
    end)

    after_each(function()
        vim.notify = orig_notify
        Cli._probe_version = orig_probe
        Config.options.cli = real_cli
        Cli._reset()
    end)

    it("never injects --tools for a child without a tool list", function()
        local cmd = Cli.command({ subagent = false })
        assert.is_nil(index_of(cmd, "--tools"))
        assert.is_nil(index_of(cmd, "-t"))
        assert.equals("pi", cmd[1])
    end)

    it("treats an empty tools array like no tool list", function()
        local base = Cli.command({ subagent = false })
        local empty = Cli.command({ subagent = false, tools = {} })
        assert.are.same(base, empty)
    end)

    it("injects --tools <csv> right before --mode rpc", function()
        local cmd = Cli.command({ subagent = false, tools = { "read", "grep" } })
        local tools_at = index_of(cmd, "--tools")
        local mode_at = index_of(cmd, "--mode")
        assert.is_not_nil(tools_at, "command must carry --tools")
        assert.equals(1, count_of(cmd, "--tools"), "exactly one --tools selection")
        assert.equals("read,grep", cmd[tools_at + 1])
        assert.is_not_nil(mode_at)
        assert.is_true(tools_at < mode_at, "--tools must precede --mode")
        assert.equals("rpc", cmd[mode_at + 1])
        assert.equals(#cmd - 1, mode_at, "--mode rpc stays last")
    end)

    it("keeps the parent command byte-identical when no child tools are given", function()
        Config.options.cli.args = { "--model", "gpt-x" }
        local no_tools = Cli.command({ subagent = false })
        assert.are.same({ "pi", "--model", "gpt-x" }, vim.list_slice(no_tools, 1, 3))
        assert.is_nil(index_of(no_tools, "--tools"))
    end)

    it("strips the user's --tools selection from the child command and warns once", function()
        local forms = {
            { "--tools", "read" },
            { "-t", "read" },
            { "--tools=read" },
            { "-t=read" },
        }
        for _, form in ipairs(forms) do
            Cli._reset()
            notes = {}
            local user_args = { "--model", "gpt-x" }
            vim.list_extend(user_args, form)
            Config.options.cli.args = vim.deepcopy(user_args)

            local cmd = Cli.command({ subagent = false, tools = { "grep", "bash" } })

            assert.equals(1, count_of(cmd, "--tools"), ("one --tools selection for form %s"):format(form[1]))
            assert.equals(0, count_of(cmd, "-t"), ("no bare -t for form %s"):format(form[1]))
            assert.equals("grep,bash", cmd[index_of(cmd, "--tools") + 1])
            -- The user's value must not survive as a stray positional token.
            assert.equals(0, count_of(cmd, "read"), ("user tool name dropped for form %s"):format(form[1]))
            -- Non-tool args are untouched.
            assert.is_not_nil(index_of(cmd, "--model"))
            assert.is_not_nil(index_of(cmd, "gpt-x"))

            -- The user's flags stay visible to parent processes...
            assert.are.same(user_args, Cli.args())
            -- ...and cli.args itself is never mutated.
            assert.are.same(user_args, Config.options.cli.args)

            assert.equals(1, #notes, ("one warning for form %s"):format(form[1]))
            assert.equals(vim.log.levels.WARN, notes[1].level)
            assert.is_truthy(
                notes[1].msg:find("subagent.tools overrides --tools from cli.args for child processes", 1, true)
            )
        end
    end)

    it("does not warn again on a second child command", function()
        Config.options.cli.args = { "--tools", "read" }
        Cli.command({ subagent = false, tools = { "grep" } })
        Cli.command({ subagent = false, tools = { "grep" } })
        assert.equals(1, #notes, "the strip warning is warn-once")
    end)

    it("warns again after _reset clears the flag", function()
        Config.options.cli.args = { "--tools", "read" }
        Cli.command({ subagent = false, tools = { "grep" } })
        Cli._reset()
        Cli.command({ subagent = false, tools = { "grep" } })
        assert.equals(2, #notes)
    end)

    it("does not warn when cli.args has no tool selection", function()
        Config.options.cli.args = { "--model", "gpt-x" }
        Cli.command({ subagent = false, tools = { "read" } })
        assert.equals(0, #notes)
    end)

    it("does not warn for a parent command even when cli.args sets --tools", function()
        Config.options.cli.args = { "--tools", "read" }
        local cmd = Cli.command()
        assert.equals(1, count_of(cmd, "--tools"))
        assert.equals("read", cmd[index_of(cmd, "--tools") + 1])
        assert.equals(0, #notes)
    end)
end)

describe("Batch.dispatch tools allowlist", function()
    local batch_tmp
    local manifest_tmp
    local real_spawn
    local real_revive
    local real_close
    local real_manifest_path
    local real_subagent_opts
    local Subsessions

    ---@return table parent
    local function parent_session()
        return {
            id = "parent-1",
            rpc = {
                is_running = function()
                    return true
                end,
            },
        }
    end

    before_each(function()
        Batch._reset()
        batch_tmp = vim.fn.tempname() .. "-tools-batches.json"
        manifest_tmp = vim.fn.tempname() .. "-tools-manifest.json"
        Batch._set_path(batch_tmp)
        real_manifest_path = Manifest.path
        Manifest.path = function()
            return manifest_tmp
        end
        Subsessions = require("pi.subsessions")
        real_spawn = Subsessions.spawn
        real_revive = Subsessions.revive
        real_close = Subsessions.close
        real_subagent_opts = vim.deepcopy(Config.options.subagent)
        Manifest._reset()
        Sessions._reset()
        Reaper._reset()
    end)

    after_each(function()
        Subsessions.spawn = real_spawn
        Subsessions.revive = real_revive
        Subsessions.close = real_close
        Config.options.subagent = real_subagent_opts
        Sessions._reset()
        Reaper._reset()
        os.remove(batch_tmp)
        os.remove(manifest_tmp)
        Batch._reset()
        Manifest.path = real_manifest_path
        Manifest._reset()
    end)

    ---@param items table[]
    ---@return table result
    local function dispatch(items)
        local result
        Batch.dispatch(parent_session(), { items = items }, function(res)
            result = res
        end)
        return result
    end

    it("accepts tools on a spawn item and forwards them to spawn", function()
        local spawned ---@type table?
        Subsessions.spawn = function(_parent, opts, _callback)
            spawned = opts
        end

        local res = dispatch({ { task = "t", tools = { "read", "grep" } } })
        assert.is_string(res.batch_id)
        assert.is_true(
            vim.wait(1000, function()
                return spawned ~= nil
            end, 20),
            "run_batch must reach spawn"
        )
        assert.are.same({ "read", "grep" }, spawned.tools)
        Batch.cancel(res.batch_id)
    end)

    it("leaves spawned tools nil when the item omits them", function()
        local spawned ---@type table?
        Subsessions.spawn = function(_parent, opts, _callback)
            spawned = opts
        end

        local res = dispatch({ { task = "t" } })
        assert.is_string(res.batch_id)
        assert.is_true(
            vim.wait(1000, function()
                return spawned ~= nil
            end, 20),
            "run_batch must reach spawn"
        )
        assert.is_nil(spawned.tools)
        Batch.cancel(res.batch_id)
    end)

    it("rejects a malformed tools value on a spawn item", function()
        local cases = {
            { tools = "read", expected = "item 1: tools must be an array of tool names" },
            { tools = {}, expected = "item 1: tools must list at least one tool" },
            {
                tools = { "read", "a b" },
                expected = "item 1: tools[2] must be a single tool name without commas or whitespace",
            },
            {
                tools = { "read,grep" },
                expected = "item 1: tools[1] must be a single tool name without commas or whitespace",
            },
        }
        for _, case in ipairs(cases) do
            local res = dispatch({ { task = "t", tools = case.tools } })
            assert.is_nil(res.batch_id)
            assert.is_truthy(res.error)
            assert.is_truthy(
                res.error:find(case.expected, 1, true),
                ("error must contain %q, got %q"):format(case.expected, tostring(res.error))
            )
        end
        assert.is_nil(next(Batch.load()), "a rejected item must not persist a batch")
    end)

    it("rejects tools on a reuse item with a named error", function()
        Manifest.upsert("child-uuid", {
            parent_id = "parent-1",
            name = "worker",
            task_prompt = "t",
            config = {},
            status = "dormant",
            reported = false,
            created_at = Manifest.iso_now(),
            last_active_at = Manifest.iso_now(),
        })

        local res = dispatch({ { target = "child-uuid", message = "continue", tools = { "read" } } })
        assert.is_nil(res.batch_id)
        assert.is_truthy(res.error)
        assert.is_truthy(res.error:find("`tools` is not accepted on a reuse item ({ target, message })", 1, true))
        assert.is_nil(next(Batch.load()))
    end)

    it("still accepts a reuse item without tools", function()
        Subsessions.revive = function(_target, callback)
            callback({
                id = "child-uuid",
                rpc = {
                    is_running = function()
                        return false
                    end,
                    send = function()
                        return true
                    end,
                },
            }, nil)
        end
        Manifest.upsert("child-uuid", {
            parent_id = "parent-1",
            name = "worker",
            task_prompt = "t",
            config = {},
            status = "dormant",
            reported = false,
            created_at = Manifest.iso_now(),
            last_active_at = Manifest.iso_now(),
        })

        local res = dispatch({ { target = "child-uuid", message = "continue" } })
        assert.is_string(res.batch_id)
        Batch.cancel(res.batch_id)
    end)
end)
