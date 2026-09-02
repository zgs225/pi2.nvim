-- Sub-session manifest read/write.

local Manifest = require("pi.subsessions.manifest")

describe("subsession manifest", function()
    local real_load = Manifest.load
    local real_save = Manifest.save
    local tmp

    before_each(function()
        tmp = vim.fn.tempname() .. ".json"
        Manifest.load = function()
            local f = io.open(tmp, "r")
            if not f then
                return {}
            end
            local ok, data = pcall(vim.json.decode, f:read("*a"))
            f:close()
            return ok and data or {}
        end
        Manifest.save = function(m)
            local f = io.open(tmp, "w")
            if not f then
                return false
            end
            f:write(vim.json.encode(m))
            f:close()
            return true
        end
        Manifest.path = function()
            return tmp
        end
    end)

    after_each(function()
        Manifest.load = real_load
        Manifest.save = real_save
        os.remove(tmp)
    end)

    it("upserts and lists children by parent_id", function()
        Manifest.upsert("child-1", {
            parent_id = "parent-a",
            name = "review",
            task_prompt = "review code",
            config = { model = { provider = "x", id = "m" } },
            status = "active",
            reported = false,
            created_at = "2026-09-02T10:00:00Z",
            last_active_at = "2026-09-02T10:00:00Z",
        })
        local kids = Manifest.children_of("parent-a")
        assert.equals(1, #kids)
        assert.equals("child-1", kids[1]._id)
        assert.equals("review", kids[1].name)
    end)

    it("sorts children deterministically when created_at ties", function()
        local base = {
            parent_id = "parent-a",
            name = "x",
            task_prompt = "t",
            config = { model = { provider = "x", id = "m" } },
            status = "active",
            reported = false,
            created_at = "2026-09-02T10:00:00Z",
            last_active_at = "2026-09-02T10:00:00Z",
        }
        Manifest.upsert("child-b", vim.tbl_extend("force", { name = "b" }, base))
        Manifest.upsert("child-a", vim.tbl_extend("force", { name = "a" }, base))
        local kids = Manifest.children_of("parent-a")
        assert.equals(2, #kids)
        assert.equals("child-a", kids[1]._id)
        assert.equals("child-b", kids[2]._id)
    end)

    it("detects child session ids", function()
        Manifest.upsert("child-1", {
            parent_id = "parent-a",
            name = "review",
            task_prompt = "review code",
            config = { model = { provider = "x", id = "m" } },
            status = "active",
            reported = false,
            created_at = "2026-09-02T10:00:00Z",
            last_active_at = "2026-09-02T10:00:00Z",
        })
        assert.is_true(Manifest.is_child_session("child-1"))
        assert.is_false(Manifest.is_child_session("parent-a"))
    end)

    it("maps session ids to a stable lineage across migration", function()
        Manifest.bind_session_lineage({ lineage_id = "lineage-1" }, "session-old")
        Manifest.register_session_lineage("session-new", "lineage-1")
        assert.are.equal("lineage-1", Manifest.resolve_lineage("session-new"))
        assert.are.equal("lineage-1", Manifest.resolve_lineage("session-old"))
    end)
end)
