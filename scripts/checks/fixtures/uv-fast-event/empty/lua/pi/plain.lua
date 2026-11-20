-- uv-fast-event, `empty`: a lua/ tree with no `new_timer(` and no `vim.system(`
-- at all. The rule has nothing to inspect, which warns (expect 1) instead of
-- reporting a clean tree or breaking the gate.

local M = {}

function M.now_ms()
    return vim.uv.now()
end

return M
