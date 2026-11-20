-- A chunk-level loop must not leak a block level: `for`/`while` open their block
-- at the keyword and close the header with a `do` that opens nothing, so the
-- capture below is still at depth 0 and must be reported exactly once.
local Config = require("pi.config")

for index = 1, 2 do
    local _ = index
end

while false do
    local _ = "unreachable"
end

local frozen = Config.options.labels.tool

return { frozen = frozen }
