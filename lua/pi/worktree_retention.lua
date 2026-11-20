--- Deferred retention sweep for pi-managed git worktrees.
---
--- `Worktree.create` calls `M.schedule(repo_root)` after a successful create;
--- the sweep itself is debounced (one pending timer per repository) so a burst
--- of creates — a sub-session fan-out, say — costs exactly one pass. Nothing
--- here runs on the startup path, and nothing here spawns git directly: every
--- subprocess belongs to `Worktree` (`list`, `sweep_locks`, `release`,
--- `snapshot_gc`), and every callback is node-style and fires on the main loop.
---
--- One pass (`M.run`), in the order the spec fixes:
---
---   1. config merge        2. `Worktree.list`        3. live-session set
---   4. stale-lock sweep    5. partition             6. mtime sort (newest first)
---   7. select             8. sequential release     9. snapshot GC
---  10. report + notify (only when something changed)
---
--- Two invariants are load-bearing and enforced here, not in the UI:
---
--- - **A5 / metadata only**: a candidate must carry `pi2-worktree.json`
---   (`entry.managed`). A hand-made `git worktree add` is never touched — it
---   only ever increments `report.foreign`.
--- - **Never GC blind**: the live set comes from the session registry. If that
---   module cannot be loaded the pass aborts with an error instead of guessing,
---   because a checkout whose owner we cannot see looks exactly like an
---   abandoned one.

local M = {}

local Config = require("pi.config")
local Notify = require("pi.notify")
local RepoConfig = require("pi.worktree_config")
local Worktree = require("pi.worktree")

local uv = vim.uv

---@class pi.WorktreeRetentionOpts
---@field cwd? string          Repository scope (default: process cwd)
---@field enabled? boolean     Override worktree.retention.enabled
---@field max_count? integer   Override (default 25)
---@field max_age_days? number Override (default 14)
---@field snapshot_days? number Override (default 30)
---@field dry_run? boolean     Select + report, never release
---@field quiet? boolean       No notification
---@field skip? fun(entry: pi.WorktreeListEntry): boolean  Extra veto (live-session check is built in)

---@class pi.WorktreeRetentionReport
---@field disabled boolean
---@field repo_root? string
---@field removed string[]      names released (in order)
---@field kept string[]         names that were candidates but survived (dirty / ahead / lock / error)
---@field foreign integer       unmanaged checkouts seen — NEVER touched (A5)
---@field live string[]         names skipped because a live session uses them
---@field stale_locks string[]  paths whose lock the sweep released
---@field snapshots_removed integer
---@field errors string[]

--- Config + opts collapsed into one fully-populated set of knobs.
---@class pi.WorktreeRetentionSettings
---@field enabled boolean
---@field max_count integer
---@field max_age_days number
---@field snapshot_days number
---@field sweep_locks boolean

--- Debounce delay for `M.schedule`. Module scope so `M._set_delay` can replace
--- it without touching config.
local DEFAULT_DELAY_MS = 8000
--- Fallbacks used when the config block is absent (the module must be safe to
--- call before `worktree.retention` exists in `defaults`).
local DEFAULT_MAX_COUNT = 25
local DEFAULT_MAX_AGE_DAYS = 14
local DEFAULT_SNAPSHOT_DAYS = 30
local SECONDS_PER_DAY = 86400

local delay_ms = DEFAULT_DELAY_MS

--- One pending deferred run per resolved repository path. Held at module scope
--- so libuv cannot collect a timer out from under its own callback (the reaper's
--- `sweep_timer` pattern).
---@type table<string, uv.uv_timer_t>
local pending = {}

--- Path key shared by the debounce slots and the live-set lookups.
--- `vim.fn.resolve` normalizes symlinks, so a session cwd and a `realpath`ed
--- list entry land on the same key.
---@param path string?
---@return string?
local function resolve_key(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local ok, resolved = pcall(vim.fn.resolve, path)
    if ok and type(resolved) == "string" and resolved ~= "" then
        return resolved
    end
    return path
end

--- Merge `worktree.retention` (config, read at call time — never cached) with a
--- repository's `.pi-worktrees.toml` `[retention]` and the per-call `opts`.
---
--- Precedence is `opts` > repository > user config > defaults: a repository that
--- commits a retention policy is stating a fact about itself (its checkouts are
--- expensive, keep fewer), while the user keeps the last word per call.
--- `enabled` and `sweep_locks` are user-level switches; they are read before the
--- sweep knows which repository it is in, so a repository cannot set them.
--- Negative values are clamped to 0 (a `max_count` of 0 means "keep nothing
--- beyond the age rule").
---@param opts? pi.WorktreeRetentionOpts
---@param repo_root? string Repository whose config overrides the user config
---@return pi.WorktreeRetentionSettings
local function merged_settings(opts, repo_root)
    local call_opts = type(opts) == "table" and opts or {}
    local cfg = Config.options.worktree or {}
    local retention = type(cfg.retention) == "table" and cfg.retention or {}
    local repo = RepoConfig.retention(repo_root)

    ---@param key string
    ---@param fallback boolean
    ---@return boolean
    local function bool(key, fallback)
        local value = call_opts[key]
        if type(value) ~= "boolean" then
            value = retention[key]
        end
        if type(value) ~= "boolean" then
            return fallback
        end
        return value
    end

    ---@param key string
    ---@param fallback number
    ---@return number
    local function number(key, fallback)
        local value = tonumber(call_opts[key]) or tonumber(repo[key]) or tonumber(retention[key]) or fallback
        return math.max(value, 0)
    end

    return {
        enabled = bool("enabled", true),
        max_count = math.floor(number("max_count", DEFAULT_MAX_COUNT)),
        max_age_days = number("max_age_days", DEFAULT_MAX_AGE_DAYS),
        snapshot_days = number("snapshot_days", DEFAULT_SNAPSHOT_DAYS),
        sweep_locks = bool("sweep_locks", true),
    }
end

--- Every path a live session is using, plus every checkout some other part of
--- the plugin has reserved for an imminent spawn (a spawn that has not
--- registered its session yet must still win over the sweep).
---@param entries pi.WorktreeListEntry[]
---@param manager table Loaded `pi.sessions.manager`
---@return table<string, true>? live
---@return string? err
local function build_live_set(entries, manager)
    ---@type table<string, true>
    local live = {}
    ---@param path any
    local function add(path)
        local key = resolve_key(path)
        if key then
            live[key] = true
        end
    end

    --- An unreadable registry must not become an empty live set: a failing
    --- `list_all` fails the whole pass instead of reporting "nothing is live".
    local ok_sessions, sessions = pcall(manager.list_all)
    if not ok_sessions or type(sessions) ~= "table" then
        return nil, "retention: sessions manager unavailable"
    end
    for _, session in ipairs(sessions) do
        if type(session) == "table" then
            add(session.cwd)
            add(session._process_cwd)
            if type(session.worktree) == "table" then
                add(session.worktree.path)
            end
            if type(session.assigned_worktree) == "table" then
                add(session.assigned_worktree.path)
            end
        end
    end

    for _, entry in ipairs(entries) do
        if type(entry) == "table" and type(entry.path) == "string" then
            local ok_reserved, reserved = pcall(manager.cwd_reserved, entry.path)
            if ok_reserved and reserved then
                add(entry.path)
            end
        end
    end

    return live
end

--- Stop and close a deferred timer. `vim.defer_fn` closes its own timer when it
--- fires, so a late cancel must not error on an already-closed handle.
---@param timer uv.uv_timer_t?
local function stop_timer(timer)
    if not timer then
        return
    end
    pcall(function()
        timer:stop()
        timer:close()
    end)
end

--- Schedule a debounced retention sweep for `repo_root`'s repository.
---
--- Coalescing, not rescheduling: a second call while a run is pending is a
--- no-op, so N creates in one burst cost one pass. The callback clears its own
--- slot before running, which is what lets the next create schedule a fresh one
--- (and keeps a failed pass from wedging the slot forever).
---@param repo_root? string Repository root (default: the process cwd)
function M.schedule(repo_root)
    local target = repo_root
    if type(target) ~= "string" or target == "" then
        target = vim.fn.getcwd()
    end
    local key = resolve_key(target)
    if key == nil or key == "" or pending[key] then
        return
    end
    -- Narrowed for the closure: LuaLS does not carry the `key == nil` guard
    -- above into a deferred callback, and the slot must stay a plain string key.
    local slot = key --[[@as string]]
    pending[slot] = vim.defer_fn(function()
        pending[slot] = nil
        -- `vim.defer_fn` already delivers this on the main loop.
        M.run({ cwd = slot })
    end, delay_ms)
end

--- Cancel pending debounced runs.
---@param repo_root? string Repository root (nil cancels every pending run)
function M.cancel(repo_root)
    if type(repo_root) == "string" and repo_root ~= "" then
        local key = resolve_key(repo_root)
        if key == nil then
            return
        end
        -- Narrowed for the slot write: the `key == nil` guard does not narrow `key`.
        local slot = key --[[@as string]]
        local timer = pending[slot]
        if timer then
            pending[slot] = nil
            stop_timer(timer)
        end
        return
    end
    for key, timer in pairs(pending) do
        pending[key] = nil
        stop_timer(timer)
    end
end

--- Test hook: override the debounce delay.
---@param ms integer? Milliseconds (nil restores the default)
function M._set_delay(ms)
    local value = tonumber(ms)
    if value == nil then
        delay_ms = DEFAULT_DELAY_MS
        return
    end
    delay_ms = math.max(math.floor(value), 0)
end

--- Run the retention sweep now.
---
--- The ten steps below are executed in the spec's order; every exit reports
--- through `cb` on the main loop exactly once.
---@param opts? pi.WorktreeRetentionOpts
---@param cb? fun(report: pi.WorktreeRetentionReport?, err: string?)
function M.run(opts, cb)
    local call_opts = type(opts) == "table" and opts or {}
    local settings = merged_settings(call_opts)
    local cwd = type(call_opts.cwd) == "string" and call_opts.cwd ~= "" and call_opts.cwd or vim.fn.getcwd()

    --- Deliver the result on the main loop exactly once: callers re-enter
    --- buffers, notify, and session state from here.
    ---@param report pi.WorktreeRetentionReport?
    ---@param err string?
    local function finish(report, err)
        if type(cb) ~= "function" then
            return
        end
        vim.schedule(function()
            cb(report, err)
        end)
    end

    -- 1. Config merge. A disabled sweep answers immediately and touches nothing.
    if not settings.enabled then
        -- A complete report shape: the callback contract has no partial form.
        ---@type pi.WorktreeRetentionReport
        local disabled = {
            disabled = true,
            removed = {},
            kept = {},
            foreign = 0,
            live = {},
            stale_locks = {},
            snapshots_removed = 0,
            errors = {},
        }
        return finish(disabled, nil)
    end

    ---@type pi.WorktreeRetentionReport
    local report = {
        disabled = false,
        repo_root = nil,
        removed = {},
        kept = {},
        foreign = 0,
        live = {},
        stale_locks = {},
        snapshots_removed = 0,
        errors = {},
    }

    -- 2. List the repository's linked worktrees (async, `Worktree` owns the git call).
    Worktree.list(cwd, function(entries, list_err)
        if type(entries) ~= "table" then
            return finish(nil, list_err or "retention: worktree list failed")
        end
        ---@cast entries pi.WorktreeListEntry[]

        -- 3. Live set. Hard failure when the session registry cannot be loaded:
        -- without it every checkout of a live session looks abandoned.
        local loaded, manager = pcall(require, "pi.sessions.manager")
        if not loaded or type(manager) ~= "table" or type(manager.list_all) ~= "function" then
            return finish(nil, "retention: sessions manager unavailable")
        end
        local live, live_err = build_live_set(entries, manager)
        if not live then
            return finish(nil, live_err)
        end

        for _, entry in ipairs(entries) do
            if type(entry) == "table" and type(entry.repo_root) == "string" and entry.repo_root ~= "" then
                report.repo_root = entry.repo_root
                break
            end
        end
        if not report.repo_root then
            -- Pure filesystem detection (no git subprocess), for the empty-list case.
            local info = Worktree.detect(cwd)
            if info and type(info.repo_root) == "string" and info.repo_root ~= "" then
                report.repo_root = info.repo_root
            end
        end

        -- 1b. Repository config, now that the root is known: a `[retention]` block in
        -- the repository's `.pi-worktrees.toml` overrides the user config for this
        -- repository (`enabled` was already read and stays a user-level switch).
        settings = merged_settings(call_opts, report.repo_root)

        ---@param entry pi.WorktreeListEntry
        ---@return boolean
        local function is_live(entry)
            local key = resolve_key(entry.path)
            return key ~= nil and live[key] == true
        end

        --- `opts.skip` is the caller's extra veto (a session about to start, a
        --- checkout under manual review). A throwing veto counts as "live":
        --- never delete on an undecidable answer.
        ---@param entry pi.WorktreeListEntry
        ---@return boolean
        local function vetoed(entry)
            if type(call_opts.skip) ~= "function" then
                return false
            end
            local ok_skip, veto = pcall(call_opts.skip, entry)
            if not ok_skip then
                report.errors[#report.errors + 1] = "retention: skip: " .. tostring(veto)
                return true
            end
            return veto and true or false
        end

        --- Steps 5-10: everything after the lock sweep.
        local function after_sweep()
            -- 5. Partition. `missing` entries are snapshot-GC territory and never
            -- prune candidates; anything without pi2 metadata is foreign and is
            -- only counted (A5).
            ---@type pi.WorktreeListEntry[]
            local candidates = {}
            for _, entry in ipairs(entries) do
                if type(entry) == "table" and not entry.missing then
                    if entry.managed == true then
                        candidates[#candidates + 1] = entry
                    else
                        report.foreign = report.foreign + 1
                    end
                end
            end

            -- 6. Last filesystem activity per candidate, then newest first: index
            -- 1..max_count is "the ones to keep". The name tiebreak keeps the
            -- selection stable for checkouts written in the same second.
            ---@type table<string, integer>
            local mtimes = {}
            for _, entry in ipairs(candidates) do
                local st = uv.fs_stat(entry.path)
                mtimes[entry.path] = (st and st.mtime and st.mtime.sec) or 0
            end
            table.sort(candidates, function(a, b)
                local ma = mtimes[a.path] or 0
                local mb = mtimes[b.path] or 0
                if ma ~= mb then
                    return ma > mb
                end
                return (a.name or "") < (b.name or "")
            end)

            -- 7. Over the cap or older than the age rule → selected. A selected
            -- candidate a live session (or `opts.skip`) uses is reported, never
            -- released.
            local now = os.time()
            local max_age = settings.max_age_days * SECONDS_PER_DAY
            ---@type pi.WorktreeListEntry[]
            local to_release = {}
            for index, entry in ipairs(candidates) do
                local age = now - (mtimes[entry.path] or 0)
                if index > settings.max_count or age > max_age then
                    if is_live(entry) or vetoed(entry) then
                        report.live[#report.live + 1] = entry.name
                    else
                        to_release[#to_release + 1] = entry
                    end
                end
            end

            --- 10. Report, and notify only when the pass changed something: a
            --- healthy tree stays silent.
            local function complete()
                local changed = #report.removed > 0 or #report.stale_locks > 0 or report.snapshots_removed > 0
                -- A dry run (and `quiet`) changes nothing, so it must not announce changes.
                local silent = call_opts.quiet or call_opts.dry_run
                if changed and not silent then
                    Notify.info(
                        string.format(
                            "Worktree retention: removed %d, released %d stale lock(s), dropped %d snapshot(s)",
                            #report.removed,
                            #report.stale_locks,
                            report.snapshots_removed
                        )
                    )
                end
                finish(report, nil)
            end

            if call_opts.dry_run == true then
                -- Select + report only: nothing is released and no snapshot is
                -- dropped, so a dry run is a pure read of the tree.
                for _, entry in ipairs(to_release) do
                    report.removed[#report.removed + 1] = entry.name
                end
                return complete()
            end

            --- 9. Snapshot GC over checkouts that no longer exist; a name still
            --- on disk keeps everything its snapshot dir holds.
            local function after_release()
                if type(report.repo_root) ~= "string" or report.repo_root == "" then
                    report.errors[#report.errors + 1] = "retention: cannot resolve repository root"
                    return complete()
                end
                if type(Worktree.snapshot_gc) ~= "function" then
                    report.errors[#report.errors + 1] = "retention: snapshot_gc unavailable"
                    return complete()
                end
                ---@type table<string, true>
                local live_names = {}
                for _, entry in ipairs(entries) do
                    if type(entry) == "table" and type(entry.name) == "string" and uv.fs_stat(entry.path) then
                        live_names[entry.name] = true
                    end
                end
                ---@type { keep_days: number, live_names: table<string, true> }
                local gc_opts = { keep_days = settings.snapshot_days, live_names = live_names }
                Worktree.snapshot_gc(report.repo_root, gc_opts, function(removed_count, gc_err)
                    if type(removed_count) == "number" then
                        report.snapshots_removed = removed_count
                    end
                    if gc_err then
                        report.errors[#report.errors + 1] = tostring(gc_err)
                    end
                    complete()
                end)
            end

            -- 8. Release sequentially, never in parallel: `release` snapshots and
            -- then removes, and two concurrent `git worktree prune`s race on the
            -- same common dir.
            ---@param index integer
            local function release_next(index)
                local entry = to_release[index]
                if not entry then
                    return after_release()
                end
                Worktree.release(entry, function(removed)
                    if removed == true then
                        report.removed[#report.removed + 1] = entry.name
                    else
                        -- Dirty, ahead, locked, or a failed snapshot: `release`
                        -- already decided. Never retry, never force.
                        report.kept[#report.kept + 1] = entry.name
                    end
                    release_next(index + 1)
                end)
            end
            release_next(1)
        end

        -- 4. Stale-lock sweep first: a stale lock also blocks `git worktree
        -- prune` for a directory that is already gone. Its failure is recorded
        -- and the prune continues — a broken sweep must not stop the GC.
        if settings.sweep_locks and type(Worktree.sweep_locks) == "function" then
            Worktree.sweep_locks(cwd, function(sweep_report, sweep_err)
                if type(sweep_report) == "table" and type(sweep_report.released) == "table" then
                    for _, path in ipairs(sweep_report.released) do
                        report.stale_locks[#report.stale_locks + 1] = path
                    end
                end
                if sweep_err then
                    report.errors[#report.errors + 1] = tostring(sweep_err)
                end
                after_sweep()
            end)
        else
            after_sweep()
        end
    end)
end

--- Test hook: cancel every pending run and restore the default delay.
function M._reset()
    M.cancel(nil)
    delay_ms = DEFAULT_DELAY_MS
end

return M
