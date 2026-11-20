-- Bypass fixture: two spellings the first version of the rule missed, and both
-- are the same defect it exists for.
--
--   { ["expr"] = true }            the option table written with a string key
--                                  (same Lua field, one bracket deeper), and
--   return (vim.keycode("<Up>"))   the G2 defect behind one cosmetic paren.
--
-- Expect ONE finding, and it is the G2 error (severity="error"): the callback
-- returns the internal keycode bytes, so pressing <Up> off the top line types
-- `\x80ku` into the prompt. Nothing here writes the buffer, so no G1 warn.

local M = {}

function M.setup(buf)
    vim.keymap.set("i", "<Up>", function()
        if vim.api.nvim_win_get_cursor(0)[1] > 1 then
            return (vim.keycode("<Up>"))
        end
        return "<Up>"
    end, { ["buffer"] = buf, ["expr"] = true, ["desc"] = "pass through" })
end

return M
