--- Git worktree isolation.
---
--- A *worktree* here is a linked git worktree created under `<repo>/.worktrees/<name>`
--- on a **detached HEAD**, so several agent sessions can touch the same repository
--- without racing on one working tree or on a branch. The module owns:
---
--- - creation (`.worktrees/<name>`, auto-appended `.gitignore` line, detached
---   checkout, metadata, `.worktreeinclude` copy, optional `setup_cmd` hook),
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

---@class pi.WorktreeCreateOpts
---@field cwd string Directory that selects the repository (usually the session cwd)
---@field name? string Worktree name (directory under `<repo>/.worktrees/`); generated when omitted
---@field mode? string Free-form mode recorded in the metadata (default `"isolated"`)
---@field base? string Commit the checkout is detached at (default: the repository's current `HEAD`); any revision `git rev-parse` accepts

---@class pi.WorktreeStatus
---@field dirty boolean Uncommitted changes (tracked, staged, or untracked)
---@field ahead integer Commits on the worktree's HEAD that are not in `base_sha`
---@field head string Current HEAD commit sha

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

--- A linked worktree as reported by `git worktree list --porcelain`, enriched
--- with the `detect()` metadata. Used by cross-worktree resume.
---@class pi.WorktreeListEntry: pi.WorktreeInfo
---@field head string HEAD commit reported by git (`""` when unparsed)
---@field branch? string Branch name (`refs/heads/` stripped) when not detached
---@field detached boolean True when git reports the worktree as detached
---@field prunable boolean git reports a prunable gitdir (directory gone)
---@field missing? boolean True when the registered directory is gone (prunable/missing); `path` no longer exists, the session binding may
---@field snapshot? string Snapshot patch backing a `missing` entry (only set by `snapshot_worktrees`)

local META_FILE = "pi2-worktree.json"
--- Bumped when the metadata layout changes; readers reject newer versions.
local META_VERSION = 1
local WORKTREES_DIR = ".worktrees"
local GITIGNORE_LINE = "/.worktrees/"
local GITIGNORE_EQUIVALENTS = {
    [GITIGNORE_LINE] = true,
    ["/.worktrees"] = true,
    [".worktrees/"] = true,
    [".worktrees"] = true,
}
local INCLUDE_FILE = ".worktreeinclude"
local SNAPSHOT_DIR = "pi2-worktree-snapshots"
--- Suffix of the snapshot metadata sidecar (`<patch>.json`).
local SIDECAR_SUFFIX = ".json"
--- Hard stop for pathological `.worktreeinclude` matches (e.g. a whole
--- `node_modules/` tree). Refusing loudly beats hanging the editor.
local MAX_INCLUDE_FILES = 20000
local MAX_NAME_LENGTH = 64
local MAX_WALK_DEPTH = 64
local COPY_BUDGET = 64

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
--- Only that situation may be retried with `--force`; "already exists" (a real
--- directory is in the way) must never be forced.
---@param text string?
---@return boolean
local function is_stale_registration(text)
    if type(text) ~= "string" then
        return false
    end
    local lower = text:lower()
    return lower:find("already registered", 1, true) ~= nil and lower:find("already exists", 1, true) == nil
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
---@param opts { cwd?: string, stdin?: string }
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
    if opts and opts.stdin then
        sys.stdin = opts.stdin
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

---@type table<string, { marker: string?, marker_stamp: string, meta_path: string?, meta_stamp: string, info: pi.WorktreeInfo }>
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
    }
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
--- Pure filesystem work (reads `.git`, the metadata file, and `commondir`), no
--- git subprocess, so it is safe to call on rendering paths. Results are cached
--- per directory and revalidated with cheap `stat` stamps.
---@param cwd string? Directory to inspect (default: the process cwd)
---@return pi.WorktreeInfo?
function M.detect(cwd)
    local dir = resolve_dir(cwd or vim.fn.getcwd())
    if not dir then
        return nil
    end

    local cached = detect_cache[dir]
    if cached then
        if file_stamp(cached.marker) == cached.marker_stamp and file_stamp(cached.meta_path) == cached.meta_stamp then
            return cached.info
        end
        detect_cache[dir] = nil
    end

    local info, marker = build_info(dir)
    if not info then
        return nil
    end
    local entry_meta = meta_path(info.git_dir)
    detect_cache[dir] = {
        marker = marker,
        marker_stamp = file_stamp(marker),
        meta_path = entry_meta,
        meta_stamp = file_stamp(entry_meta),
        info = info,
    }
    return info
end

-- Name validation ------------------------------------------------------------

--- Validate a worktree name. Names become a single directory component under
--- `<repo>/.worktrees/`, so anything that could escape or hide is rejected.
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
--- instances from picking the same directory.
---@return string
local function default_name()
    default_name_seq = default_name_seq + 1
    return string.format("wt-%s-%d-%d", os.date("%Y%m%d-%H%M%S"), vim.uv.os_getpid(), default_name_seq)
end

-- .gitignore ----------------------------------------------------------------

--- Append `line` to a `.gitignore` body unless an equivalent entry exists.
--- Pure: returns the new content, or nil when nothing needs to change.
---@param content string?
---@param line string
---@return string?
function M._append_gitignore_line(content, line)
    content = content or ""
    for _, raw in ipairs(vim.split(content, "\n", { plain = true })) do
        local trimmed = vim.trim((raw:gsub("\r", "")))
        if GITIGNORE_EQUIVALENTS[trimmed] then
            return nil
        end
    end
    local out = content
    if out ~= "" and out:sub(-1) ~= "\n" then
        out = out .. "\n"
    end
    return out .. line .. "\n"
end

--- Make sure `<repo>/.worktrees/` is git-ignored. Appends one line to the
--- repository's `.gitignore` when needed; never stages or commits anything.
---@param repo_root string
---@param cb fun(err: string?)
local function ensure_gitignore(repo_root, cb)
    run({ "git", "-C", repo_root, "check-ignore", "-q", "--no-index", WORKTREES_DIR .. "/" }, {}, function(code)
        if code == 0 then
            return cb(nil)
        end
        if code ~= 1 then
            return cb("create: cannot inspect .gitignore (git check-ignore exit " .. code .. ")")
        end
        local path = repo_root .. "/.gitignore"
        local updated = M._append_gitignore_line(read_text(path), GITIGNORE_LINE)
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
---@param info pi.WorktreeInfo
---@param cb fun(err: string?)
local function copy_includes(info, cb)
    local text = read_text(info.repo_root .. "/" .. INCLUDE_FILE)
    if type(text) ~= "string" then
        return cb(nil)
    end
    local pathspecs = M._include_pathspecs(M._parse_include(text))
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

--- Run the configured `worktree.setup_cmd` inside the new worktree.
---@param info pi.WorktreeInfo
---@param cb fun(err: string?)
local function run_setup(info, cb)
    local cfg = Config.options.worktree or {}
    local cmd = cfg.setup_cmd
    if cmd == nil then
        return cb(nil)
    end
    if type(cmd) == "string" then
        cmd = { cmd }
    end
    if type(cmd) ~= "table" then
        return cb("setup_cmd: expected a string[]")
    end
    local argv = {}
    for _, part in ipairs(cmd) do
        if type(part) ~= "string" then
            return cb("setup_cmd: every element must be a string")
        end
        argv[#argv + 1] = part
    end
    if #argv == 0 then
        return cb(nil)
    end

    run(argv, { cwd = info.path }, function(code, stdout, stderr)
        if code == 0 then
            return cb(nil)
        end
        local detail = tail(stderr ~= "" and stderr or stdout, 10)
        if detail == "" then
            return cb("setup_cmd failed (exit " .. code .. ")")
        end
        return cb("setup_cmd failed (exit " .. code .. "): " .. detail)
    end)
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

--- Create a linked worktree under `<repo>/.worktrees/<name>` on a detached HEAD.
---
--- Steps (in order, each one leaving the repository consistent):
---   1. reject non-directories, non-git directories, repositories without a
---      commit yet, and creation from *inside* a linked worktree,
---   2. ensure `/.worktrees/` is in the repository `.gitignore`,
---   3. `git worktree add --detach <target> <base>` (`opts.base`, default `HEAD`),
---   4. write the metadata into the new per-worktree git dir,
---   5. copy `.worktreeinclude` ∩ gitignored files,
---   6. run `worktree.setup_cmd` (async, cwd = worktree).
---
--- Any failure after step 3 keeps the worktree on disk (so nothing is lost) and
--- reports the error; the worktree is already registered with git at that point.
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

    local name = opts.name
    if name == nil then
        name = default_name()
    end
    local name_ok, name_err = M.validate_name(name)
    if not name_ok then
        return cb(nil, name_err)
    end
    local mode = type(opts.mode) == "string" and opts.mode ~= "" and opts.mode or "isolated"

    run({ "git", "-C", cwd, "rev-parse", "--show-toplevel" }, {}, function(code, stdout)
        local repo_root = vim.trim(stdout or "")
        if code ~= 0 or repo_root == "" then
            return cb(nil, "create: not a git repository: " .. cwd)
        end
        repo_root = realpath(repo_root) or repo_root

        local worktrees_root = repo_root .. "/" .. WORKTREES_DIR
        if is_under(cwd, worktrees_root) then
            return cb(nil, "create: refusing to create a worktree inside " .. worktrees_root)
        end

        local target = worktrees_root .. "/" .. name
        if path_exists(target) then
            return cb(nil, "create: worktree already exists: " .. target)
        end

        local requested = type(opts.base) == "string" and vim.trim(opts.base) or ""
        local rev = requested ~= "" and (requested .. "^{commit}") or "HEAD"
        run({ "git", "-C", repo_root, "rev-parse", "--verify", "-q", rev }, {}, function(base_code, base_out)
            local base_sha = vim.trim(base_out or "")
            if base_code ~= 0 or base_sha == "" then
                if requested ~= "" then
                    return cb(nil, "create: invalid base commit: " .. requested)
                end
                return cb(nil, "create: repository has no commits yet: " .. repo_root)
            end

            ensure_gitignore(repo_root, function(ignore_err)
                if ignore_err then
                    return cb(nil, ignore_err)
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

                    copy_includes(info, function(include_err)
                        if include_err then
                            return cb(nil, include_err)
                        end
                        run_setup(info, function(setup_err)
                            if setup_err then
                                return cb(nil, setup_err)
                            end
                            cb(info, nil)
                        end)
                    end)
                end

                ---@param code integer
                ---@param stdout string
                ---@param stderr string
                ---@param op string
                local function on_add_error(code, stdout, stderr, op)
                    cb(nil, "create: " .. git_err(op, code, stderr ~= "" and stderr or stdout))
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
                    run(add_argv(true), {}, function(retry_code, retry_out, retry_err)
                        if retry_code ~= 0 then
                            return on_add_error(retry_code, retry_out, retry_err, "git worktree add --force")
                        end
                        on_added()
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

--- Common git dir of a repository, resolved without spawning git.
---@param repo_root string
---@return string? common_dir
local function repo_common_dir(repo_root)
    local marker = repo_root .. "/.git"
    local st = stat(marker)
    if not st then
        return nil
    end
    if st.type == "directory" then
        return realpath(marker) or marker
    end
    local gitdir = parse_gitdir_file(read_text(marker))
    if not gitdir then
        return nil
    end
    if not is_abs(gitdir) then
        gitdir = repo_root .. "/" .. gitdir
    end
    local git_dir = realpath(gitdir) or norm(gitdir)
    return resolve_common_dir(git_dir) or git_dir
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
            elseif line == "bare" then
                current.bare = true
            end
        end
    end
    return out
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
    local name = basename(path)
    if not (M.validate_name(name)) then
        return nil
    end
    local common = repo_common_dir(main_root)
    local git_dir = (common and (common .. "/worktrees/" .. name)) or (main_root .. "/.git/worktrees/" .. name)
    local meta = read_meta(git_dir) or {}
    ---@type pi.WorktreeListEntry
    return {
        kind = "linked",
        name = type(meta.name) == "string" and meta.name ~= "" and meta.name or name,
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
    }
end

--- Linked worktrees of the repository containing `cwd` (async), sorted by path.
---
--- Each entry is the `detect()` info (metadata included) plus the porcelain
--- `head`/`branch`/`detached`/`prunable` fields — what a cross-worktree resume
--- picker needs. Worktrees whose directory is gone are skipped (nothing to
--- resume there).
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
            local managed_root = norm(main_root .. "/" .. WORKTREES_DIR)
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
                            }
                            entries[#entries + 1] = entry
                        end
                    elseif is_under(normalized, managed_root) then
                        -- Registered but the directory is gone (git reports it
                        -- prunable). Resume still needs the entry to locate the
                        -- transcript by its path, so report it as missing instead of
                        -- dropping it.
                        local entry = missing_list_entry(main_root, record)
                        if entry then
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
    local argv = { "git", "-C", info.repo_root, "worktree", "remove" }
    if opts and opts.force then
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
                return cb(true, git_err("git worktree prune", prune_code, prune_err ~= "" and prune_err or prune_out))
            end
            cb(true, nil)
        end)
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
