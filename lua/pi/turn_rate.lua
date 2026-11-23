--- Generation speed (output tokens per second) for one agent run.
---
--- π reports no throughput: `usage.output` arrives once per assistant message
--- on `message_end`, and the only clock is ours. This meter therefore sums two
--- things per timed message — the provider-reported output tokens and the
--- message's **decode window**, i.e. its first streamed content delta to its
--- `message_end` — so the numbers stay additive across the tool loop of a run
--- (several assistant messages, tools in between) while the tool execution time
--- in between is never charged to the model. Time to first token is excluded by
--- construction, so the ratio is a decode rate rather than tokens per wall
--- clock second.
---
--- Pure Lua (no Neovim API): `sessions/manager.lua` feeds it monotonic
--- `vim.uv.hrtime() / 1e9` values from the event stream and `ui/chat/history.lua`
--- renders the result with `format`.

---@class pi.TurnRateSummary
---@field tokens integer Output tokens of every timed assistant message
---@field secs number Sum of those messages' decode windows, in seconds

---@class pi.TurnRate
---@field _tokens integer
---@field _secs number
---@field _first_delta_at? number Decode-window start of the message in flight
local TurnRate = {}
TurnRate.__index = TurnRate

---@return pi.TurnRate
function TurnRate.new()
    return setmetatable({ _tokens = 0, _secs = 0, _first_delta_at = nil }, TurnRate)
end

--- Forget everything: a new agent run started.
function TurnRate:reset()
    self._tokens = 0
    self._secs = 0
    self._first_delta_at = nil
end

--- Open the decode window of a message; the clock starts on its first delta.
function TurnRate:on_message_start()
    self._first_delta_at = nil
end

--- Pin the decode-window start on the first streamed content delta.
---@param now number Monotonic seconds (`vim.uv.hrtime() / 1e9`)
function TurnRate:on_update(now)
    if self._first_delta_at == nil then
        self._first_delta_at = now
    end
end

--- Close the message's decode window and bank its tokens.
---
--- Skipped, like the statusline's `add_usage` rule: an aborted or errored
--- message (its usage can be zero or stale), a message that streamed no content
--- (no window, e.g. replayed or synthesized), a message whose usage reports no
--- output tokens (some endpoints only report usage on non-streamed responses),
--- and a window that is not positive (clock skew).
---@param usage table? Assistant message `usage` payload
---@param stop_reason string?
---@param now number Monotonic seconds
function TurnRate:on_message_end(usage, stop_reason, now)
    local started = self._first_delta_at
    self._first_delta_at = nil
    if started == nil or stop_reason == "aborted" or stop_reason == "error" then
        return
    end
    local tokens = type(usage) == "table" and tonumber(usage.output) or nil
    if not tokens or tokens <= 0 then
        return
    end
    local secs = now - started
    if secs <= 0 then
        return
    end
    self._tokens = self._tokens + tokens
    self._secs = self._secs + secs
end

--- The run's accumulated numbers, or nil when nothing was measured.
---@return pi.TurnRateSummary?
function TurnRate:summary()
    if self._tokens <= 0 or self._secs <= 0 then
        return nil
    end
    return { tokens = self._tokens, secs = self._secs }
end

--- Below this many output tokens a rate is sampling noise, not a measurement:
--- three tokens over 30 ms is not "89 tok/s", it is three tokens.
TurnRate.MIN_TOKENS = 20

--- Render a rate as `58 tok/s` (>= 10) or `4.2 tok/s` (below 10); nil when the
--- numbers cannot produce a meaningful one (nothing measured, fewer than
--- `MIN_TOKENS` output tokens, or under 1 tok/s where the figure says more
--- about a stalled stream than about speed).
---@param tokens integer
---@param secs number
---@return string?
function TurnRate.format(tokens, secs)
    if type(tokens) ~= "number" or type(secs) ~= "number" then
        return nil
    end
    if tokens < TurnRate.MIN_TOKENS or secs <= 0 then
        return nil
    end
    local rate = tokens / secs
    if rate >= 10 then
        return string.format("%d tok/s", math.floor(rate + 0.5))
    elseif rate >= 1 then
        return string.format("%.1f tok/s", rate)
    end
    return nil
end

return TurnRate
