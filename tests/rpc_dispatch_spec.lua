-- Regression: RPC dispatch must be error-isolated and must settle waiters.
--
-- A handler or a one-shot response callback that throws used to propagate out
-- of _on_stdout, skipping the trailing-partial bookkeeping (`_stdout_parts =
-- { data[#data] }`) and permanently desyncing line reassembly. A process that
-- died with pending callbacks left those callbacks hanging forever. These
-- specs pin: (1) a throwing handler/callback does not abort dispatch, (2)
-- _on_exit replies failure to every waiter exactly once and still dispatches
-- _process_exit, (3) an intentional stop() stays silent.

local Config = require("pi.config")
local Rpc = require("pi.rpc")

Config.setup({})

local function jsonl(t)
    return vim.json.encode(t)
end

--- Rpc recording every dispatched message into `out`; throws for type "boom".
---@param out pi.RpcEvent[]
---@return pi.Rpc
local function make_rpc(out)
    local rpc = Rpc.new("test")
    rpc:set_handler(function(msg)
        if msg.type == "boom" then
            error("handler exploded on " .. tostring(msg.id))
        end
        out[#out + 1] = msg
    end)
    return rpc
end

--- Collect vim.notify calls while running `fn`, then flush scheduled ones.
---@param fn fun()
---@return { msg: string, level: integer }[]
local function capture_notifications(fn)
    local notifications = {} ---@type { msg: string, level: integer }[]
    local orig = vim.notify
    vim.notify = function(msg, level)
        notifications[#notifications + 1] = { msg = msg, level = level }
    end
    local ok, err = pcall(fn)
    vim.wait(200)
    vim.notify = orig
    if not ok then
        error(err)
    end
    return notifications
end

describe("rpc._dispatch error isolation", function()
    it("keeps decoding subsequent lines when the handler throws", function()
        local out = {}
        local rpc = make_rpc(out)
        local notifications
        local second = jsonl({ type = "second", id = "2" })
        local third = jsonl({ type = "third", id = "3" })
        local half = math.floor(#third / 2)
        notifications = capture_notifications(function()
            -- Line 1 throws inside the handler; line 2 must still dispatch.
            rpc:_on_stdout({ jsonl({ type = "boom", id = "1" }), second, "" })
            -- The trailing-partial bookkeeping must have survived the throw:
            -- the next partial line must reassemble into a clean message.
            rpc:_on_stdout({ third:sub(1, half) })
            rpc:_on_stdout({ third:sub(half + 1), "" })
        end)

        assert.equals(2, #out)
        assert.equals("second", out[1].type)
        assert.equals("third", out[2].type)

        -- The throw is reported, not swallowed.
        assert.is_true(#notifications > 0)
        assert.is_truthy(notifications[1].msg:find("RPC event handler error", 1, true))
        assert.is_truthy(notifications[1].msg:find("handler exploded", 1, true))
    end)

    it("keeps decoding subsequent lines when a pending callback throws", function()
        local out = {}
        local rpc = make_rpc(out)
        rpc._pending["test:1"] = function()
            error("callback exploded")
        end
        local notifications = capture_notifications(function()
            rpc:_on_stdout({
                jsonl({ type = "response", id = "test:1" }),
                jsonl({ type = "after", id = "2" }),
                "",
            })
        end)

        -- The failing callback was consumed, the following line still arrived.
        assert.is_nil(rpc._pending["test:1"])
        assert.equals(2, #out)
        assert.equals("response", out[1].type)
        assert.equals("after", out[2].type)

        assert.is_true(#notifications > 0)
        assert.is_truthy(notifications[1].msg:find("RPC response callback error", 1, true))
    end)
end)

describe("rpc._on_exit pending drain", function()
    it("settles every waiter with a synthetic failure and dispatches _process_exit", function()
        local seen = {} ---@type pi.RpcEvent[]
        local rpc = Rpc.new("test")
        rpc:set_handler(function(msg)
            seen[#seen + 1] = msg
        end)
        rpc._job_id = 1234

        local calls = {} ---@type pi.RpcEvent[]
        rpc._pending["test:1"] = function(msg)
            calls[#calls + 1] = msg
        end
        rpc._pending["test:2"] = function(msg)
            calls[#calls + 1] = msg
        end

        rpc:_on_exit(7)

        assert.is_nil(rpc._job_id)
        assert.are.same({}, rpc._pending)
        assert.equals(2, #calls)
        for _, msg in ipairs(calls) do
            assert.equals("response", msg.type)
            assert.is_false(msg.success)
            assert.equals("process exited (code 7)", msg.error)
        end
        assert.is_truthy(calls[1].id == "test:1" or calls[1].id == "test:2")

        -- The exit event itself still reaches the handler.
        assert.equals(1, #seen)
        assert.equals("_process_exit", seen[1].type)
        assert.equals(7, seen[1].code)
    end)

    it("still settles the remaining waiters when one of them throws", function()
        local rpc = Rpc.new("test")
        rpc:set_handler(function() end)
        local calls = {} ---@type pi.RpcEvent[]
        local notifications = capture_notifications(function()
            rpc._pending["test:bad"] = function()
                error("waiter exploded")
            end
            rpc._pending["test:good"] = function(msg)
                calls[#calls + 1] = msg
            end
            rpc:_on_exit(1)
        end)

        assert.equals(1, #calls)
        assert.equals("test:good", calls[1].id)
        assert.is_false(calls[1].success)
        assert.are.same({}, rpc._pending)
        assert.is_true(#notifications > 0)
        assert.is_truthy(notifications[1].msg:find("RPC response callback error", 1, true))
    end)

    it("does not fire callbacks after an intentional stop()", function()
        local rpc = Rpc.new("test")
        rpc:set_handler(function() end)
        local job = vim.fn.jobstart({ "sleep", "5" })
        assert.is_true(job > 0)
        rpc._job_id = job
        local called = false
        rpc._pending["test:1"] = function()
            called = true
        end

        -- stop() clears _pending before the async on_exit dispatch.
        rpc:stop()
        assert.is_nil(rpc._job_id)
        rpc:_on_exit(0)

        assert.is_false(called)
        assert.are.same({}, rpc._pending)
    end)
end)
