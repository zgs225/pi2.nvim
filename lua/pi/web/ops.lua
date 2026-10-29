-- Daemon process and user-service operations for the web console.
--
-- `pi.web.init` owns the bridge (the plugin's side of the connection); this
-- module owns everything that outlives it:
--
--   * where the daemon comes from (`pi.web.runtime.resolve_daemon`, no npx);
--   * how it is started — attach if running, else start the installed user
--     service through `pi2 service start`, else spawn `<bin> daemon` detached
--     (pi2d `docs/adr/0002-install-and-run.md` §2.2);
--   * how the user service is probed and controlled (`pi2 service …`, which is
--     the only place that talks to systemd/launchd);
--   * where the daemon log lives (`$PI2_STATE_DIR/daemon.log`).
--
-- Rules:
--   * never throw and never notify: every entry point returns `info, err` or
--     calls an `on_done` back on the main loop, and the command layer decides
--     what the user reads (`:`PiWeb*` lives in `pi.web.ctl`);
--   * never block longer than the caller's budget (`vim.wait` only, and only
--     from the main loop);
--   * the daemon is a subcommand of the CLI: `<bin> daemon`, `<bin> service …`.

--- The unit file `pi2 install-service` renders.
--- @class pi.web.ServiceUnit
--- @field name string
--- @field path string
--- @field installed boolean

--- One `pi2 service status --json` body, normalised.
--- @class pi.web.ServiceStatus
--- @field manager "systemd"|"launchd"|"none"
--- @field unit pi.web.ServiceUnit|nil
--- @field enabled boolean|nil
--- @field active boolean|nil
--- @field linger boolean|nil
--- @field error string|nil

--- Options for the attach → service → spawn ladder.
--- @class pi.web.EnsureOpts
--- @field cfg? pi.WebConfig
--- @field wait_ms? integer
--- @field poll_ms? integer
--- @field timeout? integer

--- Daemon process + user-service operations (`pi.web.ops`).
--- @class pi.web.Ops
local M = {}

local Runtime = require("pi.web.runtime")

local uv = vim.uv or vim.loop

--- How long `:PiWeb` waits for `daemon.json` by default.
M.START_TIMEOUT_MS = 10000
--- Poll interval while waiting for `daemon.json`.
M.POLL_MS = 100
--- How long one `pi2 service …` call may take before we give up on it.
M.SERVICE_WAIT_MS = 5000
--- How long a spawned daemon gets to publish `daemon.json`.
M.SPAWN_WAIT_MS = 10000
--- Every action `pi2 service` accepts (completion + validation).
M.SERVICE_ACTIONS = { "status", "start", "stop", "enable", "disable" }

--- The injectable process runner. Tests replace it with a fake that never
--- spawns anything; production uses `vim.system`.
--- @type fun(argv: string[], opts: table, on_exit: fun(res: table)): any
M.system = function(argv, opts, on_exit)
    return vim.system(argv, opts, on_exit)
end

--- @return pi.WebConfig
local function web_config()
    local ok, config = pcall(require, "pi.config")
    if not ok then
        return {}
    end
    return config.options.web or {}
end

--- Write one line to the bridge log (never at load time: `pi.web` requires us).
--- @param level string
--- @param msg string
local function log(level, msg)
    local ok, Web = pcall(require, "pi.web")
    if ok and type(Web.log) == "function" then
        pcall(Web.log, level, msg)
    end
end

--- Flatten to one bounded line.
--- @param text any
--- @param limit? integer
--- @return string
function M.one_line(text, limit)
    local line = tostring(text or ""):gsub("%s+", " ")
    line = vim.trim(line)
    local max = limit or 200
    if #line > max then
        return line:sub(1, max) .. "…"
    end
    return line
end

--- First non-empty line of a block of text, flattened. `""` when there is none.
--- @param text any
--- @return string
function M.first_line(text)
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local trimmed = vim.trim(line)
        if trimmed ~= "" then
            return M.one_line(trimmed)
        end
    end
    return ""
end

-- ---------------------------------------------------------------------------
-- autostart policy
-- ---------------------------------------------------------------------------

--- Effective autostart policy.
---
--- `web.autostart` wins when it holds one of the three documented values; the
--- deprecated `web.auto_start` boolean is translated (`false` → never start,
--- `true` → spawn detached) so existing configs keep working. Anything else
--- falls back to `"auto"`.
--- @param cfg? pi.WebConfig
--- @return "auto"|"spawn"|false
function M.autostart_mode(cfg)
    cfg = cfg or web_config()
    local mode = cfg.autostart
    if mode == "auto" or mode == "spawn" or mode == false then
        return mode
    end
    if cfg.auto_start == false then
        return false
    elseif cfg.auto_start == true then
        return "spawn"
    end
    return "auto"
end

--- Human wording for a mode (`:PiWebStatus`).
--- @param mode "auto"|"spawn"|false
--- @return string
function M.autostart_label(mode)
    if mode == "spawn" then
        return "spawn (always start a detached daemon)"
    elseif mode == false then
        return "off (connect only; start the daemon yourself)"
    end
    return "auto (attach, else start the service, else spawn)"
end

-- ---------------------------------------------------------------------------
-- daemon discovery
-- ---------------------------------------------------------------------------

--- Decoded `<runtime>/daemon.json`, or nil when no daemon published one.
--- This is the single liveness criterion for the whole plugin.
--- @return table|nil
function M.daemon_info()
    local ok, info = pcall(Runtime.read_daemon_json)
    if ok and type(info) == "table" then
        return info
    end
    return nil
end

--- Alias for `daemon_info()`: a running daemon is one that published its port.
--- @return table|nil
function M.running()
    return M.daemon_info()
end

--- `http://127.0.0.1:<port>` for a daemon record, or nil when it has no port.
--- @param info? table
--- @return string|nil
function M.daemon_url(info)
    info = info or M.daemon_info()
    local port = info and tonumber(info.port)
    if not port or port <= 0 then
        return nil
    end
    return ("http://127.0.0.1:%d"):format(math.floor(port))
end

--- Wait (bounded) for `daemon.json`, returning the record it holds.
--- Main loop only (`vim.wait`).
--- @param wait_ms? integer
--- @param poll_ms? integer
--- @return table|nil info
function M.wait_for_daemon(wait_ms, poll_ms)
    local info = M.daemon_info()
    if info then
        return info
    end
    vim.wait(wait_ms or M.START_TIMEOUT_MS, function()
        info = M.daemon_info()
        return info ~= nil
    end, poll_ms or M.POLL_MS)
    return info
end

-- ---------------------------------------------------------------------------
-- spawning `pi2 daemon`
-- ---------------------------------------------------------------------------

--- Environment the daemon needs from `web.*` (bind address, public URL, roots).
--- @param cfg? pi.WebConfig
--- @return table<string, string>|nil
function M.daemon_env(cfg)
    cfg = cfg or web_config()
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
    if next(env) == nil then
        return nil
    end
    return env
end

--- Argv for a lazy start: `<bin> daemon [web.daemon_args…]`.
--- @param resolved pi.web.DaemonCandidate
--- @param cfg? pi.WebConfig
--- @return string[]
function M.daemon_argv(resolved, cfg)
    cfg = cfg or web_config()
    local argv = { resolved.bin, "daemon" }
    for _, extra in ipairs(cfg.daemon_args or {}) do
        argv[#argv + 1] = tostring(extra)
    end
    return argv
end

--- Path of the daemon log written by a plugin-spawned daemon.
--- @return string
function M.log_path()
    return vim.fs.joinpath(Runtime.state_dir(), "daemon.log")
end

--- Open the daemon log for appending (`0600`). Returns `fd|nil, path`.
--- The descriptor is handed to `jobstart` as stdout/stderr and closed here
--- afterwards: libuv duplicates it into the child, so the parent's copy is dead
--- weight as soon as the process exists.
--- @return integer|nil fd, string path
function M.open_log()
    local path = M.log_path()
    pcall(Runtime.ensure_dir, vim.fs.dirname(path))
    local ok, fd = pcall(uv.fs_open, path, "a", 384)
    if not ok or type(fd) ~= "number" then
        return nil, path
    end
    return fd, path
end

--- Spawn `pi2 daemon` detached, appending its output to `log_path()`.
---
--- `pi2 daemon` never daemonizes itself, so the plugin's `detach` is what makes
--- it survive Neovim. Without the descriptor redirect the daemon's own lines
--- (the "listening on …" banner, startup failures) would be lost, which is what
--- `:PiWebLog` reads.
--- @return boolean started, string|nil err
function M.spawn()
    local cfg = web_config()
    local resolved = Runtime.resolve_daemon()
    if not resolved then
        return false,
            "pi2 not found — install it (`npm i -g @yuez/pi2d`, the curl installer or brew) or run :PiWebInstall"
    end

    local argv = M.daemon_argv(resolved, cfg)
    --- @type table
    local job_opts = { detach = true }
    local env = M.daemon_env(cfg)
    if env then
        job_opts.env = env
    end
    local fd, path = M.open_log()
    if fd then
        job_opts.stdout = fd
        job_opts.stderr = fd
    end

    local ok, pid = pcall(vim.fn.jobstart, argv, job_opts)
    if fd then
        pcall(uv.fs_close, fd)
    end
    if not ok or type(pid) ~= "number" or pid <= 0 then
        return false, "failed to spawn " .. tostring(argv[1])
    end
    log(
        "info",
        ("spawned daemon %s (%s, pid %d, log %s)"):format(argv[1], resolved.source, pid, fd and path or "dropped")
    )
    return true
end

-- ---------------------------------------------------------------------------
-- `pi2 service …`
-- ---------------------------------------------------------------------------

--- Run one CLI command and wait for it (`vim.system(...):wait`), bounded.
--- Main loop only.
--- @param argv string[]
--- @param timeout? integer
--- @return table|nil res, string|nil err
function M.run_sync(argv, timeout)
    local ok, handle = pcall(M.system, argv, { text = true })
    if not ok or handle == nil then
        return nil, "cannot run " .. tostring(argv[1]) .. ": " .. M.one_line(handle)
    end
    local ok_wait, res = pcall(function()
        return handle:wait(timeout or M.SERVICE_WAIT_MS)
    end)
    if not ok_wait or type(res) ~= "table" then
        return nil, ("timed out running `%s` after %d ms"):format(table.concat(argv, " "), timeout or M.SERVICE_WAIT_MS)
    end
    return res, nil
end

--- @param resolved pi.web.DaemonCandidate
--- @param action string
--- @return string[]
function M.service_argv(resolved, action)
    local argv = { resolved.bin, "service", action }
    if action == "status" then
        argv[#argv + 1] = "--json"
    end
    return argv
end

--- Normalise a `pi2 service status --json` body into the shape the plugin uses.
--- Accepts a decoded table or the raw JSON text; returns nil when it is
--- unusable (the caller then reports "unreadable output" instead of guessing).
--- @param payload table|string|nil
--- @return pi.web.ServiceStatus|nil
function M.decode_service_status(payload)
    local decoded = payload
    if type(payload) == "string" then
        local text = vim.trim(payload)
        if text == "" then
            return nil
        end
        local ok, value = pcall(vim.json.decode, text)
        if not ok or type(value) ~= "table" then
            return nil
        end
        decoded = value
    end
    if type(decoded) ~= "table" then
        return nil
    end
    local function bool_or_nil(value)
        if value == true or value == false then
            return value
        end
        return nil
    end
    local unit = decoded.unit
    local manager = decoded.manager
    if manager ~= "systemd" and manager ~= "launchd" and manager ~= "none" then
        manager = "none"
    end
    local status = {
        manager = manager,
        unit = nil,
        enabled = bool_or_nil(decoded.enabled),
        active = bool_or_nil(decoded.active),
        linger = bool_or_nil(decoded.linger),
        error = type(decoded.error) == "string" and decoded.error ~= "" and decoded.error or nil,
    }
    if type(unit) == "table" and type(unit.path) == "string" then
        status.unit = {
            name = type(unit.name) == "string" and unit.name or "pi2.service",
            path = unit.path,
            installed = unit.installed == true,
        }
    end
    return status
end

--- `pi2 service status` synchronously (used by `ensure()` and `:checkhealth`).
--- Main loop only.
--- @param opts? pi.web.EnsureOpts
--- @return pi.web.ServiceStatus|nil status, string|nil err
function M.service_status_sync(opts)
    opts = opts or {}
    local resolved = Runtime.resolve_daemon()
    if not resolved then
        return nil, "pi2 not found — install it (`npm i -g @yuez/pi2d`) or run :PiWebInstall"
    end
    local argv = M.service_argv(resolved, "status")
    local res, err = M.run_sync(argv, opts.timeout or M.SERVICE_WAIT_MS)
    if not res then
        return nil, err
    end
    if tonumber(res.code) ~= 0 then
        return nil,
            M.first_line(res.stderr) ~= "" and M.first_line(res.stderr) or ("pi2 service status exited " .. tostring(
                res.code
            ))
    end
    local status = M.decode_service_status(res.stdout)
    if not status then
        return nil, "pi2 service status returned unreadable output"
    end
    return status, nil
end

--- Run one service action asynchronously; `on_done(res|nil, err|nil)`, where
--- `res` is `{ code, stdout, stderr, argv }`.
--- @param action string
--- @param on_done fun(res: table|nil, err: string|nil)
function M.service(action, on_done)
    on_done = on_done or function() end
    local resolved = Runtime.resolve_daemon()
    if not resolved then
        on_done(
            nil,
            "pi2 not found — install it (`npm i -g @yuez/pi2d`, the curl installer or brew) or run :PiWebInstall"
        )
        return
    end
    local argv = M.service_argv(resolved, action)
    local done = false
    local ok, handle = pcall(M.system, argv, { text = true }, function(res)
        if done then
            return
        end
        done = true
        vim.schedule(function()
            on_done({
                code = res and res.code or 1,
                stdout = res and res.stdout or "",
                stderr = res and res.stderr or "",
                argv = argv,
            }, nil)
        end)
    end)
    if not ok or handle == nil then
        vim.schedule(function()
            on_done(nil, "cannot run `" .. table.concat(argv, " ") .. "`: " .. M.one_line(handle))
        end)
    end
end

--- Async `pi2 service status`; `on_done(status|nil, err|nil)`.
--- @param on_done fun(status: pi.web.ServiceStatus|nil, err: string|nil)
function M.service_status(on_done)
    on_done = on_done or function() end
    M.service("status", function(res, err)
        if not res then
            on_done(nil, err)
            return
        end
        if tonumber(res.code) ~= 0 then
            on_done(
                nil,
                M.first_line(res.stderr) ~= "" and M.first_line(res.stderr)
                    or ("pi2 service status exited " .. tostring(res.code))
            )
            return
        end
        local status = M.decode_service_status(res.stdout)
        if not status then
            on_done(nil, "pi2 service status returned unreadable output")
            return
        end
        on_done(status, nil)
    end)
end

-- ---------------------------------------------------------------------------
-- ensure: attach → service → spawn
-- ---------------------------------------------------------------------------

--- How many lines `:PiWebLog` shows by default.
M.LOG_LINES = 200

--- Read the last `count` lines of a file. Returns `lines, err`.
--- @param path string
--- @param count integer
--- @return string[] lines, string|nil err
function M.tail_file(path, count)
    local ok, stat = pcall(uv.fs_stat, path)
    if not ok or not stat or stat.type ~= "file" then
        return {}, "no log yet at " .. path
    end
    local size = tonumber(stat.size) or 0
    local window = 256 * 1024
    local offset = size > window and (size - window) or 0
    local fd_ok, fd = pcall(uv.fs_open, path, "r", 0)
    if not fd_ok or not fd then
        return {}, "cannot read " .. path
    end
    local read_ok, data = pcall(uv.fs_read, fd, size - offset, offset)
    pcall(uv.fs_close, fd)
    if not read_ok or type(data) ~= "string" then
        return {}, "cannot read " .. path
    end
    if offset > 0 then
        -- The window may start mid-line; drop the partial first line.
        data = data:gsub("^[^\n]*\n", "")
    end
    local lines = vim.split(data, "\n", { plain = true })
    while #lines > 0 and vim.trim(lines[#lines]) == "" do
        table.remove(lines)
    end
    if #lines > count then
        local tail = {}
        for index = #lines - count + 1, #lines do
            tail[#tail + 1] = lines[index]
        end
        lines = tail
    end
    return lines, nil
end

--- Last lines of the daemon log for `:PiWebLog`.
---
--- Service mode reads the service manager's own log (`journalctl --user -u
--- pi2` on Linux, the LaunchAgent's `StandardOutPath` on macOS); spawn mode
--- reads `log_path()`. A missing log is reported as one line, never an error.
--- @param count? integer
--- @param on_done? fun(lines: string[], err: string|nil)
--- @return string[]|nil lines, string|nil err synchronous result in tests
function M.log_lines(count, on_done)
    count = count or M.LOG_LINES
    local lines, err
    local status = M.service_status_sync({ timeout = M.SERVICE_WAIT_MS })

    if status and status.unit and status.unit.installed and status.manager == "systemd" then
        local res = M.run_sync({ "journalctl", "--user", "-u", "pi2", "-n", tostring(count), "--no-pager" })
        if res and tonumber(res.code) == 0 then
            lines = vim.split(tostring(res.stdout or ""), "\n", { plain = true })
            while #lines > 0 and vim.trim(lines[#lines]) == "" do
                table.remove(lines)
            end
        else
            lines, err = M.tail_file(M.log_path(), count)
        end
    elseif status and status.unit and status.unit.installed and status.manager == "launchd" then
        local base = Runtime.state_dir()
        local out_lines, out_err = M.tail_file(vim.fs.joinpath(base, "pi2-daemon.log"), count)
        local err_lines = M.tail_file(vim.fs.joinpath(base, "pi2-daemon.err.log"), count)
        lines = {}
        vim.list_extend(lines, out_lines)
        if #err_lines > 0 then
            vim.list_extend(lines, err_lines)
        end
        if #lines == 0 then
            err = out_err
        end
    else
        lines, err = M.tail_file(M.log_path(), count)
    end

    if lines == nil or #lines == 0 then
        lines = { err or ("no log yet at " .. M.log_path()) }
        err = nil
    end
    if on_done then
        vim.schedule(function()
            on_done(lines, err)
        end)
        return nil, nil
    end
    return lines, err
end

--- Start the installed user service (only when a unit exists) and wait for it.
--- Never blocks longer than `M.SERVICE_WAIT_MS` + `wait_ms`.
--- @param opts? pi.web.EnsureOpts
--- @return boolean started, string|nil err
function M.start_service(opts)
    opts = opts or {}
    local status, status_err = M.service_status_sync({ timeout = opts.timeout })
    if not status then
        -- Not fatal: without a readable unit there is simply nothing to start.
        log("debug", "service probe failed: " .. tostring(status_err))
        return false, nil
    end
    if not (status.unit and status.unit.installed) then
        return false, nil
    end
    local resolved = Runtime.resolve_daemon()
    if not resolved then
        return false, "pi2 not found — install it (`npm i -g @yuez/pi2d`) or run :PiWebInstall"
    end
    local argv = M.service_argv(resolved, "start")
    local res, err = M.run_sync(argv, opts.timeout or M.SERVICE_WAIT_MS)
    if not res then
        return false, err
    end
    if tonumber(res.code) ~= 0 then
        local detail = M.first_line(res.stderr)
        return false, detail ~= "" and detail or ("pi2 service start exited " .. tostring(res.code))
    end
    log("info", "started the user service (" .. table.concat(argv, " ") .. ")")
    return true, nil
end

--- Resolve how `:PiWeb` may reach a daemon: attach → service → spawn.
---
--- Nothing here needs a `pi2` executable when a daemon is already running —
--- that is the service-mode case, where resolution may legitimately fail.
--- Main loop only (`vim.wait`).
--- @param opts? pi.web.EnsureOpts
--- @return table|nil info, string|nil err
function M.ensure(opts)
    opts = opts or {}
    local cfg = opts.cfg or web_config()
    local wait_ms = opts.wait_ms or M.START_TIMEOUT_MS
    local poll_ms = opts.poll_ms or M.POLL_MS

    -- 1. attach: a published daemon.json is all that is required.
    local info = M.daemon_info()
    if info then
        return info
    end

    local mode = M.autostart_mode(cfg)
    if mode == false then
        return nil,
            "web.autostart is disabled — start the daemon with `pi2 daemon` (or enable the user service with :PiWebService install)"
    end

    local errors = {}

    -- 2. the user service, when one is installed and mode is "auto".
    if mode == "auto" then
        local started, err = M.start_service(opts)
        if started then
            info = M.wait_for_daemon(wait_ms, poll_ms)
            if info then
                return info
            end
            errors[#errors + 1] = "the service started but published no daemon.json"
        elseif err then
            errors[#errors + 1] = "service: " .. err
        end
    end

    -- 3. spawn a detached daemon.
    local spawned, spawn_err = M.spawn()
    if not spawned then
        errors[#errors + 1] = spawn_err or "failed to spawn pi2 daemon"
        return nil, table.concat(errors, "; ")
    end
    info = M.wait_for_daemon(wait_ms, poll_ms)
    if info then
        return info
    end
    errors[#errors + 1] = "pi2 daemon did not publish daemon.json within " .. tostring(wait_ms) .. " ms"
    return nil, table.concat(errors, "; ")
end

return M
