-- Positive control for the same bookkeeping: one function, a loop between the
-- grep and the delete. Tracking the loop must not switch the pairing off — the
-- G18 pattern is still reported at the delete.
local function clean(sessions)
    for _, path in ipairs(sessions) do
        vim.fn.system("grep -rl sentinel " .. path)
    end
    os.remove(sessions.manifest)
end

return { clean = clean }
