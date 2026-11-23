-- Unit tests for pi.compaction.state — per-session compaction bookkeeping.
-- Pure data: no editor, no filesystem, no RPC.

local State = require("pi.compaction.state")

---@param overrides? table
---@return table
local function start_event(overrides)
    return vim.tbl_extend("force", { type = "compaction_start", reason = "manual" }, overrides or {})
end

---@param overrides? table
---@return table
local function end_event(overrides)
    ---@type table
    local result = {
        summary = "summary text",
        firstKeptEntryId = "entry-7",
        tokensBefore = 48000,
        estimatedTokensAfter = 9000,
        usage = { input = 100, output = 20 },
        details = { readFiles = { "a", "b" }, modifiedFiles = { "c" } },
    }
    local event = { type = "compaction_end", reason = "threshold", result = result, aborted = false, willRetry = false }
    for key, value in pairs(overrides or {}) do
        if key == "result" then
            event.result = vim.tbl_extend("force", event.result, value)
        else
            event[key] = value
        end
    end
    return event
end

describe("pi.compaction.state", function()
    ---@type pi.CompactionState
    local st

    before_each(function()
        st = State.new()
    end)

    describe("new", function()
        it("starts empty", function()
            assert.are.same({}, st.records)
            assert.are.equal(0, st.turn)
            assert.is_nil(st.active)
            assert.is_nil(st.retry)
            assert.is_nil(st.last_focus)
            assert.are.same({}, st.focus_history)
            assert.is_false(st.warned_thrash)
            assert.is_false(st.warned_invalid)
        end)
    end)

    describe("on_turn", function()
        it("increments the run counter", function()
            State.on_turn(st)
            assert.are.equal(1, st.turn)
            State.on_turn(st)
            assert.are.equal(2, st.turn)
        end)
    end)

    describe("finish", function()
        it("records every field of a successful compaction", function()
            State.on_turn(st)
            State.on_turn(st)
            State.start(st, start_event({ reason = "overflow" }))
            local record = State.finish(st, end_event())

            assert.are.equal(1, record.seq)
            assert.are.equal("threshold", record.reason, "the end event's reason wins")
            assert.are.equal(48000, record.tokens_before)
            assert.are.equal(9000, record.tokens_after)
            assert.is_true(record.estimated)
            assert.are.same({ input = 100, output = 20 }, record.usage)
            assert.are.equal(2, record.read_files)
            assert.are.equal(1, record.modified_files)
            assert.are.equal("entry-7", record.first_kept_entry_id)
            assert.are.equal("summary text", record.summary)
            assert.are.equal(12, record.summary_chars)
            assert.is_false(record.aborted)
            assert.is_false(record.will_retry)
            assert.is_nil(record.error)
            assert.are.equal(2, record.turn)
            assert.are.equal(st.turn, record.turn)
            assert.is_number(record.ts)
            assert.is_number(record.started_at)
            assert.is_true(record.started_at <= record.ts)
            assert.is_number(record.duration_ms)
            assert.is_true(record.duration_ms >= 0)
            assert.is_nil(st.active, "finishing clears the active compaction")
        end)

        it("carries the engine marker and the extension's omitted counts", function()
            State.start(st, start_event())
            local record = State.finish(st, {
                type = "compaction_end",
                result = {
                    summary = "s",
                    tokensBefore = 100,
                    details = {
                        engine = "pi2-compaction",
                        readFiles = { "a" },
                        readFilesOmitted = 4,
                        modifiedFiles = { "b", "c" },
                        modifiedFilesOmitted = 2,
                    },
                },
            })
            assert.are.equal("pi2-compaction", record.engine)
            assert.are.equal(4, record.read_files_omitted)
            assert.are.equal(2, record.modified_files_omitted)
        end)

        it("reads omitted counts from the nested fileLists shape too", function()
            State.start(st, start_event())
            local record = State.finish(st, {
                type = "compaction_end",
                result = {
                    summary = "s",
                    details = {
                        fileLists = { omitted = { read = 7, modified = 3 } },
                        readFiles = {},
                        modifiedFiles = {},
                    },
                },
            })
            assert.are.equal(7, record.read_files_omitted)
            assert.are.equal(3, record.modified_files_omitted)
            assert.are.equal(0, record.read_files)
            assert.are.equal(0, record.modified_files)
        end)

        it("leaves the file counts nil when the event has no lists", function()
            State.start(st, start_event())
            local record = State.finish(st, { type = "compaction_end", result = { summary = "s" } })
            assert.is_nil(record.read_files)
            assert.is_nil(record.modified_files)
            assert.is_nil(record.read_files_omitted)
            assert.is_nil(record.modified_files_omitted)
        end)

        it("marks a compaction without estimatedTokensAfter as not estimated", function()
            State.start(st, start_event())
            local record = State.finish(st, { type = "compaction_end", result = { summary = "s", tokensBefore = 10 } })
            assert.is_nil(record.tokens_after)
            assert.is_false(record.estimated)
        end)

        it("records an aborted compaction", function()
            State.start(st, start_event())
            local record = State.finish(st, { type = "compaction_end", aborted = true })
            assert.is_true(record.aborted)
            assert.are.equal(0, record.tokens_before)
            assert.are.equal("", record.summary)
            assert.are.equal(0, record.summary_chars)
            assert.is_true(#st.records == 1)
        end)

        it("records errorMessage and willRetry", function()
            State.start(st, start_event())
            local record = State.finish(
                st,
                end_event({
                    aborted = true,
                    willRetry = true,
                    errorMessage = "provider exploded",
                })
            )
            assert.are.equal("provider exploded", record.error)
            assert.is_true(record.will_retry)
            assert.is_true(record.aborted)
        end)

        it("rejects an empty errorMessage", function()
            State.start(st, start_event())
            local record = State.finish(st, { type = "compaction_end", errorMessage = "" })
            assert.is_nil(record.error)
        end)

        it("records a finish without a start", function()
            local record = State.finish(st, end_event({ reason = "manual" }))
            assert.are.equal("manual", record.reason)
            assert.is_nil(record.duration_ms, "no start means no duration")
            assert.are.equal(record.ts, record.started_at)
            assert.are.equal(1, #st.records)
        end)

        it("falls back to the active reason and then to unknown", function()
            State.start(st, start_event({ reason = "overflow" }))
            assert.are.equal("overflow", State.finish(st, { type = "compaction_end" }).reason)
            assert.are.equal("unknown", State.finish(st, { type = "compaction_end" }).reason)
        end)

        it("carries the focus text given before the start", function()
            State.set_focus(st, "  keep the migration plan  ")
            State.start(st, start_event())
            local record = State.finish(st, end_event())
            assert.are.equal("keep the migration plan", record.custom_instructions)
        end)

        it("caps the record list at 100, dropping the oldest", function()
            for _ = 1, 105 do
                State.finish(st, end_event({ result = { tokensBefore = 1000 } }))
            end
            assert.are.equal(100, #st.records)
            assert.are.equal(6, st.records[1].seq, "the oldest five were dropped")
            assert.are.equal(105, st.records[#st.records].seq)
        end)
    end)

    describe("match", function()
        it("finds the record a replayed summary describes", function()
            State.finish(st, end_event({ result = { summary = "first", tokensBefore = 1000 } }))
            State.finish(st, end_event({ result = { summary = "second", tokensBefore = 2000 } }))
            local found = State.match(st, "second", 2000)
            assert.is_not_nil(found)
            assert.are.equal("second", found.summary)

            local first = State.match(st, "first", 1000)
            assert.is_not_nil(first)
            assert.are.equal(1, first.seq)
        end)

        it("requires both the summary and the occupancy to match", function()
            State.finish(st, end_event({ result = { summary = "same", tokensBefore = 1000 } }))
            assert.is_nil(State.match(st, "same", 1001))
            assert.is_nil(State.match(st, "other", 1000))
            assert.is_nil(State.match(st, "same", nil))
        end)

        it("prefers the newest duplicate", function()
            State.finish(st, end_event({ result = { summary = "same", tokensBefore = 1000 } }))
            State.finish(st, end_event({ result = { summary = "same", tokensBefore = 1000 } }))
            local found = State.match(st, "same", 1000)
            assert.is_not_nil(found)
            assert.are.equal(2, found.seq)
        end)

        it("returns nil for a non-string summary", function()
            State.finish(st, end_event())
            assert.is_nil(State.match(st, nil, 48000))
        end)
    end)

    describe("thrash", function()
        ---@param turn integer
        ---@param tokens_before integer
        ---@param tokens_after integer?
        local function push_compaction(turn, tokens_before, tokens_after)
            State.finish(st, {
                type = "compaction_end",
                result = {
                    summary = "s",
                    tokensBefore = tokens_before,
                    estimatedTokensAfter = tokens_after,
                },
            })
            st.records[#st.records].turn = turn
        end

        it("reports nothing before three records exist", function()
            st.turn = 5
            push_compaction(5, 1000, 100)
            push_compaction(5, 1000, 100)
            assert.is_nil(State.thrash(st))
        end)

        it("reports three compactions inside ten turns on frequency alone", function()
            st.turn = 10
            push_compaction(8, 1000, 100)
            push_compaction(9, 1000, 100)
            push_compaction(10, 1000, 100)
            local thrash = State.thrash(st)
            assert.is_not_nil(thrash)
            assert.are.equal(3, thrash.count)
            assert.is_false(thrash.non_decreasing, "every compaction released, so it rose but did not stall")
            assert.are.equal(1000, thrash.first)
            assert.are.equal(1000, thrash.last)
        end)

        it("reports a pair of non-decreasing compactions that release nothing", function()
            st.turn = 20
            push_compaction(2, 90000, 90000) -- outside the window (turn < 10), so count stays at 2
            push_compaction(18, 50000, nil)
            push_compaction(19, 50000, 50000)
            local thrash = State.thrash(st)
            assert.is_not_nil(thrash)
            assert.are.equal(2, thrash.count)
            assert.is_true(thrash.non_decreasing)
            assert.are.equal(50000, thrash.first)
            assert.are.equal(50000, thrash.last)
        end)

        it("cannot report once the compactions are older than the window", function()
            st.turn = 40
            push_compaction(1, 50000, nil)
            push_compaction(2, 50000, nil)
            push_compaction(3, 50000, nil)
            assert.is_nil(State.thrash(st))
        end)

        it("is not thrash when two falling compactions did make room", function()
            st.turn = 10
            push_compaction(1, 90000, 10000)
            push_compaction(9, 60000, 20000)
            push_compaction(10, 50000, 10000)
            local thrash = State.thrash(st)
            assert.is_not_nil(thrash, "three compactions in the window is thrash on frequency")
            assert.are.equal(3, thrash.count)
            assert.is_false(thrash.non_decreasing)
        end)

        it("does not call a pair non-decreasing when both released", function()
            st.turn = 20
            push_compaction(1, 90000, 90000) -- outside the window
            push_compaction(18, 50000, 1000)
            push_compaction(19, 45000, 900)
            assert.is_nil(State.thrash(st), "two records, both released, nothing to report")
        end)

        it("uses the last two when the first is the outlier", function()
            st.turn = 10
            push_compaction(1, 90000, nil)
            push_compaction(9, 40000, 40000)
            push_compaction(10, 45000, 45000)
            local thrash = State.thrash(st)
            assert.is_not_nil(thrash)
            assert.are.equal(3, thrash.count)
            assert.is_true(thrash.non_decreasing, "40k -> 45k across the last two")
        end)
    end)

    describe("retry", function()
        it("seeds a scheduled retry", function()
            State.retry(st, {
                type = "summarization_retry_scheduled",
                attempt = 2,
                maxAttempts = 3,
                delayMs = 1500,
                errorMessage = "rate limited",
            })
            assert.are.equal(2, st.retry.attempt)
            assert.are.equal(3, st.retry.max_attempts)
            assert.are.equal("rate limited", st.retry.error)
        end)

        it("keeps the attempt and records the source on attempt_start", function()
            State.retry(st, { type = "summarization_retry_scheduled", attempt = 2, maxAttempts = 3 })
            State.retry(st, {
                type = "summarization_retry_attempt_start",
                source = "compaction",
                reason = "overflow",
            })
            assert.are.equal(2, st.retry.attempt)
            assert.are.equal(3, st.retry.max_attempts)
            assert.are.equal("compaction", st.retry.source)
            assert.are.equal("overflow", st.retry.reason)
        end)

        it("seeds attempt 1 when attempt_start arrives alone", function()
            State.retry(st, { type = "summarization_retry_attempt_start", source = "branchSummary" })
            assert.are.equal(1, st.retry.attempt)
            assert.are.equal("branchSummary", st.retry.source)
        end)

        it("clears on finished", function()
            State.retry(st, { type = "summarization_retry_scheduled", attempt = 1, maxAttempts = 3 })
            State.retry(st, { type = "summarization_retry_finished" })
            assert.is_nil(st.retry)
        end)

        it("never throws on missing fields", function()
            State.retry(st, {})
            assert.is_nil(st.retry)
            State.retry(st, { type = "summarization_retry_scheduled" })
            assert.are.equal(1, st.retry.attempt)
            assert.is_nil(st.retry.max_attempts)
            State.retry(st, nil)
            assert.is_not_nil(st.retry)
        end)
    end)

    describe("focus", function()
        it("remembers the last focus and prepends the history", function()
            State.set_focus(st, "first")
            State.set_focus(st, "second")
            assert.are.equal("second", st.last_focus)
            assert.are.same({ "second", "first" }, st.focus_history)
        end)

        it("trims and de-duplicates", function()
            State.set_focus(st, "  keep the plan  ")
            State.set_focus(st, "other")
            State.set_focus(st, "keep the plan")
            assert.are.equal("keep the plan", st.last_focus)
            assert.are.same({ "keep the plan", "other" }, st.focus_history)
        end)

        it("rejects blank and non-string focus text", function()
            State.set_focus(st, "kept")
            State.set_focus(st, "")
            State.set_focus(st, "   ")
            State.set_focus(st, nil)
            State.set_focus(st, 42)
            assert.are.equal("kept", st.last_focus)
            assert.are.same({ "kept" }, st.focus_history)
        end)

        it("caps the history at five entries", function()
            for index = 1, 7 do
                State.set_focus(st, "focus " .. index)
            end
            assert.are.equal(5, #st.focus_history)
            assert.are.equal("focus 7", st.focus_history[1])
            assert.are.equal("focus 3", st.focus_history[5])
        end)

        it("reports the pending focus only while a compaction runs", function()
            State.set_focus(st, "keep the plan")
            assert.is_nil(State.active_focus(st))
            State.start(st, start_event())
            assert.are.equal("keep the plan", State.active_focus(st))
            State.finish(st, end_event())
            assert.is_nil(State.active_focus(st))
        end)

        it("prefers the active event's own custom instructions", function()
            State.set_focus(st, "remembered")
            State.start(st, start_event({ customInstructions = "explicit" }))
            assert.are.equal("explicit", State.active_focus(st))
        end)
    end)
end)
