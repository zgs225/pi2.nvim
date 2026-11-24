-- Chat history title: the worktree badge (`π 󰙅 name`) in the side-layout
-- winbar and the float border title. Covers the display matrix (main
-- worktree + matching cwd = no badge, linked worktree, dirty/ahead `*`, and
-- the `⚠` reserved for a divergence the badge cannot show on its own),
-- breadcrumb priority, `%` escaping for the winbar expression, the
-- layout/show re-apply, and the workspace caches (`_prompt_history` /
-- `_prompt_nav`) reset by `set_cwd`.
--
-- `pi.worktree` is stubbed through package.loaded so nothing shells out to
-- git; its own spec covers detection.

local Chat = require("pi.ui.chat")
local Config = require("pi.config")

local GLYPH = "󰙅"
local TAB = 875

---@class pi.SpecWorktreeStub
---@field detect_dir string|"*" directory `detect` answers for, or "*" for any
---@field info table? what `detect` returns
---@field calls { info: table, cb: fun(status: table) }[] recorded `status` calls

--- Install a `pi.worktree` stub through package.loaded and return a mutable
--- controller for it.
---@param info table? what `detect` returns for any directory
---@return pi.SpecWorktreeStub
local function stub_worktree(info)
    local stub = { detect_dir = "*", info = info, calls = {} }
    package.loaded["pi.worktree"] = {
        detect = function(dir)
            if stub.detect_dir ~= "*" and stub.detect_dir ~= dir then
                return nil
            end
            return stub.info
        end,
        status = function(info_arg, cb)
            stub.calls[#stub.calls + 1] = { info = info_arg, cb = cb }
        end,
    }
    return stub
end

---@param mode pi.LayoutMode
---@return pi.Chat
local function setup_chat(mode)
    local chat = Chat.new(TAB, mode, {
        send = function()
            return true
        end,
    })
    chat:ensure_shown_and_focus_prompt()
    return chat
end

---@param chat pi.Chat
local function teardown_chat(chat)
    chat._layout:hide()
    pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
    local wins = vim.api.nvim_list_wins()
    for i = 2, #wins do
        pcall(vim.api.nvim_win_close, wins[i], false)
    end
end

---@param chat pi.Chat
---@return string winbar of the history window
local function history_winbar(chat)
    local win = assert(chat._layout:history_win())
    return assert(vim.api.nvim_win_get_option(win, "winbar"))
end

--- Flatten a float title: Neovim reports it as plain text or as a list of
--- `[text, hl]` chunks.
---@param title string|table
---@return string
local function title_text(title)
    if type(title) == "string" then
        return title
    end
    local parts = {}
    for _, chunk in ipairs(title) do
        parts[#parts + 1] = chunk[1]
    end
    return table.concat(parts)
end

---@param chat pi.Chat
---@return string title of the history float
local function history_float_title(chat)
    local win = assert(chat._layout:history_win())
    return title_text(vim.api.nvim_win_get_config(win).title)
end

--- Run every recorded `status` callback and let the scheduled title refresh
--- land.
---@param stub pi.SpecWorktreeStub
---@param status table
local function resolve_status(stub, status)
    for _, call in ipairs(stub.calls) do
        call.cb(status)
    end
    vim.wait(100, function()
        return false
    end, 10)
end

describe("chat history worktree badge", function()
    local real_worktree_module

    before_each(function()
        Config.setup({})
        real_worktree_module = package.loaded["pi.worktree"]
    end)

    after_each(function()
        package.loaded["pi.worktree"] = real_worktree_module
    end)

    describe("display matrix (pure)", function()
        local main = { kind = "main", name = "repo", path = "/repo" }
        local linked = { kind = "linked", name = "wt", path = "/repo-wt", repo_root = "/repo" }

        it("hides the badge for the main worktree when the cwd matches", function()
            assert.is_nil(Chat.worktree_badge(main, true, nil))
            assert.is_nil(Chat.worktree_badge(main, true, { dirty = true }))
        end)

        it("names a linked worktree, whether or not its cwd matches", function()
            assert.are.same({ { GLYPH .. " wt", "PiChatHistoryWorktree" } }, Chat.worktree_badge(linked, true, nil))
            -- A worktree session normally runs outside Neovim's cwd: the glyph
            -- is the whole signal, with no `⚠` prefix and no warning color.
            assert.are.same(
                { { GLYPH .. " wt", "PiChatHistoryWorktree" } },
                Chat.worktree_badge(linked, false, nil, "/repo-wt")
            )
        end)

        it("marks a dirty or ahead linked worktree with *", function()
            assert.are.same(
                { { GLYPH .. " wt*", "PiChatHistoryWorktree" } },
                Chat.worktree_badge(linked, true, { dirty = true })
            )
            assert.are.same(
                { { GLYPH .. " wt*", "PiChatHistoryWorktree" } },
                Chat.worktree_badge(linked, true, { dirty = false, ahead = 2 })
            )
            assert.are.same(
                { { GLYPH .. " wt", "PiChatHistoryWorktree" } },
                Chat.worktree_badge(linked, true, { dirty = false, ahead = 0 })
            )
            -- The dirty marker survives the usual cwd mismatch too.
            assert.are.same(
                { { GLYPH .. " wt*", "PiChatHistoryWorktree" } },
                Chat.worktree_badge(linked, false, { dirty = true }, "/repo-wt")
            )
        end)

        it("warns only where the badge cannot show the divergence itself", function()
            -- Main checkout elsewhere: its repository name, in the warning color.
            assert.are.same({ { "⚠ repo", "PiStatusLineWarning" } }, Chat.worktree_badge(main, false, nil, "/repo"))
            -- Not a work tree at all: the directory's own name.
            assert.are.same(
                { { "⚠ scratch", "PiStatusLineWarning" } },
                Chat.worktree_badge(nil, false, nil, "/tmp/scratch")
            )
            assert.are.same(
                { { "⚠ notes", "PiStatusLineWarning" } },
                Chat.worktree_badge(nil, false, nil, "/home/me/notes/")
            )
            -- Matching cwd: nothing to warn about, in any kind of directory.
            assert.is_nil(Chat.worktree_badge(nil, true, nil, "/tmp/scratch"))
            -- No usable directory name: no badge rather than a bare `⚠`.
            assert.is_nil(Chat.worktree_badge(nil, false, nil, nil))
            assert.is_nil(Chat.worktree_badge(nil, false, nil, "/"))
        end)

        it("ignores unknown or anonymous worktrees", function()
            assert.is_nil(Chat.worktree_badge(nil, true, nil))
            assert.is_nil(Chat.worktree_badge({ kind = "other", name = "x" }, true, nil))
            assert.is_nil(Chat.worktree_badge({ kind = "linked", name = "" }, true, nil))
            -- An unusable worktree label falls back to the directory's own name.
            assert.are.same(
                { { "⚠ scratch", "PiStatusLineWarning" } },
                Chat.worktree_badge({ kind = "other", name = "x" }, false, nil, "/tmp/scratch")
            )
        end)
    end)

    describe("side layout winbar", function()
        it("keeps the plain title in the main worktree with a matching cwd", function()
            local chat = setup_chat("side")
            local cwd = vim.fn.getcwd()
            stub_worktree({ kind = "main", name = "repo", path = cwd, repo_root = cwd })

            chat:set_cwd(cwd)

            local winbar = history_winbar(chat)
            assert.is_truthy(winbar:find("π", 1, true))
            assert.is_nil(winbar:find(GLYPH, 1, true))
            teardown_chat(chat)
        end)

        it("shows the linked worktree and its dirty marker", function()
            local chat = setup_chat("side")
            local stub = stub_worktree({ kind = "linked", name = "wt", path = "/tmp/wt", repo_root = "/tmp/main" })

            chat:set_cwd(vim.fn.getcwd())
            local winbar = history_winbar(chat)
            assert.is_truthy(winbar:find(GLYPH .. " wt", 1, true))
            assert.is_truthy(winbar:find("PiChatHistoryWorktree", 1, true))
            assert.is_nil(winbar:find("*", 1, true))

            -- The async status lands as `*` (dirty or ahead).
            resolve_status(stub, { dirty = true, ahead = 0 })
            assert.is_truthy(history_winbar(chat):find(GLYPH .. " wt*", 1, true))

            teardown_chat(chat)
        end)

        it("does not warn for a linked worktree whose cwd differs", function()
            local chat = setup_chat("side")
            stub_worktree({ kind = "linked", name = "wt", path = "/tmp/wt", repo_root = "/tmp/main" })

            chat:set_cwd(vim.fn.getcwd() .. "-somewhere-else")

            local winbar = history_winbar(chat)
            assert.is_truthy(winbar:find(GLYPH .. " wt", 1, true))
            assert.is_truthy(winbar:find("PiChatHistoryWorktree", 1, true))
            assert.is_nil(winbar:find("⚠", 1, true))
            teardown_chat(chat)
        end)

        it("warns in the warning color when the main checkout's cwd differs", function()
            local chat = setup_chat("side")
            stub_worktree({ kind = "main", name = "repo", path = "/tmp/main", repo_root = "/tmp/main" })

            chat:set_cwd(vim.fn.getcwd() .. "-somewhere-else")

            local winbar = history_winbar(chat)
            assert.is_truthy(winbar:find("⚠ repo", 1, true))
            assert.is_truthy(winbar:find("PiStatusLineWarning", 1, true))
            assert.is_nil(winbar:find(GLYPH, 1, true))
            teardown_chat(chat)
        end)

        it("lets the sub-session breadcrumb win over the badge", function()
            local chat = setup_chat("side")
            stub_worktree({ kind = "linked", name = "wt", path = "/tmp/wt", repo_root = "/tmp/main" })

            chat:set_cwd(vim.fn.getcwd())
            assert.is_truthy(history_winbar(chat):find(GLYPH, 1, true))

            chat:set_subsession_breadcrumb("parent", "parent-id")
            local winbar = history_winbar(chat)
            assert.is_truthy(winbar:find("◂ 父：parent", 1, true))
            assert.is_nil(winbar:find(GLYPH, 1, true))

            chat:clear_subsession_breadcrumb()
            assert.is_truthy(history_winbar(chat):find(GLYPH, 1, true))
            teardown_chat(chat)
        end)

        it("escapes % so the winbar still evaluates", function()
            local chat = setup_chat("side")
            stub_worktree({ kind = "linked", name = "50%wt", path = "/tmp/wt", repo_root = "/tmp/main" })

            chat:set_cwd(vim.fn.getcwd())
            local winbar = history_winbar(chat)
            assert.is_truthy(winbar:find("50%%wt", 1, true))

            local evaluated = vim.api.nvim_eval_statusline(winbar, { winid = chat._layout:history_win() })
            assert.is_truthy(evaluated.str:find("50%wt", 1, true))
            teardown_chat(chat)
        end)

        it("re-applies the badge after the layout is shown again", function()
            local chat = setup_chat("side")
            stub_worktree({ kind = "linked", name = "wt", path = "/tmp/wt", repo_root = "/tmp/main" })
            chat:set_cwd(vim.fn.getcwd())

            chat._layout:hide()
            -- A fresh side-layout window starts from the plain panel title.
            chat:show()
            assert.is_truthy(history_winbar(chat):find(GLYPH .. " wt", 1, true))
            teardown_chat(chat)
        end)
    end)

    describe("float layout title", function()
        it("carries the badge in the float border title", function()
            local chat = setup_chat("float")
            stub_worktree({ kind = "linked", name = "wt", path = "/tmp/wt", repo_root = "/tmp/main" })

            chat:set_cwd(vim.fn.getcwd())

            local title = history_float_title(chat)
            assert.is_truthy(title:find("π", 1, true))
            assert.is_truthy(title:find(GLYPH .. " wt", 1, true))
            teardown_chat(chat)
        end)

        it("warns in the float border title when the session cwd is elsewhere", function()
            local chat = setup_chat("float")
            stub_worktree(nil)
            local elsewhere = vim.fn.getcwd() .. "-elsewhere"

            chat:set_cwd(elsewhere)

            local title = history_float_title(chat)
            assert.is_truthy(title:find("π", 1, true))
            assert.is_truthy(title:find("⚠ " .. vim.fn.fnamemodify(elsewhere, ":t"), 1, true))
            teardown_chat(chat)
        end)

        it("keeps the plain title in the main worktree with a matching cwd", function()
            local chat = setup_chat("float")
            local cwd = vim.fn.getcwd()
            stub_worktree({ kind = "main", name = "repo", path = cwd, repo_root = cwd })

            chat:set_cwd(cwd)

            local title = history_float_title(chat)
            assert.is_truthy(title:find("π", 1, true))
            assert.is_nil(title:find(GLYPH, 1, true))
            teardown_chat(chat)
        end)
    end)

    describe("workspace caches", function()
        it("drops the prompt-history store and cursor when the cwd changes", function()
            local chat = setup_chat("side")
            stub_worktree(nil)

            chat:set_cwd(vim.fn.getcwd())
            assert.is_truthy(chat:_history_store())
            assert.is_truthy(chat:_history_nav())

            chat:set_cwd(vim.fn.getcwd() .. "-other-worktree")
            assert.is_nil(chat._prompt_history)
            assert.is_nil(chat._prompt_nav)

            -- And they are rebuilt against the new workspace on demand.
            assert.is_truthy(chat:_history_store())
            teardown_chat(chat)
        end)
    end)

    describe("refresh triggers", function()
        it("never runs git status for the main worktree", function()
            local chat = setup_chat("side")
            local cwd = vim.fn.getcwd()
            local stub = stub_worktree({ kind = "main", name = "repo", path = cwd, repo_root = cwd })

            chat:set_cwd(cwd)
            chat:refresh_worktree()

            -- Only a linked worktree's badge carries `*`, so a main checkout's
            -- status can never change the title.
            assert.are.equal(0, #stub.calls)

            chat:set_cwd(cwd .. "-elsewhere")
            chat:refresh_worktree()
            assert.are.equal(0, #stub.calls)
            teardown_chat(chat)
        end)

        it("refreshes after tool completion (debounced) and on agent end (immediately)", function()
            local chat = setup_chat("side")
            local stub = stub_worktree({ kind = "linked", name = "wt", path = "/tmp/wt", repo_root = "/tmp/main" })
            chat:set_cwd(vim.fn.getcwd())
            resolve_status(stub, { dirty = false, ahead = 0 })
            assert.is_nil(history_winbar(chat):find("*", 1, true))
            stub.calls = {}

            -- A tool finished: coalesced behind the debounce, then refreshed.
            chat:on_tool_end("bash", "unknown-call", nil, false)
            assert.are.equal(0, #stub.calls)
            vim.wait(1500, function()
                return #stub.calls > 0
            end, 20)
            assert.are.equal(1, #stub.calls)
            resolve_status(stub, { dirty = true, ahead = 0 })
            assert.is_truthy(history_winbar(chat):find(GLYPH .. " wt*", 1, true))

            -- A finished turn refreshes synchronously: files are final.
            stub.calls = {}
            chat:on_agent_end()
            assert.are.equal(1, #stub.calls)
            teardown_chat(chat)
        end)

        it("re-reads the status when the chat is shown again", function()
            local chat = setup_chat("side")
            local stub = stub_worktree({ kind = "linked", name = "wt", path = "/tmp/wt", repo_root = "/tmp/main" })
            chat:set_cwd(vim.fn.getcwd())
            assert.are.equal(1, #stub.calls)

            chat._layout:hide()
            stub.calls = {}
            chat:show()

            assert.are.equal(1, #stub.calls)
            teardown_chat(chat)
        end)

        it("treats a symlinked or trailing-slash session cwd as matching", function()
            local chat = setup_chat("side")
            -- No work tree: the `⚠` falls back to the cwd comparison itself, so
            -- this is where symlink / trailing-slash normalization is visible.
            stub_worktree(nil)
            local link = vim.fn.tempname() .. "-link"
            assert.is_truthy(vim.uv.fs_symlink(vim.fn.getcwd(), link, { dir = true }))

            chat:set_cwd(link)
            assert.is_nil(history_winbar(chat):find("⚠", 1, true))

            chat:set_cwd(vim.fn.getcwd() .. "/")
            assert.is_nil(history_winbar(chat):find("⚠", 1, true))

            local elsewhere = vim.fn.getcwd() .. "-elsewhere"
            chat:set_cwd(elsewhere)
            local winbar = history_winbar(chat)
            assert.is_truthy(winbar:find("⚠ " .. vim.fn.fnamemodify(elsewhere, ":t"), 1, true))

            vim.uv.fs_unlink(link)
            teardown_chat(chat)
        end)
    end)
end)

-- The git branch badge rides the same title path, so it is exercised here too:
-- the display matrix, the `HEAD` watcher that makes a `git checkout` show up
-- without waiting for the turn to end, the per-turn fallback, and the non-git
-- case (nothing rendered at all — no placeholder).
describe("chat history branch badge", function()
    local BRANCH_GLYPH = "󰘬"
    local real_worktree_module
    local real_branch_module

    before_each(function()
        Config.setup({})
        real_worktree_module = package.loaded["pi.worktree"]
        real_branch_module = package.loaded["pi.git_branch"]
        package.loaded["pi.git_branch"] = nil
    end)

    after_each(function()
        package.loaded["pi.worktree"] = real_worktree_module
        package.loaded["pi.git_branch"] = real_branch_module
        local ok, Branch = pcall(require, "pi.git_branch")
        if ok and type(Branch._reset) == "function" then
            Branch._reset()
        end
    end)

    --- Install a `pi.git_branch` stub: `read` answers `info` for any directory,
    --- `watch` records the callback so a spec can simulate a checkout.
    ---@param info pi.GitBranch?
    ---@return { info: pi.GitBranch?, on_change: fun(info: pi.GitBranch?)?, unsubscribed: integer }
    local function stub_branch(info)
        local stub = { info = info, on_change = nil, unsubscribed = 0 }
        package.loaded["pi.git_branch"] = {
            read = function()
                return stub.info
            end,
            label = function(rec)
                if type(rec) ~= "table" then
                    return nil
                end
                return rec.name or rec.detached
            end,
            watch = function(_cwd, cb)
                stub.on_change = cb
                return function()
                    stub.unsubscribed = stub.unsubscribed + 1
                end
            end,
        }
        return stub
    end

    --- A fabricated main checkout: `.git/HEAD` is all the reader needs.
    ---@param head string raw HEAD content
    ---@return string root
    local function fake_repo(head)
        local root = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
        vim.fn.mkdir(root .. "/.git", "p")
        vim.fn.writefile({ head }, root .. "/.git/HEAD")
        return root
    end

    describe("display matrix (pure)", function()
        it("renders the branch name", function()
            assert.are.same(
                { { BRANCH_GLYPH .. " feat/login-ui", "PiChatHistoryBranch" } },
                Chat.branch_badge({ name = "feat/login-ui", git_dir = "/repo/.git" })
            )
        end)

        it("renders the short sha of a detached checkout", function()
            -- `pi.worktree_new()` detaches, so this is the common state: hiding
            -- it would leave the badge empty exactly when it matters.
            assert.are.same(
                { { BRANCH_GLYPH .. " 3db087b", "PiChatHistoryBranch" } },
                Chat.branch_badge({ detached = "3db087b", git_dir = "/repo/.git" })
            )
        end)

        it("renders nothing outside a repository", function()
            assert.is_nil(Chat.branch_badge(nil))
            assert.is_nil(Chat.branch_badge({}))
            assert.is_nil(Chat.branch_badge({ name = "", git_dir = "/repo/.git" }))
            assert.is_nil(Chat.branch_badge({ name = "", detached = "" }))
            assert.is_nil(Chat.branch_badge("feat/x"))
        end)
    end)

    describe("side layout winbar", function()
        it("appends the branch after the worktree badge", function()
            local chat = setup_chat("side")
            stub_worktree({ kind = "linked", name = "wt", path = "/tmp/wt", repo_root = "/tmp/main" })
            stub_branch({ name = "feat/x", git_dir = "/tmp/main/.git/worktrees/wt" })

            chat:set_cwd(vim.fn.getcwd())

            local winbar = history_winbar(chat)
            assert.is_truthy(winbar:find(GLYPH .. " wt", 1, true))
            assert.is_truthy(winbar:find(BRANCH_GLYPH .. " feat/x", 1, true))
            assert.is_truthy(winbar:find("PiChatHistoryBranch", 1, true))
            -- The worktree badge stays in front of the branch.
            assert.is_true(winbar:find(GLYPH, 1, true) < winbar:find(BRANCH_GLYPH, 1, true))
            teardown_chat(chat)
        end)

        it("shows the branch in a plain checkout with a matching cwd", function()
            -- The branch is the one identity chunk a main checkout gets: the
            -- worktree badge is deliberately blank there.
            local chat = setup_chat("side")
            local cwd = vim.fn.getcwd()
            stub_worktree({ kind = "main", name = "repo", path = cwd, repo_root = cwd })
            stub_branch({ name = "main", git_dir = cwd .. "/.git" })

            chat:set_cwd(cwd)

            local winbar = history_winbar(chat)
            assert.is_nil(winbar:find(GLYPH, 1, true))
            assert.is_truthy(winbar:find(BRANCH_GLYPH .. " main", 1, true))
            teardown_chat(chat)
        end)

        it("keeps the plain title outside a repository and arms no watcher", function()
            local chat = setup_chat("side")
            stub_worktree(nil)
            local stub = stub_branch(nil)

            chat:set_cwd(vim.fn.getcwd())

            local winbar = history_winbar(chat)
            assert.is_nil(winbar:find(BRANCH_GLYPH, 1, true))
            assert.is_nil(winbar:find("PiChatHistoryBranch", 1, true))
            assert.is_nil(stub.on_change)
            teardown_chat(chat)
        end)

        it("escapes % in a branch name so the winbar still evaluates", function()
            local chat = setup_chat("side")
            stub_worktree(nil)
            stub_branch({ name = "feat/50%off", git_dir = "/repo/.git" })

            chat:set_cwd(vim.fn.getcwd())

            local winbar = history_winbar(chat)
            assert.is_truthy(winbar:find("50%%off", 1, true))
            local evaluated = vim.api.nvim_eval_statusline(winbar, { winid = chat._layout:history_win() })
            assert.is_truthy(evaluated.str:find("50%off", 1, true))
            teardown_chat(chat)
        end)

        it("lets the sub-session breadcrumb win over the branch", function()
            local chat = setup_chat("side")
            stub_worktree(nil)
            stub_branch({ name = "feat/x", git_dir = "/repo/.git" })

            chat:set_cwd(vim.fn.getcwd())
            assert.is_truthy(history_winbar(chat):find(BRANCH_GLYPH, 1, true))

            chat:set_subsession_breadcrumb("parent", "parent-id")
            assert.is_nil(history_winbar(chat):find(BRANCH_GLYPH, 1, true))

            chat:clear_subsession_breadcrumb()
            assert.is_truthy(history_winbar(chat):find(BRANCH_GLYPH, 1, true))
            teardown_chat(chat)
        end)
    end)

    describe("refresh", function()
        it("updates the title when the watcher reports a checkout", function()
            local chat = setup_chat("side")
            stub_worktree(nil)
            local stub = stub_branch({ name = "main", git_dir = "/repo/.git" })
            chat:set_cwd(vim.fn.getcwd())
            assert.is_truthy(history_winbar(chat):find(BRANCH_GLYPH .. " main", 1, true))

            assert.are.equal("function", type(stub.on_change))
            stub.on_change({ name = "feat/switched", git_dir = "/repo/.git" })
            assert.is_truthy(history_winbar(chat):find(BRANCH_GLYPH .. " feat/switched", 1, true))

            -- Unchanged (same ref rewritten) reports must not re-render.
            local before = history_winbar(chat)
            stub.on_change({ name = "feat/switched", git_dir = "/repo/.git" })
            assert.are.equal(before, history_winbar(chat))
            teardown_chat(chat)
        end)

        it("re-reads the branch on agent end (a checkout run by the turn's tools)", function()
            local chat = setup_chat("side")
            stub_worktree(nil)
            local stub = stub_branch({ name = "main", git_dir = "/repo/.git" })
            chat:set_cwd(vim.fn.getcwd())

            -- The turn's tool checked out another branch: the fallback read sees
            -- it even on a filesystem whose watcher never fired.
            stub.info = { name = "feat/from-bash", git_dir = "/repo/.git" }
            chat:on_agent_end()

            assert.is_truthy(history_winbar(chat):find(BRANCH_GLYPH .. " feat/from-bash", 1, true))
            teardown_chat(chat)
        end)

        it("re-arms the watcher when the session cwd moves to another checkout", function()
            local chat = setup_chat("side")
            stub_worktree(nil)
            local stub = stub_branch({ name = "main", git_dir = "/repo-a/.git" })
            chat:set_cwd(vim.fn.getcwd())
            assert.are.equal(0, stub.unsubscribed)

            stub.info = { name = "feat/b", git_dir = "/repo-b/.git" }
            chat:set_cwd(vim.fn.getcwd() .. "-elsewhere")

            assert.is_truthy(history_winbar(chat):find(BRANCH_GLYPH .. " feat/b", 1, true))
            teardown_chat(chat)
        end)

        it("releases the watcher when the chat is disposed", function()
            local chat = setup_chat("side")
            stub_worktree(nil)
            local stub = stub_branch({ name = "main", git_dir = "/repo/.git" })
            chat:set_cwd(vim.fn.getcwd())
            assert.are.equal(0, stub.unsubscribed)

            chat:dispose()
            assert.are.equal(1, stub.unsubscribed)
            -- Disposing twice must not call the unsubscribe again.
            chat:dispose()
            assert.are.equal(1, stub.unsubscribed)
            teardown_chat(chat)
        end)
    end)

    describe("real checkout", function()
        it("follows a HEAD rewrite without polling", function()
            -- End to end over the real modules: `pi.worktree` resolves the git
            -- dir from the filesystem, `pi.git_branch` reads `HEAD` and watches
            -- it. No git process, no timer.
            package.loaded["pi.worktree"] = nil
            package.loaded["pi.git_branch"] = nil
            local Branch = require("pi.git_branch")
            local root = fake_repo("ref: refs/heads/feat/live")
            local chat = setup_chat("side")

            chat:set_cwd(root)
            assert.is_truthy(history_winbar(chat):find(BRANCH_GLYPH .. " feat/live", 1, true))
            assert.are.equal(1, Branch._active_watches())

            vim.fn.writefile({ "ref: refs/heads/feat/next" }, root .. "/.git/HEAD")
            assert.is_true(
                vim.wait(3000, function()
                    return history_winbar(chat):find(BRANCH_GLYPH .. " feat/next", 1, true) ~= nil
                end, 20),
                "the HEAD rewrite never reached the winbar"
            )

            -- Non-git cwd: the chunk disappears and the watcher with it.
            local plain = vim.uv.fs_realpath(vim.fn.tempname()) or vim.fn.tempname()
            vim.fn.mkdir(plain, "p")
            chat:set_cwd(plain)
            assert.is_nil(history_winbar(chat):find(BRANCH_GLYPH, 1, true))
            assert.are.equal(0, Branch._active_watches())

            vim.fn.delete(root, "rf")
            vim.fn.delete(plain, "rf")
            teardown_chat(chat)
        end)
    end)
end)
