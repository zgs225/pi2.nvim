local Read = require("pi.subsessions.read")
local Manifest = require("pi.subsessions.manifest")
local Subsessions = require("pi.subsessions")

describe("subsession JSONL projection", function()
    local function write_jsonl(path, rows)
        local f = assert(io.open(path, "w"))
        for _, row in ipairs(rows) do
            f:write(vim.json.encode(row) .. "\n")
        end
        f:close()
    end

    it("infer_run_status uses structured roles, not projected text", function()
        local path = vim.fn.tempname() .. ".jsonl"
        write_jsonl(path, {
            { type = "message", message = { role = "user", content = "go" } },
            { type = "message", message = { role = "assistant", content = "done" } },
        })
        assert.equals("completed", Read.infer_run_status(path))

        write_jsonl(path, {
            { type = "message", message = { role = "user", content = "go" } },
            { type = "tool_use", name = "bash" },
        })
        assert.equals("interrupted", Read.infer_run_status(path))

        write_jsonl(path, {
            { type = "message", message = { role = "user", content = "hello toolbox" } },
        })
        assert.is_nil(Read.infer_run_status(path))
        os.remove(path)
    end)

    it("rebuild_statuses does not treat __lineage__ as a child row", function()
        local tmp = vim.fn.tempname() .. "-rebuild.json"
        local real_path = Manifest.path
        Manifest._reset()
        Manifest.path = function()
            return tmp
        end
        Manifest.register_session_lineage("session-a", "lineage-a")
        Manifest.upsert("child-1", {
            parent_id = "lineage-a",
            name = "w",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
        })

        Subsessions.rebuild_statuses()

        local manifest = Manifest.load()
        assert.is_table(manifest.__lineage__)
        assert.is_nil(manifest.__lineage__.status)
        assert.equals("lineage-a", manifest.__lineage__["session-a"])
        assert.equals("dormant", manifest["child-1"].status)

        Manifest.path = real_path
        Manifest._reset()
        os.remove(tmp)
    end)
end)
