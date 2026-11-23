-- Unified :PiToggleChat — the toggle manages the whole π UI of a tab: the chat
-- windows *and* the tab-level side panels (sessions / tasks / todo). The panels
-- that were open when it hid the UI are remembered and reopened together with
-- the chat; a hide with no panel open remembers nothing (so a later show does
-- not resurrect a panel the user had already closed).

local Chat = require("pi.ui.chat")
local Sessions = require("pi.ui.sessions")
local Sidebar = require("pi.ui.sidebar")
local Tasks = require("pi.ui.tasks")
local Todo = require("pi.todo")
local Workspace = require("pi.ui.workspace")

---@return pi.TabId
local function current_tab()
    return vim.api.nvim_get_current_tabpage()
end

--- The chat is keyed by its tab (in production the manager builds one per
--- tabpage), so the spec constructs it with the real tab: the toggle reads the
--- tab's panel windows through that key.
---@return pi.Chat
local function setup_chat()
    local chat = Chat.new(current_tab(), "side", {
        send = function()
            return true
        end,
    })
    chat:ensure_shown_and_focus_prompt()
    return chat
end

---@param chat pi.Chat?
local function teardown_chat(chat)
    local tab = current_tab()
    pcall(Sessions.close_tab, tab)
    pcall(Tasks.close_tab, tab)
    pcall(Todo.close_tab, tab)
    if chat then
        pcall(function()
            chat._layout:hide()
        end)
        pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
        pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
        pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
    end
    pcall(vim.cmd, "only")
    Workspace._reset()
    Sidebar._reset()
    pcall(Sessions._reset)
    pcall(Tasks._reset)
    pcall(Todo._reset)
end

describe("pi.ui.chat unified UI toggle", function()
    local chat

    after_each(function()
        teardown_chat(chat)
        chat = nil
    end)

    it("hides and restores the chat together with the open side panels", function()
        chat = setup_chat()
        local tab = current_tab()
        Sessions.open()
        Tasks.open()
        assert.is_not_nil(Sessions.win(tab))
        assert.is_not_nil(Tasks.win(tab))
        assert.is_true(chat:ui_visible())

        chat:hide_ui()

        assert.is_false(chat:is_visible())
        assert.is_nil(Sessions.win(tab), "sessions panel closed with the UI")
        assert.is_nil(Tasks.win(tab), "tasks panel closed with the UI")
        assert.is_nil(Todo.win(tab))
        assert.is_false(chat:ui_visible())
        assert.same({ sessions = true, tasks = true, todo = false }, chat._hidden_panels)
        assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0), "only the editor window is left")

        chat:show_ui()

        assert.is_true(chat:is_visible())
        assert.is_not_nil(Sessions.win(tab), "sessions panel restored")
        assert.is_not_nil(Tasks.win(tab), "tasks panel restored")
        assert.is_nil(Todo.win(tab), "a panel that was closed stays closed")
        assert.is_nil(chat._hidden_panels, "the remembered set is consumed once")
    end)

    it("toggle() closes the whole UI and restores it on the second press", function()
        chat = setup_chat()
        local tab = current_tab()
        Sessions.open()
        Todo.open()
        assert.is_true(chat:is_visible())

        chat:toggle()

        assert.is_false(chat:is_visible())
        assert.is_nil(Sessions.win(tab))
        assert.is_nil(Todo.win(tab))

        chat:toggle()

        assert.is_true(chat:is_visible())
        assert.is_not_nil(Sessions.win(tab))
        assert.is_not_nil(Todo.win(tab))
    end)

    it("does not resurrect panels that were already closed", function()
        chat = setup_chat()
        local tab = current_tab()
        Sessions.open()
        Sessions.close()

        chat:hide_ui()
        assert.is_nil(chat._hidden_panels, "nothing was open, nothing remembered")

        chat:show_ui()
        assert.is_true(chat:is_visible())
        assert.is_nil(Sessions.win(tab))
        assert.is_nil(Tasks.win(tab))
        assert.is_nil(Todo.win(tab))
    end)

    it("closes the task-output splits opened from the tasks panel", function()
        chat = setup_chat()
        Tasks.open()
        -- `o` / `a` in the panel open an ordinary split on a pi-task-output
        -- buffer; the toggle owns it like the panel itself.
        local b = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(b, "pi://task-output/t1")
        vim.bo[b].buftype = "nofile"
        vim.bo[b].filetype = "pi-task-output"
        vim.cmd("vsplit")
        local output_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(output_win, b)
        assert.is_true(vim.api.nvim_win_is_valid(output_win))

        chat:hide_ui()
        assert.is_false(vim.api.nvim_win_is_valid(output_win), "task output split closed with the UI")
        assert.is_false(chat:is_visible())
    end)

    it("counts an open panel as visible UI even when the chat is hidden", function()
        chat = setup_chat()
        local tab = current_tab()
        chat:hide()
        assert.is_false(chat:is_visible())
        Sessions.open()
        assert.is_true(chat:ui_visible(), "a sessions dashboard is π UI")

        chat:toggle()
        assert.is_false(chat:ui_visible())
        assert.is_nil(Sessions.win(tab))
    end)

    it("pi.toggle_chat closes the panels when the tab has no session", function()
        local tab = current_tab()
        Sessions.open()
        assert.is_not_nil(Sessions.win(tab))
        -- No session is bound to this tab in a fresh spec process, which is the
        -- dashboard case: the toggle must still manage the π UI it can see.
        require("pi").toggle_chat()
        assert.is_nil(Sessions.win(tab))
    end)
end)
