--- Chat layout — window creation, positioning, and management.

---@class pi.ChatLayout
---@field _mode pi.LayoutMode
---@field _history_win integer?
---@field _prompt_win integer?
---@field _attachments_win integer?
---@field _tab integer? Tab the side windows live in (captured on show)
---@field _winclosed_autocmd integer WinClosed handler id (for teardown/tests)
---@field _history pi.ChatHistory
---@field _prompt pi.ChatPrompt
---@field _attachments pi.ChatAttachments
---@field _has_attention boolean
---@field _bash_mode boolean
local Layout = {}
Layout.__index = Layout

local Config = require("pi.config")
local Prompt = require("pi.ui.chat.prompt")
local Highlights = require("pi.ui.highlights")
local Render = require("pi.ui.render")

--- Low z-index so other floats naturally sit on top.
local FLOAT_ZINDEX = 10

-- Capture editor options to inherit in π windows.
local editor_foldcolumn = vim.wo.foldcolumn

---@param win integer
---@param extra? fun(win: integer)
local function set_win_opts(win, extra)
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = editor_foldcolumn
    vim.wo[win].foldenable = false
    vim.wo[win].list = false
    vim.wo[win].conceallevel = 2
    vim.wo[win].winfixbuf = true
    -- These options form the fingerprint used by pi.ui.winfix to detect
    -- windows inherited from pi. Keep in sync with has_pi_fingerprint().
    vim.wo[win].concealcursor = "nvic"
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline = false
    if extra then
        extra(win)
    end
end

---@param win integer
---@param title string
---@param hl_group string
---@param title_hl_group? string
local function set_winbar(win, title, hl_group, title_hl_group)
    title_hl_group = title_hl_group or (hl_group .. "Title")
    vim.wo[win].winbar = "%#" .. hl_group .. "#%=%#" .. title_hl_group .. "# " .. title .. " %#" .. hl_group .. "#%="
end

---@param win integer
local function clear_winbar(win)
    vim.wo[win].winbar = ""
end

--- Update prompt title styling to reflect pending attention.
---@param has_attention boolean
function Layout:refresh_prompt_attention(has_attention)
    self._has_attention = has_attention
    self:_refresh_prompt_chrome()
end

--- Update prompt title styling to reflect bash mode (prompt starts with "!").
---@param is_bash boolean
function Layout:set_bash_mode(is_bash)
    if self._bash_mode == is_bash then
        return
    end
    self._bash_mode = is_bash
    self:_refresh_prompt_chrome()
end

---@return boolean
function Layout:bash_mode()
    return self._bash_mode
end

--- Re-apply the prompt window title text and colors from the current
--- bash-mode / attention state. Bash mode wins over attention styling.
function Layout:_refresh_prompt_chrome()
    local pwin = self:prompt_win()
    if not pwin then
        return
    end

    local prompt_cfg = Config.options.panels.prompt
    local title = (self._bash_mode and (prompt_cfg.bash_title or "bash")) or prompt_cfg.title

    if self._mode == "float" then
        local winhighlight = Highlights.CHAT_PROMPT_WINHIGHLIGHT
        if self._bash_mode then
            winhighlight = Highlights.CHAT_PROMPT_BASH_WINHIGHLIGHT
        elseif self._has_attention then
            winhighlight = Highlights.CHAT_PROMPT_ATTENTION_WINHIGHLIGHT
        end
        vim.wo[pwin].winhighlight = winhighlight
        pcall(vim.api.nvim_win_set_config, pwin, { title = " " .. title .. " ", title_pos = "center" })
        return
    end

    local side_cfg = Config.resolve_side_layout()
    if side_cfg.panels.prompt.winbar then
        local title_hl = "PiChatPromptWinbarTitle"
        if self._bash_mode then
            title_hl = "PiChatPromptWinbarBashTitle"
        elseif self._has_attention then
            title_hl = "PiChatPromptWinbarAttentionTitle"
        end
        set_winbar(pwin, title, "PiChatPromptWinbar", title_hl)
    end
end

---@param mode pi.LayoutMode
---@param history pi.ChatHistory
---@param prompt pi.ChatPrompt
---@param attachments pi.ChatAttachments
---@return pi.ChatLayout
function Layout.new(mode, history, prompt, attachments)
    local self = setmetatable({}, Layout)
    self._mode = mode
    self._history_win = nil
    self._prompt_win = nil
    self._attachments_win = nil
    self._terminal_win = nil
    self._tab = nil
    self._history = history
    self._prompt = prompt
    self._attachments = attachments
    self._has_attention = false
    self._bash_mode = false

    attachments:set_on_change(function()
        self:_refresh_attachments()
    end)

    -- After any window closes in this layout's tab, re-normalize the side
    -- column heights (issue #31): closing a full-width window (e.g.
    -- toggleterm's horizontal terminal, `botright split`) re-distributes the
    -- freed height to the bottom window of each column frame, ignoring
    -- 'winfixheight', so the prompt balloons and history stays compressed
    -- until the next text change. WinClosed fires only when the window count
    -- decreases — never on manual <C-w>+/drag — so user-adjusted heights are
    -- preserved. The callback self-guards (tab, mode, π's own windows).
    self._winclosed_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
        desc = "pi: re-normalize side column heights after a window closes",
        callback = function(ev)
            -- WinClosed's event table carries the closed window id only as
            -- <afile> (a string), unlike WinNew/WinEnter which set ev.win.
            -- The current tab at event time is the tab the window lived in.
            self:_on_win_closed(tonumber(ev.file), vim.api.nvim_get_current_tabpage())
        end,
    })

    return self
end

--- Handle WinClosed: re-normalize the side column heights after an external
--- window in the layout's tab closes.
---@param closed_win integer? closed window id (nil when the event table is odd)
---@param closed_tab integer tab the closed window lived in
function Layout:_on_win_closed(closed_win, closed_tab)
    -- The event-time tab is authoritative: the closed window lived there, and
    -- by the time the deferred normalize runs the current tab may have moved.
    if self._tab and closed_tab ~= self._tab then
        return -- a window closed in another tab; this layout's column is untouched
    end
    if self._mode ~= "side" then
        return -- floats are independent of the frame tree
    end
    -- π's own windows close through hide()/set_mode() (nvim_win_close keeps
    -- the ids in _*_win until the fields are cleared afterwards), and a user
    -- closing a π window externally leaves a broken layout normalize must not
    -- fight. Both cases match the raw fields here; a nil closed_win (unexpected
    -- event table) also lands in this branch and is a safe early return.
    if closed_win == self._history_win or closed_win == self._prompt_win or closed_win == self._attachments_win then
        return
    end
    -- The bash terminal window is optional chrome: when it closes (user :q or
    -- external close) just drop the reference; the buffer survives and the
    -- window is re-created on demand (next bash run or :PiBashOpen).
    if closed_win == self._terminal_win then
        self._terminal_win = nil
        return
    end
    -- Defer: WinClosed fires before the closed window's height is handed back
    -- to the frame tree, so an immediate normalize would be overwritten by
    -- the redistribution (issue #31). Run once the event loop settles.
    vim.schedule(function()
        if self._tab ~= closed_tab then
            return -- the layout moved tabs while the callback was pending
        end
        if self._mode ~= "side" then
            return
        end
        if not self:history_win() or not self:prompt_win() then
            return -- layout hidden or torn down before the deferred normalize ran
        end
        self:_normalize_side_heights()
    end)
end

--- Re-normalize the side column heights: let history take the full column
--- height, then pin the prompt (and attachments) back to their content
--- heights. Mirrors the height-fixing tail of _refresh_attachments;
--- idempotent when the column is already correct.
function Layout:_normalize_side_heights()
    local hwin = self:history_win()
    local pwin = self:prompt_win()
    if not hwin or not pwin then
        return
    end
    -- Capture the attachments/terminal heights before wincmd _ shrinks them.
    local awin = self:attachments_win()
    local target_attachments_height = awin and vim.api.nvim_win_get_height(awin) or 0
    local twin = self:terminal_win()
    local target_terminal_height = twin and vim.api.nvim_win_get_height(twin) or 0
    vim.api.nvim_win_call(hwin, function()
        vim.cmd("wincmd _")
    end)
    vim.api.nvim_win_set_height(pwin, self._prompt:content_height())
    if awin and target_attachments_height > 0 then
        vim.api.nvim_win_set_height(awin, target_attachments_height)
    end
    if twin and target_terminal_height > 0 then
        vim.api.nvim_win_set_height(twin, target_terminal_height)
    end
end

---@param after_win integer
function Layout:_open_attachments_in_side_layout(after_win)
    local prev_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(after_win)
    vim.cmd("belowright " .. self._attachments:count() .. "split")
    self._attachments_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self._attachments_win, self._attachments:buf())
    vim.wo[self._attachments_win].winfixheight = true
    vim.wo[self._attachments_win].winfixwidth = true
    vim.wo[self._attachments_win].signcolumn = "no"
    vim.wo[self._attachments_win].foldcolumn = editor_foldcolumn
    vim.wo[self._attachments_win].winfixbuf = true
    vim.wo[self._attachments_win].wrap = false
    -- Fingerprint options — see pi.ui.winfix
    vim.wo[self._attachments_win].concealcursor = "nvic"
    vim.wo[self._attachments_win].number = false
    vim.wo[self._attachments_win].relativenumber = false
    vim.wo[self._attachments_win].cursorline = false

    vim.api.nvim_set_current_win(prev_win)
end

---@param col integer
---@param row integer
---@param width integer
---@param border string|string[]
function Layout:_open_attachments_in_float_layout(col, row, width, border)
    -- Available height: screen lines minus cmdline, statusline (1), rows above (row), border (2)
    local max_height = vim.o.lines - vim.o.cmdheight - 1 - row - 2
    if max_height < 1 then
        return
    end
    local height = math.min(self._attachments:count(), max_height)
    self._attachments_win = vim.api.nvim_open_win(self._attachments:buf(), false, {
        relative = "editor",
        width = width,
        height = height,
        col = col,
        row = row,
        style = "minimal",
        border = border,
        zindex = FLOAT_ZINDEX,
        title = " " .. Config.options.panels.attachments.title .. " ",
        title_pos = "center",
    })
    vim.wo[self._attachments_win].winfixheight = true
    vim.wo[self._attachments_win].signcolumn = "yes"
    vim.wo[self._attachments_win].winfixbuf = true
    vim.wo[self._attachments_win].wrap = false
    vim.wo[self._attachments_win].winhighlight = Highlights.CHAT_ATTACHMENTS_WINHIGHLIGHT
    -- Fingerprint options — see pi.ui.winfix
    vim.wo[self._attachments_win].concealcursor = "nvic"
    vim.wo[self._attachments_win].number = false
    vim.wo[self._attachments_win].relativenumber = false
    vim.wo[self._attachments_win].cursorline = false
end

function Layout:_close_history_win()
    local hwin = self:history_win()
    if hwin then
        vim.api.nvim_win_close(hwin, false)
    end
    self._history_win = nil
    self._history:set_win(nil)
end

function Layout:_close_prompt_win()
    local pwin = self:prompt_win()
    if pwin then
        vim.api.nvim_win_close(pwin, false)
    end
    self._prompt_win = nil
    self._prompt:set_win(nil)
end

function Layout:_close_attachments_win()
    local awin = self:attachments_win()
    if not awin then
        self._attachments_win = nil
        return
    end
    -- Move focus away before closing: try previous window, fall back to next
    -- if the previous window is the one we're closing (only window in column).
    if vim.api.nvim_get_current_win() == awin then
        vim.cmd("wincmd p")
        if vim.api.nvim_get_current_win() == awin then
            vim.cmd("wincmd w")
        end
    end
    vim.api.nvim_win_close(awin, false)
    self._attachments_win = nil
end

--- Resolve a dimension (width or height) from a config value.
--- Values < 1 are treated as fractions of the available space.
---@param value number
---@param available integer
---@return integer
local function resolve_dimension(value, available)
    if value < 1 then
        return math.floor(available * value)
    end
    return math.floor(value)
end

--- Resolve side panel width in columns from config.
---@return integer
local function resolve_side_width()
    local side_cfg = Config.resolve_side_layout()
    return resolve_dimension(side_cfg.width, vim.o.columns)
end

--- Resolve float dimensions in pixels from config.
---@param float_cfg? pi.FloatLayout Pre-resolved config; resolved internally if omitted.
---@return integer width, integer total_height
local function resolve_float_size(float_cfg)
    float_cfg = float_cfg or Config.resolve_float_layout()
    local width = resolve_dimension(float_cfg.width, vim.o.columns)
    local total_height = resolve_dimension(float_cfg.height, vim.o.lines - vim.o.cmdheight - 1)
    return width, total_height
end

-- ---------------------------------------------------------------------------
-- Bash terminal window (config: bash.terminal). Same optional-chrome pattern
-- as attachments: opened on demand below the history window, closed by user
-- or programmatically, never re-created by show()/hide() itself.
-- ---------------------------------------------------------------------------

--- Resolve the terminal window height in lines from bash.terminal_height.
---@return integer
function Layout:_terminal_height()
    local cfg = Config.options.bash or {}
    local available
    local hwin = self:history_win()
    if hwin then
        available = vim.api.nvim_win_get_height(hwin)
    else
        available = vim.o.lines - vim.o.cmdheight - 1
    end
    return math.max(3, resolve_dimension(cfg.terminal_height or 0.35, available))
end

--- Set common window options for the terminal window.
---@param win integer
function Layout:_set_terminal_win_opts(win)
    vim.wo[win].winfixheight = true
    vim.wo[win].winfixwidth = true
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = editor_foldcolumn
    vim.wo[win].winfixbuf = true
    vim.wo[win].wrap = false
    -- Fingerprint options — see pi.ui.winfix
    vim.wo[win].concealcursor = "nvic"
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].cursorline = false
end

function Layout:_open_terminal_in_side_layout(buf)
    local hwin = self._history_win
    local prev_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_call(hwin, function()
        vim.cmd("belowright " .. self:_terminal_height() .. "split")
    end)
    self._terminal_win = vim.api.nvim_get_current_win()
    -- The split inherits winfixbuf from the history window; clear it so the
    -- terminal buffer can be installed (_set_terminal_win_opts re-arms it).
    vim.wo[self._terminal_win].winfixbuf = false
    vim.api.nvim_win_set_buf(self._terminal_win, buf)
    self:_set_terminal_win_opts(self._terminal_win)
    vim.api.nvim_set_current_win(prev_win)
end

---@param buf integer
function Layout:_open_terminal_in_float_layout(buf)
    local float_cfg = Config.resolve_float_layout()
    local width = self._history_win and vim.api.nvim_win_get_width(self._history_win)
        or select(1, resolve_float_size(float_cfg))
    local border = float_cfg.border or "rounded"
    -- Row/col are corrected by _reposition_float_stack right after opening.
    self._terminal_win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        width = width,
        height = self:_terminal_height(),
        col = 0,
        row = 0,
        style = "minimal",
        border = border,
        zindex = FLOAT_ZINDEX,
    })
    self:_set_terminal_win_opts(self._terminal_win)
end

--- Open (or reuse) the terminal window showing buf. Never steals focus unless
--- requested; the side layout restores the previous window after splitting.
---@param buf integer terminal buffer to display
---@param focus boolean move focus into the terminal window
function Layout:open_terminal_win(buf, focus)
    if not self:is_visible() then
        return
    end
    local twin = self:terminal_win()
    if twin then
        if vim.api.nvim_win_get_buf(twin) ~= buf then
            vim.api.nvim_win_set_buf(twin, buf)
        end
    elseif self._mode == "float" then
        self:_open_terminal_in_float_layout(buf)
        self:_reposition_float_stack()
    else
        self:_open_terminal_in_side_layout(buf)
    end
    if focus then
        twin = self:terminal_win()
        if twin then
            vim.api.nvim_set_current_win(twin)
        end
    end
end

function Layout:close_terminal_win()
    local twin = self:terminal_win()
    if not twin then
        self._terminal_win = nil
        return
    end
    clear_winbar(twin)
    if vim.api.nvim_get_current_win() == twin then
        vim.cmd("wincmd p")
        if vim.api.nvim_get_current_win() == twin then
            vim.cmd("wincmd w")
        end
    end
    vim.api.nvim_win_close(twin, false)
    self._terminal_win = nil
end

--- Winbar title for the terminal window (command + status).
---@param text string
---@param hl_group? string
function Layout:set_terminal_title(text, hl_group)
    local twin = self:terminal_win()
    if twin then
        set_winbar(twin, text, hl_group or "PiToolStatus")
    end
end

--- Reposition (and optionally resize) the float window stack.
--- When target_width / target_height are given, windows are resized to match
--- the new dimensions (used on VimResized). Without them, the current window
--- sizes are preserved and only positions are recalculated (used when the
--- attachment count changes).
---@param target_width? integer
---@param target_height? integer
---@param float_cfg? pi.FloatLayout Pre-resolved config; resolved internally if omitted.
function Layout:_reposition_float_stack(target_width, target_height, float_cfg)
    if not self._history_win or not vim.api.nvim_win_is_valid(self._history_win) then
        return
    end
    if not self._prompt_win or not vim.api.nvim_win_is_valid(self._prompt_win) then
        return
    end

    float_cfg = float_cfg or Config.resolve_float_layout()
    local ui_width = vim.o.columns
    local ui_height = vim.o.lines - vim.o.cmdheight - 1
    local border = float_cfg.border or "rounded"

    local width = target_width or vim.api.nvim_win_get_width(self._history_win)
    local prompt_height = vim.api.nvim_win_get_height(self._prompt_win)
    local attach_count = self._attachments:count()
    local term_win = self:terminal_win()
    local term_height = term_win and vim.api.nvim_win_get_height(term_win) or 0

    local history_height
    if target_height then
        -- Derive history height from the target total height.
        history_height = target_height - prompt_height - 1
        if attach_count > 0 then
            history_height = history_height - attach_count - 2
        end
        if term_height > 0 then
            history_height = history_height - term_height - 2
        end
        history_height = math.max(3, history_height)
    else
        history_height = vim.api.nvim_win_get_height(self._history_win)
    end

    -- border takes 2 lines per window (top + bottom)
    local total = history_height + 2 + prompt_height + 2
    if attach_count > 0 then
        total = total + attach_count + 2
    end
    if term_height > 0 then
        total = total + term_height + 2
    end

    -- Shrink history if stack doesn't fit
    local overhead = total - history_height
    if total > ui_height then
        history_height = math.max(3, ui_height - overhead)
        total = history_height + overhead
    end

    -- If it still doesn't fit, skip attachments
    if total > ui_height and attach_count > 0 then
        total = total - attach_count - 2
        attach_count = 0
        self:_close_attachments_win()
    end

    -- If it still doesn't fit, shrink (or as a last resort drop) the terminal
    if total > ui_height and term_height > 0 then
        local rest = total - term_height - 2
        if ui_height - rest >= 3 then
            term_height = ui_height - rest
            total = rest + term_height + 2
        else
            self:close_terminal_win()
            term_height = 0
            total = rest
        end
    end

    local col = math.floor((ui_width - width) / 2)
    local row = math.max(0, math.floor((ui_height - total) / 2))

    vim.api.nvim_win_set_config(self._history_win, {
        relative = "editor",
        row = row,
        col = col,
        height = history_height,
        width = width,
    })

    local prompt_row = row + history_height + 2
    vim.api.nvim_win_set_config(self._prompt_win, {
        relative = "editor",
        row = prompt_row,
        col = col,
        width = width,
    })

    local next_row = prompt_row + prompt_height + 2
    if attach_count > 0 then
        local attach_row = next_row
        local awin = self:attachments_win()
        if awin then
            vim.api.nvim_win_set_config(awin, {
                relative = "editor",
                row = attach_row,
                col = col,
                width = width,
                height = attach_count,
            })
        else
            self:_open_attachments_in_float_layout(col, attach_row, width, border)
        end
        next_row = attach_row + attach_count + 2
    end

    if term_height > 0 then
        local twin = self:terminal_win()
        if twin then
            vim.api.nvim_win_set_config(twin, {
                relative = "editor",
                row = next_row,
                col = col,
                width = width,
                height = term_height,
            })
        end
    end
end

function Layout:_refresh_attachments()
    if not self._prompt_win or not vim.api.nvim_win_is_valid(self._prompt_win) then
        return
    end
    local is_float = self._mode == "float"

    if self._attachments:count() == 0 then
        local was_visible = self:attachments_win() ~= nil
        self:_close_attachments_win()
        vim.api.nvim_set_current_win(self._prompt_win)
        vim.cmd("startinsert")
        if was_visible then
            if is_float then
                self:_reposition_float_stack()
            else
                vim.api.nvim_win_call(self._history_win, function()
                    vim.cmd("wincmd _")
                end)
                vim.api.nvim_win_set_height(self._prompt_win, self._prompt:content_height())
            end
        end
        return
    end

    if is_float then
        self:_reposition_float_stack()
    else
        if not self:attachments_win() then
            self:_open_attachments_in_side_layout(self._prompt_win)
        end
        local awin = self:attachments_win()
        if awin then
            local side_cfg = Config.resolve_side_layout()
            if side_cfg.panels.attachments.winbar then
                set_winbar(awin, Config.options.panels.attachments.title, "PiChatAttachmentsWinbar")
            end
            -- Account for winbar + padding in target height
            local aheight = self._attachments:count() + 1 -- +1 for padding line
            if vim.wo[awin].winbar ~= "" then
                aheight = aheight + 1
            end
            vim.api.nvim_win_set_height(awin, aheight)
        end
        -- Maximize history, then re-fix prompt, attachments and terminal
        -- heights. Capture heights before wincmd _ steals their space.
        local target_attachments_height = awin and vim.api.nvim_win_get_height(awin) or 0
        local twin = self:terminal_win()
        local target_terminal_height = twin and vim.api.nvim_win_get_height(twin) or 0
        vim.api.nvim_win_call(self._history_win, function()
            vim.cmd("wincmd _")
        end)
        vim.api.nvim_win_set_height(self._prompt_win, self._prompt:content_height())
        if awin then
            vim.api.nvim_win_set_height(awin, target_attachments_height)
        end
        if twin and target_terminal_height > 0 then
            vim.api.nvim_win_set_height(twin, target_terminal_height)
        end
    end
end

function Layout:_open_in_side_layout()
    local side_cfg = Config.resolve_side_layout()
    local panels = side_cfg.panels
    local w = resolve_side_width()
    local vsplit_cmd = side_cfg.position == "left" and "topleft" or "botright"
    vim.cmd(vsplit_cmd .. " " .. w .. "vsplit")

    self._history_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self._history_win, self._history:buf())
    set_win_opts(self._history_win, function(win)
        vim.wo[win].winfixwidth = true
        -- Builtin engine: conceallevel=0 because treesitter markdown can't
        -- conceal brackets/bold in tool output.  render-markdown engine needs
        -- conceallevel=2 (set by set_win_opts) to hide syntax markers.
        if Render.engine() == "builtin" then
            vim.wo[win].conceallevel = 0
        end
    end)
    if panels.history.winbar then
        set_winbar(self._history_win, Config.options.panels.history.title, "PiChatHistoryWinbar")
    end
    self._history:set_win(self._history_win)

    local prompt_winbar = panels.prompt.winbar
    local prompt_h = Prompt.HEIGHT + (prompt_winbar and 1 or 0)
    vim.cmd("belowright " .. prompt_h .. "split")
    self._prompt_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self._prompt_win, self._prompt:buf())
    set_win_opts(self._prompt_win, function(win)
        vim.wo[win].winfixwidth = true
        vim.wo[win].winfixheight = true
        vim.wo[win].virtualedit = "onemore"
    end)
    if prompt_winbar then
        set_winbar(self._prompt_win, Config.options.panels.prompt.title, "PiChatPromptWinbar")
    end
    self._prompt:set_layout("side")
    self._prompt:set_win(self._prompt_win)
end

function Layout:_open_in_float_layout()
    local float_cfg = Config.resolve_float_layout()
    local width, total_height = resolve_float_size(float_cfg)
    local history_height = total_height - Prompt.HEIGHT - 1
    local col = math.floor((vim.o.columns - width) / 2)
    local row = math.floor((vim.o.lines - vim.o.cmdheight - 1 - total_height) / 2)
    local border = float_cfg.border or "rounded"
    local user_win = float_cfg.win or {}

    self._history_win = vim.api.nvim_open_win(
        self._history:buf(),
        false,
        vim.tbl_deep_extend("force", {
            relative = "editor",
            width = width,
            height = history_height,
            col = col,
            row = row,
            style = "minimal",
            border = border,
            zindex = FLOAT_ZINDEX,
            title = " " .. Config.options.panels.history.title .. " ",
            title_pos = "center",
        }, user_win)
    )
    set_win_opts(self._history_win)
    vim.wo[self._history_win].winbar = ""
    vim.wo[self._history_win].winhighlight = Highlights.CHAT_HISTORY_WINHIGHLIGHT
    if Render.engine() == "builtin" then
        vim.wo[self._history_win].conceallevel = 0
    end
    self._history:set_win(self._history_win)

    self._prompt_win = vim.api.nvim_open_win(
        self._prompt:buf(),
        true,
        vim.tbl_deep_extend("force", {
            relative = "editor",
            width = width,
            height = Prompt.HEIGHT,
            col = col,
            row = row + history_height + 2,
            style = "minimal",
            border = border,
            zindex = FLOAT_ZINDEX,
            title = " " .. Config.options.panels.prompt.title .. " ",
            title_pos = "center",
        }, user_win)
    )
    set_win_opts(self._prompt_win, function(win)
        vim.wo[win].winfixheight = true
        vim.wo[win].virtualedit = "onemore"
    end)
    vim.wo[self._prompt_win].winbar = ""
    vim.wo[self._prompt_win].winhighlight = Highlights.CHAT_PROMPT_WINHIGHLIGHT
    self._prompt:set_layout("float")
    self._prompt:set_win(self._prompt_win)
end

--- Handle editor resize. Re-evaluates layout config (which may be a function)
--- and updates window geometry in the current mode.
function Layout:on_resize()
    if not self:is_visible() then
        return
    end

    if self._mode == "float" then
        local float_cfg = Config.resolve_float_layout()
        local width, total_height = resolve_float_size(float_cfg)
        self:_reposition_float_stack(width, total_height, float_cfg)
    else
        if self._history_win and vim.api.nvim_win_is_valid(self._history_win) then
            vim.api.nvim_win_set_width(self._history_win, resolve_side_width())
        end
    end
end

---@return boolean opened true if a fresh open occurred
function Layout:show()
    if self._history_win and vim.api.nvim_win_is_valid(self._history_win) then
        return false
    end
    self._tab = vim.api.nvim_get_current_tabpage()
    if self._mode == "float" then
        self:_open_in_float_layout()
    else
        self:_open_in_side_layout()
    end
    -- auto_open lives here (not in Chat:show) so every path that makes the
    -- chat visible — including set_layout/set_mode — opens the list too.
    if Config.options.sessions_list.auto_open then
        require("pi.ui.sessions").open()
    end
    return true
end

function Layout:hide()
    -- Clear winbars before closing to prevent window-buffer-local
    -- winbar state from leaking into the next layout's windows.
    local twin = self:terminal_win()
    if twin then
        clear_winbar(twin)
    end
    local awin = self:attachments_win()
    if awin then
        clear_winbar(awin)
    end
    local pwin = self:prompt_win()
    if pwin then
        clear_winbar(pwin)
    end
    local hwin = self:history_win()
    if hwin then
        clear_winbar(hwin)
    end

    self:_close_attachments_win()
    self:close_terminal_win()
    self:_close_prompt_win()
    self:_close_history_win()
end

---@return pi.LayoutMode
function Layout:mode()
    return self._mode
end

---@param mode pi.LayoutMode
function Layout:set_mode(mode)
    -- Save prompt cursor before tearing down windows.
    local prompt_cursor
    local pwin = self:prompt_win()
    if pwin then
        prompt_cursor = vim.api.nvim_win_get_cursor(pwin)
    end

    self:hide()
    self._mode = mode
    self:show()
    self._prompt:resize()
    if self._attachments:count() > 0 then
        self:_refresh_attachments()
    end

    -- Restore prompt cursor in the new window.
    if prompt_cursor then
        pwin = self:prompt_win()
        if pwin then
            local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(pwin))
            prompt_cursor[1] = math.min(prompt_cursor[1], line_count)
            vim.api.nvim_win_set_cursor(pwin, prompt_cursor)
        end
    end
end

function Layout:toggle()
    self:set_mode(self._mode == "side" and "float" or "side")
end

---@return boolean
function Layout:is_visible()
    return self._history_win ~= nil and vim.api.nvim_win_is_valid(self._history_win)
end

---@return integer?
function Layout:history_win()
    if self._history_win and vim.api.nvim_win_is_valid(self._history_win) then
        return self._history_win
    end
    return nil
end

---@return integer?
function Layout:prompt_win()
    if self._prompt_win and vim.api.nvim_win_is_valid(self._prompt_win) then
        return self._prompt_win
    end
    return nil
end

---@return integer?
function Layout:attachments_win()
    if self._attachments_win and vim.api.nvim_win_is_valid(self._attachments_win) then
        return self._attachments_win
    end
    return nil
end

---@return integer?
function Layout:terminal_win()
    if self._terminal_win and vim.api.nvim_win_is_valid(self._terminal_win) then
        return self._terminal_win
    end
    self._terminal_win = nil
    return nil
end

return Layout
