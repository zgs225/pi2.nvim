--- Ask float: the blocking questionnaire the `ask` tool renders.
---
--- attention.lua owns the queue (immediate vs queued, statusline indicator,
--- :PiAttention); this module owns the presentation. `decode` turns the
--- `__pi_ask__` select payload into a normalized request, `open` renders it and
--- calls back exactly once with the wire reply.
---
--- Keys are buffer-local and vim-style on purpose: the reader is in normal mode,
--- so j/k move inside a question, h/l switch questions, gg/G jump to the first
--- and last option, and ZZ/ZQ submit and discard (the same pair vim uses to
--- write and quit).
---
--- Closing the window any other way (`:q`, `<C-w>c`, a plugin closing floats) is
--- not an answer: `opts.on_hide` fires so the caller can re-queue the request —
--- the backend is still blocked in ctx.ui.select, so dropping the request would
--- hang the turn forever and answering it would put words in the user's mouth.
---
--- The float is a normal-mode window. It drops out of insert on open and refuses
--- to re-enter it (`Prompt:focus` defers a `startinsert` that would otherwise
--- land here, where every keystroke on the read-only buffer is an E21); closing
--- it hands insert mode back to the window that had it.

local Keys = require("pi.keys")
local Ft = require("pi.filetypes")
local Strings = require("pi.ask.strings")

local M = {}

--- Reserved title of the select request that carries an ask payload.
---@type string
M.TITLE = "__pi_ask__"

local ns = vim.api.nvim_create_namespace("pi-ask")
local WINHIGHLIGHT = require("pi.ui.highlights").DIALOG_WINHIGHLIGHT

---@return boolean
local function is_insert()
    return vim.fn.mode():match("^i") ~= nil
end

---@class pi.AskOption
---@field label string
---@field description? string

---@class pi.AskQuestion
---@field id string
---@field header string
---@field question string
---@field options? pi.AskOption[]
---@field multi? boolean
---@field placeholder? string

---@class pi.AskRequest
---@field questions pi.AskQuestion[]

---@class pi.AskAnswer
---@field id string
---@field answered boolean
---@field selected integer[]
---@field labels string[]
---@field custom? string

--- Header budget in display columns (a CJK char is two of them).
local HEADER_WIDTH = 12

--- Default keymap, overridable through `ask.keys` (pi.KeySpecs, same shape as
--- `dialog.keys` / `diff.keys`).
---@type table<string, any>
local KEY_DEFAULTS = {
    down = "j",
    up = "k",
    next_question = "l",
    prev_question = "h",
    first = "gg",
    last = "G",
    select = "<CR>",
    toggle = "<Space>",
    clear = "x",
    free_text = "i",
    submit = "ZZ",
    cancel = { "<Esc>", "q", "ZQ" },
}

--- Options the float honours, read at call time (never cached at load).
---@return { allow_free_text: boolean, keys: table<string, any> }
local function float_cfg()
    local ask = require("pi.config").options.ask or {}
    local keys = vim.deepcopy(KEY_DEFAULTS)
    if type(ask.keys) == "table" then
        keys = vim.tbl_deep_extend("force", keys, ask.keys)
    end
    return { allow_free_text = ask.allow_free_text ~= false, keys = keys }
end

--- Geometry shared by every pi float (`dialog.border` / max width / max height).
---@return { border: any, max_width: number, max_height: number }
local function float_geometry()
    local dialog = require("pi.config").options.dialog or {}
    return {
        border = dialog.border or "rounded",
        max_width = type(dialog.max_width) == "number" and dialog.max_width or 0.8,
        max_height = type(dialog.max_height) == "number" and dialog.max_height or 0.8,
    }
end

--- Cut a header down to HEADER_WIDTH display columns.
---@param text string
---@return string
local function truncate_header(text)
    if vim.fn.strdisplaywidth(text) <= HEADER_WIDTH then
        return text
    end
    local out = ""
    for _, char in ipairs(vim.fn.split(text, "\\zs")) do
        if vim.fn.strdisplaywidth(out .. char) > HEADER_WIDTH - 1 then
            break
        end
        out = out .. char
    end
    return out .. "…"
end

--- Decode a `__pi_ask__` select payload into a request.
---
--- Every rejection returns a reason instead of throwing: attention turns an
--- undecodable payload into `{ v = 1, error = "unsupported" }`, which makes the
--- extension fall back to plain per-question dialogs instead of blocking.
---@param payload string?
---@return pi.AskRequest?, string?
function M.decode(payload)
    if type(payload) ~= "string" or vim.trim(payload) == "" then
        return nil, "missing payload"
    end
    local ok, decoded = pcall(vim.json.decode, payload)
    if not ok or type(decoded) ~= "table" then
        return nil, "invalid json"
    end
    if decoded.v ~= 1 then
        return nil, "unsupported version"
    end
    local raw = decoded.questions
    if type(raw) ~= "table" or #raw == 0 then
        return nil, "no questions"
    end

    local questions = {} ---@type pi.AskQuestion[]
    local seen_ids = {}
    for index, item in ipairs(raw) do
        if type(item) ~= "table" then
            return nil, string.format("question %d: not an object", index)
        end
        for _, field in ipairs({ "id", "header", "question" }) do
            if type(item[field]) ~= "string" or vim.trim(item[field]) == "" then
                return nil, string.format("question %d: missing %s", index, field)
            end
        end
        -- Answers are keyed by id, so a duplicate would silently merge two
        -- questions into one answer.
        if seen_ids[item.id] then
            return nil, string.format("question %d: duplicate id %s", index, item.id)
        end
        seen_ids[item.id] = true

        local options = {} ---@type pi.AskOption[]
        if item.options ~= nil then
            if type(item.options) ~= "table" then
                return nil, string.format("question %d: options is not a list", index)
            end
            for option_index, option in ipairs(item.options) do
                if type(option) ~= "table" then
                    return nil, string.format("question %d: option %d is not an object", index, option_index)
                end
                if type(option.label) ~= "string" or vim.trim(option.label) == "" then
                    return nil, string.format("question %d: option %d has no label", index, option_index)
                end
                options[#options + 1] = {
                    label = option.label,
                    description = type(option.description) == "string" and option.description or nil,
                }
            end
            if #options == 1 then
                return nil, string.format("question %d: a single option is not a choice", index)
            end
        end

        questions[#questions + 1] = {
            id = item.id,
            header = truncate_header(item.header),
            question = item.question,
            options = options,
            multi = item.multi == true,
            placeholder = type(item.placeholder) == "string" and item.placeholder or nil,
        }
    end

    return { questions = questions }
end

--- Encode the reply the extension parses.
---@param answers pi.AskAnswer[]?
---@param cancelled boolean
---@return table
function M.encode(answers, cancelled)
    if cancelled then
        return { v = 1, cancelled = true }
    end
    return { v = 1, answers = answers or {}, cancelled = false }
end

---@param win integer
local function fit_height_to_wrapped_content(win)
    if not vim.api.nvim_win_is_valid(win) then
        return
    end
    local geometry = float_geometry()
    local editor_w = vim.o.columns
    local editor_h = vim.o.lines - vim.o.cmdheight
    local cap_h = geometry.max_height < 1 and math.floor(editor_h * geometry.max_height) or geometry.max_height
    local width = vim.api.nvim_win_get_width(win)
    local ok_height, text_height = pcall(vim.api.nvim_win_text_height, win, {})
    if not ok_height or type(text_height) ~= "table" then
        return
    end
    local height = math.max(1, math.min(text_height.all, cap_h))
    local win_cfg = vim.api.nvim_win_get_config(win)
    win_cfg.row = math.floor((editor_h - height) / 2)
    win_cfg.col = math.floor((editor_w - width) / 2)
    win_cfg.height = height
    pcall(vim.api.nvim_win_set_config, win, win_cfg)
end

--- Open a centered float for the questionnaire.
---@return { buf: integer, win: integer }
local function open_float()
    local geometry = float_geometry()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = Ft.ask
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].completefunc = ""
    vim.bo[buf].omnifunc = ""
    vim.bo[buf].modifiable = false

    local editor_w = vim.o.columns
    local editor_h = vim.o.lines - vim.o.cmdheight
    local cap_w = geometry.max_width < 1 and math.floor(editor_w * geometry.max_width) or geometry.max_width
    local cap_h = geometry.max_height < 1 and math.floor(editor_h * geometry.max_height) or geometry.max_height
    local width = math.max(20, math.min(math.max(44, math.floor(editor_w * 0.6)), cap_w))
    local height = math.min(8, cap_h)

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        row = math.floor((editor_h - height) / 2),
        col = math.floor((editor_w - width) / 2),
        width = width,
        height = height,
        style = "minimal",
        border = geometry.border,
        title = " " .. Strings.t("float_title") .. " ",
        title_pos = "center",
    })
    vim.wo[win].winhighlight = WINHIGHLIGHT
    vim.wo[win].signcolumn = "no"
    vim.wo[win].cursorline = false
    vim.wo[win].wrap = true

    return { buf = buf, win = win }
end

--- Replace the float's content (the buffer is read-only between renders).
---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    vim.bo[buf].modifiable = true
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

--- A single question with its selectable rows resolved.
---@class pi.AskFloatQuestion
---@field id string
---@field header string
---@field question string
---@field options pi.AskOption[]
---@field rows table[]
---@field multi boolean
---@field text_only boolean

local active = false

--- Open the questionnaire and block on the user.
---
--- `opts.on_done` fires exactly once when the user answers, cancels, or the ask
--- times out. `opts.on_hide` fires instead when the float is closed some other
--- way (`:q`, `<C-w>c`, an overlay collapsing it): the backend is still waiting,
--- so the caller is expected to re-queue the request. It never fires when `open`
--- itself refuses to open (another ask is already showing).
---@param req pi.AskRequest
---@param opts { timeout?: integer, on_done: fun(result: table), on_hide?: fun() }
---@return boolean opened
---@return string? reason `"busy"` when another float already owns the screen,
--- `"empty"` when the request carries no questions.
function M.open(req, opts)
    if active then
        return false, "busy"
    end

    local cfg = float_cfg()
    local questions = {} ---@type pi.AskFloatQuestion[]
    for _, question in ipairs(req.questions or {}) do
        local options = question.options or {}
        local rows = {}
        for index, option in ipairs(options) do
            rows[#rows + 1] = { kind = "option", index = index, label = option.label, description = option.description }
        end
        if cfg.allow_free_text then
            rows[#rows + 1] = { kind = "free", index = #options + 1 }
        end
        if #rows == 0 then
            -- Free text disabled and no options: the question still needs one
            -- selectable row, otherwise the user cannot answer at all.
            rows[1] = { kind = "free", index = 1 }
        end
        questions[#questions + 1] = {
            id = question.id,
            header = question.header,
            question = question.question,
            options = options,
            rows = rows,
            multi = question.multi == true,
            text_only = #options == 0,
        }
    end
    if #questions == 0 then
        return false, "empty"
    end

    local multi_question = #questions > 1
    local review_tab = #questions + 1
    local state = { tab = 1, cursor = 1, done = false }
    local answers = {} ---@type table<string, pi.AskAnswer>
    for _, question in ipairs(questions) do
        answers[question.id] = { id = question.id, answered = false, selected = {}, labels = {} }
    end

    -- `Prompt:focus` defers a `startinsert` for the window it focused; opening
    -- this float steals that focus, so the deferred startinsert lands *here*.
    -- The buffer is read-only and binds normal-mode keys only, which turned
    -- every keystroke into an E21. Leave insert before opening, and keep the
    -- float out of it (the guard below beats any startinsert that arrives later,
    -- whatever the schedule order).
    local was_insert = is_insert()
    vim.cmd("stopinsert")

    local float = open_float()
    local buf, win = float.buf, float.win
    active = true

    vim.api.nvim_create_autocmd("InsertEnter", {
        buffer = buf,
        callback = function()
            vim.cmd("stopinsert")
        end,
    })

    -- A scheduled focus change elsewhere can also win the race against
    -- nvim_open_win; re-assert once the loop settles so the keys land in the
    -- window the user is looking at.
    vim.schedule(function()
        if state.done or not vim.api.nvim_win_is_valid(win) then
            return
        end
        if vim.api.nvim_get_current_win() ~= win then
            pcall(vim.api.nvim_set_current_win, win)
        end
    end)

    local timer = nil ---@type integer?

    ---@return pi.AskAnswer
    local function answer_of(question)
        return answers[question.id]
    end

    ---@param question pi.AskFloatQuestion
    ---@return boolean
    local function is_answered(question)
        local answer = answers[question.id]
        return answer ~= nil and answer.answered == true
    end

    ---@param question pi.AskFloatQuestion
    ---@return string
    local function describe_answer(question, answer)
        if type(answer.custom) == "string" and vim.trim(answer.custom) ~= "" then
            return Strings.t("wrote") .. answer.custom
        end
        if #answer.labels > 0 then
            return table.concat(answer.labels, ", ")
        end
        return Strings.t("unanswered")
    end

    ---@return table[]
    local function current_rows()
        if state.tab > #questions then
            return {}
        end
        return questions[state.tab].rows
    end

    ---@return string
    local function hint()
        if state.tab > #questions then
            return Strings.t("hint_review")
        end
        local question = questions[state.tab]
        local parts = { Strings.t("hint_move") }
        if multi_question then
            parts[#parts + 1] = Strings.t("hint_switch")
        end
        parts[#parts + 1] = Strings.t("hint_select")
        if question.multi then
            parts[#parts + 1] = Strings.t("hint_toggle")
            parts[#parts + 1] = Strings.t("hint_clear")
        end
        for _, row in ipairs(question.rows) do
            if row.kind == "free" then
                parts[#parts + 1] = Strings.t("hint_free")
                break
            end
        end
        parts[#parts + 1] = Strings.t("hint_submit")
        parts[#parts + 1] = Strings.t("hint_cancel")
        return table.concat(parts, " · ")
    end

    local render ---@type fun()

    ---@param text string
    ---@param group? string
    ---@return integer row 0-based row of the appended line
    local function push(lines, highlights, text, group)
        lines[#lines + 1] = text
        if group then
            highlights[#highlights + 1] = { row = #lines - 1, group = group, text = text }
        end
        return #lines - 1
    end

    render = function()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local lines = {} ---@type string[]
        local highlights = {} ---@type { row: integer, group: string, text: string }[]
        local cursor_row = 1

        if state.tab > #questions then
            push(lines, highlights, Strings.t("review"), "PiAskHeader")
            push(lines, highlights, "")
            for _, question in ipairs(questions) do
                local answer = answer_of(question)
                local mark = answer.answered and Strings.t("answered_mark") or Strings.t("unanswered_mark")
                local text = string.format("%s %s   %s", mark, question.header, describe_answer(question, answer))
                push(lines, highlights, text, answer.answered and "PiAskAnswer" or "PiAskCancelled")
            end
            push(lines, highlights, "")
            push(lines, highlights, hint())
        else
            local question = questions[state.tab]
            if multi_question then
                push(lines, highlights, Strings.t("progress", state.tab, #questions), "PiAskHeader")
                local chips = {}
                for index, item in ipairs(questions) do
                    if index == state.tab then
                        chips[#chips + 1] = "[" .. item.header .. "]"
                    else
                        local mark = is_answered(item) and Strings.t("answered_mark") or Strings.t("unanswered_mark")
                        chips[#chips + 1] = mark .. item.header
                    end
                end
                push(lines, highlights, table.concat(chips, "  "), "PiAskHeader")
                push(lines, highlights, "")
            end
            push(lines, highlights, question.question)
            push(lines, highlights, "")
            local picked = answer_of(question).selected
            for index, row in ipairs(question.rows) do
                local pointer = index == state.cursor and "> " or "  "
                -- Multi-select needs a visible tick per row: without it the user
                -- cannot tell what a Space press changed before submitting.
                local mark = ""
                if question.multi and row.kind == "option" then
                    local is_picked = false
                    for _, value in ipairs(picked) do
                        if value == row.index then
                            is_picked = true
                            break
                        end
                    end
                    mark = is_picked and (Strings.t("answered_mark") .. " ") or (Strings.t("unanswered_mark") .. " ")
                end
                local text
                if row.kind == "free" then
                    text = Strings.t("free_text")
                    local answer = answer_of(question)
                    if type(answer.custom) == "string" and vim.trim(answer.custom) ~= "" then
                        text = text .. " " .. Strings.t("wrote") .. answer.custom
                    end
                    text = string.format("%s%s%d. %s", pointer, mark, row.index, text)
                else
                    text = string.format("%s%s%d. %s", pointer, mark, row.index, row.label)
                end
                cursor_row = push(lines, highlights, text, index == state.cursor and "PiAskOption" or nil) + 1
                if type(row.description) == "string" and row.description ~= "" then
                    push(lines, highlights, "      " .. row.description, "PiAskHeader")
                end
            end
            push(lines, highlights, "")
            push(lines, highlights, hint())
        end

        set_lines(buf, lines)
        pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
        for _, item in ipairs(highlights) do
            pcall(vim.api.nvim_buf_add_highlight, buf, ns, item.group, item.row, 0, #item.text)
        end
        -- Refit after the lines exist: measuring the buffer before its content
        -- is written reports one row and collapses the float to a single line.
        fit_height_to_wrapped_content(win)
        local target = math.max(1, math.min(cursor_row, math.max(1, #lines)))
        pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
    end

    ---@return nil
    local close_window = function()
        if timer then
            pcall(vim.fn.timer_stop, timer)
            timer = nil
        end
        active = false
        pcall(function()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
            if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_delete(buf, { force = true })
            end
        end)
        -- Hand insert mode back to whoever had it (same contract as
        -- lua/pi/ui/dialog.lua), but only to an editable buffer: the chat
        -- history is read-only and would just reject the startinsert.
        if was_insert then
            vim.schedule(function()
                if vim.bo.modifiable and vim.fn.mode():match("^n") then
                    vim.cmd("startinsert")
                end
            end)
        end
    end

    ---@param cancelled boolean
    local function finish(cancelled)
        if state.done then
            return
        end
        state.done = true
        local payload
        if cancelled then
            payload = M.encode(nil, true)
        else
            local list = {} ---@type pi.AskAnswer[]
            for _, question in ipairs(questions) do
                list[#list + 1] = answer_of(question)
            end
            payload = M.encode(list, false)
        end
        close_window()
        opts.on_done(payload)
    end

    ---@return integer
    local function unanswered_count()
        local count = 0
        for _, question in ipairs(questions) do
            if not is_answered(question) then
                count = count + 1
            end
        end
        return count
    end

    ---@return nil
    local submit = function()
        if state.done then
            return
        end
        if unanswered_count() > 0 then
            local choice =
                vim.fn.confirm(Strings.t("confirm_unanswered", unanswered_count()), Strings.t("confirm_buttons"), 2)
            if choice ~= 1 then
                render()
                return
            end
        end
        finish(false)
    end

    --- Answer a question with free text: the free-text row wins over any option
    --- selection (the wire format cannot express "both").
    ---@param question pi.AskFloatQuestion
    ---@return nil
    local function prompt_free_text(question)
        local answer = answer_of(question)
        local Dialog = require("pi.ui.dialog")
        Dialog.input({
            title = Strings.t("answer_title", question.header),
            default = answer.custom or "",
        }, function(value)
            -- The ask can end while the input float is open (ask.timeout_ms, a
            -- hidden float, another window closing us): drop a late answer.
            if state.done then
                return
            end
            if value == nil or vim.trim(value) == "" then
                render()
                return
            end
            answer.custom = value
            answer.selected = {}
            answer.labels = {}
            answer.answered = vim.trim(value) ~= ""
            if state.tab <= #questions and state.tab < #questions then
                state.tab = state.tab + 1
                state.cursor = 1
                render()
            elseif state.tab <= #questions then
                if multi_question then
                    state.tab = review_tab
                    render()
                else
                    finish(false)
                end
            end
        end)
    end

    --- Record the cursored option and move on (or submit on the last question).
    ---@return nil
    local function confirm_current()
        if state.tab > #questions then
            submit()
            return
        end
        local question = questions[state.tab]
        local row = question.rows[state.cursor]
        if row == nil then
            return
        end
        if row.kind == "free" then
            prompt_free_text(question)
            return
        end
        local answer = answer_of(question)
        if question.multi then
            if #answer.selected == 0 then
                answer.selected = { row.index }
                answer.labels = { row.label }
                -- The wire format cannot express "an option and some text": the
                -- option wins, so the earlier free-text answer is dropped.
                answer.custom = nil
                answer.answered = true
            end
        else
            answer.selected = { row.index }
            answer.labels = { row.label }
            answer.custom = nil
            answer.answered = true
        end
        if not multi_question then
            finish(false)
            return
        end
        if state.tab < #questions then
            state.tab = state.tab + 1
            state.cursor = 1
        else
            state.tab = review_tab
        end
        render()
    end

    --- Toggle the cursored option of a multi-select question.
    ---@return nil
    local function toggle_current()
        if state.tab > #questions then
            return
        end
        local question = questions[state.tab]
        local row = question.rows[state.cursor]
        if row == nil then
            return
        end
        if row.kind == "free" then
            prompt_free_text(question)
            return
        end
        if not question.multi then
            confirm_current()
            return
        end
        local answer = answer_of(question)
        local found = nil ---@type integer?
        for index, value in ipairs(answer.selected) do
            if value == row.index then
                found = index
                break
            end
        end
        if found then
            table.remove(answer.selected, found)
        else
            answer.selected[#answer.selected + 1] = row.index
            table.sort(answer.selected)
        end
        answer.custom = nil
        answer.labels = {}
        for _, value in ipairs(answer.selected) do
            local option = question.options[value]
            if option then
                answer.labels[#answer.labels + 1] = option.label
            end
        end
        answer.answered = #answer.selected > 0
        render()
    end

    --- Clear every selection of the current question (multi-select only).
    ---@return nil
    local function clear_current()
        if state.tab > #questions then
            return
        end
        local question = questions[state.tab]
        if not question.multi then
            return
        end
        local answer = answer_of(question)
        answer.selected = {}
        answer.labels = {}
        answer.custom = nil
        answer.answered = false
        render()
    end

    ---@param delta integer
    ---@return nil
    local function move(delta)
        local rows = current_rows()
        if #rows == 0 then
            return
        end
        state.cursor = math.max(1, math.min(#rows, state.cursor + delta))
        render()
    end

    ---@param tab integer
    ---@return nil
    local function goto_tab(tab)
        if not multi_question then
            return
        end
        state.tab = math.max(1, math.min(review_tab, tab))
        state.cursor = 1
        render()
    end

    ---@param digit integer
    ---@return nil
    local function pick(digit)
        if state.tab > #questions then
            return
        end
        local question = questions[state.tab]
        local row = question.rows[digit]
        if row == nil then
            return
        end
        state.cursor = digit
        if row.kind == "free" then
            prompt_free_text(question)
            return
        end
        if question.multi then
            toggle_current()
        else
            confirm_current()
        end
    end

    -- Bindings: single-character keys through Keys.bind (the same path every
    -- other pi float uses), multi-character vim sequences directly so `gg`/`ZZ`
    -- are not swallowed by a nowait mapping.
    local keys = cfg.keys
    ---@param spec any
    ---@param handler fun()
    local function bind(spec, handler)
        for _, key in ipairs(Keys.resolve(spec)) do
            Keys.bind(buf, key, handler, { nowait = true, desc = "Pi ask" })
        end
    end

    ---@param spec any
    ---@param handler fun()
    local function bind_sequence(spec, handler)
        for _, key in ipairs(Keys.resolve(spec)) do
            local lhs = Keys.lhs(key)
            local modes = type(key) == "table" and key.modes or "n"
            vim.keymap.set(modes, lhs, handler, { buffer = buf, desc = "Pi ask" })
        end
    end

    bind(keys.down, function()
        move(1)
    end)
    bind(keys.up, function()
        move(-1)
    end)
    bind_sequence(keys.first, function()
        state.cursor = 1
        render()
    end)
    bind_sequence(keys.last, function()
        state.cursor = math.max(1, #current_rows())
        render()
    end)
    bind(keys.next_question, function()
        goto_tab(state.tab + 1)
    end)
    bind(keys.prev_question, function()
        goto_tab(state.tab - 1)
    end)
    bind(keys.select, confirm_current)
    bind(keys.toggle, toggle_current)
    bind(keys.clear, clear_current)
    bind(keys.free_text, function()
        if state.tab > #questions then
            return
        end
        local question = questions[state.tab]
        for index, row in ipairs(question.rows) do
            if row.kind == "free" then
                state.cursor = index
                render()
                prompt_free_text(question)
                return
            end
        end
    end)
    bind_sequence(keys.submit, submit)
    bind(keys.cancel, function()
        finish(true)
    end)
    for digit = 1, 9 do
        vim.keymap.set("n", tostring(digit), function()
            pick(digit)
        end, { buffer = buf, desc = "Pi ask option " .. digit })
    end

    -- Closing the float by other means (`:q`, `<C-w>c`, a plugin's cleanup) is
    -- not an answer: hand it back to the caller, which re-queues the request so
    -- the user can reopen it with :PiAttention. Answering for the user here
    -- would be the fabricated-answer bug the design note warns about.
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win),
        once = true,
        callback = function()
            if state.done then
                return
            end
            state.done = true
            close_window()
            if opts.on_hide then
                opts.on_hide()
            else
                opts.on_done(M.encode(nil, true))
            end
        end,
    })

    if type(opts.timeout) == "number" and opts.timeout > 0 then
        timer = vim.defer_fn(function()
            timer = nil
            -- Answer "cancelled" instead of only closing the window: if the
            -- backend is still blocked (a host-side timeout, not pi's own), a
            -- silent close would hang the turn. When pi already resolved the
            -- dialog, the extra response is dropped as an unknown id.
            finish(true)
        end, opts.timeout)
    end

    local ok, err = pcall(function()
        render()
    end)
    if not ok then
        state.done = true
        close_window()
        error(err, 0)
    end
    return true
end

return M
