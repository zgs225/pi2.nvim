-- Per-tab three-column workspace (lua/pi/ui/workspace.lua).
--
-- Headless windows are real, so the spec drives the coordinator directly (no
-- RPC, no chat session) and asserts the frame geometry: where a side column
-- lands, how wide it is, how stacked panels are ordered and sized, what the
-- chat column is carved out of, and how a borrowed tab window is handed back.

local Sidebar = require("pi.ui.sidebar")
local Workspace = require("pi.ui.workspace")

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

---@return integer
local function scratch_buf()
    return vim.api.nvim_create_buf(false, true)
end

--- An ordinary (non-scratch) empty buffer: `buftype=""`, unnamed, unmodified —
--- what `:tabnew` leaves in a fresh tab.
---@return integer
local function empty_buf()
    return vim.api.nvim_create_buf(false, false)
end

---@param win integer
---@return integer 1-based screen column
local function col(win)
    return vim.fn.win_screenpos(win)[2]
end

---@param win integer
---@return integer 1-based screen row
local function row(win)
    return vim.fn.win_screenpos(win)[1]
end

---@param tab pi.TabId
---@return integer[]
local function frame_wins(tab)
    local out = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_win_get_config(win).relative == "" then
            out[#out + 1] = win
        end
    end
    return out
end

---@param tab pi.TabId
---@return integer? the non-π window (the "editor" the layout leaves behind)
local function editor_win(tab)
    for _, win in ipairs(frame_wins(tab)) do
        local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
        if not vim.startswith(ft, "pi-") then
            return win
        end
    end
    return nil
end

local saved_columns
local saved_lines

describe("pi.ui.workspace", function()
    before_each(function()
        saved_columns = vim.o.columns
        saved_lines = vim.o.lines
        Workspace._reset()
        Sidebar._reset()
        pcall(vim.cmd, "only")
        vim.o.columns = 120
    end)

    after_each(function()
        Workspace._reset()
        Sidebar._reset()
        pcall(vim.cmd, "only")
        vim.o.columns = saved_columns
        vim.o.lines = saved_lines
    end)

    describe("plan()", function()
        it("never keeps the historical split layout", function()
            vim.api.nvim_win_set_buf(0, empty_buf())
            assert.are.equal("split", Workspace.plan(current_tab(), { full_tab = "never" }))
            assert.are.equal("split", Workspace.plan(current_tab(), {}))
        end)

        it("auto takes over an untouched scratch window", function()
            vim.api.nvim_win_set_buf(0, empty_buf())
            assert.are.equal("full", Workspace.plan(current_tab(), { full_tab = "auto" }))
        end)

        it("auto declines a named buffer", function()
            local b = scratch_buf()
            vim.api.nvim_buf_set_name(b, "pi://workspace-plan-named")
            vim.api.nvim_win_set_buf(0, b)
            assert.are.equal("split", Workspace.plan(current_tab(), { full_tab = "auto" }))
        end)

        it("auto declines a modified buffer", function()
            local b = empty_buf()
            vim.api.nvim_win_set_buf(0, b)
            vim.api.nvim_buf_set_lines(b, 0, -1, false, { "draft" })
            assert.are.equal("split", Workspace.plan(current_tab(), { full_tab = "auto" }))
        end)

        it("always takes over a single window whatever it shows", function()
            local b = scratch_buf()
            vim.api.nvim_buf_set_name(b, "pi://workspace-plan-file")
            vim.api.nvim_win_set_buf(0, b)
            assert.are.equal("full", Workspace.plan(current_tab(), { full_tab = "always" }))
        end)

        it("never takes over a tab with several windows", function()
            vim.api.nvim_win_set_buf(0, empty_buf())
            vim.cmd("vsplit")
            assert.are.equal("split", Workspace.plan(current_tab(), { full_tab = "auto" }))
            assert.are.equal("split", Workspace.plan(current_tab(), { full_tab = "always" }))
        end)
    end)

    describe("side columns", function()
        it("creates a left column at the tab's left edge with the panel width", function()
            local tab = current_tab()
            local win = assert(Workspace.claim_panel(tab, "sessions", scratch_buf(), {
                edge = "left",
                width = 40,
            }))
            assert.are.equal(1, col(win))
            assert.are.equal(40, vim.api.nvim_win_get_width(win))
            assert.is_true(vim.wo[win].winfixwidth)
        end)

        it("caps a column at 40% of the editor width", function()
            local win = assert(Workspace.claim_panel(current_tab(), "sessions", scratch_buf(), {
                edge = "left",
                width = 100,
            }))
            assert.are.equal(48, vim.api.nvim_win_get_width(win))
        end)

        it("resolves a fractional column width against the editor width", function()
            local win = assert(Workspace.claim_panel(current_tab(), "tasks", scratch_buf(), {
                edge = "right",
                width = 0.25,
            }))
            assert.are.equal(30, vim.api.nvim_win_get_width(win))
        end)

        it("stacks a panel at its ORDER position whatever the open order", function()
            local tab = current_tab()
            -- Tasks (order 3) opens the column first, todo (order 2) joins it:
            -- the new window must land above the tasks panel, not below it.
            local tasks = assert(Workspace.claim_panel(tab, "tasks", scratch_buf(), {
                edge = "right",
                width = 40,
            }))
            assert.are.equal(1, #Sidebar.panels(tab, "right"))
            local todo = assert(Workspace.claim_panel(tab, "todo", scratch_buf(), {
                edge = "right",
                width = 40,
            }))
            local panels = Sidebar.panels(tab, "right")
            assert.are.equal(2, #panels)
            assert.are.equal("todo", panels[1].key)
            assert.are.equal("tasks", panels[2].key)
            assert.is_true(row(todo) < row(tasks), "todo stacked above tasks")
            assert.are.equal(
                vim.api.nvim_win_get_width(todo),
                vim.api.nvim_win_get_width(tasks),
                "both panels share the column width"
            )
        end)

        it("shares the column height by claim weight", function()
            local tab = current_tab()
            local sessions = assert(Workspace.claim_panel(tab, "sessions", scratch_buf(), {
                edge = "left",
                width = 40,
                weight = 1,
            }))
            local todo = assert(Workspace.claim_panel(tab, "todo", scratch_buf(), {
                edge = "left",
                width = 40,
                weight = 1,
            }))
            local total = Sidebar.height_budget(2)
            local hs, ht = vim.api.nvim_win_get_height(sessions), vim.api.nvim_win_get_height(todo)
            assert.are.equal(total, hs + ht)
            assert.is_true(math.abs(hs - ht) <= 1, "even split, got " .. hs .. "/" .. ht)
        end)

        it("gives the freed width back to the editor when a column closes", function()
            local tab = current_tab()
            local editor = vim.api.nvim_get_current_win()
            local before = vim.api.nvim_win_get_width(editor)
            assert(Workspace.claim_panel(tab, "sessions", scratch_buf(), { edge = "left", width = 40 }))
            Workspace.flush()
            assert.are.equal(before - 41, vim.api.nvim_win_get_width(editor), "one separator column too")
            Workspace.release_panel(tab, "sessions")
            Workspace.flush()
            assert.are.equal(before, vim.api.nvim_win_get_width(editor))
            assert.are.equal(0, #Sidebar.panels(tab, "left"))
        end)

        it("records the width spec on the panel that opened the column only", function()
            local tab = current_tab()
            assert(Workspace.claim_panel(tab, "sessions", scratch_buf(), { edge = "left", width = 40 }))
            assert(Workspace.claim_panel(tab, "todo", scratch_buf(), { edge = "left", width = 0.1 }))
            assert.are.equal(40, Sidebar.width_spec(tab, "left"))
        end)

        it("releases a column claim when its window is closed behind its back", function()
            local tab = current_tab()
            local win = assert(Workspace.claim_panel(tab, "sessions", scratch_buf(), {
                edge = "left",
                width = 40,
            }))
            vim.api.nvim_win_close(win, true)
            assert.are.equal(0, #Sidebar.panels(tab, "left"))
        end)
    end)

    describe("chat column", function()
        it("splits a column of the configured width in split mode", function()
            local tab = current_tab()
            local editor = vim.api.nvim_get_current_win()
            local center = Workspace.acquire_center(tab, { full_tab = "never", position = "right", width = 0.4 })
            assert.are.equal("split", Workspace.mode(tab))
            assert.is_false(center.borrowed)
            assert.are.equal(math.floor(120 * 0.4), vim.api.nvim_win_get_width(center.win))
            assert(editor_win(tab), "editor window still present in split mode")
            vim.api.nvim_win_close(center.win, true)
            assert.are.equal(editor, vim.api.nvim_get_current_win())
        end)

        it("borrows the tab's only window in full-tab mode and restores it", function()
            local tab = current_tab()
            local file = vim.fn.tempname() .. ".txt"
            vim.fn.writefile({ "hello", "world" }, file)
            vim.cmd("edit " .. vim.fn.fnameescape(file))
            local win = vim.api.nvim_get_current_win()
            local file_buf = vim.api.nvim_win_get_buf(win)

            local center = Workspace.acquire_center(tab, { full_tab = "always", position = "right", width = 40 })
            assert.are.equal("full", Workspace.mode(tab))
            assert.is_true(center.borrowed)
            assert.are.equal(win, center.win)
            assert.are.equal(1, #frame_wins(tab), "the tab still has exactly one frame window")

            -- What pi.ui.chat.layout does with the borrowed window: buffer
            -- first, then the π window options (winfixbuf included).
            vim.api.nvim_win_set_buf(win, scratch_buf())
            vim.api.nvim_set_option_value("winfixbuf", true, { win = win })
            vim.cmd("belowright 5split")
            local prompt = vim.api.nvim_get_current_win()
            Workspace.register_chat(tab, {
                history = win,
                prompt = prompt,
                prompt_height = function()
                    return 5
                end,
            })
            Workspace.flush()

            vim.api.nvim_win_close(prompt, true)
            Workspace.release_chat(tab)
            Workspace.flush()

            assert.are.equal(file_buf, vim.api.nvim_win_get_buf(win), "original buffer restored")
            assert.is_false(vim.wo[win].winfixbuf, "winfixbuf cleared before the buffer switch")
            assert.is_false(vim.wo[win].winfixwidth)
        end)

        it("closes the chat column it created on release (split mode)", function()
            local tab = current_tab()
            local editor = vim.api.nvim_get_current_win()
            local center = Workspace.acquire_center(tab, { full_tab = "never", position = "left", width = 40 })
            Workspace.register_chat(tab, { history = center.win, prompt_height = function() end })
            Workspace.release_chat(tab)
            Workspace.flush()
            assert.are.equal(1, #frame_wins(tab), "leftover editor only")
            assert.are.equal(editor, vim.api.nvim_get_current_win())
            assert.is_nil(Workspace.chat(tab))
        end)
    end)

    describe("height budget", function()
        it("subtracts the tabline, the command line and the statuslines", function()
            local n = 2
            local expected = vim.o.lines - vim.o.cmdheight - n
            assert.are.equal(expected, Sidebar.height_budget(n))

            -- A second tabpage shows the tabline, which costs one more row.
            vim.cmd("tabnew")
            local with_tabline = vim.o.lines - vim.o.cmdheight - 1 - n
            assert.are.equal(with_tabline, Sidebar.height_budget(n))
            assert.are.equal(expected - 1, Sidebar.height_budget(n))
            vim.cmd("tabclose")
        end)
    end)
end)
