-- Side-panel stacking coordinator (lua/pi/ui/sidebar.lua).
--
-- Uses real splits in headless Neovim. Geometry constants mirror the
-- empirical layout rules the module implements: each stacked window costs
-- one statusline row, and each adjacent vsplit pair costs one separator
-- column.

local Sidebar = require("pi.ui.sidebar")

--- Column height budget for n stacked windows.
---@param n integer
---@return integer
local function height_budget(n)
    return vim.o.lines - vim.o.cmdheight - n
end

--- Row width budget for n side-by-side windows.
---@param n integer
---@return integer
local function width_budget(n)
    return vim.o.columns - (n - 1)
end

--- Open a left-column window and return its handle.
---@return integer
local function new_left_win()
    vim.cmd("topleft 30vsplit")
    return vim.api.nvim_get_current_win()
end

local function cleanup()
    Sidebar._reset()
    pcall(vim.cmd, "only")
end

describe("pi.ui.sidebar", function()
    before_each(cleanup)
    after_each(cleanup)

    it("gives a single panel the full column height and pins it", function()
        local win = new_left_win()
        Sidebar.claim(1, "left", "sessions", win)
        assert.are.equal(height_budget(1), vim.api.nvim_win_get_height(win))
        assert.is_true(vim.wo[win].winfixheight)
    end)

    it("splits the column evenly between two panels", function()
        local w1 = new_left_win()
        Sidebar.claim(1, "left", "sessions", w1)
        vim.api.nvim_set_current_win(w1)
        vim.cmd("split")
        local w2 = vim.api.nvim_get_current_win()
        Sidebar.claim(1, "left", "tasks", w2)

        local h1 = vim.api.nvim_win_get_height(w1)
        local h2 = vim.api.nvim_win_get_height(w2)
        assert.are.equal(height_budget(2), h1 + h2)
        assert.is_true(math.abs(h1 - h2) <= 1, "even split, got " .. h1 .. "/" .. h2)
        assert.is_true(vim.wo[w1].winfixheight)
        assert.is_true(vim.wo[w2].winfixheight)
    end)

    it("honors weight ratios", function()
        local w1 = new_left_win()
        vim.api.nvim_set_current_win(w1)
        vim.cmd("split")
        local w2 = vim.api.nvim_get_current_win()
        Sidebar.claim(1, "left", "sessions", w1, { weight = 2 })
        Sidebar.claim(1, "left", "tasks", w2, { weight = 1 })

        local h1 = vim.api.nvim_win_get_height(w1)
        local h2 = vim.api.nvim_win_get_height(w2)
        assert.are.equal(height_budget(2), h1 + h2)
        assert.is_true(h1 > h2, "2:1 split, got " .. h1 .. "/" .. h2)
        assert.is_true(math.abs(h1 - 2 * h2) <= 2, "ratio roughly 2:1, got " .. h1 .. "/" .. h2)
    end)

    it("clamps tiny shares to at least one line", function()
        local w1 = new_left_win()
        vim.api.nvim_set_current_win(w1)
        vim.cmd("split")
        local w2 = vim.api.nvim_get_current_win()
        Sidebar.claim(1, "left", "sessions", w1, { weight = 1000 })
        Sidebar.claim(1, "left", "tasks", w2, { weight = 1 })

        assert.is_true(vim.api.nvim_win_get_height(w2) >= 1)
        assert.are.equal(height_budget(2), vim.api.nvim_win_get_height(w1) + vim.api.nvim_win_get_height(w2))
    end)

    it("orders panels sessions < todo < tasks regardless of claim order", function()
        local wt = new_left_win()
        vim.api.nvim_set_current_win(wt)
        vim.cmd("split")
        local ws = vim.api.nvim_get_current_win()
        Sidebar.claim(1, "left", "tasks", wt)
        Sidebar.claim(1, "left", "sessions", ws)

        local panels = Sidebar.panels(1, "left")
        assert.are.equal(2, #panels)
        assert.are.equal("sessions", panels[1].key)
        assert.are.equal("tasks", panels[2].key)
    end)

    it("grows the remaining panel back to full height on release", function()
        local w1 = new_left_win()
        vim.api.nvim_set_current_win(w1)
        vim.cmd("split")
        local w2 = vim.api.nvim_get_current_win()
        Sidebar.claim(1, "left", "sessions", w1)
        Sidebar.claim(1, "left", "tasks", w2)

        -- Real flow: the panel closes its own window first, then releases.
        vim.api.nvim_win_close(w2, true)
        Sidebar.release(1, "tasks")
        assert.are.equal(height_budget(1), vim.api.nvim_win_get_height(w1))
        assert.are.equal(1, #Sidebar.panels(1, "left"))
        assert.are.equal("sessions", Sidebar.panels(1, "left")[1].key)
    end)

    it("honors a per-claim order override", function()
        local w1 = new_left_win()
        vim.api.nvim_set_current_win(w1)
        vim.cmd("split")
        local w2 = vim.api.nvim_get_current_win()
        Sidebar.claim(1, "left", "sessions", w1)
        Sidebar.claim(1, "left", "todo", w2, { order = 0.5 })

        local panels = Sidebar.panels(1, "left")
        assert.are.equal("todo", panels[1].key)
        assert.are.equal("sessions", panels[2].key)
    end)

    it("treats release of an unknown key as a no-op", function()
        local win = new_left_win()
        Sidebar.claim(1, "left", "sessions", win)
        Sidebar.release(1, "bogus")
        Sidebar.release(2, "sessions")
        assert.are.equal(1, #Sidebar.panels(1, "left"))
    end)

    it("prunes windows closed behind its back", function()
        local w1 = new_left_win()
        vim.api.nvim_set_current_win(w1)
        vim.cmd("split")
        local w2 = vim.api.nvim_get_current_win()
        Sidebar.claim(1, "left", "sessions", w1)
        Sidebar.claim(1, "left", "tasks", w2)

        vim.api.nvim_win_close(w2, true)
        Sidebar.restack(1, "left")
        assert.are.equal(height_budget(1), vim.api.nvim_win_get_height(w1))
        assert.are.equal(1, #Sidebar.panels(1, "left"))
    end)

    it("distributes widths on horizontal edges with winfixwidth", function()
        vim.cmd("topleft 10split")
        local w1 = vim.api.nvim_get_current_win()
        vim.cmd("vsplit")
        local w2 = vim.api.nvim_get_current_win()
        Sidebar.claim(1, "top", "sessions", w1)
        Sidebar.claim(1, "top", "tasks", w2)

        local w1w = vim.api.nvim_win_get_width(w1)
        local w2w = vim.api.nvim_win_get_width(w2)
        assert.are.equal(width_budget(2), w1w + w2w)
        assert.is_true(math.abs(w1w - w2w) <= 1, "even split, got " .. w1w .. "/" .. w2w)
        assert.is_true(vim.wo[w1].winfixwidth)
        assert.is_true(vim.wo[w2].winfixwidth)
    end)

    it("re-claiming the same key replaces the registration", function()
        local w1 = new_left_win()
        Sidebar.claim(1, "left", "sessions", w1)
        vim.cmd("botright 30vsplit")
        local w2 = vim.api.nvim_get_current_win()
        Sidebar.claim(1, "right", "sessions", w2)

        assert.are.equal(0, #Sidebar.panels(1, "left"))
        local panels = Sidebar.panels(1, "right")
        assert.are.equal(1, #panels)
        assert.are.equal(w2, panels[1].win)
    end)

    it("resolves edges explicitly and falls back to left", function()
        assert.are.equal("right", Sidebar.effective_edge(1, "right"))
        assert.are.equal("bottom", Sidebar.effective_edge(1, "bottom"))
        assert.are.equal("left", Sidebar.effective_edge(1, "follow"))
        assert.are.equal("left", Sidebar.effective_edge(1, nil))
        assert.are.equal("left", Sidebar.effective_edge(1, "bogus"))
    end)
end)
