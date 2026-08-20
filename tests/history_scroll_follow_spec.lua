-- Auto-follow state (issue #90): streaming must follow the bottom only while
-- the user is pinned there. The old proximity heuristic (cursor within 10
-- lines of the bottom) made h/j/k/l unusable during streaming — every render
-- event snapped the cursor back, and escaping required moving >10 lines
-- within one 30ms flush window.

local History = require("pi.ui.chat.history")

local TAB = 961

local function pump(ms)
    vim.wait(ms or 50)
end

describe("history auto-follow state (issue #90)", function()
    ---@type pi.ChatHistory
    local h
    local win

    before_each(function()
        h = History.new(TAB)
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, h:buf())
        h:set_win(win)
        h:on_agent_start(nil)
        pump(60)
    end)

    local function total()
        return vim.api.nvim_buf_line_count(h:buf())
    end

    local function cursor_line()
        return vim.api.nvim_win_get_cursor(win)[1]
    end

    --- Stream one delta and let the flush timer land it.
    local function stream(text)
        h:on_text_delta(text or "more streaming output\n")
        pump(60)
    end

    it("follows the stream while the cursor stays at the bottom", function()
        stream("chunk one\n")
        stream("chunk two\n")
        assert.are.equal(total(), cursor_line(), "cursor must ride the bottom while following")
    end)

    it("keeps the user's cursor after a single 'k' (regression)", function()
        stream("chunk one\nchunk two\nchunk three\n")
        assert.are.equal(total(), cursor_line())

        vim.api.nvim_feedkeys("kkk", "nx", false)
        -- Headless Neovim never delivers CursorMoved; the lazy drift check
        -- in _should_auto_scroll must catch the move on the next delta.
        pump(30)
        local line_after_move = cursor_line()
        assert.are.equal(total() - 3, line_after_move, "sanity: kkk moved up 3 lines")

        stream("next delta must not yank the cursor back\n")
        assert.are.equal(line_after_move, cursor_line(), "user's cursor position must survive streaming")
    end)

    it("re-enables following when the user returns to the bottom", function()
        stream("chunk one\nchunk two\n")
        vim.api.nvim_feedkeys("kk", "nx", false)
        pump(30)
        stream("detached delta\n")
        local detached = cursor_line()
        assert.is_true(detached < total(), "sanity: still detached")

        vim.api.nvim_feedkeys("G", "nx", false)
        -- Headless Neovim never delivers CursorMoved; fire it the way a
        -- real UI would so _on_cursor_moved observes the return to bottom.
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = h:buf(), modeline = false })
        pump(30)
        stream("attached again\n")
        assert.are.equal(total(), cursor_line(), "G back to the bottom must re-attach")
    end)

    it("detaches on scroll('up') and re-attaches on scroll_to_bottom()", function()
        stream("chunk one\nchunk two\n")
        assert.are.equal(total(), cursor_line())

        h:scroll("up", 2)
        pump(30)
        stream("peek delta\n")
        assert.are.equal(total() - 1, cursor_line(), "scroll('up') must detach even though the cursor is at the bottom")

        h:scroll_to_bottom()
        pump(30)
        stream("attached delta\n")
        assert.are.equal(total(), cursor_line(), "scroll_to_bottom() must re-attach")
    end)

    it("scroll('down') re-attaches when the cursor is back on the last line", function()
        stream("chunk one\n")
        h:scroll("up", 2)
        assert.is_false(h._auto_follow)
        h:scroll("down", 2)
        pump(30)
        assert.is_true(h._auto_follow, "cursor never left the last line, so scrolling down re-attaches")
    end)

    it("programmatic scrolls do not look like user movement", function()
        stream("chunk one\n")
        assert.are.equal(total(), cursor_line())

        -- Our own scroll records a pending cursor; a matching CursorMoved
        -- must not toggle the follow state.
        h:scroll_to_bottom()
        pump(30)
        assert.is_true(h._auto_follow)

        -- Consecutive follow scrolls keep following on.
        stream("chunk two\n")
        stream("chunk three\n")
        assert.is_true(h._auto_follow)
        assert.are.equal(total(), cursor_line())
    end)

    it("buffer shrink above the parked cursor does not detach follow (#91)", function()
        for i = 1, 10 do
            stream("prefill " .. i .. "\n")
        end
        assert.are.equal(total(), cursor_line())
        local parked_pending = h._pending_cursor
        assert.is_truthy(parked_pending)

        -- What tool-block collapse / bash cleanup do in a real turn: delete
        -- lines above the parked cursor. The restore in _with_modifiable
        -- clamps to the new last line; the drift check must read that as
        -- our own edit, not user movement.
        h:_with_modifiable(function()
            vim.api.nvim_buf_set_lines(h:buf(), 2, 8, false, {})
        end)
        pump(30)
        assert.is_true(h._auto_follow, "shrink must not detach follow")

        stream("post-shrink content\n")
        assert.are.equal(total(), cursor_line(), "streaming must re-pin after a shrink")
    end)

    it("keeps following through a collapsing tool block into a thinking block (#91)", function()
        stream("intro text\n")

        -- A bash tool whose long output auto-collapses on end (shrinks the
        -- buffer while the cursor is parked at the bottom).
        h:on_tool_start("bash", "t-shrink", { command = "seq 1 100" })
        pump(40)
        local long_out = {}
        for i = 1, 60 do
            long_out[#long_out + 1] = "line " .. i
        end
        h:on_tool_end("bash", "t-shrink", table.concat(long_out, "\n"), false)
        pump(60)
        assert.is_true(h._auto_follow, "collapse shrink must not detach follow")

        -- Thinking block lands at the bottom afterwards; the turn keeps
        -- streaming and the view must ride the bottom.
        h:on_thinking_start()
        pump(40)
        h:on_thinking_delta("thinking about the collapsed output...")
        pump(40)
        h:on_thinking_end()
        pump(40)
        stream("final answer\n")
        assert.are.equal(total(), cursor_line(), "view must stay pinned after thinking completes")
    end)
end)
