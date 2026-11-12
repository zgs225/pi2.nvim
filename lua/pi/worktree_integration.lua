--- Automatic integration of sub-session worktree patches into the parent checkout.
---
--- **Retained but dormant:** spawned sub-sessions no longer get a checkout of their
--- own (they run in the parent's cwd), so a fresh dispatch never reaches this path.
--- The module still ships for checkouts recorded by earlier versions.
--- When a child does own one and settles, its work stays isolated until someone moves it out. This
--- module is the **automatic** path: it captures the child's patch, writes a
--- durable snapshot, and applies the patch to the parent's working tree when
--- (and only when) doing so is safe. `:PiWorktreeApply` stays the manual,
--- reviewed route and is unaffected.
---
--- ## Invariants
---
--- 1. **Never lose work.** The patch is captured *and* snapshotted before
---    anything is applied, and the checkout is only deleted after the patch is
---    verifiably present in the target (`probe == "already"`). `skipped` (empty
---    diff) is the only path that deletes without a snapshot — there is nothing
---    to lose.
--- 2. **Never write under a live agent.** The apply only runs when the parent is
---    blocked in `wait_subagents` (its turn is suspended inside one tool call)
---    or idle; a busy parent, a second live session in the same checkout, or a
---    modified Neovim buffer that the patch touches all park the patch instead.
--- 3. **Idempotent.** `probe` (`git apply --check` / `--reverse --check`) decides
---    between `clean` (apply), `already` (mark applied, never write twice) and
---    `conflict` (never partially apply). A persisted `patch_sha` guards against
---    replaying a different patch from the same row.
--- 4. **Serialized per target.** `git apply` takes no working-tree lock, so every
---    write to one checkout goes through one queue keyed by `repo_root`.
--- 5. **State lives in the manifest row** (`entry.integration`), written *before*
---    the first write and re-checked at fire time, so a crashed Neovim can be
---    reconciled from disk (`reconcile`).
---
--- ## States
---
--- | state | meaning |
--- | --- | --- |
--- | `queued` | captured + snapshotted, waiting for a safe window |
--- | `applying` | `git apply` in flight (crash marker for `reconcile`) |
--- | `applied` | present in the target; checkout removed or deliberately kept |
--- | `resolving` | a resolving prompt was sent to the (reused) child agent |
--- | `needs_attention` | stopped; a human decision is required |
---
--- Outcomes returned to callers that are *never* persisted: `disabled`,
--- `no_child`, `no_entry`, `no_worktree`, `worktree_missing`, `skipped`.
---
--- `needs_attention` reasons worth knowing: `capture_failed` / `snapshot_failed`
--- (nothing was written), `probe_unavailable` / `head_unavailable` (fail closed),
--- `modified_buffer` / `parent_dirty` / `parent_busy` (retryable — promoted back
--- to `queued` by `on_parent_ready`), `patch_conflict` / `apply_failed` /
--- `base_drift` (resolved once by the child when `auto_resolve` allows it,
--- otherwise a human decision), `delta_baseline_missing` (a new run on an
--- already integrated checkout whose baseline cannot be trusted — the previous
--- patch is never replayed), `resolve_failed` (the child could not be prompted),
--- and `checkout_changed` / `ignored` / `live_session` (applied, but the checkout
--- was deliberately kept).
---
--- ## Repeated runs on one checkout
---
--- Every capture records the checkout's `head_sha`. When a *new* run settles on
--- an already integrated checkout, `delta_plan` picks the diff base: a changed
--- `base_sha` (fresh or rebased checkout) means a plain base→now capture is the
--- delta; an unchanged base with a **committed** previous round means diffing
--- from that recorded `head_sha`; anything else (the previous work was still
--- uncommitted, or no baseline was recorded) stops in
--- `needs_attention:delta_baseline_missing` instead of replaying the old patch.
--- `from_sha` stores the base actually used, so `detach` and retention can
--- re-capture and compare against `patch_sha`.
---
--- ## Fire-time re-checks
---
--- A decision is made after an async probe, so the safety facts are re-checked
--- immediately before `git apply` (`prewrite_blocker`: parent blocked/idle, no
--- second live session, no modified buffer) and again before a checkout is
--- deleted (`checkout_matches`: a fresh `diff` must still equal `patch_sha`, else
--- a background writer's new work would be destroyed). Deletion also re-checks
--- `run_generation`, the durable snapshot and ignored content.
---
--- ## Dependencies (other modules)
---
--- - `pi.worktree`: `diff(info, cb, opts?)`, `snapshot(info, cb)`,
---   `probe(target, patch, cb)`, `apply_patch(target, patch, cb)`,
---   `status(info, cb)`, `detect(cwd)`, `remove(info, opts, cb)`. A missing
---   `probe`/`apply_patch` fails **closed** (`needs_attention`), never open.
--- - `pi.subsessions.manifest`: `load_at`/`load`/`patch`/`locate`/`workspace`/
---   `iso_now`/`scopes`.
--- - `pi.subsessions.batch`: optional `is_waiting(cwd, lineage)`. Absent means
---   "not blocked in a wait", which only ever *delays* an apply.
--- - `pi.sessions.manager`: `list_all`/`get_by_id`/`find_by_lineage`.
--- - `pi.attention` (optional) for the persistent `needs_attention` notification.
---
--- Every function is async and main-loop safe: worktree/git callbacks are
--- `vim.schedule`d before any editor or manifest work (G26).

local M = {}

local Config = require("pi.config")

--- Persisted integration states. Everything else is an outcome, not a state.
---@type table<string, boolean>
local STATES = {
    queued = true,
    applying = true,
    applied = true,
    resolving = true,
    needs_attention = true,
}

--- Reasons that only need time (not a human): a `needs_attention` row is
--- promoted back to `queued` by `on_parent_ready` only for these.
---@type table<string, boolean>
local RETRYABLE = {
    modified_buffer = true,
    parent_busy = true,
    parent_gone = true,
    other_session = true,
    parent_dirty = true,
    no_target = true,
    probe_unavailable = true,
}

--- Queue reasons that are the normal steady state and must not toast.
---@type table<string, boolean>
local QUIET = {
    parent_busy = true,
    captured = true,
    applying = true,
}

local DEFAULT_KEEP = 15

-- Lazy accessors -------------------------------------------------------------
--
-- `pi.subsessions.init` requires this module, so requiring it back at load time
-- would be a cycle. Everything below is resolved at call time (G20 for config).

---@return table
local function manifest()
    return require("pi.subsessions.manifest")
end

---@return table
local function sessions()
    return require("pi.sessions.manager")
end

---@return table?
local function worktree()
    local ok, mod = pcall(require, "pi.worktree")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

--- Effective configuration, read at call time (never cached: G20).
---@return { auto: boolean, auto_resolve: boolean, max_attempts: integer, keep_count: integer }
local function cfg()
    local wt = Config.options.worktree or {}
    local ic = type(wt.integration) == "table" and wt.integration or {}
    local keep = tonumber(ic.keep_count)
    if keep == nil then
        keep = DEFAULT_KEEP
    end
    local attempts = tonumber(ic.max_attempts)
    if attempts == nil then
        attempts = 1
    end
    return {
        auto = ic.auto ~= false,
        auto_resolve = ic.auto_resolve ~= false,
        max_attempts = math.max(attempts, 0),
        keep_count = math.max(keep, 0),
    }
end

-- Path helpers ---------------------------------------------------------------

---@param path any
---@return string?
local function norm(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local ok, resolved = pcall(vim.fs.normalize, path)
    if ok and type(resolved) == "string" and resolved ~= "" then
        return (resolved:gsub("/+$", ""))
    end
    return path
end

--- True when `path` is `dir` or lives below it.
---@param path string?
---@param dir string?
---@return boolean
local function is_under(path, dir)
    local p = norm(path)
    local d = norm(dir)
    if not p or not d then
        return false
    end
    if p == d then
        return true
    end
    return p:sub(1, #d + 1) == d .. "/"
end

---@param path string?
---@param dir string?
---@return string? rel path relative to `dir`
local function relative(path, dir)
    local p = norm(path)
    local d = norm(dir)
    if not p or not d or not is_under(p, d) then
        return nil
    end
    if p == d then
        return ""
    end
    return p:sub(#d + 2)
end

--- Path of the repository-local worktree directory (never touched by an apply).
---@param root string
---@return string
local function worktrees_dir(root)
    return (norm(root) or root) .. "/.worktrees"
end

-- Patch helpers --------------------------------------------------------------

--- C-style escapes git uses when a path needs quoting (`core.quotePath`): the
--- short escapes plus three-digit **octal** bytes, which is how git spells any
--- non-printable or non-ASCII byte. Anything this cannot decode returns `nil` so
--- the caller can fail closed instead of guessing a path.
---@param value string
---@return string? decoded
local function c_unquote(value)
    if value:sub(1, 1) ~= '"' then
        return value
    end
    if #value < 2 or value:sub(-1) ~= '"' then
        return nil
    end
    local short = {
        a = "\a",
        b = "\b",
        f = "\f",
        n = "\n",
        r = "\r",
        t = "\t",
        v = "\v",
        ["\\"] = "\\",
        ['"'] = '"',
        ["/"] = "/",
    }
    local out = {}
    local i = 2
    local last = #value - 1
    while i <= last do
        local ch = value:sub(i, i)
        if ch == '"' then
            -- A bare quote inside the payload: not something git emits.
            return nil
        end
        if ch ~= "\\" then
            out[#out + 1] = ch
            i = i + 1
        else
            local nxt = value:sub(i + 1, i + 1)
            if nxt == "" then
                return nil
            end
            if short[nxt] then
                out[#out + 1] = short[nxt]
                i = i + 2
            elseif nxt:match("%d") then
                local oct = value:sub(i + 1, i + 3)
                if #oct < 3 or not oct:match("^[0-7][0-7][0-7]$") then
                    return nil
                end
                local byte = tonumber(oct, 8)
                if not byte or byte > 255 then
                    return nil
                end
                out[#out + 1] = string.char(byte)
                i = i + 4
            else
                -- Unknown escape: never guess a path.
                return nil
            end
        end
    end
    return table.concat(out)
end

--- Split a `diff --git` argument list, honoring quoted tokens.
---@param text string
---@return string[]? tokens nil when the quoting is malformed
local function split_patch_tokens(text)
    local out = {}
    local i = 1
    local n = #text
    while i <= n do
        local ch = text:sub(i, i)
        if ch == " " then
            i = i + 1
        elseif ch == '"' then
            local j = i + 1
            local closed = false
            while j <= n do
                local cj = text:sub(j, j)
                if cj == "\\" then
                    j = j + 2
                elseif cj == '"' then
                    closed = true
                    break
                else
                    j = j + 1
                end
            end
            if not closed or j > n then
                return nil
            end
            out[#out + 1] = text:sub(i, j)
            i = j + 1
        else
            local space = text:find(" ", i, true)
            local stop = space and (space - 1) or n
            out[#out + 1] = text:sub(i, stop)
            i = stop + 1
        end
    end
    return out
end

--- Strip the `a/` or `b/` prefix of a decoded patch path.
---@param decoded string?
---@param prefix "a"|"b"
---@return string? path
local function strip_prefix(decoded, prefix)
    if type(decoded) ~= "string" or decoded == "" then
        return nil
    end
    if decoded == "/dev/null" then
        return "/dev/null"
    end
    if decoded:sub(1, 2) ~= prefix .. "/" then
        return nil
    end
    return decoded:sub(3)
end

--- Paths a unified patch touches, repo-relative and deduplicated.
---
--- Accepts the `+++ b/<path>` / `--- a/<path>` form (including `/dev/null`) and
--- the `diff --git a/x b/y` header, in both the plain and the **C-quoted** form
--- git uses for unusual bytes, so a rename records both sides.
---
--- The second return value is `false` as soon as one path could not be decoded.
--- Callers must then treat the path list as unknown (fail closed) rather than
--- trust a partial list: it drives the "do not overwrite a modified buffer"
--- check and the parent's `changed_files`.
---@param patch string?
---@return string[] files
---@return boolean complete
function M.patch_files(patch)
    local out, seen = {}, {}
    if type(patch) ~= "string" then
        return out, false
    end
    local complete = true
    ---@param path string?
    local function add(path)
        if path == nil then
            complete = false
            return
        end
        if path == "" or path == "/dev/null" or seen[path] then
            return
        end
        seen[path] = true
        out[#out + 1] = path
    end
    ---@param raw string
    ---@param prefix "a"|"b"
    local function add_raw(raw, prefix)
        add(strip_prefix(c_unquote(raw), prefix))
    end
    -- `--- `/`+++ ` headers only appear *before* a hunk; inside one they are
    -- content (a removed line whose text starts with `-- ` renders as `--- …`),
    -- which must never be mistaken for a path.
    local in_hunk = false
    for line in patch:gmatch("[^\n]+") do
        if line:sub(1, 1) == "@" and line:sub(1, 2) == "@@" then
            in_hunk = true
        elseif line:sub(1, 10) == "diff --git" then
            in_hunk = false
            local header = line:match("^diff %-%-git (.*)$")
            local tokens = header and split_patch_tokens(header) or nil
            if tokens == nil or #tokens ~= 2 then
                complete = false
            else
                add_raw(tokens[1], "a")
                add_raw(tokens[2], "b")
            end
        elseif not in_hunk then
            local plus = line:match("^%+%+%+ (.*)$")
            local minus = line:match("^%-%-%- (.*)$")
            if plus then
                add_raw(plus, "b")
            elseif minus then
                add_raw(minus, "a")
            end
        end
    end
    return out, complete
end

---@param patch string
---@return string
local function sha_of(patch)
    local ok, value = pcall(vim.fn.sha256, patch)
    if ok and type(value) == "string" then
        return value
    end
    return #patch .. ":" .. (patch:sub(1, 64))
end

--- Read a snapshot patch byte-for-byte (text mode would mangle binary hunks).
---@param path string?
---@return string?
local function read_patch(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local fd = io.open(path, "rb")
    if not fd then
        return nil
    end
    local data = fd:read("*a")
    fd:close()
    return data
end

--- Split NUL-separated git output.
---@param text string?
---@return string[]
local function split_nul(text)
    local out = {}
    if type(text) ~= "string" or text == "" then
        return out
    end
    for chunk in text:gmatch("([^%z]+)%z") do
        out[#out + 1] = chunk
    end
    if #out == 0 and text:sub(-1) ~= "\0" then
        out[1] = text
    end
    return out
end

-- Manifest records -----------------------------------------------------------

---@class pi.WorktreeIntegration
---@field state "queued"|"applying"|"applied"|"resolving"|"needs_attention"
---@field patch_sha string sha256 of the captured patch
---@field base_sha? string base commit of the child checkout
---@field parent_head? string HEAD of the target checkout when the patch was captured
---@field snapshot_path? string durable patch copy under `<git common dir>/pi2-worktree-snapshots/`
---@field files string[] repo-relative paths the patch touches
---@field files_complete? boolean false when `files` could not be parsed fully (the path list is then treated as unknown and safety checks widen)
---@field head_sha? string HEAD of the child checkout at capture time (the delta baseline for a reused checkout)
---@field from_sha? string diff base actually used for this capture (set only for an incremental capture; the full base is `base_sha`)
---@field attempts integer resolving attempts already spent
---@field error string last error text (empty when none; never nil so a re-persist cannot resurrect a stale value)
---@field applied_at string ISO timestamp of the successful apply (empty when never applied)
---@field reason? string machine code of the last decision (see `M._decide`)
---@field run_generation? integer child run the integration belongs to
---@field kept_reason? string non-empty when `applied` but the checkout was deliberately kept
---@field pinned? boolean never removed by retention
---@field archived? boolean retention already handled this row
---@field archived_at? string
---@field worktree_removed? boolean the checkout was deleted

--- Integration record of a manifest row.
---@param entry any
---@return pi.WorktreeIntegration?
local function record_of(entry)
    local rec = type(entry) == "table" and entry.integration or nil
    if type(rec) ~= "table" then
        return nil
    end
    return rec
end

--- Build the next full record: `Manifest.patch` merges only top-level keys, so
--- the `integration` subtable is always replaced wholesale — a partial table
--- would silently drop every field it does not mention.
---@param rec table?
---@param fields table
---@return pi.WorktreeIntegration
local function merged(rec, fields)
    local out = {}
    if type(rec) == "table" then
        for k, v in pairs(rec) do
            out[k] = v
        end
    end
    if type(fields) == "table" then
        for k, v in pairs(fields) do
            if v ~= nil then
                out[k] = v
            end
        end
    end
    if type(out.state) ~= "string" or not STATES[out.state] then
        out.state = "queued"
    end
    out.attempts = math.max(tonumber(out.attempts) or 0, 0)
    out.files = type(out.files) == "table" and out.files or {}
    out.error = type(out.error) == "string" and out.error or ""
    out.applied_at = type(out.applied_at) == "string" and out.applied_at or ""
    out.patch_sha = type(out.patch_sha) == "string" and out.patch_sha or ""
    return out
end

--- Persist a record on a manifest row. Falls back to `locate` so a row found in
--- another workspace (after a Neovim restart or a tab cwd change) still
--- receives the state.
---@param child_id string
---@param cwd? string
---@param rec table
---@return boolean ok
local function persist(child_id, cwd, rec)
    if type(child_id) ~= "string" or child_id == "" or type(rec) ~= "table" then
        return false
    end
    local Manifest = manifest()
    local ok, saved = pcall(Manifest.patch, child_id, { integration = rec }, cwd)
    return ok and saved == true
end

--- Fresh manifest row for a child, searching other workspaces when the hint
--- misses (same discipline as `Subsessions.on_child_settled`).
---@param child_id string
---@param cwd? string
---@return table? entry
---@return string? workspace
local function row_of(child_id, cwd)
    if type(child_id) ~= "string" or child_id == "" then
        return nil, nil
    end
    local Manifest = manifest()
    local entry = Manifest.load(cwd)[child_id]
    if type(entry) == "table" then
        return entry, cwd
    end
    local located, located_cwd = Manifest.locate(child_id, cwd)
    if type(located) == "table" then
        return located, located_cwd or cwd
    end
    return nil, cwd
end

-- Git helper ----------------------------------------------------------------
--
-- Only facts the `pi.worktree` contract does not expose: the ignored content of
-- a checkout (deciding whether `--force` removal is lossless) and the target's
-- HEAD when `detect`/`status` are unavailable. Everything else goes through the
-- worktree API.

---@alias pi.WorktreeIntegrationGit fun(argv: string[], cwd: string, cb: fun(code: integer, stdout: string, stderr: string))

---@type pi.WorktreeIntegrationGit?
local git_override = nil

--- Test seam for the ignored-content probe (see `M._set_ignored`).
---@type fun(info: table, cb: fun(entries: string[]))?
local ignored_override = nil

---@param argv string[]
---@param cwd string
---@param cb fun(code: integer, stdout: string, stderr: string)
local function git(argv, cwd, cb)
    if git_override then
        return git_override(argv, cwd, cb)
    end
    local ok, err = pcall(vim.system, argv, { cwd = cwd, text = true }, function(res)
        vim.schedule(function()
            cb(res.code or -1, res.stdout or "", res.stderr or "")
        end)
    end)
    if not ok then
        vim.schedule(function()
            cb(-1, "", tostring(err))
        end)
    end
end

-- Facts gathering ------------------------------------------------------------

---@class pi.WorktreeIntegrationFacts
---@field has_patch boolean
---@field probe? "clean"|"already"|"conflict" nil when the probe could not run
---@field probe_error? string
---@field snapshot_ok boolean
---@field target_ok boolean
---@field parent_state "blocked"|"idle"|"busy"|"gone"|"unknown"
---@field parent_head? string
---@field base_sha? string
---@field parent_dirty_hit? boolean
---@field modified_buffers? string[]
---@field other_session? string id of a live session in the target checkout
---@field child_alive boolean
---@field attempts integer
---@field max_attempts integer
---@field auto_resolve boolean

--- Pure decision function: facts in, action out. No I/O, no config reads (the
--- caller folds the configuration into the facts), so every branch is testable.
---
--- Actions: `apply` (write), `mark_applied` (already present — record only),
--- `queue`, `resolve` (hand back to the child agent), `needs_attention`, `skip`.
---@param input table? Partial facts are allowed: every absent field falls back
---   to the documented default (see `pi.WorktreeIntegrationFacts`).
---@return { action: "apply"|"mark_applied"|"queue"|"resolve"|"needs_attention"|"skip", reason: string, retryable: boolean }
function M._decide(input)
    local facts = type(input) == "table" and input or {}
    local attempts = tonumber(facts.attempts) or 0
    local max_attempts = tonumber(facts.max_attempts) or 0

    ---@param action string
    ---@param reason string
    ---@param retryable? boolean
    local function decide(action, reason, retryable)
        return { action = action, reason = reason, retryable = retryable == true }
    end

    --- A conflict (textual clash, base drift, or a failed apply) is only ever
    --- handed back to the child agent when the user opted in, the process that
    --- owns the checkout is still alive, and the attempt budget allows it.
    ---@param reason string
    local function conflict(reason)
        if facts.auto_resolve and facts.child_alive and max_attempts > attempts then
            return decide("resolve", reason, false)
        end
        return decide("needs_attention", reason, false)
    end

    if facts.has_patch == false then
        return decide("skip", "empty", false)
    end
    if facts.snapshot_ok == false then
        return decide("needs_attention", "snapshot_missing", false)
    end
    if facts.target_ok == false then
        return decide("needs_attention", "no_target", true)
    end
    if facts.probe == "already" then
        -- Idempotency first: the patch is already in the target, so nothing
        -- else (buffers, busy parent, stale base) can make a write correct.
        return decide("mark_applied", "already_applied", false)
    end
    if facts.probe == nil then
        return decide("needs_attention", "probe_unavailable", true)
    end
    if type(facts.modified_buffers) == "table" and #facts.modified_buffers > 0 then
        return decide("needs_attention", "modified_buffer", true)
    end
    if facts.parent_dirty_hit == true then
        return decide("needs_attention", "parent_dirty", true)
    end
    if facts.probe == "conflict" then
        return conflict("patch_conflict")
    end
    if
        type(facts.base_sha) == "string"
        and facts.base_sha ~= ""
        and facts.parent_head ~= nil
        and facts.base_sha ~= facts.parent_head
    then
        -- The child's patch is anchored at an older commit: a textual apply can
        -- succeed while meaning something else. Never auto-apply across drift.
        return conflict("base_drift")
    end
    if facts.other_session ~= nil then
        return decide("queue", "other_session", true)
    end
    if facts.parent_state == "blocked" or facts.parent_state == "idle" then
        return decide("apply", "ready", false)
    end
    if facts.parent_state == "gone" then
        return decide("queue", "parent_gone", true)
    end
    return decide("queue", "parent_busy", true)
end

--- Run a closure on the main loop, exactly once.
---@param fn? function
---@return fun(...)
local function once(fn)
    local called = false
    return function(...)
        if called then
            return
        end
        called = true
        if type(fn) ~= "function" then
            return
        end
        local args = { n = select("#", ...), ... }
        vim.schedule(function()
            pcall(fn, unpack(args, 1, args.n))
        end)
    end
end

---@param parent any
---@return "blocked"|"idle"|"busy"|"gone"|"unknown"
local function parent_state(parent)
    if type(parent) ~= "table" then
        return "gone"
    end
    local rpc = parent.rpc
    if type(rpc) ~= "table" or type(rpc.is_running) ~= "function" then
        return "unknown"
    end
    if not rpc:is_running() then
        return "gone"
    end
    if M.is_waiting(parent) then
        return "blocked"
    end
    if parent._detached_busy == true then
        return "busy"
    end
    local chat = parent.chat
    if type(chat) == "table" and type(chat.is_streaming) == "function" then
        local ok, streaming = pcall(chat.is_streaming, chat)
        if ok and streaming == true then
            return "busy"
        end
    end
    return "idle"
end

--- Live session rooted in `path` (registry + running rpc), optionally skipping ids.
---@param path string?
---@param exclude? table<string, boolean>
---@return pi.Session?
local function live_session_in(path, exclude)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local S = sessions()
    for _, session in ipairs(S.list_all()) do
        if type(session) == "table" and not (exclude and exclude[session.id]) then
            local rpc = session.rpc
            local running = type(rpc) == "table" and type(rpc.is_running) == "function" and rpc:is_running()
            if running then
                local wt = session.worktree
                local wt_path = type(wt) == "table" and wt.path or nil
                if is_under(session.cwd, path) or is_under(session._process_cwd, path) or is_under(wt_path, path) then
                    return session
                end
            end
        end
    end
    return nil
end

--- A live session that may read or write the *target* checkout's working tree.
---
--- Worktree sessions are harmless (they own a separate checkout), and the child
--- whose patch is being integrated is excluded, as is the parent itself (it is
--- the caller's responsibility to have checked the parent's own state).
---@param root string
---@param exclude? table<string, boolean>
---@return pi.Session?
local function other_session_in(root, exclude)
    local S = sessions()
    for _, session in ipairs(S.list_all()) do
        if type(session) == "table" and not (exclude and exclude[session.id]) then
            local rpc = session.rpc
            local running = type(rpc) == "table" and type(rpc.is_running) == "function" and rpc:is_running()
            if running and type(session.worktree) ~= "table" then
                local cwd = session.cwd or session._process_cwd
                if
                    is_under(cwd, root)
                    and not is_under(cwd, worktrees_dir(root))
                    and not is_under(session._process_cwd, worktrees_dir(root))
                then
                    return session
                end
            end
        end
    end
    return nil
end

--- Loaded Neovim buffers with unsaved changes that the patch would overwrite.
---
--- `whole_repo` widens the check to **any** modified buffer inside the target
--- checkout. That is the safe fallback when the patch's path list could not be
--- parsed: a partial list must never make the check pass by omission.
---@param root string
---@param files string[]
---@param whole_repo? boolean
---@return string[] paths (repo-relative when the path is under the target)
local function modified_buffers(root, files, whole_repo)
    local hit = {}
    local wanted = {}
    for _, rel in ipairs(type(files) == "table" and files or {}) do
        local full = norm(root .. "/" .. tostring(rel))
        if full then
            wanted[full] = rel
        end
    end
    if whole_repo ~= true and next(wanted) == nil then
        return hit
    end
    local ok, bufs = pcall(vim.api.nvim_list_bufs)
    if not ok then
        return hit
    end
    local root_norm = norm(root) or root
    for _, buf in ipairs(bufs) do
        local modified = false
        pcall(function()
            modified = vim.bo[buf].modified == true
        end)
        if modified then
            local ok_name, name = pcall(vim.api.nvim_buf_get_name, buf)
            local full = ok_name and norm(name) or nil
            if full then
                local rel = wanted[full]
                if rel == nil and whole_repo == true and is_under(full, root_norm) then
                    rel = full:sub(#root_norm + 2)
                end
                if rel then
                    hit[#hit + 1] = rel
                end
            end
        end
    end
    return hit
end

--- Ignored content of a checkout: `--force` removal would delete it, but a patch
--- capture never includes it (only tracked + non-ignored untracked files).
---@param info table
---@param cb fun(entries: string[]) always called; non-empty means "not safe"
local function ignored_content(info, cb)
    if ignored_override then
        return ignored_override(info, cb)
    end
    local path = type(info) == "table" and info.path or nil
    if type(path) ~= "string" or path == "" then
        return cb({ "no_path" })
    end
    git({ "git", "-C", path, "status", "--porcelain", "--ignored=matching", "-z" }, path, function(code, out, err)
        if code ~= 0 then
            -- Cannot prove the checkout is disposable: fail closed.
            return cb({ "git_error: " .. tostring(err ~= "" and err or code) })
        end
        local entries = {}
        for _, chunk in ipairs(split_nul(out)) do
            if chunk:sub(1, 2) == "!!" then
                local rel = chunk:sub(4)
                if rel ~= "" and not is_under(rel, ".worktrees") then
                    entries[#entries + 1] = rel
                end
            end
        end
        cb(entries)
    end)
end

--- The captured patch for `ctx`, from the recorded snapshot or (when that file
--- is gone — a row written by another instance, a cleaned-up snapshot dir) the
--- checkout's latest snapshot. The content is always verified against
--- `patch_sha`: a drifted snapshot must never be applied.
---@param ctx { rec?: pi.WorktreeIntegration, info?: table } only these two fields are read
---@return string? patch
---@return string? path
local function resolve_snapshot(ctx)
    local rec = type(ctx.rec) == "table" and ctx.rec or {}
    local expected = type(rec.patch_sha) == "string" and rec.patch_sha or ""
    local patch = read_patch(rec.snapshot_path)
    local path = rec.snapshot_path
    if not patch then
        local Wt = worktree()
        local info = ctx.info
        if Wt and type(Wt.latest_snapshot) == "function" and type(info) == "table" then
            local ok, latest = pcall(Wt.latest_snapshot, info.repo_root, info.name)
            if ok and type(latest) == "table" and type(latest.path) == "string" then
                patch = read_patch(latest.path)
                path = latest.path
            end
        end
    end
    if type(patch) ~= "string" or patch == "" then
        return nil, path
    end
    if expected ~= "" and sha_of(patch) ~= expected then
        return nil, path
    end
    return patch, path
end

--- Target checkout HEAD, preferring the worktree API over a raw git call.
---@param root string
---@param cb fun(head: string?, target_ok: boolean)
local function target_head(root, cb)
    local Wt = worktree()
    if Wt and type(Wt.detect) == "function" and type(Wt.status) == "function" then
        local ok, info = pcall(Wt.detect, root)
        if ok and type(info) == "table" then
            local ok2 = pcall(Wt.status, info, function(status)
                local head = type(status) == "table" and status.head or nil
                cb(type(head) == "string" and head ~= "" and head or nil, true)
            end)
            if ok2 then
                return
            end
        end
    end
    git({ "git", "-C", root, "rev-parse", "HEAD" }, root, function(code, out)
        if code ~= 0 then
            return cb(nil, false)
        end
        local head = vim.trim(out or "")
        cb(head ~= "" and head or nil, true)
    end)
end

--- Probe the target for the patch's three-way relationship.
---@param root string
---@param patch string
---@param cb fun(kind: "clean"|"already"|"conflict"|nil, err: string?)
local function probe(root, patch, cb)
    local Wt = worktree()
    if not Wt or type(Wt.probe) ~= "function" then
        return cb(nil, "worktree probe unavailable")
    end
    local ok, err = pcall(Wt.probe, root, patch, function(kind, probe_err)
        if kind == "clean" or kind == "already" or kind == "conflict" then
            return cb(kind, nil)
        end
        cb(nil, probe_err or ("probe returned " .. tostring(kind)))
    end)
    if not ok then
        cb(nil, tostring(err))
    end
end

--- HEAD commit of a worktree checkout, when the module can report it.
---@param Wt table?
---@param info table?
---@param cb fun(head: string?)
local function head_of(Wt, info, cb)
    if not Wt or type(Wt.status) ~= "function" or type(info) ~= "table" then
        return cb(nil)
    end
    local ok = pcall(Wt.status, info, function(status)
        local head = type(status) == "table" and status.head or nil
        cb(type(head) == "string" and head ~= "" and head or nil)
    end)
    if not ok then
        cb(nil)
    end
end

--- Re-capture a checkout and compare it with the patch that was integrated.
---
--- This is the guard that keeps a **background writer** from being deleted: a
--- checkout can change after the capture (a revived child, a resolving round, a
--- stray process), and deleting it would destroy that work. `ok == false` with
--- `checkout_changed` means "the checkout holds more than what was integrated".
---@param info table
---@param rec table
---@param cb fun(ok: boolean, reason: string?)
local function checkout_matches(info, rec, cb)
    local Wt = worktree()
    if not Wt or type(Wt.diff) ~= "function" then
        return cb(false, "diff_unavailable")
    end
    local expected = type(rec.patch_sha) == "string" and rec.patch_sha or ""
    if expected == "" then
        return cb(false, "diff_unverified")
    end
    local opts = nil
    if type(rec.from_sha) == "string" and rec.from_sha ~= "" then
        opts = { from = rec.from_sha }
    end
    local ok = pcall(Wt.diff, info, function(patch)
        vim.schedule(function()
            if type(patch) ~= "string" then
                return cb(false, "rediff_failed")
            end
            if sha_of(patch) ~= expected then
                return cb(false, "checkout_changed")
            end
            cb(true, nil)
        end)
    end, opts)
    if not ok then
        cb(false, "rediff_failed")
    end
end

--- Reason that makes a write unsafe **right now**, or nil.
---
--- The facts `M._decide` saw were gathered before a probe round-trip; the parent
--- can start a turn (or the user can start editing) in that window. Re-checked
--- immediately before `git apply`, never after.
---@param ctx pi.WorktreeIntegrationContext
---@return string? reason
local function prewrite_blocker(ctx)
    local state = parent_state(ctx.parent)
    if state == "gone" then
        return "parent_gone"
    end
    if state ~= "blocked" and state ~= "idle" then
        return "parent_busy"
    end
    local excluded = { [ctx.child_id] = true }
    if type(ctx.parent) == "table" and type(ctx.parent.id) == "string" then
        excluded[ctx.parent.id] = true
    end
    if other_session_in(ctx.root, excluded) then
        return "other_session"
    end
    local files = type(ctx.rec) == "table" and ctx.rec.files or {}
    local whole = type(ctx.rec) == "table" and ctx.rec.files_complete == false
    if #modified_buffers(ctx.root, files, whole) > 0 then
        return "modified_buffer"
    end
    return nil
end

-- Notifications --------------------------------------------------------------

--- Short checkbox label for UI text.
---@param ctx table
---@return string
local function label(ctx)
    local info = type(ctx) == "table" and ctx.info or nil
    local name = type(info) == "table" and info.name or nil
    if type(name) ~= "string" or name == "" then
        name = "worktree"
    end
    return name
end

---@param ctx table
---@return string
local function file_count(ctx)
    local files = type(ctx) == "table" and type(ctx.rec) == "table" and ctx.rec.files or {}
    return tostring(type(files) == "table" and #files or 0)
end

---@param text string
---@param level integer
---@param ctx? table
local function notify(text, level, ctx)
    local parent = type(ctx) == "table" and ctx.parent or nil
    local chat = type(parent) == "table" and parent.chat or nil
    if type(chat) == "table" and type(chat.show_worktree_integration) == "function" then
        local ok = pcall(chat.show_worktree_integration, chat, text)
        if ok then
            return
        end
    end
    if level >= vim.log.levels.WARN and type(parent) == "table" then
        local ok, Attention = pcall(require, "pi.attention")
        if ok and type(Attention) == "table" and type(Attention.notify) == "function" then
            local ok2 = pcall(Attention.notify, parent.attached_tab, text, level)
            if ok2 then
                return
            end
        end
    end
    local ok, Notify = pcall(require, "pi.notify")
    if ok and type(Notify) == "table" then
        local level_name = level == vim.log.levels.ERROR and "error"
            or (level == vim.log.levels.WARN and "warn" or "info")
        local fn = Notify[level_name]
        if type(fn) == "function" then
            pcall(fn, "󰙅 " .. text)
            return
        end
    end
    pcall(vim.notify, text, level)
end

-- Worktrees cache ------------------------------------------------------------

--- Merge freshly detected metadata into a recorded worktree info: a resolving
--- agent may have rebased the checkout and rewritten its `base_sha`, and
--- capturing against the recorded (stale) base would produce a reversed patch.
---@param Wt table
---@param info table
---@return table
local function refresh_info(Wt, info)
    if type(info) ~= "table" or type(info.path) ~= "string" then
        return info
    end
    if type(Wt.detect) ~= "function" then
        return info
    end
    local ok, fresh = pcall(Wt.detect, info.path)
    if ok and type(fresh) == "table" and fresh.kind == "linked" then
        local out = {}
        for k, v in pairs(info) do
            out[k] = v
        end
        for k, v in pairs(fresh) do
            if v ~= nil then
                out[k] = v
            end
        end
        return out
    end
    return info
end

-- Repository queue -----------------------------------------------------------
--
-- `git apply` takes no lock on the working tree, so every write into one target
-- checkout is serialized here. Keyed by `repo_root`, never by parent session: two
-- parents may share the same checkout.

---@type table<string, { busy: boolean, queue: { child_id: string, cwd: string }[] }>
local repos = {}

--- Normalized queue/lock key of a target checkout.
---
--- The key is captured **once**, when the lock is taken, and every later release
--- or drain uses that same key. `attempt` may re-resolve the parent and end up
--- with a different `ctx.root` (the parent was not registered when the item was
--- queued); releasing under the new key would leave the original queue busy
--- forever — a leaked lock that silently stops all later integrations.
---@param root any
---@return string?
local function lock_key(root)
    local key = norm(root)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    return key
end

---@param key string
---@return { busy: boolean, queue: { child_id: string, cwd: string }[] }
local function repo_state(key)
    local state = repos[key]
    if not state then
        state = { busy = false, queue = {} }
        repos[key] = state
    end
    return state
end

--- Take the per-checkout lock. Returns the key to release, or nil when it is
--- already held (the caller must then queue instead of applying).
---@param root any
---@return string? key
local function acquire_lock(root)
    local key = lock_key(root)
    if not key then
        return nil
    end
    local state = repo_state(key)
    if state.busy then
        return nil
    end
    state.busy = true
    return key
end

--- Release a lock taken by `acquire_lock` / `M._drain`.
---@param key any
local function release_lock(key)
    local k = type(key) == "string" and key or nil
    if not k then
        return
    end
    local state = repos[k]
    if state then
        state.busy = false
    end
end

---@param root any
---@param child_id string
---@param cwd string
---@return boolean added
local function enqueue(root, child_id, cwd)
    local key = lock_key(root)
    if not key or type(child_id) ~= "string" or child_id == "" then
        return false
    end
    local state = repo_state(key)
    for _, item in ipairs(state.queue) do
        if item.child_id == child_id then
            return false
        end
    end
    state.queue[#state.queue + 1] = { child_id = child_id, cwd = cwd }
    return true
end

--- One integration attempt.
---@class pi.WorktreeIntegrationContext
---@field child_id string
---@field cwd string owning workspace (the manifest file that holds the row)
---@field root string target checkout (the parent's cwd)
---@field parent? pi.Session
---@field child? pi.Session
---@field entry? table
---@field rec? pi.WorktreeIntegration
---@field info? table
---@field patch? string
---@field from_queue boolean
---@field lock_root? string normalized queue/lock key this attempt holds (captured at acquisition)

--- Resolve a context from the manifest.
---@param child_id string
---@param cwd? string
---@param opts? { child?: pi.Session, parent?: pi.Session, patch?: string, from_queue?: boolean }
---@return pi.WorktreeIntegrationContext?
local function load_ctx(child_id, cwd, opts)
    opts = opts or {}
    local Manifest = manifest()
    local S = sessions()
    local entry, workspace = row_of(child_id, cwd)
    if type(entry) ~= "table" then
        return nil
    end
    workspace = workspace or cwd
    local child = opts.child or S.get_by_id(child_id)
    local parent = opts.parent
    if type(parent) ~= "table" and type(entry.parent_id) == "string" then
        local ok, found = pcall(S.find_by_lineage, entry.parent_id)
        parent = ok and found or nil
    end
    local info = type(entry.worktree) == "table" and entry.worktree or nil
    local root = nil
    if type(parent) == "table" then
        root = norm(parent.cwd) or parent.cwd
    end
    if type(root) ~= "string" or root == "" then
        root = type(info) == "table" and info.repo_root or nil
    end
    if type(root) ~= "string" or root == "" then
        root = Manifest.workspace(parent) or workspace
    end
    local rec = record_of(entry)
    return {
        child_id = child_id,
        cwd = workspace,
        root = root or vim.fn.getcwd(),
        parent = type(parent) == "table" and parent or nil,
        child = type(child) == "table" and child or nil,
        entry = entry,
        rec = rec,
        info = info,
        patch = opts.patch,
        from_queue = opts.from_queue == true,
    }
end

--- Merge the patch's files into the parent session's `changed_files` so
--- `:PiDiff` and the sessions list see what the integration wrote.
---@param parent any
---@param root string
---@param files string[]
local function merge_changed_files(parent, root, files)
    if type(parent) ~= "table" or type(parent.changed_files) ~= "table" then
        return
    end
    for _, rel in ipairs(files or {}) do
        if type(rel) == "string" and rel ~= "" then
            parent.changed_files[norm(root .. "/" .. rel) or (root .. "/" .. rel)] = true
        end
    end
end

--- Drop a removed checkout from every live session so nothing later tries to
--- release or badge a directory that no longer exists (ghost worktree).
---@param info table
local function forget_sessions(info)
    local path = type(info) == "table" and info.path or nil
    if type(path) ~= "string" or path == "" then
        return
    end
    local S = sessions()
    for _, session in ipairs(S.list_all()) do
        local wt = type(session) == "table" and session.worktree or nil
        if type(wt) == "table" and norm(wt.path) == norm(path) then
            session.worktree = nil
            session._worktree_released = true
        end
    end
end

-- Terminal transitions ------------------------------------------------------

--- Descending `finish` plus a notification; every terminal path goes through here.
---@param ctx pi.WorktreeIntegrationContext
---@param finish fun(...)
---@param kind string
---@param fields table
---@param text string
---@param level integer
local function settle(ctx, finish, kind, fields, text, level)
    ctx.rec = merged(ctx.rec, fields)
    persist(ctx.child_id, ctx.cwd, ctx.rec)
    if text and text ~= "" then
        notify(text, level, ctx)
    end
    finish(kind, ctx.rec)
end

--- Forward declaration: `mark_applied` confirms the write and then hands off to
--- the disposal checks, which live below it (and are mutually recursive with
--- `keep_checkout`).
---@type fun(ctx: pi.WorktreeIntegrationContext, finish: fun(...))
local detach

--- The patch is confirmed present in the target: record it, tell the parent
--- which files changed, then try to dispose of the checkout.
---@param ctx pi.WorktreeIntegrationContext
---@param finish fun(...)
---@param decision_reason? string why the patch is considered applied (`already_applied` when the probe short-circuited)
local function mark_applied(ctx, finish, decision_reason)
    local reason = decision_reason == "already_applied" and "already_applied" or "applied"
    ctx.rec = merged(ctx.rec, {
        state = "applied",
        applied_at = manifest().iso_now(),
        error = "",
        reason = reason,
    })
    persist(ctx.child_id, ctx.cwd, ctx.rec)
    merge_changed_files(ctx.parent, ctx.root, ctx.rec.files)
    detach(ctx, finish)
end

--- Keep the checkout and say why: applied work is in the target, but deleting
--- this directory would lose something the patch does not carry.
---@param ctx pi.WorktreeIntegrationContext
---@param reason string
---@param finish fun(...)
local function keep_checkout(ctx, reason, finish)
    local text = string.format("%s → applied %s file(s) · checkout kept (%s)", label(ctx), file_count(ctx), reason)
    settle(ctx, finish, "applied_kept", { kept_reason = reason }, text, vim.log.levels.INFO)
end

--- Close the settled child process so its checkout can be deleted safely.
---
--- A settled child keeps its `pi --mode rpc` process alive for reuse, and a
--- revived child may reuse that process **without** spawning a new checkout —
--- so deleting a directory a live process is rooted in would break the child's
--- next tool call. Closing it here is what makes the removal safe: a later
--- revive starts in the parent's workspace cwd (the recorded path is gone),
--- and `close` refuses while the engine owns
--- the row, so this never races a concurrent decision.
---
--- Refused when a tab is currently showing the child (same rule as the idle
--- reaper): the user is looking at it, so the checkout stays.
---@param ctx pi.WorktreeIntegrationContext
---@param cb fun(ready: boolean)
---@return nil
local function quiesce_child(ctx, cb)
    local child = ctx.child
    if type(child) ~= "table" then
        return cb(true)
    end
    local child_rpc = child.rpc --[[@as table?]]
    if type(child_rpc) ~= "table" or type(child_rpc.is_running) ~= "function" or child_rpc:is_running() ~= true then
        return cb(true)
    end
    if child.attached_tab ~= nil then
        return cb(false)
    end
    local ok, Sub = pcall(require, "pi.subsessions")
    if not ok or type(Sub) ~= "table" or type(Sub.close) ~= "function" then
        return cb(false)
    end
    local done = false
    ---@param ready boolean
    local function settle_ready(ready)
        if done then
            return
        end
        done = true
        cb(ready == true)
    end
    local ok_close = pcall(Sub.close, ctx.child_id, function(closed)
        vim.schedule(function()
            settle_ready(closed == true)
        end)
    end)
    if not ok_close then
        return settle_ready(false)
    end
end

--- Delete the child checkout when (and only when) nothing is lost by doing so.
---@param ctx pi.WorktreeIntegrationContext
---@param finish fun(...)
detach = function(ctx, finish)
    local info = ctx.info
    local path = type(info) == "table" and info.path or nil
    if type(path) ~= "string" or path == "" or vim.fn.isdirectory(path) ~= 1 then
        local text = string.format("%s → applied %s file(s)", label(ctx), file_count(ctx))
        return settle(ctx, finish, "applied", { kept_reason = "" }, text, vim.log.levels.INFO)
    end
    local Wt = worktree()
    if not Wt or type(Wt.remove) ~= "function" then
        return keep_checkout(ctx, "remove_unavailable", finish)
    end

    -- Fire-time re-checks: the row may have moved on (a revived run owns the
    -- checkout now) and the snapshot is the only copy left once the directory
    -- is gone.
    local row = row_of(ctx.child_id, ctx.cwd)
    local generation = type(row) == "table" and row.run_generation or nil
    -- Always a table: the record is read field-by-field below, and a removed
    -- checkout must never make this path decide on a nil record.
    local rec = record_of(row) or ctx.rec or merged(nil, {})
    ctx.rec = rec
    if type(generation) == "number" and type(rec.run_generation) == "number" and generation ~= rec.run_generation then
        return keep_checkout(ctx, "generation_changed", finish)
    end
    if type(rec.snapshot_path) ~= "string" or vim.fn.filereadable(rec.snapshot_path) ~= 1 then
        return keep_checkout(ctx, "snapshot_missing", finish)
    end
    -- Any *other* live session rooted in the checkout blocks the delete; the
    -- child itself is handled by `quiesce_child` below.
    local other = live_session_in(path, { [ctx.child_id] = true })
    if other then
        return keep_checkout(ctx, "live_session", finish)
    end
    local wt_info = info --[[@as table]]
    ignored_content(wt_info, function(entries)
        if type(entries) == "table" and #entries > 0 then
            return keep_checkout(ctx, "ignored", finish)
        end
        quiesce_child(ctx, function(ready)
            if not ready then
                return keep_checkout(ctx, "live_session", finish)
            end
            -- Closing the process opens a window in which the parent could
            -- revive the child (reusing the still-present checkout). Re-check
            -- the generation immediately before the destructive call.
            local row_now = row_of(ctx.child_id, ctx.cwd)
            local gen_now = type(row_now) == "table" and row_now.run_generation or nil
            if
                type(gen_now) == "number"
                and type(ctx.rec.run_generation) == "number"
                and gen_now ~= ctx.rec.run_generation
            then
                return keep_checkout(ctx, "generation_changed", finish)
            end
            -- The checkout must still hold *exactly* the patch we integrated.
            -- Anything else means a background writer added work after the
            -- capture (a revived child, a resolving round, a stray process) and
            -- deleting it would destroy that work.
            checkout_matches(wt_info, ctx.rec, function(match_ok, match_reason)
                if not match_ok then
                    return keep_checkout(ctx, match_reason or "checkout_changed", finish)
                end
                local ok, err = pcall(
                    Wt.remove,
                    wt_info,
                    { force = true, snapshot = false },
                    function(removed, remove_err)
                        vim.schedule(function()
                            if not removed then
                                ctx.rec = merged(ctx.rec, { error = tostring(remove_err or "remove failed") })
                                return keep_checkout(ctx, "remove_failed", finish)
                            end
                            forget_sessions(wt_info)
                            ctx.rec = merged(ctx.rec, {
                                kept_reason = "",
                                archived = true,
                                archived_at = manifest().iso_now(),
                                worktree_removed = true,
                                error = "",
                            })
                            local text = string.format(
                                "%s → applied %s file(s) · checkout removed (snapshot kept)",
                                label(ctx),
                                file_count(ctx)
                            )
                            settle(ctx, finish, "applied", { state = "applied" }, text, vim.log.levels.INFO)
                        end)
                    end
                )
                if not ok then
                    ctx.rec = merged(ctx.rec, { error = tostring(err) })
                    keep_checkout(ctx, "remove_failed", finish)
                end
            end)
        end)
    end)
end

--- Stop and surface: a human decision is required.
---@param ctx pi.WorktreeIntegrationContext
---@param reason string
---@param err string?
---@param finish fun(...)
local function needs_attention(ctx, reason, err, finish)
    local detail = type(err) == "string" and vim.trim(err) or ""
    detail = detail:gsub("%s+", " ")
    if #detail > 160 then
        detail = detail:sub(1, 157) .. "..."
    end
    local text = string.format(
        "%s → needs attention: %s%s",
        label(ctx),
        reason,
        detail ~= "" and (" (" .. detail .. ")") or ""
    )
    settle(
        ctx,
        finish,
        "needs_attention",
        { state = "needs_attention", reason = reason, error = detail },
        text,
        vim.log.levels.ERROR
    )
end

--- Park the patch until a safe window.
---
--- Deliberately does not enqueue: `queued` is a persisted state and the trigger
--- that opens a safe window is the parent becoming ready, so `on_parent_ready`
--- re-enqueues. Enqueuing here would retry the same decision immediately from
--- the drain loop (the item is popped again the moment `attempt` releases the
--- lock), doubling every probe for no benefit.
---@param ctx pi.WorktreeIntegrationContext
---@param reason string
---@param finish fun(...)
local function park(ctx, reason, finish)
    local text = ""
    if not QUIET[reason] then
        text = string.format("%s → queued (%s)", label(ctx), reason)
    end
    settle(ctx, finish, "queued", { state = "queued", reason = reason, error = "" }, text, vim.log.levels.INFO)
end

--- Prompt the (reused) child agent to rebase/resolve in its own checkout.
---
--- Reports a real failure: `rpc.send` returns `false` when the process is gone
--- or the command cannot be encoded, and throws when the client is unusable. A
--- prompt that never reached the child must not leave the row in `resolving`
--- (nothing would ever move it again).
---@param ctx pi.WorktreeIntegrationContext
---@return boolean sent
---@return string? err
local function send_resolve_prompt(ctx)
    local child = ctx.child
    local rpc = type(child) == "table" and child.rpc or nil
    if type(rpc) ~= "table" or type(rpc.send) ~= "function" then
        return false
    end
    local okr, running = pcall(rpc.is_running, rpc)
    if not okr or running ~= true then
        return false
    end
    local path = type(ctx.info) == "table" and ctx.info.path or "your worktree"
    local parent_cwd = ctx.root
    local parent_head = tostring(ctx.rec and ctx.rec.parent_head or "unknown")
    local base = tostring(ctx.rec and ctx.rec.base_sha or "unknown")
    local message = table.concat({
        "[Automatic worktree integration] Your patch could not be applied to the parent checkout.",
        "",
        "Your checkout: " .. tostring(path),
        "Parent checkout: " .. tostring(parent_cwd) .. " (HEAD " .. parent_head .. ")",
        "Your base commit: " .. base,
        "",
        "Do this, working only inside your own checkout:",
        "1. Rebase your work onto the parent's current HEAD commit.",
        "2. Resolve every conflict in your checkout.",
        "3. Run the project's tests there.",
        "4. Reply with a short report: rebase result, conflicts resolved, test output summary.",
        "",
        "Do not touch the parent checkout, do not commit or push, do not create nested worktrees or sub-sessions.",
    }, "\n")
    local call_ok, sent = pcall(rpc.send, rpc, { type = "prompt", message = message }, function() end)
    if not call_ok then
        return false, tostring(sent)
    end
    if sent == false then
        return false, "rpc.send refused the resolving prompt"
    end
    return true, nil
end

--- Hand a conflict back to the child agent when allowed, else stop.
---@param ctx pi.WorktreeIntegrationContext
---@param reason string
---@param err string?
---@param finish fun(...)
local function on_conflict(ctx, reason, err, finish)
    local conf = cfg()
    local rec = ctx.rec or merged(nil, {})
    local decision = M._decide({
        has_patch = true,
        snapshot_ok = true,
        target_ok = true,
        probe = "conflict",
        parent_state = "unknown",
        attempts = rec.attempts,
        max_attempts = conf.max_attempts,
        auto_resolve = conf.auto_resolve,
        child_alive = type(ctx.child) == "table" and ctx.child.rpc ~= nil and ctx.child.rpc:is_running() == true,
    })
    if decision.action ~= "resolve" then
        return needs_attention(ctx, reason, err, finish)
    end
    local sent, send_err = send_resolve_prompt(ctx)
    if not sent then
        return needs_attention(ctx, "resolve_failed", send_err or "could not prompt the child agent", finish)
    end
    local attempts = (tonumber(rec.attempts) or 0) + 1
    local text =
        string.format("%s → resolving in its checkout (attempt %d/%d)", label(ctx), attempts, conf.max_attempts)
    settle(
        ctx,
        finish,
        "resolving",
        { state = "resolving", reason = reason, error = "", attempts = attempts },
        text,
        vim.log.levels.WARN
    )
end

-- Gathering + execution ------------------------------------------------------

--- Collect every fact `M._decide` needs.
---@param ctx pi.WorktreeIntegrationContext
---@param cb fun(facts: pi.WorktreeIntegrationFacts)
local function gather(ctx, cb)
    local conf = cfg()
    local excluded = {}
    if type(ctx.parent) == "table" and type(ctx.parent.id) == "string" then
        excluded[ctx.parent.id] = true
    end
    excluded[ctx.child_id] = true

    local files = type(ctx.rec) == "table" and ctx.rec.files or {}
    local complete = not (type(ctx.rec) == "table" and ctx.rec.files_complete == false)
    -- Fail closed: an unparsed (or empty while the patch is not) path list means
    -- "we do not know which files this touches", so check the whole checkout.
    local whole_repo = (not complete) or (#files == 0 and type(ctx.patch) == "string" and ctx.patch ~= "")
    local facts = {
        has_patch = type(ctx.patch) == "string" and ctx.patch ~= "",
        snapshot_ok = type(ctx.rec) == "table" and type(ctx.rec.snapshot_path) == "string" and vim.fn.filereadable(
            ctx.rec.snapshot_path
        ) == 1,
        target_ok = true,
        parent_state = parent_state(ctx.parent),
        base_sha = type(ctx.rec) == "table" and ctx.rec.base_sha or nil,
        modified_buffers = modified_buffers(ctx.root, files, whole_repo),
        child_alive = type(ctx.child) == "table"
            and type(ctx.child.rpc) == "table"
            and ctx.child.rpc:is_running() == true,
        attempts = type(ctx.rec) == "table" and (tonumber(ctx.rec.attempts) or 0) or 0,
        max_attempts = conf.max_attempts,
        auto_resolve = conf.auto_resolve,
    }
    local other = other_session_in(ctx.root, excluded)
    if other then
        facts.other_session = tostring(other.id)
    end

    target_head(ctx.root, function(head, target_ok)
        facts.parent_head = head
        facts.target_ok = target_ok == true
        if type(ctx.patch) ~= "string" or ctx.patch == "" then
            return cb(facts)
        end
        probe(ctx.root, ctx.patch, function(kind, err)
            facts.probe = kind
            facts.probe_error = err
            cb(facts)
        end)
    end)
end

--- Apply the patch, then prove it landed before recording `applied`.
---@param ctx pi.WorktreeIntegrationContext
---@param finish fun(...)
local function do_apply(ctx, finish)
    local Wt = worktree()
    if not Wt or type(Wt.apply_patch) ~= "function" then
        return needs_attention(ctx, "apply_unavailable", "pi.worktree.apply_patch is missing", finish)
    end
    -- The decision was made after an async probe round-trip. Re-check the
    -- safety facts right here: the parent may have started a turn, another
    -- session may have appeared, or the user may have begun editing a file the
    -- patch writes. Parking is always safe; writing underneath a live agent is
    -- not recoverable.
    local blocker = prewrite_blocker(ctx)
    if blocker == "modified_buffer" then
        return needs_attention(ctx, blocker, "a buffer with unsaved changes covers a patched file", finish)
    end
    if blocker then
        return park(ctx, blocker, finish)
    end
    ctx.rec = merged(ctx.rec, { state = "applying", reason = "applying", error = "" })
    persist(ctx.child_id, ctx.cwd, ctx.rec)
    local ok, err = pcall(Wt.apply_patch, ctx.root, ctx.patch, function(applied, apply_err)
        vim.schedule(function()
            if not applied then
                return on_conflict(ctx, "apply_failed", apply_err, finish)
            end
            -- Self-verification: the only proof that the write is complete.
            probe(ctx.root, ctx.patch, function(kind, probe_err)
                if kind ~= "already" then
                    return needs_attention(
                        ctx,
                        "verify_failed",
                        probe_err or ("patch is not present in " .. tostring(ctx.root)),
                        finish
                    )
                end
                mark_applied(ctx, finish)
            end)
        end)
    end)
    if not ok then
        needs_attention(ctx, "apply_failed", tostring(err), finish)
    end
end

--- Execute one decision for `ctx`.
---@param ctx pi.WorktreeIntegrationContext
---@param facts pi.WorktreeIntegrationFacts
---@param finish fun(...)
local function execute(ctx, facts, finish)
    -- Keep the target HEAD with the record: it documents which commit the patch
    -- was judged against and feeds the resolving prompt.
    if type(facts.parent_head) == "string" and facts.parent_head ~= "" then
        ctx.rec = merged(ctx.rec, { parent_head = facts.parent_head })
        persist(ctx.child_id, ctx.cwd, ctx.rec)
    end
    local decision = M._decide(facts)
    if decision.action == "skip" then
        return finish("skipped")
    end
    if decision.action == "mark_applied" then
        return mark_applied(ctx, finish, decision.reason)
    end
    if decision.action == "queue" then
        return park(ctx, decision.reason, finish)
    end
    if decision.action == "resolve" then
        return on_conflict(ctx, decision.reason, nil, finish)
    end
    if decision.action == "needs_attention" then
        return needs_attention(ctx, decision.reason, facts.probe_error, finish)
    end
    do_apply(ctx, finish)
end

--- One queued/attempted integration, serialized per target checkout.
---@param ctx pi.WorktreeIntegrationContext
---@param finish fun(...)
local function attempt(ctx, finish)
    local done = once(function(...)
        -- Release and drain under the key captured when the lock was taken: the
        -- attempt may have re-resolved the parent into a different directory,
        -- and unlocking the new key would leak the original one.
        local key = ctx.lock_root or lock_key(ctx.root)
        release_lock(key)
        -- Preserve the first two values (kind, record) for the caller.
        finish(...)
        if key then
            vim.schedule(function()
                M._drain(key)
            end)
        end
    end)

    local row, workspace = row_of(ctx.child_id, ctx.cwd)
    if type(row) ~= "table" then
        return done("no_entry")
    end
    ctx.cwd = workspace or ctx.cwd
    ctx.entry = row
    ctx.rec = record_of(row) or ctx.rec or merged(nil, {})
    local info = type(row.worktree) == "table" and row.worktree or ctx.info
    local Wt = worktree()
    if type(info) ~= "table" or type(info.path) ~= "string" or vim.fn.isdirectory(info.path) ~= 1 then
        -- No checkout: either it was already integrated and disposed of, or the
        -- work is gone. Neither can be integrated from here.
        if type(ctx.rec) == "table" and ctx.rec.state == "applied" then
            return done("applied", ctx.rec)
        end
        return done("no_worktree")
    end
    ctx.info = Wt and refresh_info(Wt, info) or info
    if not ctx.parent then
        local S = sessions()
        ctx.parent = type(row.parent_id) == "string" and S.find_by_lineage(row.parent_id) or nil
        if type(ctx.parent) == "table" then
            ctx.root = norm(ctx.parent.cwd) or ctx.root
        end
    end

    local patch = ctx.patch
    if type(patch) ~= "string" or patch == "" then
        patch, ctx.rec.snapshot_path = resolve_snapshot(ctx)
        if type(patch) ~= "string" or patch == "" then
            return needs_attention(ctx, "snapshot_missing", "no snapshot patch to apply", done)
        end
    end
    ctx.patch = patch
    gather(ctx, function(facts)
        execute(ctx, facts, done)
    end)
end

--- Pop and run the next item for one target checkout.
---@param root string
function M._drain(root)
    local key = lock_key(root)
    if not key then
        return
    end
    local state = repo_state(key)
    if state.busy then
        return
    end
    local item = table.remove(state.queue, 1)
    if not item then
        return
    end
    state.busy = true
    local ctx = load_ctx(item.child_id, item.cwd, { from_queue = true })
    if not ctx then
        release_lock(key)
        vim.schedule(function()
            M._drain(key)
        end)
        return
    end
    -- The queue key is authoritative for locking, even when the context resolves
    -- a different target root.
    ctx.lock_root = key
    ctx.root = key
    -- An engine error must never wedge the per-target lock: release it and let
    -- the next readiness signal retry.
    local ok, err = pcall(attempt, ctx, function() end)
    if not ok then
        release_lock(key)
        notify(("worktree integration failed: %s"):format(tostring(err)), vim.log.levels.ERROR, ctx)
    end
end

-- Public API -----------------------------------------------------------------

--- Whether `parent` is currently blocked inside a `wait_subagents` request.
--- Delegates to `pi.subsessions.batch.is_waiting` when that seam exists; an
--- absent seam degrades to `false`, which only ever delays integration.
---@param parent any
---@return boolean
function M.is_waiting(parent)
    if type(parent) ~= "table" then
        return false
    end
    -- The sub-session layer keeps a depth counter on the parent while it is
    -- blocked in a wait; that marker is authoritative (it also covers a wait
    -- that has not registered a batch waiter yet).
    local ok_sub, Sub = pcall(require, "pi.subsessions")
    if ok_sub and type(Sub) == "table" and type(Sub.parent_waiting) == "function" then
        local ok_m, waiting = pcall(Sub.parent_waiting, parent)
        if ok_m and waiting == true then
            return true
        end
    end
    local ok, Batch = pcall(require, "pi.subsessions.batch")
    if not ok or type(Batch) ~= "table" or type(Batch.is_waiting) ~= "function" then
        return false
    end
    local Manifest = manifest()
    local cwd = Manifest.workspace(parent) or parent.cwd
    local lineage = ""
    local ok_l, value = pcall(Manifest.lineage_for_session, parent, cwd)
    if ok_l and type(value) == "string" then
        lineage = value
    end
    if lineage == "" then
        lineage = type(parent.id) == "string" and parent.id or ""
    end
    local ok2, waiting = pcall(Batch.is_waiting, cwd, lineage)
    return ok2 and waiting == true
end
---@class pi.WorktreeIntegrationPlan
---@field from? string diff base for an incremental capture (nil = the checkout base)

--- Decide how a *new* run on an already integrated checkout is captured.
---
--- Two shapes are trustworthy:
---
--- * `{ from = nil }` — the checkout's **base changed** (a fresh checkout, or a
---   rebased one). Its base already contains the applied work, so a plain
---   base→now diff *is* the delta.
--- * `{ from = head_sha }` — the same checkout, and the previous round was
---   committed there. Diffing from that commit yields only what came after it,
---   so the old patch is not replayed.
---
--- Anything else returns `nil, reason`: replaying the previous patch would be
--- worse than stopping, and there is no other anchor to diff against.
---@param child_id string
---@param cwd string
---@param rec pi.WorktreeIntegration
---@param cb fun(plan: pi.WorktreeIntegrationPlan?, err: string?)
local function delta_plan(child_id, cwd, rec, cb)
    local Wt = worktree()
    local row = row_of(child_id, cwd)
    local info = type(row) == "table" and type(row.worktree) == "table" and row.worktree or nil
    if not Wt or type(info) ~= "table" or type(info.path) ~= "string" or vim.fn.isdirectory(info.path) ~= 1 then
        return cb(nil, "the child checkout is gone")
    end
    local fresh = refresh_info(Wt, info)
    local prev_head = type(rec.head_sha) == "string" and rec.head_sha ~= "" and rec.head_sha or nil
    local prev_base = type(rec.base_sha) == "string" and rec.base_sha ~= "" and rec.base_sha or nil
    if not prev_head then
        return cb(nil, "the previous capture recorded no head commit")
    end
    local base = type(fresh.base_sha) == "string" and fresh.base_sha ~= "" and fresh.base_sha or nil
    if base and prev_base and base ~= prev_base then
        -- New or rebased checkout: its own base already excludes the applied work.
        return cb({ from = nil }, nil)
    end
    if prev_head == prev_base then
        -- The previous round's work was still uncommitted at capture time, so a
        -- diff from the base would replay it and there is no other anchor.
        return cb(
            nil,
            "the previously integrated changes are still uncommitted in the checkout; commit them or start a fresh checkout"
        )
    end
    -- Same checkout, previous work committed: only what came after the recorded
    -- head is new. Confirm the old post-image is still present first, so a rewind
    -- is not mistaken for new work.
    ---@type { rec: pi.WorktreeIntegration, info: table }
    local snapshot_ctx = { rec = rec, info = fresh }
    local old_patch = resolve_snapshot(snapshot_ctx)
    if type(old_patch) ~= "string" or old_patch == "" then
        return cb(nil, "the previous patch snapshot is unavailable")
    end
    probe(fresh.path, old_patch, function(kind)
        if kind ~= "already" then
            return cb(nil, "the checkout no longer contains the previously integrated changes")
        end
        cb({ from = prev_head }, nil)
    end)
end

--- Capture the checkout's patch (and a durable snapshot) and start integrating.
---
--- `opts.from` makes this an **incremental** capture: the diff starts at that
--- commit instead of the checkout base, so a reused, already integrated checkout
--- contributes only its new work.
---@param child pi.Session
---@param child_id string
---@param cwd string
---@param rec pi.WorktreeIntegration? previous record (nil on the first capture)
---@param generation integer?
---@param finish fun(...)
---@param opts? pi.WorktreeIntegrationPlan
local function capture_and_integrate(child, child_id, cwd, rec, generation, finish, opts)
    opts = opts or {}
    local Wt = worktree()
    if not Wt or type(Wt.diff) ~= "function" then
        return finish("worktree_missing")
    end
    local row, workspace = row_of(child_id, cwd)
    if type(row) ~= "table" then
        return finish("no_entry")
    end
    cwd = workspace or cwd
    local info = type(row.worktree) == "table" and row.worktree or nil
    if type(info) ~= "table" or type(info.path) ~= "string" or vim.fn.isdirectory(info.path) ~= 1 then
        return finish("no_worktree")
    end
    local fresh = refresh_info(Wt, info)
    local from = type(opts.from) == "string" and opts.from ~= "" and opts.from or nil
    local diff_opts = from and { from = from } or nil

    Wt.diff(fresh, function(patch, diff_err)
        vim.schedule(function()
            local ctx = load_ctx(child_id, cwd, { child = child })
            if not ctx then
                return finish("no_entry")
            end
            ctx.info = fresh
            if type(patch) ~= "string" then
                -- Capture is all-or-nothing: a partial patch would be worse than
                -- none, and the failure is deterministic (nested repo, >20k
                -- untracked files), so retrying it is pointless.
                return needs_attention(ctx, "capture_failed", diff_err, finish)
            end
            if vim.trim(patch) == "" then
                -- Nothing (new) to integrate: e.g. the checkout was never touched
                -- again after its previous round was applied.
                return finish("skipped")
            end
            if type(Wt.snapshot) ~= "function" then
                return needs_attention(ctx, "snapshot_unavailable", "pi.worktree.snapshot is missing", finish)
            end
            -- The checkout HEAD is the delta baseline for a later run on the same
            -- checkout; without it that run cannot be captured incrementally, so
            -- record it every time (and stop now when it cannot be read).
            head_of(Wt, fresh, function(head)
                if not head then
                    return needs_attention(ctx, "head_unavailable", "cannot read the checkout HEAD commit", finish)
                end
                Wt.snapshot(fresh, function(snapshot_path, snap_err)
                    vim.schedule(function()
                        if
                            type(snapshot_path) ~= "string"
                            or snapshot_path == ""
                            or vim.fn.filereadable(snapshot_path) ~= 1
                        then
                            return needs_attention(ctx, "snapshot_failed", snap_err, finish)
                        end
                        local files, files_complete = M.patch_files(patch)
                        ctx.patch = patch
                        ctx.rec = merged(rec, {
                            state = "queued",
                            patch_sha = sha_of(patch),
                            base_sha = type(fresh.base_sha) == "string" and fresh.base_sha
                                or (rec and rec.base_sha)
                                or "",
                            head_sha = head,
                            from_sha = from or "",
                            snapshot_path = snapshot_path,
                            files = files,
                            files_complete = files_complete,
                            -- The resolving budget belongs to the checkout, not to
                            -- a capture: a re-capture after a resolving round must
                            -- keep it, or the budget never runs out. A different
                            -- run gets a fresh budget.
                            attempts = (rec and rec.run_generation == generation) and (tonumber(rec.attempts) or 0)
                                or 0,
                            run_generation = generation,
                            reason = "captured",
                            error = "",
                        })
                        persist(child_id, ctx.cwd, ctx.rec)
                        local key = acquire_lock(ctx.root)
                        if not key then
                            enqueue(ctx.root, child_id, ctx.cwd)
                            return finish("queued", ctx.rec)
                        end
                        ctx.lock_root = key
                        local ok_attempt, attempt_err = pcall(attempt, ctx, finish)
                        if not ok_attempt then
                            release_lock(key)
                            needs_attention(ctx, "engine_error", tostring(attempt_err), finish)
                        end
                    end)
                end)
            end)
        end)
    end, diff_opts)
end

--- Integrate a settled child's worktree patch.
---
--- `done(outcome, record)` fires exactly once, on the main loop, after the
--- integration finished **or** was safely parked (`queued`) — the caller may
--- release its reservation at that point. Outcomes: `applied`,
--- `applied_kept`, `queued`, `needs_attention`, `resolving`, `skipped`, plus the
--- non-managed `disabled`/`no_child`/`no_entry`/`no_worktree`/`worktree_missing`/`error`.
---@param child pi.Session?
---@param entry table? manifest row (re-read from disk; used as a hint only)
---@param manifest_cwd string? workspace that owns the child's row
---@param done? fun(outcome: string, record: table?)
function M.on_child_settled(child, entry, manifest_cwd, done)
    local finish = once(done)
    if not cfg().auto then
        return finish("disabled")
    end
    if type(child) ~= "table" or type(child.id) ~= "string" or child.id == "" then
        return finish("no_child")
    end
    local child_id = child.id
    local cwd = manifest_cwd or manifest().workspace(child) or child.cwd
    local row = type(entry) == "table" and entry or row_of(child_id, cwd)
    if type(row) ~= "table" then
        return finish("no_entry")
    end
    local rec = record_of(row)
    local generation = type(row.run_generation) == "number" and row.run_generation or nil
    local same_run = rec ~= nil and (rec.run_generation == nil or generation == nil or rec.run_generation == generation)

    -- Idempotency: never integrate the same run twice.
    if rec and rec.state == "applied" and same_run then
        return finish("applied", rec)
    end
    if rec and rec.state == "needs_attention" and same_run then
        return finish("needs_attention", rec)
    end
    if rec and (rec.state == "queued" or rec.state == "applying") and same_run then
        -- Crash left this row mid-flight: retry from the durable snapshot.
        local ctx = load_ctx(child_id, cwd, { child = child })
        if not ctx then
            return finish("no_entry")
        end
        local key = acquire_lock(ctx.root)
        if not key then
            enqueue(ctx.root, child_id, ctx.cwd)
            return finish("queued", ctx.rec)
        end
        ctx.lock_root = key
        -- The retry must never leak the lock either: an engine error releases it
        -- and surfaces instead of wedging every later integration.
        local ok_attempt, attempt_err = pcall(attempt, ctx, finish)
        if not ok_attempt then
            release_lock(key)
            needs_attention(ctx, "engine_error", tostring(attempt_err), finish)
        end
        return nil
    end
    if rec and rec.state == "applied" then
        -- A *new* run reused an already integrated checkout. Capture only what
        -- came after the previous round; never replay the applied patch.
        return delta_plan(child_id, cwd, rec, function(plan, plan_err)
            if not plan then
                local ctx = load_ctx(child_id, cwd, { child = child })
                if not ctx then
                    return finish("no_entry")
                end
                return needs_attention(ctx, "delta_baseline_missing", plan_err, finish)
            end
            capture_and_integrate(child, child_id, cwd, rec, generation, finish, plan)
        end)
    end
    return capture_and_integrate(child, child_id, cwd, rec, generation, finish, nil)
end

--- The parent became ready (finished a turn, resumed, or started waiting).
---
--- Drains the target checkout's queue, re-enqueues rows already parked as
--- `queued`, and promotes `needs_attention` rows whose reason only needed time
--- (`modified_buffer` after the buffer was saved, `parent_busy`,
--- `other_session`, …). A real conflict is never promoted.
---@param parent pi.Session?
---@return integer promoted number of rows moved back to actionable
function M.on_parent_ready(parent)
    if not cfg().auto then
        return 0
    end
    if type(parent) ~= "table" then
        return 0
    end
    local cwd = manifest().workspace(parent) or parent.cwd
    if type(cwd) ~= "string" or cwd == "" then
        return 0
    end
    local root = lock_key(parent.cwd) or lock_key(cwd)
    local promoted = M._promote_retryable(parent, cwd) + M._requeue_parked(parent, cwd)
    if not root then
        return promoted
    end
    if not repo_state(root).busy then
        M._drain(root)
    end
    return promoted
end

--- Enqueue this parent's persisted `queued` rows (the queue itself is memory
--- only, so a restart or a parked decision needs this to become actionable).
---@param parent pi.Session
---@param cwd string
---@return integer requeued
function M._requeue_parked(parent, cwd)
    local Manifest = manifest()
    local rows = Manifest.load(cwd)
    local root = lock_key(parent.cwd) or lock_key(cwd)
    local parent_id = tostring(parent.id or "")
    local lineage = ""
    local ok, value = pcall(Manifest.lineage_for_session, parent, cwd)
    if ok and type(value) == "string" then
        lineage = value
    end
    if lineage == "" then
        lineage = parent_id
    end
    local count = 0
    for id, row in pairs(rows) do
        if Manifest.is_entry_id(id) and type(row) == "table" then
            local rec = record_of(row)
            local owner = tostring(row.parent_id or "")
            if rec and rec.state == "queued" and (owner == lineage or owner == parent_id) then
                if root and enqueue(root, id, cwd) then
                    count = count + 1
                end
            end
        end
    end
    return count
end

--- Re-queue this parent's retryable `needs_attention` rows.
---@param parent pi.Session
---@param cwd string
---@return integer promoted
function M._promote_retryable(parent, cwd)
    local Manifest = manifest()
    local lineage = ""
    local ok, value = pcall(Manifest.lineage_for_session, parent, cwd)
    if ok and type(value) == "string" then
        lineage = value
    end
    if lineage == "" then
        lineage = tostring(parent.id or "")
    end
    local rows = Manifest.load(cwd)
    local promoted = 0
    local parent_id = tostring(parent.id or "")
    for id, row in pairs(rows) do
        if Manifest.is_entry_id(id) and type(row) == "table" then
            local rec = record_of(row)
            local owner = tostring(row.parent_id or "")
            local mine = owner == lineage or owner == parent_id
            if rec and rec.state == "needs_attention" and mine and RETRYABLE[rec.reason or ""] == true then
                local next_rec = merged(rec, { state = "queued", error = "" })
                if persist(id, cwd, next_rec) then
                    enqueue(lock_key(parent.cwd) or cwd, id, cwd)
                    promoted = promoted + 1
                end
            end
        end
    end
    return promoted
end

-- Reconciliation -------------------------------------------------------------

--- Recover persisted state after a restart.
---
--- `applying` is a crash marker: the patch is probed against the target and the
--- three outcomes map to `applied` (it landed), `queued` (it did not) and
--- `needs_attention` (the target and the patch disagree). `queued` rows are
--- re-enqueued, and a `resolving` row whose child process died is stopped.
---@param done? fun(summary: table)
function M.reconcile(done)
    local finish = once(done)
    local summary = { checked = 0, applied = 0, queued = 0, needs_attention = 0, skipped = 0 }
    local jobs = {}
    local Manifest = manifest()
    local seen = {}
    local scopes = {}
    local ok_scopes, list = pcall(Manifest.scopes, { disk = true })
    if ok_scopes and type(list) == "table" then
        for _, scope in ipairs(list) do
            if type(scope) == "table" and type(scope.path) == "string" and not seen[scope.path] then
                seen[scope.path] = true
                scopes[#scopes + 1] = scope
            end
        end
    end
    for _, scope in ipairs(scopes) do
        local rows = Manifest.load_at(scope.path)
        for id, row in pairs(rows) do
            local rec = Manifest.is_entry_id(id) and record_of(row) or nil
            if rec and STATES[rec.state] and rec.state ~= "applied" then
                jobs[#jobs + 1] = {
                    child_id = id,
                    cwd = scope.cwd or (type(row) == "table" and row.workspace) or nil,
                    row = row,
                    rec = rec,
                }
            end
        end
    end

    local index = 0
    local index_step
    ---@param job table
    local function next_job(job)
        local rec = record_of(row_of(job.child_id, job.cwd)) or job.rec
        job.rec = rec
        local info = type(job.row) == "table" and type(job.row.worktree) == "table" and job.row.worktree or nil
        local path = type(info) == "table" and info.path or nil
        local exists = type(path) == "string" and vim.fn.isdirectory(path) == 1
        local ctx = load_ctx(job.child_id, job.cwd, {})
        if not ctx then
            summary.skipped = summary.skipped + 1
            return index_step()
        end
        ctx.info = info
        ctx.rec = rec
        if rec.state == "resolving" then
            local child = ctx.child
            local alive = type(child) == "table" and type(child.rpc) == "table" and child.rpc:is_running() == true
            if not alive then
                summary.needs_attention = summary.needs_attention + 1
                return needs_attention(ctx, "resolver_gone", "the resolving child process is gone", index_step)
            end
            summary.skipped = summary.skipped + 1
            return index_step()
        end
        if rec.state == "queued" then
            if not exists then
                summary.needs_attention = summary.needs_attention + 1
                return needs_attention(ctx, "worktree_missing", "the child checkout is gone", index_step)
            end
            summary.queued = summary.queued + 1
            enqueue(ctx.root, job.child_id, ctx.cwd)
            return index_step()
        end
        -- state == "applying": the crash marker. Probe decides.
        local patch, found = resolve_snapshot(ctx)
        if type(patch) ~= "string" or patch == "" then
            summary.needs_attention = summary.needs_attention + 1
            return needs_attention(ctx, "snapshot_missing", "cannot verify the interrupted apply", index_step)
        end
        if type(found) == "string" and found ~= rec.snapshot_path then
            ctx.rec = merged(rec, { snapshot_path = found })
            persist(job.child_id, job.cwd, ctx.rec)
        end
        ctx.patch = patch
        probe(ctx.root, patch, function(kind, err)
            if kind == "already" then
                summary.applied = summary.applied + 1
                ctx.rec = merged(ctx.rec, { state = "applied", applied_at = manifest().iso_now(), error = "" })
                persist(job.child_id, job.cwd, ctx.rec)
                merge_changed_files(ctx.parent, ctx.root, ctx.rec.files)
                return detach(ctx, function()
                    index_step()
                end)
            end
            if kind == "clean" then
                summary.queued = summary.queued + 1
                ctx.rec = merged(ctx.rec, { state = "queued", reason = "reconciled", error = "" })
                persist(job.child_id, job.cwd, ctx.rec)
                enqueue(ctx.root, job.child_id, ctx.cwd)
                return index_step()
            end
            summary.needs_attention = summary.needs_attention + 1
            needs_attention(ctx, "reconcile_conflict", err, index_step)
        end)
    end

    index_step = function()
        index = index + 1
        local job = jobs[index]
        if not job then
            return finish(summary)
        end
        summary.checked = summary.checked + 1
        next_job(job)
    end

    index_step()
end

-- Retention ------------------------------------------------------------------

--- Managed child checkouts in one workspace (only rows whose directory still
--- exists and that retention has not already handled).
---@param cwd string
---@return table[] rows `{ id, cwd, entry, rec, info }`
local function managed_rows(cwd)
    local Manifest = manifest()
    local out = {}
    local rows = Manifest.load(cwd)
    for id, entry in pairs(rows) do
        if Manifest.is_entry_id(id) and type(entry) == "table" then
            local rec = record_of(entry)
            local info = type(entry.worktree) == "table" and entry.worktree or nil
            if
                rec
                and rec.archived ~= true
                and type(info) == "table"
                and type(info.path) == "string"
                and info.path ~= ""
                and vim.fn.isdirectory(info.path) == 1
            then
                out[#out + 1] = { id = id, cwd = cwd, entry = entry, rec = rec, info = info }
            end
        end
    end
    return out
end

--- Why a checkout must not be deleted automatically (nil = safe to delete).
---@param row table
---@param cb fun(reason: string?)
local function retention_blocker(row, cb)
    local rec = row.rec
    local info = row.info
    if rec.pinned == true then
        return cb("pinned")
    end
    if type(rec.kept_reason) == "string" and rec.kept_reason ~= "" then
        return cb("kept")
    end
    if rec.state ~= "applied" then
        return cb("state")
    end
    if rec.archived == true then
        return cb("archived")
    end
    -- The row moved on to a newer run after this record was written: the
    -- checkout is the newer run's workspace, never retention's to delete.
    local entry_generation = type(row.entry) == "table" and row.entry.run_generation or nil
    if
        type(rec.run_generation) == "number"
        and type(entry_generation) == "number"
        and rec.run_generation ~= entry_generation
    then
        return cb("stale_generation")
    end
    local Wt = worktree()
    if Wt and type(Wt.detect) == "function" then
        local ok, fresh = pcall(Wt.detect, info.path)
        if not ok or type(fresh) ~= "table" or fresh.kind ~= "linked" then
            -- Not a linked worktree any more: never touch it.
            return cb("not_managed")
        end
        if norm(fresh.repo_root) ~= norm(info.repo_root) then
            return cb("not_managed")
        end
    end
    if vim.fn.isdirectory(info.path) ~= 1 then
        return cb("gone")
    end
    if live_session_in(info.path) then
        return cb("live_session")
    end
    local patch = read_patch(rec.snapshot_path)
    if type(patch) ~= "string" or patch == "" then
        return cb("snapshot_missing")
    end
    if type(rec.patch_sha) == "string" and rec.patch_sha ~= "" and sha_of(patch) ~= rec.patch_sha then
        return cb("patch_drift")
    end
    probe(info.repo_root or row.cwd, patch, function(kind)
        if kind ~= "already" then
            -- `clean` means the work is not in the target (lost?), `conflict`
            -- means we cannot prove it is there. Neither may be deleted.
            return cb("unverified")
        end
        ignored_content(info, function(entries)
            if type(entries) == "table" and #entries > 0 then
                return cb("ignored")
            end
            -- Re-capture the checkout: it must still hold just the patch that is
            -- verified in the target. New work (a revived child, a stray
            -- process) makes it undeletable, even though the old patch landed.
            checkout_matches(info, rec, function(match_ok, match_reason)
                if not match_ok then
                    return cb(match_reason or "checkout_changed")
                end
                cb(nil)
            end)
        end)
    end)
end

--- Delete one managed checkout (verified applied) and archive its row.
---@param row table
---@param cb fun(removed: boolean)
local function retention_remove(row, cb)
    local Wt = worktree()
    if not Wt or type(Wt.remove) ~= "function" then
        return cb(false)
    end
    local ok = pcall(Wt.remove, row.info, { force = true, snapshot = false }, function(removed, err)
        vim.schedule(function()
            if not removed then
                persist(row.id, row.cwd, merged(row.rec, { error = tostring(err or "remove failed") }))
                return cb(false)
            end
            forget_sessions(row.info)
            persist(
                row.id,
                row.cwd,
                merged(row.rec, {
                    archived = true,
                    archived_at = manifest().iso_now(),
                    worktree_removed = true,
                    error = "",
                })
            )
            cb(true)
        end)
    end)
    if not ok then
        cb(false)
    end
end

--- Soft cap on managed child checkouts.
---
--- Only `applied` rows whose patch is **verified present** and whose checkout is
--- inactive (no live process) and unpinned are deleted, oldest first, once the
--- managed total exceeds `worktree.integration.keep_count`. Rows that are
--- `queued`/`applying`/`resolving`/`needs_attention`, deliberately kept rows
--- (`kept_reason`), and unverifiable rows still count toward the total but are
--- never deleted — an unintegrated worktree is never removed for quota.
---@param cwd? string workspace to sweep (default: every manifest on disk)
---@param done? fun(summary: table)
function M.enforce_retention(cwd, done)
    local finish = once(done)
    local conf = cfg()
    local summary = { managed = 0, removable = 0, removed = 0, protected = 0, kept = {} }

    local scopes = {}
    local Manifest = manifest()
    if type(cwd) == "string" and cwd ~= "" then
        scopes[1] = cwd
    else
        local seen = {}
        local ok, list = pcall(Manifest.scopes, { disk = true })
        if ok and type(list) == "table" then
            for _, scope in ipairs(list) do
                local path = type(scope) == "table" and scope.cwd or nil
                if type(path) == "string" and path ~= "" and not seen[path] then
                    seen[path] = true
                    scopes[#scopes + 1] = path
                end
            end
        end
    end

    local candidates = {}
    for _, scope in ipairs(scopes) do
        for _, row in ipairs(managed_rows(scope)) do
            summary.managed = summary.managed + 1
            candidates[#candidates + 1] = row
        end
    end
    table.sort(candidates, function(a, b)
        local ak = tostring((a.rec and a.rec.applied_at) or (a.entry and a.entry.last_active_at) or "")
        local bk = tostring((b.rec and b.rec.applied_at) or (b.entry and b.entry.last_active_at) or "")
        if ak ~= bk then
            return ak < bk
        end
        return tostring(a.id) < tostring(b.id)
    end)

    local needed = math.max(summary.managed - conf.keep_count, 0)
    local index = 0
    local function step()
        if summary.removed >= needed or index >= #candidates then
            return finish(summary)
        end
        index = index + 1
        local row = candidates[index]
        retention_blocker(row, function(reason)
            if reason ~= nil then
                if reason ~= "archived" and reason ~= "gone" then
                    summary.protected = summary.protected + 1
                    summary.kept[#summary.kept + 1] = { id = row.id, reason = reason }
                end
                return step()
            end
            retention_remove(row, function(removed)
                if removed then
                    summary.removed = summary.removed + 1
                else
                    summary.protected = summary.protected + 1
                    summary.kept[#summary.kept + 1] = { id = row.id, reason = "remove_failed" }
                end
                step()
            end)
        end)
    end
    step()
end

-- Test hooks -----------------------------------------------------------------

--- Replace the git fact runner (`nil` restores `vim.system`).
---@param fn pi.WorktreeIntegrationGit?
function M._set_git(fn)
    git_override = fn
end

--- Replace the ignored-content probe (`nil` restores the git-backed one).
---@param fn fun(info: table, cb: fun(entries: string[]))?
function M._set_ignored(fn)
    ignored_override = fn
end

--- Drop in-memory queue/lock state.
function M._reset()
    repos = {}
end

--- Queue depth of one target checkout (tests).
---@param root string
---@return integer
function M._queue_depth(root)
    local state = repos[norm(root) or root]
    return state and #state.queue or 0
end

--- Whether one target checkout is currently integrating (tests).
---@param root string
---@return boolean
function M._busy(root)
    local state = repos[norm(root) or root]
    return state ~= nil and state.busy == true
end

return M
