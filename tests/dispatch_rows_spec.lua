local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local SubToolUi = require("pi.subsessions.tool_ui")

describe("dispatch_rows", function()
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
    end)

    it("renders N rows with checkmarks and name labels on all-ok", function()
        local args = {
            items = {
                { task = "build the parser" },
                { name = "tester", task = "write tests" },
            },
            wait = false,
        }
        local details = {
            status = "completed",
            items = {
                { status = "ok", task = "build the parser" },
                { status = "ok", name = "tester", task = "write tests" },
            },
        }
        local rows = SubToolUi.dispatch_rows(args, details)
        assert.are.equal(2, #rows)
        assert.are.equal("  ├─ ", rows[1].prefix)
        assert.are.equal("  └─ ", rows[2].prefix)
        assert.are.equal("✓", rows[1].mark)
        assert.are.equal("PiToolStatus", rows[1].mark_hl)
        assert.are.equal("✓", rows[2].mark)
        assert.are.equal("build the parser", rows[1].label)
        assert.are.equal("tester", rows[2].label)
        assert.is_nil(rows[1].excerpt, "ok rows must not carry an output summary")
        assert.is_nil(rows[2].excerpt)
    end)

    it("marks partial results per item and truncates failed excerpts", function()
        local args = {
            items = {
                { task = "t1" },
                { task = "t2" },
                { task = "t3" },
            },
            wait = false,
        }
        local details = {
            status = "partial",
            items = {
                { status = "ok", task = "t1", output = "some output" },
                { status = "failed", task = "t2", error = string.rep("e", 120) },
                { status = "cancelled", task = "t3", error = "stop\nnow" },
            },
        }
        local rows = SubToolUi.dispatch_rows(args, details)
        assert.are.equal(3, #rows)

        assert.are.equal("✓", rows[1].mark)
        assert.is_nil(rows[1].excerpt, "ok rows never show output")

        assert.are.equal("✗", rows[2].mark)
        assert.are.equal("PiToolError", rows[2].mark_hl)
        assert.is_not_nil(rows[2].excerpt)
        assert.are.equal(string.rep("e", 80) .. "…", rows[2].excerpt)
        -- 80 characters (not bytes) plus the ellipsis: a cut must never split a
        -- UTF-8 sequence.
        assert.is_true(vim.fn.strchars(rows[2].excerpt) <= 81)

        assert.are.equal("⊘", rows[3].mark)
        assert.are.equal("PiToolError", rows[3].mark_hl)
        assert.are.equal("stop now", rows[3].excerpt, "excerpt is flattened")
    end)

    it("omits cancelled excerpts when the item carries no error", function()
        local args = { items = { { task = "t1" }, { task = "t2" } }, wait = false }
        local details = {
            status = "cancelled",
            items = {
                { status = "cancelled", task = "t1" },
                { status = "cancelled", task = "t2", error = "gone" },
            },
        }
        local rows = SubToolUi.dispatch_rows(args, details)
        assert.is_nil(rows[1].excerpt)
        assert.are.equal("gone", rows[2].excerpt)
    end)

    it("draws no marks while every item is still queued", function()
        local args = { items = { { task = "a" }, { task = "b" } }, wait = false }
        local details = {
            status = "running",
            summary = { total = 2, done = 0 },
            items = {
                { status = "queued", task = "a" },
                { status = "queued", task = "b" },
            },
        }
        local rows = SubToolUi.dispatch_rows(args, details)
        assert.are.equal(2, #rows)
        for _, row in ipairs(rows) do
            assert.are.equal("", row.mark)
            assert.is_nil(row.mark_hl)
        end
    end)

    it("mixes queued and running marks in one snapshot", function()
        local args = { items = { { task = "a" }, { task = "b" }, { task = "c" } }, wait = false }
        local details = {
            status = "running",
            items = {
                { status = "queued", task = "a" },
                { status = "running", task = "b" },
                { status = "spawning", task = "c" },
            },
        }
        local rows = SubToolUi.dispatch_rows(args, details)
        assert.are.equal("·", rows[1].mark)
        assert.are.equal("Comment", rows[1].mark_hl)
        assert.are.equal("◐", rows[2].mark)
        assert.are.equal("PiToolRunning", rows[2].mark_hl)
        assert.are.equal("◐", rows[3].mark)
    end)

    it("never renders an item ref, explicit or default", function()
        local args = {
            items = {
                { ref = "alpha", task = "named task" },
                -- Item 2's default ref is "1", item 3 has none: neither shape is
                -- a human-readable identity, so no row shows one.
                { ref = "1", task = "default index ref" },
                { task = "no ref" },
            },
            wait = false,
        }
        local details = {
            status = "completed",
            items = {
                { status = "ok", name = "named", task = "named task" },
                { status = "ok", task = "default index ref" },
                { status = "ok", task = "no ref" },
            },
        }
        local rows = SubToolUi.dispatch_rows(args, details)
        assert.are.equal("named", rows[1].label)
        assert.is_nil(rows[2].label:find("[", 1, true), "default index ref never renders")
        assert.matches("default index ref", rows[2].label)
        assert.is_nil(rows[3].label:find("[", 1, true), "absent ref → no prefix")
        for _, row in ipairs(rows) do
            assert.is_nil(row.label:find("alpha", 1, true), "explicit refs never render either")
        end
    end)

    it("labels an unnamed reuse item by its message, not a truncated id", function()
        -- The manifest row is gone (a replay in another workspace): the message
        -- is the only part of the item that survives it.
        local gone = "0b9c8d7e-6f5a-4b3c-2d1e-9f8a7b6c5d4e"
        local args = {
            items = {
                { target = gone, message = "summarize the findings\nand report" },
                { target = gone .. "x", message = string.rep("y", 60) },
            },
            wait = false,
        }
        local details = {
            status = "completed",
            items = {
                { status = "ok", target = gone },
                { status = "ok", target = gone .. "x" },
            },
        }
        local rows = SubToolUi.dispatch_rows(args, details)
        -- From the tool input, since the batch record need not echo it back.
        assert.are.equal('sub-session "summarize the findings and report"', rows[1].label)
        assert.are.equal('sub-session "' .. string.rep("y", 40) .. '…"', rows[2].label)
        assert.is_nil(rows[1].label:find("…6c5d4e", 1, true), "no id when a message exists")
    end)

    it("falls back to the truncated id when a reuse item has no message either", function()
        local gone = "0b9c8d7e-6f5a-4b3c-2d1e-9f8a7b6c5d4e"
        local rows = SubToolUi.dispatch_rows(
            { items = { { target = gone, message = "" } }, wait = false },
            { status = "completed", items = { { status = "ok", target = gone } } }
        )
        assert.are.equal("…6c5d4e", rows[1].label)
    end)

    it("keeps a stated model / thinking level on the status row", function()
        local args = {
            items = { { task = "a", name = "one", model = "gpt-4o" }, { task = "b", name = "two" } },
            wait = false,
        }
        local details = {
            status = "completed",
            items = {
                { status = "ok", task = "a", name = "one", model = "gpt-4o" },
                { status = "ok", task = "b", name = "two" },
            },
        }
        local rows = SubToolUi.dispatch_rows(args, details)
        assert.are.equal("one (gpt-4o)", rows[1].label)
        assert.are.equal("two", rows[2].label)
    end)

    it("falls back to the first 40 task characters without a name", function()
        local task = string.rep("x", 50)
        local args = { items = { { task = task } }, wait = false }
        local details = { status = "completed", items = { { status = "ok", task = task } } }
        local rows = SubToolUi.dispatch_rows(args, details)
        assert.are.equal(string.rep("x", 40), rows[1].label)
    end)

    it("labels reuse items with the manifest child name", function()
        Manifest.upsert("child-row", {
            parent_id = "p",
            name = "auth-review",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
        })
        local args = { items = { { target = "child-row", message = "go" } }, wait = false }
        local details = {
            status = "completed",
            items = { { status = "ok", target = "child-row", message = "go" } },
        }
        local rows = SubToolUi.dispatch_rows(args, details)
        assert.are.equal("auth-review", rows[1].label)
    end)

    it("returns nil when details has no items table", function()
        local args = { items = { { task = "a" } }, wait = false }
        assert.is_nil(SubToolUi.dispatch_rows(args, { error = "boom" }))
        assert.is_nil(SubToolUi.dispatch_rows(args, { status = "running" }))
        assert.is_nil(SubToolUi.dispatch_rows(args, nil))
        assert.is_nil(SubToolUi.dispatch_rows(nil, { items = {} }))
        assert.is_nil(SubToolUi.dispatch_rows({}, { items = {} }))
    end)
end)

describe("batch_status_text", function()
    it("localizes zh terminal states", function()
        Config.setup({ title = { lang = "zh" } })
        assert.are.equal(
            "4/4 已完成",
            SubToolUi.batch_status_text({ status = "completed", summary = { done = 4, total = 4 } })
        )
        assert.are.equal(
            "2/4 部分失败",
            SubToolUi.batch_status_text({ status = "partial", summary = { done = 2, total = 4 } })
        )
        assert.are.equal(
            "4/4 失败",
            SubToolUi.batch_status_text({ status = "failed", summary = { done = 4, total = 4 } })
        )
        assert.are.equal(
            "1/4 已取消",
            SubToolUi.batch_status_text({ status = "cancelled", summary = { done = 1, total = 4 } })
        )
        assert.are.equal(
            "2/4 进行中",
            SubToolUi.batch_status_text({ status = "running", summary = { done = 2, total = 4 } })
        )
    end)

    it("keeps en terminal states as the raw status word", function()
        Config.setup({ title = { lang = "en" } })
        assert.are.equal(
            "4/4 completed",
            SubToolUi.batch_status_text({ status = "completed", summary = { done = 4, total = 4 } })
        )
        assert.are.equal(
            "2/4 partial",
            SubToolUi.batch_status_text({ status = "partial", summary = { done = 2, total = 4 } })
        )
        assert.are.equal(
            "4/4 failed",
            SubToolUi.batch_status_text({ status = "failed", summary = { done = 4, total = 4 } })
        )
        assert.are.equal(
            "1/4 cancelled",
            SubToolUi.batch_status_text({ status = "cancelled", summary = { done = 1, total = 4 } })
        )
        assert.are.equal(
            "2/4 running",
            SubToolUi.batch_status_text({ status = "running", summary = { done = 2, total = 4 } })
        )
    end)
end)

describe("dispatch_inline_status", function()
    before_each(function()
        Config.setup({ title = { lang = "zh" } })
    end)

    it("counters only when the single item came back cleanly", function()
        assert.are.equal(
            "1/1 已完成",
            SubToolUi.dispatch_inline_status({ status = "completed", summary = { done = 1, total = 1 } })
        )
    end)

    it("appends the item's error, flattened and capped, when it failed", function()
        local details = {
            status = "failed",
            summary = { done = 1, total = 1 },
            items = { { status = "failed", error = "tests: 3 failures\nin history_spec" } },
        }
        assert.are.equal("1/1 失败 — tests: 3 failures in history_spec", SubToolUi.dispatch_inline_status(details))

        local long = {
            status = "failed",
            summary = { done = 1, total = 1 },
            items = { { status = "failed", error = string.rep("e", 120) } },
        }
        assert.are.equal("1/1 失败 — " .. string.rep("e", 80) .. "…", SubToolUi.dispatch_inline_status(long))
    end)

    it("cuts an excerpt on characters, never inside a UTF-8 sequence", function()
        local details = {
            status = "failed",
            summary = { done = 1, total = 1 },
            items = { { status = "failed", error = string.rep("错误", 50) } },
        }
        local text = SubToolUi.dispatch_inline_status(details)
        assert.are.equal("1/1 失败 — " .. string.rep("错误", 40) .. "…", text)
    end)

    it("surfaces a tool-level rejection, which never arrives as isError", function()
        assert.are.equal(
            '! item 1: unknown sub-agent target "nope"',
            SubToolUi.dispatch_inline_status({ error = 'item 1: unknown sub-agent target "nope"' })
        )
    end)

    it("says nothing without details", function()
        assert.is_nil(SubToolUi.dispatch_inline_status(nil))
        assert.is_nil(SubToolUi.dispatch_inline_status({}))
    end)
end)

describe("dispatch_header_detail", function()
    it("carries the item count and nothing else (en)", function()
        Config.setup({ title = { lang = "en" } })
        assert.are.equal(
            "4 items",
            SubToolUi.dispatch_header_detail({
                items = { { task = "a" }, { task = "b" }, { task = "c" }, { task = "d" } },
            })
        )
    end)

    it("carries the item count and nothing else (zh)", function()
        Config.setup({ title = { lang = "zh" } })
        assert.are.equal(
            "4 项",
            SubToolUi.dispatch_header_detail({
                items = {
                    { task = "a" },
                    { task = "b" },
                    { task = "c" },
                    { target = "i1", message = "m" },
                },
            })
        )
    end)

    it("says nothing for a single item, which never renders a block", function()
        Config.setup({ title = { lang = "en" } })
        assert.is_nil(SubToolUi.dispatch_header_detail({ items = { { task = "only" } }, wait = false }))
        assert.is_nil(SubToolUi.dispatch_header_detail({ items = {} }))
        assert.is_nil(SubToolUi.dispatch_header_detail(nil))
        assert.is_nil(SubToolUi.dispatch_header_detail({}))
    end)
end)
