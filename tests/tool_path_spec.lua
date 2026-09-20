-- Display shortening for the file paths tool blocks print (read/edit/write).
--
-- Models commonly emit absolute paths (`/home/u/proj/apps/web/src/Foo.vue`);
-- the workspace prefix carries no information. `pi.path` strips it, and the
-- inline `read` line shows the file name only. This spec pins both the helper
-- and the rendering, plus the guarantee that `gf` still resolves the real file
-- when the rendered text is shortened.

local Path = require("pi.path")
local Config = require("pi.config")
local Render = require("pi.ui.render")
local History = require("pi.ui.chat.history")
local Tools = require("pi.ui.chat.tools")
local Ft = require("pi.filetypes")

local TAB = 917

local function pump(ms)
    vim.wait(ms or 50)
end

---@param buf integer
---@return string[]
local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- 1-indexed row of the first line containing `sub`, or nil.
---@param buf integer
---@param sub string
---@return integer?
local function row_with(buf, sub)
    for i, l in ipairs(lines_of(buf)) do
        if l:find(sub, 1, true) then
            return i
        end
    end
    return nil
end

--- Byte range of the first extmark with `hl_group` on `row` (0-indexed).
---@param h pi.ChatHistory
---@param row integer
---@param hl_group string
---@return { start_col: integer, end_col: integer }?
local function hl_range(h, row, hl_group)
    local ems = vim.api.nvim_buf_get_extmarks(h:buf(), h:ns(), { row, 0 }, { row, -1 }, { details = true })
    for _, em in ipairs(ems) do
        local d = em[4] or {}
        if d.hl_group == hl_group then
            return { start_col = em[3], end_col = d.end_col }
        end
    end
    return nil
end

describe("pi.path", function()
    local base = "/home/u/proj"

    it("keeps a path that is already relative to the base", function()
        assert.are.equal("apps/web/src/Foo.vue", Path.display("apps/web/src/Foo.vue", { base = base }))
    end)

    it("strips the base prefix from an absolute path", function()
        assert.are.equal("apps/web/src/Foo.vue", Path.display(base .. "/apps/web/src/Foo.vue", { base = base }))
    end)

    it("strips a trailing slash from the base", function()
        assert.are.equal("src/Foo.vue", Path.display(base .. "/src/Foo.vue", { base = base .. "/" }))
    end)

    it("anchors a path outside the base to $HOME", function()
        -- Neovim resolves `~` from its startup $HOME, so build the case from the
        -- real home rather than overriding the env var mid-test.
        local home = Path.resolve("~", nil)
        local got = Path.display(home .. "/.pi/agent/sessions/x.jsonl", { base = home .. "/work" })
        assert.are.equal("~/.pi/agent/sessions/x.jsonl", got)
    end)

    it("leaves a path outside base and home absolute", function()
        local home = Path.resolve("~", nil)
        local got = Path.display("/var/tmp/pi/out.txt", { base = home .. "/work" })
        assert.are.equal("/var/tmp/pi/out.txt", got)
    end)

    it("collapses to the file name in basename mode", function()
        assert.are.equal("Foo.vue", Path.display(base .. "/apps/web/src/Foo.vue", { base = base, basename = true }))
        assert.are.equal("x.jsonl", Path.display("~/.pi/x.jsonl", { base = base, basename = true }))
    end)

    it("resolves relative paths against the base, not the process cwd", function()
        assert.are.equal(base .. "/src/Foo.vue", Path.resolve("src/Foo.vue", base))
        assert.are.equal(base .. "/src/Foo.vue", Path.resolve(base .. "/./src/Foo.vue", nil))
    end)

    it("ignores the base for absolute and ~ paths", function()
        assert.are.equal("/etc/hosts", Path.resolve("/etc/hosts", base))
        assert.are.equal(vim.fn.fnamemodify("~/.pi", ":p"):gsub("/$", ""), Path.resolve("~/.pi", base))
    end)
end)

describe("collapsed path lines", function()
    local saved_render

    before_each(function()
        -- The builtin engine keeps the collapsed line verbatim; the
        -- render-markdown engine wraps it in display-only code fences.
        saved_render = Config.options.render
        Config.options.render = { engine = "builtin" }
        Render._reset()
    end)

    after_each(function()
        Config.options.render = saved_render
        Render._reset()
    end)

    it("keeps the file name when the line overflows the width", function()
        local long = "apps/web-antd/src/views/resource-center/report-metrics/components/ReportMetricsFormDrawer.vue"
        local lines = Tools.build_collapsed_view({ long }, {}, false, 1, 0, 60)
        assert.are.equal(1, #lines)
        assert.is_truthy(lines[1]:find("ReportMetricsFormDrawer.vue", 1, true))
        assert.is_truthy(lines[1]:find("…", 1, true))
        assert.is_true(vim.fn.strdisplaywidth(lines[1]) <= 60)
    end)

    it("truncates on character boundaries in a multi-byte line", function()
        local long = "/数据/报告/一二三四五六七八九十/最终报告文件.vue"
        local lines = Tools.build_collapsed_view({ long }, {}, false, 1, 0, 20)
        local head, tail = lines[1]:match("^(.*)…(.*)$")
        assert.is_not_nil(head, "expected an elided line")
        assert.is_true(#head > 0 and #tail > 0, "both ends must survive")
        assert.is_true(vim.fn.strdisplaywidth(lines[1]) <= 20)
        assert.is_truthy(long:sub(1, #head) == head)
        assert.is_truthy(long:sub(-#tail) == tail)
    end)
end)

describe("tool path rendering", function()
    local dir
    local target
    local base_wins

    before_each(function()
        base_wins = vim.api.nvim_list_wins()
        dir = vim.fn.tempname()
        target = dir .. "/lua/pi/tools.lua"
        vim.fn.mkdir(vim.fn.fnamemodify(target, ":h"), "p")
        vim.fn.writefile({ "local x = 1" }, target)
    end)

    after_each(function()
        for _, w in ipairs(vim.api.nvim_list_wins()) do
            if not vim.tbl_contains(base_wins, w) then
                pcall(vim.api.nvim_win_close, w, true)
            end
        end
    end)

    it("read renders the file name only", function()
        local h = History.new(TAB)
        h:set_cwd(dir)
        h:on_tool_start("read", "r1", { path = target })
        pump()

        local row = row_with(h:buf(), "tools.lua")
        assert.is_not_nil(row, "expected the read line to name the file")
        assert.is_nil(row_with(h:buf(), dir), "the workspace prefix must not be rendered")
    end)

    it("edit renders the path relative to the session cwd", function()
        local h = History.new(TAB)
        h._blocks_expanded = true
        h:set_cwd(dir)
        h:on_tool_start(
            "edit",
            "e1",
            { path = target, edits = { { oldText = "local x = 1", newText = "local x = 2" } } }
        )
        pump()
        h:on_tool_end("edit", "e1", { content = { { type = "text", text = "[accepted]" } } }, false)
        pump()

        local row = row_with(h:buf(), "lua/pi/tools.lua")
        assert.is_not_nil(row, "expected the edit body line to be workspace-relative")
        assert.is_nil(row_with(h:buf(), dir), "the workspace prefix must not be rendered")
        -- The diff still reads the real file: oldText was located, so line
        -- numbers are rendered (a failed lookup falls back to no numbers).
        assert.is_not_nil(row_with(h:buf(), "- local x = 1"))
    end)

    it("write renders the path relative to the session cwd", function()
        local h = History.new(TAB)
        h:set_cwd(dir)
        h:on_tool_start("write", "w1", { path = target, content = "local x = 2\n" })
        pump()

        assert.is_not_nil(row_with(h:buf(), "lua/pi/tools.lua"))
        assert.is_nil(row_with(h:buf(), dir))
    end)

    it("read highlights the shortened detail over its exact byte range", function()
        -- The path is multi-byte but extmark columns are byte offsets: a range
        -- computed from display cells would drift past the detail text.
        local h = History.new(TAB)
        h:set_cwd(dir)
        h:on_tool_start("read", "r3", { path = dir .. "/报告/Foo.vue" })
        pump()

        local row = row_with(h:buf(), "Foo.vue") - 1
        local line = lines_of(h:buf())[row + 1]
        local range = hl_range(h, row, "PiToolCall")
        assert.is_not_nil(range)
        assert.are.equal(line:find("Foo.vue", 1, true) - 1, range.start_col)
        assert.are.equal(#line, range.end_col)
    end)

    it("opens the real file from a read block rendered as a bare file name", function()
        local h = History.new(TAB)
        h:set_cwd(dir)
        h:on_tool_start("read", "r2", { path = target })
        pump()

        -- Mimic the layout: the history window is winfixbuf-pinned, so the
        -- file opens in a separate editor window.
        vim.cmd("topleft vsplit")
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, h:buf())
        vim.wo[win].winfixbuf = true
        h:set_win(win)

        local row = row_with(h:buf(), "tools.lua")
        assert.is_not_nil(row)
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { row, 0 })

        assert.is_true(h:goto_path_at_cursor())
        assert.are.equal(vim.fn.resolve(target), vim.fn.resolve(vim.api.nvim_buf_get_name(0)))
        assert.are.equal(Ft.history, vim.bo[h:buf()].filetype)
    end)

    it("resolves a workspace-relative line against the session cwd", function()
        local h = History.new(TAB)
        h:set_cwd(dir)
        vim.bo[h:buf()].modifiable = true
        vim.api.nvim_buf_set_lines(h:buf(), 0, -1, false, { "lua/pi/tools.lua" })
        vim.bo[h:buf()].modifiable = false

        vim.cmd("topleft vsplit")
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, h:buf())
        vim.wo[win].winfixbuf = true
        h:set_win(win)
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { 1, 0 })

        assert.is_true(h:goto_path_at_cursor())
        assert.are.equal(vim.fn.resolve(target), vim.fn.resolve(vim.api.nvim_buf_get_name(0)))
    end)
end)
