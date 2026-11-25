-- Ban 1 fixture (G34): the separator-aware, root-blind pattern that shipped in
-- tests/compaction_extension_spec.lua and was red only on macOS.
describe("run-dir file", function()
    it("assumes /run", function()
        assert.matches("[/\\]run[/\\]", require("pi.compaction.extension").state_path())
    end)
end)
