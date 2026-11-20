-- Negative control for the second subject directory: an e2e script that runs a
-- `grep` and writes to a temp dir, but never deletes anything (G18 stays quiet).
local state = vim.fn.tempname()

local function collect()
    local out = vim.fn.system({ "grep", "-l", "sentinel", state })
    return out
end

io.write(collect(), "\n")
io.write(tostring(vim.env.PI_CODING_AGENT_DIR), "\n")
