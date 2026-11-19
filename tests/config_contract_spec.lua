-- Runtime contract of `Config.setup` (gotcha G31).
--
-- The *structural* half of G19 — that the `---@class pi.Options` annotation, the
-- test fixtures and the `defaults` table agree — is enforced statically by
-- `scripts/checks/rules/config_three_spots.py` through `make check`, so it is
-- deliberately not repeated here. This spec covers only the RUNTIME contract:
-- `setup()` must hand back a table that is independent of the module-local
-- `defaults`, so a user plugin (or a spec) writing into a nested option cannot
-- pollute the defaults for every later `setup()` in the process.
--
-- It is the regression guard for the deepcopy in `M.setup`:
--   M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
-- Without that deepcopy, `tbl_deep_extend` keeps a *reference* to the first
-- source's nested tables, so `options.subagent` IS `defaults.subagent` (G31).

local Config = require("pi.config")

describe("config contract (G31)", function()
    before_each(function()
        Config.setup({})
    end)

    after_each(function()
        Config.setup({})
    end)

    it("setup() restores a nested default after an in-place write", function()
        Config.setup({})
        -- lua/pi/config.lua:535 — `defaults.subagent.max_children = 5`.
        assert.equals(5, Config.options.subagent.max_children)

        Config.options.subagent.max_children = 2
        Config.setup({})

        -- Before the deepcopy fix this read back 2: the write landed in
        -- `defaults.subagent` and setup() re-derived options from it.
        assert.equals(5, Config.options.subagent.max_children)
    end)

    it("nested option tables are not aliased to the module defaults", function()
        Config.setup({})
        local first = Config.options.subagent

        Config.setup({})

        assert.is_false(rawequal(first, Config.options.subagent))
        -- lua/pi/config.lua:533-535 — every nested key still carries its default.
        assert.are.same(
            { enabled = true, max_children = 5 },
            { enabled = Config.options.subagent.enabled, max_children = Config.options.subagent.max_children }
        )
    end)

    it("a write to one nested subtable does not leak into a sibling", function()
        Config.setup({})
        -- lua/pi/config.lua:578-581 — `defaults.todo` is a sibling of `subagent`.
        assert.equals(20, Config.options.todo.max_items)

        Config.options.subagent.max_children = 2
        Config.options.subagent.viewer.todo.max_items = 99

        assert.equals(20, Config.options.todo.max_items)

        Config.setup({})

        assert.equals(5, Config.options.subagent.max_children)
        assert.equals(20, Config.options.subagent.viewer.todo.max_items)
        assert.equals(20, Config.options.todo.max_items)
    end)

    it("a fresh setup() returns a fresh table each time", function()
        Config.setup({})
        local first_options = Config.options
        local first_subagent = Config.options.subagent

        Config.setup({})

        assert.is_false(rawequal(first_options, Config.options))
        assert.is_false(rawequal(first_subagent, Config.options.subagent))
    end)
end)
