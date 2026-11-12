-- Session cwd pass-through: the project file cache must list the workspace the
-- caller belongs to (a git worktree), and an async refresh must never overwrite
-- the cache after the reader moved on. Defaults stay `getcwd()`.

local FilesCache = require("pi.cache.files")

describe("session cwd: files cache", function()
    local original_cwd = vim.fn.getcwd()
    local dirs = {} ---@type string[]

    --- Create a git repo with the given relative files, without cd-ing into it.
    ---@param files string[]
    ---@return string repo directory (symlink-resolved, the form the cache keys on)
    local function make_repo(files)
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        vim.system({ "git", "init", "-q", dir }):wait()
        for _, f in ipairs(files) do
            vim.fn.writefile({ "x" }, dir .. "/" .. f)
        end
        dir = assert(vim.uv.fs_realpath(dir))
        dirs[#dirs + 1] = dir
        return dir
    end

    before_each(function()
        FilesCache._reset()
    end)

    after_each(function()
        FilesCache._reset()
        vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
        for _, dir in ipairs(dirs) do
            vim.fn.delete(dir, "rf")
        end
        dirs = {}
    end)

    it("lists an explicit workspace without cd-ing into it", function()
        local main = make_repo({ "main.txt" })
        local worktree = make_repo({ "worktree.txt" })
        vim.cmd("cd " .. vim.fn.fnameescape(main))

        assert.are.same({ "worktree.txt" }, FilesCache.list(worktree))
        assert.are.equal(worktree, FilesCache._cache().cwd)
        assert.are.equal(main, vim.fn.getcwd(), "listing must not have changed Neovim's cwd")
    end)

    it("keeps defaulting to Neovim's cwd", function()
        local main = make_repo({ "only-main.txt" })
        make_repo({ "other.txt" })
        vim.cmd("cd " .. vim.fn.fnameescape(main))

        assert.are.same({ "only-main.txt" }, FilesCache.list())
        assert.are.equal(main, FilesCache._cache().cwd)
    end)

    it("resolves exists() against the requested workspace", function()
        local main = make_repo({ "main.txt" })
        local worktree = make_repo({ "worktree-only.txt" })
        vim.cmd("cd " .. vim.fn.fnameescape(main))

        assert.is_true(FilesCache.exists("worktree-only.txt", worktree))
        assert.is_false(FilesCache.exists("worktree-only.txt"), "Neovim's cwd must not see it")
        assert.is_true(FilesCache.exists("main.txt"))
    end)

    it("isolates each workspace's refreshed listing in its own slot", function()
        local main = make_repo({ "a.txt" })
        local worktree = make_repo({ "b.txt" })
        vim.cmd("cd " .. vim.fn.fnameescape(main))

        -- Warm both workspaces first, then add one file to each so the
        -- refreshes have something new to pick up.
        assert.are.same({ "b.txt" }, FilesCache.list(worktree))
        assert.are.same({ "a.txt" }, FilesCache.list(main))
        vim.fn.writefile({ "x" }, worktree .. "/c.txt")
        vim.fn.writefile({ "x" }, main .. "/d.txt")
        FilesCache._expire(worktree)
        FilesCache._expire(main)

        -- Both reads are served from their own (stale) slot.
        assert.are.same({ "b.txt" }, FilesCache.list(worktree))
        assert.are.same({ "a.txt" }, FilesCache.list(main))

        -- Both background refreshes land, each in its own workspace.
        assert.is_true(
            vim.wait(3000, function()
                local w = FilesCache._cache(worktree)
                local m = FilesCache._cache(main)
                return w ~= nil
                    and m ~= nil
                    and vim.tbl_contains(w.files, "c.txt")
                    and vim.tbl_contains(m.files, "d.txt")
            end, 10),
            "each workspace's refresh must land in its own slot"
        )

        assert.are.same({ "b.txt", "c.txt" }, FilesCache._cache(worktree).files)
        assert.are.same({ "a.txt", "d.txt" }, FilesCache._cache(main).files)
    end)

    it("does not cancel a workspace's in-flight refresh when another workspace is read", function()
        local main = make_repo({ "main.txt" })
        local worktree = make_repo({ "b.txt" })
        vim.cmd("cd " .. vim.fn.fnameescape(main))

        -- Warm the worktree, then make it stale: the next read returns the
        -- stale list and schedules the workspace's refresh.
        assert.are.same({ "b.txt" }, FilesCache.list(worktree))
        vim.fn.writefile({ "x" }, worktree .. "/c.txt")
        FilesCache._expire(worktree)
        assert.are.same({ "b.txt" }, FilesCache.list(worktree))
        assert.are.equal(1, FilesCache._refresh_spawns(worktree))

        -- Reads in the other workspace while that refresh is in flight must
        -- neither cancel it nor wait on it (the old single-slot code dropped
        -- the worktree result and re-entered a blocking fetch forever).
        assert.are.same({ "main.txt" }, FilesCache.list(main))
        assert.is_true(FilesCache.exists("main.txt", main))
        assert.are.equal(1, FilesCache._refresh_spawns(worktree), "the in-flight refresh must not be restarted")

        assert.is_true(
            vim.wait(3000, function()
                local c = FilesCache._cache(worktree)
                return c ~= nil and vim.tbl_contains(c.files, "c.txt")
            end, 10),
            "the worktree refresh must still land"
        )
        assert.are.same({ "main.txt" }, FilesCache._cache(main).files, "the other workspace's slot is untouched")
    end)

    it("alternating workspaces keep serving their own caches without a new cold fetch", function()
        local a = make_repo({ "a.txt" })
        local b = make_repo({ "b.txt" })

        -- Warm both workspaces: exactly one blocking cold fetch each.
        assert.are.same({ "a.txt" }, FilesCache.list(a))
        assert.are.same({ "b.txt" }, FilesCache.list(b))
        assert.are.equal(2, FilesCache._sync_fetches())
        assert.are.equal(1, FilesCache._sync_fetches(a))
        assert.are.equal(1, FilesCache._sync_fetches(b))

        -- Expire both and alternate: every read is answered from that
        -- workspace's stale slot (stale-while-revalidate), never from a
        -- blocking `git ls-files` on the main loop.
        FilesCache._expire(a)
        FilesCache._expire(b)
        for _ = 1, 3 do
            assert.are.same({ "a.txt" }, FilesCache.list(a))
            assert.are.same({ "b.txt" }, FilesCache.list(b))
        end
        assert.are.equal(2, FilesCache._sync_fetches(), "alternation must not trigger a cold refetch")
        assert.are.equal(1, FilesCache._refresh_spawns(a), "single-flight per workspace")
        assert.are.equal(1, FilesCache._refresh_spawns(b), "single-flight per workspace")

        -- And both refreshes do land, each in its own slot.
        assert.is_true(
            vim.wait(3000, function()
                local ca = FilesCache._cache(a)
                local cb = FilesCache._cache(b)
                local now = vim.uv.hrtime()
                return ca ~= nil and cb ~= nil and (now - ca.timestamp) < 5e9 and (now - cb.timestamp) < 5e9
            end, 10),
            "both workspace refreshes must land"
        )
    end)
end)
