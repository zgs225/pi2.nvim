-- One hook at the chunk top level, one compliant describe.
-- The top-level `before_each` is exactly G14: it registers nothing, the spec's
-- setup never runs, and the failure has no assertion message.

local Setup = require("fixture.setup")

before_each(function()
    Setup.reset()
end)

describe("compliant", function()
    before_each(function()
        Setup.reset()
    end)

    after_each(function()
        Setup.teardown()
    end)

    it("works", function()
        assert.is_true(true)
    end)
end)
