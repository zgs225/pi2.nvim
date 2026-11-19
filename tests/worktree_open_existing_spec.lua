-- :Pi worktree=<name> / :PiNewTab worktree=<name> — a fresh session in an
-- EXISTING directory (pi.worktree_session.open_existing):
--   * flag parsing (`worktree=` / `layout=`) and completion in pi.commands,
--   * refusal of the flag on :PiContinue / :PiResume,
--   * name resolution (validated name, must exist under <repo>/.worktrees/,
--     must be a linked worktree) and the `cwd` form — any existing directory:
--     linked worktree = worktree metadata, main checkout or a plain dir =
--     ordinary session with no metadata and no bind,
--   * the occupied-tab refusal of `:Pi worktree=` (new_tab = false),
--   * the success path (get_or_create with that cwd + worktree info) and its
--     silence (no notification on success),
--   * metadata bind only for a checkout that was never bound,
--   * a failed start closes the scratch tab and never releases the checkout
--     (the directory existed before the command ran — releasing it would
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

--- Wait for an asynchronous continuation (creation schedules its callback).
---@param pred fun(): boolean
---@return boolean
local function wait_for(pred)
    return vim.wait(500, pred, 10)
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
        -- A missing checkout points at how to create one, never at an
        -- implicit create.
        assert.is_truthy(result.err:find("create it with `git worktree add missing`", 1, true))
        assert.is_not_nil(find_note("not found", vim.log.levels.ERROR))
        assert.are.equal(tabs_before, tab_count())
        assert.are.equal(0, #created)
    end)

    it("starts an ordinary session for the main checkout", function()
        local wt = install_worktree()
        local session = fake_session({ cwd = REPO })
        install_sessions({ session = session })
        local tabs_before = tab_count()

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ cwd = REPO }, function(started, err)
            result.session = started
            result.err = err
        end)

        assert.is_nil(result.err)
        assert.are.equal(session, result.session)
        assert.are.equal(1, #created)
        assert.are.equal(REPO, created[1].cwd)
        -- A `kind == "main"` info must never become session metadata: it would
        -- badge the main checkout as a worktree, refuse a nested create as
        -- "nested" and make `resolve_target(nil)` return it.
        assert.is_nil(created[1].worktree)
        assert.are.equal(0, #wt.calls.bind)
        assert.are.equal(tabs_before + 1, tab_count())
        -- Success is silent: only failures notify.
        assert.are.equal(0, #notes)
    end)

    it("starts an ordinary session outside any git repository", function()
        local wt = install_worktree({
            detect = function()
                return nil
            end,
        })
        local plain = vim.fn.tempname()
        vim.fn.mkdir(plain, "p")
        local session = fake_session({ cwd = plain })
        install_sessions({ session = session })

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ cwd = plain }, function(started, err)
            result.session = started
            result.err = err
        end)

        assert.is_nil(result.err)
        assert.are.equal(session, result.session)
        assert.are.equal(plain, created[1].cwd)
        assert.is_nil(created[1].worktree)
        assert.are.equal(0, #wt.calls.bind)
        assert.are.equal(0, #notes)
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

    it("prefers cwd over name and keeps linked metadata", function()
        local wt = install_worktree()
        install_sessions({ session = fake_session() })

        ---@type { session: pi.Session? }
        local result = {}
        WorktreeSession.open_existing({ name = "does-not-exist", cwd = CHECKOUT }, function(session)
            result.session = session
        end)

        assert.is_not_nil(result.session)
        assert.are.equal(CHECKOUT, created[1].cwd)
        -- A linked checkout is attached exactly as before, bind included.
        assert.are.equal("linked", created[1].worktree.kind)
        assert.are.equal(CHECKOUT, created[1].worktree.path)
        assert.are.equal(1, #wt.calls.bind)
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
        assert.are.equal(0, #notes)
    end)

    it("opens a new tabpage by default", function()
        install_sessions({ session = fake_session() })
        local tabs_before = tab_count()

        WorktreeSession.open_existing({ name = "wt1" })

        assert.are.equal(tabs_before + 1, tab_count())
        assert.are.equal(1, #created)
        assert.are.equal(CHECKOUT, created[1].cwd)
    end)

    it("places the new tabpage right after tab_after", function()
        install_sessions({ session = fake_session() })
        -- Anchor in the middle of the tabline, with another tab behind it: the
        -- new tab belongs next to its group, not appended at the end.
        vim.cmd("tabnew")
        local anchor = vim.api.nvim_get_current_tabpage()
        vim.cmd("tabnew")

        ---@type table<pi.TabId, true>
        local known = {}
        for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            known[tab] = true
        end

        WorktreeSession.open_existing({ name = "wt1", tab_after = anchor })

        local order = vim.api.nvim_list_tabpages()
        assert.are.equal(vim.tbl_count(known) + 1, #order)
        local anchor_index, new_index
        for index, tab in ipairs(order) do
            if tab == anchor then
                anchor_index = index
            end
            if not known[tab] then
                new_index = index
            end
        end
        assert.is_not_nil(anchor_index)
        assert.is_not_nil(new_index)
        assert.are.equal(anchor_index + 1, new_index)
        -- The chat of the tab that was opened is the one focused.
        assert.are.equal(order[new_index], vim.api.nvim_get_current_tabpage())
    end)

    it("appends the new tabpage when tab_after is not a live tabpage", function()
        install_sessions({ session = fake_session() })
        local tabs_before = tab_count()

        WorktreeSession.open_existing({ name = "wt1", tab_after = 999999 })

        assert.are.equal(tabs_before + 1, tab_count())
        assert.are.equal(1, #created)
    end)

    it("ignores tab_after when it reuses the current tabpage", function()
        install_sessions({ session = fake_session() })
        vim.cmd("tabnew")
        local anchor = vim.api.nvim_get_current_tabpage()
        local tabs_before = tab_count()

        WorktreeSession.open_existing({ name = "wt1", new_tab = false, tab_after = anchor })

        assert.are.equal(tabs_before, tab_count())
        assert.are.equal(anchor, vim.api.nvim_get_current_tabpage())
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

describe("create on a missing worktree name", function()
    before_each(setup)
    after_each(restore)

    --- The checkout `brand-new` does not exist, so `create = true` must make it
    --- and then open a session in the path the stub reports.
    local NEW_PATH = REPO .. "/.worktrees/brand-new"

    ---@param requests table[]
    ---@return pi.TestWorktreeStub
    local function install_create(requests)
        return install_worktree({
            create = function(opts, cb)
                requests[#requests + 1] = opts
                cb(fake_info({ name = opts.name, path = NEW_PATH }), nil)
            end,
        })
    end

    it("creates the named checkout and opens a session in it", function()
        ---@type table[]
        local requests = {}
        install_create(requests)
        local session = fake_session({ cwd = NEW_PATH })
        install_sessions({ session = session })
        local tabs_before = tab_count()

        ---@type { session: pi.Session? }
        local result = {}
        WorktreeSession.open_existing({ name = "brand-new", create = true }, function(started)
            result.session = started
        end)
        wait_for(function()
            return result.session ~= nil
        end)

        assert.are.equal(1, #requests)
        assert.are.equal("brand-new", requests[1].name)
        assert.are.equal("new", requests[1].mode)
        -- Base repository: no session in this tab, so Neovim's cwd.
        assert.are.equal(vim.fs.normalize(vim.fn.getcwd()), vim.fs.normalize(requests[1].cwd))
        assert.are.equal(session, result.session)
        assert.are.equal(tabs_before + 1, tab_count())
        assert.are.equal(1, #created)
        assert.are.equal(NEW_PATH, created[1].cwd)
        assert.are.equal("brand-new", created[1].worktree.name)
        -- A created checkout is never released on the success path, and the
        -- start is silent like every other `worktree=` open.
        assert.are.equal(0, #notes)
    end)

    it(":Pi worktree=<new name> creates and reuses the current tab", function()
        ---@type table[]
        local requests = {}
        install_create(requests)
        install_sessions({ session = fake_session({ cwd = NEW_PATH }) })
        local tabs_before = tab_count()

        vim.cmd("Pi worktree=brand-new")
        wait_for(function()
            return #created > 0
        end)

        assert.are.equal(1, #requests)
        assert.are.equal(tabs_before, tab_count())
        assert.are.equal(NEW_PATH, created[1].cwd)
        assert.are.equal(0, #notes)
    end)

    it("refuses a taken tab before creating anything", function()
        ---@type table[]
        local requests = {}
        install_create(requests)
        install_sessions({ current = fake_session({ worktree = fake_info() }) })
        local tabs_before = tab_count()

        vim.cmd("Pi worktree=brand-new")

        assert.is_not_nil(find_note("already runs a session", vim.log.levels.ERROR))
        -- The tab is checked first: a taken tab must not leave an empty
        -- checkout on disk that cannot be opened.
        assert.are.equal(0, #requests)
        assert.are.equal(0, #created)
        assert.are.equal(tabs_before, tab_count())
    end)

    it("refuses to create a nested worktree", function()
        ---@type table[]
        local requests = {}
        install_create(requests)
        install_sessions({ current = fake_session({ worktree = fake_info() }) })

        vim.cmd("PiNewTab worktree=brand-new")

        assert.is_not_nil(find_note("Nested worktrees are not supported", vim.log.levels.ERROR))
        assert.are.equal(0, #requests)
        assert.are.equal(0, #created)
    end)

    it("releases the fresh checkout when the session fails to start", function()
        ---@type table[]
        local requests = {}
        local wt = install_create(requests)
        install_sessions({ session = nil })
        local tabs_before = tab_count()

        vim.cmd("PiNewTab worktree=brand-new")
        wait_for(function()
            return #wt.calls.release > 0
        end)

        assert.are.equal(1, #requests)
        assert.is_not_nil(find_note("Failed to start a session", vim.log.levels.ERROR))
        -- The setup_cmd/includes already ran and the directory was created by
        -- this call, so nothing of the user's is in it: release it.
        assert.are.equal(1, #wt.calls.release)
        assert.are.equal(NEW_PATH, wt.calls.release[1].info.path)
        assert.are.equal(tabs_before, tab_count())
    end)
end)

describe("repo_cwd repository scope", function()
    before_each(setup)
    after_each(restore)

    -- A second repository whose managed checkout carries the *same* name as the
    -- one in REPO: the case a cross-repo `current.name == wanted` shortcut
    -- would silently get wrong.
    local REPO_B = vim.fn.tempname()
    local CHECKOUT_B = REPO_B .. "/.worktrees/wt1"
    local NEW_B = REPO_B .. "/.worktrees/brand-new"
    vim.fn.mkdir(CHECKOUT_B, "p")

    local MAIN_B = { kind = "main", name = "repo-b", path = REPO_B, repo_root = REPO_B }

    --- Detect stub covering both repositories: each `.worktrees/<name>` is a
    --- linked checkout of its own repo, each repo root is that repo's main
    --- checkout, anything else is unknown (not a git repository).
    ---@param overrides? table
    ---@return pi.TestWorktreeStub
    local function install_two_repos(overrides)
        local extra = vim.deepcopy(overrides or {})
        extra.detect = function(dir)
            if type(dir) ~= "string" then
                return nil
            end
            local norm = vim.fs.normalize(dir)
            if norm == vim.fs.normalize(CHECKOUT) then
                return fake_info()
            end
            if norm == vim.fs.normalize(CHECKOUT_B) then
                return fake_info({ path = CHECKOUT_B, repo_root = REPO_B })
            end
            if norm == vim.fs.normalize(REPO) then
                return MAIN
            end
            if norm == vim.fs.normalize(REPO_B) then
                return MAIN_B
            end
            return nil
        end
        return install_worktree(extra)
    end

    --- `Worktree.create` stub that records its requests.
    ---@param requests table[]
    ---@param result fun(opts: table): table?, string?
    local function install_create(requests, result)
        return install_two_repos({
            create = function(opts, cb)
                requests[#requests + 1] = opts
                local info, err = result(opts)
                cb(info, err)
            end,
        })
    end

    it("resolves a name in the explicit repository, not the tab's checkout", function()
        local wt = install_two_repos()
        -- The current tab runs in REPO's worktree, also called `wt1`.
        local current = fake_session({ worktree = fake_info(), cwd = CHECKOUT })
        install_sessions({ current = current, session = fake_session({ cwd = CHECKOUT_B }) })

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ name = "wt1", repo_cwd = REPO_B }, function(session, err)
            result.session = session
            result.err = err
        end)

        assert.is_nil(result.err)
        assert.is_not_nil(result.session)
        -- The identical name in the other repository must resolve there: the
        -- `current.name == wanted` shortcut may not cross repositories.
        assert.are.equal(CHECKOUT_B, created[1].cwd)
        assert.are.equal(CHECKOUT_B, created[1].worktree.path)
        assert.are.equal(REPO_B, created[1].worktree.repo_root)
        assert.are.equal(1, #wt.calls.bind)
        assert.are.equal(0, #notes)
    end)

    it("reports a missing name against the explicit repository", function()
        install_two_repos()
        install_sessions({ current = fake_session({ worktree = fake_info(), cwd = CHECKOUT }) })

        ---@type { err: string? }
        local result = {}
        WorktreeSession.open_existing({ name = "nope", repo_cwd = REPO_B }, function(_, err)
            result.err = err
        end)

        assert.is_string(result.err)
        assert.is_truthy(result.err:find(REPO_B .. "/.worktrees", 1, true))
        assert.are.equal(0, #created)
    end)

    it("creates in the explicit repository, not from the tab's cwd", function()
        ---@type table[]
        local requests = {}
        install_create(requests, function(opts)
            return fake_info({ name = opts.name, path = NEW_B, repo_root = REPO_B }), nil
        end)
        -- A session elsewhere must not become the creation base.
        install_sessions({ session = fake_session({ cwd = NEW_B }) })

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ name = "brand-new", repo_cwd = REPO_B, create = true }, function(s, err)
            result.session = s
            result.err = err
        end)
        wait_for(function()
            return result.session ~= nil or result.err ~= nil
        end)

        assert.is_nil(result.err)
        assert.are.equal(1, #requests)
        assert.are.equal("brand-new", requests[1].name)
        assert.are.equal(vim.fs.normalize(REPO_B), vim.fs.normalize(requests[1].cwd))
        assert.are.equal(NEW_B, created[1].cwd)
        assert.are.equal(0, #notes)
    end)

    it("creates from an explicit main root while the tab runs in a worktree", function()
        ---@type table[]
        local requests = {}
        local new_path = REPO .. "/.worktrees/from-main"
        install_create(requests, function(opts)
            return fake_info({ name = opts.name, path = new_path }), nil
        end)
        local current = fake_session({ worktree = fake_info(), cwd = CHECKOUT })
        install_sessions({ current = current, session = fake_session({ cwd = new_path }) })

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ name = "from-main", repo_cwd = REPO, create = true }, function(s, err)
            result.session = s
            result.err = err
        end)
        wait_for(function()
            return result.session ~= nil or result.err ~= nil
        end)

        -- An explicit repository scope makes the tab's own worktree irrelevant:
        -- the checkout is requested in the named repository, not nested in the
        -- worktree this tab runs in.
        assert.is_nil(find_note("Nested worktrees are not supported"))
        assert.is_nil(result.err)
        assert.are.equal(1, #requests)
        assert.are.equal(vim.fs.normalize(REPO), vim.fs.normalize(requests[1].cwd))
        assert.are.equal(new_path, created[1].cwd)
    end)

    it("still leaves a linked repo_cwd to Worktree.create to refuse", function()
        ---@type table[]
        local requests = {}
        install_create(requests, function()
            return nil, "worktree: cannot create a worktree from a linked worktree"
        end)
        install_sessions({})

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ name = "brand-new", repo_cwd = CHECKOUT, create = true }, function(s, err)
            result.session = s
            result.err = err
        end)
        wait_for(function()
            return result.session ~= nil or result.err ~= nil
        end)

        assert.is_nil(result.session)
        -- The scope is handed to the git side as-is (a real linked cwd is
        -- rejected there), and nothing is opened on failure.
        assert.are.equal(1, #requests)
        assert.are.equal(vim.fs.normalize(CHECKOUT), vim.fs.normalize(requests[1].cwd))
        assert.is_not_nil(find_note("Failed to create worktree", vim.log.levels.ERROR))
        assert.are.equal(0, #created)
    end)

    it("fails clearly for a repo_cwd that does not exist and writes nothing", function()
        ---@type table[]
        local requests = {}
        install_create(requests, function()
            return fake_info(), nil
        end)
        install_sessions({ current = fake_session({ worktree = fake_info(), cwd = CHECKOUT }) })
        local tabs_before = tab_count()

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ name = "wt1", repo_cwd = REPO_B .. "/nope", create = true }, function(s, err)
            result.session = s
            result.err = err
        end)

        assert.is_nil(result.session)
        assert.is_string(result.err)
        assert.is_truthy(result.err:find("Directory not found", 1, true))
        assert.is_not_nil(find_note("Directory not found", vim.log.levels.ERROR))
        -- A bad scope never falls back to the tab's repository and never
        -- creates anything.
        assert.are.equal(0, #requests)
        assert.are.equal(0, #created)
        assert.are.equal(tabs_before, tab_count())
    end)

    it("fails clearly for a repo_cwd outside any git repository and writes nothing", function()
        local plain = vim.fn.tempname()
        vim.fn.mkdir(plain, "p")
        ---@type table[]
        local requests = {}
        install_create(requests, function()
            return fake_info(), nil
        end)
        install_sessions({})

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ name = "wt1", repo_cwd = plain, create = true }, function(s, err)
            result.session = s
            result.err = err
        end)

        assert.is_nil(result.session)
        assert.is_string(result.err)
        assert.is_truthy(result.err:find("Not inside a git repository", 1, true))
        assert.is_not_nil(find_note("Not inside a git repository", vim.log.levels.ERROR))
        assert.are.equal(0, #requests)
        assert.are.equal(0, #created)
    end)

    it("refuses an explicit scope without a name instead of using the tab's worktree", function()
        ---@type table[]
        local requests = {}
        install_create(requests, function()
            return fake_info(), nil
        end)
        -- The tab runs in REPO's worktree: the nameless fallback would resolve
        -- *there*, crossing the repository the caller named.
        local current = fake_session({ worktree = fake_info(), cwd = CHECKOUT })
        install_sessions({ current = current })

        ---@type table[]
        local open_opts =
            { { repo_cwd = REPO_B }, { repo_cwd = REPO_B, name = "" }, { repo_cwd = REPO_B, name = "   " } }
        for i, opts in ipairs(open_opts) do
            local tabs_before = tab_count()
            ---@type { session: pi.Session?, err: string? }
            local result = {}
            WorktreeSession.open_existing(opts, function(session, err)
                result.session = session
                result.err = err
            end)

            assert.is_nil(result.session, "case " .. i)
            assert.is_string(result.err, "case " .. i)
            assert.is_truthy(result.err:find("repo_cwd requires a worktree name", 1, true), "case " .. i)
            assert.is_not_nil(find_note("repo_cwd requires a worktree name", vim.log.levels.ERROR))
            assert.are.equal(tabs_before, tab_count(), "case " .. i)
        end
        -- repo_cwd only scopes a name: no resolution in any repository, no
        -- session, no bind, and nothing created.
        assert.are.equal(0, #requests)
        assert.are.equal(0, #created)
    end)

    it("does not create an unnamed checkout for a scopeless create", function()
        ---@type table[]
        local requests = {}
        install_create(requests, function(opts)
            return fake_info({ name = opts.name, path = NEW_B, repo_root = REPO_B }), nil
        end)
        install_sessions({ current = fake_session({ worktree = fake_info(), cwd = CHECKOUT }) })
        local tabs_before = tab_count()

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({ repo_cwd = REPO_B, create = true }, function(session, err)
            result.session = session
            result.err = err
        end)

        assert.is_nil(result.session)
        assert.is_string(result.err)
        assert.is_truthy(result.err:find("repo_cwd requires a worktree name", 1, true))
        -- `create` must never turn a missing name into a generated one.
        assert.are.equal(0, #requests)
        assert.are.equal(0, #created)
        assert.are.equal(tabs_before, tab_count())
    end)

    it("rejects a non-string or blank repo_cwd on the name path instead of treating it as unscoped", function()
        ---@type table[]
        local requests = {}
        install_create(requests, function()
            return fake_info(), nil
        end)
        install_sessions({ current = fake_session({ worktree = fake_info(), cwd = CHECKOUT }) })
        local tabs_before = tab_count()

        ---@type table[]
        local cases = {
            { opts = { name = "wt1", repo_cwd = 42 }, err = "repo_cwd must be a string" },
            { opts = { name = "wt1", repo_cwd = "   " }, err = "repo_cwd must not be blank" },
            -- The shape error outranks a name that is not there either.
            { opts = { repo_cwd = 42 }, err = "repo_cwd must be a string" },
        }
        for i, case in ipairs(cases) do
            ---@type { session: pi.Session?, err: string? }
            local result = {}
            WorktreeSession.open_existing(case.opts, function(session, err)
                result.session = session
                result.err = err
            end)

            assert.is_nil(result.session, "case " .. i)
            assert.is_string(result.err, "case " .. i)
            assert.is_truthy(result.err:find(case.err, 1, true), "case " .. i)
            assert.is_not_nil(find_note(case.err, vim.log.levels.ERROR))
        end
        assert.are.equal(0, #requests)
        assert.are.equal(0, #created)
        assert.are.equal(tabs_before, tab_count())
    end)

    it("ignores repo_cwd entirely when cwd is given, even a malformed one", function()
        local wt = install_two_repos()
        local session = fake_session({ cwd = CHECKOUT })
        install_sessions({ session = session })

        ---@type table[]
        local cases = {
            { name = "does-not-exist", repo_cwd = 42 },
            { name = "does-not-exist", repo_cwd = "   " },
            { name = "does-not-exist", repo_cwd = REPO_B .. "/nope" },
            { repo_cwd = 42 },
        }
        for i, opts in ipairs(cases) do
            opts.cwd = CHECKOUT
            ---@type { session: pi.Session?, err: string? }
            local result = {}
            WorktreeSession.open_existing(opts, function(started, err)
                result.session = started
                result.err = err
            end)

            -- "cwd wins": repo_cwd is not consulted at all on the cwd path, so
            -- even a non-string/blank/nonexistent scope cannot reject a valid
            -- directory, and no name resolution happens for it.
            assert.is_nil(result.err, "case " .. i)
            assert.are.equal(session, result.session, "case " .. i)
            assert.are.equal(CHECKOUT, created[i].cwd, "case " .. i)
            assert.are.equal("linked", created[i].worktree.kind, "case " .. i)
        end
        assert.are.equal(0, #notes)
        -- One bind per opened checkout; none of them went through resolution.
        assert.are.equal(#cases, #wt.calls.bind)
    end)

    it("leaves the unscoped nameless fallback unchanged", function()
        install_two_repos()
        local current = fake_session({ worktree = fake_info(), cwd = CHECKOUT })
        local session = fake_session({ cwd = CHECKOUT })
        install_sessions({ current = current, session = session })

        ---@type { session: pi.Session?, err: string? }
        local result = {}
        WorktreeSession.open_existing({}, function(started, err)
            result.session = started
            result.err = err
        end)

        assert.is_nil(result.err)
        assert.are.equal(session, result.session)
        -- Without `repo_cwd` the tab's own worktree is still the target.
        assert.are.equal(CHECKOUT, created[1].cwd)
        assert.are.equal("linked", created[1].worktree.kind)
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
