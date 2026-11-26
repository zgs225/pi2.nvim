-- Config surface of the bundled `ask` tool: the `options.ask` defaults, the
-- deep-merge of a user override, the runtime file the extension re-reads
-- (lua/pi/ask/init.lua) and the `--extension extensions/ask.ts` injection in
-- `Cli.command`.
--
-- The runtime file is the only channel the configure values reach an
-- already-spawned RPC process (the process env is frozen at spawn), so the
-- publication half is asserted against the real file on disk, read back with
-- `io.open` + `vim.json.decode` where the JSON encoding itself matters (a
-- `timeout_ms` key that must be present and `null`, not dropped).
--
-- The `Cli.command` half is hermetic: `M.bin()` is the configured string and
-- `M.args()` only probes `pi --version` for the gated `--no-mcp` flag, which
-- the default `cli.args` does not carry, so no child process is spawned.

local Config = require("pi.config")
local Ask = require("pi.ask")
local Cli = require("pi.cli")

--- Is `path` present as a `--extension` argument in `cmd`? Mirrors
--- tests/search_tools_cli_spec.lua.
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

describe("ask config defaults", function()
    before_each(function()
        Config.setup({})
    end)

    after_each(function()
        Config.setup({})
    end)

    it("exposes the documented defaults", function()
        local ask = Config.options.ask
        assert.is_not.is_nil(ask)
        assert.is_true(ask.enabled)
        assert.are.equal(4, ask.max_questions)
        assert.are.equal(4, ask.max_options)
        assert.is_true(ask.allow_free_text)
        assert.is_nil(ask.timeout_ms)
        assert.are.equal("float", ask.ui)
    end)

    it("exposes the default keymaps", function()
        local keys = Config.options.ask.keys
        assert.are.equal("j", keys.down)
        assert.are.equal("k", keys.up)
        assert.are.equal("l", keys.next_question)
        assert.are.equal("h", keys.prev_question)
        assert.are.equal("gg", keys.first)
        assert.are.equal("G", keys.last)
        assert.are.equal("<CR>", keys.select)
        assert.are.equal("<Space>", keys.toggle)
        assert.are.equal("x", keys.clear)
        assert.are.equal("i", keys.free_text)
        assert.are.equal("ZZ", keys.submit)
    end)

    it("makes cancel a list that contains <Esc>", function()
        local cancel = Config.options.ask.keys.cancel
        assert.are.equal("table", type(cancel))
        local found = false
        for _, key in ipairs(cancel) do
            if key == "<Esc>" then
                found = true
            end
        end
        assert.is_true(found, "expected <Esc> among the cancel keys")
    end)

    it("restores the defaults after a user setup()", function()
        Config.setup({ ask = { enabled = false, max_questions = 1 } })
        assert.is_false(Config.options.ask.enabled)
        assert.are.equal(1, Config.options.ask.max_questions)

        Config.setup({})
        assert.is_true(Config.options.ask.enabled)
        assert.are.equal(4, Config.options.ask.max_questions)
    end)
end)

describe("ask config deep merge", function()
    after_each(function()
        Config.setup({})
    end)

    it("applies the override and keeps the untouched nested keys", function()
        Config.setup({ ask = { enabled = false, keys = { down = "n" } } })

        assert.is_false(Config.options.ask.enabled)
        -- Overridden leaf.
        assert.are.equal("n", Config.options.ask.keys.down)
        -- Sibling leaves inside the same nested table survive the merge.
        assert.are.equal("k", Config.options.ask.keys.up)
        assert.are.equal("ZZ", Config.options.ask.keys.submit)
        assert.are.equal("<Esc>", Config.options.ask.keys.cancel[1])
        -- Sibling keys of the outer table survive too.
        assert.are.equal(4, Config.options.ask.max_questions)
        assert.are.equal("float", Config.options.ask.ui)
    end)

    it("does not alias the module defaults", function()
        Config.setup({ ask = { keys = { down = "n" } } })
        Config.options.ask.keys.up = "K"

        Config.setup({})
        assert.are.equal("k", Config.options.ask.keys.up)
        assert.are.equal("j", Config.options.ask.keys.down)
    end)
end)

describe("ask runtime config file", function()
    local dir ---@type string

    before_each(function()
        Config.setup({})
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        Ask._set_path(dir .. "/ask-config")
    end)

    after_each(function()
        Ask._set_path(nil)
        vim.fn.delete(dir, "rf")
        Config.setup({})
    end)

    --- Decode the runtime file exactly as the extension would, keeping JSON
    --- nulls as `vim.NIL` so a missing key and a null value stay distinct.
    ---@return table?
    local function read_file()
        local f = io.open(Ask.state_path(), "r")
        if not f then
            return nil
        end
        local content = f:read("*a") or ""
        f:close()
        local parsed = vim.json.decode(content)
        assert.are.equal("table", type(parsed))
        return parsed
    end

    it("_set_path/state_path round-trip", function()
        assert.are.equal(dir .. "/ask-config", Ask.state_path())
    end)

    it("returns nil before anything was published", function()
        assert.is_nil(Ask.published())
        assert.is_nil(read_file())
    end)

    it("publishes every field", function()
        Ask.publish({
            enabled = true,
            max_questions = 3,
            max_options = 2,
            allow_free_text = false,
            timeout_ms = 1500,
        })

        local published = Ask.published()
        assert.is_not.is_nil(published)
        assert.is_true(published.enabled)
        assert.are.equal(3, published.max_questions)
        assert.are.equal(2, published.max_options)
        assert.is_false(published.allow_free_text)
        assert.are.equal(1500, published.timeout_ms)
    end)

    it("writes timeout_ms as a PRESENT null when it is nil", function()
        Ask.publish({ timeout_ms = nil })

        local parsed = read_file()
        assert.is_not.is_nil(parsed)
        assert.is_not.is_nil(rawget(parsed, "timeout_ms"), "expected a timeout_ms key in the JSON payload")
        assert.are.equal(vim.NIL, parsed.timeout_ms)
        -- ... and it reads back as nil (no timeout), not as vim.NIL.
        assert.is_nil(Ask.published().timeout_ms)
    end)

    it("normalizes a non-positive or fractional timeout to nil", function()
        Ask.publish({ timeout_ms = 0 })
        assert.is_nil(Ask.published().timeout_ms)

        Ask.publish({ timeout_ms = 12.5 })
        assert.is_nil(Ask.published().timeout_ms)

        Ask.publish({ timeout_ms = -3 })
        assert.is_nil(Ask.published().timeout_ms)
    end)

    it("persists enabled = false", function()
        Ask.publish({ enabled = false })
        assert.is_false(Ask.published().enabled)
    end)

    it("publishes the defaults when called with no config", function()
        Ask.publish(nil)
        local published = Ask.published()
        assert.is_true(published.enabled)
        assert.are.equal(4, published.max_questions)
        assert.are.equal(4, published.max_options)
        assert.is_true(published.allow_free_text)
        assert.is_nil(published.timeout_ms)
    end)

    it("is republished by Config.setup()", function()
        Config.setup({ ask = { max_questions = 2 } })

        local published = Ask.published()
        assert.is_not.is_nil(published, "Config.setup() must publish the ask config")
        assert.are.equal(2, published.max_questions)
    end)

    it("Config.setup() publishes enabled = false too", function()
        Config.setup({ ask = { enabled = false, timeout_ms = 900 } })

        local published = Ask.published()
        assert.is_false(published.enabled)
        assert.are.equal(900, published.timeout_ms)
    end)
end)

describe("ask extension injection", function()
    before_each(function()
        Config.setup({})
    end)

    after_each(function()
        Config.setup({})
    end)

    it("resolves an existing absolute extension path", function()
        local path = Cli.ask_extension_path()
        assert.is_true(vim.startswith(path, "/"))
        assert.is_truthy(path:match("/extensions/ask%.ts$"))
        assert.are.equal(1, vim.fn.filereadable(path))
    end)

    it("injects --extension <ask.ts> into a parent process", function()
        local path = Cli.ask_extension_path()
        assert.is_true(has_extension(Cli.command({}), path))
    end)

    it("never injects it into a sub-session process", function()
        local path = Cli.ask_extension_path()
        local cmd = Cli.command({ subagent = false })
        assert.is_false(has_extension(cmd, path))
        -- The other extensions still ride as `--extension` pairs, so the
        -- assertion above is not trivially true because the argv is empty.
        assert.is_true(has_extension(cmd, Cli.bg_tasks_extension_path()))
    end)

    it("keeps injecting it when ask.enabled = false so the switch stays live", function()
        Config.setup({ ask = { enabled = false } })
        local path = Cli.ask_extension_path()
        -- Injection is deliberately not gated on `enabled`: a process that never
        -- loaded the extension could not honour a later flip back to true. The
        -- switch travels through the runtime file instead, where the extension
        -- registers inactive and reconciles the active tool set per turn.
        assert.is_true(has_extension(Cli.command({}), path))
        assert.is_false(require("pi.ask").published().enabled)
    end)
end)
