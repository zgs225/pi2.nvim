-- Fixture for the parse-luajit rule: must FAIL (Lua 5.3 bitwise operator).
-- Neovim stable ships LuaJIT, which has no `&`.
local function is_continuation(byte)
    return (byte & 0xc0) == 0x80
end

return is_continuation
