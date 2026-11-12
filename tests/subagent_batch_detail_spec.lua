-- Readable `poll_subagents` / `wait_subagents` rows: the batch's item labels
-- instead of a bare batch id, and the failed items in the header status.
--
-- Both tools render inline (a single line, no body rows), so the labels are the
-- only thing tying a row to the work it waits on and the header is the only
-- place a failed item can surface.

local Batch = require("pi.subsessions.batch")
local History = require("pi.ui.chat.history")
local Manifest = require("pi.subsessions.manifest")
local SubToolUi = require("pi.subsessions.tool_ui")
local Tools = require("pi.ui.chat.tools")

local TAB = 957
local BATCH_ID = "1731300000-123456"

local function pump(ms)
    vim.wait(ms or 60)
end

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function text_of(buf)
    return table.concat(lines_of(buf), "\n")
end

--- Every inline virt_text chunk in the buffer, in buffer order.
---@param h pi.ChatHistory
---@return string[]
local function virt_text(h)
    local out = {}
    for _, em in ipairs(vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), 0, -1, { details = true })) do
        local vt = (em[4] or {}).virt_text
        if vt then
            for _, chunk in ipairs(vt) do
                if type(chunk[1]) == "string" then
                    out[#out + 1] = chunk[1]
                end
            end
        end
    end
    return out
end

local function delete(h)
    pcall(vim.api.nvim_buf_delete, h:buf(), { force = true })
end

---@param items table[]
---@param status string
---@return table details
local function batch_details(items, status)
    local summary = { total = #items, done = 0, ok = 0, failed = 0, cancelled = 0, running = 0 }
    for _, item in ipairs(items) do
        if item.status == "ok" then
            summary.done = summary.done + 1
            summary.ok = summary.ok + 1
        elseif item.status == "failed" then
            summary.done = summary.done + 1
            summary.failed = summary.failed + 1
        elseif item.status == "cancelled" then
            summary.done = summary.done + 1
            summary.cancelled = summary.cancelled + 1
        else
            summary.running = summary.running + 1
        end
    end
    return { batch_id = BATCH_ID, status = status, summary = summary, items = items }
end

describe("subagent batch detail", function()
    local batch_tmp
    local manifest_tmp

    --- Persist a batch record the way dispatch would, then re-read it.
    ---@param items table[]
    ---@param status string
    local function write_batch(items, status)
        local file = assert(io.open(batch_tmp, "w"))
        file:write(vim.json.encode({
            [BATCH_ID] = { id = BATCH_ID, status = status, items = items, updated_at = "2026-11-11T00:00:00Z" },
        }))
        file:close()
        Batch._reset()
        Batch._set_path(batch_tmp)
    end

    before_each(function()
        batch_tmp = vim.fn.tempname() .. "-batches.json"
        manifest_tmp = vim.fn.tempname() .. ".json"
        Manifest.path = function()
            return manifest_tmp
        end
        Batch._reset()
        Batch._set_path(batch_tmp)
    end)

    after_each(function()
        Batch._reset()
        os.remove(batch_tmp)
        os.remove(manifest_tmp)
    end)

    local items = {
        { ref = "a", task = "review the auth flow", name = "auth-review", status = "ok" },
        { ref = "b", task = "fix the schema migration", name = "schema-fix", status = "failed" },
        { ref = "c", task = "sweep the docs", name = "docs-sweep", status = "failed" },
    }

    it("names the batch's items instead of its id", function()
        write_batch(items, "partial")
        assert.are.equal("auth-review, schema-fix, docs-sweep", SubToolUi.batch_items_text(BATCH_ID))
    end)

    it("elides the labels past the bound as +N", function()
        local many = {}
        for i = 1, 6 do
            many[i] = { ref = "r" .. i, task = "task " .. i, name = "item-" .. i, status = "ok" }
        end
        write_batch(many, "completed")
        assert.are.equal("item-1, item-2, item-3, +3", SubToolUi.batch_items_text(BATCH_ID))
    end)

    it("falls back to the short id when the batch record is gone", function()
        assert.are.equal("batch …123456", SubToolUi.batch_items_text(BATCH_ID))
    end)

    it("appends the items that did not come back cleanly to the status", function()
        local text = SubToolUi.batch_outcome_text(batch_details(items, "partial"))
        assert.are.equal("3/3 partial · ✗ schema-fix, ✗ docs-sweep", text)
    end)

    it("keeps the plain counters when nothing failed", function()
        local clean = {
            { ref = "a", task = "review", name = "auth-review", status = "ok" },
            { ref = "b", task = "tests", name = "tests", status = "running" },
        }
        assert.are.equal("1/2 running", SubToolUi.batch_outcome_text(batch_details(clean, "running")))
    end)

    it("renders the labels in the poll row and the failures in its status", function()
        write_batch(items, "partial")
        local h = History.new(TAB)
        h:on_tool_start("poll_subagents", "p1", { batch_id = BATCH_ID })
        h:on_tool_end(
            "poll_subagents",
            "p1",
            { content = { { type = "text", text = "batch settled" } }, details = batch_details(items, "partial") },
            false
        )
        pump(90)
        local text = text_of(h:buf())
        assert.is_truthy(text:find("auth-review, schema-fix, docs-sweep", 1, true), text)
        local virt = table.concat(virt_text(h), "|")
        assert.is_truthy(virt:find("3/3 partial", 1, true), virt)
        assert.is_truthy(virt:find("✗ schema-fix", 1, true), virt)
        delete(h)
    end)

    it("shows the wait window on a wait row", function()
        write_batch(items, "partial")
        local h = History.new(TAB)
        h:on_tool_start("wait_subagents", "w1", { batch_id = BATCH_ID, timeout_ms = 300000 })
        pump(60)
        local text = text_of(h:buf())
        assert.is_truthy(text:find("auth-review, schema-fix, docs-sweep (timeout 300s)", 1, true), text)
        delete(h)
    end)

    it("keeps the renderer wiring on both poll and wait", function()
        for _, tool in ipairs({ "poll_subagents", "wait_subagents" }) do
            local renderer = Tools.get_renderer(tool)
            assert.is_true(Tools.is_inline(renderer, { batch_id = BATCH_ID }), tool)
            assert.is_function(renderer.inline_text, tool)
            assert.is_function(renderer.inline_status, tool)
        end
    end)
end)
