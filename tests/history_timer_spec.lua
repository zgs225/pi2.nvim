-- Regression: timers must not outlive their history buffer.
--
-- A7: deleting the history buffer while the spinner was armed left the
-- repeating uv timer running forever (it re-armed on every frame with no
-- valid buffer to stop it), and History:clear() returned at its
-- invalid-buffer guard *before* stopping the spinner/stream timers.
--
-- B2: the thinking-block helpers indexed `pos[1]` unguarded, so a stale
-- anchor (buffer wiped/rebuilt while a block was streaming) crashed inside
-- the scheduled callback instead of degrading to a no-op.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")

--- An extmark id that never existed in this namespace.
local BOGUS_ANCHOR = 1000000

local function pump(ms)
    vim.wait(ms or 60)
end

describe("history timers and stale thinking anchors", function()
    local saved_spinner
    local saved_show_thinking

    before_each(function()
        saved_spinner = Config.options.spinner
        saved_show_thinking = Config.options.show_thinking
        -- classic = 80ms frames: fast enough to observe a tick quickly.
        Config.options.spinner = "classic"
        Config.options.show_thinking = true
    end)

    after_each(function()
        Config.options.spinner = saved_spinner
        Config.options.show_thinking = saved_show_thinking
    end)

    local function new_history(tab)
        return History.new(tab)
    end

    it("stops the spinner timer once its buffer is wiped", function()
        local h = new_history(960)
        h:set_status({ type = "agent", text = "Working…" })
        pump(50)
        assert.is_not_nil(h._spinner_timer, "spinner timer should be armed")

        vim.api.nvim_buf_delete(h:buf(), { force = true })

        assert.is_true(
            vim.wait(1000, function()
                return h._spinner_timer == nil
            end),
            "spinner timer was not stopped after the buffer was wiped"
        )
    end)

    it("clear() stops both timers after a wipe", function()
        local h = new_history(961)
        h:set_status({ type = "agent", text = "Working…" })
        pump(50)
        h:_ensure_stream_timer()
        assert.is_not_nil(h._spinner_timer, "spinner timer should be armed")
        assert.is_not_nil(h._stream_timer, "stream timer should be armed")

        -- Wipe first, then clear: pre-fix, clear() bailed at the
        -- invalid-buffer guard and left both timers alive.
        vim.api.nvim_buf_delete(h:buf(), { force = true })
        h:clear()

        assert.is_nil(h._spinner_timer, "spinner timer must be stopped")
        assert.is_nil(h._stream_timer, "stream timer must be stopped")
    end)

    it("thinking block insert/remove ignore a bogus anchor", function()
        local h = new_history(962)

        local ok_insert, err_insert = pcall(function()
            h:_insert_thinking_block({ "", "π Thinking", "" }, BOGUS_ANCHOR)
        end)
        assert.is_true(ok_insert, "insert with a dead anchor must not error: " .. tostring(err_insert))

        local ok_remove, err_remove = pcall(function()
            h:_remove_thinking_block(2, BOGUS_ANCHOR)
        end)
        assert.is_true(ok_remove, "remove with a dead anchor must not error: " .. tostring(err_remove))

        pcall(vim.api.nvim_buf_delete, h:buf(), { force = true })
    end)

    it("on_thinking_end with a dead anchor records an empty block", function()
        local h = new_history(963)
        h._thinking_accum = {
            anchor = BOGUS_ANCHOR,
            lines = { "pondering" },
            header_text = "pondering",
            measured = false,
            gen = 1,
        }
        h._thinking_requested = false

        h:on_thinking_end()
        pump(100)

        assert.is_nil(h._thinking_accum, "the block must still be sealed")
        assert.are.equal(1, #h._thinking_blocks, "an (empty) block is recorded")
        assert.are.equal(0, h._thinking_blocks[1].line_count, "no rows were rendered for a dead anchor")

        pcall(vim.api.nvim_buf_delete, h:buf(), { force = true })
    end)
end)
