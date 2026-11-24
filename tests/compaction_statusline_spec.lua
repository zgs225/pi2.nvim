-- Statusline compaction countdown (Gitea #127 P0-1, revised): the distance to
-- pi's automatic compaction threshold lives on the `compaction` marker
-- (`󰏗 56k`), not on the `context` component, and it is off by default — the
-- pre-countdown statusline is the default (A), the compact form is opt-in (B),
-- and `countdown = "near"` discloses it only once the context is close.
--
-- The budget shape is the one `lua/pi/compaction/settings.lua:M.budget`
-- returns; the canonical case derives its expected numbers from the real
-- module instead of hardcoding them (a hardcoded "56k" would silently rot).
--
-- The second suite covers the chat wrappers that push a budget, forward a
-- compaction summary and cancel a running compaction with the double-<Esc>
-- gesture.

local Chat = require("pi.ui.chat")
local Config = require("pi.config")
local Settings = require("pi.compaction.settings")
local StatusLine = require("pi.ui.chat.statusline")
local Stats = require("pi.stats")

local ns = vim.api.nvim_create_namespace("pi-statusline")
local WINDOW = 200000

--- Empty-handed budget with the `pi.CompactionBudget` shape (200k window,
--- default reserve/keep => threshold 183616).
---@param overrides table?
---@return pi.CompactionBudget
local function budget(overrides)
    ---@type pi.CompactionBudget
    local b = {
        window = WINDOW,
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
    --- The marker glyph the countdown hangs off. Derived, never hardcoded: the
    --- history block header uses the same `labels.compaction`.
    local glyph

    before_each(function()
        Config.setup({})
        glyph = Config.options.labels.compaction
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

    --- Render only the compaction marker so the row is exactly its text.
    ---@param compaction_cfg table?
    local function only_compaction(compaction_cfg)
        Config.options.statusline = {
            layout = { left = { "compaction" }, center = {}, right = {} },
            components = { compaction = compaction_cfg or {} },
        }
    end

    --- Render only the context component (A mode: no countdown anywhere).
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

    --- Model + occupancy + auto-compaction on: the countdown's prerequisites.
    ---@param tokens integer?
    local function ready(tokens)
        sl:update_state({ model = { id = "m", contextWindow = WINDOW }, autoCompactionEnabled = true })
        if tokens then
            sl:add_usage({ input = tokens })
        end
    end

    --- Tokens at `pct` percent of the default budget's threshold.
    ---@param pct number
    ---@return integer
    local function at_pct(pct)
        return math.floor(budget().threshold * pct / 100)
    end

    it("shows the bare marker by default (A: no countdown at all)", function()
        only_compaction()
        ready(127800)
        sl:set_compaction_budget(budget())
        local text, row = status_row()
        assert.are.equal(glyph, text)
        assert.are.equal(glyph, row[1][1], "one chunk: the marker alone")
        assert.are.equal("PiStatusLine", row[1][2])
    end)

    it("countdown = true always appends the distance, from the real budget module", function()
        only_compaction({ countdown = true })
        local effective = {
            reserve = Settings.DEFAULTS.reserve,
            keep = Settings.DEFAULTS.keep,
            enabled = true,
            source = "default",
        }
        local b = assert(Settings.budget(effective, WINDOW))
        assert.are.equal(183616, b.threshold)
        assert.is_false(b.pathological)

        local tokens = 127800 -- 63.9% of 200k
        ready(tokens)
        sl:set_compaction_budget(b)

        local expected = glyph .. " " .. Stats.format_tokens(b.threshold - tokens)
        assert.are.equal("󰏗 56k", expected)
        local text, row = status_row()
        assert.are.equal(expected, text)
        assert.is_not_nil(chunk_with(row, Stats.format_tokens(b.threshold - tokens)))
        assert.are.equal("PiStatusLine", row[1][2], "a healthy countdown is not an error")
    end)

    it("counts down as the context grows", function()
        only_compaction({ countdown = true })
        local b = budget()
        ready()
        sl:set_compaction_budget(b)

        for _, tokens in ipairs({ 100000, 150000, 180000 }) do
            sl:add_usage({ input = tokens })
            assert.are.equal(glyph .. " " .. Stats.format_tokens(b.threshold - tokens), (status_row()))
        end
    end)

    it("shows 'now' at and over the threshold instead of a negative number", function()
        only_compaction({ countdown = true })
        local b = budget()
        ready()
        sl:set_compaction_budget(b)

        sl:add_usage({ input = b.threshold })
        assert.are.equal(glyph .. " now", (status_row()))

        sl:add_usage({ input = b.threshold + 50000 })
        local text = status_row()
        assert.are.equal(glyph .. " now", text)
        assert.is_nil(text:find("-%d", 1, true), "no negative countdown")
    end)

    it("countdown = 'near' hides the distance until the context is close", function()
        only_compaction({ countdown = "near" })
        local b = budget()
        ready()
        sl:set_compaction_budget(b)

        -- 50% and 70% of the threshold: nothing to warn about yet.
        for _, pct in ipairs({ 50, 70 }) do
            sl:add_usage({ input = at_pct(pct) })
            assert.are.equal(glyph, (status_row()), "hidden below the near point")
        end

        -- 85% of the threshold: past the default near point (80%).
        local tokens = at_pct(85)
        sl:add_usage({ input = tokens })
        assert.are.equal(glyph .. " " .. Stats.format_tokens(b.threshold - tokens), (status_row()))
    end)

    it("honours a custom near percentage", function()
        local b = budget()
        ready()
        sl:add_usage({ input = at_pct(60) })
        sl:set_compaction_budget(b)

        only_compaction({ countdown = "near", near = 50 })
        sl:render()
        assert.are.equal(glyph .. " " .. Stats.format_tokens(b.threshold - at_pct(60)), (status_row()))

        only_compaction({ countdown = "near", near = 90 })
        sl:render()
        assert.are.equal(glyph, (status_row()))
    end)

    it("marks a pathological budget (keep >= threshold) with '!', near or not", function()
        only_compaction({ countdown = "near" })
        ready(127800)
        sl:set_compaction_budget(budget({ keep = 190000, pathological = true }))
        local text, row = status_row()
        assert.are.equal(glyph .. " !", text, "an unusable budget is never hidden by near")
        assert.are.equal("PiStatusLineError", chunk_with(row, "!")[2])
    end)

    it("marks an invalid settings value with '?' and an error highlight", function()
        only_compaction({ countdown = true })
        ready(127800)
        sl:set_compaction_budget(budget({ invalid = "compaction.reserveTokens" }))
        local text, row = status_row()
        assert.are.equal(glyph .. " ?", text)
        assert.are.equal("PiStatusLineError", chunk_with(row, "?")[2])
    end)

    it("renders no distance when pi's compaction is disabled", function()
        only_compaction({ countdown = true })
        ready(127800)
        sl:set_compaction_budget(budget({ enabled = false, pathological = false }))
        assert.are.equal(glyph, (status_row()))
    end)

    it("renders no distance before the first usage (occupancy unknown)", function()
        only_compaction({ countdown = true })
        ready()
        sl:set_compaction_budget(budget())
        assert.are.equal(glyph, (status_row()))
    end)

    it("drops the distance when the budget is cleared", function()
        only_compaction({ countdown = true })
        ready(127800)
        sl:set_compaction_budget(budget())
        assert.is_not_nil(status_row():find(glyph .. " ", 1, true))
        sl:set_compaction_budget(nil)
        assert.are.equal(glyph, (status_row()))
    end)

    it("hides the marker while auto-compaction is off", function()
        only_compaction({ countdown = true })
        ready(127800)
        sl:set_compaction_budget(budget())
        sl:update_state({ model = { id = "m", contextWindow = WINDOW }, autoCompactionEnabled = false })
        assert.are.equal("", (status_row()))
    end)

    it("leaves the context component text-free in every mode", function()
        only_context()
        ready(127800)
        sl:set_compaction_budget(budget())
        assert.are.equal("63.9%/200k", (status_row()))
    end)

    it("keeps the context highlight untouched by an unusable budget", function()
        only_context({ warn = 70, error = 90 })
        ready(150000) -- 75% > warn
        sl:set_compaction_budget(budget({ keep = 190000, pathological = true }))
        local text, row = status_row()
        assert.are.equal("75.0%/200k", text)
        assert.are.equal("PiStatusLineWarning", chunk_with(row, "/200k")[2])
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
        only_compaction({ countdown = true })
        ready(127800)

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

    it("a compaction needs a second <Esc>: the first only arms and shows the hint", function()
        local calls = stub_pi()
        chat:set_compacting(true)
        chat:_handle_abort_esc()
        vim.wait(100, function()
            return chat._prompt:statusline()._state.abort_hint ~= nil
        end)
        assert.are.same({}, calls, "the first <Esc> must not cancel the compaction")
        assert.is_not_nil(chat._abort_esc_at, "the first <Esc> must arm while compacting")
        assert.is_not_nil(chat._abort_esc_timer, "the first <Esc> must start the disarm timer")
        assert.are.equal("Press <Esc> again to abort", chat._prompt:statusline()._state.abort_hint)
        assert.is_true(chat:is_compacting())
    end)

    it("the second <Esc> within the window cancels the compaction exactly once", function()
        local calls = stub_pi()
        chat:set_compacting(true)
        chat:_handle_abort_esc()
        assert.are.same({}, calls)
        chat:_handle_abort_esc()
        vim.wait(100, function()
            return #calls > 0
        end)
        -- The abort runs off the keypress path (vim.schedule), and the gesture
        -- is disarmed before it so a third press cannot re-fire.
        assert.are.same({ "compact_abort" }, calls)
        assert.is_nil(chat._abort_esc_at)
        assert.is_nil(chat._abort_esc_timer)
        chat:_handle_abort_esc()
        assert.are.same({ "compact_abort" }, calls, "a third <Esc> only re-arms")
        assert.is_not_nil(chat._abort_esc_at)
    end)

    it("<Esc> during a compaction is inert when abort is disabled", function()
        local calls = stub_pi()
        Config.options.abort.enabled = false
        chat:set_compacting(true)
        chat:_handle_abort_esc()
        chat:_handle_abort_esc()
        vim.wait(50)
        assert.are.same({}, calls)
        assert.is_nil(chat._abort_esc_at)
        assert.is_nil(chat._abort_esc_timer)
    end)

    it("the compaction ending disarms a half-pressed gesture", function()
        local calls = stub_pi()
        chat:set_compacting(true)
        chat:_handle_abort_esc()
        assert.is_not_nil(chat._abort_esc_at)
        chat:set_compacting(false)
        assert.is_nil(chat._abort_esc_at, "leaving the compaction must disarm the gesture")
        assert.is_nil(chat._abort_esc_timer)
        vim.wait(100, function()
            return chat._prompt:statusline()._state.abort_hint == nil
        end)
        assert.is_nil(chat._prompt:statusline()._state.abort_hint, "the hint must be cleared too")
        assert.are.same({}, calls)
    end)

    it("streaming without a compaction keeps the double-<Esc> gesture", function()
        local calls = stub_pi()
        chat._streaming = true
        chat:_handle_abort_esc()
        assert.are.same({}, calls)
        assert.is_not_nil(chat._abort_esc_at, "the first <Esc> must still arm while streaming")
    end)
end)
