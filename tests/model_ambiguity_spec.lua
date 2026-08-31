-- Provider-ambiguity suffix for the statusline model component: the session
-- manager reconciles the current model (from get_state) against the backend
-- model list (get_available_models) and pushes a "[provider]" (or
-- "[provider@host]") suffix to the statusline when the same model id is
-- served by several providers/endpoints. These specs drive the manager
-- against a stubbed Rpc with canned responses.

local Config = require("pi.config")
local Rpc = require("pi.rpc")
local Sessions = require("pi.sessions.manager")

Config.setup({})

local real_rpc = { start = Rpc.start, stop = Rpc.stop, send = Rpc.send }

--- Commands sent through the stub, in order.
local sent = {}
--- type -> fun(cmd): pi.RpcEvent; nil responder = never answered.
local responders = {}
local notes = {}

--- How often get_available_models was requested.
local function models_fetch_count()
    local n = 0
    for _, cmd in ipairs(sent) do
        if cmd.type == "get_available_models" then
            n = n + 1
        end
    end
    return n
end

local function install_stub()
    sent = {}
    responders = {}
    notes = {}

    Rpc.start = function(self)
        self._job_id = 999
        return true
    end
    Rpc.stop = function(self)
        self._job_id = nil
        self._pending = {}
    end
    Rpc.send = function(self, cmd, callback)
        if not self._job_id then
            return false
        end
        if not cmd.id then
            cmd.id = self._tab .. ":" .. self._req_id
            self._req_id = self._req_id + 1
        end
        sent[#sent + 1] = vim.deepcopy(cmd)
        local responder = responders[cmd.type]
        if callback and responder then
            local res = responder(cmd)
            vim.schedule(function()
                callback(res)
            end)
        end
        return true
    end

    vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
    end

    responders.get_commands = function()
        return { type = "response", success = true, data = { commands = {} } }
    end
    responders.get_state = function()
        return {
            type = "response",
            success = true,
            data = {
                model = { provider = "qwen", id = "qwen3-max", baseUrl = "https://api.qwen.example" },
                thinkingLevel = "off",
            },
        }
    end
    -- Default backend model list: qwen3-max served by two providers.
    responders.get_available_models = function()
        return {
            type = "response",
            success = true,
            data = {
                models = {
                    { provider = "qwen", id = "qwen3-max", baseUrl = "https://api.qwen.example" },
                    { provider = "openrouter", id = "qwen3-max", baseUrl = "https://openrouter.ai/api/v1" },
                    { provider = "kimi-coding", id = "k3", baseUrl = "https://api.kimi.example" },
                },
            },
        }
    end
end

local function restore_stub()
    Sessions.stop()
    Rpc.start = real_rpc.start
    Rpc.stop = real_rpc.stop
    Rpc.send = real_rpc.send
end

--- Wait until fn() is truthy; fail the spec with `what` otherwise.
local function wait_or_fail(fn, what)
    assert(vim.wait(3000, fn, 10), what)
end

--- Current ambiguity suffix displayed by the session's statusline.
---@param session pi.Session
---@return string?
local function displayed_suffix(session)
    return session.chat._prompt:statusline()._state.model_ambiguity_suffix
end

describe("model provider ambiguity in the statusline", function()
    before_each(function()
        install_stub()
    end)

    after_each(function()
        restore_stub()
    end)

    it("pushes a [provider] suffix when the model id is served by several providers", function()
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return displayed_suffix(session) == "[qwen]"
        end, "ambiguity suffix was not pushed")
        assert.are.equal(1, models_fetch_count())
    end)

    it("reuses the cached model list within the TTL instead of refetching", function()
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return displayed_suffix(session) == "[qwen]"
        end, "ambiguity suffix was not pushed")

        Sessions.refresh_state(session)
        wait_or_fail(function()
            return models_fetch_count() >= 1
        end, "initial fetch was not sent")
        -- A second refresh shortly after must not refetch the list.
        vim.wait(50)
        local before = models_fetch_count()
        Sessions.refresh_state(session)
        vim.wait(100)
        assert.are.equal(before, models_fetch_count(), "cached list must be reused within the TTL")
        assert.are.equal("[qwen]", displayed_suffix(session))
    end)

    it("stays at the bare id when the model is unambiguous", function()
        responders.get_state = function()
            return {
                type = "response",
                success = true,
                data = { model = { provider = "kimi-coding", id = "k3" }, thinkingLevel = "off" },
            }
        end
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return displayed_suffix(session) == nil
        end, "unambiguous model must keep the suffix nil")
        assert.are.equal(nil, displayed_suffix(session))
    end)

    it("stays at the bare id when the list fetch fails (silent)", function()
        responders.get_available_models = function()
            return { type = "response", success = false, error = "boom" }
        end
        local session = Sessions.get_or_create()
        assert.is_not_nil(session)
        wait_or_fail(function()
            return models_fetch_count() >= 1
        end, "list fetch was not attempted")
        vim.wait(100)
        assert.is_nil(displayed_suffix(session), "failed fetch must not push a suffix")
        assert.are.equal(0, #notes, "failure must stay silent (no notify)")
    end)
end)
