-- Full-tab side layout: a session opened in a fresh tab takes the whole tab
-- over instead of leaving a dead editor column between the π windows, while an
-- ordinary `:Pi` next to a file keeps the split. The borrowed window is handed
-- back with its buffer, cursor and window options when the UI hides.

local Chat = require("pi.ui.chat")
local Config = require("pi.config")
local Sessions = require("pi.ui.sessions")
local Sidebar = require("pi.ui.sidebar")
local Workspace = require("pi.ui.workspace")

local saved_side
local saved_sessions

--- Full side-layout config (a table value is used verbatim, so a partial one
--- would drop `panels`).
---@param overrides? table
local function set_side(overrides)
    Config.options.layout.side = vim.tbl_deep_extend("force", {
        position = "right",
        width = 80,
        full_tab = "auto",
        panels = {
            history = { winbar = true },
            prompt = { winbar = true },
            attachments = { winbar = true },
        },
    }, overrides or {})
end

---@return pi.Chat
local function setup_chat()
    local chat = Chat.new(vim.api.nvim_get_current_tabpage(), "side", {
        send = function()
            return true
        end,
    })
    chat:ensure_shown_and_focus_prompt()
    return chat
end

--- Leave the tab with exactly one window showing an ordinary empty buffer:
--- `plan()` declines a takeover when the only window shows a π (or otherwise
--- named/modified) buffer, so a leaked chat window from the previous test would
--- silently turn the next takeover into a split layout.
local function reset_tab_window()
    pcall(vim.cmd, "silent! only")
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local reusable = vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf) == "" and not vim.bo[buf].modified
    if not reusable then
        vim.api.nvim_set_option_value("winfixbuf", false, { win = win })
        pcall(vim.api.nvim_win_set_buf, win, vim.api.nvim_create_buf(true, false))
    end
end

---@param chat pi.Chat?
local function teardown(chat)
    if chat then
        pcall(function()
            chat._layout:hide()
        end)
        pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
        pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
        pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
    end
    local tab = vim.api.nvim_get_current_tabpage()
    pcall(Sessions.close_tab, tab)
    reset_tab_window()
    Workspace._reset()
    Sidebar._reset()
end

---@param tab pi.TabId
---@return integer[] frame windows of `tab`
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
---@return integer? the non-π window left in the tab
local function editor_win(tab)
    for _, win in ipairs(frame_wins(tab)) do
        local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
        if not vim.startswith(ft, "pi-") then
            return win
        end
    end
    return nil
end

---@return string path of a temp file holding `lines`
local function temp_file(lines)
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile(lines or { "hello", "world" }, path)
    return path
end

describe("side layout full-tab takeover", function()
    ---@type pi.Chat?
    local chat

    before_each(function()
        saved_side = vim.deepcopy(Config.options.layout.side)
        saved_sessions = vim.deepcopy(Config.options.sessions_list)
        Workspace._reset()
        Sidebar._reset()
        reset_tab_window()
    end)

    after_each(function()
        Config.options.layout.side = saved_side
        Config.options.sessions_list = saved_sessions
        Workspace._reset()
        Sidebar._reset()
        reset_tab_window()
    end)

    it("takes over an untouched tab so the chat fills it", function()
        set_side()
        local chat = setup_chat()
        local tab = vim.api.nvim_get_current_tabpage()

        assert.are.equal("full", Workspace.mode(tab))
        -- History + prompt only: the `:tabnew` window became the chat column,
        -- so no dead editor column is left between the π windows.
        assert.are.equal(2, #frame_wins(tab))
        assert.is_nil(editor_win(tab))
        assert.are.equal(chat._layout:history_win(), frame_wins(tab)[1])
    end)

    it("keeps the split when the tab shows a file", function()
        set_side()
        vim.cmd("edit " .. vim.fn.fnameescape(temp_file()))
        local chat = setup_chat()
        local tab = vim.api.nvim_get_current_tabpage()

        assert.are.equal("split", Workspace.mode(tab))
        assert.is_not_nil(editor_win(tab), "the file window stays visible")
    end)

    it("always takes over a file tab and hands the window back", function()
        set_side({ full_tab = "always" })
        local path = temp_file({ "first line", "second line", "third line" })
        vim.cmd("edit " .. vim.fn.fnameescape(path))
        local win = vim.api.nvim_get_current_win()
        local file_buf = vim.api.nvim_win_get_buf(win)
        vim.api.nvim_win_set_cursor(win, { 2, 4 })
        local view = vim.fn.winsaveview()

        local chat = setup_chat()
        local tab = vim.api.nvim_get_current_tabpage()
        assert.are.equal("full", Workspace.mode(tab))
        assert.are.equal(win, chat._layout:history_win(), "the tab's own window became the chat column")
        assert.are.not_equal(file_buf, vim.api.nvim_win_get_buf(win))

        chat:hide()

        assert.are.equal(1, #frame_wins(tab), "only the restored window is left")
        assert.are.equal(file_buf, vim.api.nvim_win_get_buf(win), "the original buffer came back")
        assert.is_false(vim.wo[win].winfixbuf, "winfixbuf cleared before the buffer switch")
        assert.is_false(vim.wo[win].winfixwidth)
        assert.is_false(vim.wo[win].winfixheight)
        assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1], "cursor restored")
        assert.are.equal(view.leftcol, vim.fn.winsaveview().leftcol)

        vim.cmd("only")
        vim.api.nvim_buf_delete(file_buf, { force = true })
        Workspace.forget(tab)
    end)

    it("never keeps the historical split layout", function()
        set_side({ full_tab = "never" })
        local chat = setup_chat()
        local tab = vim.api.nvim_get_current_tabpage()

        assert.are.equal("split", Workspace.mode(tab))
        assert.is_not_nil(editor_win(tab), "a leftover editor window remains in split mode")
    end)

    it("never takes over a tab with several windows", function()
        set_side({ full_tab = "always" })
        vim.cmd("vsplit")
        local chat = setup_chat()
        local tab = vim.api.nvim_get_current_tabpage()

        assert.are.equal("split", Workspace.mode(tab))
        -- Two original windows + the chat column (history + prompt).
        assert.are.equal(4, #frame_wins(tab))
    end)

    it("puts the side columns around the taken-over chat", function()
        set_side()
        Config.options.sessions_list =
            { mode = "side", auto_open = false, collapse_subsessions = false, position = "left", width = 30 }
        local chat = setup_chat()
        local tab = vim.api.nvim_get_current_tabpage()
        Sessions.open()

        local hwin = assert(chat._layout:history_win())
        local pwin = assert(chat._layout:prompt_win())
        local sessions = assert(Sessions.win(tab))
        assert.are.equal(3, #frame_wins(tab), "sessions + chat + prompt")
        assert.are.equal(1, vim.fn.win_screenpos(sessions)[2], "sessions column holds the left edge")
        assert.is_true(vim.fn.win_screenpos(hwin)[2] > 1, "chat column is inboard of the sessions column")
        assert.are.equal(vim.fn.win_screenpos(hwin)[2], vim.fn.win_screenpos(pwin)[2], "prompt shares the chat column")
    end)

    it("re-borrows the same window when the UI is shown again", function()
        set_side()
        local chat = setup_chat()
        local tab = vim.api.nvim_get_current_tabpage()
        local win = assert(chat._layout:history_win())

        chat:hide()
        assert.are.equal(1, #frame_wins(tab))

        chat:show()
        assert.are.equal("full", Workspace.mode(tab))
        assert.are.equal(win, chat._layout:history_win(), "the same tab window is reused")
    end)
end)
