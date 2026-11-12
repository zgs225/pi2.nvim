-- Session cwd pass-through: grep/find tool results are relative to the pi
-- process's workspace, so the quickfix list must anchor on the session cwd
-- (a git worktree) instead of Neovim's cwd. Defaults stay `getcwd()`.

local Config = require("pi.config")
local Quickfix = require("pi.quickfix")

Config.setup({})

describe("session cwd: quickfix", function()
    local original_cwd = vim.fn.getcwd()
    local main ---@type string
    local worktree ---@type string

    ---@return string
    local function make_dir()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        dir = assert(vim.uv.fs_realpath(dir))
        return dir
    end

    before_each(function()
        Quickfix._reset()
        main = make_dir()
        worktree = make_dir()
        vim.cmd("cd " .. vim.fn.fnameescape(main))
    end)

    after_each(function()
        Quickfix._reset()
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        vim.fn.delete(main, "rf")
        vim.fn.delete(worktree, "rf")
    end)

    it("parse_grep resolves relative hits against the requested workspace", function()
        local items = Quickfix.parse_grep("src/a.ts:12: hello", worktree)
        assert.are.equal(1, #items)
        assert.are.equal(worktree .. "/src/a.ts", items[1].filename)
        assert.are.equal(12, items[1].lnum)
        assert.are.equal("hello", items[1].text)
    end)

    it("parse_grep keeps Neovim's cwd when no workspace is given", function()
        local items = Quickfix.parse_grep("src/a.ts:1: x")
        assert.are.equal(main .. "/src/a.ts", items[1].filename)
    end)

    it("parse_files resolves relative hits against the requested workspace", function()
        local items = Quickfix.parse_files("lib/b.lua\nlib/c.lua", worktree)
        assert.are.equal(2, #items)
        assert.are.equal(worktree .. "/lib/b.lua", items[1].filename)
        assert.are.equal(worktree .. "/lib/c.lua", items[2].filename)
    end)

    it("leaves absolute paths untouched", function()
        local abs = worktree .. "/src/abs.ts"
        local items = Quickfix.parse_grep(abs .. ":3: y", main)
        assert.are.equal(abs, items[1].filename)
    end)

    it("on_tool_end fills the list with session-cwd paths", function()
        Config.setup({ quickfix = { grep = true } })
        Quickfix.on_tool_start("grep", "call-1", { pattern = "needle" })
        Quickfix.on_tool_end("grep", "call-1", {
            content = { { type = "text", text = "src/a.ts:7: needle here" } },
        }, false, worktree)

        local qf = vim.fn.getqflist({ items = true, title = true })
        assert.are.equal(1, #qf.items)
        assert.are.equal(worktree .. "/src/a.ts", vim.fn.bufname(qf.items[1].bufnr))
        assert.are.equal(7, qf.items[1].lnum)
        assert.is_truthy(tostring(qf.title):find("needle", 1, true))

        Config.setup({})
    end)
end)
