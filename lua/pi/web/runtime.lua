---@class pi.web.Runtime
--- Platform paths and daemon resolution shared with `pi2d`
--- (`pi2d/src/core/paths.ts`).
---
--- The plugin and the daemon must agree on where the daemon socket, its token
--- file, the per-instance sockets and the daemon log live, otherwise the bridge
--- either cannot dial or the daemon refuses the handshake. This module is the
--- single source of truth for those paths, and it owns the ladder that finds the
--- `pi2` executable (`resolve_daemon`). There is no `npx` path (pi2d ADR 0002):
--- a missing executable is reported, never bootstrapped.
---
--- Every function here is **main-loop only** (it may touch `vim.env`, `vim.fs`
--- and `vim.fn`), never call it from a `vim.uv` callback.
local M = {}

--- Read one entry from an injected environment table, treating a missing value,
--- a non-string and `""` as unset.
--- @param source table<string, string|nil>|nil
--- @param name string
--- @return string|nil
local function env_value(source, name)
    if type(source) ~= "table" then
        return nil
    end
    local value = source[name]
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return value
end

--- Read an environment override, treating "" as unset.
--- @param name string
--- @return string|nil
local function env(name)
    return env_value(vim.env, name)
end

--- @return boolean
function M.is_mac()
    return (vim.uv or vim.loop).os_uname().sysname == "Darwin"
end

--- @return string
local function home()
    return vim.fn.expand("~")
end

--- @return string
local function uid()
    local uv = vim.uv or vim.loop
    if type(uv.getuid) == "function" then
        local ok, id = pcall(uv.getuid)
        if ok and id then
            return tostring(id)
        end
    end
    return "0"
end

--- Join path segments without normalizing (keeps trailing-slash semantics).
--- @vararg string
--- @return string
local function join(...)
    return vim.fs.joinpath(...)
end

--- Directory holding the daemon socket and token: `$PI2_RUNTIME_DIR` when set,
--- otherwise the platform runtime dir (`$XDG_RUNTIME_DIR/pi2` on Linux,
--- `~/Library/Caches/pi2/run` on macOS).
--- @return string
function M.runtime_dir()
    local override = env("PI2_RUNTIME_DIR")
    if override then
        return override
    end
    if M.is_mac() then
        return join(home(), "Library", "Caches", "pi2", "run")
    end
    local base = env("XDG_RUNTIME_DIR")
    if not base then
        local uv = vim.uv or vim.loop
        local tmp = uv.os_tmpdir() or "/tmp"
        base = join(tmp, "pi2-" .. uid())
    end
    return join(base, "pi2")
end

--- Path of the daemon's unix socket. `$PI2_SOCKET` overrides the location
--- (and thereby the token path) for tests and non-standard installs.
--- @return string
function M.socket_path()
    local override = env("PI2_SOCKET")
    if override then
        return override
    end
    return join(M.runtime_dir(), "d.sock")
end

--- Path of the daemon's handshake token file (`d.sock.token` next to the socket).
--- @return string
function M.token_path()
    return M.socket_path() .. ".token"
end

--- Alias for `token_path()` (the token file, not its contents).
--- @return string
function M.token()
    return M.token_path()
end

--- Read and trim the daemon token. Returns nil when the file is missing,
--- unreadable or empty (the bridge then connects without a token and lets the
--- daemon decide).
--- @return string|nil
function M.read_token()
    local uv = vim.uv or vim.loop
    local path = M.token_path()
    local fd = uv.fs_open(path, "r", 438) -- 0666 & ~umask
    if not fd then
        return nil
    end
    local ok, stat = pcall(uv.fs_fstat, fd)
    local data
    if ok and stat then
        local read_ok, content = pcall(uv.fs_read, fd, stat.size, 0)
        if read_ok then
            data = content
        end
    end
    pcall(uv.fs_close, fd)
    if type(data) ~= "string" then
        return nil
    end
    local token = vim.trim(data)
    if token == "" then
        return nil
    end
    return token
end

--- Directory for daemon-owned persistent data (registry, logs).
--- @return string
function M.data_dir()
    local override = env("PI2_DATA_DIR")
    if override then
        return override
    end
    if M.is_mac() then
        return join(home(), "Library", "Application Support", "pi2")
    end
    local base = env("XDG_DATA_HOME")
    if not base then
        base = join(home(), ".local", "share")
    end
    return join(base, "pi2")
end

--- Directory for daemon-owned state: logs and generated host inits. Mirrors
--- `stateDir()` in `pi2d/src/core/paths.ts`: `$PI2_STATE_DIR` →
--- `~/Library/Logs/pi2` (macOS) → `$XDG_STATE_HOME/pi2` → `~/.local/state/pi2`.
---
--- This is the daemon-log directory: `pi2 daemon` appends `daemon.log` here (and
--- `instances/<instanceId>.log` per managed Neovim), which is what `:PiWebLog`
--- and `:checkhealth pi` point at. Resolution only — nothing is created here.
--- @return string
function M.state_dir()
    local override = env("PI2_STATE_DIR")
    if override then
        return override
    end
    if M.is_mac() then
        return join(home(), "Library", "Logs", "pi2")
    end
    local base = env("XDG_STATE_HOME")
    if not base then
        base = join(home(), ".local", "state")
    end
    return join(base, "pi2")
end

--- Create a directory (recursively) and force `mode` on it. Idempotent.
--- @param path string
--- @param mode? integer defaults to 0700
--- @return string|nil path, string|nil err
function M.ensure_dir(path, mode)
    mode = mode or 448 -- 0700
    local uv = vim.uv or vim.loop
    local stat = uv.fs_stat(path)
    if stat then
        if stat.type ~= "directory" then
            return nil, "not a directory: " .. path
        end
        pcall(uv.fs_chmod, path, mode)
        return path, nil
    end
    local ok, err = pcall(vim.fn.mkdir, path, "p", mode)
    if not ok then
        return nil, tostring(err)
    end
    -- mkdir() honours the umask; a socket directory must stay private.
    pcall(uv.fs_chmod, path, mode)
    return path, nil
end

-- ---------------------------------------------------------------------------
-- sha256 (used for the short instance-socket names)
-- ---------------------------------------------------------------------------

local NIBBLE = {}
for a = 0, 15 do
    NIBBLE[a] = {}
    for b = 0, 15 do
        local r, bitv, x, y = 0, 1, a, b
        for _ = 1, 4 do
            if x % 2 ~= y % 2 then
                r = r + bitv
            end
            x, y, bitv = math.floor(x / 2), math.floor(y / 2), bitv * 2
        end
        NIBBLE[a][b] = r
    end
end

local M32 = 4294967296

--- 32-bit xor, arithmetic only (no `bit`/`vim.fn` dependency, so it is safe on
--- any Neovim build and callable from anywhere).
--- @param a integer
--- @param b integer
--- @return integer
local function bxor32(a, b)
    local r, mul = 0, 1
    for _ = 1, 8 do
        r = r + NIBBLE[a % 16][b % 16] * mul
        a, b, mul = math.floor(a / 16), math.floor(b / 16), mul * 16
    end
    return r
end

local AND_NIBBLE = {}
for a = 0, 15 do
    AND_NIBBLE[a] = {}
    for b = 0, 15 do
        local r, bitv, x, y = 0, 1, a, b
        for _ = 1, 4 do
            if x % 2 == 1 and y % 2 == 1 then
                r = r + bitv
            end
            x, y, bitv = math.floor(x / 2), math.floor(y / 2), bitv * 2
        end
        AND_NIBBLE[a][b] = r
    end
end

--- @param a integer
--- @param b integer
--- @return integer
local function band32(a, b)
    local r, mul = 0, 1
    for _ = 1, 8 do
        r = r + AND_NIBBLE[a % 16][b % 16] * mul
        a, b, mul = math.floor(a / 16), math.floor(b / 16), mul * 16
    end
    return r
end

--- @param x integer
--- @param n integer
--- @return integer
local function rshift32(x, n)
    return math.floor(x / 2 ^ n)
end

--- @param x integer
--- @param n integer
--- @return integer
local function lshift32(x, n)
    return (x * 2 ^ n) % M32
end

--- @param x integer
--- @return integer
local function rrotate32(x, n)
    return bxor32(rshift32(x, n), lshift32(x, 32 - n))
end

--- @param a integer
--- @param b integer
--- @return integer
local function add32(a, b)
    return (a + b) % M32
end

local K = {
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
}

--- @param s string
--- @param i integer 1-based byte offset
--- @return integer
local function byte_at(s, i)
    return s:byte(i) or 0
end

--- Pure-Lua SHA-256 of a byte string (lowercase hex).
--- @param message string
--- @return string
function M.sha256_hex(message)
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    local len = #message
    local bits = len * 8
    local pad = (56 - (len + 1) % 64) % 64
    local tail = {}
    tail[#tail + 1] = "\128"
    tail[#tail + 1] = string.rep("\0", pad)
    for shift = 56, 0, -8 do
        tail[#tail + 1] = string.char(math.floor(bits / 2 ^ shift) % 256)
    end
    local data = message .. table.concat(tail)

    local w = {}
    for offset = 1, #data, 64 do
        for i = 0, 15 do
            local p = offset + i * 4
            w[i] = ((byte_at(data, p) * 256 + byte_at(data, p + 1)) * 256 + byte_at(data, p + 2)) * 256
                + byte_at(data, p + 3)
        end
        for i = 16, 63 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor32(bxor32(rrotate32(x, 7), rrotate32(x, 18)), rshift32(x, 3))
            local s1 = bxor32(bxor32(rrotate32(y, 17), rrotate32(y, 19)), rshift32(y, 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % M32
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 0, 63 do
            local S1 = bxor32(bxor32(rrotate32(e, 6), rrotate32(e, 11)), rrotate32(e, 25))
            local ch = bxor32(band32(e, f), band32(4294967295 - e, g))
            local t1 = (h + S1 + ch + K[i + 1] + w[i]) % M32
            local S0 = bxor32(bxor32(rrotate32(a, 2), rrotate32(a, 13)), rrotate32(a, 22))
            local maj = bxor32(bxor32(band32(a, b), band32(a, c)), band32(b, c))
            local t2 = (S0 + maj) % M32
            h, g, f, e = g, f, e, (d + t1) % M32
            d, c, b, a = c, b, a, (t1 + t2) % M32
        end
        h0, h1, h2, h3 = add32(h0, a), add32(h1, b), add32(h2, c), add32(h3, d)
        h4, h5, h6, h7 = add32(h4, e), add32(h5, f), add32(h6, g), add32(h7, h)
    end

    local out = {}
    for _, v in ipairs({ h0, h1, h2, h3, h4, h5, h6, h7 }) do
        out[#out + 1] = string.format("%08x", v)
    end
    return table.concat(out)
end

--- SHA-256 hex digest, preferring the builtin (main loop only) and falling back
--- to the pure-Lua implementation.
--- @param message string
--- @return string
function M.sha256(message)
    if vim.fn.exists("*sha256") == 1 then
        local ok, digest = pcall(vim.fn.sha256, message)
        if ok and type(digest) == "string" and #digest == 64 then
            return digest
        end
    end
    return M.sha256_hex(message)
end

--- First 16 hex chars of the SHA-256 of `text` — short, stable identifiers.
--- @param text string
--- @return string
function M.hex16(text)
    return M.sha256(text):sub(1, 16)
end

-- ---------------------------------------------------------------------------
-- Instance sockets
-- ---------------------------------------------------------------------------

--- Directory holding the per-instance sockets.
--- @return string
function M.instance_dir()
    return join(M.runtime_dir(), "i")
end

--- Path of the daemon discovery file (`<runtime>/daemon.json`, written by
--- `pi2 daemon` after `listen()`; it carries the *actual* bound port).
--- @param dir? string runtime dir override
--- @return string
function M.daemon_json_path(dir)
    return join(dir or M.runtime_dir(), "daemon.json")
end

--- Path of the local CLI admin token (`<runtime>/cli.token`, 0600).
--- @param dir? string runtime dir override
--- @return string
function M.cli_token_path(dir)
    return join(dir or M.runtime_dir(), "cli.token")
end

--- Read a small text file and trim it. Never throws.
--- @param path string
--- @return string|nil
function M.read_text(path)
    local uv = vim.uv or vim.loop
    local ok, fd = pcall(uv.fs_open, path, "r", 0)
    if not ok or not fd then
        return nil
    end
    local data
    local stat_ok, stat = pcall(uv.fs_fstat, fd)
    if stat_ok and stat then
        local read_ok, content = pcall(uv.fs_read, fd, stat.size, 0)
        if read_ok then
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

--- Decoded `<runtime>/daemon.json`, or nil when it is missing/malformed.
--- Pure: no side effects, never throws.
--- @param dir? string runtime dir override
--- @return table|nil
function M.read_daemon_json(dir)
    local raw = M.read_text(M.daemon_json_path(dir))
    if not raw then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    return decoded
end

--- Socket path for one managed instance. The name is a 16-hex sha256 slice of
--- `workspace_id:instance_id`, so it is stable for the daemon and short enough
--- for the ~104-byte unix-socket limit (macOS); if the runtime dir is unusually
--- deep we fall back to a short temp base.
--- @param workspace_id string
--- @param instance_id string
--- @return string
function M.instance_socket_path(workspace_id, instance_id)
    local name = M.hex16(tostring(workspace_id) .. ":" .. tostring(instance_id)) .. ".sock"
    local path = join(M.instance_dir(), name)
    if #path >= 100 then
        local uv = vim.uv or vim.loop
        path = join(uv.os_tmpdir() or "/tmp", "pi2-i-" .. uid(), name)
    end
    return path
end

-- ---------------------------------------------------------------------------
-- Daemon resolution ladder
-- ---------------------------------------------------------------------------

--- Where a resolved `pi2` executable came from (ladder order).
---@alias pi.web.DaemonSource "config"|"env"|"path"|"plugin-data"|"checkout"

---@class pi.web.DaemonCandidate
---@field bin string executable to spawn: `<bin> daemon [web.daemon_args…]`
---@field source pi.web.DaemonSource

---@class pi.web.ResolveOpts
---@field config? pi.WebConfig daemon settings (defaults to `pi.config.options.web`)
---@field cwd? string start of the checkout walk-up (defaults to the process cwd)
---@field data_dir? string plugin-data root (defaults to `stdpath("data")`)
---@field env? table<string, string|nil> environment read for `$PI2_DAEMON_BIN` (defaults to `vim.env`)
---@field exepath? fun(name: string): string
---@field executable? fun(path: string): boolean

--- `true` when `path` exists and is executable. Never throws.
--- @param path string
--- @param executable fun(path: string): boolean
--- @return boolean
local function is_runnable(path, executable)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local uv = vim.uv or vim.loop
    local ok_stat, stat = pcall(uv.fs_stat, path)
    if not ok_stat or not stat or stat.type ~= "file" then
        return false
    end
    local ok_exec, runnable = pcall(executable, path)
    return ok_exec and runnable == true
end

--- Every ancestor of `dir`, starting with `dir` itself (string-only, so it works
--- for paths that do not exist and on Windows separators too).
--- @param dir string
--- @return string[]
local function ancestors(dir)
    local out = {}
    local current = (dir:gsub("[/\\]+$", ""))
    while current ~= "" do
        out[#out + 1] = current
        local parent = current:match("^(.*)[/\\][^/\\]*$")
        if not parent or parent == current then
            break
        end
        current = parent
    end
    return out
end

--- Turn a configured/exported value into a runnable path: an absolute (or
--- path-like) value is used as-is, a bare name goes through `exepath`. Returns
--- `nil` when nothing exists and is executable there.
--- @param value string|nil
--- @param exepath fun(name: string): string
--- @param executable fun(path: string): boolean
--- @return string|nil
local function runnable_bin(value, exepath, executable)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    local bin = value
    if not bin:find("[/\\]") then
        local ok_exe, resolved = pcall(exepath, value)
        bin = (ok_exe and type(resolved) == "string") and resolved or ""
    end
    if is_runnable(bin, executable) then
        return bin
    end
    return nil
end

--- @param opts pi.web.ResolveOpts
--- @return pi.web.DaemonCandidate|nil
local function do_resolve(opts)
    local ok_cfg, config = pcall(require, "pi.config")
    local cfg = opts.config or (ok_cfg and config.options.web) or {}
    local env_source = opts.env or vim.env
    local exepath = opts.exepath or function(name)
        return vim.fn.exepath(name)
    end
    local executable = opts.executable or function(path)
        return vim.fn.executable(path) == 1
    end
    --- @param fn fun(arg: string): string
    --- @param arg string
    --- @return string
    local function call(fn, arg)
        local pok, value = pcall(fn, arg)
        if pok and type(value) == "string" then
            return value
        end
        return ""
    end

    -- 1. config: `web.binary`, falling back to the deprecated `web.daemon`
    --    alias. An absolute path is used as-is, a bare name goes through exepath.
    local configured = cfg.binary
    if type(configured) ~= "string" or configured == "" then
        configured = cfg.daemon
    end
    local bin = runnable_bin(configured, exepath, executable)
    if bin then
        return { bin = bin, source = "config" }
    end

    -- 2. env: $PI2_DAEMON_BIN, same treatment as the config value.
    bin = runnable_bin(env_value(env_source, "PI2_DAEMON_BIN"), exepath, executable)
    if bin then
        return { bin = bin, source = "env" }
    end

    -- 3. PATH
    local on_path = call(exepath, "pi2")
    if is_runnable(on_path, executable) then
        return { bin = on_path, source = "path" }
    end

    -- 4. plugin data: the npm package `:PiWebInstall` maintains.
    local data_root = opts.data_dir or vim.fn.stdpath("data")
    local dir = cfg.install_dir
    if type(dir) ~= "string" or dir == "" then
        dir = join(data_root, "pi2d")
    end
    local plugin_data = join(dir, "node_modules", ".bin", "pi2")
    if is_runnable(plugin_data, executable) then
        return { bin = plugin_data, source = "plugin-data" }
    end

    -- 5. checkout: `node_modules/.bin/pi2` walked up from the cwd (daemon devs).
    for _, base in ipairs(ancestors(opts.cwd or vim.fn.getcwd())) do
        local candidate = join(base, "node_modules", ".bin", "pi2")
        if is_runnable(candidate, executable) then
            return { bin = candidate, source = "checkout" }
        end
    end

    -- Nothing runnable: no `npx` fallback (pi2d ADR 0002), the caller reports
    -- the install command instead.
    return nil
end

--- Resolve the `pi2` daemon executable through the fixed ladder:
---
--- 1. `web.binary` (or the deprecated `web.daemon`) — `config`
--- 2. `$PI2_DAEMON_BIN` — `env`
--- 3. `pi2` on `PATH` — `path`
--- 4. `<web.install_dir>/node_modules/.bin/pi2` — `plugin-data`
--- 5. `node_modules/.bin/pi2` walked up from the cwd — `checkout`
---
--- Every candidate must exist *and* be executable; the first match wins and
--- nothing else (no `npx`) is used as a fallback. Never throws: an undetectable
--- executable yields `nil`.
--- @param opts? pi.web.ResolveOpts
--- @return pi.web.DaemonCandidate|nil
function M.resolve_daemon(opts)
    local ok, resolved = pcall(do_resolve, opts or {})
    if ok then
        return resolved
    end
    return nil
end

return M
