--- Path shortening and resolution for user-facing path output.
---
--- Tool blocks print the paths they touch, and models routinely emit absolute
--- ones (`/home/<user>/proj/apps/web/src/Foo.vue`). The workspace prefix carries
--- no information — the session cwd already fixes it — so it is stripped before
--- the path reaches the history buffer.
---
--- `display()` is lossless by default: it only removes the workspace (or home)
--- prefix, so the returned text still resolves against the same base via
--- `resolve()` — which `History:goto_path_at_cursor` depends on. The
--- `basename` mode (used by the inline `read` line) is the one lossy mode, and
--- its callers must recover the real path from the tool block rather than from
--- the rendered text.

local M = {}

---@class pi.PathDisplayOpts
---@field base? string Workspace cwd stripped from the path (default: the process cwd)
---@field basename? boolean Keep only the last segment (lossy; default: false)

---@param p string
---@return string
local function strip_trailing_slash(p)
    if #p > 1 and p:sub(-1) == "/" then
        return p:sub(1, -2)
    end
    return p
end

---@param p string
---@return boolean
local function is_absolute(p)
    return p:sub(1, 1) == "/" or p:match("^%a:[/\\]") ~= nil or p:sub(1, 2) == "\\\\"
end

--- `abs` relative to `dir`, or nil when it is not inside it.
---@param abs string
---@param dir string
---@return string? rel
local function relative_to(abs, dir)
    if dir == "" then
        return nil
    end
    if dir == "/" then
        return abs:sub(1, 1) == "/" and abs:sub(2) or nil
    end
    if vim.startswith(abs, dir .. "/") then
        return abs:sub(#dir + 2)
    end
    return nil
end

--- Normalize a path to an absolute form: `~` expanded, relative paths resolved
--- against `base`, `..` collapsed. Never touches the filesystem, so it also
--- works for paths that do not exist (yet).
---@param path string
---@param base? string  directory used to resolve relative paths (default: the process cwd)
---@return string abs
function M.resolve(path, base)
    local p = vim.trim(path)
    if p == "" then
        return p
    end
    local absolute
    if is_absolute(p) or p == "~" or p:sub(1, 2) == "~/" then
        absolute = vim.fn.fnamemodify(p, ":p")
    else
        local dir = type(base) == "string" and vim.trim(base) or ""
        if dir == "" then
            dir = vim.fn.getcwd()
        end
        absolute = vim.fn.fnamemodify(dir .. "/" .. p, ":p")
    end
    return strip_trailing_slash(vim.fn.simplify(absolute))
end

--- Shorten a path for display by stripping the workspace (or home) prefix.
---@param path string
---@param opts? pi.PathDisplayOpts
---@return string
function M.display(path, opts)
    opts = opts or {}
    if type(path) ~= "string" or vim.trim(path) == "" then
        return path
    end

    local base = M.resolve(opts.base or vim.fn.getcwd(), nil)
    local abs = M.resolve(path, base)
    local rel = relative_to(abs, base)
    if not rel then
        local home = M.resolve("~", nil)
        local from_home = relative_to(abs, home)
        rel = from_home and ("~/" .. from_home) or abs
    end

    if opts.basename then
        return rel:match("([^/\\]+)$") or rel
    end
    return rel
end

return M
