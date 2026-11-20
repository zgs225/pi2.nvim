--- Minimal TOML reader for `pi.worktree_config` (`.pi-worktrees.toml`).
---
--- Deliberately a *subset* of TOML v1.0, sized to a repository config file a
--- human writes by hand:
---
--- - `key = value` pairs, `[table]` and `[table.sub]` headers, `#` comments
--- - basic (escaped) and literal strings, single-line only
--- - integers, floats, booleans
--- - arrays, including multi-line arrays and a trailing comma
---
--- Not supported, and reported as an error instead of being silently ignored:
--- inline tables (`{ a = 1 }`), arrays of tables (`[[x]]`), dotted keys in a
--- header are supported but dotted keys in a `key =` statement are not, and
--- dates/times are read as strings only. Nothing here evaluates code: a value
--- is data, never a command.
---
--- `M.decode(text)` returns `(table)` or `(nil, err)` where `err` names the line
--- (`"toml: line 7: unterminated array"`), so a broken config file can be
--- reported verbatim.

local M = {}

---@class pi.TomlReader
---@field text string Full document
---@field i integer Byte index of the next unread character
---@field line integer 1-based line of `i`

---@param text string
---@return pi.TomlReader
local function reader(text)
    return { text = text, i = 1, line = 1 }
end

---@param st pi.TomlReader
---@return string? char
local function peek(st)
    return st.text:sub(st.i, st.i)
end

--- Advance `n` characters, keeping `line` in step.
---@param st pi.TomlReader
---@param n integer
local function advance(st, n)
    local text = st.text
    local last = math.min(st.i + n - 1, #text)
    if last >= st.i then
        local _, lines = text:sub(st.i, last):gsub("\n", "")
        st.line = st.line + lines
        st.i = last + 1
    end
end

--- Error text for the reader's current position.
---@param st pi.TomlReader
---@param msg string
---@return string err
local function fail_msg(st, msg)
    return string.format("toml: line %d: %s", st.line, msg)
end

---@param st pi.TomlReader
---@param msg string
---@return nil value
---@return string err
local function fail(st, msg)
    return nil, fail_msg(st, msg)
end

---@param ch string?
---@return boolean
local function is_space(ch)
    return ch == " " or ch == "\t" or ch == "\r"
end

--- Skip spaces, tabs, carriage returns, and — when `newlines` is true — line
--- breaks and `#` comments anywhere in the document.
---@param st pi.TomlReader
---@param newlines boolean
local function skip_ws(st, newlines)
    while true do
        local ch = peek(st)
        if ch == "" then
            return
        end
        if is_space(ch) or (newlines and ch == "\n") then
            advance(st, 1)
        elseif newlines and ch == "#" then
            while true do
                local c = peek(st)
                if c == "" or c == "\n" then
                    break
                end
                advance(st, 1)
            end
        else
            return
        end
    end
end

---@param ch string?
---@return boolean
local function is_bare_key_char(ch)
    return ch ~= nil and ch ~= "" and (ch:match("[%w_%-]") ~= nil)
end

-- Strings --------------------------------------------------------------------

---@type table<string, string>
local ESCAPES = {
    b = "\b",
    t = "\t",
    n = "\n",
    f = "\f",
    r = "\r",
    ['"'] = '"',
    ["\\"] = "\\",
}

---@param st pi.TomlReader
---@return string? value
---@return string? err
local function parse_basic_string(st)
    advance(st, 1) -- opening quote
    local out = {}
    while true do
        local ch = peek(st)
        if ch == "" or ch == "\n" then
            return fail(st, "unterminated string")
        end
        if ch == '"' then
            advance(st, 1)
            return table.concat(out)
        end
        if ch == "\\" then
            advance(st, 1)
            local esc = peek(st)
            if esc == "" then
                return fail(st, "unterminated escape")
            end
            local simple = ESCAPES[esc]
            if simple then
                out[#out + 1] = simple
                advance(st, 1)
            elseif esc == "u" or esc == "U" then
                local len = esc == "u" and 4 or 8
                local hex = st.text:sub(st.i + 1, st.i + len)
                if #hex ~= len or hex:match("^%x+$") == nil then
                    return fail(st, "invalid unicode escape")
                end
                local code = tonumber(hex, 16)
                if code == nil or code > 0x10FFFF then
                    return fail(st, "invalid unicode escape")
                end
                out[#out + 1] = vim.fn.nr2char(code)
                advance(st, 1 + len)
            else
                return fail(st, "invalid escape '" .. esc .. "'")
            end
        else
            out[#out + 1] = ch
            advance(st, 1)
        end
    end
end

---@param st pi.TomlReader
---@return string? value
---@return string? err
local function parse_literal_string(st)
    advance(st, 1) -- opening quote
    local start = st.i
    while true do
        local ch = peek(st)
        if ch == "" or ch == "\n" then
            return fail(st, "unterminated literal string")
        end
        if ch == "'" then
            local value = st.text:sub(start, st.i - 1)
            advance(st, 1)
            return value
        end
        advance(st, 1)
    end
end

-- Values ---------------------------------------------------------------------

---@param st pi.TomlReader
---@return table? value
---@return string? err
local function parse_array(st)
    advance(st, 1) -- [
    local out = {}
    while true do
        skip_ws(st, true)
        local ch = peek(st)
        if ch == "" then
            return fail(st, "unterminated array")
        end
        if ch == "]" then
            advance(st, 1)
            return out
        end
        local value, err = M._value(st)
        if err then
            return nil, err
        end
        out[#out + 1] = value
        skip_ws(st, true)
        local sep = peek(st)
        if sep == "," then
            advance(st, 1)
        elseif sep ~= "]" then
            return fail(st, "expected ',' or ']' in array")
        end
    end
end

--- Parse one value at the reader's position.
---@param st pi.TomlReader
---@return any value
---@return string? err
function M._value(st)
    local ch = peek(st)
    if ch == '"' then
        return parse_basic_string(st)
    end
    if ch == "'" then
        return parse_literal_string(st)
    end
    if ch == "[" then
        return parse_array(st)
    end

    local start = st.i
    while true do
        local c = peek(st)
        if c == "" or is_space(c) or c == "\n" or c == "," or c == "]" or c == "#" then
            break
        end
        advance(st, 1)
    end
    local word = st.text:sub(start, st.i - 1)
    if word == "" then
        return fail(st, "expected a value")
    end
    if word == "true" then
        return true
    end
    if word == "false" then
        return false
    end

    local digits = word:gsub("_", "")
    local number = tonumber(digits)
    if number ~= nil and (digits:match("^[+-]?%d+$") or digits:match("^[+-]?%d+%.%d+$")) then
        return number
    end
    return fail(st, "unsupported value '" .. word .. "' (strings must be quoted)")
end

-- Keys and tables --------------------------------------------------------------

---@param st pi.TomlReader
---@return string? key
---@return string? err
local function parse_key_part(st)
    local ch = peek(st)
    if ch == '"' then
        return parse_basic_string(st)
    end
    if ch == "'" then
        return parse_literal_string(st)
    end
    local start = st.i
    while is_bare_key_char(peek(st)) do
        advance(st, 1)
    end
    local key = st.text:sub(start, st.i - 1)
    if key == "" then
        return fail(st, "expected a key")
    end
    return key
end

--- Parse a dotted key (`a.b.c`) into its parts.
---@param st pi.TomlReader
---@return string[]? parts
---@return string? err
local function parse_dotted_key(st)
    local parts = {}
    while true do
        skip_ws(st, false)
        local part, err = parse_key_part(st)
        if err then
            return nil, err
        end
        parts[#parts + 1] = part
        skip_ws(st, false)
        if peek(st) ~= "." then
            return parts
        end
        advance(st, 1)
    end
end

--- Walk `parts` from `root`, creating intermediate tables when `create` is set.
--- Returns the table the last part names, or `(nil, err)` when the path is not a
--- table. The final part is only resolved by the caller (it holds a value).
---@param root table
---@param parts string[]
---@param st pi.TomlReader
---@return table? parent
---@return string? err
local function walk(root, parts, st)
    local node = root
    for index = 1, #parts - 1 do
        local name = parts[index]
        local existing = node[name]
        if existing == nil then
            existing = {}
            node[name] = existing
        elseif type(existing) ~= "table" then
            return fail(st, string.format("'%s' is already a value, not a table", table.concat(parts, ".", 1, index)))
        end
        node = existing
    end
    return node
end

---@class pi.TomlState
---@field root table Document root (a `[table]` header is always absolute)
---@field current table Table a `key = value` statement writes into

---@param st pi.TomlReader
---@param state pi.TomlState
---@return boolean ok
---@return string? err
local function parse_statement(st, state)
    if peek(st) == "[" then
        advance(st, 1)
        if peek(st) == "[" then
            return false, fail_msg(st, "arrays of tables ('[[x]]') are not supported")
        end
        local parts, err = parse_dotted_key(st)
        if err or not parts then
            return false, err or fail_msg(st, "expected a table name")
        end
        skip_ws(st, false)
        if peek(st) ~= "]" then
            return false, fail_msg(st, "expected ']' to close the table header")
        end
        advance(st, 1)
        skip_ws(st, false)
        local rest = peek(st)
        if rest ~= "" and rest ~= "\n" and rest ~= "#" then
            return false, fail_msg(st, "trailing text after table header")
        end
        local node, walk_err = walk(state.root, parts, st)
        if walk_err or not node then
            return false, walk_err or fail_msg(st, "invalid table header")
        end
        local leaf = node[parts[#parts]]
        if leaf == nil then
            leaf = {}
            node[parts[#parts]] = leaf
        elseif type(leaf) ~= "table" then
            return false, fail_msg(st, string.format("'%s' is already a value, not a table", table.concat(parts, ".")))
        end
        -- Re-opening a table is accepted (it merges) rather than rejected: a
        -- hand-written config that splits `[retention]` in two is a typo we can
        -- read unambiguously.
        state.current = leaf
        return true, nil
    end

    local parts, err = parse_dotted_key(st)
    if err or not parts then
        return false, err or fail_msg(st, "expected a key")
    end
    skip_ws(st, false)
    if peek(st) ~= "=" then
        return false, fail_msg(st, "expected '=' after key")
    end
    advance(st, 1)
    skip_ws(st, false)
    local value, value_err = M._value(st)
    if value_err then
        return false, value_err
    end
    skip_ws(st, false)
    local rest = peek(st)
    if rest ~= "" and rest ~= "\n" and rest ~= "#" then
        return false, fail_msg(st, "trailing text after value")
    end

    local parent, walk_err = walk(state.current, parts, st)
    if walk_err or not parent then
        return false, walk_err or fail_msg(st, "invalid key")
    end
    local key = parts[#parts]
    if parent[key] ~= nil then
        return false, fail_msg(st, "duplicate key '" .. table.concat(parts, ".") .. "'")
    end
    parent[key] = value
    return true, nil
end

-- Public API -----------------------------------------------------------------

--- Decode a TOML document.
---@param text string
---@return table? value
---@return string? err
function M.decode(text)
    if type(text) ~= "string" then
        return nil, "toml: text required"
    end
    local st = reader(text)
    local root = {}
    ---@type pi.TomlState
    local state = { root = root, current = root }
    while true do
        skip_ws(st, true)
        if st.i > #st.text then
            return root
        end
        local ok, err = parse_statement(st, state)
        if not ok then
            return nil, err
        end
    end
end

return M
