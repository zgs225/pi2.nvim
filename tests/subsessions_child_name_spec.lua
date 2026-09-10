-- Child sub-session names: a child's own auto-generated session title
-- (extensions/title.ts → pi.setSessionName → session_info_changed) replaces the
-- task-derived manifest name, while an explicitly supplied name is protected.
--
-- Covers three layers:
-- 1. Manifest name provenance (`fallback_name` / `is_derived_name`).
-- 2. pi.subsessions.on_child_session_name — the adoption decision.
-- 3. pi.sessions.manager.handle_event — the session_info_changed wiring.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")
local SessionList = require("pi.ui.sessions")

Config.setup({})

---@param overrides? table
---@return pi.SubsessionManifestEntry
local function entry(overrides)
    return vim.tbl_extend("force", {
        parent_id = "lineage-a",
        name = "review the auth flow and report findings",
        task_prompt = "review the auth flow and report findings",
        config = {},
        status = "active",
        reported = false,
        created_at = "2026-09-02T10:00:00Z",
        last_active_at = "2026-09-02T10:00:00Z",
    }, overrides or {})
end

describe("subsession manifest name provenance", function()
    it("derives the fallback name from the first 40 task characters", function()
        local task = string.rep("x", 60)
        assert.are.equal(string.rep("x", 40), Manifest.fallback_name(task))
        assert.are.equal("short task", Manifest.fallback_name("short task"))
    end)

    it("has no fallback name for an empty or missing task", function()
        assert.is_nil(Manifest.fallback_name(""))
        assert.is_nil(Manifest.fallback_name(nil))
    end)

    it("treats an explicit name as not derived", function()
        assert.is_false(Manifest.is_derived_name(entry({ name = "auth-review", name_source = "explicit" })))
    end)

    it("treats an adopted auto title as not derived", function()
        assert.is_false(Manifest.is_derived_name(entry({ name = "auth review", name_source = "auto" })))
    end)

    it("treats a fallback name as derived", function()
        assert.is_true(Manifest.is_derived_name(entry({ name_source = "fallback" })))
    end)

    it("treats a missing or empty name as derived", function()
        assert.is_true(Manifest.is_derived_name(entry({ name = nil })))
        assert.is_true(Manifest.is_derived_name(entry({ name = "" })))
    end)

    it("treats a legacy entry as derived only when the name is the task prefix", function()
        -- No name_source: the only signal is the name itself.
        assert.is_true(Manifest.is_derived_name(entry({ name = "review the auth flow and report findings" })))
        assert.is_false(Manifest.is_derived_name(entry({ name = "user-chosen name" })))
        assert.is_false(Manifest.is_derived_name(entry({ name = "user-chosen name", task_prompt = "" })))
    end)
end)

describe("subsessions.on_child_session_name", function()
    local manifest_tmp
    local real_manifest_path

    before_each(function()
        manifest_tmp = vim.fn.tempname() .. "-child-name-manifest.json"
        real_manifest_path = Manifest.path
        Manifest.path = function()
            return manifest_tmp
        end
        Manifest._reset()
    end)

    after_each(function()
        Manifest.path = real_manifest_path
        Manifest._reset()
        pcall(os.remove, manifest_tmp)
    end)

    it("adopts the child's generated title over a derived name", function()
        Manifest.upsert("child-1", entry({ name_source = "fallback" }))
        assert.is_true(Subsessions.on_child_session_name({ id = "child-1", parent_id = "lineage-a" }, "auth review"))
        local stored = Manifest.load()["child-1"]
        assert.are.equal("auth review", stored.name)
        assert.are.equal("auto", stored.name_source)
    end)

    it("never overwrites an explicit name", function()
        Manifest.upsert("child-1", entry({ name = "auth-review", name_source = "explicit" }))
        assert.is_false(
            Subsessions.on_child_session_name({ id = "child-1", parent_id = "lineage-a" }, "generated title")
        )
        assert.are.equal("auth-review", Manifest.load()["child-1"].name)
    end)

    it("is a no-op when the name already matches", function()
        Manifest.upsert("child-1", entry({ name = "auth review", name_source = "auto" }))
        assert.is_false(Subsessions.on_child_session_name({ id = "child-1", parent_id = "lineage-a" }, "auth review"))
    end)

    it("ignores empty names and sessions that are not manifest children", function()
        Manifest.upsert("child-1", entry({ name_source = "fallback" }))
        Manifest.upsert("__lineage__", { parent = "x" })
        assert.is_false(Subsessions.on_child_session_name({ id = "child-1" }, ""))
        assert.is_false(Subsessions.on_child_session_name({ id = "child-1" }, nil))
        assert.is_false(Subsessions.on_child_session_name({ id = "parent-1" }, "parent title"))
        assert.is_false(Subsessions.on_child_session_name({}, "no id"))
        assert.is_false(Subsessions.on_child_session_name(nil, "no session"))
        assert.are.equal("review the auth flow and report findings", Manifest.load()["child-1"].name)
    end)

    it("adopts a title for a legacy entry whose name is the task prefix", function()
        Manifest.upsert("child-1", entry())
        assert.is_true(Subsessions.on_child_session_name({ id = "child-1" }, "auth review"))
        assert.are.equal("auth review", Manifest.load()["child-1"].name)
    end)

    it("leaves a legacy entry with a hand-picked name alone", function()
        Manifest.upsert("child-1", entry({ name = "hand-picked" }))
        assert.is_false(Subsessions.on_child_session_name({ id = "child-1" }, "auth review"))
        assert.are.equal("hand-picked", Manifest.load()["child-1"].name)
    end)
end)

describe("session_info_changed wiring for child sessions", function()
    local manifest_tmp
    local real_manifest_path

    before_each(function()
        manifest_tmp = vim.fn.tempname() .. "-child-name-wiring.json"
        real_manifest_path = Manifest.path
        Manifest.path = function()
            return manifest_tmp
        end
        Manifest._reset()
        SessionList._reset()
    end)

    after_each(function()
        Manifest.path = real_manifest_path
        Manifest._reset()
        SessionList._reset()
        pcall(os.remove, manifest_tmp)
    end)

    it("adopts a child's reported session name", function()
        Manifest.upsert("child-1", entry({ name_source = "fallback" }))
        Sessions.handle_event(
            { id = "child-1", parent_id = "lineage-a", attention = { pending = {} } },
            { type = "session_info_changed", name = "auth review" }
        )
        assert.are.equal("auth review", Manifest.load()["child-1"].name)
    end)

    it("does not touch the manifest for a parent session", function()
        Manifest.upsert("child-1", entry({ name_source = "fallback" }))
        Sessions.handle_event(
            { id = "child-1", attention = { pending = {} } },
            { type = "session_info_changed", name = "parent title" }
        )
        assert.are.equal("review the auth flow and report findings", Manifest.load()["child-1"].name)
    end)
end)
