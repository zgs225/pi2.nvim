-- In-sync tree (fixture): every shape the expr-mapping gate must stay quiet on.
--
-- 1. an <expr> mapping returning the literal "<Esc>" (the G2 fix),
-- 2. an <expr> callback whose nvim_buf_set_lines sits inside vim.schedule(...)
--    (the G1 fix),
-- 3. a NON-expr mapping writing the buffer directly: <expr> is what makes a
--    buffer write illegal, so this one must never fire,
-- 4. an <expr> mapping whose callback is a same-file function passed by name and
--    returning the literal "<Up>".

local M = {}

local function pass_up()
    return "<Up>"
end

function M.setup(buf)
    vim.keymap.set("i", "<Esc>", function()
        return "<Esc>"
    end, { buffer = buf, expr = true, desc = "leave insert" })

    vim.keymap.set("i", "<C-p>", function()
        vim.schedule(function()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
        end)
        return ""
    end, { buffer = buf, expr = true, desc = "recall, deferred" })

    vim.keymap.set("i", "<Tab>", function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x" })
    end, { buffer = buf, desc = "not an expr mapping: a direct write is fine" })

    vim.keymap.set("i", "<Up>", pass_up, { buffer = buf, expr = true, desc = "pass through" })

    -- Bracket-string option keys are the same Lua fields. `["buffer"]`/`["desc"]`
    -- without an `expr` key must stay a plain mapping, so its direct write is legal.
    vim.keymap.set("i", "<C-n>", function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "next" })
    end, { ["buffer"] = buf, ["desc"] = "bracket keys, still not an expr mapping" })

    -- `return ("<Down>")` is a parenthesised literal: skipping the `(` must not
    -- turn a correct <expr> fallback into a finding.
    vim.keymap.set("i", "<Down>", function()
        return ("<Down>")
    end, { buffer = buf, ["expr"] = true, desc = "parens around the literal are harmless" })
end

return M
