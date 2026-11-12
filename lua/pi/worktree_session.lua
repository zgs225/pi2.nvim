--- Worktree session orchestration: `:PiWorktreeNew` / `:PiWorktreeFork` /
--- `:PiWorktreeBranch` / `:PiWorktreeApply` / `:PiWorktreeShip` /
--- `:PiWorktreeRemove`.
---
--- The git side lives in `pi.worktree` (create/bind/release/branch/diff/snapshot/
--- remove...); this module only sequences it with the session manager and the
--- UI: create the worktree and open a fresh tabpage in it, review a patch
--- before applying it to the main checkout, prefill a shipping prompt, and
--- guard/confirm removal.
---
--- Why a new process instead of RPC `new_session` / `fork`: those commands
--- rebind the *current* process (which keeps its cwd), so they can neither
--- move a conversation into a worktree nor leave the parent conversation
--- untouched.

local M = {}

local Notify = require("pi.notify")
local Sessions = require("pi.sessions.manager")
local Config = require("pi.config")
local Dialog = require("pi.ui.dialog")
local DiffReview = require("pi.ui.diff_review")

---@class pi.WorktreeOpts
---@field name? string Worktree name (default: generated).
---@field layout? pi.LayoutMode Chat layout for the new tab.

--- Target of the worktree operations that act on an existing checkout
--- (`:PiWorktreeApply/Ship/Remove`).
---@class pi.WorktreeTargetOpts
---@field name? string Worktree name under `<repo>/.worktrees/` (default: the current session's worktree).

--- Startup flags in `cli.args` that select/own a session. Combining them with
--- the `--fork` we append makes pi exit before RPC starts, so the fork command
--- refuses with an actionable message instead of spawning a doomed process.
---@type table<string, true>
local SESSION_FLAGS = {
    ["--continue"] = true,
    ["-c"] = true,
    ["--resume"] = true,
    ["-r"] = true,
    ["--session"] = true,
    ["--no-session"] = true,
}

--- Lazy accessor for the worktree module. Lazy + pcall'd so this module can
--- load (and specs can run) while `pi.worktree` is still being implemented,
--- and so a missing/broken module degrades to a clear user error.
---@return table?
local function worktree_module()
    local ok, mod = pcall(require, "pi.worktree")
    if not ok or type(mod) ~= "table" then
        return nil
    end
    return mod
end

--- First session-selecting flag present in `cli.args`, if any.
---@param args string[]
---@return string?
local function conflicting_session_flag(args)
    for _, arg in ipairs(args or {}) do
        if type(arg) == "string" then
            local name = arg:match("^(%-%-[%w%-]+)=") or arg
            if SESSION_FLAGS[name] then
                return name
            end
        end
    end
    return nil
end

--- Release a worktree that was created but could not get a session attached
--- (process start failed), so a failed `:PiWorktree*` does not leak an empty
--- checkout. Contract: `Worktree.release(info, cb)`.
---@param Worktree table
---@param info table
local function release_orphan(Worktree, info)
    if type(Worktree.release) ~= "function" then
        return
    end
    local ok, err = pcall(Worktree.release, info, function() end)
    if not ok then
        Notify.warn("worktree cleanup failed: " .. tostring(err))
    end
end

--- Validate the info returned by `Worktree.create` before it is used as a
--- process cwd. Malformed info must not leak into the session manager.
---@param info any
---@return boolean
local function valid_info(info)
    return type(info) == "table" and type(info.path) == "string" and info.path ~= ""
end

--- Two paths point at the same directory. Normalizes symlinks and trailing
--- separators so a worktree reached via a symlinked/`~/` path still matches its
--- canonical form (a live session must never be missed because of that).
---@param a string?
---@param b string?
---@return boolean
local function same_path(a, b)
    if type(a) ~= "string" or a == "" or type(b) ~= "string" or b == "" then
        return false
    end
    if a == b then
        return true
    end
    return vim.fn.resolve(a) == vim.fn.resolve(b)
end

--- Two worktree info tables describe the same checkout (identity or path).
---@param a any
---@param b any
---@return boolean
local function same_worktree(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    if a == b then
        return true
    end
    return same_path(a.path, b.path)
end

--- Resolve the worktree a command targets.
---
--- Without a name this is the current session's worktree (falling back to the
--- linked worktree its cwd lives in, for resumed sessions). A name is
--- validated and then joined under `<repo>/.worktrees/<name>`, so it can never
--- escape the checkout directory; the resolved directory must be a linked git
--- worktree (`Worktree.detect`).
---@param name string?
---@return table? info
---@return string? err
local function resolve_target(name)
    local Worktree = worktree_module()
    if not Worktree then
        return nil, "Worktree support is unavailable (pi.worktree module missing)"
    end
    if name ~= nil and type(name) ~= "string" then
        return nil, "Worktree name must be a string"
    end

    local session = Sessions.get()
    local current = session and type(session.worktree) == "table" and session.worktree or nil
    local wanted = type(name) == "string" and vim.trim(name) or ""

    if wanted == "" then
        if current then
            return current
        end
        local cwd = (session and session.cwd) or vim.fn.getcwd()
        local detected = type(Worktree.detect) == "function" and Worktree.detect(cwd) or nil
        if type(detected) == "table" and detected.kind == "linked" then
            return detected
        end
        return nil, "No worktree target: this session is not running in a worktree"
    end

    if type(Worktree.validate_name) == "function" then
        local ok, err = Worktree.validate_name(wanted)
        if not ok then
            return nil, err or ("Invalid worktree name: " .. wanted)
        end
    elseif not wanted:match("^[%w][%w._-]*$") then
        return nil, "Invalid worktree name: " .. wanted
    end

    if current and current.name == wanted then
        return current
    end

    local repo_root = type(current) == "table" and current.repo_root or nil
    local cwd = (session and session.cwd) or vim.fn.getcwd()
    if type(repo_root) ~= "string" or repo_root == "" then
        local detected = type(Worktree.detect) == "function" and Worktree.detect(cwd) or nil
        repo_root = type(detected) == "table" and detected.repo_root or nil
    end
    if type(repo_root) ~= "string" or repo_root == "" then
        return nil, "Not inside a git repository: cannot resolve worktree '" .. wanted .. "'"
    end

    local path = repo_root .. "/.worktrees/" .. wanted
    if vim.fn.isdirectory(path) == 0 then
        return nil, string.format("Worktree '%s' not found under %s/.worktrees", wanted, repo_root)
    end
    local info = type(Worktree.detect) == "function" and Worktree.detect(path) or nil
    if type(info) ~= "table" or info.kind ~= "linked" then
        return nil, "Not a git worktree: " .. path
    end
    return info
end

--- First running session whose process cwd is `dir` (normalized compare).
--- Covers sessions that *inherited* a worktree cwd: their `worktree` field is
--- nil (they don't own the checkout), so only `cwd`/`_process_cwd` identify
--- them.
---@param dir string?
---@return pi.Session?
local function running_session_at(dir)
    if type(dir) ~= "string" or dir == "" then
        return nil
    end
    for _, session in ipairs(Sessions.list_all()) do
        if
            session.rpc
            and session.rpc:is_running()
            and (same_path(session.cwd, dir) or same_path(session._process_cwd, dir))
        then
            return session
        end
    end
    return nil
end

--- Any live session process whose cwd is this worktree (a process must never
--- lose the directory underneath it).
---
--- Three ways to own the checkout: the same worktree metadata, a process cwd
--- (also covers children that inherited the worktree, which carry no worktree
--- metadata), or the recorded binding `session_id`.
---@param info table
---@return pi.Session?
local function live_session_for(info)
    for _, session in ipairs(Sessions.list_all()) do
        if same_worktree(session.worktree, info) and session.rpc and session.rpc:is_running() then
            return session
        end
    end
    local by_path = running_session_at(type(info.path) == "string" and info.path or nil)
    if by_path then
        return by_path
    end
    if type(info.session_id) == "string" and info.session_id ~= "" then
        local session = Sessions.get_by_id(info.session_id)
        if session and session.rpc and session.rpc:is_running() then
            return session
        end
    end
    return nil
end

--- Registered session bound to a worktree, current tab first.
---@param info table
---@return pi.Session?
local function session_for_worktree(info)
    local current = Sessions.get()
    if current and same_worktree(current.worktree, info) then
        return current
    end
    if type(info.session_id) == "string" and info.session_id ~= "" then
        local by_id = Sessions.get_by_id(info.session_id)
        if by_id and same_worktree(by_id.worktree, info) then
            return by_id
        end
    end
    for _, session in ipairs(Sessions.list_all()) do
        if same_worktree(session.worktree, info) then
            return session
        end
    end
    return nil
end

--- Drop stale worktree references after a removal (the checkout is gone, so a
--- later close must not try to release it).
---@param info table
local function forget_worktree(info)
    for _, session in ipairs(Sessions.list_all()) do
        if same_worktree(session.worktree, info) then
            session.worktree = nil
            session._worktree_released = true
        end
    end
end

--- Short display label for a repository directory (accept hint text).
---@param path string?
---@return string
local function short_label(path)
    if type(path) ~= "string" or path == "" then
        return "main checkout"
    end
    return vim.fn.fnamemodify(path, ":t")
end

--- Default `git apply` runner. Applies the patch to the main checkout's
--- **working tree only**: no `--index`/`--cached` (the index is the user's),
--- no `--3way` (never merges behind their back) and no commit. `git apply` is
--- atomic: a conflicting hunk aborts the whole patch.
---@type fun(repo_root: string, patch: string, cb: fun(ok: boolean, err?: string))
local function default_apply_runner(repo_root, patch, cb)
    if type(repo_root) ~= "string" or repo_root == "" then
        cb(false, "unknown repository root")
        return
    end
    -- `git apply` rejects a patch whose last line has no trailing newline. Our
    -- diff producers end with one, but normalizing keeps the runner robust to a
    -- patch that was trimmed along the way.
    if type(patch) ~= "string" or patch:sub(-1) ~= "\n" then
        patch = (patch or "") .. "\n"
    end
    local ok, err = pcall(vim.system, { "git", "-C", repo_root, "apply", "--whitespace=nowarn" }, {
        text = true,
        stdin = patch,
    }, function(res)
        if res.code == 0 then
            cb(true)
            return
        end
        local text = res.stderr
        if type(text) ~= "string" or text == "" then
            text = res.stdout
        end
        cb(false, type(text) == "string" and text ~= "" and text or ("git apply exited " .. tostring(res.code)))
    end)
    if not ok then
        cb(false, tostring(err))
    end
end

local apply_runner = default_apply_runner

--- Test hook: replace the `git apply` runner (nil restores the default).
---@param fn fun(repo_root: string, patch: string, cb: fun(ok: boolean, err?: string))|nil
function M._set_apply_runner(fn)
    apply_runner = fn or default_apply_runner
end

--- Test hook: resolve a target worktree the way the commands do.
---@param name string?
---@return table? info
---@return string? err
function M._resolve_target(name)
    return resolve_target(name)
end

--- Close the tabpage `open_worktree_session` just created after a session
--- start failure — but only when it is still safe: the tab exists, is not the
--- last one, has exactly one window, and that window still shows the original
--- empty, unmodified `:tabnew` buffer. Anything the user opened in the
--- meantime keeps the tab.
---@param tab pi.TabId
---@param expected_buf integer The buffer the fresh tab was showing on creation.
---@return boolean closed
local function close_failed_tab(tab, expected_buf)
    if type(tab) ~= "number" or not vim.api.nvim_tabpage_is_valid(tab) then
        return false
    end
    if vim.fn.tabpagenr("$") <= 1 then
        return false
    end
    local wins = vim.api.nvim_tabpage_list_wins(tab)
    if #wins ~= 1 then
        return false
    end
    local win = wins[1]
    local bufnr = vim.api.nvim_win_get_buf(win)
    if bufnr ~= expected_buf then
        return false
    end
    if vim.api.nvim_buf_get_name(bufnr) ~= "" then
        return false
    end
    if vim.bo[bufnr].modified or vim.bo[bufnr].buftype ~= "" then
        return false
    end
    local ok = pcall(vim.api.nvim_win_close, win, false)
    return ok
end

--- Open a new tabpage and start a session process in `info.path`.
---@param Worktree table
---@param info table Worktree metadata from `Worktree.create`.
---@param opts pi.WorktreeOpts
---@param source? { file: string, name?: string, session: pi.Session } Fork source conversation.
---@return pi.Session?
local function open_worktree_session(Worktree, info, opts, source)
    if not valid_info(info) then
        Notify.error("Failed to create worktree: invalid worktree info")
        return nil
    end

    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    local tab_buf = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(tab))
    local session = Sessions.get_or_create({
        cwd = info.path,
        layout = opts.layout,
        worktree = info,
        -- A fork bootstraps the new process from the source session file: the
        -- backend clones the active branch into a new session *in the
        -- worktree's cwd*. The parent process/session is untouched.
        args = source and { "--fork", source.file } or nil,
    })
    if not session then
        -- Do not leave the scratch tab behind when nothing could be started in
        -- it (the process start failed before a chat/session was bound).
        close_failed_tab(tab, tab_buf)
        Notify.error("Failed to start a session in the worktree; releasing " .. info.path)
        release_orphan(Worktree, info)
        return nil
    end

    if source then
        session.forked_from = {
            session_id = source.session.id,
            session_file = source.file,
            -- Backend display name when the source session has one; the UI
            -- falls back to the session-file basename otherwise.
            name = source.name,
            worktree = type(source.session.worktree) == "table" and source.session.worktree.name or nil,
        }
        -- Mirror onto the worktree metadata so row renderers that only see
        -- the worktree info can label a fork. Only the live `session.forked_from`
        -- is guaranteed: `Worktree.bind` persists session_id/session_file and
        -- drops unknown fields.
        info.forked_from = session.forked_from
    end

    if source and session.chat then
        -- `--fork` seeds the *backend* with the parent's conversation, but a
        -- fresh chat buffer only shows what this client renders: without a
        -- replay the forked tab looks empty even though the backend carries the
        -- history. `manager.reload_messages` is the documented reload path
        -- (clear -> get_messages -> startup block -> replay -> refresh_state ->
        -- focus prompt), matching what `:PiFork` does after its fork response.
        -- Called after `forked_from` is set so no replay can render a fork
        -- without its `↳ forked from …` marker.
        local ok, manager = pcall(require, "pi.sessions.manager")
        if ok and type(manager) == "table" and type(manager.reload_messages) == "function" then
            manager.reload_messages(session)
        end
    end

    if session.chat then
        -- Immediate show/focus for the tab we just opened (synchronous, so it
        -- cannot reach into another tab). The replay above ends with its own
        -- deferred `ensure_shown_and_focus_prompt()`; that one lands in the
        -- same chat and is the same behavior `:PiFork` already has.
        session.chat:ensure_shown_and_focus_prompt()
    end
    Notify.info((source and "Forked into worktree: " or "Worktree session: ") .. info.path)
    return session
end

--- Resolve the source session file for a worktree fork.
---
--- Always asks the backend for `get_state`: it is authoritative about
--- `sessionFile`, whether a run is still streaming (the UI guard can lag),
--- `messageCount` and the source display name (`sessionName`, used by the
--- `↳ forked from …` UI marker). Forking an empty conversation would produce
--- an empty child in a fresh worktree, so that case gets a specific error
--- instead.
---@param session pi.Session
---@param callback fun(source: { file: string, name?: string }|nil, err: string?)
local function resolve_fork_source(session, callback)
    local rpc = session.rpc
    if not rpc or not rpc:is_running() then
        callback(nil, "No active session process")
        return
    end
    local sent = rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            local data = res and res.success and res.data or nil
            if type(data) ~= "table" then
                callback(nil, "Failed to read the current session state")
                return
            end
            if data.isStreaming == true or (session.chat and session.chat:is_streaming()) then
                callback(nil, "Wait for the agent to finish before forking into a worktree")
                return
            end
            local count = tonumber(data.messageCount)
            if count ~= nil and count == 0 then
                callback(nil, "Nothing to fork: the current session has no messages yet")
                return
            end
            local path = data.sessionFile
            if type(path) ~= "string" or path == "" then
                callback(nil, "Nothing to fork: the current session has no file yet")
                return
            end
            session.session_file = path
            callback({
                file = path,
                name = type(data.sessionName) == "string" and data.sessionName ~= "" and data.sessionName or nil,
            })
        end)
    end)
    if not sent then
        callback(nil, "Failed to send get_state")
    end
end

--- Create a worktree and reject nesting: a session that already runs in a
--- worktree must not spawn another one inside it.
---@param session pi.Session?
---@return string?
local function nesting_error(session)
    if session and type(session.worktree) == "table" then
        return "Nested worktrees are not supported: this session already runs in a worktree"
    end
    return nil
end

--- Create a worktree and open a fresh session in it (`:PiWorktreeNew`).
---@param opts? pi.WorktreeOpts
---@param callback? fun(session: pi.Session?)
function M.new(opts, callback)
    opts = opts or {}
    local Worktree = worktree_module()
    if not Worktree or type(Worktree.create) ~= "function" then
        Notify.error("Worktree support is unavailable (pi.worktree module missing)")
        return
    end

    local parent = Sessions.get()
    local nested = nesting_error(parent)
    if nested then
        Notify.error(nested)
        return
    end

    local base_cwd = (parent and parent.cwd) or vim.fn.getcwd()
    Worktree.create({ cwd = base_cwd, mode = "new", name = opts.name }, function(info, err)
        vim.schedule(function()
            if not valid_info(info) then
                Notify.error("Failed to create worktree: " .. tostring(err or "unknown error"))
                return
            end
            local session = open_worktree_session(Worktree, info, opts, nil)
            if callback then
                callback(session)
            end
        end)
    end)
end

--- Fork the current conversation into a new worktree (`:PiWorktreeFork`).
---
--- The child process is bootstrapped with `--fork <source session file>`: the
--- backend creates a new session (in the worktree's cwd) from the source
--- branch, leaving the parent session file and its process untouched.
---@param opts? pi.WorktreeOpts
---@param callback? fun(session: pi.Session?)
function M.fork(opts, callback)
    opts = opts or {}
    local session = Sessions.get()
    if not session or not session.rpc or not session.rpc:is_running() then
        Notify.warn("No active session")
        return
    end
    if session.chat and session.chat:is_streaming() then
        Notify.warn("Wait for the agent to finish before forking into a worktree")
        return
    end
    local nested = nesting_error(session)
    if nested then
        Notify.error(nested)
        return
    end

    local Worktree = worktree_module()
    if not Worktree or type(Worktree.create) ~= "function" then
        Notify.error("Worktree support is unavailable (pi.worktree module missing)")
        return
    end

    local conflict = conflicting_session_flag(require("pi.cli").args())
    if conflict then
        Notify.error(
            "Cannot fork into a worktree while pi.cli.args contains " .. conflict .. " (conflicts with --fork)"
        )
        return
    end

    resolve_fork_source(session, function(source, err)
        if not source then
            -- The streaming/empty cases are user-informative, not hard failures.
            Notify.warn(err or "Nothing to fork")
            return
        end
        local base_cwd = session.cwd or vim.fn.getcwd()
        Worktree.create({ cwd = base_cwd, mode = "fork", name = opts.name }, function(info, create_err)
            vim.schedule(function()
                if not valid_info(info) then
                    Notify.error("Failed to create worktree: " .. tostring(create_err or "unknown error"))
                    return
                end
                local child = open_worktree_session(Worktree, info, opts, {
                    file = source.file,
                    name = source.name,
                    session = session,
                })
                if callback then
                    callback(child)
                end
            end)
        end)
    end)
end

--- Move the current worktree session onto an explicit branch
--- (`:PiWorktreeBranch <branch>`): worktrees start on a detached HEAD, so
--- there is otherwise no branch name for the work to land on.
---
--- Tolerates both a synchronous `Worktree.branch(info, branch)` that returns
--- a result and an asynchronous one that invokes the optional callback; the
--- completion is delivered on the main loop either way.
---@param branch string
function M.branch(branch)
    branch = type(branch) == "string" and vim.trim(branch) or ""
    if branch == "" then
        Notify.warn("Branch name required")
        return
    end
    local session = Sessions.get()
    if not session then
        Notify.warn("No active session")
        return
    end
    local info = session.worktree
    if type(info) ~= "table" then
        Notify.warn("The current session is not running in a worktree")
        return
    end
    local Worktree = worktree_module()
    if not Worktree or type(Worktree.branch) ~= "function" then
        Notify.error("Worktree support is unavailable (pi.worktree module missing)")
        return
    end

    local finished = false
    ---@param result any
    ---@param err? any
    local function finish(result, err)
        if finished then
            return
        end
        finished = true
        vim.schedule(function()
            if result == false or (err ~= nil and err ~= "") then
                Notify.error("Failed to switch worktree branch: " .. tostring(err or "unknown error"))
            else
                Notify.info("Worktree branch: " .. branch)
            end
        end)
    end

    local ok, result, err = pcall(Worktree.branch, info, branch, finish)
    if not ok then
        finished = true
        Notify.error("Failed to switch worktree branch: " .. tostring(result))
        return
    end
    if result ~= nil then
        finish(result, err)
    end
end

--- Review a worktree's patch (relative to its base commit, untracked files
--- included) in the shared diff-review panel and, only on explicit accept
--- (`a`), apply it to the main checkout's working tree.
---
--- The patch is never applied automatically and nothing is committed: the
--- index and HEAD of the main checkout stay untouched. A conflicting or
--- failed `git apply` leaves both checkouts intact (the worktree is never
--- modified by this operation).
---@param opts? pi.WorktreeTargetOpts
---@param callback? fun(ok: boolean, err?: string) Called on every terminal path except a user-cancelled review.
function M.apply(opts, callback)
    opts = opts or {}
    local Worktree = worktree_module()
    if not Worktree or type(Worktree.diff) ~= "function" then
        Notify.error("Worktree support is unavailable (pi.worktree module missing)")
        if callback then
            callback(false, "worktree module missing")
        end
        return
    end
    local info, err = resolve_target(opts.name)
    if type(info) ~= "table" then
        Notify.error(err or "No worktree target")
        if callback then
            callback(false, err)
        end
        return
    end

    local function fail(message, reason)
        Notify.error(message)
        if callback then
            callback(false, reason or message)
        end
    end

    Worktree.diff(info, function(patch, diff_err)
        vim.schedule(function()
            if type(patch) ~= "string" then
                fail("Failed to read the worktree diff: " .. tostring(diff_err or "unknown error"), diff_err)
                return
            end
            if vim.trim(patch) == "" then
                Notify.info("No changes to apply from " .. tostring(info.path))
                if callback then
                    callback(false, "empty diff")
                end
                return
            end
            local sections = DiffReview.parse_sections(patch)
            if #sections == 0 then
                Notify.warn("The worktree diff has no reviewable file sections; nothing applied")
                if callback then
                    callback(false, "no reviewable sections")
                end
                return
            end
            -- parse_sections anchors `abs` at Neovim's cwd; in a worktree
            -- review the files being reviewed live in the worktree, so `<CR>`
            -- must jump there (the main checkout is the apply destination,
            -- not the source of truth).
            for _, section in ipairs(sections) do
                if type(section.path) == "string" and section.path ~= "" then
                    section.abs = info.path .. "/" .. section.path
                end
            end

            ---@type pi.DiffReviewGroup
            local group = {
                toplevel = info.path,
                branch = info.name or "",
                rel_files = {},
                abs_files = {},
                sections = {},
            }
            for i = 1, #sections do
                group.sections[i] = i
            end

            DiffReview.render(sections, {
                groups = { group },
                accept_label = "apply to " .. short_label(info.repo_root),
                on_accept = function()
                    -- Session id the user consented to (nil when no warning was
                    -- needed). Kept as a string so ids compare uniformly.
                    local warned_id = nil
                    local function run_apply()
                        -- Final re-check immediately before the write: a session
                        -- may have started while the warning was on screen (or
                        -- between the check and here). Consent is tied to the
                        -- warned session, so a *new* one blocks the write.
                        local live_now = running_session_at(info.repo_root)
                        if live_now and tostring(live_now.id) ~= tostring(warned_id or "") then
                            Notify.error(
                                "Main checkout "
                                    .. tostring(info.repo_root)
                                    .. " now has a running π session ("
                                    .. tostring(live_now.id)
                                    .. "); worktree patch not applied"
                            )
                            if callback then
                                callback(false, "main checkout busy")
                            end
                            return
                        end
                        apply_runner(info.repo_root, patch, function(ok, apply_err)
                            vim.schedule(function()
                                if ok then
                                    Notify.info(
                                        "Applied worktree patch to "
                                            .. tostring(info.repo_root)
                                            .. " (working tree only; not committed)"
                                    )
                                    if callback then
                                        callback(true)
                                    end
                                else
                                    Notify.error(
                                        "git apply failed in "
                                            .. tostring(info.repo_root)
                                            .. ": "
                                            .. tostring(apply_err)
                                    )
                                    if callback then
                                        callback(false, apply_err)
                                    end
                                end
                            end)
                        end)
                    end

                    -- Applying rewrites the main checkout's working tree; if a
                    -- pi process is running there, the agent may read/write the
                    -- same files mid-turn. Warn explicitly instead of applying
                    -- underneath it. Cancelling writes nothing.
                    local live = running_session_at(info.repo_root)
                    if not live then
                        run_apply()
                        return
                    end
                    warned_id = tostring(live.id)
                    Dialog.confirm({
                        title = "Apply into a live checkout?",
                        message = "The main checkout "
                            .. tostring(info.repo_root)
                            .. " is running π session ("
                            .. tostring(live.id)
                            .. "). Applying rewrites files in its working tree while the agent may be using them. Apply anyway?",
                    }, function(confirmed)
                        vim.schedule(function()
                            if not confirmed then
                                Notify.info("Worktree patch not applied")
                                if callback then
                                    callback(false, "cancelled")
                                end
                                return
                            end
                            run_apply()
                        end)
                    end)
                end,
            })
        end)
    end)
end

--- Chat prompt template for shipping a worktree's work. Deliberately plain
--- text: the user reviews/edits it in the prompt and submits it themselves;
--- pi.nvim never sends it and never commits on the user's behalf.
---@param info table
---@param status table?
---@return string
local function ship_template(info, status)
    local base = type(info.base_sha) == "string" and info.base_sha ~= "" and info.base_sha or "unknown"
    local head = (type(status) == "table" and type(status.head) == "string" and status.head ~= "") and status.head
        or base
    local state = "unknown"
    if type(status) == "table" then
        state = (status.dirty and "dirty" or "clean")
            .. ", "
            .. tostring(status.ahead or 0)
            .. " commit(s) ahead of the base commit"
    end
    local path = tostring(info.path)
    local branch = "pi/" .. tostring(info.name or "worktree")
    return table.concat({
        "Ship the changes from this isolated git worktree.",
        "",
        "Worktree (absolute path): " .. path,
        "Repository main checkout: " .. tostring(info.repo_root),
        "HEAD: " .. head .. " (detached HEAD; base commit " .. base .. ")",
        "State: " .. state,
        "",
        "Requirements:",
        "1. Work only inside the worktree above; the main checkout may be in use.",
        "2. If HEAD is still detached, create a branch before committing:",
        "   git -C " .. path .. " switch -c " .. branch,
        "3. Commit the work with focused messages. Do not commit in the main checkout.",
        "4. Push the branch to the configured remote and open a pull request; mention the base commit and the worktree path.",
        "5. Resolve any merge/rebase conflicts yourself: re-read the affected files, keep this worktree's intent, and never force-push shared branches.",
        "6. Do not amend or rewrite commits that are already pushed.",
        "",
        "Do not modify the main checkout's working tree.",
    }, "\n")
end

--- Prefill the target session's prompt with the ship template
--- (`:PiWorktreeShip`). Never sends: the user reviews and submits it.
---@param opts? pi.WorktreeTargetOpts
---@param callback? fun(ok: boolean, err?: string)
function M.ship(opts, callback)
    opts = opts or {}
    local info, err = resolve_target(opts.name)
    if type(info) ~= "table" then
        Notify.error(err or "No worktree target")
        if callback then
            callback(false, err)
        end
        return
    end

    local target = session_for_worktree(info)
    if not target then
        Notify.error(
            "No registered π session for worktree '"
                .. tostring(info.name or info.path)
                .. "'; open it from :PiSessions / :PiSubSwitch first"
        )
        if callback then
            callback(false, "no session")
        end
        return
    end

    local current = Sessions.get()
    local focused = true
    if target ~= current then
        local tab = target.attached_tab
        if type(tab) == "number" and vim.api.nvim_tabpage_is_valid(tab) then
            local ok_tab, tab_err = pcall(vim.api.nvim_set_current_tabpage, tab)
            if not ok_tab then
                Notify.error("Failed to switch to the worktree session's tab: " .. tostring(tab_err))
                if callback then
                    callback(false, tab_err)
                end
                return
            end
        elseif not target.chat then
            Notify.error(
                "Worktree '"
                    .. tostring(info.name or info.path)
                    .. "' has no attached chat; open its session from :PiSessions, then retry"
            )
            if callback then
                callback(false, "no chat")
            end
            return
        else
            -- Chat exists but its tab is gone: prefill without stealing focus.
            focused = false
        end
    end

    local label = tostring(info.name or info.path)
    local function prefill(status)
        vim.schedule(function()
            local chat = target.chat
            if not chat then
                Notify.error("Worktree session is not attached to a tab; open it from :PiSessions, then retry")
                if callback then
                    callback(false, "no chat")
                end
                return
            end
            local text = ship_template(info, status)
            if type(chat._set_prompt_draft) == "function" then
                chat:_set_prompt_draft(text)
            end
            if focused and type(chat.ensure_shown_and_focus_prompt) == "function" then
                chat:ensure_shown_and_focus_prompt()
            end
            -- Never send: the prompt waits for the user.
            Notify.info("Ship instructions for worktree '" .. label .. "' prefilled (not sent)")
            if callback then
                callback(true)
            end
        end)
    end

    local Worktree = worktree_module()
    if Worktree and type(Worktree.status) == "function" then
        Worktree.status(info, function(status, status_err)
            if type(status) ~= "table" then
                vim.schedule(function()
                    Notify.warn("Could not read worktree status: " .. tostring(status_err or "unknown error"))
                end)
            end
            prefill(status)
        end)
    else
        prefill(nil)
    end
end

--- Remove a worktree (`:PiWorktreeRemove`) after confirmation.
---
--- Safety rules: a live session process refuses the removal outright (never
--- delete a live cwd); a dirty/ahead checkout is flagged in the confirmation;
--- and the patch snapshot runs first — if snapshotting fails, nothing is
--- removed. `Worktree.remove` then runs with `force=true, snapshot=false`, so
--- it cannot take a second snapshot or silently skip the forced delete.
---@param opts? pi.WorktreeTargetOpts
---@param callback? fun(ok: boolean, err?: string)
function M.remove(opts, callback)
    opts = opts or {}
    local Worktree = worktree_module()
    if not Worktree or type(Worktree.remove) ~= "function" then
        Notify.error("Worktree support is unavailable (pi.worktree module missing)")
        if callback then
            callback(false, "worktree module missing")
        end
        return
    end
    local info, err = resolve_target(opts.name)
    if type(info) ~= "table" then
        Notify.error(err or "No worktree target")
        if callback then
            callback(false, err)
        end
        return
    end

    -- Refuse before any dialog/status work: deleting a live cwd breaks the
    -- running agent's next tool call (and the process may still be writing).
    local function refuse_live(is_live)
        Notify.error(
            "Worktree "
                .. tostring(info.path)
                .. " still has a running π session ("
                .. tostring(is_live.id)
                .. "); close its process first (:PiStop / :PiSubClose / :PiSessions x)"
        )
        if callback then
            callback(false, "live session")
        end
    end

    local live = live_session_for(info)
    if live then
        refuse_live(live)
        return
    end

    local cfg = Config.options.worktree or {}
    local snapshot_enabled = cfg.snapshot_before_remove ~= false

    local function confirmed_remove()
        -- Re-check after the confirmation: a session may have been revived or
        -- restarted while the dialog was open.
        local live_now = live_session_for(info)
        if live_now then
            refuse_live(live_now)
            return
        end

        local function finish(snapshot_path)
            -- Re-check again after the (potentially slow) snapshot, right before
            -- the destructive call: closes the TOCTOU window in which a session
            -- starts between confirmation and removal.
            local live_before_remove = live_session_for(info)
            if live_before_remove then
                refuse_live(live_before_remove)
                return
            end
            Worktree.remove(info, { force = true, snapshot = false }, function(removed, remove_err)
                vim.schedule(function()
                    if not removed then
                        Notify.error(
                            "Failed to remove worktree "
                                .. tostring(info.path)
                                .. ": "
                                .. tostring(remove_err or "unknown error")
                        )
                        if callback then
                            callback(false, remove_err)
                        end
                        return
                    end
                    forget_worktree(info)
                    local note = snapshot_path and (" (snapshot: " .. snapshot_path .. ")") or ""
                    Notify.info("Removed worktree " .. tostring(info.path) .. note)
                    if callback then
                        callback(true)
                    end
                end)
            end)
        end

        if not snapshot_enabled then
            finish(nil)
            return
        end
        if type(Worktree.snapshot) ~= "function" then
            Notify.error("Snapshot support is unavailable; worktree NOT removed")
            if callback then
                callback(false, "snapshot unavailable")
            end
            return
        end
        Worktree.snapshot(info, function(snapshot_path, snap_err)
            vim.schedule(function()
                if type(snapshot_path) ~= "string" or snapshot_path == "" then
                    Notify.error("Snapshot failed; worktree NOT removed: " .. tostring(snap_err or "unknown error"))
                    if callback then
                        callback(false, snap_err)
                    end
                    return
                end
                finish(snapshot_path)
            end)
        end)
    end

    local function ask(status)
        local dirty = type(status) == "table" and status.dirty == true
        local ahead = type(status) == "table" and (tonumber(status.ahead) or 0) or 0
        local message = "Remove worktree " .. tostring(info.path) .. "?"
        if dirty or ahead > 0 then
            local risks = {}
            if dirty then
                risks[#risks + 1] = "uncommitted changes"
            end
            if ahead > 0 then
                risks[#risks + 1] = ahead .. " commit(s) ahead of base"
            end
            message = message .. " It has " .. table.concat(risks, " and ") .. "."
            if snapshot_enabled then
                message = message .. " A patch snapshot is written first."
            else
                message = message
                    .. " Snapshotting is disabled (worktree.snapshot_before_remove=false): this work will be LOST."
            end
        end
        Dialog.confirm({ title = "Remove worktree", message = message }, function(confirmed)
            vim.schedule(function()
                if not confirmed then
                    if callback then
                        callback(false, "cancelled")
                    end
                    return
                end
                confirmed_remove()
            end)
        end)
    end

    if type(Worktree.status) == "function" then
        Worktree.status(info, function(status, status_err)
            vim.schedule(function()
                if type(status) ~= "table" then
                    Notify.warn("Could not read worktree status: " .. tostring(status_err or "unknown error"))
                end
                ask(status)
            end)
        end)
    else
        ask(nil)
    end
end

---@class pi.WorktreeRecoverySnapshot
---@field path? string Patch file path (sidecar under the git dir).
---@field patch? string Patch text (read from `path` when only the path is known).
---@field base_sha? string Base commit recorded with the snapshot.
---@field integrated? boolean The recorded work was already integrated into the main branch.

---@class pi.ResumeTarget
---@field cwd? string Requested working directory.
---@field worktree? table Worktree metadata when the target is a managed worktree.
---@field session_id? string Session id used to look up integration metadata.

--- Split `<repo>/.worktrees/<name>` into its repository root and worktree name.
---@param path string
---@return string? repo_root
---@return string? name
local function split_worktree_path(path)
    if type(path) ~= "string" or path == "" then
        return nil, nil
    end
    local norm = vim.fs.normalize(path)
    local repo_root, name = norm:match("^(.-)[/\\]%.worktrees[/\\]([^/\\]+)$")
    if type(repo_root) == "string" and repo_root ~= "" and type(name) == "string" and name ~= "" then
        return repo_root, name
    end
    return nil, nil
end

--- Snapshot record for a removed worktree, or nil + reason when unavailable.
--- Tolerant by design: the git-side module owns the record shape and may not
--- have shipped `latest_snapshot` yet.
---@param Worktree table
---@param repo_root string
---@param name string
---@return pi.WorktreeRecoverySnapshot? snapshot
---@return string? err
local function read_snapshot(Worktree, repo_root, name)
    if type(Worktree.latest_snapshot) ~= "function" then
        return nil, "latest_snapshot is unavailable"
    end
    local ok, snap, snap_err = pcall(Worktree.latest_snapshot, repo_root, name)
    if not ok then
        return nil, tostring(snap)
    end
    if snap == nil then
        return nil, type(snap_err) == "string" and snap_err or nil
    end

    ---@type pi.WorktreeRecoverySnapshot
    local record = {}
    if type(snap) == "string" then
        record.path = snap
    elseif type(snap) == "table" then
        -- `pi.worktree.latest_snapshot` returns `{ path, meta? }` (meta = the
        -- `.patch.json` sidecar); tolerate an enriched shape from other
        -- implementations too.
        local meta = type(snap.meta) == "table" and snap.meta or nil
        record.path = type(snap.path) == "string" and snap.path or nil
        record.patch = type(snap.patch) == "string" and snap.patch or nil
        record.base_sha = (type(snap.base_sha) == "string" and snap.base_sha)
            or (meta and type(meta.base_sha) == "string" and meta.base_sha)
            or nil
        record.integrated = snap.integrated == true
            or (type(snap.integration) == "table" and snap.integration.integrated == true)
    else
        return nil, "latest_snapshot returned an unsupported value"
    end
    if type(record.patch) ~= "string" and type(record.path) == "string" then
        local file = io.open(record.path, "r")
        if file then
            record.patch = file:read("*a")
            file:close()
        end
    end
    return record, nil
end

--- Manifest row for a session id (any workspace), or nil.
---@param session_id string?
---@return table?
local function locate_entry(session_id)
    if type(session_id) ~= "string" or session_id == "" then
        return nil
    end
    local ok, Manifest = pcall(require, "pi.subsessions.manifest")
    if not ok or type(Manifest) ~= "table" or type(Manifest.locate) ~= "function" then
        return nil
    end
    local called, entry = pcall(Manifest.locate, session_id)
    if not called then
        return nil
    end
    return type(entry) == "table" and entry or nil
end

--- `integrated`/`applied` flag of an integration record, or nil when absent.
---@param value any
---@return boolean?
local function integration_flag(value)
    if type(value) ~= "table" then
        return nil
    end
    if value.integrated == true or value.applied == true then
        return true
    end
    if value.integrated == false or value.applied == false then
        return false
    end
    return nil
end

--- Whether a manifest row says the worktree's work was integrated into the
--- main branch already. Tolerant across the shapes the integration module may
--- use (top-level flag, `integration` sub-table, or a nested `worktree` row).
---@param entry table?
---@return boolean
local function entry_integrated(entry)
    if type(entry) ~= "table" then
        return false
    end
    local direct = integration_flag(entry)
    if direct ~= nil then
        return direct
    end
    local nested = integration_flag(entry.integration)
    if nested ~= nil then
        return nested
    end
    -- Integration engine record on the child's manifest row: `applied` (or a
    -- recorded `applied_at`) means the patch already landed in the parent.
    local rec = entry.integration
    if type(rec) == "table" then
        if rec.state == "applied" then
            return true
        end
        if type(rec.applied_at) == "string" and rec.applied_at ~= "" then
            return true
        end
    end
    local worktree = entry.worktree
    if type(worktree) == "table" then
        local wt_flag = integration_flag(worktree)
        if wt_flag ~= nil then
            return wt_flag
        end
        local wt_nested = integration_flag(worktree.integration)
        if wt_nested ~= nil then
            return wt_nested
        end
    end
    return false
end

--- Recreate a managed worktree that was removed (clean auto-release or
--- `:PiWorktreeRemove`) so a saved session can be resumed in its workspace.
---
--- Recovery sources, in order: integration metadata on the session's manifest
--- row (`Manifest.locate`), then the latest snapshot sidecar
--- (`Worktree.latest_snapshot`). Rules:
---   * integrated work → create from the *current* HEAD and never re-apply the
---     old patch (re-applying integrated work would duplicate it);
---   * not integrated → create from the recorded base commit, then apply the
---     snapshot into the new worktree;
---   * neither → explicit error. The session is never silently opened in the
---     main checkout, and nothing is ever written there.
---@param opts { repo_root: string, name: string, session_id?: string, base_sha?: string, mode?: string }
---@param cb fun(info: table?, err: string?)
function M.recover_worktree(opts, cb)
    if type(opts) ~= "table" or type(cb) ~= "function" then
        return
    end
    local Worktree = worktree_module()
    if not Worktree or type(Worktree.create) ~= "function" then
        cb(nil, "Worktree support is unavailable (pi.worktree module missing)")
        return
    end
    local repo_root = opts.repo_root
    local name = opts.name
    if type(repo_root) ~= "string" or repo_root == "" or vim.fn.isdirectory(repo_root) == 0 then
        cb(nil, "Cannot recover worktree: invalid repository root")
        return
    end
    if type(name) ~= "string" or name == "" then
        cb(nil, "Cannot recover worktree: missing name")
        return
    end
    if type(Worktree.validate_name) == "function" then
        local ok, err = Worktree.validate_name(name)
        if not ok then
            cb(nil, err or ("Invalid worktree name: " .. name))
            return
        end
    end

    local path = repo_root .. "/.worktrees/" .. name
    if vim.fn.isdirectory(path) == 1 then
        local info = type(Worktree.detect) == "function" and Worktree.detect(path) or nil
        if type(info) == "table" then
            cb(info)
            return
        end
    end

    local entry = locate_entry(opts.session_id)
    local integrated = entry_integrated(entry)
    local base_sha = opts.base_sha
    if type(entry) == "table" then
        local entry_worktree = entry.worktree
        local record = entry.integration
        if type(record) == "table" and type(record.base_sha) == "string" and record.base_sha ~= "" then
            base_sha = record.base_sha
        elseif type(entry.base_sha) == "string" and entry.base_sha ~= "" then
            base_sha = entry.base_sha
        elseif type(entry_worktree) == "table" and type(entry_worktree.base_sha) == "string" then
            base_sha = entry_worktree.base_sha
        end
    end

    ---@type pi.WorktreeRecoverySnapshot?
    local snapshot = nil
    if not integrated then
        local snap, snap_err = read_snapshot(Worktree, repo_root, name)
        if not snap then
            cb(
                nil,
                string.format(
                    "Worktree '%s' is missing and has no snapshot or integration record (%s); refusing to resume in the main checkout",
                    name,
                    tostring(snap_err or "none found")
                )
            )
            return
        end
        snapshot = snap
        if snap.integrated == true then
            integrated = true
        end
        base_sha = base_sha or snap.base_sha
        if not integrated then
            if type(snap.patch) ~= "string" then
                cb(nil, "Snapshot for worktree '" .. name .. "' is unreadable")
                return
            end
            if vim.trim(snap.patch) == "" then
                -- A clean release still writes a (zero-byte / whitespace)
                -- snapshot next to the removed checkout. There is nothing to
                -- restore: recreate the checkout at its base and succeed
                -- without calling apply_patch (whose empty-patch error
                -- semantics stay as they are for other callers).
                snapshot = nil
            end
        end
    end

    if not integrated and (type(base_sha) ~= "string" or base_sha == "") then
        cb(
            nil,
            "Worktree '"
                .. name
                .. "' is missing and its base commit is unknown; refusing to recreate it at the wrong base"
        )
        return
    end

    -- Integrated work already lives in the main branch: recreate at the
    -- current HEAD (no `base`). Otherwise recreate at the recorded base so the
    -- snapshot applies cleanly. (An `x and nil or y` idiom would fall through
    -- to `y` here — the true branch must be an explicit nil.)
    local create_base = nil
    if not integrated then
        create_base = base_sha
    end
    Worktree.create({
        cwd = repo_root,
        name = name,
        mode = opts.mode or "resume",
        base = create_base,
    }, function(info, create_err)
        if not valid_info(info) then
            cb(nil, "Failed to recreate worktree '" .. name .. "': " .. tostring(create_err or "unknown error"))
            return
        end
        if integrated or not snapshot or type(snapshot.patch) ~= "string" or vim.trim(snapshot.patch) == "" then
            cb(info)
            return
        end
        if type(Worktree.apply_patch) ~= "function" then
            release_orphan(Worktree, info)
            cb(nil, "Worktree module cannot restore snapshots (apply_patch missing)")
            return
        end

        local done = false
        local function finish(applied, apply_err)
            if done then
                return
            end
            done = true
            vim.schedule(function()
                if type(applied) == "table" then
                    info = applied
                    applied = true
                end
                if applied == false or (applied == nil and apply_err ~= nil) then
                    release_orphan(Worktree, info)
                    cb(
                        nil,
                        "Failed to restore snapshot into worktree '"
                            .. name
                            .. "': "
                            .. tostring(apply_err or "unknown error")
                    )
                    return
                end
                cb(info)
            end)
        end
        -- Contract: `apply_patch(target_dir, patch, cb)` — apply the snapshot
        -- into the *new* worktree, never the main checkout.
        local ok_call, call_err = pcall(Worktree.apply_patch, info.path, snapshot.patch, finish)
        if not ok_call then
            finish(false, call_err)
        end
    end)
end

--- Ensure a resume target's checkout exists before the session is opened.
---
--- An existing directory is used as-is (worktree metadata refreshed via
--- `Worktree.detect` when missing). A missing managed worktree is recovered
--- through `recover_worktree` (integration metadata / snapshot), never by
--- silently opening the session in the main checkout.
---@param target pi.ResumeTarget
---@param cb fun(target: pi.ResumeTarget?)
function M.prepare_resume_target(target, cb)
    if type(cb) ~= "function" then
        return
    end
    target = target or {}
    local Worktree = worktree_module()
    local worktree = type(target.worktree) == "table" and target.worktree or nil
    local cwd = type(target.cwd) == "string" and target.cwd or nil

    -- No cwd/worktree hint: keep the historical in-place resume path.
    if (not cwd or cwd == "") and not worktree then
        cb(target)
        return
    end

    local function finish(info)
        local resolved = type(info) == "table" and info or worktree
        local resolved_cwd = cwd
        if valid_info(resolved) then
            resolved_cwd = resolved.path
        end
        if type(resolved_cwd) ~= "string" or vim.fn.isdirectory(resolved_cwd) == 0 then
            cb(nil)
            return
        end
        if type(resolved) ~= "table" and Worktree and type(Worktree.detect) == "function" then
            resolved = Worktree.detect(resolved_cwd)
        end
        cb({
            cwd = resolved_cwd,
            worktree = type(resolved) == "table" and resolved or nil,
            session_id = target.session_id,
        })
    end

    local existing = cwd or (worktree and worktree.path)
    if type(existing) == "string" and vim.fn.isdirectory(existing) == 1 then
        local info = worktree
        if type(info) ~= "table" and Worktree and type(Worktree.detect) == "function" then
            info = Worktree.detect(existing)
        end
        finish(info or { path = existing })
        return
    end

    local repo_root = worktree and worktree.repo_root or nil
    local name = worktree and worktree.name or nil
    if type(repo_root) ~= "string" or repo_root == "" or type(name) ~= "string" or name == "" then
        local derived_root, derived_name = split_worktree_path(existing or cwd or "")
        repo_root = repo_root or derived_root
        name = name or derived_name
    end
    if type(repo_root) ~= "string" or repo_root == "" or type(name) ~= "string" or name == "" then
        if not worktree then
            -- A plain session whose recorded cwd no longer exists (and which is
            -- not a managed `<repo>/.worktrees/<name>` path): keep the old
            -- in-place resume instead of inventing a worktree for it.
            cb({ session_id = target.session_id })
            return
        end
        Notify.error(
            "Worktree for this session is missing and cannot be located"
                .. ((type(existing) == "string" and existing ~= "") and (": " .. existing) or "")
        )
        cb(nil)
        return
    end

    M.recover_worktree({
        repo_root = repo_root,
        name = name,
        session_id = target.session_id,
        base_sha = worktree and worktree.base_sha or nil,
    }, function(info, err)
        if not valid_info(info) then
            Notify.error("Failed to recover worktree '" .. tostring(name) .. "': " .. tostring(err or "unknown error"))
            cb(nil)
            return
        end
        Notify.info("Recovered worktree " .. info.path)
        finish(info)
    end)
end

return M
