--- User command registration.

local M = {}

---@type table<string, string[]>
local flag_values = { layout = { "side", "float" } }

---@param args string
---@return pi.SessionCreateOpts
local function parse_flags(args)
    ---@type pi.SessionCreateOpts
    local flags = {}
    local layout = args:match("layout=(%S+)")
    if layout == "side" or layout == "float" then
        flags.layout = layout
    end
    return flags
end

---@param prefix string
---@return string[]
local function complete_flags(prefix)
    ---@type string[]
    local candidates = {}
    for k, vals in pairs(flag_values) do
        for _, v in ipairs(vals) do
            candidates[#candidates + 1] = k .. "=" .. v
        end
    end
    table.sort(candidates)
    return vim.tbl_filter(function(c)
        return c:find(prefix, 1, true) == 1
    end, candidates)
end

--- Handle :PiSteeringMode / :PiFollowUpMode. With a `mode` argument, set it
--- directly (validated by the public setter); without one, read the backend's
--- current value via `get_state` and switch to the other mode.
---@param kind "steering"|"follow_up"
---@param mode? string
local function queue_mode_command(kind, mode)
    local Pi = require("pi")
    local is_steering = kind == "steering"
    local setter = is_steering and Pi.set_steering_mode or Pi.set_follow_up_mode
    local field = is_steering and "steeringMode" or "followUpMode"
    local label = is_steering and "steering" or "follow-up"

    if mode and mode ~= "" then
        setter(mode)
        return
    end

    local Notify = require("pi.notify")
    local session = require("pi.sessions.manager").get()
    if not session or not session.rpc:is_running() then
        Notify.warn("No active session")
        return
    end

    session.rpc:send({ type = "get_state" }, function(res)
        vim.schedule(function()
            local current
            if res.success and type(res.data) == "table" then
                current = res.data[field]
            end
            if current == nil then
                Notify.error("Failed to read " .. label .. " mode")
                return
            end
            setter(current == "all" and "one-at-a-time" or "all")
        end)
    end)
end

function M.setup()
    local Pi = require("pi")

    vim.api.nvim_create_user_command("Pi", function(cmd)
        Pi.toggle(parse_flags(cmd.args))
    end, { nargs = "*", complete = complete_flags, desc = "Show or toggle π chat" })

    vim.api.nvim_create_user_command("PiNewTab", function()
        Pi.new_tab()
    end, { desc = "Open a fresh π session in a new tab" })

    vim.api.nvim_create_user_command("PiContinue", function(cmd)
        Pi.continue_session(parse_flags(cmd.args))
    end, { nargs = "*", complete = complete_flags, desc = "Continue last π conversation" })

    vim.api.nvim_create_user_command("PiResume", function(cmd)
        Pi.resume_session(parse_flags(cmd.args))
    end, { nargs = "*", complete = complete_flags, desc = "Select a past π conversation" })

    vim.api.nvim_create_user_command("PiToggleChat", function()
        Pi.toggle_chat()
    end, { desc = "Toggle π chat window" })

    vim.api.nvim_create_user_command("PiToggleLayout", function()
        Pi.toggle_layout()
    end, { desc = "Toggle π layout (side/float)" })

    vim.api.nvim_create_user_command("PiAbort", function()
        Pi.abort()
    end, { desc = "Abort current π operation" })

    vim.api.nvim_create_user_command("PiAbortBash", function()
        Pi.abort_bash()
    end, { desc = "Abort the running direct bash (!) command" })

    vim.api.nvim_create_user_command("PiSteeringMode", function(cmd)
        queue_mode_command("steering", cmd.args)
    end, { nargs = "?", desc = "Set or cycle π steering queued-message mode (all/one-at-a-time)" })

    vim.api.nvim_create_user_command("PiFollowUpMode", function(cmd)
        queue_mode_command("follow_up", cmd.args)
    end, { nargs = "?", desc = "Set or cycle π follow-up queued-message mode (all/one-at-a-time)" })

    vim.api.nvim_create_user_command("PiStop", function()
        Pi.stop()
    end, { desc = "Stop π process and close chat" })

    vim.api.nvim_create_user_command("PiAttention", function()
        Pi.attention()
    end, { desc = "Open the next pending π attention request" })

    vim.api.nvim_create_user_command("PiNewSession", function()
        Pi.new_session()
    end, { desc = "Start new π session" })

    vim.api.nvim_create_user_command("PiTree", function()
        Pi.tree()
    end, { desc = "Navigate π session tree" })

    vim.api.nvim_create_user_command("PiFork", function()
        Pi.fork()
    end, { desc = "Fork π session from a past message" })

    vim.api.nvim_create_user_command("PiClone", function()
        Pi.clone()
    end, { desc = "Duplicate current π session branch into a new session" })

    vim.api.nvim_create_user_command("PiSessions", function()
        Pi.sessions()
    end, { desc = "Toggle π sessions overview list" })

    vim.api.nvim_create_user_command("PiTasks", function()
        Pi.tasks()
    end, { desc = "Toggle π background tasks panel" })

    vim.api.nvim_create_user_command("PiSessionStats", function()
        Pi.session_stats()
    end, { desc = "Show π session stats dashboard (tokens, cost, context)" })

    vim.api.nvim_create_user_command("PiDiff", function()
        Pi.diff_review()
    end, { desc = "Review the git diff of every file changed in the current session" })

    vim.api.nvim_create_user_command("PiToggleThinking", function()
        Pi.toggle_thinking()
    end, { desc = "Toggle π thinking visibility" })

    vim.api.nvim_create_user_command("PiToggleStartupDetails", function()
        Pi.toggle_startup_details()
    end, { desc = "Toggle π startup details between compact and expanded" })

    vim.api.nvim_create_user_command("PiCycleThinking", function()
        Pi.cycle_thinking_level()
    end, { desc = "Cycle π thinking level" })

    vim.api.nvim_create_user_command("PiSelectThinking", function()
        Pi.select_thinking_level()
    end, { desc = "Select π thinking level" })

    vim.api.nvim_create_user_command("PiCycleModel", function()
        Pi.cycle_model()
    end, { desc = "Cycle π model" })

    vim.api.nvim_create_user_command("PiSelectModel", function()
        Pi.select_model()
    end, { desc = "Select π model" })

    vim.api.nvim_create_user_command("PiSelectModelAll", function()
        Pi.select_model_all()
    end, { desc = "Select π model from all available (searchable)" })

    vim.api.nvim_create_user_command("PiSendMention", function(args)
        Pi.send_mention(args)
    end, { range = true, desc = "Send file or selection as @mention to Pi prompt" })

    vim.api.nvim_create_user_command("PiAttachImage", function(cmd)
        Pi.attach_image(cmd.args)
    end, { nargs = 1, complete = "file", desc = "Attach image file at path to π prompt" })

    vim.api.nvim_create_user_command("PiPasteImage", function()
        Pi.paste_image()
    end, { desc = "Paste an image from the clipboard as π attachment" })

    vim.api.nvim_create_user_command("PiCompact", function(cmd)
        local instructions = cmd.args ~= "" and cmd.args or nil
        Pi.compact(instructions)
    end, { nargs = "?", desc = "Compact π conversation context" })

    vim.api.nvim_create_user_command("PiToggleAutoCompaction", function()
        Pi.toggle_auto_compaction()
    end, { desc = "Toggle π automatic context compaction" })

    vim.api.nvim_create_user_command("PiSessionName", function(cmd)
        local name = cmd.args ~= "" and cmd.args or nil
        Pi.set_session_name(name)
    end, { nargs = "?", desc = "Set or show π session display name" })

    vim.api.nvim_create_user_command("PiToggleDebug", function()
        Pi.toggle_debug()
    end, { desc = "Toggle π RPC debug logging" })

    vim.api.nvim_create_user_command("PiSubNew", function()
        Pi.sub_new()
    end, { desc = "Spawn a sub-session with a task prompt" })

    vim.api.nvim_create_user_command("PiSubSwitch", function()
        Pi.sub_switch()
    end, { desc = "Switch to a sub-session of the current conversation" })

    vim.api.nvim_create_user_command("PiSubParent", function()
        Pi.sub_parent()
    end, { desc = "Return to the parent session" })

    vim.api.nvim_create_user_command("PiSubClose", function()
        Pi.sub_close()
    end, { desc = "Close the current sub-session process (file retained)" })

    vim.api.nvim_create_user_command("PiSubView", function()
        Pi.sub_view()
    end, { desc = "View sub-session in a read-only float" })

    vim.api.nvim_create_user_command("PiTodo", function()
        require("pi.todo").toggle()
    end, { desc = "Toggle the todo sidebar panel" })

    vim.api.nvim_create_user_command("PiWebStart", function()
        local ok, err = pcall(require("pi.web").start)
        if not ok then
            require("pi.notify").error("Web console failed to start: " .. tostring(err))
            return
        end
        require("pi.notify").info(
            "Web console started (workspace " .. tostring(require("pi.web").status().workspace_id) .. ")"
        )
    end, { desc = "Start the π² web console bridge (pi2d)" })

    vim.api.nvim_create_user_command("PiWebStop", function()
        require("pi.web").stop()
        require("pi.notify").info("Web console stopped")
    end, { desc = "Stop the π² web console bridge" })

    vim.api.nvim_create_user_command("PiWebStatus", function()
        require("pi.notify").info(table.concat(require("pi.web").status_lines(), "\n"))
    end, { desc = "Show π² web console bridge status" })
end

return M
