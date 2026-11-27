-- pi.ui.chat.mentions `display` — the reverse of `expand`, used when a user
-- message is rendered in the history.
--
-- `expand` rewrites `@path` into pi's own syntax before sending, and pi stores
-- the EXPANDED text in the session transcript. A live message reaches the
-- history as authored; a replayed one (resume, compaction rebuild) carries the
-- expansion, which used to show up as `[directory: legado-server/]` in the
-- middle of the user's sentence. These pin both halves: the pure transform and
-- what the rendered history actually shows (including fenced code, which is
-- left verbatim).

describe("mention display", function()
    local Mentions = require("pi.ui.chat.mentions")

    describe("display", function()
        it("renders a directory expansion as the authored mention", function()
            assert.are.equal(
                "我需要彻底移除 @legado-server/ 的部署",
                Mentions.display("我需要彻底移除 [directory: legado-server/] 的部署")
            )
        end)

        it("renders a file expansion as the authored mention", function()
            assert.are.equal("look at @lua/pi/init.lua", Mentions.display("look at [file: lua/pi/init.lua]"))
        end)

        it("keeps a line range", function()
            assert.are.equal("@lua/a.lua#L12", Mentions.display("[file: lua/a.lua, line: 12]"))
            assert.are.equal("@lua/a.lua#L3-5", Mentions.display("[file: lua/a.lua, lines: 3-5]"))
        end)

        it("rewrites every mention in a line", function()
            assert.are.equal("@a.lua and @b/", Mentions.display("[file: a.lua] and [directory: b/]"))
        end)

        it("leaves an authored mention alone", function()
            assert.are.equal(
                "@lua/a.lua#L3-5 和 @legado-server/",
                Mentions.display("@lua/a.lua#L3-5 和 @legado-server/")
            )
        end)

        it("leaves prose brackets alone", function()
            for _, text in ipairs({
                "[foo: bar]",
                "[file: unterminated",
                "a [link](https://example.com) and [brackets]",
                "see #L3",
                "",
            }) do
                assert.are.equal(text, Mentions.display(text))
            end
        end)

        it("does not invent a mention from an empty path", function()
            assert.are.equal("[file: ]", Mentions.display("[file: ]"))
            assert.are.equal("[directory: ]", Mentions.display("[directory: ]"))
        end)

        it("does not cross a newline to find the closing bracket", function()
            assert.are.equal("[file: a\nb]", Mentions.display("[file: a\nb]"))
        end)

        it("is idempotent", function()
            local once = Mentions.display("[directory: legado-server/]")
            assert.are.equal(once, Mentions.display(once))
        end)
    end)

    describe("history render", function()
        local Config = require("pi.config")
        local History = require("pi.ui.chat.history")
        local TAB = 1351
        local history, win

        before_each(function()
            Config.options.user_message_align = "left"
        end)

        after_each(function()
            if win and vim.api.nvim_win_is_valid(win) then
                pcall(vim.api.nvim_win_close, win, true)
            end
            if history then
                pcall(vim.api.nvim_buf_delete, history:buf(), { force = true })
            end
            history, win = nil, nil
        end)

        --- Render one user message and return its body rows plus the copied text.
        ---@param msg string
        ---@return string[] body
        ---@return string? copied
        local function render(msg)
            history = History.new(TAB)
            win = vim.api.nvim_open_win(history:buf(), true, {
                relative = "editor",
                row = 1,
                col = 1,
                width = 80,
                height = 16,
                style = "minimal",
            })
            history:set_win(win)
            vim.wait(30)
            history:add_user_message(msg, nil)
            vim.wait(120)

            local icon = Config.options.labels.user_message
            local lines = vim.api.nvim_buf_get_lines(history:buf(), 0, -1, false)
            local label_row ---@type integer?
            for i, line in ipairs(lines) do
                if vim.startswith(vim.trim(line), icon) then
                    label_row = i - 1
                    break
                end
            end
            local body = {}
            if label_row then
                local j = label_row + 3 -- label row, one blank, then the body
                while lines[j] and vim.trim(lines[j]) ~= "" do
                    body[#body + 1] = lines[j]
                    j = j + 1
                end
            end
            local target = label_row and history:copy_target_at(label_row) or nil
            return body, target and target.text or nil
        end

        it("shows a replayed message as the authored mention", function()
            local body, copied = render("我需要彻底移除 [directory: legado-server/] 的部署")
            assert.are.equal("我需要彻底移除 @legado-server/ 的部署", vim.trim(body[1] or ""))
            assert.are.equal("我需要彻底移除 @legado-server/ 的部署", copied, "gy copies the authored form")
        end)

        it("shows a replayed file range as the authored mention", function()
            local body, copied = render("check [file: lua/a.lua, lines: 3-5] please")
            assert.are.equal("check @lua/a.lua#L3-5 please", vim.trim(body[1] or ""))
            assert.are.equal("check @lua/a.lua#L3-5 please", copied)
        end)

        it("leaves a fenced code block verbatim", function()
            local msg = "expand this:\n```\n[file: lua/a.lua]\n```\nafter"
            local body = render(msg)
            assert.are.equal("expand this:", vim.trim(body[1] or ""))
            assert.are.equal("```", vim.trim(body[2] or ""))
            assert.are.equal("[file: lua/a.lua]", vim.trim(body[3] or ""), "code keeps pi's syntax")
            assert.are.equal("```", vim.trim(body[4] or ""))
            assert.are.equal("after", vim.trim(body[5] or ""))
        end)
    end)
end)
