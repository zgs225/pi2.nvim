--- Prompt buffer decoration: @-mention and /command highlighting.

local M = {}

local CommandsCache = require("pi.cache.commands")

local ns = vim.api.nvim_create_namespace("pi-prompt-decorators")

--- Workspace cwd of the current tab's session (nil = Neovim's cwd).
---
--- A mention is workspace-relative, so the existence check must look in the
--- session's cwd (a worktree session's files are not under Neovim's cwd).
--- Resolved lazily and defensively so decorating never fails when the session
--- layer is unavailable.
---@return string?
local function session_cwd()
    local ok, manager = pcall(require, "pi.sessions.manager")
    if not ok or type(manager) ~= "table" or type(manager.get) ~= "function" then
        return nil
    end
    local ok_get, session = pcall(manager.get)
    if not ok_get or type(session) ~= "table" then
        return nil
    end
    local cwd = session.cwd
    return type(cwd) == "string" and cwd ~= "" and cwd or nil
end

--- Parse mention ref, stripping optional #L range suffix.
---@param ref string
---@return string path
local function parse_path(ref)
    local path = ref:match("^(.-)#L%d+%-?%d*$")
    return path or ref
end

--- Update mention and command extmarks for a buffer.
---@param buf integer
function M.update(buf)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- /command highlight — first line, starting with /
    if lines[1] and lines[1]:byte(1) == 47 then -- /
        local cmd_token = lines[1]:match("^(/%S+)")
        if cmd_token then
            local name = cmd_token:sub(2)
            local matches = CommandsCache.match(name)
            for _, cmd in ipairs(matches) do
                if cmd.name == name then
                    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
                        end_col = #cmd_token,
                        hl_group = "PiCommand",
                    })
                    break
                end
            end
        end
    end

    -- @mention highlights
    local FilesCache = require("pi.cache.files")
    local cwd = session_cwd()
    for row, line in ipairs(lines) do
        local col = 1
        while col <= #line do
            local start, finish, ref = line:find("@(%S+)", col)
            if not start then
                break
            end
            local Mentions = require("pi.ui.chat.mentions")
            local clean = Mentions.strip_trailing(ref)
            finish = start + #clean -- adjust end to exclude punctuation
            local path = parse_path(clean)
            local Providers = require("pi.mention_providers")
            if Providers.has(path) or FilesCache.exists(path, cwd) then
                vim.api.nvim_buf_set_extmark(buf, ns, row - 1, start - 1, {
                    end_col = finish,
                    hl_group = "PiMention",
                })
            end
            col = finish + 1
        end
    end
end

--- Attach prompt buffer decoration (debounced on text changes).
---@param buf integer
function M.attach(buf)
    local timer = assert(vim.uv.new_timer())
    local DEBOUNCE_MS = 150

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = buf,
        callback = function()
            timer:stop()
            timer:start(
                DEBOUNCE_MS,
                0,
                vim.schedule_wrap(function()
                    if vim.api.nvim_buf_is_valid(buf) then
                        M.update(buf)
                    end
                end)
            )
        end,
    })

    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function()
            timer:stop()
            timer:close()
        end,
    })
end

return M
