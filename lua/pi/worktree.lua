--- Git worktree isolation.
---
--- A *worktree* here is a linked git worktree created at a path the module
--- owns — `<repo>/.worktrees/<name>` by default, wherever `M.worktrees_root`
--- says — on a **detached HEAD**, so several agent sessions can touch the same repository
--- without racing on one working tree or on a branch. The module owns:
---
--- - creation (`.worktrees/<name>`, one line in `<git-common-dir>/info/exclude`,
---   detached checkout, metadata, `.worktreeinclude` copy, optional `setup_cmd`
---   hook),
--- - detection of the worktree a directory belongs to (pure filesystem read, no
---   git subprocess — safe to call from rendering paths),
--- - state queries (dirty/ahead), snapshotting, cleanup (=release), apply-style
---   diffing, and re-attaching a branch.
---
--- Metadata lives in the *per-worktree git dir* git itself creates
--- (`<common>/worktrees/<name>/pi2-worktree.json`), written atomically
--- (tmp + fsync + rename) and never inside the work tree, so it can never show up
--- in `git status`, never leaks into a clone, and disappears together with the
--- worktree when git removes it.
---
--- Everything that spawns git goes through `run()` (async, `vim.system` +
--- `vim.schedule`), and every public function takes a node-style callback
--- `cb(result, err)`. Nothing here touches buffers, windows, or `vim.notify`.

local M = {}

local Config = require("pi.config")
local RepoConfig = require("pi.worktree_config")

local uv = vim.uv

---@class pi.WorktreeInfo
---@field kind "linked"|"main" Linked worktree or the repository's main work tree
---@field name string Worktree name (metadata `name`, falling back to the directory basename)
---@field path string Absolute work tree root
---@field repo_root string Absolute path of the repository's main work tree
---@field git_dir string Absolute per-worktree git dir (`<repo>/.git` for the main work tree)
---@field common_dir? string Absolute common git dir (shared by every worktree)
---@field base_sha? string Commit the worktree was created from
---@field mode? string Creation mode recorded in the metadata (`"isolated"` by default)
---@field session_id? string pi session bound to this worktree
---@field session_file? string pi session transcript file bound to this worktree
---@field managed? boolean Metadata (`pi2-worktree.json`) present in its git dir
---@field locked? boolean A `git worktree lock` is in effect (read from `<git_dir>/locked`)
---@field lock_reason? string Raw lock reason text (nil when unlocked)

---@class pi.WorktreeCreateOpts
---@field cwd string Directory that selects the repository (usually the session cwd)
---@field session_id? string pi session id recorded in the checkout's lock reason (`-` while unknown)
---@field name? string Worktree name (its directory under the worktree root); generated when omitted
---@field mode? string Free-form mode recorded in the metadata (default `"isolated"`)
---@field base? string Commit the checkout is detached at (default: the repository's current `HEAD`); any revision `git rev-parse` accepts
---@field setup? boolean Run `worktree.setup_cmd` after the checkout is ready (default true); `false` skips it for callers that must stay fast (sub-session spawns)

---@class pi.WorktreeBaseOpts
---@field kind? string `"head"` (default: the checkout `cwd` runs in), `"fresh"` (the remote default branch), or any revision `git rev-parse` accepts
---@field cwd? string Directory that resolves `head` and the repository (default: the process cwd)
---@field repo? string Repository root used for `fresh` and revision lookups (default: resolved from `cwd`)

---@class pi.WorktreeStatus
---@field dirty boolean Uncommitted changes (tracked, staged, or untracked)
---@field ahead integer Commits on the worktree's HEAD that are not in `base_sha`
---@field head string Current HEAD commit sha

--- State of the `git worktree lock` of one checkout.
---@class pi.WorktreeLockState
---@field locked boolean
---@field ours boolean Reason starts with `"pi2 "`
---@field reason? string Raw reason text (nil when unlocked, or when locked without a reason)

--- Outcome of `M.sweep_locks`.
---@class pi.WorktreeSweepReport
---@field released string[] Paths whose stale pi2 lock was released
---@field kept string[] Paths considered but left alone (pids alive, foreign reason, other host)
---@field foreign integer Foreign-locked checkouts seen (never touched)

---@class pi.WorktreeBindFields
---@field session_id? string
---@field session_file? string

--- Result of `M.probe`: the patch applies here (`"clean"`), is already applied
--- (`"already"`), or applies neither way (`"conflict"`).
---@alias pi.WorktreeProbeState "clean"|"already"|"conflict"

--- Metadata sidecar written next to every snapshot patch, so the patch stays
--- self-describing after the worktree itself is gone.
---@class pi.WorktreeSnapshotMeta
---@field name string Worktree name
---@field path string Work tree root the patch was captured from
---@field repo_root string Repository main checkout root
---@field base_sha string Commit the patch is relative to
---@field head string HEAD commit at capture time
---@field created_at integer Unix timestamp (seconds)

---@class pi.WorktreeSnapshot
---@field path string Absolute path of the `.patch` file
---@field meta? pi.WorktreeSnapshotMeta Sidecar metadata (nil when missing or unreadable)

---@class pi.WorktreeSnapshotGcOpts
---@field keep_days? number Snapshots of a gone checkout younger than this are kept (default 30)
---@field live_names? table<string, true> Names whose checkout still exists: keep every patch
---@field now? integer Clock override in Unix seconds (tests)

--- A linked worktree as reported by `git worktree list --porcelain`, enriched
--- with the `detect()` metadata. Used by cross-worktree resume.
---@class pi.WorktreeListEntry: pi.WorktreeInfo
---@field head string HEAD commit reported by git (`""` when unparsed)
---@field branch? string Branch name (`refs/heads/` stripped) when not detached
---@field detached boolean True when git reports the worktree as detached
---@field prunable boolean git reports a prunable gitdir (directory gone)
---@field missing? boolean True when the registered directory is gone (prunable/missing); `path` no longer exists, the session binding may
---@field snapshot? string Snapshot patch backing a `missing` entry (only set by `snapshot_worktrees`)
---@field managed boolean Metadata (`pi2-worktree.json`) present in its git dir
---@field locked boolean A `git worktree lock` is in effect
---@field locked_reason? string Lock reason text reported by `git worktree list`

local META_FILE = "pi2-worktree.json"
--- Bumped when the metadata layout changes; readers reject newer versions.
local META_VERSION = 1
local WORKTREES_DIR = ".worktrees"
local EXCLUDE_LINE = "/.worktrees/"
local INCLUDE_FILE = ".worktreeinclude"
local SNAPSHOT_DIR = "pi2-worktree-snapshots"
--- Suffix of the snapshot metadata sidecar (`<patch>.json`).
local SIDECAR_SUFFIX = ".json"
--- Default snapshot retention window for `M.snapshot_gc`, in days.
local SNAPSHOT_KEEP_DAYS = 30
--- Hard stop for pathological `.worktreeinclude` matches (e.g. a whole
--- `node_modules/` tree). Refusing loudly beats hanging the editor.
local MAX_INCLUDE_FILES = 20000
local MAX_NAME_LENGTH = 64
local MAX_WALK_DEPTH = 64
local COPY_BUDGET = 64
--- Seconds a cached remote ref stays fresh before `fresh` re-fetches.
local FRESH_TTL_SECONDS = 24 * 60 * 60
--- Hard cap on the `fresh` fetch/`ls-remote`, so an offline remote never stalls a spawn.
local FRESH_TIMEOUT_MS = 5000
--- Repositories whose `fresh` fetch already failed this session: retrying a
--- dead remote on every spawn would add the timeout to each one.
---@type table<string, true>
local fresh_fetch_failed = {}

--- Test-only override for `MAX_INCLUDE_FILES` (`M._set_max_files`).
---@type integer?
local max_files_override = nil

--- Monotonic counter behind `default_name()`: a timestamp alone repeats within
--- the same second, so back-to-back creations would collide on one directory.
local default_name_seq = 0

--- Effective file cap for `.worktreeinclude` copies *and* untracked-file capture.
---@return integer
local function max_files()
    return max_files_override or MAX_INCLUDE_FILES
end

-- Filesystem helpers ---------------------------------------------------------

---@param path string
---@return string
local function norm(path)
    return vim.fs.normalize(path)
end

---@param path string
---@return string
local function parent(path)
    local dir = vim.fs.dirname(path)
    return dir or path
end

---@param path string
---@return string
local function basename(path)
    return vim.fs.basename(path) or path
end

---@param path string
---@return boolean
local function is_abs(path)
    return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

---@param path string
---@return table?
local function stat(path)
    return uv.fs_stat(path)
end

---@param path string
---@return boolean
local function is_dir(path)
    local st = stat(path)
    return st ~= nil and st.type == "directory"
end

---@param path string
---@return string?
local function read_text(path)
    local fd = uv.fs_open(path, "r", 420)
    if not fd then
        return nil
    end
    local st = uv.fs_fstat(fd)
    local data = st and uv.fs_read(fd, st.size, 0) or nil
    uv.fs_close(fd)
    return data
end

--- Create every missing directory of `dir` (libuv only, no `vim.fn` work).
---@param dir string
---@return string? err
local function mkdirp(dir)
    if type(dir) ~= "string" or dir == "" then
        return nil
    end
    if stat(dir) then
        return nil
    end
    local up = parent(dir)
    if up ~= dir and up ~= "" then
        local err = mkdirp(up)
        if err then
            return err
        end
    end
    local ok, err = uv.fs_mkdir(dir, 493) -- 0755
    if not ok and not stat(dir) then
        return "mkdir " .. dir .. ": " .. tostring(err)
    end
    return nil
end

--- Write `text` to `path` through a sibling temp file: readers see either the
--- old or the new content, never a truncated file. Same-directory rename keeps
--- the operation atomic (cross-device rename is not).
---@param path string
---@param text string
---@return boolean ok
---@return string? err
local function write_atomic(path, text)
    local tmp = path .. ".tmp"
    local fd, open_err = uv.fs_open(tmp, "w", 420)
    if not fd then
        return false, "open " .. tmp .. ": " .. tostring(open_err)
    end
    local wrote, write_err = uv.fs_write(fd, text, 0)
    if not wrote then
        uv.fs_close(fd)
        uv.fs_unlink(tmp)
        return false, "write " .. tmp .. ": " .. tostring(write_err)
    end
    pcall(uv.fs_fsync, fd)
    uv.fs_close(fd)
    local renamed, rename_err = uv.fs_rename(tmp, path)
    if not renamed then
        uv.fs_unlink(tmp)
        return false, "rename " .. tmp .. ": " .. tostring(rename_err)
    end
    return true, nil
end

---@param path string
---@return string? Real path when the path exists, nil otherwise.
local function realpath(path)
    return uv.fs_realpath(path)
end

--- Resolve `path` to an existing directory, following symlinks. Returns nil when
--- the path does not exist (never falls back to the process cwd).
---@param path string?
---@return string?
local function resolve_dir(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local abs = norm(path)
    local st = stat(abs)
    if not st then
        return nil
    end
    if st.type ~= "directory" then
        abs = parent(abs)
        if not is_dir(abs) then
            return nil
        end
    end
    return realpath(abs) or abs
end

---@param path string
---@return boolean
local function path_exists(path)
    return stat(path) ~= nil
end

---@param path string
---@param dir string
---@return boolean
local function is_under(path, dir)
    if path == dir then
        return true
    end
    return path:sub(1, #dir + 1) == dir .. "/"
end

-- Text helpers ---------------------------------------------------------------

---@param text string?
---@return string
local function first_line(text)
    if type(text) ~= "string" then
        return ""
    end
    return vim.trim((text:gsub("\r", ""):match("^[^\n]*")) or "")
end

--- Last `n` non-empty lines of `text`, joined with " | ".
---@param text string?
---@param n integer
---@return string
local function tail(text, n)
    if type(text) ~= "string" or text == "" then
        return ""
    end
    local lines = {}
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        local trimmed = vim.trim(line)
        if trimmed ~= "" then
            lines[#lines + 1] = trimmed
        end
    end
    while #lines > n do
        table.remove(lines, 1)
    end
    return table.concat(lines, " | ")
end

--- Split NUL-terminated git output (the `-z` formats).
---@param text string?
---@return string[]
local function split_nul(text)
    local out = {}
    if type(text) ~= "string" then
        return out
    end
    for item in text:gmatch("([^%z]*)%z") do
        if item ~= "" then
            out[#out + 1] = item
        end
    end
    return out
end

---@param op string
---@param code integer
---@param stderr string?
---@return string
local function git_err(op, code, stderr)
    local detail = first_line(stderr)
    if detail == "" then
        return string.format("%s failed (exit %d)", op, code)
    end
    return string.format("%s failed (exit %d): %s", op, code, detail)
end

--- True when `git worktree add` refused because the target path is *registered
--- but missing* (the directory was deleted by hand, or a crash left
--- `.git/worktrees/<name>` behind).
---
--- A missing registration reports "already registered", a missing *and locked*
--- one reports "missing but locked worktree" (`use 'add -f -f' to override, or
--- 'unlock' and 'prune' …`). Both may be recovered, but only after the lock — if
--- any — is dealt with; "already exists" (a real directory is in the way) must
--- never be forced.
---@param text string?
---@return boolean
local function is_stale_registration(text)
    if type(text) ~= "string" then
        return false
    end
    local lower = text:lower()
    if lower:find("already exists", 1, true) then
        return false
    end
    return lower:find("already registered", 1, true) ~= nil or lower:find("missing but locked", 1, true) ~= nil
end

-- Process runner -------------------------------------------------------------

---@alias pi.WorktreeRunner fun(argv: string[], opts: table, cb: fun(code: integer, stdout: string, stderr: string))

---@type pi.WorktreeRunner?
local runner_override = nil

---@alias pi.WorktreeSidecarWriter fun(path: string, meta: pi.WorktreeSnapshotMeta): boolean, string?

--- Test-only override for the snapshot sidecar writer (`M._set_sidecar_writer`).
---@type pi.WorktreeSidecarWriter?
local sidecar_writer_override = nil

--- Run `argv` asynchronously. The callback always fires on the main loop.
---@param argv string[]
---@param opts { cwd?: string, stdin?: string, timeout?: integer, env?: table<string, string> } `timeout` (ms) kills the process; `env` is the **full** environment (see `vim.system`'s `clear_env` default)
---@param cb fun(code: integer, stdout: string, stderr: string)
local function run(argv, opts, cb)
    if runner_override then
        return runner_override(argv, opts or {}, cb)
    end
    if type(argv) ~= "table" or #argv == 0 then
        return vim.schedule(function()
            cb(-1, "", "spawn failed: empty argv")
        end)
    end
    local sys = { text = true }
    if opts and opts.cwd then
        sys.cwd = opts.cwd
    end
    if opts and opts.env then
        -- `vim.system` replaces the whole environment unless `clear_env = false`
        -- is passed, so a caller that needs extra variables hands over the full
        -- merged table (see `run_setup_command`).
        ---@diagnostic disable-next-line: undefined-field -- `env` is runtime-valid but missing from the bundled `vim.system` types
        sys.env = opts.env
    end
    if opts and opts.stdin then
        sys.stdin = opts.stdin
    end
    if opts and opts.timeout then
        sys.timeout = opts.timeout
    end
    -- vim.system throws when the binary cannot be spawned at all.
    local ok, err = pcall(vim.system, argv, sys, function(res)
        vim.schedule(function()
            cb(res.code or -1, res.stdout or "", res.stderr or "")
        end)
    end)
    if not ok then
        vim.schedule(function()
            cb(-1, "", "spawn failed: " .. tostring(err))
        end)
    end
end

-- Metadata -------------------------------------------------------------------

---@param meta table
---@return table
local function meta_payload(meta)
    return {
        version = META_VERSION,
        name = meta.name,
        path = meta.path,
        repo_root = meta.repo_root,
        base_sha = meta.base_sha,
        mode = meta.mode,
        session_id = meta.session_id == nil and vim.NIL or meta.session_id,
        session_file = meta.session_file == nil and vim.NIL or meta.session_file,
    }
end

--- Read the metadata file of a per-worktree git dir.
---
--- Absent and corrupt files read as "no metadata" `(nil, nil)`. A file written by
--- a *newer* pi.nvim is refused `(nil, err)`: its layout is unknown, so rewriting
--- it would silently drop fields this build does not understand.
---@param git_dir string
---@return table? meta
---@return string? err
local function read_meta(git_dir)
    local text = read_text(git_dir .. "/" .. META_FILE)
    if type(text) ~= "string" or text == "" then
        return nil, nil
    end
    local ok, data = pcall(vim.json.decode, text)
    if not ok or type(data) ~= "table" or data == vim.NIL then
        return nil, nil
    end
    for key, value in pairs(data) do
        if value == vim.NIL then
            data[key] = nil
        end
    end
    local version = data.version
    if type(version) == "number" and version > META_VERSION then
        return nil,
            string.format(
                "unsupported worktree metadata version %s (this build understands %d)",
                tostring(version),
                META_VERSION
            )
    end
    return data, nil
end

---@param git_dir string
---@param meta table
---@return boolean ok
---@return string? err
local function write_meta(git_dir, meta)
    local mk_err = mkdirp(git_dir)
    if mk_err then
        return false, mk_err
    end
    local ok, text = pcall(vim.json.encode, meta_payload(meta))
    if not ok then
        return false, "encode metadata: " .. tostring(text)
    end
    return write_atomic(git_dir .. "/" .. META_FILE, text)
end

---@param git_dir string
---@return string
local function meta_path(git_dir)
    return git_dir .. "/" .. META_FILE
end

-- Detection ------------------------------------------------------------------

--- One cached `M.detect` result, revalidated by cheap `stat` stamps.
---@class pi.WorktreeDetectCacheEntry
---@field marker string? Absolute `.git` marker the info was built from
---@field marker_stamp string Stamp of that marker when the info was built
---@field meta_path string? Metadata file of the per-worktree git dir
---@field meta_stamp string Stamp of that metadata file
---@field lock_path string `<git_dir>/locked` (the lock state `locked`/`lock_reason` came from)
---@field lock_stamp string Stamp of that lock file
---@field info pi.WorktreeInfo

---@type table<string, pi.WorktreeDetectCacheEntry>
local detect_cache = {}

--- Cheap identity stamp for a file: changes whenever git/we rewrites it.
---@param path string?
---@return string
local function file_stamp(path)
    if type(path) ~= "string" then
        return "none"
    end
    local st = stat(path)
    if not st then
        return "none"
    end
    local mtime = st.mtime or {}
    return table.concat({
        st.type,
        tostring(mtime.sec or 0),
        tostring(mtime.nsec or 0),
        tostring(st.size or 0),
        tostring(st.ino or 0),
    }, ":")
end

---@param text string?
---@return string?
local function parse_gitdir_file(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local line = text:match("^gitdir:%s*(.-)%s*[\r\n]") or text:match("^gitdir:%s*(.-)%s*$")
    if type(line) ~= "string" or line == "" then
        return nil
    end
    return line
end

--- Walk up from `start` until a `.git` marker (directory or file) is found.
---@param start string
---@return string? marker Absolute `.git` path
---@return "dir"|"file"? marker type
---@return string? containing directory
local function find_git_marker(start)
    local dir = start
    for _ = 1, MAX_WALK_DEPTH do
        local marker = dir .. "/.git"
        local st = stat(marker)
        if st then
            return marker, st.type == "directory" and "dir" or "file", dir
        end
        local up = parent(dir)
        if up == dir or up == "" then
            return nil
        end
        dir = up
    end
    return nil
end

--- Resolve `<git_dir>/commondir` into an absolute path.
---@param git_dir string
---@return string?
local function resolve_common_dir(git_dir)
    local text = read_text(git_dir .. "/commondir")
    if type(text) ~= "string" then
        return nil
    end
    local rel = vim.trim(text)
    if rel == "" then
        return nil
    end
    if not is_abs(rel) then
        rel = git_dir .. "/" .. rel
    end
    return realpath(rel) or norm(rel)
end

---@param target string
---@return string? Absolute per-worktree git dir of a linked worktree
local function worktree_git_dir(target)
    local text = read_text(target .. "/.git")
    if type(text) ~= "string" then
        return nil
    end
    local gitdir = parse_gitdir_file(text)
    if not gitdir then
        return nil
    end
    if not is_abs(gitdir) then
        gitdir = target .. "/" .. gitdir
    end
    return realpath(gitdir) or norm(gitdir)
end

--- Common git dir of a repository, resolved without spawning git.
---
--- Declared here (not next to the snapshot helpers that use it) because
--- `ensure_excluded` needs it: a Lua `local function` is only visible after its
--- declaration, so a later definition would silently resolve to a global.
---@param repo_root string
---@return string? common_dir
local function repo_common_dir(repo_root)
    local marker = repo_root .. "/.git"
    local st = stat(marker)
    if not st then
        -- A BARE repository has no `.git` entry: it *is* its own git dir, so
        -- `worktrees/` and the snapshot store live directly under it. Probe the
        -- two files git itself uses to recognise one (`objects/` is a directory,
        -- `HEAD` a file) instead of spawning `git rev-parse --git-dir`.
        local objects = stat(repo_root .. "/objects")
        local head = stat(repo_root .. "/HEAD")
        if objects and objects.type == "directory" and head and head.type == "file" then
            return realpath(repo_root) or norm(repo_root)
        end
        return nil
    end
    local git_dir = realpath(marker) or marker
    if st.type == "directory" then
        -- A `.git` *directory* can carry a `commondir` file too (a submodule's
        -- git dir, or a checkout created with `--separate-git-dir`), so it is
        -- resolved exactly like the gitdir-file case below: skipping it would
        -- report a private per-worktree dir where the shared one is meant.
        return resolve_common_dir(git_dir) or git_dir
    end
    local gitdir = parse_gitdir_file(read_text(marker))
    if not gitdir then
        return nil
    end
    if not is_abs(gitdir) then
        gitdir = repo_root .. "/" .. gitdir
    end
    git_dir = realpath(gitdir) or norm(gitdir)
    return resolve_common_dir(git_dir) or git_dir
end

--- Build the info table for the work tree containing `cwd`.
---@param cwd string Absolute existing directory
---@return pi.WorktreeInfo?
---@return string? marker
local function build_info(cwd)
    local marker, kind, dir = find_git_marker(cwd)
    if not marker or not dir then
        return nil
    end

    local git_dir
    local common_dir
    local repo_root
    local wt_kind
    if kind == "dir" then
        git_dir = marker
        common_dir = git_dir
        repo_root = dir
        wt_kind = "main"
    else
        local target = parse_gitdir_file(read_text(marker))
        if not target then
            return nil
        end
        if not is_abs(target) then
            target = dir .. "/" .. target
        end
        git_dir = realpath(target) or norm(target)
        common_dir = resolve_common_dir(git_dir)
        wt_kind = "linked"
    end

    local meta = read_meta(git_dir) or {}

    if not repo_root then
        if type(meta.repo_root) == "string" and meta.repo_root ~= "" then
            repo_root = meta.repo_root
        elseif common_dir then
            repo_root = parent(common_dir)
        else
            return nil
        end
    end

    local name = type(meta.name) == "string" and meta.name ~= "" and meta.name or basename(dir)
    ---@type pi.WorktreeInfo
    local info = {
        kind = wt_kind --[[@as "linked"|"main"]],
        name = name,
        path = realpath(dir) or dir,
        repo_root = realpath(repo_root) or repo_root,
        git_dir = git_dir,
        common_dir = common_dir,
        base_sha = type(meta.base_sha) == "string" and meta.base_sha or nil,
        mode = type(meta.mode) == "string" and meta.mode or nil,
        session_id = type(meta.session_id) == "string" and meta.session_id or nil,
        session_file = type(meta.session_file) == "string" and meta.session_file or nil,
        managed = next(meta) ~= nil,
    }
    -- One `stat` + read of `<git_dir>/locked`, no subprocess: that file *is* the
    -- lock state (`git worktree list` is not asked).
    local lock = M.lock_state(info)
    info.locked = lock.locked
    info.lock_reason = lock.reason
    return info, marker
end

--- Invalidate the detection cache (worktree created/removed/bound).
local function invalidate()
    detect_cache = {}
end

--- Test helper: drop the detection cache (and any injected runner).
function M._reset()
    detect_cache = {}
    runner_override = nil
    max_files_override = nil
    sidecar_writer_override = nil
    default_name_seq = 0
    fresh_fetch_failed = {}
end

--- Test helper: replace the process runner. Pass nil to restore the real one.
---@param fn pi.WorktreeRunner?
function M._set_runner(fn)
    runner_override = fn
end

--- Test helper: replace the snapshot sidecar writer. Pass nil to restore the real one.
---@param fn pi.WorktreeSidecarWriter?
function M._set_sidecar_writer(fn)
    sidecar_writer_override = fn
end

--- Test helper: override the file cap (nil restores the default).
---@param n integer?
function M._set_max_files(n)
    max_files_override = n
end

--- Resolve the worktree a directory belongs to.
---
--- Pure filesystem work (reads `.git`, the metadata file, `commondir` and the
--- per-worktree `locked` file), no git subprocess, so it is safe to call on
--- rendering paths. Results are cached per directory and revalidated with cheap
--- `stat` stamps (marker, metadata, lock file).
---@param cwd string? Directory to inspect (default: the process cwd)
---@return pi.WorktreeInfo?
function M.detect(cwd)
    local dir = resolve_dir(cwd or vim.fn.getcwd())
    if not dir then
        return nil
    end

    local cached = detect_cache[dir]
    if cached then
        local marker_same = file_stamp(cached.marker) == cached.marker_stamp
        local meta_same = file_stamp(cached.meta_path) == cached.meta_stamp
        local lock_same = file_stamp(cached.lock_path) == cached.lock_stamp
        if marker_same and meta_same and lock_same then
            return cached.info
        end
        detect_cache[dir] = nil
    end

    local info, marker = build_info(dir)
    if not info then
        return nil
    end
    local entry_meta = meta_path(info.git_dir)
    local entry_lock = info.git_dir .. "/locked"
    detect_cache[dir] = {
        marker = marker,
        marker_stamp = file_stamp(marker),
        meta_path = entry_meta,
        meta_stamp = file_stamp(entry_meta),
        lock_path = entry_lock,
        lock_stamp = file_stamp(entry_lock),
        info = info,
    }
    return info
end

-- Locking --------------------------------------------------------------------

-- `git worktree lock` is the only thing that stops `git worktree prune` /
-- `git worktree remove` from deleting a checkout out from under a running agent,
-- so every checkout we create gets one and loses it when the checkout goes away.
-- Git stores the reason as plain text in `<git_dir>/locked`; reading that file is
-- the whole lock-state query (no subprocess), which keeps the hot paths cheap.

--- Read `<git_dir>/locked`, git's physical storage for a worktree lock.
---@param git_dir string?
---@return string? reason Trimmed reason text; nil when unlocked, `""` when locked without a reason
local function read_lock_reason(git_dir)
    if type(git_dir) ~= "string" or git_dir == "" then
        return nil
    end
    local text = read_text(git_dir .. "/locked")
    if type(text) ~= "string" then
        return nil
    end
    return vim.trim((text:gsub("\r", "")))
end

---@param reason string?
---@return boolean True when the reason was written by this plugin (`^pi2%s`)
local function is_our_lock(reason)
    return type(reason) == "string" and reason:find("^pi2%s") ~= nil
end

--- Parse a lock reason into its `key=value` fields.
---
--- Tolerant on purpose: unknown fields are ignored and a malformed reason simply
--- yields no fields, so a caller must treat "ours but unparseable" as "no pids
--- recorded" (i.e. leave the lock alone).
---@param reason string?
---@return table<string, string>
local function parse_lock_fields(reason)
    local fields = {}
    if type(reason) ~= "string" then
        return fields
    end
    for key, value in reason:gmatch("([%w_]+)=(%S+)") do
        fields[key] = value
    end
    return fields
end

---@return string hostname Hostname, or `"-"` when it cannot be read.
local function local_hostname()
    local ok, name = pcall(uv.os_gethostname)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return "-"
end

--- The reason recorded in `<git_dir>/locked` (stable format — the sweep and the
--- tests parse it):
--- `pi2 name=<name> session=<id|-> pid=<agentpid|0> nvim=<nvimpid> host=<host>`.
---@param name string Checkout name (`validate_name` forbids spaces)
---@param opts { session_id?: string, pid?: integer }?
---@return string
local function lock_reason(name, opts)
    local session = "-"
    local pid = 0
    if type(opts) == "table" then
        if type(opts.session_id) == "string" and opts.session_id ~= "" then
            session = opts.session_id
        end
        if type(opts.pid) == "number" and opts.pid > 0 then
            pid = math.floor(opts.pid)
        end
    end
    return string.format(
        "pi2 name=%s session=%s pid=%d nvim=%d host=%s",
        name,
        session,
        pid,
        uv.os_getpid(),
        local_hostname()
    )
end

--- Lock bookkeeping only reads the per-worktree git dir, so a `missing` checkout
--- (directory already gone, registration still there) is a valid argument too.
---@param info pi.WorktreeInfo
---@return boolean ok
---@return string? err
local function check_lock_info(info)
    if type(info) ~= "table" then
        return false, "worktree: info table required"
    end
    if type(info.path) ~= "string" or info.path == "" then
        return false, "worktree: path missing"
    end
    if type(info.repo_root) ~= "string" or info.repo_root == "" then
        return false, "worktree: repo_root missing"
    end
    if type(info.git_dir) ~= "string" or info.git_dir == "" then
        return false, "worktree: git_dir missing"
    end
    return true, nil
end

--- Lock state of a checkout. Synchronous and filesystem only — never errors.
---@param info pi.WorktreeInfo
---@return pi.WorktreeLockState
function M.lock_state(info)
    if type(info) ~= "table" then
        return { locked = false, ours = false }
    end
    local reason = read_lock_reason(info.git_dir)
    if reason == nil then
        return { locked = false, ours = false }
    end
    ---@type pi.WorktreeLockState
    return {
        locked = true,
        ours = is_our_lock(reason),
        reason = reason ~= "" and reason or nil,
    }
end

--- Release our lock. Unlocked → `cb(true)`. A foreign lock is never touched:
--- `cb(nil, "unlock: …")` and nothing runs. `git worktree unlock` failing with
--- "is not locked" (git exits 128 for that) counts as success.
---@param info pi.WorktreeInfo
---@param cb fun(ok: boolean?, err: string?)
function M.unlock(info, cb)
    if type(cb) ~= "function" then
        return
    end
    local info_ok, info_err = check_lock_info(info)
    if not info_ok then
        return cb(nil, "unlock: " .. tostring(info_err))
    end
    local state = M.lock_state(info)
    if not state.locked then
        return cb(true)
    end
    if not state.ours then
        return cb(nil, string.format("unlock: %s is locked (%s)", info.path, tostring(state.reason)))
    end
    run({ "git", "-C", info.repo_root, "worktree", "unlock", info.path }, {}, function(code, stdout, stderr)
        invalidate()
        if code == 0 then
            return cb(true)
        end
        local detail = stderr ~= "" and stderr or stdout
        -- The checkout is unlocked either way, which is all the caller asked for.
        if (detail or ""):find("is not locked", 1, true) then
            return cb(true)
        end
        cb(false, "unlock: " .. git_err("git worktree unlock", code, detail))
    end)
end

--- Take (or refresh) our lock.
---
--- Refreshing means "ours → unlock, then lock with the new reason", which is how
--- the reason learns the agent pid once a session is bound. A foreign lock is
--- never touched: `cb(nil, "lock: <path> is locked (<reason>)")`.
---
--- `worktree.lock = false` is honoured here (not only in `create`), so every
--- caller inherits the knob; a disabled lock reports success without spawning git.
---@param info pi.WorktreeInfo
---@param opts? { session_id?: string, pid?: integer } Recorded in the lock reason
---@param cb fun(ok: boolean?, err: string?)
function M.lock(info, opts, cb)
    if type(opts) == "function" then
        cb, opts = opts, nil
    end
    if type(cb) ~= "function" then
        return
    end
    local info_ok, info_err = check_lock_info(info)
    if not info_ok then
        return cb(nil, "lock: " .. tostring(info_err))
    end
    -- Single gate for the knob: `create` asks earlier too, but only to skip the
    -- whole step cheaply (and to avoid a pointless re-read of the lock file).
    if (Config.options.worktree or {}).lock == false then
        return cb(true)
    end
    local state = M.lock_state(info)
    if state.locked and not state.ours then
        return cb(nil, string.format("lock: %s is locked (%s)", info.path, tostring(state.reason)))
    end

    local reason = lock_reason(info.name or basename(info.path), opts)

    local function take()
        local argv = { "git", "-C", info.repo_root, "worktree", "lock", "--reason", reason, info.path }
        run(argv, {}, function(code, stdout, stderr)
            invalidate()
            if code ~= 0 then
                return cb(nil, "lock: " .. git_err("git worktree lock", code, stderr ~= "" and stderr or stdout))
            end
            cb(true)
        end)
    end

    if not state.locked then
        return take()
    end
    M.unlock(info, function(unlocked, unlock_err)
        if not unlocked then
            return cb(nil, unlock_err)
        end
        take()
    end)
end

---@param pid integer
---@return boolean True when the process exists (EPERM counts: it exists, it is just not ours)
local function pid_alive(pid)
    if type(pid) ~= "number" or pid <= 0 then
        return false
    end
    local ok, rc, err, errname = pcall(uv.kill, pid, 0)
    if not ok then
        return false
    end
    if rc == 0 then
        return true
    end
    local detail = tostring(err) .. " " .. tostring(errname)
    return detail:find("EPERM", 1, true) ~= nil or detail:find("permission denied", 1, true) ~= nil
end

--- Every owner pid recorded in a reason: agent `pid` and creating `nvim`
--- (`0`/absent means "unknown" and is skipped).
---@param reason string?
---@return integer[]
local function lock_pids(reason)
    local fields = parse_lock_fields(reason)
    local pids = {}
    for _, key in ipairs({ "pid", "nvim" }) do
        local value = tonumber(fields[key])
        if value and value > 0 then
            pids[#pids + 1] = math.floor(value)
        end
    end
    return pids
end

--- Can this `pi2 ` lock be released by *this* process?
---
--- The lock is a cross-process guard, so removal and the sweep must obey the same
--- rule: our own process may always release its own lock and a dead owner makes
--- the lock stale, while a lock taken on another host, a lock with no recorded pid
--- (nothing proves the owner is gone) and a lock whose owner is still alive block.
---@param reason string Ours (`pi2 `-prefixed)
---@return boolean ok
---@return string? err Why it must be kept
local function lock_releasable(reason)
    local fields = parse_lock_fields(reason)
    local host = fields.host
    if type(host) == "string" and host ~= "" and host ~= local_hostname() then
        return false, "it was taken on another host (" .. host .. ")"
    end
    local pids = lock_pids(reason)
    if #pids == 0 then
        return false, "it records no owner pid"
    end
    local self = uv.os_getpid()
    for _, pid in ipairs(pids) do
        if pid ~= self and pid_alive(pid) then
            return false, "its owner (pid " .. pid .. ") is still running"
        end
    end
    return true, nil
end

--- Release locks WE set whose owning processes are all gone.
---
--- Never touches a reason that is not ours, a lock recorded on another host, or a
--- lock with no recorded pid at all (nothing proves its owner is dead). Runs off
--- the worktree listing, so a stale lock on an already-missing checkout is found
--- too — such a lock keeps `git worktree prune` from cleaning the registration up.
---@param cwd string? Any directory inside the repository (default: the process cwd)
---@param cb fun(report: pi.WorktreeSweepReport?, err: string?)
function M.sweep_locks(cwd, cb)
    if type(cb) ~= "function" then
        return
    end
    M.list(cwd, function(entries, list_err)
        if type(entries) ~= "table" then
            return cb(nil, list_err or "sweep: cannot list worktrees")
        end
        ---@type pi.WorktreeSweepReport
        local report = { released = {}, kept = {}, foreign = 0 }
        local host = local_hostname()
        local index = 0

        ---@param done fun()
        local function step(done)
            index = index + 1
            local entry = entries[index]
            if not entry then
                return done()
            end
            local state = M.lock_state(entry)
            if not state.locked then
                return step(done)
            end
            if not state.ours then
                report.foreign = report.foreign + 1
                report.kept[#report.kept + 1] = entry.path
                return step(done)
            end
            -- Deliberately *not* `lock_releasable`: the sweep treats every live pid
            -- as alive, including this process's own (a checkout we are still using
            -- must survive the sweep), while removal may release its own lock.
            local fields = parse_lock_fields(state.reason)
            local pids = lock_pids(state.reason)
            local alive = false
            for _, pid in ipairs(pids) do
                if pid_alive(pid) then
                    alive = true
                    break
                end
            end
            local other_host = type(fields.host) == "string" and fields.host ~= host
            if other_host or #pids == 0 or alive then
                report.kept[#report.kept + 1] = entry.path
                return step(done)
            end
            M.unlock(entry, function(unlocked)
                if unlocked then
                    report.released[#report.released + 1] = entry.path
                else
                    report.kept[#report.kept + 1] = entry.path
                end
                step(done)
            end)
        end

        step(function()
            cb(report, nil)
        end)
    end)
end

-- Layout --------------------------------------------------------------------

--- Directory holding this repository's worktrees: a worktree called `name`
--- lives at `<worktrees_root>/<name>`.
---
--- The single owner of the layout. Call sites join through here instead of
--- repeating `repo_root .. "/" .. ".worktrees"`, so a different location (a
--- sibling directory, a configured absolute root) has exactly one place to
--- change. Deliberately trivial: no existence check, no `mkdir`, no trailing
--- slash — callers probe and canonicalize as they need.
---@param repo_root string Repository root (the main checkout).
---@return string
function M.worktrees_root(repo_root)
    return repo_root .. "/" .. WORKTREES_DIR
end

-- Name validation ------------------------------------------------------------

--- Validate a worktree name. A name is one directory component under the
--- repository's worktree root (`M.worktrees_root`), so anything that could
--- escape or hide is rejected.
---@param name any
---@return boolean ok
---@return string? err
function M.validate_name(name)
    if type(name) ~= "string" then
        return false, "worktree: name must be a string"
    end
    if name == "" or #name > MAX_NAME_LENGTH then
        return false, string.format("worktree: name must be 1..%d characters", MAX_NAME_LENGTH)
    end
    if name:sub(1, 1) == "." then
        return false, "worktree: name must not start with '.'"
    end
    if not name:match("^[%w][%w._-]*$") then
        return false, "worktree: name may only contain letters, digits, '.', '_' and '-'"
    end
    return true, nil
end

--- Generated name: second-resolution timestamp, the process pid, and a
--- per-process sequence. Both extras are needed: a timestamp alone repeats for
--- creations inside the same second, and the pid keeps concurrent Neovim
--- instances from picking the same directory. Sub-session checkouts get their
--- own `sub-` prefix so an owned child checkout is recognisable by name.
---@param prefix? string `"wt"` when omitted
---@return string
local function default_name(prefix)
    default_name_seq = default_name_seq + 1
    return string.format("%s-%s-%d-%d", prefix or "wt", os.date("%Y%m%d-%H%M%S"), vim.uv.os_getpid(), default_name_seq)
end

-- Base resolution -----------------------------------------------------------

--- Modification time of `path`, in seconds (nil when it does not exist).
---@param path string
---@return integer?
local function file_mtime(path)
    local stat = vim.uv.fs_stat(path)
    if not stat or not stat.mtime then
        return nil
    end
    return stat.mtime.sec
end

--- Resolve a base commit for a new worktree.
---
--- `kind` is one of:
---   * `"head"` (default): the commit the checkout `opts.cwd` runs in is on. A
---     parent session may itself run in a linked worktree, and then this is that
---     worktree's HEAD — the state its conversation is looking at.
---   * `"fresh"`: the repository's **remote default branch**
---     (`refs/remotes/origin/HEAD`). The branch is re-fetched at most once per
---     24h, capped at 5s; a failed or impossible fetch falls back to the locally
---     cached remote ref, then to `HEAD`. Never blocks on a prompt (no
---     credentials) — git is run with a timeout and the result is not checked
---     for interaction.
---   * any other string: a revision `git rev-parse` accepts.
---@param opts pi.WorktreeBaseOpts
---@param cb fun(sha: string?, err: string?)
function M.resolve_base(opts, cb)
    if type(cb) ~= "function" then
        return
    end
    if type(opts) ~= "table" then
        return cb(nil, "base: opts table required")
    end
    local cwd = resolve_dir(opts.cwd or vim.fn.getcwd())
    if not cwd then
        return cb(nil, "base: not a directory: " .. tostring(opts.cwd))
    end
    local kind = type(opts.kind) == "string" and vim.trim(opts.kind) or ""
    -- `kind == ""` is meaningful: the repository's `.pi-worktrees.toml` (then
    -- `worktree.base_ref`, then HEAD) decides, further down.
    local repo = type(opts.repo) == "string" and vim.trim(opts.repo) or ""

    ---@param fn fun(repo_root: string)
    local function with_repo(fn)
        if repo ~= "" then
            return fn(repo)
        end
        run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, {}, function(code, stdout)
            local root = vim.trim(stdout or "")
            if code ~= 0 or root == "" then
                return cb(nil, "base: not a git repository: " .. cwd)
            end
            repo = realpath(root) or root
            fn(repo)
        end)
    end

    --- Local `HEAD`, falling back to the repository's HEAD when `cwd` has none.
    local function head()
        run({ "git", "-C", cwd, "rev-parse", "--verify", "-q", "HEAD^{commit}" }, {}, function(code, stdout)
            local sha = vim.trim(stdout or "")
            if code == 0 and sha ~= "" then
                return cb(sha)
            end
            with_repo(function(root)
                run({ "git", "-C", root, "rev-parse", "--verify", "-q", "HEAD^{commit}" }, {}, function(code2, out2)
                    local root_sha = vim.trim(out2 or "")
                    if code2 == 0 and root_sha ~= "" then
                        return cb(root_sha)
                    end
                    cb(nil, "base: repository has no commits yet: " .. root)
                end)
            end)
        end)
    end

    if kind == "" then
        -- No strategy given: the repository's `.pi-worktrees.toml` decides, then
        -- the user's `worktree.base_ref`, then the checkout's own HEAD. The root is
        -- resolved only to find that config; a directory that is not a repository
        -- still ends up in `head()`, which reports the real failure itself.
        ---@param root string?
        local function decide(root)
            ---@type string
            local ref = ""
            if type(root) == "string" and root ~= "" then
                local repo_ref = RepoConfig.base_ref(root)
                if type(repo_ref) == "string" then
                    ref = repo_ref
                end
            end
            if ref == "" then
                local cfg = Config.options.worktree or {}
                ref = type(cfg.base_ref) == "string" and vim.trim(cfg.base_ref) or ""
            end
            if ref == "" or ref == "head" then
                return head()
            end
            -- The configured strategy ("fresh" or a revision) resolves through the
            -- same paths as an explicit `kind`, so there is one implementation.
            return M.resolve_base(vim.tbl_extend("force", opts, { kind = ref, repo = root }), cb)
        end
        if repo ~= "" then
            return decide(repo)
        end
        -- Best effort: the root is resolved only to find its config, so a directory
        -- that is not a repository (or a failing git) falls through to `head()`,
        -- which reports the real error itself.
        return run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, {}, function(code, stdout)
            local root = vim.trim(stdout or "")
            if code ~= 0 or root == "" then
                return head()
            end
            decide(realpath(root) or root)
        end)
    end
    if kind == "head" then
        return head()
    end
    if kind ~= "fresh" then
        return with_repo(function(root)
            run({ "git", "-C", root, "rev-parse", "--verify", "-q", kind .. "^{commit}" }, {}, function(code, stdout)
                local sha = vim.trim(stdout or "")
                if code ~= 0 or sha == "" then
                    return cb(nil, "create: invalid base commit: " .. kind)
                end
                cb(sha)
            end)
        end)
    end

    with_repo(function(root)
        ---@param done fun(sha: string?)
        local function cached_head(done)
            run(
                { "git", "-C", root, "rev-parse", "--verify", "-q", "refs/remotes/origin/HEAD^{commit}" },
                {},
                function(code, stdout)
                    local sha = vim.trim(stdout or "")
                    done(code == 0 and sha ~= "" and sha or nil)
                end
            )
        end

        --- Default branch name: the cached `origin/HEAD`, else one `ls-remote`
        --- lookup. A repository without an `origin` reports no branch, so the
        --- caller falls back instead of failing.
        ---@param done fun(branch: string?)
        local function default_branch(done)
            run(
                { "git", "-C", root, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD" },
                {},
                function(code, stdout)
                    local name = vim.trim(stdout or "")
                    if code == 0 and name:match("^origin/%S+") then
                        return done(name:sub(8))
                    end
                    if fresh_fetch_failed[root] then
                        return done(nil)
                    end
                    run(
                        { "git", "-C", root, "ls-remote", "--symref", "origin", "HEAD" },
                        { timeout = FRESH_TIMEOUT_MS },
                        function(code2, out2)
                            local branch = (out2 or ""):match("^ref: refs/heads/(%S+)%s+HEAD")
                            if code2 ~= 0 or not branch then
                                fresh_fetch_failed[root] = true
                                return done(nil)
                            end
                            done(branch)
                        end
                    )
                end
            )
        end

        default_branch(function(branch)
            if not branch then
                return cached_head(function(sha)
                    if sha then
                        return cb(sha)
                    end
                    head()
                end)
            end
            local ref = "refs/remotes/origin/" .. branch
            ---@param done fun(sha: string?)
            local function resolve_ref(done)
                run({ "git", "-C", root, "rev-parse", "--verify", "-q", ref .. "^{commit}" }, {}, function(code, stdout)
                    local sha = vim.trim(stdout or "")
                    done(code == 0 and sha ~= "" and sha or nil)
                end)
            end
            local function after_fetch()
                resolve_ref(function(sha)
                    if sha then
                        return cb(sha)
                    end
                    cached_head(function(head_sha)
                        if head_sha then
                            return cb(head_sha)
                        end
                        head()
                    end)
                end)
            end
            ---@param fetched_at integer?
            local function maybe_fetch(fetched_at)
                local age = fetched_at and (os.time() - fetched_at) or nil
                if age and age >= 0 and age < FRESH_TTL_SECONDS then
                    return after_fetch()
                end
                run(
                    { "git", "-C", root, "fetch", "--no-tags", "--quiet", "origin", branch },
                    { timeout = FRESH_TIMEOUT_MS },
                    function(code)
                        if code == 0 then
                            fresh_fetch_failed[root] = nil
                        else
                            fresh_fetch_failed[root] = true
                        end
                        after_fetch()
                    end
                )
            end
            run({ "git", "-C", root, "rev-parse", "--git-path", "FETCH_HEAD" }, {}, function(_, stdout)
                local path = vim.trim(stdout or "")
                if path ~= "" and not is_abs(path) then
                    path = root .. "/" .. path
                end
                maybe_fetch(path ~= "" and file_mtime(path) or nil)
            end)
        end)
    end)
end

-- info/exclude --------------------------------------------------------------

--- Append `line` to an exclude-file body unless it is already present there.
--- Pure: returns the new content, or nil when nothing needs to change.
---
--- An exact-line test is deliberate: the file is only written after
--- `git check-ignore --no-index` reported that *no* source ignores the path, so
--- a differently-spelled equivalent cannot be present. Keeping the helper dumb
--- leaves the "is it covered?" decision in exactly one place: git itself.
---@param content string?
---@param line string
---@return string?
function M._append_exclude_line(content, line)
    content = content or ""
    for _, raw in ipairs(vim.split(content, "\n", { plain = true })) do
        local trimmed = vim.trim((raw:gsub("\r", "")))
        if trimmed == line then
            return nil
        end
    end
    local out = content
    if out ~= "" and out:sub(-1) ~= "\n" then
        out = out .. "\n"
    end
    return out .. line .. "\n"
end

--- Make sure `<repo>/.worktrees/` is git-ignored, writing one line to
--- `<git-common-dir>/info/exclude` when no ignore source covers it yet.
---
--- `info/exclude` is git's answer for "auxiliary files that live inside the
--- repository but are specific to one user's workflow" (gitignore(5)), and its
--- anchoring is identical to `.gitignore`. The repository's tracked `.gitignore`
--- is therefore never touched and never dirtied; nothing is staged or committed.
---@param repo_root string
---@param cb fun(err: string?)
local function ensure_excluded(repo_root, cb)
    run({ "git", "-C", repo_root, "check-ignore", "-q", "--no-index", WORKTREES_DIR .. "/" }, {}, function(code)
        if code == 0 then
            -- Already ignored by some source (.gitignore, info/exclude,
            -- core.excludesFile): writing anything would only add noise.
            return cb(nil)
        end
        if code ~= 1 then
            return cb("create: cannot inspect ignore rules (git check-ignore exit " .. code .. ")")
        end
        local common = repo_common_dir(repo_root)
        if not common then
            return cb("create: cannot resolve the git common dir of " .. repo_root)
        end
        local info_dir = common .. "/info"
        local mkdir_err = mkdirp(info_dir)
        if mkdir_err then
            return cb("create: failed to create " .. info_dir .. ": " .. mkdir_err)
        end
        local path = info_dir .. "/exclude"
        local updated = M._append_exclude_line(read_text(path), EXCLUDE_LINE)
        if updated == nil then
            return cb(nil)
        end
        local ok, err = write_atomic(path, updated)
        if not ok then
            return cb("create: failed to update " .. path .. ": " .. tostring(err))
        end
        cb(nil)
    end)
end

-- .worktreeinclude -----------------------------------------------------------

--- Parse `.worktreeinclude` into patterns (one per line, `#` comments and blank
--- lines ignored).
---@param text string?
---@return string[]
function M._parse_include(text)
    local out = {}
    for _, raw in ipairs(vim.split(text or "", "\n", { plain = true })) do
        local trimmed = vim.trim((raw:gsub("\r", "")))
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            out[#out + 1] = trimmed
        end
    end
    return out
end

--- Translate `.worktreeinclude` patterns into git pathspecs (`:(glob)` magic).
--- gitignore semantics are permissive about where a bare pattern matches, so a
--- pattern without a slash is mirrored to the recursive form as well.
---@param patterns string[]
---@return string[]
function M._include_pathspecs(patterns)
    local out = {}
    local seen = {}
    local function add(spec)
        if spec == nil or spec == "" or seen[spec] then
            return
        end
        seen[spec] = true
        out[#out + 1] = spec
    end
    for _, raw in ipairs(patterns or {}) do
        local pat = vim.trim(raw)
        if pat ~= "" and pat:sub(1, 1) ~= "#" then
            pat = pat:gsub("^%./", ""):gsub("^/", "")
            local had_slash = pat:sub(-1) == "/"
            pat = pat:gsub("/+$", "")
            if pat ~= "" then
                add(":(glob)" .. pat)
                add(":(glob)" .. pat .. "/**")
                if not had_slash and not pat:find("/", 1, true) then
                    add(":(glob)**/" .. pat)
                end
            end
        end
    end
    return out
end

--- Copy the files matched by `.worktreeinclude` into a fresh worktree. Only
--- files git *ignores* are copied (the intersection of `.gitignore` and
--- `.worktreeinclude`), and the `.worktrees/` directory itself is never copied.
---
--- A repository's `include` list in `.pi-worktrees.toml` is **additive**: the two
--- sources are merged, so a config file never has to repeat what
--- `.worktreeinclude` already says (and vice versa).
---@param info pi.WorktreeInfo
---@param cb fun(err: string?)
local function copy_includes(info, cb)
    local patterns = M._parse_include(read_text(info.repo_root .. "/" .. INCLUDE_FILE))
    for _, pattern in ipairs(RepoConfig.include_patterns(info.repo_root)) do
        patterns[#patterns + 1] = pattern
    end
    local pathspecs = M._include_pathspecs(patterns)
    if #pathspecs == 0 then
        return cb(nil)
    end

    local argv = { "git", "-C", info.repo_root, "ls-files", "-z", "-o", "-i", "--exclude-standard", "--" }
    vim.list_extend(argv, pathspecs)

    run(argv, {}, function(code, stdout, stderr)
        if code ~= 0 then
            return cb("include: " .. git_err("git ls-files", code, stderr))
        end
        local files = {}
        for _, rel in ipairs(split_nul(stdout)) do
            if rel ~= WORKTREES_DIR and not is_under(rel, WORKTREES_DIR) then
                files[#files + 1] = rel
            end
        end
        if #files > max_files() then
            return cb(string.format("include: %d files match %s (limit %d)", #files, INCLUDE_FILE, max_files()))
        end

        local index = 0
        local function step()
            local budget = 0
            while index < #files and budget < COPY_BUDGET do
                index = index + 1
                budget = budget + 1
                local rel = files[index]
                local src = info.repo_root .. "/" .. rel
                local dst = info.path .. "/" .. rel
                local mk_err = mkdirp(parent(dst))
                if mk_err then
                    return cb("include: " .. mk_err)
                end
                local ok, copy_err = uv.fs_copyfile(src, dst)
                if not ok then
                    return cb("include: failed to copy " .. rel .. ": " .. tostring(copy_err))
                end
            end
            if index < #files then
                vim.schedule(step)
            else
                cb(nil)
            end
        end
        vim.schedule(step)
    end)
end

-- setup_cmd ------------------------------------------------------------------

--- Run one argv command inside a fresh checkout.
---
--- Both `worktree.setup_cmd` and a repository's `[setup]` lists get the same two
--- variables, so a project script does not have to guess where it is:
--- `PI_ROOT_WORKTREE_PATH` is the repository's main checkout (Cursor's
--- `$ROOT_WORKTREE_PATH` — the usual source of a local `.env`), and
--- `PI_WORKTREE_PATH` is the checkout being set up (also the cwd).
---@param info pi.WorktreeInfo
---@param argv string[]
---@param label string Prefix of the error message ("setup_cmd", ".pi-worktrees.toml setup")
---@param cb fun(err: string?)
local function run_setup_command(info, argv, label, cb)
    local env = vim.fn.environ()
    env.PI_ROOT_WORKTREE_PATH = info.repo_root
    env.PI_WORKTREE_PATH = info.path
    run(argv, { cwd = info.path, env = env }, function(code, stdout, stderr)
        if code == 0 then
            return cb(nil)
        end
        local detail = tail(stderr ~= "" and stderr or stdout, 10)
        if detail == "" then
            return cb(label .. " failed (exit " .. code .. ")")
        end
        return cb(label .. " failed (exit " .. code .. "): " .. detail)
    end)
end

--- Normalize `worktree.setup_cmd` (a string or a string[]) into an argv list.
---@param cmd any
---@return string[]? argv
---@return string? err
local function user_setup_argv(cmd)
    if cmd == nil then
        return nil
    end
    if type(cmd) == "string" then
        cmd = { cmd }
    end
    if type(cmd) ~= "table" then
        return nil, "setup_cmd: expected a string[]"
    end
    local argv = {}
    for _, part in ipairs(cmd) do
        if type(part) ~= "string" then
            return nil, "setup_cmd: every element must be a string"
        end
        argv[#argv + 1] = part
    end
    if #argv == 0 then
        return nil
    end
    return argv
end

--- Run the setup hooks of a fresh checkout, in order: `worktree.setup_cmd`
--- (the user's machine-level commands) and then the repository's
--- `.pi-worktrees.toml` `[setup]` lists.
---
--- The repository's commands are **opt-in** (`worktree.repo_setup`): a cloned
--- repository is untrusted input, and running its commands on checkout would be
--- remote code execution. Declaring them while the switch is off is reported
--- once, never silently ignored.
---@param info pi.WorktreeInfo
---@param cb fun(err: string?)
local function run_setup(info, cb)
    local cfg = Config.options.worktree or {}
    local argv, argv_err = user_setup_argv(cfg.setup_cmd)
    if argv_err then
        return cb(argv_err)
    end

    ---@type { argv: string[], label: string }[]
    local commands = {}
    if argv then
        commands[#commands + 1] = { argv = argv, label = "setup_cmd" }
    end
    local repo_commands = RepoConfig.setup_commands(info.repo_root)
    if #repo_commands > 0 then
        if cfg.repo_setup == true then
            for _, repo_argv in ipairs(repo_commands) do
                commands[#commands + 1] = { argv = repo_argv, label = RepoConfig.FILE .. " setup" }
            end
        else
            RepoConfig.note_setup_skipped(info.repo_root)
        end
    end

    ---@param index integer
    local function step(index)
        local command = commands[index]
        if not command then
            return cb(nil)
        end
        run_setup_command(info, command.argv, command.label, function(err)
            if err then
                return cb(err)
            end
            step(index + 1)
        end)
    end
    step(1)
end

-- Creation -------------------------------------------------------------------

---@param info pi.WorktreeInfo
---@return table
local function info_meta(info)
    return {
        name = info.name,
        path = info.path,
        repo_root = info.repo_root,
        base_sha = info.base_sha,
        mode = info.mode,
        session_id = info.session_id,
        session_file = info.session_file,
    }
end

--- Hand the repository to the retention module, which debounces and defers the
--- actual sweep, so this costs nothing on the creation path.
---
--- The `require` is lazy on purpose: `pi.worktree_retention` calls back into this
--- module, so a module-level require would create a load-order cycle. A missing or
--- broken module is not fatal — retention is best-effort housekeeping.
---@param repo_root string
local function schedule_retention(repo_root)
    local worktree_cfg = Config.options.worktree or {}
    local retention = type(worktree_cfg.retention) == "table" and worktree_cfg.retention or {}
    if retention.enabled == false then
        return
    end
    local ok, Retention = pcall(require, "pi.worktree_retention")
    if not ok or type(Retention) ~= "table" or type(Retention.schedule) ~= "function" then
        return
    end
    pcall(Retention.schedule, repo_root)
end

--- Create a linked worktree under `<repo>/.worktrees/<name>` on a detached HEAD.
---
--- Steps (in order, each one leaving the repository consistent):
---   1. reject non-directories, non-git directories, repositories without a
---      commit yet, and creation from *inside* a linked worktree,
---   2. ensure `/.worktrees/` is excluded (one line in
---      `<git-common-dir>/info/exclude`; the tracked `.gitignore` is untouched),
---   3. `git worktree add --detach <target> <base>` (`opts.base`, default `HEAD`),
---   4. write the metadata into the new per-worktree git dir and lock the checkout
---      (`worktree.lock`, skipped when it is `false`),
---   5. copy `.worktreeinclude` ∩ gitignored files,
---   6. run `worktree.setup_cmd` (async, cwd = worktree) unless `opts.setup` is `false`,
---   7. hand the repository to the deferred retention sweep.
---
--- A failing lock removes the checkout again: a worktree nobody can lock is a
--- worktree an external `git worktree prune` / `remove` may delete under a live
--- agent. Any other failure after step 3 keeps the worktree on disk (so nothing is
--- lost) and reports the error; the worktree is already registered with git then.
---@param opts pi.WorktreeCreateOpts
---@param cb fun(info: pi.WorktreeInfo?, err: string?)
function M.create(opts, cb)
    if type(cb) ~= "function" then
        return
    end
    if type(opts) ~= "table" then
        return cb(nil, "create: opts table required")
    end

    local cwd = resolve_dir(opts.cwd or vim.fn.getcwd())
    if not cwd then
        return cb(nil, "create: not a directory: " .. tostring(opts.cwd))
    end

    local current = M.detect(cwd)
    if current and current.kind == "linked" then
        return cb(
            nil,
            string.format(
                "create: already inside worktree %s (%s); create from the main checkout",
                current.name,
                current.path
            )
        )
    end

    local mode = type(opts.mode) == "string" and opts.mode ~= "" and opts.mode or "isolated"
    local name = opts.name
    if name == nil then
        name = default_name(mode == "subagent" and "sub" or nil)
    end
    local name_ok, name_err = M.validate_name(name)
    if not name_ok then
        return cb(nil, name_err)
    end

    run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, {}, function(code, stdout)
        local repo_root = vim.trim(stdout or "")
        if code ~= 0 or repo_root == "" then
            return cb(nil, "create: not a git repository: " .. cwd)
        end
        repo_root = realpath(repo_root) or repo_root

        local worktrees_root = M.worktrees_root(repo_root)
        if is_under(cwd, worktrees_root) then
            return cb(nil, "create: refusing to create a worktree inside " .. worktrees_root)
        end

        local target = worktrees_root .. "/" .. name
        if path_exists(target) then
            return cb(nil, "create: worktree already exists: " .. target)
        end

        local requested = type(opts.base) == "string" and vim.trim(opts.base) or ""
        -- An explicit `base` wins; an empty one hands the choice to
        -- `resolve_base`, which consults the repository's `.pi-worktrees.toml`
        -- `base_ref`, then `worktree.base_ref`, then the checkout's HEAD.
        M.resolve_base({ kind = requested, cwd = cwd, repo = repo_root }, function(base_sha, base_err)
            if type(base_sha) ~= "string" or base_sha == "" then
                return cb(nil, base_err or ("create: cannot resolve a base commit for " .. repo_root))
            end

            ensure_excluded(repo_root, function(exclude_err)
                if exclude_err then
                    return cb(nil, exclude_err)
                end

                ---@param force boolean
                ---@return string[]
                local function add_argv(force)
                    local argv = { "git", "-C", repo_root, "worktree", "add" }
                    if force then
                        argv[#argv + 1] = "--force"
                    end
                    vim.list_extend(argv, { "--detach", target, base_sha })
                    return argv
                end

                --- Post-add steps, shared by the plain add and the `--force` retry.
                local function on_added()
                    local git_dir = worktree_git_dir(target)
                    if not git_dir then
                        return cb(nil, "create: created " .. target .. " but cannot resolve its git dir")
                    end

                    ---@type pi.WorktreeInfo
                    local info = {
                        kind = "linked",
                        name = name,
                        path = realpath(target) or target,
                        repo_root = repo_root,
                        git_dir = git_dir,
                        common_dir = resolve_common_dir(git_dir) or git_dir,
                        base_sha = base_sha,
                        mode = mode,
                    }

                    local wrote, write_err = write_meta(git_dir, info_meta(info))
                    if not wrote then
                        return cb(nil, "create: failed to write metadata in " .. git_dir .. ": " .. tostring(write_err))
                    end
                    invalidate()

                    --- Locked, filled and set up: hand over to the retention timer
                    --- (deferred there, so this adds no latency) and report.
                    local function succeed()
                        schedule_retention(info.repo_root)
                        cb(info, nil)
                    end

                    --- Take the lock (skipped when `worktree.lock` is `false`).
                    ---@param cont fun(err: string?)
                    local function with_lock(cont)
                        if (Config.options.worktree or {}).lock == false then
                            return cont(nil)
                        end
                        M.lock(info, { session_id = opts.session_id }, function(locked, lock_err)
                            if not locked then
                                return cont(lock_err or "lock failed")
                            end
                            local state = M.lock_state(info)
                            info.locked = state.locked
                            info.lock_reason = state.reason
                            cont(nil)
                        end)
                    end

                    ---@param lock_err string?
                    local function on_lock(lock_err)
                        if lock_err then
                            -- An unguardable checkout is worse than none: drop it again.
                            run({ "git", "-C", repo_root, "worktree", "remove", "--force", target }, {}, function()
                                invalidate()
                                cb(nil, "create: " .. tostring(lock_err))
                            end)
                            return
                        end
                        copy_includes(info, function(include_err)
                            if include_err then
                                return cb(nil, include_err)
                            end
                            if opts.setup == false then
                                return succeed()
                            end
                            run_setup(info, function(setup_err)
                                if setup_err then
                                    return cb(nil, setup_err)
                                end
                                succeed()
                            end)
                        end)
                    end

                    with_lock(on_lock)
                end

                ---@param code integer
                ---@param stdout string
                ---@param stderr string
                ---@param op string
                local function on_add_error(code, stdout, stderr, op)
                    cb(nil, "create: " .. git_err(op, code, stderr ~= "" and stderr or stdout))
                end

                local function retry_force()
                    run(add_argv(true), {}, function(retry_code, retry_out, retry_err)
                        if retry_code ~= 0 then
                            return on_add_error(retry_code, retry_out, retry_err, "git worktree add --force")
                        end
                        on_added()
                    end)
                end

                --- Recover a registered-but-missing target. A lock that is not ours,
                --- or that a live process still holds, is never released: the add
                --- fails instead (`-f -f` would override locks we must respect).
                ---@param retry fun()
                ---@param fail fun(err: string)
                local function recover_stale(retry, fail)
                    -- `<repo>/.git` (a directory, or a gitdir file) → the common dir;
                    -- the stale registration's git dir sits under its `worktrees/`.
                    local common = repo_common_dir(repo_root) or (repo_root .. "/.git")
                    local reason = read_lock_reason(common .. "/worktrees/" .. name)
                    if reason == nil then
                        return retry()
                    end
                    ---@return string
                    local function locked_error()
                        return string.format(
                            "create: %s is locked (%s); run `git worktree unlock %s` first",
                            target,
                            reason,
                            target
                        )
                    end

                    if not is_our_lock(reason) then
                        return fail(locked_error())
                    end
                    -- Same guards as `lock_releasable`: another host's pid says nothing
                    -- about this machine, and a lock without a pid proves nothing.
                    local host = parse_lock_fields(reason).host
                    if type(host) == "string" and host ~= "" and host ~= local_hostname() then
                        return fail(locked_error())
                    end
                    local pids = lock_pids(reason)
                    if #pids == 0 then
                        return fail(locked_error())
                    end
                    local self_pid = uv.os_getpid()
                    for _, pid in ipairs(pids) do
                        -- Our own (possibly reused) pid never blocks: we are the
                        -- creator re-creating our own missing checkout.
                        if pid ~= self_pid and pid_alive(pid) then
                            return fail(
                                string.format("create: %s is still locked by a live process (%s)", target, reason)
                            )
                        end
                    end
                    run({ "git", "-C", repo_root, "worktree", "unlock", target }, {}, function(code, stdout, stderr)
                        local text = stderr ~= "" and stderr or stdout
                        -- The registration is unlocked either way, which is all we need.
                        if code ~= 0 and not (text or ""):find("is not locked", 1, true) then
                            return fail("create: " .. git_err("git worktree unlock", code, text))
                        end
                        invalidate()
                        retry()
                    end)
                end

                run(add_argv(false), {}, function(add_code, add_out, add_err)
                    if add_code == 0 then
                        return on_added()
                    end
                    local detail = add_err ~= "" and add_err or add_out
                    -- A *missing but already registered* target (directory deleted by
                    -- hand, or a crash left `.git/worktrees/<name>` behind) makes a
                    -- plain add fail. `--force` re-creates exactly this path; nothing
                    -- is pruned, so other checkouts (including other users'
                    -- worktrees) are never removed.
                    if not is_stale_registration(detail) then
                        return on_add_error(add_code, add_out, add_err, "git worktree add")
                    end
                    recover_stale(retry_force, function(err)
                        cb(nil, err)
                    end)
                end)
            end)
        end)
    end)
end

-- State ----------------------------------------------------------------------

---@param info pi.WorktreeInfo?
---@return boolean ok
---@return string? err
local function check_info(info)
    if type(info) ~= "table" then
        return false, "worktree: info table required"
    end
    if type(info.path) ~= "string" or not is_dir(info.path) then
        return false, "worktree: path is not a directory: " .. tostring(info.path)
    end
    if type(info.git_dir) ~= "string" or info.git_dir == "" then
        return false, "worktree: git_dir missing"
    end
    if type(info.repo_root) ~= "string" or info.repo_root == "" then
        return false, "worktree: repo_root missing"
    end
    return true, nil
end

--- Query the worktree state: uncommitted changes, commits ahead of the base
--- commit the worktree was created from, and the current HEAD.
---@param info pi.WorktreeInfo
---@param cb fun(status: pi.WorktreeStatus?, err: string?)
function M.status(info, cb)
    if type(cb) ~= "function" then
        return
    end
    local ok, err = check_info(info)
    if not ok then
        return cb(nil, err)
    end

    run({ "git", "-C", info.path, "status", "--porcelain", "-z" }, {}, function(code, stdout, stderr)
        if code ~= 0 then
            return cb(nil, git_err("git status", code, stderr))
        end
        local dirty = type(stdout) == "string" and #stdout > 0

        run({ "git", "-C", info.path, "rev-parse", "HEAD" }, {}, function(head_code, head_out, head_err)
            if head_code ~= 0 then
                return cb(nil, git_err("git rev-parse HEAD", head_code, head_err))
            end
            local head = vim.trim(head_out or "")
            local base = type(info.base_sha) == "string" and info.base_sha ~= "" and info.base_sha or nil
            if not base then
                return cb({ dirty = dirty, ahead = 0, head = head }, nil)
            end

            run(
                { "git", "-C", info.path, "rev-list", "--count", base .. "..HEAD" },
                {},
                function(count_code, count_out, count_err)
                    if count_code ~= 0 then
                        return cb(nil, git_err("git rev-list", count_code, count_err))
                    end
                    cb({ dirty = dirty, ahead = tonumber(vim.trim(count_out or "")) or 0, head = head }, nil)
                end
            )
        end)
    end)
end

-- Diff / snapshot ------------------------------------------------------------

---@param info pi.WorktreeInfo
---@return string? dir
local function snapshot_dir(info)
    local common = info.common_dir or resolve_common_dir(info.git_dir) or info.git_dir
    return common .. "/" .. SNAPSHOT_DIR
end

--- Write the snapshot sidecar (atomic; overridable in tests).
---@param path string
---@param meta pi.WorktreeSnapshotMeta
---@return boolean ok
---@return string? err
local function write_sidecar(path, meta)
    if sidecar_writer_override then
        return sidecar_writer_override(path, meta)
    end
    local ok, text = pcall(vim.json.encode, meta)
    if not ok then
        return false, "encode sidecar metadata: " .. tostring(text)
    end
    return write_atomic(path, text)
end

--- Collect the worktree's patch relative to `from` (default: its base commit),
--- including untracked files (rendered as `git diff --no-index /dev/null <file>`
--- additions, which `git apply` accepts).
---@param info pi.WorktreeInfo
---@param cb fun(diff: string?, err: string?)
---@param from? string Commit to diff from (default: `info.base_sha`)
local function collect_diff(info, cb, from)
    run(
        { "git", "-C", info.path, "diff", "--binary", "--no-color", from or info.base_sha, "--" },
        {},
        function(code, stdout, stderr)
            if code ~= 0 then
                return cb(nil, git_err("git diff", code, stderr))
            end
            local parts = { stdout or "" }

            run(
                { "git", "-C", info.path, "ls-files", "-z", "-o", "--exclude-standard" },
                {},
                function(list_code, list_out, list_err)
                    if list_code ~= 0 then
                        return cb(nil, git_err("git ls-files", list_code, list_err))
                    end
                    local untracked = split_nul(list_out)
                    local limit = max_files()
                    -- Refuse loudly instead of writing an incomplete patch: a
                    -- snapshot that silently leaves files behind is worse than no
                    -- snapshot at all (removal is blocked, the data is still there).
                    if #untracked > limit then
                        return cb(
                            nil,
                            string.format(
                                "cannot capture %d untracked files (limit %d); commit, ignore or remove them first",
                                #untracked,
                                limit
                            )
                        )
                    end
                    local index = 0
                    local function step()
                        index = index + 1
                        if index > #untracked then
                            return cb(table.concat(parts), nil)
                        end
                        local rel = untracked[index]
                        run({
                            "git",
                            "-C",
                            info.path,
                            "diff",
                            "--no-index",
                            "--binary",
                            "--no-color",
                            "--",
                            "/dev/null",
                            rel,
                        }, {}, function(diff_code, diff_out, diff_err)
                            -- `--no-index` exits 1 when the files differ (the normal
                            -- case). Everything else must fail the snapshot: an
                            -- untracked *directory* — i.e. a nested repository — is
                            -- unrepresentable (`error: Could not access '<dir>/null'`,
                            -- exit 1, empty output), and skipping it would drop that
                            -- checkout from the patch without a trace.
                            if diff_code >= 2 then
                                return cb(
                                    nil,
                                    string.format(
                                        "cannot capture untracked path %q: %s",
                                        rel,
                                        git_err("git diff --no-index", diff_code, diff_err)
                                    )
                                )
                            end
                            if type(diff_out) ~= "string" or diff_out:find("diff --git ", 1, true) == nil then
                                local detail = first_line(diff_err)
                                return cb(
                                    nil,
                                    string.format(
                                        "cannot capture untracked path %q (nested repository or empty diff)%s",
                                        rel,
                                        detail ~= "" and (": " .. detail) or ""
                                    )
                                )
                            end
                            parts[#parts + 1] = diff_out
                            if index % 32 == 0 then
                                vim.schedule(step)
                            else
                                step()
                            end
                        end)
                    end
                    step()
                end
            )
        end
    )
end

--- Write a patch snapshot of the worktree (relative to its base commit,
--- including untracked files) under the repository's common git dir, so it
--- survives the worktree being removed.
---@param info pi.WorktreeInfo
---@param cb fun(path: string?, err: string?)
function M.snapshot(info, cb)
    if type(cb) ~= "function" then
        return
    end
    local ok, err = check_info(info)
    if not ok then
        return cb(nil, err)
    end
    -- The name becomes a path component of the snapshot directory, so a
    -- hand-edited or foreign metadata name must not be able to escape it.
    local name_ok, name_err = M.validate_name(info.name)
    if not name_ok then
        return cb(nil, "snapshot: " .. tostring(name_err))
    end
    if type(info.base_sha) ~= "string" or info.base_sha == "" then
        return cb(nil, "snapshot: unknown base commit for " .. info.path)
    end

    collect_diff(info, function(diff, diff_err)
        if type(diff) ~= "string" then
            return cb(nil, diff_err or "snapshot: no diff")
        end
        local dir = snapshot_dir(info) .. "/" .. (info.name or "main")
        local mk_err = mkdirp(dir)
        if mk_err then
            return cb(nil, "snapshot: " .. mk_err)
        end
        local stamp = os.date("%Y%m%d-%H%M%S")
        local path = dir .. "/" .. stamp .. ".patch"
        local n = 1
        while path_exists(path) do
            n = n + 1
            path = dir .. "/" .. stamp .. "-" .. n .. ".patch"
        end
        local wrote, write_err = write_atomic(path, diff)
        if not wrote then
            return cb(nil, "snapshot: failed to write " .. path .. ": " .. tostring(write_err))
        end

        -- The sidecar is what makes the patch restorable after the checkout is
        -- gone (`latest_snapshot`), so a sidecar failure fails the snapshot and
        -- removes the orphan patch instead of leaving a half-written snapshot.
        run({ "git", "-C", info.path, "rev-parse", "HEAD" }, {}, function(head_code, head_out)
            local head = vim.trim(head_out or "")
            if head_code ~= 0 or head == "" then
                uv.fs_unlink(path)
                return cb(nil, "snapshot: cannot read HEAD: " .. git_err("git rev-parse HEAD", head_code, ""))
            end
            ---@type pi.WorktreeSnapshotMeta
            local meta = {
                name = info.name,
                path = info.path,
                repo_root = info.repo_root,
                base_sha = info.base_sha,
                head = head,
                created_at = os.time(),
            }
            local sidecar_ok, sidecar_err = write_sidecar(path .. SIDECAR_SUFFIX, meta)
            if not sidecar_ok then
                uv.fs_unlink(path)
                return cb(nil, "snapshot: failed to write " .. path .. SIDECAR_SUFFIX .. ": " .. tostring(sidecar_err))
            end
            cb(path, nil)
        end)
    end)
end

--- Newest `*.patch` in `dir` by mtime (ties broken by path).
---@param dir string
---@return string?
local function newest_patch(dir)
    local scan = uv.fs_scandir(dir)
    if not scan then
        return nil
    end
    local best ---@type string?
    local best_mtime = -1
    while true do
        local entry, kind = uv.fs_scandir_next(scan)
        if not entry then
            break
        end
        if kind ~= "directory" and entry:sub(-6) == ".patch" then
            local path = dir .. "/" .. entry
            local st = stat(path)
            local mtime = 0
            if st and st.mtime then
                mtime = (st.mtime.sec or 0) * 1000 + math.floor((st.mtime.nsec or 0) / 1000000)
            end
            if not best or mtime > best_mtime or (mtime == best_mtime and path > best) then
                best, best_mtime = path, mtime
            end
        end
    end
    return best
end

--- Read the `.json` sidecar of a snapshot patch (nil when missing/corrupt).
---@param patch_path string
---@return pi.WorktreeSnapshotMeta?
local function read_sidecar(patch_path)
    local text = read_text(patch_path .. SIDECAR_SUFFIX)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok or type(decoded) ~= "table" or decoded == vim.NIL then
        return nil
    end
    for key, value in pairs(decoded) do
        if value == vim.NIL then
            decoded[key] = nil
        end
    end
    return decoded --[[@as pi.WorktreeSnapshotMeta]]
end

--- Most recent snapshot of `<repo_root>`/`name` (synchronous, filesystem only).
---
--- Picks the newest `<timestamp>.patch` by mtime and reads its `.json` sidecar;
--- `meta` is nil when the sidecar is missing or unreadable (the patch itself is
--- still returned — the work is not lost).
---@param repo_root string
---@param name string
---@return pi.WorktreeSnapshot?
function M.latest_snapshot(repo_root, name)
    if type(repo_root) ~= "string" or repo_root == "" then
        return nil
    end
    if not (M.validate_name(name)) then
        return nil
    end
    local common = repo_common_dir(norm(repo_root))
    if not common then
        return nil
    end
    local patch = newest_patch(common .. "/" .. SNAPSHOT_DIR .. "/" .. name)
    if not patch then
        return nil
    end
    return { path = patch, meta = read_sidecar(patch) }
end

--- Worktrees that were pruned or deleted but still have a snapshot.
---
--- Synchronous and read-only: reads `<common>/pi2-worktree-snapshots/` (the
--- store that survives removal) and returns one `pi.WorktreeListEntry` per
--- worktree that is gone from disk but has a patch + valid sidecar, so a resume
--- picker can still offer that transcript. Invalid names, unreadable/corrupt
--- sidecars, sidecars that do not belong to their directory and checkouts that
--- still exist are skipped — this function never reports an error.
---@param cwd string? Directory inside the repository (default: the process cwd)
---@return pi.WorktreeListEntry[]
function M.snapshot_worktrees(cwd)
    local dir = resolve_dir(cwd or vim.fn.getcwd())
    if not dir then
        return {}
    end
    local detected = M.detect(dir)
    local common = detected and (detected.common_dir or detected.git_dir) or repo_common_dir(dir)
    if type(common) ~= "string" or common == "" then
        return {}
    end
    local repo_root = detected and detected.repo_root or parent(common)
    local snap_root = common .. "/" .. SNAPSHOT_DIR
    local scan = uv.fs_scandir(snap_root)
    if not scan then
        return {}
    end

    local entries = {}
    while true do
        local name, kind = uv.fs_scandir_next(scan)
        if not name then
            break
        end
        if kind == "directory" and (M.validate_name(name)) then
            local patch = newest_patch(snap_root .. "/" .. name)
            local meta = patch and read_sidecar(patch) or nil
            if
                type(meta) == "table"
                and meta.name == name
                and type(meta.path) == "string"
                and is_abs(meta.path)
                and type(meta.repo_root) == "string"
                and is_abs(meta.repo_root)
                and not is_dir(meta.path)
            then
                -- The per-worktree git dir may still be there (prunable record) or
                -- already gone (pruned): read it only for the session binding.
                local git_dir = common .. "/worktrees/" .. name
                local bound = read_meta(git_dir) or {}
                local reason = read_lock_reason(git_dir)
                ---@type pi.WorktreeListEntry
                local entry = {
                    kind = "linked",
                    name = name,
                    path = norm(meta.path),
                    repo_root = realpath(meta.repo_root) or norm(meta.repo_root),
                    git_dir = git_dir,
                    common_dir = common,
                    base_sha = type(meta.base_sha) == "string" and meta.base_sha or nil,
                    mode = type(bound.mode) == "string" and bound.mode or nil,
                    session_id = type(bound.session_id) == "string" and bound.session_id or nil,
                    session_file = type(bound.session_file) == "string" and bound.session_file or nil,
                    head = type(meta.head) == "string" and meta.head or "",
                    detached = true,
                    prunable = true,
                    missing = true,
                    snapshot = patch,
                    managed = next(bound) ~= nil,
                    locked = reason ~= nil,
                    lock_reason = reason ~= "" and reason or nil,
                    locked_reason = reason ~= "" and reason or nil,
                }
                entries[#entries + 1] = entry
            end
        end
    end
    table.sort(entries, function(a, b)
        return a.name < b.name
    end)
    return entries
end

--- Delete old snapshot patches (with their sidecars) of checkouts that are gone.
---
--- Per `<name>/` directory under `<common dir>/pi2-worktree-snapshots`: the newest
--- patch and its sidecar are kept while they are younger than `keep_days`, every
--- older patch is deleted with its sidecar, and the directory itself goes away
--- when nothing survives. A name whose checkout is still registered
--- (`opts.live_names`) keeps every patch. Pure filesystem work: names that fail
--- `validate_name` are skipped and nothing outside the snapshot directory is ever
--- touched.
---@param repo_root string
---@param opts? pi.WorktreeSnapshotGcOpts
---@param cb fun(removed: integer?, err: string?)
function M.snapshot_gc(repo_root, opts, cb)
    if type(cb) ~= "function" then
        return
    end
    if type(repo_root) ~= "string" or repo_root == "" then
        return vim.schedule(function()
            cb(nil, "snapshot_gc: repo_root required")
        end)
    end
    local gc_opts = type(opts) == "table" and opts or {}
    local keep_days = tonumber(gc_opts.keep_days) or SNAPSHOT_KEEP_DAYS
    local live = type(gc_opts.live_names) == "table" and gc_opts.live_names or {}
    local now = tonumber(gc_opts.now) or os.time()

    vim.schedule(function()
        local common = repo_common_dir(norm(repo_root))
        if not common then
            return cb(nil, "snapshot_gc: not a git repository: " .. repo_root)
        end
        local root = common .. "/" .. SNAPSHOT_DIR
        local scan = uv.fs_scandir(root)
        if not scan then
            return cb(0, nil)
        end

        local removed = 0
        while true do
            local name, kind = uv.fs_scandir_next(scan)
            if not name then
                break
            end
            if kind == "directory" and (M.validate_name(name)) and not live[name] then
                local dir = root .. "/" .. name
                local patches = {}
                local patch_scan = uv.fs_scandir(dir)
                if patch_scan then
                    while true do
                        local entry, entry_kind = uv.fs_scandir_next(patch_scan)
                        if not entry then
                            break
                        end
                        if entry_kind ~= "directory" and entry:sub(-6) == ".patch" then
                            patches[#patches + 1] = entry
                        end
                    end
                end
                -- `<YYYYmmdd-HHMMSS>.patch`, but same-second collisions add
                -- `<stamp>-2.patch` and there `'.' > '-'` makes the *older* name sort
                -- last: only mtime identifies the newest patch (a filename tie-break
                -- covers an equal mtime).
                local keep = nil
                local keep_stamp = nil
                for _, patch in ipairs(patches) do
                    local st = stat(dir .. "/" .. patch)
                    local mtime = st and st.mtime and st.mtime.sec or 0
                    if now - mtime < keep_days * 86400 then
                        local nsec = (st and st.mtime and st.mtime.nsec) or 0
                        local stamp = mtime * 1000 + math.floor(nsec / 1000000)
                        if not keep or stamp > keep_stamp or (stamp == keep_stamp and patch > keep) then
                            keep, keep_stamp = patch, stamp
                        end
                    end
                end
                for _, patch in ipairs(patches) do
                    if patch ~= keep then
                        local path = dir .. "/" .. patch
                        uv.fs_unlink(path .. SIDECAR_SUFFIX)
                        if uv.fs_unlink(path) then
                            removed = removed + 1
                        end
                    end
                end
                if not keep then
                    -- Only succeeds when the directory is empty (rmdir semantics).
                    pcall(uv.fs_rmdir, dir)
                end
            end
        end
        cb(removed, nil)
    end)
end

--- Unified patch of the worktree against `opts.from` (default: its base commit;
--- untracked files included), suitable for `diff_review.parse_sections` /
--- `git apply`.
---@param info pi.WorktreeInfo
---@param cb fun(diff: string?, err: string?)
---@param opts? { from?: string } Diff base override (e.g. the parent checkout's HEAD after a resolver rebase)
function M.diff(info, cb, opts)
    if type(cb) ~= "function" then
        return
    end
    local ok, err = check_info(info)
    if not ok then
        return cb(nil, err)
    end
    local from = type(opts) == "table"
            and type(opts.from) == "string"
            and vim.trim(opts.from) ~= ""
            and vim.trim(opts.from)
        or nil
    local base = from or (type(info.base_sha) == "string" and info.base_sha ~= "" and info.base_sha or nil)
    if not base then
        return cb(nil, "diff: unknown base commit for " .. info.path)
    end
    collect_diff(info, cb, base)
end

-- Patch integration ----------------------------------------------------------

--- Normalize a patch for `git apply`: it rejects a body whose last line has no
--- trailing newline ("corrupt patch"), while our producers always end with one.
---@param patch string
---@return string
local function normalize_patch(patch)
    if patch == "" or patch:sub(-1) == "\n" then
        return patch
    end
    return patch .. "\n"
end

---@param target_dir any
---@param patch any
---@return string? dir
---@return string? err
local function check_patch_args(target_dir, patch)
    if type(patch) ~= "string" then
        return nil, "patch must be a string"
    end
    local dir = resolve_dir(type(target_dir) == "string" and target_dir or nil)
    if not dir then
        return nil, "target is not a directory: " .. tostring(target_dir)
    end
    return dir
end

--- Classify what applying `patch` to `target_dir` would do, without writing
--- anything: `git apply --check` first ("clean"), then `--reverse --check`
--- ("already"), and only when both fail "conflict".
---@param target_dir string
---@param patch string
---@param cb fun(state: pi.WorktreeProbeState?, err: string?)
function M.probe(target_dir, patch, cb)
    if type(cb) ~= "function" then
        return
    end
    local dir, arg_err = check_patch_args(target_dir, patch)
    if not dir then
        return cb(nil, "probe: " .. tostring(arg_err))
    end
    if vim.trim(patch) == "" then
        -- Nothing to integrate: the tree already matches what the patch asks for.
        return cb("already", nil)
    end
    local body = normalize_patch(patch)

    run({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, {}, function(repo_code)
        if repo_code ~= 0 then
            return cb(nil, "probe: not a git repository: " .. dir)
        end
        run({ "git", "-C", dir, "apply", "--check", "-" }, { stdin = body }, function(check_code)
            if check_code == 0 then
                return cb("clean", nil)
            end
            -- `--reverse --check` succeeds only when the patch is already in the
            -- tree; when it fails too, the patch does not apply either way.
            run({ "git", "-C", dir, "apply", "--reverse", "--check", "-" }, { stdin = body }, function(reverse_code)
                if reverse_code == 0 then
                    return cb("already", nil)
                end
                cb("conflict", nil)
            end)
        end)
    end)
end

--- Apply `patch` to `target_dir`'s **working tree only** (`git apply`, no
--- `--index`/`--cached`, no `--3way`, no commit). `git apply` is atomic, so a
--- conflicting hunk aborts the whole patch and leaves the tree untouched.
---@param target_dir string
---@param patch string
---@param cb fun(ok: true?, err: string?)
function M.apply_patch(target_dir, patch, cb)
    if type(cb) ~= "function" then
        return
    end
    local dir, arg_err = check_patch_args(target_dir, patch)
    if not dir then
        return cb(nil, "apply_patch: " .. tostring(arg_err))
    end
    if vim.trim(patch) == "" then
        return cb(nil, "apply_patch: empty patch")
    end
    local body = normalize_patch(patch)

    run({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, {}, function(repo_code)
        if repo_code ~= 0 then
            return cb(nil, "apply_patch: not a git repository: " .. dir)
        end
        run({ "git", "-C", dir, "apply", "-" }, { stdin = body }, function(code, _, err)
            if code ~= 0 then
                return cb(nil, git_err("git apply", code, err))
            end
            cb(true, nil)
        end)
    end)
end

-- Listing --------------------------------------------------------------------

---@class pi.WorktreeListRecord
---@field path string
---@field head? string
---@field branch? string
---@field detached boolean
---@field prunable boolean
---@field bare boolean
---@field locked boolean
---@field locked_reason? string

--- Parse `git worktree list --porcelain` output into records (pure).
---@param text string?
---@return pi.WorktreeListRecord[]
function M._parse_worktree_list(text)
    local out = {}
    local current = nil
    for _, raw in ipairs(vim.split(text or "", "\n", { plain = true })) do
        local line = vim.trim((raw:gsub("\r", "")))
        if line == "" then
            current = nil
        elseif line:match("^worktree ") then
            current = {
                path = line:sub(#"worktree " + 1),
                detached = false,
                prunable = false,
                bare = false,
                locked = false,
            }
            out[#out + 1] = current
        elseif current then
            if line:match("^HEAD ") then
                current.head = line:sub(6)
            elseif line:match("^branch ") then
                current.branch = (line:sub(8):gsub("^refs/heads/", ""))
            elseif line == "detached" then
                current.detached = true
            elseif line:match("^prunable") then
                current.prunable = true
            elseif line:match("^locked") then
                current.locked = true
                local reason = vim.trim(line:sub(#"locked" + 1))
                current.locked_reason = reason ~= "" and reason or nil
            elseif line == "bare" then
                current.bare = true
            end
        end
    end
    return out
end

--- Read a registry dir's `gitdir` file, normalized for comparison with a work
--- tree path.
---
--- Git writes the absolute path of the work tree's own `.git` file there; a
--- relative path (git's `worktree.useRelativePaths`) is relative to the registry
--- dir that holds the file.
---@param git_dir string Per-worktree git dir (`<common>/worktrees/<name>`)
---@return string? target Normalized `<work tree>/.git`, nil when unreadable or empty
local function registry_gitdir_target(git_dir)
    local text = read_text(git_dir .. "/gitdir")
    if type(text) ~= "string" then
        return nil
    end
    local target = vim.trim((text:gsub("\r", "")))
    if target == "" then
        return nil
    end
    if not is_abs(target) then
        target = git_dir .. "/" .. target
    end
    return norm(target)
end

--- Resolve the per-worktree git dir (git's registry entry under
--- `<common>/worktrees/`) that belongs to the work tree at `path`.
---
--- Git names that directory after the checkout's basename **at creation time**
--- and never renames it: `git worktree move` rewrites the `gitdir` file *inside
--- the existing registry dir* instead. So the directory name is a hint at best —
--- for a checkout that was moved before it disappeared, the basename of `path`
--- names a registry dir that does not exist or belongs to a different checkout.
--- The authoritative link is the `gitdir` file, which always points at
--- `<work tree>/.git`.
---
--- A registry dir is only ever accepted on POSITIVE evidence, never because it
--- happens to exist:
---
---   * its `gitdir` file is readable and normalizes to exactly `<path>/.git` —
---     git's own link, authoritative (`git worktree list` derives the path it
---     prints from that same file),
---   * or, when that file is missing/unreadable, its `pi2-worktree.json` records
---     exactly `<path>` — our own sidecar, which only ever names the checkout it
---     was written for.
---
--- Existence alone proves nothing: the directory name is a creation-time
--- artefact, so another checkout's registry dir (with another checkout's
--- metadata) can sit under it, and claiming it would attach a foreign
--- name/base_sha/session_id to this path and point recovery at the wrong name.
---
--- Cost: one read on the happy path (the `gitdir` match); the scan is reached
--- only when the name yields nothing and never spawns a process.
---@param common string Common git dir (the directory holding `worktrees/`)
---@param path string Work tree path recorded by git (the directory may be gone)
---@return string? git_dir Absolute per-worktree git dir, nil when none matches
local function find_registry_dir(common, path)
    local registry = common .. "/worktrees"
    -- Normalize *before* splitting: a trailing slash makes `basename` return ""
    -- and would probe the registry root itself (L5). Both sides of every
    -- comparison below are normalized the same way.
    local normalized = norm(path)
    local expected = norm(normalized .. "/.git")

    ---@param candidate string
    ---@return boolean True only on evidence that this dir belongs to `normalized`
    local function matches(candidate)
        local recorded = registry_gitdir_target(candidate)
        if recorded == expected then
            return true
        end
        if recorded ~= nil then
            return false
        end
        -- No readable `gitdir`: the sidecar is the only evidence left, and only
        -- when it records exactly this path.
        local meta = read_meta(candidate)
        return type(meta) == "table" and type(meta.path) == "string" and norm(meta.path) == normalized
    end

    local by_name = registry .. "/" .. basename(normalized)
    if matches(by_name) then
        return by_name
    end
    -- Moved checkout: the registry dir kept its old name, so match on content.
    local handle = uv.fs_scandir(registry)
    if not handle then
        return nil
    end
    while true do
        local name, kind = uv.fs_scandir_next(handle)
        if name == nil then
            return nil
        end
        if kind == nil or kind == "directory" then
            local candidate = registry .. "/" .. name
            if candidate ~= by_name and matches(candidate) then
                return candidate
            end
        end
    end
end

--- A checkout resolved to its repository and worktree name without requiring the
--- checkout to still exist (`M.locate`).
---@class pi.WorktreeLocator
---@field repo_root string Nearest ancestor repository of `path` (walked up to the nearest `.git`
--- marker), which is the checkout's owning repository only while the checkout sits inside it:
--- a `git worktree move` into another repository reports that repository here.
---@field name string Worktree name (metadata name when recorded, else the registry dir name).
---@field path string The normalized input path.
---@field git_dir? string Registry dir under `<common>/worktrees/`, when one matched.
---@field missing boolean True when the checkout directory is gone.

--- Resolve a checkout path to its repository and worktree name, WITHOUT
--- requiring the directory to still exist.
---
--- `M.detect` cannot answer this for a deleted checkout (it reads the
--- checkout's own `.git` file), so a resume that outlived its directory has
--- no other way back to the snapshot. Deliberately metadata-first: the
--- registry entry git keeps for the checkout is authoritative, so a checkout
--- `git worktree move` relocated **inside the repository** still resolves.
---
--- That qualification is the caller's to respect: the repository is found by
--- walking up from the path's parent to the nearest `.git` marker, so a checkout
--- moved to a directory outside any repository resolves to nil even with its
--- registry entry intact, and one moved into a *different* repository reports
--- that (nearest) repository as `repo_root` — the owner only when the checkout
--- did not leave it. The layout join (`<worktrees_root>/<name>`) is only a LAST
--- resort, used after `git worktree prune` has removed the registry entry
--- entirely.
---@param path string Checkout path, possibly no longer existing.
---@return pi.WorktreeLocator? locator
function M.locate(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local target = norm(path)
    local missing = not is_dir(target)

    -- The repository, found from OUTSIDE the checkout (which may be gone): walk
    -- up to the nearest `.git` marker — the checkout's owner while it sits inside
    -- one. A checkout outside any repository resolves to nothing: an out-of-repo
    -- layout is not implemented, and its registry entry (which would still name
    -- the owner) is not reachable from here.
    local _, _, candidate = find_git_marker(parent(target))
    if not candidate then
        return nil
    end
    local repo_root = realpath(candidate) or candidate

    ---@param git_dir string Registry dir the `gitdir` file proved belongs to `target`
    ---@return pi.WorktreeLocator?
    local function from_registry(git_dir)
        local meta = read_meta(git_dir) or {}
        local name = type(meta.name) == "string" and meta.name ~= "" and meta.name or basename(git_dir)
        if not (M.validate_name(name)) then
            return nil
        end
        return { repo_root = repo_root, name = name, path = target, git_dir = git_dir, missing = missing }
    end

    local common = repo_common_dir(candidate)
    if common then
        local git_dir = find_registry_dir(common, target)
        if git_dir then
            local locator = from_registry(git_dir)
            if locator then
                return locator
            end
        end
    end

    -- Last resort (after `git worktree prune` deleted the registry entry): the
    -- layout says a checkout called `name` lives at `<worktrees_root>/<name>`.
    -- Exactly ONE valid name component — never a general path pattern.
    local root_prefix = M.worktrees_root(repo_root) .. "/"
    if target:sub(1, #root_prefix) == root_prefix then
        local leaf = target:sub(#root_prefix + 1)
        if leaf ~= "" and not leaf:find("/", 1, true) and (M.validate_name(leaf)) then
            return { repo_root = repo_root, name = leaf, path = target, missing = missing }
        end
    end
    return nil
end

--- Entry for a registered worktree whose directory is gone (git reports it
--- prunable). Built from the porcelain record plus whatever metadata the
--- per-worktree git dir still holds, so `History.list(path)` can still find the
--- transcript by its (now missing) directory.
---@param main_root string
---@param record pi.WorktreeListRecord
---@return pi.WorktreeListEntry?
local function missing_list_entry(main_root, record)
    local path = record.path
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local common = repo_common_dir(main_root)
    local git_dir = find_registry_dir(common or (main_root .. "/.git"), path)
    if not git_dir then
        return nil
    end
    local meta = read_meta(git_dir) or {}
    local name = type(meta.name) == "string" and meta.name ~= "" and meta.name or basename(git_dir)
    if not (M.validate_name(name)) then
        return nil
    end
    ---@type pi.WorktreeListEntry
    return {
        kind = "linked",
        name = name,
        path = norm(path),
        repo_root = main_root,
        git_dir = git_dir,
        common_dir = common,
        base_sha = type(meta.base_sha) == "string" and meta.base_sha ~= "" and meta.base_sha or nil,
        mode = type(meta.mode) == "string" and meta.mode or nil,
        session_id = type(meta.session_id) == "string" and meta.session_id or nil,
        session_file = type(meta.session_file) == "string" and meta.session_file or nil,
        head = record.head or "",
        branch = record.branch,
        detached = record.detached,
        prunable = true,
        missing = true,
        managed = next(meta) ~= nil,
        locked = record.locked == true,
        locked_reason = type(record.locked_reason) == "string" and record.locked_reason or nil,
        lock_reason = type(record.locked_reason) == "string" and record.locked_reason or nil,
    }
end

--- Linked worktrees of the repository containing `cwd` (async), sorted by path.
---
--- Each entry is the `detect()` info (metadata included) plus the porcelain
--- `head`/`branch`/`detached`/`prunable` fields — what a cross-worktree resume
--- picker needs. A registered checkout whose directory is gone (git reports it
--- prunable) is reported as `missing` **only when our metadata says it is ours**;
--- a foreign prunable registration is dropped (A5), wherever it points.
---@param cwd string? Directory inside the repository (default: the process cwd)
---@param cb fun(entries: pi.WorktreeListEntry[]?, err: string?)
function M.list(cwd, cb)
    if type(cb) ~= "function" then
        return
    end
    local dir = resolve_dir(cwd or vim.fn.getcwd())
    if not dir then
        return cb(nil, "list: not a directory: " .. tostring(cwd))
    end

    run({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, {}, function(code, stdout)
        local repo_root = vim.trim(stdout or "")
        if code ~= 0 or repo_root == "" then
            return cb(nil, "list: not a git repository: " .. dir)
        end
        repo_root = realpath(repo_root) or repo_root

        run({ "git", "-C", repo_root, "worktree", "list", "--porcelain" }, {}, function(list_code, list_out, list_err)
            if list_code ~= 0 then
                return cb(nil, git_err("git worktree list", list_code, list_err))
            end
            local entries = {}
            local records = M._parse_worktree_list(list_out)
            -- `git worktree list` prints the main worktree first, so this is the
            -- real repository root even when `cwd` is inside a linked worktree
            -- (where `--show-toplevel` reports the worktree, not the main one).
            local main_root = repo_root
            if records[1] and records[1].path ~= "" then
                main_root = realpath(records[1].path) or norm(records[1].path)
            end
            for _, record in ipairs(records) do
                local path = record.path
                local normalized = path ~= "" and (realpath(path) or norm(path)) or ""
                if normalized ~= "" and normalized ~= main_root and not record.bare then
                    if is_dir(path) then
                        local info = M.detect(path)
                        if info and info.kind == "linked" then
                            ---@type pi.WorktreeListEntry
                            local entry = {
                                kind = info.kind,
                                name = info.name,
                                path = info.path,
                                repo_root = info.repo_root or main_root,
                                git_dir = info.git_dir,
                                common_dir = info.common_dir,
                                base_sha = info.base_sha,
                                mode = info.mode,
                                session_id = info.session_id,
                                session_file = info.session_file,
                                head = record.head or "",
                                branch = record.branch,
                                detached = record.detached,
                                prunable = record.prunable,
                                missing = false,
                                managed = info.managed == true,
                                locked = info.locked == true or record.locked == true,
                                lock_reason = info.lock_reason or record.locked_reason,
                                locked_reason = record.locked_reason or info.lock_reason,
                            }
                            entries[#entries + 1] = entry
                        end
                    else
                        -- Registered but the directory is gone (git reports it
                        -- prunable). Resume still needs the entry to locate the
                        -- transcript by its path, so report it as missing instead
                        -- of dropping it — but only when our metadata proves the
                        -- checkout is ours (A5: never touch checkouts other tools
                        -- created). Where the checkout lived is not evidence:
                        -- `git worktree move` can put a managed checkout
                        -- anywhere, at any time.
                        local entry = missing_list_entry(main_root, record)
                        if entry and entry.managed then
                            entries[#entries + 1] = entry
                        end
                    end
                end
            end
            table.sort(entries, function(a, b)
                return a.path < b.path
            end)
            cb(entries, nil)
        end)
    end)
end

-- Removal --------------------------------------------------------------------

---@param info pi.WorktreeInfo
---@param opts { force?: boolean }
---@param cb fun(removed: boolean, err: string?)
local function worktree_remove(info, opts, cb)
    ---@param force boolean
    local function remove(force)
        local argv = { "git", "-C", info.repo_root, "worktree", "remove" }
        if force then
            argv[#argv + 1] = "--force"
        end
        argv[#argv + 1] = info.path

        run(argv, {}, function(code, stdout, stderr)
            if code ~= 0 then
                return cb(false, git_err("git worktree remove", code, stderr ~= "" and stderr or stdout))
            end
            run({ "git", "-C", info.repo_root, "worktree", "prune" }, {}, function(prune_code, prune_out, prune_err)
                invalidate()
                if prune_code ~= 0 then
                    return cb(
                        true,
                        git_err("git worktree prune", prune_code, prune_err ~= "" and prune_err or prune_out)
                    )
                end
                cb(true, nil)
            end)
        end)
    end

    local force = opts ~= nil and opts.force == true
    local state = M.lock_state(info)
    if not state.locked then
        return remove(force)
    end
    if not state.ours then
        -- The lock exists exactly to keep external cleanups out (and `--force`
        -- cannot override it), so report it and touch nothing.
        return cb(
            false,
            string.format(
                "worktree %s is locked (%s); run `git worktree unlock %s` first",
                info.path,
                tostring(state.reason),
                info.path
            )
        )
    end
    -- Our own lock, but only if this process may release it: another live owner,
    -- another host or a lock without a pid still guards the checkout.
    local releasable, why = lock_releasable(state.reason or "")
    if not releasable then
        return cb(
            false,
            string.format(
                "worktree %s is locked (%s); %s — run `git worktree unlock %s` first",
                info.path,
                tostring(state.reason),
                tostring(why),
                info.path
            )
        )
    end
    -- Releasable: unlock first, so the checkout goes away without leaving a lock
    -- record (and without git refusing the removal).
    M.unlock(info, function(unlocked, unlock_err)
        if not unlocked then
            return cb(false, unlock_err)
        end
        remove(force)
    end)
end

--- Remove the worktree only when nothing would be lost: a dirty worktree or one
--- with commits not reachable from `base_sha` is kept and reported.
---
--- A *clean* checkout is snapshotted first (an empty patch plus its `.json`
--- sidecar) so the session transcript — keyed by the checkout path — stays
--- discoverable through `snapshot_worktrees` and the same path can be recreated
--- later. A failing snapshot keeps the checkout instead of silently losing that
--- link (`cb(false, err)`); the removal itself goes through the internal
--- `worktree_remove`, never `M.remove`, so nothing snapshots twice or recurses.
---
--- A foreign `git worktree lock` keeps the checkout as well (`cb(false, err)`);
--- our own lock is released right before the removal.
---@param info pi.WorktreeInfo
---@param cb fun(removed: boolean, err: string?)
function M.release(info, cb)
    if type(cb) ~= "function" then
        return
    end
    local ok, err = check_info(info)
    if not ok then
        return cb(false, err)
    end

    M.status(info, function(status, status_err)
        if not status then
            return cb(false, status_err)
        end
        if status.dirty then
            return cb(false, "release: " .. info.path .. " has uncommitted changes")
        end
        if (status.ahead or 0) > 0 then
            return cb(
                false,
                string.format(
                    "release: %s has %d commit(s) not in %s",
                    info.path,
                    status.ahead,
                    info.base_sha or "the base commit"
                )
            )
        end
        M.snapshot(info, function(snapshot_path, snapshot_err)
            if type(snapshot_path) ~= "string" or snapshot_path == "" then
                return cb(
                    false,
                    "release: snapshot failed, worktree kept: " .. tostring(snapshot_err or "unknown error")
                )
            end
            -- `worktree_remove` (not `M.remove`): no second snapshot, no recursion.
            worktree_remove(info, {}, cb)
        end)
    end)
end

--- Remove a worktree. Snapshots first by default (`worktree.snapshot_before_remove`,
--- overridable per call) so a forced removal stays recoverable.
---
--- Our own `git worktree lock` is released first; a foreign lock refuses the
--- removal (`--force` cannot override it either) and keeps the checkout.
---@param info pi.WorktreeInfo
---@param opts? { force?: boolean, snapshot?: boolean }
---@param cb fun(removed: boolean, err: string?, snapshot_path: string?)
function M.remove(info, opts, cb)
    if type(cb) ~= "function" then
        return
    end
    opts = opts or {}
    local ok, err = check_info(info)
    if not ok then
        return cb(false, err)
    end

    local want_snapshot = opts.snapshot
    if want_snapshot == nil then
        local cfg = Config.options.worktree or {}
        want_snapshot = cfg.snapshot_before_remove ~= false
    end

    local function proceed(snapshot_path)
        worktree_remove(info, { force = opts.force == true }, function(removed, remove_err)
            cb(removed, remove_err, snapshot_path)
        end)
    end

    if not want_snapshot then
        return proceed(nil)
    end
    M.snapshot(info, function(path, snap_err)
        if not path then
            return cb(false, snap_err)
        end
        proceed(path)
    end)
end

-- Branch ---------------------------------------------------------------------

--- Attach the worktree to `branch`, creating it when it does not exist yet.
---@param info pi.WorktreeInfo
---@param branch string
---@param cb fun(ok: boolean?, err: string?)
function M.branch(info, branch, cb)
    if type(cb) ~= "function" then
        return
    end
    local ok, err = check_info(info)
    if not ok then
        return cb(nil, err)
    end
    if type(branch) ~= "string" or branch == "" then
        return cb(nil, "branch: name required")
    end

    run({ "git", "-C", info.path, "check-ref-format", "--branch", branch }, {}, function(format_code)
        if format_code ~= 0 then
            return cb(nil, "branch: invalid name: " .. branch)
        end
        run({ "git", "-C", info.path, "checkout", "-b", branch }, {}, function(code, _, stderr)
            if code == 0 then
                invalidate()
                return cb(true, nil)
            end
            -- The branch already exists somewhere in the repository: attach to it
            -- instead of failing, which is what "switch to this branch" means.
            if (stderr or ""):find("already exists", 1, true) then
                run({ "git", "-C", info.path, "checkout", branch }, {}, function(co_code, _, co_err)
                    if co_code ~= 0 then
                        return cb(nil, git_err("git checkout " .. branch, co_code, co_err))
                    end
                    invalidate()
                    return cb(true, nil)
                end)
                return
            end
            cb(nil, git_err("git checkout -b " .. branch, code, stderr))
        end)
    end)
end

-- Binding --------------------------------------------------------------------

--- Bind a pi session to a worktree by updating its metadata. Synchronous (two
--- tiny file operations) so callers can call it from session creation paths.
---@param info pi.WorktreeInfo
---@param fields pi.WorktreeBindFields
---@return boolean ok
---@return string? err
function M.bind(info, fields)
    local ok, err = check_info(info)
    if not ok then
        return false, err
    end
    if type(fields) ~= "table" then
        return false, "bind: fields table required"
    end

    local meta, meta_err = read_meta(info.git_dir)
    if meta_err then
        -- Never rewrite metadata this build does not understand: the unknown
        -- fields would be lost, including the session binding a newer version
        -- may have stored differently.
        return false, "bind: refusing to overwrite " .. meta_path(info.git_dir) .. ": " .. meta_err
    end
    meta = meta or info_meta(info)
    meta.version = META_VERSION
    meta.name = info.name
    meta.path = info.path
    meta.repo_root = info.repo_root
    meta.base_sha = info.base_sha
    meta.mode = info.mode
    if fields.session_id ~= nil then
        meta.session_id = fields.session_id
        info.session_id = fields.session_id
    end
    if fields.session_file ~= nil then
        meta.session_file = fields.session_file
        info.session_file = fields.session_file
    end

    local wrote, write_err = write_meta(info.git_dir, meta)
    if not wrote then
        return false, write_err
    end
    invalidate()
    return true, nil
end

--- Test helper: absolute path of a worktree's metadata file.
---@param info pi.WorktreeInfo
---@return string
function M._meta_path(info)
    return meta_path(info.git_dir)
end

--- Test helper: parse the body of a linked worktree's `.git` pointer file.
---@param text string?
---@return string?
function M._parse_gitdir_file(text)
    return parse_gitdir_file(text)
end

--- Test helper: the name `create` generates when `opts.name` is omitted.
---@return string
function M._default_name()
    return default_name()
end

return M
