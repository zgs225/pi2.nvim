-- The alias itself is the safe idiom and must stay quiet; only the three
-- `.options` reads below it are frozen pre-setup() snapshots.
local Config = require("pi.config")

-- A chunk-level `if` body is depth 1, a narrowing the rule documents: it is not
-- reported, and it must not disturb the depth (or the alias scope) of what
-- follows, which is what makes the three findings below possible.
if vim.fn.has("nvim-0.10") == 1 then
    local inside_if = Config.options.labels.tool
    vim.g.pi_inside_if = inside_if
end

local label = Config.options.labels.tool
local tools = Config.options.subagent.tools
local opts = require("pi.config")["options"]

return { label = label, tools = tools, opts = opts }
