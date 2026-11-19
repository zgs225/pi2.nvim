-- Fixture for the parse-luajit rule: must produce ZERO findings.
-- `goto` + `::label::` is Lua 5.2/LuaJIT, which Neovim's parser accepts, so the
-- gate must not flag it (this repo uses exactly that idiom in history.lua).
local M = {}

function M.walk(items)
    local out = {}
    for _, item in ipairs(items) do
        if item == "" then
            goto continue
        end
        out[#out + 1] = item
        ::continue::
    end
    return out
end

-- Long strings, long comments and a string that *looks* like banned syntax:
-- the lexer must not mistake any of these for code.
--[==[ a long comment with & | << >> // inside ]==]
local note = [[a & b, c // d, e >> f]]
local escaped = "quote \" and a comment marker -- not a comment"

return { walk = M.walk, note = note, escaped = escaped }
