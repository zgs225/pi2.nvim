-- Terminal surface for agent bash tool output (config: bash.terminal).
--
-- The agent's bash tool streams cumulative output via tool_execution_update.
-- When bash.terminal is enabled, Chat routes that text here instead of into
-- the chat tool block: this module owns a single nvim_open_term buffer per
-- chat and appends each run's output with chansend. The chat history only
-- carries a summary card (see History:on_tool_end, terminal_mode branch).
--
-- nvim_open_term buffers have no backing process — the command runs inside
-- the pi agent. Interrupting therefore goes through the RPC abort command,
-- not through the terminal channel (<C-c> is mapped accordingly).

local Config = require("pi.config")
local Ft = require("pi.filetypes")

---@class pi.BashTerminalHandlers
---@field focus_prompt fun():nil Move focus back to the chat prompt (double-<Esc> gesture)
---@field on_abort fun():nil Abort the running agent turn (<C-c> in the terminal window)

---@class pi.BashTerminal
---@field _tab integer owning tabpage (buffer name disambiguation)
---@field _layout pi.ChatLayout window management for the chat panel
---@field _handlers pi.BashTerminalHandlers
---@field _buf integer? terminal buffer (lazily created, survives between runs)
---@field _chan integer? nvim_open_term channel of _buf
---@field _running string? tool call id of the in-flight command
---@field _running_cmd string? command line of the in-flight run (winbar title)
---@field _sent integer bytes of cumulative text already forwarded for _running
---@field _lines integer completed lines forwarded for _running
---@field _esc_at number? timestamp (ms) of the first <Esc> in the double-<Esc> gesture
local BashTerminal = {}
BashTerminal.__index = BashTerminal

---@param tab integer
---@param layout pi.ChatLayout
---@param handlers pi.BashTerminalHandlers
---@return pi.BashTerminal
function BashTerminal.new(tab, layout, handlers)
    local self = setmetatable({}, BashTerminal)
    self._tab = tab
    self._layout = layout
    self._handlers = handlers
    return self
end

---@return boolean
function BashTerminal:enabled()
    local bash = Config.options.bash
    return bash and bash.terminal == true
end

---@return integer?
function BashTerminal:buf()
    if self._buf and vim.api.nvim_buf_is_valid(self._buf) then
        return self._buf
    end
    return nil
end

---@return boolean
function BashTerminal:has_output()
    return self:buf() ~= nil
end

---@return boolean
function BashTerminal:is_running()
    return self._running ~= nil
end

---@return integer
function BashTerminal:line_count()
    return self._lines
end

--- Buffer-local keys. <C-c> cannot kill anything here (no child process);
--- it aborts the agent turn via RPC. Double-<Esc> returns to the prompt,
--- mirroring the gesture used across the chat panel.
---@param buf integer
function BashTerminal:_set_keymaps(buf)
    vim.keymap.set("t", "<C-c>", function()
        self._handlers.on_abort()
    end, { buffer = buf, desc = "π: abort the running agent turn" })

    local esc = function()
        self:_handle_esc()
    end
    -- Terminal mode: first <Esc> leaves terminal mode (via the returned
    -- key sequence) and arms the gesture.
    vim.keymap.set("t", "<Esc>", function()
        esc()
        return "<C-\\><C-n>"
    end, { buffer = buf, expr = true, desc = "π: arm double-<Esc> (again: back to prompt)" })
    -- Normal mode: second <Esc> inside the window jumps to the prompt.
    vim.keymap.set("n", "<Esc>", esc, { buffer = buf, desc = "π: double-<Esc> back to prompt" })
end

function BashTerminal:_handle_esc()
    local timeout = (Config.options.abort and Config.options.abort.timeout) or 1500
    local now = vim.uv.now()
    if self._esc_at and (now - self._esc_at) <= timeout then
        self._esc_at = nil
        self._handlers.focus_prompt()
    else
        self._esc_at = now
    end
end

--- Create the terminal buffer (once per chat; reused across runs).
---@return integer buf, integer chan
function BashTerminal:_ensure_buf()
    local buf = self:buf()
    if buf and self._chan then
        return buf, self._chan
    end
    -- Free a stale buffer with the same name (e.g. a prior instance that was
    -- hidden but never destroyed) so set_name cannot collide (E95).
    local name = "pi://bash-" .. self._tab
    local old = vim.fn.bufnr(name)
    if old ~= -1 then
        pcall(vim.api.nvim_buf_delete, old, { force = true })
    end
    buf = vim.api.nvim_create_buf(false, false)
    local chan = vim.api.nvim_open_term(buf, {})
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].filetype = Ft.bash_terminal
    vim.bo[buf].bufhidden = "hide"
    self:_set_keymaps(buf)
    self._buf = buf
    self._chan = chan
    return buf, chan
end

--- Begin a run: separator + command line into the terminal, open the window
--- (without stealing focus), and reset streaming counters.
---@param tool_call_id string
---@param command string
function BashTerminal:start(tool_call_id, command)
    if not self:enabled() then
        return
    end
    local buf, chan = self:_ensure_buf()
    self._running = tool_call_id
    self._running_cmd = command
    self._sent = 0
    self._lines = 0

    local reused = vim.api.nvim_buf_line_count(buf) > 1 or (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") ~= ""
    local head = (reused and "\r\n" or "") .. "$ " .. command .. "\r\n"
    pcall(vim.fn.chansend, chan, head)

    self._layout:open_terminal_win(buf, false)
    self._layout:set_terminal_title("$ " .. command .. " · running", "PiToolRunning")
end

--- Forward the cumulative tool_execution_update text for the running command.
--- Computes the delta since the last update and appends it to the terminal.
--- Line endings are converted for the terminal emulator (\n -> \r\n).
---@param tool_call_id string
---@param cumulative_text string
function BashTerminal:update(tool_call_id, cumulative_text)
    if tool_call_id ~= self._running or not self._chan then
        return
    end
    local delta = cumulative_text:sub(self._sent + 1)
    if delta == "" then
        return
    end
    self._sent = #cumulative_text
    self._lines = self._lines + select(2, delta:gsub("\n", ""))
    pcall(vim.fn.chansend, self._chan, (delta:gsub("\n", "\r\n")))
end

--- Finish the run: update the winbar, optionally auto-close the window.
---@param tool_call_id string
---@param ok boolean
---@param status_label string human-readable status for the winbar (e.g. "exit 0")
function BashTerminal:finish(tool_call_id, ok, status_label)
    if tool_call_id ~= self._running then
        return
    end
    self._running = nil
    local cmd = self._running_cmd or "bash"
    self._running_cmd = nil
    local title = "$ " .. cmd .. " · " .. status_label .. " · " .. self._lines .. " lines"
    self._layout:set_terminal_title(title, ok and "PiToolStatus" or "PiToolError")

    local bash = Config.options.bash
    if bash and bash.terminal_auto_close then
        self._layout:close_terminal_win()
    end
end

--- Open (or refocus) the terminal window.
---@param focus boolean
---@return boolean opened_or_visible
function BashTerminal:show(focus)
    if not self:has_output() then
        return false
    end
    self._layout:open_terminal_win(self._buf, focus)
    return true
end

--- Tear down window and buffer (session clear/close).
function BashTerminal:destroy()
    self._running = nil
    self._running_cmd = nil
    self._layout:close_terminal_win()
    if self._buf and vim.api.nvim_buf_is_valid(self._buf) then
        pcall(vim.api.nvim_buf_delete, self._buf, { force = true })
    end
    self._buf = nil
    self._chan = nil
end

return BashTerminal
