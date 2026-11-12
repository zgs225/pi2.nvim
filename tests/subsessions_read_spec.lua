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

    -- pi persists a provider/quota/auth failure as an assistant message with
    -- `stopReason: "error"` and no content; "last entry is an assistant
    -- message → completed" booked those dead runs as successes.
    it("infer_run_status reads the stop reason, not just the role", function()
        local path = vim.fn.tempname() .. ".jsonl"
        write_jsonl(path, {
            { type = "message", message = { role = "user", content = "go" } },
            {
                type = "message",
                message = { role = "assistant", content = {}, stopReason = "error", errorMessage = "429: quota" },
            },
        })
        assert.equals("failed", Read.infer_run_status(path))

        write_jsonl(path, {
            { type = "message", message = { role = "assistant", content = {}, stopReason = "aborted" } },
        })
        assert.equals("interrupted", Read.infer_run_status(path))
        os.remove(path)
    end)

    it("last_turn returns text, stop reason and provider error in one pass", function()
        local path = vim.fn.tempname() .. ".jsonl"
        write_jsonl(path, {
            { type = "message", message = { role = "assistant", content = "first", stopReason = "stop" } },
            { type = "message", message = { role = "user", content = "go on" } },
        })
        assert.equals("first", Read.last_turn(path).text)
        assert.equals("stop", Read.last_turn(path).stop_reason)
        assert.is_nil(Read.last_turn(path).error_message)

        write_jsonl(path, {
            {
                type = "message",
                message = {
                    role = "assistant",
                    content = {},
                    stopReason = "error",
                    errorMessage = "429: insufficient_quota",
                },
            },
        })
        local turn = Read.last_turn(path)
        assert.equals("", turn.text)
        assert.equals("error", turn.stop_reason)
        assert.equals("429: insufficient_quota", turn.error_message)
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

-- The startup status rebuild infers one manifest row per transcript, and it used
-- to decode every line of every file — seconds of blocked editor on the first
-- <leader>ap in a project with a large sessions tree (startup-cost iron rule in
-- AGENTS.md). The reader now walks each file backwards from its end, so these
-- specs pin both halves of that contract: the answer is still the trailing
-- entry's, and the work is bounded by the tail window, not by the file size.
describe("subsession JSONL tail reader", function()
    local function write_rows(path, rows)
        local f = assert(io.open(path, "w"))
        for _, row in ipairs(rows) do
            f:write(vim.json.encode(row) .. "\n")
        end
        f:close()
    end

    --- Run `fn` counting `vim.json.decode` calls (the reader's only per-line cost).
    ---@param fn fun()
    ---@return integer calls
    local function decodes(fn)
        local real = vim.json.decode
        local calls = 0
        vim.json.decode = function(...)
            calls = calls + 1
            return real(...)
        end
        local ok, err = pcall(fn)
        vim.json.decode = real
        assert(ok, err)
        return calls
    end

    it("reads the tail of a multi-megabyte transcript, not the whole file", function()
        local path = vim.fn.tempname() .. ".jsonl"
        local rows = { { type = "session", version = 3, id = "child-a" } }
        for i = 1, 120 do
            rows[#rows + 1] = {
                type = "message",
                message = { role = "user", content = string.rep("x", 20000) .. i },
            }
        end
        rows[#rows + 1] = { type = "message", message = { role = "assistant", content = "done" } }
        write_rows(path, rows)

        local status, calls
        calls = decodes(function()
            status = Read.infer_run_status(path)
        end)
        assert.equals("completed", status)
        assert.is_true(calls <= 4, "decoded " .. calls .. " lines for a 2.4 MB transcript")
        os.remove(path)
    end)

    it("walks further back when the tail holds no decisive entry", function()
        local path = vim.fn.tempname() .. ".jsonl"
        local rows = {
            { type = "session", version = 3, id = "child-b" },
            { type = "message", message = { role = "assistant", content = "done", stopReason = "error" } },
        }
        for i = 1, 40 do
            rows[#rows + 1] = { type = "session_info", name = "n" .. i, pad = string.rep("y", 20000) }
        end
        write_rows(path, rows)

        assert.equals("failed", Read.infer_run_status(path))
        os.remove(path)
    end)

    it("grows the window past a single line larger than the window", function()
        local path = vim.fn.tempname() .. ".jsonl"
        write_rows(path, {
            { type = "session", version = 3, id = "child-c" },
            { type = "tool_use", name = "bash" },
            { type = "session_info", name = "huge", pad = string.rep("z", 300000) },
        })

        assert.equals("interrupted", Read.infer_run_status(path))
        os.remove(path)
    end)

    it("skips a truncated trailing line, like the forward scan does", function()
        local path = vim.fn.tempname() .. ".jsonl"
        local f = assert(io.open(path, "w"))
        f:write(vim.json.encode({ type = "session", version = 3, id = "child-d" }) .. "\n")
        f:write(vim.json.encode({ type = "message", message = { role = "assistant", content = "d" } }) .. "\n")
        f:write('{"type":"message","message":{"role":"user","cont') -- torn write, no newline
        f:close()

        assert.equals("completed", Read.infer_run_status(path))
        os.remove(path)
    end)

    it("reads last_turn from the tail too", function()
        local path = vim.fn.tempname() .. ".jsonl"
        local rows = {}
        for i = 1, 80 do
            rows[#rows + 1] = { type = "message", message = { role = "user", content = string.rep("w", 20000) .. i } }
        end
        rows[#rows + 1] = {
            type = "message",
            message = { role = "assistant", content = "final", stopReason = "error", errorMessage = "429: quota" },
        }
        write_rows(path, rows)

        local turn, calls
        calls = decodes(function()
            turn = Read.last_turn(path)
        end)
        assert.equals("final", turn.text)
        assert.equals("error", turn.stop_reason)
        assert.equals("429: quota", turn.error_message)
        assert.is_true(calls <= 4, "decoded " .. calls .. " lines for a 1.6 MB transcript")
        os.remove(path)
    end)

    it("handles an empty file and a missing file", function()
        local path = vim.fn.tempname() .. ".jsonl"
        local f = assert(io.open(path, "w"))
        f:close()
        assert.is_nil(Read.infer_run_status(path))
        assert.is_nil(Read.last_turn(path))
        assert.is_nil(Read.infer_run_status(path .. ".missing"))
        os.remove(path)
    end)
end)
