-- Generators for pi session JSONL fixtures used by the web history specs.
--
-- `lua/pi/web/history.lua` indexes and pages session JSONL files without ever
-- involving pi itself, so its specs need real files that carry the awkward
-- bits a live session produces:
--
--   * a `session` header line (no `id`/`parentId`, not a tree entry),
--   * extension `pi2-todo` checkpoints (`custom` entries, `customType = "pi2-todo"`),
--   * a complete but unparseable line (a half-flushed record),
--   * a truncated final line — pi killed mid-write, no trailing LF,
--   * for the big fixture: ~100k short lines (~50MB) and one multi-MB single
--     entry, so the backwards tail scan and the sliced index builder are
--     exercised for real instead of on toy data.
--
-- Fixtures are written under a fresh temp dir; call `M.cleanup(fixture)` when
-- done (the big one is ~50MB on disk).

local M = {}

local uv = vim.uv or vim.loop

--- Size of the single multi-MB entry in the big fixture (bytes of text).
M.DEFAULT_MULTI_BYTES = 3 * 1024 * 1024

--- Number of message entries in the big fixture.
M.DEFAULT_BIG_LINES = 100000

--- Bytes of filler text per generated big-fixture message line.
M.DEFAULT_BIG_PAYLOAD = 240

--- @class pi.web.HistoryFixture
--- @field dir string temp dir holding the fixture
--- @field path string JSONL path
--- @field header table decoded session header record
--- @field ids string[] ids of the complete entry lines, in file order (header excluded)
--- @field entries integer number of complete entry lines (header excluded)
--- @field physical_lines integer physical line count (header + entries + invalid + truncated)
--- @field todo_id string id of the embedded `pi2-todo` custom entry
--- @field todo_index integer 1-based entry index of the `pi2-todo` entry
--- @field invalid_index integer 1-based entry index after which the invalid line sits (0 = none)
--- @field truncated boolean raw truncated fragment at EOF
--- @field multi_id string|nil id of the multi-MB entry (big fixture only)
--- @field multi_index integer|nil 1-based entry index of the multi-MB entry
--- @field multi_bytes integer|nil byte length of the multi-MB entry's text
--- @field size integer fixture file size in bytes

--- Fresh temp directory.
--- @param tag string
--- @return string
local function new_dir(tag)
    local dir = ("%s/pi-web-history-%s"):format(vim.fn.tempname(), tag)
    vim.fn.mkdir(dir, "p")
    if not uv.fs_stat(dir) then
        error("cannot create fixture dir " .. dir, 0)
    end
    return dir
end

--- @param path string
--- @return integer
local function file_size(path)
    local st = assert(uv.fs_stat(path), "fixture missing: " .. path)
    return st.size
end

--- Delete a fixture's temp dir (recursive, best effort).
--- @param fixture pi.web.HistoryFixture|nil
function M.cleanup(fixture)
    if fixture and fixture.dir then
        pcall(vim.fn.delete, fixture.dir, "rf")
    end
end

--- Session header record in the pi v3 shape.
--- @param id string
--- @return table
function M.header(id)
    return {
        type = "session",
        version = 3,
        id = id,
        timestamp = "2024-12-03T14:00:00.000Z",
        cwd = "/repo",
    }
end

--- `pi2-todo` extension checkpoint entry (extensions/todo.ts appendEntry).
--- @param id string
--- @param parent string|nil
--- @param i integer sequence number (timestamps)
--- @return table
local function todo_entry(id, parent, i)
    return {
        type = "custom",
        id = id,
        parentId = parent or vim.NIL,
        timestamp = ("2024-12-03T14:%02d:%02d.000Z"):format(math.floor(i / 60) % 60, i % 60),
        customType = "pi2-todo",
        data = {
            todos = {
                { content = "write history pagination", status = "completed" },
                { content = "make the suite green", status = "pending" },
            },
            completed = 1,
            total = 2,
        },
    }
end

--- A `message` entry with the given role/content.
--- @param id string
--- @param parent string|nil
--- @param i integer sequence number
--- @param role string
--- @param content any
--- @return table
local function message_entry(id, parent, i, role, content)
    return {
        type = "message",
        id = id,
        parentId = parent or vim.NIL,
        timestamp = ("2024-12-03T14:%02d:%02d.000Z"):format(math.floor(i / 60) % 60, i % 60),
        message = {
            role = role,
            content = content,
            timestamp = 1733234400000 + i,
        },
    }
end

--- Small fixture: header + 20 complete entries, one invalid line mid-file and a
--- truncated final line. Entry `todo_index` is a `pi2-todo` checkpoint.
--- @param opts? { truncated?: boolean, invalid?: boolean }
--- @return pi.web.HistoryFixture
function M.small(opts)
    opts = opts or {}
    local dir = new_dir("small")
    local path = dir .. "/small.jsonl"
    local header = M.header("0f00d5e1-0000-4000-8000-000000000000")
    local total = 20
    local todo_index = 4
    local invalid_after = opts.invalid == false and 0 or 9

    local lines = {}
    local ids = {}
    local parent = vim.NIL
    for i = 1, total do
        local id = ("s%02d"):format(i)
        ids[i] = id
        local entry
        if i == todo_index then
            entry = todo_entry(id, parent, i)
        elseif i == 12 then
            entry = {
                type = "label",
                id = id,
                parentId = parent,
                timestamp = "2024-12-03T14:00:12.000Z",
                targetId = "s01",
                label = "checkpoint-1",
            }
        elseif i % 3 == 0 then
            entry = message_entry(id, parent, i, "toolResult", {
                { type = "text", text = "bash output for step " .. i .. ": " .. string.rep("y", 120) },
            })
            entry.message.toolCallId = ("call_%02d"):format(i)
            entry.message.toolName = "bash"
            entry.message.isError = false
        elseif i % 2 == 0 then
            entry = message_entry(id, parent, i, "assistant", {
                { type = "text", text = "assistant reply " .. i .. ": " .. string.rep("z", 160) },
            })
            entry.message.api = "anthropic-messages"
            entry.message.provider = "anthropic"
            entry.message.model = "claude-sonnet-4-5"
            entry.message.stopReason = "stop"
        else
            entry = message_entry(id, parent, i, "user", "user prompt " .. i)
        end
        lines[#lines + 1] = vim.json.encode(entry)
        parent = id
    end

    local f = assert(io.open(path, "wb"))
    f:write(vim.json.encode(header), "\n")
    local physical = 1
    for i, line in ipairs(lines) do
        f:write(line, "\n")
        physical = physical + 1
        if i == invalid_after then
            -- Complete line, unparseable payload: no id, so no cursor can point at it.
            f:write("{not json at all}\n")
            physical = physical + 1
        end
    end
    local truncated = opts.truncated ~= false
    if truncated then
        f:write('{"type":"message","id":"struncated","parentId":"s20","message":{"role"')
        physical = physical + 1
    end
    f:close()

    --- @type pi.web.HistoryFixture
    return {
        dir = dir,
        path = path,
        header = header,
        ids = ids,
        entries = total,
        physical_lines = physical,
        todo_id = ids[todo_index],
        todo_index = todo_index,
        invalid_index = invalid_after,
        truncated = truncated,
        size = file_size(path),
    }
end

--- Big fixture: header, `opts.lines` message entries (~50MB by default), a
--- `pi2-todo` checkpoint, one multi-MB single entry, an invalid line and a
--- truncated final line.
---
--- The multi-MB entry sits 25 entries before the end (see `opts.multi_at`), so
--- the narrow `tail(20)` path never has to decode it while a wider page does.
--- @param opts? { lines?: integer, payload?: integer, multi_bytes?: integer, multi_at?: integer, todo_index?: integer, invalid?: boolean }
--- @return pi.web.HistoryFixture
function M.big(opts)
    opts = opts or {}
    local lines = opts.lines or M.DEFAULT_BIG_LINES
    local payload = opts.payload or M.DEFAULT_BIG_PAYLOAD
    local multi_bytes = opts.multi_bytes or M.DEFAULT_MULTI_BYTES
    local todo_index = opts.todo_index or math.floor(lines / 4)
    local invalid_after = opts.invalid == false and 0 or math.min(lines, 1000)
    local multi_at = math.min(lines, opts.multi_at or math.max(1, lines - 24))

    local dir = new_dir("big")
    local path = dir .. "/big.jsonl"
    local header = M.header("1b1g0000-0000-4000-8000-000000000000")

    local ids = {}
    local buf = {}
    local f = assert(io.open(path, "wb"))

    --- @param line string
    local function emit(line)
        buf[#buf + 1] = line
        if #buf >= 512 then
            f:write(table.concat(buf))
            buf = {}
        end
    end

    local function flush()
        if #buf > 0 then
            f:write(table.concat(buf))
            buf = {}
        end
    end

    --- @param id string
    --- @param i integer
    --- @return string
    local function message_line(id, i)
        return (
            '{"type":"message","id":"%s","parentId":"b%06d","timestamp":"2024-12-03T14:00:00.000Z",'
            .. '"message":{"role":"assistant","content":[{"type":"text","text":"line %06d %s"}],'
            .. '"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5",'
            .. '"stopReason":"stop","timestamp":%d}}\n'
        ):format(id, i - 1, i, string.rep("w", payload), 1733234400000 + i)
    end

    f:write(vim.json.encode(header), "\n")
    local physical = 1
    for i = 1, lines do
        local id = ("b%06d"):format(i)
        ids[#ids + 1] = id
        emit(message_line(id, i))
        physical = physical + 1
        if i == todo_index then
            ids[#ids + 1] = "btodo"
            emit(vim.json.encode(todo_entry("btodo", id, i)) .. "\n")
            physical = physical + 1
        end
        if i == invalid_after then
            emit("{not json at all}\n")
            physical = physical + 1
        end
        if i == multi_at then
            -- The multi-MB entry: one huge JSONL line, id before the payload.
            local multi_id = "bmulti"
            ids[#ids + 1] = multi_id
            emit(
                (
                    '{"type":"message","id":"%s","parentId":"%s","timestamp":"2024-12-03T14:00:00.000Z",'
                    .. '"message":{"role":"assistant","content":[{"type":"text","text":"%s"}],'
                    .. '"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5",'
                    .. '"stopReason":"stop","timestamp":1733234499999}}\n'
                ):format(multi_id, id, string.rep("M", multi_bytes))
            )
            physical = physical + 1
        end
    end

    local multi_id = "bmulti"
    ids[#ids + 1] = "blabel"
    emit(vim.json.encode({
        type = "label",
        id = "blabel",
        parentId = ("b%06d"):format(lines),
        timestamp = "2024-12-03T14:00:20.000Z",
        targetId = "b000001",
        label = "after-big-entry",
    }) .. "\n")
    physical = physical + 1 -- the label entry
    flush()
    f:write('{"type":"message","id":"btruncated","parentId":"blabel","message":{"role":')
    physical = physical + 1 -- the unterminated final fragment
    f:close()

    local multi_index = multi_at + 2 -- +1 for the todo checkpoint in front of it
    --- @type pi.web.HistoryFixture
    return {
        dir = dir,
        path = path,
        header = header,
        ids = ids,
        entries = lines + 3, -- messages + todo + multi + label
        physical_lines = physical,
        todo_id = "btodo",
        todo_index = todo_index + 1,
        invalid_index = invalid_after,
        truncated = true,
        multi_id = multi_id,
        multi_index = multi_index,
        multi_bytes = multi_bytes,
        size = file_size(path),
    }
end

return M
