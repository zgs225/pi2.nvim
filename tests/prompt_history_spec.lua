-- Unit tests for pi.prompt_history (pure Lua, no UI).

local PH = require("pi.prompt_history")

--- Create an in-memory store.
local function mem(max)
    return PH.Store.new({ path = false, max = max })
end

--- Create a file-backed store under a fresh temp path.
local function file_store(max)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/history.json"
    return PH.Store.new({ path = path, max = max }), path
end

describe("prompt_history: add", function()
    it("stores entries newest-last", function()
        local s = mem()
        s:add("one")
        s:add("two")
        assert.are.same({ "one", "two" }, s:entries())
        assert.are.equal(2, s:size())
    end)

    it("ignores empty and whitespace-only entries", function()
        local s = mem()
        s:add("")
        s:add("   ")
        s:add("\n\t ")
        assert.are.equal(0, s:size())
    end)

    it("ignores non-string input", function()
        local s = mem()
        s:add(nil)
        s:add(42)
        assert.are.equal(0, s:size())
    end)

    it("dedupes consecutive duplicates", function()
        local s = mem()
        s:add("same")
        s:add("same")
        s:add("same")
        assert.are.same({ "same" }, s:entries())
        s:add("other")
        s:add("same") -- non-consecutive dup is kept
        assert.are.same({ "same", "other", "same" }, s:entries())
    end)

    it("preserves multi-line entries", function()
        local s = mem()
        s:add("line1\nline2\nline3")
        assert.are.same({ "line1\nline2\nline3" }, s:entries())
    end)

    it("enforces the cap by dropping the oldest", function()
        local s = mem(3)
        for i = 1, 5 do
            s:add("e" .. i)
        end
        assert.are.same({ "e3", "e4", "e5" }, s:entries())
    end)
end)

describe("prompt_history: navigation", function()
    it("prev returns nil on an empty store", function()
        local nav = PH.Nav.new(mem())
        assert.is_nil(nav:prev("draft"))
        assert.is_false(nav:navigating())
    end)

    it("prev walks toward older entries and stashes the draft", function()
        local s = mem()
        s:add("one")
        s:add("two")
        s:add("three")
        local nav = PH.Nav.new(s)
        assert.are.equal("three", nav:prev("draft"))
        assert.is_true(nav:navigating())
        assert.are.equal("two", nav:prev())
        assert.are.equal("one", nav:prev())
        -- at oldest: no further change
        assert.is_nil(nav:prev())
        assert.are.equal("one", nav:prev() or "one")
    end)

    it("next walks back and restores the stashed draft at the present", function()
        local s = mem()
        s:add("one")
        s:add("two")
        local nav = PH.Nav.new(s)
        assert.are.equal("two", nav:prev("my draft"))
        assert.are.equal("one", nav:prev())
        assert.are.equal("two", nav:next())
        -- back to present: draft restored, navigation ends
        assert.are.equal("my draft", nav:next())
        assert.is_false(nav:navigating())
    end)

    it("next is a no-op when not navigating", function()
        local s = mem()
        s:add("one")
        local nav = PH.Nav.new(s)
        assert.is_nil(nav:next())
    end)

    it("reset leaves navigation; a fresh prev starts from newest again", function()
        local s = mem()
        s:add("one")
        local nav = PH.Nav.new(s)
        nav:prev("draft")
        nav:reset()
        assert.is_false(nav:navigating())
        assert.are.equal("one", nav:prev("x"))
    end)

    it("cursors over the same store are independent (per-chat nav state)", function()
        local s = mem()
        s:add("one")
        s:add("two")
        local a = PH.Nav.new(s)
        local b = PH.Nav.new(s)
        assert.are.equal("two", a:prev("draft-a"))
        assert.are.equal("one", a:prev())
        -- b is untouched by a's position
        assert.is_false(b:navigating())
        assert.are.equal("two", b:prev("draft-b"))
        assert.are.equal("one", a:prev() or "one")
        assert.are.equal("draft-b", b:next())
    end)
end)

describe("prompt_history: persistence", function()
    it("round-trips entries through disk", function()
        local s, path = file_store()
        s:add("alpha")
        s:add("multi\nline")
        -- a brand-new store at the same path loads what was saved
        local s2 = PH.Store.new({ path = path })
        assert.are.same({ "alpha", "multi\nline" }, s2:entries())
    end)

    it("enforces the cap on load", function()
        local s, path = file_store()
        for i = 1, 10 do
            s:add("e" .. i)
        end
        local s2 = PH.Store.new({ path = path, max = 3 })
        assert.are.same({ "e8", "e9", "e10" }, s2:entries())
    end)

    it("ignores a corrupt file", function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        local path = dir .. "/history.json"
        local f = io.open(path, "w")
        f:write("{ this is not valid json ]")
        f:close()
        local s = PH.Store.new({ path = path })
        assert.are.equal(0, s:size())
    end)

    it("ignores a missing file", function()
        local s = PH.Store.new({ path = vim.fn.tempname() .. "/nope.json" })
        assert.are.equal(0, s:size())
    end)

    it("clear empties and persists", function()
        local s, path = file_store()
        s:add("x")
        s:clear()
        assert.are.equal(0, s:size())
        local s2 = PH.Store.new({ path = path })
        assert.are.equal(0, s2:size())
    end)
end)

describe("prompt_history: workspace registry", function()
    local base

    before_each(function()
        base = vim.fn.tempname()
        vim.fn.mkdir(base, "p")
        PH._set_base_dir(base)
        PH._reset()
        PH._set_base_dir(base) -- _reset also clears the override
    end)

    after_each(function()
        PH._reset()
    end)

    it("returns the same store for the same cwd", function()
        local dir = base .. "/proj-a"
        vim.fn.mkdir(dir, "p")
        local s1 = PH.get_for_workspace(dir)
        local s2 = PH.get_for_workspace(dir)
        assert.is_true(rawequal(s1, s2))
    end)

    it("returns different stores for different cwds", function()
        local a = base .. "/proj-a"
        local b = base .. "/proj-b"
        vim.fn.mkdir(a, "p")
        vim.fn.mkdir(b, "p")
        local sa = PH.get_for_workspace(a)
        local sb = PH.get_for_workspace(b)
        assert.is_false(rawequal(sa, sb))
        sa:add("from-a")
        assert.are.equal(0, sb:size())
    end)

    it("normalizes cwd: trailing slash and symlinks resolve to one store", function()
        local real = base .. "/proj-a"
        vim.fn.mkdir(real, "p")
        local link = base .. "/link-a"
        vim.uv.fs_symlink(real, link)

        local s1 = PH.get_for_workspace(real)
        local s2 = PH.get_for_workspace(real .. "/")
        local s3 = PH.get_for_workspace(link)
        assert.is_true(rawequal(s1, s2))
        assert.is_true(rawequal(s1, s3))
    end)

    it("falls back to the process cwd for unusable input", function()
        local s1 = PH.get_for_workspace(nil)
        local s2 = PH.get_for_workspace("")
        local s3 = PH.get_for_workspace(vim.fn.getcwd())
        assert.is_true(rawequal(s1, s2))
        assert.is_true(rawequal(s1, s3))
    end)

    it("persists each workspace to its own hash-named file", function()
        local dir = base .. "/proj-a"
        vim.fn.mkdir(dir, "p")
        local s = PH.get_for_workspace(dir)
        s:add("hello")

        local norm = PH.normalize_cwd(dir)
        local key = PH.workspace_key(norm)
        local path = base .. "/history/" .. key .. ".json"
        local reloaded = PH.Store.new({ path = path })
        assert.are.same({ "hello" }, reloaded:entries())
    end)

    it("writes index.json mapping hash to normalized cwd", function()
        local dir = base .. "/proj-a"
        vim.fn.mkdir(dir, "p")
        PH.get_for_workspace(dir)

        local f = io.open(base .. "/history/index.json", "r")
        assert.is_not_nil(f)
        local ok, decoded = pcall(vim.json.decode, f:read("*a"))
        f:close()
        assert.is_true(ok)
        local norm = PH.normalize_cwd(dir)
        assert.are.equal(norm, decoded[PH.workspace_key(norm)])
    end)

    it("honors the max option", function()
        local dir = base .. "/proj-a"
        vim.fn.mkdir(dir, "p")
        local s = PH.get_for_workspace(dir, { max = 2 })
        s:add("e1")
        s:add("e2")
        s:add("e3")
        assert.are.same({ "e2", "e3" }, s:entries())
    end)

    it("silently removes the legacy global history file", function()
        vim.fn.mkdir(base, "p")
        local legacy = base .. "/prompt_history.json"
        local f = io.open(legacy, "w")
        f:write('["old"]')
        f:close()

        local dir = base .. "/proj-a"
        vim.fn.mkdir(dir, "p")
        PH.get_for_workspace(dir)

        assert.is_nil(vim.uv.fs_stat(legacy))
        -- legacy entries are NOT migrated anywhere (pure isolation)
        local s = PH.get_for_workspace(dir)
        assert.are.equal(0, s:size())
    end)
end)
