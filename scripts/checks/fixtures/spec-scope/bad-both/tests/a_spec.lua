-- Both hooks at the chunk top level: the classic G14 shape.
-- `make test` then reports `Error 1` for this file with no failing assertion,
-- because the hooks no-op and the specs run without their setup/teardown.

before_each(function()
    require("fixture.setup").reset()
end)

after_each(function()
    require("fixture.setup").teardown()
end)

describe("body", function()
    it("runs without the setup above", function()
        assert.is_true(true)
    end)
end)
