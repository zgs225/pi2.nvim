-- After :PiResume, dormant children stay in the manifest and must be listable
-- / reusable. list_subagents reads ctx.sessionManager.getSessionId() (not
-- ExtensionAPI); dispatch({ target, message }) revives instead of spawning.

local Config = require("pi.config")
local Manifest = require("pi.subsessions.manifest")
local Filter = require("pi.subsessions.sessions_list")
local Batch = require("pi.subsessions.batch")
local Sessions = require("pi.sessions.manager")
local Subsessions = require("pi.subsessions")
local SessionList = require("pi.ui.sessions")
local History = require("pi.sessions.history")

Config.setup({})

---@param get_session_id fun(): string?
---@param manifest table
---@return table[]
local function list_subagents(get_session_id, manifest)
    local parent = get_session_id()
    if not parent or parent == "" then
        return {}
    end
    local meta = manifest.__lineage__
    local lineage = (type(meta) == "table" and type(meta[parent]) == "string") and meta[parent] or parent
    local subagents = {}
    for id, e in pairs(manifest) do
        if
            type(id) == "string"
            and id ~= ""
            and not id:match("^__")
            and type(e) == "table"
            and e.parent_id == lineage
        then
            subagents[#subagents + 1] = { id = id, name = e.name, status = e.status }
        end
    end
    return subagents
end

local function subagent_ts()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    local src = assert(io.open(root .. "/extensions/subagent.ts", "r"))
    local text = src:read("*a")
    src:close()
    return text
end

describe("reopened parent reuses a closed sub-session", function()
    local manifest_tmp
    local batch_tmp
    local real_manifest_path
    local real_parse
    local real_spawn
    local real_revive
    local real_get_by_id

    before_each(function()
        manifest_tmp = vim.fn.tempname() .. "-manifest.json"
        batch_tmp = vim.fn.tempname() .. "-batches.json"
        real_manifest_path = Manifest.path
        Manifest.path = function()
            return manifest_tmp
        end
        Manifest._reset()
        Batch._set_path(batch_tmp)
        Batch._reset()
        Batch._set_path(batch_tmp)
        real_parse = History.parse
        real_spawn = Subsessions.spawn
        real_revive = Subsessions.revive
        real_get_by_id = Sessions.get_by_id
    end)

    after_each(function()
        History.parse = real_parse
        Subsessions.spawn = real_spawn
        Subsessions.revive = real_revive
        Sessions.get_by_id = real_get_by_id
        Manifest.path = real_manifest_path
        Manifest._reset()
        Batch._reset()
        os.remove(manifest_tmp)
        os.remove(batch_tmp)
    end)

    local function seed_closed_child()
        Manifest.register_session_lineage("parent-uuid", "parent-uuid")
        Manifest.upsert("child-uuid", {
            parent_id = "parent-uuid",
            parent_epoch = 0,
            name = "worker",
            task_prompt = "previous task",
            config = {},
            status = "active",
            reported = false,
            created_at = "t0",
            last_active_at = "t0",
            agent_spawned = true,
            run_generation = 1,
        })
        Subsessions.rebuild_statuses()
        assert.equals("dormant", Manifest.load()["child-uuid"].status)
    end

    it("list_subagents reads ctx.sessionManager.getSessionId, not ExtensionAPI", function()
        local text = subagent_ts()
        assert.is_truthy(text:find("function parentSessionId(ctx: ExtensionContext)", 1, true))
        assert.is_truthy(text:find("ctx.sessionManager.getSessionId()", 1, true))
        assert.is_falsy(text:find("pi as { getSessionId?: () => string }", 1, true))
        assert.is_falsy(text:find("sessionId(pi)", 1, true))
        assert.is_truthy(text:find("const parent = parentSessionId(ctx);", 1, true))
    end)

    it("tool descriptions tell the model dormant children are reusable", function()
        local text = subagent_ts()
        assert.is_truthy(text:find("Closed (dormant) children remain reusable", 1, true))
        assert.is_truthy(text:find("Do not spawn a new child only because status is not active", 1, true))
        assert.is_truthy(text:find("the host revives the process", 1, true))
    end)

    it("lists dormant children when the parent id comes from sessionManager", function()
        seed_closed_child()
        local listed = list_subagents(function()
            return "parent-uuid"
        end, Manifest.load())
        assert.equals(1, #listed)
        assert.equals("child-uuid", listed[1].id)
        assert.equals("dormant", listed[1].status)
    end)

    it("after :PiResume the child stays in the manifest but is hidden from :PiSessions", function()
        seed_closed_child()
        History.parse = function()
            return { id = "parent-uuid", path = "/fake/parent.jsonl" }
        end

        local parent = {
            tab = 1,
            id = "tmp-1",
            lineage_id = "tmp-1",
            conversation_epoch = 0,
            rpc = {
                is_running = function()
                    return true
                end,
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

        Subsessions.on_parent_resumed(parent, "/fake/parent.jsonl")
        assert.equals("parent-uuid", parent.lineage_id)
        assert.equals("parent-uuid", parent.id)

        local children = Manifest.children_of("parent-uuid")
        assert.equals(1, #children)
        assert.equals("child-uuid", children[1]._id)
        assert.equals("dormant", children[1].status)
        assert.is_false(Filter.child_visible(children[1]))

        local rows = SessionList.build_rows({ parent }, function()
            return 0
        end, function()
            return "resumed"
        end)
        assert.equals(1, #rows)
        assert.equals("parent-uuid", rows[1].session_id)
    end)

    it("dispatch({ target, message }) revives a dormant child instead of spawning", function()
        seed_closed_child()
        History.parse = function()
            return { id = "parent-uuid", path = "/fake/parent.jsonl" }
        end

        local parent = {
            id = "parent-uuid",
            lineage_id = "parent-uuid",
            conversation_epoch = 0,
            rpc = {
                is_running = function()
                    return true
                end,
            },
        }
        Subsessions.on_parent_resumed(parent, "/fake/parent.jsonl")

        Sessions.get_by_id = function()
            return nil
        end

        local spawned = 0
        local revived = {}
        Subsessions.spawn = function(_parent, _opts, callback)
            spawned = spawned + 1
            callback(nil, "should not spawn")
        end
        Subsessions.revive = function(id, callback)
            revived[#revived + 1] = id
            callback({
                id = id,
                rpc = {
                    is_running = function()
                        return true
                    end,
                    send = function(_self, _msg, cb)
                        cb({ success = true })
                    end,
                },
            }, nil)
        end

        local done
        Batch.dispatch(parent, {
            items = { { target = "child-uuid", message = "continue previous work" } },
        }, function(res)
            done = res
        end)

        vim.wait(1000, function()
            return #revived > 0
        end)

        assert.is_not_nil(done)
        assert.equals(0, spawned)
        assert.are.same({ "child-uuid" }, revived)
        assert.is_string(done.batch_id)
    end)
end)
