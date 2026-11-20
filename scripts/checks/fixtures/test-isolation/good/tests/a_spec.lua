-- Negative control for `test-isolation`: this file mentions the banned call three
-- ways and must stay quiet. The comment spells stdpath("data"), the long string
-- below spells it again, and the setup redirects to a temp dir instead (G17).
local MENTIONED = 'vim.fn.stdpath("data")'

local guard = [==[
    vim.fn.stdpath("data") .. "/pi"
]==]

local M = {}

describe("isolated spec", function()
    before_each(function()
        -- G17: the pi backend's data dir, the prompt-history store and the draft
        -- all point into a throwaway directory before anything is sent or recalled.
        vim.env.PI_CODING_AGENT_DIR = vim.fn.tempname()
        require("pi.prompt_history")._set_base_dir(vim.fn.tempname())
        require("pi.draft")._set_path(vim.fn.tempname() .. "/draft.txt")
    end)

    after_each(function()
        require("pi.draft")._set_path(nil)
    end)

    it("runs a read-only command and deletes nothing", function()
        -- G18: a `grep` alone is not the defect; the grep-then-delete pair is.
        vim.fn.system({ "grep", "-c", "x", "y" })
        vim.system({ "git", "status" }):wait()
        assert.is_true(guard ~= MENTIONED)
    end)
end)

return M
