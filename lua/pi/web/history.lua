--- Plugin-owned session-history pagination for the pi2 web bridge.
---
--- The daemon never reads session JSONL itself: it asks the plugin for pages of
--- raw pi session entries (format: /usr/lib/pi/docs/session-format.md). Session
--- files are JSONL — one JSON object per LF-terminated line, the first line
--- being the `{"type":"session",...}` header (metadata, *not* a tree entry).
--- Entries are returned as pi wrote them (raw decoded JSON, `vim.NIL` for JSON
--- `null`); the caller projects them.
---
--- Design notes:
---
--- * `tail()` never needs the index. It scans backwards from EOF, growing the
---   window until it has one more than the requested page (so `hasMore` is
---   exact) and never reads more than `M.TAIL_MAX_SCAN` bytes. A 54MB / 100k
---   line session therefore serves its last 20 entries in a few milliseconds.
--- * `before()`/`after()`/`slice()` use a lazily built line-offset index
---   (byte offset + byte length + entry `id` per physical line). It is built in
---   bounded slices (`M.SLICE_BYTES` / `M.SLICE_MS`) driven by `vim.schedule`,
---   so a first `index()` call returns a partial index instead of blocking the
---   event loop. `before()`/`after()` finish the build cooperatively (bounded
---   slices, `vim.wait(0)` between them) when they need lines the index has not
---   reached yet.
--- * Indices are cached in memory only, keyed by `realpath` and invalidated by
---   `(mtime, size)`. There is no on-disk cache.
--- * File I/O goes through `vim.uv` (`fs_stat`/`fs_open`/`fs_read`/`fs_close`)
---   with explicit offsets — no `vim.fn`, no whole-file reads. Multi-MB single
---   entries are read in one offset read (never queued up through string
---   concatenation), and the index scanner only ever keeps the first
---   `M.ID_PREFIX` bytes of a pending line, so a 50MB line costs no more than a
---   short one.
--- * Truncated/unparseable lines are skipped and counted (`page.skipped`), so a
---   session killed mid-write still pages correctly.
--- * The session header (`type = "session"`) is metadata, not a tree entry, so
---   it is never returned as an entry on any page.
---
--- Page shape: `{ entries = {...}, cursor = { before = <id|nil>, hasMore = bool },
--- bytes = n, duration_ms = n, skipped = n }`. `cursor.before` is the id of the
--- page's first entry and is what a subsequent `before()` call takes;
--- `cursor.hasMore` reports whether entries exist in the request's direction.

local M = {}

local uv = vim.uv or vim.loop

--- Bytes an index tick may read at most.
M.SLICE_BYTES = 4 * 1024 * 1024
--- Milliseconds of work an index tick may do at most.
M.SLICE_MS = 20
--- Granularity of the index scanner's reads: the tick's byte and time budgets
--- are re-checked after every read, so a tick cannot overshoot by a whole
--- slice, only by one read.
local READ_CHUNK = 256 * 1024
--- Hard cap on the backwards window `tail()` may scan.
M.TAIL_MAX_SCAN = 8 * 1024 * 1024
--- First backwards window `tail()` reads (grows by doubling).
M.TAIL_BLOCK = 256 * 1024
--- Leading bytes of a line the index blurs out to find its `id`.
M.ID_PREFIX = 512
--- Page size when the caller passes no limit.
M.DEFAULT_LIMIT = 50
--- Largest page a caller may request.
M.MAX_LIMIT = 500

--- `id` of a pi session entry: `{"type":"message","id":"a0b1c2d3",...}`.
local ID_PATTERN = '"id"%s*:%s*"([^"]-)"'

--- In-memory index cache: realpath → `{ size, mtime_us, index }`.
--- @type table<string, { size: integer, mtime_us: number, index: table }>
local CACHE = {}

--- @class pi.web.HistoryIndex
--- @field path string realpath of the indexed file
--- @field size integer file size the index was built for
--- @field mtime_us number file mtime (microseconds) the index was built for
--- @field offsets integer[] 0-based byte offset of each physical line start
--- @field lengths integer[] byte length of each physical line (LF excluded)
--- @field ids table<integer, string> line number → entry id (absent when the line carries none)
--- @field count integer number of indexed physical lines
--- @field complete boolean the whole file has been scanned
--- @field error string|nil scan failure (the build stops, the index stays partial)
--- @field steps integer number of ticks run
--- @field max_slice_ms number longest tick
--- @field max_slice_bytes integer most bytes read by one tick
--- @field total_ms number total scanning time
--- @field _fd integer|nil open descriptor during the build
--- @field _pos integer next byte to scan
--- @field _pending_start integer start offset of the not-yet-terminated line
--- @field _prefix string leading bytes of the pending line
--- @field _tick boolean a scheduled tick is queued
--- @field _stepping boolean a tick is running right now

--- @class pi.web.HistoryPage
--- @field entries table[] decoded entries, in file order
--- @field cursor { before: string|nil, hasMore: boolean }
--- @field bytes integer bytes read while serving the page
--- @field duration_ms number wall time spent serving the page
--- @field skipped integer unparseable lines skipped while serving the page

--- Close a descriptor without raising.
--- @param fd integer|nil
local function close_fd(fd)
    if fd then
        pcall(uv.fs_close, fd)
    end
end

--- Read `len` bytes at `offset`; raises on I/O failure.
--- @param path string
--- @param offset integer
--- @param len integer
--- @return string
local function read_at(path, offset, len)
    if len <= 0 then
        return ""
    end
    local fd, err = uv.fs_open(path, "r", 0)
    if not fd then
        error(("cannot open %s: %s"):format(path, tostring(err)), 0)
    end
    local data, rerr = uv.fs_read(fd, len, offset)
    close_fd(fd)
    if type(data) ~= "string" then
        error(("cannot read %s at %d: %s"):format(path, offset, tostring(rerr)), 0)
    end
    return data
end

--- `(mtime in microseconds, size)` of a regular file, or nil.
--- @param path string
--- @return { size: integer, mtime_us: number }|nil
local function stat_of(path)
    local st = uv.fs_stat(path)
    if not st or st.type ~= "file" then
        return nil
    end
    local mtime = st.mtime or {}
    local mtime_us = (mtime.sec or 0) * 1000000 + math.floor((mtime.nsec or 0) / 1000)
    return { size = st.size, mtime_us = mtime_us }
end

--- Clamp a caller-supplied page size.
--- @param limit integer|nil
--- @return integer
local function normalize_limit(limit)
    local n = tonumber(limit) or M.DEFAULT_LIMIT
    n = math.floor(n)
    if n < 1 then
        n = 1
    elseif n > M.MAX_LIMIT then
        n = M.MAX_LIMIT
    end
    return n
end

--- Split a byte block into lines, remembering each line's absolute offset.
--- @param data string
--- @param base integer absolute offset of `data`'s first byte
--- @return { offset: integer, text: string }[]
local function split_lines(data, base)
    local out = {}
    local pos = 1
    while pos <= #data do
        local nl = data:find("\n", pos, true)
        local stop = nl and nl - 1 or #data
        out[#out + 1] = { offset = base + pos - 1, text = data:sub(pos, stop) }
        if not nl then
            break
        end
        pos = nl + 1
    end
    return out
end

--- Parse one JSONL line.
---
--- Returns nil for blank lines (`blank = true`, not an error) and nil for
--- unparseable lines (`blank = false`, the caller counts them).
--- @param text string
--- @return table|nil, boolean blank
local function parse_line(text)
    if text:match("^%s*$") then
        return nil, true
    end
    if text:sub(-1) == "\r" then
        text = text:sub(1, -2)
    end
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok or type(decoded) ~= "table" then
        return nil, false
    end
    return decoded, false
end

--- True when a decoded record is the session header. The header is metadata
--- (cwd, version, parent session), not a tree entry, so pages never return it;
--- `session` is not an entry type, only the first line of a session file.
--- @param entry table
--- @return boolean
local function is_session_header(entry)
    return entry.type == "session"
end

--- First `M.ID_PREFIX` bytes of a line, built from a pending prefix and the
--- current chunk slice. Never grows past the prefix budget.
--- @param prefix string already collected leading bytes
--- @param chunk string
--- @param from integer first byte of the line inside `chunk`
--- @param to integer last byte (inclusive) of the line inside `chunk`, may be < `from`
--- @return string
local function line_head(prefix, chunk, from, to)
    local room = M.ID_PREFIX - #prefix
    if room <= 0 or to < from then
        return prefix
    end
    return prefix .. chunk:sub(from, math.min(to, from + room - 1))
end

--- @param head string leading bytes of a line
--- @return string|nil
local function head_id(head)
    return head:match(ID_PATTERN)
end

-- ---------------------------------------------------------------------------
-- index
-- ---------------------------------------------------------------------------

--- @param path string
--- @param st { size: integer, mtime_us: number }
--- @return pi.web.HistoryIndex
local function new_index(path, st)
    return {
        path = path,
        size = st.size,
        mtime_us = st.mtime_us,
        offsets = {},
        lengths = {},
        ids = {},
        count = 0,
        complete = false,
        error = nil,
        steps = 0,
        max_slice_ms = 0,
        max_slice_bytes = 0,
        total_ms = 0,
        _fd = nil,
        _pos = 0,
        _pending_start = 0,
        _prefix = "",
        _tick = false,
        _stepping = false,
    }
end

--- Append one physical line to the index.
--- @param idx pi.web.HistoryIndex
--- @param offset integer
--- @param len integer
--- @param head string leading bytes of the line
local function push_line(idx, offset, len, head)
    local line = idx.count + 1
    idx.count = line
    idx.offsets[line] = offset
    idx.lengths[line] = len
    local id = head_id(head)
    if id then
        idx.ids[line] = id
    end
end

--- Finalize the index: record the unterminated last line (a truncated write or
--- a session without a trailing LF) and release the descriptor.
--- @param idx pi.web.HistoryIndex
local function finish_index(idx)
    if idx._pending_start < idx.size then
        push_line(idx, idx._pending_start, idx.size - idx._pending_start, idx._prefix)
        idx._pending_start = idx.size
    end
    idx._prefix = ""
    idx.complete = true
    close_fd(idx._fd)
    idx._fd = nil
end

--- Fold one read chunk into the index, recording every complete line.
--- @param idx pi.web.HistoryIndex
--- @param chunk string
--- @param base integer absolute offset of `chunk`'s first byte
local function scan_chunk(idx, chunk, base)
    local pos = 1
    while true do
        local nl = chunk:find("\n", pos, true)
        if not nl then
            break
        end
        local nl_abs = base + nl - 1
        local start = idx._pending_start
        local head = line_head(idx._prefix, chunk, pos, nl - 1)
        push_line(idx, start, nl_abs - start, head)
        idx._pending_start = nl_abs + 1
        idx._prefix = ""
        pos = nl + 1
    end
    if pos <= #chunk then
        idx._prefix = line_head(idx._prefix, chunk, pos, #chunk)
    end
end

local index_step --- @type fun(idx: pi.web.HistoryIndex): boolean
local schedule_step --- @type fun(idx: pi.web.HistoryIndex)

--- Scan one bounded slice: at most `M.SLICE_BYTES` bytes or `M.SLICE_MS` of
--- work. Never blocks longer than that.
--- @param idx pi.web.HistoryIndex
--- @return boolean advanced whether new bytes were indexed
function index_step(idx)
    if idx.complete or idx.error or idx._stepping then
        return false
    end
    idx._stepping = true
    local t0 = uv.hrtime()
    local deadline = t0 + M.SLICE_MS * 1e6
    local read = 0
    local ok, err = pcall(function()
        if not idx._fd then
            local fd, oerr = uv.fs_open(idx.path, "r", 0)
            if not fd then
                error(("cannot open %s: %s"):format(idx.path, tostring(oerr)), 0)
            end
            idx._fd = fd
        end
        while idx._pos < idx.size do
            local want = math.min(M.SLICE_BYTES - read, READ_CHUNK, idx.size - idx._pos)
            local chunk, rerr = uv.fs_read(idx._fd, want, idx._pos)
            if type(chunk) ~= "string" or chunk == "" then
                error(("cannot read %s at %d: %s"):format(idx.path, idx._pos, tostring(rerr)), 0)
            end
            scan_chunk(idx, chunk, idx._pos)
            idx._pos = idx._pos + #chunk
            read = read + #chunk
            if read >= M.SLICE_BYTES or uv.hrtime() >= deadline then
                break
            end
        end
        if idx._pos >= idx.size then
            finish_index(idx)
        end
    end)
    idx._stepping = false
    if not ok then
        idx.error = tostring(err)
        close_fd(idx._fd)
        idx._fd = nil
    end
    local ms = (uv.hrtime() - t0) / 1e6
    idx.steps = idx.steps + 1
    idx.total_ms = idx.total_ms + ms
    if ms > idx.max_slice_ms then
        idx.max_slice_ms = ms
    end
    if read > idx.max_slice_bytes then
        idx.max_slice_bytes = read
    end
    return read > 0
end

--- True while `idx` is still the cached index for its file.
--- Background ticks stop for evicted indices; a reader that still holds one
--- resumes building it synchronously through `_ensure_index_complete()`.
--- @param idx pi.web.HistoryIndex
--- @return boolean
local function is_cached(idx)
    local cached = CACHE[idx.path]
    return cached ~= nil and cached.index == idx
end

--- Queue one index tick on the main loop, chaining until the build is done.
--- @param idx pi.web.HistoryIndex
function schedule_step(idx)
    if idx.complete or idx.error or idx._tick then
        return
    end
    idx._tick = true
    vim.schedule(function()
        idx._tick = false
        if idx.complete or idx.error then
            return
        end
        if idx._stepping then
            -- Another (synchronous) driver owns the build; do not interleave.
            schedule_step(idx)
            return
        end
        index_step(idx)
        if not idx.complete and not idx.error and is_cached(idx) then
            schedule_step(idx)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- reader
-- ---------------------------------------------------------------------------

--- @class pi.web.HistoryReader
--- @field path string realpath of the session file
--- @field _stat { size: integer, mtime_us: number }|nil last observed stat
--- @field _index pi.web.HistoryIndex|nil lazily built index
local Reader = {}
Reader.__index = Reader

--- Open a session file for pagination.
--- @param path string
--- @return pi.web.HistoryReader|nil, string|nil
function M.open(path)
    if type(path) ~= "string" or path == "" then
        return nil, "path is required"
    end
    local realpath = uv.fs_realpath(path) or path
    local st = stat_of(realpath)
    if not st then
        return nil, ("not a readable session file: %s"):format(path)
    end
    local reader = setmetatable({ path = realpath, _stat = st, _index = nil }, Reader)
    return reader
end

--- Drop every cached index (tests and explicit invalidation).
function M.clear_cache()
    for key in pairs(CACHE) do
        CACHE[key] = nil
    end
end

--- Re-stat the file; a changed `(mtime, size)` invalidates the cached index.
--- @return { size: integer, mtime_us: number }|nil
function Reader:_refresh()
    local st = stat_of(self.path)
    if not st then
        return nil
    end
    local old = self._stat
    self._stat = st
    if old and (old.size ~= st.size or old.mtime_us ~= st.mtime_us) then
        self._index = nil
        CACHE[self.path] = nil
    end
    return st
end

--- The line-offset index for this file, built lazily.
---
--- Returns a possibly *partial* index immediately and keeps building it on the
--- event loop: callers that need the whole file must use
--- `_ensure_index_complete()`. Returns nil when the file is gone.
--- @return pi.web.HistoryIndex|nil
function Reader:index()
    local st = self:_refresh()
    if not st then
        return nil
    end
    local idx = self._index
    if idx and idx.size == st.size and idx.mtime_us == st.mtime_us then
        if not is_cached(idx) then
            CACHE[self.path] = { size = st.size, mtime_us = st.mtime_us, index = idx }
            schedule_step(idx)
        end
        return idx
    end
    local cached = CACHE[self.path]
    if cached and cached.size == st.size and cached.mtime_us == st.mtime_us then
        self._index = cached.index
        return cached.index
    end
    idx = new_index(self.path, st)
    self._index = idx
    CACHE[self.path] = { size = st.size, mtime_us = st.mtime_us, index = idx }
    schedule_step(idx)
    return idx
end

--- Finish the index build in bounded slices, yielding between them. Returns a
--- complete index (or one carrying `error`), or nil when the file is gone.
--- @return pi.web.HistoryIndex|nil
function Reader:_ensure_index_complete()
    local idx = self:index()
    if not idx then
        return nil
    end
    while not idx.complete and not idx.error do
        if not index_step(idx) then
            break
        end
        -- Let pending timers/scheduled callbacks run between slices. A fast
        -- event context forbids vim.wait; there the per-slice budget is the
        -- only bound, which is still bounded.
        pcall(vim.wait, 0)
    end
    if not idx.complete and not idx.error then
        -- Only reachable when another driver holds the build; never hand a
        -- silently truncated index to a pager.
        idx.error = "index build stalled"
    end
    return idx
end

--- The complete index, raising when the file cannot be indexed.
--- @return pi.web.HistoryIndex
function Reader:_indexed()
    local idx = self:_ensure_index_complete()
    if not idx then
        error(("session file vanished: %s"):format(self.path), 0)
    end
    if idx.error then
        error(("cannot index %s: %s"):format(self.path, idx.error), 0)
    end
    return idx
end

--- Read and slice the exact lines `[first, last]` using the index offsets.
--- @param idx pi.web.HistoryIndex
--- @param first integer
--- @param last integer
--- @return { index: integer, text: string }[], integer bytes
function Reader:_read_lines(idx, first, last)
    first = math.max(1, first)
    last = math.min(idx.count, last)
    if last < first then
        return {}, 0
    end
    local from = idx.offsets[first]
    local to = idx.offsets[last] + idx.lengths[last]
    local data = read_at(self.path, from, to - from)
    local out = {}
    for line = first, last do
        local start = idx.offsets[line] - from + 1
        out[#out + 1] = { index = line, text = data:sub(start, start + idx.lengths[line] - 1) }
    end
    return out, #data
end

--- Parse the lines of a page in the given order, collecting decoded entries.
---
--- The session header line is never returned (it is metadata, not a tree
--- entry); blank lines are ignored; unparseable lines are counted.
--- @param lines { index: integer, text: string }[]
--- @param newest_first boolean walk the list from its end
--- @param want integer stop once this many entries were collected (`0` = all)
--- @param into table[] accumulator
--- @param stats { skipped: integer } counter, mutated
function Reader:_collect(lines, newest_first, want, into, stats)
    local n = #lines
    local step = newest_first and -1 or 1
    local i = newest_first and n or 1
    while i >= 1 and i <= n do
        local line = lines[i]
        local entry, blank = parse_line(line.text)
        if entry then
            if not is_session_header(entry) then
                into[#into + 1] = entry
            end
        elseif not blank then
            stats.skipped = stats.skipped + 1
        end
        if want > 0 and #into >= want then
            return
        end
        i = i + step
    end
end

--- Build a page record.
--- @param entries table[] decoded entries, file order
--- @param has_more boolean entries exist beyond this page in the request direction
--- @param bytes integer
--- @param skipped integer
--- @param t0 integer uv.hrtime() at request start
--- @return pi.web.HistoryPage
local function make_page(entries, has_more, bytes, skipped, t0)
    local first = entries[1]
    local before = nil
    if type(first) == "table" and type(first.id) == "string" then
        before = first.id
    end
    return {
        entries = entries,
        -- Without a usable cursor id the caller could never page again, so
        -- report the end instead of trapping it in a retry loop.
        cursor = { before = before, hasMore = has_more and before ~= nil },
        bytes = bytes,
        duration_ms = (uv.hrtime() - t0) / 1e6,
        skipped = skipped,
    }
end

--- Trim an accumulator that holds one extra entry (the `hasMore` probe) into a
--- page of at most `limit` entries, newest last / oldest first depending on the
--- direction.
--- @param acc table[] entries in collection order
--- @param newest_first boolean
--- @param limit integer
--- @param want integer
--- @return table[] entries, boolean has_more
local function page_from(acc, newest_first, limit, want)
    local has_more = #acc >= want
    local entries = {}
    if newest_first then
        -- acc = newest first → page = the newest `limit`, in file order.
        local top = math.min(#acc, limit)
        for i = top, 1, -1 do
            entries[#entries + 1] = acc[i]
        end
    else
        for i = 1, math.min(#acc, limit) do
            entries[#entries + 1] = acc[i]
        end
    end
    return entries, has_more
end

--- The newest `limit` entries, read backwards from EOF without the index.
--- @param limit integer|nil
--- @return pi.web.HistoryPage
function Reader:tail(limit)
    local t0 = uv.hrtime()
    limit = normalize_limit(limit)
    local want = limit + 1
    local st = self:_refresh()
    if not st then
        error(("session file vanished: %s"):format(self.path), 0)
    end
    local size = st.size
    local skipped = 0
    local bytes = 0
    local acc = {}
    local reached_start = size == 0
    local from = size
    local data = ""
    local window = math.min(size, M.TAIL_BLOCK)

    while true do
        local take = math.min(window - #data, from)
        if take > 0 then
            local chunk = read_at(self.path, from - take, take)
            data = chunk .. data
            from = from - take
            bytes = bytes + #chunk
        end
        acc = {}
        skipped = 0
        local lines = split_lines(data, from)
        for i = #lines, 1, -1 do
            local line = lines[i]
            local entry, blank = parse_line(line.text)
            if entry then
                if not is_session_header(entry) then
                    acc[#acc + 1] = entry
                end
            elseif not blank then
                skipped = skipped + 1
            end
            if #acc >= want then
                break
            end
        end
        reached_start = from == 0
        if #acc >= want or reached_start or window >= M.TAIL_MAX_SCAN then
            break
        end
        window = math.min(size, M.TAIL_MAX_SCAN, window * 2)
    end

    local entries, has_more = page_from(acc, true, limit, want)
    return make_page(entries, has_more or not reached_start, bytes, skipped, t0)
end

--- The line number of the entry with `id`, or nil. Linear over the indexed
--- ids: they are not sorted, and paging near the tail (the common case) also
--- has a warm index, so this is one hash lookup per physical line.
--- @param idx pi.web.HistoryIndex
--- @param id string
--- @return integer|nil
local function line_of_id(idx, id)
    for line = 1, idx.count do
        if idx.ids[line] == id then
            return line
        end
    end
    return nil
end

--- Entries older than `cursor` (nil = the newest page), `limit` of them.
--- @param cursor string|nil entry id
--- @param limit integer|nil
--- @return pi.web.HistoryPage
function Reader:before(cursor, limit)
    local t0 = uv.hrtime()
    limit = normalize_limit(limit)
    local want = limit + 1
    local idx = self:_indexed()

    local stop --- @type integer exclusive upper bound (first line not scanned)
    if cursor == nil then
        stop = idx.count + 1
    else
        local line = line_of_id(idx, cursor)
        if not line then
            return make_page({}, false, 0, 0, t0)
        end
        stop = line
    end

    local acc = {}
    local stats = { skipped = 0 }
    local bytes = 0
    local span = math.max(limit * 2, 16)
    local reached_start = stop <= 1
    while not reached_start do
        local first = math.max(1, stop - span)
        local lines, nbytes = self:_read_lines(idx, first, stop - 1)
        bytes = bytes + nbytes
        self:_collect(lines, true, want, acc, stats)
        reached_start = first == 1
        if #acc >= want or reached_start then
            break
        end
        stop = first
        span = span * 2
    end

    local entries, has_more = page_from(acc, true, limit, want)
    return make_page(entries, has_more, bytes, stats.skipped, t0)
end

--- Entries newer than `cursor` (nil = from the start of the session), `limit` of them.
--- @param cursor string|nil entry id
--- @param limit integer|nil
--- @return pi.web.HistoryPage
function Reader:after(cursor, limit)
    local t0 = uv.hrtime()
    limit = normalize_limit(limit)
    local want = limit + 1
    local idx = self:_indexed()

    local start --- @type integer first line to scan (1-based)
    if cursor == nil then
        start = 1
    else
        local line = line_of_id(idx, cursor)
        if not line then
            return make_page({}, false, 0, 0, t0)
        end
        start = line + 1
    end

    local acc = {}
    local stats = { skipped = 0 }
    local bytes = 0
    local span = math.max(limit * 2, 16)
    local finished = start > idx.count
    while not finished do
        local last = math.min(idx.count, start + span - 1)
        local lines, nbytes = self:_read_lines(idx, start, last)
        bytes = bytes + nbytes
        self:_collect(lines, false, want, acc, stats)
        finished = last >= idx.count
        if #acc >= want or finished then
            break
        end
        start = last + 1
        span = span * 2
    end

    local entries, has_more = page_from(acc, false, limit, want)
    return make_page(entries, has_more, bytes, stats.skipped, t0)
end

--- First index in `[1, n]` whose value is >= `target` (n + 1 when none).
--- @param values integer[] sorted ascending
--- @param n integer
--- @param target integer
--- @return integer
local function lower_bound(values, n, target)
    local lo, hi = 1, n + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if values[mid] < target then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

--- Whole entries whose lines start inside `[from_offset, to_offset)` and end
--- before `to_offset`. Offsets are byte offsets as reported by the index;
--- partial lines at either boundary are excluded.
--- @param from_offset integer
--- @param to_offset integer
--- @return pi.web.HistoryPage
function Reader:slice(from_offset, to_offset)
    local t0 = uv.hrtime()
    local idx = self:_indexed()
    from_offset = math.floor(tonumber(from_offset) or 0)
    to_offset = math.floor(tonumber(to_offset) or 0)
    if to_offset <= from_offset or idx.count == 0 then
        return make_page({}, false, 0, 0, t0)
    end

    local first = lower_bound(idx.offsets, idx.count, from_offset)
    -- Last line that ends at or before `to_offset`.
    local lo, hi = 1, idx.count
    local last = 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if idx.offsets[mid] + idx.lengths[mid] <= to_offset then
            last = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    if first > idx.count or last < first then
        return make_page({}, false, 0, 0, t0)
    end

    local lines, bytes = self:_read_lines(idx, first, last)
    local acc = {}
    local stats = { skipped = 0 }
    self:_collect(lines, false, 0, acc, stats)
    return make_page(acc, last < idx.count, bytes, stats.skipped, t0)
end

return M
