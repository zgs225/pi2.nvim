-- uv-fast-event, `good`: every shape the rule must stay quiet on. Expect 0 findings.
--
-- 1. a repeating timer (interval in the `repeat` slot) whose editor work is
--    inside `vim.schedule`,
-- 2. a `vim.system` callback doing the same,
-- 3. a one-shot timer whose callback touches only plain Lua (no editor call, so
--    no fast-event crash) — the one-shot half alone is not this rule's business.

local M = {}

local flush_timer = vim.uv.new_timer()
local once_timer = assert(uv.new_timer())

local ticks = 0
local plains = 0

function M.start()
    flush_timer:start(30, 30, function()
        ticks = ticks + 1
        vim.schedule(function()
            vim.api.nvim_buf_set_lines(0, -1, -1, false, { tostring(ticks) })
        end)
    end)
end

---@param cmd string[]
---@param on_done fun(stdout: string)
function M.spawn(cmd, on_done)
    vim.system(cmd, { text = true }, function(res)
        vim.schedule(function()
            on_done(res.stdout or "")
        end)
    end)
end

function M.one_shot()
    once_timer:start(1000, 0, function()
        plains = plains + 1
    end)
end

return M
