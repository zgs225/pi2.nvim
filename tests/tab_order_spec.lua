-- pi.sessions.tab_order: the single ordering model shared by :PiSessions row
-- grouping and every path that opens a session tab. The list prints one
-- checkout's sessions as a contiguous block, a permutation of the tabline
-- order — so the block invariant holds only if the tabline is permuted the same
-- way. These specs pin the model (classification, block order, canonical
-- sequence), the anchor a new tab joins, and the explicit reconcile pass.
--
-- Real tabpages are used (handles and visual order are what `:tabmove` acts on)
-- and `pi.worktree` is stubbed through package.loaded, so no git runs.

local Config = require("pi.config")
local TabOrder = require("pi.sessions.tab_order")

Config.setup({})

---@type table<string, { kind: string, name: string, path: string, repo_root: string }>
local WORKTREES = {
    ["/repo/main"] = { kind = "main", name = "main", path = "/repo/main", repo_root = "/repo/main" },
    ["/repo/wt"] = { kind = "linked", name = "wt", path = "/repo/wt", repo_root = "/repo/main" },
    ["/repo/wt2"] = { kind = "linked", name = "wt2", path = "/repo/wt2", repo_root = "/repo/main" },
}

local real_worktree = package.loaded["pi.worktree"]
local detect_calls = 0

local function install_stub()
    detect_calls = 0
    package.loaded["pi.worktree"] = {
        detect = function(dir)
            detect_calls = detect_calls + 1
            return WORKTREES[dir]
        end,
    }
    TabOrder.reset()
end

local function restore_stub()
    package.loaded["pi.worktree"] = real_worktree
    TabOrder.reset()
end

---@param opts { id: string, tab: pi.TabId, cwd?: string }
---@return pi.Session
local function fake_session(opts)
    return {
        id = opts.id,
        tab = opts.tab,
        attached_tab = opts.tab,
        cwd = opts.cwd,
        conversation_epoch = 0,
    }
end

--- Run `fn` with `count` real tabpages, passed as `{ tab1, … }` in tabline order.
---@param count integer
---@param fn fun(tabs: pi.TabId[])
local function with_tabs(count, fn)
    local tabs = { vim.api.nvim_get_current_tabpage() }
    for _ = 2, count do
        vim.cmd("tabnew")
        tabs[#tabs + 1] = vim.api.nvim_get_current_tabpage()
    end
    local ok, err = pcall(fn, tabs)
    for index = #tabs, 2, -1 do
        if vim.api.nvim_tabpage_is_valid(tabs[index]) then
            pcall(vim.api.nvim_set_current_tabpage, tabs[index])
            pcall(vim.cmd, "tabclose")
        end
    end
    if vim.api.nvim_tabpage_is_valid(tabs[1]) then
        pcall(vim.api.nvim_set_current_tabpage, tabs[1])
    end
    if not ok then
        error(err)
    end
end

--- Labels of the live tabline in visual order (`plain` for a non-π tab).
---@param labels table<pi.TabId, string>
---@return string[]
local function tabline_labels(labels)
    local out = {}
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        out[#out + 1] = labels[tab] or "plain"
    end
    return out
end

describe("pi.sessions.tab_order", function()
    before_each(install_stub)
    after_each(restore_stub)

    describe("model", function()
        it("groups by checkout in first-appearance order, keeping tabline order inside a block", function()
            with_tabs(3, function(tabs)
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "wt_b", tab = tabs[2], cwd = "/repo/wt" }),
                    fake_session({ id = "main_c", tab = tabs[3], cwd = "/repo/main" }),
                }

                local model = TabOrder.model({ sessions = sessions })

                assert.is_true(model.grouped)
                assert.are.same({ "/repo/main", "/repo/wt" }, { model.groups[1].path, model.groups[2].path })
                assert.are.same({ "main_a", "main_c" }, {
                    model.groups[1].sessions[1].id,
                    model.groups[1].sessions[2].id,
                })
                assert.are.same({ tabs[1], tabs[3], tabs[2] }, model.tabs, "blocks then members in tabline order")
            end)
        end)

        it("stays flat below two worktrees", function()
            with_tabs(2, function(tabs)
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "plain", tab = tabs[2], cwd = "/tmp/plain" }),
                }

                local model = TabOrder.model({ sessions = sessions })

                assert.is_false(model.grouped)
                assert.are.same({ tabs[1], tabs[2] }, model.tabs)
            end)
        end)

        it("puts sessions outside a work tree in the trailing ungrouped bucket", function()
            with_tabs(3, function(tabs)
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "plain", tab = tabs[2], cwd = "/tmp/plain" }),
                    fake_session({ id = "wt_b", tab = tabs[3], cwd = "/repo/wt" }),
                }

                local model = TabOrder.model({ sessions = sessions })

                assert.are.same({ "plain" }, { model.ungrouped[1].id })
                assert.are.same({ tabs[1], tabs[3], tabs[2] }, model.tabs)
            end)
        end)
    end)

    describe("anchor", function()
        it("is the block's last tab by tabline position", function()
            with_tabs(3, function(tabs)
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "wt_b", tab = tabs[2], cwd = "/repo/wt" }),
                    fake_session({ id = "main_c", tab = tabs[3], cwd = "/repo/main" }),
                }

                assert.are.equal(tabs[3], TabOrder.anchor("/repo/main", { sessions = sessions }))
                assert.are.equal(tabs[2], TabOrder.anchor("/repo/wt", { sessions = sessions }))
            end)
        end)

        it("is nil for a flat list", function()
            with_tabs(2, function(tabs)
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "main_b", tab = tabs[2], cwd = "/repo/main" }),
                }

                assert.is_nil(TabOrder.anchor("/repo/main", { sessions = sessions }))
            end)
        end)

        it("inserts a checkout with no block after the last existing block", function()
            with_tabs(3, function(tabs)
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "wt_b", tab = tabs[2], cwd = "/repo/wt" }),
                    fake_session({ id = "plain", tab = tabs[3], cwd = "/tmp/plain" }),
                }

                -- wt2's block goes before the ungrouped tail, i.e. after wt's
                -- last tab — not behind the ungrouped row.
                assert.are.equal(tabs[2], TabOrder.anchor("/repo/wt2", { sessions = sessions }))
            end)
        end)

        it("ignores the tab being placed", function()
            with_tabs(4, function(tabs)
                local placed = fake_session({ id = "main_new", tab = tabs[4], cwd = "/repo/main" })
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "wt_b", tab = tabs[2], cwd = "/repo/wt" }),
                    fake_session({ id = "main_c", tab = tabs[3], cwd = "/repo/main" }),
                    placed,
                }

                assert.are.equal(
                    tabs[3],
                    TabOrder.anchor("/repo/main", { sessions = sessions, exclude_tab = placed.tab })
                )
            end)
        end)
    end)

    describe("place", function()
        it("moves a new tab after the last tab of its block", function()
            with_tabs(4, function(tabs)
                local labels = {
                    [tabs[1]] = "main_a",
                    [tabs[2]] = "wt_b",
                    [tabs[3]] = "wt_c",
                    [tabs[4]] = "main_new",
                }
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "wt_b", tab = tabs[2], cwd = "/repo/wt" }),
                    fake_session({ id = "wt_c", tab = tabs[3], cwd = "/repo/wt" }),
                    fake_session({ id = "main_new", tab = tabs[4], cwd = "/repo/main" }),
                }

                assert.is_true(TabOrder.place(tabs[4], "/repo/main", { sessions = sessions }))
                assert.are.same({ "main_a", "main_new", "wt_b", "wt_c" }, tabline_labels(labels))
            end)
        end)

        it("does not move a tab that already sits directly after its block", function()
            with_tabs(3, function(tabs)
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "wt_b", tab = tabs[2], cwd = "/repo/wt" }),
                    fake_session({ id = "main_new", tab = tabs[3], cwd = "/repo/main" }),
                }

                -- main's block tail is tab 1, but the new tab sits behind wt's
                -- tab, so it *is* moved (the block's own last tab is what it
                -- joins, not the end of the tabline).
                assert.is_true(TabOrder.place(tabs[3], "/repo/main", { sessions = sessions }))
                assert.are.equal(tabs[3], vim.api.nvim_list_tabpages()[2])
            end)
        end)

        it("is a no-op without a checkout or for a flat list", function()
            with_tabs(2, function(tabs)
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "main_b", tab = tabs[2], cwd = "/repo/main" }),
                }

                assert.is_false(TabOrder.place(tabs[2], "/repo/main", { sessions = sessions }))
                assert.is_false(TabOrder.place(tabs[2], nil, { sessions = sessions }))
            end)
        end)
    end)

    describe("move_after", function()
        it("ignores equal, invalid and adjacent pairs", function()
            with_tabs(2, function(tabs)
                assert.is_false(TabOrder.move_after(nil, tabs[1]))
                assert.is_false(TabOrder.move_after(tabs[1], tabs[1]))
                -- tabs[2] already sits directly after tabs[1]: no move needed.
                assert.is_false(TabOrder.move_after(tabs[2], tabs[1]))
                assert.is_false(TabOrder.move_after(999999, tabs[1]))
                assert.are.same(tabs, vim.api.nvim_list_tabpages())

                -- The reverse really does reorder.
                assert.is_true(TabOrder.move_after(tabs[1], tabs[2]))
                assert.are.same({ tabs[2], tabs[1] }, vim.api.nvim_list_tabpages())
            end)
        end)
    end)

    describe("reconcile", function()
        it("orders π tabs into blocks and leaves a non-π tab in its slot", function()
            with_tabs(4, function(tabs)
                local labels = {
                    [tabs[1]] = "main_a",
                    [tabs[3]] = "wt_b",
                    [tabs[4]] = "main_c",
                }
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "wt_b", tab = tabs[3], cwd = "/repo/wt" }),
                    fake_session({ id = "main_c", tab = tabs[4], cwd = "/repo/main" }),
                }

                assert.are.equal(1, TabOrder.reconcile({ sessions = sessions }))
                assert.are.same({ "main_a", "plain", "main_c", "wt_b" }, tabline_labels(labels))
            end)
        end)

        it("is idempotent", function()
            with_tabs(3, function(tabs)
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "wt_b", tab = tabs[2], cwd = "/repo/wt" }),
                    fake_session({ id = "main_c", tab = tabs[3], cwd = "/repo/main" }),
                }

                assert.is_true(TabOrder.reconcile({ sessions = sessions }) > 0)
                assert.are.equal(0, TabOrder.reconcile({ sessions = sessions }))
            end)
        end)

        it("does not fire TabEnter while reordering", function()
            with_tabs(3, function(tabs)
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "wt_b", tab = tabs[2], cwd = "/repo/wt" }),
                    fake_session({ id = "main_c", tab = tabs[3], cwd = "/repo/main" }),
                }
                local entered = 0
                local autocmd = vim.api.nvim_create_autocmd("TabEnter", {
                    callback = function()
                        entered = entered + 1
                    end,
                })
                local before = vim.o.eventignore
                local ok, err = pcall(function()
                    TabOrder.reconcile({ sessions = sessions })
                end)
                local after = vim.o.eventignore
                pcall(vim.api.nvim_del_autocmd, autocmd)
                assert.are.equal(before, after, "eventignore must be restored")
                if not ok then
                    error(err)
                end
                -- Moving focus through the tabs would consume their unseen
                -- done/error badges and re-render todo panels.
                assert.are.equal(0, entered)
            end)
        end)

        it("moves nothing on a flat list", function()
            with_tabs(2, function(tabs)
                local sessions = {
                    fake_session({ id = "main_a", tab = tabs[1], cwd = "/repo/main" }),
                    fake_session({ id = "main_b", tab = tabs[2], cwd = "/repo/main" }),
                }

                assert.are.equal(0, TabOrder.reconcile({ sessions = sessions }))
            end)
        end)
    end)

    describe("detect", function()
        it("memoizes per directory until reset", function()
            assert.is_truthy(TabOrder.detect("/repo/main"))
            assert.is_truthy(TabOrder.detect("/repo/main"))
            assert.are.equal(1, detect_calls, "second call served from the cache")

            TabOrder.reset()
            assert.is_truthy(TabOrder.detect("/repo/main"))
            assert.are.equal(2, detect_calls, "reset drops the cache")
        end)

        it("caches a non-worktree directory too", function()
            assert.is_nil(TabOrder.detect("/tmp/plain"))
            assert.is_nil(TabOrder.detect("/tmp/plain"))
            assert.are.equal(1, detect_calls)
        end)
    end)
end)
