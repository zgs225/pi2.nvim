---@class Pi2WebProtocol
--- Wire protocol constants shared by the plugin bridge and the state model.
--- Keep in sync with `pi2d/docs/protocol.md`.
local M = {}

M.VERSION = 1

--- Daemon -> plugin record types.
M.IN = {
    HELLO_ACK = "hello_ack",
    CMD = "cmd",
    SUB_SUBSCRIBE = "sub.subscribe",
    SUB_UNSUBSCRIBE = "sub.unsubscribe",
    INSTANCE_SHUTDOWN = "instance.shutdown",
    WORKSPACE_QUERY = "workspace.query",
    PING = "ping",
}

--- Plugin -> daemon record types.
M.OUT = {
    HELLO = "hello",
    INSTANCE_STATE = "instance_state",
    SNAPSHOT = "snapshot",
    EVENT = "event",
    ACK = "ack",
    ERROR = "error",
    BYE = "bye",
}

--- Derived event types (pi events are relayed verbatim, these are computed by the plugin).
M.DERIVED = {
    SESSION = "pi2:session",
    TODO = "pi2:todo",
    BATCH = "pi2:batch",
    TASK = "pi2:task",
    SUBAGENTS = "pi2:subagents",
    ATTENTION_REQUEST = "pi2:attention_request",
    ATTENTION_RESOLVED = "pi2:attention_resolved",
    PROCESS_EXIT = "pi2:process_exit",
    ERROR = "pi2:error",
}

--- Stable error codes (must match `pi2d/src/protocol/errors.ts`).
M.ERR = {
    BAD_REQUEST = "E_BAD_REQUEST",
    UNAUTHORIZED = "E_UNAUTHORIZED",
    FORBIDDEN = "E_FORBIDDEN",
    NOT_FOUND = "E_NOT_FOUND",
    METHOD_NOT_ALLOWED = "E_METHOD_NOT_ALLOWED",
    PROTOCOL_VERSION = "E_PROTOCOL_VERSION",
    PAYLOAD_TOO_LARGE = "E_PAYLOAD_TOO_LARGE",
    RATE_LIMITED = "E_RATE_LIMITED",
    INSTANCE_STARTING = "E_INSTANCE_STARTING",
    INSTANCE_UNMANAGED = "E_INSTANCE_UNMANAGED",
    INSTANCE_UNAVAILABLE = "E_INSTANCE_UNAVAILABLE",
    LEASE_CONFLICT = "E_LEASE",
    EXTERNAL_SESSION = "E_EXTERNAL_SESSION",
    SESSION_NOT_FOUND = "E_SESSION_NOT_FOUND",
    ATTENTION_RESOLVED = "E_ATTENTION_RESOLVED",
    UNSUPPORTED = "E_UNSUPPORTED",
    INTERNAL = "E_INTERNAL",
}

--- Session status values used by the state model and the UI.
M.STATUS = {
    STARTING = "starting",
    BUSY = "busy",
    COMPACTING = "compacting",
    IDLE = "idle",
    EXITED = "exited",
    INTERRUPTED = "interrupted",
}

--- Encode a table as a single JSONL record (no trailing newline).
--- @param record table
--- @return string
function M.encode(record)
    return vim.json.encode(record)
end

--- Decode one JSONL line. Returns nil + error string on failure.
--- @param line string
--- @return table|nil, string|nil
function M.decode(line)
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok or type(decoded) ~= "table" then
        return nil, "invalid json"
    end
    return decoded, nil
end

--- Is a record's `v` acceptable to this plugin?
---
--- Every record carries `v` (protocol §1) and the plugin speaks exactly
--- `M.VERSION`. A missing field is tolerated (older/looser producers); anything
--- else must match. A mismatch is permanent, so the bridge stops instead of
--- retrying forever against an incompatible daemon.
--- @param value any
--- @return boolean
function M.is_compatible(value)
    if value == nil then
        return true
    end
    return tonumber(value) == M.VERSION
end

--- One-line reason for a version mismatch (notify + log).
--- @param value any
--- @return string
function M.mismatch_message(value)
    return (
        "daemon speaks pi2 protocol v%s, this plugin speaks v%d — upgrade pi2d "
        .. "(`npm i -g @yuez/pi2d`, or your package manager) or pi2.nvim"
    ):format(tostring(value), M.VERSION)
end

--- Build an outbound envelope with the protocol version filled in.
--- @param kind string
--- @param fields table|nil
--- @return table
function M.envelope(kind, fields)
    local rec = { v = M.VERSION, type = kind }
    if fields then
        for k, val in pairs(fields) do
            if val ~= nil then
                rec[k] = val
            end
        end
    end
    return rec
end

return M
