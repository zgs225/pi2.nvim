-- Headless e2e: git worktrees + real `pi --mode rpc` sessions, real git repos.
--
-- Unlike tests/*_worktree*_spec.lua (mocked RPC/git), this drives the real
-- feature end to end: `git worktree add`, metadata sidecars, `.worktreeinclude`
-- copies, `setup_cmd`, the diff-review apply path, snapshots/release, and the
-- sessions-list grouping. No provider turn is used and the prompt is never
-- submitted; only the real child processes are started.
--
-- Hermetic: every run gets a unique temp root with its own agent dir (the
-- user's auth/model/settings files are symlinked in read-only), temp git
-- repos, and all dialogs are auto-answered. Nothing under ~/.pi is written.
--
-- Needs the pi binary, so it is NOT part of `make test` or CI. Run from the
-- repo root:
--   make e2e-worktrees
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/worktrees.lua)

local uv = vim.uv

local ROOT = vim.fn.tempname() .. "-pi-e2e-worktrees"
local AGENT = ROOT .. "/agent"
local STARTED = uv.hrtime()
local LAST = STARTED

io.stdout:setvbuf("no")

---@class E2EResults
---@field results { ok: boolean, msg: string }[]
---@field notices { msg: string, level: integer }[]
---@field selects string[]
local S = { results = {}, notices = {}, selects = {} }

--- Mark a step boundary with elapsed timing.
---@param name string
local function step(name)
    local now = uv.hrtime()
    print(string.format("[step] %-58s +%6.2fs (total %7.2fs)", name, (now - LAST) / 1e9, (now - STARTED) / 1e9))
    LAST = now
end

--- Record and print one check; raises on failure so the scenario aborts.
---@param cond any
---@param msg string
---@param ctx? table
local function check(cond, msg, ctx)
    if cond then
        S.results[#S.results + 1] = { ok = true, msg = msg }
        print("[ok]   " .. msg)
        return
    end
    S.results[#S.results + 1] = { ok = false, msg = msg }
    local detail = ctx ~= nil and (" | ctx=" .. vim.inspect(ctx, { newline = " ", indent = "" })) or ""
    print("[FAIL] " .. msg .. detail)
    error("FAILED: " .. msg .. detail, 0)
end

--- Soft check: records the result but never aborts.
---@param cond any
---@param msg string
---@param ctx? table
local function check_soft(cond, msg, ctx)
    if cond then
        S.results[#S.results + 1] = { ok = true, msg = msg }
        print("[ok]   " .. msg)
    else
        S.results[#S.results + 1] = { ok = false, msg = msg }
        local detail = ctx ~= nil and (" | ctx=" .. vim.inspect(ctx, { newline = " ", indent = "" })) or ""
        print("[FAIL] " .. msg .. detail)
    end
end

--- Wait for `cond`; fails the run on timeout.
---@param cond fun(): boolean
---@param ms integer
---@param label string
local function wait(cond, ms, label)
    if not vim.wait(ms, cond, 25) then
        check(false, "timed out waiting for " .. label)
    end
end

--- Run an async callback API to completion and return its packed args.
---@param fn fun(...)
---@param ms integer
---@param ... any
---@return table
local function call(fn, ms, ...)
    local args = { n = select("#", ...), ... }
    local pack, done
    args.n = args.n + 1
    args[args.n] = function(...)
        pack = { n = select("#", ...), ... }
        done = true
    end
    fn(unpack(args, 1, args.n))
    if not vim.wait(ms, function()
        return done
    end, 25) then
        check(false, "timed out waiting for an async callback")
    end
    return pack or { n = 0 }
end

--- Run a command and capture its result.
---@param argv string[]
---@param cwd? string
---@param stdin? string
---@return integer code, string stdout, string stderr
local function sh(argv, cwd, stdin)
    local res = vim.system(argv, { text = true, cwd = cwd, stdin = stdin }):wait()
    return res.code or -1, res.stdout or "", res.stderr or ""
end

--- git with failure detection.
---@param argv string[]
---@param cwd string
---@return string stdout
local function git(argv, cwd)
    local full = { "git" }
    vim.list_extend(full, argv)
    local code, out, err = sh(full, cwd)
    if code ~= 0 then
        error("git " .. table.concat(argv, " ") .. " failed in " .. tostring(cwd) .. ": " .. err .. out, 0)
    end
    return out
end

---@param path string
---@return string?
local function read(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return text
end

---@param path string
---@param text string
local function write(path, text)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then
        table.remove(lines)
    end
    vim.fn.writefile(lines, path)
end

---@param path string
---@return boolean
local function exists(path)
    return uv.fs_stat(path) ~= nil
end

---@param dir string
---@return string
local function head(dir)
    return vim.trim(git({ "rev-parse", "HEAD" }, dir))
end

---@param repo string
---@return string[] names
local function worktree_names(repo)
    local out = git({ "worktree", "list", "--porcelain" }, repo)
    local names = {}
    for path in out:gmatch("worktree ([^\n]+)") do
        local name = vim.trim(path):match("/%.worktrees/([^/]+)$")
        if name then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

--- Create a throwaway git repository with one commit and neutral identity.
---@param name string
---@return string path
local function repo(name)
    local dir = ROOT .. "/repos/" .. name
    vim.fn.mkdir(dir, "p")
    git({ "init", "-q", "-b", "main" }, dir)
    git({ "config", "user.email", "pi-e2e@example.com" }, dir)
    git({ "config", "user.name", "pi e2e" }, dir)
    git({ "config", "commit.gpgsign", "false" }, dir)
    write(dir .. "/seed.txt", "seed\n")
    write(dir .. "/README.md", "# e2e\n")
    git({ "add", "-A" }, dir)
    git({ "commit", "-qm", "init" }, dir)
    return dir
end

---@param path string
---@return string
local function realpath(path)
    return uv.fs_realpath(path) or path
end

-- Notifications / dialogs ----------------------------------------------------

local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
    S.notices[#S.notices + 1] = { msg = tostring(msg), level = level }
    print("[notify] " .. tostring(msg))
    if orig_notify and S.passthrough_notify then
        orig_notify(msg, level, opts)
    end
end

---@param pat string
---@param from? integer
---@return string?
local function notice_matching(pat, from)
    for i = #S.notices, from or 1, -1 do
        if S.notices[i].msg:find(pat) then
            return S.notices[i].msg
        end
    end
    return nil
end

---@param pat string
---@param ms? integer
---@param from? integer
---@return string msg
local function wait_notice(pat, ms, from)
    local msg
    wait(function()
        msg = notice_matching(pat, from)
        return msg ~= nil
    end, ms or 15000, "notification matching " .. pat)
    return msg
end

local orig_select = vim.ui.select
---@type string
S.select_answer = "Yes"
vim.ui.select = function(items, opts, on_choice)
    local prompt = (opts and opts.prompt) or ""
    S.selects[#S.selects + 1] = prompt
    local answer = S.select_answer
    if answer ~= "Yes" and answer ~= "No" then
        answer = items and items[1] or nil
    end
    vim.schedule(function()
        on_choice(answer)
    end)
end

-- Sessions / worktrees -------------------------------------------------------

---@type table[]
local tracked = {}
---@type integer
local scratch

---@param tab integer
local function focus_tab(tab)
    pcall(vim.api.nvim_set_current_tabpage, tab)
end

--- Focus the sessionless scratch tab and cd to `dir`.
---@param dir string
local function scratch_at(dir)
    focus_tab(scratch)
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
end

---@param session table?
local function track(session)
    if session then
        tracked[#tracked + 1] = session
    end
    return session
end

--- Wait for a session's RPC child to be live.
---@param session table
local function wait_live(session)
    wait(function()
        return session.rpc ~= nil and session.rpc:is_running()
    end, 30000, "session process live")
end

--- Create a worktree through the public API from the scratch tab.
---@param dir string
---@param name? string
---@return table session
local function new_worktree(dir, name)
    scratch_at(dir)
    local mark = #S.notices
    local Sessions = require("pi.sessions.manager")
    local before = {}
    for _, session in ipairs(Sessions.list_all()) do
        before[session] = true
    end
    require("pi").worktree_new({ name = name })
    local found
    wait(function()
        for _, session in ipairs(Sessions.list_all()) do
            if not before[session] and type(session.worktree) == "table" then
                found = session
                return true
            end
        end
        return false
    end, 30000, "worktree session registration")
    if not found then
        local msg = notice_matching("Failed to create worktree", mark) or "no notification"
        check(false, "worktree_new did not register a session: " .. tostring(msg))
    end
    wait_live(found)
    return track(found)
end

--- Create a worktree through the lower-level git module (no session).
---@param dir string
---@param name string
---@return table info
local function create_checkout(dir, name)
    local pack = call(function(cb)
        require("pi.worktree").create({ cwd = dir, name = name }, cb)
    end, 30000)
    check(type(pack[1]) == "table", "worktree.create returned info", { info = pack[1], err = pack[2] })
    return pack[1]
end

--- Stop a session through the manager (triggers the worktree release path).
---@param session table
local function close_session(session)
    pcall(function()
        require("pi.sessions.manager").close_session(session)
    end)
end

--- Find the review list buffer (the one with the accept keymap).
---@return integer?
local function review_list_buf()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
            for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
                if map.lhs == "a" and (map.desc or ""):find("Accept:", 1, true) then
                    return buf
                end
            end
        end
    end
    return nil
end

--- Press a normal-mode key in a buffer (through its real keymap).
---@param buf integer
---@param key string
local function press(buf, key)
    vim.api.nvim_buf_call(buf, function()
        vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
    end)
end

-- Scenarios -----------------------------------------------------------------

--- Expect a worktree_new refusal: an error notification and no new session.
---@param dir string
---@param opts table
---@param pattern string
---@return string msg
local function expect_refusal(dir, opts, pattern)
    if dir then
        scratch_at(dir)
    end
    local Sessions = require("pi.sessions.manager")
    local before = #Sessions.list_all()
    local mark = #S.notices
    require("pi").worktree_new(opts)
    local msg = wait_notice(pattern, 15000, mark)
    check(#Sessions.list_all() == before, "refusal did not register a session", {
        before = before,
        after = #Sessions.list_all(),
    })
    return msg
end

--- S2: refusals — invalid/duplicate names, non-git, no commits, nesting.
---@param repo_dir string
---@param w1 table
local function scenario_s2(repo_dir, w1)
    step("S2 invalid names")
    for _, bad in ipairs({ "bad/name", "..x", ".hidden" }) do
        expect_refusal(repo_dir, { name = bad }, "name")
        check(not exists(repo_dir .. "/.worktrees/" .. bad), "no checkout created for invalid name", { name = bad })
    end

    step("S2 duplicate name")
    local before = #require("pi.sessions.manager").list_all()
    local dup = expect_refusal(repo_dir, { name = "w1" }, "already exists")
    check(dup:find("w1", 1, true) ~= nil, "duplicate refusal names the checkout", { msg = dup })
    check(#require("pi.sessions.manager").list_all() == before, "duplicate refusal left the session count unchanged")

    step("S2 non-git directory")
    local plain = ROOT .. "/repos/plain"
    vim.fn.mkdir(plain, "p")
    expect_refusal(plain, { name = "w1" }, "not a git repository")

    step("S2 repository with zero commits")
    local empty = ROOT .. "/repos/empty"
    vim.fn.mkdir(empty, "p")
    git({ "init", "-q", "-b", "main" }, empty)
    expect_refusal(empty, { name = "w1" }, "no commits")
    check(not exists(empty .. "/.worktrees"), "zero-commit refusal created no .worktrees directory")

    step("S2 nested worktree from inside a worktree session")
    focus_tab(w1.attached_tab)
    local nested = expect_refusal(nil, { name = "nested" }, "Nested worktrees")
    check(nested:find("already runs in a worktree", 1, true) ~= nil, "nested refusal explains the rule", {
        msg = nested,
    })
    check(not exists(repo_dir .. "/.worktrees/nested"), "nested refusal created no checkout")
end

--- S1: create — checkout, detached HEAD, metadata, gitignore, generated name.
---@param repo_dir string
local function scenario_s1(repo_dir)
    step("S1 create a named worktree")
    local base = head(repo_dir)
    local session = new_worktree(repo_dir, "w1")
    local wt = repo_dir .. "/.worktrees/w1"

    check(session.cwd == wt, "session cwd is <repo>/.worktrees/w1", { cwd = session.cwd })
    check(realpath(session.cwd) == realpath(wt), "session cwd resolves to the checkout")
    check(vim.trim(git({ "rev-parse", "--abbrev-ref", "HEAD" }, wt)) == "HEAD", "checkout is on a detached HEAD")
    check(head(wt) == base, "checkout HEAD equals the repository HEAD", { base = base, head = head(wt) })
    check(session.rpc:is_running(), "worktree session process is live")
    check(vim.tbl_contains(worktree_names(repo_dir), "w1"), "git worktree list contains w1")

    local meta_path = repo_dir .. "/.git/worktrees/w1/pi2-worktree.json"
    local meta_text = read(meta_path)
    local meta = meta_text and vim.json.decode(meta_text) or {}
    check(type(meta) == "table" and meta.name == "w1", "metadata records the name", { meta = meta })
    check(meta.path == realpath(wt), "metadata records the checkout path", { meta = meta })
    check(meta.base_sha == base, "metadata records the base commit", { meta = meta })

    local ignore = read(repo_dir .. "/.gitignore") or ""
    local count = 0
    for _ in ignore:gmatch("/%.worktrees/") do
        count = count + 1
    end
    check(count == 1, "/.worktrees/ appears in .gitignore exactly once", { gitignore = ignore })
    check(vim.trim(git({ "diff", "--cached" }, repo_dir)) == "", "nothing is staged")
    check(vim.trim(git({ "status", "--porcelain" }, wt)) == "", "checkout starts clean")

    step("S1 create with a generated name")
    local generated = new_worktree(repo_dir)
    local name = vim.fs.basename(generated.cwd)
    check(
        name:match("^wt%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+%-%d+$") ~= nil,
        "generated worktree name matches the timestamp-pid-sequence pattern",
        { name = name }
    )
    return session
end

-- ---------------------------------------------------------------------------

--- Open the worktree review panel for `name`.
---@param name string
---@return integer list_buf
---@return table DiffReview
local function open_review(name)
    local DiffReview = require("pi.ui.diff_review")
    require("pi").worktree_apply({ name = name })
    wait(function()
        return DiffReview.is_open()
    end, 30000, "worktree review panel")
    local buf = review_list_buf()
    check(buf ~= nil, "review list buffer with the accept keymap exists")
    return buf, DiffReview
end

--- S7: branch — switch onto a new/existing branch, reject an invalid name.
---@param repo_dir string
local function scenario_s7(repo_dir)
    step("S7 branch onto a new name")
    local session = new_worktree(repo_dir, "w-branch")
    focus_tab(session.attached_tab)
    local wt = session.cwd
    local mark = #S.notices
    require("pi").worktree_branch("feat-e2e")
    wait_notice("Worktree branch: feat%-e2e", 15000, mark)
    check(vim.trim(git({ "rev-parse", "--abbrev-ref", "HEAD" }, wt)) == "feat-e2e", "checkout is on feat-e2e")

    step("S7 second call with the existing branch succeeds")
    mark = #S.notices
    require("pi").worktree_branch("feat-e2e")
    wait_notice("Worktree branch: feat%-e2e", 15000, mark)
    check(vim.trim(git({ "rev-parse", "--abbrev-ref", "HEAD" }, wt)) == "feat-e2e", "checkout stayed on feat-e2e")
    check(notice_matching("Failed to switch", mark) == nil, "existing branch produced no error")

    step("S7 invalid branch name is rejected")
    mark = #S.notices
    require("pi").worktree_branch("bad..name")
    local msg = wait_notice("Failed to switch worktree branch", 15000, mark)
    check(msg:find("bad..name", 1, true) ~= nil, "invalid-branch error names the value", { msg = msg })
    check(vim.trim(git({ "rev-parse", "--abbrev-ref", "HEAD" }, wt)) == "feat-e2e", "invalid branch left HEAD alone")
    return session
end

--- S10: sessions list — one group row per worktree, flat with one worktree.
---@param repo_dir string
local function scenario_s10(repo_dir)
    step("S10 sessions list groups by worktree")
    local w_a = new_worktree(repo_dir, "list-a")
    local w_b = new_worktree(repo_dir, "list-b")
    scratch_at(repo_dir)
    require("pi").show({ layout = "side" })
    local Sessions = require("pi.sessions.manager")
    local main_session
    wait(function()
        main_session = Sessions.get()
        return main_session ~= nil and main_session.rpc ~= nil and main_session.rpc:is_running()
    end, 30000, "main session process live")
    track(main_session)

    local List = require("pi.ui.sessions")
    local name_of = function()
        return nil
    end
    local rows = List.build_rows({ main_session, w_a, w_b }, function()
        return 0
    end, name_of)
    local groups = {}
    for _, row in ipairs(rows) do
        if row.is_group then
            groups[#groups + 1] = row
        end
    end
    check(#groups == 3, "one group row per git worktree (main + two worktrees)", { groups = #groups, rows = #rows })
    local group_roots = {}
    for _, row in ipairs(groups) do
        group_roots[realpath(row.group_id)] = true
    end
    check(
        group_roots[realpath(repo_dir)] and group_roots[realpath(w_a.cwd)] and group_roots[realpath(w_b.cwd)],
        "group rows name the main checkout and both worktrees",
        { roots = vim.tbl_keys(group_roots) }
    )
    check(#rows == 6, "three groups + one member row each", { rows = #rows })
    check(w_a.cwd ~= w_b.cwd, "the worktrees are distinct checkouts")

    step("S10 single worktree stays flat")
    local flat = List.build_rows({ w_a }, function()
        return 0
    end, name_of)
    check(#flat == 1 and not flat[1].is_group, "a single worktree keeps the flat list shape", { rows = #flat })
end

--- S9: release — clean close deletes+snapshots, dirty close keeps.
---@param repo_dir string
local function scenario_s9(repo_dir)
    step("S9 stopping a clean worktree session releases the checkout")
    local clean = new_worktree(repo_dir, "w-clean")
    local clean_wt = clean.cwd
    close_session(clean)
    wait(function()
        return not exists(clean_wt)
    end, 30000, "clean worktree removal")
    check(not vim.tbl_contains(worktree_names(repo_dir), "w-clean"), "clean close removed the worktree from git")
    local patches = vim.fn.glob(repo_dir .. "/.git/pi2-worktree-snapshots/w-clean/*.patch", false, true)
    check(#patches == 1, "clean close wrote one (empty) snapshot patch", { patches = patches })
    check(read(patches[1]) == "", "clean snapshot patch is empty", { content = read(patches[1]) })
    check(vim.fn.filereadable(patches[1] .. ".json") == 1, "clean snapshot has its .patch.json sidecar")

    step("S9 stopping a dirty worktree session keeps it")
    local dirty = new_worktree(repo_dir, "w-keep")
    write(dirty.cwd .. "/uncommitted.txt", "keep me\n")
    local mark = #S.notices
    close_session(dirty)
    local msg = wait_notice("Worktree kept", 30000, mark)
    check(msg:find(dirty.cwd, 1, true) ~= nil, "kept notification names the checkout", { msg = msg })
    check(exists(dirty.cwd), "dirty checkout directory was kept")
    check(vim.tbl_contains(worktree_names(repo_dir), "w-keep"), "dirty checkout stays registered with git")
    check(read(dirty.cwd .. "/uncommitted.txt") == "keep me\n", "dirty work is still on disk")
end

--- S8: ship — prefill the worktree chat prompt, never send.
---@param session table
local function scenario_s8(session)
    step("S8 ship prefills the prompt and sends nothing")
    focus_tab(session.attached_tab)
    local chat = session.chat
    check(type(chat) == "table", "worktree session has a chat")
    local lines_before = vim.api.nvim_buf_line_count(chat._history:buf())
    local mark = #S.notices
    require("pi").worktree_ship({ name = "w-branch" })
    wait_notice("prefilled %(not sent%)", 20000, mark)

    local text
    wait(function()
        text = chat._prompt:text()
        return type(text) == "string" and text ~= ""
    end, 10000, "prompt prefill")
    check(text:find(session.cwd, 1, true) ~= nil, "prompt carries the absolute worktree path", { text = text })
    check(text:find(session.worktree.base_sha, 1, true) ~= nil, "prompt carries the base commit")
    check(text:find("HEAD:", 1, true) ~= nil, "prompt carries the HEAD line")
    check(text:find("Commit the work", 1, true) ~= nil, "prompt carries the commit requirement")
    check(text:find("Push the branch", 1, true) ~= nil, "prompt carries the push requirement")
    check(text:find("pull request", 1, true) ~= nil, "prompt carries the PR requirement")
    check(chat:is_streaming() == false, "ship started no streaming turn")
    check(
        vim.api.nvim_buf_line_count(chat._history:buf()) == lines_before,
        "ship added no messages to the chat history"
    )
end

--- S6: remove — live refusal, cancel, confirm+snapshot.
---@param repo_dir string
local function scenario_s6(repo_dir)
    step("S6 remove refuses while a session is rooted in the checkout")
    local live = new_worktree(repo_dir, "w-live")
    local mark = #S.notices
    require("pi").worktree_remove({ name = "w-live" })
    local msg = wait_notice("running π session", 15000, mark)
    check(msg:find("close its process first", 1, true) ~= nil, "live refusal tells the user to close the process")
    check(exists(live.cwd), "live refusal left the checkout on disk")
    check(live.rpc:is_running(), "live refusal left the session process running")

    step("S6 cancel keeps the checkout and writes no snapshot")
    create_checkout(repo_dir, "w-cancel")
    local snap_dir = repo_dir .. "/.git/pi2-worktree-snapshots/w-cancel"
    S.select_answer = "No"
    local cancel_pack = call(function(cb)
        require("pi.worktree_session").remove({ name = "w-cancel" }, cb)
    end, 20000)
    S.select_answer = "Yes"
    check(cancel_pack[1] == false, "cancel reported a non-removal", { result = cancel_pack[1] })
    check(exists(repo_dir .. "/.worktrees/w-cancel"), "cancel left the checkout on disk")
    check(not exists(snap_dir), "cancel wrote no snapshot")

    step("S6 confirm snapshots then removes the checkout")
    create_checkout(repo_dir, "w-confirm")
    local confirm_pack = call(function(cb)
        require("pi.worktree_session").remove({ name = "w-confirm" }, cb)
    end, 30000)
    check(confirm_pack[1] == true, "confirm reported the removal", { result = confirm_pack[1] })
    check(not exists(repo_dir .. "/.worktrees/w-confirm"), "confirm removed the checkout directory")
    check(not vim.tbl_contains(worktree_names(repo_dir), "w-confirm"), "confirm removed it from git worktree list")
    local patches = vim.fn.glob(repo_dir .. "/.git/pi2-worktree-snapshots/w-confirm/*.patch", false, true)
    check(#patches == 1, "confirm wrote one snapshot patch under R/.git/pi2-worktree-snapshots/<name>/", {
        patches = patches,
    })
    check(vim.fn.filereadable(patches[1] .. ".json") == 1, "snapshot has its .patch.json sidecar")
end

--- S5: apply — review panel, `a` writes into the main working tree only.
---@param repo_dir string
local function scenario_s5(repo_dir)
    step("S5 review panel + accept writes both files into the main checkout")
    local session = new_worktree(repo_dir, "w-apply")
    local wt = session.cwd
    local head_before = head(repo_dir)
    write(wt .. "/seed.txt", "seed from worktree\n")
    write(wt .. "/new1.txt", "brand new\n")

    local list_buf, DiffReview = open_review("w-apply")
    local label = DiffReview._accept_label()
    check(label == "apply to " .. vim.fs.basename(repo_dir), "accept label names the main repository", {
        label = label,
    })
    local joined = table.concat(vim.api.nvim_buf_get_lines(list_buf, 0, -1, false), "\n")
    check(joined:find("seed.txt", 1, true) ~= nil, "review lists the modified tracked file")
    check(joined:find("new1.txt", 1, true) ~= nil, "review lists the untracked file")

    press(list_buf, "a")
    wait(function()
        return exists(repo_dir .. "/new1.txt")
    end, 30000, "patch applied to the main checkout")
    check(read(repo_dir .. "/seed.txt") == "seed from worktree\n", "modified tracked file copied to main")
    check(read(repo_dir .. "/new1.txt") == "brand new\n", "untracked file copied to main")
    check(vim.trim(git({ "diff", "--cached" }, repo_dir)) == "", "main index is untouched (git diff --cached empty)")
    check(head(repo_dir) == head_before, "main HEAD unchanged")
    check(read(wt .. "/seed.txt") == "seed from worktree\n", "worktree file unchanged by the apply")
    check(not DiffReview.is_open(), "review panel closed after accepting")

    step("S5 q writes nothing")
    write(wt .. "/seed.txt", "second worktree edit\n")
    write(wt .. "/new2.txt", "not applied\n")
    local q_buf = open_review("w-apply")
    press(q_buf, "q")
    wait(function()
        return not DiffReview.is_open()
    end, 15000, "review panel closed by q")
    check(read(repo_dir .. "/seed.txt") == "seed from worktree\n", "q left the main tracked file untouched")
    check(not exists(repo_dir .. "/new2.txt"), "q copied no untracked file")

    step("S5 conflicting main change aborts the whole apply")
    os.remove(wt .. "/new1.txt")
    os.remove(wt .. "/new2.txt")
    write(wt .. "/seed.txt", "wt conflict\n")
    write(wt .. "/new3.txt", "must not land\n")
    write(repo_dir .. "/seed.txt", "main conflict\n")
    local c_buf = open_review("w-apply")
    press(c_buf, "a")
    local msg = wait_notice("git apply failed", 30000)
    check(msg:find(repo_dir, 1, true) ~= nil, "conflict notification names the main checkout", { msg = msg })
    check(read(repo_dir .. "/seed.txt") == "main conflict\n", "conflict left the main file untouched")
    check(read(wt .. "/seed.txt") == "wt conflict\n", "conflict left the worktree file untouched")
    check(not exists(repo_dir .. "/new3.txt"), "conflict wrote no other file into main")
    check(not DiffReview.is_open(), "review panel closed after the failed apply")
end

--- S4: `worktree.setup_cmd` success/failure semantics.
---@param repo_dir string
local function scenario_s4(repo_dir)
    step("S4 setup_cmd success writes inside the checkout")
    local Config = require("pi.config")
    Config.options.worktree = Config.options.worktree or {}
    Config.options.worktree.setup_cmd = { "sh", "-c", "printf 'setup ok\\n' > marker.txt" }
    local session = new_worktree(repo_dir, "w-setup")
    check(read(session.cwd .. "/marker.txt") == "setup ok\n", "setup_cmd ran in the new checkout", {
        got = read(session.cwd .. "/marker.txt"),
    })
    check(session.cwd == repo_dir .. "/.worktrees/w-setup", "session started in the setup checkout")

    step("S4 failing setup_cmd keeps the checkout and starts no session")
    Config.options.worktree.setup_cmd = { "sh", "-c", "printf boom >&2; exit 3" }
    local Sessions = require("pi.sessions.manager")
    local before = #Sessions.list_all()
    scratch_at(repo_dir)
    local mark = #S.notices
    require("pi").worktree_new({ name = "w-setup-fail" })
    local msg = wait_notice("setup_cmd failed", 15000, mark)
    check(msg:find("exit 3", 1, true) ~= nil, "failure notification reports the exit code", { msg = msg })
    check(msg:find("boom", 1, true) ~= nil, "failure notification carries the output tail", { msg = msg })
    check(#Sessions.list_all() == before, "failed setup_cmd started no session")
    check(exists(repo_dir .. "/.worktrees/w-setup-fail"), "failed setup_cmd keeps the checkout")
    check(vim.tbl_contains(worktree_names(repo_dir), "w-setup-fail"), "failed checkout stays registered with git")
    Config.options.worktree.setup_cmd = nil
end

--- S3: `.worktreeinclude` copies ignored+matched files only.
---@param repo_dir string
local function scenario_s3(repo_dir)
    step("S3 .worktreeinclude copies ignored+matched files only")
    write(repo_dir .. "/.gitignore", "*.log\n*.bin\n")
    write(repo_dir .. "/.worktreeinclude", "*.log\nseed.txt\n")
    write(repo_dir .. "/keep.log", "keep\n")
    write(repo_dir .. "/other.bin", "bin\n")
    write(repo_dir .. "/seed.txt", "modified in main\n")

    local session = new_worktree(repo_dir, "w-include")
    local wt = session.cwd
    check(read(wt .. "/keep.log") == "keep\n", "ignored+matched file was copied into the checkout")
    check(read(wt .. "/seed.txt") == "seed\n", "tracked file keeps the committed base content (not copied)", {
        got = read(wt .. "/seed.txt"),
    })
    check(read(repo_dir .. "/seed.txt") == "modified in main\n", "main checkout working tree untouched")
    check(not exists(wt .. "/other.bin"), "ignored-but-unmatched file was not copied")
end

local function setup()
    local source_agent = vim.env.PI_CODING_AGENT_DIR
    if source_agent == nil or source_agent == "" then
        source_agent = vim.fn.expand("~/.pi/agent")
    end

    vim.fn.mkdir(AGENT .. "/sessions", "p")
    for _, name in ipairs({
        "auth.json",
        "models.json",
        "models-store.json",
        "settings.json",
        "cliproxyapi.json",
        "cliproxyapi-models.json",
        "mcp.json",
    }) do
        local src = source_agent .. "/" .. name
        local dst = AGENT .. "/" .. name
        if exists(src) and not exists(dst) then
            pcall(uv.fs_symlink, src, dst)
        end
    end

    vim.env.PI_CODING_AGENT_DIR = AGENT
    require("pi").setup({
        agent_dir = AGENT,
        draft = { path = ROOT .. "/draft.txt" },
        prompt = { history = { path = ROOT .. "/prompt-history.json" } },
        render = { enabled = false },
    })
    vim.cmd("tabnew")
    scratch = vim.api.nvim_get_current_tabpage()
    print(("[setup] root=%s agent=%s"):format(ROOT, AGENT))
end

---@return integer
local function processes_under_root()
    local count = 0
    for _, pid in ipairs(vim.fn.readdir("/proc")) do
        if pid:match("^%d+$") then
            local env = read("/proc/" .. pid .. "/environ")
            local cmd = read("/proc/" .. pid .. "/cmdline")
            if
                env
                and env:find("PI_CODING_AGENT_DIR=" .. AGENT, 1, true)
                and cmd
                and cmd:find("--mode", 1, true)
                and cmd:find("rpc", 1, true)
            then
                count = count + 1
            end
        end
    end
    return count
end

local function cleanup()
    for _, session in ipairs(tracked) do
        pcall(function()
            if session.rpc then
                session.rpc:stop()
            end
        end)
    end
    pcall(function()
        require("pi.sessions.manager")._reset()
    end)
    local ok = vim.wait(10000, function()
        return processes_under_root() == 0
    end, 100)
    if not ok then
        for _, pid in ipairs(vim.fn.readdir("/proc")) do
            if pid:match("^%d+$") then
                local env = read("/proc/" .. pid .. "/environ")
                local cmd = read("/proc/" .. pid .. "/cmdline")
                if
                    env
                    and env:find("PI_CODING_AGENT_DIR=" .. AGENT, 1, true)
                    and cmd
                    and cmd:find("--mode", 1, true)
                then
                    pcall(uv.kill, tonumber(pid), 9)
                end
            end
        end
        vim.wait(5000, function()
            return processes_under_root() == 0
        end, 100)
    end
    check_soft(processes_under_root() == 0, "no leftover pi --mode rpc processes under the run root")
end

local function main()
    check(vim.fn.executable("pi") == 1, "pi binary is available in PATH")
    setup()

    local ok, failure = pcall(function()
        local repo1 = repo("s1")
        local w1 = scenario_s1(repo1)
        scenario_s2(repo1, w1)
        scenario_s3(repo("s3"))
        scenario_s4(repo("s4"))
        scenario_s5(repo("s5"))
        scenario_s6(repo("s6"))
        local w_branch = scenario_s7(repo("s7"))
        scenario_s8(w_branch)
        scenario_s9(repo("s9"))
        scenario_s10(repo("s10"))
    end)

    cleanup()
    vim.ui.select = orig_select
    vim.notify = orig_notify

    local fails, oks = 0, 0
    for _, r in ipairs(S.results) do
        if r.ok then
            oks = oks + 1
        else
            fails = fails + 1
        end
    end
    print("")
    print("========================================")
    print(
        ("e2e summary: %d checks, %d ok, %d failed, %.1fs"):format(
            oks + fails,
            oks,
            fails,
            (uv.hrtime() - STARTED) / 1e9
        )
    )
    print("root=" .. ROOT)
    print("========================================")
    if not ok then
        print("FAIL: " .. tostring(failure))
        io.stdout:flush()
        os.exit(1)
    end
    io.stdout:flush()
    os.exit(fails == 0 and 0 or 1)
end

main()
