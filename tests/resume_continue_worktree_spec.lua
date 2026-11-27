-- `:PiContinue` must keep recovering a worktree checkout that no longer exists.
--
-- `:PiResume` rows carry `worktree_info` (`Worktree.list` / snapshot store), so
-- `prepare_resume_target` can recreate a deleted checkout before the session is
-- opened. `:PiContinue` only holds a transcript path, and the reverse path
-- parser that used to bridge the gap is gone: it only understood
-- `<repo>/.worktrees/<name>` and returned nothing for any other layout, so it
-- could not be kept. The replacement carries the *current* session's worktree
-- metadata onto the target when the continued transcript was recorded in that
-- same checkout. That is the reachable case: a checkout deleted underneath a
-- running process (`rm -rf`, `git worktree remove --force` from a shell) leaves
-- transcripts whose recorded cwd is gone, and `Worktree.detect` cannot name a
-- repository from a directory that no longer exists.
--
-- Paths are compared, never parsed: a transcript recorded in another directory
-- is not handed worktree metadata it never had.

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")
local History = require("pi.sessions.history")
local Subsessions = require("pi.subsessions")
local Pi = require("pi")

Config.setup({})
Pi.setup({})

local real = {
    rpc_start = Rpc.start,
    rpc_stop = Rpc.stop,
    rpc_send = Rpc.send,
    parse = History.parse,
    list = History.list,
    notify = vim.notify,
    on_parent_resumed = Subsessions.on_parent_resumed,
    worktree = package.loaded["pi.worktree"],
}

---@type table[] notifications recorded while vim.notify is stubbed
local notes = {}

local function install_notify()
    notes = {}
    vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
end

---@param needle string
---@param level? integer
---@return table?
local function find_note(needle, level)
    for i = #notes, 1, -1 do
        local note = notes[i]
        if note.msg:find(needle, 1, true) and (level == nil or note.level == level) then
            return note
        end
    end
    return nil
end

local function wait_for(fn)
    assert(vim.wait(3000, fn, 10), "condition was not met in time")
end

---@param path string
---@return string
local function mkdir(path)
    vim.fn.mkdir(path, "p")
    return path
end

--- Canned RPC responses shared by the manager-driving specs.
---@param cmd table
---@return table
local function response_for(cmd)
    if cmd.type == "get_state" then
        return {
            type = "response",
            id = cmd.id,
            success = true,
            data = {
                sessionId = "sess-1",
                sessionFile = "/tmp/pi-continue-wt-spec/session.jsonl",
                model = { provider = "test", id = "m" },
                thinkingLevel = "medium",
                autoCompactionEnabled = false,
                messageCount = 1,
            },
        }
    elseif cmd.type == "get_commands" then
        return { type = "response", id = cmd.id, success = true, data = { commands = {} } }
    end
    return { type = "response", id = cmd.id, success = true, data = {} }
end

--- Install Rpc stubs; returns the collected start opts and sent commands.
---@return { starts: table[], commands: table[] }
local function install_rpc_stub()
    local state = { starts = {}, commands = {} }
    Rpc.start = function(self, opts)
        state.starts[#state.starts + 1] = vim.deepcopy(opts or {})
        self._job_id = 900 + #state.starts
        return true
    end
    Rpc.stop = function(self)
        self._job_id = nil
        self._pending = {}
    end
    Rpc.send = function(self, cmd, cb)
        state.commands[#state.commands + 1] = vim.deepcopy(cmd)
        if cb then
            vim.schedule(function()
                cb(response_for(cmd))
            end)
        end
        return true
    end
    return state
end

--- Stub the manager's RPC `get_state` to report an **empty** conversation:
--- the only state `:PiContinue` is allowed to replace, and the one a freshly
--- started worktree session is in when its checkout disappears.
---@param state { starts: table[], commands: table[] }
local function stub_empty_state(state)
    Rpc.send = function(self, cmd, cb)
        state.commands[#state.commands + 1] = vim.deepcopy(cmd)
        if cb then
            local res = response_for(cmd)
            if cmd.type == "get_state" then
                res.data.sessionId = "current-session"
                res.data.sessionFile = "/tmp/pi-continue-wt-spec/current.jsonl"
                res.data.messageCount = 0
                res.data.pendingMessageCount = 0
                res.data.isStreaming = false
            end
            vim.schedule(function()
                cb(res)
            end)
        end
        return true
    end
end

local function restore()
    -- Flush scheduled RPC/tab callbacks while the stubs are still installed.
    vim.wait(20)
    for _, live in ipairs(Sessions.list()) do
        if live.chat then
            pcall(function()
                live.chat:hide()
            end)
        end
    end
    vim.cmd("silent! only")
    Sessions._reset()
    require("pi.ui.workspace")._reset()
    Rpc.start = real.rpc_start
    Rpc.stop = real.rpc_stop
    Rpc.send = real.rpc_send
    History.parse = real.parse
    History.list = real.list
    vim.notify = real.notify
    Subsessions.on_parent_resumed = real.on_parent_resumed
    package.loaded["pi.worktree"] = real.worktree
    Config.setup({})
end

--- Repository + a managed checkout that is already gone, with a snapshot the
--- recovery can restore from. `recovered` is the same path as `gone` on
--- purpose: recovery recreates the checkout where it lived, so the target cwd
--- equals the path the live process already records.
---@return { repo: string, gone: string, recovered: string, patch: string }
local function dead_checkout()
    local repo = mkdir(vim.fn.tempname() .. "-repo")
    vim.fn.mkdir(repo .. "/.worktrees", "p")
    vim.fn.mkdir(repo .. "/.git/pi2-worktree-snapshots", "p")
    local patch = vim.fn.tempname() .. ".patch"
    vim.fn.writefile({ "SNAPSHOT-PATCH" }, patch)
    return {
        repo = repo,
        gone = repo .. "/.worktrees/gone",
        recovered = repo .. "/.worktrees/gone",
        patch = patch,
    }
end

--- Stub `pi.worktree` with the surface `prepare_resume_target` /
--- `recover_worktree` use, plus the call log the specs assert on.
---@param ctx { repo: string, gone: string, patch: string }
---@return table stub
local function install_worktree_stub(ctx)
    local stub = { created = {}, applied = nil }
    stub.detect = function(cwd)
        local norm = vim.fs.normalize(cwd)
        if norm == ctx.repo then
            return {
                kind = "main",
                name = "repo",
                path = ctx.repo,
                repo_root = ctx.repo,
                common_dir = ctx.repo .. "/.git",
            }
        end
        if norm == ctx.gone and vim.fn.isdirectory(norm) == 1 then
            return { kind = "linked", name = "gone", path = norm, repo_root = ctx.repo }
        end
        return nil
    end
    stub.list = function(_, cb)
        cb({}, nil)
    end
    stub.snapshot_worktrees = function()
        return {}
    end
    stub.worktrees_root = function(root)
        return root .. "/.worktrees"
    end
    stub.validate_name = function()
        return true
    end
    stub.latest_snapshot = function(root, name)
        if root ~= ctx.repo or name ~= "gone" then
            return nil, "unknown worktree"
        end
        return { path = ctx.patch, meta = { base_sha = "snapbase", name = "gone" } }
    end
    stub.create = function(opts, cb)
        stub.created[#stub.created + 1] = vim.deepcopy(opts)
        local path = ctx.repo .. "/.worktrees/" .. opts.name
        vim.fn.mkdir(path, "p")
        cb({ kind = "linked", name = opts.name, path = path, repo_root = ctx.repo }, nil)
    end
    stub.apply_patch = function(_, text, cb)
        stub.applied = text
        cb(true, nil)
    end
    stub.release = function(_, cb)
        cb(true)
    end
    stub.lock = function(_, _, cb)
        cb(true)
    end
    stub.bind = function(_, _, cb)
        cb(true)
    end
    package.loaded["pi.worktree"] = stub
    return stub
end

describe(":PiContinue into a session whose worktree is gone", function()
    local rpc_state

    before_each(function()
        install_notify()
        rpc_state = install_rpc_stub()
        Subsessions.on_parent_resumed = function() end
    end)

    after_each(restore)

    it("recovers the checkout instead of resuming in place", function()
        local ctx = dead_checkout()
        local stub = install_worktree_stub(ctx)
        local candidate_path = "/tmp/pi-continue-wt-spec/older.jsonl"
        local candidate = {
            id = "older",
            path = candidate_path,
            timestamp = "2025-01-01T00:00:00.000Z",
            first_message = "older work in the checkout",
            modified = 3,
            cwd = ctx.gone,
        }
        History.list = function(cwd)
            if vim.fs.normalize(tostring(cwd)) == ctx.gone then
                return { candidate }
            end
            return {}
        end
        History.parse = function(path)
            if path == candidate_path then
                return vim.deepcopy(candidate)
            end
            return real.parse(path)
        end
        stub_empty_state(rpc_state)

        -- The live session *is* the (now vanished) checkout: `rm -rf` or
        -- `git worktree remove --force` ran in a shell while it was running.
        local worktree_info = { kind = "linked", name = "gone", path = ctx.gone, repo_root = ctx.repo }
        local current = Sessions.get_or_create({ cwd = ctx.gone, worktree = worktree_info })
        assert.is_not_nil(current)
        assert.equals(ctx.gone, current.cwd)

        Sessions.continue_session()
        wait_for(function()
            return #stub.created == 1 and stub.applied ~= nil
        end)
        vim.wait(50)
        -- The checkout was recreated at its recorded path from the snapshot
        -- stored next to it: the continued transcript gets its workspace back
        -- instead of an in-place resume in a directory that does not exist.
        assert.equals("gone", stub.created[1].name)
        assert.equals(ctx.repo, stub.created[1].cwd)
        assert.equals("resume", stub.created[1].mode)
        assert.equals("snapbase", stub.created[1].base)
        assert.is_truthy(tostring(stub.applied):find("SNAPSHOT-PATCH", 1, true))
        assert.is_not_nil(find_note("Recovered worktree", vim.log.levels.INFO))
        local session = Sessions.get()
        assert.equals(ctx.recovered, session.cwd)
        assert.is_not_nil(session.worktree)
        assert.equals("gone", session.worktree.name)
        -- The process is *not* respawned: recovery restores the checkout at the
        -- path the live process already records, and `open_resume_target` only
        -- restarts on a cwd change. (Respawning here would also run the old
        -- session's release path against the freshly recreated checkout.) The
        -- transcript is switched into the running process instead.
        assert.equals(1, #rpc_state.starts)
        local switched = false
        for _, cmd in ipairs(rpc_state.commands) do
            if cmd.type == "switch_session" and cmd.sessionPath == candidate_path then
                switched = true
            end
        end
        assert.is_true(switched)
        os.remove(ctx.patch)
    end)

    it("does not invent worktree metadata for a transcript recorded elsewhere", function()
        local ctx = dead_checkout()
        local stub = install_worktree_stub(ctx)
        local elsewhere = vim.fn.tempname() .. "-old-project"
        local candidate_path = "/tmp/pi-continue-wt-spec/elsewhere.jsonl"
        local candidate = {
            id = "elsewhere",
            path = candidate_path,
            timestamp = "2025-01-01T00:00:00.000Z",
            first_message = "an old plain directory",
            modified = 3,
            cwd = elsewhere,
        }
        -- Listed under the checkout's workspace on purpose: the guard under
        -- test is the *recorded* cwd, not the directory the row was found in.
        History.list = function()
            return { candidate }
        end
        History.parse = function(path)
            if path == candidate_path then
                return vim.deepcopy(candidate)
            end
            return real.parse(path)
        end
        stub_empty_state(rpc_state)

        local worktree_info = { kind = "linked", name = "gone", path = ctx.gone, repo_root = ctx.repo }
        local current = Sessions.get_or_create({ cwd = ctx.gone, worktree = worktree_info })
        assert.is_not_nil(current)

        Sessions.continue_session()
        wait_for(function()
            local sent = false
            for _, cmd in ipairs(rpc_state.commands) do
                if cmd.type == "switch_session" then
                    sent = true
                end
            end
            return sent
        end)
        -- Nothing recreated, no restart: a plain vanished directory keeps the
        -- historical in-place continue.
        assert.equals(0, #stub.created)
        assert.equals(1, #rpc_state.starts)
        assert.equals(ctx.gone, Sessions.get().cwd)
    end)
end)
