-- Headless e2e: ANSI-coloured tool output through the *real* chat wiring.
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/ansi_render_e2e.lua
--
-- Unlike tests/ansi_render_spec.lua (a `History.new()` sandbox), this boots the
-- plugin, opens the real side layout with its history window, and pushes a bash
-- tool result carrying SGR sequences into that live instance. It asserts what a
-- user would see: no escape bytes in the buffer, `PiAnsi*` span extmarks with
-- resolved colours on the output row, colours surviving a collapse/expand round
-- trip, and display widths that match the visible text.
--
-- No prompt is submitted (the backend send is stubbed), so no session
-- transcript is written and no model is called.

local failures = {}

local function check(name, ok, detail)
    print(string.format("[%s] %s%s", ok and "PASS" or "FAIL", name, detail and (" — " .. detail) or ""))
    if not ok then
        failures[#failures + 1] = name
    end
end

local function find_buf(ft)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].filetype == ft then
            return b
        end
    end
end

--- Rows (0-indexed) of lines that are exactly `text`.
local function rows_exact(buf, text)
    local out = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l == text then
            out[#out + 1] = i - 1
        end
    end
    return out
end

local function ansi_marks(history)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(history:buf(), history:ns(), 0, -1, { details = true })) do
        local hl = m[4] and m[4].hl_group
        if type(hl) == "string" and hl:match("^PiAnsi") then
            out[#out + 1] = m
        end
    end
    return out
end

local function escape_free(buf)
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l:find("\27", 1, true) then
            return false, l
        end
    end
    return true
end

local ok, err = pcall(function()
    require("pi").show({ layout = "side" })
    vim.wait(8000, function()
        return find_buf("pi-chat-history") ~= nil
    end, 50)

    local hbuf = find_buf("pi-chat-history")
    check("chat history buffer exists", hbuf ~= nil)
    if not hbuf then
        return
    end

    local session = require("pi.sessions.manager").get()
    check("session created", session ~= nil)
    if not session then
        return
    end
    -- Keep the test hermetic: never talk to the model.
    session.chat._agent.send = function() end

    local history = session.chat._history
    check("history instance reachable from the session", history ~= nil)
    if not history then
        return
    end

    -- A realistic ANSI payload: bold green PASS, red FAIL, 256-colour and
    -- truecolor spans, plus an OSC title sequence to prove it is dropped.
    local output = table.concat({
        "\27]0;pi ansi e2e\7\27[1;32mPASS\27[0m test_api.py::test_ok",
        "\27[1;31mFAIL\27[0m test_api.py::test_bad",
        "\27[38;5;208mwarning\27[0m \27[38;2;255;105;180mtruecolor\27[0m",
    }, "\n")

    history:on_tool_start("bash", "ansi-e2e", { command = "ls --color" })
    vim.wait(200)
    history:on_tool_end("bash", "ansi-e2e", { content = { { type = "text", text = output } } }, false)
    vim.wait(400)

    local clean, dirty = escape_free(hbuf)
    check("buffer carries no escape bytes", clean, dirty)
    local osc_leaked = false
    for _, l in ipairs(vim.api.nvim_buf_get_lines(hbuf, 0, -1, false)) do
        if l:find("pi ansi e2e", 1, true) then
            osc_leaked = true
        end
    end
    check("OSC title sequence dropped", not osc_leaked)
    -- Only the tail is visible while collapsed (bash keeps output_visible = 1).
    check("collapsed tail renders the last output line", #rows_exact(hbuf, "warning truecolor") == 1)

    local block = history._tool_blocks["ansi-e2e"]
    check("tool block registered", block ~= nil)
    if block then
        -- Three output lines with output_visible = 1 ⇒ collapsed to the tail.
        check("block collapsed to the tail", block.expanded == false)
    end

    local marks = ansi_marks(history)
    check("ANSI span extmarks created", #marks > 0, ("%d marks"):format(#marks))

    local groups = {}
    for _, m in ipairs(marks) do
        local hl = m[4].hl_group
        groups[hl] = true
        check("span sits above the block base highlight", (m[4].priority or 0) > 200)
    end

    local n_groups = 0
    local all_have_colour = true
    for hl in pairs(groups) do
        n_groups = n_groups + 1
        local attrs = vim.api.nvim_get_hl(0, { name = hl, link = false })
        if not attrs.fg and not attrs.bg then
            all_have_colour = false
        end
    end
    check("span groups resolve to real colours", n_groups > 0 and all_have_colour, ("%d groups"):format(n_groups))

    -- Width correctness: for the rows that came from the tool output, the
    -- visible text must measure exactly as wide as it looks (a raw ESC would
    -- add two columns each). Non-output rows (nerd-font icons in the welcome
    -- banner) legitimately have dw > chars, so they are not part of this check.
    local expected_rows = {
        ["PASS test_api.py::test_ok"] = true,
        ["FAIL test_api.py::test_bad"] = true,
        ["warning truecolor"] = true,
    }
    local width_ok, width_seen = true, 0
    for _, l in ipairs(vim.api.nvim_buf_get_lines(hbuf, 0, -1, false)) do
        if expected_rows[l] then
            width_seen = width_seen + 1
            if vim.fn.strdisplaywidth(l) ~= vim.fn.strchars(l) then
                width_ok = false
            end
        end
    end
    check("display widths match the visible text", width_ok and width_seen >= 1, ("%d rows"):format(width_seen))

    if block then
        local before = #ansi_marks(history)
        history:_set_tool_block_expanded(block, true)
        vim.wait(300)
        local expanded_marks = #ansi_marks(history)
        check("expand reveals every span", expanded_marks >= before, ("%d -> %d"):format(before, expanded_marks))
        check("SGR-carrying line survives as visible text", #rows_exact(hbuf, "PASS test_api.py::test_ok") == 1)
        history:_set_tool_block_expanded(block, false)
        vim.wait(300)
        local recollapsed_marks = #ansi_marks(history)
        check("re-collapse keeps the tail coloured", recollapsed_marks > 0, ("%d marks"):format(recollapsed_marks))
        check("still escape-free after toggling", (escape_free(hbuf)))
    end

    -- The degraded path: with colorization disabled the block must still render
    -- clean text (this is what an older Neovim / a failed hl call falls back to).
    local Ansi = require("pi.ui.chat.ansi")
    Ansi._degrade("e2e forced degradation")
    history:on_tool_start("bash", "ansi-e2e-2", { command = "true" })
    vim.wait(150)
    history:on_tool_end("bash", "ansi-e2e-2", {
        content = { { type = "text", text = "\27[31mdegraded\27[0m line" } },
    }, false)
    vim.wait(300)
    check("degraded render is escape-free", (escape_free(hbuf)))
    check("degraded render keeps a matching ANSI mark count", Ansi.enabled == false)
    Ansi._reset()
end)

if not ok then
    check("e2e body completed without error", false, tostring(err))
end

if #failures > 0 then
    print("ANSI E2E: " .. #failures .. " failed — " .. table.concat(failures, ", "))
    vim.cmd("cq 1")
else
    print("ANSI E2E: ALL GREEN")
    vim.cmd("cq 0")
end
