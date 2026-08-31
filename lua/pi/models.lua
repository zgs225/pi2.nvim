--- Model selection: cycling, picking, and resolving configured model entries.

local M = {}

local Config = require("pi.config")
local Notify = require("pi.notify")
local ScopedModels = require("pi.scoped_models")

--- Resolve configured model entries against available backend models.
--- Returns the matched subset in config order.
---@param entries pi.ModelEntry[]
---@param all_models table[] models from get_available_models
---@return table[] resolved  matched backend model objects
function M.resolve_entries(entries, all_models)
    ---@type table[]
    local resolved = {}
    ---@type table<string, true>
    local seen = {}
    for _, entry in ipairs(entries) do
        local matched = false
        if type(entry) == "string" then
            -- Exact ID match, or canonical "provider/modelId" reference.
            for _, m in ipairs(all_models) do
                local canonical = m.provider .. "/" .. m.id
                if (m.id == entry or canonical == entry) and not seen[canonical] then
                    resolved[#resolved + 1] = m
                    seen[canonical] = true
                    matched = true
                end
            end
            if not matched then
                Notify.warn("Configured model not found: " .. entry)
            end
        elseif type(entry) == "table" and entry.match then
            if entry.exact then
                -- Exact ID match (or canonical "provider/modelId"): take the
                -- first hit and stop. `latest` is ignored.
                for _, m in ipairs(all_models) do
                    local canonical = m.provider .. "/" .. m.id
                    if (m.id == entry.match or canonical == entry.match) and not seen[canonical] then
                        resolved[#resolved + 1] = m
                        seen[canonical] = true
                        matched = true
                        break
                    end
                end
                if not matched then
                    Notify.warn('No models matched "' .. entry.match .. '"')
                end
                goto continue
            end
            local needle = entry.match:lower()
            ---@type table[]
            local matches = {}
            for _, m in ipairs(all_models) do
                if m.id:lower():find(needle, 1, true) and not seen[m.provider .. "/" .. m.id] then
                    matches[#matches + 1] = m
                end
            end
            if entry.latest then
                -- Pick the model whose ID sorts last (date suffixes sort naturally)
                table.sort(matches, function(a, b)
                    return a.id < b.id
                end)
                if #matches > 0 then
                    local m = matches[#matches]
                    resolved[#resolved + 1] = m
                    seen[m.provider .. "/" .. m.id] = true
                    matched = true
                end
            else
                for _, m in ipairs(matches) do
                    resolved[#resolved + 1] = m
                    seen[m.provider .. "/" .. m.id] = true
                    matched = true
                end
            end
            if not matched then
                Notify.warn('No models matched "' .. entry.match .. '"')
            end
        end
        ::continue::
    end
    return resolved
end

--- Format a model for display: "model-id  [provider]"
---@param model table
---@return string
function M.format_label(model)
    return model.id .. "  [" .. model.provider .. "]"
end

--- Compact host label from a base URL ("https://api.anthropic.com/v1" ->
--- "api.anthropic.com"; default ports 443/80 are dropped). nil when the URL
--- is absent or not parseable.
---@param base_url string?
---@return string?
local function host_of(base_url)
    if type(base_url) ~= "string" or base_url == "" then
        return nil
    end
    local host = base_url:gsub("^[%w%+%-%._]+://", ""):gsub("/.*$", "")
    host = host:gsub(":443$", ""):gsub(":80$", "")
    if host == "" then
        return nil
    end
    return host
end

--- Provider disambiguation suffix for the statusline model component.
--- A model id is ambiguous when the backend serves it under >= 2 distinct
--- providers, or under one provider through >= 2 distinct base URLs (custom
--- gateways/proxies). Same provider + same baseUrl = the same endpoint, so
--- duplicate listings never count.
--- Returns nil when the id is unambiguous, when the current model is not in
--- the list at all, or when the list is unusable — the caller then shows the
--- bare id.
---@param current table backend Model object (.provider, .id, .baseUrl?)
---@param all_models table[] models from get_available_models
---@return string? suffix e.g. "[anthropic]" or "[openai@api.example.com]"
function M.ambiguity_suffix(current, all_models)
    local id = type(current) == "table" and current.id or nil
    if type(id) ~= "string" or type(all_models) ~= "table" then
        return nil
    end
    ---@type table<string, true>
    local providers = {}
    local urls_by_provider = {} ---@type table<string, table<string, true>>
    for _, m in ipairs(all_models) do
        if type(m) == "table" and m.id == id and type(m.provider) == "string" then
            providers[m.provider] = true
            local urls = urls_by_provider[m.provider]
            if not urls then
                urls = {}
                urls_by_provider[m.provider] = urls
            end
            if type(m.baseUrl) == "string" and m.baseUrl ~= "" then
                urls[m.baseUrl] = true
            end
        end
    end
    local provider_count = 0
    for _ in pairs(providers) do
        provider_count = provider_count + 1
    end
    if provider_count == 0 then
        -- Current model absent from the list — nothing to disambiguate against.
        return nil
    end
    if provider_count > 1 then
        return "[" .. current.provider .. "]"
    end
    local provider = next(providers)
    local url_count = 0
    for _ in pairs(urls_by_provider[provider]) do
        url_count = url_count + 1
    end
    if url_count < 2 then
        return nil
    end
    -- Same provider, several endpoints: label by endpoint host. Without a
    -- parseable host the bare provider still marks the ambiguity.
    local host = host_of(current.baseUrl)
    if host then
        return "[" .. provider .. "@" .. host .. "]"
    end
    return "[" .. provider .. "]"
end

--- Send set_model RPC and notify on result.
--- A successful manual switch updates the tab's model pin, so subsequent
--- `:PiNewSession` in this tab keep this model.
---@param session pi.Session
---@param model table backend model object with .provider and .id
function M.set(session, model)
    local Sessions = require("pi.sessions.manager")
    session.rpc:send({ type = "set_model", provider = model.provider, modelId = model.id }, function(res)
        vim.schedule(function()
            if res.success then
                session.pinned_model = { provider = model.provider, id = model.id }
                Sessions.refresh_state(session)
            else
                Notify.warn(res.error or "Failed to set model")
            end
        end)
    end)
end

--- Fetch available models from the backend, then call fn with them.
---@param session pi.Session
---@param fn fun(models: table[])
function M.with_available(session, fn)
    session.rpc:send({ type = "get_available_models" }, function(res)
        vim.schedule(function()
            if not res.success then
                Notify.warn(res.error or "Failed to fetch models")
                return
            end
            local models = (res.data or {}).models or {}
            if #models == 0 then
                Notify.warn("No models available")
                return
            end
            fn(models)
        end)
    end)
end

--- Cycle to the next model.
--- If `models` is configured, cycles within the resolved subset.
---@param session pi.Session
function M.cycle(session)
    local entries = Config.options.models
    if not entries or #entries == 0 then
        -- No config — use backend's built-in cycle
        session.rpc:send({ type = "cycle_model" }, function(res)
            vim.schedule(function()
                if res.success and res.data then
                    local model = res.data.model
                    if type(model) == "table" and type(model.provider) == "string" and type(model.id) == "string" then
                        session.pinned_model = { provider = model.provider, id = model.id }
                    end
                    require("pi.sessions.manager").refresh_state(session)
                elseif res.success then
                    Notify.info("Only one model available")
                else
                    Notify.warn(res.error or "Failed to cycle model")
                end
            end)
        end)
        return
    end
    -- Configured models — resolve and cycle manually
    M.with_available(session, function(all_models)
        local resolved = M.resolve_entries(entries, all_models)
        if #resolved == 0 then
            Notify.warn("No configured models matched available models")
            return
        end
        if #resolved == 1 then
            Notify.info("Only one model in list")
            return
        end
        -- Find current model and advance to next
        session.rpc:send({ type = "get_state" }, function(state_res)
            vim.schedule(function()
                local current = state_res.success and state_res.data and state_res.data.model
                local current_key = current and (current.provider .. "/" .. current.id) or ""
                local next_idx = 1
                for i, m in ipairs(resolved) do
                    if m.provider .. "/" .. m.id == current_key then
                        next_idx = (i % #resolved) + 1
                        break
                    end
                end
                M.set(session, resolved[next_idx])
            end)
        end)
    end)
end

--- Resolve the :PiSelectModel candidate list as a three-layer ladder:
--- 1. config-model entries matching available models (editor-local curated
---    shortlist wins, mirroring its role in cycling);
--- 2. the backend's resolved model scope (--models / enabledModels, read by
---    extensions/scoped-models.ts) intersected with available models;
--- 3. all available models.
--- Entries that match nothing already produced a Notify.warn inside
--- resolve_entries; a zero-match entry list falls through to the next layer
--- instead of dead-ending the picker.
---@param entries pi.ModelEntry[]? config.models; nil/empty skips layer 1
---@param scope { provider: string, id: string }[]? backend scope; nil/empty skips layer 2
---@param all_models table[] models from get_available_models
---@return table[] candidates non-empty unless all_models is empty
function M.resolve_select_candidates(entries, scope, all_models)
    if entries and #entries > 0 then
        local resolved = M.resolve_entries(entries, all_models)
        if #resolved > 0 then
            return resolved
        end
    end
    local scoped = ScopedModels.filter(scope, all_models)
    if #scoped > 0 then
        return scoped
    end
    return all_models
end

--- Select a model from configured models, then the backend's model scope,
--- then all available models. Rendered through the model dialog.
---@param session pi.Session
function M.select(session)
    local Dialog = require("pi.ui.dialog")
    M.with_available(session, function(all_models)
        local entries = Config.options.models
        local scope = ScopedModels.read(ScopedModels.state_path(session.tab))
        local models = M.resolve_select_candidates(entries, scope, all_models)
        ---@type string[]
        local labels = {}
        for i, m in ipairs(models) do
            labels[i] = M.format_label(m)
        end

        Dialog.select({ title = "Select model", options = labels, kind = "pi-model" }, function(choice)
            if not choice then
                return
            end
            for i, l in ipairs(labels) do
                if l == choice then
                    M.set(session, models[i])
                    return
                end
            end
        end)
    end)
end

--- Select a model from all available models using vim.ui.select (searchable).
---@param session pi.Session
function M.select_all(session)
    M.with_available(session, function(models)
        ---@type string[]
        local labels = {}
        for i, m in ipairs(models) do
            labels[i] = M.format_label(m)
        end
        vim.ui.select(labels, {
            prompt = "Select model (all)",
            -- snacks.nvim workaround: its picker can compute non-integer
            -- heights, crashing nvim_win_set_config. Force math.floor.
            snacks = {
                layout = {
                    config = function(layout)
                        for _, box in ipairs(layout.layout) do
                            if box.win == "list" then
                                box.height = math.floor(math.max(math.min(#labels, vim.o.lines * 0.8 - 10), 2))
                            end
                        end
                    end,
                },
            },
        }, function(_, idx)
            if not idx then
                return
            end
            M.set(session, models[idx])
        end)
    end)
end

return M
