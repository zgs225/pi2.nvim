-- Regression (issue #110): <leader>ap froze the editor for 20s+ in projects
-- with many sessions and sub-session manifest entries. Root cause:
-- rebuild_statuses() called Read.find_path() per manifest entry, and
-- find_path() re-ran History.list() — a full scan parsing every session file
-- — on every call: O(children × sessions).
--
-- These specs pin the fix contract:
--   - History.find_by_id resolves by the `<timestamp>_<id>.jsonl` filename
--     convention (one readdir, no full scan) and falls back to a full list()
--     scan only when no filename matches, preserving first-match (newest)
--     semantics for duplicate ids.
--   - rebuild_statuses writes the manifest back only when something changed,
--     and never overwrites an on-disk manifest that failed to decode.

local Config = require("pi.config")
local History = require("pi.sessions.history")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")

Config.setup({})

--- Mirror of the private encode_cwd() so the test can lay out the sessions dir.
local function encode_cwd(cwd)
    local encoded = cwd:gsub("^[\\/]", ""):gsub("[\\/:]", "-")
    return "--" .. encoded .. "--"
end

--- Write a session .jsonl file whose header carries `id` and whose last
--- meaningful entry sets the inferred run status.
---@param path string
---@param id string
---@param last table? final JSONL entry (defaults to an assistant message)
local function write_session(path, id, last)
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode({ type = "session", version = 3, id = id, timestamp = "2026-09-01T00:00:00Z" }) .. "\n")
    f:write(vim.json.encode({ type = "message", message = { role = "user", content = "go" } }) .. "\n")
    f:write(vim.json.encode(last or { type = "message", message = { role = "assistant", content = "done" } }) .. "\n")
    f:close()
end

--- Insert a manifest child entry directly into the on-disk manifest.
---@param id string
---@param parent_id string
---@param status string
local function seed_child(id, parent_id, status)
    local manifest = Manifest.load()
    manifest[id] = {
        _id = id,
        parent_id = parent_id,
        name = "child " .. id,
        task_prompt = "task",
        config = {},
        status = status,
        reported = false,
        created_at = "2026-09-01T00:00:00Z",
        last_active_at = "2026-09-01T00:00:00Z",
    }
    Manifest.save(manifest)
end

describe("History.find_by_id (issue #110)", function()
    local agent_dir
    local cwd
    local saved_agent_dir
    local saved_cwd
    local real_list

    before_each(function()
        agent_dir = vim.fn.tempname()
        cwd = vim.fn.tempname()
        vim.fn.mkdir(cwd, "p")
        cwd = assert(vim.uv.fs_realpath(cwd))
        vim.fn.mkdir(agent_dir .. "/sessions/" .. encode_cwd(cwd), "p")
        saved_agent_dir = Config.options.agent_dir
        saved_cwd = vim.fn.getcwd()
        Config.options.agent_dir = agent_dir
        vim.cmd("cd " .. vim.fn.fnameescape(cwd))
        Manifest._reset()
        real_list = History.list
    end)

    after_each(function()
        History.list = real_list
        Config.options.agent_dir = saved_agent_dir
        vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))
        vim.fn.delete(agent_dir, "rf")
        vim.fn.delete(cwd, "rf")
        Manifest._reset()
    end)

    local function sessions_dir()
        return agent_dir .. "/sessions/" .. encode_cwd(cwd)
    end

    it("resolves by filename convention without a full list() scan", function()
        write_session(sessions_dir() .. "/2026-09-01T00-00-00-000Z_abc-123.jsonl", "abc-123")

        -- The fast path must not fall back to the full scan: if it does, the
        -- stub raises and the test fails.
        History.list = function()
            error("find_by_id must resolve convention-named files without History.list()")
        end

        local info = History.find_by_id("abc-123")
        assert.is_not_nil(info)
        assert.equals("abc-123", info.id)
        assert.equals(sessions_dir() .. "/2026-09-01T00-00-00-000Z_abc-123.jsonl", info.path)
    end)

    it("falls back to a full scan when no filename matches the id", function()
        -- Header id differs from the filename suffix: the fast path misses.
        write_session(sessions_dir() .. "/weird-name.jsonl", "abc-456")

        local info = History.find_by_id("abc-456")
        assert.is_not_nil(info)
        assert.equals("abc-456", info.id)
        assert.equals(sessions_dir() .. "/weird-name.jsonl", info.path)
    end)

    it("scans at most once for an unknown id", function()
        local scans = 0
        History.list = function()
            scans = scans + 1
            return {}
        end
        assert.is_nil(History.find_by_id("does-not-exist"))
        assert.equals(1, scans, "fast-path miss must fall back to exactly one full scan")
    end)

    it("picks the newest file when several share an id (first-match semantics)", function()
        local old_path = sessions_dir() .. "/2026-01-01T00-00-00-000Z_dup-id.jsonl"
        local new_path = sessions_dir() .. "/2026-01-02T00-00-00-000Z_dup-id.jsonl"
        write_session(old_path, "dup-id")
        write_session(new_path, "dup-id")
        -- Glob order is alphabetical (oldest first); mtimes decide the winner.
        vim.uv.fs_utime(old_path, 1000, 1000)
        vim.uv.fs_utime(new_path, 2000, 2000)

        local info = History.find_by_id("dup-id")
        assert.is_not_nil(info)
        assert.equals(new_path, info.path)
    end)
end)

describe("rebuild_statuses (issue #110)", function()
    local agent_dir
    local cwd
    local saved_agent_dir
    local saved_cwd
    local saved_get_by_id
    local real_list

    before_each(function()
        agent_dir = vim.fn.tempname()
        cwd = vim.fn.tempname()
        vim.fn.mkdir(cwd, "p")
        cwd = assert(vim.uv.fs_realpath(cwd))
        vim.fn.mkdir(agent_dir .. "/sessions/" .. encode_cwd(cwd), "p")
        saved_agent_dir = Config.options.agent_dir
        saved_cwd = vim.fn.getcwd()
        Config.options.agent_dir = agent_dir
        vim.cmd("cd " .. vim.fn.fnameescape(cwd))
        Manifest._reset()
        real_list = History.list
        saved_get_by_id = Sessions.get_by_id
        Sessions.get_by_id = function()
            return nil
        end
    end)

    after_each(function()
        Sessions.get_by_id = saved_get_by_id
        History.list = real_list
        Config.options.agent_dir = saved_agent_dir
        vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))
        vim.fn.delete(agent_dir, "rf")
        vim.fn.delete(cwd, "rf")
        Manifest._reset()
    end)

    local function sessions_dir()
        return agent_dir .. "/sessions/" .. encode_cwd(cwd)
    end

    it("scans the session directory exactly once, not once per manifest entry", function()
        write_session(sessions_dir() .. "/2026-09-01T00-00-00-000Z_child-a.jsonl", "child-a")
        write_session(
            sessions_dir() .. "/2026-09-01T00-00-01-000Z_child-b.jsonl",
            "child-b",
            { type = "tool_use", name = "bash" }
        )
        seed_child("child-a", "parent-1", "active")
        seed_child("child-b", "parent-1", "active")
        -- Entries whose file is gone must resolve from the same snapshot, not
        -- each pay a fallback full scan.
        seed_child("gone-1", "parent-1", "active")
        seed_child("gone-2", "parent-1", "active")

        local scans = 0
        History.list = function()
            scans = scans + 1
            return real_list()
        end

        Subsessions.rebuild_statuses()

        assert.equals(1, scans, "rebuild_statuses must build its id→path index from a single scan")
        local manifest = Manifest.load()
        assert.equals("completed", manifest["child-a"].status)
        assert.equals("interrupted", manifest["child-b"].status)
        assert.equals("dormant", manifest["gone-1"].status)
        assert.equals("dormant", manifest["gone-2"].status)
    end)

    it("marks entries without a session file as dormant and leaves finished ones alone", function()
        seed_child("gone-active", "parent-1", "active")
        seed_child("gone-completed", "parent-1", "completed")

        Subsessions.rebuild_statuses()

        local manifest = Manifest.load()
        assert.equals("dormant", manifest["gone-active"].status)
        assert.equals("completed", manifest["gone-completed"].status)
    end)

    it("prefers a live session over inferred status", function()
        write_session(sessions_dir() .. "/2026-09-01T00-00-00-000Z_live-child.jsonl", "live-child")
        seed_child("live-child", "parent-1", "dormant")
        Sessions.get_by_id = function(id)
            if id == "live-child" then
                return {
                    rpc = {
                        is_running = function()
                            return true
                        end,
                    },
                }
            end
            return nil
        end

        Subsessions.rebuild_statuses()

        assert.equals("active", Manifest.load()["live-child"].status)
    end)

    it("stamps last_active_at from the session file mtime", function()
        local path = sessions_dir() .. "/2026-09-01T00-00-00-000Z_mtime-child.jsonl"
        write_session(path, "mtime-child")
        local epoch = 1756684800
        vim.uv.fs_utime(path, epoch, epoch)
        local expected = os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
        seed_child("mtime-child", "parent-1", "active")

        Subsessions.rebuild_statuses()

        assert.equals(expected, Manifest.load()["mtime-child"].last_active_at)
    end)

    it("skips saving when nothing changed", function()
        local path = sessions_dir() .. "/2026-09-01T00-00-00-000Z_settled.jsonl"
        write_session(path, "settled")
        local epoch = 1756684800
        vim.uv.fs_utime(path, epoch, epoch)
        local mtime_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
        seed_child("settled", "parent-1", "completed")
        -- Persist the already-consistent state (status + mtime stamp).
        local manifest = Manifest.load()
        manifest["settled"].last_active_at = mtime_iso
        Manifest.save(manifest)

        local saves = 0
        local real_save = Manifest.save
        Manifest.save = function(m)
            saves = saves + 1
            return real_save(m)
        end

        Subsessions.rebuild_statuses()

        Manifest.save = real_save
        assert.equals(0, saves, "an already-consistent manifest must not be rewritten")
    end)

    it("never overwrites a manifest that failed to decode", function()
        seed_child("child-a", "parent-1", "active")
        -- Corrupt the on-disk file behind Manifest's back, then drop the cache
        -- so the next load() actually reads it.
        local path = Manifest.path()
        local raw = "not json \xff\xfe at all"
        local f = assert(io.open(path, "wb"))
        f:write(raw)
        f:close()
        Manifest._reset()

        Subsessions.rebuild_statuses()

        local g = assert(io.open(path, "rb"))
        local after = g:read("*a")
        g:close()
        assert.equals(raw, after, "a corrupt manifest must be left untouched, not overwritten")
        assert.is_true(Manifest.decode_failed())
    end)

    it("refuses every writer while the manifest is corrupt, not just the rebuild", function()
        local path = Manifest.path()
        local raw = "not json at all"
        local f = assert(io.open(path, "wb"))
        f:write(raw)
        f:close()
        Manifest._reset()

        local notifies = 0
        local real_notify = vim.notify
        vim.notify = function()
            notifies = notifies + 1
        end

        -- Writers that would previously rebuild-and-save over the damaged file.
        Manifest.upsert("child-a", { _id = "child-a", parent_id = "p", name = "x" })
        Manifest.register_session_lineage("child-a", "p")
        Manifest.patch("child-a", { status = "failed" })

        vim.notify = real_notify

        local g = assert(io.open(path, "rb"))
        local after = g:read("*a")
        g:close()
        assert.equals(raw, after, "no writer may overwrite a corrupt manifest")
        assert.is_true(Manifest.decode_failed(), "decode_failed must stay set until the file decodes again")
        assert.is_true(notifies >= 1, "the refusal must surface to the user")
    end)

    it("save() works again once the manifest decodes", function()
        local path = Manifest.path()
        local f = assert(io.open(path, "wb"))
        f:write("broken")
        f:close()
        Manifest._reset()
        Manifest.load()
        assert.is_true(Manifest.decode_failed())
        assert.equals(false, Manifest.save({}))

        -- The user repairs the file by hand: the next load() must clear the
        -- latch so persistence resumes.
        f = assert(io.open(path, "wb"))
        f:write(vim.json.encode({}))
        f:close()
        Manifest._reset()
        Manifest.load()
        assert.is_false(Manifest.decode_failed())

        assert.is_true(Manifest.save({ child = { parent_id = "p" } }))
        local g = assert(io.open(path, "rb"))
        assert.not_equals("broken", g:read("*a"))
        g:close()
    end)
end)
