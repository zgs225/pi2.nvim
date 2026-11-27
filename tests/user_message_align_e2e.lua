-- Headless e2e: user message alignment in the REAL chat, not a detached History
-- in a sandbox buffer.
--
-- The unit spec (`tests/user_message_align_spec.lua`) pins `build_user_block`
-- and the realign pass against a float of a known width. This script pins what
-- only the real thing can observe:
--
--   * the width the padding is computed from is the chat history window's own
--     text area (`getwininfo().width - textoff`, i.e. after sign/fold columns),
--     so the padded rows really end on the window's right edge;
--   * nothing in the real render path (render-markdown attach, the startup
--     preamble, pending-block stripping) rewrites or re-indents those rows;
--   * a resize through the layout's real handlers re-pads EVERY block (the
--     multi-block case is where a wrong extmark gravity silently moved the
--     second block's anchor onto the first), and the conversation survives the
--     rewrite;
--   * toggling the layout reopens the history window at a different width, and
--     that alone (via `set_win`) re-pads the blocks.
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/user_message_align_e2e.lua
--
-- Isolation (G17/G18): agent dir / prompt history / draft are temp paths set
-- before `require("pi")`, and `_agent.send` is stubbed (no model call). A run
-- that pollutes the user's sessions dir fails at the bottom.

local real_sessions_dir = vim.fn.expand("~/.pi/agent/sessions")
--- @param dir string
--- @return integer
local function count_jsonl(dir)
    return #vim.fn.globpath(dir, "**/*.jsonl", false, true)
end

local real_sessions_before = count_jsonl(real_sessions_dir)
local agent_dir = vim.fn.tempname()

vim.env.PI_CODING_AGENT_DIR = agent_dir
require("pi.prompt_history")._set_base_dir(vim.fn.tempname())
require("pi.draft")._set_path(vim.fn.tempname() .. "/draft.txt")

local failures = {}

--- Record one assertion. `detail` carries the got/want evidence.
---@param name string assertion label
---@param ok boolean assertion result
---@param detail? string got/want evidence
local function check(name, ok, detail)
    print(string.format("[%s] %s%s", ok and "PASS" or "FAIL", name, detail and (" — " .. detail) or ""))
    if not ok then
        failures[#failures + 1] = name
    end
end

--- Drain the event loop (`vim.schedule` render callbacks need it).
---@param ms? integer
local function pump(ms)
    vim.wait(ms or 150)
end

--- @param ft string
--- @return integer? buf first buffer carrying this filetype
local function find_buf(ft)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].filetype == ft then
            return b
        end
    end
end

--- Width of a window's text area, the way `History:_history_width()` reads it.
---@param win integer
---@return integer
local function text_width(win)
    local info = vim.fn.getwininfo(win)
    if info and info[1] then
        return math.max(1, info[1].width - info[1].textoff)
    end
    return vim.api.nvim_win_get_width(win)
end

--- @param s string
--- @return integer
local function dw(s)
    return vim.fn.strdisplaywidth(s)
end

--- One user message block as rendered: its label row and its body rows.
--- Structurally: a row whose first non-blank cell is the user icon, then the
--- mandatory blank line, then every non-blank row after it.
---@param hbuf integer
---@param icon string
---@return { label: string, body: string[] }[]
local function user_blocks(hbuf, icon)
    local lines = vim.api.nvim_buf_get_lines(hbuf, 0, -1, false)
    local out = {}
    local i = 1
    while i <= #lines do
        if vim.startswith(vim.trim(lines[i]), icon) then
            local body = {}
            local j = i + 2 -- label row, then exactly one blank
            while j <= #lines and lines[j] ~= "" do
                body[#body + 1] = lines[j]
                j = j + 1
            end
            out[#out + 1] = { label = lines[i], body = body }
            i = j
        else
            i = i + 1
        end
    end
    return out
end

--- Leading padding of a rendered row, in columns (the padding is ASCII spaces).
---@param line string
---@return integer
local function left_col(line)
    return #(line:match("^ *") or "")
end

--- The configured floor on a box's width, in columns (0 = none).
---@return integer
local function min_width()
    local minw = require("pi.config").options.user_message_min_width
    if type(minw) ~= "number" or minw <= 0 then
        return 0
    end
    return minw
end

--- Assert the block contract on every block: all rows start on the label's left
--- column, the BOX's right edge sits on `edge` (the text-area width minus the
--- one-column right margin) and nothing overflows it. A box is at least
--- `user_message_min_width` wide, so a short one does not put a glyph on the
--- edge: the box is right-aligned, the text inside it is left-aligned.
---@param blocks { label: string, body: string[] }[]
---@param edge integer
---@return string? first offending row, or nil
local function block_geometry_error(blocks, edge)
    for _, block in ipairs(blocks) do
        local left = left_col(block.label)
        local content = dw(block.label) - left
        if dw(block.label) > edge then
            return "label overflow:" .. block.label
        end
        for _, row in ipairs(block.body) do
            if left_col(row) ~= left then
                return "off the block's left column:" .. row
            end
            if dw(row) > edge then
                return "overflow:" .. row
            end
            content = math.max(content, dw(row) - left)
        end
        local box = math.max(content, min_width())
        if left + box ~= edge then
            return ("box does not end on the edge (left=%d box=%d):%s"):format(left, box, block.label)
        end
    end
    return nil
end

--- First body row wider than `cap` display columns, ignoring the label (the
--- label is a floor, never capped).
---@param blocks { label: string, body: string[] }[]
---@param cap integer
---@return string? first row over the cap, or nil
local function over_cap(blocks, cap)
    for _, block in ipairs(blocks) do
        for _, row in ipairs(block.body) do
            if dw(row) - left_col(row) > cap then
                return row
            end
        end
    end
    return nil
end

--- The text a block renders, with the right padding stripped back off.
--- Leading spaces only: a hard-wrapped chunk keeps whatever the message has at
--- its edges, so trailing spaces must survive for the text to compare equal.
---@param block { label: string, body: string[] }
---@return string
local function block_text(block)
    local parts = {}
    for _, row in ipairs(block.body) do
        parts[#parts + 1] = (row:gsub("^ +", ""))
    end
    return table.concat(parts, "")
end

--- Compare text ignoring whitespace: a hard wrap may split at a space, and
--- whether that space lands at the end of one row or the start of the next is
--- not what this script asserts.
---@param s string
---@return string
local function squash(s)
    return (s:gsub("%s+", ""))
end

local messages = {
    "right aligned in the real chat",
    "中文也要按显示宽度补齐",
    "the real chat window pads every user body row to its right edge, "
        .. "and this sentence is long enough to need more than one rendered row",
}

local ok_body, err = pcall(function()
    local Config = require("pi.config")
    require("pi").setup({
        user_message_align = "right",
        layout = { default = "side", side = { width = 64 } },
    })
    check("option resolved from setup()", Config.options.user_message_align == "right")
    check(
        "the shipped width bounds are a 75% cap and a 24-column floor",
        Config.options.user_message_max_width == 0.75 and Config.options.user_message_min_width == 24,
        ("max=%s min=%s"):format(
            tostring(Config.options.user_message_max_width),
            tostring(Config.options.user_message_min_width)
        )
    )
    local icon = Config.options.labels.user_message

    require("pi").show({ layout = "side" })
    vim.wait(15000, function()
        return find_buf("pi-chat-history") ~= nil and find_buf("pi-chat-prompt") ~= nil
    end, 20)

    local session = require("pi.sessions.manager").get()
    check("session created", session ~= nil)
    if not session or not session.chat then
        return
    end
    local chat = session.chat
    if chat._agent then
        chat._agent.send = function() end -- hermetic: never call the model
    end
    local layout = chat._layout
    local history = chat._history
    check("side layout is active", layout and layout:mode() == "side")
    if not layout then
        return
    end
    local hwin = layout:history_win()
    check("history window valid", hwin ~= nil and vim.api.nvim_win_is_valid(hwin))
    if not hwin then
        return
    end
    local hbuf = vim.api.nvim_win_get_buf(hwin)

    -- The startup preamble is fetched asynchronously and rendered into the same
    -- buffer; let it land first so this script measures nothing but the blocks.
    vim.wait(15000, function()
        return history._startup_loaded == true
    end, 20)
    pump(100)

    for _, text in ipairs(messages) do
        chat:add_user_message(text, nil)
        pump()
    end
    pump(250)

    local tw = text_width(hwin)
    local edge = tw - 1 -- history.lua keeps one column of right margin
    local blocks = user_blocks(hbuf, icon)
    check("three user message blocks rendered", #blocks == 3, "got=" .. #blocks)
    check(
        "every block is flush right and internally left-aligned",
        block_geometry_error(blocks, edge) == nil,
        ("text_area=%d edge=%d off=%s"):format(tw, edge, vim.inspect(block_geometry_error(blocks, edge)))
    )
    check(
        "the CJK message is padded by display width, not byte length",
        blocks[2] ~= nil and squash(block_text(blocks[2])) == squash(messages[2]),
        blocks[2] and block_text(blocks[2]) or "missing"
    )
    check(
        "the long message wrapped instead of overflowing",
        blocks[3] ~= nil and #blocks[3].body >= 2 and squash(block_text(blocks[3])) == squash(messages[3]),
        blocks[3] and ("rows=" .. #blocks[3].body) or "missing"
    )
    check(
        "the shipped 75% cap bounds every body row of the default render",
        over_cap(blocks, math.floor(tw * Config.options.user_message_max_width)) == nil,
        tostring(over_cap(blocks, math.floor(tw * Config.options.user_message_max_width)))
    )

    -- The width cap: a box is at most `user_message_max_width` columns wide,
    -- still flush right, still internally left-aligned. The cap is read at
    -- render time, so only the message added AFTER it takes effect here; the
    -- layout toggle below re-renders the earlier ones and is where every block
    -- is checked against it.
    local cap = 28
    Config.options.user_message_max_width = cap
    chat:add_user_message(string.rep("k", 100), nil)
    pump(300)
    local capped_blocks = user_blocks(hbuf, icon)
    check("the capped message rendered as its own block", #capped_blocks == 4, "got=" .. #capped_blocks)
    local capped = capped_blocks[#capped_blocks]
    check(
        "the cap makes the box exactly `cap` wide and keeps it flush right",
        capped ~= nil and left_col(capped.label) == edge - cap,
        capped and ("left=%d want=%d"):format(left_col(capped.label), edge - cap) or "missing"
    )
    check(
        "the capped message wraps instead of spanning the window",
        capped ~= nil and #capped.body >= 4 and squash(block_text(capped)) == string.rep("k", 100),
        capped and ("rows=" .. #capped.body) or "missing"
    )
    check(
        "every row of the capped block stays inside the cap",
        capped ~= nil and over_cap({ capped }, cap) == nil,
        capped and tostring(over_cap({ capped }, cap)) or "missing"
    )

    -- The floor: a two-letter message still renders as a box `min_width` wide,
    -- so a short message reads as a bubble instead of a sliver on the edge.
    chat:add_user_message("ok", nil)
    pump(300)
    local floored_blocks = user_blocks(hbuf, icon)
    local floored = floored_blocks[#floored_blocks]
    check("the short message rendered as its own block", #floored_blocks == 5, "got=" .. #floored_blocks)
    check(
        "a short message keeps the minimum box width",
        floored ~= nil and left_col(floored.label) == edge - min_width(),
        floored and ("left=%d want=%d"):format(left_col(floored.label), edge - min_width()) or "missing"
    )

    -- (1) The layout toggle reopens the history window at a different width;
    -- `set_win` alone has to re-pad every block for it.
    local switched = false
    if pcall(function()
        require("pi").toggle_layout()
    end) then
        switched = vim.wait(8000, function()
            return layout:mode() == "float"
        end, 20)
    end
    check("switched to the float layout", switched == true, "mode=" .. tostring(layout:mode()))
    if not switched then
        return
    end
    pump(300)
    local fwin = layout:history_win()
    local fbuf = vim.api.nvim_win_get_buf(fwin)
    local tw_float = text_width(fwin)
    local edge_float = tw_float - 1
    check(
        "the float history window has a different text width",
        tw_float ~= tw,
        ("side=%d float=%d"):format(tw, tw_float)
    )
    local blocks_float = user_blocks(fbuf, icon)
    check("all five blocks survived the layout toggle", #blocks_float == 5, "got=" .. #blocks_float)
    check(
        "every block re-laid out for the float layout",
        block_geometry_error(blocks_float, edge_float) == nil,
        ("edge=%d off=%s"):format(edge_float, vim.inspect(block_geometry_error(blocks_float, edge_float)))
    )
    check(
        "the cap survived the re-render: no block is wider than the cap",
        over_cap(blocks_float, cap) == nil,
        tostring(over_cap(blocks_float, cap))
    )

    -- (2) A REAL editor resize. Headless has no UI, so `columns` alone fires
    -- nothing — the layout's own `VimResized` handler is what resizes the float
    -- stack, and firing that event is exactly what a terminal resize does.
    local before_cols = vim.o.columns
    vim.o.columns = math.max(40, math.floor(before_cols * 0.6))
    vim.api.nvim_exec_autocmds("VimResized", {})
    pump(500)
    local tw_after = text_width(layout:history_win())
    check(
        "the real history text area really changed width",
        tw_after ~= tw_float,
        ("columns %d→%d, text_width %d→%d"):format(before_cols, vim.o.columns, tw_float, tw_after)
    )
    local blocks_after = user_blocks(vim.api.nvim_win_get_buf(layout:history_win()), icon)
    local edge_after = tw_after - 1
    check(
        "every block re-laid out for the NEW edge after the real resize",
        block_geometry_error(blocks_after, edge_after) == nil,
        ("edge=%d off=%s"):format(edge_after, vim.inspect(block_geometry_error(blocks_after, edge_after)))
    )
    check(
        "the cap still holds after the real resize",
        over_cap(blocks_after, cap) == nil,
        tostring(over_cap(blocks_after, cap))
    )
    local expected_texts = { messages[1], messages[2], messages[3], string.rep("k", 100), "ok" }
    local same = #blocks_after == #expected_texts
    for i = 1, math.min(#expected_texts, #blocks_after) do
        same = same and squash(block_text(blocks_after[i])) == squash(expected_texts[i])
    end
    check("every message kept its own text through the realigns", same, "got=" .. #blocks_after)
end)

if not ok_body then
    check("e2e body completed without error", false, tostring(err))
end

-- G18: no model call => no transcript.
local real_sessions_after = count_jsonl(real_sessions_dir)
check(
    "G18: real sessions dir jsonl count unchanged",
    real_sessions_after == real_sessions_before,
    ("got=%d want=%d delta=%+d dir=%s"):format(
        real_sessions_after,
        real_sessions_before,
        real_sessions_after - real_sessions_before,
        real_sessions_dir
    )
)
local temp_jsonl = vim.fn.globpath(agent_dir, "**/*.jsonl", false, true)
check("G18: temp agent dir has no session transcript", #temp_jsonl == 0, ("got=%d want=0"):format(#temp_jsonl))

if #failures > 0 then
    print("USER MESSAGE ALIGN E2E: " .. #failures .. " failed — " .. table.concat(failures, ", "))
    vim.cmd("cq 1")
else
    print("USER MESSAGE ALIGN E2E: ALL GREEN")
    vim.cmd("cq 0")
end
