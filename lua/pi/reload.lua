--- Buffer reload logic: syncs open Neovim buffers after pi modifies files on disk.

local Notify = require("pi.notify")

local M = {}

---@class pi.ReloadResult
---@field reloaded string[] Paths whose buffers were reloaded silently.
---@field skipped string[] Paths whose buffers were skipped (modified by user).

--- Canonicalize a path for buffer matching: absolute with symlinks resolved.
--- Neovim buffer names are always symlink-resolved, while paths reported by
--- pi may not be (e.g. a cwd under /tmp on macOS, where /tmp → /private/tmp).
--- `:p` alone does not resolve symlinks. Falls back to the absolute form when
--- the file no longer exists (fs_realpath returns nil).
---
--- Relative paths are resolved against `base` — the workspace the pi process ran
--- in — because tool arguments are workspace-relative and Neovim's cwd may be a
--- different checkout (a worktree session, or a resumed session started
--- elsewhere). Omitting `base` keeps the old process-cwd behaviour.
---@param path string
---@param base? string workspace cwd (default: Neovim's current cwd)
---@return string
local function canonical(path, base)
    local is_absolute = path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil or path:sub(1, 2) == "\\\\"
    local abs
    if not is_absolute and type(base) == "string" and vim.trim(base) ~= "" then
        abs = vim.fn.fnamemodify(vim.trim(base):gsub("[\\/]+$", "") .. "/" .. path, ":p")
    else
        abs = vim.fn.fnamemodify(path, ":p")
    end
    return vim.uv.fs_realpath(abs) or abs
end

--- Reload all loaded, unmodified buffers whose file matches any of the given paths.
--- Modified buffers are never touched. Returns a summary of what happened.
---@param paths string[] Absolute or relative file paths that pi just modified.
---@param cwd? string workspace cwd relative paths resolve against (default: Neovim's current cwd)
---@return pi.ReloadResult
function M.reload_buffers(paths, cwd)
    ---@type string[]
    local reloaded = {}
    ---@type string[]
    local skipped = {}

    for _, raw_path in ipairs(paths) do
        local abs_path = canonical(raw_path, cwd)
        local found = false
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == abs_path then
                found = true
                if vim.bo[buf].modified then
                    skipped[#skipped + 1] = raw_path
                else
                    vim.api.nvim_buf_call(buf, function()
                        vim.cmd("silent edit!")
                    end)
                    reloaded[#reloaded + 1] = raw_path
                end
                break -- one buffer per path is enough
            end
        end
        -- No loaded buffer for this path: nothing to do.
        if not found then
            -- intentionally not tracked
        end
    end

    return { reloaded = reloaded, skipped = skipped }
end

--- Called after a file-changing tool completes. Reads the reload mode from
--- config (never cached) and acts accordingly.
---@param path string The file path that was just modified (as recorded in changed_files).
---@param cwd? string workspace cwd the path is relative to (default: Neovim's current cwd)
function M.on_file_changed(path, cwd)
    local mode = require("pi.config").options.reload.mode
    if mode == false then
        return
    end

    local result = M.reload_buffers({ path }, cwd)

    if mode == "notify" then
        if #result.reloaded > 0 then
            Notify.info("Reloaded: " .. table.concat(result.reloaded, ", "))
        end
        if #result.skipped > 0 then
            Notify.warn("Modified (not reloaded): " .. table.concat(result.skipped, ", "))
        end
    end
    -- "silent": no notifications at all
end

return M
