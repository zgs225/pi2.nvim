-- Negative control for the loop bookkeeping (the false positive this fixture
-- locks): `scan` greps inside a `for`, `wipe` deletes after a `while`. Neither
-- function holds both halves, so nothing may be reported — even though both
-- loops end before anything else happens.
local function scan(sessions)
    for _, path in ipairs(sessions) do
        vim.fn.system("grep -rl sentinel " .. path)
    end
end

local function wipe(manifest)
    local guard = #manifest.entries
    while guard > 0 do
        guard = guard - 1
    end
    os.remove(manifest.path)
end

return { scan = scan, wipe = wipe }
