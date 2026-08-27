-- Backend model-scope bridge (nvim side): parsing the runtime file written
-- by extensions/scoped-models.ts, and intersecting the scope with the
-- backend's available-model snapshot.

local ScopedModels = require("pi.scoped_models")

describe("scoped_models.read", function()
    after_each(function()
        ScopedModels._set_path(nil)
    end)

    it("returns nil when the file is absent", function()
        assert.is_nil(ScopedModels.read("/nonexistent/pi2nvim-scope"))
    end)

    it("parses provider/id pairs written by the extension", function()
        local path = os.tmpname()
        local f = io.open(path, "w")
        f:write('{"models":[{"provider":"anthropic","id":"claude-sonnet-4"},{"provider":"openai","id":"gpt-5"}]}')
        f:close()
        local models = assert(ScopedModels.read(path))
        assert.are.same({
            { provider = "anthropic", id = "claude-sonnet-4" },
            { provider = "openai", id = "gpt-5" },
        }, models)
        os.remove(path)
    end)

    it("returns an empty list when no scoping is configured", function()
        local path = os.tmpname()
        local f = io.open(path, "w")
        f:write('{"models":[]}')
        f:close()
        local models = assert(ScopedModels.read(path))
        assert.are.same({}, models)
        os.remove(path)
    end)

    it("returns nil for corrupt JSON and tolerates malformed entries", function()
        local corrupt = os.tmpname()
        local f = io.open(corrupt, "w")
        f:write('{"models":[{"provider":"anthropic"')
        f:close()
        assert.is_nil(ScopedModels.read(corrupt))
        os.remove(corrupt)

        local partial = os.tmpname()
        f = io.open(partial, "w")
        f:write(
            '{"models":[{"provider":"a","id":"x"},{"id":"no-provider"},{"provider":"no-id"},{"unrelated":true},{"provider":42,"id":43}]}'
        )
        f:close()
        assert.are.same({ { provider = "a", id = "x" } }, ScopedModels.read(partial))
        os.remove(partial)
    end)
end)

describe("scoped_models.filter", function()
    local all_models = {
        { provider = "opencode-go", id = "deepseek-v4-flash" },
        { provider = "deepseek", id = "deepseek-v4-flash" },
        { provider = "kimi-coding", id = "k3" },
    }

    it("treats nil/empty scope as no scope", function()
        assert.are.same({}, ScopedModels.filter(nil, all_models))
        assert.are.same({}, ScopedModels.filter({}, all_models))
    end)

    it("intersects with available models preserving scope order", function()
        -- all_models order would put opencode-go first; scope order wins.
        local filtered = ScopedModels.filter(
            { { provider = "kimi-coding", id = "k3" }, { provider = "deepseek", id = "deepseek-v4-flash" } },
            all_models
        )
        assert.are.same(2, #filtered)
        assert.are.same("k3", filtered[1].id)
        assert.are.same("kimi-coding", filtered[1].provider)
        assert.are.same("deepseek", filtered[2].provider)
    end)

    it("drops unavailable entries and duplicates", function()
        local filtered = ScopedModels.filter({
            { provider = "gone", id = "nope" },
            { provider = "kimi-coding", id = "k3" },
            { provider = "kimi-coding", id = "k3" },
        }, all_models)
        assert.are.same(1, #filtered)
        assert.are.same("kimi-coding", filtered[1].provider)
    end)

    it("pins scope entries to their exact provider/modelId pair", function()
        -- canonical match on provider+id only: deepseek/deepseek-v4-flash,
        -- not every provider's copy.
        local filtered = ScopedModels.filter({ { provider = "deepseek", id = "deepseek-v4-flash" } }, all_models)
        assert.are.same(1, #filtered)
        assert.are.same("deepseek", filtered[1].provider)
    end)
end)
