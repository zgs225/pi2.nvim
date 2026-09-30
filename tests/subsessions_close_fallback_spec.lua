-- M.close inside the revive id-migration window: M.revive pins the registry
-- key to the manifest id via Sessions.ensure_id, but the revived process's
-- pre-switch get_state response carries its own self-generated sessionId and
-- capture_session_id -> migrate_session_id re-keys the registry (the
-- post-switch get_state heals it one round-trip later). In that window
-- get_by_id(manifest id) is nil while the process is alive — close must still
-- stop the process (session-file fallback) before patching the manifest
-- dormant, otherwise a live process hides under a dormant row the reaper
-- skips forever.
--
-- Hermetic per G14/G17/G18: manifest redirected to a temp file, Read.find_path
-- stubbed (no real session-dir scan, no real files touched or removed),
-- registry fakes via Sessions._register_for_test. No Config.options.subagent
-- mutation (G31).

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Subsessions = require("pi.subsessions")
local Sessions = require("pi.sessions.manager")

describe("subsessions close in the revive id-migration window", function()
    local manifest_tmp
    local real_manifest_path
    local real_find_path
    local child_path
    local stop_calls

    --- Manifest id used throughout; Read.find_path resolves it to `child_path`.
    local MANIFEST_ID = "child-manifest"

    before_each(function()
        Config.setup({})
        stop_calls = 0
        -- Virtual path: M.close never reads the file, only compares it.
        child_path = "/tmp/pi-close-fallback-" .. tostring(os.time()) .. ".jsonl"
        manifest_tmp = vim.fn.tempname() .. ".json"
        real_manifest_path = Manifest.path
        Manifest.path = function()
            return manifest_tmp
        end
        Manifest._reset()
        Sessions._reset()
        real_find_path = Read.find_path
        Read.find_path = function(id)
            if id == MANIFEST_ID then
                return child_path
            end
            return nil
        end
    end)

    after_each(function()
        Read.find_path = real_find_path
        Sessions._reset()
        Manifest.path = real_manifest_path
        Manifest._reset()
        pcall(os.remove, manifest_tmp)
    end)

    ---@param status string
    local function add_manifest_row(status)
        Manifest.upsert(MANIFEST_ID, {
            parent_id = "lineage-a",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "t",
            config = {},
            status = status,
            reported = false,
            created_at = "2024-01-01T00:00:00Z",
            last_active_at = "2024-01-01T00:00:00Z",
        })
    end

    --- Register a fake running child session whose rpc:stop is observable.
    ---@param opts { id: string, session_file?: string, parent_id?: string }
    ---@return table session
    local function register_child(opts)
        ---@type table
        local session = {
            id = opts.id,
            parent_id = opts.parent_id,
            session_file = opts.session_file,
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function()
                    stop_calls = stop_calls + 1
                end,
            },
        }
        Sessions._register_for_test(session)
        return session
    end

    ---@return string? status
    local function manifest_status()
        local entry = Manifest.load()[MANIFEST_ID]
        return entry ~= nil and type(entry) == "table" and entry.status or nil
    end

    it("stops the migrated-key child via the session-file fallback", function()
        add_manifest_row("active")
        -- Registry key migrated away from the manifest id; the child still
        -- reports the revive-loaded JSONL for the manifest id.
        register_child({ id = "rekeyed-session-1", session_file = child_path, parent_id = "lineage-a" })
        assert.is_nil(Sessions.get_by_id(MANIFEST_ID), "precondition: registry key is migrated away")

        assert.is_true(Subsessions.close(MANIFEST_ID))
        assert.equals(1, stop_calls, "fallback target's rpc:stop must run exactly once")
        assert.is_nil(Sessions.get_by_id("rekeyed-session-1"), "close_session must drop the migrated registry key")
        assert.equals("dormant", manifest_status())
    end)

    it("returns false when no registered child matches the manifest session file", function()
        add_manifest_row("active")
        register_child({
            id = "rekeyed-session-2",
            session_file = "/tmp/some-other-session.jsonl",
            parent_id = "lineage-a",
        })
        assert.is_nil(Sessions.get_by_id(MANIFEST_ID))

        assert.is_false(Subsessions.close(MANIFEST_ID))
        assert.equals(0, stop_calls, "a non-matching session must not be stopped")
        assert.is_truthy(Sessions.get_by_id("rekeyed-session-2"), "unrelated registry row must survive")
        -- No process was found; the dormant patch (file retained) still applies.
        assert.equals("dormant", manifest_status())
    end)

    it("does not match a parent session (parent_id == nil) on the same file", function()
        add_manifest_row("active")
        register_child({ id = "parent-session", session_file = child_path })

        assert.is_false(Subsessions.close(MANIFEST_ID))
        assert.equals(0, stop_calls, "parent sessions are never close targets")
        assert.is_truthy(Sessions.get_by_id("parent-session"))
    end)

    it("closes directly when the registry key is still pinned to the manifest id", function()
        add_manifest_row("active")
        register_child({ id = MANIFEST_ID, session_file = child_path, parent_id = "lineage-a" })

        assert.is_true(Subsessions.close(MANIFEST_ID))
        assert.equals(1, stop_calls)
        assert.is_nil(Sessions.get_by_id(MANIFEST_ID))
        assert.equals("dormant", manifest_status())
    end)

    it("returns false when the manifest id resolves to no file and no registry row", function()
        add_manifest_row("active")
        assert.is_false(Subsessions.close("no-such-child"))
        assert.equals(0, stop_calls)
    end)
end)
