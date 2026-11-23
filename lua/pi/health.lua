local Compat = require("pi.compat")
local Cli = require("pi.cli")
local Config = require("pi.config")

local M = {}

---@param bin string
---@return string? version
---@return string? err
local function get_pi_version(bin)
    local output = vim.fn.system({ bin, "--version" })
    if vim.v.shell_error ~= 0 then
        return nil, "failed to run `" .. bin .. " --version`: " .. vim.trim(output)
    end

    local version = Compat.extract_version(output)
    if not version then
        return nil, "could not parse version from `" .. vim.trim(output) .. "`"
    end

    return version, nil
end

--- Check whether a treesitter parser is available.
---@param lang string
---@return boolean
local function has_ts_parser(lang)
    local ok = pcall(vim.treesitter.language.inspect, lang)
    return ok
end

M.check = function()
    vim.health.start("pi.nvim")

    -- ── Neovim version ────────────────────────────────────────────────
    if vim.fn.has("nvim-0.10") == 1 then
        vim.health.ok("Neovim >= 0.10")
    else
        vim.health.error("Neovim >= 0.10 is required", {
            "Upgrade Neovim to 0.10 or newer",
        })
    end

    -- ── pi executable and version ─────────────────────────────────────
    local bin = Cli.bin()
    local pi_version ---@type string?
    local bin_found = vim.fn.executable(bin) == 1
    if bin_found then
        vim.health.ok("`" .. bin .. "` executable found")

        local version, err = get_pi_version(bin)
        pi_version = version
        if not version then
            vim.health.warn("Could not determine pi version: " .. (err or "unknown error"))
        else
            local cmp_min = Compat.compare_versions(version, Compat.min_supported)
            local cmp_validated = Compat.compare_versions(version, Compat.validated)

            if cmp_min == nil or cmp_validated == nil then
                vim.health.warn(
                    "Could not compare pi version `"
                        .. version
                        .. "` against supported range (min="
                        .. Compat.min_supported
                        .. ", validated="
                        .. Compat.validated
                        .. ")"
                )
            elseif cmp_min < 0 then
                vim.health.error(
                    "pi version `" .. version .. "` is older than minimum supported `" .. Compat.min_supported .. "`"
                )
            elseif cmp_validated > 0 then
                vim.health.warn(
                    "pi version `"
                        .. version
                        .. "` is newer than last validated `"
                        .. Compat.validated
                        .. "` (expected to work, but not validated yet)"
                )
            else
                vim.health.ok(
                    "pi version `"
                        .. version
                        .. "` is within supported/validated range (min="
                        .. Compat.min_supported
                        .. ", validated="
                        .. Compat.validated
                        .. ")"
                )
            end
        end
    else
        vim.health.error("`" .. bin .. "` executable not found in PATH", {
            "Install pi from https://pi.dev",
        })
    end

    -- ── Treesitter parsers ────────────────────────────────────────────
    if has_ts_parser("markdown") then
        vim.health.ok("treesitter `markdown` parser found")
    else
        vim.health.info("treesitter `markdown` parser not found (chat history highlighting will be limited)")
    end
    if has_ts_parser("markdown_inline") then
        vim.health.ok("treesitter `markdown_inline` parser found")
    else
        vim.health.info("treesitter `markdown_inline` parser not found (inline markdown highlighting will be limited)")
    end

    -- ── Optional plugins ──────────────────────────────────────────────
    if pcall(require, "img-clip") then
        vim.health.ok("img-clip.nvim found (clipboard image paste)")
    else
        vim.health.info("img-clip.nvim not found (`:PiPasteImage` and clipboard paste interception unavailable)")
    end

    local render_engine = Config.options.render and Config.options.render.engine or "builtin"
    if pcall(require, "render-markdown") then
        vim.health.ok("render-markdown.nvim found")
    elseif render_engine == "render-markdown" then
        vim.health.warn('render-markdown.nvim not found but `render.engine = "render-markdown"` is set', {
            'Install render-markdown.nvim or set `render.engine = "builtin"`',
        })
    else
        vim.health.info(
            'render-markdown.nvim not found (optional, only needed for `render.engine = "render-markdown"`)'
        )
    end

    if pcall(require, "blink.cmp") then
        vim.health.ok("blink.cmp found (prompt completion)")
    else
        vim.health.info("blink.cmp not found (optional, built-in completefunc still works)")
    end

    -- ── Bundled tree extension ────────────────────────────────────────
    local tree_cfg = Config.options.tree or {}
    if tree_cfg.enabled ~= false then
        local tree_path = Cli.tree_extension_path()
        if vim.uv.fs_stat(tree_path) then
            vim.health.ok("bundled tree extension found (`:PiTree`)")
        else
            vim.health.warn("bundled tree extension not found at " .. tree_path, {
                "Reinstall pi2.nvim or set `tree = { enabled = false }` to disable :PiTree",
            })
        end
    end

    -- ── Bundled vision extension ──────────────────────────────────────
    local vision_cfg = Config.options.vision or {}
    if type(vision_cfg.model) == "string" and vision_cfg.model ~= "" then
        local vision_path = Cli.vision_extension_path()
        if vim.uv.fs_stat(vision_path) then
            vim.health.ok("bundled vision extension found (`vision.model = " .. vision_cfg.model .. "`")
        else
            vim.health.warn("bundled vision extension not found at " .. vision_path, {
                "Reinstall pi2.nvim or unset `vision.model` to disable the vision fallback",
            })
        end

        -- Version floor: the vision extension needs a public
        -- ModelRegistry.getProvider() (pi 0.81.0+). Below that every image
        -- submission fast-fails with a `[pi-vision]` error and the prompt is
        -- restored — no crash, but the feature never works.
        local vision_min = Compat.vision_min_supported
        if not pi_version then
            vim.health.warn(
                "Could not verify pi version against the vision fallback requirement (pi >= " .. vision_min .. ")",
                {
                    "Fix the pi version detection above, or unset `vision.model` to disable the vision fallback",
                }
            )
        else
            local cmp_vision = Compat.compare_versions(pi_version, vision_min)
            if cmp_vision == nil then
                vim.health.warn(
                    "Could not compare pi version `"
                        .. pi_version
                        .. "` against the vision fallback minimum `"
                        .. vision_min
                        .. "`"
                )
            elseif cmp_vision < 0 then
                vim.health.error(
                    "pi version `" .. pi_version .. "` is older than the vision fallback minimum `" .. vision_min .. "`",
                    {
                        "Upgrade pi to " .. vision_min .. "+ or unset `vision.model` to disable the vision fallback",
                        "With an older pi, image submissions fast-fail with a `[pi-vision]` error and the prompt is restored (no crash)",
                    }
                )
            else
                vim.health.ok(
                    "pi version `"
                        .. pi_version
                        .. "` satisfies the vision fallback requirement (pi >= "
                        .. vision_min
                        .. ")"
                )
            end
        end
    end

    -- ── Bundled auto-title extension ──────────────────────────────────
    if Config.options.title == nil or Config.options.title.enabled ~= false then
        local title_path = Cli.title_extension_path()
        if vim.uv.fs_stat(title_path) then
            vim.health.ok("bundled auto-title extension found")
        else
            vim.health.warn("bundled auto-title extension not found at " .. title_path, {
                "Reinstall pi2.nvim or set `title.enabled = false` to disable auto titles",
            })
        end

        -- Version floor: the title extension needs pi.setSessionName() /
        -- pi.getSessionName() and the extension turn_end event. Below the
        -- floor sessions stay unnamed (first-message fallback) — no crash.
        local title_min = Compat.title_min_supported
        if not pi_version then
            vim.health.warn(
                "Could not verify pi version against the auto-title requirement (pi >= " .. title_min .. ")",
                {
                    "Fix the pi version detection above, or set `title.enabled = false` to disable auto titles",
                }
            )
        else
            local cmp_title = Compat.compare_versions(pi_version, title_min)
            if cmp_title == nil then
                vim.health.warn(
                    "Could not compare pi version `"
                        .. pi_version
                        .. "` against the auto-title minimum `"
                        .. title_min
                        .. "`"
                )
            elseif cmp_title < 0 then
                vim.health.error(
                    "pi version `" .. pi_version .. "` is older than the auto-title minimum `" .. title_min .. "`",
                    {
                        "Upgrade pi to " .. title_min .. "+ or set `title.enabled = false` to disable auto titles",
                        "With an older pi, sessions stay unnamed (first-message fallback) — no crash",
                    }
                )
            else
                vim.health.ok(
                    "pi version `" .. pi_version .. "` satisfies the auto-title requirement (pi >= " .. title_min .. ")"
                )
            end
        end
    end

    -- ── Bundled model-scope bridge extension ────────────────────────────
    local scope_path = Cli.scoped_models_extension_path()
    if vim.uv.fs_stat(scope_path) then
        vim.health.ok("bundled model-scope bridge extension found")
    else
        vim.health.warn("bundled model-scope bridge extension not found at " .. scope_path, {
            "Reinstall pi2.nvim",
        })
    end

    -- Version floor: the bridge reads ctx.scopedModels (pi 0.83.0+). Below
    -- the floor it stays silent and :PiSelectModel falls back to
    -- config.models / the full list — degraded scope mirroring, no crash.
    -- Warn (not error): when no --models/enabledModels scoping is configured
    -- on the pi side this layer is inert anyway.
    local scope_min = Compat.scoped_models_min_supported
    if not pi_version then
        vim.health.warn(
            "Could not verify pi version against the model-scope bridge requirement (pi >= " .. scope_min .. ")"
        )
    else
        local cmp_scope = Compat.compare_versions(pi_version, scope_min)
        if cmp_scope == nil then
            vim.health.warn(
                "Could not compare pi version `"
                    .. pi_version
                    .. "` against the model-scope bridge minimum `"
                    .. scope_min
                    .. "`"
            )
        elseif cmp_scope < 0 then
            vim.health.warn(
                "pi version `" .. pi_version .. "` is older than the model-scope bridge minimum `" .. scope_min .. "`",
                {
                    "Upgrade pi to " .. scope_min .. "+ so :PiSelectModel mirrors --models/enabledModels scoping",
                    "With an older pi, :PiSelectModel ignores backend scoping and lists all models instead (no crash)",
                }
            )
        else
            vim.health.ok(
                "pi version `"
                    .. pi_version
                    .. "` satisfies the model-scope bridge requirement (pi >= "
                    .. scope_min
                    .. ")"
            )
        end
    end

    -- ── Bundled background bash tasks extension ───────────────────────
    local bg_path = Cli.bg_tasks_extension_path()
    if vim.uv.fs_stat(bg_path) then
        vim.health.ok("bundled background bash tasks extension found")
    else
        vim.health.warn("bundled background bash tasks extension not found at " .. bg_path, {
            "Reinstall pi2.nvim",
            "Without it `run_in_background` / `&`-prefix are unavailable and :PiTasks stays empty",
        })
    end

    -- Version floor: bg-tasks overrides the built-in bash tool via
    -- pi.registerTool() and re-exports createBashToolDefinition() /
    -- getShellConfig() from the package root, all verified on pi 0.85.1
    -- (exact introduction version unknown — floor set to validated version).
    -- Below the floor the extension fails to load and pi logs the error —
    -- sessions keep stock bash, no crash, :PiTasks stays empty.
    local bg_min = Compat.bg_tasks_min_supported
    if not pi_version then
        vim.health.warn(
            "Could not verify pi version against the background bash tasks requirement (pi >= " .. bg_min .. ")"
        )
    else
        local cmp_bg = Compat.compare_versions(pi_version, bg_min)
        if cmp_bg == nil then
            vim.health.warn(
                "Could not compare pi version `"
                    .. pi_version
                    .. "` against the background bash tasks minimum `"
                    .. bg_min
                    .. "`"
            )
        elseif cmp_bg < 0 then
            vim.health.warn(
                "pi version `" .. pi_version .. "` is older than the background bash tasks minimum `" .. bg_min .. "`",
                {
                    "Upgrade pi to " .. bg_min .. "+ so `run_in_background` and the `&` prefix work",
                    "With an older pi the extension fails to load and bash stays stock — no crash",
                }
            )
        else
            vim.health.ok(
                "pi version `"
                    .. pi_version
                    .. "` satisfies the background bash tasks requirement (pi >= "
                    .. bg_min
                    .. ")"
            )
        end
    end

    -- ── Three-column layout ───────────────────────────────────────────
    -- The layout resolves itself from config at open time, so the only thing
    -- worth reporting here is a configuration the user cannot see fail:
    -- an invalid takeover mode, a deprecated position, a chat column the
    -- columns squeeze below the usable floor, and legacy rows that a full-tab
    -- layout cannot honor.
    local Workspace = require("pi.ui.workspace")
    local layout_cfg = Config.resolve_side_layout()
    local full_tab = layout_cfg and layout_cfg.full_tab
    if full_tab == nil or full_tab == "never" or full_tab == "auto" or full_tab == "always" then
        vim.health.ok("`layout.side.full_tab` = `" .. tostring(full_tab or "never") .. "`")
    else
        vim.health.warn("Invalid `layout.side.full_tab`: `" .. tostring(full_tab) .. "`", {
            'Use "never" (split layout), "auto" (take over an untouched `:tabnew` tab) or "always"',
        })
    end
    if layout_cfg and layout_cfg.position == "bottom" then
        vim.health.warn('`layout.side.position = "bottom"` is not supported by the three-column layout', {
            'The chat column opens on the right instead; use "left" or "right"',
        })
    end

    --- Column a panel config selects, or nil for a legacy horizontal row.
    ---@param position any
    ---@return "left"|"right"|nil
    local function column_of(position)
        if position == "left" or position == "right" then
            return position
        end
        return nil
    end

    local sessions_cfg = Config.options.sessions_list or {}
    local tasks_cfg = Config.options.tasks_panel or {}
    local todo_panel_cfg = (Config.options.todo or {}).panel or {}
    local sessions_col = column_of(sessions_cfg.position) or "left"
    local tasks_col = column_of(tasks_cfg.position)
    local todo_col = column_of(todo_panel_cfg.position) or sessions_col
    -- The first panel in stacking order owns the width of its column.
    local left_spec, right_spec
    for _, owner in ipairs({
        { edge = sessions_col, width = sessions_cfg.width },
        { edge = tasks_col, width = tasks_cfg.width },
        { edge = todo_col, width = todo_panel_cfg.width or 40 },
    }) do
        if owner.edge == "left" and not left_spec then
            left_spec = owner.width
        elseif owner.edge == "right" and not right_spec then
            right_spec = owner.width
        end
    end

    local mode = (full_tab == "auto" or full_tab == "always") and "full" or "split"
    local columns = Workspace.resolve_columns(left_spec, right_spec, vim.o.columns, mode)
    local chat_width
    if mode == "full" then
        chat_width = columns.flex
    else
        chat_width = (layout_cfg and layout_cfg.width) or 80
        if chat_width < 1 then
            chat_width = math.floor(vim.o.columns * chat_width)
        end
        chat_width = math.floor(chat_width)
    end
    if chat_width < columns.min_chat then
        vim.health.warn(
            string.format("Chat column is only %d columns wide at %d editor columns", chat_width, vim.o.columns),
            {
                "Widen the editor or narrow `sessions_list.width` / `tasks_panel.width` / `todo.panel.width`",
            }
        )
    else
        vim.health.ok(string.format("Chat column %d columns wide at %d editor columns", chat_width, vim.o.columns))
    end

    if mode == "full" then
        for _, panel in ipairs({
            { name = "sessions_list", position = sessions_cfg.position },
            { name = "tasks_panel", position = tasks_cfg.position },
            { name = "todo.panel", position = todo_panel_cfg.position },
        }) do
            if panel.position == "top" or panel.position == "bottom" then
                vim.health.warn(
                    string.format(
                        '`%s.position = "%s"` is not part of the full-tab three-column layout',
                        panel.name,
                        panel.position
                    ),
                    { 'That panel opens in the left column instead; use "left" or "right"' }
                )
            end
        end
    end

    -- ── Image compression tools ────────────────────────────────────────
    local compress_cfg = Config.options.prompt and Config.options.prompt.image_compress or {}
    if compress_cfg.enable ~= false then
        local ImageCompress = require("pi.image_compress")
        local configured = compress_cfg.tool or "auto"
        local tool = ImageCompress._detect_tool(configured)
        if tool then
            vim.health.ok("image compression tool found: `" .. tool .. "`")
        elseif configured ~= "auto" then
            vim.health.warn("configured image compression tool `" .. configured .. "` not found in PATH", {
                "Install " .. configured .. ' or set `prompt.image_compress.tool = "auto"`',
            })
        else
            vim.health.info("no image compression tool found (sips/magick/ffmpeg); images will be sent uncompressed")
        end
    end
end

return M
