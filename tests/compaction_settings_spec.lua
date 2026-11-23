-- Unit tests for pi.compaction.settings — pi's own compaction knobs
-- (`settings.json` / `.pi/settings.json`), resolved lazily and cached per file
-- stamp, plus the budget derived from them.
--
-- Hermetic: every test pins the agent directory to a temp dir via
-- `_set_agent_dir`, so the real `~/.pi/agent` is never read (G17).

local Settings = require("pi.compaction.settings")

local uv = vim.uv

---@param dir string
---@param name string
---@param body string
local function write(dir, name, body)
    local path = dir .. "/" .. name
    local sub = path:match("^(.*)/[^/]+$")
    if sub then
        vim.fn.mkdir(sub, "p")
    end
    local fd = assert(uv.fs_open(path, "w", 420))
    uv.fs_write(fd, body, 0)
    uv.fs_close(fd)
end

---@param dir string
---@param body string
local function write_settings(dir, body)
    write(dir, "settings.json", body)
end

---@param cwd string
---@param body string
local function write_project(cwd, body)
    write(cwd, ".pi/settings.json", body)
end

---@param body string
local function write_global_settings(agent_dir, body)
    write_settings(agent_dir, body)
end

describe("pi.compaction.settings", function()
    local agent_dir_root
    local cwd

    before_each(function()
        Settings._reset()
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
        agent_dir_root = uv.fs_realpath(root) or root
        local workspace = vim.fn.tempname()
        vim.fn.mkdir(workspace, "p")
        cwd = uv.fs_realpath(workspace) or workspace
        Settings._set_agent_dir(agent_dir_root)
    end)

    after_each(function()
        Settings._reset()
        vim.fn.delete(agent_dir_root, "rf")
        vim.fn.delete(cwd, "rf")
    end)

    describe("resolve", function()
        it("falls back to pi's defaults without any settings file", function()
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal(16384, effective.reserve)
            assert.are.equal(20000, effective.keep)
            assert.is_true(effective.enabled)
            assert.are.equal("default", effective.source)
            assert.is_nil(effective.invalid)
            assert.is_nil(effective.model_override)
        end)

        it("reads the global settings.json", function()
            write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":1000,"keepRecentTokens":2000}}')
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal(1000, effective.reserve)
            assert.are.equal(2000, effective.keep)
            assert.are.equal("settings", effective.source)
            assert.is_nil(effective.invalid)
        end)

        it("reads the project .pi/settings.json per key over the global file", function()
            write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":1000,"keepRecentTokens":2000}}')
            write_project(cwd, '{"compaction":{"reserveTokens":3000}}')
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal(3000, effective.reserve, "project wins for the key it sets")
            assert.are.equal(2000, effective.keep, "global still answers the key the project omits")
            assert.are.equal("settings", effective.source)
        end)

        it("reads enabled from the settings files", function()
            write_global_settings(agent_dir_root, '{"compaction":{"enabled":false}}')
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.is_false(effective.enabled)
            assert.are.equal("settings", effective.source)
        end)

        it("skips the project layer without a cwd", function()
            write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":1000}}')
            write_project(cwd, '{"compaction":{"reserveTokens":3000}}')
            local effective = Settings.resolve(nil, "openai", "gpt-5")
            assert.are.equal(1000, effective.reserve)
        end)

        it("applies modelOverrides on an exact provider/model match", function()
            write_global_settings(
                agent_dir_root,
                '{"compaction":{"reserveTokens":1000,"keepRecentTokens":2000,'
                    .. '"modelOverrides":{"openai/gpt-5":{"reserveTokens":8000,"keepRecentTokens":9000}}}}'
            )
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal(8000, effective.reserve)
            assert.are.equal(9000, effective.keep)
            assert.are.equal("override", effective.source)
            assert.is_true(effective.model_override)
        end)

        it("falls back to the settings layer when the model does not match", function()
            write_global_settings(
                agent_dir_root,
                '{"compaction":{"reserveTokens":1000,"modelOverrides":{"openai/gpt-5":{"reserveTokens":8000}}}}'
            )
            local effective = Settings.resolve(cwd, "openai", "gpt-5-mini")
            assert.are.equal(1000, effective.reserve)
            assert.are.equal("settings", effective.source)
            assert.is_nil(effective.model_override)
        end)

        it("matches the override key exactly, not by model prefix or suffix", function()
            write_global_settings(
                agent_dir_root,
                '{"compaction":{"reserveTokens":1000,"modelOverrides":{"openai/gpt-5":{"reserveTokens":8000}}}}'
            )
            assert.are.equal(8000, Settings.resolve(cwd, "openai", "gpt-5").reserve)
            assert.are.equal(1000, Settings.resolve(cwd, "other", "openai/gpt-5").reserve)
            assert.are.equal(1000, Settings.resolve(cwd, "openai", "gpt").reserve)
            assert.are.equal(1000, Settings.resolve(cwd, "openai", nil).reserve)
        end)

        it("falls through per field for a partial override", function()
            write_global_settings(
                agent_dir_root,
                '{"compaction":{"reserveTokens":1000,"keepRecentTokens":2000,'
                    .. '"modelOverrides":{"openai/gpt-5":{"reserveTokens":8000}}}}'
            )
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal(8000, effective.reserve, "override answers reserveTokens")
            assert.are.equal(2000, effective.keep, "absent override field falls through to settings")
            assert.are.equal("override", effective.source)
            assert.is_true(effective.model_override)
        end)

        it("lets the project override entry win over the global one for the same key", function()
            write_global_settings(
                agent_dir_root,
                '{"compaction":{"modelOverrides":{"openai/gpt-5":{"reserveTokens":8000}}}}'
            )
            write_project(cwd, '{"compaction":{"modelOverrides":{"openai/gpt-5":{"reserveTokens":9000}}}}')
            assert.are.equal(9000, Settings.resolve(cwd, "openai", "gpt-5").reserve)
        end)

        it("treats a non-numeric reserveTokens as invalid and falls to the next layer", function()
            write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":1000,"keepRecentTokens":2000}}')
            write_project(cwd, '{"compaction":{"reserveTokens":"lots"}}')
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal(1000, effective.reserve, "falls back to the global layer")
            assert.are.equal(2000, effective.keep, "the valid project key is kept")
            assert.are.equal("invalid", effective.source)
            assert.are.equal("compaction.reserveTokens", effective.invalid)
        end)

        it("rejects zero, negative, fractional and boolean values as invalid", function()
            local cases = {
                { body = '{"compaction":{"reserveTokens":0}}', path = "compaction.reserveTokens" },
                { body = '{"compaction":{"reserveTokens":-5}}', path = "compaction.reserveTokens" },
                { body = '{"compaction":{"reserveTokens":1000.5}}', path = "compaction.reserveTokens" },
                { body = '{"compaction":{"keepRecentTokens":true}}', path = "compaction.keepRecentTokens" },
                { body = '{"compaction":{"keepRecentTokens":2000.25}}', path = "compaction.keepRecentTokens" },
                { body = '{"compaction":{"enabled":"yes"}}', path = "compaction.enabled" },
                { body = '{"compaction":5}', path = "compaction" },
                { body = '{"compaction":{"modelOverrides":5}}', path = "compaction.modelOverrides" },
            }
            for _, case in ipairs(cases) do
                Settings._reset()
                Settings._set_agent_dir(agent_dir_root)
                write_global_settings(agent_dir_root, case.body)
                local effective = Settings.resolve(cwd, "openai", "gpt-5")
                assert.are.equal("invalid", effective.source, case.body)
                assert.are.equal(case.path, effective.invalid, case.body)
                assert.are.equal(16384, effective.reserve, case.body)
                assert.are.equal(20000, effective.keep, case.body)
                assert.is_true(effective.enabled, case.body)
            end
        end)

        it("treats unparseable JSON as invalid and keeps the defaults", function()
            write_global_settings(agent_dir_root, "{not json")
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal("invalid", effective.source)
            assert.are.equal("compaction", effective.invalid)
            assert.are.equal(16384, effective.reserve)
        end)

        it("flags an invalid override field and falls to the settings layer", function()
            write_global_settings(
                agent_dir_root,
                '{"compaction":{"reserveTokens":1000,' .. '"modelOverrides":{"openai/gpt-5":{"reserveTokens":"huge"}}}}'
            )
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal(1000, effective.reserve)
            assert.are.equal("invalid", effective.source)
            assert.are.equal("compaction.modelOverrides.openai/gpt-5.reserveTokens", effective.invalid)
        end)

        it("flags a non-object override entry", function()
            write_global_settings(
                agent_dir_root,
                '{"compaction":{"reserveTokens":1000,"modelOverrides":{"openai/gpt-5":7}}}'
            )
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal(1000, effective.reserve)
            assert.are.equal("invalid", effective.source)
            assert.are.equal("compaction.modelOverrides.openai/gpt-5", effective.invalid)
        end)

        it("ignores keys it does not own (pi shares the file)", function()
            write_global_settings(agent_dir_root, '{"theme":"dark","compaction":{"reserveTokens":1000}}')
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal(1000, effective.reserve)
            assert.are.equal("settings", effective.source)
        end)

        it("still reports a broken key another layer masks", function()
            write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":"lots"}}')
            write_project(cwd, '{"compaction":{"reserveTokens":3000}}')
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal(3000, effective.reserve, "the valid project value answers")
            assert.are.equal("invalid", effective.source)
            assert.are.equal("compaction.reserveTokens", effective.invalid)
        end)

        it("does not taint the session from another model's broken override entry", function()
            write_global_settings(
                agent_dir_root,
                '{"compaction":{"reserveTokens":1000,"modelOverrides":{"openai/other":{"reserveTokens":"x"}}}}'
            )
            local effective = Settings.resolve(cwd, "openai", "gpt-5")
            assert.are.equal(1000, effective.reserve)
            assert.are.equal("settings", effective.source)
            assert.is_nil(effective.invalid)
        end)
    end)

    describe("cache", function()
        it("does not re-read an unchanged file", function()
            write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":1234}}')
            assert.are.equal(1234, Settings.resolve(cwd, "openai", "gpt-5").reserve)
            local original = uv.fs_read
            uv.fs_read = function()
                error("fs_read must not run for an unchanged stamp")
            end
            local ok, effective = pcall(Settings.resolve, cwd, "openai", "gpt-5")
            uv.fs_read = original
            assert.is_true(ok, tostring(effective))
            assert.are.equal(1234, effective.reserve)
        end)

        it("re-reads a file whose stamp changed", function()
            write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":1234}}')
            assert.are.equal(1234, Settings.resolve(cwd, "openai", "gpt-5").reserve)
            write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":43210}}')
            assert.are.equal(43210, Settings.resolve(cwd, "openai", "gpt-5").reserve)
        end)

        it("caches a missing file as missing", function()
            assert.are.equal(16384, Settings.resolve(cwd, "openai", "gpt-5").reserve)
            local original = uv.fs_read
            uv.fs_read = function()
                error("fs_read must not run for a missing file")
            end
            local ok, effective = pcall(Settings.resolve, cwd, "openai", "gpt-5")
            uv.fs_read = original
            assert.is_true(ok, tostring(effective))
            assert.are.equal("default", effective.source)
        end)

        it("picks up a file created after the missing cache entry", function()
            assert.are.equal("default", Settings.resolve(cwd, "openai", "gpt-5").source)
            write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":777}}')
            assert.are.equal(777, Settings.resolve(cwd, "openai", "gpt-5").reserve)
        end)

        it("forgets the cache on _reset", function()
            write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":1234}}')
            assert.are.equal(1234, Settings.resolve(cwd, "openai", "gpt-5").reserve)
            Settings._reset()
            Settings._set_agent_dir(agent_dir_root)
            write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":43210}}')
            assert.are.equal(43210, Settings.resolve(cwd, "openai", "gpt-5").reserve)
        end)

        it("warns once per file stamp and forgets the latch on _reset", function()
            local Notify = require("pi.notify")
            local original = Notify.warn
            local messages = {}
            Notify.warn = function(msg)
                messages[#messages + 1] = msg
            end
            local ok, err = pcall(function()
                write_global_settings(agent_dir_root, '{"compaction":{"reserveTokens":"lots"}}')
                Settings.resolve(cwd, "openai", "gpt-5")
                Settings.resolve(cwd, "openai", "gpt-5")
                assert.are.equal(1, #messages, "one warning per file stamp")
                assert.matches("compaction.reserveTokens", messages[1])

                Settings._reset()
                Settings._set_agent_dir(agent_dir_root)
                Settings.resolve(cwd, "openai", "gpt-5")
                assert.are.equal(2, #messages, "_reset forgets the warn-once latch")
            end)
            Notify.warn = original
            assert.is_true(ok, tostring(err))
        end)
    end)

    describe("agent directory", function()
        it("uses the _set_agent_dir override", function()
            local other = vim.fn.tempname()
            vim.fn.mkdir(other, "p")
            write_settings(other, '{"compaction":{"reserveTokens":900}}')
            Settings._set_agent_dir(other)
            assert.are.equal(900, Settings.resolve(cwd, "openai", "gpt-5").reserve)
            -- The first (empty) directory is now irrelevant.
            assert.are.equal("settings", Settings.resolve(cwd, "openai", "gpt-5").source)
            vim.fn.delete(other, "rf")
        end)

        it("clears the override in _reset so the env var answers again", function()
            local env_dir = vim.fn.tempname()
            vim.fn.mkdir(env_dir, "p")
            write_settings(env_dir, '{"compaction":{"reserveTokens":555}}')
            local previous = vim.env.PI_CODING_AGENT_DIR
            vim.env.PI_CODING_AGENT_DIR = env_dir
            local other = vim.fn.tempname()
            vim.fn.mkdir(other, "p")
            Settings._set_agent_dir(other)
            assert.are.equal(16384, Settings.resolve(cwd, "openai", "gpt-5").reserve, "override wins")
            Settings._reset()
            assert.are.equal(555, Settings.resolve(cwd, "openai", "gpt-5").reserve, "env var applied after _reset")
            vim.env.PI_CODING_AGENT_DIR = previous
            vim.fn.delete(env_dir, "rf")
            vim.fn.delete(other, "rf")
        end)
    end)

    describe("budget", function()
        ---@param overrides table
        ---@return pi.CompactionEffectiveSettings
        local function effective(overrides)
            return vim.tbl_extend("force", {
                reserve = 16384,
                keep = 20000,
                enabled = true,
                source = "default",
            }, overrides)
        end

        it("derives the threshold as window - reserve", function()
            local budget = Settings.budget(effective({}), 200000)
            assert.are.equal(200000, budget.window)
            assert.are.equal(16384, budget.reserve)
            assert.are.equal(20000, budget.keep)
            assert.are.equal(183616, budget.threshold)
            assert.is_false(budget.pathological)
            assert.is_true(budget.enabled)
        end)

        it("calls a keep >= threshold pathological", function()
            local budget = Settings.budget(effective({ reserve = 5000, keep = 20000 }), 20000)
            assert.are.equal(15000, budget.threshold)
            assert.is_true(budget.pathological)
        end)

        it("never calls a disabled configuration pathological", function()
            local budget = Settings.budget(effective({ reserve = 5000, keep = 20000, enabled = false }), 20000)
            assert.is_true(budget.pathological == false)
            assert.is_false(budget.enabled)
        end)

        it("forwards an invalid marker", function()
            local budget =
                Settings.budget(effective({ source = "invalid", invalid = "compaction.reserveTokens" }), 1000)
            assert.are.equal("compaction.reserveTokens", budget.invalid)
        end)

        it("returns nil without a usable window", function()
            assert.is_nil(Settings.budget(effective({}), nil))
            assert.is_nil(Settings.budget(effective({}), 0))
            assert.is_nil(Settings.budget(effective({}), -1))
            assert.is_nil(Settings.budget(effective({}), "200000"))
            assert.is_nil(Settings.budget(effective({}), 0 / 0))
        end)

        it("returns nil without effective settings", function()
            assert.is_nil(Settings.budget(nil, 200000))
        end)
    end)

    describe("pi.DEFAULTS", function()
        it("holds pi's documented defaults", function()
            assert.are.equal(16384, Settings.DEFAULTS.reserve)
            assert.are.equal(20000, Settings.DEFAULTS.keep)
        end)
    end)
end)
