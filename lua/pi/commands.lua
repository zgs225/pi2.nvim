--- User command registration.

local M = {}

---@type table<string, string[]>
local flag_values = { layout = { "side", "float" } }

--- Worktree names of the current session's repository.
---
--- Names come from the repository's worktree root (`Worktree.worktrees_root`),
--- where the repository root is the current session's worktree root or (falling
--- back) the git checkout its cwd lives in. Best-effort: no worktree module / not
--- in a repo simply yields no candidates, never an error. Runs synchronously (it
--- is a command completion callback), so it lists the directory instead of using
--- the asynchronous `Worktree.list`.
---@return string[]
local function worktree_names()
    local ok, Worktree = pcall(require, "pi.worktree")
    if
        not ok
        or type(Worktree) ~= "table"
        or type(Worktree.detect) ~= "function"
        or type(Worktree.worktrees_root) ~= "function"
    then
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
    for _, path in ipairs(vim.fn.glob(Worktree.worktrees_root(repo_root) .. "/*", false, true)) do
        if vim.fn.isdirectory(path) == 1 then
            local name = vim.fn.fnamemodify(path, ":t")
            local valid = true
            if type(Worktree.validate_name) == "function" then
                valid = Worktree.validate_name(name) == true
            end
            if valid then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    return names
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
    for _, name in ipairs(worktree_names()) do
        candidates[#candidates + 1] = "worktree=" .. name
    end
    table.sort(candidates)
    return vim.tbl_filter(function(c)
        return c:find(prefix, 1, true) == 1
    end, candidates)
end

--- Flags parsed from a `:Pi*` argument list.
---
--- `worktree` is kept beside `pi.SessionCreateOpts` on purpose: only `:Pi` and
--- `:PiNewTab` act on it (`pi.worktree_open`), while the continue/resume paths
--- forward their opts to the session manager and refuse the combination
--- instead of silently dropping the flag.
---@class pi.CommandFlags
---@field opts pi.SessionCreateOpts Session creation opts (`layout=`).
---@field worktree? string Existing worktree name from `worktree=<name>`.
---@field worktree_error? string Set when `worktree=` carries no name.

---@param args string
---@return pi.CommandFlags
local function parse_flags(args)
    ---@type pi.SessionCreateOpts
    local opts = {}
    local layout = args:match("layout=(%S+)")
    if layout == "side" or layout == "float" then
        opts.layout = layout
    end

    ---@type pi.CommandFlags
    local flags = { opts = opts }
    local worktree = args:match("worktree=(%S*)")
    if worktree ~= nil then
        worktree = vim.trim(worktree)
        if worktree == "" then
            flags.worktree_error = "worktree= requires a worktree name"
        else
            flags.worktree = worktree
        end
    end
    return flags
end

--- Reject a malformed `worktree=` value (`worktree=` with nothing after it).
---@param flags pi.CommandFlags
---@return boolean ok
local function check_worktree_value(flags)
    if not flags.worktree_error then
        return true
    end
    require("pi.notify").error(flags.worktree_error)
    return false
end

--- `worktree=` starts a fresh conversation in an *existing* checkout, while
--- continue/resume pick their own workspace — combining them is ambiguous, so
--- refuse the flag instead of silently ignoring it.
---@param flags pi.CommandFlags
---@param command string
---@return boolean ok
local function reject_worktree_flag(flags, command)
    if not check_worktree_value(flags) then
        return false
    end
    if not flags.worktree then
        return true
    end
    require("pi.notify").warn(command .. " does not take worktree=<name>; use :PiNewTab worktree=" .. flags.worktree)
    return false
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
        local flags = parse_flags(cmd.args)
        if not check_worktree_value(flags) then
            return
        end
        if flags.worktree then
            -- Current tabpage: `open_existing` refuses when it already runs a
            -- session, instead of silently stealing the tab. A name that does
            -- not exist yet is created (a fresh conversation, like `:PiNewTab`).
            Pi.worktree_open({ name = flags.worktree, layout = flags.opts.layout, new_tab = false, create = true })
            return
        end
        Pi.toggle(flags.opts)
    end, { nargs = "*", complete = complete_flags, desc = "Show or toggle π chat" })

    vim.api.nvim_create_user_command("PiNewTab", function(cmd)
        local flags = parse_flags(cmd.args)
        if not check_worktree_value(flags) then
            return
        end
        if flags.worktree then
            Pi.worktree_open({ name = flags.worktree, layout = flags.opts.layout, new_tab = true, create = true })
            return
        end
        Pi.new_tab()
    end, { nargs = "*", complete = complete_flags, desc = "Open a fresh π session in a new tab" })

    vim.api.nvim_create_user_command("PiContinue", function(cmd)
        local flags = parse_flags(cmd.args)
        if not reject_worktree_flag(flags, ":PiContinue") then
            return
        end
        Pi.continue_session(flags.opts)
    end, { nargs = "*", complete = complete_flags, desc = "Continue last π conversation" })

    vim.api.nvim_create_user_command("PiResume", function(cmd)
        local flags = parse_flags(cmd.args)
        if not reject_worktree_flag(flags, ":PiResume") then
            return
        end
        Pi.resume_session(flags.opts)
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

    vim.api.nvim_create_user_command("PiSessionsSync", function()
        require("pi.ui.sessions").sync_tabs()
    end, { desc = "Reorder π tabs into :PiSessions list order" })

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
        if cmd.bang then
            -- `:PiCompact!` compacts immediately, never through the dialog.
            Pi.compact(cmd.args ~= "" and cmd.args or nil)
            return
        end
        if cmd.args ~= "" then
            Pi.compact(cmd.args)
            return
        end
        require("pi.ui.compaction_dialog").open()
    end, {
        nargs = "?",
        bang = true,
        desc = "Compact the current context (opens a focus dialog when called without args)",
    })

    vim.api.nvim_create_user_command("PiCompactAbort", function()
        Pi.compact_abort()
    end, { desc = "Abort the running compaction" })

    vim.api.nvim_create_user_command("PiCompactRetry", function()
        Pi.compact_retry()
    end, { desc = "Retry the last failed compaction with the same focus" })

    vim.api.nvim_create_user_command("PiCompactions", function()
        require("pi.ui.compactions").toggle()
    end, { desc = "Show the compaction timeline for the current session" })

    vim.api.nvim_create_user_command("PiCopy", function(cmd)
        local session = require("pi.sessions.manager").get()
        local chat = session and session.chat or nil
        if not chat then
            require("pi.notify").warn("No active π session to copy from")
            return
        end
        chat:copy_range(cmd.line1, cmd.line2, { clipboard = cmd.bang })
    end, {
        range = true,
        bang = true,
        desc = "Copy chat history lines (source text when whole messages are selected)",
    })

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
