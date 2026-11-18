-- Worktree protocol of the parent-side sub-agent extension
-- (extensions/subagent.ts):
--
-- 1. `dispatch_subagents` spawn items accept `worktree` in two shapes: `{ path }`
--    borrows an existing linked worktree (never created/released/merged/reset),
--    `{ create }` creates one — or adopts the one its `name` already names — with
--    a base strategy (`head` / `fresh` / explicit revision). Spawn-only either way.
-- 2. `list_subagents` reports the checkout the child runs in: the assigned one
--    first (`assigned_worktree`, borrowed or adopted), then the owned row
--    `worktree` this spawn created, projected with `owned` / `reused` flags.
-- 3. `read_subagent` reads the parent manifest's recorded `session_file` first
--    (a child in an assigned worktree keeps its JSONL in that other checkout),
--    falls back to the cwd session-directory scan, and refuses to project a row
--    that belongs to another parent's lineage.
--
-- Two layers, both real:
--   * static assertions on the extension source (always run), and
--   * a behaviour test that imports the actual extension with a stub `typebox`
--     and a fake `pi` API, then executes list_subagents / read_subagent against
--     a temp manifest (skipped when node cannot strip TypeScript types).

local function repo_root()
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
end

---@return string
local function source()
    local path = repo_root() .. "/extensions/subagent.ts"
    local file = assert(io.open(path, "r"), "subagent.ts must exist at: " .. path)
    local content = file:read("*a")
    file:close()
    return content
end

--- Description string of a tool definition (anchored on its `name:`).
---@param content string
---@param tool string
---@return string
local function tool_description(content, tool)
    local desc = content:match('name: "' .. tool .. '",.-description:%s*"([^"]*)"')
    assert(desc, tool .. " must be registered with a description")
    return desc
end

--- Description string of the next field after an anchor (e.g. `path: Type.String({`).
---@param content string
---@param anchor string
---@param what string
---@return string
local function field_description(content, anchor, what)
    local desc = content:match(anchor .. '.-description:%s*"([^"]*)"')
    assert(desc, "could not find a description for " .. what .. " in extensions/subagent.ts")
    return desc
end

---@param text string
---@param needles string[]
---@param what string
local function contains_all(text, needles, what)
    for _, needle in ipairs(needles) do
        assert.is_truthy(text:find(needle, 1, true), string.format("%s must mention %q; got: %s", what, needle, text))
    end
end

---@param text string
---@param needles string[]
---@param what string
local function contains_none(text, needles, what)
    for _, needle in ipairs(needles) do
        assert.is_nil(text:find(needle, 1, true), string.format("%s must not mention %q", what, needle))
    end
end

local function worktree_schema_block(content)
    return assert(
        content:match("const WorktreeRefSchema%s*=%s*Type%.Union%((.-)\n%);"),
        "the worktree schema must be a Type.Union(...) constant"
    )
end

describe("extensions/subagent.ts worktree protocol (static)", function()
    local content

    before_each(function()
        content = source()
    end)

    it("declares worktree as an optional borrow-or-create union on the spawn variant", function()
        assert.is_truthy(
            content:match("worktree:%s*Type%.Optional%(WorktreeRefSchema%)"),
            "the spawn variant must declare worktree: Type.Optional(WorktreeRefSchema)"
        )
        local block = worktree_schema_block(content)
        local _, variants = block:gsub("Type%.Object%(", "")
        assert.are.equal(2, variants, "the union must carry exactly the borrow and create variants")
        assert.is_truthy(block:match("path:%s*Type%.String%({"), "the borrow variant must have a string `path`")
        assert.is_truthy(block:match("create:%s*Type%.Union%("), "the create variant must take a boolean or an object")
        contains_all(block, { "base", "name", "setup" }, "the create variant")
    end)

    it("keeps worktree on the spawn variant only", function()
        local _, declarations = content:gsub("worktree:%s*Type%.Optional%(WorktreeRefSchema%)", "")
        assert.are.equal(1, declarations, "exactly one item variant may declare worktree")
        local declared_at = assert(content:find("worktree:%s*Type%.Optional%(WorktreeRefSchema%)"))
        local reuse_at = assert(content:find('message:%s*Type%.String%({%s*description:%s*"Follow%-up message'))
        assert.is_true(declared_at < reuse_at, "worktree must be declared on the spawn (first) variant")
        contains_all(
            field_description(content, "message:%s*Type%.String%({", "the reuse message field"),
            { "`worktree`", "rejected" },
            "the reuse message description"
        )
    end)

    it("documents every frozen rule of the worktree request", function()
        local block = worktree_schema_block(content)
        local descriptions = {}
        for desc in block:gmatch('description:%s*"([^"]*)"') do
            table.insert(descriptions, desc)
        end
        assert.is_true(
            #descriptions >= 4,
            "the union, both variants and the create discriminator each describe themselves"
        )
        local all = table.concat(descriptions, "\n")
        -- Each rule below is one a model must be able to act on.
        contains_all(all, {
            "borrow an existing linked worktree",
            "parent's repository",
            "not both",
            "adopt",
            "inherits the parent's cwd",
            "shares that checkout",
            "no isolation between those children",
            "file-level isolation",
            "released automatically",
            "kept",
        }, "the worktree description")
        contains_none(all, { "${" }, "the worktree description must stay a static string")
    end)

    it("documents the create variant's base strategy, name reuse and setup opt-in", function()
        local block = assert(
            content:match("const WorktreeCreateSchema%s*=%s*Type%.Object%((.-)\n%);"),
            "the create schema must be its own Type.Object(...) constant"
        )
        contains_all(block, {
            "'head' (default",
            "'fresh'",
            "origin/HEAD",
            "already resolves to a linked worktree",
            "setup_cmd",
        }, "the create schema")
    end)

    it("describes the path field as an absolute existing linked worktree", function()
        contains_all(
            field_description(content, "path:%s*Type%.String%({", "the worktree path field"),
            { "Absolute path", "already exist", "parent's repository" },
            "the path description"
        )
    end)

    it("lists worktree among the spawn-only fields of dispatch_subagents", function()
        contains_all(
            tool_description(content, "dispatch_subagents"),
            { "`name`, `model`, `thinking_level`, `tools` and `worktree`", "five spawn-only fields" },
            "the dispatch description"
        )
    end)

    it("documents the worktree projection of list_subagents", function()
        contains_all(
            tool_description(content, "list_subagents"),
            { "last_active_at, worktree?, error?", "owned", "reused", "{ path, name?, owned?, reused? }" },
            "the list_subagents description"
        )
    end)

    it("documents the recorded-transcript lookup of read_subagent", function()
        contains_all(tool_description(content, "read_subagent"), {
            "session_file",
            "readable",
            "scanning this workspace's session directory",
            "another parent's lineage",
            "session file not found",
        }, "the read_subagent description")
    end)

    it("projects the assigned checkout first, then the owned row checkout", function()
        assert.is_truthy(
            content:match("worktree:%s*childWorktree%(%w+%)"),
            "the listed row must project its worktree through childWorktree(entry)"
        )
        local helper = assert(content:match("function childWorktree%(.-\n}"), "childWorktree not found")
        contains_all(
            helper,
            { "entry?.assigned_worktree", "entry?.worktree", "source.owned", "source.reused" },
            "childWorktree"
        )
    end)

    it("prefers the recorded session_file before the cwd scan in read_subagent", function()
        assert.is_truthy(
            content:match("recordedTranscriptPath%(params%.target, ctx%)%s*%?%?%s*findSessionFile%(params%.target%)"),
            "read_subagent must try the recorded path first, then fall back to findSessionFile"
        )
        local helper =
            assert(content:match("function recordedTranscriptPath(.-)\n}"), "recordedTranscriptPath not found")
        contains_all(helper, {
            "isChildEntry(id)",
            "entry.parent_id !== resolveLineage(parent, manifest)",
            "entry.session_file",
            "isReadableFile(file)",
        }, "recordedTranscriptPath")
        assert.is_truthy(
            content:match('if %(!path%) return toolResult%({ error: "session file not found" }%)'),
            "an unresolvable transcript must keep returning the documented error"
        )
    end)
end)

-- ---------------------------------------------------------------------------
-- Behaviour test: run the real extension code under node.
-- ---------------------------------------------------------------------------

--- Major version of the local node, or nil when node is missing/unusable.
---@return integer?
local function node_major()
    if vim.fn.executable("node") ~= 1 then
        return nil
    end
    local out = vim.fn.system({ "node", "-e", "process.stdout.write(process.versions.node)" })
    if vim.v.shell_error ~= 0 then
        return nil
    end
    return tonumber(vim.trim(out):match("^(%d+)"))
end

-- Node >= 23 strips TypeScript types without a flag, which is what lets this
-- spec import extensions/subagent.ts as-is.
local NODE_MAJOR = node_major()
local NEEDS_NODE = "node >= 23 (TypeScript type stripping) is required for this behaviour test"

---@param path string
---@param content string
local function write_file(path, content)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local file = assert(io.open(path, "w"), "could not write " .. path)
    file:write(content)
    file:close()
end

---@param table_value table
---@param key string
---@return boolean
local function has_key(table_value, key)
    return vim.tbl_contains(vim.tbl_keys(table_value), key)
end

local TYPEBOX_STUB = [==[
export const Type = {
  Object: (properties, opts) => ({ type: "object", properties, ...(opts || {}) }),
  String: (opts) => ({ type: "string", ...(opts || {}) }),
  Number: (opts) => ({ type: "number", ...(opts || {}) }),
  Boolean: (opts) => ({ type: "boolean", ...(opts || {}) }),
  Array: (items, opts) => ({ type: "array", items, ...(opts || {}) }),
  Union: (anyOf, opts) => ({ anyOf, ...(opts || {}) }),
  Optional: (inner) => ({ ...inner, optional: true }),
};
]==]

-- Imports the extension unmodified with a stub `typebox` + fake ExtensionAPI,
-- writes the manifest where the extension will look for it (PI_CODING_AGENT_DIR
-- plus the workspace cwd), then executes the two observation tools.
local DRIVER = [==[
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const config = JSON.parse(readFileSync(process.argv[2], "utf8"));

const tools = new Map();
const api = {
  on() {},
  registerTool(def) {
    tools.set(def.name, def);
  },
};
const extension = await import(pathToFileURL(config.extensionUrl).href);
extension.default(api);

process.env.PI_CODING_AGENT_DIR = config.agentDir;
process.chdir(config.workspace);

const encodeCwd = (cwd) => `--${cwd.replace(/^[\\/]+/, "").replace(/[\\/:]/g, "-")}--`;
const sessionsDir = join(config.agentDir, "sessions", encodeCwd(config.workspace));
mkdirSync(sessionsDir, { recursive: true });
for (const [name, content] of Object.entries(config.sessionsFiles)) {
  writeFileSync(join(sessionsDir, name), content);
}
writeFileSync(join(sessionsDir, ".pi2-subsessions.json"), JSON.stringify(config.manifest));

const ctx = { hasUI: false, sessionManager: { getSessionId: () => config.parentId } };
const call = async (name, params) => {
  const res = await tools.get(name).execute("call-1", params, undefined, undefined, ctx);
  return JSON.parse(res.content[0].text);
};

const reads = {};
for (const [key, target] of Object.entries(config.reads)) {
  reads[key] = await call("read_subagent", { target });
}

const dispatch = tools.get("dispatch_subagents").parameters;
const spawn = dispatch.properties.items.items.anyOf[0];
const reuse = dispatch.properties.items.items.anyOf[1];
const worktree = spawn.properties.worktree || null;
const variants = (worktree && worktree.anyOf) || [];
const borrow = variants[0] || {};
const create = variants[1] || {};
const createValue = (create.properties && create.properties.create) || {};
const createUnion = createValue.anyOf || [];

const report = {
  sessionsDir,
  subagents: await call("list_subagents", {}),
  reads,
  schema: {
    spawnHasWorktree: worktree !== null,
    worktreeOptional: !!(worktree && worktree.optional),
    worktreeDescription: worktree && worktree.description,
    worktreeVariants: variants.length,
    borrowType: borrow.type,
    pathType: borrow.properties && borrow.properties.path.type,
    pathDescription: borrow.properties && borrow.properties.path.description,
    createVariantType: create.type,
    createAllowsBoolean: createUnion.some((entry) => entry.type === "boolean"),
    createAllowsObject: createUnion.some((entry) => entry.type === "object"),
    createObjectKeys: (createUnion.find((entry) => entry.type === "object") || {}).properties
      ? Object.keys((createUnion.find((entry) => entry.type === "object") || {}).properties)
      : [],
    reuseHasWorktree: Object.prototype.hasOwnProperty.call(reuse.properties, "worktree"),
  },
  descriptions: {
    dispatch: tools.get("dispatch_subagents").description,
    list: tools.get("list_subagents").description,
    read: tools.get("read_subagent").description,
    reuseMessage: reuse.properties.message.description,
  },
};

writeFileSync(config.report, JSON.stringify(report, null, 2));
]==]

describe("extensions/subagent.ts worktree protocol (behaviour)", function()
    local tmp, report

    ---@param role string
    ---@param text string
    ---@return string
    local function message(role, text)
        return vim.json.encode({ type = "message", message = { role = role, content = text } }) .. "\n"
    end

    before_each(function()
        report = nil
        if not NODE_MAJOR or NODE_MAJOR < 23 then
            return
        end

        tmp = vim.fn.tempname()
        vim.fn.mkdir(tmp, "p")

        local parent_id = "11111111-1111-4111-8111-111111111111"
        local workspace = tmp .. "/ws"
        vim.fn.mkdir(workspace, "p")

        -- The assigned child's JSONL lives *outside* the parent's session
        -- directory (that is what an assigned worktree means); the file dropped
        -- into the session directory for the same id is a decoy.
        local assigned_transcript = tmp .. "/repo/.worktrees/auth/sessions/1700000000000_child-assigned.jsonl"
        local foreign_transcript = tmp .. "/repo/.worktrees/theirs/sessions/1700000000000_foreign.jsonl"
        write_file(
            assigned_transcript,
            message("user", "assigned-child brief") .. message("assistant", "assigned-child done")
        )
        write_file(foreign_transcript, message("user", "foreign-secret"))

        local config = {
            extensionUrl = tmp .. "/ext/subagent.ts",
            workspace = workspace,
            agentDir = tmp .. "/agent",
            parentId = parent_id,
            report = tmp .. "/report.json",
            reads = {
                assigned = "child-assigned",
                fallback = "child-fallback",
                stale = "child-stale",
                foreign = "foreign",
                unknown = "nobody",
                empty_file = "child-empty-file",
            },
            sessionsFiles = {
                ["1700000000001_child-assigned.jsonl"] = message("user", "decoy-from-cwd-scan"),
                ["1700000000002_child-fallback.jsonl"] = message("user", "fallback-child"),
            },
            manifest = {
                __lineage__ = { [parent_id] = parent_id },
                ["child-assigned"] = {
                    parent_id = parent_id,
                    name = "auth",
                    status = "active",
                    assigned_worktree = { kind = "linked", path = "/repo/.worktrees/auth", name = "auth" },
                    session_file = assigned_transcript,
                },
                ["child-assigned-noname"] = {
                    parent_id = parent_id,
                    name = "no-name",
                    status = "completed",
                    assigned_worktree = { kind = "linked", path = "/repo/.worktrees/b" },
                },
                ["child-owned"] = {
                    parent_id = parent_id,
                    name = "own-checkout",
                    status = "active",
                    worktree = { path = "/repo/.worktrees/owned", name = "owned", owned = true, base_sha = "abc" },
                },
                ["child-adopted"] = {
                    parent_id = parent_id,
                    name = "adopted",
                    status = "completed",
                    assigned_worktree = { kind = "linked", path = "/repo/.worktrees/kept", reused = true },
                },
                ["child-plain"] = { parent_id = parent_id, name = "plain", status = "dormant" },
                ["child-fallback"] = { parent_id = parent_id, name = "fallback", session_file = tmp .. "/gone.jsonl" },
                ["child-stale"] = { parent_id = parent_id, name = "stale", session_file = tmp .. "/missing.jsonl" },
                ["child-empty-file"] = { parent_id = parent_id, name = "empty", session_file = "" },
                foreign = { parent_id = "another-parent", name = "theirs", session_file = foreign_transcript },
            },
        }

        local config_path = tmp .. "/config.json"
        write_file(config_path, vim.json.encode(config))
        write_file(tmp .. "/ext/node_modules/typebox/package.json", [[{"type": "module", "main": "index.mjs"}]])
        write_file(tmp .. "/ext/node_modules/typebox/index.mjs", TYPEBOX_STUB)
        -- Byte copy, so the stub `typebox` resolves next to the imported module
        -- without adding anything (or a node_modules) to the repository.
        write_file(tmp .. "/ext/subagent.ts", source())
        write_file(tmp .. "/driver.mjs", DRIVER)

        local out = vim.fn.system({ vim.fn.exepath("node"), tmp .. "/driver.mjs", config_path })
        assert.are.equal(0, vim.v.shell_error, "driver failed:\n" .. out)
        local report_file = assert(io.open(tmp .. "/report.json", "r"), "driver wrote no report:\n" .. out)
        report = vim.json.decode(report_file:read("*a"))
        report_file:close()
    end)

    after_each(function()
        if tmp and vim.fn.isdirectory(tmp) == 1 then
            vim.fn.delete(tmp, "rf")
        end
    end)

    ---@return boolean
    local function ready()
        if not report then
            pending(NEEDS_NODE)
            return false
        end
        return true
    end

    it("registers worktree as an optional borrow-or-create union on the spawn variant only", function()
        if not ready() then
            return
        end
        assert.is_true(report.schema.spawnHasWorktree, "spawn items must expose worktree")
        assert.is_true(report.schema.worktreeOptional, "an omitted worktree must mean 'inherit the parent cwd'")
        assert.are.equal(2, report.schema.worktreeVariants, "the union must carry the borrow and create variants")
        assert.are.equal("object", report.schema.borrowType)
        assert.are.equal("string", report.schema.pathType)
        assert.are.equal("object", report.schema.createVariantType)
        assert.is_true(report.schema.createAllowsBoolean, "create: true must be accepted")
        assert.is_true(report.schema.createAllowsObject, "create: { ... } must be accepted")
        for _, key in ipairs({ "base", "name", "setup" }) do
            assert.is_true(
                vim.tbl_contains(report.schema.createObjectKeys, key),
                "create must expose `" .. key .. "`; got: " .. vim.inspect(report.schema.createObjectKeys)
            )
        end
        assert.is_false(report.schema.reuseHasWorktree, "reuse items must not accept worktree")
        contains_all(report.schema.worktreeDescription, {
            "borrow an existing linked worktree",
            "parent's repository",
            "not both",
            "adopt",
            "inherits the parent's cwd",
            "shares that checkout",
            "no isolation between those children",
            "file-level isolation",
        }, "the worktree schema description")
        contains_all(report.descriptions.reuseMessage, { "`worktree`", "rejected" }, "the reuse message description")
        contains_all(report.descriptions.dispatch, { "`worktree`", "five spawn-only fields" }, "dispatch description")
        contains_all(
            report.descriptions.list,
            { "owned", "reused", "{ path, name?, owned?, reused? }" },
            "list_subagents description"
        )
        contains_all(
            report.descriptions.read,
            { "session_file", "session file not found" },
            "read_subagent description"
        )
    end)

    it("reports the checkout a child runs in: assigned first, owned with its flag", function()
        if not ready() then
            return
        end
        local by_id = {}
        for _, row in ipairs(report.subagents.subagents) do
            by_id[row.id] = row
        end

        assert.are.same({ path = "/repo/.worktrees/auth", name = "auth" }, by_id["child-assigned"].worktree)
        assert.are.same({ path = "/repo/.worktrees/b" }, by_id["child-assigned-noname"].worktree)
        assert.are.same(
            { path = "/repo/.worktrees/owned", name = "owned", owned = true },
            by_id["child-owned"].worktree
        )
        assert.are.same({ path = "/repo/.worktrees/kept", reused = true }, by_id["child-adopted"].worktree)
        assert.is_false(
            has_key(by_id["child-assigned-noname"].worktree, "name"),
            "an unnamed assignment must not fabricate a name key"
        )
        assert.is_false(
            has_key(by_id["child-assigned"].worktree, "owned"),
            "a borrowed or adopted checkout must not claim ownership"
        )
        assert.is_false(has_key(by_id["child-plain"], "worktree"), "child-plain must not report a worktree")
        assert.is_nil(by_id.foreign, "another parent's child must not be listed")
    end)

    it("reads the manifest session_file before the cwd scan", function()
        if not ready() then
            return
        end
        local lines = table.concat(report.reads.assigned.lines, "\n")
        contains_all(lines, { "assigned-child brief", "assigned-child done" }, "the assigned child's transcript")
        contains_none(lines, { "decoy-from-cwd-scan" }, "a recorded session_file must win over the cwd scan")
    end)

    it("falls back to the cwd scan when the recorded path is unusable", function()
        if not ready() then
            return
        end
        assert.are.same({ "[1] user: fallback-child" }, report.reads.fallback.lines)
    end)

    it("returns the documented error for stale, foreign and unknown ids", function()
        if not ready() then
            return
        end
        for _, key in ipairs({ "stale", "foreign", "unknown", "empty_file" }) do
            assert.is_nil(report.reads[key].lines, key .. " must not project any lines")
            assert.are.equal(
                "session file not found",
                report.reads[key].error,
                key .. " must report the documented error"
            )
        end
        assert.is_truthy(report.reads.foreign.lines == nil, "a foreign row's transcript must never be read")
    end)
end)
