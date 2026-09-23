-- Regression spec for pi.ui.winfix's pi-filetype exemption (todo sidebar
-- line-number bug, wave 2a).
--
-- winfix captures the user's window-option defaults at setup() and, on
-- BufEnter, resets windows carrying pi's option fingerprint (concealcursor
-- "nvic" with number/relativenumber/cursorline off) back to those defaults.
-- Pi panel windows (todo, sessions, dialog, ...) legitimately carry that same
-- fingerprint — they set it themselves — so the handler must exempt every
-- "pi-*" filetype, not only the three chat panes. Before the fix, entering
-- the pi-sessions todo panel flipped `number` to the captured global default
-- (true for a `:set number` user) and dropped the winfixbuf/width/height
-- pins. The spec pins both directions of the contract: pi buffers are
-- exempt, user buffers still get reset.
--
-- The global `number` default is armed BEFORE setup() so a wrongful reset is
-- observable. The describes run synchronously at file load, so the restore
-- at the bottom of the file executes after the last test (the spec also runs
-- in its own nvim process; the restore is belt and braces).

local Ft = require("pi.filetypes")

--- Panel scratch buffers created by open_panel; deleted in after_each.
local panel_bufs = {}

local saved_number_global = vim.api.nvim_get_option_value("number", { scope = "global" })
local saved_number_win = vim.wo.number

vim.cmd("set number")
assert.equals(
    true,
    vim.api.nvim_get_option_value("number", { scope = "global" }),
    "global number default must be true before winfix.setup() captures it"
)
require("pi.ui.winfix").setup()

--- Read a window-local option.
---@param win integer
---@param name string
---@return any
local function wo(win, name)
    return vim.api.nvim_get_option_value(name, { win = win })
end

--- Arm a window the way the todo panel does (lua/pi/todo/init.lua
--- set_win_opts) plus the concealcursor a chat-parent split leaks
--- (lua/pi/ui/chat/layout.lua:42).
---@param win integer
local function arm_panel(win)
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].foldenable = false
    vim.wo[win].list = false
    vim.wo[win].spell = false
    vim.wo[win].cursorline = false
    vim.wo[win].winfixbuf = true
    vim.wo[win].winfixwidth = true
    vim.wo[win].winfixheight = true
    vim.wo[win].concealcursor = "nvic"
end

--- Split off the current window, give it a fresh scratch buffer with
--- filetype `ft`, and arm it with the panel options.
---@param ft string filetype for the panel buffer (see pi.filetypes)
---@param ft_after_enter? boolean assign the filetype after the buffer has
---  already been entered, mirroring a late filetype assignment
---@return integer win panel window
---@return integer buf panel buffer
---@return integer other window that was current before the split
local function open_panel(ft, ft_after_enter)
    local other = vim.api.nvim_get_current_win()
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, true)
    if not ft_after_enter then
        vim.bo[buf].filetype = ft
    end
    vim.api.nvim_win_set_buf(win, buf)
    if ft_after_enter then
        vim.bo[buf].filetype = ft
    end
    arm_panel(win)
    panel_bufs[#panel_bufs + 1] = buf
    return win, buf, other
end

--- Leave the panel window and re-enter it, asserting that BufEnter really
--- fired for the panel buffer — otherwise the cycle would prove nothing.
---@param win integer panel window to re-enter
---@param other integer window to leave to first
---@param buf integer panel buffer whose BufEnter must fire
local function focus_cycle(win, other, buf)
    local enters = 0
    local id = vim.api.nvim_create_autocmd("BufEnter", {
        buffer = buf,
        callback = function()
            enters = enters + 1
        end,
    })
    vim.api.nvim_set_current_win(other)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_del_autocmd(id)
    assert.is_true(enters >= 1, "focus cycle must fire BufEnter for the panel buffer")
end

describe("pi.ui.winfix pi-filetype exemption", function()
    local base_wins = {}

    before_each(function()
        base_wins = vim.api.nvim_list_wins()
        panel_bufs = {}
    end)

    after_each(function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if not vim.tbl_contains(base_wins, w) then
                pcall(vim.api.nvim_win_close, w, true)
            end
        end
        for _, b in ipairs(panel_bufs) do
            if vim.api.nvim_buf_is_valid(b) then
                pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
        end
        local first = base_wins[1]
        if first and vim.api.nvim_win_is_valid(first) then
            vim.api.nvim_set_current_win(first)
        end
    end)

    it("leaves a pi-sessions panel window untouched across re-entry", function()
        local win, buf, other = open_panel(Ft.sessions)

        -- The window is armed exactly like the real todo panel.
        assert.is_false(wo(win, "number"), "panel opens with number=false")
        assert.equals("nvic", wo(win, "concealcursor"), "panel carries the leaked concealcursor")
        assert.is_true(wo(win, "winfixbuf"), "panel opens winfixbuf-pinned")

        focus_cycle(win, other, buf)

        -- Pre-fix this flips number to the captured default (true) and drops
        -- the winfix* pins to their captured defaults (false).
        assert.is_false(wo(win, "number"), "pi panel window must keep nonumber")
        assert.is_false(wo(win, "relativenumber"), "pi panel window must keep norelativenumber")
        assert.equals("nvic", wo(win, "concealcursor"), "pi panel window must keep concealcursor")
        assert.is_true(wo(win, "winfixbuf"), "pi panel window must keep winfixbuf")
        assert.is_true(wo(win, "winfixwidth"), "pi panel window must keep winfixwidth")
        assert.is_true(wo(win, "winfixheight"), "pi panel window must keep winfixheight")
    end)

    it("exempts every pi filetype, not only the chat panes", function()
        -- Sorted so the loop order (and failure output) is deterministic.
        local keys = vim.tbl_keys(Ft)
        table.sort(keys)
        for _, key in ipairs(keys) do
            local ft = Ft[key]
            local win, buf, other = open_panel(ft)
            focus_cycle(win, other, buf)
            assert.is_false(wo(win, "number"), ft .. " panel window must keep nonumber")
            assert.equals("nvic", wo(win, "concealcursor"), ft .. " panel window must keep concealcursor")
            vim.api.nvim_set_current_win(other)
        end
    end)

    it("still resets a user buffer that inherited the pi fingerprint", function()
        -- Same fingerprint as a pi panel, but the buffer is a user buffer
        -- (filetype "lua"): winfix must reset it to the captured defaults.
        local win, buf, other = open_panel("lua")
        assert.equals("nvic", wo(win, "concealcursor"), "user window starts with the fingerprint")

        focus_cycle(win, other, buf)

        assert.is_true(wo(win, "number"), "captured global number default (true) must be restored")
        assert.is_false(wo(win, "winfixbuf"), "captured winfixbuf default (false) must be restored")
    end)

    it("exempts a pi window whose filetype is set after the buffer was entered", function()
        local win, buf, other = open_panel(Ft.sessions, true)
        assert.equals(Ft.sessions, vim.bo[buf].filetype, "filetype assigned after the window was entered")

        focus_cycle(win, other, buf)

        assert.is_false(wo(win, "number"), "pi panel window must keep nonumber")
        assert.equals("nvic", wo(win, "concealcursor"), "pi panel window must keep concealcursor")
        assert.is_true(wo(win, "winfixbuf"), "pi panel window must keep winfixbuf")
    end)
end)

-- Runs after the last test (describes execute synchronously at load).
vim.api.nvim_set_option_value("number", saved_number_global, { scope = "global" })
vim.wo.number = saved_number_win
