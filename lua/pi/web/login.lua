-- Local-browser login handshake (`POST /api/v1/console/session`).
--
-- `:PiWeb` in `local` access mode must land in an *already signed in* browser:
-- the daemon mints (rotates) the local-browser device token and returns a
-- `#t=<token>` handoff URL. The credentials for that call live next to the
-- daemon: `<runtime>/daemon.json` (actual bound port) and `<runtime>/cli.token`
-- (local admin token, 0600).
--
-- The token never appears in argv (world-readable through `ps`): curl reads the
-- Authorization header from stdin (`-H @-`). It is never printed or logged
-- either — the returned URL contains it by design and is only handed to the
-- opener (and to callers for `--print`-style display).
--
-- The HTTP round-trip is a bounded `vim.system` call (`text = true`, 5 s
-- timeout), so the editor is never blocked indefinitely.

local M = {}

local Runtime = require("pi.web.runtime")

local uv = vim.uv or vim.loop

--- Default round-trip budget for the console-session request.
M.TIMEOUT_MS = 5000
--- Bodies in error messages are flattened and truncated to this many chars.
M.BODY_LIMIT = 200

---@class pi.web.LoginOpts
---@field runtime_dir? string read `daemon.json`/`cli.token` from here (tests)
---@field timeout? integer milliseconds to wait for the request (default 5000)
---@field system? fun(cmd: string[], opts: table, on_exit: fun(res: table)): any injectable `vim.system`
---@field opener? fun(url: string): boolean, string|nil injectable opener
---@field config? pi.WebConfig defaults to `pi.config`

--- Flatten to a single trimmed line of at most `BODY_LIMIT` chars.
--- @param text any
--- @return string
local function one_line(text)
    local line = tostring(text or ""):gsub("%s+", " ")
    line = vim.trim(line)
    if #line > M.BODY_LIMIT then
        line = line:sub(1, M.BODY_LIMIT) .. "…"
    end
    return line
end

--- @param dir? string
--- @return integer|nil port, string|nil err
local function daemon_port(dir)
    local path = Runtime.daemon_json_path(dir)
    local raw = Runtime.read_text(path)
    if not raw then
        return nil, "no running pi2 daemon (" .. path .. " missing)"
    end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return nil, "malformed " .. path
    end
    local port = tonumber(decoded.port)
    if not port or port <= 0 then
        return nil, path .. " has no port"
    end
    return math.floor(port), nil
end

--- POST the console-session request. Returns the HTTP status and body.
--- @param port integer
--- @param token string
--- @param opts pi.web.LoginOpts
--- @return integer|nil status, string body, string|nil err
local function post_session(port, token, opts)
    local system = opts.system or vim.system
    local timeout = opts.timeout or M.TIMEOUT_MS
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
        "{}",
        "-w",
        "\n%{http_code}",
        ("http://127.0.0.1:%d/api/v1/console/session"):format(port),
    }
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
        return nil, "", "cannot run curl: " .. one_line(err)
    end
    if not done then
        vim.wait(timeout, function()
            return done
        end, 20)
    end
    if not done or type(result) ~= "table" then
        return nil, "", ("console session request timed out after %d ms"):format(timeout)
    end
    if tonumber(result.code) ~= 0 then
        local detail = result.stderr
        if type(detail) ~= "string" or vim.trim(detail) == "" then
            detail = "exit " .. tostring(result.code)
        end
        return nil, "", "curl failed: " .. one_line(detail)
    end
    local stdout = type(result.stdout) == "string" and result.stdout or ""
    local body, status = stdout:match("^(.-)\n(%d%d%d)%s*$")
    if not status then
        return nil, stdout, "unexpected response from the daemon"
    end
    return tonumber(status), body or "", nil
end

--- @param opts? pi.web.LoginOpts
--- @return pi.web.LoginOpts
local function normalize(opts)
    opts = opts or {}
    local normalized = {
        runtime_dir = opts.runtime_dir,
        timeout = opts.timeout,
        system = opts.system,
        opener = opts.opener,
        config = opts.config,
    }
    if not normalized.config then
        local ok, config = pcall(require, "pi.config")
        normalized.config = (ok and config.options.web) or {}
    end
    return normalized
end

--- Request a signed-in console URL from the local daemon.
--- @param opts? pi.web.LoginOpts
--- @return string|nil url, string|nil err
function M.url(opts)
    local o = normalize(opts)
    local port, port_err = daemon_port(o.runtime_dir)
    if not port then
        return nil, port_err
    end
    local token_path = Runtime.cli_token_path(o.runtime_dir)
    local token = Runtime.read_text(token_path)
    if not token then
        return nil, "missing " .. token_path
    end
    local status, body, err = post_session(port, token, o)
    if not status then
        return nil, err
    end
    if status ~= 200 then
        return nil, ("%s %s"):format(tostring(status), one_line(body))
    end
    local ok, decoded = pcall(vim.json.decode, body or "")
    if not ok or type(decoded) ~= "table" then
        return nil, "console session response is not JSON"
    end
    local url = decoded.url
    if type(url) ~= "string" or url == "" then
        return nil, "console session response has no url"
    end
    return url, nil
end

--- Start a detached process; returns false + reason when the spawn fails.
--- @param argv string[]
--- @param opts pi.web.LoginOpts
--- @return boolean ok, string|nil err
function M.spawn(argv, opts)
    local system = opts.system or vim.system
    local ok, obj = pcall(system, argv, { detach = true })
    if not ok then
        return false, one_line(obj)
    end
    if obj == nil then
        return false, "opener not found: " .. tostring(argv[1])
    end
    return true, nil
end

--- Hand `url` to the platform opener without ever waiting for it.
--- `web.browser` overrides the command; `vim.ui.open` is preferred when present.
--- @param url string
--- @param opts? pi.web.LoginOpts
--- @return boolean ok, string|nil err
function M.open_url(url, opts)
    local o = normalize(opts)
    if o.opener then
        return o.opener(url)
    end
    local browser = o.config and o.config.browser
    if type(browser) == "string" and browser ~= "" then
        return M.spawn({ browser, url }, o)
    end
    if type(vim.ui.open) == "function" then
        local ok, obj, open_err = pcall(vim.ui.open, url)
        if ok and obj ~= nil then
            return true, nil
        end
        -- `nil, nil` means "no handler"; a real error is reported to the caller.
        if ok and type(open_err) == "string" and open_err ~= "" then
            return false, one_line(open_err)
        end
    end
    if (uv.os_uname().sysname or "") == "Darwin" then
        return M.spawn({ "open", url }, o)
    end
    return M.spawn({ "xdg-open", url }, o)
end

--- Sign in and open the browser. Callers must only use this for
--- `access == "local"` (non-loopback modes pair instead of auto-signing-in).
--- @param opts? pi.web.LoginOpts
--- @return string|nil url, string|nil err
function M.open(opts)
    local url, err = M.url(opts)
    if not url then
        return nil, err
    end
    local ok, open_err = M.open_url(url, opts)
    if not ok then
        return url, open_err
    end
    return url, nil
end

return M
