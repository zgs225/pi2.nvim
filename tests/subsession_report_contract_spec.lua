-- Unit tests for the sub-agent report contract:
-- 1. lua/pi/subsessions/tool_ui.lua split_report_status — the trailing
--    "STATUS: ok|blocked|failed" marker is split off only when it is the last
--    non-blank line and carries a legal value; otherwise the report comes back
--    untouched, byte for byte.
-- 2. completion_report — no marker keeps the old wording exactly; a marker
--    adds it to the header.
-- 3. extensions/subagent-child.ts WORKER_NOTE — static text that states the
--    reporting rules (in-message, absolute paths, outcome first, STATUS line)
--    and stays free of backticks / ${} interpolation.

local Config = require("pi.config")
local SubToolUi = require("pi.subsessions.tool_ui")

local function repo_root()
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
end

describe("subsession report contract: split_report_status", function()
    it("splits the three legal status values off the body", function()
        ---@type { report: string, status: string, body: string }[]
        local cases = {
            { report = "done\nSTATUS: ok", status = "ok", body = "done" },
            { report = "done\nSTATUS: blocked", status = "blocked", body = "done" },
            { report = "done\nSTATUS: failed", status = "failed", body = "done" },
        }
        for _, case in ipairs(cases) do
            local status, body = SubToolUi.split_report_status(case.report)
            assert.are.equal(case.status, status, ("status of %q"):format(case.report))
            assert.are.equal(case.body, body, ("body of %q"):format(case.report))
        end
    end)

    it("matches the STATUS word case-insensitively and normalizes the value", function()
        ---@type { report: string, status: string }[]
        local cases = {
            { report = "done\nSTATUS: OK", status = "ok" },
            { report = "done\nSTATUS: Blocked", status = "blocked" },
            { report = "done\nSTATUS: FAILED", status = "failed" },
            { report = "done\nstatus: ok", status = "ok" },
            { report = "done\nStatus: Ok", status = "ok" },
        }
        for _, case in ipairs(cases) do
            local status, body = SubToolUi.split_report_status(case.report)
            assert.are.equal(case.status, status, ("status of %q"):format(case.report))
            assert.are.equal("done", body, ("body of %q"):format(case.report))
        end
    end)

    it("tolerates surrounding whitespace on the marker line", function()
        ---@type { report: string, status: string, body: string }[]
        local cases = {
            { report = "done\nSTATUS:   ok   ", status = "ok", body = "done" },
            { report = "done\n   STATUS: ok", status = "ok", body = "done" },
            { report = "done\n\tSTATUS:\tfailed\t", status = "failed", body = "done" },
            -- blank lines after the marker are still "last non-blank line"
            { report = "done\nSTATUS: ok\n\n  \n", status = "ok", body = "done" },
        }
        for _, case in ipairs(cases) do
            local status, body = SubToolUi.split_report_status(case.report)
            assert.are.equal(case.status, status, ("status of %q"):format(case.report))
            assert.are.equal(case.body, body, ("body of %q"):format(case.report))
        end
    end)

    it("handles CRLF line endings", function()
        local status, body = SubToolUi.split_report_status("done\r\nSTATUS: ok\r\n")
        assert.are.equal("ok", status)
        assert.are.equal("done", body)

        local status2, body2 = SubToolUi.split_report_status("line1\r\nline2\r\nSTATUS: blocked")
        assert.are.equal("blocked", status2)
        assert.are.equal("line1\r\nline2", body2)
    end)

    it("preserves the body's internal whitespace and left indent, trims the right", function()
        local status, body = SubToolUi.split_report_status("  done\nSTATUS: ok")
        assert.are.equal("ok", status)
        assert.are.equal("  done", body)

        local status2, body2 = SubToolUi.split_report_status("line1\n\nline2\nSTATUS: ok")
        assert.are.equal("ok", status2)
        assert.are.equal("line1\n\nline2", body2)

        local status3, body3 = SubToolUi.split_report_status("done   \n\nSTATUS: ok")
        assert.are.equal("ok", status3)
        assert.are.equal("done", body3)
    end)

    it("uses the last marker line when several are present", function()
        local status, body = SubToolUi.split_report_status("a\nSTATUS: ok\nSTATUS: failed")
        assert.are.equal("failed", status)
        assert.are.equal("a\nSTATUS: ok", body)
    end)

    it("returns nil plus the untouched report when there is no legal marker", function()
        ---@type { name: string, report: string }[]
        local cases = {
            { name = "illegal value", report = "done\nSTATUS: maybe" },
            { name = "empty value", report = "done\nSTATUS:" },
            { name = "whitespace-only value", report = "done\nSTATUS:   " },
            { name = "marker not last", report = "done\nSTATUS: ok\nmore text" },
            { name = "marker only", report = "STATUS: ok" },
            { name = "marker only with blanks", report = "\n  \nSTATUS: ok\n\n" },
            { name = "no marker", report = "just a report" },
            { name = "embedded marker", report = "STATUS: ok is what I would say" },
            { name = "marker with suffix", report = "done\nSTATUS: ok!" },
        }
        for _, case in ipairs(cases) do
            local status, body = SubToolUi.split_report_status(case.report)
            assert.is_nil(status, ("%s must not yield a status"):format(case.name))
            assert.are.equal(case.report, body, ("%s must return the original report"):format(case.name))
        end
    end)

    it("returns nil plus the original input for non-strings and the empty string", function()
        local status, body = SubToolUi.split_report_status("")
        assert.is_nil(status)
        assert.are.equal("", body)

        local status2, body2 = SubToolUi.split_report_status(nil)
        assert.is_nil(status2)
        assert.is_nil(body2)

        local status3, body3 = SubToolUi.split_report_status(42)
        assert.is_nil(status3)
        assert.are.equal(42, body3)
    end)
end)

describe("subsession report contract: completion_report", function()
    after_each(function()
        Config.setup({})
    end)

    it("keeps the old zh wording byte for byte without a marker", function()
        Config.setup({ title = { lang = "zh" } })
        assert.are.equal("[子会话「w」已完成] done", SubToolUi.completion_report("w", "done"))
        -- an illegal marker is not a marker: the report stays verbatim
        assert.are.equal(
            "[子会话「w」已完成] done\nSTATUS: maybe",
            SubToolUi.completion_report("w", "done\nSTATUS: maybe")
        )
    end)

    it("keeps the old en wording byte for byte without a marker", function()
        Config.setup({ title = { lang = "en" } })
        assert.are.equal('[Sub-session "w" completed] done', SubToolUi.completion_report("w", "done"))
        assert.are.equal(
            '[Sub-session "w" completed] done\nSTATUS: maybe',
            SubToolUi.completion_report("w", "done\nSTATUS: maybe")
        )
    end)

    it("renders the status in the zh header when a marker is present", function()
        Config.setup({ title = { lang = "zh" } })
        assert.are.equal(
            "[子会话「w」已完成：blocked] done",
            SubToolUi.completion_report("w", "done\nSTATUS: blocked")
        )
        assert.are.equal("[子会话「w」已完成：ok] done", SubToolUi.completion_report("w", "done\nSTATUS: OK"))
    end)

    it("renders the status in the en header when a marker is present", function()
        Config.setup({ title = { lang = "en" } })
        assert.are.equal(
            '[Sub-session "w" completed: blocked] done',
            SubToolUi.completion_report("w", "done\nSTATUS: blocked")
        )
        assert.are.equal('[Sub-session "w" completed: ok] done', SubToolUi.completion_report("w", "done\nSTATUS: OK"))
    end)
end)

describe("subsession report contract: extensions/subagent-child.ts WORKER_NOTE", function()
    local content

    before_each(function()
        local path = repo_root() .. "/extensions/subagent-child.ts"
        local file = io.open(path, "r")
        assert.is_not_nil(file, "subagent-child.ts must exist at: " .. path)
        content = file:read("*a")
        file:close()
        assert.is_not_nil(content, "subagent-child.ts must be readable")
    end)

    it("states the four reporting rules in the static note", function()
        local note = content:match("const WORKER_NOTE%s*=%s*%[(.-)%]%.join")
        assert.is_not_nil(note, "WORKER_NOTE must be a [...].join(...) constant")
        local lower = note:lower()

        -- 1. the report goes in the last message, not in a file
        assert.is_truthy(lower:find("last message", 1, true), "note must say the report is the last message")
        assert.is_truthy(lower:find("not in a file", 1, true), "note must forbid a file-based report")

        -- 2. absolute paths
        assert.is_truthy(lower:find("absolute", 1, true), "note must require absolute paths")
        assert.is_truthy(lower:find("path", 1, true), "note must talk about paths")

        -- 3. outcome first, roughly 200 words
        assert.is_truthy(lower:find("outcome", 1, true), "note must ask for the outcome first")
        assert.is_truthy(lower:find("200", 1, true), "note must cap the report at about 200 words")

        -- 4. the three STATUS values
        assert.is_truthy(lower:find("status: ok", 1, true), "note must mention STATUS: ok")
        assert.is_truthy(lower:find("status: blocked", 1, true), "note must mention STATUS: blocked")
        assert.is_truthy(lower:find("status: failed", 1, true), "note must mention STATUS: failed")
    end)

    it("keeps the note a template-free static literal", function()
        local note = content:match("const WORKER_NOTE%s*=%s*%[(.-)%]%.join")
        assert.is_not_nil(note, "WORKER_NOTE must be a [...].join(...) constant")
        assert.is_nil(note:find("`", 1, true), "WORKER_NOTE must not use template literals")
        assert.is_nil(note:find("${", 1, true), "WORKER_NOTE must not use interpolation")
    end)
end)
