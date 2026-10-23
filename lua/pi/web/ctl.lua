-- `:PiWeb*` command implementations (the user-facing control surface).
--
-- This module is the only place that shells out for the console workflows:
-- install/update (npm), doctor, pairing and the one-command `:PiWeb` flow
-- (choose/remember access mode → resolve daemon → start the bridge → wait for
-- `<runtime>/daemon.json` → sign in a local browser or show the pairing hint).
--
-- Rules:
--   * never throw at the user — `call()` wraps every entry point and degrades to
--     a one-line `pi.notify`;
--   * never block longer than the contract allows (`:PiWeb` polls `daemon.json`
--     for at most 10 s, everything else is async);
--   * never print the CLI token: only `pi2 open --print`-style flows return the
--     signed-in URL, and this module never renders it.

local M = {}

local Notify = require("pi.notify")

--- `:PiWeb` waits this long for the daemon to publish `daemon.json`.
M.START_TIMEOUT_MS = 10000
--- Poll interval while waiting for `daemon.json`.
M.POLL_MS = 100

--- @return pi.WebConfig
local function web_config()
    local ok, config = pcall(require, "pi.config")
    if not ok then
        return {}
    end
    return config.options.web or {}
end

--- Flatten to one bounded line.
--- @param text any
--- @return string
local function one_line(text)
    local line = tostring(text or ""):gsub("%s+", " ")
    line = vim.trim(line)
    if #line > 200 then
        line = line:sub(1, 200) .. "…"
    end
    return line
end

--- @param text any
--- @param fallback string
--- @return string
local function detail(text, fallback)
    local line = one_line(text)
    if line == "" then
        return fallback
    end
    return line
end

--- Where `:PiWebInstall` puts the npm package.
--- @param cfg? pi.WebConfig
--- @return string
function M.install_dir(cfg)
    cfg = cfg or web_config()
    if type(cfg.install_dir) == "string" and cfg.install_dir ~= "" then
        return cfg.install_dir
    end
    return vim.fs.joinpath(vim.fn.stdpath("data"), "pi2d")
end

--- Build the argv for a CLI subcommand, honouring the resolved source.
--- `npx` always runs the pinned package: `npx -y @yuez/pi2d@latest <sub> …`.
--- @param resolved pi.web.DaemonCandidate
--- @param sub string
--- @param extra? string[]
--- @return string[]
function M.cli_argv(resolved, sub, extra)
    local argv
    if resolved.source == "npx" then
        argv = { "npx", "-y", "@yuez/pi2d@latest", sub }
    else
        argv = { resolved.bin, sub }
    end
    for _, arg in ipairs(extra or {}) do
        argv[#argv + 1] = tostring(arg)
    end
    return argv
end

--- Run a command asynchronously and hand the result back on the main loop.
--- @param argv string[]
--- @param on_done fun(res: table)
--- @return boolean started
function M.run(argv, on_done)
    local function deliver(res)
        vim.schedule(function()
            pcall(on_done, res)
        end)
    end
    local ok, obj = pcall(vim.system, argv, { text = true }, deliver)
    if not ok then
        deliver({ code = -1, stdout = "", stderr = tostring(obj), argv = argv })
        return false
    end
    return obj ~= nil
end

--- Wait (bounded) for `<runtime>/daemon.json`.
--- @param timeout? integer milliseconds (default 10000)
--- @return table|nil info
function M.wait_for_daemon(timeout)
    local ok, Runtime = pcall(require, "pi.web.runtime")
    if not ok then
        return nil
    end
    local info = Runtime.read_daemon_json()
    if info then
        return info
    end
    vim.wait(timeout or M.START_TIMEOUT_MS, function()
        info = Runtime.read_daemon_json()
        return info ~= nil
    end, M.POLL_MS)
    return info
end

--- `true` when a daemon looks alive (it published `daemon.json`).
--- @return boolean
function M.daemon_running()
    local ok, Runtime = pcall(require, "pi.web.runtime")
    if not ok then
        return false
    end
    return Runtime.read_daemon_json() ~= nil
end

--- External base URL for `lan`/`tailscale` (never contains a token).
--- @param mode pi.web.AccessMode
--- @param info? table decoded `daemon.json`
--- @return string
function M.external_url(mode, info)
    info = info or {}
    local public = info.publicUrl
    if type(public) ~= "string" or public == "" then
        public = web_config().public_url
    end
    if type(public) == "string" and public ~= "" then
        return (public:gsub("/+$", ""))
    end
    local port = tonumber(info.port) or 7676
    if mode == "tailscale" then
        return ("http://127.0.0.1:%d (set web.public_url to your tailnet URL)"):format(port)
    end
    return ("http://127.0.0.1:%d (other devices: http://<this-host>:%d)"):format(port, port)
end

--- `:PiWeb`: the whole one-command flow.
function M.open_console()
    local ok, Access = pcall(require, "pi.web.access")
    if not ok then
        Notify.error("web console unavailable: " .. one_line(Access))
        return
    end
    if Access.pinned() == nil and Access.remembered() == nil then
        -- First run (or `web.access = "ask"` with nothing remembered): ask once,
        -- then remember so the next `:PiWeb` is a single keystroke.
        Access.choose(function(mode)
            if not mode then
                Notify.info("web console: no access mode chosen")
                return
            end
            M.launch(mode)
        end)
        return
    end
    M.launch(Access.get())
end

--- Run the console flow for one access mode.
--- @param mode pi.web.AccessMode
function M.launch(mode)
    local ok, Runtime = pcall(require, "pi.web.runtime")
    if not ok then
        Notify.error("web console unavailable: " .. one_line(Runtime))
        return
    end
    local resolved = Runtime.resolve_daemon()
    if not resolved then
        -- Never run npm behind the user's back: point at the explicit command.
        Notify.warn("pi2 daemon not found — run :PiWebInstall to install it")
        return
    end

    local Web = require("pi.web")
    local valid, start_err = Web.start_daemon()
    if not valid and start_err and start_err:find("auto_start", 1, true) then
        Notify.error("web console: " .. one_line(start_err) .. " — start it with `pi2 daemon`")
        return
    end
    pcall(Web.start)

    local info = M.wait_for_daemon(M.START_TIMEOUT_MS)
    if not info then
        local hint = start_err and (" (" .. one_line(start_err) .. ")") or ""
        Notify.error("web console: pi2 daemon did not start" .. hint .. " — run :PiWebDoctor")
        return
    end

    local port = tonumber(info.port)
    if mode ~= "local" then
        -- Non-loopback access never auto-signs-in: pair the other device instead.
        Notify.info(
            ("web console (%s): %s — run :PiWebPair to pair a device"):format(mode, M.external_url(mode, info))
        )
        return
    end

    if web_config().open == false then
        Notify.info(("web console ready at http://127.0.0.1:%s (web.open is off)"):format(tostring(port or "?")))
        return
    end

    local ok_login, Login = pcall(require, "pi.web.login")
    if not ok_login then
        Notify.error("web console: login unavailable: " .. one_line(Login))
        return
    end
    local url, open_err = Login.open()
    if not url then
        Notify.error("web console sign-in failed: " .. one_line(open_err))
        return
    end
    if open_err then
        Notify.warn("web console: could not open a browser (" .. one_line(open_err) .. ") — run `pi2 open`")
        return
    end
    Notify.info(("web console: opened http://127.0.0.1:%s in your browser"):format(tostring(port or "?")))
end

--- npm install of `@yuez/pi2d@latest`, then report the newly resolved source.
--- @param global boolean
--- @param kind "install"|"update"
function M.npm_install(global, kind)
    local cfg = web_config()
    local argv, target
    if global then
        argv = { "npm", "i", "-g", "@yuez/pi2d@latest" }
        target = "@yuez/pi2d@latest (global)"
    else
        target = M.install_dir(cfg)
        argv = { "npm", "i", "--prefix", target, "@yuez/pi2d@latest" }
    end
    Notify.info("web console: installing " .. target .. "…")
    M.run(argv, function(res)
        if tonumber(res.code) ~= 0 then
            Notify.error(
                "web console install failed: "
                    .. detail(res.stderr ~= "" and res.stderr or res.stdout, "npm exited " .. tostring(res.code))
            )
            return
        end
        local ok, Runtime = pcall(require, "pi.web.runtime")
        local resolved = ok and Runtime.resolve_daemon() or nil
        local source = resolved and (resolved.source .. " (" .. resolved.bin .. ")") or "not found"
        Notify.info(
            ("web console: %s %s — daemon source: %s"):format(
                kind == "update" and "updated" or "installed",
                target,
                source
            )
        )
        if kind == "update" then
            Notify.info("web console: restart the daemon to use the update (`pi2 daemon --force`)")
        end
    end)
end

--- `:PiWebInstall [--global]`
--- @param args? string[]
function M.install(args)
    local global = false
    for _, arg in ipairs(args or {}) do
        if arg == "--global" or arg == "-g" then
            global = true
        end
    end
    M.npm_install(global, "install")
end

--- `:PiWebUpdate [--global]`
--- @param args? string[]
function M.update(args)
    local global = false
    for _, arg in ipairs(args or {}) do
        if arg == "--global" or arg == "-g" then
            global = true
        end
    end
    M.npm_install(global, "update")
end

--- Render a `pi2 doctor --json` payload as `name status detail` lines.
--- Falls back to the plain-text report when the payload is not JSON.
--- @param stdout string
--- @return string[]
function M.render_doctor(stdout)
    local lines = {}
    local text = vim.trim(stdout or "")
    if text == "" then
        return lines
    end
    local ok, decoded = pcall(vim.json.decode, text)
    if ok and type(decoded) == "table" and type(decoded.checks) == "table" then
        for _, check in ipairs(decoded.checks) do
            if type(check) == "table" then
                lines[#lines + 1] = ("%s %s %s"):format(
                    tostring(check.name),
                    tostring(check.status),
                    one_line(check.detail)
                )
            end
        end
        return lines
    end
    for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
        if vim.trim(line) ~= "" then
            lines[#lines + 1] = vim.trim(line)
        end
    end
    return lines
end

--- `:PiWebDoctor`
function M.doctor()
    local ok, Runtime = pcall(require, "pi.web.runtime")
    if not ok then
        Notify.error("web console unavailable: " .. one_line(Runtime))
        return
    end
    local resolved = Runtime.resolve_daemon()
    if not resolved then
        Notify.warn("pi2 daemon not found — run :PiWebInstall to install it")
        return
    end
    M.run(M.cli_argv(resolved, "doctor", { "--json" }), function(res)
        local lines = M.render_doctor(res.stdout)
        if #lines == 0 then
            Notify.warn("web console doctor: no output — " .. detail(res.stderr, "exit " .. tostring(res.code)))
            return
        end
        local message = "web console doctor (" .. resolved.source .. ")\n" .. table.concat(lines, "\n")
        if tonumber(res.code) ~= 0 then
            Notify.warn(message)
        else
            Notify.info(message)
        end
    end)
end

--- Report the effective mode, plus the restart hint when a daemon is live.
--- @param mode pi.web.AccessMode
function M.report_access(mode)
    local message = ("web console access mode: %s"):format(tostring(mode))
    if M.daemon_running() then
        message = message .. " — restart the running daemon to apply it (`pi2 daemon --force`)"
    end
    Notify.info(message)
end

--- `:PiWebAccess [mode]`
--- @param args? string[]
function M.access(args)
    local ok, Access = pcall(require, "pi.web.access")
    if not ok then
        Notify.error("web console unavailable: " .. one_line(Access))
        return
    end
    local mode = vim.trim(table.concat(args or {}, " "))
    if mode == "" then
        Access.choose(function(chosen)
            if not chosen then
                Notify.info("web console: access mode unchanged")
                return
            end
            M.report_access(chosen)
        end)
        return
    end
    if not Access.is_mode(mode) then
        Notify.error("web console: access mode must be local, lan or tailscale")
        return
    end
    local saved, err = Access.set(mode)
    if not saved then
        Notify.error("web console: cannot save the access mode: " .. one_line(err))
        return
    end
    M.report_access(saved)
end

--- External base URL the daemon advertises, when known.
--- @param info? table decoded `daemon.json`
--- @return string|nil
function M.public_url(info)
    local public = info and info.publicUrl
    if type(public) ~= "string" or public == "" then
        public = web_config().public_url
    end
    if type(public) ~= "string" or public == "" then
        return nil
    end
    return (public:gsub("/+$", ""))
end

--- Render the `pi2 pairing` output (URL + code) into one line.
--- @param stdout string
--- @return string
function M.render_pairing(stdout)
    local text = stdout or ""
    local url = text:match("url%s+(%S+)")
    local code = text:match("code%s+(%S+)")
    if url and code then
        return ("web console: pair a device at %s (code %s)"):format(url, code)
    end
    if url then
        return ("web console: pair a device at %s"):format(url)
    end
    local fallback = one_line(text)
    if fallback == "" then
        return "web console: pairing returned no code"
    end
    return "web console: " .. fallback
end

--- `:PiWebPair`
function M.pair()
    local ok, Runtime = pcall(require, "pi.web.runtime")
    if not ok then
        Notify.error("web console unavailable: " .. one_line(Runtime))
        return
    end
    local resolved = Runtime.resolve_daemon()
    if not resolved then
        Notify.warn("pi2 daemon not found — run :PiWebInstall to install it")
        return
    end
    if not Runtime.read_daemon_json() then
        Notify.warn("web console: no running pi2 daemon — run :PiWeb first")
        return
    end
    local extra = {}
    local public = M.public_url(Runtime.read_daemon_json())
    if public then
        extra = { "--public-url", public }
    end
    M.run(M.cli_argv(resolved, "pairing", extra), function(res)
        if tonumber(res.code) ~= 0 then
            Notify.error(
                "web console pairing failed: "
                    .. detail(res.stderr ~= "" and res.stderr or res.stdout, "exit " .. tostring(res.code))
            )
            return
        end
        Notify.info(M.render_pairing(res.stdout or ""))
    end)
end

--- Run one command implementation, degrading to a one-line notify instead of
--- letting an error escape into the user's face.
--- @param name string
--- @param ... any
--- @return boolean ok
function M.call(name, ...)
    local fn = M[name]
    if type(fn) ~= "function" then
        Notify.error("web console: " .. tostring(name) .. " is unavailable")
        return false
    end
    local packed = { pcall(fn, ...) }
    if not packed[1] then
        Notify.error("web console: " .. one_line(packed[2]))
        return false
    end
    return true
end

return M
