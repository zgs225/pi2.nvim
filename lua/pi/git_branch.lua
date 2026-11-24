--- Git branch of a checkout, read from `<git_dir>/HEAD`.
---
--- Derived, never stored: pi's RPC protocol carries no git state (the TUI
--- resolves the branch in-process for its footer), so a frontend that wants to
--- show it has to read it. Reading `HEAD` is one small file read, which is what
--- the pi TUI and Crush both do — a `git symbolic-ref` / `git branch
--- --show-current` subprocess costs an order of magnitude more and could never
--- run on a render path (this plugin redraws the history title on every streamed
--- event). Because the file *is* the state, a checkout can also be *observed* by
--- watching that file instead of polling git.
---
--- The git directory comes from `pi.worktree.detect` — a cached, subprocess-free
--- filesystem walk that already resolves a `.git` *file* (`gitdir:` pointers of
--- linked worktrees and submodules) and `commondir`. That matters: a linked
--- worktree keeps its own `HEAD` in its own git dir, so the branch must be read
--- from there, never from the repository's main `.git`.
---
--- Three answers, matching every surveyed frontend (a directory that is not a
--- checkout renders nothing at all — no placeholder):
---
---   - on a branch   → `{ name = "feat/login-ui" }`
---   - detached HEAD → `{ detached = "3db087b" }` — `HEAD` *is* the commit, so
---                     the short sha needs no subprocess either
---   - no repository → `nil`
---
--- `pi.worktree_new()` detaches by default, so `detached` is the normal state
--- for a worktree session until `pi.worktree_branch()` puts it on a branch; it
--- is displayed rather than hidden precisely because hiding it would leave the
--- common case with no indicator at all.
local M = {}

local uv = vim.uv or vim.loop

--- Characters of a detached `HEAD` shown as its name (git's own default
--- abbreviation, and what Gemini CLI displays for the same case).
M.SHORT_SHA_LENGTH = 7

--- Quiet period between a `HEAD` write and the re-read. A checkout writes the
--- file once, but tools may touch it more than once (checkout + reset), and the
--- watcher is per open chat UI.
local DEBOUNCE_MS = 150

---@class pi.GitBranch
---@field name? string Branch name (absent when `HEAD` is detached)
---@field detached? string Short commit hash (absent when on a branch)
---@field git_dir string Git directory the `HEAD` was read from

---@class pi.GitBranchWatch
---@field git_dir string
---@field head? string Raw `HEAD` text last read — the file is the whole state
---@field on_change fun(info: pi.GitBranch?)
---@field handle? uv.uv_fs_event_t
---@field pending boolean Debounce timer armed
---@field closed boolean

--- Watchers kept alive by their callback; `M._reset()` closes them all.
---@type table<pi.GitBranchWatch, true>
local live_watches = {}

---@param watches table<pi.GitBranchWatch, true>
---@param state pi.GitBranchWatch
local function drop(watches, state)
    if state.closed then
        return
    end
    state.closed = true
    state.pending = false
    local handle = state.handle
    state.handle = nil
    if handle then
        pcall(handle.stop, handle)
        if not handle:is_closing() then
            pcall(handle.close, handle)
        end
    end
    watches[state] = nil
end

--- Read a whole (small) file without throwing.
---@param path string
---@return string?
local function read_text(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local text = file:read("*a")
    file:close()
    return text
end

--- Git directory of `dir`, or nil when it is not inside a checkout.
---@param dir string
---@return string?
local function detect_git_dir(dir)
    local loaded, Worktree = pcall(require, "pi.worktree")
    if not loaded or type(Worktree) ~= "table" or type(Worktree.detect) ~= "function" then
        return nil
    end
    local ok, info = pcall(Worktree.detect, dir)
    if not ok or type(info) ~= "table" then
        return nil
    end
    local git_dir = info.git_dir
    if type(git_dir) ~= "string" or git_dir == "" then
        return nil
    end
    return git_dir
end

--- Raw `HEAD` text, or nil when it cannot be read (a `git init` that never
--- produced one, an unreadable or corrupt git dir).
---@param git_dir string
---@return string?
local function read_head(git_dir)
    local text = read_text(git_dir .. "/HEAD")
    if type(text) ~= "string" then
        return nil
    end
    local head = vim.trim((text:gsub("\r", "")))
    if head == "" then
        return nil
    end
    return head
end

--- Turn a raw `HEAD` into a branch record.
---
--- `HEAD` is git's own storage: `ref: refs/heads/<name>` on a branch, a bare
--- commit hash when detached, a raw sha of an unborn branch's target otherwise.
--- Anything else — a symref outside `refs/heads/`, the `.invalid` placeholder
--- some tools write into a mid-operation repository — answers `nil`: showing a
--- ref name that is not a branch would be worse than showing nothing, and
--- resolving it would mean a subprocess on a render path.
---@param head string
---@param git_dir string
---@return pi.GitBranch?
local function parse_head(head, git_dir)
    local name = head:match("^ref:%s*refs/heads/(.+)$")
    if name and name ~= "" and name ~= ".invalid" then
        return { name = name, git_dir = git_dir }
    end
    if #head >= M.SHORT_SHA_LENGTH and head:match("^%x+$") then
        return { detached = head:sub(1, M.SHORT_SHA_LENGTH), git_dir = git_dir }
    end
    return nil
end

--- The branch of the checkout `cwd` belongs to.
---
--- One cached `pi.worktree.detect` (marker-stamped, no subprocess) plus one
--- `HEAD` read. Safe on a render path.
---@param cwd? string directory to inspect (default: Neovim's cwd)
---@return pi.GitBranch?
function M.read(cwd)
    local dir = type(cwd) == "string" and vim.trim(cwd) or ""
    if dir == "" then
        dir = vim.fn.getcwd()
    end
    local git_dir = detect_git_dir(dir)
    if not git_dir then
        return nil
    end
    local head = read_head(git_dir)
    if not head then
        return nil
    end
    return parse_head(head, git_dir)
end

--- Display text for a branch record: the branch name, or the short sha of a
--- detached `HEAD`. `nil` when there is nothing to show.
---@param info pi.GitBranch?
---@return string?
function M.label(info)
    if type(info) ~= "table" then
        return nil
    end
    if type(info.name) == "string" and info.name ~= "" then
        return info.name
    end
    if type(info.detached) == "string" and info.detached ~= "" then
        return info.detached
    end
    return nil
end

--- Re-read `HEAD` and report the new record when the file changed.
---@param state pi.GitBranchWatch
local function check(state)
    if state.closed then
        return
    end
    local head = read_head(state.git_dir)
    if head == state.head then
        return
    end
    state.head = head
    local info = nil
    if head then
        info = parse_head(head, state.git_dir)
    end
    state.on_change(info)
end

--- Coalesce the writes of one checkout into a single re-read.
---@param state pi.GitBranchWatch
local function schedule_check(state)
    if state.closed or state.pending then
        return
    end
    state.pending = true
    vim.defer_fn(function()
        state.pending = false
        check(state)
    end, DEBOUNCE_MS)
end

--- An unsubscribe that has nothing to release.
---@return fun()
local function noop()
    return function() end
end

--- Watch `cwd`'s checkout for a branch switch (`git checkout` inside the agent's
--- bash tool, or in a terminal next to the editor) and call `on_change` with the
--- new record — `nil` once the checkout stops being one.
---
--- The watcher is an `fs_event` on the git directory, filtered to `HEAD`: the
--- same file the reader reads, so there is nothing to poll and nothing to keep
--- in sync. Filesystems that cannot watch (network mounts, some WSL setups)
--- simply report no event; the caller's own refresh at each turn boundary is
--- the fallback, exactly like Codex CLI's model.
---
--- The returned unsubscribe function must be called when the UI goes away: the
--- handle keeps the state table alive, so a closed chat would otherwise leave a
--- watcher behind for every tab it ever opened.
---@param cwd? string directory to watch (default: Neovim's cwd)
---@param on_change fun(info: pi.GitBranch?)
---@return fun() unsubscribe
function M.watch(cwd, on_change)
    local dir = type(cwd) == "string" and vim.trim(cwd) or ""
    if dir == "" then
        dir = vim.fn.getcwd()
    end
    local git_dir = detect_git_dir(dir)
    if not git_dir or type(on_change) ~= "function" then
        return noop
    end
    local state = {
        git_dir = git_dir,
        head = read_head(git_dir),
        on_change = on_change,
        pending = false,
        closed = false,
    }
    local handle = uv.new_fs_event()
    if not handle then
        return noop
    end
    state.handle = handle
    local watching = pcall(function()
        handle:start(git_dir, {}, function(err, filename)
            -- A dropped watch (directory removed by `git worktree prune`) must
            -- not throw in the event loop: the handle simply stops reporting,
            -- and the next turn-boundary refresh re-arms it.
            if err then
                return
            end
            -- Some platforms report no filename for a directory watch.
            if filename == nil or filename == "HEAD" then
                schedule_check(state)
            end
        end)
    end)
    if not watching then
        if not handle:is_closing() then
            pcall(handle.close, handle)
        end
        state.handle = nil
        return noop
    end
    live_watches[state] = true
    return function()
        drop(live_watches, state)
    end
end

--- Number of watchers currently open (specs assert the teardown).
---@return integer
function M._active_watches()
    local count = 0
    for _ in pairs(live_watches) do
        count = count + 1
    end
    return count
end

--- Test helper: close every watch.
function M._reset()
    for state in pairs(live_watches) do
        drop(live_watches, state)
    end
    live_watches = {}
end

return M
