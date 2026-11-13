-- Headless e2e: :PiResume partitions against a REAL git repo with REAL linked
-- worktrees, rendered by the REAL telescope picker.
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/resume_partitions_e2e.lua
--
-- Why this layer exists: the plenary specs stub telescope, so they cannot see
-- whether the dynamic finder really re-runs per keystroke, whether the title
-- rows reach the results buffer, or whether a picked worktree row starts the
-- pi process with that checkout as its cwd. This script builds a temporary
-- repository plus two managed checkouts, writes session files into a temporary
-- agent dir, opens :PiResume, types into the prompt, and inspects the picker's
-- own results buffer. It then selects a worktree row and asserts the backend
-- process really runs inside that checkout (/proc/<pid>/cwd on Linux).
--
-- Requires: git, and telescope.nvim on disk. The open assertion additionally
-- needs the pi binary; without it the script skips that part and still verifies
-- the picker. Missing prerequisites skip cleanly (exit 0), keeping CI on the
-- plenary suite.

local failures = {}

local function check(name, ok, detail)
    print(string.format("[%s] %s%s", ok and "PASS" or "FAIL", name, detail and (" — " .. detail) or ""))
    if not ok then
        failures[#failures + 1] = name
    end
end

local function realpath(path)
    return (type(path) == "string" and vim.uv.fs_realpath(path)) or path
end

local function write(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

local function git(repo, ...)
    local argv = { "git", "-C", repo }
    for _, part in ipairs({ ... }) do
        argv[#argv + 1] = part
    end
    local out = vim.fn.system(argv)
    if vim.v.shell_error ~= 0 then
        error("git " .. table.concat({ ... }, " ") .. " failed: " .. tostring(out))
    end
    return vim.trim(out)
end

local telescope_root = vim.fn.expand("~/.local/share/nvim/lazy/telescope.nvim")
local plenary_root = vim.env.PLENARY_PATH or vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")

local tmp = vim.fn.tempname()
local orig_cwd = vim.fn.getcwd()

--- Remove the fixture and leave no process behind.
local function cleanup()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "TelescopePrompt" then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
    end
    if vim.fn.getcwd() ~= orig_cwd then
        pcall(vim.cmd, "cd " .. vim.fn.fnameescape(orig_cwd))
    end
    pcall(vim.fn.delete, tmp, "rf")
end

local ok, err = pcall(function()
    if vim.fn.isdirectory(telescope_root) == 0 then
        print("[SKIP] telescope.nvim is not installed")
        return
    end
    if vim.fn.isdirectory(plenary_root) == 0 then
        print("[SKIP] plenary.nvim is not installed (telescope needs it)")
        return
    end
    if vim.fn.executable("git") ~= 1 then
        print("[SKIP] git is not installed")
        return
    end
    vim.opt.runtimepath:prepend(telescope_root)

    local Sessions = require("pi.sessions.manager")
    local History = require("pi.sessions.history")
    local Pi = require("pi")

    -- Fixture -----------------------------------------------------------------

    vim.fn.mkdir(tmp, "p")
    local repo = tmp .. "/demo-repo"
    local wt_auth = repo .. "/.worktrees/fix-auth"
    local wt_polish = repo .. "/.worktrees/polish"

    vim.fn.mkdir(repo, "p")
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "e2e@example.com")
    git(repo, "config", "user.name", "e2e")
    write(repo .. "/README.md", "fixture\n")
    write(repo .. "/.gitignore", "/.worktrees/\n")
    git(repo, "add", ".")
    git(repo, "commit", "-q", "-m", "fixture")
    git(repo, "worktree", "add", "--detach", wt_auth, "HEAD")
    git(repo, "worktree", "add", "--detach", wt_polish, "HEAD")
    -- A checkout created outside the repository and outside `.worktrees/`: git
    -- reports it, so the picker must enumerate it like a π-managed one.
    local wt_ext = tmp .. "/external-checkout"
    git(repo, "worktree", "add", "--detach", wt_ext, "HEAD")

    local agent_dir = tmp .. "/agent"
    -- Pickup-side config plus the child process: pi has no --agent-dir flag, so
    -- the env var is what keeps the spawned backend out of the real ~/.pi/agent.
    vim.env.PI_CODING_AGENT_DIR = agent_dir
    Pi.setup({ agent_dir = agent_dir, title = { enabled = false } })

    local function make_session(cwd, id, iso, name, first_message, mtime)
        local dir = History.get_sessions_dir(cwd)
        vim.fn.mkdir(dir, "p")
        local file = dir .. "/" .. iso:gsub("[:%.]", "-") .. "_" .. id .. ".jsonl"
        local lines = {
            vim.json.encode({ type = "session", version = 3, id = id, timestamp = iso, cwd = realpath(cwd) }),
            vim.json.encode({
                type = "message",
                id = "u1",
                parentId = vim.NIL,
                timestamp = iso,
                message = { role = "user", content = { { type = "text", text = first_message } } },
            }),
        }
        if name then
            lines[#lines + 1] = vim.json.encode({ type = "session_info", timestamp = iso, name = name })
        end
        write(file, table.concat(lines, "\n") .. "\n")
        local now = os.time()
        vim.uv.fs_utime(file, mtime or now, mtime or now)
        return realpath(file)
    end

    local now = os.time()
    local auth_session =
        make_session(wt_auth, "e2e-auth", "2026-01-02T10:00:00.000Z", "auth session", "auth ask", now - 200)
    make_session(wt_polish, "e2e-polish", "2026-01-03T10:00:00.000Z", "deploy notes", "polish ask", now - 100)
    make_session(repo, "e2e-main", "2026-01-01T10:00:00.000Z", "main session", "main ask", now - 300)
    make_session(wt_ext, "e2e-ext", "2026-01-04T10:00:00.000Z", "external session", "ext ask", now - 50)

    -- A checkout deleted but recoverable from a snapshot store, holding nothing
    -- but a SUB-SESSION transcript: it must not become a partition of its own.
    -- The child linkage lives in the parent's workspace manifest, which is what
    -- the collection consults — nothing here is stubbed.
    local dead = repo .. "/.worktrees/sub-dead"
    make_session(dead, "e2e-dead-child", "2026-01-05T10:00:00.000Z", "dead child", "dead ask", now)
    write(
        History.get_sessions_dir(repo) .. "/.pi2-subsessions.json",
        vim.json.encode({ ["e2e-dead-child"] = { parent_id = "e2e-main", status = "completed" } })
    )
    local snap = repo .. "/.git/pi2-worktree-snapshots/sub-dead"
    vim.fn.mkdir(snap, "p")
    write(snap .. "/20260105-100000.patch", "")
    local head = git(repo, "rev-parse", "HEAD")
    write(
        snap .. "/20260105-100000.patch.json",
        vim.json.encode({
            name = "sub-dead",
            path = dead,
            repo_root = repo,
            base_sha = head,
            head = head,
            created_at = now,
        })
    )

    vim.cmd("cd " .. vim.fn.fnameescape(repo))

    -- Helpers -----------------------------------------------------------------

    --- Result rows without telescope's selection caret / list padding, so
    --- assertions compare the entry text itself.
    local function row_texts(picker)
        local buf = picker.results_bufnr
        if not buf or not vim.api.nvim_buf_is_valid(buf) then
            return {}
        end
        local out = {}
        for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            out[#out + 1] = (line:gsub("^%s*[>]?%s*", ""):gsub("%s+$", ""))
        end
        return out
    end

    local function find_row(rows, text)
        for i, row in ipairs(rows) do
            if row == text then
                return i
            end
        end
        return nil
    end

    local function wait_for_prompt()
        local found
        local ok_prompt = vim.wait(15000, function()
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "TelescopePrompt" then
                    found = buf
                    return true
                end
            end
            return false
        end, 20)
        return ok_prompt and found or nil
    end

    -- Open the picker ---------------------------------------------------------

    Sessions.resume_session()
    local prompt_buf = wait_for_prompt()
    check("telescope prompt opened", prompt_buf ~= nil)
    if not prompt_buf then
        return
    end
    local status = require("telescope.state").get_status(prompt_buf)
    local picker = status and status.picker or nil
    check("picker state resolves", picker ~= nil)
    if not picker then
        return
    end

    local ok_rows = vim.wait(15000, function()
        return #row_texts(picker) >= 8
    end, 20)
    local rows = row_texts(picker)
    check("unfiltered list shows every partition", ok_rows)

    local title_auth = find_row(rows, "󰙅 fix-auth")
    local title_polish = find_row(rows, "󰙅 polish")
    local title_ext = find_row(rows, "󰙅 external-checkout")
    local title_main = find_row(rows, "demo-repo")
    check("fix-auth title row", title_auth ~= nil, table.concat(rows, " | "))
    check("polish title row", title_polish ~= nil)
    check("externally created checkout gets a title row", title_ext ~= nil, table.concat(rows, " | "))
    check("main checkout title row", title_main ~= nil)

    -- Ordering: external (newest) → polish → fix-auth → main.
    check(
        "partitions ordered by newest session",
        title_ext ~= nil
            and title_polish ~= nil
            and title_auth ~= nil
            and title_main ~= nil
            and title_ext < title_polish
            and title_polish < title_auth
            and title_auth < title_main
    )

    -- A snapshot-recoverable checkout whose only transcript is a child row is
    -- not a partition: no ghost title, no ghost row.
    check(
        "no ghost partition for a child-only checkout",
        find_row(rows, "󰙅 sub-dead") == nil,
        table.concat(rows, " | ")
    )
    check("no row for its sub-session transcript", find_row(rows, "2026-01-05  dead child") == nil)
    check(
        "the externally created checkout's session is listed",
        find_row(rows, "2026-01-04  external session") ~= nil,
        table.concat(rows, " | ")
    )

    -- R3: session rows never carry checkout information.
    local auth_row = find_row(rows, "2026-01-02  auth session")
    check("a worktree session row is rendered", auth_row ~= nil, table.concat(rows, " | "))
    local leaks = false
    for _, row in ipairs(rows) do
        if row:find("session", 1, true) or row:find("deploy notes", 1, true) then
            if row:find("fix-auth", 1, true) or row:find("polish", 1, true) or row:find("󰙅", 1, true) then
                leaks = true
            end
        end
    end
    check("session rows carry no worktree context", not leaks)

    -- Filtering keeps the title -------------------------------------------------

    -- "deploy" matches only polish's session row — not its title, not its path.
    picker:set_prompt("deploy")
    vim.wait(15000, function()
        local current = row_texts(picker)
        return find_row(current, "2026-01-03  deploy notes") ~= nil
            and find_row(current, "2026-01-02  auth session") == nil
    end, 20)
    local filtered = row_texts(picker)
    local f_title = find_row(filtered, "󰙅 polish")
    local f_session = find_row(filtered, "2026-01-03  deploy notes")
    check("matched session survives filtering", f_session ~= nil, table.concat(filtered, " | "))
    check("its partition title survives filtering", f_title ~= nil)
    check("title sits above the matched session", f_title ~= nil and f_session ~= nil and f_title < f_session)
    check("partitions without a match disappear", find_row(filtered, "2026-01-02  auth session") == nil)
    check("the title is shown though only one partition survives", f_title ~= nil)

    -- A query matching the worktree name keeps that partition's sessions.
    picker:set_prompt("polish")
    local by_name = vim.wait(15000, function()
        local current = row_texts(picker)
        return find_row(current, "󰙅 polish") ~= nil and find_row(current, "2026-01-03  deploy notes") ~= nil
    end, 20)
    check("worktree name matches its partition and sessions", by_name)

    -- Open in the matching checkout --------------------------------------------

    -- Narrow to one partition with exactly one session row; the picker selects
    -- the group row first, and <CR> on a title steps to the session below it.
    picker:set_prompt("auth session")
    local narrowed = vim.wait(15000, function()
        local current = row_texts(picker)
        return find_row(current, "2026-01-02  auth session") ~= nil
            and find_row(current, "2026-01-03  deploy notes") == nil
    end, 20)
    check("narrowed to the fix-auth partition", narrowed)

    if vim.fn.executable("pi") ~= 1 then
        print("[SKIP] pi is not installed: opening a row was not exercised")
        return
    end

    -- <CR> on the first row (the group title) must step to the next session row.
    vim.api.nvim_set_current_win(picker.prompt_win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

    local opened
    local open_ok = vim.wait(20000, function()
        local session = Sessions.get()
        if session and session._process_cwd then
            opened = session
            return true
        end
        return false
    end, 50)

    check("selecting a row starts a session", open_ok)
    if opened then
        check(
            "the process cwd is the matching worktree",
            realpath(opened._process_cwd) == realpath(wt_auth),
            tostring(opened._process_cwd)
        )
        local job = opened.rpc and opened.rpc._job_id
        local pid = job and vim.fn.jobpid(job) or nil
        if vim.uv.os_uname().sysname == "Linux" and type(pid) == "number" and pid > 0 then
            local proc_cwd
            vim.wait(5000, function()
                proc_cwd = vim.uv.fs_readlink("/proc/" .. pid .. "/cwd")
                return proc_cwd ~= nil
            end, 50)
            check("the OS process really runs in that checkout", proc_cwd == realpath(wt_auth), tostring(proc_cwd))
        else
            print("[SKIP] /proc process-cwd check (not Linux, or no pid)")
        end
        local loaded = vim.wait(20000, function()
            return realpath(opened.session_file) == realpath(auth_session)
        end, 50)
        check("the picked session file is loaded", loaded, tostring(opened.session_file))
    end

    -- Always close whatever session the open started, so no pi process (or its
    -- temp cwd) outlives the fixture.
    local session = Sessions.get()
    if session then
        Sessions.close_session(session)
        vim.wait(5000, function()
            return not session.rpc:is_running()
        end, 50)
    end
end)

cleanup()

if not ok then
    check("e2e body completed without error", false, tostring(err))
end

if #failures > 0 then
    print(string.format("RESUME PARTITIONS E2E: %d failed — %s", #failures, table.concat(failures, ", ")))
    vim.cmd("cq 1")
else
    print("RESUME PARTITIONS E2E: ALL GREEN")
    vim.cmd("cq 0")
end
