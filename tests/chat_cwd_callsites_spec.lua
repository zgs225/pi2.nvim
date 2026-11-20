-- Real call-chain: the session workspace cwd (not Neovim's) must reach every
-- consumer that resolves paths relative to the workspace — @-mention
-- materialisation (both submission paths), project-file completion, and prompt
-- decorators. Each case drives the public entry point and records the cwd the
-- downstream module actually received, so a regression in the wiring (a
-- dropped argument) fails here rather than only in a worktree session.
--
-- All downstream modules are spied/stubbed through package.loaded; nothing
-- here shells out to git.

local Chat = require("pi.ui.chat")
local Completion = require("pi.completion")
local Config = require("pi.config")
local Decorators = require("pi.ui.chat.decorators")

local TAB = 1201
local WS = "/tmp/pi-ws-callsite"

--- Swap `package.loaded["pi.sessions.manager"]` for a stub returning `session`,
--- run `fn`, then restore. `session = nil` simulates "no session".
---@param session table?
---@param fn fun()
local function with_session(session, fn)
    local real = package.loaded["pi.sessions.manager"]
    package.loaded["pi.sessions.manager"] = {
        get = function()
            return session
        end,
    }
    local ok, err = pcall(fn)
    package.loaded["pi.sessions.manager"] = real
    if not ok then
        error(err)
    end
end

--- Temporarily replace one method of a module table.
---@param module table
---@param name string
---@param replacement function
---@param fn fun()
local function with_method(module, name, replacement, fn)
    local real = module[name]
    module[name] = replacement
    local ok, err = pcall(fn)
    module[name] = real
    if not ok then
        error(err)
    end
end

--- Swap `package.loaded["pi.sessions.manager"]` for a stub answering both
--- `get` and `get_or_create`, run `fn`, then restore.
---@param session table?
---@param fn fun()
local function with_session_manager(session, fn)
    local real = package.loaded["pi.sessions.manager"]
    package.loaded["pi.sessions.manager"] = {
        get = function()
            return session
        end,
        get_or_create = function()
            return session
        end,
    }
    local ok, err = pcall(fn)
    package.loaded["pi.sessions.manager"] = real
    if not ok then
        error(err)
    end
end

---@param buf integer
---@param needle string
---@return boolean
local function buf_contains(buf, needle)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find(needle, 1, true) then
            return true
        end
    end
    return false
end

--- A session stand-in with a scratch prompt buffer, enough for Mentions.send.
---@param cwd string?
---@return table
local function mention_session(cwd)
    local buf = vim.api.nvim_create_buf(false, true)
    return {
        cwd = cwd,
        _buf = buf,
        chat = {
            _buf = buf,
            prompt_buf = function(self)
                return self._buf
            end,
            prompt_win = function()
                return nil
            end,
            show = function() end,
            ensure_shown_and_focus_prompt = function() end,
        },
    }
end

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

---@param send fn(cmd: table): boolean?
---@return pi.Chat
local function setup_chat(send)
    local chat = Chat.new(TAB, "side", { send = send or function()
        return true
    end })
    chat:ensure_shown_and_focus_prompt()
    return chat
end

---@param chat pi.Chat
---@param text string
local function set_prompt(chat, text)
    vim.api.nvim_buf_set_lines(chat._prompt:buf(), 0, -1, false, { text })
end

describe("session cwd reaches the mention/completion call chain", function()
    before_each(function()
        Config.setup({})
    end)

    it("materialises @-providers in the session cwd on submit", function()
        local seen = {}
        local sent = {}
        Config.setup({
            mention_providers = {
                rec = function(cwd)
                    seen[#seen + 1] = cwd
                    return "provider output"
                end,
            },
        })
        local chat = setup_chat(function(cmd)
            sent[#sent + 1] = cmd
            return true
        end)
        chat:set_cwd(WS)

        set_prompt(chat, "look at @rec")
        chat:submit()

        assert.are.same({ WS }, seen)
        assert.are.equal("prompt", sent[1].type)
        assert.is_truthy(sent[1].message:find('<context name="rec">', 1, true))
        assert.is_truthy(sent[1].message:find("provider output", 1, true))
        teardown_chat(chat)
    end)

    it("materialises @-providers in the session cwd for compaction-queued messages", function()
        local seen = {}
        Config.setup({
            mention_providers = {
                rec = function(cwd)
                    seen[#seen + 1] = cwd
                    return "queued output"
                end,
            },
        })
        local chat = setup_chat()
        chat:set_cwd(WS)

        -- Compacting: submit() queues the message instead of sending it, which
        -- is the second Mentions.expand call site.
        chat._compacting = true
        set_prompt(chat, "queued @rec")
        chat:submit()

        assert.are.same({ WS }, seen)
        assert.are.equal(1, #chat._compaction_queue)
        assert.is_truthy(chat._compaction_queue[1].expanded:find("queued output", 1, true))
        teardown_chat(chat)
    end)

    it("lists project files from the session cwd", function()
        local seen = {}
        local FilesCache = require("pi.cache.files")
        with_session({ cwd = WS }, function()
            with_method(FilesCache, "list", function(cwd)
                seen[#seen + 1] = cwd
                return {}
            end, function()
                Completion.complete_files("a", function(path)
                    return { path = path }
                end)
            end)
        end)

        assert.are.same({ WS }, seen)
    end)

    it("checks mention paths in the session cwd when decorating the prompt", function()
        local seen = {}
        local FilesCache = require("pi.cache.files")
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "see @some/file.lua" })

        with_session({ cwd = WS }, function()
            with_method(FilesCache, "exists", function(path, cwd)
                seen[#seen + 1] = { path, cwd }
                return true
            end, function()
                Decorators.update(buf)
            end)
        end)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })

        assert.are.equal(1, #seen)
        assert.are.equal("some/file.lua", seen[1][1])
        assert.are.equal(WS, seen[1][2])
    end)

    it("stays nil-safe without a session", function()
        local listed = { "sentinel" }
        local checked = { "sentinel" }
        local FilesCache = require("pi.cache.files")
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@some/file.lua" })

        with_session(nil, function()
            with_method(FilesCache, "list", function(cwd)
                listed = { cwd }
                return {}
            end, function()
                with_method(FilesCache, "exists", function(path, cwd)
                    checked = { path, cwd }
                    return false
                end, function()
                    Completion.complete_files("a", function(path)
                        return { path = path }
                    end)
                    Decorators.update(buf)
                end)
            end)
        end)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })

        -- Both fall back to Neovim's cwd (nil argument), never to another
        -- session's workspace.
        assert.are.same({ nil }, listed)
        assert.are.equal("some/file.lua", checked[1])
        assert.is_nil(checked[2])
    end)
end)

describe("Mentions.send workspace anchor", function()
    local Mentions = require("pi.ui.chat.mentions")
    local FilesCache = require("pi.cache.files")

    --- Run `fn` with the prompt-decorator existence check stubbed, so the
    --- scheduled insert never spawns git.
    ---@param fn fun()
    local function with_stubbed_exists(fn)
        with_method(FilesCache, "exists", function()
            return false
        end, fn)
    end

    --- Wait for the scheduled mention insert and return the resulting prompt
    --- line.
    ---@param session table
    ---@return string
    local function wait_for_mention(session)
        local inserted = vim.wait(1000, function()
            return buf_contains(session._buf, "@")
        end, 10)
        assert.is_true(inserted, "expected the mention to be inserted")
        return vim.api.nvim_buf_get_lines(session._buf, 0, -1, false)[1] or ""
    end

    it("renders a worktree session's file relative to the session cwd", function()
        local session = mention_session("/repo/.worktrees/wt")
        local line

        with_session_manager(session, function()
            with_stubbed_exists(function()
                Mentions.send({ path = "/repo/.worktrees/wt/src/a.lua" }, { focus = false })
                line = wait_for_mention(session)
            end)
        end)
        pcall(vim.api.nvim_buf_delete, session._buf, { force = true })

        -- Regression: relativising against Neovim's cwd (the main checkout)
        -- produced `@.worktrees/wt/src/a.lua`.
        assert.are.equal("@src/a.lua", (line:match("^(%S+)")))
        assert.is_nil(line:find(".worktrees", 1, true))
    end)

    it("prefers an explicit opts.cwd over the session cwd", function()
        local session = mention_session("/repo")
        local line

        with_session_manager(session, function()
            with_stubbed_exists(function()
                Mentions.send(
                    { path = "/repo/.worktrees/wt/src/a.lua" },
                    { focus = false, cwd = "/repo/.worktrees/wt" }
                )
                line = wait_for_mention(session)
            end)
        end)
        pcall(vim.api.nvim_buf_delete, session._buf, { force = true })

        assert.are.equal("@src/a.lua", (line:match("^(%S+)")))
    end)

    it("keeps the old behaviour when the session has no cwd", function()
        local session = mention_session(nil)
        local path = "/tmp/pi-ws-callsite-elsewhere/src/a.lua"
        local line

        with_session_manager(session, function()
            with_stubbed_exists(function()
                Mentions.send({ path = path }, { focus = false })
                line = wait_for_mention(session)
            end)
        end)
        pcall(vim.api.nvim_buf_delete, session._buf, { force = true })

        assert.are.equal("@" .. vim.fn.fnamemodify(path, ":."), (line:match("^(%S+)")))
    end)

    it("does nothing without a session", function()
        local decorated = false

        with_session_manager(nil, function()
            with_method(FilesCache, "exists", function()
                decorated = true
                return false
            end, function()
                Mentions.send({ path = "/repo/.worktrees/wt/src/a.lua" }, { focus = false })
            end)
        end)
        vim.wait(100, function()
            return false
        end, 10)

        -- No session: the insert path (and therefore the decoration) never runs.
        assert.is_false(decorated)
    end)

    it("anchors the mention through the public :PiSendMention entry", function()
        local session = mention_session("/repo/.worktrees/wt")
        local line

        with_session_manager(session, function()
            with_stubbed_exists(function()
                require("pi").send_mention({ path = "/repo/.worktrees/wt/src/a.lua" }, { focus = false })
                line = wait_for_mention(session)
            end)
        end)
        pcall(vim.api.nvim_buf_delete, session._buf, { force = true })

        assert.are.equal("@src/a.lua", (line:match("^(%S+)")))
    end)
end)
