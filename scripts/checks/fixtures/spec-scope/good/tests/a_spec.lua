-- Lexer hygiene plus the compliant shape: every hook is inside a
-- `describe(...)` closure. A comment may mention before_each and after_each
-- freely -- they are not code -- and so may a string body.

describe("outer", function()
    local state = {}

    before_each(function()
        state = {}
    end)

    after_each(function()
        state = nil
    end)

    it("mentions the hooks in prose and in string literals", function()
        local first = "before_each"
        local second = "after_each"
        local long = [[before_each(fn) at the top level]]
        assert.are.equal("before_each", first)
        assert.are.equal("after_each", second)
        assert.are.equal("before_each(fn) at the top level", long)
    end)

    describe("nested", function()
        -- A nested describe is the new innermost bracket: still a describe closure.
        before_each(function()
            state.depth = 1
        end)

        after_each(function()
            state.depth = 0
        end)

        it("nests", function()
            assert.are.equal(1, state.depth)
        end)
    end)

    it("runs a hook-bearing loop inside a describe without confusing the block stack", function()
        for _ = 1, 3 do
            for _ = 1, 1 do
                assert.is_true(true)
            end
        end
        do
            assert.is_true(true)
        end
        if state then
            assert.is_true(true)
        end
    end)
end)

describe(function()
    -- describe's callback as the only argument: still a describe closure.
    before_each(function() end)
    after_each(function() end)

    it("works", function()
        assert.is_true(true)
    end)
end)
