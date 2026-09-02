-- Headless e2e: multi-item dispatch_subagents renders in history without crashing.
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/subagent_dispatch_render_e2e.lua

local Config = require("pi.config")
local History = require("pi.ui.chat.history")
local Manifest = require("pi.subsessions.manifest")
local SubToolUi = require("pi.subsessions.tool_ui")

local manifest_tmp = vim.fn.tempname() .. "-e2e-manifest.json"
Manifest.path = function()
    return manifest_tmp
end

Config.setup({ title = {}, render = { engine = "builtin" } })

local old_lang = vim.fn.getenv("LANG")
vim.fn.setenv("LANG", "zh_CN.UTF-8")

local ok, err = pcall(function()
    assert(SubToolUi.resolve_lang() == "zh", "expected zh from LANG")

    Manifest.upsert("child-a", {
        parent_id = "parent",
        name = "review-auth",
        task_prompt = "t",
        config = {},
        status = "active",
        reported = false,
        created_at = "t",
        last_active_at = "t",
    })

    local h = History.new(992)
    h._blocks_expanded = true
    h:on_tool_start("dispatch_subagents", "e2e-dispatch", {
        items = {
            { ref = "spawn", task = "explore codebase" },
            { ref = "msg", target = "child-a", message = "summarize" },
        },
        wait = false,
    })

    vim.wait(200, function()
        local lines = vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
        for _, line in ipairs(lines) do
            if line:find("子·派发", 1, true) then
                return true
            end
        end
        return false
    end, 20)

    local lines = vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
    local header, tree = false, 0
    for _, line in ipairs(lines) do
        if line:find("子·派发", 1, true) then
            header = true
        end
        if line:find("├─", 1, true) or line:find("└─", 1, true) then
            tree = tree + 1
        end
    end

    assert(header, "expected localized dispatch header")
    assert(tree >= 2, "expected item tree lines, got " .. tree)

    local result = {
        content = {
            {
                type = "text",
                text = vim.json.encode({
                    status = "completed",
                    summary = { done = 2, total = 2 },
                    items = {
                        { ref = "spawn", status = "ok", output = "explored" },
                        { ref = "msg", status = "ok", output = "summarized" },
                    },
                }),
            },
        },
    }
    h:on_tool_end("dispatch_subagents", "e2e-dispatch", result, false)

    local joined = ""
    vim.wait(1000, function()
        joined = table.concat(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false), "\n")
        return joined:find("status:", 1, true) ~= nil and joined:find("✓", 1, true) ~= nil
    end, 20)

    assert(joined:find("status:", 1, true), "expected status line on batch end")
    assert(joined:find("✓", 1, true), "expected completion marks")
end)

if old_lang == vim.NIL then
    vim.fn.setenv("LANG", "")
else
    vim.fn.setenv("LANG", old_lang)
end
os.remove(manifest_tmp)

if not ok then
    io.stderr:write("subagent_dispatch_render_e2e: FAIL\n" .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end

print("subagent_dispatch_render_e2e: OK")
vim.cmd("cq 0")
