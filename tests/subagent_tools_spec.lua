local Config = require("pi.config")
local Tools = require("pi.ui.chat.tools")
local SubToolUi = require("pi.subsessions.tool_ui")

Config.setup({ title = { lang = "zh" } })

local nf = function(cp)
    return vim.fn.nr2char(cp, 1)
end

describe("subagent tool icons", function()
    it("uses dedicated nerd-font icons instead of the generic fallback", function()
        local generic = Config.options.labels.tool
        assert.are.equal(nf(0xF0D0B), Tools.get_tool_icon("list_subagents"))
        assert.are.equal(nf(0xF0229), Tools.get_tool_icon("read_subagent"))
        assert.are.equal(nf(0xF0E6F), Tools.get_tool_icon("dispatch_subagents"))
        assert.are.equal(nf(0xF051C), Tools.get_tool_icon("poll_subagents"))
        assert.are.equal(nf(0xF0955), Tools.get_tool_icon("wait_subagents"))
        assert.are.equal(nf(0xF0680), Tools.get_tool_icon("stop_subagents"))
        assert.is_not(generic, Tools.get_tool_icon("dispatch_subagents"))
    end)

    it("uses localized display names", function()
        assert.are.equal("子·派发", Tools.tool_display_name("dispatch_subagents", {}))
    end)

    it("dispatch block mode shows mixed item summary", function()
        local renderer = Tools.get_renderer("dispatch_subagents")
        local detail = renderer.inline_text({
            items = {
                { task = "a" },
                { target = "id", message = "m" },
            },
        })
        assert.matches("2 项", detail)
    end)
end)
