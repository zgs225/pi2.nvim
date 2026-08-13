-- Unit tests for pi.ui.diff_review (:PiDiff): pure diff parsing, hunk
-- line-number walking, config resolution, and float rendering.

local Config = require("pi.config")
local M = require("pi.ui.diff_review")

local SAMPLE = table.concat({
    "diff --git a/README.md b/README.md",
    "index 1234567..89abcde 100644",
    "--- a/README.md",
    "+++ b/README.md",
    "@@ -1,3 +1,4 @@",
    " # Title",
    "-old line",
    "+new line",
    " context line",
    "+",
    "diff --git a/lua/pi/init.lua b/lua/pi/init.lua",
    "new file mode 100644",
    "index 0000000..abcdef0",
    "--- /dev/null",
    "+++ b/lua/pi/init.lua",
    "@@ -0,0 +1,2 @@",
    "+local M = {}",
    "+return M",
    "diff --git a/gone.txt b/gone.txt",
    "deleted file mode 100644",
    "index abc..def 100644",
    "--- a/gone.txt",
    "+++ b/dev/null",
    "@@ -1,2 +0,0 @@",
    "-old one",
    "-old two",
    "",
}, "\n")

describe("diff_review parse_sections", function()
    it("splits output into per-file sections without the diff --git header", function()
        local sections = M.parse_sections(SAMPLE)
        assert.are.equal(3, #sections)

        local readme = sections[1]
        assert.are.equal("README.md", readme.path)
        assert.is_false(readme.deleted)
        assert.are.equal(vim.fn.fnamemodify("README.md", ":p"), readme.abs)
        assert.are.same({
            "index 1234567..89abcde 100644",
            "--- a/README.md",
            "+++ b/README.md",
            "@@ -1,3 +1,4 @@",
            " # Title",
            "-old line",
            "+new line",
            " context line",
            "+",
        }, readme.body)

        local new_file = sections[2]
        assert.are.equal("lua/pi/init.lua", new_file.path)
        assert.is_false(new_file.deleted)
        assert.are.equal("A", new_file.status)
        assert.are.equal("new file mode 100644", new_file.body[1])

        local gone = sections[3]
        assert.are.equal("gone.txt", gone.path)
        assert.is_true(gone.deleted)
        assert.are.equal("D", gone.status)
        assert.are.equal("@@ -1,2 +0,0 @@", gone.body[5])
        -- trailing empty line from the final newline is trimmed
        assert.are.equal("-old two", gone.body[#gone.body])

        -- the plain modified file keeps status M
        assert.are.equal("M", sections[1].status)
    end)

    it("handles a/dev/null (new file) and b/dev/null (deleted) paths", function()
        local new_output = table.concat({
            "diff --git a/dev/null b/added.txt",
            "new file mode 100644",
            "--- /dev/null",
            "+++ b/added.txt",
            "@@ -0,0 +1,1 @@",
            "+hello",
            "",
        }, "\n")
        local added = M.parse_sections(new_output)
        assert.are.equal(1, #added)
        assert.are.equal("added.txt", added[1].path)
        assert.is_false(added[1].deleted)

        local del_output = table.concat({
            "diff --git a/removed.txt b/removed.txt",
            "deleted file mode 100644",
            "--- a/removed.txt",
            "+++ b/dev/null",
            "@@ -1,1 +0,0 @@",
            "-bye",
            "",
        }, "\n")
        local removed = M.parse_sections(del_output)
        assert.are.equal("removed.txt", removed[1].path)
        assert.is_true(removed[1].deleted)
    end)

    it("returns no sections for empty output", function()
        assert.are.same({}, M.parse_sections(""))
    end)
end)

describe("diff_review compute_hunk_lines", function()
    it("walks context/add lines and keeps the deletion point on removed lines", function()
        local body = {
            "index 1234567..89abcde 100644",
            "--- a/README.md",
            "+++ b/README.md",
            "@@ -1,3 +1,4 @@",
            " # Title",
            "-old line",
            "+new line",
            " context line",
            "+",
        }
        local out = M.compute_hunk_lines(body)
        assert.is_nil(out[1]) -- before the first hunk: no target
        assert.is_nil(out[2])
        assert.is_nil(out[3])
        assert.are.equal(1, out[4]) -- hunk header -> hunk start
        assert.are.equal(1, out[5]) -- context "# Title" -> line 1
        assert.are.equal(2, out[6]) -- removed line -> deletion point (line 2)
        assert.are.equal(2, out[7]) -- added "+new line" -> line 2
        assert.are.equal(3, out[8]) -- context -> line 3
        assert.are.equal(4, out[9]) -- added "+" (blank) -> line 4
    end)

    it("maps a new file hunk starting at line 1", function()
        local out = M.compute_hunk_lines({
            "@@ -0,0 +1,2 @@",
            "+local M = {}",
            "+return M",
        })
        assert.are.equal(1, out[1])
        assert.are.equal(1, out[2])
        assert.are.equal(2, out[3])
    end)

    it("maps a deleted file hunk to line 0 (no jump targets built)", function()
        local out = M.compute_hunk_lines({
            "@@ -1,2 +0,0 @@",
            "-old one",
            "-old two",
        })
        assert.are.equal(0, out[1])
        assert.are.equal(0, out[2])
        assert.are.equal(0, out[3])
    end)

    it("keeps the counter on `\\ No newline` metadata lines", function()
        local out = M.compute_hunk_lines({
            "@@ -1,2 +1,2 @@",
            "-a",
            "+b",
            "\\ No newline at end of file",
            "+c",
        })
        assert.are.equal(1, out[1])
        assert.are.equal(1, out[2])
        assert.are.equal(1, out[3])
        assert.are.equal(2, out[4])
        assert.are.equal(2, out[5])
    end)
end)

describe("diff_review config", function()
    after_each(function()
        Config.setup({})
    end)

    it("defaults to 0.8 width/height with a rounded border", function()
        assert.are.equal(0.8, Config.options.diff_review.width)
        assert.are.equal(0.8, Config.options.diff_review.height)
        assert.are.equal("rounded", Config.options.diff_review.border)
        assert.are.equal("left", Config.options.diff_review.list.position)
        assert.are.equal(30, Config.options.diff_review.list.width)
    end)

    it("merges partial user config over the defaults", function()
        Config.setup({ diff_review = { width = 0.5, list = { position = "right", width = 40 } } })
        assert.are.equal(0.5, Config.options.diff_review.width)
        assert.are.equal(0.8, Config.options.diff_review.height)
        assert.are.equal("rounded", Config.options.diff_review.border)
        assert.are.equal("right", Config.options.diff_review.list.position)
        assert.are.equal(40, Config.options.diff_review.list.width)
    end)
end)

describe("diff_review render", function()
    after_each(function()
        M._reset()
    end)

    it("opens a side file list plus a float showing the first file", function()
        local sections = M.parse_sections(SAMPLE)
        M.render(sections)

        assert.is_true(M.is_open())
        -- the review is one panel: an outer container float framing two
        -- borderless inner floats (file list left, diff right)
        local shell_win = assert(M._shell_win())
        local shell_cfg = vim.api.nvim_win_get_config(shell_win)
        assert.are.equal("editor", shell_cfg.relative)
        assert.are.equal(8, #shell_cfg.border) -- rounded border, expanded
        assert.is_true(vim.wo[shell_win].winfixbuf)

        -- focus stays in the file list float
        local list_win = vim.api.nvim_get_current_win()
        local list_buf = vim.api.nvim_win_get_buf(list_win)
        assert.are.equal("pi-diff-review", vim.bo[list_buf].filetype)
        assert.are.equal("nofile", vim.bo[list_buf].buftype)
        assert.is_true(vim.wo[list_win].winfixbuf)

        local float_win = assert(M._float_win())
        -- the container must sit below the inner floats: a focusable=false
        -- float draws above focusable=true floats with the same zindex and
        -- would hide the diff float (issue #16 follow-up)
        assert.is_true(shell_cfg.zindex < vim.api.nvim_win_get_config(list_win).zindex)
        assert.is_true(shell_cfg.zindex < vim.api.nvim_win_get_config(float_win).zindex)
        for _, w in ipairs({ list_win, float_win }) do
            local cfg = vim.api.nvim_win_get_config(w)
            assert.are.equal("editor", cfg.relative)
            assert.are.equal("none", cfg.border)
            -- inner floats sit inside the container bounds
            assert.is_true(cfg.col > shell_cfg.col and cfg.col + cfg.width <= shell_cfg.col + shell_cfg.width)
            assert.is_true(cfg.row > shell_cfg.row and cfg.row + cfg.height <= shell_cfg.row + shell_cfg.height)
        end

        local list_lines = vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)
        assert.matches("3 files", list_lines[1])
        assert.are.equal("M README.md", list_lines[2])
        assert.are.equal("A lua/pi/init.lua", list_lines[3])
        assert.are.equal("D gone.txt", list_lines[4])

        -- the float shows the first file's diff
        local float_win = assert(M._float_win())
        local b = vim.api.nvim_win_get_buf(float_win)
        assert.are.equal("diff", vim.bo[b].filetype)
        assert.are.equal("nofile", vim.bo[b].buftype)
        assert.is_true(vim.wo[float_win].winfixbuf)
        assert.are.equal(1, M._current_idx())

        local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        assert.is_true(vim.startswith(lines[1], "── README.md"))
        assert.is_true(vim.startswith(lines[2], "index 1234567"))

        -- header jumps to line 1; "-old line" (buffer line 7) keeps the deletion point
        local targets = M._targets()
        assert.are.same({ path = vim.fn.fnamemodify("README.md", ":p"), line = 1 }, targets[1])
        assert.are.same({ path = vim.fn.fnamemodify("README.md", ":p"), line = 2 }, targets[7])
        -- the blank added line (buffer line 10) -> new-file line 4
        assert.are.same({ path = vim.fn.fnamemodify("README.md", ":p"), line = 4 }, targets[10])
    end)

    it("switches the float to the selected file", function()
        M.render(M.parse_sections(SAMPLE))
        M._show_file(2)
        assert.are.equal(2, M._current_idx())
        local float_win = assert(M._float_win())
        local b = vim.api.nvim_win_get_buf(float_win)
        local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        assert.is_true(vim.startswith(lines[1], "── lua/pi/init.lua"))
        -- the first added line (buffer line 7) -> new-file line 1
        assert.are.same({ path = vim.fn.fnamemodify("lua/pi/init.lua", ":p"), line = 1 }, M._targets()[7])

        -- a deleted file shows only the header, with no jump targets
        M._show_file(3)
        assert.are.equal(3, M._current_idx())
        local gone_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        assert.is_true(vim.startswith(gone_lines[1], "── gone.txt"))
        assert.are.same({}, M._targets())
    end)

    it("is closed by M.close and M._reset", function()
        M.render(M.parse_sections(SAMPLE))
        M.close()
        assert.is_false(M.is_open())
        assert.is_nil(M._float_win())
        assert.are.same({}, M._targets())
        M.render(M.parse_sections(SAMPLE))
        M._reset()
        assert.is_false(M.is_open())
    end)

    it("scrolls the diff float from the file list, keeping focus there", function()
        -- a diff much longer than the float height
        local body = {}
        for i = 1, 200 do
            body[#body + 1] = "+line " .. i
        end
        M.render({
            {
                path = "big.txt",
                abs = vim.fn.fnamemodify("big.txt", ":p"),
                deleted = false,
                status = "M",
                body = body,
            },
        })

        local float_win = assert(M._float_win())
        local function viewport_top()
            return vim.api.nvim_win_call(float_win, function()
                return vim.fn.line("w0")
            end)
        end

        assert.are.equal(1, viewport_top())
        M._scroll_diff("<C-f>")
        assert.is_true(viewport_top() > 1, "<C-f> should scroll the diff float down")
        local scrolled = viewport_top()
        M._scroll_diff("<C-b>")
        assert.is_true(viewport_top() < scrolled, "<C-b> should scroll the diff float back up")

        -- focus stays in the file list
        local cur = vim.api.nvim_get_current_win()
        assert.are.equal("pi-diff-review", vim.bo[vim.api.nvim_win_get_buf(cur)].filetype)

        -- the paging keymap on the list buffer really scrolls the float
        M._scroll_diff("<C-b>")
        local top = viewport_top()
        vim.api.nvim_feedkeys(vim.keycode("<C-f>"), "x", false)
        vim.wait(200, function()
            return viewport_top() > top
        end, 10)
        assert.is_true(viewport_top() > top, "<C-f> keymap should scroll the diff float")
        assert.are.equal("pi-diff-review", vim.bo[vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())].filetype)
    end)
end)

describe("diff_review group list layout", function()
    after_each(function()
        M._reset()
    end)

    it("renders group headers, maps rows, and branch-prefixes the float header", function()
        local sections = M.parse_sections(SAMPLE)
        sections[1].toplevel = "/home/user/repo"
        sections[2].toplevel = "/home/user/repo"
        sections[3].toplevel = "/home/user/repo-feat"
        local groups = {
            {
                toplevel = "/home/user/repo",
                branch = "main",
                rel_files = {},
                abs_files = {},
                sections = { 1, 2 },
            },
            {
                toplevel = "/home/user/repo-feat",
                branch = "feat-x",
                rel_files = {},
                abs_files = {},
                sections = { 3 },
            },
        }
        M.render(sections, { groups = groups })

        local list_win = vim.api.nvim_get_current_win()
        local list_buf = vim.api.nvim_win_get_buf(list_win)
        local lines = vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)
        assert.matches("3 files", lines[1])
        assert.matches("2 worktrees", lines[1])
        assert.are.equal("main · " .. vim.fn.fnamemodify("/home/user/repo", ":~"), lines[2])
        assert.are.equal("M README.md", lines[3])
        assert.are.equal("A lua/pi/init.lua", lines[4])
        assert.are.equal("feat-x · " .. vim.fn.fnamemodify("/home/user/repo-feat", ":~"), lines[5])
        assert.are.equal("D gone.txt", lines[6])

        -- header rows map to their group's first section
        local map = M._row_entries()
        assert.are.same({ group = 1, section = 1 }, map[2])
        assert.are.same({ group = 1, section = 2 }, map[4])
        assert.are.same({ group = 2, section = 3 }, map[5])
        assert.are.same({ group = 2, section = 3 }, map[6])

        -- moving the cursor onto a header shows the group's first file
        vim.api.nvim_win_set_cursor(list_win, { 5, 0 })
        M._on_list_cursor_moved()
        assert.are.equal(3, M._current_idx())

        -- the diff float header carries the branch prefix
        local float_win = assert(M._float_win())
        local b = vim.api.nvim_win_get_buf(float_win)
        local float_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
        assert.is_true(vim.startswith(float_lines[1], "── feat-x · gone.txt"))
    end)

    it("keeps the flat layout without groups", function()
        M.render(M.parse_sections(SAMPLE))
        local list_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
        local lines = vim.api.nvim_buf_get_lines(list_buf, 0, -1, false)
        assert.are.equal("M README.md", lines[2])
        assert.is_false(vim.startswith(lines[2], "·"))
        -- no worktree count in the hint for a flat list
        assert.is_false(vim.startswith(lines[1], "─ 2 worktrees"))
        -- every section row maps to a section; there are no header rows
        local map = M._row_entries()
        assert.are.equal(3, #vim.tbl_keys(map))
        assert.are.same({ group = 1, section = 3 }, map[4])
    end)
end)

describe("diff_review collection", function()
    local cleanup_dirs = {}

    after_each(function()
        for _, dir in ipairs(cleanup_dirs) do
            pcall(vim.fn.delete, dir, "rf")
        end
        cleanup_dirs = {}
        M._reset()
    end)

    ---@return string resolved tmp dir
    local function tmp_dir()
        local dir = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(dir, "p")
        cleanup_dirs[#cleanup_dirs + 1] = dir
        return dir
    end

    local function git(dir, ...)
        return vim.fn.system({ "git", "-C", dir, ... })
    end

    ---@param dir string
    ---@return string
    local function init_repo(dir, branch)
        vim.fn.mkdir(dir, "p")
        git(dir, "init", "-q", "-b", branch)
        git(dir, "config", "user.email", "t@t")
        git(dir, "config", "user.name", "t")
        return dir
    end

    ---@param files string[]
    ---@param cwd string
    local function collect_async(files, cwd)
        local result = nil
        M._collect(files, cwd, function(sections, groups, outside)
            result = { sections = sections, groups = groups, outside = outside }
        end)
        assert.is_true(
            vim.wait(10000, function()
                return result ~= nil
            end, 20),
            "collection timed out"
        )
        return result
    end

    it("shows staged changes via git diff HEAD", function()
        local dir = init_repo(tmp_dir(), "main")
        vim.fn.writefile({ "v1" }, dir .. "/a.txt")
        git(dir, "add", "a.txt")
        git(dir, "commit", "-qm", "one")
        vim.fn.writefile({ "v2" }, dir .. "/a.txt")
        git(dir, "add", "a.txt")

        local r = collect_async({ "a.txt" }, dir)
        assert.are.equal(1, #r.sections)
        assert.are.equal("M", r.sections[1].status)
        assert.are.equal("a.txt", r.sections[1].path)
        assert.are.equal("a.txt", vim.fn.fnamemodify(r.sections[1].abs, ":t"))
        assert.are.equal(dir, r.groups[1].toplevel)
        assert.are.equal("main", r.groups[1].branch)
        assert.are.equal(0, r.outside)
    end)

    it("shows untracked files as full-file additions", function()
        local dir = init_repo(tmp_dir(), "main")
        vim.fn.writefile({ "u" }, dir .. "/new.txt")

        local r = collect_async({ "new.txt" }, dir)
        assert.are.equal(1, #r.sections)
        assert.are.equal("A", r.sections[1].status)
        assert.are.equal("new.txt", r.sections[1].path)
    end)

    it("skips committed changes (documented gap: no pre-change blob)", function()
        local dir = init_repo(tmp_dir(), "main")
        vim.fn.writefile({ "v1" }, dir .. "/a.txt")
        git(dir, "add", "a.txt")
        git(dir, "commit", "-qm", "one")
        vim.fn.writefile({ "v2" }, dir .. "/a.txt")
        git(dir, "add", "a.txt")
        git(dir, "commit", "-qm", "two")

        local r = collect_async({ "a.txt" }, dir)
        assert.are.equal(0, #r.sections)
        assert.are.equal(0, r.outside)
    end)

    it("handles a fresh repository without HEAD via --cached", function()
        local dir = init_repo(tmp_dir(), "main")
        vim.fn.writefile({ "s" }, dir .. "/staged.txt")
        git(dir, "add", "staged.txt")

        local r = collect_async({ "staged.txt" }, dir)
        assert.are.equal(1, #r.sections)
        assert.are.equal("A", r.sections[1].status)
        assert.are.equal("staged.txt", r.sections[1].path)
    end)

    it("groups files by work tree with the session cwd's group first", function()
        local dir_a = init_repo(tmp_dir(), "main")
        vim.fn.writefile({ "a" }, dir_a .. "/a.txt")
        local dir_b = init_repo(tmp_dir(), "feat-b")
        vim.fn.writefile({ "b" }, dir_b .. "/b.txt")

        -- session cwd inside repo A; one file in each repo
        local r = collect_async({ "a.txt", dir_b .. "/b.txt" }, dir_a)
        assert.are.equal(2, #r.groups)
        -- session cwd's group first even though dir_b < dir_a alphabetically
        assert.are.equal(dir_a, r.groups[1].toplevel)
        assert.are.equal("main", r.groups[1].branch)
        assert.are.equal(dir_b, r.groups[2].toplevel)
        assert.are.equal("feat-b", r.groups[2].branch)
        assert.are.equal(2, #r.sections)
        assert.are.equal("a.txt", r.sections[1].path)
        assert.are.equal(dir_a, r.sections[1].toplevel)
        assert.are.equal("b.txt", r.sections[2].path)
        assert.are.equal(dir_b, r.sections[2].toplevel)
    end)

    it("counts files outside any work tree as skipped", function()
        local dir = tmp_dir() -- no git repo here
        vim.fn.writefile({ "x" }, dir .. "/x.txt")

        local r = collect_async({ "x.txt" }, dir)
        assert.are.equal(0, #r.sections)
        assert.are.equal(1, r.outside)
    end)
end)
