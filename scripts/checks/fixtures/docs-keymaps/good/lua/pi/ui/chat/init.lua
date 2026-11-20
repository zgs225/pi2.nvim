local Chat = {}
Chat.__index = Chat

function Chat:_set_keymaps()
    local hbuf = self._history:buf()
    vim.keymap.set("n", "<CR>", function()
        self:submit()
    end, { buffer = hbuf })

    -- Mode tables are skipped like a mode string: the lhs is the next argument.
    vim.keymap.set({ "n", "i" }, "<C-n>", function()
        self._prompt:history_next()
    end, { buffer = hbuf })
end

return Chat
