-- The bundled search-tools extension: config default, extension path, and the
-- `--extension` injection in `Cli.command`.
--
-- Steering the model away from `bash grep` is only worth anything if the
-- extension is actually loaded by default, so the injection half is asserted
-- here (the wire-level effect is `make e2e-search-tools`).

local Config = require("pi.config")
local Cli = require("pi.cli")

--- Is `path` present as a `--extension` argument in `cmd`?
---@param cmd string[]
---@param path string
---@return boolean
local function has_extension(cmd, path)
    for index = 1, #cmd - 1 do
        if cmd[index] == "--extension" and cmd[index + 1] == path then
            return true
        end
    end
    return false
end

describe("search_tools config + extension injection", function()
    before_each(function()
        Config.setup({})
    end)

    after_each(function()
        Config.setup({})
    end)

    it("defaults search_tools.enabled to true", function()
        assert.is_true(Config.options.search_tools.enabled)
    end)

    it("restores the default after setup()", function()
        Config.options.search_tools.enabled = false
        Config.setup({})
        assert.is_true(Config.options.search_tools.enabled)
    end)

    it("resolves an existing absolute extension path", function()
        local path = Cli.search_tools_extension_path()
        assert.is_true(vim.startswith(path, "/"))
        assert.is_truthy(path:match("/extensions/search%-tools%.ts$"))
        assert.equals(1, vim.fn.filereadable(path))
    end)

    it("passes --extension <path> when enabled", function()
        Config.setup({ search_tools = { enabled = true } })
        local path = Cli.search_tools_extension_path()
        assert.is_true(has_extension(Cli.command(), path))
    end)

    it("omits --extension <path> when disabled but keeps every other extension", function()
        Config.setup({ search_tools = { enabled = false } })
        local cmd = Cli.command()
        assert.is_false(has_extension(cmd, Cli.search_tools_extension_path()))
        -- The other bundled extensions still ride as `--extension` pairs.
        assert.is_true(has_extension(cmd, Cli.tree_extension_path()))
        assert.is_true(has_extension(cmd, Cli.vision_extension_path()))
    end)
end)
