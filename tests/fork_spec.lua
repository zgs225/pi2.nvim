-- :PiFork / :PiClone — fork starts a new session from a past user message
-- (get_fork_messages picker → fork RPC → prompt prefill + reload); clone
-- duplicates the current active branch into a new session (clone RPC →
-- reload, no picker, no prefill). Both rebind the session to the new file and
-- can be cancelled by a session_before_fork extension handler (cancelled
-- response → silent no-op). These specs drive the session manager against a
-- stubbed Rpc with canned responses — no real pi process.

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")
local Pi = require("pi")

Config.setup({})
Pi.setup({})

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }
local real_notify = vim.notify
local real_select = vim.ui.select

--- Commands sent through the stub, in order.
local sent = {}
--- type -> fun(cmd): pi.RpcEvent; nil responder = never answered.
local responders = {}
--- vim.notify spy records.
local notes = {}
--- vim.ui.select spy: calls and a one-shot answer() for the pending picker.
local select_spy

local function install_stub()
    sent = {}
    responders = {}
    notes = {}
    select_spy = { calls = {}, pending = nil }

    Rpc.start = function(self)
        self._job_id = 999
        return true
    end
    Rpc.stop = function(self)
        self._job_id = nil
        self._pending = {}
    end
    Rpc.send = function(self, cmd, callback)
        if not self._job_id then
            return false
        end
        if not cmd.id then
            cmd.id = self._tab .. ":" .. self._req_id
            self._req_id = self._req_id + 1
        end
        sent[#sent + 1] = vim.deepcopy(cmd)
        local responder = responders[cmd.type]
        if callback and responder then
            local res = responder(cmd)
            vim.schedule(function()
                callback(res)
            end)
        end
        return true
    end

    vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
    end

    vim.ui.select = function(items, opts, on_choice)
        select_spy.calls[#select_spy.calls + 1] = { items = items, opts = opts, on_choice = on_choice }
        select_spy.pending = on_choice
    end

    responders.get_commands = function()
        return { type = "response", success = true, data = { commands = {} } }
    end
    responders.get_state = function()
        return {
            type = "response",
            success = true,
            data = { model = { provider = "test", id = "m" }, autoCompactionEnabled = false },
        }
    end
    responders.get_fork_messages = function()
        return {
            type = "response",
            success = true,
            data = {
                messages = {
                    { entryId = "msg-1", text = "first ask" },
                    { entryId = "msg-2", text = "second ask" },
                },
            },
        }
    end
    responders.fork = function(_cmd)
        return { type = "response", success = true, data = { text = "rewritten ask", cancelled = false } }
    end
    responders.clone = function()
        return { type = "response", success = true, data = { cancelled = false } }
    end
    responders.get_messages = function()
        return {
            type = "response",
            success = true,
            data = {
                messages = {
                    { role = "user", content = "original ask" },
                    { role = "assistant", content = "original answer" },
                },
            },
        }
    end
end

local function restore_stub()
    Sessions.stop()
    Rpc.start = real_rpc.start
    Rpc.stop = real_rpc.stop
    Rpc.send = real_rpc.send
    vim.notify = real_notify
    vim.ui.select = real_select
end

--- Wait until fn() is truthy; fail the spec with `what` otherwise.
local function wait_or_fail(fn, what)
    assert(vim.wait(3000, fn, 10), what)
end

--- First command of `type` sent after index `from` (0 = from start).
---@return table? cmd
---@return integer idx
local function find_after(from, type)
    for i = from + 1, #sent do
        if sent[i].type == type then
            return sent[i], i
        end
    end
    return nil, #sent
end

--- Latest notification containing a substring (Notify prefixes messages
--- with "π │ ", so exact matches on the raw message never hit).
---@param needle string
---@return table?
local function find_note_containing(needle)
    for i = #notes, 1, -1 do
        if notes[i].msg:find(needle, 1, true) then
            return notes[i]
        end
    end
    return nil
end

--- Create the current tab's session and wait for the initial commands
--- (get_commands / get_state) to be sent.
---@return pi.Session
local function open_session()
    local session = Sessions.get_or_create()
    assert.is_not_nil(session)
    wait_or_fail(function()
        return #sent > 0
    end, "initial session commands were not sent")
    return session
end

--- Lines of a buffer (trimmed).
---@param buf integer
---@return string[]
local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Exact match on the trimmed line (user-message bodies render indented).
---@param buf integer
---@param line string
---@return boolean
local function buf_has_exact_line(buf, line)
    for _, l in ipairs(lines_of(buf)) do
        if vim.trim(l) == line then
            return true
        end
    end
    return false
end

describe("pi fork / clone", function()
    before_each(function()
        install_stub()
    end)

    after_each(function()
        restore_stub()
    end)

    it("registers the :PiFork and :PiClone user commands", function()
        local cmds = vim.api.nvim_get_commands({})
        assert.is_not_nil(cmds["PiFork"])
        assert.is_not_nil(cmds["PiClone"])
    end)

    it("warns and sends nothing without an active session", function()
        Pi.fork()
        assert.are.equal(0, #sent)
        assert.are.equal(1, #notes)
        assert.are.equal(vim.log.levels.WARN, notes[1].level)

        notes = {}
        Pi.clone()
        assert.are.equal(0, #sent)
        assert.are.equal(vim.log.levels.WARN, notes[1].level)
    end)

    it("fetches forkable user messages and opens the picker with the fork kind", function()
        local session = open_session()
        local from = #sent

        Pi.fork()
        wait_or_fail(function()
            return select(1, find_after(from, "get_fork_messages")) ~= nil
        end, "get_fork_messages was not sent")

        wait_or_fail(function()
            return #select_spy.calls > 0
        end, "fork picker did not open")
        local call = select_spy.calls[1]
        assert.are.equal("pi-fork-select", call.opts.kind)
        assert.are.same({ "[user] first ask", "[user] second ask" }, call.items)
        -- The picker being open means no fork command was sent yet.
        assert.is_nil(select(1, find_after(from, "fork")))
    end)

    it("notifies and sends nothing when there are no forkable messages", function()
        responders.get_fork_messages = function()
            return { type = "response", success = true, data = { messages = {} } }
        end
        local session = open_session()
        local from = #sent

        Pi.fork()
        wait_or_fail(function()
            return find_note_containing("No messages to fork from") ~= nil
        end, "no 'No messages to fork from' notification")
        assert.is_nil(select(1, find_after(from, "fork")))
        assert.are.equal(0, #select_spy.calls)
    end)

    it("forks from the picked message: prefill + reload, new session info", function()
        local session = open_session()
        local from = #sent

        Pi.fork()
        wait_or_fail(function()
            return #select_spy.calls > 0
        end, "fork picker did not open")
        select_spy.pending("[user] second ask")

        local fork_cmd
        wait_or_fail(function()
            fork_cmd = select(1, find_after(from, "fork"))
            return fork_cmd ~= nil
        end, "fork command was not sent")
        assert.are.equal("msg-2", fork_cmd.entryId)

        -- Success path reloads the new session's messages and prefills the
        -- prompt with the forked message text (mirrors the TUI's editor).
        wait_or_fail(function()
            return select(1, find_after(from, "get_messages")) ~= nil
        end, "get_messages reload was not sent after fork")
        wait_or_fail(function()
            return find_note_containing("Forked to new session") ~= nil
        end, "no 'Forked to new session' info")
        wait_or_fail(function()
            return session.chat._prompt:text() == "rewritten ask"
        end, "forked message text was not prefilled into the prompt")
        wait_or_fail(function()
            return buf_has_exact_line(session.chat._history:buf(), "original ask")
        end, "reloaded history does not contain the replayed user message")
        -- The replayed assistant answer follows.
        wait_or_fail(function()
            return buf_has_exact_line(session.chat._history:buf(), "original answer")
        end, "reloaded history does not contain the replayed assistant message")
    end)

    it("does not fork when the picker is cancelled", function()
        local session = open_session()
        local from = #sent

        Pi.fork()
        wait_or_fail(function()
            return #select_spy.calls > 0
        end, "fork picker did not open")
        select_spy.pending(nil)

        vim.wait(200, function() end, 10)
        assert.is_nil(select(1, find_after(from, "fork")))
        assert.is_nil(select(1, find_after(from, "get_messages")))
        assert.are.equal(0, #notes)
    end)

    it("is a silent no-op when an extension cancels the fork", function()
        responders.fork = function()
            return { type = "response", success = true, data = { text = "rewritten ask", cancelled = true } }
        end
        local session = open_session()
        local from = #sent

        Pi.fork()
        wait_or_fail(function()
            return #select_spy.calls > 0
        end, "fork picker did not open")
        select_spy.pending("[user] first ask")
        wait_or_fail(function()
            return select(1, find_after(from, "fork")) ~= nil
        end, "fork command was not sent")

        -- No reload, no prefill, no notification (cancelled is not an error).
        vim.wait(200, function() end, 10)
        assert.is_nil(select(1, find_after(from, "get_messages")))
        assert.are.equal("", session.chat._prompt:text())
        assert.are.equal(0, #notes)
    end)

    it("surfaces a failed fork and does not reload", function()
        responders.fork = function()
            return { type = "response", success = false, error = "fork locked by provider" }
        end
        local session = open_session()
        local from = #sent

        Pi.fork()
        wait_or_fail(function()
            return #select_spy.calls > 0
        end, "fork picker did not open")
        select_spy.pending("[user] first ask")
        wait_or_fail(function()
            return select(1, find_after(from, "fork")) ~= nil
        end, "fork command was not sent")

        wait_or_fail(function()
            return find_note_containing("fork locked by provider") ~= nil
        end, "no error notification for the failed fork")
        assert.are.equal(vim.log.levels.ERROR, find_note_containing("fork locked by provider").level)
        assert.is_nil(select(1, find_after(from, "get_messages")))
    end)

    it("clones the current branch: reload, no picker, no prefill", function()
        local session = open_session()
        local from = #sent

        Pi.clone()
        wait_or_fail(function()
            return select(1, find_after(from, "clone")) ~= nil
        end, "clone command was not sent")

        wait_or_fail(function()
            return select(1, find_after(from, "get_messages")) ~= nil
        end, "get_messages reload was not sent after clone")
        wait_or_fail(function()
            return find_note_containing("Cloned to new session") ~= nil
        end, "no 'Cloned to new session' info")
        -- The duplicated branch replays identically.
        wait_or_fail(function()
            return buf_has_exact_line(session.chat._history:buf(), "original ask")
        end, "reloaded history does not contain the cloned user message")
        -- No selector, no prompt prefill for clone.
        assert.are.equal(0, #select_spy.calls)
        assert.are.equal("", session.chat._prompt:text())
    end)

    it("is a silent no-op when an extension cancels the clone", function()
        responders.clone = function()
            return { type = "response", success = true, data = { cancelled = true } }
        end
        local session = open_session()
        local from = #sent

        Pi.clone()
        wait_or_fail(function()
            return select(1, find_after(from, "clone")) ~= nil
        end, "clone command was not sent")

        vim.wait(200, function() end, 10)
        assert.is_nil(select(1, find_after(from, "get_messages")))
        assert.are.equal(0, #notes)
    end)

    it("surfaces a failed clone and does not reload", function()
        responders.clone = function()
            return { type = "response", success = false, error = "cannot clone: no entries" }
        end
        local session = open_session()
        local from = #sent

        Pi.clone()
        wait_or_fail(function()
            return select(1, find_after(from, "clone")) ~= nil
        end, "clone command was not sent")

        wait_or_fail(function()
            return find_note_containing("cannot clone") ~= nil
        end, "no error notification for the failed clone")
        assert.is_nil(select(1, find_after(from, "get_messages")))
    end)

    it("intercepts a bare /fork prompt locally", function()
        local session = open_session()
        local from = #sent

        vim.api.nvim_buf_set_lines(session.chat._prompt:buf(), 0, -1, false, { "/fork" })
        session.chat:_send_message(nil)

        wait_or_fail(function()
            return select(1, find_after(from, "get_fork_messages")) ~= nil
        end, "bare /fork was not intercepted as get_fork_messages")
        -- The command consumed the prompt and was not submitted as a prompt.
        assert.are.equal("", session.chat._prompt:text())
        assert.is_nil(select(1, find_after(from, "prompt")))
        -- Drain the async response chain inside the test: the response
        -- callback opens the (stubbed) picker; letting it fire after the
        -- test would hit the restored real vim.ui.select.
        wait_or_fail(function()
            return #select_spy.calls > 0
        end, "fork picker did not open for intercepted /fork")
    end)

    it("intercepts a bare /clone prompt locally", function()
        local session = open_session()
        local from = #sent

        vim.api.nvim_buf_set_lines(session.chat._prompt:buf(), 0, -1, false, { "/clone" })
        session.chat:_send_message(nil)

        wait_or_fail(function()
            return select(1, find_after(from, "clone")) ~= nil
        end, "bare /clone was not intercepted as clone RPC")
        assert.are.equal("", session.chat._prompt:text())
        assert.is_nil(select(1, find_after(from, "prompt")))
        -- Drain the whole clone response chain (reload -> replay) inside the
        -- test; like the /fork picker, a straggler would touch restored
        -- stubs after the test ends.
        wait_or_fail(function()
            return buf_has_exact_line(session.chat._history:buf(), "original ask")
        end, "intercepted /clone did not replay the cloned branch")
    end)
end)
