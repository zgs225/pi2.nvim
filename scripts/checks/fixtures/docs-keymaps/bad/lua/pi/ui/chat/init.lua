local Chat = {}
Chat.__index = Chat

function Chat:_set_keymaps()
    local hbuf = self._history:buf()
    vim.keymap.set("n", "<CR>", function()
        self:submit()
    end, { buffer = hbuf })

    -- Undocumented below: `gp` is bound but doc/keymaps.md never mentions it.
    vim.keymap.set("n", "gp", function()
        self:return_to_parent()
    end, { buffer = hbuf })
end

return Chat
