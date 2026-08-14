-- Unit tests for pi.draft (unsent-prompt persistence). Hermetic: uses a temp
-- file via the test path hook, never the real stdpath.

describe("pi.draft", function()
    local Draft = require("pi.draft")
    local path

    before_each(function()
        Draft._reset()
        path = vim.fn.tempname() .. "/draft.txt"
        Draft._set_path(path)
    end)

    after_each(function()
        Draft._set_path(nil)
        Draft._reset()
    end)

    describe("persistence", function()
        it("returns nil when there is no draft", function()
            assert.is_nil(Draft.load())
        end)

        it("round-trips save/load (multi-line)", function()
            Draft.save("line1\nline2")
            assert.are.equal("line1\nline2", Draft.load())
        end)

        it("save('') clears the stored draft", function()
            Draft.save("something")
            Draft.save("")
            assert.is_nil(Draft.load())
        end)

        it("clear removes the draft", function()
            Draft.save("x")
            Draft.clear()
            assert.is_nil(Draft.load())
        end)
    end)

    describe("restore_once", function()
        it("returns the draft on the first call only", function()
            Draft.save("my draft")
            assert.are.equal("my draft", Draft.restore_once())
            assert.is_nil(Draft.restore_once())
        end)

        it("leaves the file in place so an unsent draft survives", function()
            Draft.save("keep me")
            Draft.restore_once()
            assert.are.equal("keep me", Draft.load())
        end)

        it("returns nil when there is nothing to restore", function()
            assert.is_nil(Draft.restore_once())
        end)

        it("_reset allows restoring again (simulates a new process)", function()
            Draft.save("again")
            Draft.restore_once()
            Draft._reset()
            Draft._set_path(path) -- _reset clears the override; re-point at the same file
            assert.are.equal("again", Draft.restore_once())
        end)
    end)
end)

describe("pi.draft workspace scoping", function()
    local Draft = require("pi.draft")
    local PH = require("pi.prompt_history")
    local base

    before_each(function()
        Draft._reset()
        base = vim.fn.tempname()
        vim.fn.mkdir(base, "p")
        PH._set_base_dir(base)
    end)

    after_each(function()
        Draft._reset()
        PH._reset()
    end)

    it("drafts are isolated per workspace", function()
        local a = base .. "/proj-a"
        local b = base .. "/proj-b"
        vim.fn.mkdir(a, "p")
        vim.fn.mkdir(b, "p")

        Draft.set_workspace(a)
        Draft.save("draft in A")
        Draft.set_workspace(b)
        assert.is_nil(Draft.load())
        Draft.set_workspace(a)
        assert.are.equal("draft in A", Draft.load())
    end)

    it("stores the draft next to the workspace history file", function()
        local a = base .. "/proj-a"
        vim.fn.mkdir(a, "p")
        Draft.set_workspace(a)
        Draft.save("x")
        local norm = PH.normalize_cwd(a)
        local path = base .. "/history/" .. PH.workspace_key(norm) .. ".draft"
        local f = io.open(path, "r")
        assert.is_not_nil(f)
        assert.are.equal("x", f:read("*a"))
        f:close()
    end)

    it("silently removes the legacy global draft file", function()
        local legacy = base .. "/draft.txt"
        local f = io.open(legacy, "w")
        f:write("old global draft")
        f:close()

        local a = base .. "/proj-a"
        vim.fn.mkdir(a, "p")
        Draft.set_workspace(a)

        assert.is_nil(vim.uv.fs_stat(legacy))
        assert.is_nil(Draft.load()) -- legacy content is NOT migrated
    end)
end)
