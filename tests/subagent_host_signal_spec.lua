-- Static verification spec for subagent.ts AbortSignal propagation to hostRequest.

describe("extensions/subagent.ts AbortSignal forwarding", function()
    local content

    before_each(function()
        local ts_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/extensions/subagent.ts"
        local file = io.open(ts_path, "r")
        assert.is_not_nil(file, "subagent.ts must exist at: " .. ts_path)
        content = file:read("*a")
        file:close()
    end)

    it("hostRequest declaration accepts an optional signal parameter", function()
        local host_request_decl = content:match("async function hostRequest%(([^%)]*)%)")
        assert.is_not_nil(host_request_decl, "hostRequest declaration must be found")
        assert.is_truthy(
            host_request_decl:match("signal%?:%s*AbortSignal"),
            "hostRequest parameter list must include optional signal: AbortSignal, got: " .. host_request_decl
        )
    end)

    it("ctx.ui.select call in hostRequest passes third argument referencing signal", function()
        local select_call = content:match("ctx%.ui%.select%([^%)]+%)")
        assert.is_not_nil(select_call, "ctx.ui.select call must be found in subagent.ts")
        assert.is_truthy(
            select_call:match("HOST_TITLE%s*,%s*%[%s*payload%s*%]%s*,%s*([^%)]+)"),
            "ctx.ui.select must receive 3 arguments with HOST_TITLE and [payload], got: " .. select_call
        )
        local opts_arg = select_call:match("HOST_TITLE%s*,%s*%[%s*payload%s*%]%s*,%s*(.-)%s*%)")
        assert.is_not_nil(opts_arg, "Third argument (options) must be present in select call")
        assert.is_truthy(
            opts_arg:match("signal"),
            "Third argument in select call must reference signal, got: " .. opts_arg
        )
    end)

    it("wait_subagents execute passes signal into hostRequest", function()
        local params, body = content:match('name:%s*"wait_subagents".-async execute%s*(%b())%s*(%b{})')
        assert.is_not_nil(params, "wait_subagents parameters must exist")
        assert.is_not_nil(body, "wait_subagents body must exist")
        assert.is_truthy(
            params:match("[%s,]signal[%s,]"),
            "wait_subagents execute parameter list must accept `signal` (not `_signal`), got: " .. params
        )
        assert.is_truthy(
            body:match('hostRequest%(ctx,%s*"wait_subagents",%s*params,%s*signal%)'),
            "wait_subagents execute body must pass signal to hostRequest, got: " .. body
        )
    end)

    it("dispatch_subagents execute passes signal into hostRequest", function()
        local params, body = content:match('name:%s*"dispatch_subagents".-async execute%s*(%b())%s*(%b{})')
        assert.is_not_nil(params, "dispatch_subagents parameters must exist")
        assert.is_not_nil(body, "dispatch_subagents body must exist")
        assert.is_truthy(
            params:match("[%s,]signal[%s,]"),
            "dispatch_subagents execute parameter list must accept `signal` (not `_signal`), got: " .. params
        )
        assert.is_truthy(
            body:match('hostRequest%(ctx,%s*"dispatch_subagents",%s*params,%s*signal%)'),
            "dispatch_subagents execute body must pass signal to hostRequest, got: " .. body
        )
    end)

    it("all other tunneled tools pass signal into hostRequest", function()
        local poll_params, poll_body = content:match('name:%s*"poll_subagents".-async execute%s*(%b())%s*(%b{})')
        assert.is_not_nil(poll_params, "poll_subagents params must exist")
        assert.is_truthy(poll_params:match("[%s,]signal[%s,]"), "poll_subagents must accept signal")
        assert.is_truthy(
            poll_body:match('hostRequest%(ctx,%s*"poll_subagents",%s*params,%s*signal%)'),
            "poll_subagents must pass signal to hostRequest"
        )

        local list_params, list_body = content:match('name:%s*"list_batches".-async execute%s*(%b())%s*(%b{})')
        assert.is_not_nil(list_params, "list_batches params must exist")
        assert.is_truthy(list_params:match("[%s,]signal[%s,]"), "list_batches must accept signal")
        assert.is_truthy(
            list_body:match('hostRequest%(ctx,%s*"list_batches",%s*%{%}%s*,%s*signal%)'),
            "list_batches must pass signal to hostRequest"
        )

        local stop_params, stop_body = content:match('name:%s*"stop_subagents".-async execute%s*(%b())%s*(%b{})')
        assert.is_not_nil(stop_params, "stop_subagents params must exist")
        assert.is_truthy(stop_params:match("[%s,]signal[%s,]"), "stop_subagents must accept signal")
        assert.is_truthy(
            stop_body:match('hostRequest%(ctx,%s*"stop_subagents",%s*params,%s*signal%)'),
            "stop_subagents must pass signal to hostRequest"
        )
    end)

    it("observation tools do not tunnel through hostRequest and keep _signal", function()
        local list_tool = content:match('name:%s*"list_subagents".-async execute%((.-)%)%s*{.-return toolResult')
        assert.is_not_nil(list_tool, "list_subagents must exist")
        assert.is_truthy(list_tool:match("_signal"), "list_subagents should keep _signal as it reads disk directly")
        assert.is_nil(list_tool:match("hostRequest"), "list_subagents must not call hostRequest")

        local read_tool = content:match('name:%s*"read_subagent".-async execute%((.-)%)%s*{.-return toolResult')
        assert.is_not_nil(read_tool, "read_subagent must exist")
        assert.is_truthy(read_tool:match("_signal"), "read_subagent should keep _signal as it reads disk directly")
        assert.is_nil(read_tool:match("hostRequest"), "read_subagent must not call hostRequest")
    end)
end)
