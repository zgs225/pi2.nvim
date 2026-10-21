-- Headless host entry point used by `pi2d`.
--
-- `pi2d` spawns one Neovim per workspace as
--
--   nvim --headless --listen <runtime>/i/<hash>.sock -u <init> -c 'lua require("pi.host").start()'
--
-- with `PI2_RUNTIME_DIR`, `PI2_DAEMON_SOCKET`, `PI2_DAEMON_TOKEN_PATH` and
-- `PI2_WORKSPACE_ID` in the environment. This module adopts that context,
-- boots the plugin + web bridge, and keeps the (headless) process alive until
-- the daemon sends `instance.shutdown` (see `pi.web.shutdown`).
--
-- Rules:
--   * never print to stdout (`--headless` shares it with nothing useful, and
--     the daemon captures nothing anyway — diagnostics go to `web.log`);
--   * never spawn a second daemon: the daemon that spawned this process owns
--     the socket, so `pi.web.start_daemon()` sees it and backs off;
--   * keep the event loop running with `vim.wait`, not a busy loop.

local M = {}

--- @type boolean
M._stopping = false
--- @type boolean
M._started = false

--- @param name string
--- @return string|nil
local function env(name)
    local value = vim.env[name]
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

--- @return string|nil
local function log_path()
    local ok, web = pcall(function()
        return require("pi.config").options.web
    end)
    if not ok or type(web) ~= "table" then
        return nil
    end
    local value = web.log
    if type(value) == "string" then
        return value
    end
    return nil
end

--- Best-effort diagnostic file, since stdout/stderr are not available.
--- @param level string
--- @param msg string
local function log(level, msg)
    local path = log_path()
    if not path then
        return
    end
    local uv = vim.uv or vim.loop
    local fd = uv.fs_open(path, "a", 384)
    if not fd then
        return
    end
    pcall(uv.fs_write, fd, os.date("%Y-%m-%dT%H:%M:%S ") .. level .. " " .. tostring(msg) .. "\n", -1)
    pcall(uv.fs_close, fd)
end

--- Ask `M.start` to return (the daemon is shutting this instance down). The
--- caller (`pi.web.shutdown`) then quits the process after a short drain.
--- @return boolean
function M.stop()
    M._stopping = true
    return true
end

--- Adopt the daemon's environment without clobbering explicit overrides.
function M.adopt_env()
    local daemon_socket = env("PI2_DAEMON_SOCKET")
    if daemon_socket and not env("PI2_SOCKET") then
        -- `pi.web.runtime` resolves the daemon socket (and the token next to
        -- it) from PI2_SOCKET; the daemon passes its own path separately.
        vim.env.PI2_SOCKET = daemon_socket
    end
end

--- Boot the plugin + web bridge and keep the process alive.
--- @param workspace string|nil Workspace cwd (defaults to $PI2_WORKSPACE or cwd)
--- @param opts? { setup?: pi.Options, on_ready?: fun(), timeout_ms?: integer, interval_ms?: integer }
--- @return boolean
function M.start(workspace, opts)
    opts = opts or {}
    if M._started then
        return true
    end
    M._started = true
    M._stopping = false

    M.adopt_env()

    local cwd = workspace or env("PI2_WORKSPACE") or vim.fn.getcwd()
    if type(cwd) == "string" and vim.fn.isdirectory(cwd) == 1 then
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(cwd))
    end

    -- `--listen` already started the server; a bare `-l` host still advertises
    -- a connectable address so `nvim --server <addr> --remote-ui` can attach.
    if vim.v.servername == "" then
        pcall(vim.fn.serverstart)
    end

    local ok_setup, setup_err = pcall(function()
        if not package.loaded["pi.commands"] then
            require("pi").setup(opts.setup or {})
        end
        local Config = require("pi.config")
        Config.options.web = vim.tbl_deep_extend("force", Config.options.web or {}, { enabled = true })
    end)
    if not ok_setup then
        log("error", "plugin setup failed: " .. tostring(setup_err))
    end

    local Web = require("pi.web")
    Web.set_host(true)
    local ok_start, start_err = pcall(Web.start)
    if not ok_start then
        log("error", "web start failed: " .. tostring(start_err))
    end

    if opts.on_ready then
        pcall(opts.on_ready)
    end

    if opts.timeout_ms and opts.timeout_ms >= 0 then
        vim.wait(opts.timeout_ms, function()
            return M._stopping
        end, opts.interval_ms or 200)
    else
        -- `vim.wait(-1, …)` is invalid: process events in bounded slices and
        -- keep looping until the daemon asks us to stop.
        while not M._stopping do
            vim.wait(opts.interval_ms or 200, function()
                return M._stopping
            end, 50)
        end
    end

    M._started = false
    return true
end

--- Test hook: drop one-shot state so a spec can boot twice in one process.
function M._reset()
    M._stopping = false
    M._started = false
end

return M
