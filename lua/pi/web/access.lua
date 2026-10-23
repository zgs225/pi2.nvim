-- Remembered web-console access mode (`local` | `lan` | `tailscale`).
--
-- The mode chooses how the daemon binds and which origins it accepts; it is
-- advertised to `pi2 daemon` through `PI2_ACCESS_MODE` (see `pi.web.start_daemon`).
-- Resolution order:
--
--   1. `web.access` when it is set and not `"ask"` (explicit configuration wins);
--   2. the remembered answer in `<stdpath("state")>/pi2/access.json`;
--   3. `"local"` (loopback only).
--
-- Reading is pure and never throws (a malformed file falls back to `"local"`);
-- writing is atomic (temp file + rename) and private (0600 file, 0700 dir).

local M = {}

local Runtime = require("pi.web.runtime")

local uv = vim.uv or vim.loop

--- @alias pi.web.AccessMode "local"|"lan"|"tailscale"

--- Ladder order, also the `vim.ui.select` order.
--- @type pi.web.AccessMode[]
M.MODES = { "local", "lan", "tailscale" }

--- Short `vim.ui.select` descriptions.
--- @type table<pi.web.AccessMode, string>
M.DESCRIPTIONS = {
    ["local"] = "local — this machine only, browser opens already signed in (default)",
    ["lan"] = "lan — reachable on your local network (no TLS)",
    ["tailscale"] = "tailscale — reachable through a tailnet/public URL",
}

--- Test hook: override the base directory (mirrors `pi.prompt_history`).
--- @type string|nil
local base_dir_override = nil

--- @param dir? string
function M._set_base_dir(dir)
    base_dir_override = dir
end

--- @param mode any
--- @return boolean
function M.is_mode(mode)
    if type(mode) ~= "string" then
        return false
    end
    for _, known in ipairs(M.MODES) do
        if known == mode then
            return true
        end
    end
    return false
end

--- Directory holding the remembered mode (`<stdpath("state")>/pi2`).
--- @return string
function M.dir()
    if base_dir_override then
        return base_dir_override
    end
    return vim.fs.joinpath(vim.fn.stdpath("state"), "pi2")
end

--- Path of the persisted choice.
--- @return string
function M.path()
    return vim.fs.joinpath(M.dir(), "access.json")
end

--- The configured mode, when `web.access` pins one (i.e. is not nil/`"ask"`).
--- @return pi.web.AccessMode|nil
function M.pinned()
    local ok, config = pcall(require, "pi.config")
    if not ok then
        return nil
    end
    local access = (config.options.web or {}).access
    if M.is_mode(access) then
        return access
    end
    return nil
end

--- The persisted mode, or nil when nothing usable was remembered. Pure: no
--- side effects, never throws (malformed JSON → nil).
--- @return pi.web.AccessMode|nil
function M.remembered()
    local raw = Runtime.read_text(M.path())
    if not raw then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    if M.is_mode(decoded.access) then
        return decoded.access
    end
    return nil
end

--- Effective access mode: `web.access` → remembered → `"local"`.
--- @return pi.web.AccessMode
function M.get()
    return M.pinned() or M.remembered() or "local"
end

--- Persist `mode` atomically (temp file + rename, 0600 file, 0700 dir).
--- @param mode pi.web.AccessMode|string
--- @return pi.web.AccessMode|nil mode, string|nil err
function M.set(mode)
    if not M.is_mode(mode) then
        return nil, "access must be local, lan or tailscale"
    end
    local dir = M.dir()
    local ok_dir, dir_err = Runtime.ensure_dir(dir, 448) -- 0700
    if not ok_dir then
        return nil, dir_err
    end
    local path = M.path()
    local tmp = ("%s.tmp.%d"):format(path, uv.hrtime())
    local payload = vim.json.encode({ access = mode })
    local fd, open_err = uv.fs_open(tmp, "w", 384) -- 0600
    if not fd then
        return nil, tostring(open_err or ("cannot write " .. tmp))
    end
    local wrote, write_err = pcall(uv.fs_write, fd, payload .. "\n", -1)
    pcall(uv.fs_close, fd)
    if not wrote then
        pcall(uv.fs_unlink, tmp)
        return nil, tostring(write_err)
    end
    local renamed, rename_err = pcall(uv.fs_rename, tmp, path)
    if not renamed then
        pcall(uv.fs_unlink, tmp)
        return nil, tostring(rename_err)
    end
    pcall(uv.fs_chmod, path, 384)
    return mode
end

--- Ask the user for a mode with `vim.ui.select` and remember the answer.
---
--- With an `on_choice` callback the call is asynchronous (the picker keeps the
--- editor responsive) and returns `nil` immediately; without one it waits for
--- the answer and returns the chosen mode (nil when cancelled).
--- @param on_choice? fun(mode: pi.web.AccessMode|nil)
--- @return pi.web.AccessMode|nil
function M.choose(on_choice)
    local answered = false
    --- @type pi.web.AccessMode|nil
    local answer = nil

    --- @param item any
    local function finish(item)
        answered = true
        if M.is_mode(item) then
            answer = M.set(item) or item
        end
        if on_choice then
            on_choice(answer)
        end
    end

    vim.ui.select(M.MODES, {
        prompt = "π² web console access mode",
        format_item = function(item)
            return M.DESCRIPTIONS[item] or tostring(item)
        end,
    }, finish)

    if on_choice then
        return nil
    end
    -- Default (and several plugin) pickers answer synchronously; an async one
    -- answers from its own loop, which `vim.wait` keeps running.
    if not answered then
        vim.wait(60000, function()
            return answered
        end, 20)
    end
    return answer
end

return M
