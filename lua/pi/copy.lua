--- Register/clipboard writes for the chat copy feature.
---
--- A yank is not just "put the text in a register": Vim also fills the
--- numbered register `0`, honours a register prefix (`"ayy`), and mirrors the
--- system clipboard only when 'clipboard' says so. `:PiCopy` and the copy key
--- (`copy.key`, default `gy`) have to behave the same way or a user's
--- `"ap`/`"0p` habits break.

local M = {}

--- The register a plain yank would target for the current 'clipboard' setting.
---@return string?
local function clipboard_mirror()
    local clipboard = vim.o.clipboard or ""
    if clipboard:find("unnamedplus", 1, true) then
        return "+"
    end
    if clipboard:find("unnamed", 1, true) then
        return "*"
    end
    return nil
end

--- Write `text` the way a yank does.
---
--- - no register prefix: `"` and `0` are filled, plus `*` / `+` when 'clipboard'
---   contains `unnamed` / `unnamedplus`;
--- - a register prefix (`"agy` with the default key): only that register is
---   written;
--- - `opts.clipboard`: `+` as well (`:PiCopy!`), so a build without a clipboard
---   provider still keeps the text in `"` / `0` instead of silently dropping it.
---
--- The register type is linewise on purpose: a message or a range of history
--- lines is line-oriented, so `p` must put it below the cursor rather than
--- splice it into the current line.
---@param text string
---@param opts? { register?: string, clipboard?: boolean }
---@return string target the register the text landed in (for the notification)
function M.write(text, opts)
    opts = opts or {}
    local register = opts.register
    if register == nil then
        register = vim.v.register
    end
    if type(register) ~= "string" then
        register = ""
    end

    if opts.clipboard then
        pcall(vim.fn.setreg, "+", text, "V")
        pcall(vim.fn.setreg, '"', text, "V")
        pcall(vim.fn.setreg, "0", text, "V")
        return "+"
    end

    if register ~= "" and register ~= '"' then
        vim.fn.setreg(register, text, "V")
        return register
    end

    vim.fn.setreg('"', text, "V")
    vim.fn.setreg("0", text, "V")
    local mirror = clipboard_mirror()
    if mirror then
        pcall(vim.fn.setreg, mirror, text, "V")
        return mirror
    end
    return '"'
end

--- Human-readable register name for a notification.
---@param register string
---@return string
function M.describe(register)
    if register == '"' then
        return "the unnamed register"
    end
    return "register " .. register
end

return M
