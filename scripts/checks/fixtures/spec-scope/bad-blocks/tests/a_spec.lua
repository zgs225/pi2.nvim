-- Three misplaced hooks that a "is it at column 0?" line check would miss.

if os.getenv("FIXTURE_SKIP") then
    -- Still not inside any function: a top-level `if` block is not a describe.
    before_each(function()
        require("fixture.setup").reset()
    end)
end

do
    after_each(function()
        require("fixture.setup").teardown()
    end)
end

describe("helper", function()
    local function shared_setup()
        -- Inside a function, but that function is not a `describe` argument --
        -- calling it later from a spec still registers the hook on nothing.
        before_each(function()
            require("fixture.setup").reset()
        end)
    end

    it("calls the helper", function()
        shared_setup()
        assert.is_true(true)
    end)
end)
