--- Sub-session lifecycle: spawn, switch, close, report, and host bridge for subagent.ts.

local M = {}

local Config = require("pi.config")
local Notify = require("pi.notify")
local Dialog = require("pi.ui.dialog")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Batch = require("pi.subsessions.batch")
local Sessions = require("pi.sessions.manager")
local Reaper = require("pi.subsessions.reaper")

--- Run generation of a brand-new child row. Every new run on an existing row
--- (revive) increments it; the integration engine records the generation it
--- captured so a late apply/cleanup can be rejected when the child moved on.
local FIRST_RUN_GENERATION = 1

--- Abort epochs per lineage: interactive spawns capture the epoch at start and
--- bail out when it changes mid-flight (see M.spawn).
local abort_epochs = {}

--- Bump the abort epoch for a lineage so in-flight interactive spawns for it stop.
---@param lineage_id string
function M.mark_lineage_aborted(lineage_id)
    if type(lineage_id) ~= "string" or lineage_id == "" then
        return
    end
    abort_epochs[lineage_id] = (abort_epochs[lineage_id] or 0) + 1
end

---@param lineage_id string
---@return integer epoch Current abort epoch (0 when unknown).
function M.abort_epoch(lineage_id)
    if type(lineage_id) ~= "string" or lineage_id == "" then
        return 0
    end
    return abort_epochs[lineage_id] or 0
end

--- Test helper: drop all recorded abort epochs.
function M._reset_abort_epochs()
    abort_epochs = {}
end

--- Highest generation aborted per child. A child's `agent_settled` carries no
--- generation of its own, and the parent may already have reused that child for
--- a newer run by the time it arrives — so the settle path filters batch items
--- by this watermark instead of by the current manifest generation.
local child_aborts = {}

--- Record the generation aborted for a child (monotonic per child).
---@param child_id string
---@param generation? integer
function M.mark_child_aborted(child_id, generation)
    if type(child_id) ~= "string" or child_id == "" or type(generation) ~= "number" then
        return
    end
    -- `nil` means "never recorded": a recorded 0 must not be confused with an
    -- absent watermark (real runs start at 1, but the distinction is what keeps
    -- `aborted_generation` honest).
    local current = child_aborts[child_id]
    if current == nil or generation > current then
        child_aborts[child_id] = generation
    end
end

--- Highest generation aborted for a child, or nil when none was recorded.
---@param child_id string
---@return integer?
function M.aborted_generation(child_id)
    if type(child_id) ~= "string" or child_id == "" then
        return nil
    end
    return child_aborts[child_id]
end

--- Test helper: drop all recorded abort watermarks.
function M._reset_child_aborts()
    child_aborts = {}
end

---@param a string?
---@param b string?
---@return boolean
local function same_resolved_path(a, b)
    if type(a) ~= "string" or a == "" or type(b) ~= "string" or b == "" then
        return false
    end
    return vim.fn.resolve(a) == vim.fn.resolve(b)
end

--- True when this RPC process already has `path` open — UI switch must not
--- send `switch_session` (pi always aborts the agent first).
--- A live process that has not yet reported `session_file` is treated as already
--- on the right file: `switch_session` would abort a just-spawned child.
---@param session pi.Session
---@param path string?
---@return boolean
local function process_has_session_file(session, path)
    if not session.rpc:is_running() then
        return false
    end
    if not path or path == "" then
        return true
    end
    if type(session.session_file) ~= "string" or session.session_file == "" then
        return true
    end
    return same_resolved_path(session.session_file, path)
end

--- Rebuild the bound chat from a live process, or `switch_session` when the
--- process is on a different file (revive / empty session vs disk).
---@param session pi.Session
---@param path string?
---@param callback fun(ok: boolean, err?: string)
local function reattach_or_load(session, path, callback)
    if process_has_session_file(session, path) then
        Sessions.reattach_view(session, function(ok)
            callback(ok, ok and nil or "failed to rebuild session view")
        end)
        return
    end
    if path then
        Sessions.load_session_path(session, path, function(ok)
            callback(ok, ok and nil or "failed to load session")
        end, { rebind_parent_context = false })
        return
    end
    callback(true)
end

---@class pi.SubsessionSpawnOpts
---@field task string
---@field name? string
---@field model? pi.ModelRef
---@field thinking_level? string
---@field agent_spawned? boolean Block completion prompt injection (Agent tool path).

---@param parent pi.Session
---@return pi.PinnedConfig?
local function resolve_child_config(parent, opts)
    local cfg = Config.options.subagent or {}
    if opts.model then
        return {
            model = opts.model,
            thinking_level = opts.thinking_level,
        }
    end
    if cfg.default_config == "inherit" or cfg.default_config == nil then
        local pin = parent.pinned_config
        if pin and pin.model then
            return {
                model = { provider = pin.model.provider, id = pin.model.id },
                thinking_level = opts.thinking_level or pin.thinking_level,
            }
        end
    end
    return nil
end

--- Format available backend models into a compact reference list.
--- Models matching `preferred_provider` are sorted first, followed by others.
--- Truncated to 20 models with (+N more) suffix when exceeded.
---@param models table[]?
---@param preferred_provider string?
---@return string?
local function format_available_models(models, preferred_provider)
    if type(models) ~= "table" or #models == 0 then
        return nil
    end
    local same_provider = {}
    local other_providers = {}
    local seen = {}
    for _, m in ipairs(models) do
        if type(m) == "table" and type(m.provider) == "string" and type(m.id) == "string" then
            local ref = m.provider .. "/" .. m.id
            if not seen[ref] then
                seen[ref] = true
                if preferred_provider and m.provider == preferred_provider then
                    same_provider[#same_provider + 1] = ref
                else
                    other_providers[#other_providers + 1] = ref
                end
            end
        end
    end
    table.sort(same_provider)
    table.sort(other_providers)
    local ordered = {}
    for _, ref in ipairs(same_provider) do
        ordered[#ordered + 1] = ref
    end
    for _, ref in ipairs(other_providers) do
        ordered[#ordered + 1] = ref
    end
    if #ordered == 0 then
        return nil
    end
    local max_display = 20
    local shown = {}
    for i = 1, math.min(#ordered, max_display) do
        shown[#shown + 1] = ordered[i]
    end
    local extra = #ordered - max_display
    local res = table.concat(shown, ", ")
    if extra > 0 then
        res = res .. string.format(" (+%d more)", extra)
    end
    return res
end

---@param session pi.Session
---@param config pi.PinnedConfig?
---@param callback fun(ok: boolean, err?: string)
local function apply_config(session, config, callback)
    if not config or not config.model then
        callback(true)
        return
    end
    local function after_model()
        if config.thinking_level then
            local sent_tl = session.rpc:send(
                { type = "set_thinking_level", level = config.thinking_level },
                function(res)
                    if res.success then
                        callback(true)
                    else
                        local tl_err = (type(res.error) == "string" and res.error ~= "") and res.error
                            or "failed to set thinking level"
                        callback(false, tl_err)
                    end
                end
            )
            if not sent_tl then
                callback(false, "failed to send thinking level command")
            end
        else
            callback(true)
        end
    end
    local sent_model = session.rpc:send(
        { type = "set_model", provider = config.model.provider, modelId = config.model.id },
        function(res)
            if res.success then
                Sessions.update_pinned_config(session, {
                    model = config.model,
                    thinking_level = config.thinking_level,
                })
                after_model()
            else
                local base_err = res.error
                if type(base_err) ~= "string" or base_err == "" then
                    base_err = string.format("Model not found: %s/%s", config.model.provider, config.model.id)
                end
                local sent = session.rpc:send({ type = "get_available_models" }, function(models_res)
                    local models_list = models_res.success and models_res.data and models_res.data.models
                    local formatted = format_available_models(models_list, config.model.provider)
                    local full_err = (formatted and formatted ~= "")
                            and string.format("%s. Available models: [%s]", base_err, formatted)
                        or base_err
                    callback(false, full_err)
                end)
                if not sent then
                    callback(false, base_err)
                end
            end
        end
    )
    if not sent_model then
        callback(false, "failed to send model command")
    end
end

---@param session pi.Session
---@param task string
---@param callback fun(ok: boolean)
local function send_task(session, task, callback)
    local sent = session.rpc:send({ type = "prompt", message = task }, function(res)
        callback(res.success == true)
    end)
    if not sent then
        callback(false)
    end
end

--- Worktree integration engine, loaded lazily and optional.
---
--- The engine owns the child-checkout → parent-changes state machine
--- (`queued` → `resolving` → `applying` → `applied` / `needs_attention`). Same
--- rationale as `worktree_mod`: the sub-session layer keeps working — and specs
--- keep running — when the module is absent or a stub stands in for it.
---@return table?
local function integration_mod()
    local ok, mod = pcall(require, "pi.worktree_integration")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

--- True when automatic worktree integration is enabled (`worktree.integration.auto`,
--- default true).
---
--- Read here as well as in the engine so a disabled engine never costs a settle
--- an event-loop tick: without it, `done` is only reached through the engine's
--- own scheduled callback.
---@return boolean
local function integration_auto()
    local wt = Config.options.worktree --[[@as table?]]
    local integration = type(wt) == "table" and wt.integration or nil
    if type(integration) ~= "table" then
        return true
    end
    return integration.auto ~= false
end

--- Integration **states** the engine persists on a manifest row (its other
--- outcome codes — "disabled", "no_worktree", "skipped", "no_entry" — are
--- results, not states, and must not leave a record behind).
---@type table<string, boolean>
local integration_states = {
    applied = true,
    queued = true,
    applying = true,
    resolving = true,
    needs_attention = true,
}

--- Normalize the engine's `done(state, record)` callback into the record the
--- sub-session layer stores and reports (`state` plus `files`, `error`, ...).
---
--- The engine reports outcome codes that are not persisted states ("disabled",
--- "no_entry", "no_worktree", ...); those yield `nil` — no integration record,
--- exactly like a run with nothing to integrate.
---@param state string? engine outcome or state name
---@param record table? persisted integration record
---@return table?
local function integration_outcome(state, record)
    local rec = record --[[@as table]]
    local name = type(rec) == "table" and rec.state or nil
    if type(name) ~= "string" then
        name = type(state) == "string" and state or nil
    end
    if not name or not integration_states[name] then
        return nil
    end
    local outcome = {}
    if type(rec) == "table" then
        for k, v in pairs(rec) do
            outcome[k] = v
        end
    end
    outcome.state = name
    return outcome
end

--- Call `fn` on the engine when it exists and exposes that function.
--- Never lets an engine error break sub-session bookkeeping.
---@param name string engine function name
---@param ... any arguments
---@return boolean called
local function integration_call(name, ...)
    local mod = integration_mod()
    if not mod or type(mod[name]) ~= "function" then
        return false
    end
    local ok, err = pcall(mod[name], ...)
    if not ok then
        Notify.warn(("worktree integration %s failed: %s"):format(name, tostring(err)))
        return false
    end
    return true
end

--- Mark `parent` as blocked waiting on sub-sessions.
---
--- The marker is a depth counter — one tab/handler can wait while another wait
--- is already open — and it is always cleared by `end_parent_wait` (settle,
--- timeout and synchronous completion all run through the same callback).
--- `Integration.on_parent_ready` is what drives the engine's queue: while the
--- parent is waiting, an applied result belongs to that waiting call.
---@param parent pi.Session
local function begin_parent_wait(parent)
    local session = parent --[[@as table]]
    session.waiting_subagents = (tonumber(session.waiting_subagents) or 0) + 1
    integration_call("on_parent_ready", parent)
end

--- Clear one wait on `parent`; the marker disappears entirely at depth 0 and the
--- engine is told the parent is ready again.
---@param parent pi.Session
local function end_parent_wait(parent)
    local session = parent --[[@as table]]
    local depth = (tonumber(session.waiting_subagents) or 0) - 1
    if depth > 0 then
        session.waiting_subagents = depth
        return
    end
    -- Cleared, not zeroed: "no marker" is the resting state every caller tests.
    session.waiting_subagents = nil
    integration_call("on_parent_ready", parent)
end

--- True when `parent` is currently blocked in a sub-session wait.
---@param parent pi.Session?
---@return boolean
function M.parent_waiting(parent)
    local session = parent --[[@as table?]]
    return type(session) == "table" and (tonumber(session.waiting_subagents) or 0) > 0
end

---@param parent pi.Session
---@param callback fun(parent_id: string)
local function with_parent_id(parent, callback)
    local id = parent.id
    if type(id) == "string" and id ~= "" and not id:match("^tmp%-") then
        callback(id)
        return
    end
    parent.rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            local sid = res.success and res.data and res.data.sessionId
            if type(sid) == "string" and sid ~= "" then
                Sessions.ensure_id(parent, sid)
                callback(sid)
            elseif type(id) == "string" and id ~= "" then
                callback(id)
            else
                callback("")
            end
        end)
    end)
end

--- Called when the parent starts a fresh conversation (/new) in the same tab.
---@param parent pi.Session
function M.on_parent_new_conversation(parent)
    if type(parent.id) == "string" and parent.id ~= "" then
        Manifest.bind_session_lineage(parent, parent.id, Manifest.workspace(parent))
    end
    parent.conversation_epoch = (parent.conversation_epoch or 0) + 1
    parent.view_parent_id = nil
    -- A process reused for a fresh conversation is no longer a child.
    parent.parent_id = nil
    require("pi.ui.sessions").request_refresh()
end

--- Reset sub-session UI context when the tab resumes a different parent session file.
---@param session pi.Session
---@param session_path string
function M.on_parent_resumed(session, session_path)
    -- A process reused by :PiResume is no longer a child; drop stale parentage.
    session.parent_id = nil
    session.view_parent_id = nil
    session.conversation_epoch = 0
    session.lineage_id = nil
    local info = require("pi.sessions.history").parse(session_path)
    if info and type(info.id) == "string" and info.id ~= "" then
        Sessions.ensure_id(session, info.id)
        -- A resumed session file carries the cwd it was created in, and
        -- `load_session` adopts it before this runs: the lineage map belongs to
        -- that workspace's manifest.
        Manifest.rebind_lineage(session, info.id, Manifest.workspace(session))
    end
    require("pi.ui.sessions").request_refresh()
end

--- Worktree metadata for a child session: the `pi.WorktreeInfo` record returned
--- by `pi.worktree.create` / `detect`, round-tripped through the manifest so a
--- revive can reuse the checkout.
--- What the worktree resolver reads from a session: where to create a checkout
--- from, and whether that session already lives in one. A live `pi.Session`
--- qualifies, and so does a synthetic `{ cwd = manifest_workspace }` base used
--- by a revive whose parent process is not running.
---@alias pi.SubsessionWorktreeBase pi.Session|{ cwd?: string, worktree?: table }

---@class pi.SubsessionWorktree
---@field path string Worktree root — the child session cwd.
---@field name? string Worktree name (`sub-<timestamp>-<n>-<pid>` for children).
---@field kind? "linked"|"main"
---@field repo_root? string Main work tree of the repository.
---@field git_dir? string Per-worktree git dir.
---@field common_dir? string Shared git dir.
---@field base_sha? string Commit the worktree was created from.
---@field mode? string Creation mode recorded in the metadata (`"new"` for children).
---@field session_id? string pi session bound to the worktree.
---@field session_file? string pi session transcript bound to the worktree.

--- Worktree module, loaded lazily.
---
--- Isolation is an optional layer: when `pi.worktree` cannot be loaded the
--- spawn path keeps working with the parent's cwd (exactly the behavior of an
--- install without the module) instead of failing every sub-session.
---@return table?
local function worktree_mod()
    local ok, mod = pcall(require, "pi.worktree")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

--- True when each new sub-session gets its own worktree (`worktree.isolate_subagents`, default true).
---@return boolean
local function isolation_enabled()
    local wt = Config.options.worktree or {}
    return wt.isolate_subagents ~= false
end

--- Session cwd, or nil when the session has none recorded.
---@param session pi.SubsessionWorktreeBase?
---@return string?
local function session_cwd(session)
    local cwd = session and session.cwd
    if type(cwd) == "string" and cwd ~= "" then
        return cwd
    end
    return nil
end

--- The linked worktree `session` already runs in, or nil.
---
--- Sub-sessions never nest worktrees: a child of a session that already lives
--- in one inherits that cwd instead of creating a second checkout (the parent's
--- checkout is never released by a child). `session.worktree` is the manager's
--- own record; `detect` covers a cwd adopted from a resumed session file.
---@param session pi.SubsessionWorktreeBase?
---@return pi.SubsessionWorktree?
local function detect_worktree(session)
    if type(session) ~= "table" then
        return nil
    end
    if type(session.worktree) == "table" and type(session.worktree.path) == "string" then
        return session.worktree
    end
    local mod = worktree_mod()
    local cwd = session_cwd(session)
    if not mod or type(mod.detect) ~= "function" or not cwd then
        return nil
    end
    local ok, info = pcall(mod.detect, cwd)
    if ok and type(info) == "table" and info.kind == "linked" and type(info.path) == "string" and info.path ~= "" then
        return info
    end
    return nil
end

--- Monotonic counter behind `child_worktree_name` (per Neovim process).
local child_worktree_seq = 0

--- Unique name for a child checkout.
---
--- `pi.worktree`'s default name is second-resolution (`wt-<YYYYmmdd-HHMMSS>`), so
--- children dispatched together — a batch fans out up to `max_children` at
--- once — would collide on one name. A spawn counter plus the process pid keeps
--- them distinct, also across concurrent Neovim instances. The `sub-` prefix
--- tells child checkouts apart from user-created `wt-*` worktrees.
---@return string
local function child_worktree_name()
    child_worktree_seq = child_worktree_seq + 1
    return ("sub-%s-%d-%x"):format(os.date("%Y%m%d-%H%M%S"), child_worktree_seq, vim.fn.getpid())
end

--- Repository root `mod.detect(cwd)` reports for `cwd`, or nil outside a repository.
---
--- A `main` info names the main work tree in `path`; a linked one points at it
--- through `repo_root`.
---@param mod table
---@param cwd string
---@return string?
local function detected_repo_root(mod, cwd)
    if type(mod.detect) ~= "function" then
        return nil
    end
    local ok, info = pcall(mod.detect, cwd)
    if not ok or type(info) ~= "table" then
        return nil
    end
    local root = info.kind == "main" and (info.path or info.repo_root) or info.repo_root
    if type(root) == "string" and root ~= "" then
        return root
    end
    return nil
end

--- Name to recreate a recorded checkout under.
---
--- The recorded name is authoritative — it *is* the directory component under
--- `<repo>/.worktrees/`; rows written before names were tracked fall back to the
--- recorded path's basename, which is the directory that checkout used.
---@param reuse pi.SubsessionWorktree
---@return string
local function recorded_worktree_name(reuse)
    if type(reuse.name) == "string" and reuse.name ~= "" then
        return reuse.name
    end
    return vim.fn.fnamemodify(reuse.path, ":t")
end

--- Resolve the cwd (and owned worktree) a child process should start in.
---
--- Cases, in order:
--- 1. `reuse` — a worktree recorded on the child's manifest row (revive) that
---    still exists on disk is reused as-is, dirty or not: it holds that
---    child's uncommitted work.
--- 2. the parent already lives in a linked worktree — the child inherits that
---    cwd and owns nothing (a parent's worktree is never released by a child).
--- 3. a recorded checkout that is gone is recreated at its recorded path (same
---    repository only) — see the block below.
--- 4. otherwise create a fresh worktree for the child.
---
--- `info` is only non-nil when the child *owns* the worktree (created or
--- reused), so callers know what `release` may later delete. `err` is set only
--- when a creation fails — the caller must then release its spawn reservation and
--- report the error, never silently share the parent's directory.
---@param parent pi.SubsessionWorktreeBase? Live parent, or a synthetic
---   `{ cwd = manifest_workspace }` base when the parent process is not running.
---@param reuse pi.SubsessionWorktree?
---@param callback fun(info: pi.SubsessionWorktree?, cwd: string?, err: string?)
local function prepare_worktree(parent, reuse, callback)
    local mod = worktree_mod()
    if not mod then
        callback(nil, session_cwd(parent), nil)
        return
    end

    if type(reuse) == "table" and type(reuse.path) == "string" and reuse.path ~= "" then
        if vim.fn.isdirectory(reuse.path) == 1 then
            callback(reuse, reuse.path, nil)
            return
        end
    end

    local inherited = detect_worktree(parent)
    if inherited then
        callback(nil, inherited.path, nil)
        return
    end

    -- Isolation needs a deterministic base to create from. Every live session
    -- carries `cwd` (the manager sets it), so a missing one means there is no
    -- workspace to isolate — the child keeps the process default.
    local cwd = session_cwd(parent)
    if not cwd then
        callback(nil, nil, nil)
        return
    end

    if not isolation_enabled() or type(mod.create) ~= "function" then
        callback(nil, cwd, nil)
        return
    end

    local done = false
    ---@param info pi.SubsessionWorktree?
    ---@param dir string?
    ---@param err string?
    local function finish(info, dir, err)
        if done then
            return
        end
        done = true
        callback(info, dir, err)
    end

    --- Create a checkout; `cb` receives the info or a non-empty error string.
    ---@param opts pi.WorktreeCreateOpts
    ---@param cb fun(info: pi.SubsessionWorktree?, err: string?)
    local function create(opts, cb)
        local ok, create_err = pcall(mod.create, opts, function(info, err)
            vim.schedule(function()
                if type(info) ~= "table" or type(info.path) ~= "string" or info.path == "" then
                    local reason = (type(err) == "string" and err ~= "") and err
                        or "failed to create sub-session worktree"
                    cb(nil, reason)
                    return
                end
                cb(info, nil)
            end)
        end)
        if not ok then
            cb(nil, "failed to create sub-session worktree: " .. tostring(create_err))
        end
    end

    -- A revived child's transcript records the checkout it ran in as its cwd,
    -- and a resume refuses to load from a missing directory. So a recorded
    -- checkout that is gone (a clean close released it — the documented normal
    -- path) must come back at the *same* directory: a freshly named one could
    -- never be opened, and every revive would repeat the cycle. Replaying is
    -- only safe within one repository — a checkout of some other repo is
    -- isolated afresh instead (today's behaviour).
    if type(reuse) == "table" and type(reuse.path) == "string" and reuse.path ~= "" then
        local recorded_repo = type(reuse.repo_root) == "string" and reuse.repo_root or nil
        if recorded_repo and detected_repo_root(mod, cwd) == recorded_repo then
            local name = recorded_worktree_name(reuse)
            local base = type(reuse.base_sha) == "string" and vim.trim(reuse.base_sha) or ""
            create({ cwd = cwd, mode = "new", name = name, base = base ~= "" and base or nil }, function(info, err)
                if info then
                    finish(info, info.path, nil)
                    return
                end
                -- The recorded base commit can be gone (rewritten history,
                -- pruned objects): retry once at the repository HEAD instead of
                -- failing an otherwise recoverable revive.
                if base ~= "" and type(err) == "string" and err:find("invalid base commit", 1, true) then
                    create({ cwd = cwd, mode = "new", name = name }, function(retry_info, retry_err)
                        if retry_info then
                            finish(retry_info, retry_info.path, nil)
                        else
                            finish(nil, nil, retry_err)
                        end
                    end)
                    return
                end
                -- Never fall back to a new name here: the transcript would not
                -- load, which is exactly the bug this path exists to fix.
                finish(nil, nil, err)
            end)
            return
        end
    end

    create({ cwd = cwd, mode = "new", name = child_worktree_name() }, function(info, err)
        if info then
            finish(info, info.path, nil)
        else
            finish(nil, nil, err)
        end
    end)
end

--- Ask `pi.worktree` to release an owned worktree.
---
--- `release` deletes the checkout only when it is clean; a worktree with
--- uncommitted work always survives so a revive can pick it back up.
---@param info pi.SubsessionWorktree?
---@return boolean requested True when a worktree module accepted the request.
local function release_worktree_info(info)
    if type(info) ~= "table" or type(info.path) ~= "string" or info.path == "" then
        return false
    end
    local mod = worktree_mod()
    if not mod or type(mod.release) ~= "function" then
        return false
    end
    pcall(mod.release, info, function() end)
    return true
end

--- Worktree info recorded on a manifest row, or nil.
---
--- Manifest rows may predate the worktree/session_file fields (and other
--- modules own that class annotation), so both are read structurally.
---@param entry any
---@return pi.SubsessionWorktree?
local function entry_worktree(entry)
    if type(entry) ~= "table" or type(entry.worktree) ~= "table" then
        return nil
    end
    return entry.worktree
end

--- Release the worktree recorded for `child_id`.
---
--- The manager releases the worktree of every session it closes (close_session /
--- _process_exit are the authority, with a once-only guard), so this is only for
--- children no live process owns any more — see `Reaper.release_orphaned_worktrees`.
--- A checkout any live session is rooted in is never released: the registry id
--- may differ from the manifest id (revive id migration), and the process may
--- still write into that cwd.
---@param child_id string
---@return boolean released
function M.release_worktree(child_id)
    if type(child_id) ~= "string" or child_id == "" then
        return false
    end
    ---@type pi.SubsessionManifestEntry?
    local entry = Manifest.load()[child_id]
    if type(entry) ~= "table" then
        entry = Manifest.locate(child_id)
    end
    -- A row the integration engine has a record for is engine-owned: mid-flight
    -- states (queued/resolving/applying) must not be pulled out from under it,
    -- and an `applied`/`needs_attention` checkout may still hold its changes.
    -- Engine-driven cleanup is `Integration.enforce_retention`.
    if Manifest.integration_state(entry) ~= nil then
        return false
    end
    local info = entry_worktree(entry)
    local path = type(info) == "table" and info.path or nil
    if type(path) ~= "string" or path == "" then
        return false
    end
    for _, session in ipairs(Sessions.list_all()) do
        local wt = session.worktree
        if (type(wt) == "table" and wt.path == path) or session.cwd == path then
            return false
        end
    end
    return release_worktree_info(info)
end

--- Publish worktree ↔ session ownership to `pi.worktree`.
---@param info pi.SubsessionWorktree?
---@param session_id string?
---@param session_file string?
local function bind_worktree(info, session_id, session_file)
    if type(info) ~= "table" then
        return
    end
    local mod = worktree_mod()
    if not mod or type(mod.bind) ~= "function" then
        return
    end
    pcall(mod.bind, info, { session_id = session_id, session_file = session_file })
end

--- Session file recorded on a manifest row, when it still exists on disk.
---@param entry any
---@return string?
local function manifest_session_file(entry)
    local path = type(entry) == "table" and entry.session_file or nil
    if type(path) == "string" and path ~= "" and vim.fn.filereadable(path) == 1 then
        return path
    end
    return nil
end

--- Liveness test behind the `subagent.max_children` limit: a child occupies a
--- slot while its RPC process is still running in this Neovim instance,
--- whatever the manifest says — a completed (or interrupted) child whose
--- process lingers must not let the lineage spawn past the cap, while a dead
--- process (failed/dormant, or no registry row at all) frees its slot.
--- Shared between M.spawn and batch dispatch pre-checks. Lives here, not in
--- manifest.lua, so the manifest never requires the sessions manager
--- (dependency direction).
---@param child_id string
---@return boolean
function M.is_child_process_alive(child_id)
    local session = Sessions.get_by_id(child_id)
    if not session or not session.rpc then
        return false
    end
    return session.rpc:is_running() == true
end

--- Spawn a background sub-session for `parent`.
---@param parent pi.Session
---@param opts pi.SubsessionSpawnOpts
---@param callback fun(child: pi.Session?, err: string?)
function M.spawn(parent, opts, callback)
    local subcfg = Config.options.subagent or {}
    if subcfg.enabled == false then
        callback(nil, "subagent disabled")
        return
    end

    -- Every manifest / batch row written by this spawn belongs to the parent's
    -- workspace — the same cwd the child process reports as `process.cwd()`.
    -- Neovim's cwd is not that authority: a tab can run in a worktree checkout.
    local cwd = Manifest.workspace(parent)
    -- Abort epoch of the lineage as it resolves *now*: `with_parent_id` below can
    -- do an id-lookup round-trip, and before that round-trip finishes the parent
    -- may still be keyed by a `tmp-` id. An abort landing in that window bumps
    -- that pre-migration key, so it is captured here as well as after the lookup.
    local entry_lineage = Manifest.lineage_for_session(parent, cwd)
    local entry_epoch = M.abort_epoch(entry_lineage)

    with_parent_id(parent, function(parent_id)
        if parent_id == "" then
            callback(nil, "parent session id not available")
            return
        end

        -- Nothing has been reserved or created yet, so an abort that arrived
        -- while the id lookup was in flight just cancels this spawn.
        if M.abort_epoch(entry_lineage) ~= entry_epoch then
            callback(nil, "sub-session aborted while spawning")
            return
        end

        Manifest.bind_session_lineage(parent, parent_id, cwd)
        local lineage_id = Manifest.lineage_for_session(parent, cwd)
        if lineage_id == "" then
            lineage_id = parent_id
        end
        -- Abort-epoch guard: if the lineage is aborted while the async spawn
        -- chain below is still in flight, the chain bails out instead of
        -- starting a task for a sub-session the user already cancelled.
        local epoch = M.abort_epoch(lineage_id)

        local max = subcfg.max_children or 5
        if not Manifest.try_reserve_spawn(lineage_id, max, M.is_child_process_alive, cwd) then
            -- Slot pressure: auto-reap the oldest settled child to make room.
            if
                Reaper.reap_oldest_settled(lineage_id, 1, nil, cwd) == 0
                or not Manifest.try_reserve_spawn(lineage_id, max, M.is_child_process_alive, cwd)
            then
                callback(nil, ("max %d concurrent sub-sessions"):format(max))
                return
            end
        end
        local held = true
        local function unreserve()
            if held then
                held = false
                Manifest.release_spawn(lineage_id)
            end
        end

        local tab = parent.attached_tab or vim.api.nvim_get_current_tabpage()

        --- Start the child process in the already-resolved cwd/worktree.
        ---@param wt pi.SubsessionWorktree? Worktree the child owns (nil when it shares a cwd).
        ---@param child_cwd string? Process cwd (inherited parent cwd, or nil = process default).
        local function start_child(wt, child_cwd)
            local child = Sessions.create_detached(tab, {
                subagent = false,
                cwd = child_cwd,
                worktree = wt,
            })
            if not child then
                unreserve()
                release_worktree_info(wt)
                callback(nil, "failed to start sub-session process")
                return
            end
            if wt then
                child.worktree = wt
            end
            child.parent_id = parent_id
            -- Sub-session bookkeeping for this child lives in the parent's
            -- workspace manifest, not in the child's own (worktree) cwd.
            child.manifest_cwd = cwd
            -- First run on a brand-new row. Every later run (revive / reuse)
            -- bumps it, which is what lets the integration engine reject a late
            -- apply or cleanup that belongs to a superseded run.
            child.run_generation = FIRST_RUN_GENERATION

            local config = resolve_child_config(parent, opts)
            -- An explicitly supplied name is honoured verbatim; otherwise derive one
            -- from the task. `name_source` records which of the two it was so the
            -- child's own auto title can replace a derived name later without ever
            -- clobbering the caller's choice (see M.on_child_session_name).
            local explicit_name = type(opts.name) == "string" and opts.name ~= "" and opts.name or nil
            local name = explicit_name or Manifest.fallback_name(opts.task) or "sub-session"
            local name_source = explicit_name and "explicit" or "fallback"

            local function register_and_run(session_id)
                child.id = session_id
                if M.abort_epoch(lineage_id) ~= epoch then
                    unreserve()
                    Sessions.close_session(child)
                    callback(nil, "sub-session aborted while spawning")
                    return
                end
                Manifest.upsert(session_id, {
                    parent_id = lineage_id,
                    parent_epoch = parent.conversation_epoch or 0,
                    name = name,
                    name_source = name_source,
                    task_prompt = opts.task,
                    config = config and {
                        model = config.model,
                        thinking_level = config.thinking_level,
                    } or {},
                    status = "active",
                    reported = false,
                    created_at = Manifest.iso_now(),
                    last_active_at = Manifest.iso_now(),
                    agent_spawned = opts.agent_spawned == true,
                    run_generation = FIRST_RUN_GENERATION,
                    session_file = child.session_file,
                    worktree = wt or nil,
                    workspace = cwd,
                }, cwd)
                unreserve()
                -- Isolation bookkeeping: `pi.worktree` keeps the worktree's
                -- session file in sync with the backend session id.
                bind_worktree(wt, session_id, child.session_file)
                apply_config(child, config, function(ok, config_err)
                    -- Abort can land during the config round-trip: the child is in
                    -- the manifest but has not received its task yet, so reclaim it
                    -- instead of starting work the user already cancelled.
                    if M.abort_epoch(lineage_id) ~= epoch then
                        Manifest.patch(session_id, { status = "interrupted", last_active_at = Manifest.iso_now() }, cwd)
                        Sessions.close_session(child)
                        require("pi.ui.sessions").request_refresh()
                        callback(nil, "sub-session aborted while spawning")
                        return
                    end
                    if not ok then
                        Manifest.patch(session_id, { status = "failed", last_active_at = Manifest.iso_now() }, cwd)
                        Sessions.close_session(child)
                        require("pi.ui.sessions").request_refresh()
                        callback(nil, config_err or "failed to apply sub-session config")
                        return
                    end
                    send_task(child, opts.task, function(sent_ok)
                        if sent_ok then
                            require("pi.ui.sessions").request_refresh()
                            callback(child, nil)
                        else
                            Manifest.patch(session_id, { status = "failed", last_active_at = Manifest.iso_now() }, cwd)
                            Sessions.close_session(child)
                            callback(nil, "failed to send task to sub-session")
                        end
                    end)
                end)
            end

            -- Wait for backend session id via get_state.
            child.rpc:send({ type = "get_state" }, function(res)
                vim.schedule(function()
                    if M.abort_epoch(lineage_id) ~= epoch then
                        unreserve()
                        Sessions.close_session(child)
                        callback(nil, "sub-session aborted while spawning")
                        return
                    end
                    if not res.success or not res.data then
                        unreserve()
                        Sessions.close_session(child)
                        callback(nil, "failed to capture sub-session state")
                        return
                    end
                    local sid = res.data.sessionId
                    if type(sid) ~= "string" or sid == "" then
                        unreserve()
                        Sessions.close_session(child)
                        callback(nil, "backend did not report session id")
                        return
                    end
                    Sessions.ensure_id(child, sid)
                    if type(res.data.sessionFile) == "string" and res.data.sessionFile ~= "" then
                        child.session_file = res.data.sessionFile
                    end
                    register_and_run(sid)
                end)
            end)
        end

        -- Isolate the child before starting its process: a failed worktree
        -- creation drops the spawn reservation and reports the error instead of
        -- letting the child work in the parent's checkout.
        prepare_worktree(parent, nil, function(wt, child_cwd, wt_err)
            if wt_err then
                unreserve()
                callback(nil, wt_err)
                return
            end
            if M.abort_epoch(lineage_id) ~= epoch then
                -- Freshly created and still empty: nobody owns it yet.
                release_worktree_info(wt)
                unreserve()
                callback(nil, "sub-session aborted while spawning")
                return
            end
            start_child(wt, child_cwd)
        end)
    end)
end

---@param child_id string
---@param callback fun(ok: boolean, err: string?)
---@param opts? { tab?: pi.TabId }
function M.switch_to(child_id, callback, opts)
    opts = opts or {}
    local tab = opts.tab or vim.api.nvim_get_current_tabpage()
    if vim.api.nvim_get_current_tabpage() ~= tab then
        vim.api.nvim_set_current_tabpage(tab)
    end
    local current = Sessions.get_for_tab(tab)
    if not current then
        callback(false, "no active session on this tab")
        return
    end
    local chat = current.chat
    if not chat then
        callback(false, "no chat UI")
        return
    end
    local child = Sessions.get_by_id(child_id)
    if child and child.rpc:is_running() then
        M._bind_and_load(current, child, tab, chat, callback)
        return
    end
    M.revive(child_id, function(revived, err)
        if not revived then
            callback(false, err or "sub-session not found")
            return
        end
        M._bind_and_load(current, revived, tab, chat, callback)
    end)
end

---@param current pi.Session Tab's current session (parent or sibling child).
---@param child pi.Session
---@param tab pi.TabId
---@param chat pi.Chat
---@param callback fun(ok: boolean, err: string?)
function M._bind_and_load(current, child, tab, chat, callback)
    local root_parent_id = current.view_parent_id or current.id
    child.view_parent_id = root_parent_id
    Sessions.bind_chat(child, chat, tab)
    require("pi.ui.sessions").mark_child_completion_seen(child.id)
    local parent_sess = Sessions.get_by_id(root_parent_id) or current
    local parent_name = parent_sess.session_file and require("pi.sessions.history").parse(parent_sess.session_file)
    local label = parent_name and parent_name.name or "parent"
    chat:set_subsession_breadcrumb(label, root_parent_id)
    -- The backend-reported file is authoritative; the lookup covers a child
    -- whose process has not reported one yet, searching the child's own
    -- workspace (its worktree) rather than Neovim's cwd.
    -- The file that *belongs to this child id* is authoritative for a view
    -- switch: when the live process is on a different file, `switch_session`
    -- must move it back. `session_file` is the fallback for a child whose file
    -- was not found (not yet flushed, or a resumed id).
    local disk_path = Read.find_path(child.id, { cwd = Manifest.workspace(child) })
    local path = disk_path or child.session_file
    reattach_or_load(child, path, callback)
end

--- Switch current tab back to the parent session.
---@param callback fun(ok: boolean, err?: string)
---@param opts? { for_new_session?: boolean } When true, bind the parent and clear child history without reloading the parent file (used by `/new`).
function M.switch_to_parent(callback, opts)
    opts = opts or {}
    local current = Sessions.get()
    if not current or not current.view_parent_id then
        callback(false, "not in a sub-session view")
        return
    end
    local parent = Sessions.get_by_id(current.view_parent_id)
    if not parent or not parent.rpc:is_running() then
        callback(false, "parent session not running")
        return
    end
    local tab = current.attached_tab
    local chat = current.chat
    if not tab or not chat then
        callback(false, "no chat")
        return
    end
    Sessions.bind_chat(parent, chat, tab)
    chat:clear_subsession_breadcrumb()
    parent.view_parent_id = nil
    if opts.for_new_session then
        chat:clear()
        callback(true)
        return
    end
    local disk_path = Read.find_path(parent.id, { cwd = parent.cwd })
    local path = disk_path or parent.session_file
    reattach_or_load(parent, path, callback)
end

--- Resolve the registry session behind a child id, tolerating the revive
--- id-migration window.
---
--- `M.revive` pins the registry key to the manifest id via
--- `Sessions.ensure_id(child, child_id)`, but the pre-switch `get_state`
--- response of the freshly spawned process carries the new process's
--- self-generated sessionId, and `capture_session_id` →
--- `migrate_session_id` (sessions/manager.lua) migrates the key away; the
--- post-switch `get_state` migrates it back one round-trip later. Inside that
--- window `Sessions.get_by_id(child_id)` returns nil while the process is
--- still alive. Fall back to matching the revive-loaded session file
--- (`Read.find_path(child_id)` — the manifest id's JSONL on disk, still
--- reported as `session_file` by the child in that window) among registered
--- *child* sessions (`parent_id ~= nil`), so a close during the window still
--- stops the process instead of stranding a live process under a dormant
--- manifest row (which the reaper would skip forever).
---
--- Only `M.close` consults this fallback; other lookups keep the strict id match.
---@param child_id string Manifest child session id.
---@return pi.Session? session Registry session to close, or nil when none resolves.
local function resolve_child(child_id)
    local session = Sessions.get_by_id(child_id)
    if session then
        return session
    end
    -- The row names the workspace and the recorded transcript, which is what
    -- makes the lookup work when Neovim's cwd is somewhere else entirely.
    local entry, manifest_cwd = Manifest.locate(child_id)
    local path = manifest_session_file(entry)
    if not path then
        local recorded = entry_worktree(entry)
        path = Read.find_path(child_id, { cwd = (type(recorded) == "table" and recorded.path) or manifest_cwd })
    end
    if not path or path == "" then
        path = Read.find_path(child_id)
    end
    if not path or path == "" then
        return nil
    end
    for _, s in ipairs(Sessions.list_all()) do
        if s.parent_id ~= nil and type(s.session_file) == "string" and same_resolved_path(s.session_file, path) then
            return s
        end
    end
    return nil
end

--- Close sub-session process (file retained).
---@param child_id string
---@param callback? fun(ok: boolean)
---@return boolean stopped True when a running RPC process was stopped.
function M.close(child_id, callback)
    local stopped = false
    local child = resolve_child(child_id)
    -- The integration engine owns the child's checkout while it is queued /
    -- resolving / applying: closing the process or dropping the row now would
    -- race it (and the manager would release the directory under its feet).
    local entry, workspace = Manifest.locate(child_id, Manifest.workspace(child))
    if Manifest.integration_busy(entry) then
        if callback then
            callback(false)
        end
        return false
    end
    if child and child.rpc:is_running() then
        Sessions.close_session(child)
        stopped = true
    end
    -- The row lives in the child's manifest workspace (the parent's cwd); with no
    -- registry row left, `Manifest.patch` locates it across workspaces.
    Manifest.patch(
        child_id,
        { status = "dormant", last_active_at = Manifest.iso_now() },
        workspace or Manifest.workspace(child)
    )
    require("pi.ui.sessions").request_refresh()
    if callback then
        callback(true)
    end
    return stopped
end

--- Revive a dormant sub-session (spawn process + switch_session).
--- Subject to `subagent.max_children` quota and auto-reaps the oldest settled
--- child of the same lineage to make room when slots are saturated.
---
--- The row is located across workspaces first: a revive driven from the sessions
--- list or an Agent dispatch can run with Neovim's cwd in another checkout than
--- the parent's. Every manifest write below then targets the workspace that owns
--- the row, so the revived child stays consistent with its spawn-time record.
---@param child_id string
---@param callback fun(session: pi.Session?, err: string?)
function M.revive(child_id, callback)
    -- A revived process is a new run on the existing row, so the generation moves
    -- forward (see FIRST_RUN_GENERATION); the live-reuse path below does not bump
    -- — it continues the run that is already in flight.
    local entry, manifest_cwd = Manifest.locate(child_id)
    if type(entry) ~= "table" then
        callback(nil, "session file not found")
        return
    end
    local generation = (type(entry.run_generation) == "number" and entry.run_generation or 0) + 1
    if not manifest_cwd then
        local recorded_workspace = (entry --[[@as table]]).workspace
        if type(recorded_workspace) == "string" and recorded_workspace ~= "" then
            manifest_cwd = recorded_workspace
        end
    end
    -- Reuse an already-live process for this id instead of starting a second
    -- one: two processes on the same session file race its JSONL, and the caller
    -- (switch / dispatch / UI) only wants a usable session. No transcript lookup
    -- is needed — the running process already owns its file.
    local live = resolve_child(child_id)
    if live and live.rpc and live.rpc:is_running() then
        local workspace = manifest_cwd or Manifest.workspace(live)
        live.manifest_cwd = workspace
        Manifest.patch(child_id, { status = "active", last_active_at = Manifest.iso_now() }, workspace)
        callback(live, nil)
        return
    end

    local recorded = entry_worktree(entry)
    -- The transcript lives in the child's own workspace — its worktree when it
    -- has one — which can differ from the manifest workspace.
    local transcript_cwd = (type(recorded) == "table" and recorded.path) or manifest_cwd
    -- Prefer the session file recorded at spawn/revive; fall back to a lookup for
    -- rows written before `session_file` was tracked.
    local path = manifest_session_file(entry) or Read.find_path(child_id, { cwd = transcript_cwd })
    if not path then
        callback(nil, "session file not found")
        return
    end
    local lineage_id = entry.parent_id
    if type(lineage_id) ~= "string" or lineage_id == "" then
        callback(nil, "sub-session parent lineage not found")
        return
    end
    local subcfg = Config.options.subagent or {}
    if subcfg.enabled == false then
        callback(nil, "subagent disabled")
        return
    end

    local max = subcfg.max_children or 5
    if not Manifest.try_reserve_spawn(lineage_id, max, M.is_child_process_alive, manifest_cwd) then
        -- Slot pressure: auto-reap the oldest settled child to make room.
        if
            Reaper.reap_oldest_settled(lineage_id, 1, nil, manifest_cwd) == 0
            or not Manifest.try_reserve_spawn(lineage_id, max, M.is_child_process_alive, manifest_cwd)
        then
            callback(nil, ("max %d concurrent sub-sessions"):format(max))
            return
        end
    end
    local held = true
    local function unreserve()
        if held then
            held = false
            Manifest.release_spawn(lineage_id)
        end
    end

    local tab = vim.api.nvim_get_current_tabpage()
    -- A revived child keeps its own worktree when it still exists (dirty work
    -- included); a child whose worktree is gone is re-isolated the same way a
    -- fresh spawn is, and never nests inside a parent that already runs in one.
    local base = Sessions.find_by_lineage(lineage_id) --[[@as pi.SubsessionWorktreeBase?]]
    if not base and manifest_cwd then
        -- The parent process is not live (revive from the sessions list), but the
        -- manifest workspace is still the base a replacement checkout comes from.
        base = { cwd = manifest_cwd }
    end
    prepare_worktree(base, recorded, function(wt, child_cwd, wt_err)
        if wt_err then
            unreserve()
            callback(nil, wt_err)
            return
        end
        local child = Sessions.create_detached(tab, {
            subagent = false,
            cwd = child_cwd,
            worktree = wt,
        })
        if not child then
            unreserve()
            release_worktree_info(wt)
            callback(nil, "failed to start process")
            return
        end
        if wt then
            child.worktree = wt
        end
        child.manifest_cwd = manifest_cwd
        child.run_generation = generation
        Sessions.ensure_id(child, child_id)
        unreserve()
        child.parent_id = entry.parent_id
        -- A revive can rebuild the checkout (the recorded one was gone): record
        -- the worktree this run actually uses, plus the transcript, so the next
        -- revive reuses it and settle/release bookkeeping stays accurate.
        if wt then
            Manifest.patch(child_id, { worktree = wt, session_file = path, workspace = manifest_cwd }, manifest_cwd)
        end
        bind_worktree(wt, child_id, path)
        Sessions.load_session_path(child, path, function(ok)
            if ok then
                -- `integration` is deliberately not in this patch: a resume keeps
                -- the recorded integration outcome (applied / queued / needs
                -- attention) so the parent can still report what happened to that
                -- checkout, and the engine can reconcile it.
                Manifest.patch(child_id, {
                    status = "active",
                    last_active_at = Manifest.iso_now(),
                    run_generation = generation,
                    session_file = child.session_file or path,
                    worktree = wt or recorded,
                    workspace = manifest_cwd,
                }, manifest_cwd)
                callback(child, nil)
            else
                unreserve()
                Sessions.close_session(child)
                callback(nil, "failed to switch session")
            end
        end, { rebind_parent_context = false })
    end)
end

--- Adopt a child's own session title as its manifest name.
---
--- The bundled extensions/title.ts names every unnamed session after its first
--- turn (pi.setSessionName), which the backend reports back as
--- session_info_changed — including for child processes. Parenting that onto
--- the manifest is what gives an unnamed child a readable row in :PiSessions,
--- the :PiSubSwitch / :PiSubView pickers and the completion notice, instead of
--- the truncated task prefix derived at spawn time.
---
--- Only derived names are replaced (Manifest.is_derived_name): an explicitly
--- supplied name always wins. No-op when the name already matches.
---@param session pi.Session
---@param name string? Backend session name from the event.
---@return boolean changed True when the manifest was updated; the caller refreshes the UI.
function M.on_child_session_name(session, name)
    if type(session) ~= "table" or type(name) ~= "string" or name == "" then
        return false
    end
    local id = session.id
    if type(id) ~= "string" or id == "" then
        return false
    end
    local entry, workspace = Manifest.locate(id, Manifest.workspace(session))
    if type(entry) ~= "table" or entry.parent_id == nil then
        return false
    end
    if entry.name == name or not Manifest.is_derived_name(entry) then
        return false
    end
    Manifest.patch(id, { name = name, name_source = "auto" }, workspace)
    return true
end

--- Called on child agent_settled — inject completion report into parent.
---
--- `aborted` is the authoritative cancel signal added in pi >= 1.1.0
--- (`agent_settled.aborted`). Older pi omits the field, so the run's abort
--- state falls back to the session file's last stop reason; the per-child
--- generation watermark stays the guard that keeps a late settle of an aborted
--- run from touching a newer run on the same child.
---@param child pi.Session
---@param aborted? boolean
function M.on_child_settled(child, aborted)
    local SessionList = require("pi.ui.sessions")

    -- The child's row lives in the parent's workspace (`manifest_cwd`, set at
    -- spawn/revive), never in the child's own worktree cwd. A child registered
    -- before this field existed, or a row living elsewhere, is located: a settle
    -- that misses the row leaves its batch running forever.
    local manifest_cwd = Manifest.workspace(child)
    local entry = Manifest.load(manifest_cwd)[child.id]
    if type(entry) ~= "table" then
        local located, located_cwd = Manifest.locate(child.id, manifest_cwd)
        if type(located) ~= "table" then
            return
        end
        entry = located
        if located_cwd then
            manifest_cwd = located_cwd
            child.manifest_cwd = located_cwd
        end
    end

    local function after_completed(parent)
        if child.chat then
            SessionList.mark_child_completion_seen(child.id)
        end
        SessionList.request_refresh()
        if parent then
            SessionList.acknowledge_reported_children_for_current_tab(parent)
        end
        -- Manifest is settled: arm the idle reaper (fire-time re-checks all
        -- conditions; a failure here must never break settle handling).
        pcall(Reaper.schedule, child.id, manifest_cwd)
    end

    -- Transcript: the backend-reported file is what the child is actually
    -- writing to (it can live in the child's own worktree workspace); the row's
    -- recorded file, then an id lookup in the child's workspace, cover a process
    -- that has not reported one yet.
    local path = child.session_file
    if type(path) ~= "string" or path == "" then
        path = manifest_session_file(entry)
    end
    if type(path) ~= "string" or path == "" then
        path = Read.find_path(child.id, { cwd = child.cwd or manifest_cwd })
    end
    local report = path and Read.last_assistant_message(path) or nil
    -- Prefer the event field when present; only read the file on older pi.
    local was_aborted = aborted == true or (path ~= nil and Read.last_stop_reason(path) == "aborted")
    -- A crashed process lands here with the manager having patched the row
    -- `failed` first; a run that failed on its own ends the same way.
    local run_failed = entry.status == "failed"
    local parent = Sessions.find_by_lineage(entry.parent_id)

    --- Finish the settle: batch accounting, manifest status, parent report.
    ---
    --- Runs **after** the integration engine reported (see the dispatch at the
    --- end of this function), so the batch item the parent observes already
    --- carries `integration` and a waiting call returns an applied / queued /
    --- needs_attention result instead of a bare "ok".
    ---@param integration table? engine outcome
    local function finish_settle(integration)
        if type(integration) == "table" and type(integration.state) ~= "string" then
            -- The parent tool result must always be able to name a state.
            integration.state = "needs_attention"
        end
        -- A failed run stays failed: the later patches below must not flip a
        -- crashed/failed child's row to `completed`.
        local final_status = run_failed and "failed" or "completed"

        --- Row patch that also records the integration outcome (when there is one).
        ---@param patch table
        ---@return table
        local function with_integration(patch)
            if type(integration) == "table" then
                patch.integration = integration
            end
            return patch
        end

        if was_aborted then
            -- Settle the aborted run's own items (waking a parent blocked in
            -- wait_subagents) without touching a newer run: prefer the recorded
            -- abort watermark over the manifest generation, which the parent may
            -- already have bumped by reusing this child.
            --
            -- An aborted run is never integrated automatically: the user
            -- cancelled the work, so its items report `skipped` and its worktree
            -- is left exactly as it was (the row keeps no integration record).
            local watermark = M.aborted_generation(child.id)
            local current = type(entry.run_generation) == "number" and entry.run_generation or nil
            Batch.interrupt_items_for_child(child.id, {
                generation = watermark or current,
                reason = "cancelled: aborted by user",
                cwd = manifest_cwd,
                integration = { state = "skipped", reason = "aborted" },
            })
            -- When the child was already reused for a newer run this settle belongs
            -- to the aborted run only: leave the live run's manifest status alone.
            if not (watermark and current and current > watermark) then
                Manifest.patch(child.id, {
                    status = "interrupted",
                    last_report = report,
                    last_active_at = Manifest.iso_now(),
                }, manifest_cwd)
            end
            after_completed(parent)
            return
        end

        local claimed = Batch.on_child_settled(child.id, manifest_cwd, integration)

        -- Agent tool path or a running batch item: skip parent prompt injection.
        if entry.agent_spawned or claimed then
            Manifest.patch(
                child.id,
                with_integration({
                    status = final_status,
                    last_report = report,
                    last_active_at = Manifest.iso_now(),
                }),
                manifest_cwd
            )
            after_completed(parent)
            return
        end

        if entry.reported then
            -- Already reported by an earlier settle: still record a (late)
            -- integration outcome instead of dropping it on the floor.
            if type(integration) == "table" then
                Manifest.patch(child.id, with_integration({}), manifest_cwd)
            end
            after_completed(parent)
            return
        end

        if not path then
            return
        end
        if not report or report == "" then
            Manifest.patch(
                child.id,
                with_integration({ status = final_status, last_active_at = Manifest.iso_now() }),
                manifest_cwd
            )
            after_completed(parent)
            return
        end
        if not parent or not parent.rpc:is_running() then
            Manifest.patch(
                child.id,
                with_integration({
                    status = final_status,
                    last_report = report,
                    last_active_at = Manifest.iso_now(),
                }),
                manifest_cwd
            )
            after_completed(parent)
            return
        end
        local msg = require("pi.subsessions.tool_ui").completion_report(entry.name, report)
        parent.rpc:send({ type = "prompt", message = msg }, function(res)
            vim.schedule(function()
                if res.success then
                    Manifest.patch(
                        child.id,
                        with_integration({
                            status = final_status,
                            reported = true,
                            last_report = report,
                            last_active_at = Manifest.iso_now(),
                        }),
                        manifest_cwd
                    )
                else
                    Manifest.patch(
                        child.id,
                        with_integration({
                            status = final_status,
                            last_report = report,
                            last_active_at = Manifest.iso_now(),
                        }),
                        manifest_cwd
                    )
                end
                SessionList.request_refresh()
                SessionList.acknowledge_reported_children_for_current_tab(parent)
                -- Prompt-injection path patched the manifest last: arm the reaper here too.
                pcall(Reaper.schedule, child.id, manifest_cwd)
            end)
        end)
    end

    -- Integration runs **first**: the engine must see the settle before the
    -- batch accounting and before any waiter is woken, so the parent's tool
    -- result (and a blocked `wait_subagents`) already carries the child's
    -- integration state. The engine may be asynchronous (it has to run git), so
    -- the rest of the settle waits for its `done` callback.
    if was_aborted or run_failed or not integration_auto() then
        -- Aborted and failed runs are never integrated automatically: the user
        -- cancelled, or the child died half-way, so applying its checkout to the
        -- parent would ship unfinished work. No integration record is written
        -- (`finish_settle(nil)`), the worktree stays on disk for diagnosis, and
        -- the row keeps its `interrupted` / `failed` status.
        finish_settle(nil)
        return
    end
    local mod = integration_mod()
    if not mod or type(mod.on_child_settled) ~= "function" then
        finish_settle(nil)
        return
    end
    local called = false
    ---@param state string? engine outcome or persisted state name
    ---@param record table? persisted integration record
    local function done(state, record)
        if called then
            return
        end
        called = true
        finish_settle(integration_outcome(state, record))
    end
    local ok, err = pcall(mod.on_child_settled, child, entry, manifest_cwd, done)
    if not ok then
        finish_settle({ state = "needs_attention", error = tostring(err) })
    end
end

--- Session files of one workspace, newest first: an id → path index.
---
--- Built from the directory that holds the manifest (one glob plus one header
--- parse per file) rather than `History.list(cwd)`, because a scope discovered
--- on disk has no cwd to pass. Entries whose file is gone (the common dormant
--- case in a long-lived project) must not each pay a fallback full scan through
--- find_path — that was the O(children × sessions) freeze of issue #110.
---@param scope pi.SubsessionScope
---@return table<string, string>
local function scope_session_index(scope)
    local History = require("pi.sessions.history")
    local index = {}
    if scope.cwd then
        -- Known workspace: `History.list` is newest-first, so keeping the first
        -- match for an id preserves find_path's newest-file semantics.
        for _, info in ipairs(History.list(scope.cwd)) do
            if index[info.id] == nil then
                index[info.id] = info.path
            end
        end
        return index
    end
    -- Workspace discovered on disk (no cwd to hand to History.list): index the
    -- directory that holds the manifest, newest file first for the same reason.
    local dir = vim.fn.fnamemodify(scope.path, ":h")
    local paths = vim.fn.glob(dir .. "/*.jsonl", false, true)
    table.sort(paths, function(a, b)
        local ma, mb = vim.fn.getftime(a), vim.fn.getftime(b)
        if ma ~= mb then
            return ma > mb
        end
        return a > b
    end)
    for _, path in ipairs(paths) do
        local info = History.parse(path)
        if info and type(info.id) == "string" and info.id ~= "" and index[info.id] == nil then
            index[info.id] = path
        end
    end
    return index
end

--- Rebuild one workspace's statuses (manifest + batches that live beside it).
--- The manifest is only written back when something actually changed: a rebuild
--- that finds every entry already consistent must not rewrite a potentially
--- large file on every startup (write amplification + mtime churn for backup
--- tools).
---@param scope pi.SubsessionScope
local function rebuild_scope(scope)
    local manifest = Manifest.load_at(scope.path)
    if Manifest.decode_failed_at(scope.path) then
        -- The on-disk manifest did not decode: the in-memory table is not
        -- backed by the file, so saving would overwrite the real manifest
        -- (typically with an empty table, destroying all sub-session
        -- metadata). Surface the corruption instead of silently wiping it.
        Notify.error(
            ("Sub-session manifest is corrupt (%s); skipping status rebuild (not overwriting the file)"):format(
                scope.path
            )
        )
        return
    end
    local index ---@type table<string, string>?
    local changed = false
    for id, entry in pairs(manifest) do
        if Manifest.is_entry_id(id) and type(entry) == "table" and entry.parent_id ~= nil then
            -- The transcript recorded at spawn/revive wins: a child in its own
            -- worktree keeps its JSONL there, not in the parent's workspace.
            local path = manifest_session_file(entry)
            if not path then
                index = index or scope_session_index(scope)
                path = index[id]
            end
            if not path then
                if entry.status == "active" then
                    entry.status = "dormant"
                    changed = true
                end
            else
                local mtime = tostring(os.date("!%Y-%m-%dT%H:%M:%SZ", vim.fn.getftime(path)))
                if entry.last_active_at ~= mtime then
                    entry.last_active_at = mtime
                    changed = true
                end
                local inferred = Read.infer_run_status(path)
                if inferred == "completed" then
                    if entry.status ~= "completed" then
                        entry.status = "completed"
                        changed = true
                    end
                elseif inferred == "interrupted" then
                    if entry.status ~= "interrupted" then
                        entry.status = "interrupted"
                        changed = true
                    end
                end
                local live = Sessions.get_by_id(id)
                if live and live.rpc:is_running() then
                    if entry.status ~= "active" then
                        entry.status = "active"
                        changed = true
                    end
                elseif entry.status == "active" then
                    entry.status = "dormant"
                    changed = true
                end
            end
            manifest[id] = entry
        end
    end
    if changed then
        Manifest.save_at(manifest, scope.path)
    end
    -- Batches live next to the manifest; a known workspace goes through the
    -- cwd API (which honours any path override), a discovered one by path.
    if scope.cwd then
        pcall(Batch.rebuild, scope.cwd)
    else
        pcall(Batch.rebuild_at, Batch.path_for_manifest(scope.path))
    end
end

--- Rebuild manifest statuses after Neovim restart, for **every** workspace.
---
--- The scopes come from `Manifest.scopes`: Neovim's cwd, every live session's
--- workspace (a tab may run in a worktree checkout), and every manifest found on
--- disk — a workspace whose sessions are all dormant still gets its statuses and
--- batches reconciled, which a process-cwd-only rebuild silently skipped.
function M.rebuild_statuses()
    -- Setup entry (invoked once from pi.setup): start the periodic idle sweep.
    pcall(Reaper.start)
    local seen = {}
    for _, scope in ipairs(Manifest.scopes({ disk = true })) do
        if not seen[scope.path] then
            seen[scope.path] = true
            pcall(rebuild_scope, scope)
        end
    end
    -- Engine reconciliation runs **after** the statuses are rebuilt (it reads
    -- them), and retention runs **after** reconcile completes (it must not race
    -- an integration that is still resolving). `enforce_retention` — not the
    -- orphan backstop — is what eventually removes `applied` checkouts.
    local mod = integration_mod()
    if not mod or type(mod.reconcile) ~= "function" then
        return
    end
    local function enforce()
        integration_call("enforce_retention")
    end
    local ok = pcall(mod.reconcile, function()
        -- `reconcile` may call back synchronously; never re-enter the engine
        -- from inside its own stack.
        vim.schedule(enforce)
    end)
    if not ok then
        enforce()
    end
end

--- Host bridge for subagent.ts (`__pi_subagent__` select tunnel).
---@param parent pi.Session
---@param payload string JSON { action, params }
---@param on_done? fun(result: table) When set, long-running actions complete asynchronously.
---@return table? Immediate result for sync-only callers (tests).
function M.handle_host(parent, payload, on_done)
    local ok, req = pcall(vim.json.decode, payload)
    if not ok or type(req) ~= "table" or type(req.action) ~= "string" then
        local err = { error = "invalid host request" }
        if on_done then
            on_done(err)
            return
        end
        return err
    end
    local action = req.action
    local params = req.params or {}

    -- Every row this bridge reads or writes (batches, manifest rows) belongs to
    -- the parent session's workspace, not to Neovim's cwd: the parent may run in
    -- a worktree checkout, and the pi process reports that cwd as `process.cwd()`.
    local cwd = Manifest.workspace(parent)
    local lineage = Manifest.lineage_for_session(parent, cwd)
    if lineage == "" then
        lineage = parent.id
    end

    if action == "dispatch_subagents" then
        local function finish(result)
            if on_done then
                on_done(result)
            end
        end
        Batch.dispatch(parent, {
            items = params.items or {},
            cancel_siblings_on_fail = params.cancel_siblings_on_fail,
        }, function(result)
            if result.error or params.wait ~= true or not result.batch_id then
                finish(result)
                return
            end
            -- The parent is about to block: mark it (clearable via the depth
            -- counter) and let the engine drive its queue, so an applied result
            -- reaches this waiting call rather than a separate prompt.
            begin_parent_wait(parent)
            Batch.wait(result.batch_id, function(snapshot)
                end_parent_wait(parent)
                finish(snapshot)
            end, { timeout_ms = params.timeout_ms, owner = lineage, cwd = cwd })
        end)
        return
    end

    if action == "poll_subagents" then
        local batch_id = params.batch_id
        if type(batch_id) ~= "string" or batch_id == "" then
            local err = { error = "batch_id required" }
            if on_done then
                on_done(err)
            else
                return err
            end
            return
        end
        local snap = Batch.poll(batch_id, cwd)
        local result = snap or { error = "batch not found" }
        if on_done then
            on_done(result)
        else
            return result
        end
        return
    end

    if action == "wait_subagents" then
        local batch_id = params.batch_id
        if type(batch_id) ~= "string" or batch_id == "" then
            local err = { error = "batch_id required" }
            if on_done then
                on_done(err)
            else
                return err
            end
            return
        end
        begin_parent_wait(parent)
        Batch.wait(batch_id, function(result)
            -- Cleared on settle **and** on timeout: both arrive through here, so
            -- the marker can never outlive the wait.
            end_parent_wait(parent)
            if on_done then
                on_done(result)
            end
        end, { timeout_ms = params.timeout_ms, owner = lineage, cwd = cwd })
        return
    end

    if action == "list_batches" then
        local function finish(result)
            if on_done then
                on_done(result)
            end
            return result
        end
        if not on_done and type(parent.id) == "string" and parent.id ~= "" then
            local current = Manifest.lineage_for_session(parent, cwd)
            return finish({ batches = Batch.list_for_parent(current ~= "" and current or parent.id, cwd) })
        end
        with_parent_id(parent, function(parent_id)
            if parent_id == "" then
                finish({ batches = {} })
                return
            end
            Manifest.bind_session_lineage(parent, parent_id, cwd)
            local current = Manifest.lineage_for_session(parent, cwd)
            finish({ batches = Batch.list_for_parent(current ~= "" and current or parent_id, cwd) })
        end)
        return
    end

    if action == "stop_subagents" then
        local targets = params.targets
        if type(targets) ~= "table" or #targets == 0 then
            local err = { error = "targets required" }
            if on_done then
                on_done(err)
            else
                return err
            end
            return
        end
        local stopped = 0
        for _, target in ipairs(targets) do
            if type(target) == "string" and target ~= "" then
                if M.close(target) then
                    stopped = stopped + 1
                end
            end
        end
        local result = { ok = true, stopped = stopped }
        if on_done then
            on_done(result)
        else
            return result
        end
        return
    end

    local err = { error = "unknown action: " .. action }
    if on_done then
        on_done(err)
        return
    end
    return err
end

--- User command: create sub-session interactively.
function M.sub_new()
    local parent = Sessions.get()
    if not parent then
        Notify.warn("No active session")
        return
    end
    Dialog.input({ title = "Sub-session task", kind = "pi-sub-new" }, function(task)
        if not task or task == "" then
            return
        end
        local default_name = Manifest.fallback_name(task) or task
        Dialog.input(
            { title = "Sub-session name (optional)", default = default_name, kind = "pi-sub-new-name" },
            function(name)
                -- Accepting the prefilled default keeps the name *derived*, so the
                -- child's own generated title can still replace it. Only a name
                -- the user actually typed counts as an explicit choice (cancel
                -- passes nil, which spawns with the derived name as before).
                local typed = type(name) == "string" and name ~= "" and name or nil
                local explicit = typed ~= nil and typed ~= default_name
                M.spawn(parent, { task = task, name = explicit and typed or nil }, function(child, err)
                    if child then
                        Notify.info("Sub-session started: " .. (typed or default_name))
                    else
                        Notify.error(err or "failed to spawn sub-session")
                    end
                end)
            end
        )
    end)
end

--- User command: picker to switch to a child sub-session.
function M.sub_switch()
    local parent = Sessions.get()
    if not parent then
        Notify.warn("No active session")
        return
    end
    local root_id = parent.view_parent_id or parent.id
    local root_sess = (root_id and Sessions.get_by_id(root_id)) or parent
    -- The child rows live in the root session's workspace manifest.
    local cwd = Manifest.workspace(root_sess)
    local lineage = Manifest.lineage_for_session(root_sess, cwd)
    local children = Manifest.children_of(lineage, cwd)
    if parent.view_parent_id then
        -- also allow switching among siblings when already in child view
        children = Manifest.children_of(lineage, cwd)
    end
    if #children == 0 then
        Notify.info("No sub-sessions for this conversation")
        return
    end
    ---@type string[]
    local labels = {}
    for _, entry in ipairs(children) do
        labels[#labels + 1] = ("%s · %s"):format(entry.name, entry.status)
    end
    Dialog.select({ title = "Sub-sessions", options = labels, kind = "pi-sub-switch" }, function(choice)
        if not choice then
            return
        end
        local idx = vim.tbl_contains(labels, choice) and vim.fn.index(labels, choice) + 1 or nil
        if not idx then
            for i, l in ipairs(labels) do
                if l == choice then
                    idx = i
                    break
                end
            end
        end
        if not idx then
            return
        end
        local entry = children[idx]
        local child_id = entry and entry._id
        if not child_id then
            return
        end
        M.switch_to(child_id, function(ok, err)
            if not ok then
                Notify.error(err or "switch failed")
            end
        end)
    end)
end

function M.sub_parent()
    M.switch_to_parent(function(ok, err)
        if not ok then
            Notify.warn(err or "cannot return to parent")
        end
    end)
end

function M.sub_close()
    local current = Sessions.get()
    if not current then
        Notify.warn("No active session")
        return
    end
    local in_child_view = current.view_parent_id ~= nil
    local is_child = current.parent_id ~= nil or Manifest.is_child_session(current.id, Manifest.workspace(current))
    if not in_child_view and not is_child then
        Notify.warn("Current session is not a sub-session")
        return
    end
    if in_child_view then
        -- Return to the parent BEFORE closing: M.close detaches the tab, after
        -- which switch_to_parent's Sessions.get() fails and the user is
        -- stranded on a dead child view.
        local child_id = current.id
        M.switch_to_parent(function(ok)
            if ok then
                M.close(child_id)
            else
                Notify.warn("Cannot return to parent; sub-session left running")
            end
        end)
        return
    end
    M.close(current.id)
end

--- User command: picker to view a child sub-session in a read-only float.
function M.sub_view()
    local parent = Sessions.get()
    if not parent then
        Notify.warn("No active session")
        return
    end
    local root_id = parent.view_parent_id or parent.id
    local root_sess = (root_id and Sessions.get_by_id(root_id)) or parent
    local cwd = Manifest.workspace(root_sess)
    local lineage = Manifest.lineage_for_session(root_sess, cwd)
    local children = Manifest.children_of(lineage, cwd)
    if parent.view_parent_id then
        -- also allow switching among siblings when already in child view
        children = Manifest.children_of(lineage, cwd)
    end
    if #children == 0 then
        Notify.info("No sub-sessions for this conversation")
        return
    end
    ---@type string[]
    local labels = {}
    for _, entry in ipairs(children) do
        labels[#labels + 1] = ("%s · %s"):format(entry.name, entry.status)
    end
    Dialog.select({ title = "View Sub-session", options = labels, kind = "pi-sub-view" }, function(choice)
        if not choice then
            return
        end
        local idx = vim.tbl_contains(labels, choice) and vim.fn.index(labels, choice) + 1 or nil
        if not idx then
            for i, l in ipairs(labels) do
                if l == choice then
                    idx = i
                    break
                end
            end
        end
        if not idx then
            return
        end
        local entry = children[idx]
        local child_id = entry and entry._id
        if not child_id then
            return
        end
        M.preview(child_id, cwd)
    end)
end

--- Preview sub-session in a read-only float viewer.
--- Upgrade of the original raw-text preview: now renders full chat history
--- with tool blocks, thinking, markdown, and live streaming support.
---@param child_id string
---@param cwd? string workspace whose manifest holds the child's row (default: locate it)
function M.preview(child_id, cwd)
    require("pi.ui.subsession_viewer").open(child_id, { cwd = cwd })
end

--- Test-only: exported for unit tests.
M._format_available_models = format_available_models

return M
