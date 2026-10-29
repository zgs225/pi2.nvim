-- Local-browser login handshake for `:PiWeb`.
--
-- The daemon mints (rotates) the local-browser device token and returns a
-- `#t=<token>` handoff URL over `POST /api/v1/console/session`. That exchange is
-- already owned by the CLI — `pi2 open --print` reads `<runtime>/daemon.json`
-- and `<runtime>/cli.token`, keeps the token out of argv and prints exactly the
-- signed-in URL — so the plugin runs it instead of re-implementing the HTTP
-- call. One code path, and no `curl` dependency for the editor.
--
-- The URL contains the token by design; it is only handed to the opener (and to
-- callers for `--print`-style display), never logged.
--
-- The round-trip is a bounded `vim.system` call (`text = true`, 5 s), so the
-- editor is never blocked indefinitely.

local M = {}

local Runtime = require("pi.web.runtime")

--- Default budget for `pi2 open --print`.
M.TIMEOUT_MS = 5000
--- Error details are flattened and truncated to this many chars.
M.BODY_LIMIT = 200

---@class pi.web.LoginOpts
---@field timeout? integer milliseconds to wait for the CLI (default 5000)
---@field system? fun(cmd: string[], opts: table, on_exit: fun(res: table)): any injectable `vim.system`
---@field opener? fun(url: string): boolean, string|nil injectable opener
---@field config? pi.WebConfig defaults to `pi.config`
---@field resolve? fun(): pi.web.DaemonCandidate|nil injectable daemon resolution (tests)

--- Flatten to a single trimmed line of at most `M.BODY_LIMIT` chars.
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

--- First non-empty line of a block of text, flattened.
--- @param text any
--- @return string
local function first_line(text)
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local trimmed = vim.trim(line)
        if trimmed ~= "" then
            return one_line(trimmed)
        end
    end
    return ""
end

--- @param opts? pi.web.LoginOpts
--- @return pi.web.LoginOpts
local function normalize(opts)
    opts = opts or {}
    local normalized = {
        timeout = opts.timeout,
        system = opts.system,
        opener = opts.opener,
        config = opts.config,
        resolve = opts.resolve,
    }
    if not normalized.config then
        local ok, config = pcall(require, "pi.config")
        normalized.config = (ok and config.options.web) or {}
    end
    return normalized
end

--- Request a signed-in console URL through `pi2 open --print`.
--- @param opts? pi.web.LoginOpts
--- @return string|nil url, string|nil err
function M.url(opts)
    local o = normalize(opts)
    local resolved
    if type(o.resolve) == "function" then
        local ok, value = pcall(o.resolve)
        resolved = ok and value or nil
    else
        local ok, value = pcall(Runtime.resolve_daemon)
        resolved = ok and value or nil
    end
    if not resolved then
        return nil,
            "pi2 not found — install the CLI (`npm i -g @yuez/pi2d`, the curl installer or brew) or run :PiWebInstall"
    end

    local argv = { resolved.bin, "open", "--print" }
    local system = o.system or vim.system
    local timeout = o.timeout or M.TIMEOUT_MS
    local done, result = false, nil
    local ok, err = pcall(system, argv, { text = true }, function(res)
        result = res
        done = true
    end)
    if not ok then
        return nil, "cannot run `" .. table.concat(argv, " ") .. "`: " .. one_line(err)
    end
    if not done then
        vim.wait(timeout, function()
            return done
        end, 20)
    end
    if not done or type(result) ~= "table" then
        return nil, ("`pi2 open --print` timed out after %d ms"):format(timeout)
    end
    if tonumber(result.code) ~= 0 then
        local detail = first_line(result.stderr)
        if detail == "" then
            detail = first_line(result.stdout)
        end
        if detail == "" then
            detail = "exit " .. tostring(result.code)
        end
        return nil, "pi2 open failed: " .. detail
    end

    -- `pi2 open --print` prints the URL on one line; take the last URL-shaped
    -- line so a stray warning on stdout cannot become the handoff target.
    local url
    for line in tostring(result.stdout or ""):gmatch("[^\r\n]+") do
        local trimmed = vim.trim(line)
        if trimmed:match("^https?://%S+$") then
            url = trimmed
        end
    end
    if not url then
        return nil, "`pi2 open --print` printed no URL"
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
    if ((vim.uv or vim.loop).os_uname().sysname or "") == "Darwin" then
        return M.spawn({ "open", url }, o)
    end
    return M.spawn({ "xdg-open", url }, o)
end

--- Sign in and open the browser. This is the loopback handshake: the daemon
--- only accepts it from this machine, so other devices pair via `:PiWebPair`
--- instead of being signed in.
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
