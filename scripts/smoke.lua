-- Headless smoke check for pi.nvim (run via `make smoke`).
--
-- Boots the real user config (lazy.nvim → pi loads from its installed path —
-- see the worktree caveat G23), opens the chat, and asserts the end-to-end
-- wiring comes up: the chat history/prompt buffers exist and the session's
-- RPC backend process starts. Exits `cq 0` on success, `cq 1` on failure so
-- the shell sees the result.
--
-- Nothing is submitted to the agent, so no session transcript is written, and
-- Neovim's VimLeavePre teardown stops the spawned backend process on exit.
--
-- This is the minimal, permanent version of the per-feature headless e2e
-- template (`.agents/skills/develop/scripts/headless_e2e_template.lua`); see
-- `.agents/skills/develop/references/testing.md` (§ Layer 2) for the full
-- playbook and pitfalls.

local failures = {}

local function check(name, ok, detail)
    print(string.format("[%s] %s%s", ok and "PASS" or "FAIL", name, detail and (" — " .. detail) or ""))
    if not ok then
        failures[#failures + 1] = name
    end
end

local function find_buf(ft)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].filetype == ft then
            return b
        end
    end
end

local ok, err = pcall(function()
    -- Loading pi through the user config exercises lazy.nvim wiring and the
    -- plugin's setup path end-to-end.
    assert(require("pi"), "pi failed to load")
    check("plugin loads", true)

    require("pi").show({ layout = "side" })
    vim.wait(8000, function()
        return find_buf("pi-chat-history") ~= nil and find_buf("pi-chat-prompt") ~= nil
    end, 50)
    check(
        "chat buffers exist (history + prompt)",
        find_buf("pi-chat-history") ~= nil and find_buf("pi-chat-prompt") ~= nil
    )

    local session = require("pi.sessions.manager").get()
    check("session created", session ~= nil)
    local backend_up = session ~= nil and vim.wait(8000, function()
        return session.rpc:is_running()
    end, 50)
    check("rpc backend process running", backend_up == true)
end)

if not ok then
    check("smoke body completed without error", false, tostring(err))
end

if #failures > 0 then
    print("SMOKE: " .. #failures .. " failed — " .. table.concat(failures, ", "))
    vim.cmd("cq 1")
else
    print("SMOKE: ALL GREEN")
    vim.cmd("cq 0")
end
