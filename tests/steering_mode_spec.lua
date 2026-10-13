-- :PiSteeringMode / :PiFollowUpMode and the pi.set_steering_mode /
-- pi.set_follow_up_mode public API. These specs drive the session manager
-- against a stubbed Rpc: no real pi process, canned responses.

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")
local Pi = require("pi")

Config.setup({})
Pi.setup({})

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }

--- Commands sent through the stub, in order.
local sent = {}
--- type -> fun(cmd): pi.RpcEvent; nil responder = never answered.
local responders = {}
--- vim.notify spy records.
local notes = {}

local function install_stub()
    sent = {}
    responders = {}
    notes = {}

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

    responders.get_commands = function()
        return { type = "response", success = true, data = { commands = {} } }
    end
    responders.get_state = function()
        return {
            type = "response",
            success = true,
            data = { steeringMode = "one-at-a-time", followUpMode = "one-at-a-time" },
        }
    end
    responders.set_steering_mode = function(cmd)
        return { type = "response", success = true, data = { mode = cmd.mode } }
    end
    responders.set_follow_up_mode = function(cmd)
        return { type = "response", success = true, data = { mode = cmd.mode } }
    end
end

local function restore_stub()
    Sessions.stop()
    Rpc.start = real_rpc.start
    Rpc.stop = real_rpc.stop
    Rpc.send = real_rpc.send
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

--- Last recorded notification.
local function last_note()
    return notes[#notes]
end

--- Wait for any notification whose message contains `needle`.
---@return table? note
local function wait_note(needle)
    local found
    wait_or_fail(function()
        for _, note in ipairs(notes) do
            if note.msg:find(needle, 1, true) then
                found = note
                return true
            end
        end
        return false
    end, "no notification containing " .. needle)
    return found
end

--- Create a session and wait for its startup commands to settle.
local function new_session()
    local session = Sessions.get_or_create()
    assert.is_not_nil(session)
    wait_or_fail(function()
        return #sent > 0
    end, "session startup commands were not sent")
    return session
end

describe("steering / follow-up queue modes", function()
    before_each(function()
        install_stub()
    end)

    after_each(function()
        restore_stub()
    end)

    it("registers the :PiSteeringMode and :PiFollowUpMode user commands", function()
        local cmds = vim.api.nvim_get_commands({})
        assert.is_not_nil(cmds["PiSteeringMode"])
        assert.is_not_nil(cmds["PiFollowUpMode"])
    end)

    it("rejects an invalid steering mode without sending a command", function()
        Pi.set_steering_mode("bogus")
        local note = last_note()
        assert.is_not_nil(note)
        assert.are.equal(vim.log.levels.ERROR, note.level)
        assert.is_not_nil(note.msg:find('must be "all" or "one-at-a-time"', 1, true))
        assert.is_nil(select(1, find_after(0, "set_steering_mode")))
    end)

    it("rejects an invalid follow-up mode without sending a command", function()
        Pi.set_follow_up_mode("sometimes")
        local note = last_note()
        assert.is_not_nil(note)
        assert.are.equal(vim.log.levels.ERROR, note.level)
        assert.is_not_nil(note.msg:find('must be "all" or "one-at-a-time"', 1, true))
        assert.is_nil(select(1, find_after(0, "set_follow_up_mode")))
    end)

    it("warns and sends nothing when there is no active session", function()
        Pi.set_steering_mode("all")
        local note = last_note()
        assert.is_not_nil(note)
        assert.are.equal(vim.log.levels.WARN, note.level)
        assert.is_not_nil(note.msg:find("No active session", 1, true))
        assert.is_nil(select(1, find_after(0, "set_steering_mode")))
    end)

    it("sends set_steering_mode with the requested mode", function()
        local session = new_session()
        assert.is_true(session.rpc:is_running())

        local from = #sent
        Pi.set_steering_mode("all")

        local cmd
        wait_or_fail(function()
            cmd = select(1, find_after(from, "set_steering_mode"))
            return cmd ~= nil
        end, "set_steering_mode was not sent")
        assert.are.equal("all", cmd.mode)

        local note = wait_note("Steering mode")
        assert.are.equal(vim.log.levels.INFO, note.level)
        assert.is_not_nil(note.msg:find("Steering mode: all", 1, true))
    end)

    it("sends set_follow_up_mode with the requested mode", function()
        local session = new_session()
        assert.is_true(session.rpc:is_running())

        local from = #sent
        Pi.set_follow_up_mode("one-at-a-time")

        local cmd
        wait_or_fail(function()
            cmd = select(1, find_after(from, "set_follow_up_mode"))
            return cmd ~= nil
        end, "set_follow_up_mode was not sent")
        assert.are.equal("one-at-a-time", cmd.mode)

        local note = wait_note("Follow-up mode")
        assert.are.equal(vim.log.levels.INFO, note.level)
        assert.is_not_nil(note.msg:find("Follow-up mode: one-at-a-time", 1, true))
    end)

    it("surfaces a failed set command", function()
        new_session()
        responders.set_steering_mode = function()
            return { type = "response", success = false, error = "locked" }
        end

        Pi.set_steering_mode("all")
        local note = wait_note("Failed to set steering mode")
        assert.are.equal(vim.log.levels.ERROR, note.level)
        assert.is_not_nil(note.msg:find("locked", 1, true))
    end)

    it("reports a send failure", function()
        new_session()
        local original = Rpc.send
        Rpc.send = function()
            return false
        end
        Pi.set_steering_mode("all")
        Rpc.send = original

        local note = last_note()
        assert.is_not_nil(note)
        assert.are.equal(vim.log.levels.ERROR, note.level)
        assert.is_not_nil(note.msg:find("Failed to send steering mode command", 1, true))
    end)

    it("sets the mode from a command argument", function()
        new_session()

        local from = #sent
        vim.cmd("PiSteeringMode all")

        local cmd
        wait_or_fail(function()
            cmd = select(1, find_after(from, "set_steering_mode"))
            return cmd ~= nil
        end, "set_steering_mode was not sent")
        assert.are.equal("all", cmd.mode)
    end)

    it("cycles steering one-at-a-time -> all when no argument is given", function()
        new_session()

        local from = #sent
        vim.cmd("PiSteeringMode")

        local state = select(1, find_after(from, "get_state"))
        assert.is_not_nil(state, "cycle did not read get_state")

        local cmd
        wait_or_fail(function()
            cmd = select(1, find_after(from, "set_steering_mode"))
            return cmd ~= nil
        end, "set_steering_mode was not sent")
        assert.are.equal("all", cmd.mode)
    end)

    it("cycles steering all -> one-at-a-time when no argument is given", function()
        responders.get_state = function()
            return {
                type = "response",
                success = true,
                data = { steeringMode = "all", followUpMode = "all" },
            }
        end
        new_session()

        local from = #sent
        vim.cmd("PiSteeringMode")

        local cmd
        wait_or_fail(function()
            cmd = select(1, find_after(from, "set_steering_mode"))
            return cmd ~= nil
        end, "set_steering_mode was not sent")
        assert.are.equal("one-at-a-time", cmd.mode)
    end)

    it("cycles follow-up mode using the followUpMode field", function()
        responders.get_state = function()
            return {
                type = "response",
                success = true,
                data = { steeringMode = "one-at-a-time", followUpMode = "all" },
            }
        end
        new_session()

        local from = #sent
        vim.cmd("PiFollowUpMode")

        local cmd
        wait_or_fail(function()
            cmd = select(1, find_after(from, "set_follow_up_mode"))
            return cmd ~= nil
        end, "set_follow_up_mode was not sent")
        assert.are.equal("one-at-a-time", cmd.mode)
    end)

    it("reports a failed get_state during cycling and sends no set command", function()
        responders.get_state = function()
            return { type = "response", success = false, error = "no state" }
        end
        new_session()

        local from = #sent
        vim.cmd("PiSteeringMode")

        local note = wait_note("Failed to read steering mode")
        assert.are.equal(vim.log.levels.ERROR, note.level)
        assert.is_nil(select(1, find_after(from, "set_steering_mode")))
    end)
end)
