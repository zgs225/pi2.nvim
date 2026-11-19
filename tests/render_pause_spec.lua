-- Regression: render-markdown must not re-render the history buffer during replay.
--
-- render-markdown.nvim re-renders the whole buffer on every TextChanged. A
-- session replay makes hundreds of buffer edits, so leaving it active makes
-- loading a large session hang (each edit re-parses the growing buffer, O(n^2)).
-- The fix pauses render-markdown for the history buffer while replaying and
-- re-enables it (rendering once) afterwards.
--
-- render-markdown.nvim is an OPTIONAL dependency: `tests/minimal_init.lua`
-- puts it on 'runtimepath' when the checkout exists, and it may be absent on
-- another machine. These specs therefore pin the *safe no-op* behavior of the
-- helpers in every case — builtin engine, engine requested and installed, and
-- engine requested but unloadable — so none of them can error regardless of
-- what is installed. The genuinely-missing path is simulated deterministically
-- (package.preload) rather than depending on the machine's plugins.

local Config = require("pi.config")
local Render = require("pi.ui.render")

---@return integer buf a scratch buffer the helpers can be pointed at
local function scratch_buf()
    return vim.api.nvim_create_buf(false, true)
end

---@param buf integer
local function delete_buf(buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

describe("render pause/resume", function()
    local saved_engine
    local saved_loaded
    local saved_preload
    local saved_notify
    local warnings

    before_each(function()
        saved_engine = Config.options.render and Config.options.render.engine
        Config.options.render = Config.options.render or {}
        saved_loaded = package.loaded["render-markdown"]
        saved_preload = package.preload["render-markdown"]
        warnings = {}
        saved_notify = vim.notify
        vim.notify = function(msg)
            warnings[#warnings + 1] = msg
        end
    end)

    after_each(function()
        vim.notify = saved_notify
        package.loaded["render-markdown"] = saved_loaded
        package.preload["render-markdown"] = saved_preload
        Config.options.render.engine = saved_engine
        Render._reset()
    end)

    it("engine defaults to builtin", function()
        Config.options.render.engine = nil
        assert.equals("builtin", Render.engine())
    end)

    it("pause/resume are safe no-ops for the builtin engine", function()
        Config.options.render.engine = "builtin"
        local buf = scratch_buf()
        assert.has_no.errors(function()
            Render.pause_history(buf)
            Render.resume_history(buf)
        end)
        delete_buf(buf)
    end)

    it("pause/resume do not error when the engine is requested", function()
        Config.options.render.engine = "render-markdown"
        -- Whatever the machine's plugin state is (attached, disabled, or not
        -- installed at all), the helpers must swallow internal failures and
        -- never raise: they sit on the replay hot path.
        local buf = scratch_buf()
        assert.has_no.errors(function()
            Render.pause_history(buf)
            Render.resume_history(buf)
        end)
        delete_buf(buf)
    end)

    it("attach_history degrades quietly when the engine is unloadable", function()
        Config.options.render.engine = "render-markdown"
        -- Deterministic "not installed": unload the real module and make the
        -- require fail, instead of relying on the machine lacking the plugin.
        package.loaded["render-markdown"] = nil
        package.preload["render-markdown"] = function()
            error("not installed")
        end
        assert.is_false((pcall(require, "render-markdown")))

        local buf = scratch_buf()
        assert.has_no.errors(function()
            Render.attach_history(buf)
        end)
        delete_buf(buf)
        assert.equals(1, #warnings, "missing engine must warn once, not raise")

        -- Warn-once guard: a second attach stays quiet.
        local buf2 = scratch_buf()
        assert.has_no.errors(function()
            Render.attach_history(buf2)
        end)
        delete_buf(buf2)
        assert.equals(1, #warnings)

        -- The normal teardown path (Config.setup + _reset) restores behaviour:
        -- the warn-once guard is cleared, so the helpers react to a missing
        -- engine again instead of being stuck silent.
        Config.setup({})
        Render._reset()
        assert.equals("render-markdown", Render.engine())
        local buf3 = scratch_buf()
        assert.has_no.errors(function()
            Render.attach_history(buf3)
        end)
        delete_buf(buf3)
        assert.equals(2, #warnings)
    end)

    it("pause/resume ignore an invalid buffer", function()
        Config.options.render.engine = "render-markdown"
        assert.has_no.errors(function()
            Render.pause_history(999999)
            Render.resume_history(999999)
        end)
    end)
end)
