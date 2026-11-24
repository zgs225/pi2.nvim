-- Unit tests for pi.compaction.extension — the runtime config file the bundled
-- `extensions/compaction.ts` re-reads on every compaction event.

local Extension = require("pi.compaction.extension")

local uv = vim.uv

describe("pi.compaction.extension", function()
    local dir

    before_each(function()
        Extension._reset()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        Extension._set_path(dir .. "/compaction-config")
    end)

    after_each(function()
        Extension._reset()
        vim.fn.delete(dir, "rf")
    end)

    ---@return string
    local function raw()
        local fd = assert(uv.fs_open(Extension.state_path(), "r", 420))
        local st = assert(uv.fs_fstat(fd))
        local text = uv.fs_read(fd, st.size, 0)
        uv.fs_close(fd)
        return text
    end

    ---@return table
    local function decoded_raw()
        return vim.json.decode(raw())
    end

    describe("state_path", function()
        it("defaults to a run-dir file named after the pid", function()
            Extension._reset()
            local path = Extension.state_path()
            assert.matches("pi2nvim%-compaction%-config%-" .. tostring(vim.fn.getpid()) .. "$", path)
            assert.matches("[/\\]run[/\\]", path)
        end)

        it("honours the _set_path override", function()
            assert.are.equal(dir .. "/compaction-config", Extension.state_path())
        end)

        it("restores the default in _reset", function()
            Extension._reset()
            assert.is_truthy(Extension.state_path():match("pi2nvim%-compaction%-config"))
        end)
    end)

    describe("defaults", function()
        it("matches the documented shape", function()
            assert.are.same({
                enabled = true,
                cleaner = {
                    enabled = true,
                    max_read = 50,
                    max_modified = 100,
                    drop_temp = true,
                    drop_build = true,
                    strip_previous_lists = true,
                },
                checkpoint = {
                    enabled = false,
                    model = nil,
                    thinking_level = nil,
                    language = "auto",
                    max_words = 1500,
                },
                state = { enabled = true, max_tokens = 1000 },
                prune = { enabled = false, high_water = 0.7, min_turns = 8 },
                owner = { detect = true },
            }, Extension.defaults())
        end)
    end)

    describe("publish", function()
        it("writes the full shape with every key present", function()
            Extension.publish(nil)
            local payload = decoded_raw()
            for _, key in ipairs({ "enabled", "cleaner", "checkpoint", "state", "prune", "owner" }) do
                assert.is_not_nil(payload[key], "missing top-level key " .. key)
            end
            for _, key in ipairs({
                "enabled",
                "max_read",
                "max_modified",
                "drop_temp",
                "drop_build",
                "strip_previous_lists",
            }) do
                assert.is_not_nil(payload.cleaner[key], "missing cleaner." .. key)
            end
            for _, key in ipairs({ "enabled", "language", "max_words" }) do
                assert.is_not_nil(payload.checkpoint[key], "missing checkpoint." .. key)
            end
            assert.is_not_nil(payload.checkpoint.model, "model must be present as JSON null")
            assert.are.equal(vim.NIL, payload.checkpoint.model)
            assert.are.equal(vim.NIL, payload.checkpoint.thinking_level)
            assert.is_not_nil(payload.state.max_tokens)
            assert.is_not_nil(payload.prune.high_water)
            assert.is_not_nil(payload.prune.min_turns)
            assert.is_not_nil(payload.owner.detect)
        end)

        it("publishes defaults for a nil or empty config", function()
            Extension.publish(nil)
            assert.are.same(Extension.defaults(), Extension.published())
            Extension.publish({})
            assert.are.same(Extension.defaults(), Extension.published())
        end)

        it("round-trips a full custom config", function()
            Extension.publish({
                enabled = true,
                cleaner = { enabled = false, max_read = 10, max_modified = 20, drop_temp = false },
                checkpoint = {
                    enabled = true,
                    model = "anthropic/claude-sonnet-4",
                    thinking_level = "high",
                    language = "english",
                    max_words = 800,
                },
                state = { enabled = false, max_tokens = 500 },
                prune = { enabled = true, high_water = 0.8, min_turns = 4 },
                owner = { detect = false },
            })
            local published = assert(Extension.published())
            assert.is_false(published.cleaner.enabled)
            assert.are.equal(10, published.cleaner.max_read)
            assert.are.equal(20, published.cleaner.max_modified)
            assert.is_false(published.cleaner.drop_temp)
            assert.is_true(published.cleaner.drop_build, "unset boolean keeps its default")
            assert.is_true(published.checkpoint.enabled)
            assert.are.equal("anthropic/claude-sonnet-4", published.checkpoint.model)
            assert.are.equal("high", published.checkpoint.thinking_level)
            assert.are.equal("english", published.checkpoint.language)
            assert.are.equal(800, published.checkpoint.max_words)
            assert.is_false(published.state.enabled)
            assert.are.equal(500, published.state.max_tokens)
            assert.is_true(published.prune.enabled)
            assert.are.equal(0.8, published.prune.high_water)
            assert.are.equal(4, published.prune.min_turns)
            assert.is_false(published.owner.detect)
        end)

        it("still writes the file for a disabled config", function()
            Extension.publish({ enabled = false, cleaner = { enabled = false } })
            local published = assert(Extension.published())
            assert.is_false(published.enabled)
            assert.is_false(published.cleaner.enabled)
        end)

        it("overwrites a previous publication", function()
            Extension.publish({ cleaner = { max_read = 5 } })
            Extension.publish({ cleaner = { max_read = 15 } })
            assert.are.equal(15, assert(Extension.published()).cleaner.max_read)
        end)

        it("creates a missing parent directory", function()
            Extension._set_path(dir .. "/nested/deeper/config")
            Extension.publish(nil)
            assert.is_not_nil(assert(Extension.published()))
        end)
    end)

    describe("clamping", function()
        it("clamps max_read and max_modified to positive integers", function()
            Extension.publish({ cleaner = { max_read = 0, max_modified = -3 } })
            local published = assert(Extension.published())
            assert.are.equal(50, published.cleaner.max_read)
            assert.are.equal(100, published.cleaner.max_modified)

            Extension.publish({ cleaner = { max_read = "many", max_modified = 12.9 } })
            published = assert(Extension.published())
            assert.are.equal(50, published.cleaner.max_read)
            assert.are.equal(12, published.cleaner.max_modified)
        end)

        it("clamps max_words into 200..6000", function()
            Extension.publish({ checkpoint = { max_words = 5 } })
            assert.are.equal(200, assert(Extension.published()).checkpoint.max_words)
            Extension.publish({ checkpoint = { max_words = 999999 } })
            assert.are.equal(6000, assert(Extension.published()).checkpoint.max_words)
            Extension.publish({ checkpoint = { max_words = "long" } })
            assert.are.equal(1500, assert(Extension.published()).checkpoint.max_words)
        end)

        it("clamps max_tokens into 100..4000", function()
            Extension.publish({ state = { max_tokens = 1 } })
            assert.are.equal(100, assert(Extension.published()).state.max_tokens)
            Extension.publish({ state = { max_tokens = 100000 } })
            assert.are.equal(4000, assert(Extension.published()).state.max_tokens)
            Extension.publish({ state = { max_tokens = nil } })
            assert.are.equal(1000, assert(Extension.published()).state.max_tokens)
        end)

        it("clamps high_water into 0.3..0.95", function()
            Extension.publish({ prune = { high_water = 0.1 } })
            assert.are.equal(0.3, assert(Extension.published()).prune.high_water)
            Extension.publish({ prune = { high_water = 1.5 } })
            assert.are.equal(0.95, assert(Extension.published()).prune.high_water)
            Extension.publish({ prune = { high_water = 0.55 } })
            assert.are.equal(0.55, assert(Extension.published()).prune.high_water)
        end)

        it("clamps min_turns into 1..100", function()
            Extension.publish({ prune = { min_turns = 0 } })
            assert.are.equal(1, assert(Extension.published()).prune.min_turns)
            Extension.publish({ prune = { min_turns = 500 } })
            assert.are.equal(100, assert(Extension.published()).prune.min_turns)
            Extension.publish({ prune = { min_turns = 3.7 } })
            assert.are.equal(4, assert(Extension.published()).prune.min_turns)
        end)

        it("normalizes language to a supported value", function()
            Extension.publish({ checkpoint = { language = "conversation" } })
            assert.are.equal("conversation", assert(Extension.published()).checkpoint.language)
            Extension.publish({ checkpoint = { language = "klingon" } })
            assert.are.equal("auto", assert(Extension.published()).checkpoint.language)
            Extension.publish({ checkpoint = { language = 42 } })
            assert.are.equal("auto", assert(Extension.published()).checkpoint.language)
        end)

        it("normalizes model and thinking_level to a string or nil", function()
            Extension.publish({ checkpoint = { model = "", thinking_level = 5 } })
            local published = assert(Extension.published())
            assert.is_nil(published.checkpoint.model)
            assert.is_nil(published.checkpoint.thinking_level)

            Extension.publish({ checkpoint = { model = "openai/gpt-5", thinking_level = "low" } })
            published = assert(Extension.published())
            assert.are.equal("openai/gpt-5", published.checkpoint.model)
            assert.are.equal("low", published.checkpoint.thinking_level)
        end)
    end)

    describe("published", function()
        it("returns nil without a runtime file", function()
            assert.is_nil(Extension.published())
        end)

        it("returns nil for undecodable content", function()
            local fd = assert(uv.fs_open(Extension.state_path(), "w", 420))
            uv.fs_write(fd, "{nope", 0)
            uv.fs_close(fd)
            assert.is_nil(Extension.published())
        end)

        it("re-normalizes a hand-written file", function()
            local fd = assert(uv.fs_open(Extension.state_path(), "w", 420))
            uv.fs_write(fd, '{"cleaner":{"max_read":-1},"checkpoint":{"language":"english"}}', 0)
            uv.fs_close(fd)
            local published = assert(Extension.published())
            assert.are.equal(50, published.cleaner.max_read)
            assert.are.equal("english", published.checkpoint.language)
            assert.is_true(published.enabled)
        end)
    end)
end)
