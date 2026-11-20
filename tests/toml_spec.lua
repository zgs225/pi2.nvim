-- Unit tests for pi.toml — the minimal TOML reader behind `.pi-worktrees.toml`.
--
-- The reader exists so a repository can carry its worktree settings as data
-- (`lua/pi/worktree_config.lua` interprets it). Everything here is a pure text
-- in / table out assertion: no filesystem, no git.

local T = require("pi.toml")

---@param text string
---@return table value
local function dec(text)
    local value, err = T.decode(text)
    assert.is_nil(err)
    assert.are.equal("table", type(value))
    return value
end

---@param text string
---@return string err
local function dec_err(text)
    local value, err = T.decode(text)
    assert.is_nil(value)
    assert.are.equal("string", type(err))
    return err
end

describe("pi.toml", function()
    it("decodes an empty document as an empty table", function()
        assert.are.same({}, dec(""))
        assert.are.same({}, dec("# only a comment\n\n\n"))
    end)

    it("decodes strings, integers, floats and booleans", function()
        local value = dec([[
name = "fix-auth"
literal = 'C:\path\no-escape'
count = 25
ratio = 0.5
on = true
off = false
]])
        assert.are.equal("fix-auth", value.name)
        assert.are.equal("C:\\path\\no-escape", value.literal)
        assert.are.equal(25, value.count)
        assert.are.equal(0.5, value.ratio)
        assert.is_true(value.on)
        assert.is_false(value.off)
    end)

    it("decodes the basic-string escapes", function()
        local value = dec([[s = "a\tb\nc\"d\\e\u00e9"]])
        assert.are.equal('a\tb\nc"d\\e' .. vim.fn.nr2char(0xe9), value.s)
    end)

    it("decodes single-line and multi-line arrays, with trailing commas", function()
        local value = dec([==[
flat = [".env", "*.local"]
multi = [
  "a",
  "b",   # comment inside the array
]
nested = [["npm", "ci"], ["make"]]
empty = []
]==])
        assert.are.same({ ".env", "*.local" }, value.flat)
        assert.are.same({ "a", "b" }, value.multi)
        assert.are.same({ { "npm", "ci" }, { "make" } }, value.nested)
        assert.are.same({}, value.empty)
    end)

    it("decodes table headers as absolute from the document root", function()
        local value = dec([==[
base_ref = "fresh"

[retention]
max_count = 40

[setup]
unix = [["npm", "ci"]]

[retention]
snapshot_days = 2
]==])
        assert.are.equal("fresh", value.base_ref)
        assert.are.same({ max_count = 40, snapshot_days = 2 }, value.retention)
        assert.are.same({ unix = { { "npm", "ci" } } }, value.setup)
    end)

    it("supports dotted keys and dumps into the table they name", function()
        local value = dec([[
retention.max_count = 3
[retention]
max_age_days = 7
]])
        assert.are.same({ max_count = 3, max_age_days = 7 }, value.retention)
    end)

    it("tolerates CRLF line endings", function()
        local value = dec('base_ref = "head"\r\n[retention]\r\nmax_count = 2\r\n')
        assert.are.equal("head", value.base_ref)
        assert.are.equal(2, value.retention.max_count)
    end)

    it("reports the line of a syntax error", function()
        local err = dec_err('ok = true\nbad = "unterminated\n')
        assert.is_truthy(err:find("toml: line 2:", 1, true))
        assert.is_truthy(err:find("unterminated string", 1, true))
    end)

    it("refuses an unquoted bare-word value instead of guessing", function()
        assert.is_truthy(dec_err("setup = npm\n"):find("unsupported value 'npm'", 1, true))
    end)

    it("refuses duplicate keys, inline tables and arrays of tables", function()
        assert.is_truthy(dec_err("a = 1\na = 2\n"):find("duplicate key 'a'", 1, true))
        assert.is_truthy(dec_err("a = { b = 1 }\n"):find("unsupported value '{'", 1, true))
        assert.is_truthy(dec_err("[[items]]\nname = 'x'\n"):find("arrays of tables", 1, true))
    end)

    it("refuses a value that shadows a table", function()
        assert.is_truthy(dec_err("a = 1\n[a]\nb = 2\n"):find("already a value, not a table", 1, true))
    end)

    it("refuses trailing text after a value or header", function()
        assert.is_truthy(dec_err("a = 1 b = 2\n"):find("trailing text after value", 1, true))
        assert.is_truthy(dec_err("[a] x = 1\n"):find("trailing text after table header", 1, true))
    end)
end)
