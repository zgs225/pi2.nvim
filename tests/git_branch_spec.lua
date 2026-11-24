-- Unit tests for pi.git_branch: the display matrix is derived from `<git_dir>/HEAD`
-- only, so every fixture here is a fabricated `.git` tree (no git process, and no
-- repository on the machine is touched):
--
--   on a branch        → { name = "…" }
--   detached `HEAD`    → { detached = "<7 chars>" }
--   not a repository   → nil (no placeholder, like every surveyed frontend)
--
-- plus the linked-worktree case (branch lives in the worktree's *own* git dir,
-- resolved through the `.git` file's `gitdir:` pointer) and the `HEAD` watcher
-- that turns a `git checkout` into a title refresh without polling.

local B = require("pi.git_branch")

--- A temp directory whose path is already canonical (`tempname()` may be a
--- symlinked `$TMPDIR`, while the detector resolves real paths).
---@return string
local function tempdir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    return vim.uv.fs_realpath(path) or path
end

--- Write `text` to `path`, creating parent directories.
---@param path string
---@param text string
local function write(path, text)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
end

--- A main-checkout fixture: `<root>/.git/HEAD` only, which is all the reader
--- needs (git itself is never consulted).
---@param head string raw `HEAD` content
---@return string root
local function repo(head)
    local root = tempdir()
    write(root .. "/.git/HEAD", head)
    return root
end

--- A linked-worktree fixture: `<root>/.git` is a *file* pointing at the
--- repository's per-worktree git dir, whose `HEAD` holds the branch.
---@param head string raw `HEAD` content of the worktree
---@return string worktree, string git_dir
local function linked_worktree(head)
    local root = tempdir()
    local git_dir = root .. "/.git/worktrees/wt"
    vim.fn.mkdir(git_dir, "p")
    write(git_dir .. "/HEAD", head)
    write(git_dir .. "/commondir", "../..")
    local wt = tempdir()
    write(wt .. "/.git", "gitdir: " .. git_dir)
    return wt, git_dir
end

describe("pi.git_branch", function()
    local dirs

    before_each(function()
        dirs = {}
        B._reset()
    end)

    after_each(function()
        B._reset()
        for _, dir in ipairs(dirs) do
            vim.fn.delete(dir, "rf")
        end
    end)

    --- Register a fixture directory for cleanup.
    ---@param dir string
    ---@return string
    local function track(dir)
        dirs[#dirs + 1] = dir
        return dir
    end

    describe("read", function()
        it("names the branch on a checkout", function()
            local root = track(repo("ref: refs/heads/feat/login-ui\n"))
            local info = B.read(root)
            assert.are.same("feat/login-ui", info and info.name)
            assert.are.same(root .. "/.git", info and info.git_dir)
            assert.is_nil(info and info.detached)
        end)

        it("answers for a subdirectory of the checkout", function()
            local root = track(repo("ref: refs/heads/main\n"))
            vim.fn.mkdir(root .. "/lua/pi", "p")
            assert.are.same("main", B.read(root .. "/lua/pi").name)
        end)

        it("reads the worktree's own HEAD, not the repository's", function()
            -- The `.git` *file* + `gitdir:` pointer is how git stores a linked
            -- worktree; its HEAD is where a checkout inside it lands.
            local wt, git_dir = linked_worktree("ref: refs/heads/feat/wt\n")
            track(wt)
            track(vim.fn.fnamemodify(git_dir, ":h:h:h"))
            local info = B.read(wt)
            assert.are.same("feat/wt", info and info.name)
            assert.are.same(git_dir, info and info.git_dir)
        end)

        it("detaches to the short sha, with no git process", function()
            -- `pi.worktree_new()` detaches by default, so this is the normal
            -- state of a worktree session until it is put on a branch. HEAD *is*
            -- the commit: the short sha costs no subprocess and no polling.
            local head = "3db087bedce6af065bfb071654742db05eea2b3d"
            local root = track(repo(head))
            local info = B.read(root)
            assert.are.same(head:sub(1, B.SHORT_SHA_LENGTH), info and info.detached)
            assert.are.same(7, #info.detached)
            assert.is_nil(info and info.name)
            assert.are.same("3db087b", B.label(info))
        end)

        it("detaches inside a linked worktree too", function()
            local sha = "abcdef0123456789abcdef0123456789abcdef01"
            local wt, git_dir = linked_worktree(sha)
            track(wt)
            track(vim.fn.fnamemodify(git_dir, ":h:h:h"))
            assert.are.same(sha:sub(1, 7), B.label(B.read(wt)))
        end)

        it("renders nothing outside a repository", function()
            local plain = track(tempdir())
            assert.is_nil(B.read(plain))
            -- A missing or empty directory falls back to Neovim's own cwd (the
            -- chat asks for the session cwd, which may not be known yet).
            assert.are.same(B.read(vim.fn.getcwd()), B.read(nil))
            assert.are.same(B.read(vim.fn.getcwd()), B.read(""))
        end)

        it("renders nothing for a directory that does not exist", function()
            assert.is_nil(B.read("/no/such/directory/anywhere"))
        end)

        it("tolerates a checkout without a usable HEAD", function()
            local missing = track(tempdir())
            vim.fn.mkdir(missing .. "/.git", "p")
            assert.is_nil(B.read(missing))

            local empty = track(repo(""))
            assert.is_nil(B.read(empty))
        end)

        it("ignores a ref that is not a branch", function()
            -- `.invalid` is what tools write into a repository mid-operation
            -- (git's own "this repo is temporarily unusable" marker); anything
            -- outside refs/heads is not a branch, and resolving it would mean a
            -- subprocess on a render path.
            assert.is_nil(B.read(track(repo("ref: refs/heads/.invalid\n"))))
            assert.is_nil(B.read(track(repo("ref: refs/remotes/origin/main\n"))))
            assert.is_nil(B.read(track(repo("not a ref at all\n"))))
        end)

        it("trims the file's line ending", function()
            local root = track(tempdir())
            write(root .. "/.git/HEAD", "ref: refs/heads/crlf\r")
            assert.are.same("crlf", B.read(root).name)
        end)
    end)

    describe("label", function()
        it("prefers the branch name and falls back to the short sha", function()
            assert.are.same("feat/x", B.label({ name = "feat/x", git_dir = "/g" }))
            assert.are.same("3db087b", B.label({ detached = "3db087b", git_dir = "/g" }))
        end)

        it("has nothing to show for a missing or empty record", function()
            assert.is_nil(B.label(nil))
            assert.is_nil(B.label({}))
            assert.is_nil(B.label({ name = "", detached = "" }))
            assert.is_nil(B.label("feat/x"))
        end)
    end)

    describe("watch", function()
        --- Wait until `fn` is true, failing the spec on timeout.
        ---@param fn fun(): boolean
        ---@param message string
        local function wait_for(fn, message)
            assert.is_true(vim.wait(3000, fn, 10), message)
        end

        it("reports a checkout by rewriting HEAD", function()
            local root = track(repo("ref: refs/heads/main\n"))
            local seen = {}
            local unsubscribe = B.watch(root, function(info)
                seen[#seen + 1] = B.label(info)
            end)
            assert.are.same(1, B._active_watches())

            write(root .. "/.git/HEAD", "ref: refs/heads/feat/next\n")
            wait_for(function()
                return #seen == 1
            end, "the HEAD rewrite did not reach the watcher")
            assert.are.same("feat/next", seen[1])

            unsubscribe()
            assert.are.same(0, B._active_watches())

            -- A released watcher must stay quiet: the handle keeps its callback
            -- (and the chat) alive otherwise.
            write(root .. "/.git/HEAD", "ref: refs/heads/main\n")
            vim.wait(300, function()
                return false
            end, 10)
            assert.are.same(1, #seen)
        end)

        it("coalesces several writes into one refresh", function()
            local root = track(repo("ref: refs/heads/main\n"))
            local seen = {}
            local unsubscribe = B.watch(root, function(info)
                seen[#seen + 1] = B.label(info)
            end)
            write(root .. "/.git/HEAD", "ref: refs/heads/one\n")
            write(root .. "/.git/HEAD", "ref: refs/heads/two\n")
            wait_for(function()
                return #seen == 1
            end, "the debounced refresh never landed")
            -- The debounce read the *latest* file, and an unchanged rewrite of
            -- the same ref must not re-render.
            assert.are.same("two", seen[1])
            write(root .. "/.git/HEAD", "ref: refs/heads/two\n")
            vim.wait(300, function()
                return false
            end, 10)
            assert.are.same(1, #seen)
            unsubscribe()
        end)

        it("reports a branch that switched to detached and back", function()
            local root = track(repo("ref: refs/heads/main\n"))
            local seen = {}
            local unsubscribe = B.watch(root, function(info)
                seen[#seen + 1] = B.label(info) or "none"
            end)
            local sha = "0123456789abcdef0123456789abcdef01234567"
            write(root .. "/.git/HEAD", sha)
            wait_for(function()
                return #seen == 1
            end, "a detached HEAD was not reported")
            assert.are.same(sha:sub(1, 7), seen[1])

            write(root .. "/.git/HEAD", "ref: refs/heads/back\n")
            wait_for(function()
                return #seen == 2
            end, "the re-attached branch was not reported")
            assert.are.same("back", seen[2])
            unsubscribe()
        end)

        it("does nothing outside a repository", function()
            local plain = track(tempdir())
            local calls = 0
            local unsubscribe = B.watch(plain, function()
                calls = calls + 1
            end)
            assert.are.same(0, B._active_watches())
            assert.are.same("function", type(unsubscribe))
            unsubscribe()
            assert.are.same(0, calls)
        end)

        it("closes every watcher on _reset", function()
            local root = track(repo("ref: refs/heads/main\n"))
            B.watch(root, function() end)
            B.watch(root, function() end)
            assert.are.same(2, B._active_watches())
            B._reset()
            assert.are.same(0, B._active_watches())
        end)
    end)
end)
