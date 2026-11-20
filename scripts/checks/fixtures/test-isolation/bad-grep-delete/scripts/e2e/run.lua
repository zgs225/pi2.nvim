-- Ban 2 fixture (G18): "clean up the test sessions" — grep for the sentinel and
-- delete every hit. With the backend stubbed no test transcript exists, so the
-- hits are real sessions.
local sessions = "/home/me/.pi/agent/sessions"

local function clean_up()
    local hits = vim.fn.system({ "grep", "-rl", "test sentinel", sessions })
    for path in hits:gmatch("[^\n]+") do
        os.remove(path)
    end
end

clean_up()
