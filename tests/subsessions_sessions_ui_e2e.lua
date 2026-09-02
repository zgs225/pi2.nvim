-- Headless e2e: sub-session list sort/filter, H toggle, PiResume exclusion.
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/subsessions_sessions_ui_e2e.lua

local Manifest = require("pi.subsessions.manifest")
local SessionList = require("pi.ui.sessions")
local Sessions = require("pi.sessions.manager")
local History = require("pi.sessions.history")
local Subsessions = require("pi.subsessions")

local manifest_tmp = vim.fn.tempname() .. "-e2e-manifest.json"
Manifest.path = function()
    return manifest_tmp
end

local function fake_session(tab, id)
    return {
        tab = tab,
        id = id,
        rpc = {
            is_running = function()
                return true
            end,
            stop = function() end,
        },
        chat = {
            is_streaming = function()
                return false
            end,
            is_compacting = function()
                return false
            end,
            active_verb = function()
                return nil
            end,
            extension_status = function()
                return nil
            end,
        },
    }
end

local ok, err = pcall(function()
    -- 1) Stable child sort (created_at tie → id ascending)
    local base = {
        parent_id = "parent-e2e",
        task_prompt = "t",
        config = {},
        status = "active",
        reported = false,
        created_at = "2026-09-02T10:00:00Z",
        last_active_at = "2026-09-02T10:00:00Z",
    }
    Manifest.upsert("zzz-child", vim.tbl_extend("force", base, { name = "z" }))
    Manifest.upsert("aaa-child", vim.tbl_extend("force", base, { name = "a" }))
    Manifest.upsert("mmm-child", vim.tbl_extend("force", base, {
        name = "m",
        created_at = "2026-09-02T11:00:00Z",
    }))

    local first = Manifest.children_of("parent-e2e")
    local second = Manifest.children_of("parent-e2e")
    assert(#first == 3, "expected 3 manifest children")
    assert(first[1]._id == second[1]._id and first[2]._id == second[2]._id and first[3]._id == second[3]._id,
        "children_of order must be stable across calls")
    assert(first[1]._id == "mmm-child", "newest created_at first")
    assert(first[2]._id == "aaa-child", "tie broken by id ascending")
    assert(first[3]._id == "zzz-child", "tie broken by id ascending")

    -- 2) :PiSessions hides dormant by default; H shows all
    Manifest.upsert("live-child", vim.tbl_extend("force", base, {
        name = "live",
        status = "active",
        created_at = "2026-09-02T12:00:00Z",
    }))
    Manifest.upsert("sleep-child", vim.tbl_extend("force", base, {
        name = "sleep",
        status = "dormant",
        created_at = "2026-09-02T09:00:00Z",
    }))

    local parent = fake_session(42, "parent-e2e")
    Sessions._register_for_test(parent)

    local function build()
        return SessionList.build_rows({ parent }, function()
            return 0
        end, function()
            return "parent chat"
        end)
    end

    local rows = build()
    local child_ids = {}
    for _, row in ipairs(rows) do
        if row.child_id then
            child_ids[#child_ids + 1] = row.child_id
        end
    end
    assert(vim.tbl_contains(child_ids, "live-child"), "active child visible by default")
    assert(not vim.tbl_contains(child_ids, "sleep-child"), "dormant child hidden by default")

    SessionList.toggle_show_hidden_children()
    assert(SessionList.show_hidden_children() == true, "H toggle should enable hidden rows")
    rows = build()
    child_ids = {}
    for _, row in ipairs(rows) do
        if row.child_id then
            child_ids[#child_ids + 1] = row.child_id
        end
    end
    assert(vim.tbl_contains(child_ids, "sleep-child"), "dormant child visible when H is on")
    SessionList.toggle_show_hidden_children()

    Manifest.upsert("epoch-child", vim.tbl_extend("force", base, {
        name = "epoch0",
        status = "active",
        parent_id = "parent-e2e",
        parent_epoch = 0,
    }))
    parent.lineage_id = "parent-e2e"
    parent.id = "parent-e2e"
    parent.conversation_epoch = 0
    Subsessions.on_parent_new_conversation(parent)
    assert(parent.conversation_epoch == 1, "epoch should increment after /new")

    rows = build()
    child_ids = {}
    for _, row in ipairs(rows) do
        if row.child_id then
            child_ids[#child_ids + 1] = row.child_id
        end
    end
    assert(not vim.tbl_contains(child_ids, "epoch-child"), "prior epoch child hidden after /new")

    SessionList.toggle_show_hidden_children()
    rows = build()
    local found_epoch_child = false
    for _, row in ipairs(rows) do
        if row.child_id == "epoch-child" then
            found_epoch_child = true
        end
    end
    SessionList.toggle_show_hidden_children()
    assert(found_epoch_child, "H shows prior-conversation children")

    Sessions._reset()

    -- 3) PiResume excludes manifest children
    local parent_path = "/tmp/pi-sessions-e2e-parent.jsonl"
    local child_path = "/tmp/pi-sessions-e2e-child.jsonl"
    local orig_list = History.list
    History.list = function()
        return {
            {
                path = parent_path,
                id = "parent-resume-id",
                name = "parent",
                timestamp = "2025-06-01T10:00:00Z",
                first_message = "parent",
                modified = 2,
            },
            {
                path = child_path,
                id = "child-resume-id",
                name = "child worker",
                timestamp = "2025-06-02T11:00:00Z",
                first_message = "child",
                modified = 3,
            },
        }
    end
    Manifest.upsert("child-resume-id", vim.tbl_extend("force", base, {
        parent_id = "parent-resume-id",
        name = "child worker",
        status = "dormant",
    }))

    local captured_items
    local orig_select = vim.ui.select
    vim.ui.select = function(items, opts, _)
        captured_items = items
        if opts and opts.on_choice then
            opts.on_choice(nil)
        end
    end

    Sessions.resume_session()
    History.list = orig_list
    vim.ui.select = orig_select

    assert(type(captured_items) == "table", "resume_session should open picker")
    assert(#captured_items == 1, "resume picker should exclude sub-sessions")
    assert(captured_items[1].session.id == "parent-resume-id", "only parent session remains")
    assert(Manifest.is_child_session("child-resume-id"), "child still in manifest for reuse")
end)

os.remove(manifest_tmp)
Sessions._reset()

if not ok then
    io.stderr:write("subsessions_sessions_ui_e2e: FAIL\n" .. tostring(err) .. "\n")
    vim.cmd("cq 1")
end

print("subsessions_sessions_ui_e2e: OK")
vim.cmd("cq 0")
