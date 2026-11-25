-- Ban 2 fixture (G34): the expected value spells the Linux run dir while the
-- compared value is computed by the product — inline, and through a local.
describe("run-dir file", function()
    it("pins one machine's answer", function()
        assert.are.equal(
            "/run/user/1000/nvim.0/pi2nvim-compaction-config-" .. vim.fn.getpid(),
            require("pi.compaction.extension").state_path()
        )
    end)

    it("pins it through a local", function()
        local path = require("pi.title").state_path()
        assert.are.equal("/var/folders/xy/T/nvim.user/abc/pi2nvim-title-config", path)
    end)
end)
