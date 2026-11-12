-- Automatic worktree integration (lua/pi/worktree_integration.lua).
--
-- Covers: the pure decision truth table, patch parsing, the capture →
-- snapshot → apply pipeline, idempotency (`probe == "already"`), parking while
-- the parent is busy / a buffer is modified and resuming on `on_parent_ready`,
-- per-target serialization, the crash reconcile (applying → clean/already/
-- conflict), the resolving hand-back (with the attempt budget), and retention
-- (soft cap that never deletes unintegrated work).
--
-- Hermetic: `pi.worktree`, `pi.subsessions.batch` and the git fact runner are
-- fakes installed in `package.loaded` / test hooks, the manifest is redirected
-- to a temp file, and sessions are fakes registered via `_register_for_test`.
-- No git process, no real pi process, no provider.

local Config = require("pi.config")
local Integration = require("pi.worktree_integration")
local Manifest = require("pi.subsessions.manifest")
local Sessions = require("pi.sessions.manager")

-- Absolute paths are per-test (a fake checkout must live under a temp dir).
local WORKSPACE
local TARGET
local WT_PATH

local PATCH = table.concat({
    "diff --git a/a.txt b/a.txt",
    "index 5626abf..814f4a4 100644",
    "--- a/a.txt",
    "+++ b/a.txt",
    "@@ -1 +1,2 @@",
    " one",
    "+two",
    "",
}, "\n")

---@class TestIntegrationEnv
local env = {}

--- Run an async API to completion.
---@param fn fun(cb: fun(...))
---@param timeout? integer
---@return { n: integer, done: boolean, [integer]: any }
local function call(fn, timeout)
    local pack = { n = 0, done = false }
    fn(function(...)
        pack.n = select("#", ...)
        for i = 1, select("#", ...) do
            pack[i] = select(i, ...)
        end
        pack.done = true
    end)
    assert.is_true(
        vim.wait(timeout or 5000, function()
            return pack.done
        end, 5),
        "timed out waiting for callback"
    )
    return pack
end

---@param fn fun()
---@param timeout? integer
local function wait_until(fn, timeout)
    assert.is_true(vim.wait(timeout or 5000, fn, 5), "timed out waiting for a condition")
end

-- Fixtures -------------------------------------------------------------------

---@return table
local function worktree_info()
    return {
        kind = "linked",
        name = "sub-1",
        path = WT_PATH,
        repo_root = TARGET,
        git_dir = WT_PATH .. "/.git",
        base_sha = "base000",
        mode = "new",
    }
end

---@param patch string?
---@return string
local function sha(patch)
    return vim.fn.sha256(patch or "")
end

--- Install a fake `pi.worktree` module recording every call.
---@return table fake
local function install_fake_worktree()
    vim.fn.mkdir(WT_PATH, "p")
    local fake = {
        diff_calls = 0,
        diff_opts = {},
        diff_paths = {},
        snapshot_calls = 0,
        probe_calls = {},
        apply_calls = {},
        remove_calls = {},
        in_flight = 0,
        max_in_flight = 0,
        applied_patches = {},
        detected = {},
    }
    fake.detected[WT_PATH] = worktree_info()
    fake.detected[TARGET] = {
        kind = "main",
        name = "parent",
        path = TARGET,
        repo_root = TARGET,
        git_dir = TARGET .. "/.git",
        base_sha = "base000",
    }

    function fake.detect(cwd)
        return fake.detected[vim.fs.normalize(cwd or "")]
    end

    function fake.status(info, cb)
        vim.schedule(function()
            local head = env.head or "base000"
            local path = type(info) == "table" and info.path or nil
            if type(env.head_by_path) == "table" and type(path) == "string" and env.head_by_path[path] then
                head = env.head_by_path[path]
            end
            cb({ dirty = env.dirty == true, ahead = 0, head = head })
        end)
    end

    --- Patch a given checkout produces (per-worktree override for multi-child specs).
    ---@param info table
    ---@return string?
    function fake.patch_for(info)
        local name = type(info) == "table" and info.name or nil
        if type(env.patch_by_name) == "table" and type(name) == "string" then
            local patch = env.patch_by_name[name]
            if patch ~= nil then
                return patch
            end
        end
        return env.patch
    end

    function fake.diff(info, cb, opts)
        fake.diff_calls = fake.diff_calls + 1
        fake.diff_opts[#fake.diff_opts + 1] = opts
        fake.diff_paths[#fake.diff_paths + 1] = type(info) == "table" and info.path or nil
        local err = env.diff_error
        local patch = fake.patch_for(info)
        if type(env.diff_hook) == "function" then
            -- Lets a test model a checkout that changed between the capture and
            -- a later re-diff.
            patch = env.diff_hook(info, opts, patch) or patch
        end
        vim.schedule(function()
            cb(patch, err)
        end)
    end

    function fake.snapshot(info, cb)
        fake.snapshot_calls = fake.snapshot_calls + 1
        if env.snapshot_error then
            local err = env.snapshot_error
            return vim.schedule(function()
                cb(nil, err)
            end)
        end
        local dir = env.snapshot_dir or tostring(info.path)
        vim.fn.mkdir(dir, "p")
        local path = dir .. "/" .. tostring(info.name or "wt") .. "-snapshot.patch"
        local fd = io.open(path, "wb")
        fd:write(fake.patch_for(info) or PATCH)
        fd:close()
        env.snapshot_path = path
        vim.schedule(function()
            cb(path, nil)
        end)
    end

    ---@param target string
    ---@param patch string
    ---@param cb fun(kind: string?, err: string?)
    function fake.probe(target, patch, cb)
        fake.probe_calls[#fake.probe_calls + 1] = target
        local kind
        if type(env.probe_fn) == "function" then
            kind = env.probe_fn(target, patch)
        elseif fake.applied_patches[sha(patch)] then
            -- The target already carries this patch: that is what the
            -- self-verification (and a second child) must observe.
            kind = "already"
        else
            kind = env.probe
        end
        vim.schedule(function()
            cb(kind, kind == nil and (env.probe_error or "probe failed") or nil)
        end)
    end

    ---@param target string
    ---@param patch string
    ---@param cb fun(ok: boolean, err: string?)
    function fake.apply_patch(target, patch, cb)
        fake.apply_calls[#fake.apply_calls + 1] = { target = target, patch = patch }
        fake.in_flight = fake.in_flight + 1
        if fake.in_flight > fake.max_in_flight then
            fake.max_in_flight = fake.in_flight
        end
        local function finish(ok, err)
            fake.in_flight = fake.in_flight - 1
            if ok and type(env.on_apply) == "function" then
                env.on_apply()
            end
            if ok then
                fake.applied_patches[sha(patch)] = true
            end
            cb(ok, err)
        end
        local delay = tonumber(env.apply_delay) or 1
        vim.defer_fn(function()
            if env.apply_ok == false then
                finish(false, env.apply_error or "patch does not apply")
            else
                finish(true, nil)
            end
        end, delay)
    end

    function fake.remove(info, opts, cb)
        fake.remove_calls[#fake.remove_calls + 1] = { path = info.path, force = opts and opts.force }
        local ok = env.remove_ok ~= false
        vim.schedule(function()
            if ok and env.remove_dir ~= false then
                vim.fn.delete(info.path, "rf")
            end
            cb(ok, ok and nil or "remove failed")
        end)
    end

    package.loaded["pi.worktree"] = fake
    return fake
end

--- Register a fake session.
---@param id string
---@param cwd string
---@param opts? table
---@return table session
local function make_session(id, cwd, opts)
    opts = opts or {}
    local state = { running = opts.running ~= false }
    local session = {
        id = id,
        cwd = cwd,
        manifest_cwd = opts.manifest_cwd,
        attached_tab = opts.tab,
        worktree = opts.worktree,
        changed_files = {},
        _detached_busy = opts.busy,
        rpc = {
            is_running = function()
                return state.running
            end,
            stop = function()
                state.running = false
            end,
            send = function(_, cmd, cb)
                env.prompts[#env.prompts + 1] = { id = id, cmd = cmd }
                if cb then
                    cb({ success = true })
                end
            end,
        },
    }
    session._state = state
    Sessions._register_for_test(session)
    return session
end

--- Seed a manifest row.
---@param id string
---@param fields? table
local function seed_row(id, fields)
    local rows = Manifest.load(WORKSPACE)
    local row = vim.tbl_extend("force", {
        parent_id = "parent-1",
        name = id,
        task_prompt = "task",
        config = {},
        status = "completed",
        reported = true,
        created_at = Manifest.iso_now(),
        last_active_at = Manifest.iso_now(),
        run_generation = 1,
        worktree = worktree_info(),
    }, fields or {})
    rows[id] = row
    Manifest.save(rows, WORKSPACE)
    return row
end

--- Current persisted integration record.
---@param id string
---@return table?
local function record(id)
    local row = Manifest.load(WORKSPACE)[id]
    return type(row) == "table" and row.integration or nil
end

describe("pi.worktree_integration", function()
    local real = {}
    local manifest_tmp
    local parent
    local child

    before_each(function()
        Config.setup({})
        real.root = vim.fn.tempname()
        WORKSPACE = real.root .. "/parent"
        TARGET = WORKSPACE
        WT_PATH = WORKSPACE .. "/.worktrees/sub-1"
        vim.fn.mkdir(WT_PATH, "p")
        Integration._reset()
        Manifest._reset()
        real.manifest_path = Manifest.path
        real.batch = package.loaded["pi.subsessions.batch"]
        real.subsessions = package.loaded["pi.subsessions"]
        real.worktree = package.loaded["pi.worktree"]
        real.git = nil
        manifest_tmp = vim.fn.tempname() .. "-integration-manifest.json"
        Manifest.path = function()
            return manifest_tmp
        end
        -- `reconcile` / `enforce_retention` sweep every manifest on disk by
        -- design; a spec must not read this machine's real ~/.pi sessions.
        real.scopes = Manifest.scopes
        Manifest.scopes = function()
            return { { path = manifest_tmp, cwd = WORKSPACE } }
        end
        env = {
            prompts = {},
            patch = PATCH,
            probe = "clean",
            head = "base000",
            ignored = {},
            apply_delay = 1,
            -- Snapshots live outside the checkout, under the git common dir in
            -- production — so they must survive the checkout's removal.
            snapshot_dir = real.root .. "/snapshots",
        }
        package.loaded["pi.subsessions.batch"] = {
            is_waiting = function()
                return env.waiting == true
            end,
        }
        -- Contract stub for the two seams the engine calls into: closing a
        -- settled child (so its checkout becomes removable) and the wait marker.
        env.closed = {}
        package.loaded["pi.subsessions"] = {
            close = function(id, cb)
                env.closed[#env.closed + 1] = id
                if cb then
                    cb(true)
                end
                return true
            end,
            parent_waiting = function(session)
                return type(session) == "table" and (tonumber(session.waiting_subagents) or 0) > 0
            end,
        }
        env.fake = install_fake_worktree()
        Integration._set_git(function(_argv, _cwd, cb)
            cb(0, "", "")
        end)
        Integration._set_ignored(function(_info, cb)
            cb(env.ignored or {})
        end)
        Sessions._reset()
        parent = make_session("parent-1", TARGET)
        child = make_session("child-1", WT_PATH, { manifest_cwd = WORKSPACE, worktree = worktree_info() })
    end)

    after_each(function()
        Config.setup({})
        Integration._reset()
        Integration._set_ignored(nil)
        Integration._set_git(nil)
        Manifest.path = real.manifest_path
        Manifest.scopes = real.scopes
        Manifest._reset()
        package.loaded["pi.subsessions.batch"] = real.batch
        package.loaded["pi.subsessions"] = real.subsessions
        package.loaded["pi.worktree"] = real.worktree
        Sessions._reset()
        os.remove(manifest_tmp or "")
        if type(real.root) == "string" then
            vim.fn.delete(real.root, "rf")
        end
    end)

    --- Settle one child through the public API.
    ---@param id? string
    ---@return { outcome: string?, rec: table? }
    local function settle(id)
        id = id or "child-1"
        local session = id == "child-1" and child or Sessions.get_by_id(id)
        local pack = call(function(cb)
            Integration.on_child_settled(session, Manifest.load(WORKSPACE)[id], WORKSPACE, cb)
        end)
        return { outcome = pack[1], rec = pack[2] }
    end

    describe("patch parsing", function()
        it("collects both sides of a rename and skips /dev/null", function()
            local patch = table.concat({
                "diff --git a/old.txt b/new.txt",
                "--- a/old.txt",
                "+++ b/new.txt",
                "@@ -1 +1 @@",
                "-x",
                "+y",
                "diff --git a/added.txt b/added.txt",
                "--- /dev/null",
                "+++ b/added.txt",
                "@@ -0,0 +1 @@",
                "+hello",
                "",
            }, "\n")
            local files, complete = Integration.patch_files(patch)
            assert.are.same({ "old.txt", "new.txt", "added.txt" }, files)
            assert.is_true(complete)
        end)

        it("tolerates an empty or malformed patch", function()
            assert.are.same({}, (Integration.patch_files(nil)))
            assert.are.same({}, (Integration.patch_files("")))
            local files, complete = Integration.patch_files("not a patch")
            assert.are.same({}, files)
            assert.is_true(complete, "no header at all is not a parse failure")
        end)

        it("decodes C-quoted paths: escapes, octal UTF-8 and quotes", function()
            local patch = table.concat({
                'diff --git "a/tab\\tname" "b/tab\\tname"',
                '--- "a/tab\\tname"',
                '+++ "b/tab\\tname"',
                "@@ -1 +1 @@",
                "-a",
                "+b",
                'diff --git "a/\\303\\244.txt" "b/\\303\\244.txt"',
                '--- "a/\\303\\244.txt"',
                '+++ "b/\\303\\244.txt"',
                "@@ -1 +1 @@",
                "-a",
                "+b",
                'diff --git "a/say \\"hi\\".txt" "b/say \\"hi\\".txt"',
                '--- "a/say \\"hi\\".txt"',
                '+++ "b/say \\"hi\\".txt"',
                "@@ -1 +1 @@",
                "-a",
                "+b",
                "",
            }, "\n")
            local files, complete = Integration.patch_files(patch)
            assert.is_true(complete, "every quoted path must decode")
            assert.are.same({ "tab\tname", "\195\164.txt", 'say "hi".txt' }, files)
        end)

        it("fails closed on quoting it cannot decode", function()
            local unterminated = table.concat({
                'diff --git "a/unterminated b/x',
                "@@ -1 +1 @@",
                "-a",
                "+b",
                "",
            }, "\n")
            local files, complete = Integration.patch_files(unterminated)
            assert.are.same({}, files)
            assert.is_false(complete)

            local bad_escape = 'diff --git "a/q\\q" "b/q\\q"\n'
            local escaped, ok = Integration.patch_files(bad_escape)
            assert.are.same({}, escaped)
            assert.is_false(ok, "an unknown escape must not be guessed")
        end)

        it("does not mistake removed hunk content for a header", function()
            local patch = table.concat({
                "diff --git a/doc.md b/doc.md",
                "--- a/doc.md",
                "+++ b/doc.md",
                "@@ -1,3 +1,3 @@",
                "-- old bullet",
                "++ new bullet",
                "--- a/not-a-path",
                "+++ b/also-not",
                "",
            }, "\n")
            local files, complete = Integration.patch_files(patch)
            assert.is_true(complete)
            assert.are.same({ "doc.md" }, files)
        end)
    end)

    describe("_decide truth table", function()
        ---@param facts table `probe_nil = true` drops the probe (it must not be
        ---  masked by the `tbl_extend` default, which skips nil values).
        ---@return table
        local function decide(facts)
            local base = {
                has_patch = true,
                probe = "clean",
                snapshot_ok = true,
                target_ok = true,
                parent_state = "idle",
                parent_head = "base000",
                base_sha = "base000",
                child_alive = true,
                attempts = 0,
                max_attempts = 1,
                auto_resolve = true,
            }
            if facts.probe_nil then
                base.probe = nil
                facts.probe_nil = nil
            end
            return Integration._decide(vim.tbl_extend("force", base, facts))
        end

        it("applies only when every precondition holds", function()
            local d = decide({})
            assert.are.equal("apply", d.action)
            assert.are.equal("ready", d.reason)
        end)

        it("applies while the parent is blocked in a wait", function()
            assert.are.equal("apply", decide({ parent_state = "blocked" }).action)
        end)

        it("skips an empty patch", function()
            local d = decide({ has_patch = false })
            assert.are.equal("skip", d.action)
            assert.are.equal("empty", d.reason)
        end)

        it("never applies without a durable snapshot", function()
            local d = decide({ snapshot_ok = false })
            assert.are.equal("needs_attention", d.action)
            assert.are.equal("snapshot_missing", d.reason)
        end)

        it("fails closed when the probe cannot run", function()
            local d = decide({ probe_nil = true })
            assert.are.equal("needs_attention", d.action)
            assert.are.equal("probe_unavailable", d.reason)
            assert.is_true(d.retryable)
        end)

        it("treats an already applied patch as done without writing", function()
            local d = decide({ probe = "already", parent_state = "busy", modified_buffers = { "a.txt" } })
            assert.are.equal("mark_applied", d.action)
            assert.are.equal("already_applied", d.reason)
        end)

        it("never applies over a modified buffer", function()
            local d = decide({ modified_buffers = { "a.txt" } })
            assert.are.equal("needs_attention", d.action)
            assert.are.equal("modified_buffer", d.reason)
            assert.is_true(d.retryable)
        end)

        it("stops on dirty parent paths", function()
            local d = decide({ parent_dirty_hit = true })
            assert.are.equal("needs_attention", d.action)
            assert.are.equal("parent_dirty", d.reason)
        end)

        it("parks while the parent is busy, gone or another session is live", function()
            assert.are.equal("queue", decide({ parent_state = "busy" }).action)
            assert.are.equal("parent_busy", decide({ parent_state = "busy" }).reason)
            assert.are.equal("parent_gone", decide({ parent_state = "gone" }).reason)
            local other = decide({ other_session = "parent-2" })
            assert.are.equal("queue", other.action)
            assert.are.equal("other_session", other.reason)
        end)

        it("hands a conflict to the child only with budget, config and a live child", function()
            local d = decide({ probe = "conflict" })
            assert.are.equal("resolve", d.action)
            assert.are.equal("patch_conflict", d.reason)
            assert.are.equal("needs_attention", decide({ probe = "conflict", auto_resolve = false }).action)
            assert.are.equal("needs_attention", decide({ probe = "conflict", child_alive = false }).action)
            assert.are.equal("needs_attention", decide({ probe = "conflict", attempts = 1 }).action)
        end)

        it("never auto-applies across a base drift", function()
            local d = decide({ parent_head = "moved111" })
            assert.are.equal("resolve", d.action)
            assert.are.equal("base_drift", d.reason)
            local stopped = decide({ parent_head = "moved111", auto_resolve = false })
            assert.are.equal("needs_attention", stopped.action)
            assert.are.equal("base_drift", stopped.reason)
            assert.is_false(stopped.retryable)
        end)

        it("reports a missing target checkout", function()
            local d = decide({ target_ok = false })
            assert.are.equal("needs_attention", d.action)
            assert.are.equal("no_target", d.reason)
            assert.is_true(d.retryable)
        end)
    end)

    describe("capture and apply", function()
        it("skips a child with no changes and writes nothing", function()
            seed_row("child-1")
            env.patch = ""
            local result = settle()
            assert.are.equal("skipped", result.outcome)
            assert.is_nil(record("child-1"))
            assert.are.equal(0, #env.fake.apply_calls)
        end)

        it("stops in needs_attention when the capture fails (deterministic)", function()
            seed_row("child-1")
            env.patch = nil
            env.diff_error = "cannot capture 20001 untracked files"
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            local rec = record("child-1")
            assert.are.equal("needs_attention", rec.state)
            assert.are.equal("capture_failed", rec.reason)
            assert.are.equal(0, #env.fake.apply_calls)
        end)

        it("stops when the snapshot fails instead of applying unbacked work", function()
            seed_row("child-1")
            env.snapshot_error = "disk full"
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            assert.are.equal("snapshot_failed", record("child-1").reason)
            assert.are.equal(0, #env.fake.apply_calls)
        end)

        it("captures, snapshots, applies, records and removes the checkout", function()
            seed_row("child-1")
            local result = settle()
            assert.are.equal("applied", result.outcome)
            assert.are.equal(1, #env.fake.apply_calls)
            assert.are.equal(TARGET, env.fake.apply_calls[1].target)
            assert.are.equal(PATCH, env.fake.apply_calls[1].patch)

            local rec = record("child-1")
            assert.are.equal("applied", rec.state)
            assert.is_true(rec.archived == true)
            assert.are.equal(1, #env.closed, "the settled child must be closed before its checkout is deleted")
            assert.are.equal(vim.fn.sha256(PATCH), rec.patch_sha)
            assert.are.equal("base000", rec.base_sha)
            assert.are.equal("base000", rec.parent_head)
            assert.are.same({ "a.txt" }, rec.files)
            assert.is_true(rec.files_complete == true)
            assert.are.equal("base000", rec.head_sha, "the checkout HEAD is the delta baseline for a later run")
            assert.is_true(vim.fn.filereadable(rec.snapshot_path) == 1)
            assert.are.equal(1, #env.fake.remove_calls)
            assert.is_true(env.fake.remove_calls[1].force)
            assert.is_nil(child.worktree)
            assert.is_true(child._worktree_released)
            local abs = vim.fs.normalize(TARGET .. "/a.txt")
            assert.is_true(parent.changed_files[abs] == true, "parent changed_files must see the applied file")
            assert.is_false(Integration._busy(TARGET), "the per-target lock must be released")
        end)

        it("is idempotent: an already applied patch is never written twice", function()
            seed_row("child-1")
            env.probe = "already"
            local result = settle()
            assert.are.equal("applied", result.outcome)
            assert.are.equal(0, #env.fake.apply_calls)
            local rec = record("child-1")
            assert.are.equal("applied", rec.state)
            assert.are.equal("already_applied", rec.reason)
        end)

        it("does not integrate the same run twice", function()
            seed_row("child-1")
            settle()
            local diffs = env.fake.diff_calls
            local result = settle()
            assert.are.equal("applied", result.outcome)
            assert.are.equal(diffs, env.fake.diff_calls, "a settled+applied row must not be re-captured")
            assert.are.equal(1, #env.fake.apply_calls)
        end)

        it("keeps the checkout when ignored content would be lost", function()
            seed_row("child-1")
            env.ignored = { ".env.local" }
            local result = settle()
            assert.are.equal("applied_kept", result.outcome)
            local rec = record("child-1")
            assert.are.equal("applied", rec.state)
            assert.are.equal("ignored", rec.kept_reason)
            assert.are.equal(0, #env.fake.remove_calls)
            assert.is_true(vim.fn.isdirectory(WT_PATH) == 1)
        end)

        it("keeps the checkout when a newer run took it over mid-apply", function()
            seed_row("child-1")
            env.on_apply = function()
                local rows = Manifest.load(WORKSPACE)
                rows["child-1"].run_generation = 2
                Manifest.save(rows, WORKSPACE)
            end
            local result = settle()
            assert.are.equal("applied_kept", result.outcome)
            assert.are.equal("generation_changed", record("child-1").kept_reason)
            assert.are.equal(0, #env.fake.remove_calls)
        end)

        it("re-checks the parent right before the write and parks instead of applying", function()
            seed_row("child-1")
            -- The probe is the last fact gathered; flip the parent to "busy"
            -- there, i.e. after the decision and before `git apply`.
            env.probe_fn = function(target)
                if target == TARGET then
                    parent._detached_busy = true
                end
                return "clean"
            end
            local result = settle()
            assert.are.equal("queued", result.outcome)
            local rec = record("child-1")
            assert.are.equal("queued", rec.state)
            assert.are.equal("parent_busy", rec.reason)
            assert.are.equal(0, #env.fake.apply_calls, "nothing may be written while the parent is busy")
            assert.is_false(Integration._busy(TARGET))
        end)

        it("widens the modified-buffer check when the patch path list is incomplete", function()
            vim.fn.mkdir(env.snapshot_dir, "p")
            local snapshot = env.snapshot_dir .. "/child-1.patch"
            local fd = io.open(snapshot, "wb")
            fd:write(PATCH)
            fd:close()
            seed_row("child-1", {
                integration = {
                    state = "queued",
                    patch_sha = sha(PATCH),
                    base_sha = "base000",
                    snapshot_path = snapshot,
                    files = {},
                    files_complete = false, -- the path list could not be parsed
                    attempts = 0,
                    error = "",
                    run_generation = 1,
                },
            })
            -- A modified buffer at a path the (empty) list does not mention: only
            -- a whole-checkout scan can see it.
            local buf = vim.api.nvim_create_buf(false, false)
            vim.api.nvim_buf_set_name(buf, TARGET .. "/elsewhere.txt")
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "draft" })
            assert.is_true(vim.bo[buf].modified)
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            assert.are.equal("modified_buffer", record("child-1").reason)
            assert.are.equal(0, #env.fake.apply_calls, "an unknown path list must never be trusted")
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end)

        it("re-checks a modified buffer right before the write", function()
            seed_row("child-1")
            local buf = vim.api.nvim_create_buf(false, false)
            vim.api.nvim_buf_set_name(buf, TARGET .. "/a.txt")
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "clean" })
            vim.bo[buf].modified = false
            -- The user starts editing *after* the decision was made: the probe is
            -- the last async step before `git apply`.
            env.probe_fn = function(target)
                if target == TARGET then
                    vim.bo[buf].modified = true
                end
                return "clean"
            end
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            assert.are.equal("modified_buffer", record("child-1").reason)
            assert.are.equal(0, #env.fake.apply_calls)
            assert.is_false(Integration._busy(TARGET))
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end)

        it("keeps the checkout when a background writer added work after the capture", function()
            seed_row("child-1")
            local late = "diff --git a/late.txt b/late.txt\n--- /dev/null\n+++ b/late.txt\n@@ -0,0 +1 @@\n+late\n"
            local calls = 0
            env.diff_hook = function(_info, _opts, patch)
                calls = calls + 1
                if calls == 1 then
                    return patch -- the capture sees only the integrated work
                end
                return patch .. late -- the checkout grew afterwards
            end
            local result = settle()
            assert.are.equal("applied_kept", result.outcome)
            local rec = record("child-1")
            assert.are.equal("checkout_changed", rec.kept_reason)
            assert.are.equal(0, #env.fake.remove_calls, "a checkout holding new work must not be deleted")
            assert.is_true(vim.fn.isdirectory(WT_PATH) == 1)
        end)

        it("fails closed when the self-verification probe disagrees", function()
            seed_row("child-1")
            -- clean at decision time, then the post-apply probe says clean again
            env.probe_fn = function()
                return "clean"
            end
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            local rec = record("child-1")
            assert.are.equal("verify_failed", rec.reason)
            assert.are.equal(0, #env.fake.remove_calls)
        end)
    end)

    describe("parking and readiness", function()
        it("parks while the parent is busy and applies on on_parent_ready", function()
            seed_row("child-1")
            parent._detached_busy = true
            local result = settle()
            assert.are.equal("queued", result.outcome)
            assert.are.equal("parent_busy", record("child-1").reason)
            assert.are.equal(0, #env.fake.apply_calls)

            parent._detached_busy = false
            Integration.on_parent_ready(parent)
            wait_until(function()
                return record("child-1").state == "applied"
            end)
            assert.are.equal(1, #env.fake.apply_calls)
        end)

        it("applies while the parent is blocked in wait_subagents", function()
            seed_row("child-1")
            -- The wiring keeps this depth counter while the parent is parked in
            -- a wait; a blocked parent is still "busy" by run state, so the
            -- marker must win.
            parent.waiting_subagents = 1
            parent._detached_busy = true
            local result = settle()
            assert.are.equal("applied", result.outcome)
            parent.waiting_subagents = nil
        end)

        it("parks behind a modified buffer, then recovers once it is clean", function()
            seed_row("child-1")
            -- A scratch buffer cannot carry `modified`; use a real file buffer.
            local buf = vim.api.nvim_create_buf(false, false)
            vim.api.nvim_buf_set_name(buf, TARGET .. "/a.txt")
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local draft" })
            assert.is_true(vim.bo[buf].modified)
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            assert.are.equal("modified_buffer", record("child-1").reason)
            assert.are.equal(0, #env.fake.apply_calls)

            vim.bo[buf].modified = false
            Integration.on_parent_ready(parent)
            wait_until(function()
                return record("child-1").state == "applied"
            end)
            assert.are.equal(1, #env.fake.apply_calls)
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end)

        it("parks when another live session shares the target checkout", function()
            seed_row("child-1")
            make_session("parent-2", TARGET)
            local result = settle()
            assert.are.equal("queued", result.outcome)
            assert.are.equal("other_session", record("child-1").reason)
            assert.are.equal(0, #env.fake.apply_calls)
        end)
    end)

    describe("serialization", function()
        it("never runs two applies into one checkout at the same time", function()
            local second_path = WORKSPACE .. "/.worktrees/sub-2"
            vim.fn.mkdir(second_path, "p")
            local second_info = vim.tbl_extend("force", worktree_info(), { name = "sub-2", path = second_path })
            env.fake.detected[second_path] = second_info
            seed_row("child-1")
            seed_row("child-2", { worktree = second_info })
            env.patch_by_name = { ["sub-2"] = PATCH:gsub("two", "three") }
            local second = make_session("child-2", second_path, {
                manifest_cwd = WORKSPACE,
                worktree = second_info,
            })
            env.apply_delay = 20
            local first_done, second_done = false, false
            Integration.on_child_settled(child, Manifest.load(WORKSPACE)["child-1"], WORKSPACE, function()
                first_done = true
            end)
            Integration.on_child_settled(second, Manifest.load(WORKSPACE)["child-2"], WORKSPACE, function()
                second_done = true
            end)
            wait_until(function()
                return first_done and second_done
            end)
            -- Whatever the interleaving, only one write may touch the checkout
            -- at a time: the second parks (queued) or runs strictly after the
            -- first finished.
            assert.are.equal(1, env.fake.max_in_flight, "applies must be serialized per target")
            Integration.on_parent_ready(parent)
            wait_until(function()
                local a = record("child-1")
                local b = record("child-2")
                return a and a.state == "applied" and b and b.state == "applied"
            end)
            assert.are.equal(2, #env.fake.apply_calls)
            assert.are.equal(1, env.fake.max_in_flight)
        end)
    end)

    describe("conflicts and drift", function()
        it("hands a conflicting patch back to the child agent", function()
            seed_row("child-1")
            env.probe = "conflict"
            local result = settle()
            assert.are.equal("resolving", result.outcome)
            local rec = record("child-1")
            assert.are.equal("resolving", rec.state)
            assert.are.equal(1, rec.attempts)
            assert.are.equal("patch_conflict", rec.reason)
            assert.are.equal(0, #env.fake.apply_calls)
            assert.are.equal(1, #env.prompts)
            local prompt = env.prompts[1].cmd
            assert.are.equal("prompt", prompt.type)
            assert.is_truthy(prompt.message:find("Rebase", 1, true))
            assert.is_truthy(prompt.message:find(WT_PATH, 1, true))
        end)

        it("stops instead of hanging in resolving when rpc.send refuses", function()
            seed_row("child-1")
            env.probe = "conflict"
            child.rpc.send = function()
                return false
            end
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            local rec = record("child-1")
            assert.are.equal("needs_attention", rec.state)
            assert.are.equal("resolve_failed", rec.reason)
            assert.are.equal(0, #env.prompts)
            assert.is_false(Integration._busy(TARGET))
        end)

        it("stops when rpc.send throws", function()
            seed_row("child-1")
            env.probe = "conflict"
            child.rpc.send = function()
                error("client is gone")
            end
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            local rec = record("child-1")
            assert.are.equal("resolve_failed", rec.reason)
            assert.is_truthy(tostring(rec.error):find("client is gone", 1, true))
        end)

        it("stops after the attempt budget is spent", function()
            seed_row("child-1")
            env.probe = "conflict"
            assert.are.equal("resolving", settle().outcome)

            -- The resolving child settled again: re-capture (its worktree moved),
            -- still conflicting, budget exhausted.
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            local rec = record("child-1")
            assert.are.equal("needs_attention", rec.state)
            assert.are.equal("patch_conflict", rec.reason)
            assert.are.equal(1, rec.attempts)
        end)

        it("never resolves when auto_resolve is off", function()
            Config.setup({ worktree = { integration = { auto_resolve = false } } })
            seed_row("child-1")
            env.probe = "conflict"
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            assert.are.equal("patch_conflict", record("child-1").reason)
            assert.are.equal(0, #env.prompts)
        end)

        it("stops on a base drift instead of applying stale context", function()
            seed_row("child-1")
            env.head = "moved222"
            Config.setup({ worktree = { integration = { auto_resolve = false } } })
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            assert.are.equal("base_drift", record("child-1").reason)
            assert.are.equal(0, #env.fake.apply_calls)
        end)

        it("stops when the resolving child process is gone", function()
            seed_row("child-1")
            env.probe = "conflict"
            settle()
            assert.are.equal("resolving", record("child-1").state)
            child._state.running = false
            Integration._reset()
            local pack = call(function(cb)
                Integration.reconcile(cb)
            end)
            assert.are.equal(1, pack[1].checked)
            assert.are.equal("needs_attention", record("child-1").state)
            assert.are.equal("resolver_gone", record("child-1").reason)
        end)
    end)

    describe("reconcile", function()
        --- Seed a row stuck in `applying` with a valid snapshot.
        ---@param id string
        ---@param opts? table
        local function seed_applying(id, opts)
            opts = opts or {}
            vim.fn.mkdir(env.snapshot_dir, "p")
            local snapshot = env.snapshot_dir .. "/" .. id .. ".patch"
            local fd = io.open(snapshot, "wb")
            fd:write(opts.patch or PATCH)
            fd:close()
            local info = vim.tbl_extend("force", worktree_info(), { path = WT_PATH })
            return seed_row(id, {
                worktree = info,
                integration = {
                    state = "applying",
                    patch_sha = opts.patch_sha or vim.fn.sha256(opts.patch or PATCH),
                    base_sha = "base000",
                    parent_head = "base000",
                    snapshot_path = opts.snapshot_path or snapshot,
                    files = { "a.txt" },
                    attempts = 0,
                    error = "",
                    applied_at = "",
                    run_generation = 1,
                },
            })
        end

        it("recovers an applied crash as applied", function()
            seed_applying("child-1")
            env.probe = "already"
            local pack = call(function(cb)
                Integration.reconcile(cb)
            end)
            local summary = pack[1]
            assert.are.equal(1, summary.checked)
            assert.are.equal(1, summary.applied)
            assert.are.equal("applied", record("child-1").state)
        end)

        it("recovers a not-applied crash as queued", function()
            seed_applying("child-1")
            env.probe = "clean"
            local pack = call(function(cb)
                Integration.reconcile(cb)
            end)
            assert.are.equal(1, pack[1].queued)
            assert.are.equal("queued", record("child-1").state)
            assert.are.equal(1, Integration._queue_depth(TARGET))
        end)

        it("recovers an ambiguous crash as needs_attention", function()
            seed_applying("child-1")
            env.probe = "conflict"
            local pack = call(function(cb)
                Integration.reconcile(cb)
            end)
            assert.are.equal(1, pack[1].needs_attention)
            assert.are.equal("needs_attention", record("child-1").state)
            assert.are.equal("reconcile_conflict", record("child-1").reason)
        end)

        it("stops when the snapshot is gone or drifted", function()
            seed_applying("child-1", { snapshot_path = WT_PATH .. "/missing.patch" })
            local pack = call(function(cb)
                Integration.reconcile(cb)
            end)
            assert.are.equal(1, pack[1].needs_attention)
            assert.are.equal("snapshot_missing", record("child-1").reason)
            assert.are.equal(0, #env.fake.probe_calls)
        end)

        it("leaves a queued row parked for its parent", function()
            seed_row("child-1", {
                integration = {
                    state = "queued",
                    patch_sha = vim.fn.sha256(PATCH),
                    base_sha = "base000",
                    snapshot_path = WT_PATH .. "/whatever.patch",
                    files = { "a.txt" },
                    attempts = 0,
                    error = "",
                    applied_at = "",
                    run_generation = 1,
                },
            })
            local pack = call(function(cb)
                Integration.reconcile(cb)
            end)
            assert.are.equal(1, pack[1].queued)
            assert.are.equal("queued", record("child-1").state)
        end)
    end)

    describe("lock hygiene", function()
        it("releases the lock when a queued retry has nothing to apply", function()
            seed_row("child-1", {
                integration = {
                    state = "queued",
                    patch_sha = sha(PATCH),
                    base_sha = "base000",
                    snapshot_path = env.snapshot_dir .. "/missing.patch",
                    files = { "a.txt" },
                    files_complete = true,
                    attempts = 0,
                    error = "",
                    run_generation = 1,
                },
            })
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            assert.are.equal("snapshot_missing", record("child-1").reason)
            assert.is_false(Integration._busy(TARGET), "a retry that fails must not keep the lock")
        end)

        it("releases the lock under its acquisition key even if the target re-resolves", function()
            seed_row("child-1")
            -- No parent at settle time: the initial target is the checkout's
            -- repo_root. The parent then appears (with a different directory)
            -- after the lock is taken, so `attempt` re-resolves a new root.
            Sessions._reset()
            local real_patch = Manifest.patch
            local patched = false
            Manifest.patch = function(...)
                local ok = real_patch(...)
                if not patched then
                    patched = true
                    make_session("parent-1", TARGET .. "/nested")
                end
                return ok
            end
            local done, outcome = false, nil
            Integration.on_child_settled(child, Manifest.load(WORKSPACE)["child-1"], WORKSPACE, function(state)
                outcome = state
                done = true
            end)
            assert.is_true(
                vim.wait(5000, function()
                    return done
                end, 5),
                "settle timed out"
            )
            Manifest.patch = real_patch
            assert.are.equal("applied", outcome)
            assert.is_false(Integration._busy(TARGET), "the acquisition key's lock must not leak")
            assert.is_false(Integration._busy(TARGET .. "/nested"))
        end)
    end)

    describe("new run on an integrated checkout", function()
        --- Write a patch snapshot under the (out-of-checkout) snapshot dir.
        ---@param name string
        ---@param patch string
        ---@return string
        local function write_snapshot(name, patch)
            vim.fn.mkdir(env.snapshot_dir, "p")
            local path = env.snapshot_dir .. "/" .. name
            local fd = io.open(path, "wb")
            fd:write(patch)
            fd:close()
            return path
        end

        --- An `applied` record from a previous run.
        ---@param fields table
        ---@return table
        local function applied_record(fields)
            return vim.tbl_extend("force", {
                state = "applied",
                patch_sha = sha(PATCH),
                base_sha = "base000",
                head_sha = "base000",
                snapshot_path = write_snapshot("prev.patch", PATCH),
                files = { "a.txt" },
                files_complete = true,
                attempts = 0,
                error = "",
                applied_at = "2024-01-01T00:00:00Z",
                run_generation = 1,
            }, fields or {})
        end

        it("captures from the new base when the checkout's base changed", function()
            local recreated = vim.tbl_extend("force", worktree_info(), { base_sha = "newbase" })
            env.fake.detected[WT_PATH] = recreated
            seed_row("child-1", {
                run_generation = 2,
                worktree = recreated,
                integration = applied_record({ head_sha = "h1" }),
            })
            env.head = "newbase"
            env.head_by_path = { [WT_PATH] = "h2" }
            local result = settle()
            assert.are.equal("applied", result.outcome)
            local opts = env.fake.diff_opts[1]
            assert.is_nil(opts and opts.from, "a new base is a plain base→now capture")
            local rec = record("child-1")
            assert.are.equal("newbase", rec.base_sha)
            assert.are.equal("h2", rec.head_sha)
            assert.are.equal("", rec.from_sha)
            assert.are.equal(2, rec.run_generation)
        end)

        it("captures only the new work when the same checkout was integrated before", function()
            local old = PATCH:gsub("two", "old")
            seed_row("child-1", {
                run_generation = 2,
                integration = applied_record({
                    head_sha = "h2",
                    patch_sha = sha(old),
                    snapshot_path = write_snapshot("old.patch", old),
                }),
            })
            env.head = "base000"
            env.head_by_path = { [WT_PATH] = "h3" }
            env.probe_fn = function(_target, patch)
                if sha(patch) == sha(old) then
                    return "already" -- the checkout still carries the previous work
                end
                if env.fake.applied_patches[sha(patch)] then
                    return "already" -- … and the delta is present after the write
                end
                return "clean"
            end
            local result = settle()
            assert.are.equal("applied", result.outcome)
            local opts = env.fake.diff_opts[#env.fake.diff_opts]
            assert.are.equal("h2", opts and opts.from, "the delta must start at the previous capture's head")
            local rec = record("child-1")
            assert.are.equal("h2", rec.from_sha)
            assert.are.equal(1, #env.fake.apply_calls, "only the delta is applied")
        end)

        it("refuses to replay when the previous work was never committed", function()
            seed_row("child-1", {
                run_generation = 2,
                integration = applied_record({ head_sha = "base000" }),
            })
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            local rec = record("child-1")
            assert.are.equal("delta_baseline_missing", rec.reason)
            assert.is_truthy(rec.error:find("uncommitted", 1, true))
            assert.are.equal(0, env.fake.diff_calls, "no capture may run without a baseline")
            assert.are.equal(0, #env.fake.apply_calls)
        end)

        it("refuses when the previous capture recorded no head baseline", function()
            local legacy = applied_record({})
            legacy.head_sha = nil -- a row written before head_sha existed
            seed_row("child-1", { run_generation = 2, integration = legacy })
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            local rec = record("child-1")
            assert.are.equal("delta_baseline_missing", rec.reason)
            assert.is_truthy(rec.error:find("head", 1, true))
            assert.are.equal(0, env.fake.diff_calls)
        end)

        it("refuses when the checkout no longer carries the previously integrated changes", function()
            seed_row("child-1", {
                run_generation = 2,
                integration = applied_record({ head_sha = "h2" }),
            })
            env.head_by_path = { [WT_PATH] = "h3" }
            env.probe_fn = function()
                return "clean" -- the old post-image is gone (rewound checkout)
            end
            local result = settle()
            assert.are.equal("needs_attention", result.outcome)
            assert.are.equal("delta_baseline_missing", record("child-1").reason)
            assert.are.equal(0, env.fake.diff_calls)
        end)
    end)

    describe("retention", function()
        --- Seed an applied row with a live checkout and snapshot.
        ---@param id string
        ---@param fields? table
        local function seed_applied(id, fields)
            local path = WORKSPACE .. "/.worktrees/" .. id
            vim.fn.mkdir(path, "p")
            vim.fn.mkdir(env.snapshot_dir, "p")
            env.fake.detected[path] = vim.tbl_extend("force", worktree_info(), { name = id, path = path })
            vim.fn.mkdir(env.snapshot_dir, "p")
            local snapshot = env.snapshot_dir .. "/" .. id .. ".patch"
            local fd = io.open(snapshot, "wb")
            fd:write(PATCH)
            fd:close()
            return seed_row(
                id,
                vim.tbl_extend("force", {
                    worktree = env.fake.detected[path],
                    integration = {
                        state = "applied",
                        patch_sha = vim.fn.sha256(PATCH),
                        base_sha = "base000",
                        parent_head = "base000",
                        snapshot_path = snapshot,
                        files = { "a.txt" },
                        attempts = 0,
                        error = "",
                        applied_at = "2024-01-01T00:00:00Z",
                        run_generation = 1,
                    },
                }, fields or {})
            )
        end

        it("removes only applied+verified+inactive+unpinned checkouts over the cap", function()
            Config.setup({ worktree = { integration = { keep_count = 1 } } })
            seed_applied("child-1", {
                integration = {
                    state = "applied",
                    patch_sha = vim.fn.sha256(PATCH),
                    base_sha = "base000",
                    snapshot_path = env.snapshot_dir .. "/child-1.patch",
                    files = { "a.txt" },
                    attempts = 0,
                    error = "",
                    applied_at = "2024-01-01T00:00:00Z",
                },
            })
            seed_applied("child-2", {
                integration = {
                    state = "applied",
                    patch_sha = vim.fn.sha256(PATCH),
                    base_sha = "base000",
                    snapshot_path = env.snapshot_dir .. "/child-2.patch",
                    files = { "a.txt" },
                    attempts = 0,
                    error = "",
                    applied_at = "2024-01-02T00:00:00Z",
                },
            })
            seed_applied("child-3", {
                integration = {
                    state = "applied",
                    patch_sha = vim.fn.sha256(PATCH),
                    base_sha = "base000",
                    snapshot_path = env.snapshot_dir .. "/child-3.patch",
                    files = { "a.txt" },
                    attempts = 0,
                    error = "",
                    applied_at = "2024-01-03T00:00:00Z",
                },
            })
            env.probe = "already"

            local pack = call(function(cb)
                Integration.enforce_retention(WORKSPACE, cb)
            end)
            local summary = pack[1]
            assert.are.equal(3, summary.managed)
            assert.are.equal(2, summary.removed)
            -- Oldest first: child-1 and child-2 go, child-3 stays.
            assert.is_true(Manifest.load(WORKSPACE)["child-1"].integration.archived == true)
            assert.is_true(Manifest.load(WORKSPACE)["child-2"].integration.archived == true)
            assert.is_true(Manifest.load(WORKSPACE)["child-3"].integration.archived ~= true)
            assert.is_true(vim.fn.isdirectory(WORKSPACE .. "/.worktrees/child-3") == 1)
        end)

        it("never deletes unintegrated, parked, pinned or unverified checkouts", function()
            Config.setup({ worktree = { integration = { keep_count = 0 } } })
            seed_applied("child-1", {
                integration = {
                    state = "needs_attention",
                    patch_sha = vim.fn.sha256(PATCH),
                    snapshot_path = env.snapshot_dir .. "/child-1.patch",
                    files = {},
                    attempts = 0,
                    error = "conflict",
                    reason = "patch_conflict",
                },
            })
            seed_applied("child-2", {
                integration = {
                    state = "queued",
                    patch_sha = vim.fn.sha256(PATCH),
                    snapshot_path = env.snapshot_dir .. "/child-2.patch",
                    files = {},
                    attempts = 0,
                    error = "",
                },
            })
            seed_applied("child-3", {
                integration = {
                    state = "applied",
                    patch_sha = vim.fn.sha256(PATCH),
                    snapshot_path = env.snapshot_dir .. "/child-3.patch",
                    files = {},
                    attempts = 0,
                    error = "",
                    pinned = true,
                },
            })
            seed_applied("child-4", {
                integration = {
                    state = "applied",
                    patch_sha = vim.fn.sha256(PATCH),
                    snapshot_path = env.snapshot_dir .. "/child-4.patch",
                    files = {},
                    attempts = 0,
                    error = "",
                    kept_reason = "ignored",
                },
            })
            env.probe = "conflict"

            local pack = call(function(cb)
                Integration.enforce_retention(WORKSPACE, cb)
            end)
            assert.are.equal(0, pack[1].removed)
            assert.are.equal(0, #env.fake.remove_calls)
            for _, id in ipairs({ "child-1", "child-2", "child-3", "child-4" }) do
                assert.is_true(
                    vim.fn.isdirectory(WORKSPACE .. "/.worktrees/" .. id) == 1,
                    id .. " must survive retention"
                )
            end
        end)

        it("never deletes a checkout whose row belongs to a newer run", function()
            Config.setup({ worktree = { integration = { keep_count = 0 } } })
            seed_applied("child-1")
            local rows = Manifest.load(WORKSPACE)
            rows["child-1"].run_generation = 2
            Manifest.save(rows, WORKSPACE)
            env.probe = "already"
            local pack = call(function(cb)
                Integration.enforce_retention(WORKSPACE, cb)
            end)
            assert.are.equal(0, pack[1].removed)
            assert.are.equal(0, #env.fake.remove_calls)
            assert.is_true(vim.fn.isdirectory(WORKSPACE .. "/.worktrees/child-1") == 1)
            local found = false
            for _, item in ipairs(pack[1].kept or {}) do
                if item.reason == "stale_generation" then
                    found = true
                end
            end
            assert.is_true(found, "a stale row must be reported, not silently skipped")
        end)

        it("never deletes a checkout that grew after the capture", function()
            Config.setup({ worktree = { integration = { keep_count = 0 } } })
            seed_applied("child-1")
            env.probe = "already"
            local late = "diff --git a/late.txt b/late.txt\n--- /dev/null\n+++ b/late.txt\n@@ -0,0 +1 @@\n+late\n"
            env.diff_hook = function()
                return PATCH .. late
            end
            local pack = call(function(cb)
                Integration.enforce_retention(WORKSPACE, cb)
            end)
            assert.are.equal(0, pack[1].removed)
            assert.are.equal(0, #env.fake.remove_calls)
            local found = false
            for _, item in ipairs(pack[1].kept or {}) do
                if item.reason == "checkout_changed" then
                    found = true
                end
            end
            assert.is_true(found, "new work in the checkout must block retention")
        end)

        it("never deletes a checkout a live session owns", function()
            Config.setup({ worktree = { integration = { keep_count = 0 } } })
            seed_applied("child-1")
            env.probe = "already"
            -- A live session rooted in the checkout: removal would break it.
            make_session("child-1", WORKSPACE .. "/.worktrees/child-1")
            local pack = call(function(cb)
                Integration.enforce_retention(WORKSPACE, cb)
            end)
            assert.are.equal(0, pack[1].removed)
            assert.are.equal(0, #env.fake.remove_calls)
        end)

        it("is a no-op while the managed count is under the cap", function()
            Config.setup({ worktree = { integration = { keep_count = 15 } } })
            seed_applied("child-1")
            env.probe = "already"
            local pack = call(function(cb)
                Integration.enforce_retention(WORKSPACE, cb)
            end)
            assert.are.equal(0, pack[1].removed)
        end)
    end)

    describe("configuration", function()
        it("does nothing when worktree.integration.auto is off", function()
            Config.setup({ worktree = { integration = { auto = false } } })
            seed_row("child-1")
            local result = settle()
            assert.are.equal("disabled", result.outcome)
            assert.is_nil(record("child-1"))
            assert.are.equal(0, env.fake.diff_calls)
        end)

        it("treats a missing config table as the documented defaults", function()
            -- G31: never mutate the shared defaults table in place.
            Config.options.worktree = vim.deepcopy(Config.options.worktree)
            Config.options.worktree.integration = nil
            seed_row("child-1")
            local result = settle()
            assert.are.equal("applied", result.outcome)
        end)
    end)

    describe("wait detection", function()
        it("delegates to Batch.is_waiting and degrades to false without the seam", function()
            package.loaded["pi.subsessions.batch"] = {
                is_waiting = function()
                    return true
                end,
            }
            assert.is_true(Integration.is_waiting(parent))
            package.loaded["pi.subsessions.batch"] = { is_waiting = function() end }
            assert.is_false(Integration.is_waiting(parent))
            package.loaded["pi.subsessions.batch"] = nil
            assert.is_false(Integration.is_waiting(parent))
            assert.is_false(Integration.is_waiting(nil))
        end)
    end)
end)

-- Real-git end to end ---------------------------------------------------------
--
-- The suite above stubs `pi.worktree` so every branch is deterministic. This
-- one drives the **real** module against a throwaway repository: create →
-- capture → snapshot → apply → remove, and the idempotent replay. It needs the
-- git binary (like tests/worktree_git_spec.lua) and no pi process.

describe("pi.worktree_integration (real git)", function()
    local W = require("pi.worktree")
    local real = {}
    local repo
    local workspace
    local manifest_tmp
    local parent
    local child

    ---@param argv string[]
    ---@param cwd string
    ---@return integer code, string stdout, string stderr
    local function sh(argv, cwd)
        local res = vim.system(argv, { text = true, cwd = cwd }):wait()
        return res.code or -1, res.stdout or "", res.stderr or ""
    end

    ---@param argv string[]
    ---@param cwd string
    ---@return string out
    local function git(argv, cwd)
        local code, out, err = sh(argv, cwd)
        assert.are.equal(0, code, table.concat(argv, " ") .. " failed: " .. err .. out)
        return out
    end

    ---@param id string
    ---@param dir string
    ---@param running boolean
    ---@return table session
    local function register(id, dir, running)
        local state = { running = running ~= false }
        local session = {
            id = id,
            cwd = dir,
            changed_files = {},
            rpc = {
                is_running = function()
                    return state.running
                end,
                stop = function()
                    state.running = false
                end,
                send = function() end,
            },
        }
        require("pi.sessions.manager")._register_for_test(session)
        return session
    end

    before_each(function()
        Config.setup({})
        Integration._reset()
        require("pi.sessions.manager")._reset()
        require("pi.subsessions.manifest")._reset()
        real.worktree = package.loaded["pi.worktree"]
        real.subsessions = package.loaded["pi.subsessions"]
        real.batch = package.loaded["pi.subsessions.batch"]
        package.loaded["pi.worktree"] = W
        package.loaded["pi.subsessions"] = {
            close = function(_id, cb)
                if cb then
                    cb(true)
                end
                return true
            end,
            parent_waiting = function()
                return false
            end,
        }
        package.loaded["pi.subsessions.batch"] = { is_waiting = function() end }

        local repo_dir = vim.fn.tempname() .. "-e2e"
        vim.fn.mkdir(repo_dir, "p")
        repo = assert(vim.uv.fs_realpath(repo_dir))
        git({ "git", "init", "-q" }, repo)
        git({ "git", "config", "user.email", "pi-test@example.com" }, repo)
        git({ "git", "config", "user.name", "pi test" }, repo)
        vim.fn.writefile({ "seed" }, repo .. "/seed.txt")
        git({ "git", "add", "-A" }, repo)
        git({ "git", "commit", "-qm", "init" }, repo)
        workspace = repo

        manifest_tmp = vim.fn.tempname() .. "-integration-manifest.json"
        real.manifest_path = require("pi.subsessions.manifest").path
        require("pi.subsessions.manifest").path = function()
            return manifest_tmp
        end
    end)

    after_each(function()
        require("pi.subsessions.manifest").path = real.manifest_path
        require("pi.subsessions.manifest")._reset()
        require("pi.sessions.manager")._reset()
        Integration._reset()
        package.loaded["pi.worktree"] = real.worktree
        package.loaded["pi.subsessions"] = real.subsessions
        package.loaded["pi.subsessions.batch"] = real.batch
        os.remove(manifest_tmp or "")
        vim.fn.delete(repo or "", "rf")
    end)

    it("applies a child's patch to the parent checkout and disposes of the worktree", function()
        local created
        W.create({ cwd = repo, name = "sub-e2e" }, function(info)
            created = info
        end)
        assert.is_true(
            vim.wait(20000, function()
                return created ~= nil
            end, 10),
            "worktree creation timed out"
        )
        assert.is_truthy(created, "worktree creation failed")
        local wt_path = created.path

        -- The child's work: one new file and one edited file.
        vim.fn.writefile({ "feature" }, wt_path .. "/feature.txt")
        vim.fn.writefile({ "seed", "one", "two" }, wt_path .. "/seed.txt")

        -- Parent + child fake sessions and the child's manifest row.
        parent = register("parent-e2e", repo)
        child = register("child-e2e", wt_path)
        child.worktree = created
        local Manifest = require("pi.subsessions.manifest")
        Manifest.save({
            ["child-e2e"] = {
                parent_id = "parent-e2e",
                name = "sub-e2e",
                task_prompt = "task",
                config = {},
                status = "completed",
                reported = true,
                created_at = Manifest.iso_now(),
                last_active_at = Manifest.iso_now(),
                run_generation = 1,
                worktree = created,
            },
        }, workspace)

        local done = false
        local outcome, record
        Integration.on_child_settled(child, Manifest.load(workspace)["child-e2e"], workspace, function(state, rec)
            outcome, record = state, rec
            done = true
        end)
        assert.is_true(
            vim.wait(30000, function()
                return done
            end, 10),
            "integration timed out"
        )
        assert.are.equal("applied", outcome)
        assert.are.equal("applied", record.state)

        -- The parent's working tree carries the child's work (uncommitted).
        assert.are.equal("feature\n", table.concat(vim.fn.readfile(repo .. "/feature.txt"), "\n") .. "\n")
        assert.are.equal("seed\none\ntwo\n", table.concat(vim.fn.readfile(repo .. "/seed.txt"), "\n") .. "\n")
        local status = git({ "git", "status", "--porcelain" }, repo)
        assert.is_truthy(status:find("feature.txt", 1, true), "new file must show up in the parent checkout")
        assert.is_truthy(status:find("seed.txt", 1, true))

        -- The checkout is gone, the snapshot survives and the record is archived.
        assert.are.equal(0, vim.fn.isdirectory(wt_path))
        assert.is_true(vim.fn.filereadable(record.snapshot_path) == 1)
        assert.is_true(record.archived == true)
        assert.is_nil(child.worktree)
        local listed = git({ "git", "-C", repo, "worktree", "list" }, repo)
        assert.is_nil(listed:find("sub-e2e", 1, true), "the checkout must be unregistered")
    end)

    it("integrates only the new work of a reused, already integrated checkout", function()
        -- `.git/info/exclude` is shared by every worktree of the repository and
        -- is not part of the tree, so the ignored file keeps the checkout alive
        -- without polluting the patch.
        vim.fn.writefile({ ".env.local" }, repo .. "/.git/info/exclude")

        local created
        W.create({ cwd = repo, name = "sub-delta" }, function(info)
            created = info
        end)
        assert.is_true(
            vim.wait(20000, function()
                return created ~= nil
            end, 10),
            "worktree creation timed out"
        )
        local wt = created.path

        -- Round 1: work *committed* in the checkout (that is what makes a later
        -- incremental capture trustworthy) plus ignored content that keeps it.
        vim.fn.writefile({ "one" }, wt .. "/one.txt")
        git({ "git", "-C", wt, "add", "one.txt" }, wt)
        git({ "git", "-C", wt, "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-qm", "one" }, wt)
        local head1 = vim.trim(git({ "git", "-C", wt, "rev-parse", "HEAD" }, wt))
        vim.fn.writefile({ "secret" }, wt .. "/.env.local")

        parent = register("parent-delta", repo)
        child = register("child-delta", wt)
        child.worktree = created
        local Manifest = require("pi.subsessions.manifest")
        Manifest.save({
            ["child-delta"] = {
                parent_id = "parent-delta",
                name = "sub-delta",
                task_prompt = "task",
                config = {},
                status = "completed",
                reported = true,
                created_at = Manifest.iso_now(),
                last_active_at = Manifest.iso_now(),
                run_generation = 1,
                worktree = created,
            },
        }, workspace)

        local function settle()
            local done, state = false, nil
            Integration.on_child_settled(child, Manifest.load(workspace)["child-delta"], workspace, function(out)
                state = out
                done = true
            end)
            assert.is_true(
                vim.wait(30000, function()
                    return done
                end, 10),
                "settle timed out"
            )
            return state
        end

        assert.are.equal("applied_kept", settle())
        assert.are.equal(head1, Manifest.load(workspace)["child-delta"].integration.head_sha)
        assert.is_true(vim.fn.filereadable(repo .. "/one.txt") == 1)
        assert.is_true(vim.fn.isdirectory(wt) == 1, "ignored content keeps the checkout")

        -- Round 2: a new run on the same checkout, with uncommitted new work.
        local entries = Manifest.load(workspace)
        entries["child-delta"].run_generation = 2
        Manifest.save(entries, workspace)
        vim.fn.writefile({ "two" }, wt .. "/two.txt")

        local state = settle()
        assert.is_true(state == "applied" or state == "applied_kept", "delta integrate failed: " .. tostring(state))
        local rec = Manifest.load(workspace)["child-delta"].integration
        assert.are.equal(head1, rec.from_sha, "the delta must start at the previously integrated commit")
        assert.are.equal("one\n", table.concat(vim.fn.readfile(repo .. "/one.txt"), "\n") .. "\n")
        assert.are.equal("two\n", table.concat(vim.fn.readfile(repo .. "/two.txt"), "\n") .. "\n")
        local status = git({ "git", "status", "--porcelain" }, repo)
        assert.is_truthy(status:find("two.txt", 1, true))
        assert.is_nil(status:find("one.txt", 1, true) and status:find("^A  one.txt"), "one.txt must not be re-added")
    end)

    it("does not replay an applied patch on a second settle", function()
        local created
        W.create({ cwd = repo, name = "sub-replay" }, function(info)
            created = info
        end)
        assert.is_true(vim.wait(20000, function()
            return created ~= nil
        end))
        vim.fn.writefile({ "feature" }, created.path .. "/feature.txt")
        parent = register("parent-replay", repo)
        child = register("child-replay", created.path)
        child.worktree = created
        local Manifest = require("pi.subsessions.manifest")
        Manifest.save({
            ["child-replay"] = {
                parent_id = "parent-replay",
                name = "sub-replay",
                task_prompt = "task",
                config = {},
                status = "completed",
                reported = true,
                created_at = Manifest.iso_now(),
                last_active_at = Manifest.iso_now(),
                run_generation = 1,
                worktree = created,
            },
        }, workspace)

        local function settle()
            local done, state = false, nil
            Integration.on_child_settled(child, Manifest.load(workspace)["child-replay"], workspace, function(s)
                state = s
                done = true
            end)
            assert.is_true(vim.wait(30000, function()
                return done
            end, 10))
            return state
        end

        assert.are.equal("applied", settle())
        local before = git({ "git", "status", "--porcelain" }, repo)
        assert.are.equal("applied", settle())
        assert.are.equal(before, git({ "git", "status", "--porcelain" }, repo), "the parent tree must not change again")
    end)
end)
