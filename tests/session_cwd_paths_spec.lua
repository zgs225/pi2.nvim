-- Session cwd pass-through for path consumers that read the workspace:
-- buffer reload, `@mention` expansion and the built-in git mention providers.
-- All anchor on the caller's workspace (a git worktree) and keep `getcwd()` as
-- the default.

local Config = require("pi.config")
local Reload = require("pi.reload")
local Mentions = require("pi.ui.chat.mentions")
local Providers = require("pi.mention_providers")

Config.setup({})

---@return string resolved temp dir
local function make_dir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return assert(vim.uv.fs_realpath(dir))
end

---@param path string
---@param lines string[]
local function write_file(path, lines)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
end

--- Init a git repo at `dir` with one commit and `f.txt` = v1.
---@param dir string
local function init_repo(dir)
    vim.system({ "git", "init", "-q", "-b", "main", dir }):wait()
    vim.system({ "git", "-C", dir, "config", "user.email", "t@t" }):wait()
    vim.system({ "git", "-C", dir, "config", "user.name", "t" }):wait()
    write_file(dir .. "/f.txt", { "v1" })
    vim.system({ "git", "-C", dir, "add", "." }):wait()
    vim.system({ "git", "-C", dir, "commit", "-qm", "one" }):wait()
end

describe("session cwd: path consumers", function()
    local original_cwd = vim.fn.getcwd()
    local main ---@type string
    local worktree ---@type string
    local rel = "src/a.lua"

    before_each(function()
        original_cwd = vim.fn.getcwd()
        main = make_dir()
        worktree = make_dir()
        vim.cmd("cd " .. vim.fn.fnameescape(main))
    end)

    after_each(function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            local name = vim.api.nvim_buf_get_name(buf)
            if vim.startswith(name, main) or vim.startswith(name, worktree) then
                pcall(vim.api.nvim_buf_delete, buf, { force = true })
            end
        end
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        pcall(vim.fn.delete, main, "rf")
        pcall(vim.fn.delete, worktree, "rf")
    end)

    describe("reload", function()
        --- Open both checkouts' copies of `rel`; the worktree one is modified.
        ---@return integer worktree_buf
        ---@return integer main_buf
        local function open_both()
            for _, dir in ipairs({ main, worktree }) do
                write_file(dir .. "/" .. rel, { dir == main and "main" or "worktree" })
            end
            vim.cmd("silent edit " .. vim.fn.fnameescape(worktree .. "/" .. rel))
            local worktree_buf = vim.fn.bufnr(worktree .. "/" .. rel)
            vim.cmd("silent edit " .. vim.fn.fnameescape(main .. "/" .. rel))
            local main_buf = vim.fn.bufnr(main .. "/" .. rel)
            vim.bo[worktree_buf].modified = true
            return worktree_buf, main_buf
        end

        it("matches relative tool paths against the session cwd", function()
            local worktree_buf = open_both()

            local result = Reload.reload_buffers({ rel }, worktree)
            assert.are.same({ rel }, result.skipped, "the worktree buffer is the one that matches (and is modified)")
            assert.are.same({}, result.reloaded)
            assert.is_true(vim.bo[worktree_buf].modified)

            -- The same relative path anchored at the main checkout matches the
            -- unmodified main buffer instead.
            local main_result = Reload.reload_buffers({ rel }, main)
            assert.are.same({}, main_result.skipped)
            assert.are.same({ rel }, main_result.reloaded)
        end)

        it("keeps Neovim's cwd as the default base", function()
            open_both()
            vim.bo[vim.fn.bufnr(worktree .. "/" .. rel)].modified = false
            local result = Reload.reload_buffers({ rel })
            assert.are.same({ rel }, result.reloaded)
            assert.are.same({}, result.skipped)
        end)

        it("on_file_changed accepts a workspace cwd", function()
            local worktree_buf = open_both()
            Reload.on_file_changed(rel, worktree)
            assert.are.equal(worktree .. "/" .. rel, vim.api.nvim_buf_get_name(worktree_buf))
        end)
    end)

    describe("@-mention expansion", function()
        it("checks existence against the session cwd", function()
            write_file(worktree .. "/" .. rel, { "x" })
            assert.are.equal("[file: " .. rel .. "]", Mentions.expand("@" .. rel, worktree))
            assert.are.equal("@" .. rel, Mentions.expand("@" .. rel), "Neovim's cwd has no such file")
        end)

        it("expands ranges against the session cwd too", function()
            write_file(worktree .. "/" .. rel, { "x" })
            assert.are.equal("[file: " .. rel .. ", lines: 3-5]", Mentions.expand("@" .. rel .. "#L3-5", worktree))
        end)
    end)

    describe("mention providers", function()
        it("runs git-diff in the session's workspace", function()
            init_repo(main)
            init_repo(worktree)
            write_file(worktree .. "/f.txt", { "v2" })

            local content = Providers.materialize("git-diff", worktree)
            assert.is_truthy(content)
            assert.is_truthy(content:find("+v2", 1, true))
            assert.is_truthy(content:find("-v1", 1, true))
            assert.is_nil(Providers.materialize("git-diff", main), "the main checkout has no changes")
            assert.is_nil(Providers.materialize("git-diff"), "no default workspace = Neovim's cwd (clean)")
        end)
    end)
end)
