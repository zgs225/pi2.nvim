--- Authoritative pi2 session-state model.
---
--- This is a rule-for-rule port of the canonical TypeScript reference
--- `pi2d/src/protocol/reducer.ts` (documented in `pi2d/docs/protocol.md` §4/§4.1).
--- The browser only keeps a render cache reduced by the same rules; the plugin
--- owns the truth. Both reducers must reproduce `pi2d/fixtures/*/expected.json`
--- exactly — `tests/web_state_conformance_spec.lua` pins that.
---
--- The file is pure Lua on purpose: apart from the `vim.json` sentinels
--- (`vim.NIL`, `vim.empty_dict()`) and `vim.deepcopy` it touches no Neovim API, so
--- it can be applied from an RPC callback or a headless test without UI state.
--- Envelope concerns (`epoch`, `seq`, `ts` assignment) belong to the bridge.
---
--- JSON model notes:
--- * `vim.json.decode` maps JSON `null` to `vim.NIL`, `{}` to `vim.empty_dict()`
---   and `[]` to a plain empty table. State keeps null-valued fields as
---   `vim.NIL` so a snapshot still encodes `null` (dropping the key would
---   produce an invalid SessionState on the wire).
--- * Numbers are Lua/JS doubles, so usage sums (`cost.total`) match bit-for-bit.

local M = {}

--- Newest entries the reducer retains. The browser renders from the reducer
--- state, so an unbounded `entries` array grows for the whole process lifetime;
--- older turns stay available through the history pagination
--- (`workspace.query{kind="entries"}`), which is authoritative.
M.MAX_ENTRIES = 500

--- Nested reference to the shared empty-dict metatable, used to tell a decoded
--- JSON object (`{}` → `vim.empty_dict()`) from a decoded JSON array (`[]`).
local EMPTY_DICT_MT = getmetatable(vim.empty_dict())

--- @class pi.web.BlockText
--- @field type "text"
--- @field text string

--- @class pi.web.BlockThinking
--- @field type "thinking"
--- @field text string
--- @field redacted? boolean

--- @class pi.web.ToolOutput
--- @field text? string
--- @field details? unknown
--- @field isError? boolean

--- @class pi.web.BlockTool
--- @field type "tool"
--- @field toolCallId string
--- @field name string
--- @field args? unknown
--- @field output? pi.web.ToolOutput
--- @field state "pending" | "running" | "done" | "error"
--- @field durationMs? number

--- @class pi.web.BlockError
--- @field type "error"
--- @field text string

--- @alias pi.web.Block pi.web.BlockText | pi.web.BlockThinking | pi.web.BlockTool | pi.web.BlockError

--- @class pi.web.Entry
--- @field id string deterministic `m1`, `m2`, … in arrival order
--- @field role "user" | "assistant" | "system" | "notice"
--- @field ts number
--- @field blocks pi.web.Block[]
--- @field done boolean
--- @field images? { mimeType: string, data: string }[]

--- @class pi.web.UsageTotals
--- @field input number
--- @field output number
--- @field cacheRead number
--- @field cacheWrite number
--- @field cost number

--- @class pi.web.Flags
--- @field attention boolean
--- @field done boolean
--- @field error boolean

--- @class pi.web.QueueItem
--- @field id string
--- @field text string
--- @field steer boolean

--- The projected session state. Mirrors `SessionState` in
--- `pi2d/docs/protocol.md` §4 field-for-field; null-valued fields are `vim.NIL`
--- (so they still encode as JSON `null`).
--- @class pi.web.SessionState
--- @field sessionId string
--- @field workspaceId string
--- @field cwd string
--- @field name string|nil
--- @field status string `starting|busy|compacting|idle|exited|interrupted`
--- @field flags pi.web.Flags
--- @field model { provider: string, id: string }|nil
--- @field thinking string|nil `off|minimal|low|medium|high|xhigh|max`
--- @field usage pi.web.UsageTotals
--- @field contextUsage { tokens: number, window: number, percent: number }|nil
--- @field queue pi.web.QueueItem[]
--- @field todos table[]
--- @field tasks table[]
--- @field batches table[]
--- @field subagents table[]
--- @field attention table[]
--- @field entries pi.web.Entry[]

--- @class pi.web.StateInit
--- @field session_id string
--- @field workspace_id? string
--- @field cwd? string
--- @field name? string
--- @field status? string
--- @field model? { provider: string, id: string }
--- @field thinking? string

--- Location of a tool block inside an entry, so execution events that arrive
--- after the authoritative `message_end` rebuild can find it again.
--- @class pi.web.ToolBlockLoc
--- @field entry_id string
--- @field index integer

--- @class pi.web.State
--- @field _state pi.web.SessionState the projected SessionState
--- @field _next_entry integer next entry number (ids are `m<n>`)
--- @field _assistant_entry_id string|nil entry receiving streaming updates
--- @field _user_entry_id string|nil entry receiving the authoritative user body
--- @field _tool_blocks table<string, pi.web.ToolBlockLoc> toolCallId → block location
--- @field _tool_args table<string, string> streamed tool-call argument buffer (debug only)
local State = {}
State.__index = State

--- @param v unknown
--- @return boolean
local function is_empty_dict(v)
    return type(v) == "table" and getmetatable(v) == EMPTY_DICT_MT
end

--- True for decoded JSON arrays (sequential 1..n numeric keys). A plain empty
--- table is an array: `vim.json` decodes `[]` to `{}` and `{}` to
--- `vim.empty_dict()`, the latter carrying the sentinel metatable.
--- @param v unknown
--- @return boolean
local function is_array(v)
    if type(v) ~= "table" or is_empty_dict(v) then
        return false
    end
    if next(v) == nil then
        return true
    end
    local count = 0
    for k in pairs(v) do
        if type(k) ~= "number" then
            return false
        end
        count = count + 1
    end
    return count == #v
end

--- Finiteness from `Number.isFinite`.
--- @param v unknown
--- @param fallback? number
--- @return number
local function num(v, fallback)
    if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
        return v
    end
    return fallback or 0
end

--- `typeof v === "string"` narrowed to a `string|nil` result.
--- @param v unknown
--- @return string|nil
local function str(v)
    if type(v) == "string" then
        return v
    end
    return nil
end

--- `rec()`: the value if it is a JSON object, else nil.
--- @param v unknown
--- @return table|nil
local function rec(v)
    if type(v) == "table" and not is_array(v) then
        return v
    end
    return nil
end

--- `arr()`: the value if it is a JSON array, else an empty array.
--- @param v unknown
--- @return table
local function arr(v)
    if is_array(v) then
        return v
    end
    return {}
end

--- Render a number the way JS template interpolation does, for fallback ids.
--- @param n number
--- @return string
local function id_num(n)
    if n == math.floor(n) then
        return ("%d"):format(n)
    end
    return tostring(n)
end

--- @param self pi.web.State
--- @param id string|nil
--- @return table|nil
local function entry_of(self, id)
    if not id then
        return nil
    end
    for _, entry in ipairs(self._state.entries) do
        if entry.id == id then
            return entry
        end
    end
    return nil
end

--- Forward declarations: entry creation enforces the retention cap.
--- @type fun(self: pi.web.State)
local trim_entries
--- @type fun(self: pi.web.State, entry: pi.web.Entry|nil)
local forget_tool_blocks

--- @param self pi.web.State
--- @param role string
--- @param ts number
--- @param blocks? pi.web.Block[]
--- @param done? boolean
--- @return pi.web.Entry
local function new_entry(self, role, ts, blocks, done)
    local entry = {
        id = "m" .. self._next_entry,
        role = role,
        ts = ts,
        blocks = blocks or {},
        done = done == true,
    }
    self._next_entry = self._next_entry + 1
    local entries = self._state.entries
    entries[#entries + 1] = entry
    trim_entries(self)
    return entry
end

--- Drop the oldest entries once the retention cap is exceeded. An entry the
--- reducer is still streaming into (assistant/user) is never dropped, and tool
--- block locations of dropped entries are forgotten so the index stays bounded.
--- @param self pi.web.State
trim_entries = function(self)
    local entries = self._state.entries
    while #entries > M.MAX_ENTRIES do
        local keep_assistant = entries[1].id == self._assistant_entry_id
        local keep_user = entries[1].id == self._user_entry_id
        if (keep_assistant or keep_user) and #entries > 1 then
            -- Drop the next oldest instead of the block being streamed into.
            local dropped = table.remove(entries, 2)
            forget_tool_blocks(self, dropped)
        else
            local dropped = table.remove(entries, 1)
            forget_tool_blocks(self, dropped)
        end
    end
end

--- @param self pi.web.State
--- @param entry pi.web.Entry|nil
forget_tool_blocks = function(self, entry)
    if not entry then
        return
    end
    for tool_call_id, loc in pairs(self._tool_blocks) do
        if loc.entry_id == entry.id then
            self._tool_blocks[tool_call_id] = nil
            self._tool_args[tool_call_id] = nil
        end
    end
end

--- Block at `slot` (1-based Lua array position), filling gaps with empty text
--- placeholders and replacing a block of a different type. The protocol's
--- `contentIndex` is 0-based, so callers pass `contentIndex + 1`.
--- @param entry pi.web.Entry
--- @param slot integer
--- @param template fun(): pi.web.Block
--- @return pi.web.Block
local function block_at(entry, slot, template)
    while #entry.blocks < slot do
        entry.blocks[#entry.blocks + 1] = { type = "text", text = "" }
    end
    local existing = entry.blocks[slot]
    local block = template()
    if existing and existing.type == block.type then
        return existing
    end
    entry.blocks[slot] = block
    return block
end

--- @param entry pi.web.Entry
--- @param slot integer 1-based array position (see `block_at`)
--- @param block_type "text" | "thinking"
--- @param delta string
local function append_delta(entry, slot, block_type, delta)
    local block = block_at(entry, slot, function()
        return { type = block_type, text = "" }
    end)
    block.text = block.text .. delta
end

--- @param content unknown
--- @param ts number
--- @return pi.web.Block[]
local function content_to_blocks(content, ts)
    if type(content) == "string" then
        return { { type = "text", text = content } }
    end
    local blocks = {}
    for _, raw in ipairs(arr(content)) do
        local b = rec(raw) or {}
        local block_type = str(b.type)
        if block_type == "text" then
            blocks[#blocks + 1] = { type = "text", text = str(b.text) or "" }
        elseif block_type == "thinking" then
            blocks[#blocks + 1] = { type = "thinking", text = str(b.thinking) or str(b.text) or "" }
        elseif block_type == "toolCall" then
            blocks[#blocks + 1] = {
                type = "tool",
                toolCallId = str(b.id) or ("call_" .. id_num(ts) .. "_" .. id_num(#blocks)),
                name = str(b.name) or "tool",
                args = b.arguments,
                state = "pending",
            }
        elseif block_type == "error" then
            blocks[#blocks + 1] = { type = "error", text = str(b.text) or str(b.error) or "error" }
        end
    end
    return blocks
end

--- Images carried by a message's content (user messages only).
--- @param content unknown
--- @return { mimeType: string, data: string }[]|nil
local function images_of(content)
    local out = {}
    for _, raw in ipairs(arr(content)) do
        local b = rec(raw) or {}
        if str(b.type) == "image" and type(b.data) == "string" and type(b.mimeType) == "string" then
            out[#out + 1] = { mimeType = b.mimeType, data = b.data }
        end
    end
    if #out == 0 then
        return nil
    end
    return out
end

--- Accumulate one assistant message's usage into the session totals.
--- @param state table SessionState
--- @param usage unknown
local function add_usage(state, usage)
    local u = rec(usage)
    if not u then
        return
    end
    local totals = state.usage
    totals.input = totals.input + num(u.input)
    totals.output = totals.output + num(u.output)
    totals.cacheRead = totals.cacheRead + num(u.cacheRead)
    totals.cacheWrite = totals.cacheWrite + num(u.cacheWrite)
    local cost = rec(u.cost)
    totals.cost = totals.cost + num(cost and cost.total)
end

--- Project a tool result/partial result into the compact `ToolOutput` shape.
--- @param value unknown
--- @return pi.web.ToolOutput|nil
local function tool_output_of(value)
    local v = rec(value)
    if not v then
        return nil
    end
    local texts = {}
    for _, raw in ipairs(arr(v.content)) do
        local b = rec(raw) or {}
        if str(b.type) == "text" and type(b.text) == "string" then
            texts[#texts + 1] = b.text
        end
    end
    local out = {}
    local count = 0
    if #texts > 0 then
        out.text = table.concat(texts, "\n")
        count = count + 1
    end
    if v.details ~= nil then
        out.details = v.details
        count = count + 1
    end
    if type(v.isError) == "boolean" then
        out.isError = v.isError
        count = count + 1
    end
    if count == 0 then
        return nil
    end
    return out
end

--- @param self pi.web.State
--- @param entry_id string|nil
--- @param slot integer 1-based array position (see `block_at`)
--- @return string|nil
local function find_tool_call_id_at(self, entry_id, slot)
    for tool_call_id, loc in pairs(self._tool_blocks) do
        if loc.entry_id == entry_id and loc.index == slot then
            return tool_call_id
        end
    end
    return nil
end

--- Find the tool block for `tool_call_id`, creating it (and its entry) when it
--- is unknown to the state — e.g. an execution event whose `toolcall_start`
--- was dropped by throttling.
--- @param self pi.web.State
--- @param tool_call_id string
--- @param entry_id string|nil preferred entry when no location is known
--- @param slot integer|nil preferred 1-based array position (see `block_at`)
--- @param ts number timestamp for a freshly created entry
--- @return pi.web.BlockTool
local function ensure_tool_block(self, tool_call_id, entry_id, slot, ts)
    local loc = self._tool_blocks[tool_call_id]
    local entry = (loc and entry_of(self, loc.entry_id)) or entry_of(self, entry_id)
    if entry and loc then
        local block = entry.blocks[loc.index]
        if block and block.type == "tool" then
            return block
        end
    end
    local target = entry or new_entry(self, "assistant", ts, {})
    local at = slot or (#target.blocks + 1)
    local block = { type = "tool", toolCallId = tool_call_id, name = "tool", state = "pending" }
    while #target.blocks < at do
        target.blocks[#target.blocks + 1] = { type = "text", text = "" }
    end
    target.blocks[at] = block
    self._tool_blocks[tool_call_id] = { entry_id = target.id, index = at }
    return block
end

--- Replace an entry's blocks with authoritative content while carrying over the
--- execution state (output / duration / state) of tool blocks, then re-index
--- them so late `tool_execution_*` events still land.
--- @param self pi.web.State
--- @param blocks pi.web.Block[]
--- @return pi.web.Block[]
local function rebuild_blocks(self, blocks)
    local out = {}
    for _, block in ipairs(blocks) do
        local tool_call_id = block.type == "tool" and block.toolCallId or nil
        local loc = tool_call_id and self._tool_blocks[tool_call_id]
        local holder = loc and entry_of(self, loc.entry_id)
        local existing = holder and loc and holder.blocks[loc.index]
        if tool_call_id and existing and existing.type == "tool" then
            if block.name and block.name ~= "" then
                existing.name = block.name
            end
            if block.args ~= nil then
                existing.args = block.args
            end
            out[#out + 1] = existing
        else
            out[#out + 1] = block
        end
    end
    -- re-index tool blocks (their positions may have changed)
    local known = {}
    for tool_call_id, loc in pairs(self._tool_blocks) do
        known[#known + 1] = { id = tool_call_id, entry_id = loc.entry_id }
    end
    for _, item in ipairs(known) do
        local at
        for i, block in ipairs(out) do
            if block.type == "tool" and block.toolCallId == item.id then
                at = i
                break
            end
        end
        if at then
            self._tool_blocks[item.id] = { entry_id = item.entry_id, index = at }
        end
    end
    return out
end

--- Event handlers, keyed by `event.type` (the switch of `applyEvent`).
--- @type table<string, function>
local handlers = {}

--- @param self pi.web.State
handlers.agent_start = function(self)
    local state = self._state
    state.status = "busy"
    state.flags.done = false
    state.flags.error = false
end

--- @param self pi.web.State
--- @param event table
handlers.agent_settled = function(self, event)
    local state = self._state
    if state.status ~= "exited" and state.status ~= "interrupted" then
        state.status = "idle"
    end
    local aborted = event.aborted == true
    state.flags.done = not aborted
    if aborted then
        state.flags.error = true
    end
end

--- @param self pi.web.State
handlers.compaction_start = function(self)
    self._state.status = "compacting"
end

--- @param self pi.web.State
handlers.compaction_end = function(self)
    local state = self._state
    if state.status == "compacting" then
        state.status = "idle"
    end
end

--- @param self pi.web.State
--- @param event table
handlers.session_info_changed = function(self, event)
    self._state.name = str(event.name) or vim.NIL
end

--- @param self pi.web.State
--- @param event table
handlers.thinking_level_changed = function(self, event)
    local level = str(event.level)
    if level then
        self._state.thinking = level
    end
end

--- @param self pi.web.State
--- @param event table
handlers.queue_update = function(self, event)
    local queue = {}
    local steer_index = 0
    for _, text in ipairs(arr(event.steering)) do
        if type(text) == "string" then
            queue[#queue + 1] = { id = "q:steer:" .. id_num(steer_index), text = text, steer = true }
        end
        steer_index = steer_index + 1
    end
    local follow_index = 0
    for _, text in ipairs(arr(event.followUp)) do
        if type(text) == "string" then
            queue[#queue + 1] = { id = "q:follow:" .. id_num(follow_index), text = text, steer = false }
        end
        follow_index = follow_index + 1
    end
    self._state.queue = queue
end

--- @param self pi.web.State
--- @param event table
--- @param ts number
handlers.message_start = function(self, event, ts)
    local msg = rec(event.message)
    if not msg then
        return
    end
    local role = str(msg.role)
    if role == "user" then
        local entry = new_entry(self, "user", ts, content_to_blocks(msg.content, ts))
        local images = images_of(msg.content)
        if images then
            entry.images = images
        end
        self._user_entry_id = entry.id
    elseif role == "assistant" then
        local entry = new_entry(self, "assistant", ts, {})
        self._assistant_entry_id = entry.id
    end
end

--- @param self pi.web.State
--- @param event table
--- @param ts number
handlers.message_update = function(self, event, ts)
    local update = rec(event.assistantMessageEvent)
    if not update then
        return
    end
    local entry = entry_of(self, self._assistant_entry_id)
    if not entry then
        return
    end
    local index = num(update.contentIndex)
    local slot = index + 1 -- protocol contentIndex is 0-based
    local update_type = str(update.type)

    if update_type == "text_start" or update_type == "thinking_start" then
        local block_type = update_type == "text_start" and "text" or "thinking"
        block_at(entry, slot, function()
            return { type = block_type, text = "" }
        end)
    elseif update_type == "text_delta" then
        append_delta(entry, slot, "text", str(update.delta) or "")
    elseif update_type == "thinking_delta" then
        append_delta(entry, slot, "thinking", str(update.delta) or "")
    elseif update_type == "text_end" or update_type == "thinking_end" then
        local block_type = update_type == "text_end" and "text" or "thinking"
        local block = block_at(entry, slot, function()
            return { type = block_type, text = "" }
        end)
        if type(update.content) == "string" then
            block.text = update.content
        end
    elseif update_type == "toolcall_start" then
        local tool_call_id = str(update.id) or ("call_" .. id_num(ts) .. "_" .. id_num(index))
        while #entry.blocks < slot do
            entry.blocks[#entry.blocks + 1] = { type = "text", text = "" }
        end
        entry.blocks[slot] = {
            type = "tool",
            toolCallId = tool_call_id,
            name = str(update.toolName) or "tool",
            state = "pending",
        }
        self._tool_blocks[tool_call_id] = { entry_id = entry.id, index = slot }
        self._tool_args[tool_call_id] = ""
    elseif update_type == "toolcall_delta" then
        local tool_call_id = find_tool_call_id_at(self, entry.id, slot)
        if tool_call_id then
            self._tool_args[tool_call_id] = (self._tool_args[tool_call_id] or "") .. (str(update.delta) or "")
        end
    elseif update_type == "toolcall_end" then
        local call = rec(update.toolCall)
        local tool_call_id = (call and str(call.id)) or find_tool_call_id_at(self, entry.id, slot)
        if not tool_call_id then
            return
        end
        local block = ensure_tool_block(self, tool_call_id, entry.id, slot, ts)
        block.name = str(call and call.name) or block.name
        if call then
            block.args = call.arguments
        end
        self._tool_args[tool_call_id] = nil
    elseif update_type == "error" then
        entry.blocks[#entry.blocks + 1] = {
            type = "error",
            text = str(update.error) or str(update.reason) or "error",
        }
    end
end

--- @param self pi.web.State
--- @param event table
--- @param ts number
handlers.tool_execution_start = function(self, event, ts)
    local tool_call_id = str(event.toolCallId)
    if not tool_call_id then
        return
    end
    local block = ensure_tool_block(self, tool_call_id, self._assistant_entry_id, nil, ts)
    block.name = str(event.toolName) or block.name
    block.args = event.args
    block.state = "running"
end

--- @param self pi.web.State
--- @param event table
--- @param ts number
handlers.tool_execution_update = function(self, event, ts)
    local tool_call_id = str(event.toolCallId)
    if not tool_call_id then
        return
    end
    local block = ensure_tool_block(self, tool_call_id, self._assistant_entry_id, nil, ts)
    local output = tool_output_of(event.partialResult)
    if output then
        block.output = output
    end
end

--- @param self pi.web.State
--- @param event table
--- @param ts number
handlers.tool_execution_end = function(self, event, ts)
    local tool_call_id = str(event.toolCallId)
    if not tool_call_id then
        return
    end
    local block = ensure_tool_block(self, tool_call_id, self._assistant_entry_id, nil, ts)
    local output = tool_output_of(event.result)
    if output then
        block.output = output
    end
    block.state = event.isError == true and "error" or "done"
    if type(event.durationMs) == "number" then
        block.durationMs = event.durationMs
    end
end

--- @param self pi.web.State
--- @param event table
--- @param ts number
handlers.message_end = function(self, event, ts)
    local msg = rec(event.message)
    if not msg then
        return
    end
    local role = str(msg.role)
    if role == "user" then
        local entry = entry_of(self, self._user_entry_id)
        if not entry then
            return
        end
        entry.blocks = content_to_blocks(msg.content, ts)
        entry.images = images_of(msg.content)
        entry.done = true
        return
    end
    if role ~= "assistant" then
        return
    end
    local entry = entry_of(self, self._assistant_entry_id)
    if not entry then
        return
    end
    entry.blocks = rebuild_blocks(self, content_to_blocks(msg.content, ts))
    entry.done = true
    add_usage(self._state, msg.usage)
end

--- @param self pi.web.State
--- @param event table
handlers["pi2:session"] = function(self, event)
    local patch = rec(event.session)
    if not patch then
        return
    end
    local state = self._state
    -- Session id migration (`tmp-N` → backend id): the projection keeps its
    -- entries, only its identity moves (the bridge announces `previousSessionId`
    -- alongside; seq/subscription migration is the instance's job).
    local session_id = str(patch.sessionId)
    if session_id and session_id ~= "" then
        state.sessionId = session_id
    end
    for _, key in ipairs({ "status", "name", "model", "thinking", "usage", "contextUsage", "flags" }) do
        if patch[key] ~= nil then
            state[key] = patch[key]
        end
    end
    if #state.attention > 0 then
        state.flags.attention = true
    end
end

--- @param self pi.web.State
--- @param event table
handlers["pi2:todo"] = function(self, event)
    local todos = {}
    for _, raw in ipairs(arr(event.todos)) do
        local t = rec(raw) or {}
        local todo = {
            content = str(t.content) or "",
            status = str(t.status) or "pending",
        }
        if type(t.activeForm) == "string" then
            todo.activeForm = t.activeForm
        end
        todos[#todos + 1] = todo
    end
    self._state.todos = todos
end

--- @param self pi.web.State
--- @param event table
handlers["pi2:batch"] = function(self, event)
    local batch = {
        batchId = str(event.batchId) or "batch",
        status = str(event.status) or "running",
        items = {},
    }
    for _, raw in ipairs(arr(event.items)) do
        local item = rec(raw) or {}
        local projected = { ref = str(item.ref) or "" }
        if type(item.name) == "string" then
            projected.name = item.name
        end
        projected.status = str(item.status) or "queued"
        if type(item.error) == "string" then
            projected.error = item.error
        end
        batch.items[#batch.items + 1] = projected
    end
    local summary = rec(event.summary)
    if summary then
        batch.summary = summary
    end
    local batches = self._state.batches
    for i, existing in ipairs(batches) do
        if existing.batchId == batch.batchId then
            batches[i] = batch
            return
        end
    end
    batches[#batches + 1] = batch
end

--- @param self pi.web.State
--- @param event table
--- @param ts number
handlers["pi2:task"] = function(self, event, ts)
    local t = rec(event.task)
    if not t then
        return
    end
    local task = {
        id = str(t.id) or "task",
        command = str(t.command) or "",
        status = str(t.status) or "running",
        startTime = num(t.startTime, ts),
    }
    if type(t.durationMs) == "number" then
        task.durationMs = t.durationMs
    end
    -- `exitCode` is present-but-null once the task finished; a missing key keeps
    -- it absent (it may still be running).
    if t.exitCode ~= nil and (t.exitCode == vim.NIL or type(t.exitCode) == "number") then
        task.exitCode = t.exitCode
    end
    if type(t.outputFile) == "string" then
        task.outputFile = t.outputFile
    end
    local tasks = self._state.tasks
    for i, existing in ipairs(tasks) do
        if existing.id == task.id then
            tasks[i] = task
            return
        end
    end
    tasks[#tasks + 1] = task
end

--- @param self pi.web.State
--- @param event table
handlers["pi2:subagents"] = function(self, event)
    self._state.subagents = arr(event.subagents)
end

--- @param self pi.web.State
--- @param event table
--- @param ts number
handlers["pi2:attention_request"] = function(self, event, ts)
    local request_id = str(event.requestId) or ("att_" .. id_num(ts))
    local item = {
        requestId = request_id,
        method = str(event.method) or "select",
    }
    if type(event.title) == "string" then
        item.title = event.title
    end
    if type(event.message) == "string" then
        item.message = event.message
    end
    if is_array(event.options) then
        item.options = event.options
    end
    if event.payload ~= nil then
        item.payload = event.payload
    end
    if type(event.timeoutSec) == "number" then
        item.timeoutSec = event.timeoutSec
    end
    item.createdAt = num(event.createdAt, ts)
    item.receivedAt = ts

    local attention = {}
    for _, existing in ipairs(self._state.attention) do
        if existing.requestId ~= request_id then
            attention[#attention + 1] = existing
        end
    end
    attention[#attention + 1] = item
    self._state.attention = attention
    self._state.flags.attention = true
end

--- @param self pi.web.State
--- @param event table
handlers["pi2:attention_resolved"] = function(self, event)
    local request_id = str(event.requestId)
    local attention = {}
    for _, existing in ipairs(self._state.attention) do
        if existing.requestId ~= request_id then
            attention[#attention + 1] = existing
        end
    end
    local state = self._state
    state.attention = attention
    state.flags.attention = #attention > 0
end

--- @param self pi.web.State
--- @param event table
handlers["pi2:process_exit"] = function(self, event)
    local code = event.code
    local clean = code == nil or code == vim.NIL or code == 0
    self._state.status = clean and "exited" or "interrupted"
    -- An exit is not a finished turn: `flags.done` stays untouched so the UI
    -- shows the hollow "exited" dot instead of a done mark (reducer.ts).
end

--- @param self pi.web.State
--- @param event table
--- @param ts number
handlers["pi2:error"] = function(self, event, ts)
    local text = str(event.message) or "error"
    local entry = entry_of(self, self._assistant_entry_id)
    if not entry then
        entry = new_entry(self, "notice", ts, {})
    end
    entry.blocks[#entry.blocks + 1] = { type = "error", text = text }
    if not self._assistant_entry_id then
        entry.done = true
    end
    self._state.flags.error = true
end

--- Apply one session event to the state.
--- @param event table a `SessionEvent` (pi event or `pi2:` derived event)
function State:apply(event)
    if type(event) ~= "table" then
        return
    end
    local handler = handlers[str(event.type)]
    if handler then
        handler(self, event, num(event.ts))
    end
end

--- Deep copy of the projected `SessionState`, safe to hand to the wire/UI.
--- @return table
function State:state()
    return vim.deepcopy(self._state)
end

--- Snapshot payload: the `SessionState` the bridge ships in `snapshot` records
--- (`pi2d/docs/protocol.md` §2/§4). Same shape as `:state()`.
--- @return table
function State:snapshot()
    return vim.deepcopy(self._state)
end

--- Create a session state.
--- @param init pi.web.StateInit
--- @return pi.web.State
function M.new(init)
    init = init or {}
    --- @type pi.web.SessionState
    local state = {
        sessionId = init.session_id or "",
        workspaceId = init.workspace_id or "",
        cwd = init.cwd or "",
        name = init.name or vim.NIL,
        status = init.status or "starting",
        flags = { attention = false, done = false, error = false },
        model = init.model or vim.NIL,
        thinking = init.thinking or vim.NIL,
        usage = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, cost = 0 },
        contextUsage = vim.NIL,
        queue = {},
        todos = {},
        tasks = {},
        batches = {},
        subagents = {},
        attention = {},
        entries = {},
    }
    return setmetatable({
        _state = state,
        _next_entry = 1,
        _assistant_entry_id = nil,
        _user_entry_id = nil,
        _tool_blocks = {},
        _tool_args = {},
    }, State)
end

return M
