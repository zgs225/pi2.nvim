-- Statusline compaction countdown (Gitea #127 P0-1): the context component
-- appends the distance to pi's automatic compaction threshold, and the chat
-- wrappers that push a budget / forward a compaction summary / abort a running
-- compaction with a single <Esc>.
--
-- The budget shape is the one `lua/pi/compaction/settings.lua:M.budget`
-- returns; the canonical case derives its expected numbers from the real
-- module instead of hardcoding them (a hardcoded "37k" would silently rot).

local Chat = require("pi.ui.chat")
local Config = require("pi.config")
local Settings = require("pi.compaction.settings")
local StatusLine = require("pi.ui.chat.statusline")
local Stats = require("pi.stats")

local ns = vim.api.nvim_create_namespace("pi-statusline")

--- Empty-handed budget with the `pi.CompactionBudget` shape (200k window,
--- default reserve/keep => threshold 183616).
---@param overrides table?
---@return pi.CompactionBudget
local function budget(overrides)
    ---@type pi.CompactionBudget
    local b = {
        window = 200000,
        reserve = 16384,
        keep = 20000,
        threshold = 183616,
        pathological = false,
        enabled = true,
    }
    if overrides then
        for key, value in pairs(overrides) do
            b[key] = value
        end
    end
    return b
end

describe("statusline compaction countdown", function()
    local buf
    local sl

    before_each(function()
        Config.setup({})
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(0, buf)
        sl = StatusLine.new(buf, 1, function()
            return 0
        end)
    end)

    after_each(function()
        Config.setup({})
        pcall(vim.cmd.silent, "only")
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    --- Render only the context component so the row is exactly its text.
    ---@param context_cfg table?
    local function only_context(context_cfg)
        Config.options.statusline = {
            layout = { left = { "context" }, center = {}, right = {} },
            components = { context = context_cfg or {} },
        }
    end

    --- Concatenated text of the status row (last virt_line of the extmark),
    --- without the right-hand padding.
    ---@return string text
    ---@return pi.StatusLineChunk[] row
    local function status_row()
        local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
        assert.are.equal(1, #marks, "expected exactly one statusline extmark")
        local virt_lines = marks[1][4].virt_lines
        assert.is_table(virt_lines)
        local row = virt_lines[#virt_lines]
        local text = ""
        for _, chunk in ipairs(row) do
            text = text .. chunk[1]
        end
        return (text:gsub("%s+$", "")), row
    end

    --- First rendered chunk containing `needle`.
    ---@param row pi.StatusLineChunk[]
    ---@param needle string
    ---@return pi.StatusLineChunk?
    local function chunk_with(row, needle)
        for _, chunk in ipairs(row) do
            if chunk[1]:find(needle, 1, true) then
                return chunk
            end
        end
        return nil
    end

    --- Percentage text chunk + its highlight.
    ---@param row pi.StatusLineChunk[]
    ---@return pi.StatusLineChunk?
    local function pct_chunk(row)
        local window = Stats.format_tokens(200000)
        return chunk_with(row, "/" .. window)
    end

    it("appends the live countdown, computed from the real budget module", function()
        only_context()
        local effective = {
            reserve = Settings.DEFAULTS.reserve,
            keep = Settings.DEFAULTS.keep,
            enabled = true,
            source = "default",
        }
        local b = assert(Settings.budget(effective, 200000))
        assert.are.equal(183616, b.threshold)
        assert.is_false(b.pathological)

        local tokens = 127800 -- 63.9% of 200k
        sl:update_state({ model = { contextWindow = 200000 } })
        sl:add_usage({ input = tokens })
        sl:set_compaction_budget(b)

        local expected = string.format(
            "%.1f%%/%s · %s to compact",
            (tokens / 200000) * 100,
            Stats.format_tokens(200000),
            Stats.format_tokens(b.threshold - tokens)
        )
        assert.are.equal("63.9%/200k · 56k to compact", expected)
        local text, row = status_row()
        assert.are.equal(expected, text)
        -- Suffix is its own chunk, so the percentage keeps its own highlight.
        local suffix = chunk_with(row, " to compact")
        assert.is_not_nil(suffix)
        assert.are.equal("PiStatusLine", suffix[2], "a healthy countdown is not an error")
    end)

    it("counts down to zero as the context grows", function()
        only_context()
        local b = budget()
        sl:update_state({ model = { contextWindow = 200000 } })
        sl:set_compaction_budget(b)

        sl:add_usage({ input = 100000 })
        local text = status_row()
        assert.is_not_nil(text:find(" · " .. Stats.format_tokens(b.threshold - 100000) .. " to compact", 1, true))
    end)

    it("shows 'at compaction threshold' instead of a negative number at/over the threshold", function()
        only_context()
        local b = budget()
        local expected = string.format(
            "%.1f%%/%s · at compaction threshold",
            (b.threshold / 200000) * 100,
            Stats.format_tokens(200000)
        )
        sl:update_state({ model = { contextWindow = 200000 } })
        sl:set_compaction_budget(b)
        sl:add_usage({ input = b.threshold })
        local text = status_row()
        assert.are.equal(expected, text)
        assert.is_nil(text:find("-%d", 1, true), "no negative countdown")

        sl._state.context_tokens = b.threshold + 50000
        sl:render()
        text = status_row()
        assert.is_not_nil(text:find(" · at compaction threshold", 1, true))
        assert.is_nil(text:find("-%d", 1, true), "no negative countdown")
    end)

    it("marks a pathological budget (keep >= threshold) as an error", function()
        only_context()
        sl:update_state({ model = { contextWindow = 200000 } })
        sl:add_usage({ input = 127800 })
        sl:set_compaction_budget(budget({ keep = 190000, pathological = true }))
        local text, row = status_row()
        assert.are.equal("63.9%/200k · keep ≥ budget", text)
        local suffix = chunk_with(row, "keep ≥ budget")
        assert.is_not_nil(suffix)
        assert.are.equal("PiStatusLineError", suffix[2])
        -- The percentage chunk has no warn/error of its own, so the component
        -- reads as one error.
        local pct = pct_chunk(row)
        assert.is_not_nil(pct)
        assert.are.equal("PiStatusLineError", pct[2])
    end)

    it("keeps the percentage's own warn highlight when the budget is pathological", function()
        only_context({ warn = 70, error = 90 })
        sl:update_state({ model = { contextWindow = 200000 } })
        sl:add_usage({ input = 150000 }) -- 75% > warn
        sl:set_compaction_budget(budget({ pathological = true }))
        local text, row = status_row()
        assert.are.equal("75.0%/200k · keep ≥ budget", text)
        local pct = pct_chunk(row)
        assert.is_not_nil(pct)
        assert.are.equal("PiStatusLineWarning", pct[2])
        assert.are.equal("PiStatusLineError", chunk_with(row, "keep ≥ budget")[2])
    end)

    it("marks an invalid settings value with '?' and an error highlight", function()
        only_context()
        sl:update_state({ model = { contextWindow = 200000 } })
        sl:add_usage({ input = 127800 })
        sl:set_compaction_budget(budget({ invalid = "compaction.reserveTokens" }))
        local text, row = status_row()
        assert.are.equal("63.9%/200k · ?", text)
        assert.are.equal("PiStatusLineError", chunk_with(row, " · ?")[2])
    end)

    it("renders no suffix when the component's countdown is disabled", function()
        only_context({ countdown = false })
        sl:update_state({ model = { contextWindow = 200000 } })
        sl:add_usage({ input = 127800 })
        sl:set_compaction_budget(budget())
        assert.are.equal("63.9%/200k", (status_row()))
    end)

    it("renders no suffix when pi's compaction is disabled", function()
        only_context()
        sl:update_state({ model = { contextWindow = 200000 } })
        sl:add_usage({ input = 127800 })
        sl:set_compaction_budget(budget({ enabled = false, pathological = false }))
        assert.are.equal("63.9%/200k", (status_row()))
    end)

    it("renders today's percentage when no budget is known", function()
        only_context()
        sl:update_state({ model = { contextWindow = 200000 } })
        sl:add_usage({ input = 127800 })
        assert.are.equal("63.9%/200k", (status_row()))
    end)

    it("drops the suffix when the budget is cleared", function()
        only_context()
        sl:update_state({ model = { contextWindow = 200000 } })
        sl:add_usage({ input = 127800 })
        sl:set_compaction_budget(budget())
        assert.is_not_nil(status_row():find(" to compact", 1, true))
        sl:set_compaction_budget(nil)
        assert.are.equal("63.9%/200k", (status_row()))
    end)

    it("hides the component without a context window (no invented denominator)", function()
        only_context()
        sl:add_usage({ input = 127800 })
        sl:set_compaction_budget(budget())
        -- Nothing visible at all: the row is the single blank padding chunk.
        local text = status_row()
        assert.are.equal("", text)
        assert.is_nil(text:find("/", 1, true))
    end)

    it("re-renders only when the pushed budget could change the text", function()
        only_context()
        sl:update_state({ model = { contextWindow = 200000 } })
        sl:add_usage({ input = 127800 })

        local renders = 0
        local original_render = StatusLine.render
        ---@diagnostic disable-next-line: duplicate-set-field
        StatusLine.render = function(self, ...)
            renders = renders + 1
            return original_render(self, ...)
        end
        local ok, err = pcall(function()
            sl:set_compaction_budget(budget())
            assert.are.equal(1, renders)
            -- A fresh table with the same fields is not a change.
            sl:set_compaction_budget(budget())
            assert.are.equal(1, renders)
            sl:set_compaction_budget(budget({ keep = 25000 }))
            assert.are.equal(2, renders)
            sl:set_compaction_budget(budget({ pathological = true }))
            assert.are.equal(3, renders)
            sl:set_compaction_budget(budget({ pathological = true, invalid = "compaction.enabled" }))
            assert.are.equal(4, renders)
            sl:set_compaction_budget(nil)
            assert.are.equal(5, renders)
            sl:set_compaction_budget(nil)
            assert.are.equal(5, renders)
        end)
        StatusLine.render = original_render
        assert.is_true(ok, err)
    end)
end)

describe("chat compaction wrappers", function()
    local TAB = 874
    local chat
    local cleanup
    local original_pi

    before_each(function()
        Config.setup({})
        original_pi = package.loaded["pi"]
        chat = Chat.new(TAB, "side", {
            send = function()
                return true
            end,
        })
        cleanup = function()
            chat:set_retrying(false)
            chat:_disarm_abort_esc()
            chat:_clear_aborted_notice()
            package.loaded["pi"] = original_pi
            pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
            pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
        end
    end)

    after_each(function()
        cleanup()
        Config.setup({})
    end)

    --- Replace `require("pi")` with a spy so `compact_abort` is observable.
    ---@return string[] calls
    local function stub_pi()
        local calls = {}
        package.loaded["pi"] = {
            compact_abort = function()
                calls[#calls + 1] = "compact_abort"
            end,
        }
        return calls
    end

    --- A bare chat (no windows): enough for the forwarding wrappers.
    ---@param history any
    ---@return any
    local function bare_chat(history)
        return { _history = history }
    end

    it("set_compaction_budget reaches the status line state", function()
        local b = budget()
        chat:set_compaction_budget(b)
        local state = chat._prompt:statusline()._state
        assert.are.same(b, state.compaction_budget)
        chat:set_compaction_budget(nil)
        assert.is_nil(state.compaction_budget)
    end)

    it("set_compaction_budget is a no-op without a prompt or status line", function()
        assert.is_nil(Chat.set_compaction_budget(bare_chat(nil), budget()))
        local no_statusline = {
            _prompt = {
                statusline = function()
                    return nil
                end,
            },
        }
        assert.is_nil(Chat.set_compaction_budget(no_statusline, budget()))
    end)

    it("append_compaction_summary forwards the meta argument", function()
        local got
        local fake = bare_chat({
            append_compaction_summary = function(_, summary, tokens_before, meta)
                got = { summary, tokens_before, meta }
            end,
        })
        local meta = { reason = "threshold", tokens_after = 12000 }
        Chat.append_compaction_summary(fake, "the summary", 183616, meta)
        assert.are.same({ "the summary", 183616, meta }, got)

        Chat.append_compaction_summary(fake, "bare", 5)
        assert.are.same({ "bare", 5, nil }, got)
    end)

    it("jump_to_compaction forwards the pair and returns the history's boolean", function()
        local got
        local jumped = true
        local fake = bare_chat({
            jump_to_compaction = function(_, summary, tokens_before)
                got = { summary, tokens_before }
                return jumped
            end,
        })
        assert.is_true(Chat.jump_to_compaction(fake, "the summary", 183616))
        assert.are.same({ "the summary", 183616 }, got)

        jumped = false
        assert.is_false(Chat.jump_to_compaction(fake, "the summary", 183616))
    end)

    it("jump_to_compaction returns false without a history or the lookup", function()
        assert.is_false(Chat.jump_to_compaction(bare_chat(nil), "the summary", 1))
        assert.is_false(Chat.jump_to_compaction(bare_chat({}), "the summary", 1))
    end)

    it("a single <Esc> during a compaction aborts it and arms no gesture", function()
        local calls = stub_pi()
        chat:set_compacting(true)
        chat:_handle_abort_esc()
        assert.are.same({ "compact_abort" }, calls)
        assert.is_nil(chat._abort_esc_at, "compaction abort must not arm the double-<Esc> gesture")
        assert.is_nil(chat._abort_esc_timer, "compaction abort must not start the disarm timer")
        assert.is_true(chat:is_compacting())
    end)

    it("<Esc> during a compaction is inert when abort is disabled", function()
        local calls = stub_pi()
        Config.options.abort.enabled = false
        chat:set_compacting(true)
        chat:_handle_abort_esc()
        assert.are.same({}, calls)
        assert.is_nil(chat._abort_esc_at)
    end)

    it("streaming without a compaction keeps the double-<Esc> gesture", function()
        local calls = stub_pi()
        chat._streaming = true
        chat:_handle_abort_esc()
        assert.are.same({}, calls)
        assert.is_not_nil(chat._abort_esc_at, "the first <Esc> must still arm while streaming")
    end)
end)
