-- Worktree plumbing owned by the sessions/RPC layer:
--   * Rpc:start passes opts.cwd to jobstart and PI_NVIM_WORKTREE_PATH in env,
--   * Cli.command appends opts.extra_args (session bootstrap flags),
--   * Sessions.get_or_create / create_detached resolve cwd before start, keep
--     session.cwd/worktree, follow cwd on view switches and session loads,
--   * close_session / stop / _process_exit release a worktree exactly once,
--     after the process stopped,
--   * pi.worktree_session orchestrates :PiWorktreeNew / :PiWorktreeFork /
--     :PiWorktreeBranch and surfaces failures through Notify.
--
-- The specs drive real manager code against stubbed Rpc + a stubbed
-- pi.worktree module: no pi process and no git checkouts.

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Cli = require("pi.cli")
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
    jobstart = vim.fn.jobstart,
    notify = vim.notify,
    select = vim.ui.select,
    parse = History.parse,
    list = History.list,
    on_parent_resumed = Subsessions.on_parent_resumed,
    on_child_settled = Subsessions.on_child_settled,
    worktree_integration = package.loaded["pi.worktree_integration"],
    get = Sessions.get,
    get_or_create = Sessions.get_or_create,
    worktree = package.loaded["pi.worktree"],
    quickfix_tool_end = require("pi.quickfix").on_tool_end,
    reload_file_changed = require("pi.reload").on_file_changed,
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
                sessionFile = "/tmp/pi-worktree-spec/session.jsonl",
                model = { provider = "test", id = "m" },
                thinkingLevel = "medium",
                autoCompactionEnabled = false,
                messageCount = 1,
            },
        }
    elseif cmd.type == "get_commands" then
        return { type = "response", id = cmd.id, success = true, data = { commands = {} } }
    elseif cmd.type == "switch_session" then
        return { type = "response", id = cmd.id, success = true, data = { cancelled = false } }
    elseif cmd.type == "get_messages" then
        return { type = "response", id = cmd.id, success = true, data = { messages = {} } }
    end
    return { type = "response", id = cmd.id, success = true, data = {} }
end

--- Install Rpc stubs; returns a table collecting start opts.
---@return { starts: table[], commands: table[], responded: fun(cmd: table, cb?: fun(res: table)) }
local function install_rpc_stub()
    -- Keep the real integration queue out of the specs: manager idle hooks may
    -- otherwise drain leftover real manifest rows and emit notifications.
    package.loaded["pi.worktree_integration"] = {
        on_parent_ready = function()
            return 0
        end,
    }
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

local function restore()
    -- Flush scheduled RPC callbacks while the stubs are still installed: a
    -- get_state answered asynchronously after a test body would otherwise fire
    -- inside the next test (and hit a different pi.worktree stub).
    vim.wait(20)
    Sessions.get = real.get
    Sessions.get_or_create = real.get_or_create
    Sessions._reset()
    Rpc.start = real.rpc_start
    Rpc.stop = real.rpc_stop
    Rpc.send = real.rpc_send
    vim.fn.jobstart = real.jobstart
    vim.notify = real.notify
    History.parse = real.parse
    History.list = real.list
    vim.ui.select = real.select
    Subsessions.on_parent_resumed = real.on_parent_resumed
    Subsessions.on_child_settled = real.on_child_settled
    package.loaded["pi.worktree_integration"] = real.worktree_integration
    package.loaded["pi.worktree"] = real.worktree
    require("pi.quickfix").on_tool_end = real.quickfix_tool_end
    require("pi.reload").on_file_changed = real.reload_file_changed
    Config.setup({})
end

---@param cmd string[]
---@return integer?
local function index_of(cmd, value)
    for i, arg in ipairs(cmd) do
        if arg == value then
            return i
        end
    end
    return nil
end

--- Minimal fake pi.Session for orchestration specs.
---@param overrides? table
---@return table
local function fake_session(overrides)
    local session = {
        id = "parent-1",
        cwd = "/repo",
        session_file = "/repo/sessions/one.jsonl",
    }
    session.chat = {
        stream = false,
        shown = 0,
        calls = {},
        user_messages = {},
        is_streaming = function(self)
            return self.stream == true
        end,
        ensure_shown_and_focus_prompt = function(self)
            self.shown = self.shown + 1
        end,
        -- Attention redraws look the current tab's session up asynchronously;
        -- a fake chat without these methods makes those scheduled callbacks
        -- error out (noise without a test failure).
        render_statusline = function() end,
        refresh_prompt_attention = function() end,
        set_status = function() end,
    }
    -- Surface driven by manager.reload_messages / replay_messages / refresh_state
    -- (the fork replay). Every call is recorded so a spec can prove that the
    -- backend history actually reached the chat buffer.
    for _, name in ipairs({
        "clear",
        "show_loading",
        "clear_placeholder",
        "set_replaying",
        "on_agent_start",
        "on_agent_end",
        "show_startup_block",
        "update_state",
    }) do
        session.chat[name] = function(self)
            self.calls[#self.calls + 1] = name
        end
    end
    session.chat.add_user_message = function(self, text, timestamp, images)
        self.calls[#self.calls + 1] = "add_user_message"
        self.user_messages[#self.user_messages + 1] = { text = text, timestamp = timestamp, images = images }
    end
    session.rpc = {
        running = true,
        is_running = function(self)
            return self.running == true
        end,
        send = function(_, cmd, cb)
            if cb then
                vim.schedule(function()
                    if cmd.type == "get_state" then
                        cb({
                            type = "response",
                            success = true,
                            data = {
                                sessionId = session.id,
                                sessionFile = session.session_file,
                                sessionName = "parent chat",
                                messageCount = 1,
                                isStreaming = false,
                            },
                        })
                    else
                        cb(response_for(cmd))
                    end
                end)
            end
            return true
        end,
    }
    for k, v in pairs(overrides or {}) do
        session[k] = v
    end
    return session
end

describe("Rpc:start cwd / worktree env / extra args", function()
    local jobstart_calls

    before_each(function()
        install_notify()
        jobstart_calls = {}
        vim.fn.jobstart = function(cmd, opts)
            jobstart_calls[#jobstart_calls + 1] = { cmd = cmd, opts = opts }
            return 4242
        end
    end)

    after_each(function()
        restore()
    end)

    it("passes cwd to jobstart and the worktree path in the env", function()
        local dir = mkdir(vim.fn.tempname() .. "-wt")
        local rpc = Rpc.new(1)
        assert.is_true(rpc:start({
            cwd = dir,
            worktree_path = "/tmp/some-worktree",
            extra_args = { "--fork", "/tmp/source.jsonl" },
        }))

        assert.equals(1, #jobstart_calls)
        local call = jobstart_calls[1]
        assert.equals(dir, call.opts.cwd)
        assert.equals("/tmp/some-worktree", call.opts.env.PI_NVIM_WORKTREE_PATH)
        local fork_at = index_of(call.cmd, "--fork")
        assert.is_not_nil(fork_at)
        assert.equals("/tmp/source.jsonl", call.cmd[fork_at + 1])
        assert.equals("rpc", call.cmd[#call.cmd])
        rpc._job_id = nil
    end)

    it("keeps the old behavior without cwd/worktree options", function()
        local rpc = Rpc.new(1)
        assert.is_true(rpc:start())
        local call = jobstart_calls[1]
        assert.is_nil(call.opts.cwd)
        assert.is_nil(call.opts.env.PI_NVIM_WORKTREE_PATH)
        rpc._job_id = nil
    end)

    it("fails with a clear message when the cwd does not exist", function()
        local rpc = Rpc.new(1)
        assert.is_false(rpc:start({ cwd = "/tmp/pi-nvim-no-such-dir-" .. tostring(vim.uv.hrtime()) }))
        assert.equals(0, #jobstart_calls)
        assert.is_not_nil(find_note("Working directory does not exist", vim.log.levels.ERROR))
    end)
end)

describe("Cli.command extra args", function()
    before_each(function()
        Config.setup({})
    end)

    after_each(function()
        Config.setup({})
    end)

    it("appends extra args before --mode rpc", function()
        local cmd = Cli.command({ extra_args = { "--fork", "/tmp/s.jsonl" } })
        local fork_at = index_of(cmd, "--fork")
        local mode_at = index_of(cmd, "--mode")
        assert.is_not_nil(fork_at)
        assert.is_not_nil(mode_at)
        assert.is_true(fork_at < mode_at)
        assert.equals("/tmp/s.jsonl", cmd[fork_at + 1])
    end)

    it("drops empty and non-string extra args", function()
        local cmd = Cli.command({ extra_args = { "", 42, "--fork", "/tmp/s.jsonl" } })
        assert.is_nil(index_of(cmd, ""))
        assert.is_not_nil(index_of(cmd, "--fork"))
    end)

    it("ignores a non-table extra_args", function()
        assert.does_not_error(function()
            Cli.command({ extra_args = "--fork" })
        end)
    end)
end)

describe("session cwd / worktree plumbing", function()
    local rpc_state

    before_each(function()
        install_notify()
        rpc_state = install_rpc_stub()
    end)

    after_each(function()
        restore()
    end)

    it("create_detached starts the process in opts.cwd and stores the worktree", function()
        local dir = mkdir(vim.fn.tempname() .. "-detached")
        local info = { name = "wt1", path = dir, repo_root = "/repo", base_sha = "abc" }
        local session = Sessions.create_detached(1, { cwd = dir, worktree = info })
        assert.is_not_nil(session)
        assert.equals(dir, session.cwd)
        assert.equals(info, session.worktree)
        assert.equals(dir, rpc_state.starts[1].cwd)
        assert.equals(dir, rpc_state.starts[1].worktree_path)
    end)

    it("create_detached defaults to Neovim's cwd and no worktree", function()
        local session = Sessions.create_detached(1)
        assert.is_not_nil(session)
        assert.equals(vim.fn.getcwd(), session.cwd)
        assert.is_nil(session.worktree)
        assert.equals(vim.fn.getcwd(), rpc_state.starts[1].cwd)
        assert.is_nil(rpc_state.starts[1].worktree_path)
    end)

    it("get_or_create honors opts.cwd and points the chat at it", function()
        local dir = mkdir(vim.fn.tempname() .. "-tab")
        local info = { name = "wt2", path = dir }
        local session = Sessions.get_or_create({ cwd = dir, worktree = info })
        assert.is_not_nil(session)
        assert.equals(dir, session.cwd)
        assert.equals(info, session.worktree)
        assert.equals(dir, session.chat._cwd)
        assert.equals(dir, rpc_state.starts[1].cwd)
    end)

    it("bind_chat_to_session updates the chat cwd on a view switch", function()
        local first = Sessions.get_or_create()
        assert.is_not_nil(first)
        local chat = first.chat
        assert.is_not_nil(chat)
        local dir = mkdir(vim.fn.tempname() .. "-switch")
        local other = Sessions.create_detached(1, { cwd = dir })
        assert.is_not_nil(other)

        local tab = vim.api.nvim_get_current_tabpage()
        Sessions.bind_chat(other, chat, tab)
        assert.equals(dir, chat._cwd)
        assert.equals(dir, other.cwd)
    end)

    it("bind() publishes the backend id/file once both are known", function()
        local bind_calls = {}
        package.loaded["pi.worktree"] = {
            bind = function(info, fields)
                bind_calls[#bind_calls + 1] = { info = info, fields = fields }
                return true
            end,
        }
        local dir = mkdir(vim.fn.tempname() .. "-bind")
        local info = { name = "wt3", path = dir }
        local session = Sessions.create_detached(1, { cwd = dir, worktree = info })
        assert.is_not_nil(session)
        -- Earlier specs in this describe leave scheduled get_state callbacks
        -- behind (Rpc stubs answer asynchronously), so wait for the call that
        -- belongs to THIS worktree instead of assuming call #1.
        local function own_call()
            for _, call in ipairs(bind_calls) do
                if call.info == info then
                    return call
                end
            end
            return nil
        end
        wait_for(function()
            return own_call() ~= nil
        end)
        local call = own_call()
        assert.equals("sess-1", call.fields.session_id)
        assert.equals("/tmp/pi-worktree-spec/session.jsonl", call.fields.session_file)
        package.loaded["pi.worktree"] = nil
    end)

    it("load_session adopts the cwd recorded in the session file", function()
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        local dir = mkdir(vim.fn.tempname() .. "-resume")
        History.parse = function(path)
            if path == "/tmp/pi-worktree-spec/resumed.jsonl" then
                return { id = "resumed-1", path = path, cwd = dir, timestamp = "2025-01-01T00:00:00Z", modified = 0 }
            end
            return real.parse(path)
        end
        Subsessions.on_parent_resumed = function() end

        Sessions.load_session_path(session, "/tmp/pi-worktree-spec/resumed.jsonl")
        wait_for(function()
            return session.cwd == dir and session.chat and session.chat._cwd == dir
        end)
    end)

    it("load_session never adopts a cwd that does not exist", function()
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        local before = session.cwd
        History.parse = function(path)
            if path == "/tmp/pi-worktree-spec/ghost.jsonl" then
                return {
                    id = "ghost-1",
                    path = path,
                    cwd = "/tmp/pi-worktree-spec/no-such-cwd-" .. tostring(vim.uv.hrtime()),
                    timestamp = "2025-01-01T00:00:00Z",
                    modified = 0,
                }
            end
            return real.parse(path)
        end
        Subsessions.on_parent_resumed = function() end

        local loaded = false
        Sessions.load_session_path(session, "/tmp/pi-worktree-spec/ghost.jsonl", function()
            loaded = true
        end)
        wait_for(function()
            return loaded
        end)
        assert.equals(before, session.cwd)
        assert.equals(before, session.chat._cwd)
    end)

    it("load_session prefers the process cwd over a different recorded cwd", function()
        local process_dir = mkdir(vim.fn.tempname() .. "-process")
        local file_dir = mkdir(vim.fn.tempname() .. "-recorded")
        local session = Sessions.get_or_create({ cwd = process_dir })
        assert.is_not_nil(session)
        assert.equals(process_dir, session._process_cwd)
        -- Simulate an earlier rebind that moved the anchor away from the cwd
        -- the backend process actually runs in.
        session.cwd = file_dir
        History.parse = function(path)
            if path == "/tmp/pi-worktree-spec/moved.jsonl" then
                return {
                    id = "moved-1",
                    path = path,
                    cwd = file_dir,
                    timestamp = "2025-01-01T00:00:00Z",
                    modified = 0,
                }
            end
            return real.parse(path)
        end
        Subsessions.on_parent_resumed = function() end

        local loaded = false
        Sessions.load_session_path(session, "/tmp/pi-worktree-spec/moved.jsonl", function()
            loaded = true
        end)
        wait_for(function()
            return loaded and session.cwd == process_dir and session.chat._cwd == process_dir
        end)
    end)

    it("load_session keeps a worktree path over a different recorded cwd", function()
        local worktree_dir = mkdir(vim.fn.tempname() .. "-wt")
        local file_dir = mkdir(vim.fn.tempname() .. "-recorded")
        local session = Sessions.get_or_create({ cwd = worktree_dir })
        assert.is_not_nil(session)
        -- Worktree fallback applies when no explicit process cwd was recorded.
        session._process_cwd = nil
        session.worktree = { name = "wt", path = worktree_dir }
        session.cwd = file_dir
        package.loaded["pi.worktree"] = {
            bind = function()
                return true
            end,
        }
        History.parse = function(path)
            if path == "/tmp/pi-worktree-spec/wt.jsonl" then
                return {
                    id = "wt-1",
                    path = path,
                    cwd = file_dir,
                    timestamp = "2025-01-01T00:00:00Z",
                    modified = 0,
                }
            end
            return real.parse(path)
        end
        Subsessions.on_parent_resumed = function() end

        local loaded = false
        Sessions.load_session_path(session, "/tmp/pi-worktree-spec/wt.jsonl", function()
            loaded = true
        end)
        wait_for(function()
            return loaded and session.cwd == worktree_dir
        end)
        package.loaded["pi.worktree"] = real.worktree
    end)

    it("passes the session cwd to quickfix and reload on tool end", function()
        local Quickfix = require("pi.quickfix")
        local Reload = require("pi.reload")
        local real_quickfix = Quickfix.on_tool_end
        local real_reload = Reload.on_file_changed
        local seen = {}
        Quickfix.on_tool_end = function(_, _, _, _, cwd)
            seen.quickfix = cwd
        end
        Reload.on_file_changed = function(_, cwd)
            seen.reload = cwd
        end

        local dir = mkdir(vim.fn.tempname() .. "-tool-cwd")
        local session = {
            id = "tool-cwd",
            cwd = dir,
            attention = { pending = {} },
            changed_files = {},
            _pending_file_change_args = { ["tc-1"] = { path = "a.txt" } },
            chat = { on_tool_end = function() end },
        }
        Sessions.handle_event(session, { type = "tool_execution_end", toolName = "grep", toolCallId = "tc-1" })
        wait_for(function()
            return seen.quickfix == dir and seen.reload == dir
        end)

        Quickfix.on_tool_end = real_quickfix
        Reload.on_file_changed = real_reload
    end)

    it("tags the crash manifest patch with the session workspace", function()
        local Manifest = require("pi.subsessions.manifest")
        local real_patch, real_workspace = Manifest.patch, Manifest.workspace
        local captured = {}
        Manifest.workspace = function(session)
            captured.session = session
            return "/ws-from-session"
        end
        Manifest.patch = function(id, patch, cwd)
            captured.id, captured.patch, captured.cwd = id, patch, cwd
            return true
        end
        Subsessions.on_child_settled = function() end

        local session = {
            id = "crash-1",
            parent_id = "parent-1",
            cwd = "/repo/.worktrees/wt",
            session_file = "/repo/.worktrees/wt/session.jsonl",
            attention = { pending = {} },
            changed_files = {},
            rpc = {
                is_running = function()
                    return false
                end,
                stop = function() end,
            },
        }
        Sessions._register_for_test(session)
        Sessions.handle_event(session, { type = "_process_exit", code = 1 })

        assert.equals("crash-1", captured.id)
        assert.equals("/ws-from-session", captured.cwd)
        assert.equals("failed", captured.patch.status)
        assert.equals(session, captured.session)

        Manifest.patch, Manifest.workspace = real_patch, real_workspace
    end)
end)

describe("cross-worktree resume", function()
    local rpc_state

    before_each(function()
        install_notify()
        rpc_state = install_rpc_stub()
    end)

    after_each(restore)

    it("re-binds worktree metadata after resuming a linked-cwd session", function()
        local dir = mkdir(vim.fn.tempname() .. "-rebind")
        local session = Sessions.get_or_create({ cwd = dir })
        assert.is_not_nil(session)
        assert.is_nil(session.worktree)
        local detected = { kind = "linked", name = "wt-rebind", path = dir, repo_root = "/repo" }
        local bind_calls = {}
        package.loaded["pi.worktree"] = {
            detect = function(cwd)
                return cwd == dir and detected or nil
            end,
            bind = function(info, fields)
                bind_calls[#bind_calls + 1] = { info = info, fields = fields }
            end,
        }
        Subsessions.on_parent_resumed = function() end

        local loaded = false
        Sessions.load_session_path(session, "/tmp/pi-worktree-spec/rebind.jsonl", function()
            loaded = true
        end)
        wait_for(function()
            return loaded and session.worktree == detected
        end)
        -- Wait for the bind that belongs to THIS detected checkout (the
        -- canned get_state responder may rewrite the session file path, which
        -- only the real backend keeps in sync).
        local function own_bind()
            for _, call in ipairs(bind_calls) do
                if call.info == detected then
                    return call
                end
            end
            return nil
        end
        wait_for(function()
            return own_bind() ~= nil
        end)
        local call = own_bind()
        assert.equals("sess-1", call.fields.session_id)
        assert.equals("string", type(call.fields.session_file))
    end)

    it("lists worktree sessions and restarts the process in that cwd", function()
        local old = Sessions.get_or_create()
        assert.is_not_nil(old)
        local repo = mkdir(vim.fn.tempname() .. "-repo")
        vim.fn.mkdir(repo .. "/.worktrees", "p")
        local dir = mkdir(repo .. "/.worktrees/wt1")
        local wt = { kind = "linked", name = "wt1", path = dir, repo_root = repo, base_sha = "base1" }
        local list_calls = 0
        package.loaded["pi.worktree"] = {
            detect = function(cwd)
                if cwd == vim.fn.getcwd() then
                    return { kind = "main", name = "repo", path = repo, repo_root = repo }
                end
                return cwd == dir and wt or nil
            end,
            list = function(_, cb)
                list_calls = list_calls + 1
                cb({ wt }, nil)
            end,
        }
        History.list = function(cwd)
            if cwd == dir then
                return {
                    {
                        id = "wt-session",
                        path = "/tmp/pi-worktree-spec/wt1.jsonl",
                        timestamp = "2025-01-01T00:00:00.000Z",
                        first_message = "worktree work",
                        modified = 2,
                        cwd = dir,
                    },
                }
            end
            return {}
        end
        Subsessions.on_parent_resumed = function() end

        local picked
        vim.ui.select = function(items, opts, on_choice)
            picked = { items = items, opts = opts }
            for _, item in ipairs(items) do
                if item.kind == "session" then
                    on_choice(item)
                    return
                end
            end
        end

        Sessions.resume_session()
        wait_for(function()
            return picked ~= nil
        end)
        assert.equals(1, list_calls)
        assert.equals(1, #picked.items)
        -- A single checkout stays flat: one session row, no group title and no
        -- per-row worktree suffix (the checkout is named only by a title row).
        assert.equals("session", picked.items[1].kind)
        assert.equals("wt1", picked.items[1].item.session.worktree)
        assert.equals("2025-01-01  worktree work", picked.opts.format_item(picked.items[1]))

        wait_for(function()
            local session = Sessions.get()
            return session ~= nil and session ~= old and session.cwd == dir
        end)
        local session = Sessions.get()
        assert.equals(dir, session.cwd)
        assert.equals(dir, session._process_cwd)
        assert.equals(wt, session.worktree)
        assert.equals(2, #rpc_state.starts)
        assert.equals(dir, rpc_state.starts[2].cwd)
        wait_for(function()
            for _, cmd in ipairs(rpc_state.commands) do
                if cmd.type == "switch_session" then
                    return true
                end
            end
            return false
        end)
    end)

    it("resumes in place when the process already runs in the target cwd", function()
        local repo = mkdir(vim.fn.tempname() .. "-repo")
        vim.fn.mkdir(repo .. "/.worktrees", "p")
        local dir = mkdir(repo .. "/.worktrees/wt1")
        local session = Sessions.get_or_create({ cwd = dir })
        assert.is_not_nil(session)
        local wt = { kind = "linked", name = "wt1", path = dir, repo_root = repo }
        package.loaded["pi.worktree"] = {
            detect = function(cwd)
                if cwd == vim.fn.getcwd() then
                    return { kind = "main", name = "repo", path = repo, repo_root = repo }
                end
                return cwd == dir and wt or nil
            end,
            list = function(_, cb)
                cb({ wt }, nil)
            end,
        }
        History.list = function(cwd)
            if cwd == dir then
                return {
                    {
                        id = "wt-session-2",
                        path = "/tmp/pi-worktree-spec/wt2.jsonl",
                        timestamp = "2025-01-01T00:00:00.000Z",
                        first_message = "again",
                        modified = 3,
                        cwd = dir,
                    },
                }
            end
            return {}
        end
        Subsessions.on_parent_resumed = function() end

        local picked
        vim.ui.select = function(items, _, on_choice)
            picked = items
            on_choice(items[1])
        end

        local starts_before = #rpc_state.starts
        Sessions.resume_session()
        wait_for(function()
            return picked ~= nil
        end)
        wait_for(function()
            for _, cmd in ipairs(rpc_state.commands) do
                if cmd.type == "switch_session" then
                    return true
                end
            end
            return false
        end)
        assert.equals(starts_before, #rpc_state.starts)
        assert.equals(session, Sessions.get())
        assert.equals(wt, session.worktree)
    end)

    it("notifies the integration engine when a parent settles", function()
        local calls = {}
        package.loaded["pi.worktree_integration"] = {
            on_parent_ready = function(session)
                calls[#calls + 1] = session
            end,
        }
        local parent = fake_session({ id = "parent-ready" })
        Sessions.handle_event(parent, { type = "agent_settled" })
        assert.equals(1, #calls)
        assert.equals(parent, calls[1])

        Subsessions.on_child_settled = function() end
        local child = fake_session({ id = "child-ready", parent_id = "parent-ready" })
        Sessions.handle_event(child, { type = "agent_settled" })
        assert.equals(1, #calls)
    end)
end)

describe("worktree release hooks", function()
    local release_calls

    before_each(function()
        install_notify()
        install_rpc_stub()
        release_calls = {}
        package.loaded["pi.worktree"] = {
            release = function(info, cb)
                release_calls[#release_calls + 1] = info
                if cb then
                    cb(false, "dirty")
                end
            end,
        }
    end)

    after_each(function()
        package.loaded["pi.worktree"] = nil
        restore()
    end)

    it("close_session releases once after the process stopped", function()
        local dir = mkdir(vim.fn.tempname() .. "-close")
        local info = { name = "c1", path = dir }
        local session = Sessions.create_detached(1, { cwd = dir, worktree = info })
        assert.is_not_nil(session)
        Sessions.close_session(session)
        wait_for(function()
            return #release_calls == 1
        end)
        assert.equals(info, release_calls[1])
        -- The later process-exit dispatch must not release a second time.
        Sessions.handle_event(session, { type = "_process_exit", code = 0 })
        vim.wait(50)
        assert.equals(1, #release_calls)
        assert.is_not_nil(find_note("Worktree kept", vim.log.levels.INFO))
    end)

    it("M.stop releases the current tab's worktree", function()
        local dir = mkdir(vim.fn.tempname() .. "-stop")
        local info = { name = "c2", path = dir }
        local session = Sessions.get_or_create({ cwd = dir, worktree = info })
        assert.is_not_nil(session)
        Sessions.stop()
        wait_for(function()
            return #release_calls == 1
        end)
        assert.equals(info, release_calls[1])
    end)

    it("an unexpected process exit releases the worktree", function()
        local dir = mkdir(vim.fn.tempname() .. "-exit")
        local info = { name = "c3", path = dir }
        local session = Sessions.create_detached(1, { cwd = dir, worktree = info })
        assert.is_not_nil(session)
        Sessions.handle_event(session, { type = "_process_exit", code = 1 })
        wait_for(function()
            return #release_calls == 1
        end)
        assert.equals(info, release_calls[1])
    end)

    it("does nothing for ordinary sessions", function()
        local session = Sessions.create_detached(1)
        assert.is_not_nil(session)
        Sessions.close_session(session)
        vim.wait(50)
        assert.equals(0, #release_calls)
    end)

    it("skips release when the checkout is already gone", function()
        local info = { name = "c4", path = mkdir(vim.fn.tempname() .. "-gone") }
        local session = Sessions.create_detached(1, { worktree = info })
        assert.is_not_nil(session)
        vim.fn.delete(info.path, "rf")
        Sessions.close_session(session)
        vim.wait(50)
        assert.equals(0, #release_calls)
    end)

    it("keeps the checkout while another live session uses the same cwd", function()
        local dir = mkdir(vim.fn.tempname() .. "-shared")
        local info = { name = "shared", path = dir }
        local session = Sessions.create_detached(1, { cwd = dir, worktree = info })
        assert.is_not_nil(session)
        local other = {
            id = "other-1",
            cwd = dir,
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        }
        Sessions._register_for_test(other)

        Sessions.close_session(session)
        vim.wait(50)
        assert.equals(0, #release_calls)
    end)

    it("keeps the checkout when another live session has it as process cwd", function()
        local dir = mkdir(vim.fn.tempname() .. "-shared-process")
        local info = { name = "shared2", path = dir }
        local session = Sessions.create_detached(1, { worktree = info })
        assert.is_not_nil(session)
        local other = {
            id = "other-2",
            cwd = "/elsewhere",
            _process_cwd = dir,
            rpc = {
                is_running = function()
                    return true
                end,
                stop = function() end,
            },
        }
        Sessions._register_for_test(other)

        Sessions.close_session(session)
        vim.wait(50)
        assert.equals(0, #release_calls)
    end)
end)

describe("worktree session orchestration", function()
    local worktree_stub
    local created
    local opened
    local fake_child

    before_each(function()
        install_notify()
        install_rpc_stub()
        created = {}
        opened = {}
        fake_child = fake_session({ id = "child-1", cwd = "/repo/.worktrees/wt" })

        worktree_stub = {
            create = function(opts, cb)
                created[#created + 1] = opts
                cb({ name = opts.name or "generated", path = "/repo/.worktrees/" .. (opts.name or "generated") }, nil)
            end,
            bind = function() end,
            release = function() end,
            branch = function(info, branch, cb)
                cb(true, nil)
            end,
        }
        package.loaded["pi.worktree"] = worktree_stub

        Sessions.get_or_create = function(opts)
            opened[#opened + 1] = opts
            fake_child.cwd = opts.cwd
            return fake_child
        end
    end)

    after_each(function()
        package.loaded["pi.worktree"] = nil
        restore()
    end)

    it("registers the :PiWorktree* commands and public API", function()
        local cmds = vim.api.nvim_get_commands({})
        assert.is_not_nil(cmds["PiWorktreeNew"])
        assert.is_not_nil(cmds["PiWorktreeFork"])
        assert.is_not_nil(cmds["PiWorktreeBranch"])
        assert.is_function(Pi.worktree_new)
        assert.is_function(Pi.worktree_fork)
        assert.is_function(Pi.worktree_branch)
    end)

    it(":PiWorktreeNew creates a worktree and starts a fresh session in it", function()
        Sessions.get = function()
            return fake_session()
        end

        require("pi.worktree_session").new({ name = "wt-new" })
        wait_for(function()
            return #opened > 0
        end)

        assert.equals(1, #created)
        assert.equals("/repo", created[1].cwd)
        assert.equals("new", created[1].mode)
        assert.equals("wt-new", created[1].name)
        assert.equals("/repo/.worktrees/wt-new", opened[1].cwd)
        assert.equals("/repo/.worktrees/wt-new", opened[1].worktree.path)
        assert.is_nil(opened[1].args)
        assert.equals(1, fake_child.chat.shown)
    end)

    it(":PiWorktreeNew surfaces create failures", function()
        worktree_stub.create = function(_, cb)
            cb(nil, "not a git repository")
        end
        require("pi.worktree_session").new({ name = "bad" })
        wait_for(function()
            return find_note("Failed to create worktree", vim.log.levels.ERROR) ~= nil
        end)
        assert.equals(0, #opened)
    end)

    it("refuses to nest a worktree inside a worktree session", function()
        Sessions.get = function()
            return fake_session({ worktree = { name = "outer", path = "/repo/.worktrees/outer" } })
        end
        require("pi.worktree_session").new({ name = "inner" })
        assert.is_not_nil(find_note("Nested worktrees are not supported", vim.log.levels.ERROR))
        assert.equals(0, #created)
    end)

    it("closes the fresh tab when the session process fails to start", function()
        Sessions.get = function()
            return nil
        end
        Sessions.get_or_create = function()
            return nil
        end
        local released = 0
        worktree_stub.release = function(_, cb)
            released = released + 1
            if type(cb) == "function" then
                cb(true, nil)
            end
        end

        local tabs_before = #vim.api.nvim_list_tabpages()
        require("pi.worktree_session").new({ name = "no-start" })
        wait_for(function()
            return released == 1
        end)
        vim.wait(50)
        assert.equals(tabs_before, #vim.api.nvim_list_tabpages())
        assert.is_not_nil(find_note("Failed to start a session in the worktree"))
    end)

    it(":PiWorktreeFork bootstraps the child with --fork and keeps the parent untouched", function()
        local parent = fake_session()
        Sessions.get = function()
            return parent
        end

        -- The forked child process already carries the parent's conversation;
        -- get_messages is how the client learns about it. Record what the child
        -- is asked and hand back one inherited user message.
        local child_send = fake_child.rpc.send
        local child_commands = {}
        fake_child.rpc.send = function(self, cmd, cb)
            child_commands[#child_commands + 1] = vim.deepcopy(cmd)
            if cmd.type == "get_messages" then
                if cb then
                    vim.schedule(function()
                        cb({
                            type = "response",
                            id = cmd.id,
                            success = true,
                            data = {
                                messages = { { role = "user", content = "forked question", timestamp = 1 } },
                            },
                        })
                    end)
                end
                return true
            end
            return child_send(self, cmd, cb)
        end

        require("pi.worktree_session").fork({ name = "wt-fork" })
        wait_for(function()
            return #opened > 0
        end)

        assert.equals(1, #created)
        assert.equals("fork", created[1].mode)
        assert.equals("/repo", created[1].cwd)
        assert.equals("/repo/.worktrees/wt-fork", opened[1].cwd)
        assert.same({ "--fork", "/repo/sessions/one.jsonl" }, opened[1].args)
        assert.equals("parent-1", fake_child.forked_from.session_id)
        assert.equals("/repo/sessions/one.jsonl", fake_child.forked_from.session_file)
        assert.equals("parent chat", fake_child.forked_from.name)
        assert.equals(fake_child.forked_from, opened[1].worktree.forked_from)
        assert.equals("parent-1", parent.id)

        -- A fresh chat buffer has to be told about the forked history, exactly
        -- like :PiFork does after its fork response.
        -- (a) the client asked the child backend for the inherited messages…
        wait_for(function()
            for _, cmd in ipairs(child_commands) do
                if cmd.type == "get_messages" then
                    return true
                end
            end
            return false
        end)
        -- (b) …and the replayed user message reached the chat buffer.
        wait_for(function()
            return #fake_child.chat.user_messages > 0
        end)
        assert.equals("forked question", fake_child.chat.user_messages[1].text)
    end)

    it(":PiWorktreeNew does not replay the parent's history into the child", function()
        Sessions.get = function()
            return fake_session()
        end

        require("pi.worktree_session").new({ name = "wt-no-replay" })
        wait_for(function()
            return #opened > 0
        end)
        vim.wait(50)

        -- Only a fork carries a backend history to replay; a brand-new session
        -- must not clear/refetch its chat.
        assert.same({}, fake_child.chat.calls)
    end)

    it(":PiWorktreeFork refuses while the source is streaming", function()
        local parent = fake_session()
        parent.chat.stream = true
        Sessions.get = function()
            return parent
        end
        require("pi.worktree_session").fork()
        assert.is_not_nil(find_note("Wait for the agent to finish", vim.log.levels.WARN))
        assert.equals(0, #created)
    end)

    it(":PiWorktreeFork refuses an empty conversation", function()
        local parent = fake_session({ session_file = nil })
        parent.rpc.send = function(_, cmd, cb)
            cb({
                type = "response",
                success = true,
                data = { sessionId = "parent-1", messageCount = 0, isStreaming = false },
            })
            return true
        end
        Sessions.get = function()
            return parent
        end
        require("pi.worktree_session").fork()
        wait_for(function()
            return find_note("Nothing to fork", vim.log.levels.WARN) ~= nil
        end)
        assert.equals(0, #created)
    end)

    it(":PiWorktreeFork refuses when cli.args already selects a session", function()
        Sessions.get = function()
            return fake_session()
        end
        Config.options.cli.args = { "--continue" }
        require("pi.worktree_session").fork()
        assert.is_not_nil(find_note("conflicts with --fork", vim.log.levels.ERROR))
        assert.equals(0, #created)
    end)

    it(":PiWorktreeBranch attaches the current worktree to a branch", function()
        local calls = {}
        worktree_stub.branch = function(info, branch, cb)
            calls[#calls + 1] = { info = info, branch = branch }
            cb(true, nil)
        end
        local info = { name = "wt-b", path = "/repo/.worktrees/wt-b" }
        Sessions.get = function()
            return fake_session({ worktree = info })
        end

        require("pi.worktree_session").branch("feat/isolation")
        wait_for(function()
            return find_note("Worktree branch", vim.log.levels.INFO) ~= nil
        end)
        assert.equals(1, #calls)
        assert.equals(info, calls[1].info)
        assert.equals("feat/isolation", calls[1].branch)
    end)

    it(":PiWorktreeBranch warns outside a worktree session", function()
        Sessions.get = function()
            return fake_session()
        end
        require("pi.worktree_session").branch("feat/x")
        assert.is_not_nil(find_note("not running in a worktree", vim.log.levels.WARN))
    end)
end)

describe("worktree discovery and continue for resume", function()
    local rpc_state

    before_each(function()
        install_notify()
        rpc_state = install_rpc_stub()
    end)

    after_each(restore)

    --- History.list stub with per-cwd sessions and a call counter.
    ---@param by_cwd table<string, table[]>
    ---@return table<string, integer> calls
    local function stub_history_list(by_cwd)
        local calls = {}
        History.list = function(cwd)
            calls[tostring(cwd)] = (calls[tostring(cwd)] or 0) + 1
            return by_cwd[cwd] or {}
        end
        return calls
    end

    it("discovers missing/prunable and snapshot-only worktrees without cd", function()
        local repo = mkdir(vim.fn.tempname() .. "-repo")
        vim.fn.mkdir(repo .. "/.worktrees", "p")
        vim.fn.mkdir(repo .. "/.git/pi2-worktree-snapshots", "p")
        local gone = repo .. "/.worktrees/gone"
        local snap = repo .. "/.worktrees/snapshot-only"
        local unmanaged = mkdir(vim.fn.tempname() .. "-dev-wt")
        local list_calls, snapshot_calls = 0, 0
        package.loaded["pi.worktree"] = {
            detect = function(cwd)
                if cwd == vim.fn.getcwd() then
                    return { kind = "main", name = "repo", path = repo, repo_root = repo, common_dir = repo .. "/.git" }
                end
                return nil
            end,
            list = function(_, cb)
                list_calls = list_calls + 1
                -- `list` now also reports prunable/missing checkouts; the
                -- snapshot row is duplicated here on purpose (dedupe check).
                cb({
                    { name = "gone", path = gone, repo_root = repo, prunable = true },
                    { name = "snapshot-only", path = snap, repo_root = repo },
                    -- Not under `<repo>/.worktrees/`: a developer checkout, not
                    -- a pi-managed worktree. Must stay out of the picker.
                    { name = "dev-wt", path = unmanaged, repo_root = repo },
                }, nil)
            end,
            snapshot_worktrees = function(_)
                snapshot_calls = snapshot_calls + 1
                return { { name = "snapshot-only", path = snap, repo_root = repo, base_sha = "snapbase" } }
            end,
        }
        local calls = stub_history_list({
            [gone] = {
                {
                    id = "s-gone",
                    path = "/tmp/pi-worktree-spec/gone.jsonl",
                    timestamp = "2025-01-01T00:00:00.000Z",
                    first_message = "gone work",
                    modified = 3,
                    cwd = gone,
                },
            },
            [snap] = {
                {
                    id = "s-snap",
                    path = "/tmp/pi-worktree-spec/snap.jsonl",
                    timestamp = "2025-01-02T00:00:00.000Z",
                    first_message = "snapshot work",
                    modified = 2,
                    cwd = snap,
                },
            },
            [unmanaged] = {
                {
                    id = "s-unmanaged",
                    path = "/tmp/pi-worktree-spec/unmanaged.jsonl",
                    timestamp = "2025-01-03T00:00:00.000Z",
                    first_message = "unmanaged",
                    modified = 4,
                    cwd = unmanaged,
                },
            },
        })

        local picked
        vim.ui.select = function(items, opts, on_choice)
            picked = { items = items, opts = opts }
            on_choice(nil)
        end

        Sessions.resume_session()
        wait_for(function()
            return picked ~= nil
        end)
        assert.equals(1, list_calls)
        assert.equals(1, snapshot_calls)
        assert.equals(1, calls[gone])
        assert.equals(1, calls[snap]) -- both sources deduped to one listing
        -- Two checkouts => one title row per checkout, each followed by its
        -- session row; row text never carries the worktree name.
        assert.equals(4, #picked.items)
        assert.is_nil(calls[unmanaged]) -- unmanaged linked checkout not listed
        assert.equals("group", picked.items[1].kind)
        assert.equals("󰙅 gone", picked.items[1].text)
        assert.equals("󰙅 gone", picked.opts.format_item(picked.items[1]))
        assert.equals("session", picked.items[2].kind)
        assert.equals("gone", picked.items[2].item.session.worktree)
        assert.equals("2025-01-01  gone work", picked.opts.format_item(picked.items[2]))
        assert.equals("group", picked.items[3].kind)
        assert.equals("󰙅 snapshot-only", picked.items[3].text)
        assert.equals("󰙅 snapshot-only", picked.opts.format_item(picked.items[3]))
        assert.equals("session", picked.items[4].kind)
        assert.equals("snapshot-only", picked.items[4].item.session.worktree)
        assert.equals("2025-01-02  snapshot work", picked.opts.format_item(picked.items[4]))
    end)

    it("recovers a deleted worktree from its snapshot and restarts there", function()
        local repo = mkdir(vim.fn.tempname() .. "-repo")
        vim.fn.mkdir(repo .. "/.worktrees", "p")
        vim.fn.mkdir(repo .. "/.git/pi2-worktree-snapshots", "p")
        local gone = repo .. "/.worktrees/gone"
        local patch = vim.fn.tempname() .. ".patch"
        vim.fn.writefile({ "SNAPSHOT-PATCH" }, patch)
        local applied
        package.loaded["pi.worktree"] = {
            detect = function(cwd)
                if cwd == vim.fn.getcwd() then
                    return { kind = "main", name = "repo", path = repo, repo_root = repo, common_dir = repo .. "/.git" }
                end
                return nil
            end,
            list = function(_, cb)
                cb({ { name = "gone", path = gone, repo_root = repo, prunable = true } }, nil)
            end,
            snapshot_worktrees = function()
                return {}
            end,
            validate_name = function()
                return true
            end,
            latest_snapshot = function(root, name)
                assert.equals(repo, root)
                assert.equals("gone", name)
                return { path = patch, meta = { base_sha = "snapbase", name = "gone" } }
            end,
            create = function(opts, cb)
                local path = repo .. "/.worktrees/" .. opts.name
                vim.fn.mkdir(path, "p")
                cb({ kind = "linked", name = opts.name, path = path, repo_root = repo }, nil)
            end,
            apply_patch = function(_, text, cb)
                applied = text
                cb(true, nil)
            end,
        }
        stub_history_list({
            [gone] = {
                {
                    id = "s-gone",
                    path = "/tmp/pi-worktree-spec/gone.jsonl",
                    timestamp = "2025-01-01T00:00:00.000Z",
                    first_message = "gone work",
                    modified = 3,
                    cwd = gone,
                },
            },
        })
        Subsessions.on_parent_resumed = function() end
        local picked
        vim.ui.select = function(items, _, on_choice)
            picked = items
            on_choice(items[1])
        end

        local old = Sessions.get_or_create()
        assert.is_not_nil(old)
        Sessions.resume_session()
        wait_for(function()
            return picked ~= nil
        end)
        wait_for(function()
            local session = Sessions.get()
            return session ~= nil and session.cwd == gone and applied ~= nil
        end)
        local session = Sessions.get()
        assert.equals(gone, session.cwd)
        assert.equals(gone, session._process_cwd)
        assert.is_truthy(applied:find("SNAPSHOT-PATCH", 1, true))
        assert.is_not_nil(find_note("Recovered worktree", vim.log.levels.INFO))
        os.remove(patch)
    end)

    it("clears stale worktree metadata when a resume lands outside a checkout", function()
        local dir = mkdir(vim.fn.tempname() .. "-plain")
        local session = Sessions.get_or_create({ cwd = dir })
        assert.is_not_nil(session)
        session.worktree = { kind = "linked", name = "stale", path = "/nope/wt" }
        package.loaded["pi.worktree"] = {
            detect = function()
                return nil
            end,
        }
        Subsessions.on_parent_resumed = function() end
        local loaded = false
        Sessions.load_session_path(session, "/tmp/pi-worktree-spec/plain.jsonl", function()
            loaded = true
        end)
        wait_for(function()
            return loaded and session.worktree == nil
        end)
    end)

    it("resumes from a worktree back into the main checkout (reverse resume)", function()
        local repo = mkdir(vim.fn.tempname() .. "-repo")
        vim.fn.mkdir(repo .. "/.worktrees", "p")
        local wt_dir = mkdir(repo .. "/.worktrees/wt1")
        local wt_info = { kind = "linked", name = "wt1", path = wt_dir, repo_root = repo }
        package.loaded["pi.worktree"] = {
            detect = function(cwd)
                if cwd == vim.fn.getcwd() then
                    return { kind = "main", name = "repo", path = repo, repo_root = repo, common_dir = repo .. "/.git" }
                end
                if cwd == wt_dir then
                    return wt_info
                end
                if cwd == repo then
                    return { kind = "main", name = "repo", path = repo, repo_root = repo, common_dir = repo .. "/.git" }
                end
                return nil
            end,
            list = function(_, cb)
                cb({}, nil)
            end,
            snapshot_worktrees = function()
                return {}
            end,
        }
        local main_item = {
            id = "main-session",
            path = "/tmp/pi-worktree-spec/main.jsonl",
            timestamp = "2025-01-06T00:00:00.000Z",
            first_message = "main work",
            modified = 5,
            cwd = repo,
        }
        History.list = function(cwd)
            if cwd == nil or cwd == vim.fn.getcwd() then
                return { main_item }
            end
            return {}
        end
        Subsessions.on_parent_resumed = function() end

        local current = Sessions.get_or_create({ cwd = wt_dir })
        assert.is_not_nil(current)
        assert.equals(wt_dir, current.cwd)
        local picked
        vim.ui.select = function(items, _, on_choice)
            picked = items
            on_choice(items[1])
        end

        Sessions.resume_session()
        wait_for(function()
            return picked ~= nil
        end)
        wait_for(function()
            local session = Sessions.get()
            return session ~= nil and session ~= current and session.cwd == repo
        end)
        local session = Sessions.get()
        assert.equals(repo, session.cwd)
        assert.equals(repo, session._process_cwd)
        assert.is_nil(session.worktree) -- non-linked cwd clears stale metadata
        assert.equals(2, #rpc_state.starts)
        assert.equals(repo, rpc_state.starts[2].cwd)
    end)

    it("continue lists the process cwd, not Neovim's cwd", function()
        local nvim_cwd = vim.fn.getcwd()
        local dir = mkdir(vim.fn.tempname() .. "-continue")
        local worktree_item = {
            id = "current-wt",
            path = "/tmp/pi-worktree-spec/current.jsonl",
            timestamp = "2025-01-03T00:00:00.000Z",
            first_message = "current",
            modified = 1,
            cwd = dir,
        }
        local foreign = {
            id = "foreign",
            path = "/tmp/pi-worktree-spec/foreign.jsonl",
            timestamp = "2025-01-04T00:00:00.000Z",
            first_message = "foreign",
            modified = 9,
            cwd = nvim_cwd,
        }
        local calls = stub_history_list({
            [dir] = { worktree_item },
            [nvim_cwd] = { foreign },
        })

        local session = Sessions.get_or_create({ cwd = dir })
        assert.is_not_nil(session)
        -- Empty conversation so :PiContinue opens the previous one.
        Rpc.send = function(self, cmd, cb)
            rpc_state.commands[#rpc_state.commands + 1] = cmd
            if cb then
                local res
                if cmd.type == "get_state" then
                    res = {
                        type = "response",
                        success = true,
                        data = {
                            sessionId = "current-wt",
                            sessionFile = "/tmp/pi-worktree-spec/empty-current.jsonl",
                            model = { provider = "test", id = "m" },
                            thinkingLevel = "medium",
                            autoCompactionEnabled = false,
                            messageCount = 0,
                            pendingMessageCount = 0,
                            isStreaming = false,
                        },
                    }
                else
                    res = response_for(cmd)
                end
                vim.schedule(function()
                    cb(res)
                end)
            end
            return true
        end
        Subsessions.on_parent_resumed = function() end

        Sessions.continue_session()
        wait_for(function()
            for _, cmd in ipairs(rpc_state.commands) do
                if cmd.type == "switch_session" then
                    return true
                end
            end
            return false
        end)
        assert.equals(1, calls[dir])
        assert.is_nil(calls[nvim_cwd]) -- never listed Neovim's cwd
        assert.equals(1, #rpc_state.starts) -- same cwd: no restart
        assert.equals(session, Sessions.get())
    end)

    it("continue across cwd restarts the process in the session's cwd", function()
        local target = mkdir(vim.fn.tempname() .. "-continue-target")
        local current = Sessions.get_or_create()
        assert.is_not_nil(current)
        local candidate_path = "/tmp/pi-worktree-spec/other-cwd.jsonl"
        local candidate = {
            id = "other-cwd",
            path = candidate_path,
            timestamp = "2025-01-05T00:00:00.000Z",
            first_message = "other cwd",
            modified = 9,
            cwd = target,
        }
        stub_history_list({ [vim.fn.getcwd()] = { candidate } })
        History.parse = function(path)
            if path == candidate_path then
                return { id = candidate.id, path = path, cwd = target, timestamp = candidate.timestamp, modified = 9 }
            end
            return real.parse(path)
        end
        Rpc.send = function(self, cmd, cb)
            rpc_state.commands[#rpc_state.commands + 1] = cmd
            if cb then
                local res
                if cmd.type == "get_state" then
                    res = {
                        type = "response",
                        success = true,
                        data = {
                            sessionId = "current",
                            sessionFile = "/tmp/pi-worktree-spec/current.jsonl",
                            model = { provider = "test", id = "m" },
                            thinkingLevel = "medium",
                            autoCompactionEnabled = false,
                            messageCount = 0,
                            pendingMessageCount = 0,
                            isStreaming = false,
                        },
                    }
                else
                    res = response_for(cmd)
                end
                vim.schedule(function()
                    cb(res)
                end)
            end
            return true
        end
        Subsessions.on_parent_resumed = function() end

        Sessions.continue_session()
        wait_for(function()
            local session = Sessions.get()
            return session ~= nil and session ~= current and session.cwd == target
        end)
        assert.equals(2, #rpc_state.starts)
        assert.equals(target, rpc_state.starts[2].cwd)
    end)
end)
