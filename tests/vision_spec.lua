-- Vision fallback: pure marker parsing, transform prediction, notify prefix.

describe("vision", function()
    local Vision

    before_each(function()
        Vision = require("pi.vision")
    end)

    describe("make_marker / parse", function()
        it("round-trips a marker after user text", function()
            local marker = Vision.make_marker("anthropic/claude-sonnet-4-5", "A screenshot of a diff view.")
            local text = "review this\n\n" .. marker
            local parsed = Vision.parse(text)
            assert.are.equal("review this", parsed.text)
            assert.are.equal("anthropic/claude-sonnet-4-5", parsed.model)
            assert.are.equal("A screenshot of a diff view.", parsed.description)
        end)

        it("round-trips a multi-line description", function()
            local desc = "line one\nline two\nline three"
            local text = "look\n\n" .. Vision.make_marker("google/gemini-2.5-pro", desc)
            local parsed = Vision.parse(text)
            assert.are.equal("look", parsed.text)
            assert.are.equal("google/gemini-2.5-pro", parsed.model)
            assert.are.equal(desc, parsed.description)
        end)

        it("handles an empty original text (image-only submission)", function()
            local parsed = Vision.parse(Vision.make_marker("openai/gpt-4o", "desc"))
            assert.are.equal("", parsed.text)
            assert.are.equal("openai/gpt-4o", parsed.model)
            assert.are.equal("desc", parsed.description)
        end)

        it("returns the text unchanged when there is no marker", function()
            local parsed = Vision.parse("plain message, no images")
            assert.are.equal("plain message, no images", parsed.text)
            assert.is_nil(parsed.model)
            assert.is_nil(parsed.description)
        end)

        it("returns the text unchanged for an unterminated marker", function()
            local text = "hello\n\n<pi-vision model=\"a/b\">\npartial"
            local parsed = Vision.parse(text)
            assert.are.equal(text, parsed.text)
            assert.is_nil(parsed.model)
        end)

        it("returns the text unchanged when the model attribute is malformed", function()
            local text = 'hello\n\n<pi-vision model="broken\ndesc</pi-vision>'
            local parsed = Vision.parse(text)
            assert.are.equal(text, parsed.text)
            assert.is_nil(parsed.model)
        end)

        it("trims the blank separator between original text and marker", function()
            local text = "text\n\n\n" .. Vision.make_marker("p/m", "d") .. "\n"
            local parsed = Vision.parse(text)
            assert.are.equal("text", parsed.text)
        end)
    end)

    describe("expects_transform", function()
        local function opts(model)
            return { vision = { model = model } }
        end

        it("predicts a transform for a non-vision model with attachments", function()
            assert.are.equal("p/m", Vision.expects_transform(opts("p/m"), false, 2))
        end)

        it("is a no-op when the main model supports images", function()
            assert.is_nil(Vision.expects_transform(opts("p/m"), true, 2))
        end)

        it("is a no-op when vision is not configured", function()
            assert.is_nil(Vision.expects_transform({ vision = {} }, false, 2))
            assert.is_nil(Vision.expects_transform({}, false, 2))
        end)

        it("is a no-op without image attachments", function()
            assert.is_nil(Vision.expects_transform(opts("p/m"), false, 0))
        end)

        it("is a no-op when the model capability is unknown", function()
            assert.is_nil(Vision.expects_transform(opts("p/m"), nil, 2))
        end)

        it("rejects an empty model string", function()
            assert.is_nil(Vision.expects_transform(opts(""), false, 1))
        end)
    end)

    describe("parse_notify", function()
        it("extracts the reason from a prefixed error", function()
            assert.are.equal("boom", Vision.parse_notify("[pi-vision] boom"))
        end)

        it("ignores unrelated notifications", function()
            assert.is_nil(Vision.parse_notify("some other extension failed"))
            assert.is_nil(Vision.parse_notify(nil))
        end)

        it("falls back to a generic reason for a bare prefix", function()
            assert.are.equal("unknown error", Vision.parse_notify("[pi-vision]"))
            assert.are.equal("unknown error", Vision.parse_notify("[pi-vision]   "))
        end)
    end)
end)
