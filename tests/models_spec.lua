-- Configured model entry resolution: `models` entries (strings and specs)
-- are resolved against the backend model list for cycling and the picker.

local Config = require("pi.config")

Config.setup({})

--- vim.notify spy records.
local notes = {}

vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
end

---@type table[]
local all_models = {
    { provider = "kimi-coding", id = "k3", name = "Kimi K3" },
    { provider = "opencode-go", id = "kimi-k3", name = "Kimi K3" },
    { provider = "opencode-go", id = "deepseek-v4-flash", name = "DeepSeek V4 Flash" },
    { provider = "deepseek", id = "deepseek-v4-flash", name = "DeepSeek V4 Flash" },
    { provider = "qwen-token-plan-cn", id = "deepseek-v4-flash", name = "DeepSeek V4 Flash" },
    { provider = "kimi-coding", id = "kimi-for-coding", name = "Kimi for Coding" },
}

describe("models.resolve_entries", function()
    before_each(function()
        notes = {}
    end)

    it("matches a string entry by exact ID", function()
        local resolved = require("pi.models").resolve_entries({ "k3" }, all_models)
        assert.are.same(1, #resolved)
        assert.are.same("kimi-coding", resolved[1].provider)
        assert.are.same("k3", resolved[1].id)
    end)

    it("matches a string entry by canonical provider/modelId", function()
        local resolved = require("pi.models").resolve_entries({ "opencode-go/deepseek-v4-flash" }, all_models)
        assert.are.same(1, #resolved)
        assert.are.same("opencode-go", resolved[1].provider)
        assert.are.same("deepseek-v4-flash", resolved[1].id)
    end)

    it("matches every provider copy of a bare ambiguous ID", function()
        local resolved = require("pi.models").resolve_entries({ "deepseek-v4-flash" }, all_models)
        assert.are.same(3, #resolved)
    end)

    it("dedupes across providers only within the same entry form", function()
        -- Canonical entry pins the opencode-go copy; the bare entry still
        -- matches the other providers' copies.
        local resolved =
            require("pi.models").resolve_entries({ "opencode-go/deepseek-v4-flash", "deepseek-v4-flash" }, all_models)
        assert.are.same(3, #resolved)
        assert.are.same("opencode-go", resolved[1].provider)
    end)

    it("matches an exact spec by canonical provider/modelId", function()
        local resolved = require("pi.models").resolve_entries(
            { { match = "opencode-go/deepseek-v4-flash", exact = true } },
            all_models
        )
        assert.are.same(1, #resolved)
        assert.are.same("opencode-go", resolved[1].provider)
    end)

    it("warns when a string entry matches nothing", function()
        local resolved = require("pi.models").resolve_entries({ "no-such-model" }, all_models)
        assert.are.same(0, #resolved)
        assert.are.same(1, #notes)
        assert.matches("Configured model not found", notes[1].msg)
    end)
end)

-- The :PiSelectModel candidate ladder: config.models → backend scope → all.
describe("models.resolve_select_candidates", function()
    local Models = require("pi.models")
    local ScopedModels = require("pi.scoped_models")

    local scope_path = os.tmpname()
    after_each(function()
        notes = {}
    end)

    --- Write a scope file the same way extensions/scoped-models.ts does.
    ---@param models table[]?
    local function set_scope(models)
        if models == nil then
            os.remove(scope_path)
            return
        end
        local f = io.open(scope_path, "w")
        f:write(vim.json.encode({ models = models }))
        f:close()
    end

    local function read_scope()
        return ScopedModels.read(scope_path)
    end

    it("prefers matching config-model entries over the backend scope", function()
        set_scope({ { provider = "kimi-coding", id = "k3" } })
        local candidates = Models.resolve_select_candidates({ "deepseek-v4-flash" }, read_scope(), all_models)
        -- bare ID matches every provider copy of deepseek-v4-flash
        assert.are.same(3, #candidates)
    end)

    it("falls through to the backend scope when entries match nothing", function()
        set_scope({ { provider = "kimi-coding", id = "k3" } })
        local candidates = Models.resolve_select_candidates({ "no-such-model" }, read_scope(), all_models)
        assert.are.same(1, #candidates)
        assert.are.same("k3", candidates[1].id)
        assert.are.same(1, #notes) -- resolve_entries still reported the miss
    end)

    it("uses the backend scope when no config-model entries are set", function()
        set_scope({ { provider = "deepseek", id = "deepseek-v4-flash" } })
        local candidates = Models.resolve_select_candidates(nil, read_scope(), all_models)
        -- scope pins one provider/modelId pair of the three copies
        assert.are.same(1, #candidates)
        assert.are.same("deepseek", candidates[1].provider)
    end)

    it("ignores an empty backend scope", function()
        set_scope({})
        local candidates = Models.resolve_select_candidates(nil, read_scope(), all_models)
        assert.are.same(#all_models, #candidates)
    end)

    it("falls back to all models when both layers are absent or empty", function()
        set_scope(nil) -- no file: extension silent (pi < 0.83.0 / unscoped)
        assert.are.same(#all_models, #Models.resolve_select_candidates(nil, read_scope(), all_models))
        set_scope({})
        assert.are.same(#all_models, #Models.resolve_select_candidates({}, {}, all_models))
    end)
end)

describe("models.ambiguity_suffix", function()
    local Models = require("pi.models")

    it("returns nil for an id served by exactly one provider endpoint", function()
        -- k3 exists only under kimi-coding, all fixtures have no baseUrl
        assert.is_nil(Models.ambiguity_suffix({ provider = "kimi-coding", id = "k3" }, all_models))
    end)

    it("returns [provider] when the id exists under several providers", function()
        assert.are.equal(
            "[deepseek]",
            Models.ambiguity_suffix({ provider = "deepseek", id = "deepseek-v4-flash" }, all_models)
        )
        assert.are.equal(
            "[opencode-go]",
            Models.ambiguity_suffix({ provider = "opencode-go", id = "deepseek-v4-flash" }, all_models)
        )
    end)

    it("returns nil when duplicates share provider and baseUrl (same endpoint)", function()
        local list = {
            { provider = "openai", id = "gpt-x", baseUrl = "https://api.openai.com" },
            { provider = "openai", id = "gpt-x", baseUrl = "https://api.openai.com" },
        }
        local suffix =
            Models.ambiguity_suffix({ provider = "openai", id = "gpt-x", baseUrl = "https://api.openai.com" }, list)
        assert.is_nil(suffix)
    end)

    it("labels endpoint-level ambiguity with provider@host", function()
        local list = {
            { provider = "openai", id = "gpt-x", baseUrl = "https://api.openai.com" },
            { provider = "openai", id = "gpt-x", baseUrl = "https://gateway.internal:8080/v1" },
        }
        local suffix = Models.ambiguity_suffix(
            { provider = "openai", id = "gpt-x", baseUrl = "https://gateway.internal:8080/v1" },
            list
        )
        assert.are.equal("[openai@gateway.internal:8080]", suffix)
    end)

    it("strips scheme, path and default ports from the host label", function()
        local list = {
            { provider = "openai", id = "gpt-x", baseUrl = "https://api.openai.com/v1" },
            { provider = "openai", id = "gpt-x", baseUrl = "http://localhost:11434" },
        }
        local suffix =
            Models.ambiguity_suffix({ provider = "openai", id = "gpt-x", baseUrl = "https://api.openai.com/v1" }, list)
        assert.are.equal("[openai@api.openai.com]", suffix)
    end)

    it("falls back to the bare provider when the current baseUrl is missing", function()
        local list = {
            { provider = "openai", id = "gpt-x", baseUrl = "https://api.openai.com" },
            { provider = "openai", id = "gpt-x", baseUrl = "https://gateway.internal" },
        }
        assert.are.equal("[openai]", Models.ambiguity_suffix({ provider = "openai", id = "gpt-x" }, list))
    end)

    it("returns nil when the current model is absent from the list", function()
        assert.is_nil(Models.ambiguity_suffix({ provider = "nope", id = "ghost" }, all_models))
    end)

    it("returns nil on unusable input", function()
        assert.is_nil(Models.ambiguity_suffix(nil, all_models))
        assert.is_nil(Models.ambiguity_suffix({}, all_models))
        assert.is_nil(Models.ambiguity_suffix({ provider = "kimi-coding", id = "k3" }, nil))
    end)
end)
