-- Compaction summary block: the header reports what pi did (reason,
-- before → after tokens, duration) and the expanded body adds the metadata
-- rows (kept-from id, file counts, summarisation usage, retry / abort / error).
--
-- A block without a `pi.CompactionRecord` (older sessions, replayed messages)
-- must keep rendering exactly the line it always did, so every rich form is
-- asserted next to its legacy counterpart.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")

local ns = vim.api.nvim_create_namespace("pi-chat")
local TAB = 1311

local function pump(ms)
    vim.wait(ms or 30)
end

describe("history compaction block", function()
    local h

    before_each(function()
        h = History.new(TAB)
        vim.api.nvim_win_set_buf(0, h:buf())
        h:set_win(0)
    end)

    after_each(function()
        pcall(vim.api.nvim_buf_delete, h:buf(), { force = true })
        h = nil
    end)

    ---@return string
    local function icon()
        return Config.options.labels.compaction
    end

    --- Build a block's lines without touching the buffer.
    ---@param block pi.CompactionBlock
    ---@return string[]
    local function build(block)
        local lines = h:_build_compaction_lines(block)
        return lines
    end

    --- Header row for the given pieces.
    ---@param text string
    ---@return string
    local function header(text)
        return "────── " .. icon() .. " " .. text .. " ──────"
    end

    --- 0-indexed row of the block's blank margin row.
    ---@param block pi.CompactionBlock
    ---@return integer
    local function block_row(block)
        return vim.api.nvim_buf_get_extmark_by_id(h:buf(), ns, block.anchor, {})[1]
    end

    ---@return string[]
    local function buffer_lines()
        return vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
    end

    --- Text of a 0-indexed buffer row.
    ---@param row integer
    ---@return string?
    local function line_at(row)
        return buffer_lines()[row + 1]
    end

    --- First hl_group painted on a 0-indexed row.
    ---@param row integer
    ---@return string?
    local function row_hl(row)
        local marks = vim.api.nvim_buf_get_extmarks(h:buf(), ns, { row, 0 }, { row, -1 }, { details = true })
        for _, mark in ipairs(marks) do
            local hl = (mark[4] or {}).hl_group
            if hl then
                return hl
            end
        end
        return nil
    end

    describe("header", function()
        it("reports before → after, reason and duration from the record", function()
            local lines = build({
                summary = "",
                tokens_before = 150000,
                expanded = false,
                meta = { tokens_after = 42000, estimated = true, reason = "threshold", duration_ms = 63000 },
            })
            assert.are.equal("", lines[1], "row 0 stays the blank margin")
            assert.are.equal(header("compacted · 150k → 42k (est.) · threshold · 1m 03s"), lines[2])
            assert.are.equal(3, #lines)
        end)

        it("marks an estimate only when `estimated` is set", function()
            local lines = build({
                summary = "",
                tokens_before = 150000,
                expanded = false,
                meta = { tokens_after = 42000, estimated = false, reason = "manual", duration_ms = 12000 },
            })
            assert.are.equal(header("compacted · 150k → 42k · manual · 12s"), lines[2])
        end)

        it("omits the duration segment below one second or when unknown", function()
            local short = build({
                summary = "",
                tokens_before = 150000,
                expanded = false,
                meta = { tokens_after = 42000, estimated = true, reason = "manual", duration_ms = 900 },
            })
            assert.are.equal(header("compacted · 150k → 42k (est.) · manual"), short[2])

            local unknown = build({
                summary = "",
                tokens_before = 150000,
                expanded = false,
                meta = { tokens_after = 42000, estimated = true, reason = "manual" },
            })
            assert.are.equal(header("compacted · 150k → 42k (est.) · manual"), unknown[2])
        end)

        it("keeps the before-only form when the estimate is missing", function()
            local lines = build({
                summary = "",
                tokens_before = 150000,
                expanded = false,
                meta = { reason = "manual", duration_ms = 12000 },
            })
            assert.are.equal(header("compacted · 150k tokens · manual · 12s"), lines[2])
        end)

        it("renders a legacy block (no record) exactly as before", function()
            local lines = build({ summary = "", tokens_before = 150000, expanded = false })
            assert.are.equal(header("compacted · 150,000 tokens"), lines[2])
            assert.are.equal(3, #lines)
        end)
    end)

    describe("expanded body", function()
        it("lists the summary lines, then the metadata rows in report order", function()
            local lines = build({
                summary = "line one\nline two",
                tokens_before = 150000,
                expanded = true,
                meta = {
                    tokens_after = 42000,
                    estimated = true,
                    reason = "threshold",
                    duration_ms = 12300,
                    first_kept_entry_id = "e1",
                    read_files = 12,
                    modified_files = 4,
                    read_files_omitted = 10,
                    modified_files_omitted = 8,
                    usage = { input = 8200, output = 1100, cost = { total = 0.003 } },
                },
            })
            assert.are.equal(header("compacted · 150k → 42k (est.) · threshold · 12s"), lines[2])
            assert.are.equal("  line one", lines[3])
            assert.are.equal("  line two", lines[4])
            assert.are.equal("", lines[5], "one blank line separates the summary from the metadata")
            assert.are.equal("  kept from: e1", lines[6])
            assert.are.equal("  files: 12 read · 4 modified · 18 omitted", lines[7])
            assert.are.equal("  summary: 8.2k in / 1.1k out · $0.003", lines[8])
            assert.are.equal(8, #lines)
        end)

        it("drops omitted counts at zero and absent usage segments", function()
            local lines = build({
                summary = "sum",
                tokens_before = 90000,
                expanded = true,
                meta = {
                    reason = "manual",
                    read_files = 3,
                    modified_files = 0,
                    usage = { output = 900 },
                },
            })
            local body = vim.list_slice(lines, 3)
            assert.are.same({ "  sum", "", "  files: 3 read · 0 modified", "  summary: 900 out" }, body)
        end)

        it("adds no blank line when the record has no metadata to show", function()
            local lines = build({
                summary = "sum",
                tokens_before = 90000,
                expanded = true,
                meta = { reason = "manual", usage = {} },
            })
            assert.are.same({ "", header("compacted · 90k tokens · manual"), "  sum" }, lines)
        end)

        it("reports a retry, an abort and the error as warn rows", function()
            local lines = build({
                summary = "sum",
                tokens_before = 150000,
                expanded = true,
                meta = {
                    reason = "overflow",
                    will_retry = true,
                    aborted = true,
                    error = "429 Too Many Requests\nretry later",
                },
            })
            local body = vim.list_slice(lines, 3)
            assert.are.same({
                "  sum",
                "",
                "  will retry after compaction",
                "  aborted",
                "  error: 429 Too Many Requests retry later",
            }, body)
        end)

        it("flattens an error to one line of at most 120 characters", function()
            local message = ("line one\nline two  "):rep(20)
            local lines = build({
                summary = "sum",
                tokens_before = 150000,
                expanded = true,
                meta = { reason = "overflow", aborted = true, error = message },
            })
            local row = lines[#lines]
            assert.is_true(row:find("  error: line one line two line one line two", 1, true) == 1, row)
            assert.is_false(row:find("\n", 1, true) ~= nil, "the error must be flattened")
            local text = (row:gsub("^  error: ", ""))
            assert.are.equal(120, vim.fn.strchars(text))
            assert.are.equal("...", text:sub(-3))
        end)

        it("paints metadata rows soft and failure rows as warnings", function()
            h:set_blocks_expanded(true)
            h:_append_compaction_summary("sum", 150000, {
                reason = "threshold",
                tokens_after = 42000,
                estimated = true,
                duration_ms = 12300,
                first_kept_entry_id = "e1",
                read_files = 12,
                modified_files = 4,
                usage = { input = 8200, output = 1100, cost = { total = 0.003 } },
                will_retry = true,
                aborted = true,
                error = "stream closed",
            })
            local block = h:compaction_blocks()[1]
            local start = block_row(block)
            assert.are.equal("PiCompactionText", row_hl(start + 1), "header")
            assert.are.equal("PiCompactionText", row_hl(start + 2), "summary line")
            assert.are.equal("PiCompactionMeta", row_hl(start + 4), "kept from")
            assert.are.equal("PiCompactionMeta", row_hl(start + 5), "files")
            assert.are.equal("PiCompactionMeta", row_hl(start + 6), "usage")
            assert.are.equal("PiCompactionWarn", row_hl(start + 7), "will retry")
            assert.are.equal("PiCompactionWarn", row_hl(start + 8), "aborted")
            assert.are.equal("PiCompactionWarn", row_hl(start + 9), "error")
        end)
    end)

    describe("collapsing", function()
        it("shows the hint when collapsed and expands in place, keeping the anchor", function()
            h:_append_compaction_summary("first\nsecond", 150000, {
                reason = "manual",
                tokens_after = 1000,
                estimated = true,
            })
            local block = h:compaction_blocks()[1]
            local start = block_row(block)
            assert.are.equal("  Tab to expand", line_at(start + 2))
            assert.are.equal("PiCompactionHint", row_hl(start + 2))

            vim.api.nvim_win_set_cursor(0, { start + 2, 0 })
            assert.is_true(h:toggle_compaction_block())
            assert.is_true(block.expanded)
            assert.are.equal(start, block_row(block), "the anchor survives the re-render")
            assert.are.equal("  first", line_at(start + 2))
            assert.are.equal("  second", line_at(start + 3))
            local lines = buffer_lines()
            assert.are.equal(#lines - start, block.line_count, "line_count tracks the rendered rows")

            vim.api.nvim_win_set_cursor(0, { start + 2, 0 })
            assert.is_true(h:toggle_compaction_block())
            assert.is_false(block.expanded)
            assert.are.equal("  Tab to expand", line_at(start + 2))
        end)
    end)

    describe("navigation", function()
        it("finds blocks by summary + tokens and jumps to the header", function()
            h:_append_compaction_summary("sum A", 150000)
            h:_append_compaction_summary("sum B", 90000)
            local blocks = h:compaction_blocks()
            assert.are.equal(2, #blocks)

            local a = h:find_compaction_block("sum A", 150000)
            local b = h:find_compaction_block("sum B", 90000)
            assert.are.equal(blocks[1], a)
            assert.are.equal(blocks[2], b)
            assert.is_nil(h:find_compaction_block("sum A", 90000), "both keys must match")
            assert.is_nil(h:find_compaction_block("sum C", 150000))

            assert.is_true(h:jump_to_compaction("sum B", 90000))
            local row = vim.api.nvim_win_get_cursor(0)[1] - 1
            assert.are.equal(block_row(blocks[2]) + 1, row, "cursor lands on the block header")

            local before = vim.api.nvim_win_get_cursor(0)
            assert.is_false(h:jump_to_compaction("sum C", 1), "a missing block is a no-op")
            assert.are.same(before, vim.api.nvim_win_get_cursor(0))
        end)
    end)

    describe("status text", function()
        it("renders a retry's own text and keeps the run clock across the change", function()
            local models = {}
            h:set_status_listener(function(model)
                models[#models + 1] = model and vim.deepcopy(model) or nil
            end)

            h:set_status({ type = "agent", text = "Working…" }, 100)
            pump()
            assert.are.equal("Working…", models[#models].text)

            h:set_status({ type = "compaction", text = "summary retry 2/3 (429)" })
            pump()
            assert.are.equal("summary retry 2/3 (429)", models[#models].text)
            assert.are.equal(100, h._status_start_time, "a mid-run text change keeps the run clock")

            h:set_status({ type = "compaction" })
            pump()
            assert.are.equal("Compacting…", models[#models].text, "no text falls back to the default")
            assert.are.equal(100, h._status_start_time)

            h:set_status(nil)
            pump()
            assert.is_nil(h._status_start_time, "idle restarts the clock for the next run")
        end)
    end)
end)
