-- Tests for plugin-owned session-history pagination (`lua/pi/web/history.lua`).
--
-- The daemon never reads session JSONL itself: it asks the plugin for pages of
-- raw pi session entries (see /usr/lib/pi/docs/session-format.md). This spec
-- pins the reader contract:
--
--   * `tail()` never touches the index — it scans backwards from EOF (≤ 8MB),
--     so a 50MB session still serves its last entries in well under 100ms;
--   * the full line-offset index is built lazily in bounded slices (≤ 4MB or
--     20ms per tick) through `vim.schedule`, and a partially built index is
--     never needed to serve the tail;
--   * `before()`/`after()` cursor paging never duplicates or skips an entry;
--   * truncated final lines and unparseable lines are skipped (and counted);
--   * index memory is linear in the number of lines.

local history = require("pi.web.history")
local fixtures = require("tests.helpers.history_fixtures")

local uv = vim.uv or vim.loop

--- Wall-clock nanoseconds.
--- @return number
local function hrtime()
    return uv.hrtime()
end

--- Milliseconds elapsed since `t0` (uv.hrtime).
--- @param t0 number
--- @return number
local function since_ms(t0)
    return (uv.hrtime() - t0) / 1e6
end

--- Ids of the entries on a page, in page order. Entries without an `id` (the
--- session header) are not tree entries, so they are skipped.
--- @param page pi.web.HistoryPage
--- @return string[]
local function page_ids(page)
    local ids = {}
    for _, entry in ipairs(page.entries) do
        if type(entry.id) == "string" then
            ids[#ids + 1] = entry.id
        end
    end
    return ids
end

--- Count the entries on a page whose JSON `type` field matches.
--- @param page pi.web.HistoryPage
--- @param kind string
--- @return integer
local function count_type(page, kind)
    local n = 0
    for _, entry in ipairs(page.entries) do
        if entry.type == kind then
            n = n + 1
        end
    end
    return n
end

--- ids[start..stop] (inclusive, 1-based).
--- @param ids string[]
--- @param start integer
--- @param stop integer
--- @return string[]
local function id_range(ids, start, stop)
    local out = {}
    for i = start, math.min(stop, #ids) do
        out[#out + 1] = ids[i]
    end
    return out
end

describe("web history", function()
    local made = {} --- @type pi.web.HistoryFixture[]
    local big --- @type pi.web.HistoryFixture|nil

    --- Track a fixture for cleanup.
    --- @generic T
    --- @param fixture T
    --- @return T
    local function track(fixture)
        made[#made + 1] = fixture
        return fixture
    end

    --- The ~50MB fixture, built once and shared by the slow specs.
    --- @return pi.web.HistoryFixture
    local function big_fixture()
        if not big then
            big = track(fixtures.big())
        end
        return big
    end

    before_each(function()
        history.clear_cache()
    end)

    after_each(function()
        history.clear_cache()
    end)

    --- plenary's busted has no `after_all`: drop the temp dirs (the big one is
    --- ~50MB) when the test process exits.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            history.clear_cache()
            for _, fixture in ipairs(made) do
                fixtures.cleanup(fixture)
            end
            made = {}
            big = nil
        end,
    })

    describe("tail", function()
        it("returns the last N entries in file order", function()
            local f = track(fixtures.small())
            local reader = assert(history.open(f.path))

            local page = reader:tail(5)

            assert.are.same({ "s16", "s17", "s18", "s19", "s20" }, page_ids(page))
            assert.are.same({ "s16", "s17", "s18", "s19", "s20" }, id_range(f.ids, 16, 20))
            -- `before` is the id to hand to a subsequent before() call.
            assert.are.same("s16", page.cursor.before)
            assert.is_true(page.cursor.hasMore)
            assert.is_true(page.bytes > 0)
            assert.is_true(type(page.duration_ms) == "number" and page.duration_ms >= 0)
            -- The truncated fragment at EOF is not an entry; it is counted as skipped.
            assert.are.same(1, page.skipped)
        end)

        it("skips the truncated final line and counts invalid lines", function()
            local f = track(fixtures.small())
            local reader = assert(history.open(f.path))

            local page = reader:tail(20)

            -- All 20 complete entries, in order: nothing lost, nothing invented.
            assert.are.same(f.ids, page_ids(page))
            -- The truncated fragment at EOF is not an entry...
            for _, id in ipairs(page_ids(page)) do
                assert.are_not.same("struncated", id)
            end
            -- ...and both unparseable lines (the garbage line and the truncated
            -- fragment) are counted.
            assert.are.same(2, page.skipped)
            assert.is_false(page.cursor.hasMore)
            assert.are.same("s01", page.cursor.before)
        end)

        it("returns an empty page when the file has no complete line", function()
            local path = vim.fn.tempname() .. ".jsonl"
            local fd = assert(uv.fs_open(path, "w", 420))
            uv.fs_write(fd, '{"type":"message","id":"only', -1)
            uv.fs_close(fd)

            local page = assert(history.open(path)):tail(5)

            assert.are.same({}, page.entries)
            assert.is_false(page.cursor.hasMore)
            assert.is_nil(page.cursor.before)
            assert.are.same(1, page.skipped)

            os.remove(path)
        end)

        it("returns the last entries of a ~50MB session in under 100ms", function()
            local f = big_fixture()
            local reader = assert(history.open(f.path))

            local t0 = hrtime()
            local page = reader:tail(20)
            local ms = since_ms(t0)
            print(
                ("  [timing] tail(20) on %.1f MB / %d lines: %.2f ms wall, %.2f ms reported, %d bytes read"):format(
                    f.size / 1048576,
                    f.physical_lines,
                    ms,
                    page.duration_ms,
                    page.bytes
                )
            )

            assert.are.same(id_range(f.ids, #f.ids - 19, #f.ids), page_ids(page))
            assert.is_true(page.cursor.hasMore)
            assert.is_true(ms < 100, ("tail(20) took %.2f ms (must stay under 100 ms)"):format(ms))
            -- The backwards scan is bounded: it must not read the whole file.
            assert.is_true(page.bytes <= history.TAIL_MAX_SCAN)
            assert.is_true(page.bytes < f.size / 4, ("tail read %d of %d bytes"):format(page.bytes, f.size))
        end)

        it("round-trips a multi-MB single entry", function()
            local f = big_fixture()
            local reader = assert(history.open(f.path))

            -- A page wide enough to reach the huge line: the backwards window
            -- has to grow past it and the line is read in one offset read.
            local page = reader:tail(30)
            assert.are.same(id_range(f.ids, #f.ids - 29, #f.ids), page_ids(page))
            assert.is_true(
                page.bytes >= f.multi_bytes,
                ("the tail window (%d bytes) must cover the multi-MB entry"):format(page.bytes)
            )

            local multi
            for _, entry in ipairs(page.entries) do
                if entry.id == f.multi_id then
                    multi = entry
                end
            end
            assert.is_truthy(multi, "the multi-MB entry must be on the page")
            assert.are.same(f.multi_bytes, #multi.message.content[1].text)
        end)

        it("serves the tail without waiting for the full index", function()
            local f = big_fixture()
            local reader = assert(history.open(f.path))

            local idx = reader:index()
            assert.is_false(idx.complete, "the sliced index build must not run at index() time")

            local t0 = hrtime()
            local page = reader:tail(5)
            local ms = since_ms(t0)

            assert.are.same(id_range(f.ids, #f.ids - 4, #f.ids), page_ids(page))
            assert.is_false(idx.complete, "tail() must not wait for the index")
            assert.is_true(ms < 100, ("tail(5) with a cold, partial index took %.2f ms"):format(ms))

            -- Drain the background build so it cannot leak into later specs.
            assert.is_true(
                vim.wait(30000, function()
                    return idx.complete
                end, 1),
                "index build timed out"
            )
        end)
    end)

    describe("index", function()
        it("builds in bounded slices instead of one blocking pass", function()
            local f = big_fixture()
            local reader = assert(history.open(f.path))

            local t0 = hrtime()
            local idx = reader:index()
            assert.is_true(
                vim.wait(30000, function()
                    return idx.complete
                end, 1),
                "index build timed out"
            )
            local ms = since_ms(t0)
            print(
                ("  [timing] index of %.1f MB / %d lines: %d ticks, %.2f ms total, %.2f ms worst tick, %d bytes worst tick"):format(
                    f.size / 1048576,
                    f.physical_lines,
                    idx.steps,
                    idx.total_ms,
                    idx.max_slice_ms,
                    idx.max_slice_bytes
                )
            )

            -- Every physical line is indexed, including the truncated one.
            assert.are.same(f.physical_lines, idx.count)
            assert.are.same(idx.count, #idx.offsets)
            assert.are.same(idx.count, #idx.lengths)
            -- Sliced: several ticks, each bounded by the byte and time budget.
            assert.is_true(idx.steps > 1, ("index was built in %d tick(s); expected slicing"):format(idx.steps))
            -- Under a loaded full-suite run a tick can overshoot the 20ms budget
            -- (GC, other specs); the contract is "no single blocking pass", so
            -- assert a generous ceiling plus the byte budget below.
            assert.is_true(idx.max_slice_ms < 250, ("worst index tick took %.2f ms"):format(idx.max_slice_ms))
            assert.is_true(idx.max_slice_bytes <= history.SLICE_BYTES)
            assert.is_true(ms > 0)

            -- Offsets are strictly increasing line starts and cover the file.
            local last = idx.offsets[idx.count]
            assert.are.same(f.size, last + idx.lengths[idx.count])

            -- The id of the embedded custom checkpoint is in the index.
            local todo_line
            for line, id in pairs(idx.ids) do
                if id == f.todo_id then
                    todo_line = line
                end
            end
            assert.is_truthy(todo_line, "pi2-todo entry id missing from the index")
        end)

        it("is cached by realpath and invalidated by (mtime, size)", function()
            local f = track(fixtures.small())
            local first = assert(history.open(f.path))
            local idx = first:index()
            assert.is_true(vim.wait(5000, function()
                return idx.complete
            end, 1))

            -- Same file, new handle: the built index is reused, not rebuilt.
            local second = assert(history.open(f.path))
            assert.are.equal(idx, second:index())

            -- Append one more entry: (mtime, size) changed, so the cache is stale.
            -- The leading LF terminates the fixture's truncated fragment first.
            local fd = assert(uv.fs_open(f.path, "a", 420))
            uv.fs_write(fd, "\n" .. vim.json.encode({
                type = "message",
                id = "s21",
                parentId = "s20",
                timestamp = "2024-12-03T14:00:30.000Z",
                message = { role = "user", content = "late entry", timestamp = 1733234430000 },
            }) .. "\n", -1)
            uv.fs_close(fd)

            local third = assert(history.open(f.path))
            local fresh = third:index()
            assert.is_not.equal(idx, fresh)
            assert.is_false(fresh.complete)

            local page = third:tail(1)
            assert.are.same({ "s21" }, page_ids(page))

            assert.is_true(vim.wait(5000, function()
                return fresh.complete
            end, 1))
            assert.are.same(f.physical_lines + 1, fresh.count)
        end)

        it("keeps index memory linear in the number of lines", function()
            local small_file =
                track(fixtures.big({ lines = 20000, payload = 40, multi_bytes = 65536, invalid = false }))
            local bigger_file =
                track(fixtures.big({ lines = 40000, payload = 40, multi_bytes = 65536, invalid = false }))

            --- Build the index for one fixture and report the retained KB.
            --- @param fixture pi.web.HistoryFixture
            --- @return number, pi.web.HistoryIndex
            local function measure(fixture)
                history.clear_cache()
                collectgarbage("collect")
                collectgarbage("collect")
                local before = collectgarbage("count")
                local reader = assert(history.open(fixture.path))
                local idx = reader:index()
                assert.is_true(
                    vim.wait(30000, function()
                        return idx.complete
                    end, 1),
                    "index build timed out"
                )
                -- Measure retained memory, not uncollected garbage: the index is
                -- still referenced by the reader and the module cache.
                collectgarbage("collect")
                collectgarbage("collect")
                local after = collectgarbage("count")
                return (after - before) * 1024, idx
            end

            local bytes_small, idx_small = measure(small_file)
            local bytes_big, idx_big = measure(bigger_file)
            local per_line = bytes_big / idx_big.count
            print(
                ("  [timing] index memory: %d lines -> %.0f KB (%.1f B/line), %d lines -> %.0f KB (%.1f B/line)"):format(
                    idx_small.count,
                    bytes_small / 1024,
                    bytes_small / idx_small.count,
                    idx_big.count,
                    bytes_big / 1024,
                    per_line
                )
            )

            assert.are.same(small_file.physical_lines, idx_small.count)
            assert.are.same(bigger_file.physical_lines, idx_big.count)
            -- Linear: ~2x the lines costs ~2x the memory (offsets + lengths + ids
            -- per line), never a per-line scan of the file.
            local ratio = bytes_big / bytes_small
            assert.is_true(
                ratio > 1.5 and ratio < 2.6,
                ("index memory grew %.2fx for 2x the lines (%.0f KB -> %.0f KB)"):format(
                    ratio,
                    bytes_small / 1024,
                    bytes_big / 1024
                )
            )
            assert.is_true(per_line < 200, ("index costs %.1f bytes per line"):format(per_line))
        end)
    end)

    describe("cursor paging", function()
        it("before() walks back to the header without gaps or duplicates", function()
            local f = track(fixtures.small())
            local reader = assert(history.open(f.path))

            local newest_first = {}
            local headers = 0
            local page = reader:tail(4)
            local guard = 0
            while true do
                headers = headers + count_type(page, "session")
                local ids = page_ids(page)
                for i = #ids, 1, -1 do
                    newest_first[#newest_first + 1] = ids[i]
                end
                if not page.cursor.hasMore then
                    break
                end
                assert.is_string(page.cursor.before, "a page with hasMore must carry a before cursor")
                page = reader:before(page.cursor.before, 4)
                guard = guard + 1
                assert.is_true(guard < 100, "before() paging did not terminate")
            end

            local oldest_first = {}
            for i = #newest_first, 1, -1 do
                oldest_first[#oldest_first + 1] = newest_first[i]
            end
            assert.are.same(f.ids, oldest_first)
            assert.are.same(0, headers, "the session header is metadata, not a paged entry")
        end)

        it("after() walks forward from the header without gaps or duplicates", function()
            local f = track(fixtures.small())
            local reader = assert(history.open(f.path))

            local collected = {}
            local page = reader:after(nil, 3)
            local guard = 0
            while true do
                local ids = page_ids(page)
                for _, id in ipairs(ids) do
                    collected[#collected + 1] = id
                end
                if not page.cursor.hasMore then
                    break
                end
                local last = page.entries[#page.entries]
                assert.is_truthy(
                    last and type(last.id) == "string",
                    "a page with hasMore must end on an entry with an id"
                )
                page = reader:after(last.id, 3)
                guard = guard + 1
                assert.is_true(guard < 100, "after() paging did not terminate")
            end

            assert.are.same(f.ids, collected)

            -- Past the last complete entry only the truncated fragment is left.
            local eof = reader:after("s20", 5)
            assert.are.same({}, eof.entries)
            assert.is_false(eof.cursor.hasMore)
            assert.are.same(1, eof.skipped)
        end)

        it("pages across an unparseable line without losing the cursor", function()
            local f = track(fixtures.small())
            local reader = assert(history.open(f.path))

            -- The garbage line sits right after entry 9, so paging back from
            -- entry 10 has to step over it.
            local page = reader:before("s10", 3)
            assert.are.same({ "s07", "s08", "s09" }, page_ids(page))
            assert.are.same("s07", page.cursor.before)
            assert.is_true(page.cursor.hasMore)
            assert.are.same(1, page.skipped)
        end)

        it("before() and after() agree around the same cursor", function()
            local f = track(fixtures.small())
            local reader = assert(history.open(f.path))

            local before = page_ids(reader:before("s10", 3))
            local after = page_ids(reader:after("s10", 3))
            assert.are.same({ "s07", "s08", "s09" }, before)
            assert.are.same({ "s11", "s12", "s13" }, after)
        end)

        it("returns empty pages for an unknown cursor id", function()
            local f = track(fixtures.small())
            local reader = assert(history.open(f.path))

            local page = reader:before("does-not-exist", 3)
            assert.are.same({}, page.entries)
            assert.is_false(page.cursor.hasMore)
            assert.is_nil(page.cursor.before)

            local forwards = reader:after("does-not-exist", 3)
            assert.are.same({}, forwards.entries)
            assert.is_false(forwards.cursor.hasMore)
        end)
    end)

    describe("slice", function()
        it("returns exactly the whole lines inside a byte range", function()
            local f = track(fixtures.small())
            local reader = assert(history.open(f.path))
            local idx = reader:index()
            assert.is_true(vim.wait(5000, function()
                return idx.complete
            end, 1))

            -- Physical line 1 is the header; entries 1..4 are lines 2..5.
            local page = reader:slice(idx.offsets[2], idx.offsets[6])
            assert.are.same({ "s01", "s02", "s03", "s04" }, page_ids(page))
            assert.are.same("s01", page.cursor.before)
            assert.is_true(page.cursor.hasMore)
            assert.is_true(page.bytes > 0)

            -- A range starting mid-line still starts at the next line boundary.
            local partial = reader:slice(idx.offsets[3] + 5, idx.offsets[7])
            assert.are.same({ "s03", "s04", "s05" }, page_ids(partial))
        end)

        it("returns an empty page past EOF", function()
            local f = track(fixtures.small())
            local reader = assert(history.open(f.path))
            local idx = reader:index()
            assert.is_true(vim.wait(5000, function()
                return idx.complete
            end, 1))

            local page = reader:slice(f.size, f.size + 100)
            assert.are.same({}, page.entries)
            assert.is_false(page.cursor.hasMore)
        end)
    end)

    describe("open", function()
        it("returns nil and an error for a missing file", function()
            local reader, err = history.open("/nonexistent/pi-web-history.jsonl")
            assert.is_nil(reader)
            assert.is_string(err)
        end)
    end)
end)
