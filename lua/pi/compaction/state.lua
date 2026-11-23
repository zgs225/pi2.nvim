--- Per-session compaction state: what happened, when, and whether it is thrashing.
---
--- Pure data with a small event API — no editor access, no `Notify`, no buffers.
--- `lua/pi/sessions/manager.lua` owns one `pi.CompactionState` per session and
--- feeds it the RPC events; the UI (compaction panel, chat block, statusline)
--- only reads the records.
---
--- Two ideas shape it:
---
--- - **A record per event, always.** An aborted or failed compaction is the most
---   interesting one (`aborted`, `error`), so `finish` appends even without a
---   matching `start`; `active` only supplies the start time and the reason.
--- - **Keep the numbers.** `thrash` returns the exact `tokens_before` bounds it
---   judged on instead of a boolean, so the message can quote them ("3
---   compactions in the last 10 turns, 48k -> 61k").

local M = {}

---@class pi.CompactionRecord One finished compaction attempt
---@field seq integer Monotonic within the state, starting at 1
---@field ts number Epoch seconds when it finished
---@field started_at number Epoch seconds when it started (equals `ts` without a start event)
---@field duration_ms integer? Wall time in milliseconds; nil without a start event
---@field reason string "manual" | "threshold" | "overflow" | "unknown"
---@field tokens_before integer Occupancy the compactor wanted to cut (`result.tokensBefore`)
---@field tokens_after integer? pi's estimate after compaction (`result.estimatedTokensAfter`)
---@field estimated boolean True when `tokens_after` is pi's heuristic estimate
---@field usage table? Provider token usage of the summarisation call, passed through
---@field read_files integer? Number of read paths pi carried into the summary
---@field modified_files integer? Number of modified paths pi carried into the summary
---@field read_files_omitted integer? Read paths the extension dropped from that list
---@field modified_files_omitted integer? Modified paths the extension dropped from that list
---@field first_kept_entry_id string? Entry id pi resumes from after the summary
---@field summary string The summary text ("" when the event carried none)
---@field summary_chars integer `#summary`, so the UI never has to recount on a redraw
---@field aborted boolean
---@field will_retry boolean
---@field error string? `errorMessage` when the event reported one
---@field engine string? `details.engine` — set by the bundled pi2-compaction extension
---@field custom_instructions string? Focus text the user gave the compactor
---@field turn integer Session run counter when it finished

---@class pi.CompactionActive The compaction currently in flight
---@field reason string
---@field started_at number Epoch seconds
---@field turn integer
---@field custom_instructions? string

---@class pi.CompactionRetry A summarisation retry in flight
---@field attempt integer
---@field max_attempts? integer
---@field source? string "compaction" | "branchSummary"
---@field reason? string
---@field error? string

---@class pi.CompactionState
---@field records pi.CompactionRecord[] Newest last; capped at `M.MAX_RECORDS`
---@field turn integer Session run counter, bumped by `on_turn`
---@field active? pi.CompactionActive
---@field retry? pi.CompactionRetry
---@field last_focus? string Most recent focus text given to a compactor
---@field focus_history string[] Newest first, unique, max `M.MAX_FOCUS_HISTORY`
---@field warned_thrash boolean Caller-owned latch: the thrash notice was shown once
---@field warned_invalid boolean Caller-owned latch: the invalid-settings notice was shown once

--- Records kept per session; older ones are dropped.
---@type integer
M.MAX_RECORDS = 100

--- Focus texts remembered for the compact dialog.
---@type integer
M.MAX_FOCUS_HISTORY = 5

--- Turns of history the thrash detector looks at.
---@type integer
M.THRASH_WINDOW = 10

--- A successful compaction must release at least 5% to count as progress.
---@type number
M.RELEASE_RATIO = 0.95

--- Wall-clock seconds since the epoch, with sub-second resolution when libuv
--- offers it. Both `ts` and `started_at` use this clock, so `duration_ms` is the
--- difference of two readings of the same clock (an integer-second `os.time()`
--- alone would make every fast compaction look instantaneous).
---@return number
local function now_seconds()
    local uv = vim.uv
    local gettimeofday = uv and uv.gettimeofday
    if type(gettimeofday) == "function" then
        -- luv returns `(sec, usec)`; a table form exists in newer builds.
        local ok, sec, usec = pcall(gettimeofday)
        if ok and type(sec) == "table" then
            local tv = sec
            if type(tv.sec) == "number" then
                return tv.sec + (tv.usec or 0) / 1000000
            end
        elseif ok and type(sec) == "number" then
            return sec + (type(usec) == "number" and usec or 0) / 1000000
        end
    end
    return os.time()
end

---@param value any
---@return integer?
local function as_integer(value)
    if type(value) ~= "number" or value ~= value then
        return nil
    end
    return math.floor(value)
end

---@param value any
---@return string?
local function as_nonempty_string(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

---@param value any
---@return table?
local function as_table(value)
    if type(value) == "table" and value ~= vim.NIL then
        return value
    end
    return nil
end

--- Count an array field, or nil when it is not an array at all.
---@param value any
---@return integer?
local function count_list(value)
    if type(value) ~= "table" or value == vim.NIL then
        return nil
    end
    return #value
end

--- Omitted file count, from either the flat extension field or the nested
--- `details.fileLists.omitted` shape.
---@param details table
---@param flat_field string e.g. "readFilesOmitted"
---@param nested_field string e.g. "read"
---@return integer?
local function omitted_count(details, flat_field, nested_field)
    local flat = as_integer(details[flat_field])
    if flat then
        return flat
    end
    local file_lists = as_table(details.fileLists)
    local omitted = file_lists and as_table(file_lists.omitted)
    if not omitted then
        return nil
    end
    return as_integer(omitted[nested_field])
end

--- New per-session state.
---@return pi.CompactionState
function M.new()
    return {
        records = {},
        turn = 0,
        focus_history = {},
        warned_thrash = false,
        warned_invalid = false,
    }
end

--- Bump the session run counter (call on `agent_start`).
---@param st pi.CompactionState
function M.on_turn(st)
    st.turn = (st.turn or 0) + 1
end

--- Record the start of a compaction (call on `compaction_start`).
---@param st pi.CompactionState
---@param ev table `compaction_start` / `auto_compaction_start` payload
function M.start(st, ev)
    ev = as_table(ev) or {}
    local reason = as_nonempty_string(ev.reason) or "unknown"
    local focus = as_nonempty_string(ev.customInstructions) or as_nonempty_string(ev.custom_instructions)
    st.active = {
        reason = reason,
        started_at = now_seconds(),
        turn = st.turn or 0,
        custom_instructions = focus or st.last_focus,
    }
end

--- Record the end of a compaction (call on `compaction_end`). Always appends one
--- record — aborted and failed compactions are the ones worth surfacing — and
--- always clears `st.active`.
---@param st pi.CompactionState
---@param ev table `compaction_end` / `auto_compaction_end` payload
---@return pi.CompactionRecord
function M.finish(st, ev)
    ev = as_table(ev) or {}
    local active = st.active
    local result = as_table(ev.result) or {}
    local details = as_table(result.details) or {}

    local ts = now_seconds()
    local started_at = active and active.started_at or ts
    local duration_ms = active and math.max(0, math.floor((ts - started_at) * 1000)) or nil

    local summary = type(result.summary) == "string" and result.summary or ""
    local tokens_before = as_integer(result.tokensBefore) or 0
    local tokens_after = as_integer(result.estimatedTokensAfter)
    local usage = as_table(result.usage)
    local last = st.records[#st.records]

    ---@type pi.CompactionRecord
    local record = {
        seq = (last and last.seq or 0) + 1,
        ts = ts,
        started_at = started_at,
        duration_ms = duration_ms,
        reason = as_nonempty_string(ev.reason) or (active and active.reason) or "unknown",
        tokens_before = tokens_before,
        tokens_after = tokens_after,
        estimated = tokens_after ~= nil,
        usage = usage,
        read_files = count_list(details.readFiles),
        modified_files = count_list(details.modifiedFiles),
        read_files_omitted = omitted_count(details, "readFilesOmitted", "read"),
        modified_files_omitted = omitted_count(details, "modifiedFilesOmitted", "modified"),
        first_kept_entry_id = as_nonempty_string(result.firstKeptEntryId),
        summary = summary,
        summary_chars = #summary,
        aborted = ev.aborted == true,
        will_retry = ev.willRetry == true,
        error = as_nonempty_string(ev.errorMessage),
        engine = as_nonempty_string(details.engine),
        custom_instructions = active and active.custom_instructions or nil,
        turn = st.turn or 0,
    }

    st.records[#st.records + 1] = record
    if #st.records > M.MAX_RECORDS then
        table.remove(st.records, 1)
    end
    st.active = nil
    return record
end

--- Find the record a replayed `<compaction>` message belongs to.
---
--- A replay only carries the summary text and `tokensBefore`, so the newest
--- record matching both is the one the message describes (a duplicate summary at
--- a different occupancy is a genuinely different compaction).
---@param st pi.CompactionState
---@param summary string
---@param tokens_before integer
---@return pi.CompactionRecord?
function M.match(st, summary, tokens_before)
    if type(summary) ~= "string" then
        return nil
    end
    local wanted_tokens = as_integer(tokens_before)
    for index = #st.records, 1, -1 do
        local record = st.records[index]
        if record.summary == summary and record.tokens_before == wanted_tokens then
            return record
        end
    end
    return nil
end

--- Detect a compaction loop: several compactions in the last turns, with the
--- context not actually being released.
---
--- Returns nil when there is nothing to say. `count >= 3` is thrash on frequency
--- alone (the context is being re-filled faster than the compactor can cut); a
--- pair is thrash only when the occupancy did not drop — `tokens_before`
--- non-decreasing across the window and at least one compaction that released
--- less than `M.RELEASE_RATIO` (or had no estimate at all).
---@param st pi.CompactionState
---@return { count: integer, non_decreasing: boolean, first: integer, last: integer }?
function M.thrash(st)
    if #st.records < 3 then
        return nil
    end
    local from = (st.turn or 0) - M.THRASH_WINDOW
    ---@type pi.CompactionRecord[]
    local window = {}
    for _, record in ipairs(st.records) do
        if record.turn >= from then
            window[#window + 1] = record
        end
    end
    if #window < 2 then
        return nil
    end
    local count = #window
    local first = window[1]
    local last = window[count]
    local rising = last.tokens_before >= first.tokens_before
    if not rising then
        rising = last.tokens_before >= window[count - 1].tokens_before
    end
    local stalled = false
    for _, record in ipairs(window) do
        if record.tokens_after == nil or record.tokens_after >= record.tokens_before * M.RELEASE_RATIO then
            stalled = true
            break
        end
    end
    local non_decreasing = rising and stalled
    if count < 3 and not non_decreasing then
        return nil
    end
    return { count = count, non_decreasing = non_decreasing, first = first.tokens_before, last = last.tokens_before }
end

--- Track a summarisation retry (call for every `summarization_retry_*` event).
---@param st pi.CompactionState
---@param ev table Retry event payload (`attempt`, `maxAttempts`, `delayMs`, `errorMessage`, `source`, `reason`)
function M.retry(st, ev)
    ev = as_table(ev) or {}
    local kind = ev.type or ev.kind
    local existing = st.retry

    if kind == "summarization_retry_scheduled" then
        st.retry = {
            attempt = as_integer(ev.attempt) or (existing and existing.attempt) or 1,
            max_attempts = as_integer(ev.maxAttempts) or (existing and existing.max_attempts),
            source = existing and existing.source,
            reason = existing and existing.reason,
            error = as_nonempty_string(ev.errorMessage) or (existing and existing.error),
        }
    elseif kind == "summarization_retry_attempt_start" then
        st.retry = {
            attempt = as_integer(ev.attempt) or (existing and existing.attempt) or 1,
            max_attempts = as_integer(ev.maxAttempts) or (existing and existing.max_attempts),
            source = as_nonempty_string(ev.source) or (existing and existing.source),
            reason = as_nonempty_string(ev.reason) or (existing and existing.reason),
            error = existing and existing.error,
        }
    elseif kind == "summarization_retry_finished" then
        st.retry = nil
    end
end

--- Remember the focus text a user gave (or meant to give) a compaction.
---
--- Blank and non-string input is ignored rather than stored: an empty entry in
--- the history would be a dead menu row. A repeat moves to the front instead of
--- duplicating, and the history stays bounded.
---@param st pi.CompactionState
---@param text string?
function M.set_focus(st, text)
    if type(text) ~= "string" then
        return
    end
    local focus = vim.trim(text)
    if focus == "" then
        return
    end
    st.last_focus = focus
    local history = st.focus_history or {}
    st.focus_history = history
    for index = #history, 1, -1 do
        if history[index] == focus then
            table.remove(history, index)
        end
    end
    table.insert(history, 1, focus)
    while #history > M.MAX_FOCUS_HISTORY do
        table.remove(history)
    end
end

--- Focus text that applies to the compaction in flight (nil when none runs).
---@param st pi.CompactionState
---@return string?
function M.active_focus(st)
    if not st.active then
        return nil
    end
    local focus = st.active.custom_instructions
    if type(focus) == "string" and focus ~= "" then
        return focus
    end
    return st.last_focus
end

return M
