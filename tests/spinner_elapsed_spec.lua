-- Regression for issue #93: the statusline spinner's elapsed counter must
-- measure the whole busy period (the agent run), not the current status
-- text. Mid-run text changes (auto-compaction, retry, the post-compaction
-- agent_start) must NOT restart it at 0; only a real idle transition
-- (set_status(nil)) restarts the counter for the next run.
--
-- The elapsed is computed from a fake vim.uv.hrtime clock at every
-- _emit_status call, and set_status re-emits whenever the text changes, so
-- no real spinner-timer pumping is needed to observe the counter.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")
local Chat = require("pi.ui.chat.init")

local TAB = 961

local function pump(ms)
    vim.wait(ms or 30)
end

describe("spinner elapsed timing", function()
    local saved_spinner
    local real_hrtime
    local clock

    before_each(function()
        saved_spinner = Config.options.spinner
        clock = 0
        real_hrtime = vim.uv.hrtime
        vim.uv.hrtime = function()
            return clock * 1e9
        end
    end)

    after_each(function()
        vim.uv.hrtime = real_hrtime
        Config.options.spinner = saved_spinner
    end)

    --- History with a capturing status listener.
    ---@return pi.ChatHistory, {clock: number, busy: pi.StatusLineBusy?}[]
    local function setup()
        local h = History.new(TAB + 1)
        vim.api.nvim_win_set_buf(0, h:buf())
        h:set_win(0)
        local models = {}
        h:set_status_listener(function(m)
            models[#models + 1] = { clock = clock, busy = m and vim.deepcopy(m) or nil }
        end)
        return h, models
    end

    --- Most recent busy model emitted (skips idle models).
    ---@param models table[]
    ---@return pi.StatusLineBusy?
    local function last_busy(models)
        for i = #models, 1, -1 do
            local b = models[i].busy
            if b then
                return b
            end
        end
        return nil
    end

    it("keeps the counter across mid-run status text changes and restarts only on idle", function()
        local h, models = setup()

        -- Run starts.
        h:set_status({ type = "agent", text = "Working…" })
        pump()
        assert.are.equal("", last_busy(models).elapsed)
        assert.are.equal("Working…", last_busy(models).text)

        -- 40s of work, then auto-compaction kicks in mid-run: the text
        -- changes but the counter must keep running (issue #93).
        clock = 40
        h:set_status({ type = "compaction" })
        pump()
        assert.are.equal(" 40s", last_busy(models).elapsed, "compaction must not reset the counter")
        assert.are.equal("Compacting…", last_busy(models).text)

        -- Compaction finishes, the run resumes with a fresh agent_start
        -- (new random verb): text changes again, counter still continuous.
        clock = 47
        h:set_status({ type = "agent", text = "Burning tokens…" })
        pump()
        assert.are.equal(" 47s", last_busy(models).elapsed, "post-compaction agent_start must not reset the counter")

        -- Retry cycle mid-run: same guarantee.
        clock = 50
        h:set_status({ type = "agent", text = "Retrying…" })
        pump()
        assert.are.equal(" 50s", last_busy(models).elapsed, "retry must not reset the counter")

        -- Run truly ends: idle transition hides the spinner and clears the
        -- counter, so the next run starts from 0 again.
        h:set_status(nil)
        pump()
        assert.is_nil(models[#models].busy, "idle must hide the spinner")
        h:set_status({ type = "agent", text = "Next run…" })
        pump()
        assert.are.equal("", last_busy(models).elapsed, "a new run starts from 0")
    end)

    it("preserves the verb and busy timing across the compaction rebuild", function()
        local chat = Chat.new(TAB + 2, "side", {
            send = function()
                return true
            end,
        })
        chat:on_agent_start()
        pump()
        local verb = chat:active_verb()
        assert.is_not_nil(verb, "a started run has an active verb")

        chat:clear_for_compaction_rebuild()
        assert.are.equal(verb, chat:active_verb(), "rebuild must keep the active verb (issue #93)")
        -- The run continues after the rebuild: a resume agent_start is not a
        -- brand-new task, so the busy text/timing survive clear()'s history
        -- wipe until restore_active_agent_status re-arms the spinner.
        assert.is_not_nil(chat._history._status_text)
        assert.is_not_nil(chat._history._status_start_time)

        pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
        pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
        pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
    end)

    it("does not restart the counter when the same text is re-set", function()
        local h, models = setup()
        h:set_status({ type = "agent", text = "Working…" })
        pump()
        clock = 30
        h:set_status({ type = "agent", text = "Working…" })
        pump()
        -- Same text early-returns without emitting; the busy model (and its
        -- elapsed at the moment of the last emission) is unchanged.
        local busy = last_busy(models)
        assert.are.equal("Working…", busy.text)
    end)
end)
