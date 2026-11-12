-- :Pi worktree=<name> / :PiNewTab worktree=<name> — a fresh session in an
-- EXISTING managed worktree (pi.worktree_session.open_existing):
--   * flag parsing (`worktree=` / `layout=`) and completion in pi.commands,
--   * refusal of the flag on :PiContinue / :PiResume,
--   * name resolution (validated name, must exist under <repo>/.worktrees/,
--     must be a linked worktree) and the `cwd` form,
--   * the occupied-tab refusal of `:Pi worktree=` (new_tab = false),
--   * the success path (get_or_create with the checkout cwd + worktree info),
--   * metadata bind only for a checkout that was never bound,
--   * a failed start closes the scratch tab and never releases the checkout
--     (the worktree existed before the command ran — releasing it would
--     delete the user's work).
--
-- pi.worktree is stubbed through package.loaded and the session manager's
-- entry points are patched in place: no git checkout, no pi process.

local Config = require("pi.config")
local Pi = require("pi")
local Sessions = require("pi.sessions.manager")
local WorktreeSession = require("pi.worktree_session")

Config.setup({})
Pi.setup({})

local REPO = vim.fn.tempname()
local CHECKOUT = REPO .. "/.worktrees/wt1"
vim.fn.mkdir(CHECKOUT, "p")

---@class pi.TestWorktreeStub
---@field calls { bind: table[], detect: string[], release: table[] }

local real = {
    notify = vim.notify,
    get = Sessions.get,
    get_or_create = Sessions.get_or_create,
    list_all = Sessions.list_all,
    continue_session = Sessions.continue_session,
    resume_session = Sessions.resume_session,
    worktree = package.loaded["pi.worktree"],
}

---@type table[] notifications recorded while vim.notify is stubbed
local notes = {}
---@type table[] pi.SessionCreateOpts recorded by the get_or_create stub
local created = {}

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

---@return integer
local function tab_count()
    return #vim.api.nvim_list_tabpages()
end

--- The managed checkout every test opens, plus the repository's main checkout
--- (a directory inside the same repo that is *not* a worktree).
local MAIN = { kind = "main", name = "repo", path = REPO, repo_root = REPO }

---@param overrides? table
---@return table worktree info
local function fake_info(overrides)
    local info = {
        kind = "linked",
        name = "wt1",
        path = CHECKOUT,
        repo_root = REPO,
        git_dir = REPO .. "/.git/worktrees/wt1",
        common_dir = REPO .. "/.git",
    }
    for k, v in pairs(overrides or {}) do
        info[k] = v
    end
    return info
end

---@param overrides? table
---@return pi.Session
local function fake_session(overrides)
    local session = {
        id = "sess-wt1",
        session_file = REPO .. "/session.jsonl",
        cwd = CHECKOUT,
        focused = 0,
    }
    session.chat = {
        is_streaming = function()
            return false
        end,
        ensure_shown_and_focus_prompt = function()
            session.focused = session.focused + 1
        end,
        -- Attention redraws look the current tab's session up asynchronously;
        -- a fake chat without these makes those callbacks error out.
        render_statusline = function() end,
        refresh_prompt_attention = function() end,
    }
    session.rpc = {
        running = true,
        is_running = function(self)
            return self.running == true
        end,
    }
    for k, v in pairs(overrides or {}) do
        session[k] = v
    end
    return session
end

--- Install a pi.worktree stub: the managed checkout is detected as a linked
--- worktree, everything else as the repository's main checkout.
---@param overrides? table
---@return pi.TestWorktreeStub
local function install_worktree(overrides)
    local wt = { calls = { bind = {}, detect = {}, release = {} } }
    wt.validate_name = function(name)
        if type(name) ~= "string" or name == "" or not name:match("^[%w][%w._-]*$") then
            return false, "worktree: invalid name"
        end
        return true, nil
    end
    wt.detect = function(dir)
        wt.calls.detect[#wt.calls.detect + 1] = dir
        if type(dir) == "string" and vim.fs.normalize(dir) == vim.fs.normalize(CHECKOUT) then
            return fake_info()
        end
        return MAIN
    end
    wt.bind = function(info, fields)
        wt.calls.bind[#wt.calls.bind + 1] = { info = info, fields = fields }
        return true, nil
    end
    wt.release = function(info, cb)
        wt.calls.release[#wt.calls.release + 1] = { info = info, cb = cb }
        if type(cb) == "function" then
            cb(true, nil)
        end
    end
    for k, v in pairs(overrides or {}) do
        wt[k] = v
    end
    package.loaded["pi.worktree"] = wt
    return wt
end

--- Patch the session manager. `current` is what `Sessions.get()` returns (the
--- tab's session), `session` what `get_or_create` returns (nil = start failed).
---@param opts? { current?: pi.Session, session?: pi.Session }
local function install_sessions(opts)
    opts = opts or {}
    created = {}
    Sessions.get = function()
        return opts.current
    end
    Sessions.list_all = function()
        return opts.current and { opts.current } or {}
    end
    Sessions.get_or_create = function(create_opts)
        created[#created + 1] = create_opts
        return opts.session
    end
end

local function restore()
    vim.wait(20)
    Sessions.get = real.get
    Sessions.get_or_create = real.get_or_create
    Sessions.list_all = real.list_all
    Sessions.continue_session = real.continue_session
    Sessions.resume_session = real.resume_session
    vim.notify = real.notify
    package.loaded["pi.worktree"] = real.worktree
    Config.setup({})
    -- Tabs opened by the commands under test; their sessions are stubs, so
    -- closing them cannot stop a process.
    while #vim.api.nvim_list_tabpages() > 1 do
        vim.cmd("tabclose")
    end
end

--- Fresh notifications, worktree stub and session stubs for one test.
local function setup()
    notes = {}
    created = {}
    vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    install_worktree()
    install_sessions()
end

describe("open_existing target resolution", function()
    before_each(setup)
    after_each(restore)

    it("errors for an unknown worktree name and creates nothing", function()
        -- A session inside a worktree: `<repo>/.worktrees/<name>` is its
        -- resolution base, so the missing directory is the error.
        local current = fake_session({
            worktree = fake_info(),
            rpc = {
                is_running = function()
                    return false
                end,
            },
        })
        install_sessions({ current = current })
        local tabs_before = tab_count()

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ name = "missing" }, function(session, err)
            result.session = session
            result.err = err
        end)

        assert.is_nil(result.session)
        assert.is_string(result.err)
        assert.is_truthy(result.err:find("not found", 1, true))
        -- A missing checkout points at the creating command, never at an
        -- implicit create.
        assert.is_truthy(result.err:find(":PiWorktreeNew missing", 1, true))
        assert.is_not_nil(find_note("not found", vim.log.levels.ERROR))
        assert.are.equal(tabs_before, tab_count())
        assert.are.equal(0, #created)
    end)

    it("errors for a cwd that is not a linked worktree", function()
        local tabs_before = tab_count()

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ cwd = REPO }, function(session, err)
            result.session = session
            result.err = err
        end)

        assert.is_nil(result.session)
        assert.is_truthy(result.err:find("Not a managed git worktree", 1, true))
        assert.is_not_nil(find_note("Not a managed git worktree", vim.log.levels.ERROR))
        assert.are.equal(tabs_before, tab_count())
        assert.are.equal(0, #created)
    end)

    it("errors for a cwd that does not exist", function()
        ---@type { err: string? }
        local result = {}
        WorktreeSession.open_existing({ cwd = REPO .. "/nope" }, function(_, err)
            result.err = err
        end)

        assert.is_truthy(result.err:find("Directory not found", 1, true))
        assert.are.equal(0, #created)
    end)

    it("prefers cwd over name", function()
        install_sessions({ session = fake_session() })

        ---@type { session: pi.Session? }
        local result = {}
        WorktreeSession.open_existing({ name = "does-not-exist", cwd = CHECKOUT }, function(session)
            result.session = session
        end)

        assert.is_not_nil(result.session)
        assert.are.equal(CHECKOUT, created[1].cwd)
    end)
end)

describe("open_existing tabs", function()
    before_each(setup)
    after_each(restore)

    it("reuses the current tabpage when new_tab = false", function()
        local session = fake_session()
        install_sessions({ session = session })
        local tabs_before = tab_count()

        ---@type { session: pi.Session? }
        local result = {}
        WorktreeSession.open_existing({ name = "wt1", layout = "float", new_tab = false }, function(started)
            result.session = started
        end)

        assert.are.equal(session, result.session)
        assert.are.equal(tabs_before, tab_count())
        assert.are.equal(1, session.focused)
        assert.are.equal(1, #created)
        assert.are.equal(CHECKOUT, created[1].cwd)
        assert.are.equal("float", created[1].layout)
    end)

    it("opens a new tabpage by default", function()
        install_sessions({ session = fake_session() })
        local tabs_before = tab_count()

        WorktreeSession.open_existing({ name = "wt1" })

        assert.are.equal(tabs_before + 1, tab_count())
        assert.are.equal(1, #created)
        assert.are.equal(CHECKOUT, created[1].cwd)
    end)

    it("refuses new_tab = false when the tab already runs a session", function()
        local current = fake_session({ worktree = fake_info() })
        install_sessions({ current = current })
        local tabs_before = tab_count()

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ name = "wt1", new_tab = false }, function(session, err)
            result.session = session
            result.err = err
        end)

        assert.is_nil(result.session)
        assert.is_truthy(result.err:find("already runs a session", 1, true))
        assert.is_truthy(result.err:find(":PiNewTab worktree=wt1", 1, true))
        assert.is_not_nil(find_note("already runs a session", vim.log.levels.ERROR))
        -- Touch nothing: no tab, no process, no metadata write.
        assert.are.equal(tabs_before, tab_count())
        assert.are.equal(0, #created)
    end)

    it("closes the scratch tab and never releases the checkout on failure", function()
        local wt = install_worktree()
        install_sessions({ session = nil })
        local tabs_before = tab_count()

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ name = "wt1" }, function(session, err)
            result.session = session
            result.err = err
        end)

        assert.is_nil(result.session)
        assert.is_truthy(result.err:find("Failed to start a session", 1, true))
        assert.is_not_nil(find_note("Failed to start a session", vim.log.levels.ERROR))
        assert.are.equal(tabs_before, tab_count())
        -- The checkout predates the command: releasing it would delete the
        -- user's work.
        assert.are.equal(0, #wt.calls.release)
    end)
end)

describe("open_existing metadata", function()
    before_each(setup)
    after_each(restore)

    it("passes the resolved worktree info to the session manager", function()
        local session = fake_session()
        install_sessions({ session = session })

        WorktreeSession.open_existing({ name = "wt1" })

        assert.are.equal(CHECKOUT, created[1].worktree.path)
        assert.are.equal("linked", created[1].worktree.kind)
        assert.are.equal("wt1", created[1].worktree.name)
        assert.is_nil(created[1].args)
    end)

    it("binds an unbound checkout to the opened session", function()
        local wt = install_worktree()
        install_sessions({ session = fake_session() })

        WorktreeSession.open_existing({ name = "wt1" })

        assert.are.equal(1, #wt.calls.bind)
        assert.are.equal("sess-wt1", wt.calls.bind[1].fields.session_id)
        assert.are.equal(REPO .. "/session.jsonl", wt.calls.bind[1].fields.session_file)
    end)

    it("never rebinds a checkout that already has a session", function()
        local bound = fake_info({ session_id = "sess-owner" })
        local wt = install_worktree({
            detect = function()
                return bound
            end,
        })
        install_sessions({ session = fake_session() })

        WorktreeSession.open_existing({ cwd = CHECKOUT })

        assert.are.equal(0, #wt.calls.bind)
        assert.are.equal("sess-owner", bound.session_id)
    end)

    it("does not bind a placeholder (tmp-) session id", function()
        local wt = install_worktree()
        install_sessions({ session = fake_session({ id = "tmp-7" }) })

        WorktreeSession.open_existing({ name = "wt1" })

        assert.are.equal(0, #wt.calls.bind)
    end)
end)

describe("worktree= command flag", function()
    before_each(setup)
    after_each(restore)

    it(":PiNewTab worktree=<name> opens a new tab in that checkout", function()
        local tabs_before = tab_count()
        install_sessions({ session = fake_session() })

        vim.cmd("PiNewTab worktree=wt1")

        assert.are.equal(tabs_before + 1, tab_count())
        assert.are.equal(1, #created)
        assert.are.equal(CHECKOUT, created[1].cwd)
    end)

    it(":Pi worktree=<name> refuses in a tab that already runs a session", function()
        local current = fake_session({ worktree = fake_info() })
        install_sessions({ current = current })
        local tabs_before = tab_count()

        vim.cmd("Pi worktree=wt1")

        assert.is_not_nil(find_note("already runs a session", vim.log.levels.ERROR))
        assert.are.equal(tabs_before, tab_count())
        assert.are.equal(0, #created)
    end)

    it(":Pi worktree= without a name is an error", function()
        vim.cmd("Pi worktree=")

        assert.is_not_nil(find_note("worktree= requires a worktree name", vim.log.levels.ERROR))
        assert.are.equal(0, #created)
    end)

    it(":PiContinue / :PiResume reject the flag", function()
        ---@type table[]
        local continued = {}
        ---@type table[]
        local resumed = {}
        Sessions.continue_session = function(opts)
            continued[#continued + 1] = opts
        end
        Sessions.resume_session = function(opts)
            resumed[#resumed + 1] = opts
        end

        vim.cmd("PiContinue worktree=wt1")
        vim.cmd("PiResume worktree=wt1")

        assert.are.equal(0, #continued)
        assert.are.equal(0, #resumed)
        assert.is_not_nil(find_note(":PiContinue does not take worktree=", vim.log.levels.WARN))
        assert.is_not_nil(find_note(":PiResume does not take worktree=", vim.log.levels.WARN))
    end)

    it("still forwards layout= to continue/resume", function()
        ---@type table[]
        local continued = {}
        Sessions.continue_session = function(opts)
            continued[#continued + 1] = opts
        end

        vim.cmd("PiContinue layout=side")

        assert.are.equal(1, #continued)
        assert.are.equal("side", continued[1].layout)
    end)

    it("completes worktree names", function()
        local matches = vim.fn.getcompletion("PiNewTab worktree=wt", "cmdline")
        assert.is_true(vim.tbl_contains(matches, "worktree=wt1"))
    end)
end)
