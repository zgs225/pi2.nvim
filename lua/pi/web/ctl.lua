-- `:PiWeb*` command implementations (the user-facing control surface).
--
-- This module is the only place that shells out for the console workflows:
-- install/update (npm), doctor, pairing + the QR view and the one-command
-- `:PiWeb` flow (resolve daemon → start the bridge → wait for
-- `<runtime>/daemon.json` → sign in a local browser) and the `:PiWebPair`
-- QR view.
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

--- `:PiWeb`: the whole one-command flow.
function M.open_console()
    M.launch()
end

--- Resolve the daemon binary, spawn it when nothing publishes `daemon.json`, and
--- wait (bounded) for it. Notifies the reason and returns `nil` on failure.
--- @return table|nil info decoded `daemon.json`
function M.ensure_running()
    local ok, Runtime = pcall(require, "pi.web.runtime")
    if not ok then
        Notify.error("web console unavailable: " .. one_line(Runtime))
        return nil
    end
    if not Runtime.resolve_daemon() then
        -- Never run npm behind the user's back: point at the explicit command.
        Notify.warn("pi2 daemon not found — run :PiWebInstall to install it")
        return nil
    end
    local info = Runtime.read_daemon_json()
    if info then
        return info
    end

    local Web = require("pi.web")
    local valid, start_err = Web.start_daemon()
    if not valid and start_err and start_err:find("auto_start", 1, true) then
        Notify.error("web console: " .. one_line(start_err) .. " — start it with `pi2 daemon`")
        return nil
    end
    pcall(Web.start)

    info = M.wait_for_daemon(M.START_TIMEOUT_MS)
    if not info then
        local hint = start_err and (" (" .. one_line(start_err) .. ")") or ""
        Notify.error("web console: pi2 daemon did not start" .. hint .. " — run :PiWebDoctor")
        return nil
    end
    return info
end

--- `:PiWeb`'s second half: sign a local browser in once the daemon is up.
function M.launch()
    local info = M.ensure_running()
    if not info then
        return
    end

    local port = tonumber(info.port)
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

--- External base URL the daemon advertises, when known.
--- @param info? table decoded `daemon.json`
--- @return string|nil
--- One-line summary of a pairing report, for hosts with no UI to draw in.
--- @param report { url: string, code: string }
--- @return string
function M.pairing_line(report)
    return ("web console: pair a device at %s (code %s)"):format(report.url, report.code)
end

--- Normalise a pairing mint response into a render-ready report.
---
--- `payload` is either the decoded `POST /api/v1/pair` body or its JSON text.
--- Returns `nil` for anything unusable (no URL/code, a matrix with a non-`1`/`0`
--- character, a mis-sized grid), so callers fail with one message instead of
--- drawing garbage.
--- @param payload table|string|nil
--- @return { url: string, code: string, expires_at: number|nil, version: number|nil, size: integer, rows: string[], bases: table[] }|nil
function M.pairing_report(payload)
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
    local url, code = decoded.url, decoded.code
    if type(url) ~= "string" or url == "" or type(code) ~= "string" or code == "" then
        return nil
    end
    local qr = decoded.qr
    if type(qr) ~= "table" or type(qr.rows) ~= "table" then
        return nil
    end
    local size = tonumber(qr.size)
    local rows = {}
    for _, row in ipairs(qr.rows) do
        if type(row) ~= "string" or row == "" or row:find("[^01]") then
            return nil
        end
        if size and #row ~= size then
            return nil
        end
        rows[#rows + 1] = row
    end
    if #rows == 0 then
        return nil
    end
    size = size or #rows
    if #rows ~= size then
        return nil
    end
    return {
        url = url,
        code = code,
        expires_at = tonumber(decoded.expiresAt),
        version = tonumber(qr.version),
        size = size,
        rows = rows,
        --- Every address a phone could use, as reported by the mint response.
        bases = type(decoded.bases) == "table" and decoded.bases or {},
    }
end

--- HTTP budget for the mint round-trip; the daemon answers immediately.
M.MINT_TIMEOUT_MS = 5000

--- POST `/api/v1/pair` and hand back a render-ready report.
---
--- The daemon owns the URL, the QR matrix and the base list (ADR 0001): this
--- module only asks for them, so the symbol and the link always agree. The CLI
--- token travels through curl's stdin config, so it never appears in `ps`.
---
--- @param base string|nil pin the link to one of the advertised bases
--- @param on_done fun(report: table|nil, err: string|nil)
--- @param opts? { port?: integer, token?: string, system?: fun(argv: string[], opts: table, on_exit: fun(res: table)): any, timeout?: integer }
function M.mint_pair(base, on_done, opts)
    opts = opts or {}
    local ok_runtime, Runtime = pcall(require, "pi.web.runtime")
    if not ok_runtime then
        on_done(nil, "web console unavailable: " .. one_line(Runtime))
        return
    end
    local daemon = Runtime.read_daemon_json() or {}
    local port = tonumber(opts.port) or tonumber(daemon.port)
    if not port or port <= 0 then
        on_done(nil, "no daemon port — is `pi2 daemon` running?")
        return
    end
    local token = opts.token or Runtime.read_text(Runtime.cli_token_path())
    if type(token) ~= "string" or token == "" then
        on_done(nil, "no CLI token in the runtime dir — restart `pi2 daemon`")
        return
    end

    local body = "{}"
    if type(base) == "string" and base ~= "" then
        body = vim.json.encode({ base = base })
    end
    local argv = {
        "curl",
        "-sS",
        "-X",
        "POST",
        "-H",
        "@-",
        "-H",
        "Content-Type: application/json",
        "--data",
        body,
        "-w",
        "\n%{http_code}",
        ("http://127.0.0.1:%d/api/v1/pair"):format(port),
    }

    local system = opts.system or vim.system
    local timeout = opts.timeout or M.MINT_TIMEOUT_MS
    local done = false
    --- @type table|nil
    local result = nil
    local ok, err = pcall(
        system,
        argv,
        { text = true, stdin = "Authorization: Bearer " .. token .. "\n" },
        function(res)
            result = res
            done = true
        end
    )
    if not ok then
        on_done(nil, "cannot run curl: " .. one_line(err))
        return
    end
    if not done then
        vim.wait(timeout, function()
            return done
        end, 20)
    end
    if not done or type(result) ~= "table" then
        on_done(nil, ("pairing mint timed out after %d ms"):format(timeout))
        return
    end
    if tonumber(result.code) ~= 0 then
        local detail = type(result.stderr) == "string" and vim.trim(result.stderr) or ""
        on_done(nil, "curl failed: " .. (detail ~= "" and one_line(detail) or ("exit " .. tostring(result.code))))
        return
    end

    local stdout = type(result.stdout) == "string" and result.stdout or ""
    local raw, status = stdout:match("^(.-)\n(%d%d%d)%s*$")
    if not status then
        on_done(nil, "unexpected response from the daemon")
        return
    end
    local status_code = tonumber(status)
    if status_code ~= 200 then
        local ok_decode, payload = pcall(vim.json.decode, raw or "")
        local reason = ok_decode and type(payload) == "table"
                and tostring(payload.message or payload.code or "")
            or ""
        on_done(
            nil,
            ("pairing mint refused: HTTP %d%s"):format(status_code, reason ~= "" and (" — " .. reason) or "")
        )
        return
    end
    local ok_decode, payload = pcall(vim.json.decode, raw or "")
    if not ok_decode or type(payload) ~= "table" then
        on_done(nil, "pairing mint returned unreadable JSON")
        return
    end
    local report = M.pairing_report(payload)
    if not report then
        on_done(nil, "pairing mint returned no usable QR payload")
        return
    end
    on_done(report, nil)
end

--- Base URL of a pairing link (`…/pair/<CODE>` → `…`).
--- @param url string
--- @return string
function M.pairing_base(url)
    return (tostring(url or ""):gsub("/pair/[^/]+$", ""))
end

--- Short picker label for one `bases[]` entry of the mint response.
--- @param base table
--- @return string
function M.base_label(base)
    local kind = ({ public = "public", lan = "LAN", other = "routed", tailscale = "tailscale" })[base.kind] or "?"
    if base.kind == "public" then
        return ("public URL  %s"):format(tostring(base.url))
    end
    return ("%-10s %-16s %-9s %s"):format(
        tostring(base.name or "?"),
        tostring(base.address or "?"),
        kind,
        tostring(base.url or "?")
    )
end

--- Ask which address a phone should use. Exactly one usable base skips the menu.
--- @param bases table[]|nil
--- @param on_choice fun(base: table|nil) `nil` when the user cancels
function M.choose_base(bases, on_choice)
    local usable = {}
    for _, base in ipairs(bases or {}) do
        if type(base) == "table" and type(base.url) == "string" and base.url ~= "" then
            usable[#usable + 1] = base
        end
    end
    if #usable <= 1 then
        on_choice(usable[1])
        return
    end
    vim.ui.select(usable, {
        prompt = "π │ web console: which address should a phone use?",
        format_item = M.base_label,
    }, function(choice)
        on_choice(choice)
    end)
end

--- Split a base URL into the host/port a TCP probe should dial.
--- @param url string|nil
--- @return string|nil host, integer|nil port
function M.probe_target(url)
    local scheme, rest = tostring(url or ""):match("^(%a[%w+.-]*)://(.+)$")
    if not scheme then
        return nil, nil
    end
    rest = rest:gsub("/.*$", "")
    local host, port = rest:match("^(%[[^%]]+%]):(%d+)$")
    if not host then
        host, port = rest:match("^([^:]+):(%d+)$")
    end
    if not host then
        host = rest
        port = scheme == "https" and 443 or 80
    end
    return host, tonumber(port)
end

--- `true` when something listens on that address — which is exactly what a
--- phone would find. Unprobeable URLs are treated as reachable (fail open).
--- @param url string
--- @param on_done fun(ok: boolean, detail: string)
--- @param timeout? integer milliseconds
function M.reachable(url, on_done, timeout)
    local host, port = M.probe_target(url)
    local uv = vim.uv or vim.loop
    local tcp = host ~= nil and port ~= nil and uv.new_tcp() or nil
    if not tcp then
        on_done(true, "not probed")
        return
    end
    local finished = false
    local timer = uv.new_timer()
    local function finish(ok, detail)
        if finished then
            return
        end
        finished = true
        if timer then
            pcall(function()
                timer:stop()
                timer:close()
            end)
        end
        pcall(function()
            tcp:close()
        end)
        vim.schedule(function()
            on_done(ok, detail)
        end)
    end
    timer:start(timeout or 2000, 0, function()
        finish(false, "timed out")
    end)
    tcp:connect(host, port, function(err)
        if err ~= nil then
            finish(false, tostring(err))
        else
            finish(true, "connected")
        end
    end)
end

--- Draw a pairing report: refuse loopback, probe the address, then float or text.
--- @param report { url: string, code: string, rows: string[], expires_at?: number }
function M.show_pairing(report)
    local base = M.pairing_base(report.url)
    local host = M.probe_target(base)
    if type(host) == "string" and (host == "localhost" or host == "[::1]" or host:match("^127%.") ~= nil) then
        Notify.warn(
            (
                "web console: %s only works on this machine — the daemon only listens on 127.0.0.1; "
                .. 'set `web.host = "0.0.0.0"` (or PI2_HOST) and restart it'
            ):format(report.url)
        )
        return
    end
    M.reachable(base, function(ok, reason)
        if not ok then
            Notify.warn(
                ("web console: %s is not reachable (%s) — check `web.host`/PI2_HOST and the firewall"):format(
                    base,
                    reason
                )
            )
            return
        end
        local ok_qr, Qr = pcall(require, "pi.web.qr")
        if not ok_qr or #vim.api.nvim_list_uis() == 0 then
            Notify.info(M.pairing_line(report))
            return
        end
        local shown = pcall(Qr.open, {
            rows = report.rows,
            url = report.url,
            code = report.code,
            expires_at = report.expires_at,
            refresh = M.pair,
        })
        if not shown then
            Notify.info(M.pairing_line(report))
        end
    end)
end

--- `:PiWebPair`: pick the address a phone should use, mint a code for it, draw
--- the QR code (or one notify line when there is no UI to draw in).
---
--- Guessing the address is what produced unscannable `127.0.0.1` links, so the
--- command asks: the mint response carries every base (interface name + IPv4 +
--- URL) and the picker shows them. The chosen base is then probed with a TCP
--- connect before anything is drawn — a code nobody can reach is a bug, not a
--- fallback.
---
--- `opts` is forwarded to `mint_pair`, which is where tests inject `system`/
--- `port`/`token`; production passes nothing.
--- @param opts? table
function M.pair(opts)
    local info = M.ensure_running()
    if not info then
        return
    end

    local function mint(base, on_report)
        M.mint_pair(base, function(report, err)
            if not report then
                Notify.error("web console pairing failed: " .. tostring(err))
                return
            end
            on_report(report)
        end, opts)
    end

    mint(nil, function(report)
        local default_base = M.pairing_base(report.url)
        M.choose_base(report.bases, function(chosen)
            if chosen == nil then
                if #(report.bases or {}) == 0 then
                    -- A host with no usable interface: fall back to the base the
                    -- daemon picked (show_pairing refuses loopback explicitly).
                    M.show_pairing(report)
                    return
                end
                Notify.info("web console: pairing cancelled")
                return
            end
            if chosen.url == default_base then
                M.show_pairing(report)
                return
            end
            -- A different address needs a code minted on that base; the first
            -- code simply expires unused.
            mint(chosen.url, function(rerun)
                M.show_pairing(rerun)
            end)
        end)
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
