-- Worktree operations owned by pi.worktree_session + the commands/API layer:
--   * :PiWorktreeApply — review the worktree patch (diff-review panel), apply
--     to the main checkout only after explicit accept, empty/conflict/failure
--     handling, never auto-apply.
--   * :PiWorktreeShip — prefill the target session's prompt with shipping
--     instructions, never send, switch tabs to an attached target.
--   * :PiWorktreeRemove — live-session refusal, dirty/ahead warning, snapshot
--     before removal (failure blocks the delete), force remove.
--   * release_orphan regression (release must receive a callback).
-- All pi.worktree git operations are stubbed: no git checkout, no pi process.

local Config = require("pi.config")
local Pi = require("pi")
local Sessions = require("pi.sessions.manager")
local DiffReview = require("pi.ui.diff_review")
local WorktreeSession = require("pi.worktree_session")

Config.setup({})
Pi.setup({})

local real = {
    notify = vim.notify,
    get = Sessions.get,
    get_by_id = Sessions.get_by_id,
    get_or_create = Sessions.get_or_create,
    list_all = Sessions.list_all,
    select = vim.ui.select,
    set_tab = vim.api.nvim_set_current_tabpage,
    worktree = package.loaded["pi.worktree"],
}

local SAMPLE = table.concat({
    "diff --git a/a.txt b/a.txt",
    "index 5626abf..814f4a4 100644",
    "--- a/a.txt",
    "+++ b/a.txt",
    "@@ -1 +1,2 @@",
    " one",
    "+two",
    "",
}, "\n")

---@type table[]
local notes = {}
---@type table[]
local dialogs = {}
---@type string? answer for the next confirm dialog ("Yes"/"No")
local dialog_answer = "Yes"

local RESULT = { session = nil }

local function install_spies()
    notes = {}
    dialogs = {}
    dialog_answer = "Yes"
    vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = tostring(msg), level = level }
    end
    vim.ui.select = function(items, opts, on_choice)
        dialogs[#dialogs + 1] = { items = items, opts = opts }
        on_choice(dialog_answer)
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

---@param overrides? table
---@return table worktree info
local function fake_info(overrides)
    local info = {
        kind = "linked",
        name = "wt1",
        path = "/repo/.worktrees/wt1",
        repo_root = "/repo",
        base_sha = "base123",
        git_dir = "/repo/.git/worktrees/wt1",
        common_dir = "/repo/.git",
    }
    for k, v in pairs(overrides or {}) do
        info[k] = v
    end
    return info
end

---@param overrides? table
---@return table session
local function fake_session(overrides)
    local session = {
        id = "sess-wt1",
        cwd = "/repo/.worktrees/wt1",
        drafts = {},
        focused = 0,
        sent = 0,
    }
    session.chat = {
        is_streaming = function()
            return false
        end,
        _set_prompt_draft = function(_, text)
            session.drafts[#session.drafts + 1] = text
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
        send = function()
            session.sent = session.sent + 1
            return true
        end,
    }
    for k, v in pairs(overrides or {}) do
        session[k] = v
    end
    return session
end

--- Default worktree stub: only the operations a spec exercises need to be
--- meaningful; all callbacks fire asynchronously like the real module.
---@param overrides? table
---@return table
local function install_worktree(overrides)
    -- Built in two steps: the method closures reference `wt`, which is only in
    -- scope after the declaration (a table literal would resolve `wt` as a
    -- global there).
    local wt = {
        calls = { remove = {}, snapshot = {}, release = {}, create = {} },
    }
    wt.validate_name = function(name)
        if type(name) ~= "string" or name == "" or name:sub(1, 1) == "." then
            return false, "worktree: invalid name"
        end
        if not name:match("^[%w][%w._-]*$") then
            return false, "worktree: invalid name"
        end
        return true, nil
    end
    wt.detect = function()
        return nil
    end
    wt.create = function(opts, cb)
        wt.calls.create[#wt.calls.create + 1] = opts
        cb({ kind = "linked", name = opts.name or "generated", path = "/repo/.worktrees/wt-new" }, nil)
    end
    wt.diff = function(_, cb)
        cb(SAMPLE, nil)
    end
    wt.status = function(_, cb)
        cb({ dirty = false, ahead = 0, head = "head456" }, nil)
    end
    wt.snapshot = function(info, cb)
        wt.calls.snapshot[#wt.calls.snapshot + 1] = info
        cb("/repo/.git/pi2-snapshots/wt1/20250101-000000.patch", nil)
    end
    wt.remove = function(info, opts, cb)
        wt.calls.remove[#wt.calls.remove + 1] = { info = info, opts = opts }
        cb(true, nil, "/repo/.git/pi2-snapshots/wt1/20250101-000000.patch")
    end
    wt.release = function(info, cb)
        wt.calls.release[#wt.calls.release + 1] = { info = info, cb = cb }
        if type(cb) == "function" then
            cb(true, nil)
        end
    end
    wt.branch = function(_, _, cb)
        cb(true, nil)
    end
    for k, v in pairs(overrides or {}) do
        wt[k] = v
    end
    package.loaded["pi.worktree"] = wt
    return wt
end

local function restore()
    vim.wait(20)
    Sessions.get = real.get
    Sessions.get_by_id = real.get_by_id
    Sessions.get_or_create = real.get_or_create
    Sessions.list_all = real.list_all
    vim.notify = real.notify
    vim.ui.select = real.select
    vim.api.nvim_set_current_tabpage = real.set_tab
    package.loaded["pi.worktree"] = real.worktree
    WorktreeSession._set_apply_runner(nil)
    DiffReview.close()
    Sessions._reset()
    Config.setup({})
    -- `tbl_deep_extend` can reuse the defaults sub-table, so a test that flips
    -- this option must not leak it into later tests (Config.setup alone may
    -- re-read the mutated default).
    if type(Config.options.worktree) == "table" then
        Config.options.worktree.snapshot_before_remove = true
    end
end

describe("release_orphan", function()
    before_each(install_spies)
    after_each(restore)

    it("calls Worktree.release with a callback when session start fails", function()
        local wt = install_worktree()
        Sessions.get = function()
            return nil
        end
        Sessions.get_or_create = function()
            return nil
        end

        WorktreeSession.new({ name = "orphan" })
        wait_for(function()
            return #wt.calls.release == 1
        end)
        local call = wt.calls.release[1]
        assert.is_not_nil(call.info)
        assert.equals("/repo/.worktrees/wt-new", call.info.path)
        -- Regression: a missing callback makes the real Worktree.release a no-op.
        assert.is_function(call.cb)
        assert.is_not_nil(find_note("Failed to start a session in the worktree"))
    end)
end)

describe("worktree target resolution", function()
    before_each(install_spies)
    after_each(restore)

    it("defaults to the current session's worktree", function()
        local info = fake_info()
        install_worktree()
        Sessions.get = function()
            return fake_session({ worktree = info })
        end
        local resolved, err = WorktreeSession._resolve_target(nil)
        assert.is_nil(err)
        assert.equals(info, resolved)
    end)

    it("rejects names that could escape the worktrees directory", function()
        install_worktree()
        Sessions.get = function()
            return fake_session({ worktree = fake_info() })
        end
        for _, name in ipairs({ "../evil", "a/b", ".hidden", "with space" }) do
            local resolved, err = WorktreeSession._resolve_target(name)
            assert.is_nil(resolved)
            assert.is_not_nil(err)
        end
    end)

    it("resolves an existing sibling name under <repo>/.worktrees", function()
        local repo = mkdir(vim.fn.tempname() .. "-repo")
        vim.fn.mkdir(repo .. "/.worktrees/wt2", "p")
        local wt = install_worktree()
        wt.detect = function(path)
            if path == repo .. "/.worktrees/wt2" then
                return fake_info({ name = "wt2", path = path, repo_root = repo })
            end
            return nil
        end
        Sessions.get = function()
            return fake_session({
                worktree = fake_info({ name = "wt1", path = repo .. "/.worktrees/wt1", repo_root = repo }),
            })
        end

        local resolved, err = WorktreeSession._resolve_target("wt2")
        assert.is_nil(err)
        assert.equals("wt2", resolved.name)
        assert.equals(repo .. "/.worktrees/wt2", resolved.path)
    end)

    it("reports a missing worktree name", function()
        local repo = mkdir(vim.fn.tempname() .. "-repo")
        install_worktree()
        Sessions.get = function()
            return fake_session({ worktree = fake_info({ name = "other", repo_root = repo }) })
        end
        local resolved, err = WorktreeSession._resolve_target("nope")
        assert.is_nil(resolved)
        assert.is_not_nil(err)
        assert.is_truthy(err:find("not found", 1, true))
    end)
end)

describe(":PiWorktreeApply", function()
    local wt
    local info
    local apply_calls

    before_each(function()
        install_spies()
        apply_calls = {}
        info = fake_info()
        wt = install_worktree()
        Sessions.get = function()
            return fake_session({ worktree = info })
        end
        WorktreeSession._set_apply_runner(function(repo_root, patch, cb)
            apply_calls[#apply_calls + 1] = { repo_root = repo_root, patch = patch }
            cb(true)
        end)
    end)

    after_each(restore)

    it("renders the review first and applies only after explicit accept", function()
        local finished
        WorktreeSession.apply({}, function(ok)
            finished = ok
        end)
        wait_for(function()
            return DiffReview.is_open()
        end)
        assert.equals(0, #apply_calls)
        assert.is_not_nil(DiffReview._accept_label())
        -- Review files are anchored at the worktree, not at Neovim's cwd.
        local anchored = false
        for _, target in pairs(DiffReview._targets()) do
            assert.equals(info.path .. "/a.txt", target.path)
            anchored = true
        end
        assert.is_true(anchored)

        DiffReview._accept()
        wait_for(function()
            return #apply_calls == 1 and finished == true
        end)
        assert.equals("/repo", apply_calls[1].repo_root)
        assert.equals(SAMPLE, apply_calls[1].patch)
        assert.is_false(DiffReview.is_open())
        assert.is_not_nil(find_note("Applied worktree patch", vim.log.levels.INFO))
        assert.is_truthy(find_note("working tree only", vim.log.levels.INFO).msg)
    end)

    it("does not apply when the review is closed without accepting", function()
        local finished
        WorktreeSession.apply({}, function(ok)
            finished = ok
        end)
        wait_for(function()
            return DiffReview.is_open()
        end)
        DiffReview.close()
        vim.wait(50)
        assert.equals(0, #apply_calls)
        assert.is_nil(finished)
    end)

    it("prefills the accept hint with the main checkout label", function()
        WorktreeSession.apply({})
        wait_for(function()
            return DiffReview.is_open()
        end)
        assert.equals("apply to repo", DiffReview._accept_label())
        DiffReview.close()
    end)

    it("reports an empty diff and opens no review", function()
        wt.diff = function(_, cb)
            cb("", nil)
        end
        WorktreeSession.apply({})
        wait_for(function()
            return find_note("No changes to apply", vim.log.levels.INFO) ~= nil
        end)
        assert.is_false(DiffReview.is_open())
        assert.equals(0, #apply_calls)
    end)

    it("reports a diff read failure", function()
        wt.diff = function(_, cb)
            cb(nil, "git diff exploded")
        end
        WorktreeSession.apply({})
        wait_for(function()
            return find_note("Failed to read the worktree diff", vim.log.levels.ERROR) ~= nil
        end)
        assert.is_false(DiffReview.is_open())
        assert.equals(0, #apply_calls)
    end)

    it("reports a diff without reviewable sections", function()
        wt.diff = function(_, cb)
            cb("not a diff at all", nil)
        end
        WorktreeSession.apply({})
        wait_for(function()
            return find_note("no reviewable file sections", vim.log.levels.WARN) ~= nil
        end)
        assert.is_false(DiffReview.is_open())
        assert.equals(0, #apply_calls)
    end)

    it("surfaces a conflicting/failed git apply without deleting the worktree", function()
        WorktreeSession._set_apply_runner(function(_, _, cb)
            cb(false, "error: patch does not apply")
        end)
        local finished
        WorktreeSession.apply({}, function(ok)
            finished = ok
        end)
        wait_for(function()
            return DiffReview.is_open()
        end)
        DiffReview._accept()
        wait_for(function()
            return find_note("git apply failed", vim.log.levels.ERROR) ~= nil
        end)
        assert.is_false(finished)
        assert.is_true(vim.fn.isdirectory(info.path) ~= 1) -- never created/deleted here
        assert.equals(0, #wt.calls.remove)
        assert.equals(0, #wt.calls.release)
    end)

    it("warns before applying while the main checkout has a running session", function()
        local main = fake_session({ id = "main-live", cwd = info.repo_root, worktree = nil })
        Sessions.list_all = function()
            return { main }
        end
        local dialogs_before = #dialogs
        local finished
        WorktreeSession.apply({}, function(ok)
            finished = ok
        end)
        wait_for(function()
            return DiffReview.is_open()
        end)
        DiffReview._accept()
        wait_for(function()
            return finished == true
        end)
        assert.equals(dialogs_before + 1, #dialogs)
        assert.is_truthy(dialogs[#dialogs].opts.prompt:find("running", 1, true))
        assert.equals(1, #apply_calls)
    end)

    it("does not write when the live-checkout warning is cancelled", function()
        local main = fake_session({ id = "main-live", cwd = info.repo_root })
        Sessions.list_all = function()
            return { main }
        end
        dialog_answer = "No"
        local finished
        WorktreeSession.apply({}, function(ok)
            finished = ok
        end)
        wait_for(function()
            return DiffReview.is_open()
        end)
        DiffReview._accept()
        wait_for(function()
            return finished == false
        end)
        assert.equals(0, #apply_calls)
        assert.is_not_nil(find_note("patch not applied", vim.log.levels.INFO))
    end)

    it("refuses when a different session appears before the write (race)", function()
        local first = fake_session({ id = "main-first", cwd = info.repo_root })
        local second = fake_session({ id = "main-second", cwd = info.repo_root })
        local current_live = first
        Sessions.list_all = function()
            return { current_live }
        end
        vim.ui.select = function(items, opts, on_choice)
            dialogs[#dialogs + 1] = { items = items, opts = opts }
            -- A new session starts while the warning is on screen.
            current_live = second
            on_choice("Yes")
        end
        local finished
        WorktreeSession.apply({}, function(ok)
            finished = ok
        end)
        wait_for(function()
            return DiffReview.is_open()
        end)
        DiffReview._accept()
        wait_for(function()
            return finished == false
        end)
        assert.equals(0, #apply_calls)
        assert.is_not_nil(find_note("now has a running π session", vim.log.levels.ERROR))
    end)

    it("re-checks the main checkout right before a warning-free apply (race)", function()
        local main = fake_session({ id = "main-late", cwd = info.repo_root })
        local calls = 0
        Sessions.list_all = function()
            calls = calls + 1
            return calls >= 2 and { main } or {}
        end
        local finished
        WorktreeSession.apply({}, function(ok)
            finished = ok
        end)
        wait_for(function()
            return DiffReview.is_open()
        end)
        DiffReview._accept()
        wait_for(function()
            return finished == false
        end)
        assert.equals(0, #apply_calls)
        assert.is_not_nil(find_note("now has a running π session", vim.log.levels.ERROR))
    end)
end)

describe(":PiWorktreeShip", function()
    local wt
    local info

    before_each(function()
        install_spies()
        info = fake_info()
        wt = install_worktree()
    end)

    after_each(restore)

    it("prefills the current session's prompt and never sends it", function()
        local session = fake_session({ worktree = info })
        Sessions.get = function()
            return session
        end
        Sessions.list_all = function()
            return { session }
        end
        Sessions.get_by_id = function()
            return session
        end

        local finished
        WorktreeSession.ship({}, function(ok)
            finished = ok
        end)
        wait_for(function()
            return #session.drafts == 1 and finished == true
        end)

        local draft = session.drafts[1]
        assert.is_truthy(draft:find("/repo/.worktrees/wt1", 1, true))
        assert.is_truthy(draft:find("base123", 1, true))
        assert.is_truthy(draft:find("detached", 1, true))
        assert.is_truthy(draft:find("pull request", 1, true))
        assert.is_truthy(draft:find("conflict", 1, true))
        assert.is_truthy(draft:find("switch -c", 1, true))
        assert.equals(0, session.sent)
        assert.equals(1, session.focused)
        assert.is_not_nil(find_note("prefilled (not sent)", vim.log.levels.INFO))
    end)

    it("switches to another registered session's tab before prefilling", function()
        local repo = mkdir(vim.fn.tempname() .. "-ship-switch")
        vim.fn.mkdir(repo .. "/.worktrees/wt1", "p")
        local target_info = fake_info({ name = "wt1", path = repo .. "/.worktrees/wt1", repo_root = repo })
        wt.detect = function(path)
            return path == target_info.path and target_info or nil
        end
        local current = fake_session({
            id = "current",
            worktree = fake_info({ name = "other", path = repo .. "/.worktrees/other", repo_root = repo }),
        })
        local target =
            fake_session({ id = "sess-wt1", worktree = target_info, attached_tab = vim.api.nvim_get_current_tabpage() })
        Sessions.get = function()
            return current
        end
        Sessions.get_by_id = function(id)
            return id == "sess-wt1" and target or nil
        end
        Sessions.list_all = function()
            return { current, target }
        end
        local switched
        vim.api.nvim_set_current_tabpage = function(tab)
            switched = tab
        end

        WorktreeSession.ship({ name = "wt1" })
        wait_for(function()
            return #target.drafts == 1
        end)
        assert.equals(vim.api.nvim_get_current_tabpage(), switched)
        assert.equals(0, target.sent)
    end)

    it("errors clearly when no session is registered for the worktree", function()
        Sessions.get = function()
            return fake_session({ id = "current", worktree = nil })
        end
        Sessions.list_all = function()
            return {}
        end
        Sessions.get_by_id = function()
            return nil
        end
        -- resolve via an explicit name so the target does not have to be current
        local repo = mkdir(vim.fn.tempname() .. "-ship")
        vim.fn.mkdir(repo .. "/.worktrees/wt9", "p")
        wt.detect = function(path)
            if path == repo .. "/.worktrees/wt9" then
                return fake_info({ name = "wt9", path = path, repo_root = repo })
            end
            return nil
        end
        Sessions.get = function()
            return fake_session({ id = "current", worktree = fake_info({ repo_root = repo }) })
        end

        WorktreeSession.ship({ name = "wt9" })
        wait_for(function()
            return find_note("No registered π session for worktree 'wt9'", vim.log.levels.ERROR) ~= nil
        end)
    end)

    it("errors when the target session has no attached chat", function()
        local repo = mkdir(vim.fn.tempname() .. "-ship-nochat")
        vim.fn.mkdir(repo .. "/.worktrees/wt1", "p")
        local target_info = fake_info({ name = "wt1", path = repo .. "/.worktrees/wt1", repo_root = repo })
        wt.detect = function(path)
            return path == target_info.path and target_info or nil
        end
        local current = fake_session({
            id = "current",
            worktree = fake_info({ name = "other", path = repo .. "/.worktrees/other", repo_root = repo }),
        })
        local target = fake_session({ id = "sess-wt1", worktree = target_info, attached_tab = 77 })
        target.chat = nil
        Sessions.get = function()
            return current
        end
        Sessions.get_by_id = function()
            return target
        end
        Sessions.list_all = function()
            return { current, target }
        end

        WorktreeSession.ship({ name = "wt1" })
        wait_for(function()
            return find_note("has no attached chat", vim.log.levels.ERROR) ~= nil
        end)
    end)
end)

describe(":PiWorktreeRemove", function()
    local wt
    local info

    before_each(function()
        install_spies()
        info = fake_info()
        wt = install_worktree()
        Sessions.get = function()
            return fake_session({ id = "current", worktree = nil })
        end
        Sessions.list_all = function()
            return {}
        end
        Sessions.get_by_id = function()
            return nil
        end
    end)

    after_each(restore)

    it("refuses to delete a worktree with a live session process", function()
        local live = fake_session({ id = "live-1", worktree = info })
        Sessions.list_all = function()
            return { live }
        end

        WorktreeSession.remove({ name = nil })
        -- No target by default (current session has no worktree) -> name-less
        -- call must fail before the dialog; use the explicit name path below.
        assert.equals(0, #dialogs)

        local repo = mkdir(vim.fn.tempname() .. "-live")
        vim.fn.mkdir(repo .. "/.worktrees/wt1", "p")
        wt.detect = function(path)
            if path == repo .. "/.worktrees/wt1" then
                return fake_info({ path = path, repo_root = repo })
            end
            return nil
        end
        Sessions.get = function()
            return fake_session({
                id = "current",
                worktree = fake_info({ name = "other", repo_root = repo, path = repo .. "/.worktrees/other" }),
            })
        end
        live.worktree = fake_info({ path = repo .. "/.worktrees/wt1", repo_root = repo })

        WorktreeSession.remove({ name = "wt1" })
        assert.is_not_nil(find_note("still has a running π session", vim.log.levels.ERROR))
        assert.equals(0, #dialogs)
        assert.equals(0, #wt.calls.remove)
    end)

    it("refuses while a live child inherited the worktree cwd (no worktree field)", function()
        local repo = mkdir(vim.fn.tempname() .. "-inherit")
        local target_path = repo .. "/.worktrees/wt1"
        vim.fn.mkdir(target_path, "p")
        local target = fake_info({ name = "wt1", path = target_path, repo_root = repo })
        wt.detect = function(path)
            return path == target_path and target or nil
        end
        Sessions.get = function()
            return fake_session({
                id = "current",
                worktree = fake_info({ name = "other", path = repo .. "/.worktrees/other", repo_root = repo }),
            })
        end
        -- A child that inherited the parent's worktree carries no worktree
        -- metadata; only its process cwd identifies the checkout. Trailing
        -- separator exercises the normalized comparison.
        local child = fake_session({ id = "child-inherit", worktree = nil, cwd = target_path .. "/" })
        Sessions.list_all = function()
            return { child }
        end

        WorktreeSession.remove({ name = "wt1" })
        assert.is_not_nil(find_note("still has a running π session", vim.log.levels.ERROR))
        assert.equals(0, #dialogs)
        assert.equals(0, #wt.calls.remove)
    end)

    it("refuses when a live session has the worktree as _process_cwd", function()
        Sessions.get = function()
            return fake_session({ id = "current", worktree = info })
        end
        local child = fake_session({ id = "child-proc", worktree = nil, cwd = "/elsewhere", _process_cwd = info.path })
        Sessions.list_all = function()
            return { child }
        end

        WorktreeSession.remove({})
        assert.is_not_nil(find_note("still has a running π session", vim.log.levels.ERROR))
        assert.equals(0, #dialogs)
        assert.equals(0, #wt.calls.remove)
    end)

    it("confirms, snapshots, then forces removal with snapshot disabled", function()
        local snapshot_info
        wt.snapshot = function(target, cb)
            snapshot_info = target
            cb("/snap/wt1.patch", nil)
        end
        wt.status = function(_, cb)
            cb({ dirty = true, ahead = 2, head = "head456" }, nil)
        end
        local removed
        wt.remove = function(target, opts, cb)
            removed = { info = target, opts = opts }
            cb(true, nil, "/snap/wt1.patch")
        end

        local repo = mkdir(vim.fn.tempname() .. "-remove")
        vim.fn.mkdir(repo .. "/.worktrees/wt1", "p")
        wt.detect = function(path)
            if path == repo .. "/.worktrees/wt1" then
                return fake_info({ path = path, repo_root = repo })
            end
            return nil
        end
        Sessions.get = function()
            return fake_session({ id = "current", worktree = fake_info({ name = "other", repo_root = repo }) })
        end

        WorktreeSession.remove({ name = "wt1" })
        wait_for(function()
            return removed ~= nil
        end)
        assert.equals(1, #dialogs)
        assert.is_truthy(dialogs[1].opts.prompt:find("uncommitted changes", 1, true))
        assert.is_truthy(dialogs[1].opts.prompt:find("snapshot", 1, true))
        assert.equals(repo .. "/.worktrees/wt1", snapshot_info.path)
        assert.is_true(removed.opts.force)
        assert.is_false(removed.opts.snapshot)
        assert.is_not_nil(find_note("Removed worktree", vim.log.levels.INFO))
    end)

    it("does not remove anything when the confirmation is declined", function()
        dialog_answer = "No"
        Sessions.get = function()
            return fake_session({ worktree = info })
        end
        WorktreeSession.remove({})
        wait_for(function()
            return #dialogs == 1
        end)
        vim.wait(50)
        assert.equals(0, #wt.calls.snapshot)
        assert.equals(0, #wt.calls.remove)
    end)

    it("refuses to delete when the snapshot fails", function()
        wt.snapshot = function(_, cb)
            cb(nil, "disk full")
        end
        Sessions.get = function()
            return fake_session({ worktree = info })
        end

        WorktreeSession.remove({})
        wait_for(function()
            return find_note("worktree NOT removed", vim.log.levels.ERROR) ~= nil
        end)
        assert.equals(0, #wt.calls.remove)
    end)

    it("skips snapshotting when the config disables it", function()
        local saved = Config.options.worktree.snapshot_before_remove
        Config.options.worktree.snapshot_before_remove = false
        Sessions.get = function()
            return fake_session({ worktree = info })
        end
        WorktreeSession.remove({})
        wait_for(function()
            return #wt.calls.remove == 1
        end)
        assert.equals(0, #wt.calls.snapshot)
        assert.is_false(wt.calls.remove[1].opts.snapshot)
        Config.options.worktree.snapshot_before_remove = saved
    end)

    it("re-checks live sessions after the confirmation (TOCTOU)", function()
        Sessions.get = function()
            return fake_session({ worktree = info })
        end
        local live_now = false
        local live = fake_session({ id = "late-1", worktree = info })
        Sessions.list_all = function()
            return live_now and { live } or {}
        end
        vim.ui.select = function(_, _, cb)
            -- A session is started while the confirmation is on screen.
            live_now = true
            cb("Yes")
        end

        local finished
        WorktreeSession.remove({}, function(ok)
            finished = ok
        end)
        wait_for(function()
            return finished == false
        end)
        assert.is_not_nil(find_note("still has a running π session", vim.log.levels.ERROR))
        assert.equals(0, #wt.calls.snapshot)
        assert.equals(0, #wt.calls.remove)
    end)

    it("re-checks live sessions after the snapshot (TOCTOU)", function()
        Sessions.get = function()
            return fake_session({ worktree = info })
        end
        local live_now = false
        local live = fake_session({ id = "late-2", worktree = info })
        Sessions.list_all = function()
            return live_now and { live } or {}
        end
        wt.snapshot = function(target, cb)
            wt.calls.snapshot[#wt.calls.snapshot + 1] = target
            -- A session is started while the (slow) snapshot is running.
            live_now = true
            cb("/snap/late.patch", nil)
        end

        local finished
        WorktreeSession.remove({}, function(ok)
            finished = ok
        end)
        wait_for(function()
            return finished == false
        end)
        assert.is_not_nil(find_note("still has a running π session", vim.log.levels.ERROR))
        assert.equals(1, #wt.calls.snapshot)
        assert.equals(0, #wt.calls.remove)
    end)

    it("rejects unsafe names before any dialog", function()
        WorktreeSession.remove({ name = "../evil" })
        assert.is_not_nil(find_note("invalid name", vim.log.levels.ERROR))
        assert.equals(0, #dialogs)
        assert.equals(0, #wt.calls.remove)
    end)
end)

describe("worktree command completion and public API", function()
    local wt
    local repo

    before_each(function()
        install_spies()
        repo = mkdir(vim.fn.tempname() .. "-complete")
        vim.fn.mkdir(repo .. "/.worktrees/wt1", "p")
        vim.fn.mkdir(repo .. "/.worktrees/wt2", "p")
        vim.fn.mkdir(repo .. "/.worktrees/.hidden", "p")
        wt = install_worktree()
        Sessions.get = function()
            return fake_session({ worktree = fake_info({ repo_root = repo }) })
        end
    end)

    after_each(restore)

    it("registers the phase-2 commands and public API", function()
        local cmds = vim.api.nvim_get_commands({})
        assert.is_not_nil(cmds["PiWorktreeApply"])
        assert.is_not_nil(cmds["PiWorktreeShip"])
        assert.is_not_nil(cmds["PiWorktreeRemove"])
        assert.is_function(Pi.worktree_apply)
        assert.is_function(Pi.worktree_ship)
        assert.is_function(Pi.worktree_remove)
    end)

    it("completes existing worktree names and filters hidden entries", function()
        local completions = vim.fn.getcompletion("PiWorktreeApply w", "cmdline")
        assert.same({ "wt1", "wt2" }, completions)
    end)

    it("public API tolerates a nil opts table", function()
        -- No worktree on the session and no name -> resolves to a clear error,
        -- never a Lua error.
        Sessions.get = function()
            return fake_session({ worktree = nil })
        end
        wt.detect = function()
            return nil
        end
        assert.has_no.errors(function()
            Pi.worktree_apply(nil)
            Pi.worktree_ship(nil)
            Pi.worktree_remove(nil)
        end)
        assert.is_not_nil(find_note("No worktree target", vim.log.levels.ERROR))
    end)
end)

describe("worktree recovery for cross-worktree resume", function()
    local wt
    local repo
    local Manifest
    local real_locate

    before_each(function()
        install_spies()
        repo = mkdir(vim.fn.tempname() .. "-recover")
        wt = install_worktree()
        Manifest = require("pi.subsessions.manifest")
        real_locate = Manifest.locate
        Sessions.get = function()
            return nil
        end
        Sessions.list_all = function()
            return {}
        end
        Sessions.get_by_id = function()
            return nil
        end
    end)

    after_each(function()
        Manifest.locate = real_locate
        restore()
    end)

    it("recreates a missing worktree at its base and restores the latest snapshot", function()
        local patch = vim.fn.tempname() .. ".patch"
        vim.fn.writefile({ "PATCH-CONTENT" }, patch)
        Manifest.locate = function()
            return nil
        end
        wt.latest_snapshot = function(root, name)
            assert.equals(repo, root)
            assert.equals("wt1", name)
            return { path = patch, meta = { base_sha = "base123", name = "wt1" } }
        end
        local created, applied
        wt.create = function(opts, cb)
            created = opts
            cb({ kind = "linked", name = opts.name, path = repo .. "/.worktrees/" .. opts.name, repo_root = repo }, nil)
        end
        wt.apply_patch = function(dir, text, cb)
            applied = { dir = dir, text = text }
            cb(true, nil)
        end

        local result, err
        WorktreeSession.recover_worktree({ repo_root = repo, name = "wt1", session_id = "s1" }, function(info, e)
            result, err = info, e
        end)
        wait_for(function()
            return result ~= nil or err ~= nil
        end)
        assert.is_nil(err)
        assert.equals(repo .. "/.worktrees/wt1", result.path)
        assert.equals("base123", created.base)
        assert.equals("wt1", created.name)
        assert.equals("resume", created.mode)
        assert.is_not_nil(applied)
        assert.equals(result.path, applied.dir)
        assert.is_truthy(applied.text:find("PATCH-CONTENT", 1, true))
        os.remove(patch)
    end)

    it("recreates at the base without apply_patch when the snapshot is whitespace", function()
        local patch = vim.fn.tempname() .. ".patch"
        vim.fn.writefile({ "   ", "\t", "" }, patch)
        Manifest.locate = function()
            return nil
        end
        wt.latest_snapshot = function()
            return { path = patch, meta = { base_sha = "base123", name = "wt-space" } }
        end
        local created, apply_calls = nil, 0
        wt.create = function(opts, cb)
            created = opts
            cb({ kind = "linked", name = opts.name, path = repo .. "/.worktrees/" .. opts.name, repo_root = repo }, nil)
        end
        wt.apply_patch = function()
            apply_calls = apply_calls + 1
        end

        local result, err
        WorktreeSession.recover_worktree({ repo_root = repo, name = "wt-space" }, function(info, e)
            result, err = info, e
        end)
        wait_for(function()
            return result ~= nil or err ~= nil
        end)
        assert.is_nil(err)
        assert.is_not_nil(result)
        assert.equals("base123", created.base)
        assert.equals(0, apply_calls)
        os.remove(patch)
    end)

    it("creates from the current HEAD and never re-applies integrated work", function()
        Manifest.locate = function(id)
            assert.equals("child-1", id)
            return { integration = { state = "applied", base_sha = "oldbase" } }
        end
        local snapshot_calls = 0
        wt.latest_snapshot = function()
            snapshot_calls = snapshot_calls + 1
            return nil
        end
        local created
        wt.create = function(opts, cb)
            created = opts
            cb({ kind = "linked", name = opts.name, path = repo .. "/.worktrees/" .. opts.name, repo_root = repo }, nil)
        end
        local apply_calls = 0
        wt.apply_patch = function()
            apply_calls = apply_calls + 1
        end

        local result, err
        WorktreeSession.recover_worktree({ repo_root = repo, name = "sub-1", session_id = "child-1" }, function(info, e)
            result, err = info, e
        end)
        wait_for(function()
            return result ~= nil or err ~= nil
        end)
        assert.is_nil(err)
        assert.is_not_nil(result)
        assert.is_nil(created.base) -- current HEAD, not the old base
        assert.equals(0, snapshot_calls)
        assert.equals(0, apply_calls)
    end)

    it("fails clearly when the checkout is gone and no snapshot/metadata exists", function()
        Manifest.locate = function()
            return nil
        end
        wt.latest_snapshot = function()
            return nil
        end
        local create_calls = 0
        wt.create = function(_, cb)
            create_calls = create_calls + 1
            cb(nil, "should not be called")
        end

        local result, err
        WorktreeSession.recover_worktree({ repo_root = repo, name = "wt1" }, function(info, e)
            result, err = info, e
        end)
        assert.is_nil(result)
        assert.is_truthy(err:find("no snapshot or integration record", 1, true))
        assert.equals(0, create_calls)
    end)

    it("reuses an existing checkout without recreating it", function()
        local target = repo .. "/.worktrees/wt1"
        vim.fn.mkdir(target, "p")
        local detected = { kind = "linked", name = "wt1", path = target, repo_root = repo }
        wt.detect = function(path)
            return path == target and detected or nil
        end
        local create_calls = 0
        wt.create = function(_, cb)
            create_calls = create_calls + 1
            cb(nil, "should not be called")
        end

        local result
        WorktreeSession.recover_worktree({ repo_root = repo, name = "wt1" }, function(info)
            result = info
        end)
        assert.equals(detected, result)
        assert.equals(0, create_calls)
    end)

    it("prepare_resume_target keeps an existing target and recovers a missing one", function()
        local existing = mkdir(vim.fn.tempname() .. "-exists")
        local target
        WorktreeSession.prepare_resume_target({ cwd = existing }, function(ctx)
            target = ctx
        end)
        assert.is_not_nil(target)
        assert.equals(existing, target.cwd)

        -- Missing checkout with an integrated child row: recovery opens a new
        -- worktree at the current HEAD.
        Manifest.locate = function(id)
            assert.equals("child-9", id)
            return { integration = { state = "applied" } }
        end
        wt.latest_snapshot = function()
            return nil
        end
        wt.create = function(opts, cb)
            local path = repo .. "/.worktrees/" .. opts.name
            vim.fn.mkdir(path, "p")
            cb({ kind = "linked", name = opts.name, path = path, repo_root = repo }, nil)
        end
        local recovered
        WorktreeSession.prepare_resume_target({
            cwd = repo .. "/.worktrees/wt-missing",
            session_id = "child-9",
        }, function(ctx)
            recovered = ctx
        end)
        wait_for(function()
            return recovered ~= nil
        end)
        assert.equals(repo .. "/.worktrees/wt-missing", recovered.cwd)
        assert.equals("wt-missing", recovered.worktree.name)
        assert.is_not_nil(find_note("Recovered worktree", vim.log.levels.INFO))
    end)
end)

describe("real recover_worktree after release/removal", function()
    local Worktree
    local saved_worktree_module

    local function git(cwd, ...)
        local argv = { "git", "-C", cwd }
        for _, arg in ipairs({ ... }) do
            argv[#argv + 1] = arg
        end
        local res = vim.system(argv, { text = true }):wait()
        assert.equals(0, res.code, table.concat(argv, " ") .. ": " .. tostring(res.stderr))
        return res.stdout or ""
    end

    local function make_repo()
        local repo = vim.fn.tempname() .. "-real-wt"
        vim.fn.mkdir(repo, "p")
        git(repo, "init", "-q", "-b", "main")
        git(repo, "config", "user.email", "t@t")
        git(repo, "config", "user.name", "t")
        vim.fn.writefile({ "one" }, repo .. "/a.txt")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "init")
        return repo
    end

    local function create(repo, name)
        local info, err
        Worktree.create({ cwd = repo, name = name }, function(value, e)
            info, err = value, e
        end)
        wait_for(function()
            return info ~= nil or err ~= nil
        end)
        assert.is_nil(err)
        assert.is_not_nil(info)
        return info
    end

    before_each(function()
        Config.setup({})
        saved_worktree_module = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = nil
        Worktree = require("pi.worktree")
        Worktree._reset()
    end)

    after_each(function()
        package.loaded["pi.worktree"] = saved_worktree_module
    end)

    it("recovers a clean released checkout from its empty snapshot without applying", function()
        local repo = make_repo()
        local info = create(repo, "wt-clean")
        local base = info.base_sha
        assert.is_truthy(base)

        local removed, release_err
        Worktree.release(info, function(value, e)
            removed, release_err = value, e
        end)
        wait_for(function()
            return removed ~= nil or release_err ~= nil
        end)
        assert.is_true(removed, tostring(release_err))
        assert.equals(0, vim.fn.isdirectory(info.path))
        local snap = Worktree.latest_snapshot(repo, "wt-clean")
        assert.is_not_nil(snap)
        local patch_text = table.concat(vim.fn.readfile(snap.path), "\n")
        assert.equals("", vim.trim(patch_text))

        -- Spy on apply_patch: an empty snapshot must not be applied.
        local real_apply = Worktree.apply_patch
        local apply_calls = 0
        Worktree.apply_patch = function(...)
            apply_calls = apply_calls + 1
            return real_apply(...)
        end
        local recovered, recover_err
        WorktreeSession.recover_worktree({ repo_root = repo, name = "wt-clean" }, function(value, e)
            recovered, recover_err = value, e
        end)
        wait_for(function()
            return recovered ~= nil or recover_err ~= nil
        end)
        Worktree.apply_patch = real_apply
        assert.is_nil(recover_err)
        assert.is_not_nil(recovered)
        assert.equals(0, apply_calls)
        assert.equals(1, vim.fn.isdirectory(recovered.path))
        local head = vim.trim(git(recovered.path, "rev-parse", "HEAD"))
        assert.equals(base, head)
        vim.fn.delete(repo, "rf")
    end)

    it("restores a dirty checkout from the snapshot left by an explicit removal", function()
        local repo = make_repo()
        local info = create(repo, "wt-work")
        local base = info.base_sha
        vim.fn.writefile({ "one", "two" }, info.path .. "/a.txt")
        vim.fn.writefile({ "brand new" }, info.path .. "/new.txt")

        local snapshot_path, snapshot_err
        Worktree.snapshot(info, function(value, e)
            snapshot_path, snapshot_err = value, e
        end)
        wait_for(function()
            return snapshot_path ~= nil or snapshot_err ~= nil
        end)
        assert.is_not_nil(snapshot_path, tostring(snapshot_err))

        local removed, remove_err
        Worktree.remove(info, { force = true, snapshot = false }, function(value, e)
            removed, remove_err = value, e
        end)
        wait_for(function()
            return removed ~= nil or remove_err ~= nil
        end)
        assert.is_true(removed, tostring(remove_err))
        assert.equals(0, vim.fn.isdirectory(info.path))

        local recovered, recover_err
        WorktreeSession.recover_worktree({ repo_root = repo, name = "wt-work" }, function(value, e)
            recovered, recover_err = value, e
        end)
        wait_for(function()
            return recovered ~= nil or recover_err ~= nil
        end)
        assert.is_nil(recover_err)
        assert.is_not_nil(recovered)
        assert.equals(1, vim.fn.isdirectory(recovered.path))
        assert.same({ "one", "two" }, vim.fn.readfile(recovered.path .. "/a.txt"))
        assert.same({ "brand new" }, vim.fn.readfile(recovered.path .. "/new.txt"))
        local head = vim.trim(git(recovered.path, "rev-parse", "HEAD"))
        assert.equals(base, head)
        vim.fn.delete(repo, "rf")
    end)
end)
