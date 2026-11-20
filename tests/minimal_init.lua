-- Minimal init for running pi.nvim's plenary test suite hermetically.
-- Adds plenary and this plugin to 'runtimepath' without loading the user's
-- full Neovim config, so unit tests stay fast and deterministic.
--
-- Usage (see Makefile `test` target):
--   nvim --headless -u tests/minimal_init.lua -c "lua require('plenary.test_harness').test_directory('tests')"

local function repo_root()
    -- tests/minimal_init.lua lives in <root>/tests/
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
end

local root = repo_root()

-- Shared e2e helper (`tests/e2e_deps.lua`): the hermetic scripts load it as
-- `require("e2e_deps")`, so `tests/` has to be on package.path.
package.path = root .. "/tests/?.lua;" .. package.path

-- plenary: prefer a sibling checkout (lazy.nvim layout), fall back to a
-- user-provided PLENARY_PATH env var.
local plenary = vim.env.PLENARY_PATH or vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")

-- render-markdown: OPTIONAL test dependency for the render contract spec
-- (G6/G7/G9). Only prepended when present, so the suite still runs on a machine
-- without it; the spec skips itself instead. Being on 'runtimepath' is not the
-- same as being loaded — the children run with `--noplugin` (plenary passes it),
-- so a spec must call setup()/manager.init() itself (G8).
local render_markdown = vim.env.RENDER_MARKDOWN_PATH or vim.fn.expand("~/.local/share/nvim/lazy/render-markdown.nvim")

-- telescope is deliberately NOT prepended here: the unit specs inject a FAKE
-- telescope module tree into `package.loaded`, and a real checkout on
-- 'runtimepath' loads its `plugin/` chunk alongside the fake (observed:
-- `attempt to call field 'on_close_prompt' (a nil value)` from the real
-- `telescope/pickers.lua`). The one script that needs the real picker,
-- `tests/resume_partitions_e2e.lua`, prepends `TELESCOPE_PATH` itself.

for _, path in ipairs({ plenary, root, render_markdown }) do
    if vim.uv.fs_stat(path) then
        vim.opt.runtimepath:prepend(path)
    end
end

-- Hermetic guard: keep unit tests from writing prompt-history/draft files
-- into the user's real pi data dir (specs that construct a Chat fall back to
-- the process cwd and would otherwise persist to stdpath("data")).
require("pi.prompt_history")._set_base_dir(vim.fn.tempname())
