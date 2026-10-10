--- pi CLI command construction.

local M = {}

local Compat = require("pi.compat")
local Config = require("pi.config")
local Notify = require("pi.notify")

---@type table<string, true>
local warned = {}

-- Flags that only exist from a given pi version onward. Passing an unknown
-- flag makes pi exit with an "unknown option" error before RPC starts, so a
-- gated flag is stripped (with a one-time warning) when the probed binary is
-- older than the floor.
--
--   --no-mcp  — added in pi 1.0.4 (single-run MCP disable; see CHANGELOG).
---@type table<string, string>
local GATED_ARGS = {
    ["--no-mcp"] = "1.0.4",
}

---@type table<string, true>
local warned_gated = {}

---@type boolean
local warned_version_unknown = false

---@type boolean
local warned_provider = false

---@type string?
local cached_version = nil

---@type boolean
local version_probed = false

---@type table<string, integer>
local filtered_flags = {
    ["--print"] = 1,
    ["-p"] = 1,
    ["--export"] = 2,
    ["--list-models"] = 1,
    ["--help"] = 0,
    ["-h"] = 0,
    ["--version"] = 0,
    ["-v"] = 0,
}

---@param arg string
local function warn_filtered(arg)
    if warned[arg] then
        return
    end
    warned[arg] = true
    Notify.warn("Ignoring conflicting pi CLI arg: " .. arg)
end

---@param args string[]
---@param index integer
---@param max_count integer
---@return integer
local function skip_optional_values(args, index, max_count)
    local next_index = index
    for _ = 1, max_count do
        local value = args[next_index]
        if type(value) ~= "string" or value:sub(1, 1) == "-" then
            break
        end
        next_index = next_index + 1
    end
    return next_index
end

---@return string
function M.bin()
    local cli = Config.options.cli or {}
    return cli.bin or "pi"
end

--- Probe the pi binary for its raw `--version` output. Returns nil when the
--- probe fails (binary missing, non-zero exit, empty output). Overridable in
--- tests via `M._probe_version`.
---@return string?
function M._probe_version()
    local ok, out = pcall(vim.fn.system, { M.bin(), "--version" })
    if not ok or type(out) ~= "string" or out == "" or vim.v.shell_error ~= 0 then
        return nil
    end
    return out
end

--- Lazily resolve the pi binary version (`x.y.z`), caching the first probe.
--- Returns nil when the version could not be determined.
---@return string?
function M.pi_version()
    if version_probed then
        return cached_version
    end
    version_probed = true
    local out = M._probe_version()
    if out then
        cached_version = Compat.extract_version(out)
    end
    return cached_version
end

--- Split an arg into its flag name (dropping a `=value` suffix).
---@param arg string
---@return string
local function flag_name(arg)
    local eq = arg:find("=", 1, true)
    return eq and arg:sub(1, eq - 1) or arg
end

---@param args string[]
local function check_provider_pairing(args)
    local has_provider = false
    local has_model = false
    for _, arg in ipairs(args) do
        if type(arg) == "string" then
            local name = flag_name(arg)
            if name == "--provider" then
                has_provider = true
            elseif name == "--model" then
                has_model = true
            end
        end
    end
    if has_provider and not has_model and not warned_provider then
        warned_provider = true
        Notify.warn("cli.args sets --provider without --model; pi >= 1.0.0 requires both")
    end
end

--- Drop warn-once state and the cached version probe. Test hook.
function M._reset()
    warned = {}
    warned_gated = {}
    warned_version_unknown = false
    warned_provider = false
    cached_version = nil
    version_probed = false
end

---@param args any
---@return string[]
function M.filter_args(args)
    if type(args) ~= "table" then
        return {}
    end

    local result = {} ---@type string[]
    local i = 1
    while i <= #args do
        local arg = args[i]
        if type(arg) ~= "string" or arg == "" then
            i = i + 1
        elseif arg == "--mode" then
            warn_filtered(arg)
            i = i + 2
        elseif arg:match("^%-%-mode=") or arg:match("^%-%-list%-models=") or arg:match("^%-%-export=") then
            warn_filtered(arg)
            i = i + 1
        elseif filtered_flags[arg] then
            warn_filtered(arg)
            i = skip_optional_values(args, i + 1, filtered_flags[arg])
        else
            local name = flag_name(arg)
            local min_version = GATED_ARGS[name]
            if not min_version then
                result[#result + 1] = arg
            else
                local version = M.pi_version()
                local cmp = version and Compat.compare_versions(version, min_version) or nil
                if version == nil then
                    if not warned_version_unknown then
                        warned_version_unknown = true
                        Notify.warn(
                            "Could not determine the pi version; passing "
                                .. name
                                .. " through unverified (requires pi "
                                .. min_version
                                .. "+)"
                        )
                    end
                    result[#result + 1] = arg
                elseif cmp == nil or cmp < 0 then
                    if not warned_gated[name] then
                        warned_gated[name] = true
                        Notify.warn(
                            "Ignoring " .. name .. ": requires pi " .. min_version .. " (found " .. version .. ")"
                        )
                    end
                else
                    result[#result + 1] = arg
                end
            end
            i = i + 1
        end
    end

    check_provider_pairing(result)

    return result
end

---@return string[]
function M.args()
    local cli = Config.options.cli or {}
    return M.filter_args(cli.args)
end

--- Absolute path to the plugin root (the directory containing lua/).
---@return string
local function plugin_root()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    return vim.fn.fnamemodify(source, ":h:h:h")
end

--- Absolute path to the bundled pi extension backing :PiTree.
---@return string
function M.tree_extension_path()
    return plugin_root() .. "/extensions/tree.ts"
end

--- Absolute path to the bundled pi extension backing the vision fallback.
---@return string
function M.vision_extension_path()
    return plugin_root() .. "/extensions/vision.ts"
end

--- Absolute path to the bundled pi extension backing auto session titles.
---@return string
function M.title_extension_path()
    return plugin_root() .. "/extensions/title.ts"
end

--- Absolute path to the bundled pi extension backing the todo tool
--- (todo_write + context reminders).
---@return string
function M.todo_extension_path()
    return plugin_root() .. "/extensions/todo.ts"
end

--- Absolute path to the bundled pi extension reporting the backend model
--- scope (pi --models / enabledModels) for :PiSelectModel fallback.
---@return string
function M.scoped_models_extension_path()
    return plugin_root() .. "/extensions/scoped-models.ts"
end

--- Absolute path to the bundled background bash tasks extension
--- (bash tool `run_in_background` override + `&`-prefix user bash).
---@return string
function M.bg_tasks_extension_path()
    return plugin_root() .. "/extensions/bg-tasks.ts"
end

--- Absolute path to the bundled sub-agent extension (parent sessions only).
---@return string
function M.subagent_extension_path()
    return plugin_root() .. "/extensions/subagent.ts"
end

--- Absolute path to the bundled sub-agent worker extension (child sessions only).
---@return string
function M.subagent_child_extension_path()
    return plugin_root() .. "/extensions/subagent-child.ts"
end

---@class pi.CliCommandOpts
---@field subagent? boolean false marks a child (sub-session) process: inject subagent-child.ts instead of subagent.ts (default: parent — inject subagent.ts).

---@param opts? pi.CliCommandOpts
---@return string[]
function M.command(opts)
    opts = opts or {}
    local cmd = { M.bin() }
    vim.list_extend(cmd, M.args())
    -- Inject the bundled extension that bridges session-tree navigation
    -- (:PiTree) into RPC mode; explicit -e paths work even if the user
    -- passed --no-extensions in cli.args.
    local tree = Config.options.tree or {}
    if tree.enabled ~= false then
        local ext = M.tree_extension_path()
        if vim.fn.filereadable(ext) == 1 then
            cmd[#cmd + 1] = "--extension"
            cmd[#cmd + 1] = ext
        end
    end
    -- Inject the vision fallback extension unconditionally (like tree.ts):
    -- it is a no-op unless a vision model is configured. The model reference
    -- travels via a runtime file the extension re-reads on every input event
    -- (PI_NVIM_VISION_FILE, see rpc.lua), so live setup() calls apply without
    -- respawning the RPC process.
    local ext = M.vision_extension_path()
    if vim.fn.filereadable(ext) == 1 then
        cmd[#cmd + 1] = "--extension"
        cmd[#cmd + 1] = ext
    end
    -- Inject the auto-title extension unconditionally (like vision.ts): it
    -- is a no-op unless enabled, and its options travel via a runtime file
    -- re-read on every turn_end (PI_NVIM_TITLE_FILE, see rpc.lua), so live
    -- setup() calls apply without respawning the RPC process.
    local title_ext = M.title_extension_path()
    if vim.fn.filereadable(title_ext) == 1 then
        cmd[#cmd + 1] = "--extension"
        cmd[#cmd + 1] = title_ext
    end
    -- Inject the model-scope bridge unconditionally (like title.ts): a no-op
    -- outside pi.nvim or on pi < 0.83.0. It reports the backend's resolved
    -- model scope (--models / enabledModels) via PI_NVIM_SCOPE_FILE so the
    -- :PiSelectModel picker can fall back from config.models to that scope.
    local scope_ext = M.scoped_models_extension_path()
    if vim.fn.filereadable(scope_ext) == 1 then
        cmd[#cmd + 1] = "--extension"
        cmd[#cmd + 1] = scope_ext
    end
    -- Inject the todo extension unconditionally (like title.ts) except when
    -- todo.enabled = false: the tool call itself is the only trigger, and its
    -- options travel via a runtime file re-read on every context event
    -- (PI_NVIM_TODO_FILE, see rpc.lua), so live setup() calls apply without
    -- respawning the RPC process. Injected for BOTH parent and child
    -- processes (no branching on opts.subagent): sub-sessions benefit from
    -- todo tracking too, and unlike the subagent tool there is no nesting
    -- risk (DESIGN-todo.md D4).
    local todo = Config.options.todo or {}
    if todo.enabled ~= false then
        local todo_ext = M.todo_extension_path()
        if vim.fn.filereadable(todo_ext) == 1 then
            cmd[#cmd + 1] = "--extension"
            cmd[#cmd + 1] = todo_ext
        end
    end
    -- Inject the background bash tasks extension unconditionally (like
    -- title.ts): the foreground bash path delegates byte-for-byte to the
    -- built-in definition, so the override is inert until the model passes
    -- run_in_background or the user prefixes an interactive `!` command with
    -- `&`. Below pi 0.85.1 the extension may fail to load (exports used are
    -- verified on 0.85.1) — pi logs the load error and the session continues
    -- with stock bash; see :checkhealth pi.
    local bg_ext = M.bg_tasks_extension_path()
    if vim.fn.filereadable(bg_ext) == 1 then
        cmd[#cmd + 1] = "--extension"
        cmd[#cmd + 1] = bg_ext
    end
    -- Sub-agent extensions, mutually exclusive per process role: parents
    -- get subagent.ts (orchestration tools + system-prompt note), children
    -- get subagent-child.ts (worker system-prompt note only — no tools, no
    -- nesting). subagent.enabled = false injects neither.
    local subagent = Config.options.subagent or {}
    if subagent.enabled ~= false then
        local sub_ext = opts.subagent ~= false and M.subagent_extension_path() or M.subagent_child_extension_path()
        if vim.fn.filereadable(sub_ext) == 1 then
            cmd[#cmd + 1] = "--extension"
            cmd[#cmd + 1] = sub_ext
        end
    end
    cmd[#cmd + 1] = "--mode"
    cmd[#cmd + 1] = "rpc"
    return cmd
end

return M
