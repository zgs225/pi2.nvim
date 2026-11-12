-- :PiResume row layout — partitions per checkout, group titles, flat fallback.
--
-- `lua/pi/sessions/resume_layout.lua` is the single place that decides the
-- resume picker's rows: which checkout a session belongs to, when (and how) the
-- list is split into titled partitions, and what a query keeps. Both backends
-- (telescope and vim.ui.select) render its output, so these specs drive it with
-- plain fake items — no git, no telescope, no picker.

local Layout = require("pi.sessions.resume_layout")

local MAIN = "/repo"
local AUTH = MAIN .. "/.worktrees/fix-auth"
local POLISH = MAIN .. "/.worktrees/polish"

---@class FakeWorktree
---@field name string
---@field path string

---@param name string
---@return FakeWorktree
local function wt(name)
    return { name = name, path = MAIN .. "/.worktrees/" .. name }
end

---@param path string
---@param date string
---@param modified number
---@param label string
---@param worktree? FakeWorktree
---@return pi.SessionSelectItem
local function item(path, date, modified, label, worktree)
    ---@type pi.SessionSelectItem
    local entry = {
        file = path,
        session = {
            path = path,
            timestamp = date .. "T10:00:00.000Z",
            modified = modified,
            first_message = "",
            name = label,
        },
        cwd = worktree and worktree.path or MAIN,
    }
    if worktree then
        entry.worktree = worktree.name
        entry.worktree_info = {
            kind = "linked",
            name = worktree.name,
            path = worktree.path,
            repo_root = MAIN,
        }
    end
    return entry
end

--- Two sessions in the main checkout only.
---@return pi.SessionSelectItem[]
local function main_items()
    return {
        item("/sessions/main-a.jsonl", "2025-06-01", 300, "main a"),
        item("/sessions/main-b.jsonl", "2025-06-02", 100, "main b"),
    }
end

--- Main checkout plus two managed worktrees (three partitions).
---@return pi.SessionSelectItem[]
local function mixed_items()
    local items = main_items()
    vim.list_extend(items, {
        item("/sessions/auth-a.jsonl", "2025-06-03", 400, "auth a", wt("fix-auth")),
        item("/sessions/auth-b.jsonl", "2025-06-04", 200, "auth b", wt("fix-auth")),
        item("/sessions/polish-a.jsonl", "2025-06-05", 500, "polish a", wt("polish")),
    })
    return items
end

--- Row texts, with group rows marked so the partition boundaries stay visible.
---@param rows pi.ResumeRow[]
---@return string[]
local function summary(rows)
    local out = {}
    for _, row in ipairs(rows) do
        out[#out + 1] = row.kind == "group" and ("group:" .. row.text) or row.text
    end
    return out
end

describe("pi resume layout", function()
    it("returns today's flat rows below the threshold (same text, same order)", function()
        local items = main_items()
        local rows, count = Layout.rows(items, { repo_name = "pi2.nvim" })

        assert.equals(1, count)
        assert.are.same({ "2025-06-01  main a", "2025-06-02  main b" }, summary(rows))
        for _, row in ipairs(rows) do
            assert.equals("session", row.kind)
            assert.equals("main", row.partition)
            assert.is_nil(row.title, "flat rows carry no title")
        end
        -- Incoming order, exactly like the pre-partition picker.
        assert.equals(items[1], rows[1].item)
        assert.equals(items[2], rows[2].item)
    end)

    it("stays flat for a single worktree and never appends a worktree suffix", function()
        local items = {
            item("/sessions/auth-a.jsonl", "2025-06-03", 400, "auth a", wt("fix-auth")),
            item("/sessions/auth-b.jsonl", "2025-06-04", 200, "auth b", wt("fix-auth")),
        }
        local rows, count = Layout.rows(items, { repo_name = "pi2.nvim" })

        assert.equals(1, count)
        assert.are.same({ "2025-06-03  auth a", "2025-06-04  auth b" }, summary(rows))
        assert.equals(AUTH, rows[1].partition)
        assert.is_nil(rows[1].title)
    end)

    it("groups under one title per checkout once two partitions exist", function()
        local rows, count = Layout.rows(mixed_items(), { repo_name = "pi2.nvim" })

        assert.equals(3, count)
        assert.are.same({
            -- partitions by newest session: polish (500), fix-auth (400), main (300)
            "group:󰙅 polish",
            "2025-06-05  polish a",
            "group:󰙅 fix-auth",
            "2025-06-03  auth a",
            "2025-06-04  auth b",
            "group:pi2.nvim",
            "2025-06-01  main a",
            "2025-06-02  main b",
        }, summary(rows))

        -- Linked worktrees carry the glyph and the worktree flag; the main
        -- checkout is titled with the repository name.
        assert.equals("group", rows[1].kind)
        assert.is_true(rows[1].worktree)
        assert.equals(POLISH, rows[1].partition)
        assert.equals("group", rows[6].kind)
        assert.is_false(rows[6].worktree)
        assert.equals("main", rows[6].partition)
        assert.is_nil(rows[2].title, "session rows carry no title")
    end)

    it("falls back to the repository root name for the main partition", function()
        local rows = Layout.rows(mixed_items())

        -- No repo_name: the worktree records name their repository root.
        assert.equals("group:repo", summary(rows)[6])
    end)

    it("orders equal mtimes by session file path, keeping newest first", function()
        local items = {
            item("/sessions/b.jsonl", "2025-06-01", 100, "b session"),
            item("/sessions/a.jsonl", "2025-06-02", 100, "a session"),
            item("/sessions/auth.jsonl", "2025-06-03", 200, "auth", wt("fix-auth")),
        }
        local rows = Layout.rows(items, { repo_name = "pi2.nvim" })

        assert.are.same({
            "group:󰙅 fix-auth",
            "2025-06-03  auth",
            "group:pi2.nvim",
            "2025-06-02  a session",
            "2025-06-01  b session",
        }, summary(rows))
    end)

    it("renders the first message or (empty) when a session has no name", function()
        local items = {
            {
                file = "/sessions/first.jsonl",
                session = {
                    path = "/sessions/first.jsonl",
                    timestamp = "2025-06-01T10:00:00.000Z",
                    modified = 10,
                    first_message = "hello there",
                },
            },
            {
                file = "/sessions/empty.jsonl",
                session = {
                    path = "/sessions/empty.jsonl",
                    timestamp = "2025-06-02T10:00:00.000Z",
                    modified = 20,
                    first_message = "",
                },
            },
        }
        local rows = Layout.rows(items, { repo_name = "pi2.nvim" })

        assert.are.same({ "2025-06-01  hello there", "2025-06-02  (empty)" }, summary(rows))
    end)

    it("keeps a title for a partition the query narrows to, and drops empty ones", function()
        local items = mixed_items()

        local rows, count = Layout.rows(items, { repo_name = "pi2.nvim", query = "auth b" })
        assert.equals(3, count, "the threshold counts the unfiltered partitions")
        assert.are.same({ "group:󰙅 fix-auth", "2025-06-04  auth b" }, summary(rows))

        rows = Layout.rows(items, { repo_name = "pi2.nvim", query = "nothing-matches-this" })
        assert.are.same({}, summary(rows))
    end)

    it("matches a worktree name, the partition title and the checkout path", function()
        local items = mixed_items()

        -- Worktree name, case-insensitively.
        assert.are.same(
            { "group:󰙅 polish", "2025-06-05  polish a" },
            summary(Layout.rows(items, {
                repo_name = "pi2.nvim",
                query = "POLISH",
            }))
        )

        -- Main partition title (the repository name).
        assert.are.same(
            { "group:pi2.nvim", "2025-06-01  main a", "2025-06-02  main b" },
            summary(Layout.rows(items, { repo_name = "pi2.nvim", query = "pi2.nvim" }))
        )

        -- Checkout path.
        assert.are.same(
            { "group:󰙅 fix-auth", "2025-06-03  auth a", "2025-06-04  auth b" },
            summary(Layout.rows(items, { repo_name = "pi2.nvim", query = "/.worktrees/fix-auth" }))
        )
    end)

    it("filters the flat list too", function()
        local rows, count = Layout.rows(main_items(), { repo_name = "pi2.nvim", query = "main b" })

        assert.equals(1, count)
        assert.are.same({ "2025-06-02  main b" }, summary(rows))
    end)

    it("lets opts.threshold override when the list is split", function()
        -- Higher than the partition count: flat, incoming order.
        local rows, count = Layout.rows(mixed_items(), { repo_name = "pi2.nvim", threshold = 4 })
        assert.equals(3, count)
        assert.are.same({
            "2025-06-01  main a",
            "2025-06-02  main b",
            "2025-06-03  auth a",
            "2025-06-04  auth b",
            "2025-06-05  polish a",
        }, summary(rows))

        -- Threshold 1 titles even a single partition.
        local grouped = Layout.rows(main_items(), { repo_name = "pi2.nvim", threshold = 1 })
        assert.are.same({ "group:pi2.nvim", "2025-06-01  main a", "2025-06-02  main b" }, summary(grouped))
    end)
end)
