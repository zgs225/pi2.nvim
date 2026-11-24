-- Compaction timeline panel (:PiCompactions) — lua/pi/ui/compactions.lua.
--
-- Hermetic: the session manager, the dialog and pi.compact are stubbed, so no
-- RPC process and no real agent directory is touched. Covers the pure
-- `records_from_entries` mapping, the row columns (padding, `?` estimate,
-- flattened/truncated excerpt, aborted/failed suffix, empty session text),
-- open/close/toggle per tab, the buffer-local keymaps and help overlay, every
-- row action against real headless windows, and the once-per-session
-- `get_entries` backfill.

local Panel = require("pi.ui.compactions")
local Sessions = require("pi.sessions.manager")
local Config = require("pi.config")
local Dialog = require("pi.ui.dialog")
local Notify = require("pi.notify")

local ns = vim.api.nvim_create_namespace("pi-compactions-list")

describe("compaction panel", function()
    ---@type table<string, any> saved originals, restored in after_each
    local real = {}
    ---@type table? session returned by the stubbed Sessions.get
    local session = nil
    ---@type table? state returned by the stubbed get_compaction_state
    local state = nil
    ---@type any[] Notify.info messages captured by the stub
    local notices = {}
    ---@type any[] pi.compact calls captured by the stub
    local compact_calls = {}
    ---@type any[] get_entries requests the fake rpc received
    local entry_requests = {}

    --- Fixed reference time: 2024-05-06 12:00:00 local, hour only matters.
    local T0 = 1714996800

    --- Build a live record with the fields the panel reads.
    ---@param fields table?
    ---@return pi.CompactionRecord
    local function record(fields)
        local base = {
            seq = 1,
            ts = T0,
            started_at = T0 - 12,
            duration_ms = 12000,
            reason = "threshold",
            tokens_before = 150000,
            tokens_after = 32000,
            estimated = true,
            summary = "first summary",
            summary_chars = 13,
            aborted = false,
            will_retry = false,
            turn = 1,
        }
        return vim.tbl_extend("force", base, fields or {})
    end

    --- A fake session whose rpc answers `get_entries` with `entries`.
    ---@param entries table[]?
    ---@return table
    local function fake_session(entries)
        return {
            id = "sess-1",
            session_file = "/tmp/pi-compaction-panel/session.jsonl",
            rpc = {
                send = function(_, cmd, callback)
                    if cmd.type == "get_entries" then
                        entry_requests[#entry_requests + 1] = cmd
                        callback({ success = true, data = { entries = entries or {}, leafId = "leaf" } })
                    end
                end,
            },
        }
    end

    --- One persisted compaction entry as `get_entries` returns it.
    ---@param fields table?
    ---@return table
    local function entry(fields)
        local base = {
            type = "compaction",
            id = "e1",
            timestamp = "2024-05-06T10:00:00Z",
            summary = "persisted summary",
            firstKeptEntryId = "kept-1",
            tokensBefore = 90000,
            usage = { input = 10, cost = { total = 0.001 } },
            details = { readFiles = { "a" }, modifiedFiles = { "b", "c" }, engine = "pi2" },
        }
        return vim.tbl_extend("force", base, fields or {})
    end

    --- Press a key in the current window through the real key path.
    ---@param key string
    local function press(key)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
    end

    ---@return pi.TabId
    local function current_tab()
        return vim.api.nvim_get_current_tabpage()
    end

    ---@return integer? the panel window of the current tab
    local function panel_win()
        return Panel._win(current_tab())
    end

    ---@return integer? the panel buffer of the current tab
    local function panel_buf()
        local win = panel_win()
        return win and vim.api.nvim_win_get_buf(win) or nil
    end

    ---@return string[] panel buffer lines of the current tab
    local function panel_lines()
        local b = panel_buf()
        if not b then
            return {}
        end
        return vim.api.nvim_buf_get_lines(b, 0, -1, false)
    end

    ---@return string
    local function panel_text()
        return table.concat(panel_lines(), "\n")
    end

    --- Highlight groups the panel namespace put on a 1-based buffer line.
    ---@param lnum integer
    ---@return table<string, boolean>
    local function hls_on_line(lnum)
        local groups = {}
        local marks = vim.api.nvim_buf_get_extmarks(
            panel_buf(),
            ns,
            { lnum - 1, 0 },
            { lnum - 1, -1 },
            { details = true }
        )
        for _, mark in ipairs(marks) do
            local hl = mark[4] and mark[4].hl_group
            if hl then
                groups[hl] = true
            end
        end
        return groups
    end

    --- Place the cursor on the Nth record row of the panel (1 = newest).
    ---@param index integer
    local function cursor_on_row(index)
        local win = panel_win()
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { Panel._header_lines() + index, 0 })
    end

    --- The panel buffer without worrying about a window.
    ---@return integer
    local function open_panel()
        Panel.open()
        return panel_buf()
    end

    before_each(function()
        Panel._reset()
        real = {
            get = Sessions.get,
            get_compaction_state = Sessions.get_compaction_state,
            dialog_info = Dialog.info,
            notify_info = Notify.info,
            notify_error = Notify.error,
            compact = require("pi").compact,
        }
        session = { id = "sess-1" }
        state = nil
        notices = {}
        compact_calls = {}
        entry_requests = {}
        Sessions.get = function()
            return session
        end
        Sessions.get_compaction_state = function()
            return state
        end
        Notify.info = function(msg)
            notices[#notices + 1] = msg
        end
        Notify.error = function(msg)
            notices[#notices + 1] = msg
        end
        require("pi").compact = function(focus)
            compact_calls[#compact_calls + 1] = focus
        end
    end)

    after_each(function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_is_valid(win) then
                local b = vim.api.nvim_win_get_buf(win)
                local name = vim.api.nvim_buf_get_name(b)
                if vim.bo[b].filetype == "pi-dialog" or name:find("pi://compactions", 1, true) then
                    pcall(vim.api.nvim_win_close, win, true)
                end
            end
        end
        Panel._reset()
        Config.setup({})
        Sessions.get = real.get
        Sessions.get_compaction_state = real.get_compaction_state
        Dialog.info = real.dialog_info
        Notify.info = real.notify_info
        Notify.error = real.notify_error
        require("pi").compact = real.compact
        while vim.fn.tabpagenr("$") > 1 do
            local before = vim.fn.tabpagenr("$")
            pcall(vim.cmd, "tabclose")
            if vim.fn.tabpagenr("$") >= before then
                break
            end
        end
    end)

    describe("records_from_entries", function()
        it("maps a full persisted entry", function()
            local records = Panel.records_from_entries({ entry() })
            assert.equals(1, #records)
            local rec = records[1]
            assert.equals(1, rec.seq)
            assert.equals("persisted summary", rec.summary)
            assert.equals(#"persisted summary", rec.summary_chars)
            assert.equals(90000, rec.tokens_before)
            assert.is_nil(rec.tokens_after)
            assert.is_false(rec.estimated)
            assert.equals("kept-1", rec.first_kept_entry_id)
            assert.equals(1, rec.read_files)
            assert.equals(2, rec.modified_files)
            assert.equals("pi2", rec.engine)
            assert.equals(0.001, rec.usage.cost.total)
            assert.is_false(rec.aborted)
            assert.is_false(rec.will_retry)
            -- details.reason is extension-provided; pi persists none.
            assert.equals("unknown", rec.reason)
        end)

        it("falls back when details, usage and timestamp are missing", function()
            local records = Panel.records_from_entries({ { type = "compaction", id = "bare" } })
            assert.equals(1, #records)
            local rec = records[1]
            assert.equals("", rec.summary)
            assert.equals(0, rec.tokens_before)
            assert.is_nil(rec.tokens_after)
            assert.is_nil(rec.usage)
            assert.is_nil(rec.read_files)
            assert.is_nil(rec.modified_files)
            assert.is_nil(rec.engine)
            assert.equals("unknown", rec.reason)
            assert.equals("number", type(rec.ts))
            assert.is_true(rec.ts > 0)
            assert.equals(rec.ts, rec.started_at)
        end)

        it("parses an ISO timestamp", function()
            local expected = vim.fn.strptime("%Y-%m-%dT%H:%M:%SZ", "2024-05-06T10:00:00Z")
            local records = Panel.records_from_entries({ entry() })
            assert.equals(expected, records[1].ts)
        end)

        it("keeps entry order and numbers seq sequentially, skipping non-compaction entries", function()
            local records = Panel.records_from_entries({
                { type = "message", id = "m1" },
                entry({ id = "c1", summary = "older", timestamp = "2024-05-06T08:00:00Z" }),
                entry({ id = "c2", summary = "newer", timestamp = "2024-05-06T09:00:00Z" }),
            })
            assert.equals(2, #records)
            assert.equals("older", records[1].summary)
            assert.equals(1, records[1].seq)
            assert.equals("newer", records[2].summary)
            assert.equals(2, records[2].seq)
            assert.is_true(records[2].ts > records[1].ts)
        end)
    end)

    describe("rendering", function()
        it("shows the empty session text", function()
            open_panel()
            local text = panel_text()
            assert.is_truthy(text:find("Compactions (0)", 1, true))
            assert.is_truthy(text:find("? help · q close", 1, true))
            assert.is_truthy(text:find("No compactions in this session", 1, true))
        end)

        it("renders the full column set of a record", function()
            state = {
                records = {
                    record({
                        seq = 3,
                        summary = "full summary",
                        engine = "pi2",
                        usage = { cost = { total = 0.003 } },
                        read_files = 12,
                        modified_files = 4,
                    }),
                },
            }
            open_panel()
            local lines = panel_lines()
            assert.is_truthy(lines[2]:find("Compactions (1)", 1, true))
            local row = lines[Panel._header_lines() + 1]
            local expected = table.concat({
                "  #3",
                os.date("%H:%M", T0),
                "threshold",
                "150k → 32k",
                "12s",
                "$0.003",
                "12/4 files",
                '"full summary"',
                "󰏗pi2",
            }, "  ")
            assert.equals(expected, row)
        end)

        it("pads the columns of every row to the widest cell", function()
            state = {
                records = {
                    record({ seq = 1, reason = "manual", ts = T0, tokens_after = 32000 }),
                    record({ seq = 2, reason = "threshold", ts = T0 + 60, tokens_after = 32000 }),
                },
            }
            open_panel()
            local lines = panel_lines()
            local newest = lines[Panel._header_lines() + 1]
            local older = lines[Panel._header_lines() + 2]
            assert.is_truthy(newest:find(os.date("%H:%M", T0 + 60), 1, true))
            assert.is_truthy(older:find(os.date("%H:%M", T0), 1, true))
            -- `manual` (6) is padded to `threshold` (9), then the 2-space gap.
            assert.is_truthy(older:find("manual" .. string.rep(" ", 5) .. "150k → 32k", 1, true))
        end)

        it("renders newest first", function()
            state = {
                records = {
                    record({ seq = 1, ts = T0, summary = "older one" }),
                    record({ seq = 2, ts = T0 + 600, summary = "newer one" }),
                },
            }
            open_panel()
            local lines = panel_lines()
            local header = Panel._header_lines()
            assert.is_truthy(lines[header + 1]:find("newer one", 1, true))
            assert.is_truthy(lines[header + 2]:find("older one", 1, true))
        end)

        it("shows `?` for a missing estimate and omits absent columns", function()
            local partial = record({ summary = "no estimate" })
            partial.tokens_after = nil
            partial.duration_ms = nil
            state = { records = { partial } }
            open_panel()
            local row = panel_lines()[Panel._header_lines() + 1]
            assert.is_truthy(row:find("150k → ?", 1, true))
            assert.is_nil(row:find("12s", 1, true))
            assert.is_nil(row:find("$", 1, true))
            assert.is_nil(row:find("files", 1, true))
        end)

        it("flattens and truncates the summary excerpt", function()
            local long = "first line\n  second line  " .. string.rep("x", 80)
            state = { records = { record({ summary = long }) } }
            open_panel()
            local row = panel_lines()[Panel._header_lines() + 1]
            local excerpt = row:match('"(.+)"')
            assert.is_truthy(excerpt)
            assert.equals(48, vim.fn.strdisplaywidth(excerpt))
            assert.is_truthy(excerpt:find("first line second line", 1, true))
            assert.is_truthy(excerpt:find("…", 1, true))
            assert.is_nil(excerpt:find("\n"))
        end)

        it("marks aborted and failed records in the warning group", function()
            state = {
                records = {
                    record({ seq = 1, ts = T0, summary = "went wrong", aborted = true }),
                    record({ seq = 2, ts = T0 + 60, summary = "errored out", error = "provider 500" }),
                },
            }
            open_panel()
            local lines = panel_lines()
            local header = Panel._header_lines()
            assert.is_truthy(lines[header + 1]:find("failed$"))
            assert.is_truthy(lines[header + 2]:find("aborted$"))
            assert.is_true(hls_on_line(header + 1).PiStatusLineWarning)
            assert.is_true(hls_on_line(header + 2).PiStatusLineWarning)
        end)
    end)

    describe("windows", function()
        it("opens one panel per tab and closes them independently", function()
            open_panel()
            local first_tab = current_tab()
            local first_win = panel_win()
            assert.is_truthy(first_win)
            assert.is_true(Panel.has_focus())

            vim.cmd("tabnew")
            local second_tab = current_tab()
            open_panel()
            local second_win = panel_win()
            assert.is_truthy(second_win)
            assert.are_not.equal(first_win, second_win)
            assert.equals(panel_buf(), vim.api.nvim_win_get_buf(first_win))

            Panel.close_tab(first_tab)
            assert.is_nil(Panel._win(first_tab))
            assert.is_false(vim.api.nvim_win_is_valid(first_win))
            assert.is_true(vim.api.nvim_win_is_valid(Panel._win(second_tab) or -1))

            Panel.close_tab(second_tab)
            assert.is_nil(Panel._win(second_tab))
        end)

        it("toggles open and closed", function()
            Panel.toggle()
            assert.is_truthy(panel_win())
            Panel.toggle()
            assert.is_nil(panel_win())
        end)

        it('opens in the side column when compaction.panel.mode = "side"', function()
            Config.setup({ compaction = { panel = { mode = "side", width = 50 } } })
            local tab = current_tab()
            open_panel()
            local win = panel_win()
            assert.is_truthy(win)
            -- A split (a second, non-floating window), not a float.
            assert.equals(2, #vim.api.nvim_tabpage_list_wins(tab))
            local relative = vim.api.nvim_win_get_config(win).relative
            assert.is_true(relative == nil or relative == "", "side mode is a split, not a float")
            Panel.close()
            assert.equals(1, #vim.api.nvim_tabpage_list_wins(tab))
        end)

        it("ignores a close on a tab without a panel", function()
            assert.is_nil(panel_win())
            Panel.close()
            assert.is_nil(panel_win())
            assert.has_no.errors(function()
                Panel.close_tab(current_tab())
            end)
        end)

        it("leaves no windows behind on reset", function()
            open_panel()
            Panel._reset()
            assert.is_nil(panel_win())
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
                assert.is_nil(name:find("pi://compactions", 1, true))
            end
        end)
    end)

    describe("keymaps and help", function()
        it("binds the documented keys with descriptions", function()
            open_panel()
            local expected = {
                ["<CR>"] = "Jump to this compaction in the chat history",
                gp = "Show the full compaction summary",
                d = "Diff against the previous compaction",
                y = "Copy the summary to the clipboard",
                r = "Request a new compaction with this one's focus instructions",
                q = "Close the compaction panel",
                ["?"] = "Toggle help",
            }
            local seen = {}
            for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel_buf(), "n")) do
                assert.equals(expected[map.lhs], map.desc)
                seen[map.lhs] = true
            end
            for lhs in pairs(expected) do
                assert.is_true(seen[lhs])
            end
        end)

        it("opens the help overlay on `?`", function()
            open_panel()
            local entries = Panel._help_entries()
            assert.is_true(#entries >= 7)
            press("?")
            local found = nil
            for _, win in ipairs(vim.api.nvim_list_wins()) do
                if vim.api.nvim_win_is_valid(win) then
                    local b = vim.api.nvim_win_get_buf(win)
                    if vim.bo[b].filetype == "pi-dialog" then
                        local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
                        if text:find("Toggle this help", 1, true) then
                            found = win
                        end
                    end
                end
            end
            assert.is_truthy(found)
        end)
    end)

    describe("row actions", function()
        it("jumps to the compaction under the cursor on <CR>", function()
            local captured = {}
            session = {
                id = "sess-1",
                chat = {
                    jump_to_compaction = function(_, summary, tokens_before)
                        captured.summary = summary
                        captured.tokens_before = tokens_before
                        return true
                    end,
                },
            }
            state = { records = { record({ summary = "jump me", tokens_before = 4242 }) } }
            open_panel()
            press("<CR>")
            assert.equals("jump me", captured.summary)
            assert.equals(4242, captured.tokens_before)
            assert.is_true(#notices == 0)
        end)

        it("notifies when the compaction is not in the history", function()
            session = {
                id = "sess-1",
                chat = {
                    jump_to_compaction = function()
                        return false
                    end,
                },
            }
            state = { records = { record() } }
            open_panel()
            press("<CR>")
            assert.equals("That compaction is not in the loaded history", notices[1])
        end)

        it("notifies off the rows", function()
            state = { records = { record() } }
            open_panel()
            vim.api.nvim_win_set_cursor(panel_win(), { 1, 0 })
            press("<CR>")
            assert.equals("No compaction on this line", notices[1])
        end)

        it("shows the full summary on gp", function()
            local captured = nil
            Dialog.info = function(opts)
                captured = opts
            end
            state = { records = { record({ summary = "line one\nline two" }) } }
            open_panel()
            press("gp")
            assert.equals("Compaction summary", captured.title)
            assert.same({ "line one", "line two" }, captured.lines)
        end)

        it("diffs against the previous compaction on d", function()
            local captured = nil
            Dialog.info = function(opts)
                captured = opts
            end
            state = {
                records = {
                    record({ seq = 1, ts = T0, summary = "older text" }),
                    record({ seq = 2, ts = T0 + 60, summary = "newer text" }),
                },
            }
            open_panel()
            cursor_on_row(1)
            press("d")
            assert.equals("Compaction diff (previous → this)", captured.title)
            local body = table.concat(captured.lines, "\n")
            assert.is_truthy(body:find("@@", 1, true))
            assert.is_truthy(body:find("-older text", 1, true))
            assert.is_truthy(body:find("+newer text", 1, true))
        end)

        it("notifies on d without an earlier compaction", function()
            state = { records = { record() } }
            open_panel()
            press("d")
            assert.equals("No earlier compaction to diff", notices[1])
        end)

        it("copies the summary on y", function()
            state = { records = { record({ summary = "copy this summary" }) } }
            open_panel()
            press("y")
            local plus = vim.fn.getreg("+")
            local unnamed = vim.fn.getreg('"')
            assert.is_true(plus == "copy this summary" or unnamed == "copy this summary")
            assert.equals("Compaction summary copied", notices[1])
        end)

        it("requests a compaction with the recorded focus on r", function()
            state = { records = { record({ custom_instructions = "keep the API notes" }) } }
            open_panel()
            press("r")
            assert.same({ "keep the API notes" }, compact_calls)
            assert.equals("Compaction requested", notices[1])
        end)

        it("closes the panel on q", function()
            open_panel()
            press("q")
            assert.is_nil(panel_win())
        end)
    end)

    describe("backfill", function()
        it("shows persisted compactions and asks get_entries once", function()
            session = fake_session({ entry() })
            state = nil
            open_panel()
            vim.wait(1000, function()
                return panel_text():find("persisted summary", 1, true) ~= nil
            end)
            local text = panel_text()
            assert.is_truthy(text:find("Compactions (1)", 1, true))
            assert.is_truthy(text:find("persisted summary", 1, true))
            assert.is_truthy(text:find("unknown", 1, true))
            assert.is_truthy(text:find("90k → ?", 1, true))
            assert.equals(1, #entry_requests)

            Panel.close()
            open_panel()
            vim.wait(50)
            assert.equals(1, #entry_requests)
        end)

        it("dedupes a compaction the live state already reports", function()
            session = fake_session({ entry({ tokensBefore = 150000, summary = "shared summary" }) })
            state = { records = { record({ summary = "shared summary", tokens_before = 150000 }) } }
            open_panel()
            vim.wait(1000, function()
                return panel_text():find("Compactions (1)", 1, true) ~= nil and #entry_requests == 1
            end)
            assert.is_truthy(panel_text():find("Compactions (1)", 1, true))
            assert.is_nil(panel_text():find("persisted summary", 1, true))
        end)

        it("renders without a session", function()
            session = nil
            state = nil
            open_panel()
            assert.is_truthy(panel_text():find("No compactions in this session", 1, true))
            assert.equals(0, #entry_requests)
        end)
    end)

    it("uses the configured float geometry", function()
        local compaction = Config.options.compaction or {}
        local panel_cfg = compaction.panel or {}
        assert.is_truthy(compaction.panel)
        open_panel()
        local win = panel_win()
        assert.equals(math.min(panel_cfg.width or 100, vim.o.columns - 2), vim.api.nvim_win_get_width(win))
    end)
end)
