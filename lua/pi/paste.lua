--- Clipboard / drag-and-drop image paste interception for the prompt buffer.
---
--- Neovim has no "paste" autocmd and no buffer-local paste hook: the only
--- supported hook is the global |vim.paste()| handler (invoked by both GUI
--- |nvim_paste()| and TUI bracketed paste). We install a single, idempotent
--- wrapper that is a pure pass-through everywhere except a π prompt buffer:
--- the very first thing it does is check the current filetype, and any
--- non-prompt paste is delegated to the original handler untouched. This keeps
--- the global footprint minimal — paste in the rest of the editor behaves
--- exactly as if π were not loaded.
---
--- Inside a prompt buffer:
---   1. Kitty CSI-u / xterm modifyOtherKeys encodings of Ctrl+J (and Shift+Enter)
---      are rewritten to real newlines. Some terminals paste LF as those sequences
---      instead of `\n`, which would otherwise show up as literal `^[[106;5u`.
---      Streamed chunks (phase 1/2/3) keep an incomplete CSI tail across calls.
---   2. A single-call paste (-1) is then inspected for a dropped image file path
---      (GUI drag-and-drop hands us the path as text) and attached directly;
---   3. otherwise, if the system clipboard currently holds an image, the image
---      is attached (via |Pi.paste_image()|) and the text paste is cancelled.
--- Any other paste is delegated to the original handler unchanged. Image attach
--- still runs only on phase -1; streamed text is rewritten then passed through.
---
--- The paste channel only ever carries text (the terminal/GUI does not hand
--- Neovim the clipboard image bytes), so the clipboard image is detected by
--- querying the OS clipboard directly through img-clip.nvim at paste time.
local Config = require("pi.config")
local Ft = require("pi.filetypes")

local M = {}

local installed = false
local autocmd_installed = false

--- Image file extensions recognised for drag-and-drop path attachment.
local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, gif = true, webp = true, svg = true }

--- Registry of live prompt buffers → their attachment list. Populated by
--- |pi.ChatPrompt| on creation so the global handler can reach the right
--- attachments without touching session state. Keyed by bufnr so multiple
--- tabs (each with its own prompt) coexist.
---@type table<integer, pi.ChatAttachments>
local prompts = {}

--- Incomplete CSI tail held between streamed paste chunks (prompt only).
local paste_pending = ""

--- Terminal encodings of "newline" that some pastes deliver as text instead of LF.
--- Kitty CSI-u Ctrl+J, xterm modifyOtherKeys Ctrl+J, Kitty CSI-u Shift+Enter.
local NEWLINE_ALIAS_PATTERNS = {
    "\27%[106;5u",
    "\27%[27;5;106~",
    "\27%[13;2u",
}

--- True when `frag` looks like an unfinished CSI we might complete in the next chunk.
---@param frag string
---@return boolean
local function is_incomplete_csi(frag)
    if frag == "\27" then
        return true
    end
    -- Started a CSI (ESC [ digits/semicolons) but not yet the terminator u/~.
    return frag:match("^\27%[[%d;]*$") ~= nil
end

--- Rewrite newline-alias CSI sequences in a paste chunk.
---
--- `pending` is an incomplete ESC sequence from the previous streamed chunk
--- (empty for a complete chunk). On return, `pending` is the new incomplete
--- tail, or `""` when the chunk ended on a complete sequence.
---@param lines string[]
---@param pending string
---@return string[] rewritten
---@return string pending
function M._rewrite_newline_aliases(lines, pending)
    pending = pending or ""
    local joined = pending .. table.concat(lines, "\n")
    local keep = 0
    local tail = joined:sub(-32)
    local esc = tail:find("\27[^\27]*$")
    if esc then
        local frag = tail:sub(esc)
        if is_incomplete_csi(frag) then
            keep = #frag
        end
    end
    local complete = joined
    local next_pending = ""
    if keep > 0 then
        complete = joined:sub(1, #joined - keep)
        next_pending = joined:sub(#joined - keep + 1)
    end
    for _, pat in ipairs(NEWLINE_ALIAS_PATTERNS) do
        complete = complete:gsub(pat, "\n")
    end
    return vim.split(complete, "\n", { plain = true }), next_pending
end

--- Register a prompt buffer so pasted image file paths attach to it.
---@param buf integer
---@param attachments pi.ChatAttachments
function M.register(buf, attachments)
    prompts[buf] = attachments
end

--- Forget a prompt buffer (idempotent).
---@param buf integer
function M.unregister(buf)
    prompts[buf] = nil
end

--- Quietly check whether the system clipboard currently holds an image.
--- Never warns: returns false when img-clip is missing, no clipboard tool is
--- available, or the content is not an image.
---@return boolean
function M._clipboard_has_image()
    local ok, clip = pcall(require, "img-clip.clipboard")
    if not ok then
        return false
    end
    if not clip.get_clip_cmd() then
        return false
    end
    return clip.content_is_image() == true
end

--- If `line` is a path to an existing image file, attach it to the prompt that
--- owns `buf`. Handles GUI drag-and-drop, which delivers the file path as text.
---@param buf integer
---@param line string
---@return boolean attached true when the line was consumed as an image drop
local function try_attach_dropped_image(buf, line)
    if line == "" then
        return false
    end
    local ext = line:lower():match("%.(%w+)$")
    if not ext or not IMAGE_EXTS[ext] then
        return false
    end
    local stat = vim.uv.fs_stat(line)
    if not stat or stat.type ~= "file" then
        return false
    end
    local attachments = prompts[buf]
    if not attachments then
        return false
    end
    attachments:add_file(line)
    return true
end

--- Build the wrapped |vim.paste()| handler.
---@param orig fun(lines: string[], phase: integer): boolean the original handler
---@return fun(lines: string[], phase: integer): boolean
function M._make_handler(orig)
    return function(lines, phase)
        local buf = vim.api.nvim_get_current_buf()
        -- Scope guarantee: anything outside a π prompt buffer is a pure
        -- pass-through — no CSI rewrite, no clipboard query, no fs_stat.
        if vim.bo[buf].filetype ~= Ft.prompt then
            return orig(lines, phase)
        end

        -- First / only chunk of a paste: drop any leftover CSI tail.
        if phase == 1 or phase == -1 then
            paste_pending = ""
        end
        local rewritten
        rewritten, paste_pending = M._rewrite_newline_aliases(lines, paste_pending)
        if phase == 3 or phase == -1 then
            if paste_pending ~= "" then
                rewritten[#rewritten] = (rewritten[#rewritten] or "") .. paste_pending
                paste_pending = ""
            end
        end

        -- Streamed pastes (phase 1/2/3): rewritten text only, never image attach.
        if phase ~= -1 then
            return orig(rewritten, phase)
        end

        -- Single-line paste into a prompt: first try a dropped image file path.
        if #rewritten == 1 and try_attach_dropped_image(buf, rewritten[1] or "") then
            return true -- cancel the text paste; the image is attached
        end

        -- Otherwise, attach a clipboard image if there is one.
        if Config.options.prompt.paste_image and M._clipboard_has_image() then
            -- Defer the attach: mutating the attachment buffer from inside the
            -- paste handler can hit textlock otherwise.
            vim.schedule(function()
                require("pi").paste_image()
            end)
            return false -- cancel the (text) paste
        end

        return orig(rewritten, phase)
    end
end

--- Install the global |vim.paste()| wrapper. Idempotent. The wrapper reads
--- `prompt.paste_image` at call time, so the feature can be toggled without
--- reinstalling.
function M.setup()
    if installed then
        return
    end
    installed = true
    vim.paste = M._make_handler(vim.paste)

    -- Keep the registry from leaking: drop entries when their buffer goes away.
    -- Guarded separately from `installed` so test resets (which re-run setup)
    -- do not stack duplicate autocmds.
    if not autocmd_installed then
        autocmd_installed = true
        vim.api.nvim_create_autocmd("BufWipeout", {
            callback = function(args)
                prompts[args.buf] = nil
            end,
        })
    end
end

--- Reset install state and registry. Test helper.
function M._reset()
    installed = false
    prompts = {}
    paste_pending = ""
end

return M
