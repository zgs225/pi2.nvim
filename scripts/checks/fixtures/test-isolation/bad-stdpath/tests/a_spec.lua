-- Ban 1 fixture (G17): resolving the user's real data dir from a spec.
local dir = vim.fn.stdpath("data") .. "/pi"
local history = dir .. "/prompt_history.json"

return { dir = dir, history = history }
