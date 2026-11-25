-- Negative controls for `spec-host-layout` (G34). Every shape below mentions a
-- host location and must stay quiet: comments and string bodies never reach a
-- matcher, a literal the spec also hands to the product is a transformation
-- assertion, and a `find` on arbitrary text is not a layout claim.
local MENTIONED = "[/\\]run[/\\]"
local LONG = [==[
    assert.matches("[/\\]run[/\\]", path)
]==]

describe("derived expectations", function()
    it("derives the run dir instead of spelling it", function()
        local path = require("pi.title").state_path()
        assert.are.equal(vim.fn.stdpath("run") .. "/pi2nvim-title-config-" .. vim.fn.getpid(), path)
    end)

    it("spells a path it also feeds the product", function()
        -- `/etc/hosts` is the INPUT here, so the assertion is about a
        -- transformation rather than about where this machine keeps files.
        local got = require("pi.tool_path").resolve("/etc/hosts", vim.fn.tempname())
        assert.are.equal("/etc/hosts", got)
    end)

    it("round-trips an override it spelled itself", function()
        -- The literal is a `_set_path` argument one line above, so it is input,
        -- not an expectation about the host (the `once` clause of signal 2).
        require("pi.vision")._set_path("/tmp/pi2nvim-vision-test")
        assert.are.equal("/tmp/pi2nvim-vision-test", require("pi.vision").state_path())
    end)

    it("searches a string that happens to be source text", function()
        local src = "the fingerprint comes from /proc/<pid>/stat"
        assert.is_truthy(src:find("/proc/", 1, true))
    end)

    it("compares fixture data that is only data", function()
        local session = { file = "/tmp/session.jsonl" }
        assert.are.equal("/tmp/session.jsonl", session.file)
        assert.is_true(MENTIONED ~= LONG)
    end)
end)
