-- The `ask` float state machine (lua/pi/ui/ask.lua), driven through its real
-- buffer-local keymaps: j/k move, h/l switch questions, <CR> confirms, Space
-- toggles, x clears, i types, digits pick, Esc cancels, ZZ submits. The payoff
-- of each key is the wire payload handed to `on_done` (or `on_hide` when the
-- window is closed by something else), so that is what these specs assert.
--
-- The free-text sub-dialog is stubbed: `ctx.ui.input` has its own spec, and this
-- file is about what the float does with the answer it gets back.

local Config = require("pi.config")
local Dialog = require("pi.ui.dialog")
local Ask = require("pi.ui.ask")

describe("ask float", function()
    local real_input = Dialog.input

    ---@return integer[] floating window ids
    local function floats()
        local out = {}
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(win).relative ~= "" then
                out[#out + 1] = win
            end
        end
        return out
    end

    after_each(function()
        Dialog.input = real_input
        for _, win in ipairs(floats()) do
            pcall(vim.api.nvim_win_close, win, true)
        end
        Config.setup({})
    end)

    --- Open a request and collect what the float reports back.
    ---@param questions pi.AskQuestion[]
    ---@return boolean opened
    ---@return { done: integer, hidden: integer, payload: table? }
    local function open(questions)
        local calls = { done = 0, hidden = 0 }
        local opened = Ask.open({ questions = questions }, {
            on_done = function(result)
                calls.done = calls.done + 1
                calls.payload = result
            end,
            on_hide = function()
                calls.hidden = calls.hidden + 1
            end,
        })
        return opened, calls
    end

    ---@param lhs string
    local function press(lhs)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
        vim.wait(10)
    end

    ---@return string
    local function buffer_text()
        return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    end

    local single = {
        {
            id = "q1",
            header = "DB",
            question = "Which database?",
            options = { { label = "SQLite" }, { label = "Postgres" } },
        },
    }

    it("returns the picked option and its 1-based position", function()
        local opened, calls = open(single)
        assert.is_true(opened)
        assert.matches("Which database?", buffer_text())
        press("j")
        press("<CR>")
        assert.equals(1, calls.done)
        assert.is_false(calls.payload.cancelled)
        assert.equals(1, #calls.payload.answers)
        assert.equals("q1", calls.payload.answers[1].id)
        assert.is_true(calls.payload.answers[1].answered)
        assert.same({ 2 }, calls.payload.answers[1].selected)
        assert.same({ "Postgres" }, calls.payload.answers[1].labels)
    end)

    it("refuses insert mode so a late startinsert cannot break the keys", function()
        local opened, calls = open(single)
        assert.is_true(opened)
        -- Prompt:focus defers a `startinsert` for the window it focused. When
        -- that lands after the float took focus, insert mode turned every j/k/<CR>
        -- into an E21 on this read-only buffer.
        vim.cmd("startinsert")
        vim.wait(100)
        assert.equals("n", vim.fn.mode())
        press("j")
        press("<CR>")
        assert.equals(1, calls.done)
        assert.same({ "Postgres" }, calls.payload.answers[1].labels)
    end)

    it("sizes the float to its content instead of one row", function()
        local opened = open(single)
        assert.is_true(opened)
        local height = vim.api.nvim_win_get_height(vim.api.nvim_get_current_win())
        local lines = vim.api.nvim_buf_line_count(0)
        -- The questionnaire is several rows; measuring the buffer before its
        -- content existed reported one row and collapsed the float.
        assert.is_true(lines > 1)
        assert.is_true(height > 1)
    end)

    it("picks an option by its digit", function()
        local opened, calls = open(single)
        assert.is_true(opened)
        press("2")
        assert.equals(1, calls.done)
        assert.same({ "Postgres" }, calls.payload.answers[1].labels)
    end)

    it("cancels with Esc and reports no answers", function()
        local opened, calls = open(single)
        assert.is_true(opened)
        press("<Esc>")
        assert.equals(1, calls.done)
        assert.is_true(calls.payload.cancelled)
        assert.is_nil(calls.payload.answers)
    end)

    it("reports a hidden float instead of answering for the user", function()
        local opened, calls = open(single)
        assert.is_true(opened)
        -- Closing the window by any other route is not an answer: the caller
        -- re-queues the request so the backend keeps waiting.
        local win = vim.api.nvim_get_current_win()
        pcall(vim.api.nvim_win_close, win, true)
        vim.wait(20)
        assert.equals(0, calls.done)
        assert.equals(1, calls.hidden)
    end)

    it("toggles several options in a multi-select question", function()
        local opened, calls = open({
            {
                id = "q1",
                header = "Targets",
                question = "Which services?",
                multi = true,
                options = { { label = "api" }, { label = "worker" }, { label = "cron" } },
            },
        })
        assert.is_true(opened)
        press("<Space>")
        press("j")
        press("j")
        press("<Space>")
        assert.matches("■", buffer_text())
        press("<CR>")
        assert.equals(1, calls.done)
        assert.same({ 1, 3 }, calls.payload.answers[1].selected)
        assert.same({ "api", "cron" }, calls.payload.answers[1].labels)
    end)

    it("clears a multi-select answer with x", function()
        local opened, calls = open({
            {
                id = "q1",
                header = "Targets",
                question = "Which services?",
                multi = true,
                options = { { label = "api" }, { label = "worker" } },
            },
        })
        assert.is_true(opened)
        press("<Space>")
        press("x")
        press("<CR>")
        assert.equals(1, calls.done)
        -- x cleared the answer, so <CR> on the cursored row selects just it.
        assert.same({ "api" }, calls.payload.answers[1].labels)
    end)

    it("walks a multi-question ask through the review page and submits", function()
        local opened, calls = open({
            { id = "q1", header = "DB", question = "Which database?", options = { { label = "SQLite" } } },
            { id = "q2", header = "Dir", question = "Where?", options = { { label = "local" } } },
        })
        assert.is_true(opened)
        assert.matches("ask · 1/2", buffer_text())
        press("<CR>")
        -- Second question is showing now; h goes back to the first one.
        assert.matches("Where?", buffer_text())
        press("h")
        assert.matches("Which database?", buffer_text())
        press("l")
        press("<CR>")
        -- Last question answered: the review page is showing.
        assert.matches("Review", buffer_text())
        press("<CR>")
        assert.equals(1, calls.done)
        assert.equals(2, #calls.payload.answers)
        assert.same({ "SQLite" }, calls.payload.answers[1].labels)
        assert.same({ "local" }, calls.payload.answers[2].labels)
    end)

    it("takes the free-text answer and never mixes it with options", function()
        Dialog.input = function(_, callback)
            callback("custom-dir")
        end
        local opened, calls = open(single)
        assert.is_true(opened)
        press("j")
        press("i")
        assert.equals(1, calls.done)
        assert.equals("custom-dir", calls.payload.answers[1].custom)
        assert.same({}, calls.payload.answers[1].selected)
        assert.same({}, calls.payload.answers[1].labels)
        assert.is_true(calls.payload.answers[1].answered)
    end)

    it("answers a text-only question from the free-text row", function()
        Dialog.input = function(_, callback)
            callback("/srv/data")
        end
        local opened, calls = open({ { id = "q1", header = "Dir", question = "Which directory?" } })
        assert.is_true(opened)
        assert.matches("Type your own answer", buffer_text())
        press("i")
        assert.equals(1, calls.done)
        assert.equals("/srv/data", calls.payload.answers[1].custom)
    end)

    it("drops a free-text answer when an option is confirmed on a multi question", function()
        Dialog.input = function(_, callback)
            callback("typed-first")
        end
        local opened, calls = open({
            {
                id = "q1",
                header = "Targets",
                question = "Which services?",
                multi = true,
                options = { { label = "api" }, { label = "worker" } },
            },
            { id = "q2", header = "Dir", question = "Where?", options = { { label = "local" } } },
        })
        assert.is_true(opened)
        -- Free text answers q1 and advances; h walks back to it.
        press("i")
        assert.matches("Where?", buffer_text())
        press("h")
        -- Confirming an option on the multi-select question must drop the text:
        -- the wire format has no "an option plus some text" answer.
        press("<CR>")
        press("<CR>")
        -- Both questions answered: the review page is showing, submit it.
        press("<CR>")
        assert.equals(1, calls.done)
        assert.is_nil(calls.payload.answers[1].custom)
        assert.same({ "api" }, calls.payload.answers[1].labels)
    end)

    it("refuses a second concurrent ask", function()
        local first = Ask.open({ questions = single }, { on_done = function() end })
        assert.is_true(first)
        local second = Ask.open({ questions = single }, { on_done = function() end })
        assert.is_false(second)
    end)

    it("encodes the reply as JSON arrays for selected/labels", function()
        Dialog.input = function(_, callback)
            callback("typed")
        end
        local opened, calls = open(single)
        assert.is_true(opened)
        press("i")
        assert.equals(1, calls.done)
        local round_trip = vim.json.decode(vim.json.encode(calls.payload))
        assert.equals("table", type(round_trip.answers))
        assert.equals(1, #round_trip.answers)
        assert.equals(0, #round_trip.answers[1].selected)
        assert.equals(0, #round_trip.answers[1].labels)
        assert.equals("typed", round_trip.answers[1].custom)
    end)

    it("rejects duplicate question ids", function()
        local request, err = Ask.decode(
            '{"v":1,"questions":[{"id":"a","header":"h","question":"q?","options":[{"label":"x"},{"label":"y"}]},'
                .. '{"id":"a","header":"h2","question":"q2?","options":[{"label":"x"},{"label":"y"}]}]}'
        )
        assert.is_nil(request)
        assert.matches("duplicate", err)
    end)

    it("rejects malformed payloads with a reason", function()
        local request, err = Ask.decode(nil)
        assert.is_nil(request)
        assert.equals("missing payload", err)
        request, err = Ask.decode('{"v":1,"questions":[]}')
        assert.is_nil(request)
        assert.equals("no questions", err)
        request, err = Ask.decode('{"v":2,"questions":[{"id":"a","header":"h","question":"q?"}]}')
        assert.is_nil(request)
        assert.equals("unsupported version", err)
        request, err =
            Ask.decode('{"v":1,"questions":[{"id":"a","header":"h","question":"q?","options":[{"label":"x"}]}]}')
        assert.is_nil(request)
        assert.is_not_nil(err)
    end)

    it("normalizes a decoded request (header width, multi default)", function()
        local request = Ask.decode(
            '{"v":1,"questions":[{"id":"a","header":"a-very-long-header","question":"q?","options":[{"label":"x"},{"label":"y"}]}]}'
        )
        assert.is_not_nil(request)
        assert.is_true(vim.fn.strdisplaywidth(request.questions[1].header) <= 12)
        assert.is_false(request.questions[1].multi)
        assert.equals(2, #request.questions[1].options)
    end)
end)
