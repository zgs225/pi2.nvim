local Config = require("pi.config")
local SubToolUi = require("pi.subsessions.tool_ui")
local Manifest = require("pi.subsessions.manifest")
local Tools = require("pi.ui.chat.tools")

describe("subagent tool_ui", function()
    local manifest_tmp

    before_each(function()
        manifest_tmp = vim.fn.tempname() .. ".json"
        Manifest.path = function()
            return manifest_tmp
        end
    end)

    after_each(function()
        os.remove(manifest_tmp)
    end)

    it("resolves zh labels when title.lang is zh", function()
        Config.setup({ title = { lang = "zh" } })
        assert.are.equal("子·派发", SubToolUi.display_name("dispatch_subagents"))
    end)

    it("resolves en labels when title.lang is en", function()
        Config.setup({ title = { lang = "en" } })
        assert.are.equal("sub·dispatch", SubToolUi.display_name("dispatch_subagents"))
    end)

    it("uses manifest name for child targets", function()
        Manifest.upsert("child-1", {
            parent_id = "p",
            name = "auth-review",
            task_prompt = "t",
            config = {},
            status = "active",
            reported = false,
            created_at = "t",
            last_active_at = "t",
        })
        assert.are.equal("auth-review", SubToolUi.child_name("child-1"))
        assert.are.equal("auth-review", SubToolUi.item_label({ target = "child-1", message = "hi" }))
    end)

    it("truncates ids by default", function()
        Config.setup({ subagent = { show_full_ids = false } })
        local id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        assert.are.equal("…eeeeee", SubToolUi.short_id(id))
    end)

    it("dispatch is inline only for single item with wait:true", function()
        assert.is_true(SubToolUi.dispatch_inline({ items = { { task = "x" } }, wait = true }))
        assert.is_false(SubToolUi.dispatch_inline({ items = { { task = "x" }, { task = "y" } }, wait = true }))
        assert.is_false(SubToolUi.dispatch_inline({ items = { { task = "x" } }, wait = false }))
    end)

    it("formats completion reports in zh and en", function()
        Config.setup({ title = { lang = "zh" } })
        assert.are.equal("[子会话「w」已完成] done", SubToolUi.completion_report("w", "done"))
        Config.setup({ title = { lang = "en" } })
        assert.are.equal('[Sub-session "w" completed] done', SubToolUi.completion_report("w", "done"))
    end)

    it("resolve_lang does not error when title.lang is unset", function()
        Config.setup({ title = {} })
        assert.has_no.errors(function()
            SubToolUi.resolve_lang()
        end)
    end)

    it("resolves zh from LANG when title.lang is unset", function()
        local old = vim.fn.getenv("LANG")
        vim.fn.setenv("LANG", "zh_CN.UTF-8")
        Config.setup({ title = {} })
        assert.are.equal("zh", SubToolUi.resolve_lang())
        if old == vim.NIL then
            vim.fn.setenv("LANG", "")
        else
            vim.fn.setenv("LANG", old)
        end
    end)

    it("renders multi-item dispatch block in history without error", function()
        local History = require("pi.ui.chat.history")
        Config.setup({ title = {}, render = { engine = "builtin" } })
        local h = History.new(991)
        assert.has_no.errors(function()
            h:on_tool_start("dispatch_subagents", "d-multi", {
                items = {
                    { ref = "a", task = "first task" },
                    { ref = "b", task = "second task" },
                },
                wait = false,
            })
        end)
        vim.wait(100)
        local lines = vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
        local header_found = false
        for _, line in ipairs(lines) do
            if line:find("派发", 1, true) or line:find("dispatch", 1, true) then
                header_found = true
                break
            end
        end
        assert.is_true(header_found, "dispatch block header should render")
        assert.is_true(#lines >= 3, "block mode should render item tree lines")
    end)

    it("renders dispatch block on_end when batch completes", function()
        local History = require("pi.ui.chat.history")
        Config.setup({ title = { lang = "zh" }, render = { engine = "builtin" } })
        local h = History.new(993)
        h._blocks_expanded = true
        local args = {
            items = {
                { ref = "a", task = "first task" },
                { ref = "b", task = "second task" },
            },
            wait = false,
        }
        h:on_tool_start("dispatch_subagents", "d-end", args)
        vim.wait(100)
        local result = {
            content = {
                {
                    type = "text",
                    text = vim.json.encode({
                        status = "completed",
                        summary = { done = 2, total = 2 },
                        items = {
                            { ref = "a", status = "ok", output = "result a" },
                            { ref = "b", status = "ok", output = "result b" },
                        },
                    }),
                },
            },
        }
        assert.has_no.errors(function()
            h:on_tool_end("dispatch_subagents", "d-end", result, false)
        end)
        vim.wait(100)
        local text = table.concat(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false), "\n")
        assert.matches("status:", text)
        assert.matches("✓", text)
        assert.matches("result a", text)
    end)

    it("renders dispatch block on_end with multiline output without error", function()
        local History = require("pi.ui.chat.history")
        Config.setup({ title = { lang = "en" }, render = { engine = "builtin" } })
        local h = History.new(994)
        h._blocks_expanded = true
        h:on_tool_start("dispatch_subagents", "d-ml", {
            items = { { ref = "a", task = "task" }, { ref = "b", task = "task2" } },
            wait = false,
        })
        vim.wait(100)
        local result = {
            content = {
                {
                    type = "text",
                    text = vim.json.encode({
                        status = "partial",
                        summary = { done = 1, total = 2 },
                        items = {
                            { ref = "a", status = "ok", output = "line1\nline2\nline3" },
                            { ref = "b", status = "failed", error = "boom\nstack\ntrace" },
                        },
                    }),
                },
            },
        }
        assert.has_no.errors(function()
            h:on_tool_end("dispatch_subagents", "d-ml", result, false)
        end)
        vim.wait(100)
        local text = table.concat(vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false), "\n")
        assert.matches("line1 line2", text)
        assert.matches("boom stack", text)
    end)

    it("renderer uses dynamic inline for dispatch", function()
        local renderer = Tools.get_renderer("dispatch_subagents")
        assert.is_true(Tools.is_inline(renderer, { items = { { task = "a" } }, wait = true }))
        assert.is_false(Tools.is_inline(renderer, { items = { { task = "a" }, { task = "b" } }, wait = true }))
    end)

    describe("item_config_label and dispatch rendering with model and thinking_level", function()
        it("returns nil when neither model nor thinking_level is present", function()
            assert.is_nil(SubToolUi.item_config_label({ task = "just task" }))
            assert.is_nil(SubToolUi.item_config_label(nil))
        end)

        it("formats model with table id", function()
            local label = SubToolUi.item_config_label({
                task = "test",
                model = { provider = "anthropic", id = "claude-3-7-sonnet" },
            })
            assert.are.equal("claude-3-7-sonnet", label)
        end)

        it("formats model with string id", function()
            local label = SubToolUi.item_config_label({
                task = "test",
                model = "gpt-4o",
            })
            assert.are.equal("gpt-4o", label)
        end)

        it("formats thinking_level alone", function()
            local label = SubToolUi.item_config_label({
                task = "test",
                thinking_level = "high",
            })
            assert.are.equal("think: high", label)
        end)

        it("supports think_level alias", function()
            local label = SubToolUi.item_config_label({
                task = "test",
                think_level = "low",
            })
            assert.are.equal("think: low", label)
        end)

        it("formats both model and thinking_level", function()
            local label = SubToolUi.item_config_label({
                task = "test",
                model = { provider = "anthropic", id = "claude-3-7-sonnet" },
                thinking_level = "high",
            })
            assert.are.equal("claude-3-7-sonnet · think: high", label)
        end)

        it("falls back to manifest config for target subagents", function()
            Manifest.upsert("child-cfg", {
                parent_id = "p",
                name = "worker-1",
                task_prompt = "t",
                config = {
                    model = { provider = "anthropic", id = "claude-3-5-haiku" },
                    thinking_level = "medium",
                },
                status = "active",
                reported = false,
                created_at = "t",
                last_active_at = "t",
            })
            local label = SubToolUi.item_config_label({
                target = "child-cfg",
                message = "continue work",
            })
            assert.are.equal("claude-3-5-haiku · think: medium", label)
        end)

        it("formats dispatch_header_detail with config for single item", function()
            local detail = SubToolUi.dispatch_header_detail({
                items = {
                    {
                        task = "analyze",
                        name = "analyzer",
                        model = { provider = "anthropic", id = "claude-3-7-sonnet" },
                        thinking_level = "high",
                    },
                },
            })
            assert.are.equal("analyzer (claude-3-7-sonnet · think: high)", detail)
        end)

        it("inline_text includes model and thinking level for single item", function()
            local renderer = Tools.get_renderer("dispatch_subagents")
            local text = renderer.inline_text({
                items = {
                    {
                        task = "single task",
                        name = "worker-single",
                        model = { provider = "openai", id = "gpt-4o" },
                        thinking_level = "off",
                    },
                },
                wait = true,
            })
            assert.are.equal("worker-single (gpt-4o · think: off)", text)
        end)

        it("renders model and thinking level in multi-item dispatch block lines", function()
            local History = require("pi.ui.chat.history")
            Config.setup({ title = { lang = "zh" }, render = { engine = "builtin" } })
            local h = History.new(995)
            h:on_tool_start("dispatch_subagents", "d-cfg-test", {
                items = {
                    {
                        ref = "t1",
                        name = "task-one",
                        task = "first task",
                        model = { provider = "anthropic", id = "claude-3-7-sonnet" },
                        thinking_level = "high",
                    },
                    {
                        ref = "t2",
                        name = "task-two",
                        task = "second task",
                        model = "gpt-4o",
                    },
                    {
                        ref = "t3",
                        name = "task-three",
                        task = "third task",
                    },
                },
                wait = false,
            })
            vim.wait(100)
            local lines = vim.api.nvim_buf_get_lines(h:buf(), 0, -1, false)
            local t1_found, t2_found, t3_found = false, false, false
            for _, line in ipairs(lines) do
                if line:find("[t1]", 1, true) and line:find("claude-3-7-sonnet · think: high", 1, true) then
                    t1_found = true
                end
                if line:find("[t2]", 1, true) and line:find("(gpt-4o)", 1, true) then
                    t2_found = true
                end
                if line:find("[t3]", 1, true) and line:find("task-three", 1, true) and not line:find("%(") then
                    t3_found = true
                end
            end
            assert.is_true(t1_found, "line for t1 should include model and thinking level")
            assert.is_true(t2_found, "line for t2 should include model alone")
            assert.is_true(t3_found, "line for t3 without config should not have parenthesis")
        end)
    end)
end)
