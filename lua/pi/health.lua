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
