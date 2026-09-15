-- Regression: zen mode must survive an external close of its float.
--
-- A6: `:PiZen` opened two floats (backdrop + prompt). When the zen window was
-- closed by anything outside zen.lua (tab close, :q, a layout teardown),
-- `exit()`'s `is_active()` guard returned early on the next call/scheduled
-- teardown, orphaning the full-screen backdrop and leaving the prompt bound
-- to a dead window. A WinClosed autocmd now drives the teardown, and `exit()`
-- keys off "do we hold any zen window" instead of "is the window still
-- valid", making it idempotent.

local Zen = require("pi.ui.chat.zen")

local function pump(ms)
    vim.wait(ms or 60)
end

--- Minimal `pi.ChatPrompt` stand-in covering what zen mode touches.
local function make_prompt_stub()
    local buf = vim.api.nvim_create_buf(false, true)
    local stub = {
        _buf = buf,
        zen = nil, ---@type boolean?
        layout = nil, ---@type string?
        focused = 0,
        resized = 0,
    }
    function stub:buf()
        return self._buf
    end
    function stub:win()
        return nil
    end
    function stub:set_zen(v)
        self.zen = v
    end
    function stub:set_win(w)
        self._win = w
    end
    function stub:set_layout(l)
        self.layout = l
    end
    function stub:resize()
        self.resized = self.resized + 1
    end
    function stub:focus()
        self.focused = self.focused + 1
    end
    return stub
end

describe("zen mode teardown", function()
    it("removes the backdrop when the zen window is closed externally", function()
        local prompt = make_prompt_stub()
        local zen = Zen.new(prompt)

        zen:enter()
        local win = zen._win
        assert.is_truthy(win, "zen window opened")
        assert.is_truthy(zen._backdrop_win, "backdrop opened")
        assert.is_true(zen:is_active())

        -- Close the float behind zen's back (tab close / :q / layout teardown).
        vim.api.nvim_win_close(win, true)

        assert.is_true(
            vim.wait(500, function()
                return zen._backdrop_win == nil
            end),
            "backdrop was orphaned after the zen window was closed externally"
        )
        assert.is_nil(zen._win, "zen window reference cleared")
        assert.is_false(zen:is_active())
        assert.is_false(prompt.zen, "prompt zen flag cleared")

        vim.api.nvim_buf_delete(prompt:buf(), { force = true })
    end)

    it("exit is idempotent", function()
        local prompt = make_prompt_stub()
        local zen = Zen.new(prompt)

        zen:enter()
        zen:exit()
        assert.is_nil(zen._win)
        assert.is_nil(zen._backdrop_win)

        -- A second exit (keymap + external close race) must be a no-op.
        local ok, err = pcall(function()
            zen:exit()
        end)
        assert.is_true(ok, "second exit must not error: " .. tostring(err))
        assert.is_nil(zen._backdrop_win)

        vim.api.nvim_buf_delete(prompt:buf(), { force = true })
    end)

    it("exit after an external close is idempotent", function()
        local prompt = make_prompt_stub()
        local zen = Zen.new(prompt)

        zen:enter()
        local win = zen._win
        vim.api.nvim_win_close(win, true)
        pump(100)
        assert.is_nil(zen._backdrop_win)

        local ok, err = pcall(function()
            zen:exit()
        end)
        assert.is_true(ok, "exit after external close must not error: " .. tostring(err))

        vim.api.nvim_buf_delete(prompt:buf(), { force = true })
    end)
end)
