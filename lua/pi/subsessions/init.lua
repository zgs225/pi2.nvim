--- Sub-session lifecycle: spawn, switch, close, report, and host bridge for subagent.ts.

local M = {}

local Config = require("pi.config")
local Notify = require("pi.notify")
local Dialog = require("pi.ui.dialog")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Batch = require("pi.subsessions.batch")
local Sessions = require("pi.sessions.manager")

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
        Manifest.bind_session_lineage(parent, parent.id)
    end
    parent.conversation_epoch = (parent.conversation_epoch or 0) + 1
    parent.view_parent_id = nil
    require("pi.ui.sessions").request_refresh()
end

--- Reset sub-session UI context when the tab resumes a different parent session file.
---@param session pi.Session
---@param session_path string
function M.on_parent_resumed(session, session_path)
    session.view_parent_id = nil
    session.conversation_epoch = 0
    session.lineage_id = nil
    local info = require("pi.sessions.history").parse(session_path)
    if info and type(info.id) == "string" and info.id ~= "" then
        Sessions.ensure_id(session, info.id)
        Manifest.rebind_lineage(session, info.id)
    end
    require("pi.ui.sessions").request_refresh()
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

    with_parent_id(parent, function(parent_id)
        if parent_id == "" then
            callback(nil, "parent session id not available")
            return
        end

        Manifest.bind_session_lineage(parent, parent_id)
        local lineage_id = Manifest.lineage_for_session(parent)
        if lineage_id == "" then
            lineage_id = parent_id
        end

        local max = subcfg.max_children or 5
        if not Manifest.try_reserve_spawn(lineage_id, max) then
            callback(nil, ("max %d concurrent sub-sessions"):format(max))
            return
        end
        local held = true
        local function unreserve()
            if held then
                held = false
                Manifest.release_spawn(lineage_id)
            end
        end

        local tab = parent.attached_tab or vim.api.nvim_get_current_tabpage()
        local child = Sessions.create_detached(tab, { subagent = false })
        if not child then
            unreserve()
            callback(nil, "failed to start sub-session process")
            return
        end
        child.parent_id = parent_id

        local config = resolve_child_config(parent, opts)
        local name = opts.name or opts.task:sub(1, 40)

        local function register_and_run(session_id)
            child.id = session_id
            Manifest.upsert(session_id, {
                parent_id = lineage_id,
                parent_epoch = parent.conversation_epoch or 0,
                name = name,
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
                run_generation = 1,
            })
            unreserve()
            apply_config(child, config, function(ok, config_err)
                if not ok then
                    Manifest.patch(session_id, { status = "failed", last_active_at = Manifest.iso_now() })
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
                        Manifest.patch(session_id, { status = "failed", last_active_at = Manifest.iso_now() })
                        Sessions.close_session(child)
                        callback(nil, "failed to send task to sub-session")
                    end
                end)
            end)
        end

        -- Wait for backend session id via get_state.
        child.rpc:send({ type = "get_state" }, function(res)
            vim.schedule(function()
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
    local disk_path = Read.find_path(child.id)
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
    local disk_path = Read.find_path(parent.id)
    local path = disk_path or parent.session_file
    reattach_or_load(parent, path, callback)
end

--- Close sub-session process (file retained).
---@param child_id string
---@param callback? fun(ok: boolean)
---@return boolean stopped True when a running RPC process was stopped.
function M.close(child_id, callback)
    local stopped = false
    local child = Sessions.get_by_id(child_id)
    if child and child.rpc:is_running() then
        Sessions.close_session(child)
        stopped = true
    end
    Manifest.patch(child_id, { status = "dormant", last_active_at = Manifest.iso_now() })
    require("pi.ui.sessions").request_refresh()
    if callback then
        callback(true)
    end
    return stopped
end

--- Revive a dormant sub-session (spawn process + switch_session).
---@param child_id string
---@param callback fun(session: pi.Session?, err: string?)
function M.revive(child_id, callback)
    local path = Read.find_path(child_id)
    if not path then
        callback(nil, "session file not found")
        return
    end
    local tab = vim.api.nvim_get_current_tabpage()
    local child = Sessions.create_detached(tab, { subagent = false })
    if not child then
        callback(nil, "failed to start process")
        return
    end
    Sessions.ensure_id(child, child_id)
    child.parent_id = (Manifest.load()[child_id] or {}).parent_id
    Sessions.load_session_path(child, path, function(ok)
        if ok then
            Manifest.patch(child_id, { status = "active", last_active_at = Manifest.iso_now() })
            callback(child, nil)
        else
            Sessions.close_session(child)
            callback(nil, "failed to switch session")
        end
    end, { rebind_parent_context = false })
end

--- Called on child agent_settled — inject completion report into parent.
---@param child pi.Session
function M.on_child_settled(child)
    local SessionList = require("pi.ui.sessions")

    local function after_completed(parent)
        if child.chat then
            SessionList.mark_child_completion_seen(child.id)
        end
        SessionList.request_refresh()
        if parent then
            SessionList.acknowledge_reported_children_for_current_tab(parent)
        end
    end

    local manifest = Manifest.load()
    local entry = manifest[child.id]
    if not entry then
        return
    end

    local path = child.session_file or Read.find_path(child.id)
    local report = path and Read.last_assistant_message(path) or nil
    local parent = Sessions.find_by_lineage(entry.parent_id)
    local claimed = Batch.on_child_settled(child.id)

    -- Agent tool path or a running batch item: skip parent prompt injection.
    if entry.agent_spawned or claimed then
        local status = entry.status == "failed" and "failed" or "completed"
        Manifest.patch(child.id, {
            status = status,
            last_report = report,
            last_active_at = Manifest.iso_now(),
        })
        after_completed(parent)
        return
    end

    if entry.reported then
        after_completed(parent)
        return
    end

    if not path then
        return
    end
    if not report or report == "" then
        Manifest.patch(child.id, { status = "completed", last_active_at = Manifest.iso_now() })
        after_completed(parent)
        return
    end
    if not parent or not parent.rpc:is_running() then
        Manifest.patch(child.id, {
            status = "completed",
            last_report = report,
            last_active_at = Manifest.iso_now(),
        })
        after_completed(parent)
        return
    end
    local msg = require("pi.subsessions.tool_ui").completion_report(entry.name, report)
    parent.rpc:send({ type = "prompt", message = msg }, function(res)
        vim.schedule(function()
            if res.success then
                Manifest.patch(child.id, {
                    status = "completed",
                    reported = true,
                    last_report = report,
                    last_active_at = Manifest.iso_now(),
                })
            else
                Manifest.patch(child.id, {
                    status = "completed",
                    last_report = report,
                    last_active_at = Manifest.iso_now(),
                })
            end
            SessionList.request_refresh()
            SessionList.acknowledge_reported_children_for_current_tab(parent)
        end)
    end)
end

--- Rebuild manifest statuses after Neovim restart.
function M.rebuild_statuses()
    local manifest = Manifest.load()
    for id, entry in pairs(manifest) do
        if Manifest.is_entry_id(id) and type(entry) == "table" and entry.parent_id ~= nil then
            local path = Read.find_path(id)
            if not path then
                if entry.status == "active" then
                    entry.status = "dormant"
                end
            else
                entry.last_active_at = os.date("!%Y-%m-%dT%H:%M:%SZ", vim.fn.getftime(path))
                local inferred = Read.infer_run_status(path)
                if inferred == "completed" then
                    entry.status = "completed"
                elseif inferred == "interrupted" then
                    entry.status = "interrupted"
                end
                if Sessions.get_by_id(id) and Sessions.get_by_id(id).rpc:is_running() then
                    entry.status = "active"
                elseif entry.status == "active" then
                    entry.status = "dormant"
                end
            end
            manifest[id] = entry
        end
    end
    Manifest.save(manifest)
    pcall(function()
        Batch.rebuild()
    end)
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
            Batch.wait(result.batch_id, finish, { timeout_ms = params.timeout_ms })
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
        local snap = Batch.poll(batch_id)
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
        Batch.wait(batch_id, function(result)
            if on_done then
                on_done(result)
            end
        end, { timeout_ms = params.timeout_ms })
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
            local lineage = Manifest.lineage_for_session(parent)
            return finish({ batches = Batch.list_for_parent(lineage ~= "" and lineage or parent.id) })
        end
        with_parent_id(parent, function(parent_id)
            if parent_id == "" then
                finish({ batches = {} })
                return
            end
            Manifest.bind_session_lineage(parent, parent_id)
            local lineage = Manifest.lineage_for_session(parent)
            finish({ batches = Batch.list_for_parent(lineage ~= "" and lineage or parent_id) })
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
        Dialog.input(
            { title = "Sub-session name (optional)", default = task:sub(1, 40), kind = "pi-sub-new-name" },
            function(name)
                M.spawn(parent, { task = task, name = name ~= "" and name or nil }, function(child, err)
                    if child then
                        Notify.info("Sub-session started: " .. (name or task:sub(1, 40)))
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
    local lineage = Manifest.lineage_for_session(root_sess)
    local children = Manifest.children_of(lineage)
    if parent.view_parent_id then
        -- also allow switching among siblings when already in child view
        children = Manifest.children_of(lineage)
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
        local child_id = entry._id
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
    local is_child = current.parent_id ~= nil or Manifest.is_child_session(current.id)
    if not in_child_view and not is_child then
        Notify.warn("Current session is not a sub-session")
        return
    end
    M.close(current.id)
    if in_child_view then
        M.switch_to_parent(function() end)
    end
end

--- Preview sub-session in a float (for :PiSessions `p` key).
---@param child_id string
function M.preview(child_id)
    local path = Read.find_path(child_id)
    if not path then
        Notify.warn("Sub-session file not found")
        return
    end
    local tail = (Config.options.subagent or {}).read_tail or 50
    local lines = Read.project_tail(path, tail)
    local manifest = Manifest.load()
    local entry = manifest[child_id]
    local title = entry and entry.name or child_id
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = math.min(80, vim.o.columns - 4),
        height = math.min(20, #lines + 2),
        row = math.floor((vim.o.lines - 20) / 2),
        col = math.floor((vim.o.columns - 80) / 2),
        style = "minimal",
        border = "rounded",
        title = " " .. title .. " ",
        title_pos = "center",
    })
end

--- Test-only: exported for unit tests.
M._format_available_models = format_available_models

return M
