--- Sub-session batch dispatch / poll / wait (persistent `.pi2-sub-batches.json`).

local M = {}

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Read = require("pi.subsessions.read")
local Sessions = require("pi.sessions.manager")

local BATCH_FILE = ".pi2-sub-batches.json"

---@type string?
local path_override = nil

---@type table<string, fun(result: table)[]>
local waiters = {}

---@class pi.SubsessionBatchItem
---@field ref string
---@field target? string
---@field task? string
---@field message? string
---@field name? string
---@field model? pi.ModelRef
---@field thinking_level? string
---@field status "queued"|"spawning"|"running"|"ok"|"failed"|"cancelled"
---@field generation? integer
---@field output? string
---@field error? string

---@class pi.SubsessionBatch
---@field id string
---@field parent_id string
---@field status "pending"|"running"|"completed"|"partial"|"failed"|"cancelled"
---@field created_at string
---@field updated_at string
---@field cancel_siblings_on_fail boolean
---@field items pi.SubsessionBatchItem[]

---@param path string
function M._set_path(path)
    path_override = path
end

function M._reset()
    path_override = nil
    waiters = {}
end

---@return string
function M.path()
    if path_override then
        return path_override
    end
    local History = require("pi.sessions.history")
    return History.get_sessions_dir() .. "/" .. BATCH_FILE
end

---@return table<string, pi.SubsessionBatch>
function M.load()
    local file = io.open(M.path(), "r")
    if not file then
        return {}
    end
    local content = file:read("*a")
    file:close()
    if type(content) ~= "string" or content == "" then
        return {}
    end
    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

---@param batches table<string, pi.SubsessionBatch>
---@return boolean
local function save(batches)
    local path = M.path()
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, "p")
    end
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "w")
    if not file then
        return false
    end
    file:write(vim.json.encode(batches))
    file:close()
    local ok = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
    end
    return ok == true
end

---@param id string
---@return pi.SubsessionBatch?
function M.get(id)
    return M.load()[id]
end

---@param batch pi.SubsessionBatch
local function persist(batch)
    local batches = M.load()
    batch.updated_at = Manifest.iso_now()
    batches[batch.id] = batch
    save(batches)
end

---@return string
local function new_id()
    return ("%s-%s"):format(os.time(), math.random(100000, 999999))
end

---@param batch pi.SubsessionBatch
---@return table
function M.snapshot(batch)
    local summary = { total = 0, done = 0, ok = 0, failed = 0, cancelled = 0, running = 0 }
    for _, item in ipairs(batch.items) do
        summary.total = summary.total + 1
        if item.status == "ok" then
            summary.done = summary.done + 1
            summary.ok = summary.ok + 1
        elseif item.status == "failed" then
            summary.done = summary.done + 1
            summary.failed = summary.failed + 1
        elseif item.status == "cancelled" then
            summary.done = summary.done + 1
            summary.cancelled = summary.cancelled + 1
        elseif item.status == "running" or item.status == "spawning" then
            summary.running = summary.running + 1
        end
    end
    return {
        batch_id = batch.id,
        status = batch.status,
        summary = summary,
        items = vim.deepcopy(batch.items),
    }
end

---@param batch pi.SubsessionBatch
local function recompute_status(batch)
    local ok_n, fail_n, cancel_n, pending = 0, 0, 0, 0
    for _, item in ipairs(batch.items) do
        if item.status == "ok" then
            ok_n = ok_n + 1
        elseif item.status == "failed" then
            fail_n = fail_n + 1
        elseif item.status == "cancelled" then
            cancel_n = cancel_n + 1
        else
            pending = pending + 1
        end
    end
    if batch.status == "cancelled" then
        return
    end
    if pending > 0 then
        batch.status = "running"
        return
    end
    if ok_n > 0 and fail_n == 0 and cancel_n == 0 then
        batch.status = "completed"
    elseif ok_n > 0 and (fail_n > 0 or cancel_n > 0) then
        batch.status = "partial"
    elseif fail_n > 0 then
        batch.status = "failed"
    else
        batch.status = "cancelled"
    end
end

---@param batch_id string
local function notify_waiters(batch_id)
    local batch = M.get(batch_id)
    if not batch then
        return
    end
    local terminal = batch.status == "completed"
        or batch.status == "partial"
        or batch.status == "failed"
        or batch.status == "cancelled"
    if not terminal then
        return
    end
    local cbs = waiters[batch_id]
    if not cbs then
        return
    end
    waiters[batch_id] = nil
    local snap = M.snapshot(batch)
    for _, cb in ipairs(cbs) do
        vim.schedule(function()
            cb(snap)
        end)
    end
end

---@param child_id string
---@return integer
function M.bump_generation(child_id)
    local entry = Manifest.load()[child_id]
    local gen = (entry and entry.run_generation or 0) + 1
    Manifest.patch(child_id, {
        run_generation = gen,
        status = "active",
        last_active_at = Manifest.iso_now(),
        agent_spawned = true,
    })
    return gen
end

---@param batch pi.SubsessionBatch
---@param ref string
---@param patch table
local function patch_item(batch, ref, patch)
    for _, item in ipairs(batch.items) do
        if item.ref == ref then
            for k, v in pairs(patch) do
                item[k] = v
            end
            return item
        end
    end
    return nil
end

---@param batch pi.SubsessionBatch
---@param failed_ref string
local function maybe_cancel_siblings(batch, failed_ref)
    if not batch.cancel_siblings_on_fail then
        return
    end
    local Subsessions = require("pi.subsessions")
    for _, item in ipairs(batch.items) do
        if item.ref ~= failed_ref and (item.status == "queued" or item.status == "spawning" or item.status == "running") then
            item.status = "cancelled"
            item.error = "cancelled: sibling failed"
            if item.target then
                local child = Sessions.get_by_id(item.target)
                if child and child.rpc:is_running() then
                    child.rpc:send({ type = "abort" })
                end
                Subsessions.close(item.target)
            end
        end
    end
end

---@param batch_id string
---@param ref string
---@param ok boolean
---@param opts? { output?: string, error?: string }
function M.complete_item(batch_id, ref, ok, opts)
    opts = opts or {}
    local batch = M.get(batch_id)
    if not batch or batch.status == "cancelled" then
        return
    end
    local item = patch_item(batch, ref, {})
    if not item or item.status == "cancelled" or item.status == "ok" or item.status == "failed" then
        return
    end
    if ok then
        patch_item(batch, ref, {
            status = "ok",
            output = opts.output,
            error = nil,
        })
    else
        patch_item(batch, ref, {
            status = "failed",
            error = opts.error or "failed",
        })
        maybe_cancel_siblings(batch, ref)
    end
    recompute_status(batch)
    persist(batch)
    notify_waiters(batch_id)
    require("pi.ui.sessions").request_refresh()
end

---@param child_id string
function M.on_child_settled(child_id)
    local entry = Manifest.load()[child_id]
    if not entry then
        return
    end
    local gen = entry.run_generation
    if type(gen) ~= "number" then
        return
    end
    local batches = M.load()
    local path = Read.find_path(child_id)
    local output = path and Read.last_assistant_message(path) or ""
    local failed = entry.status == "failed"
    for batch_id, batch in pairs(batches) do
        if batch.status == "running" or batch.status == "pending" then
            for _, item in ipairs(batch.items) do
                if item.target == child_id and item.generation == gen
                    and (item.status == "running" or item.status == "spawning") then
                    M.complete_item(batch_id, item.ref, not failed, {
                        output = failed and nil or output,
                        error = failed and "sub-session failed" or nil,
                    })
                end
            end
        end
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

---@param raw table
---@param index integer
---@return pi.SubsessionBatchItem?, string?
local function normalize_item(raw, index)
    if type(raw) ~= "table" then
        return nil, ("item %d: expected object"):format(index)
    end
    local ref = type(raw.ref) == "string" and raw.ref ~= "" and raw.ref or tostring(index - 1)
    if type(raw.task) == "string" and raw.task ~= "" then
        return {
            ref = ref,
            task = raw.task,
            name = type(raw.name) == "string" and raw.name or nil,
            model = raw.model,
            thinking_level = raw.thinking_level,
            status = "queued",
        }, nil
    end
    if type(raw.target) == "string" and raw.target ~= "" and type(raw.message) == "string" then
        return {
            ref = ref,
            target = raw.target,
            message = raw.message,
            status = "queued",
        }, nil
    end
    return nil, ("item %d: need task or (target + message)"):format(index)
end

---@param parent_id string
---@return integer
local function count_active_children(parent_id)
    local manifest = Manifest.load()
    local n = 0
    for _, entry in pairs(manifest) do
        if entry.parent_id == parent_id and entry.status == "active" then
            n = n + 1
        end
    end
    return n
end

---@param batch pi.SubsessionBatch
---@param parent pi.Session
local function run_batch(batch, parent)
    local Subsessions = require("pi.subsessions")

    ---@param item pi.SubsessionBatchItem
    local function start_item(item)
        local current = M.get(batch.id)
        if not current or current.status == "cancelled" then
            return
        end
        if item.status ~= "queued" then
            return
        end

        if item.task then
            item.status = "spawning"
            persist(current)
            Subsessions.spawn(parent, {
                task = item.task,
                name = item.name,
                model = item.model,
                thinking_level = item.thinking_level,
                agent_spawned = true,
            }, function(child, err)
                local b = M.get(batch.id)
                if not b or b.status == "cancelled" then
                    return
                end
                if not child then
                    M.complete_item(b.id, item.ref, false, { error = err or "spawn failed" })
                    return
                end
                local entry = Manifest.load()[child.id]
                for _, it in ipairs(b.items) do
                    if it.ref == item.ref then
                        it.target = child.id
                        it.generation = entry and entry.run_generation
                        it.status = "running"
                        break
                    end
                end
                persist(b)
            end)
            return
        end

        local target = item.target
        local function send_to(child)
            local b = M.get(batch.id)
            if not b or b.status == "cancelled" then
                return
            end
            if not child then
                M.complete_item(b.id, item.ref, false, { error = "sub-agent not found" })
                return
            end
            local gen = M.bump_generation(target)
            for _, it in ipairs(b.items) do
                if it.ref == item.ref then
                    it.generation = gen
                    it.status = "running"
                    break
                end
            end
            persist(b)
            child.rpc:send({ type = "prompt", message = item.message }, function(res)
                if not res.success then
                    M.complete_item(batch.id, item.ref, false, { error = "prompt failed" })
                end
            end)
        end

        local child = Sessions.get_by_id(target)
        if child and child.rpc:is_running() then
            send_to(child)
            return
        end
        Subsessions.revive(target, function(revived, err)
            if not revived then
                M.complete_item(batch.id, item.ref, false, { error = err or "revive failed" })
                return
            end
            send_to(revived)
        end)
    end

    for _, item in ipairs(batch.items) do
        start_item(item)
    end
end

---@class pi.SubsessionDispatchOpts
---@field items table[]
---@field cancel_siblings_on_fail? boolean

---@param parent pi.Session
---@param opts pi.SubsessionDispatchOpts
---@param callback fun(result: table)
function M.dispatch(parent, opts, callback)
    local subcfg = Config.options.subagent or {}
    if subcfg.enabled == false then
        callback({ error = "subagent disabled" })
        return
    end

    with_parent_id(parent, function(parent_id)
        if parent_id == "" then
            callback({ error = "parent session id not available" })
            return
        end

        local raw_items = opts.items
        if type(raw_items) ~= "table" or #raw_items == 0 then
            callback({ error = "items required" })
            return
        end

        local max_batch = subcfg.max_batch_size or 5
        if #raw_items > max_batch then
            callback({ error = ("max %d items per batch"):format(max_batch) })
            return
        end

        ---@type pi.SubsessionBatchItem[]
        local items = {}
        for i, raw in ipairs(raw_items) do
            local item, err = normalize_item(raw, i)
            if not item then
                callback({ error = err })
                return
            end
            items[#items + 1] = item
        end

        local new_spawns = 0
        for _, item in ipairs(items) do
            if item.task then
                new_spawns = new_spawns + 1
            end
        end
        local max_children = subcfg.max_children or 5
        if count_active_children(parent_id) + new_spawns > max_children then
            callback({ error = ("would exceed max %d concurrent sub-sessions"):format(max_children) })
            return
        end

        ---@type pi.SubsessionBatch
        local batch = {
            id = new_id(),
            parent_id = parent_id,
            status = "running",
            created_at = Manifest.iso_now(),
            updated_at = Manifest.iso_now(),
            cancel_siblings_on_fail = opts.cancel_siblings_on_fail == true,
            items = items,
        }
        persist(batch)
        callback(M.snapshot(batch))
        vim.defer_fn(function()
            run_batch(batch, parent)
        end, 0)
    end)
end

---@param batch_id string
---@return table?
function M.poll(batch_id)
    local batch = M.get(batch_id)
    if not batch then
        return nil
    end
    return M.snapshot(batch)
end

---@param parent_id string
---@return table[]
function M.list_for_parent(parent_id)
    local batches = M.load()
    ---@type table[]
    local out = {}
    for _, batch in pairs(batches) do
        if batch.parent_id == parent_id then
            out[#out + 1] = M.snapshot(batch)
        end
    end
    table.sort(out, function(a, b)
        return (a.batch_id or "") > (b.batch_id or "")
    end)
    return out
end

---@param batch_id string
---@param callback fun(result: table)
---@param opts? { timeout_ms?: integer, interval_ms?: integer }
function M.wait(batch_id, callback, opts)
    opts = opts or {}
    local timeout_ms = opts.timeout_ms or (Config.options.subagent or {}).batch_timeout_ms or 300000
    local interval_ms = opts.interval_ms or 200
    local started = vim.uv.hrtime() / 1e6

    local function tick()
        local snap = M.poll(batch_id)
        if not snap then
            callback({ error = "batch not found" })
            return
        end
        local terminal = snap.status == "completed"
            or snap.status == "partial"
            or snap.status == "failed"
            or snap.status == "cancelled"
        if terminal then
            callback(snap)
            return
        end
        if (vim.uv.hrtime() / 1e6 - started) >= timeout_ms then
            callback({ error = "timeout waiting for batch", batch_id = batch_id, status = snap.status, summary = snap.summary })
            return
        end
        vim.defer_fn(tick, interval_ms)
    end

    local batch = M.get(batch_id)
    if not batch then
        callback({ error = "batch not found" })
        return
    end
    local terminal = batch.status == "completed"
        or batch.status == "partial"
        or batch.status == "failed"
        or batch.status == "cancelled"
    if terminal then
        callback(M.snapshot(batch))
        return
    end
    waiters[batch_id] = waiters[batch_id] or {}
    table.insert(waiters[batch_id], callback)
    vim.defer_fn(tick, interval_ms)
end

---@param batch_id string
---@return boolean
function M.cancel(batch_id)
    local batch = M.get(batch_id)
    if not batch then
        return false
    end
    if batch.status == "completed" or batch.status == "partial" or batch.status == "failed" or batch.status == "cancelled" then
        return true
    end
    batch.status = "cancelled"
    local Subsessions = require("pi.subsessions")
    for _, item in ipairs(batch.items) do
        if item.status == "queued" or item.status == "spawning" or item.status == "running" then
            item.status = "cancelled"
            item.error = "batch cancelled"
            if item.target then
                local child = Sessions.get_by_id(item.target)
                if child and child.rpc:is_running() then
                    child.rpc:send({ type = "abort" })
                end
                Subsessions.close(item.target)
            end
        end
    end
    persist(batch)
    notify_waiters(batch_id)
    return true
end

---@param parent_id string
function M.cancel_for_parent(parent_id)
    local batches = M.load()
    for id, batch in pairs(batches) do
        if batch.parent_id == parent_id and batch.status == "running" then
            M.cancel(id)
        end
    end
end

--- Reconcile running batches after Neovim restart.
function M.rebuild()
    local ttl_hours = (Config.options.subagent or {}).batch_ttl_hours or 24
    local now = os.time()
    local batches = M.load()
    local changed = false
    for id, batch in pairs(batches) do
        local created = batch.created_at or ""
        local ts = created:match("^(%d%d%d%d%-%d%d%-%d%d)T")
        if ts then
            local y, m, d = ts:match("^(%d+)%-(%d+)%-(%d+)$")
            if y and m and d then
                local age_h = (now - os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0 })) / 3600
                if age_h > ttl_hours and batch.status ~= "running" then
                    batches[id] = nil
                    changed = true
                end
            end
        end
        if batch.status == "running" then
            for _, item in ipairs(batch.items) do
                if item.status == "running" and item.target and item.generation then
                    local entry = Manifest.load()[item.target]
                    if entry and entry.run_generation == item.generation and entry.status == "completed" then
                        local path = Read.find_path(item.target)
                        item.status = "ok"
                        item.output = path and Read.last_assistant_message(path) or ""
                        changed = true
                    elseif entry and entry.run_generation == item.generation and entry.status == "failed" then
                        item.status = "failed"
                        item.error = "sub-session failed"
                        changed = true
                    end
                end
            end
            recompute_status(batch)
            changed = true
        end
    end
    if changed then
        save(batches)
    end
end

return M
