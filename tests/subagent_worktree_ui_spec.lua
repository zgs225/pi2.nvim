-- Assigned worktrees (sub-agent worktree isolation) in the UI:
--   * the dispatch block names the checkout an item actually got (result item
--     first, args item as the fallback, the child's manifest row for a reuse
--     item);
--   * :PiSessions names it on the child row that was assigned it — never the
--     parent's group worktree — while the child keeps hanging under its parent,
--     so grouping / fold counts are unaffected by the cross-checkout (same
--     repository) assignment;
--   * the dormant viewer reads the transcript the manifest recorded with the
--     assignment, and resolves tool paths against the assigned checkout when
--     the transcript records no cwd of its own.
-- Rows and items without an assigned worktree must render exactly as before.
--
-- `pi.worktree` is stubbed through package.loaded and the manifest is stubbed
-- per test, so nothing here shells out to git or touches ~/.pi.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local SessionList = require("pi.ui.sessions")
local Sessions = require("pi.sessions.manager")
local SubToolUi = require("pi.subsessions.tool_ui")
local Viewer = require("pi.ui.subsession_viewer")

local GLYPH = "󰙅"
local TAB = 873

---@param path string
---@return string
local function tilde(path)
    return vim.fn.fnamemodify(path, ":~")
end

---@param path string
---@param lines table[]
---@return string
local function write_jsonl(path, lines)
    local f = io.open(path, "w")
    assert.is_not_nil(f)
    local encoded = {}
    for i, line in ipairs(lines) do
        encoded[i] = vim.json.encode(line)
    end
    f:write(table.concat(encoded, "\n"))
    f:close()
    return path
end

---@param buf integer
---@return string
local function concat_lines(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- tool_ui --------------------------------------------------------------------

describe("assigned worktree in sub-agent tool rows", function()
    local manifest_tmp

    before_each(function()
        manifest_tmp = vim.fn.tempname() .. ".json"
        Manifest.path = function()
            return manifest_tmp
        end
        Config.setup({ title = { lang = "en" } })
    end)

    after_each(function()
        os.remove(manifest_tmp)
        Config.setup({})
    end)

    it("labels a worktree by name, then by directory name, then by path", function()
        assert.is_nil(SubToolUi.worktree_label(nil))
        assert.is_nil(SubToolUi.worktree_label({}))
        assert.are.equal("wt-a", SubToolUi.worktree_label({ kind = "linked", path = "/repo/wt-a", name = "wt-a" }))
        assert.are.equal("wt-b", SubToolUi.worktree_label({ kind = "linked", path = "/repo/.worktrees/wt-b/" }))
    end)

    it("appends the assigned worktree to a dispatch item label", function()
        local item = {
            task = "write tests",
            name = "tester",
            worktree = { kind = "linked", path = "/repo/.worktrees/wt-a", name = "wt-a" },
        }
        assert.are.equal("tester " .. GLYPH .. " wt-a", SubToolUi.item_label(item))
    end)

    it("leaves a label untouched when the item carries no worktree", function()
        assert.are.equal("tester", SubToolUi.item_label({ task = "write tests", name = "tester" }))
    end)

    it("prefers the result item's assignment over the requested one", function()
        local args = { items = { { task = "t1", worktree = { kind = "linked", path = "/x/asked" } } }, wait = false }
        local details = {
            status = "completed",
            items = {
                { status = "ok", task = "t1", worktree = { kind = "linked", path = "/x/given", name = "given" } },
            },
        }
        local rows = SubToolUi.dispatch_rows(args, details)
        assert.are.equal(1, #rows)
        assert.are.equal("t1 " .. GLYPH .. " given", rows[1].label)
    end)

    it("falls back to the args item's worktree while no result detail exists", function()
        local args =
            { items = { { task = "t1", worktree = { kind = "linked", path = "/x/asked/wt-1" } } }, wait = false }
        local details = { status = "running", items = { { status = "queued", task = "t1" } } }
        local rows = SubToolUi.dispatch_rows(args, details)
        assert.are.equal("t1 " .. GLYPH .. " wt-1", rows[1].label)
    end)

    it("does not claim a checkout for an item that never started", function()
        local args =
            { items = { { task = "t1", worktree = { kind = "linked", path = "/x/asked/wt-1" } } }, wait = false }
        local details = { status = "failed", items = { { status = "failed", task = "t1", error = "spawn failed" } } }

        local rows = SubToolUi.dispatch_rows(args, details)

        -- The request never reached a child, so the requested worktree is not
        -- reported as a checkout that was actually handed out.
        assert.are.equal("t1", rows[1].label)
    end)

    it("keeps the badge for an item that failed after it started", function()
        local args =
            { items = { { task = "t1", worktree = { kind = "linked", path = "/x/asked/wt-1" } } }, wait = false }
        local details = {
            status = "partial",
            items = { { status = "failed", task = "t1", target = "child-9", error = "boom" } },
        }

        local rows = SubToolUi.dispatch_rows(args, details)

        assert.are.equal("t1 " .. GLYPH .. " wt-1", rows[1].label)
        assert.are.equal("boom", rows[1].excerpt)
    end)

    it("keeps the badge on queued and running items", function()
        local args =
            { items = { { task = "t1", worktree = { kind = "linked", path = "/x/asked/wt-1" } } }, wait = false }
        for _, status in ipairs({ "queued", "running" }) do
            local details = { status = "running", items = { { status = status, task = "t1" } } }
            local rows = SubToolUi.dispatch_rows(args, details)
            assert.are.equal("t1 " .. GLYPH .. " wt-1", rows[1].label)
        end
    end)

    it("names the worktree recorded on a reuse item's child row", function()
        Manifest.upsert("child-1", {
            parent_id = "p",
            name = "auth-review",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
            assigned_worktree = { kind = "linked", path = "/repo/.worktrees/wt-x", name = "wt-x" },
        })
        assert.are.equal(
            "auth-review " .. GLYPH .. " wt-x",
            SubToolUi.item_label({ target = "child-1", message = "hi" })
        )
    end)

    it("keeps a reuse item without an assignment unchanged", function()
        Manifest.upsert("child-2", {
            parent_id = "p",
            name = "auth-review",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
        })
        assert.are.equal("auth-review", SubToolUi.item_label({ target = "child-2", message = "hi" }))
    end)
end)

-- :PiSessions rows -----------------------------------------------------------

describe("assigned worktree on :PiSessions child rows", function()
    local orig_children
    local orig_worktree_module
    local orig_get_by_id

    ---@type table<string, table>
    local WORKTREES = {
        ["/repo/main"] = { kind = "main", name = "main", path = "/repo/main", repo_root = "/repo/main" },
        ["/repo/wt"] = { kind = "linked", name = "wt", path = "/repo/wt", repo_root = "/repo/main" },
    }

    ---@param opts? { id?: string, cwd?: string }
    ---@return pi.Session
    local function fake_session(opts)
        opts = opts or {}
        return {
            id = opts.id or "sess",
            tab = TAB,
            attached_tab = TAB,
            cwd = opts.cwd,
            conversation_epoch = 0,
            rpc = {
                is_running = function()
                    return true
                end,
            },
            chat = {
                is_streaming = function()
                    return false
                end,
                is_compacting = function()
                    return false
                end,
            },
        }
    end

    ---@param sessions pi.Session[]
    ---@return pi.SessionsListRow[]
    local function build(sessions)
        return SessionList.build_rows(sessions, function()
            return 0
        end, function(session)
            return session.id
        end)
    end

    ---@param assigned? table
    local function stub_children(assigned)
        Manifest.children_of = function(lineage)
            if lineage == "parent-1" then
                return {
                    {
                        _id = "c1",
                        name = "worker-1",
                        status = "active",
                        parent_id = "parent-1",
                        config = {},
                        assigned_worktree = assigned,
                    },
                }
            end
            return {}
        end
    end

    before_each(function()
        Config.setup({})
        SessionList._reset()
        orig_children = Manifest.children_of
        orig_worktree_module = package.loaded["pi.worktree"]
        orig_get_by_id = Sessions.get_by_id
        package.loaded["pi.worktree"] = {
            detect = function(dir)
                return WORKTREES[dir]
            end,
        }
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
        Manifest.children_of = orig_children
        package.loaded["pi.worktree"] = orig_worktree_module
        Sessions.get_by_id = orig_get_by_id
        Config.setup({})
    end)

    it("names the child's own assigned worktree instead of the parent's group worktree", function()
        local assigned = { kind = "linked", path = "/repo/other/wt-child", name = "wt-child" }
        stub_children(assigned)
        local main = fake_session({ id = "A", cwd = "/repo/main" })
        local parent = fake_session({ id = "parent-1", cwd = "/repo/wt" })

        local rows = build({ main, parent })

        -- group(main), A, group(wt), parent, child — the child never starts a
        -- group of its own and never leaves its parent's subtree.
        assert.are.equal(5, #rows)
        local child = rows[5]
        assert.are.equal(1, child.depth)
        assert.are.equal("/repo/wt", child.group_id, "the child stays in the parent's group")
        assert.are.equal(1, rows[4].child_count)
        assert.are.equal("wt-child", child.worktree)
        assert.are.equal(tilde("/repo/other/wt-child"), child.worktree_path)
        assert.are.equal("  └─ ● worker-1 · " .. GLYPH .. " wt-child", (SessionList.format_line(child, 0)))
        -- The parent row still names its own checkout implicitly through the
        -- group header; only the child carries the assigned badge.
        assert.is_nil(rows[4].worktree)
        -- Ownership safety: `row_checkout` keeps returning the parent's group, so
        -- `n` / `N` never turn the borrowed checkout into an owned top-level
        -- session (one that would be closed *and deleted* on exit).
        assert.are.equal("/repo/wt", SessionList.row_checkout(child))
    end)

    it("derives the child's worktree name from the path when it has none", function()
        stub_children({ kind = "linked", path = "/repo/other/wt-child" })
        local main = fake_session({ id = "A", cwd = "/repo/main" })
        local parent = fake_session({ id = "parent-1", cwd = "/repo/wt" })

        local rows = build({ main, parent })

        assert.are.equal("wt-child", rows[5].worktree)
        assert.are.equal("  └─ ● worker-1 · " .. GLYPH .. " wt-child", (SessionList.format_line(rows[5], 0)))
    end)

    it("keeps the inherited group worktree when the child has no assignment", function()
        stub_children(nil)
        local main = fake_session({ id = "A", cwd = "/repo/main" })
        local parent = fake_session({ id = "parent-1", cwd = "/repo/wt" })

        local rows = build({ main, parent })

        local child = rows[5]
        assert.are.equal("wt", child.worktree)
        assert.are.equal(tilde("/repo/wt"), child.worktree_path)
        assert.are.equal("  └─ ● worker-1 · " .. GLYPH .. " wt", (SessionList.format_line(child, 0)))
        assert.are.equal("/repo/wt", SessionList.row_checkout(child))
    end)

    it("keeps the parent group's checkout for n/N ownership safety", function()
        stub_children({ kind = "linked", path = "/repo/other/wt-child", name = "wt-child" })
        local main = fake_session({ id = "A", cwd = "/repo/main" })
        local parent = fake_session({ id = "parent-1", cwd = "/repo/wt" })

        local rows = build({ main, parent })

        local child = rows[5]
        assert.are.equal("wt-child", child.worktree, "the badge still names the actual checkout")
        -- `n` (new session in this checkout) and `N` (new worktree of this
        -- checkout) treat the answer as an owned top-level checkout and delete a
        -- created worktree on close, so the borrowed assignment must never reach
        -- them: the row keeps the parent's group.
        assert.are.equal("/repo/wt", SessionList.row_checkout(child))
    end)

    it("never answers with a live assigned child's own cwd", function()
        stub_children({ kind = "linked", path = "/repo/other/wt-child", name = "wt-child" })
        -- A live child runs in the assigned checkout but its rows belong to the
        -- parent workspace (`manifest_cwd`).
        local child_session = fake_session({ id = "c1", cwd = "/repo/other/wt-child" })
        child_session.manifest_cwd = "/repo/wt"
        child_session.assigned_worktree = { kind = "linked", path = "/repo/other/wt-child", name = "wt-child" }
        Sessions.get_by_id = function(id)
            return id == "c1" and child_session or nil
        end
        local parent = fake_session({ id = "parent-1", cwd = "/repo/wt" })

        local rows = build({ parent })

        -- No grouping here (one worktree), so this is the only fallback path.
        assert.are.equal("wt-child", rows[2].worktree)
        assert.are.equal("/repo/wt", SessionList.row_checkout(rows[2]))

        -- Without the parent workspace recorded, the only known directory is the
        -- borrowed one: answer nothing instead of exposing it.
        child_session.manifest_cwd = nil
        local rows_again = build({ parent })
        assert.is_nil(SessionList.row_checkout(rows_again[2]))
    end)

    it("shows the assigned worktree in a flat (single-worktree) list too", function()
        stub_children({ kind = "linked", path = "/repo/other/wt-child", name = "wt-child" })
        local parent = fake_session({ id = "parent-1", cwd = "/repo/wt" })

        local rows = build({ parent })

        -- No grouping (one worktree): parent row then its child.
        assert.are.equal(2, #rows)
        assert.are.equal("▾ ● parent-1", (SessionList.format_line(rows[1], 0)))
        assert.are.equal("  └─ ● worker-1 · " .. GLYPH .. " wt-child", (SessionList.format_line(rows[2], 0)))
    end)
end)

-- dormant viewer -------------------------------------------------------------

describe("dormant subsession viewer with an assigned worktree", function()
    local tmp_dir
    local orig_load
    local orig_find_path
    local orig_get_by_id

    ---@param overrides? table
    ---@return table entry
    local function entry(overrides)
        local base = {
            _id = "child-1",
            name = "Worker Alpha",
            status = "dormant",
            task_prompt = "t",
            parent_id = "p-1",
            config = {},
            reported = true,
            created_at = "now",
            last_active_at = "now",
        }
        return vim.tbl_extend("force", base, overrides or {})
    end

    before_each(function()
        Config.setup({})
        tmp_dir = vim.fn.tempname()
        vim.fn.mkdir(tmp_dir, "p")
        Viewer.close()
        orig_load = Manifest.load
        orig_find_path = Read.find_path
        orig_get_by_id = Sessions.get_by_id
        Sessions.get_by_id = function()
            return nil
        end
    end)

    after_each(function()
        Viewer.close()
        Manifest.load = orig_load
        Read.find_path = orig_find_path
        Sessions.get_by_id = orig_get_by_id
        Config.setup({})
        if tmp_dir and vim.fn.isdirectory(tmp_dir) == 1 then
            vim.fn.delete(tmp_dir, "rf")
        end
    end)

    it("reads the transcript path recorded on the manifest row first", function()
        local path = write_jsonl(tmp_dir .. "/assigned.jsonl", {
            { type = "session", sessionId = "child-1", cwd = "/repo/other/wt-child" },
            { type = "message", message = { role = "user", content = "assigned work" } },
        })
        local looked_up = false
        Manifest.load = function()
            return { ["child-1"] = entry({ session_file = path }) }
        end
        Read.find_path = function()
            looked_up = true
            return nil
        end

        Viewer.open("child-1")

        assert.is_true(Viewer.is_open())
        assert.is_false(looked_up, "the recorded transcript path must short-circuit the id lookup")
        assert.are.equal("/repo/other/wt-child", Viewer._history()._cwd)
        local buf = Viewer._history():buf()
        vim.wait(100, function()
            return false
        end, 10)
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        assert.is_truthy(text:find("assigned work", 1, true))
    end)

    it("falls back to the id lookup when the recorded file is gone", function()
        local path = write_jsonl(tmp_dir .. "/found.jsonl", {
            { type = "message", message = { role = "user", content = "fallback lookup" } },
        })
        Manifest.load = function()
            return {
                ["child-1"] = entry({
                    session_file = tmp_dir .. "/missing.jsonl",
                    assigned_worktree = { kind = "linked", path = "/repo/other/wt-child", name = "wt-child" },
                }),
            }
        end
        local searched = {}
        Read.find_path = function(id, opts)
            searched[#searched + 1] = type(opts) == "table" and opts.cwd or nil
            if id == "child-1" then
                return path
            end
            return nil
        end
        Viewer.open("child-1")

        assert.is_true(Viewer.is_open())
        -- The assigned checkout is searched before the parent/legacy workspace:
        -- that is where the child's JSONL lives.
        assert.are.equal("/repo/other/wt-child", searched[1])
        local buf = Viewer._history():buf()
        vim.wait(100, function()
            return false
        end, 10)
        local text = concat_lines(buf)
        assert.is_truthy(text:find("fallback lookup", 1, true))
    end)

    it("falls through to the legacy workspace when the assigned one has no row", function()
        local path = write_jsonl(tmp_dir .. "/legacy.jsonl", {
            { type = "message", message = { role = "user", content = "legacy workspace" } },
        })
        Manifest.load = function()
            return {
                ["child-1"] = entry({
                    assigned_worktree = { kind = "linked", path = "/repo/other/wt-child", name = "wt-child" },
                }),
            }
        end
        local searched = {}
        local calls = 0
        Read.find_path = function(id, opts)
            calls = calls + 1
            searched[calls] = type(opts) == "table" and opts.cwd or nil
            -- Miss in the assigned workspace, hit in the legacy one.
            if id == "child-1" and calls > 1 then
                return path
            end
            return nil
        end

        Viewer.open("child-1")

        assert.is_true(Viewer.is_open())
        assert.are.equal(2, calls, "the assigned workspace is searched first")
        assert.are.equal("/repo/other/wt-child", searched[1])
        local buf = Viewer._history():buf()
        vim.wait(100, function()
            return false
        end, 10)
        assert.is_truthy(concat_lines(buf):find("legacy workspace", 1, true))
    end)

    it("resolves tool paths against the assigned checkout when the transcript has no cwd", function()
        local path = write_jsonl(tmp_dir .. "/nocwd.jsonl", {
            { type = "message", message = { role = "user", content = "no cwd recorded" } },
        })
        Manifest.load = function()
            return {
                ["child-1"] = entry({
                    session_file = path,
                    assigned_worktree = { kind = "linked", path = "/repo/other/wt-child", name = "wt-child" },
                }),
            }
        end
        Read.find_path = function()
            return nil
        end

        Viewer.open("child-1")

        assert.is_true(Viewer.is_open())
        assert.are.equal("/repo/other/wt-child", Viewer._history()._cwd)
    end)

    it("prefers the cwd recorded in the transcript over the assignment", function()
        local path = write_jsonl(tmp_dir .. "/cwd.jsonl", {
            { type = "session", sessionId = "child-1", cwd = "/repo/wt" },
            { type = "message", message = { role = "user", content = "recorded cwd" } },
        })
        Manifest.load = function()
            return {
                ["child-1"] = entry({
                    session_file = path,
                    assigned_worktree = { kind = "linked", path = "/repo/other/wt-child", name = "wt-child" },
                }),
            }
        end
        Read.find_path = function()
            return nil
        end

        Viewer.open("child-1")

        assert.are.equal("/repo/wt", Viewer._history()._cwd)
    end)

    it("keeps the lookup-only path unchanged when nothing is recorded", function()
        local path = write_jsonl(tmp_dir .. "/plain.jsonl", {
            { type = "message", message = { role = "user", content = "plain dormant child" } },
        })
        Manifest.load = function()
            return { ["child-1"] = entry() }
        end
        Read.find_path = function(id)
            if id == "child-1" then
                return path
            end
            return nil
        end

        Viewer.open("child-1")

        assert.is_true(Viewer.is_open())
        assert.is_nil(Viewer._history()._cwd)
        local buf = Viewer._history():buf()
        vim.wait(100, function()
            return false
        end, 10)
        assert.is_truthy(concat_lines(buf):find("plain dormant child", 1, true))
    end)
end)
