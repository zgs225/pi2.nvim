local Chat = {}
Chat.__index = Chat

function Chat:_set_keymaps()
    local hbuf = self._history:buf()
    vim.keymap.set("n", "<C-q>", function()
        self:toggle()
    end, { buffer = hbuf })
end

return Chat
