-- Session cwd pass-through for sub-session bookkeeping: the manifest and the
-- batch file live next to the session files of the workspace that owns them
-- (a git worktree), and `Read.find_path` searches that workspace.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Batch = require("pi.subsessions.batch")
local Read = require("pi.subsessions.read")

--- Mirror of the session dir encoding pi uses.
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

describe("session cwd: sub-session bookkeeping", function()
    local original_cwd = vim.fn.getcwd()
    local agent_dir ---@type string
    local main ---@type string
    local worktree ---@type string
    local saved_agent_dir ---@type string?

    before_each(function()
        original_cwd = vim.fn.getcwd()
        agent_dir = make_dir()
        main = make_dir()
        worktree = make_dir()
        saved_agent_dir = Config.options.agent_dir
        Config.options.agent_dir = agent_dir
        vim.cmd("cd " .. vim.fn.fnameescape(main))
        Manifest._reset()
        Batch._reset()
    end)

    after_each(function()
        Manifest._reset()
        Batch._reset()
        Config.options.agent_dir = saved_agent_dir
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        for _, dir in ipairs({ agent_dir, main, worktree }) do
            pcall(vim.fn.delete, dir, "rf")
        end
    end)

    ---@param cwd string
    ---@return string
    local function sessions_dir(cwd)
        return agent_dir .. "/sessions/" .. encode_cwd(cwd)
    end

    describe("manifest", function()
        it("path follows the requested workspace", function()
            assert.are.equal(sessions_dir(worktree) .. "/.pi2-subsessions.json", Manifest.path(worktree))
            assert.are.equal(sessions_dir(main) .. "/.pi2-subsessions.json", Manifest.path())
        end)

        it("round-trips per workspace and keeps them separate", function()
            local ok = Manifest.save({ ["child-1"] = { parent_id = "p", status = "active" } }, worktree)
            assert.is_true(ok)

            local loaded = Manifest.load(worktree)
            assert.is_not_nil(loaded["child-1"])
            assert.is_true(Manifest.is_child_session("child-1", worktree))

            -- Default lookups still resolve against Neovim's cwd (the main
            -- checkout), which must not see the worktree's manifest.
            assert.is_nil(Manifest.load()["child-1"])
            assert.is_false(Manifest.is_child_session("child-1"))
        end)

        it("upsert/patch write into the requested workspace manifest", function()
            Manifest.upsert("child-2", { parent_id = "p", status = "active" }, worktree)
            Manifest.patch("child-2", { status = "completed" }, worktree)

            assert.are.equal("completed", Manifest.load(worktree)["child-2"].status)
            assert.is_nil(Manifest.load(main)["child-2"])
        end)
    end)

    describe("batch", function()
        it("path follows the requested workspace", function()
            assert.are.equal(sessions_dir(worktree) .. "/.pi2-sub-batches.json", Batch.path(worktree))
            assert.are.equal(sessions_dir(main) .. "/.pi2-sub-batches.json", Batch.path())
        end)

        it("keeps the explicit path override winning", function()
            local override = sessions_dir(main) .. "/custom-batches.json"
            Batch._set_path(override)
            assert.are.equal(override, Batch.path(worktree))
        end)

        it("get() reads the requested workspace file", function()
            local dir = sessions_dir(worktree)
            vim.fn.mkdir(dir, "p")
            vim.fn.writefile({
                vim.json.encode({
                    ["batch-1"] = {
                        id = "batch-1",
                        parent_id = "p",
                        status = "running",
                        created_at = "2024-01-01T00:00:00Z",
                        updated_at = "2024-01-01T00:00:00Z",
                        cancel_siblings_on_fail = false,
                        items = {},
                    },
                }),
            }, Batch.path(worktree))

            assert.is_not_nil(Batch.get("batch-1", worktree))
            assert.is_nil(Batch.get("batch-1"), "Neovim's cwd must not see the worktree batch")
            assert.is_not_nil(Batch.poll("batch-1", worktree))
            assert.is_nil(Batch.poll("batch-1"))
        end)
    end)

    describe("read.find_path", function()
        ---@param cwd string
        ---@param id string
        ---@return string path
        local function write_session(cwd, id)
            local dir = sessions_dir(cwd)
            vim.fn.mkdir(dir, "p")
            local path = ("%s/2024-01-01T00-00-00_%s.jsonl"):format(dir, id)
            vim.fn.writefile({
                vim.json.encode({ type = "session", version = 3, id = id, cwd = cwd }),
            }, path)
            return path
        end

        it("searches the requested workspace", function()
            local path = write_session(worktree, "wt-child")
            assert.are.equal(path, Read.find_path("wt-child", { cwd = worktree }))
            assert.are.equal(path, Read.find_path("wt-child", worktree), "the string shorthand is accepted too")
            assert.is_nil(Read.find_path("wt-child"), "default search stays Neovim's cwd")
        end)

        it("reuses a readable session_file and falls back otherwise", function()
            local path = write_session(worktree, "wt-child")
            assert.are.equal(path, Read.find_path("unknown-id", { cwd = worktree, session_file = path }))
            assert.are.equal(
                path,
                Read.find_path("wt-child", { cwd = worktree, session_file = worktree .. "/missing.jsonl" }),
                "an unreadable hint must fall back to the id lookup"
            )
        end)
    end)
end)
