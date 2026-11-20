-- uv-fast-event, `bad-timer`: a one-shot timer whose callback calls the editor
-- from the fast event. Expect 1 finding, at line 10 (`vim.api.…`), not at the timer.

local M = {}

---@param buf integer
function M.tick(buf)
    local timer = assert(uv.new_timer())
    timer:start(300, 0, function()
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "tick" })
    end)
end

return M
