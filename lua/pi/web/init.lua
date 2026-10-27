-- Web console entry point: bridge lifecycle, daemon bootstrap, `:PiWeb*`
-- commands support and the headless/host switches.
--
-- Design (`.agents/docs/web-integration.md` §2/§6):
--   * the bridge is a singleton per Neovim process and never blocks the editor;
--   * the daemon is started lazily (detached `jobstart`) only when the socket is
--     missing and `web.auto_start` is on — a daemon that spawned us (headless
--     host) already has its socket, so `pi.host` never spawns a second one;
--   * `pi.host` flips `host_mode`, which makes `instance.shutdown` quit the
--     headless process after stopping its sessions.

local M = {}

local Bridge = require("pi.web.bridge")
local Runtime = require("pi.web.runtime")
local Protocol = require("pi.web.protocol")
local Notify = require("pi.notify")

local uv = vim.uv or vim.loop

--- Reported in `hello.pluginVersion`. The daemon only requires a non-empty
--- string; a release build may override it.
M.VERSION = "1.8.0-dev"

--- @type pi.web.Bridge|nil
local bridge = nil
--- @type pi.web.Instance|nil
local instance = nil
local host_mode = false
local task_listener = false
local autocmds_installed = false

--- @return pi.WebConfig
local function config()
    return require("pi.config").options.web or {}
end

--- @return boolean
function M.enabled()
    return bridge ~= nil or config().enabled == true
end

--- @return boolean
function M.has_ui()
    return #vim.api.nvim_list_uis() > 0
end

--- True when this process was started by the daemon (`pi2 daemon`) for one workspace.
--- @return boolean
function M.is_host()
    return host_mode
end

--- @param value boolean
function M.set_host(value)
    host_mode = value and true or false
end

--- Write one diagnostic line. `web.log = true` uses
--- `stdpath("log")/pi2-web.log`; a string is used as the path. Falls back to
--- silence (never `print`: this process may be the daemon's instance).
--- @param level string
--- @param msg string
function M.log(level, msg)
    local sink = config().log
    if not sink then
        return
    end
    local path = type(sink) == "string" and sink or (vim.fn.stdpath("log") .. "/pi2-web.log")
    local line = os.date("%Y-%m-%dT%H:%M:%S ") .. tostring(level) .. " " .. tostring(msg) .. "\n"
    local fd = uv.fs_open(path, "a", 384) -- 0600
    if not fd then
        return
    end
    pcall(uv.fs_write, fd, line, -1)
    pcall(uv.fs_close, fd)
end

--- @return boolean
function M.daemon_present()
    return uv.fs_stat(Runtime.socket_path()) ~= nil
end

--- Spawn the daemon detached when no socket is present. Never blocks and never
--- raises: the bridge retries (with backoff) until the daemon is up.
---
--- The executable comes from `pi.web.runtime.resolve_daemon()` (config → PATH →
--- plugin data → checkout → npx). `npx` runs through the pinned package
--- (`npx -y @yuez/pi2d@latest daemon`); every other source runs `<bin> daemon`.
--- @return boolean started, string|nil err
function M.start_daemon()
    local cfg = config()
    if cfg.auto_start == false then
        return false, "web.auto_start is disabled"
    end
    if M.daemon_present() then
        return true
    end

    local resolved = Runtime.resolve_daemon()
    if not resolved then
        return false, "daemon not found: " .. tostring(cfg.daemon or "pi2")
    end

    -- The daemon is a subcommand of the CLI: `pi2 daemon [args...]`.
    local argv
    if resolved.source == "npx" then
        argv = { "npx", "-y", "@yuez/pi2d@latest", "daemon" }
    else
        argv = { resolved.bin, "daemon" }
    end
    for _, extra in ipairs(cfg.daemon_args or {}) do
        argv[#argv + 1] = tostring(extra)
    end

    --- @type table
    local job_opts = { detach = true }
    local env = {}
    if type(cfg.host) == "string" and cfg.host ~= "" then
        env.PI2_HOST = cfg.host
    end
    if type(cfg.public_url) == "string" and cfg.public_url ~= "" then
        env.PI2_PUBLIC_URL = cfg.public_url
    end
    if type(cfg.workspace_roots) == "table" and #cfg.workspace_roots > 0 then
        env.PI2_WORKSPACE_ROOTS = table.concat(cfg.workspace_roots, ",")
    end
    if next(env) ~= nil then
        job_opts.env = env
    end
    local ok, pid = pcall(vim.fn.jobstart, argv, job_opts)
    if not ok or type(pid) ~= "number" or pid <= 0 then
        return false, "failed to spawn " .. argv[1]
    end
    M.log("info", ("spawned daemon %s (%s, pid %d)"):format(argv[1], resolved.source, pid))
    return true
end

--- Answer a daemon `workspace.query` record (the bridge routes these outside
--- the normal cmd handler table).
--- @param payload table|nil
--- @param ctx pi.web.CmdContext
function M.handle_query(payload, ctx)
    local Commands = require("pi.web.commands")
    local params = type(payload) == "table" and payload or {}
    local ok, result, err = pcall(Commands.handlers["workspace.query"], params, ctx)
    local seq = instance and instance:next_seq(ctx.session_id) or 1
    if ok and result then
        local ack = { disposition = "started" }
        for key, value in pairs(result) do
            ack[key] = value
        end
        ctx.bridge:send_record(Protocol.envelope(Protocol.OUT.ACK, { id = ctx.id, seq = seq, payload = ack }))
        return
    end
    local error_payload = type(err) == "table" and err or { code = Protocol.ERR.INTERNAL, message = tostring(err) }
    ctx.bridge:send_record(Protocol.envelope(Protocol.OUT.ERROR, {
        id = ctx.id,
        payload = {
            code = error_payload.code or Protocol.ERR.INTERNAL,
            message = error_payload.message or "workspace query failed",
            retryable = false,
        },
    }))
end

--- Stop every session (used by `instance.shutdown` and process exit).
local function stop_sessions()
    local ok, manager = pcall(require, "pi.sessions.manager")
    if not ok then
        return
    end
    for _, session in ipairs(manager.list_all()) do
        pcall(manager.close_session, session)
    end
end

--- `instance.shutdown` from the daemon: drain sessions, then quit a headless
--- host (the only process the daemon owns). A TUI instance merely disconnects.
--- @param payload table|nil
--- @return boolean
function M.shutdown(payload)
    M.log("info", "instance.shutdown (" .. tostring(payload and payload.mode or "drain") .. ")")
    stop_sessions()
    if host_mode then
        -- Signal the `pi.host.start` wait loop and quit once the RPC processes
        -- have had a tick to exit.
        pcall(function()
            require("pi.host").stop()
        end)
        vim.defer_fn(function()
            pcall(vim.cmd, "qa!")
        end, 200)
    else
        M.stop()
    end
    return true
end

--- @return boolean
local function install_autocmds()
    if autocmds_installed then
        return true
    end
    autocmds_installed = true
    local group = vim.api.nvim_create_augroup("pi2_web", { clear = true })
    vim.api.nvim_create_autocmd("UIEnter", {
        group = group,
        desc = "pi2 web: re-present queued attention requests in the attached UI",
        callback = function()
            if not M.has_ui() then
                return
            end
            local Attention = require("pi.attention")
            if Attention.total_count() == 0 then
                return
            end
            vim.schedule(function()
                pcall(Attention.open_next)
            end)
        end,
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        desc = "pi2 web: stop the bridge",
        callback = function()
            pcall(M.stop)
        end,
    })
    return true
end

--- Subscribe the task registry's debounced refresh to the web fanout. Batch
--- task transitions (including `task.stop` from a web command) arrive here.
local function ensure_task_listener()
    if task_listener then
        return
    end
    local ok, Tasks = pcall(require, "pi.tasks")
    if not ok or type(Tasks.on_refresh) ~= "function" then
        return
    end
    task_listener = true
    Tasks.on_refresh(function()
        local inst = instance
        if inst and inst._active then
            pcall(inst.publish_tasks, inst)
        end
    end)
end

--- Adopt the daemon coordinates a headless host inherits: `pi2 daemon` passes its
--- socket separately (`PI2_DAEMON_SOCKET`) while `pi.web.runtime` resolves
--- everything from `PI2_SOCKET`. Also read a custom token file once; the
--- default `<socket>.token` is read lazily by the bridge on every handshake.
--- @return string|nil explicit_token
local function adopt_daemon_env()
    local daemon_socket = vim.env.PI2_DAEMON_SOCKET
    if type(daemon_socket) == "string" and daemon_socket ~= "" then
        local explicit = vim.env.PI2_SOCKET
        if explicit == nil or explicit == "" then
            vim.env.PI2_SOCKET = daemon_socket
        end
    end
    local token_path = vim.env.PI2_DAEMON_TOKEN_PATH
    if type(token_path) ~= "string" or token_path == "" or token_path == Runtime.token_path() then
        return nil
    end
    local fd = uv.fs_open(token_path, "r", 0)
    if not fd then
        return nil
    end
    local stat = uv.fs_fstat(fd)
    local data
    if stat then
        local ok, content = pcall(uv.fs_read, fd, stat.size, 0)
        if ok then
            data = content
        end
    end
    pcall(uv.fs_close, fd)
    if type(data) ~= "string" then
        return nil
    end
    data = vim.trim(data)
    return data ~= "" and data or nil
end

--- Start the bridge (idempotent). Lazy-spawns the daemon when needed.
--- @return pi.web.Bridge|nil
function M.start()
    if bridge then
        return bridge
    end
    local cfg = config()
    cfg.enabled = true
    local explicit_token = adopt_daemon_env()

    local ok_daemon, daemon_err = M.start_daemon()
    if not ok_daemon then
        M.log("warn", "daemon start skipped: " .. tostring(daemon_err))
    end

    local Instance = require("pi.web.instance")
    instance = Instance.setup({ cwd = vim.fn.getcwd() })
    ensure_task_listener()
    install_autocmds()

    local listen_addr = vim.v.servername
    if type(listen_addr) ~= "string" or listen_addr == "" then
        listen_addr = nil
    end

    local Commands = require("pi.web.commands")
    local opts = {
        workspace_id = instance.workspace_id,
        cwd = instance.cwd,
        plugin_version = M.VERSION,
        has_ui = M.has_ui(),
        listen_addr = listen_addr,
        handlers = Commands.handlers,
        log = function(level, msg)
            M.log(level, msg)
        end,
        seq_provider = function(session_id)
            return instance and instance:next_seq(session_id) or 1
        end,
        on_ready = function()
            if instance then
                instance:send_instance_state()
            end
        end,
        on_subscribe = function(session_id)
            if instance then
                instance:on_subscribe(session_id)
            end
        end,
        on_unsubscribe = function(session_id)
            if instance then
                instance:on_unsubscribe(session_id)
            end
        end,
        on_shutdown = function(payload)
            M.shutdown(payload)
        end,
        on_query = function(payload, ctx)
            M.handle_query(payload, ctx)
        end,
    }

    if explicit_token then
        opts.token = explicit_token
    end
    bridge = Bridge.setup(opts)
    instance.bridge = bridge
    M.log("info", "web bridge started for workspace " .. instance.workspace_id)
    return bridge
end

--- Stop the bridge. Sessions and the daemon keep running.
--- @return boolean
function M.stop()
    if bridge then
        pcall(bridge.stop, bridge)
    end
    Bridge.shutdown()
    bridge = nil
    pcall(require("pi.web.instance").shutdown)
    instance = nil
    local ok, cfg = pcall(function()
        return require("pi.config").options.web
    end)
    if ok and type(cfg) == "table" then
        cfg.enabled = false
    end
    M.log("info", "web bridge stopped")
    return true
end

--- @return table status
function M.status()
    local current = bridge
    local status = current and current:status() or { started = false, connected = false, ready = false }
    status.enabled = M.enabled()
    status.host = host_mode
    status.daemon_socket = Runtime.socket_path()
    status.daemon_present = M.daemon_present()
    if instance then
        status.workspace_id = instance.workspace_id
        status.instance_id = current and current:status().instance_id or status.instance_id
        status.sessions = instance:session_count()
    end
    return status
end

--- Configure + optionally start the web console. `pi.setup()` calls this when
--- `web.enabled` is true; `pi.host` calls it with `host = true`.
--- @param opts? { host?: boolean, start?: boolean, autocmds?: boolean }
--- @return pi.web.Bridge|nil
function M.setup(opts)
    opts = opts or {}
    M.set_host(opts.host == true)
    if opts.autocmds ~= false then
        install_autocmds()
    end
    if opts.start == false then
        return bridge
    end
    return M.start()
end

--- Human-readable one-liner list for `:PiWebStatus`.
--- @return string[]
function M.status_lines()
    local status = M.status()
    local lines = {
        ("web: %s"):format(status.enabled and "enabled" or "disabled"),
        ("bridge: %s"):format(status.started and (status.ready and "ready" or "connecting") or "stopped"),
        ("socket: %s%s"):format(status.daemon_socket, status.daemon_present and "" or " (missing)"),
        ("workspace: %s"):format(tostring(status.workspace_id)),
        ("instance: %s"):format(tostring(status.instance_id)),
        ("sessions: %s"):format(tostring(status.sessions or 0)),
        ("host: %s"):format(status.host and "yes" or "no"),
    }
    return lines
end

return M
