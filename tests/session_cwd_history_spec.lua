-- Session cwd pass-through: session-file lookups must follow the *session's*
-- workspace (a git worktree), not Neovim's cwd.
--
-- `History.get_sessions_dir`/`list`/`find_by_id` take an optional cwd and
-- `parse` surfaces the header's `cwd`, while every default stays `getcwd()` so
-- single-workspace callers keep the old behaviour.

local Config = require("pi.config")
local SessionHistory = require("pi.sessions.history")

--- Mirror of the module's private path encoding (the directory name pi uses).
---@param cwd string
---@return string
local function encode_cwd(cwd)
    local encoded = cwd:gsub("^[\\/]", ""):gsub("[\\/:]", "-")
    return "--" .. encoded .. "--"
end

---@return string resolved temp dir
local function make_dir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    return assert(vim.uv.fs_realpath(dir))
end

--- Write a minimal session file (`<timestamp>_<id>.jsonl`).
---@param dir string sessions dir for one workspace
---@param id string
---@param header_cwd string? omit to write a header without cwd
---@return string path
local function write_session(dir, id, header_cwd)
    local path = ("%s/2024-01-01T00-00-00_%s.jsonl"):format(dir, id)
    local header = { type = "session", version = 3, id = id, timestamp = "2024-01-01T00:00:00.000Z" }
    if header_cwd ~= nil then
        header.cwd = header_cwd
    end
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode(header) .. "\n")
    f:close()
    return path
end

describe("session cwd: history", function()
    local agent_dir ---@type string
    local main ---@type string
    local worktree ---@type string
    local saved_agent_dir ---@type string?
    local saved_cwd ---@type string

    before_each(function()
        agent_dir = make_dir()
        main = make_dir()
        worktree = make_dir()
        saved_agent_dir = Config.options.agent_dir
        saved_cwd = vim.fn.getcwd()
        Config.options.agent_dir = agent_dir
        vim.cmd("cd " .. vim.fn.fnameescape(main))
    end)

    after_each(function()
        Config.options.agent_dir = saved_agent_dir
        vim.cmd("cd " .. vim.fn.fnameescape(saved_cwd))
        vim.fn.delete(agent_dir, "rf")
        vim.fn.delete(main, "rf")
        vim.fn.delete(worktree, "rf")
    end)

    ---@param cwd string
    ---@return string
    local function sessions_dir(cwd)
        return agent_dir .. "/sessions/" .. encode_cwd(cwd)
    end

    it("encodes an explicit workspace cwd instead of Neovim's cwd", function()
        assert.are.equal(sessions_dir(worktree), SessionHistory.get_sessions_dir(worktree))
        assert.are.equal(sessions_dir(main), SessionHistory.get_sessions_dir(main))
        assert.are_not.equal(SessionHistory.get_sessions_dir(worktree), SessionHistory.get_sessions_dir(main))
    end)

    it("keeps defaulting to Neovim's cwd when no cwd is given", function()
        assert.are.equal(sessions_dir(main), SessionHistory.get_sessions_dir())
    end)

    it("normalizes stale/unusable cwd arguments to Neovim's cwd", function()
        assert.are.equal(sessions_dir(main), SessionHistory.get_sessions_dir(""))
        assert.are.equal(sessions_dir(main), SessionHistory.get_sessions_dir(nil))
        -- nonexistent absolute path: no realpath, but the path is still encoded
        assert.are.equal(
            agent_dir .. "/sessions/" .. encode_cwd(main .. "/gone"),
            SessionHistory.get_sessions_dir(main .. "/gone")
        )
    end)

    it("parse returns the cwd recorded in the session header", function()
        local dir = sessions_dir(worktree)
        vim.fn.mkdir(dir, "p")
        local info = SessionHistory.parse(write_session(dir, "abc", worktree))
        assert.is_not_nil(info)
        assert.are.equal(worktree, info.cwd)
    end)

    it("parse leaves cwd nil for headers without a usable cwd", function()
        local dir = sessions_dir(worktree)
        vim.fn.mkdir(dir, "p")
        local without = SessionHistory.parse(write_session(dir, "n1"))
        assert.is_not_nil(without)
        assert.is_nil(without.cwd)

        local empty = SessionHistory.parse(write_session(dir, "n2", ""))
        assert.is_not_nil(empty)
        assert.is_nil(empty.cwd, "an empty header cwd means 'unknown', not the empty directory")
    end)

    it("list scopes to the requested workspace", function()
        vim.fn.mkdir(sessions_dir(main), "p")
        vim.fn.mkdir(sessions_dir(worktree), "p")
        write_session(sessions_dir(main), "main-1", main)
        write_session(sessions_dir(worktree), "wt-1", worktree)

        local wt = SessionHistory.list(worktree)
        assert.are.equal(1, #wt)
        assert.are.equal("wt-1", wt[1].id)

        local default = SessionHistory.list()
        assert.are.equal(1, #default, "the default must stay Neovim's cwd")
        assert.are.equal("main-1", default[1].id)
    end)

    it("find_by_id searches the requested workspace only", function()
        vim.fn.mkdir(sessions_dir(worktree), "p")
        local path = write_session(sessions_dir(worktree), "wt-only", worktree)

        local found = SessionHistory.find_by_id("wt-only", worktree)
        assert.is_not_nil(found)
        assert.are.equal(path, found.path)
        assert.is_nil(SessionHistory.find_by_id("wt-only"), "Neovim's cwd must not see the worktree session")
        assert.is_nil(SessionHistory.find_by_id("missing", worktree))
    end)
end)
