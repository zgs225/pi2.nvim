-- Session cwd pass-through: the pre-execution diff review resolves relative
-- tool paths against the *session's* workspace (a git worktree), never Neovim's
-- cwd. Accepting a review must write the worktree's file and leave the main
-- checkout's same-named file untouched.

local Config = require("pi.config")
local Diff = require("pi.ui.diff")

Config.setup({})

---@return string resolved temp dir
local function make_dir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return assert(vim.uv.fs_realpath(dir))
end

--- Close every tabpage except `keep` (nil: leave exactly one tab open).
---@param keep integer?
local function only_tab(keep)
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if tab ~= keep and vim.api.nvim_tabpage_is_valid(tab) then
            vim.api.nvim_set_current_tabpage(tab)
            pcall(vim.cmd, "tabclose")
        end
    end
    if keep and vim.api.nvim_tabpage_is_valid(keep) then
        vim.api.nvim_set_current_tabpage(keep)
    end
end

describe("session cwd: diff review", function()
    local original_cwd = vim.fn.getcwd()
    local main ---@type string
    local worktree ---@type string
    local rel = "src/a.lua"

    before_each(function()
        main = make_dir()
        worktree = make_dir()
        for _, dir in ipairs({ main, worktree }) do
            vim.fn.mkdir(dir .. "/src", "p")
        end
        vim.fn.writefile({ "main content" }, main .. "/" .. rel)
        vim.fn.writefile({ "worktree content" }, worktree .. "/" .. rel)
        original_cwd = vim.fn.getcwd()
        -- Neovim sits in the main checkout while the session runs in the worktree.
        vim.cmd("cd " .. vim.fn.fnameescape(main))
    end)

    after_each(function()
        only_tab(nil)
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        pcall(vim.fn.delete, main, "rf")
        pcall(vim.fn.delete, worktree, "rf")
    end)

    --- Accept the review by writing the proposed buffer, like the user pressing
    --- the accept keymap from the review window.
    ---@param path string absolute path of the reviewed file
    local function accept_via_write(path)
        local after_buf = vim.fn.bufnr("pi://review" .. path)
        assert.is_true(after_buf > 0, "proposed buffer pi://review" .. path .. " not found")
        local wins = vim.fn.win_findbuf(after_buf)
        assert.is_true(#wins > 0, "proposed buffer must be displayed in the review tab")
        vim.api.nvim_set_current_win(wins[1])
        vim.cmd("write")
    end

    it("writes an accepted relative edit into the session cwd, not the main checkout", function()
        local result = nil ---@type string?
        Diff.open({
            prompt = "write " .. rel,
            toolName = "write",
            toolInput = { path = rel, content = "worktree accepted\n" },
        }, function(res)
            result = res
        end, { cwd = worktree })

        accept_via_write(worktree .. "/" .. rel)

        assert.is_truthy(result, "the review callback must have been invoked")
        assert.are.equal("Accepted", vim.json.decode(result --[[@as string]]).result)
        assert.are.same({ "worktree accepted" }, vim.fn.readfile(worktree .. "/" .. rel))
        assert.are.same({ "main content" }, vim.fn.readfile(main .. "/" .. rel), "the main checkout must be untouched")
    end)

    it("keeps resolving relative paths against Neovim's cwd without opts.cwd", function()
        local result = nil ---@type string?
        Diff.open({
            prompt = "write " .. rel,
            toolName = "write",
            toolInput = { path = rel, content = "main accepted\n" },
        }, function(res)
            result = res
        end)

        accept_via_write(main .. "/" .. rel)

        assert.is_truthy(result)
        assert.are.same({ "main accepted" }, vim.fn.readfile(main .. "/" .. rel))
        assert.are.same({ "worktree content" }, vim.fn.readfile(worktree .. "/" .. rel))
    end)

    it("leaves absolute tool paths untouched", function()
        local abs = worktree .. "/" .. rel
        local result = nil ---@type string?
        Diff.open({
            prompt = "write " .. abs,
            toolName = "write",
            toolInput = { path = abs, content = "absolute\n" },
        }, function(res)
            result = res
        end, { cwd = main })

        accept_via_write(abs)

        assert.is_truthy(result)
        assert.are.same({ "absolute" }, vim.fn.readfile(abs))
    end)
end)
