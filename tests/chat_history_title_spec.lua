-- Chat history title: the worktree badge (`π 󰙅 name`) in the side-layout
-- winbar and the float border title. Covers the display matrix (main
-- worktree + matching cwd = no badge, linked worktree, dirty/ahead `*`, cwd
-- mismatch warning), breadcrumb priority, `%` escaping for the winbar
-- expression, the layout/show re-apply, and the workspace caches
-- (`_prompt_history` / `_prompt_nav`) reset by `set_cwd`.
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

        it("names a linked worktree", function()
            assert.are.same({ { GLYPH .. " wt", "PiChatHistoryWorktree" } }, Chat.worktree_badge(linked, true, nil))
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
        end)

        it("warns when the session cwd differs from Neovim's cwd", function()
            assert.are.same({ { "⚠ repo", "PiStatusLineWarning" } }, Chat.worktree_badge(main, false, nil))
            assert.are.same(
                { { "⚠ " .. GLYPH .. " wt", "PiStatusLineWarning" } },
                Chat.worktree_badge(linked, false, nil)
            )
        end)

        it("drops the mismatch warning when worktree.warn_on_cwd_mismatch = false", function()
            Config.setup({ worktree = { warn_on_cwd_mismatch = false } })
            -- The plain linked badge (and its dirty marker) stays; the main
            -- checkout still shows nothing, because it has no glyph of its own.
            assert.is_nil(Chat.worktree_badge(main, false, nil))
            assert.are.same({ { GLYPH .. " wt", "PiChatHistoryWorktree" } }, Chat.worktree_badge(linked, false, nil))
            assert.are.same(
                { { GLYPH .. " wt*", "PiChatHistoryWorktree" } },
                Chat.worktree_badge(linked, false, { dirty = true })
            )
            Config.setup({})
        end)

        it("ignores unknown or anonymous worktrees", function()
            assert.is_nil(Chat.worktree_badge(nil, true, nil))
            assert.is_nil(Chat.worktree_badge({ kind = "other", name = "x" }, true, nil))
            assert.is_nil(Chat.worktree_badge({ kind = "linked", name = "" }, true, nil))
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

        it("shows the mismatch warning in the warning color", function()
            local chat = setup_chat("side")
            stub_worktree({ kind = "linked", name = "wt", path = "/tmp/wt", repo_root = "/tmp/main" })

            chat:set_cwd(vim.fn.getcwd() .. "-somewhere-else")

            local winbar = history_winbar(chat)
            assert.is_truthy(winbar:find("⚠ ", 1, true))
            assert.is_truthy(winbar:find("PiStatusLineWarning", 1, true))
            teardown_chat(chat)
        end)

        it("honours warn_on_cwd_mismatch = false in the winbar", function()
            Config.setup({ worktree = { warn_on_cwd_mismatch = false } })
            local chat = setup_chat("side")
            stub_worktree({ kind = "linked", name = "wt", path = "/tmp/wt", repo_root = "/tmp/main" })

            chat:set_cwd(vim.fn.getcwd() .. "-somewhere-else")

            local winbar = history_winbar(chat)
            assert.is_nil(winbar:find("⚠", 1, true))
            assert.is_truthy(winbar:find(GLYPH .. " wt", 1, true))
            assert.is_truthy(winbar:find("PiChatHistoryWorktree", 1, true))
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
        it("never runs git status for the main worktree with a matching cwd", function()
            local chat = setup_chat("side")
            local cwd = vim.fn.getcwd()
            local stub = stub_worktree({ kind = "main", name = "repo", path = cwd, repo_root = cwd })

            chat:set_cwd(cwd)
            chat:refresh_worktree()

            -- The badge is nil there, so status can never change the title.
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
            stub_worktree({ kind = "linked", name = "wt", path = "/tmp/wt", repo_root = "/tmp/main" })
            local link = vim.fn.tempname() .. "-link"
            assert.is_truthy(vim.uv.fs_symlink(vim.fn.getcwd(), link, { dir = true }))

            chat:set_cwd(link)
            assert.is_nil(history_winbar(chat):find("⚠", 1, true))
            assert.is_truthy(history_winbar(chat):find(GLYPH .. " wt", 1, true))

            chat:set_cwd(vim.fn.getcwd() .. "/")
            assert.is_nil(history_winbar(chat):find("⚠", 1, true))

            vim.uv.fs_unlink(link)
            teardown_chat(chat)
        end)
    end)
end)
