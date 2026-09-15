-- Regression: a tool call whose name carries newlines must not abort the render.
--
-- Live case: a provider returned a toolCall whose `name` was the model's whole
-- reasoning block, e.g. "bash rebase --continue\n\nLet me first check the
-- state of the file ...". pi forwards it verbatim as
-- `tool_execution_start.toolName`, history.lua built the tool block header from
-- it, and `nvim_buf_set_lines` rejected the item ("'replacement string' item
-- contains newlines") inside a `vim.schedule` callback — the block (and the
-- whole scheduled render step) was lost with a hard error.
--
-- Two layers now guard this:
--   1. tool labels/details are flattened before they are measured for extmarks;
--   2. `_append_lines` / `_insert_lines` flatten newlines at the buffer write
--      boundary, so no future caller can reintroduce the crash.

local Config = require("pi.config")
local History = require("pi.ui.chat.history")
local Manager = require("pi.sessions.manager")

local TAB = 913
local POISON = "bash rebase --continue\n\nLet me first check the state of the file"

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function dump(buf)
    return table.concat(lines_of(buf), "\n")
end

--- Run `fn` with `vim.schedule` captured, then execute every captured callback,
--- collecting any error. This mirrors the live failure: the error was raised
--- inside the scheduled `on_tool_start` closure, not by the caller.
---@param fn fun()
---@return string[] errors
local function run_scheduled(fn)
    local captured = {}
    local real = vim.schedule
    vim.schedule = function(cb)
        captured[#captured + 1] = cb
    end
    local ok, err = pcall(fn)
    vim.schedule = real
    local errors = {}
    if not ok then
        errors[#errors + 1] = tostring(err)
    end
    for _, cb in ipairs(captured) do
        local cok, cerr = pcall(cb)
        if not cok then
            errors[#errors + 1] = tostring(cerr)
        end
    end
    return errors
end

--- A History used as a session's chat, enough for Manager.handle_event routing.
---@return pi.ChatHistory
local function new_history()
    local h = History.new(TAB)
    h._blocks_expanded = true
    return h
end

---@return pi.Session
local function session_with(h)
    return {
        id = "tool-name-newline",
        chat = h,
        changed_files = {},
        rpc = {
            is_running = function()
                return true
            end,
            send = function()
                return true
            end,
        },
    }
end

describe("tool name containing newlines", function()
    before_each(function()
        Config.options.render = { engine = "builtin" }
    end)

    after_each(function()
        Config.options.render = { engine = "builtin" }
        require("pi.ui.render")._reset()
    end)

    it("renders a standard tool block from a tool_execution_start event", function()
        local h = new_history()
        local session = session_with(h)
        local errors = run_scheduled(function()
            Manager.handle_event(session, {
                type = "tool_execution_start",
                toolName = POISON,
                toolCallId = "call_1",
                args = { command = "git status" },
            })
        end)
        assert.are.same({}, errors)

        local rows = 0
        for _, line in ipairs(lines_of(h:buf())) do
            if line:find("bash rebase --continue", 1, true) then
                rows = rows + 1
            end
        end
        assert.are.equal(1, rows, "the flattened name must occupy exactly one line:\n" .. dump(h:buf()))
    end)

    it("renders an inline tool block whose detail carries newlines", function()
        local h = new_history()
        local errors = run_scheduled(function()
            h:on_tool_start("dispatch_subagents", "call_2", {
                wait = true,
                items = { { name = "first\nsecond", task = "do something" } },
            })
        end)
        assert.are.same({}, errors)
        assert.is_truthy(dump(h:buf()):find("first second", 1, true), dump(h:buf()))
    end)

    it("flattens newlines in _append_lines", function()
        local h = new_history()
        local ok, err = pcall(function()
            h:_append_lines({ "a\nb" })
        end)
        assert.is_true(ok, tostring(err))
        assert.are.equal("a b", lines_of(h:buf())[1])
    end)

    it("flattens newlines in _insert_lines", function()
        local h = new_history()
        h:_append_lines({ "first" })
        local ok, err = pcall(function()
            h:_insert_lines(0, { "x\ny" })
        end)
        assert.is_true(ok, tostring(err))
        assert.are.equal("x y", lines_of(h:buf())[1])
    end)
end)
