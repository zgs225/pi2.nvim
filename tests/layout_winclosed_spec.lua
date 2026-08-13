-- Side-layout height normalization after an external window closes (issue #31).
--
-- Reproduces: with the chat in side layout, a full-width window opened from
-- the prompt column (toggleterm's horizontal terminal does `botright split`)
-- squeezes the column; closing it re-distributes the freed height to the
-- bottom window of the column — the prompt — ignoring 'winfixheight', so the
-- prompt balloons and history stays compressed until the next text change.
-- The WinClosed handler must pin both back immediately.

local Chat = require("pi.ui.chat")

local TAB = 874

--- Build a real Chat in side layout and show it (auto_open is off by
--- default, so no sessions list interferes).
local function setup_chat()
    local chat = Chat.new(TAB, "side", {
        send = function()
            return true
        end,
    })
    chat:ensure_shown_and_focus_prompt()
    return chat
end

--- Close π's windows and every split window the tests opened, keeping the
--- original main window, so tests stay hermetic.
local function teardown_chat(chat)
    chat._layout:hide()
    pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
    local wins = vim.api.nvim_list_wins()
    for i = 2, #wins do
        pcall(vim.api.nvim_win_close, wins[i], false)
    end
end

describe("side layout WinClosed height normalization (#31)", function()
    local chat

    before_each(function()
        chat = setup_chat()
    end)

    after_each(function()
        teardown_chat(chat)
    end)

    it("restores column heights after a full-width window closes", function()
        local layout = chat._layout
        local hwin = assert(layout:history_win())
        local pwin = assert(layout:prompt_win())

        local history_before = vim.api.nvim_win_get_height(hwin)
        local prompt_before = vim.api.nvim_win_get_height(pwin)
        -- The prompt starts pinned to its content height.
        assert.equals(prompt_before, chat._prompt:content_height())

        -- Reproduce toggleterm's horizontal terminal: full-width bottom split
        -- from the prompt, resized to 30% of the screen.
        vim.api.nvim_set_current_win(pwin)
        vim.cmd("botright split")
        local twin = vim.api.nvim_get_current_win()
        vim.cmd("resize " .. math.floor(vim.o.lines * 0.3))

        -- Closing the terminal is where the bug fired: the freed height went
        -- to the prompt (bottom of the column) and history stayed squeezed.
        vim.api.nvim_win_close(twin, false)
        -- The WinClosed handler defers the normalize to the next event-loop
        -- tick (the closed window's height is handed back to the frame tree
        -- only after the autocmd fires); wait for it to settle.
        vim.wait(500, function()
            return vim.api.nvim_win_get_height(pwin) == chat._prompt:content_height()
        end)
        -- Heights must be fixed already, without any text change.
        assert.equals(
            vim.api.nvim_win_get_height(pwin),
            chat._prompt:content_height(),
            "prompt pinned back to its content height"
        )
        assert.equals(vim.api.nvim_win_get_height(hwin), history_before, "history restored to its full height")
    end)

    it("is idempotent when heights are already correct", function()
        local layout = chat._layout
        local hwin = assert(layout:history_win())
        local pwin = assert(layout:prompt_win())
        local history_before = vim.api.nvim_win_get_height(hwin)
        local prompt_before = vim.api.nvim_win_get_height(pwin)

        vim.api.nvim_set_current_win(pwin)
        vim.cmd("botright split")
        local twin = vim.api.nvim_get_current_win()
        vim.api.nvim_win_close(twin, false)
        vim.wait(500, function()
            return vim.api.nvim_win_get_height(pwin) == prompt_before
        end)

        assert.equals(vim.api.nvim_win_get_height(pwin), prompt_before)
        assert.equals(vim.api.nvim_win_get_height(hwin), history_before)
    end)

    it("does not fight π's own teardown in hide()", function()
        local layout = chat._layout
        -- hide() closes π's windows; the WinClosed handler must early-return
        -- on each one (raw _*_win ids) instead of normalizing a torn-down
        -- layout or erroring.
        assert.has_no.errors(function()
            layout:hide()
        end)
        assert.is_nil(layout:history_win())
        assert.is_nil(layout:prompt_win())
    end)

    it("does not touch the column when a π window is closed externally", function()
        local layout = chat._layout
        local hwin = assert(layout:history_win())
        local pwin = assert(layout:prompt_win())
        -- A user :q on the history window leaves a broken layout; the handler
        -- must leave it alone (no normalize, no error).
        vim.api.nvim_win_close(hwin, false)
        assert.is_nil(layout:history_win())
        assert.is_not_nil(layout:prompt_win())
    end)
end)
