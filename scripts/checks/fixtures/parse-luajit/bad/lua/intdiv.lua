-- Fixture for the parse-luajit rule: must FAIL (Lua 5.3 integer division).
local halves = 7 // 2

return halves
