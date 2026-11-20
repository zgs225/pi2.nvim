-- Render engine *state* contract for the chat history window.
--
-- This spec pins the state that the two render engines must leave behind, not
-- the pixels: which `conceallevel` the history window runs at, whether
-- render-markdown was handed pi's history filetype/buffer, and whether it
-- actually put extmarks in the buffer. Per gotcha G6, "you cannot tell if
-- headings/bold/code chrome actually render" headless — extmark counts and
-- window options are intact but the *look* is a visual property, so a GUI
-- screenshot remains the only proof of pixel-level correctness. This file must
-- not be read as proving the rendering looks right.
--
-- Two engines, deliberately opposite window options (G7):
--   builtin          conceallevel=0 so tool output stays verbatim,
--   render-markdown  conceallevel=2 (from `set_win_opts`) so markers conceal.
--
-- render-markdown.nvim is an OPTIONAL test dependency: `tests/minimal_init.lua`
-- puts it on 'runtimepath' only when the checkout exists, and the specs below
-- degrade to `pending()` entries when it is absent. Children run with
-- `--noplugin` (plenary passes it), so this spec calls `manager.init()` itself
-- (G8) and forces rendering through the public API (G9) — nothing here relies
-- on the plugin directory being sourced or on a live event loop.
--
-- `pi.worktree` is stubbed through package.loaded so `Chat:show()` does not
-- shell out to `git` (this checkout is a linked worktree).

local Chat = require("pi.ui.chat")
local Config = require("pi.config")

-- Tab id unique to this spec: `Prompt.new` / `History.new` delete stale buffers
-- whose name embeds the tab id, so reusing a real tab's id would clobber state.
local TAB = 1342

--- Is the optional render-markdown dependency loadable?
---
--- `tests/minimal_init.lua` normally puts it on 'runtimepath', but a bare
--- `PlenaryBustedFile` re-runs the file in a child that only gets plenary on
--- 'runtimepath' (no `-u minimal_init`), so fall back to the same checkout
--- resolution minimal_init uses. Absent checkout => the specs below go pending.
---@return boolean
local function have_engine()
    if pcall(require, "render-markdown") then
        return true
    end
    local path = vim.env.RENDER_MARKDOWN_PATH or vim.fn.expand("~/.local/share/nvim/lazy/render-markdown.nvim")
    if vim.uv.fs_stat(path) then
        vim.opt.runtimepath:prepend(path)
        return (pcall(require, "render-markdown"))
    end
    return false
end

-- plenary's `pending()` only *declares* a pending entry (it prints and
-- returns), so the skip has to happen when the spec is declared, not from
-- before_each.
local ENGINE_PRESENT = have_engine()

--- Declare a real spec, or a pending placeholder when the engine is missing.
---@param desc string
---@param fn fun()
local function it_or_pending(desc, fn)
    if ENGINE_PRESENT then
        it(desc, fn)
    else
        pending(desc)
    end
end

--- Find the window currently showing `buf`.
---@param buf integer
---@return integer?
local function win_for_buf(buf)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
            return win
        end
    end
    return nil
end

--- Open a chat in `mode`, assert the history buffer/window are the expected
--- ones, and return the chat.
---@param mode pi.LayoutMode
---@return pi.Chat chat
local function open_chat(mode)
    local chat = Chat.new(TAB, mode, {
        send = function()
            return true
        end,
    })
    chat:show()
    assert.is_true(chat:is_visible())
    local hbuf = chat._history:buf()
    -- Guard the assertions below against silently targeting the wrong buffer.
    assert.equals("pi-chat-history", vim.bo[hbuf].filetype)
    assert.equals("nofile", vim.bo[hbuf].buftype)
    assert.is_not_nil(win_for_buf(hbuf))
    return chat
end

--- The window currently showing the chat's history buffer.
---@param c pi.Chat
---@return integer hwin
---@return integer hbuf
local function history_window(c)
    local hbuf = c._history:buf()
    return assert(win_for_buf(hbuf)), hbuf
end

--- Close the chat's windows/buffers hermetically (see chat_history_title_spec).
---@param chat pi.Chat?
local function teardown_chat(chat)
    if not chat then
        return
    end
    pcall(function()
        chat._layout:hide()
    end)
    pcall(vim.api.nvim_buf_delete, chat._history:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._prompt:buf(), { force = true })
    pcall(vim.api.nvim_buf_delete, chat._attachments:buf(), { force = true })
    local wins = vim.api.nvim_list_wins()
    for i = 2, #wins do
        pcall(vim.api.nvim_win_close, wins[i], false)
    end
end

describe("builtin engine (G7)", function()
    local chat
    local real_worktree_module

    before_each(function()
        Config.setup({ render = { engine = "builtin" } })
        real_worktree_module = package.loaded["pi.worktree"]
        package.loaded["pi.worktree"] = {
            detect = function()
                return nil
            end,
        }
        chat = nil
    end)

    after_each(function()
        teardown_chat(chat)
        chat = nil
        package.loaded["pi.worktree"] = real_worktree_module
        Config.setup({})
    end)

    it("side layout keeps the history window at conceallevel=0", function()
        chat = open_chat("side")
        local hwin = history_window(chat)
        assert.equals(0, vim.wo[hwin].conceallevel)
    end)

    it("float layout keeps the history window at conceallevel=0", function()
        chat = open_chat("float")
        local hwin = history_window(chat)
        assert.equals(0, vim.wo[hwin].conceallevel)
    end)
end)

describe("render-markdown engine (G8/G9)", function()
    local chat
    local saved_env_lazy

    before_each(function()
        chat = nil
        if not ENGINE_PRESENT then
            return
        end
        -- The plugin probes lazy.nvim (when it is loaded at all) to find its
        -- lazy-loaded file_types/change_events. A partially initialised lazy
        -- inherited from a user config makes that probe throw, and it is
        -- irrelevant to this contract: stub it so the spec is hermetic.
        local env = require("render-markdown.lib.env")
        saved_env_lazy = env.lazy
        env.lazy = function()
            return {}
        end
        local rm = require("render-markdown")
        rm.setup({ file_types = { "markdown" } })
        -- pi.setup() normally does this (lua/pi/init.lua), and render-markdown
        -- parses the buffer through vim.treesitter.get_parser(buf), which needs
        -- a parser for the buffer's filetype. Without it the render pass logs
        -- "no treesitter parser found" and produces no marks.
        vim.treesitter.language.register("markdown", "pi-chat-history")
        -- What plugin/render-markdown.lua does (it never runs here: the child is
        -- started with --noplugin). `manager.init()` is the load-bearing part:
        -- the FileType autocmd must exist before the history buffer is created,
        -- or nothing auto-attaches (G8). log.init() is also required because the
        -- render path logs, and its entries table only exists after init().
        require("render-markdown.core.log").init()
        require("render-markdown.core.manager").init()
        Config.setup({ render = { engine = "render-markdown" } })
    end)

    after_each(function()
        if ENGINE_PRESENT then
            pcall(vim.api.nvim_del_augroup_by_name, "RenderMarkdown")
            pcall(vim.api.nvim_del_user_command, "RenderMarkdown")
            -- Deleting the augroup invalidates the manager's cached group id,
            -- so drop the module too: the next before_each re-creates both.
            package.loaded["render-markdown.core.manager"] = nil
            local env = require("render-markdown.lib.env")
            if saved_env_lazy then
                env.lazy = saved_env_lazy
            end
        end
        require("pi.ui.render")._reset()
        Config.setup({})
        teardown_chat(chat)
        chat = nil
    end)

    it_or_pending("registers pi's history filetype with the plugin", function()
        chat = open_chat("side")
        assert.is_true(vim.tbl_contains(require("render-markdown.state").file_types, "pi-chat-history"))
    end)

    it_or_pending("runs the history window at conceallevel=2", function()
        chat = open_chat("side")
        local hwin = history_window(chat)
        assert.equals(2, vim.wo[hwin].conceallevel)
    end)

    it_or_pending("attaches to the history buffer", function()
        chat = open_chat("side")
        local _, hbuf = history_window(chat)
        local manager = require("render-markdown.core.manager")
        -- pi's explicit attach is deferred through vim.schedule().
        assert.is_true(vim.wait(10000, function()
            return manager.attached(hbuf)
        end, 20))
    end)

    it_or_pending("decorates markdown written into the history buffer", function()
        chat = open_chat("side")
        local _, hbuf = history_window(chat)
        -- Same name the plugin uses for its namespace, so this returns its id.
        local ns = vim.api.nvim_create_namespace("render-markdown.nvim")
        vim.bo[hbuf].modifiable = true
        vim.api.nvim_buf_set_lines(hbuf, 0, -1, false, {
            "# Render contract",
            "",
            "- first item",
            "- second item",
            "",
            "Some **bold** prose and a [link](https://example.com).",
        })
        -- G9: headless's passive TextChanged path does not drive the async
        -- parse; force a render through the public API.
        require("render-markdown").render({ buf = hbuf })
        assert.is_true(vim.wait(10000, function()
            return #vim.api.nvim_buf_get_extmarks(hbuf, ns, 0, -1, {}) > 0
        end, 20))
    end)
end)
