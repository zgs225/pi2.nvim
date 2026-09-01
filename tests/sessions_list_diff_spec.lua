-- Sessions-overview key `d`: open the diff review (:PiDiff) of the session
-- under the cursor — the review uses the row's session's changed_files and
-- cwd (not the current tab's), and stays in the current tab. Covers the
-- keymap registration, the float content, and the dead-process / no-changed-
-- files warnings.

local SessionList = require("pi.ui.sessions")
local DiffReview = require("pi.ui.diff_review")

---@type string[]
local cleanup_dirs = {}

---@return string resolved tmp dir (removed after each test)
local function tmp_dir()
    local dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    cleanup_dirs[#cleanup_dirs + 1] = dir
    return dir
end

local function git(dir, ...)
    return vim.fn.system({ "git", "-C", dir, ... })
end

--- Fresh git repo with one committed file (v1).
---@param dir string
---@return string
local function init_repo(dir)
    vim.fn.mkdir(dir, "p")
    git(dir, "init", "-q", "-b", "main")
    git(dir, "config", "user.email", "t@t")
    git(dir, "config", "user.name", "t")
    vim.fn.writefile({ "v1" }, dir .. "/a.txt")
    git(dir, "add", "a.txt")
    git(dir, "commit", "-qm", "one")
    -- Working-tree modification (v2): the review shows `git diff HEAD`.
    vim.fn.writefile({ "v2" }, dir .. "/a.txt")
    return dir
end

--- Fake session carrying the client-side diff state the review needs
--- (changed_files / cwd), plus a scripted rpc:send for the list's name fetch.
---@param opts? { running?: boolean, tab?: integer, cwd?: string, changed_files?: table<string, true> }
local function diff_session(opts)
    opts = opts or {}
    local s = {
        tab = opts.tab or vim.api.nvim_get_current_tabpage(),
        cwd = opts.cwd,
        changed_files = opts.changed_files or {},
        rpc = {
            is_running = function()
                return opts.running ~= false
            end,
        },
        chat = {
            is_compacting = function()
                return false
            end,
            is_streaming = function()
                return false
            end,
        },
    }
    s.rpc.send = function(_, req, cb)
        if req.type == "get_state" then
            vim.schedule(function()
                cb({ success = true, data = { sessionName = "diff session" } })
            end)
        end
        return true
    end
    return s
end

--- Run fn with the session manager stubbed to `sessions` and no current
--- session, so the list renders exactly those rows and a fallback to the
--- current tab's session would resolve to nothing.
---@param sessions pi.Session[]
---@param fn fun()
local function with_manager(sessions, fn)
    local real_manager = package.loaded["pi.sessions.manager"]
    package.loaded["pi.sessions.manager"] = {
        list = function()
            return sessions
        end,
        get = function()
            return nil
        end,
    }
    local ok, err = pcall(fn)
    package.loaded["pi.sessions.manager"] = real_manager
    if not ok then
        error(err)
    end
end

local function press_key(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
end

--- Find the review's file-list float and the diff float.
---@return integer? list_win
---@return integer? list_buf
---@return integer? diff_buf
local function find_review_wins()
    local list_win, list_buf, diff_buf = nil, nil, nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        local name = vim.api.nvim_buf_get_name(buf)
        if vim.bo[buf].filetype == "pi-diff-review" and name:find("pi://diff-review-files", 1, true) then
            list_win, list_buf = win, buf
        elseif vim.bo[buf].filetype == "diff" then
            diff_buf = buf
        end
    end
    return list_win, list_buf, diff_buf
end

describe("session list diff key", function()
    before_each(function()
        SessionList._reset()
        DiffReview._reset()
    end)

    after_each(function()
        pcall(SessionList.close)
        SessionList._reset()
        DiffReview._reset()
        for _, dir in ipairs(cleanup_dirs) do
            pcall(vim.fn.delete, dir, "rf")
        end
        cleanup_dirs = {}
    end)

    it("binds d to the diff action in the list buffer", function()
        SessionList.open()
        local map = vim.fn.maparg("d", "n", false, true)
        assert.equals(1, map.buffer)
        assert.equals("Review this session's diff", map.desc)
    end)

    it("opens the review of the row session's changed files in the current tab", function()
        local dir = init_repo(tmp_dir())
        local s = diff_session({ cwd = dir, changed_files = { ["a.txt"] = true } })
        with_manager({ s }, function()
            SessionList.open()
            vim.wait(1000, function()
                return SessionList._name_of(s) ~= nil
            end)
            press_key("d")

            local list_win, list_buf, diff_buf
            vim.wait(10000, function()
                list_win, list_buf, diff_buf = find_review_wins()
                return list_buf ~= nil and diff_buf ~= nil
            end, 20)
            assert.is_not_nil(list_buf, "diff review did not open")

            -- The review stays in the current tab (no jump to the session's).
            assert.are.equal(vim.api.nvim_get_current_tabpage(), vim.fn.win_id2tabwin(list_win)[1])
            local list_text = table.concat(vim.api.nvim_buf_get_lines(list_buf, 0, -1, false), "\n")
            assert.is_truthy(list_text:find("M a.txt", 1, true), "list should show the row session's changed file")
            local diff_text = table.concat(vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false), "\n")
            assert.is_truthy(diff_text:find("-v1", 1, true), "diff should show the removed line")
            assert.is_truthy(diff_text:find("+v2", 1, true), "diff should show the added line")
        end)
    end)

    it("targets the row's session, not the current tab's", function()
        -- Two listed sessions; the current tab's is a different one. The
        -- manager stub's get() returns nil, so only the row's own
        -- changed_files/cwd can produce a review.
        local dir = init_repo(tmp_dir())
        local a = diff_session({ tab = 1000, changed_files = { ["other.txt"] = true } })
        local b = diff_session({ cwd = dir, changed_files = { ["a.txt"] = true } })
        with_manager({ a, b }, function()
            SessionList.open()
            vim.wait(1000, function()
                return SessionList._name_of(a) ~= nil and SessionList._name_of(b) ~= nil
            end)
            -- Row 1 belongs to the fake tab 1000 (not a real tabpage), so d
            -- on it would silently no-op; only row 2 can open a review.
            assert.are.equal(2, #vim.api.nvim_buf_get_lines(0, 0, -1, false))
            vim.api.nvim_win_set_cursor(0, { 2, 0 })
            press_key("d")

            local _, list_buf
            vim.wait(10000, function()
                _, list_buf = find_review_wins()
                return list_buf ~= nil
            end, 20)
            assert.is_not_nil(list_buf, "diff review did not open for the row under the cursor")
            local list_text = table.concat(vim.api.nvim_buf_get_lines(list_buf, 0, -1, false), "\n")
            assert.is_truthy(list_text:find("M a.txt", 1, true), "review should show the row session's file")
            assert.is_falsy(list_text:find("other.txt", 1, true))
        end)
    end)

    it("warns on a dead session instead of opening the review", function()
        local real_notify = package.loaded["pi.notify"]
        local warnings = {}
        package.loaded["pi.notify"] = {
            warn = function(msg)
                table.insert(warnings, msg)
            end,
        }
        local s = diff_session({ running = false, changed_files = { ["a.txt"] = true } })
        with_manager({ s }, function()
            SessionList.open()
            assert.is_nil(SessionList._name_of(s))
            press_key("d")
            vim.wait(200, function()
                return false
            end)
        end)
        package.loaded["pi.notify"] = real_notify

        assert.equals(1, #warnings)
        assert.is_truthy(warnings[1]:find("not running", 1, true))
        local _, list_buf = find_review_wins()
        assert.is_nil(list_buf)
    end)

    it("warns when the row session has no changed files", function()
        local real_notify = package.loaded["pi.notify"]
        local warnings = {}
        package.loaded["pi.notify"] = {
            warn = function(msg)
                table.insert(warnings, msg)
            end,
        }
        local s = diff_session({ changed_files = {} })
        with_manager({ s }, function()
            SessionList.open()
            vim.wait(1000, function()
                return SessionList._name_of(s) ~= nil
            end)
            press_key("d")
            vim.wait(200, function()
                return false
            end)
        end)
        package.loaded["pi.notify"] = real_notify

        assert.equals(1, #warnings)
        assert.is_truthy(warnings[1]:find("no files changed", 1, true))
        local _, list_buf = find_review_wins()
        assert.is_nil(list_buf)
    end)
end)
