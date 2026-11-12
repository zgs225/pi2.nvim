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

--- Complete existing worktree names for `:PiWorktreeApply/Ship/Remove`.
--- Names come from `<repo>/.worktrees/*`, where the repository root is the
--- current session's worktree root or (falling back) the git checkout its cwd
--- lives in. Completion is best-effort: no worktree module / not in a repo
--- simply yields no candidates, never an error.
---@param prefix string
---@return string[]
local function complete_worktree_names(prefix)
    local ok, Worktree = pcall(require, "pi.worktree")
    if not ok or type(Worktree) ~= "table" or type(Worktree.detect) ~= "function" then
        return {}
    end
    local session = require("pi.sessions.manager").get()
    local current = session and type(session.worktree) == "table" and session.worktree or nil
    local repo_root = current and current.repo_root or nil
    if type(repo_root) ~= "string" or repo_root == "" then
        local cwd = (session and session.cwd) or vim.fn.getcwd()
        local detected = Worktree.detect(cwd)
        repo_root = type(detected) == "table" and detected.repo_root or nil
    end
    if type(repo_root) ~= "string" or repo_root == "" then
        return {}
    end

    ---@type string[]
    local names = {}
    for _, path in ipairs(vim.fn.glob(repo_root .. "/.worktrees/*", false, true)) do
        if vim.fn.isdirectory(path) == 1 then
            local name = vim.fn.fnamemodify(path, ":t")
            local valid = true
            if type(Worktree.validate_name) == "function" then
                valid = Worktree.validate_name(name) == true
            end
            if valid and name:find(prefix, 1, true) == 1 then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    return names
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

    vim.api.nvim_create_user_command("PiWorktreeNew", function(cmd)
        Pi.worktree_new({ name = cmd.args ~= "" and cmd.args or nil })
    end, { nargs = "?", desc = "Start a fresh π session in a new git worktree" })

    vim.api.nvim_create_user_command("PiWorktreeFork", function(cmd)
        Pi.worktree_fork({ name = cmd.args ~= "" and cmd.args or nil })
    end, { nargs = "?", desc = "Fork the current π session into a new git worktree" })

    vim.api.nvim_create_user_command("PiWorktreeBranch", function(cmd)
        Pi.worktree_branch(cmd.args)
    end, { nargs = 1, desc = "Put the current worktree π session on a branch" })

    vim.api.nvim_create_user_command("PiWorktreeApply", function(cmd)
        Pi.worktree_apply({ name = cmd.args ~= "" and cmd.args or nil })
    end, {
        nargs = "?",
        complete = complete_worktree_names,
        desc = "Review a worktree patch and apply it to the main checkout",
    })

    vim.api.nvim_create_user_command("PiWorktreeShip", function(cmd)
        Pi.worktree_ship({ name = cmd.args ~= "" and cmd.args or nil })
    end, {
        nargs = "?",
        complete = complete_worktree_names,
        desc = "Prefill the chat prompt with worktree ship instructions",
    })

    vim.api.nvim_create_user_command("PiWorktreeRemove", function(cmd)
        Pi.worktree_remove({ name = cmd.args ~= "" and cmd.args or nil })
    end, {
        nargs = "?",
        complete = complete_worktree_names,
        desc = "Confirm and remove a worktree (snapshot first)",
    })

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
end

return M
