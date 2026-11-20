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
--- (revive) increments it, so a settle that belongs to a superseded run can be
--- told apart from the current one.
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
---@field tools? string[] Tool allowlist for this child (default: `subagent.tools`, then nil = every tool).
---@field agent_spawned? boolean Block completion prompt injection (Agent tool path).
---@field worktree? pi.SubsessionWorktreeRequest Pre-existing linked worktree to run the child in (`{ path }`, shared and never owned), or a checkout to create/adopt (`{ create }`).

--- Resolve the child tool allowlist: per-spawn override, then subagent.tools, then nil (inherit all).
---@param opts { tools?: string[] }
---@return string[]? tools Fresh normalized allowlist, or nil to inherit every tool
---@return string? err Human-readable reason when either source is invalid
local function resolve_child_tools(opts)
    local value = opts.tools
    if value == nil then
        local cfg = Config.options.subagent or {}
        value = cfg.tools
    end
    if value == nil then
        return nil, nil
    end
    local tools, err = Manifest.normalize_tools(value)
    if not tools then
        return nil, err
    end
    return tools, nil
end

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

--- Send the child's task prompt.
---
--- A rejected prompt is a real backend answer (`success: false` plus an
--- `error` such as "No API key found for …"), and that text is the only
--- explanation the parent will ever get: dropping it leaves a useless
--- "failed to send task".
---@param session pi.Session
---@param task string
---@param callback fun(ok: boolean, err?: string)
local function send_task(session, task, callback)
    local sent = session.rpc:send({ type = "prompt", message = task }, function(res)
        local err = type(res.error) == "string" and res.error ~= "" and res.error or nil
        callback(res.success == true, err)
    end)
    if not sent then
        callback(false, nil)
    end
end

--- Mark `parent` as blocked waiting on sub-sessions.
---
--- The marker is a depth counter — one tab/handler can wait while another wait
--- is already open — and it is always cleared by `end_parent_wait` (settle,
--- timeout and synchronous completion all run through the same callback).
---@param parent pi.Session
local function begin_parent_wait(parent)
    local session = parent --[[@as table]]
    session.waiting_subagents = (tonumber(session.waiting_subagents) or 0) + 1
end

--- Clear one wait on `parent`; the marker disappears entirely at depth 0.
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

--- Worktree metadata recorded on a child's manifest row.
---
--- Two shapes share this class:
---   * **owned** — a checkout this spawn created (or recreated on revive) and
---     therefore may release. It lives in the row's `worktree` field and on the
---     session as `session.worktree`.
---   * **adopted / borrowed** — a linked checkout that already existed, named by
---     `create.name` (adopted) or `worktree.path` (borrowed). It is never created,
---     reset or released, and lives on `assigned_worktree`.
---@class pi.SubsessionWorktree
---@field path string Worktree root — the child session cwd.
---@field name? string Worktree name (`sub-<timestamp>-<n>-<pid>` for children).
---@field kind? "linked"|"main"
---@field repo_root? string Main work tree of the repository.
---@field git_dir? string Per-worktree git dir.
---@field common_dir? string Shared git dir.
---@field base_sha? string Commit the worktree was created from.
---@field mode? string Creation mode recorded in the metadata (`"subagent"` for child checkouts).
---@field owned? boolean True when this spawn created the checkout, so it may be released; absent on shared checkouts.
---@field reused? boolean True when an existing checkout was adopted by name instead of created.
---@field base_ignored? boolean True when a `create.base` was ignored because the checkout already existed.
---@field session_id? string pi session bound to the worktree.
---@field session_file? string pi session transcript bound to the worktree.

--- A `worktree` request on a spawn item or the Lua API.
---@class pi.SubsessionWorktreeRequest
---@field path? string Absolute path of an existing linked worktree to borrow (never owned).
---@field create? boolean|{ base?: string, name?: string, setup?: boolean } Create a checkout for this child, or adopt the one `name` already resolves to. `base` is `"head"` (default), `"fresh"`, or any revision; `setup` runs `worktree.setup_cmd` (default `subagent.worktree.setup`).

--- Worktree module, loaded lazily.
---
--- Only releasing a leftover child checkout needs it (the reaper's orphan
--- sweep); when `pi.worktree` cannot be loaded that sweep is simply skipped.
---@return table?
local function worktree_mod()
    local ok, mod = pcall(require, "pi.worktree")
    if ok and type(mod) == "table" then
        return mod
    end
    return nil
end

--- True when `path` is absolute on the current platform.
---
--- Mirrors `pi.worktree`'s `is_abs` (POSIX `/...` plus Windows `C:\...`/
--- `C:/...`). Kept as a pure predicate so the absolute-path rule is testable
--- without a Windows filesystem; the actual `isdirectory`/`detect` checks below
--- still run on the host OS.
---@param path string
---@return boolean
local function is_absolute_path(path)
    return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

--- Validate and normalize a `worktree` request.
---
--- The field takes **either** `{ path }` (borrow an existing linked checkout)
--- **or** `{ create }` (create a checkout for this child, or adopt the one its
--- `name` already resolves to). Exactly one of the two keys must be present:
--- carrying both is ambiguous, carrying neither is not a request. `create =
--- false` is read as "no worktree" so a model can say so explicitly.
---
--- Validation here is shape-only and cheap. The borrow path is fully validated by
--- `resolve_assigned_worktree`; a create request's base/name are validated when
--- the checkout is prepared (that is where `git rev-parse` runs).
---@param raw any `opts.worktree` as supplied
---@return pi.SubsessionWorktreeRequest? request nil when no worktree was requested
---@return string? err Human-readable rejection reason
function M.normalize_worktree_request(raw)
    if raw == nil then
        return nil, nil
    end
    if type(raw) ~= "table" then
        return nil, "worktree must be an object"
    end
    local has_path = raw.path ~= nil
    local create = raw.create
    local has_create = create ~= nil and create ~= false
    if has_path and has_create then
        return nil, "worktree takes either `path` (borrow an existing checkout) or `create`, not both"
    end
    if has_path then
        if type(raw.path) ~= "string" or raw.path == "" then
            return nil, "worktree.path must be a non-empty string"
        end
        return { path = raw.path }, nil
    end
    if not has_create then
        if create == false then
            return nil, nil
        end
        return nil, "worktree needs `path` (an existing linked worktree) or `create`"
    end
    if create == true then
        return { create = true }, nil
    end
    if type(create) ~= "table" then
        return nil, "worktree.create must be a boolean or an object"
    end
    local request = { create = {} }
    if create.base ~= nil then
        if type(create.base) ~= "string" or vim.trim(create.base) == "" then
            return nil, "worktree.create.base must be a non-empty string"
        end
        request.create.base = vim.trim(create.base)
    end
    if create.name ~= nil then
        local mod = worktree_mod()
        if mod and type(mod.validate_name) == "function" then
            local ok, name_err = mod.validate_name(create.name)
            if not ok then
                return nil, name_err
            end
        end
        request.create.name = create.name
    end
    if create.setup ~= nil then
        if type(create.setup) ~= "boolean" then
            return nil, "worktree.create.setup must be a boolean"
        end
        request.create.setup = create.setup
    end
    return request, nil
end

--- Resolve and validate an explicitly assigned worktree.
---
--- The path names an **existing linked worktree**, not a checkout to create:
--- no create/setup/reset/apply/bind/release is ever called for it. It must be
--- absolute (POSIX or Windows drive), exist, be a linked worktree
--- (`kind == "linked"`), and belong to the same repository as the parent
--- workspace (same `common_dir` and `repo_root`). A hand-made/external checkout
--- and a dirty state are both fine — children share it and its writes. The
--- returned table is canonicalized from `Worktree.detect()` (`info.path`), so
--- every consumer keys on the real root.
---@param raw any Requested `{ path: string }` (nil = no assignment).
---@param parent_cwd string? Owner/parent workspace cwd used for the repo check.
---@return pi.SubsessionWorktree? assigned Canonical assignment, or nil when omitted.
---@return string? err Human-readable rejection reason.
local function resolve_assigned_worktree(raw, parent_cwd)
    if raw == nil then
        return nil, nil
    end
    if type(raw) ~= "table" then
        return nil, "worktree must be an object with a `path`"
    end
    local path = raw.path
    if type(path) ~= "string" or path == "" then
        return nil, "worktree.path must be a non-empty string"
    end
    if not is_absolute_path(path) then
        return nil, ("worktree.path must be absolute: %s"):format(path)
    end
    if vim.fn.isdirectory(path) ~= 1 then
        return nil, ("worktree.path is not an existing directory: %s"):format(path)
    end
    local mod = worktree_mod()
    if not mod or type(mod.detect) ~= "function" then
        return nil, "worktree detection is unavailable"
    end
    local info = mod.detect(path)
    if type(info) ~= "table" then
        return nil, ("worktree.path is not a git worktree: %s"):format(path)
    end
    if info.kind ~= "linked" then
        return nil, ("worktree.path is not a linked worktree: %s"):format(info.path or path)
    end
    local parent_info = type(parent_cwd) == "string" and parent_cwd ~= "" and mod.detect(parent_cwd) or nil
    if type(parent_info) ~= "table" then
        return nil, "parent workspace is not a git repository"
    end
    local same_common = type(info.common_dir) == "string"
        and type(parent_info.common_dir) == "string"
        and same_resolved_path(info.common_dir, parent_info.common_dir)
    local same_repo = type(info.repo_root) == "string"
        and type(parent_info.repo_root) == "string"
        and same_resolved_path(info.repo_root, parent_info.repo_root)
    -- `common_dir` is the strongest identity; without one on either side fall
    -- back to the main work tree. Both present and disagreeing is another repo.
    if type(info.common_dir) == "string" and type(parent_info.common_dir) == "string" then
        if not same_common then
            return nil, ("worktree.path belongs to a different repository: %s"):format(info.path or path)
        end
    elseif not same_repo then
        return nil, ("worktree.path belongs to a different repository: %s"):format(info.path or path)
    end
    if type(info.repo_root) == "string" and type(parent_info.repo_root) == "string" and not same_repo then
        return nil, ("worktree.path belongs to a different repository: %s"):format(info.path or path)
    end
    return {
        kind = "linked",
        path = info.path,
        name = type(info.name) == "string" and info.name ~= "" and info.name or nil,
        repo_root = info.repo_root,
        git_dir = info.git_dir,
        common_dir = info.common_dir,
        base_sha = info.base_sha,
    },
        nil
end

--- The repository a sub-session checkout belongs to.
---
--- Creation never runs inside the parent's own checkout: a parent session may
--- itself run in a linked worktree, and `Worktree.create` refuses to nest. The
--- repository's main work tree is the creation cwd, while `head` stays the
--- parent checkout's HEAD — the commits its conversation sees.
---@param parent_cwd string?
---@return string repo_cwd
---@return table? parent_info `Worktree.detect(parent_cwd)` when it is a checkout.
local function repository_scope(parent_cwd)
    local mod = worktree_mod()
    local info = nil
    if mod and type(mod.detect) == "function" and type(parent_cwd) == "string" and parent_cwd ~= "" then
        info = mod.detect(parent_cwd)
    end
    if type(info) == "table" and type(info.repo_root) == "string" and info.repo_root ~= "" then
        return info.repo_root, info
    end
    return parent_cwd or "", nil
end

--- Effective base strategy of a create request: the per-item `base`, else the
--- repository's `.pi-worktrees.toml` `base_ref`, else `worktree.base_ref`, else
--- `head`. The last three are decided by `Worktree.resolve_base` when this
--- answers `""` — one place, so a child checkout and a hand-started worktree of
--- the same repository start from the same commit.
---@param requested string?
---@return string kind An explicit revision, or `""` to defer to `resolve_base`.
local function resolve_base_kind(requested)
    if type(requested) == "string" and vim.trim(requested) ~= "" then
        return vim.trim(requested)
    end
    return ""
end

--- Prepare the checkout a `create` request asks for: adopt the one `name`
--- already resolves to, or create a new one at the resolved base.
---
--- Adoption is what makes a repeated dispatch reuse the work an earlier child
--- left behind: the existing checkout is kept exactly as it is — never reset,
--- rebased, re-checked-out or released — and a `base` given alongside an
--- existing name is **ignored** (reported as `base_ignored`) rather than
--- silently rewriting the state someone worked in.
---@param parent_cwd string?
---@param request pi.SubsessionWorktreeRequest Normalized `{ create = ... }` request.
---@param cb fun(info: pi.SubsessionWorktree?, owned: boolean, base_ignored: boolean, err: string?)
local function resolve_create_target(parent_cwd, request, cb)
    local mod = worktree_mod()
    if not mod or type(mod.create) ~= "function" or type(mod.detect) ~= "function" then
        return cb(nil, false, false, "worktree support is unavailable")
    end
    if type(parent_cwd) ~= "string" or parent_cwd == "" then
        return cb(nil, false, false, "sub-session workspace is unknown")
    end
    local cwd = parent_cwd --[[@as string]]
    local create = type(request.create) == "table" and request.create or {}
    local repo_cwd = repository_scope(cwd)
    local name = create.name
    local target = name and (repo_cwd .. "/.worktrees/" .. name) or nil
    if target and vim.fn.isdirectory(target) == 1 then
        -- Same validation as a borrowed path: an existing linked checkout of the
        -- same repository, canonicalized from git's own metadata. A directory
        -- that is not one of those is an error, never a "replace it".
        local adopted, adopt_err = resolve_assigned_worktree({ path = target }, cwd)
        if not adopted then
            return cb(nil, false, false, adopt_err)
        end
        adopted.reused = true
        adopted.base_ignored = create.base ~= nil
        return cb(adopted, false, create.base ~= nil, nil)
    end
    local kind = resolve_base_kind(create.base)
    mod.resolve_base({ kind = kind, cwd = parent_cwd, repo = repo_cwd }, function(sha, base_err)
        if type(sha) ~= "string" or sha == "" then
            return cb(nil, false, false, base_err or "failed to resolve a base commit")
        end
        -- `setup_cmd` is an expensive, opt-in step for a child checkout: a
        -- dispatch is already paying a `git worktree add` plus the include copy.
        local setup = create.setup
        if setup == nil then
            local subcfg = Config.options.subagent or {}
            setup = type(subcfg.worktree) == "table" and subcfg.worktree.setup == true
        end
        mod.create({
            cwd = repo_cwd,
            name = name,
            mode = "subagent",
            base = sha,
            setup = setup == true,
        }, function(info, create_err)
            if type(info) ~= "table" or type(info.path) ~= "string" or info.path == "" then
                return cb(nil, false, false, create_err or "failed to create the sub-session worktree")
            end
            info.owned = true
            cb(info, true, false, nil)
        end)
    end)
end

--- Assigned worktree recorded on a manifest row, or nil.
---@param entry any
---@return pi.SubsessionWorktree?
local function entry_assigned_worktree(entry)
    if type(entry) ~= "table" or type(entry.assigned_worktree) ~= "table" then
        return nil
    end
    return entry.assigned_worktree
end

--- Resolve the cwd a revived child runs in when no worktree is assigned.
---
--- On **revive**, the default is the owner's manifest workspace cwd: the row
--- lives there and an unassigned child has no recorded cwd of its own. (A
--- fresh spawn instead defaults to the parent's actual cwd, so a nested
--- dispatch from an assigned child stays in that worktree.) An explicitly
--- assigned child bypasses this function entirely and runs in
--- `assigned_worktree.path` while its rows stay in the owner workspace.
---
--- The other exception is a child spawned by an older version, whose row records
--- the checkout it used to run in: while that directory still exists, that
--- recorded cwd is a usable workspace, so a revive keeps running there. Once it
--- is gone the child falls back to the parent's workspace with a single warning.
--- (A checkout the current version created is recreated in place before this is
--- reached — see `recreate_owned_worktree` — so this path only covers rows whose
--- repository or name can no longer be resolved.)
---@param recorded pi.SubsessionWorktree? Checkout recorded on the child's manifest row.
---@param parent_cwd string? Parent workspace cwd (the fallback).
---@return string?
local function resolve_child_cwd(recorded, parent_cwd)
    local path = type(recorded) == "table" and recorded.path or nil
    if type(path) == "string" and path ~= "" then
        if vim.fn.isdirectory(path) == 1 then
            return path
        end
        Notify.warn(
            ("Sub-session checkout %s is gone; the child runs in %s"):format(
                path,
                parent_cwd or "the current directory"
            )
        )
    end
    return parent_cwd
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

--- Recreate a child's owned checkout that no longer exists.
---
--- The transcript records the checkout as its cwd and pi refuses to resume from
--- a missing directory, so a revive recreates it **in place** at the base commit
--- recorded when it was created. A recorded base that no longer resolves
--- (history rewritten, objects pruned) is retried once at the repository HEAD.
--- The caller decides what a failure means; this never blocks a revive.
---@param recorded pi.SubsessionWorktree
---@param parent_cwd string?
---@param cb fun(info: pi.SubsessionWorktree?, err: string?)
local function recreate_owned_worktree(recorded, parent_cwd, cb)
    local mod = worktree_mod()
    if not mod or type(mod.create) ~= "function" then
        return cb(nil, "worktree support is unavailable")
    end
    local path = type(recorded.path) == "string" and recorded.path or ""
    local name = type(recorded.name) == "string" and recorded.name ~= "" and recorded.name
        or (path ~= "" and vim.fs.basename(path) or nil)
    local repo = type(recorded.repo_root) == "string" and recorded.repo_root ~= "" and recorded.repo_root or nil
    if not repo and type(parent_cwd) == "string" and parent_cwd ~= "" then
        repo = repository_scope(parent_cwd)
    end
    if type(name) ~= "string" or name == "" or type(repo) ~= "string" or repo == "" then
        return cb(nil, "cannot locate the repository to recreate the checkout")
    end
    local base = type(recorded.base_sha) == "string" and recorded.base_sha ~= "" and recorded.base_sha or nil
    ---@param sha string?
    ---@param done fun(info: pi.SubsessionWorktree?, err: string?)
    local function attempt(sha, done)
        mod.create({ cwd = repo, name = name, mode = "subagent", base = sha, setup = false }, function(info, err)
            if type(info) == "table" and type(info.path) == "string" and info.path ~= "" then
                info.owned = true
                return done(info, nil)
            end
            done(nil, err)
        end)
    end
    attempt(base, function(info, err)
        if info then
            return cb(info, nil)
        end
        if base and type(err) == "string" and err:find("invalid base commit", 1, true) then
            return attempt(nil, function(retry_info, retry_err)
                cb(retry_info, retry_err)
            end)
        end
        cb(nil, err)
    end)
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
    -- manifest workspace — not necessarily the cwd its process runs in (an
    -- assigned child runs in a shared worktree while its rows stay in the
    -- original owner workspace). Neovim's cwd is never that authority.
    local workspace = Manifest.workspace(parent)
    -- The default child cwd follows the parent's **actual** process cwd, so a
    -- nested dispatch from an assigned child keeps building inside the assigned
    -- worktree. Storage above still uses the owner workspace.
    local parent_cwd = (type(parent.cwd) == "string" and parent.cwd ~= "" and parent.cwd) or workspace
    -- The `worktree` request is normalized before any slot is reserved or a
    -- process started: a malformed request, or a borrow path that does not name
    -- an existing linked checkout, fails fast and untouched. A `create` request
    -- is only resolved later, because creating a checkout costs git calls.
    local wt_req, wt_req_err = M.normalize_worktree_request(opts.worktree)
    if wt_req_err then
        callback(nil, wt_req_err)
        return
    end
    local assigned, assigned_err
    if wt_req and wt_req.path then
        assigned, assigned_err = resolve_assigned_worktree({ path = wt_req.path }, parent_cwd)
        if assigned_err then
            callback(nil, assigned_err)
            return
        end
    end
    --- Checkout this spawn created (owned) — resolved after the slot is held.
    ---@type pi.SubsessionWorktree?
    local owned = nil
    -- Abort epoch of the lineage as it resolves *now*: `with_parent_id` below can
    -- do an id-lookup round-trip, and before that round-trip finishes the parent
    -- may still be keyed by a `tmp-` id. An abort landing in that window bumps
    -- that pre-migration key, so it is captured here as well as after the lookup.
    local entry_lineage = Manifest.lineage_for_session(parent, workspace)
    local entry_epoch = M.abort_epoch(entry_lineage)

    with_parent_id(parent, function(parent_id)
        -- Resolve the tool allowlist before anything is reserved or created, so
        -- a bad `subagent.tools` (or spawn item) fails fast without burning a
        -- child slot or leaving a half-spawned process behind.
        local tools, tools_err = resolve_child_tools(opts)
        if tools_err then
            callback(nil, tools_err)
            return
        end
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

        Manifest.bind_session_lineage(parent, parent_id, workspace)
        local lineage_id = Manifest.lineage_for_session(parent, workspace)
        if lineage_id == "" then
            lineage_id = parent_id
        end
        -- Abort-epoch guard: if the lineage is aborted while the async spawn
        -- chain below is still in flight, the chain bails out instead of
        -- starting a task for a sub-session the user already cancelled.
        local epoch = M.abort_epoch(lineage_id)

        local max = subcfg.max_children or 5
        if not Manifest.try_reserve_spawn(lineage_id, max, M.is_child_process_alive, workspace) then
            -- Slot pressure: auto-reap the oldest settled child to make room.
            if
                Reaper.reap_oldest_settled(lineage_id, 1, nil, workspace) == 0
                or not Manifest.try_reserve_spawn(lineage_id, max, M.is_child_process_alive, workspace)
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
        --- The checkout this child runs in: the borrowed or created one, else the
        --- parent's actual cwd. Computed at launch because a `create` request
        --- resolves asynchronously, after the slot is reserved.
        local function child_cwd()
            return (assigned and assigned.path) or (owned and owned.path) or parent_cwd
        end
        local function start_child()
            local cwd = child_cwd()
            -- Reserve the canonical cwd for the synchronous registration window.
            -- Several children may share one worktree; this only keeps an owner
            -- close from releasing the checkout before the new process is
            -- registered (see release_session_worktree's guard).
            Sessions.reserve_cwd(cwd)
            local ok_create, child = pcall(Sessions.create_detached, tab, {
                subagent = false,
                tools = tools,
                cwd = cwd,
                assigned_worktree = assigned,
                worktree = owned,
            })
            Sessions.release_cwd(cwd)
            if not ok_create or not child then
                unreserve()
                callback(nil, ok_create and "failed to start sub-session process" or tostring(child))
                return
            end
            -- An assignment is never owned: it lives beside `session.worktree`
            -- so release/bind (owned-only) can never touch it.
            child.assigned_worktree = assigned
            child.parent_id = parent_id
            -- Sub-session bookkeeping for this child lives in the parent's
            -- manifest workspace, which may differ from the child's cwd.
            child.manifest_cwd = workspace
            -- First run on a brand-new row. Every later run (revive / reuse)
            -- bumps it, so a settle that belongs to a superseded run is
            -- recognisable.
            child.run_generation = FIRST_RUN_GENERATION

            local config = resolve_child_config(parent, opts)
            -- The manifest's `config` mirrors the pinned model/thinking and records
            -- the tool allowlist, so a revived child gets the same restriction
            -- (`M.revive`). `tools` stays absent rather than empty when the child
            -- inherits everything, keeping old and new manifests the same shape.
            local manifest_config = {}
            if config then
                manifest_config.model = config.model
                manifest_config.thinking_level = config.thinking_level
            end
            if tools then
                manifest_config.tools = tools
            end
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
                    config = manifest_config,
                    status = "active",
                    reported = false,
                    created_at = Manifest.iso_now(),
                    last_active_at = Manifest.iso_now(),
                    agent_spawned = opts.agent_spawned == true,
                    run_generation = FIRST_RUN_GENERATION,
                    session_file = child.session_file,
                    workspace = workspace,
                    assigned_worktree = assigned,
                    worktree = owned,
                }, workspace)
                unreserve()
                apply_config(child, config, function(ok, config_err)
                    -- Abort can land during the config round-trip: the child is in
                    -- the manifest but has not received its task yet, so reclaim it
                    -- instead of starting work the user already cancelled.
                    if M.abort_epoch(lineage_id) ~= epoch then
                        Manifest.patch(
                            session_id,
                            { status = "interrupted", last_active_at = Manifest.iso_now() },
                            workspace
                        )
                        Sessions.close_session(child)
                        require("pi.ui.sessions").request_refresh()
                        callback(nil, "sub-session aborted while spawning")
                        return
                    end
                    if not ok then
                        Manifest.patch(
                            session_id,
                            { status = "failed", last_active_at = Manifest.iso_now() },
                            workspace
                        )
                        Sessions.close_session(child)
                        require("pi.ui.sessions").request_refresh()
                        callback(nil, config_err or "failed to apply sub-session config")
                        return
                    end
                    send_task(child, opts.task, function(sent_ok, send_err)
                        if sent_ok then
                            require("pi.ui.sessions").request_refresh()
                            callback(child, nil)
                        else
                            Manifest.patch(session_id, {
                                status = "failed",
                                last_error = send_err or "failed to send task to sub-session",
                                last_active_at = Manifest.iso_now(),
                            }, workspace)
                            Sessions.close_session(child)
                            callback(
                                nil,
                                send_err and ("failed to send task to sub-session: " .. send_err)
                                    or "failed to send task to sub-session"
                            )
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

        -- A create request pays its git calls here, after the slot is held and
        -- before the process starts; an abort or a failure releases a checkout it
        -- created itself (an adopted one is never ours to remove).
        if wt_req and wt_req.create then
            ---@cast wt_req pi.SubsessionWorktreeRequest
            resolve_create_target(parent_cwd, wt_req, function(info, is_owned, base_ignored, err)
                vim.schedule(function()
                    if not info then
                        unreserve()
                        callback(nil, err or "failed to prepare the sub-session worktree")
                        return
                    end
                    if M.abort_epoch(lineage_id) ~= epoch then
                        if is_owned then
                            release_worktree_info(info)
                        end
                        unreserve()
                        callback(nil, "sub-session aborted while spawning")
                        return
                    end
                    if is_owned then
                        owned = info
                    else
                        assigned = info
                        if base_ignored then
                            Notify.warn(
                                ("Sub-session worktree %s already exists; reusing it as is (base ignored)"):format(
                                    info.path
                                )
                            )
                        end
                    end
                    start_child()
                end)
            end)
            return
        end
        -- No checkout to prepare: the child runs in the parent's workspace, so
        -- the process starts straight away.
        if M.abort_epoch(lineage_id) ~= epoch then
            unreserve()
            callback(nil, "sub-session aborted while spawning")
            return
        end
        start_child()
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
    -- The file that *belongs to this child id* is authoritative for a view
    -- switch: when the live process is on a different file, `switch_session`
    -- must move it back. `session_file` is the fallback for a child whose file
    -- was not found (not yet flushed, or a resumed id).
    --
    -- An assigned child runs in a shared worktree while its manifest row lives
    -- in the owner's workspace, where another transcript can share the same id
    -- prefix. Its readable `session_file` (then its assigned worktree) wins;
    -- only an ordinary/legacy child searches the manifest workspace first.
    local disk_path
    local assigned = child.assigned_worktree
    if type(assigned) == "table" and type(assigned.path) == "string" and assigned.path ~= "" then
        if type(child.session_file) == "string" and vim.fn.filereadable(child.session_file) == 1 then
            disk_path = child.session_file
        else
            disk_path = Read.find_path(child.id, { cwd = assigned.path })
        end
    else
        disk_path = Read.find_path(child.id, { cwd = Manifest.workspace(child) })
    end
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
        -- Prefer the assigned worktree (a shared checkout whose transcript must
        -- not be confused with the owner workspace's files), then the legacy
        -- owned checkout, then the manifest workspace.
        local assigned = entry_assigned_worktree(entry)
        local assigned_path = type(assigned) == "table" and assigned.path or nil
        local recorded = entry_worktree(entry)
        local recorded_path = type(recorded) == "table" and recorded.path or nil
        local lookup_cwd = (type(assigned_path) == "string" and assigned_path ~= "" and assigned_path)
            or (type(recorded_path) == "string" and recorded_path ~= "" and recorded_path)
            or manifest_cwd
        path = Read.find_path(child_id, { cwd = lookup_cwd })
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
    local _, workspace = Manifest.locate(child_id, Manifest.workspace(child))
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
    -- An assigned row must still point at the same existing linked worktree in
    -- the same repository. It is never recreated, replaced or fallen back to
    -- the parent: a missing/moved checkout is a hard revive error.
    local assigned_entry = entry_assigned_worktree(entry)
    local assigned, assigned_err
    if assigned_entry then
        assigned, assigned_err = resolve_assigned_worktree(assigned_entry, manifest_cwd)
        if not assigned then
            callback(nil, assigned_err)
            return
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
    -- Only a checkout the current version **created** for this child (`owned`) is
    -- recreated when it vanished: the transcript records that directory as its
    -- cwd, pi refuses to resume from a missing one, and we can prove we own it.
    -- A row from an older version records a checkout it never owned; that one
    -- keeps the old contract — use it while it exists, otherwise run in the
    -- parent workspace with one warning — because a revive must never resurrect
    -- a checkout we cannot prove we own. An adopted/borrowed checkout is likewise
    -- never recreated (a missing one is a hard error further down).
    local recorded_path = type(recorded) == "table" and recorded.path or nil
    local owns_checkout = type(recorded) == "table" and recorded.owned == true
    if
        not assigned
        and owns_checkout
        and type(recorded_path) == "string"
        and recorded_path ~= ""
        and vim.fn.isdirectory(recorded_path) == 0
    then
        ---@cast recorded pi.SubsessionWorktree
        recreate_owned_worktree(recorded, manifest_cwd, function(info, err)
            if info and vim.fn.isdirectory(info.path) == 1 then
                Manifest.patch(child_id, { worktree = info }, manifest_cwd)
            else
                -- Never block a revive on a checkout that cannot come back: drop
                -- the record (the child then runs in the parent workspace, with
                -- one warning) instead of retrying the same failure forever.
                Manifest.patch(child_id, { worktree = Manifest.REMOVE }, manifest_cwd)
                Notify.warn(
                    ("Sub-session checkout %s could not be recreated (%s); the child runs in %s"):format(
                        recorded_path,
                        tostring(err or "the recreated checkout is missing"),
                        manifest_cwd or "the current directory"
                    )
                )
            end
            M.revive(child_id, callback)
        end)
        return
    end
    -- The transcript lives in the workspace the child ran in: an assigned
    -- worktree for a modern row, or a leftover checkout recorded by an older
    -- version, which can differ from the manifest workspace.
    local transcript_cwd = assigned and assigned.path or (type(recorded) == "table" and recorded.path) or manifest_cwd
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
    -- A revived child must keep the tool allowlist it was spawned with.
    -- Older manifests (and hand-edited/corrupt ones) either omit
    -- `config.tools` (= inherit every tool, the pre-feature behavior) or carry
    -- garbage: an invalid value degrades to nil with a warning instead of
    -- blocking the revival.
    local stored_tools = type(entry.config) == "table" and entry.config.tools or nil
    local tools, tools_err = Manifest.normalize_tools(stored_tools)
    if tools_err then
        tools = nil
        Notify.warn("sub-session tool allowlist ignored on revive: " .. tools_err)
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
    -- A child runs in its parent's workspace. A row written by an older version
    -- may still record the checkout that child used to run in: that recorded cwd
    -- is honoured while the directory exists, and never recreated when it is not
    -- (see `resolve_child_cwd`). The parent process owns no live checkout here —
    -- the manifest workspace stands in for a parent revived from the list.
    local parent_session = Sessions.find_by_lineage(lineage_id)
    local parent_cwd = (parent_session and Manifest.workspace(parent_session)) or manifest_cwd
    local child_cwd, keeps_checkout
    if assigned then
        -- The assigned checkout is the cwd; the legacy `entry.worktree` record
        -- is ignored on such a row.
        child_cwd = assigned.path
        keeps_checkout = false
    else
        child_cwd = resolve_child_cwd(recorded, parent_cwd)
        local kept_path = type(recorded) == "table" and recorded.path or nil
        keeps_checkout = type(kept_path) == "string" and kept_path ~= "" and kept_path == child_cwd
    end
    -- An owned checkout stays owned across the revive: the session carries it, so
    -- close/settle can release it once it is clean. A row from an older version
    -- (no `owned` flag) keeps its recorded checkout as a *workspace* only, exactly
    -- as before this feature.
    local owned_info = nil
    if keeps_checkout and type(recorded) == "table" and recorded.owned == true then
        owned_info = recorded
    end

    Sessions.reserve_cwd(child_cwd)
    local ok_create, child = pcall(Sessions.create_detached, tab, {
        subagent = false,
        tools = tools,
        cwd = child_cwd,
        assigned_worktree = assigned,
        worktree = owned_info,
    })
    Sessions.release_cwd(child_cwd)
    if not ok_create or not child then
        unreserve()
        callback(nil, ok_create and "failed to start process" or tostring(child))
        return
    end
    child.assigned_worktree = assigned
    child.manifest_cwd = manifest_cwd
    child.run_generation = generation
    Sessions.ensure_id(child, child_id)
    unreserve()
    child.parent_id = entry.parent_id
    -- Record the transcript this run uses. On an assigned row the assignment is
    -- preserved (canonicalized) and the legacy `worktree` record is left alone;
    -- an owned/legacy row keeps exactly the old `worktree` behavior.
    local row_patch = {
        session_file = path,
        workspace = manifest_cwd,
    }
    if assigned then
        row_patch.assigned_worktree = assigned
    else
        row_patch.worktree = keeps_checkout and recorded or Manifest.REMOVE
    end
    Manifest.patch(child_id, row_patch, manifest_cwd)
    Sessions.load_session_path(child, path, function(ok)
        if ok then
            Manifest.patch(child_id, {
                status = "active",
                last_active_at = Manifest.iso_now(),
                run_generation = generation,
                session_file = child.session_file or path,
                workspace = manifest_cwd,
            }, manifest_cwd)
            callback(child, nil)
        else
            unreserve()
            Sessions.close_session(child)
            callback(nil, "failed to switch session")
        end
    end, { rebind_parent_context = false })
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

--- Called on child agent_settled — record the run outcome and inject the
--- completion (or failure) notice into the parent.
---
--- The outcome is decided in this order: **aborted** (the authoritative
--- `agent_settled.aborted` field on pi >= 1.1.0; the session file's stop reason
--- on older pi), **failed**, else completed. A failed run is what pi persists as
--- an assistant message with `stopReason: "error"` and no content — a quota,
--- auth or network failure — so the message text is empty while `errorMessage`
--- carries the reason. Booking that as a completion is how a dead child used to
--- read back as an empty `ok` result, so the failure is taken from the turn
--- itself rather than from the manifest, which only knows spawn-time failures.
---
--- The per-child generation watermark stays the guard that keeps a late settle of
--- an aborted run from touching a newer run on the same child.
---@param child pi.Session
---@param aborted? boolean
function M.on_child_settled(child, aborted)
    local SessionList = require("pi.ui.sessions")

    -- The child's row lives in the parent's workspace (`manifest_cwd`, set at
    -- spawn/revive), which is also the cwd the child runs in. A child registered
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
    -- writing to (a leftover checkout of an older child has its own workspace);
    -- the row's recorded file, then an id lookup in the child's workspace, cover
    -- a process that has not reported one yet.
    local path = child.session_file
    if type(path) ~= "string" or path == "" then
        path = manifest_session_file(entry)
    end
    if type(path) ~= "string" or path == "" then
        path = Read.find_path(child.id, { cwd = child.cwd or manifest_cwd })
    end
    -- One pass for text, stop reason and provider error. The live mirror on the
    -- session is the fallback for a child that keeps no session file (or whose
    -- file is already gone); it is also what the process-exit path leaves.
    local turn = path and Read.last_turn(path) or nil
    local report = turn and turn.text or nil
    local stop_reason = (turn and turn.stop_reason) or child._last_stop_reason
    local error_message = (turn and turn.error_message) or child._last_error_message
    local was_aborted = aborted == true or stop_reason == "aborted"
    -- `entry.status == "failed"` keeps the unexpected-exit path working: the
    -- manager patches it before settling because a crashed child leaves no
    -- assistant turn to read.
    local run_failed = not was_aborted and (stop_reason == "error" or entry.status == "failed")
    local failure_reason
    if run_failed then
        if stop_reason == "error" then
            -- Older pi may persist the turn without `errorMessage`; a reason
            -- already recorded on the manifest then wins over a generic text.
            local recorded = type(entry.last_error) == "string" and entry.last_error ~= "" and entry.last_error or nil
            failure_reason = error_message or recorded or "sub-agent run failed"
        else
            -- Unexpected process exit: the manager patched the manifest `failed`
            -- before settling, and any `last_error` there belongs to an earlier
            -- run, so it must not be recycled as this run's reason.
            failure_reason = "sub-agent process exited"
        end
    end
    local parent = Sessions.find_by_lineage(entry.parent_id)

    --- Finish the settle: batch accounting, manifest status, parent report.
    local function finish_settle()
        -- A failed run stays failed: the later patches below must not flip a
        -- crashed/failed child's row to `completed`.
        local final_status = run_failed and "failed" or "completed"

        if was_aborted then
            -- Settle the aborted run's own items (waking a parent blocked in
            -- wait_subagents) without touching a newer run: prefer the recorded
            -- abort watermark over the manifest generation, which the parent may
            -- already have bumped by reusing this child.
            --
            -- An aborted run is never folded back into the parent: the user
            -- cancelled the work, so the leftover checkout is left as it was.
            local watermark = M.aborted_generation(child.id)
            local current = type(entry.run_generation) == "number" and entry.run_generation or nil
            Batch.interrupt_items_for_child(child.id, {
                generation = watermark or current,
                reason = "cancelled: aborted by user",
                cwd = manifest_cwd,
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

        local claimed = Batch.on_child_settled(child.id, {
            ok = not run_failed,
            error = failure_reason,
            output = report,
        }, manifest_cwd)

        -- Agent tool path or a running batch item: skip parent prompt injection.
        if entry.agent_spawned or claimed then
            Manifest.patch(child.id, {
                status = final_status,
                last_report = report,
                last_error = run_failed and failure_reason or Manifest.REMOVE,
                last_active_at = Manifest.iso_now(),
            }, manifest_cwd)
            after_completed(parent)
            return
        end

        if entry.reported then
            after_completed(parent)
            return
        end

        -- A failed run has no report to deliver, so the notice is built from the
        -- error: a user-spawned child that died on a quota, auth or network
        -- failure must not disappear into a silent manifest row.
        if run_failed then
            local patch = {
                status = "failed",
                last_report = report,
                last_error = failure_reason,
                last_active_at = Manifest.iso_now(),
            }
            if not parent or not parent.rpc:is_running() then
                Manifest.patch(child.id, patch, manifest_cwd)
                after_completed(parent)
                return
            end
            local msg = require("pi.subsessions.tool_ui").failure_report(entry.name, failure_reason)
            parent.rpc:send({ type = "prompt", message = msg }, function(res)
                vim.schedule(function()
                    patch.reported = res.success == true
                    Manifest.patch(child.id, patch, manifest_cwd)
                    SessionList.request_refresh()
                    SessionList.acknowledge_reported_children_for_current_tab(parent)
                    pcall(Reaper.schedule, child.id, manifest_cwd)
                end)
            end)
            return
        end

        if not path then
            return
        end
        if not report or report == "" then
            Manifest.patch(child.id, {
                status = final_status,
                last_error = Manifest.REMOVE,
                last_active_at = Manifest.iso_now(),
            }, manifest_cwd)
            after_completed(parent)
            return
        end
        if not parent or not parent.rpc:is_running() then
            Manifest.patch(child.id, {
                status = final_status,
                last_report = report,
                last_error = Manifest.REMOVE,
                last_active_at = Manifest.iso_now(),
            }, manifest_cwd)
            after_completed(parent)
            return
        end
        local msg = require("pi.subsessions.tool_ui").completion_report(entry.name, report)
        parent.rpc:send({ type = "prompt", message = msg }, function(res)
            vim.schedule(function()
                if res.success then
                    Manifest.patch(child.id, {
                        status = final_status,
                        reported = true,
                        last_report = report,
                        last_error = Manifest.REMOVE,
                        last_active_at = Manifest.iso_now(),
                    }, manifest_cwd)
                else
                    Manifest.patch(child.id, {
                        status = final_status,
                        last_report = report,
                        last_error = Manifest.REMOVE,
                        last_active_at = Manifest.iso_now(),
                    }, manifest_cwd)
                end
                SessionList.request_refresh()
                SessionList.acknowledge_reported_children_for_current_tab(parent)
                -- Prompt-injection path patched the manifest last: arm the reaper here too.
                pcall(Reaper.schedule, child.id, manifest_cwd)
            end)
        end)
    end

    finish_settle()
end

--- Session id encoded in a pi session filename (`<timestamp>_<id>.jsonl`).
---@param path string
---@return string?
local function filename_session_id(path)
    return vim.fn.fnamemodify(path, ":t"):match("_([%w%-]+)%.jsonl$")
end

--- Does this file's header record `id`?
---
--- The filename convention is only trusted after this one-line check: a
--- renamed or hand-copied file must not make a manifest row point at the wrong
--- transcript (the rebuild writes the inferred status back into the manifest).
---@param path string
---@param id string
---@return boolean
local function session_path_has_id(path, id)
    local file = io.open(path, "r")
    if not file then
        return false
    end
    local header_line = file:read("*l")
    file:close()
    if not header_line then
        return false
    end
    local ok, header = pcall(vim.json.decode, header_line)
    return ok and type(header) == "table" and header.type == "session" and header.id == id
end

--- The session directory a scope's transcripts live in.
---@param scope pi.SubsessionScope
---@return string
local function scope_session_dir(scope)
    if scope.cwd then
        return require("pi.sessions.history").get_sessions_dir(scope.cwd)
    end
    return vim.fn.fnamemodify(scope.path, ":h")
end

--- Session files of one workspace, newest first: an id → path index.
---
--- Built from the `<timestamp>_<id>.jsonl` filename convention — one `glob()`
--- and no file reads — instead of `History.parse` per file, which walks every
--- line of every transcript to find its latest `session_info` name. On a large
--- sessions tree that parse cost seconds and it ran on the startup path (see the
--- startup-cost iron rule in `AGENTS.md`). Each hit is verified against the file
--- header before use (`session_path_has_id`), and ids without a conventionally
--- named file fall back to `scope_session_index_deep`, so the resolution
--- semantics are unchanged.
---@param scope pi.SubsessionScope
---@return table<string, string> index
---@return boolean unconventional true when the directory holds a transcript the
---   filename convention cannot name (so a parse scan could still find it)
local function scope_session_index(scope)
    local paths = vim.fn.glob(scope_session_dir(scope) .. "/*.jsonl", false, true)
    -- Newest file first: keeping the first match for an id then preserves
    -- find_path's newest-file semantics when several files share an id.
    table.sort(paths, function(a, b)
        local ma, mb = vim.fn.getftime(a), vim.fn.getftime(b)
        if ma ~= mb then
            return ma > mb
        end
        return a > b
    end)
    ---@type table<string, string>
    local index = {}
    local unconventional = false
    for _, path in ipairs(paths) do
        local id = filename_session_id(path)
        if not id then
            unconventional = true
        elseif index[id] == nil then
            index[id] = path
        end
    end
    return index, unconventional
end

--- Parse-based id → path index: the slow path behind `scope_session_index`.
---
--- Only runs for ids whose transcript does not follow the filename convention
--- (a renamed or externally written file). Entries whose file is gone (the
--- common dormant case in a long-lived project) must not each pay a fallback
--- full scan — that was the O(children × sessions) freeze of issue #110.
---@param scope pi.SubsessionScope
---@return table<string, string>
local function scope_session_index_deep(scope)
    local History = require("pi.sessions.history")
    ---@type table<string, string>
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
    local paths = vim.fn.glob(scope_session_dir(scope) .. "/*.jsonl", false, true)
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

--- Resolve a manifest row's transcript path within its scope.
---
--- Fast path first (filename index + header check), parse-based scan only for a
--- miss. Both indices are built at most once per scope and only when a row
--- actually needs one.
---@class pi.SessionIndexCache
---@field fast? table<string, string>
---@field unconventional? boolean the fast index could not name every transcript
---@field deep? table<string, string>

---@param scope pi.SubsessionScope
---@param id string
---@param cache pi.SessionIndexCache
---@return string?
local function lookup_session_path(scope, id, cache)
    if not cache.fast then
        cache.fast, cache.unconventional = scope_session_index(scope)
    end
    local path = cache.fast[id]
    if path and session_path_has_id(path, id) then
        return path
    end
    -- A row whose transcript is simply gone (the common dormant case in a
    -- long-lived project) must not trigger a parse scan: there is nothing for it
    -- to find. Only a directory holding files the convention cannot name, or a
    -- filename that lies about its header, needs the slow index.
    if not path and not cache.unconventional then
        return nil
    end
    cache.deep = cache.deep or scope_session_index_deep(scope)
    return cache.deep[id]
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
    local index_cache ---@type pi.SessionIndexCache?
    local changed = false
    for id, entry in pairs(manifest) do
        if Manifest.is_entry_id(id) and type(entry) == "table" and entry.parent_id ~= nil then
            -- The transcript recorded at spawn/revive wins: a child running in a
            -- leftover checkout keeps its JSONL there, not in the parent's
            -- workspace.
            local path = manifest_session_file(entry)
            if not path then
                index_cache = index_cache or {}
                path = lookup_session_path(scope, id, index_cache)
            end
            if not path then
                if entry.status == "active" then
                    entry.status = "dormant"
                    changed = true
                end
            else
                local mtime = tostring(os.date("!%Y-%m-%dT%H:%M:%SZ", vim.fn.getftime(path)))
                local stale = entry.last_active_at ~= mtime
                if stale then
                    entry.last_active_at = mtime
                    changed = true
                end
                -- Decode the transcript only when it moved since the last
                -- rebuild: an unchanged file still ends with the same entry, so
                -- the status booked from it still holds. Decoding every row's
                -- whole JSONL is what froze startup (startup-cost iron rule in
                -- `AGENTS.md`). A row still marked `active` is the exception —
                -- an unclean shutdown left it unsettled, and only the
                -- transcript can say whether the run finished.
                if stale or entry.status == "active" then
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
                    elseif inferred == "failed" then
                        -- A run that died on a provider/auth/quota error: the settle
                        -- handler never got to patch it (Neovim was closed, or the
                        -- pi backend died with it). Keep the reason readable too.
                        if entry.status ~= "failed" then
                            entry.status = "failed"
                            changed = true
                        end
                        local turn = Read.last_turn(path)
                        local reason = turn and turn.error_message or nil
                        if reason and entry.last_error ~= reason then
                            entry.last_error = reason
                            changed = true
                        end
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

--- Test-only: the platform-neutral absolute-path predicate (POSIX + Windows
--- drive). The filesystem checks behind it still run on the host OS.
M._is_absolute_path = is_absolute_path

return M
