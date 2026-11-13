-- Side-layout opening: the chat column must be carved out of the editor area,
-- never out of — or to the outside of — an already-open side panel column.
--
-- Reproduces the :PiResume cross-worktree bug: resuming a session from another
-- checkout closes the current session (hiding the chat) but the tab-level
-- :PiSessions / :PiTodo panels keep their edge claim. Re-showing the chat then
-- used `:topleft vsplit` / `:botright vsplit`, which place the new column at
-- the *outer* edge of the tab: with `layout.side.position = "left"` the chat
-- landed left of the panel column (panels on the right of the chat), and when
-- the focused window was a panel the split was carved out of that narrow
-- column, squeezing it to a single cell.

local Chat = require("pi.ui.chat")
local Config = require("pi.config")
local Sidebar = require("pi.ui.sidebar")

local TAB = 991

local saved_side

--- Full side-layout config table (a table value is used verbatim, so a partial
--- one would drop `panels`).
---@param position "left"|"right"
---@param width number
local function set_side(position, width)
    Config.options.layout.side = {
        position = position,
        width = width,
        panels = {
            history = { winbar = true },
            prompt = { winbar = true },
            attachments = { winbar = true },
        },
    }
end

local function setup_chat()
    local chat = Chat.new(TAB, "side", {
        send = function()
            return true
        end,
    })
    chat:ensure_shown_and_focus_prompt()
    return chat
end

local function teardown_chat(chat)
    chat._layout:hide()
    pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        pcall(vim.api.nvim_win_close, win, false)
    end
    Sidebar._reset()
end

---@param win integer
---@return integer 1-based screen column
local function col(win)
    return vim.fn.win_screenpos(win)[2]
end

--- The tab's remaining non-panel, non-float window (the editor).
---@return integer?
local function editor_win()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
        if vim.api.nvim_win_get_config(win).relative == "" and not vim.startswith(ft, "pi-") then
            return win
        end
    end
    return nil
end

--- Open a panel column at `position`, claiming the tab edge, then hide the
--- chat and show it again — the window sequence a cross-checkout resume
--- performs (the panel windows outlive the session).
---@param chat pi.Chat
---@param position "left"|"right"
---@param width integer
---@return integer panel
local function panel_then_reopen(chat, position, width)
    local pwin = chat._layout:prompt_win()
    if not pwin then
        error("prompt window missing (history=" .. tostring(chat._layout:history_win()) .. ")")
    end
    vim.api.nvim_set_current_win(pwin)
    vim.cmd((position == "left" and "topleft " or "botright ") .. width .. "vsplit")
    local panel = vim.api.nvim_get_current_win()
    -- Real panel windows pin their column width (pi.ui.sessions / pi.todo).
    vim.wo[panel].winfixwidth = true
    Sidebar.claim(vim.api.nvim_get_current_tabpage(), position, "sessions", panel)
    -- A cross-checkout resume closes the chat (hiding its windows) while the
    -- panel windows and their edge claim survive.
    chat._layout:hide()
    chat:show()
    return panel
end

describe("side layout opening with a panel column already open", function()
    local chat

    before_each(function()
        saved_side = vim.deepcopy(Config.options.layout.side)
        set_side("left", 0.4)
        chat = setup_chat()
    end)

    after_each(function()
        teardown_chat(chat)
        if saved_side then
            Config.options.layout.side = saved_side
        end
    end)

    it("opens the chat column inside a left panel column", function()
        local panel = panel_then_reopen(chat, "left", 30)
        local hwin = assert(chat._layout:history_win())
        local pwin = assert(chat._layout:prompt_win())
        local ewin = assert(editor_win(), "editor window still present")

        assert.are.equal(1, col(panel), "panel column keeps the left edge")
        assert.is_true(col(hwin) > col(panel), "chat column is right of the panel column")
        assert.are.equal(col(hwin), col(pwin), "prompt shares the chat column")
        assert.is_true(col(ewin) > col(hwin), "editor stays right of the chat")
        assert.are.equal(30, vim.api.nvim_win_get_width(panel), "panel keeps its width")
    end)

    it("opens the chat column inside a right panel column", function()
        Config.options.layout.side = nil
        set_side("right", 0.4)
        chat._layout:hide()
        chat:show()
        local panel = panel_then_reopen(chat, "right", 30)
        local hwin = assert(chat._layout:history_win())
        local ewin = assert(editor_win(), "editor window still present")

        assert.is_true(col(hwin) > col(ewin), "chat column is right of the editor")
        assert.is_true(col(panel) > col(hwin), "panel column keeps the right edge")
        assert.are.equal(30, vim.api.nvim_win_get_width(panel), "panel keeps its width")
    end)

    it("keeps the historical outer edge when no panel is open", function()
        chat._layout:hide()
        chat:show()
        local hwin = assert(chat._layout:history_win())
        assert.are.equal(1, col(hwin), "left side layout opens at the left edge")

        Config.options.layout.side = nil
        set_side("right", 0.4)
        chat._layout:hide()
        chat:show()
        hwin = assert(chat._layout:history_win())
        local ewin = assert(editor_win(), "editor window still present")
        assert.is_true(col(hwin) > col(ewin), "right side layout opens at the right edge")
    end)
end)
