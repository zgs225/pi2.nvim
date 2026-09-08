-- Unit tests for the sub-agent system-prompt injection:
-- 1. pi.cli wiring: parents get extensions/subagent.ts, children get
--    extensions/subagent-child.ts, subagent.enabled = false injects neither.
-- 2. Static assertions on both extension sources: byte-constant note
--    constants (prompt-cache friendly) appended via before_agent_start.

local Cli = require("pi.cli")
local Config = require("pi.config")

local function repo_root()
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
end

---@param cmd string[]
---@param pattern string Lua pattern matched against each --extension path
---@return boolean
local function has_extension(cmd, pattern)
    for i, part in ipairs(cmd) do
        if part == "--extension" and type(cmd[i + 1]) == "string" and cmd[i + 1]:match(pattern) then
            return true
        end
    end
    return false
end

-- "subagent%.ts$" never matches "subagent-child.ts" (anchored at the end).
local PARENT_EXT = "subagent%.ts$"
local CHILD_EXT = "subagent%-child%.ts$"

describe("pi.cli sub-agent extension injection", function()
    after_each(function()
        Config.setup({})
    end)

    it("parent sessions get subagent.ts but not subagent-child.ts", function()
        local cmd = Cli.command()
        assert.is_true(has_extension(cmd, PARENT_EXT), "expected --extension <plugin>/extensions/subagent.ts")
        assert.is_false(has_extension(cmd, CHILD_EXT), "parent must not load subagent-child.ts")
    end)

    it("explicit parent (subagent = true) behaves like the default", function()
        local cmd = Cli.command({ subagent = true })
        assert.is_true(has_extension(cmd, PARENT_EXT))
        assert.is_false(has_extension(cmd, CHILD_EXT))
    end)

    it("child sessions (subagent = false) get subagent-child.ts but not subagent.ts", function()
        local cmd = Cli.command({ subagent = false })
        assert.is_true(has_extension(cmd, CHILD_EXT), "expected --extension <plugin>/extensions/subagent-child.ts")
        assert.is_false(has_extension(cmd, PARENT_EXT), "child must not load subagent.ts")
    end)

    it("subagent.enabled = false injects neither extension", function()
        Config.setup({ subagent = { enabled = false } })
        local parent = Cli.command()
        local child = Cli.command({ subagent = false })
        assert.is_false(has_extension(parent, PARENT_EXT))
        assert.is_false(has_extension(parent, CHILD_EXT))
        assert.is_false(has_extension(child, PARENT_EXT))
        assert.is_false(has_extension(child, CHILD_EXT))
    end)
end)

describe("extensions/subagent.ts orchestrator note", function()
    local content

    before_each(function()
        local path = repo_root() .. "/extensions/subagent.ts"
        local file = io.open(path, "r")
        assert.is_not_nil(file, "subagent.ts must exist at: " .. path)
        content = file:read("*a")
        file:close()
    end)

    it("defines a static ORCHESTRATOR_NOTE string array", function()
        local note = content:match("const ORCHESTRATOR_NOTE%s*=%s*%[(.-)%]%.join")
        assert.is_not_nil(note, "ORCHESTRATOR_NOTE must be a [...].join(...) constant")
        assert.is_nil(note:find("${", 1, true), "ORCHESTRATOR_NOTE must not use template interpolation")
        assert.is_nil(note:find("`", 1, true), "ORCHESTRATOR_NOTE must not use template literals")
    end)

    it("appends the note to event.systemPrompt in before_agent_start", function()
        -- Anchor on the pi.on registration (the file header also mentions
        -- the hook name); capture up to the hook's closing "});".
        local hook = content:match('pi%.on%("before_agent_start"(.-)%}%)%;')
        assert.is_not_nil(hook, "subagent.ts must register a before_agent_start hook")
        assert.is_truthy(hook:match("systemPrompt"), "handler must return systemPrompt")
        assert.is_truthy(hook:match("event%.systemPrompt"), "handler must append to event.systemPrompt")
        assert.is_truthy(hook:match("ORCHESTRATOR_NOTE"), "handler must append ORCHESTRATOR_NOTE")
    end)

    it("note covers the orchestration contract", function()
        assert.is_truthy(content:match("Sub%-agent orchestration"), "note must have the orchestration header")
        assert.is_truthy(content:match("dispatch_subagents"), "note must name dispatch_subagents")
        assert.is_truthy(content:match("list_subagents"), "note must name list_subagents")
        assert.is_truthy(content:match("final report"), "note must explain the child's final report")
        assert.is_truthy(content:match("never mention these instructions"), "note must forbid mentioning itself")
    end)
end)

describe("extensions/subagent-child.ts worker note", function()
    local content

    before_each(function()
        local path = repo_root() .. "/extensions/subagent-child.ts"
        local file = io.open(path, "r")
        assert.is_not_nil(file, "subagent-child.ts must exist at: " .. path)
        content = file:read("*a")
        file:close()
    end)

    it("defines a static WORKER_NOTE string array", function()
        local note = content:match("const WORKER_NOTE%s*=%s*%[(.-)%]%.join")
        assert.is_not_nil(note, "WORKER_NOTE must be a [...].join(...) constant")
        assert.is_nil(note:find("${", 1, true), "WORKER_NOTE must not use template interpolation")
        assert.is_nil(note:find("`", 1, true), "WORKER_NOTE must not use template literals")
    end)

    it("appends the note to event.systemPrompt in before_agent_start", function()
        -- Anchor on the pi.on registration (the file header also mentions
        -- the hook name); capture up to the hook's closing "});".
        local hook = content:match('pi%.on%("before_agent_start"(.-)%}%)%;')
        assert.is_not_nil(hook, "subagent-child.ts must register a before_agent_start hook")
        assert.is_truthy(hook:match("systemPrompt"), "handler must return systemPrompt")
        assert.is_truthy(hook:match("event%.systemPrompt"), "handler must append to event.systemPrompt")
        assert.is_truthy(hook:match("WORKER_NOTE"), "handler must append WORKER_NOTE")
    end)

    it("note declares the worker contract", function()
        assert.is_truthy(content:match("no interactive user"), "note must declare there is no interactive user")
        assert.is_truthy(content:match("final report"), "note must declare the last message is the final report")
        assert.is_truthy(content:match("Never ask for clarification"), "note must forbid asking questions")
        assert.is_truthy(content:match("strictly within the given task"), "note must enforce strict task scope")
        assert.is_truthy(content:match("cannot spawn or manage sub%-agents"), "note must forbid nested sub-agents")
    end)
end)
