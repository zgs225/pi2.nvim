-- Regression tests for the pre-execution diff review's teardown (`pi.ui.diff`).
--
-- Accepting the review (`:w` on the proposed buffer triggers `BufWriteCmd` ->
-- `accept()`) must:
--   1. deliver the RPC result callback *before* the review UI is torn down, so
--      a cleanup error can never leave the backend blocked in ctx.ui.select();
--   2. not raise E784 when the review tab is the only tab ("E784: Cannot close
--      last window").

local Diff = require("pi.ui.diff")

---@return string temp dir created for one test
local function tmp_dir()
    local dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    return dir
end

--- Close every tabpage except `keep` (nil: leave exactly one tab open).
---@param keep integer?
local function only_tab(keep)
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if tab ~= keep and vim.api.nvim_tabpage_is_valid(tab) then
            vim.api.nvim_set_current_tabpage(tab)
            -- the last remaining tab cannot be closed (E784); pcall keeps the
            -- teardown helper usable when there is nothing left to close
            pcall(vim.cmd, "tabclose")
        end
    end
    if keep and vim.api.nvim_tabpage_is_valid(keep) then
        vim.api.nvim_set_current_tabpage(keep)
    end
end

--- Open a diff review for a `write` tool call.
---@param path string
---@param content string
---@param callback fun(result: string)
---@param opts? { timeout?: integer, on_timeout?: fun() }
---@return integer review_tab
local function open_review(path, content, callback, opts)
    vim.fn.writefile({ "old line" }, path)
    Diff.open({
        prompt = "write " .. path,
        toolName = "write",
        toolInput = { path = path, content = content },
    }, callback, opts)
    return vim.api.nvim_get_current_tabpage()
end

--- Accept the review by writing the proposed buffer, like the user pressing
--- the accept keymap from the review window.
---@param path string
local function accept_via_write(path)
    local after_buf = vim.fn.bufnr("pi://review" .. path)
    assert.is_true(after_buf > 0, "proposed buffer pi://review" .. path .. " not found")
    local wins = vim.fn.win_findbuf(after_buf)
    assert.is_true(#wins > 0, "proposed buffer must be displayed in the review tab")
    vim.api.nvim_set_current_win(wins[1])
    vim.cmd("write")
end

--- The buffer-local keymap bound to `desc` in the proposed buffer.
---@param buf integer
---@param desc string
---@return string?
local function mapped_lhs(buf, desc)
    for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if item.desc == desc then
            return item.lhs
        end
    end
    return nil
end

describe("diff review close", function()
    local tmpdirs = {}

    after_each(function()
        only_tab(nil)
        for _, dir in ipairs(tmpdirs) do
            pcall(vim.fn.delete, dir, "rf")
        end
        tmpdirs = {}
    end)

    it("delivers the RPC callback before tearing the review UI down", function()
        local dir = tmp_dir()
        tmpdirs[#tmpdirs + 1] = dir
        local path = dir .. "/reviewed.txt"

        local tabs_before = #vim.api.nvim_list_tabpages()
        local result = nil ---@type string?
        local after_buf = nil ---@type integer?
        local buf_live_at_callback = nil ---@type boolean?
        local tab_valid_at_callback = nil ---@type boolean?

        local review_tab
        review_tab = open_review(path, "new line\n", function(res)
            result = res
            buf_live_at_callback = after_buf ~= nil and vim.api.nvim_buf_is_valid(after_buf)
            tab_valid_at_callback = vim.api.nvim_tabpage_is_valid(review_tab)
        end)
        after_buf = vim.fn.bufnr("pi://review" .. path)

        assert.are.equal(tabs_before + 1, #vim.api.nvim_list_tabpages())
        accept_via_write(path)

        assert.is_truthy(result, "the RPC callback must have been invoked")
        local decoded = vim.json.decode(result --[[@as string]])
        assert.are.equal("Accepted", decoded.result)
        assert.is_true(buf_live_at_callback, "callback must run before the proposed buffer is deleted")
        assert.is_true(tab_valid_at_callback, "callback must run before the review tab is closed")
        assert.are.same({ "new line" }, vim.fn.readfile(path))

        -- cleanup really happened after the callback
        assert.is_false(vim.api.nvim_tabpage_is_valid(review_tab))
        assert.are.equal(tabs_before, #vim.api.nvim_list_tabpages())
        assert.is_false(vim.api.nvim_buf_is_valid(after_buf --[[@as integer]]))
    end)

    it("accepts without E784 when the review tab is the only tab", function()
        local dir = tmp_dir()
        tmpdirs[#tmpdirs + 1] = dir
        local path = dir .. "/only-tab.txt"

        local result = nil ---@type string?
        local after_buf = nil ---@type integer?
        local order = {} ---@type string[]

        local review_tab
        review_tab = open_review(path, "only tab content\n", function(res)
            result = res
            order[#order + 1] = "callback"
            order[#order + 1] = (after_buf ~= nil and vim.api.nvim_buf_is_valid(after_buf)) and "buf-alive"
                or "buf-gone"
        end)
        after_buf = vim.fn.bufnr("pi://review" .. path)

        -- E784 repro: make the review tab the last remaining tab, so the
        -- guarded `tabclose` in close_review_tab must be skipped entirely.
        only_tab(review_tab)
        assert.are.equal(1, #vim.api.nvim_list_tabpages())

        local ok, err = pcall(accept_via_write, path)
        assert.is_true(ok, "accept must not raise: " .. tostring(err))

        assert.is_truthy(result, "the RPC callback must have been invoked")
        assert.are.same({ "callback", "buf-alive" }, order)
        assert.are.same({ "only tab content" }, vim.fn.readfile(path))

        -- the review tab cannot be closed; teardown must leave it healthy
        assert.are.equal(1, #vim.api.nvim_list_tabpages())
        assert.is_true(vim.api.nvim_tabpage_is_valid(review_tab))

        -- let the deferred `diffthis` fixup (200 ms) run against the torn-down
        -- review: it must bail out instead of raising on dead windows
        vim.wait(400)
        assert.is_true(vim.api.nvim_tabpage_is_valid(review_tab))
        assert.are.equal(1, #vim.api.nvim_list_tabpages())
    end)

    it("delivers the reject callback before tearing the review UI down", function()
        local dir = tmp_dir()
        tmpdirs[#tmpdirs + 1] = dir
        local path = dir .. "/rejected.txt"

        local result = nil ---@type string?
        local after_buf = nil ---@type integer?
        local buf_live_at_callback = nil ---@type boolean?

        local review_tab
        review_tab = open_review(path, "not wanted\n", function(res)
            result = res
            buf_live_at_callback = after_buf ~= nil and vim.api.nvim_buf_is_valid(after_buf)
        end)
        after_buf = vim.fn.bufnr("pi://review" .. path)

        local lhs = mapped_lhs(after_buf, "Reject edit")
        assert.is_truthy(lhs, "the reject keymap must be bound in the proposed buffer")
        vim.api.nvim_set_current_win(vim.fn.win_findbuf(after_buf)[1])
        vim.api.nvim_feedkeys(lhs --[[@as string]], "x", false)

        assert.are.equal("Reject", result)
        assert.is_true(buf_live_at_callback, "callback must run before the proposed buffer is deleted")
        assert.are.same({ "old line" }, vim.fn.readfile(path))
        -- cleanup still happened afterwards
        assert.is_false(vim.api.nvim_tabpage_is_valid(review_tab))
    end)

    it("runs the timeout handler before tearing the review UI down", function()
        local dir = tmp_dir()
        tmpdirs[#tmpdirs + 1] = dir
        local path = dir .. "/timeout.txt"

        local after_buf = nil ---@type integer?
        local observed = nil ---@type { tab_valid: boolean, buf_live: boolean }?

        local review_tab
        review_tab = open_review(path, "timed out\n", function() end, {
            timeout = 50,
            on_timeout = function()
                observed = {
                    tab_valid = vim.api.nvim_tabpage_is_valid(review_tab),
                    buf_live = after_buf ~= nil and vim.api.nvim_buf_is_valid(after_buf),
                }
            end,
        })
        after_buf = vim.fn.bufnr("pi://review" .. path)

        assert.is_true(
            vim.wait(2000, function()
                return observed ~= nil
            end, 10),
            "the timeout handler did not run"
        )
        assert.is_true(observed.tab_valid, "on_timeout must run before the review tab is closed")
        assert.is_true(observed.buf_live, "on_timeout must run before the proposed buffer is deleted")
        assert.is_false(vim.api.nvim_tabpage_is_valid(review_tab))
    end)
end)
