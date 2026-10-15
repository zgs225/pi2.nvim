-- Regression: multi-line task commands in the :PiTasks preview and stop dialog.
--
-- RPC `command` strings may contain newlines (multi-line bash). The preview
-- header and the stop-confirmation message must flatten them onto a single
-- display line, otherwise nvim_buf_set_lines rejects a replacement string that
-- contains a newline (E5108) when the preview float renders.
--
-- Harness mirrors tests/tasks_ui_spec.lua: seed fake tasks through
-- pi.tasks.upsert (no RPC), open the panel, drive real key paths via
-- nvim_feedkeys, and locate the float by its buffer name.

local Tasks = require("pi.tasks")
local Panel = require("pi.ui.tasks")
local Sidebar = require("pi.ui.sidebar")
local Config = require("pi.config")

-- A multi-line bash command (the exact shape that triggered the report).
local MULTILINE = 'for spec in "等线 regular" "等线 bold"\ndo echo "$spec"\ndone'
-- The flattened form the preview header and stop dialog are expected to show.
local FLAT = 'for spec in "等线 regular" "等线 bold" do echo "$spec" done'

---@return integer
local function now_ms()
    return vim.uv.now()
end

--- Seed a fake task.
---@param fields table
---@return table
local function seed(fields)
    local task = vim.tbl_extend("force", {
        id = "t1",
        command = "echo hi",
        status = "running",
        start_time = now_ms() - 60_000,
    }, fields)
    Tasks.upsert(task)
    return task
end

--- Press a key in the current window through the real key path.
---@param key string
local function press(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
end

--- Find a window displaying a buffer whose name contains `fragment`.
---@param fragment string
---@return integer?
local function find_win_by_name(fragment)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        if name:find(fragment, 1, true) then
            return win
        end
    end
    return nil
end

--- Open the panel and park the cursor on the row whose text contains `id`.
---@param id string
---@return integer list_win
local function open_on_row(id)
    Panel.open()
    local list_win = Panel.win(vim.api.nvim_get_current_tabpage())
    vim.api.nvim_set_current_win(list_win)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(list_win), 0, -1, false)
    for i, line in ipairs(lines) do
        if line:find(id, 1, true) then
            vim.api.nvim_win_set_cursor(list_win, { i, 0 })
            return list_win
        end
    end
    error("seeded task row not found in the panel: " .. id)
end

describe("tasks preview multiline command", function()
    before_each(function()
        Tasks._reset()
        Panel._reset()
        Panel._resubscribe()
        Sidebar._reset()
    end)

    after_each(function()
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_is_valid(win) then
                local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
                if name:find("pi://task", 1, true) or name:find("pi://tasks", 1, true) then
                    pcall(vim.api.nvim_win_close, win, true)
                end
            end
        end
        Panel._reset()
        Tasks._reset()
        Sidebar._reset()
        Config.options.tasks_panel.auto_open = false
    end)

    it("flattens a multi-line command in the preview header (no E5108)", function()
        local path = vim.fn.tempname()
        vim.fn.writefile({ "regular line", "bold line" }, path)
        seed({
            id = "ml1",
            command = MULTILINE,
            status = "running",
            start_time = now_ms() - 60_000,
            output_file = path,
        })

        open_on_row("ml1")
        press("p")

        local preview = find_win_by_name("pi://task-preview/ml1")
        assert.is_not_nil(preview, "preview float opened for the multi-line task")
        local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(preview), 0, -1, false)
        assert.are.equal("$ " .. FLAT, lines[1], "header flattens the command onto a single line")

        vim.fn.delete(path)
    end)

    it("flattens a multi-line command in the stop confirmation message", function()
        seed({
            id = "ml1",
            command = MULTILINE,
            status = "running",
            pid = 987_654_321,
            start_time = now_ms() - 60_000,
        })

        open_on_row("ml1")

        local captured
        local orig_confirm = vim.fn.confirm
        vim.fn.confirm = function(msg)
            captured = msg
            return 2 -- &No: decline so nothing is signalled
        end
        press("x")
        vim.fn.confirm = orig_confirm

        assert.is_not_nil(captured, "stop key path called vim.fn.confirm")
        assert.is_nil(captured:find("\n", 1, true), "confirmation message contains no newline")
        assert.are.equal("Stop task ml1 (" .. FLAT .. ")?", captured, "confirmation message flattens the command")
    end)
end)
