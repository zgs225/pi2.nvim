-- Headless e2e: the bundled compaction cleaner (`extensions/compaction.ts`, L1).
--
-- This is the EXPERIMENT for the whole compaction feature, not just a smoke
-- test: it proves that mutating `event.preparation.fileOps` in place inside
-- `session_before_compact` really changes the summary pi writes. pi's
-- `compact()` destructures `fileOps` at call time and calls `computeFileLists`
-- AFTER the hook (and after the LLM call), so a hook that cleans the Sets in
-- place is enough — every native behaviour (native `details`, `fromHook: false`,
-- the summarisation prompt) must stay untouched. If the assertions below fail,
-- the mechanism is gone and the design has to change; the test is not the bug.
--
-- Drives the REAL stack: a `pi --mode rpc` child with the bundled extension, a
-- scripted fake OpenAI-compatible provider on 127.0.0.1 (no account, no
-- network, no real model), an isolated `PI_CODING_AGENT_DIR`, and the session
-- JSONL as ground truth.
--
-- Layout matters, and the layout is what makes the assertions mean something:
--
--   * 60 files live under `os.tmpdir()` (scratch paths the cleaner must drop),
--     60 files live in a normal project directory (paths that must survive).
--     The project tree cannot live under tmpdir() — everything there is
--     filtered by design.
--   * `keepRecentTokens` is 2000, so a manual `compact` keeps only the tail of
--     the session. The project tree lives in `~/.local/state`, NOT in the repo.
--
-- Scripted turns (one provider request per conversation turn):
--   T1  120 `read` tool calls in one assistant message (60 temp + 60 project)
--   T2  text
--   -> RPC `compact` #1: 120 read ops in, 60 dropped as scratch, capped to 50
--   T3  text  -- a user-message span the SECOND compaction can summarize
--   T4  read(<big project file>)  -- pushes the phase-2 turn past 2000 tokens
--   T5  text
--   -> runtime config rewritten to {"cleaner":{"max_read":5}}, `compact` #2
--
-- Phase 2 needs that shape on purpose: the second compaction must have a
-- non-empty `messagesToSummarize`, because only then does pi send the UPDATE
-- prompt, which is the one request that embeds `<previous-summary>` — the only
-- place the strip of the previous file lists is observable.
--
-- Assertions, all behavioural and read out of the session JSONL:
--   A1  the first summary's `<read-files>` carries ONLY project paths, at most
--       `max_read` (50) of them, and no temp path survives anywhere in it
--   A2  the native `details.readFiles` / `details.modifiedFiles` are still there
--       and `fromHook` is falsy — pi wrote its own entry, the extension only
--       changed the lists
--   A3  the cleaner's custom entry reports the counts (`readOmitted >= 60`) and
--       `strippedPrevious == false` for the first compaction
--   A4  NO summarisation request ever carries `<read-files>`: the previous
--       summary's lists are stripped before they are re-sent inside
--       `<previous-summary>` (the second phase actually takes the update-prompt
--       path, which is asserted, so A4 has teeth)
--   A5  the second compaction's `<read-files>` holds at most 5 entries, the
--       freshly read big project file is among them (recent entries are kept),
--       and the custom entry reports `strippedPrevious == true`
--   A6  no `extension_error` event, both `compact` responses are `success:true`
--
-- Phase 3 (L2, opt-in checkpoint) flips `checkpoint.enabled` on in the runtime
-- file and prompts with two backticked literals:
--   A7  the summarisation request is OURS: it carries the structured prompt
--       (every heading, the `pi2-compaction` marker, the sentinel literal) and
--       the previous summary inside `<previous-summary>` WITHOUT a file list
--   A8  the stored compaction is the extension's (`fromHook == true`), its
--       `details.engine == "pi2"`, `details.model` is the pinned model and the
--       summary has all nine headings + the sentinel + a `<read-files>` block
--   A9  a literal the model dropped comes back under `## Retained Identifiers`
--   A10 the summary is within the 2x`max_words` hard stop and the custom entry
--       reports `engine == "checkpoint"`, `checkpoint == true`, the model
--
-- Phase 4 (fail open) is a fresh session where the fake provider answers the
-- checkpoint request with an EMPTY completion:
--   A11 pi's native compaction is stored (`fromHook` falsy, no `details.engine`),
--       the custom entry reports `checkpoint == false`, and pi exits cleanly
--
-- Phase 5 (L3 state snapshot) runs a fresh session with `extensions/todo.ts`
-- loaded, `state.enabled` on and checkpoint off, in a real (tiny) git repo:
--   A12 a `pi2-compaction-state` custom entry exists whose `text` starts with
--       the `[pi2 state]` header and folds the unfinished todo, the compaction
--       facts and the git status; nothing is injected BEFORE the compaction
--   A13 the FIRST request after the compaction carries the snapshot exactly
--       once and the next prompt carries it zero times (never per turn)
--   A14 a second compaction with an unchanged state renders byte-identically,
--       the same hash, and injects nothing (stable, no second copy)
--   A15 a changed todo list changes the hash, drops the completed item from the
--       snapshot and is injected exactly once into the next request
--
-- Phase 6 (owner conflict) loads a competing extension AFTER ours, which wins
-- the `session_before_compact` chain (last handler wins):
--   A16 the stored compaction is the competitor's (`details.engine` is not
--       `pi2`), ours emitted ONE conflict notice and no more after a second
--       contested compaction (per-session rate limit)
--   A17 L2 stands down for the rest of the session (no second checkpoint
--       request), while L1 and the L3 snapshot keep working
--
-- Phase 7 (L4 prune) is a fresh session on a 12000-token model window with
-- `prune.enabled = true`, `high_water = 0.2`, `min_turns = 1`: four turns each
-- read a 4000-char file carrying its own `PRUNE-SENTINEL-<n>`:
--   A18 once the context crosses the high water mark, the OLDEST tool result is
--       a pointer line in the request body and its sentinel body is GONE, while
--       the most recent turn's tool result is still delivered in full (the last
--       turn is never pruned)
--   A19 the same pointer text is byte-identical on every following request and
--       no request ever un-prunes (the prefix does not churn)
--   A20 a `pi2-compaction-prune` custom entry exists (ids, savedChars,
--       atFraction; an identical decision is recorded once), the session JSONL
--       still holds the original sentinel, and the pointer is NEVER persisted
--   A22 a FRESH process that opens the same session file (extension instance
--       rebuilt, in-memory set empty) re-seeds the decision from that entry and
--       serves the byte-identical pointer instead of the pruned body
--   A21 the negative control: the same conversation with `prune.enabled =
--       false` delivers every full body, writes no pointer and no prune entry
--
-- Needs the pi binary, nothing else (the provider is fake), so it can run in CI:
--
--   make e2e-compaction
--   (nvim --headless -u tests/minimal_init.lua -l scripts/e2e/compaction.lua)

local uv = vim.uv

local PLUGIN_ROOT = vim.fn.fnamemodify(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h:h")
local EXTENSION = PLUGIN_ROOT .. "/extensions/compaction.ts"
-- The L3 phase folds a REAL `todo_write` result, so the bundled todo extension
-- is loaded next to ours (the snapshot never invents state).
local TODO_EXTENSION = PLUGIN_ROOT .. "/extensions/todo.ts"
local TAG = ("%d-%d"):format(uv.os_getpid(), os.time())
local RUN_ROOT = vim.fn.tempname() .. "-compaction"
-- The project tree lives OUTSIDE tmpdir(): the cleaner drops everything under
-- tmpdir() (that is the filter under test), so files that must SURVIVE it
-- cannot live there. `~/.local/state` is a normal, uninteresting path.
local PROJECT_ROOT = vim.fn.expand("~/.local/state/pi2nvim-e2e") .. "/compaction-" .. TAG

local PROVIDER = "e2ecomp"
local MODEL_ID = "e2e-model"

local N_TEMP = 60
local N_PROJECT = 60
local MAX_READ_DEFAULT = 50
local MAX_READ_PHASE2 = 5

-- Phase 3 (L2 checkpoint). The literals are backticked in the user prompt, so
-- they are extracted as protected literals; the fake summary keeps ONE of them
-- and drops the other, which is what exercises `## Retained Identifiers`.
local CHECKPOINT_MAX_WORDS = 300
local SENTINEL = "SENTINEL-LITERAL-42"
local DROPPED_LITERAL = "OTHER-LITERAL-7"

-- The nine H2 sections the checkpoint prompt asks for.
local CHECKPOINT_HEADINGS = {
    "## Goal",
    "## Constraints & Preferences",
    "## Progress",
    "## Key Decisions",
    "## Artifact Trail",
    "## Next Steps",
    "## Critical Context",
    "## Open Questions",
    "## Rejected Approaches",
}

-- The summary text the fake "model" returns; must not contain a file list.
local SUMMARY_TEXT = table.concat({
    "## Goal",
    "Finish the scripted e2e run.",
    "",
    "## Progress",
    "### Done",
    "- [x] read the files",
    "",
    "## Next Steps",
    "1. keep going",
}, "\n")

-- Phase 5 (L3). The marker is the snapshot's first token: it must appear exactly
-- once in the request a compaction is replayed into, and never again until the
-- folded state actually changes.
local STATE_MARKER = "[pi2 state]"
local STATE_TODO_ONE = "STATE-TODO-ONE write the snapshot"
local STATE_TODO_TWO = "STATE-TODO-TWO run the gate"
local STATE_TODO_THREE = "STATE-TODO-THREE report the sha"
local TODO_STATE_INITIAL = {
    { content = STATE_TODO_ONE, status = "in_progress", activeForm = "Writing the snapshot" },
    { content = STATE_TODO_TWO, status = "pending" },
}
local TODO_STATE_UPDATED = {
    { content = STATE_TODO_ONE, status = "completed" },
    { content = STATE_TODO_TWO, status = "in_progress", activeForm = "Running the gate" },
    { content = STATE_TODO_THREE, status = "pending" },
}

-- Phase 6 (owner conflict). `session_before_compact` handlers chain last-wins,
-- so a competing extension loaded AFTER ours supplies the summary and ours has
-- to notice that it lost (and stand its checkpoint layer down).
local COMPETITOR_MARKER = "COMPETITOR-SUMMARY-1"

-- Phase 7/8 (L4 prune). The same scripted conversation twice: once with
-- `prune.enabled = true` and once with it off (the negative control). The second
-- model has a SMALL window, so `high_water` is reachable after a couple of turns
-- without any real provider, while `reserveTokens` 0 keeps auto-compaction out
-- of the way (its threshold becomes the whole window, far above this run).
local PRUNE_MODEL_ID = "e2e-small"
-- 20000 tokens x 0.3 = 6000: the window FILLS after a couple of 8000-char read
-- results (the fake provider reports the real prompt size), while the whole
-- conversation plus the prompt stays well below the 20000 auto-compaction
-- threshold (reserveTokens 0), so the phase can never be turned into a
-- summarisation by accident.
--
-- `high_water` is 0.3, the contract's floor, not the issue's 0.2: pi.nvim clamps
-- the published value into 0.3..0.95, so a 0.2 would be normalised away before
-- the extension ever saw it (the extension's own clamp accepts 0.2, but a test
-- that relies on a value the publisher cannot produce would be asserting a
-- configuration that does not exist).
local PRUNE_CONTEXT_WINDOW = 20000
local PRUNE_HIGH_WATER = 0.3
local PRUNE_MIN_TURNS = 1
local PRUNE_FILES = 5
local PRUNE_CHARS = 8000
local PRUNE_SENTINEL_PREFIX = "PRUNE-SENTINEL-"
local PRUNE_POINTER_PREFIX = "[pruned tool result:"
local COMPETITOR_SOURCE = [=[
export default function competitor(pi: any) {
    pi.on("session_before_compact", async (event: any) => ({
        compaction: {
            summary: "## Competitor summary\nCOMPETITOR-SUMMARY-1",
            firstKeptEntryId: event.preparation.firstKeptEntryId,
            tokensBefore: event.preparation.tokensBefore,
            details: { engine: "competitor" },
        },
    }));
}
]=]
local OWNER_CONFLICT_NOTICE = "another compaction extension supplied this summary"

io.stdout:setvbuf("no")
local run_started = uv.hrtime()
local last_step = run_started

---@return number elapsed seconds since the previous step marker
local function step(name)
    local t = uv.hrtime()
    print(string.format("[step] %-56s +%6.2fs (total %7.2fs)", name, (t - last_step) / 1e9, (t - run_started) / 1e9))
    last_step = t
end

---@param cond boolean
---@param msg string
---@param ctx? table
local function check(cond, msg, ctx)
    if cond then
        return
    end
    local detail = ""
    if ctx ~= nil then
        detail = " | ctx=" .. vim.inspect(ctx, { newline = " ", indent = "" })
    end
    error(msg .. detail, 0)
end

---@param path string
---@return string?
local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

-- ---------------------------------------------------------------------------
-- HTTP helpers + the scripted provider (OpenAI chat-completions, streamed).
-- ---------------------------------------------------------------------------

---@return string
local function sse_headers()
    return table.concat({
        "HTTP/1.1 200 OK",
        "Content-Type: text/event-stream",
        "Cache-Control: no-cache",
        "Connection: close",
        "",
        "",
    }, "\r\n")
end

---@param delta_json string
---@param finish? string
---@return string
local function sse_chunk(delta_json, finish)
    local fr = finish and ('"' .. finish .. '"') or "null"
    return ('data: {"id":"chatcmpl-e2e","object":"chat.completion.chunk","created":0,"model":"%s","choices":[{"index":0,"delta":%s,"finish_reason":%s}]}\n\n'):format(
        MODEL_ID,
        delta_json,
        fr
    )
end

--- A final usage-only chunk, the shape `stream_options.include_usage` produces.
---
--- `prompt_tokens` is derived from the real request size (`chars/4`), because
--- `ctx.getContextUsage()` prefers the last assistant message's reported usage
--- over its own estimate: a constant here would make the L4 prune trigger see a
--- context that never grows.
---@param prompt_tokens integer
---@return string
local function sse_usage_chunk(prompt_tokens)
    local completion = 40
    return ('data: {"id":"chatcmpl-e2e","object":"chat.completion.chunk","created":0,"model":"%s","choices":[],"usage":{"prompt_tokens":%d,"completion_tokens":%d,"total_tokens":%d}}\n\n'):format(
        MODEL_ID,
        prompt_tokens,
        completion,
        prompt_tokens + completion
    )
end

---@param index integer
---@param name string
---@param args table
---@param tool_call_id? string explicit id, so a phase can name the result it prunes
---@return string
local function tool_call_chunk(index, name, args, tool_call_id)
    local arguments = vim.json.encode(vim.json.encode(args))
    return sse_chunk(
        ('{"tool_calls":[{"index":%d,"id":"%s","type":"function","function":{"name":"%s","arguments":%s}}]}'):format(
            index,
            tool_call_id or ("call_%d"):format(index),
            name,
            arguments
        )
    )
end

---@param text string
---@param prompt_tokens integer
---@return string
local function text_turn(text, prompt_tokens)
    return sse_headers()
        .. sse_chunk(('{"role":"assistant","content":%s}'):format(vim.json.encode(text)))
        .. sse_chunk("{}", "stop")
        .. sse_usage_chunk(prompt_tokens)
        .. "data: [DONE]\n\n"
end

---@param calls table[] list of { name, args, toolCallId? }
---@param prompt_tokens integer
---@return string
local function tool_turn(calls, prompt_tokens)
    local chunks = { sse_headers(), sse_chunk('{"role":"assistant","content":""}') }
    for index, call in ipairs(calls) do
        chunks[#chunks + 1] = tool_call_chunk(index - 1, call[1], call[2], call[3])
    end
    chunks[#chunks + 1] = sse_chunk("{}", "tool_calls")
    chunks[#chunks + 1] = sse_usage_chunk(prompt_tokens)
    chunks[#chunks + 1] = "data: [DONE]\n\n"
    return table.concat(chunks)
end

--- Flatten every string in a decoded JSON value: the ground truth for "what the
--- model was actually handed", independent of JSON escaping.
---@param value any
---@param parts string[]
local function flatten_strings(value, parts)
    if type(value) == "string" then
        parts[#parts + 1] = value
    elseif type(value) == "table" then
        for _, child in pairs(value) do
            flatten_strings(child, parts)
        end
    end
end

---@param body string
---@return string
local function body_text(body)
    local ok, decoded = pcall(vim.json.decode, body)
    if not ok or type(decoded) ~= "table" then
        return body
    end
    local parts = {}
    flatten_strings(decoded, parts)
    return table.concat(parts, "\n")
end

--- Is this request a summarisation call rather than a conversation turn? Both
--- the initial prompt and the update prompt wrap the conversation in
--- `<conversation>`; the split-turn prefix prompt uses `# Conversation`.
---@param text string
---@return boolean
local function is_summarization(text)
    return text:find("<conversation>", 1, true) ~= nil
        or text:find("# Conversation", 1, true) ~= nil
        or text:find("Create a structured context checkpoint summary", 1, true) ~= nil
        or text:find("NEW conversation messages to incorporate", 1, true) ~= nil
        or text:find("earlier context from an ongoing conversation", 1, true) ~= nil
end

---@class CompactionE2EProvider
---@field server? uv.uv_tcp_t
---@field mode "l1"|"checkpoint"|"fallback"|"state"|"prune" which scripted conversation is active
---@field turn integer conversation requests answered so far (per phase)
---@field summarizations string[] flattened text of every native summarisation request
---@field checkpoint_requests string[] flattened text of every L2 checkpoint request
---@field requests string[] flattened text of every CONVERSATION request (what the model was handed)
---@field temp_paths string[]
---@field project_paths string[]
---@field big_path string
---@field prune_paths string[] the L4 fixture files, one read per turn

--- The L2 checkpoint request carries a section only OUR prompt asks for.
---@param text string
---@return boolean
local function is_checkpoint_request(text)
    return text:find("## Artifact Trail", 1, true) ~= nil
end

--- The checkpoint summary the fake "model" returns. It echoes the sentinel it
--- found in the request (so a prompt that lost the conversation fails the
--- assertions) and deliberately omits `DROPPED_LITERAL`, which the extension
--- must restore under `## Retained Identifiers`.
---@param request_text string
---@return string
local function checkpoint_summary(request_text)
    local sentinel = request_text:match("`([%w]+%-LITERAL%-%d+)`") or SENTINEL
    return table.concat({
        "## Goal",
        ("Finish the checkpoint e2e run. Keep `%s` verbatim."):format(sentinel),
        "",
        "## Constraints & Preferences",
        "- [USER] never lose a literal",
        "",
        "## Progress",
        "### Done",
        "- [VERIFIED] read the large project file",
        "",
        "### In Progress",
        "- [VERIFIED] assert the stored checkpoint",
        "",
        "### Blocked",
        "- (none)",
        "",
        "## Key Decisions",
        "- **[Decision]**: [REPORTED] use the checkpoint engine",
        "",
        "## Artifact Trail",
        "- [VERIFIED] big-project-file.txt",
        "",
        "## Next Steps",
        "1. [VERIFIED] stop after the assertions",
        "",
        "## Critical Context",
        ("- [VERIFIED] sentinel %s"):format(sentinel),
        "",
        "## Open Questions",
        "- (none)",
        "",
        "## Rejected Approaches",
        "- [VERIFIED] pi's native summary format",
    }, "\n")
end

---@param text string
---@return integer
local function word_count(text)
    local count = 0
    for _ in text:gmatch("%S+") do
        count = count + 1
    end
    return count
end

---@param provider CompactionE2EProvider
---@param prompt_tokens integer the answering request's size, echoed in the usage chunk
---@return string
local function respond(provider, prompt_tokens)
    provider.turn = provider.turn + 1
    local turn = provider.turn
    ---@param text string
    ---@return string
    local function say(text)
        return text_turn(text, prompt_tokens)
    end
    ---@param calls table[] list of { name, args, toolCallId? }
    ---@return string
    local function tools(calls)
        return tool_turn(calls, prompt_tokens)
    end

    if provider.mode == "state" then
        if turn == 1 then
            return tools({
                { "todo_write", { todos = TODO_STATE_INITIAL } },
                { "read", { path = provider.big_path } },
            })
        end
        if turn == 5 then
            -- A manual `compact` needs fresh content past keepRecentTokens, so the
            -- turns before each later compaction read the big file again.
            return tools({ { "read", { path = provider.big_path } } })
        end
        if turn == 8 then
            -- The second todo_write replaces the whole list (full-replacement
            -- semantics): one item is completed, one is added.
            return tools({
                { "todo_write", { todos = TODO_STATE_UPDATED } },
                { "read", { path = provider.big_path } },
            })
        end
        return say(("State phase turn %d."):format(turn))
    end
    if provider.mode == "checkpoint" then
        if turn == 1 or turn == 3 then
            return tools({ { "read", { path = provider.big_path } } })
        end
        return say("Read the large project file again.")
    end
    if provider.mode == "fallback" then
        if turn == 1 then
            return tools({ { "read", { path = provider.big_path } } })
        end
        return say("Read the large project file.")
    end

    if provider.mode == "prune" then
        -- Odd turns read the next L4 fixture (a 4000-char result with its own
        -- sentinel), even turns answer with text. The explicit toolCallId is what
        -- the assertions name, so "which result was pruned" is unambiguous.
        local index = math.floor((turn + 1) / 2)
        if turn % 2 == 1 and provider.prune_paths[index] then
            return tools({
                { "read", { path = provider.prune_paths[index] }, ("call_prune_%d"):format(index) },
            })
        end
        return say(("Prune phase turn %d."):format(turn))
    end

    if turn == 1 then
        -- One assistant message with 120 read calls: 60 scratch paths and 60
        -- project paths. Every call is a real file so pi's read tool succeeds.
        local calls = {}
        for _, path in ipairs(provider.temp_paths) do
            calls[#calls + 1] = { "read", { path = path } }
        end
        for _, path in ipairs(provider.project_paths) do
            calls[#calls + 1] = { "read", { path = path } }
        end
        return tools(calls)
    end
    if turn == 2 then
        return say("Read all 120 files.")
    end
    if turn == 3 then
        -- Phase 2, first prompt: a text-only turn. It must come BEFORE the big
        -- read, because the second compaction has to have a user-message span to
        -- summarize -- only then does pi call the update prompt with
        -- `<previous-summary>`, which is where A4 can observe the strip.
        return say("Acknowledged. Reading the large file next.")
    end
    if turn == 4 then
        return tools({ { "read", { path = provider.big_path } } })
    end
    return say("Read the large file.")
end

---@param provider CompactionE2EProvider
---@param body string
---@return string
local function handle_request(provider, body)
    local text = body_text(body)
    -- The whole request, in the unit pi's estimate uses: a real provider reports
    -- the prompt size it was billed for, and `ctx.getContextUsage()` prefers it.
    local prompt_tokens = math.max(1, math.floor(#body / 4))
    if is_checkpoint_request(text) then
        provider.checkpoint_requests[#provider.checkpoint_requests + 1] = text
        if provider.mode == "fallback" then
            -- An EMPTY completion: the extension must fail open and let pi's
            -- native summariser run.
            return text_turn("", prompt_tokens)
        end
        return text_turn(checkpoint_summary(text), prompt_tokens)
    end
    if is_summarization(text) then
        provider.summarizations[#provider.summarizations + 1] = text
        return text_turn(SUMMARY_TEXT, prompt_tokens)
    end
    -- A conversation request: this is what the model was actually handed, so it
    -- is the ground truth for "the snapshot rode exactly one request".
    provider.requests[#provider.requests + 1] = text
    return respond(provider, prompt_tokens)
end

---@param provider CompactionE2EProvider
---@return CompactionE2EProvider
local function start_fake_provider(provider)
    local server = assert(uv.new_tcp())
    assert(server:bind("127.0.0.1", 0))
    provider.server = server
    assert(server:listen(16, function(err)
        if err then
            print("[provider] listen error: " .. tostring(err))
            return
        end
        local client = assert(uv.new_tcp())
        server:accept(client)
        local buffer = ""
        local answered = false
        client:read_start(function(read_err, chunk)
            if read_err or not chunk then
                pcall(client.close, client)
                return
            end
            buffer = buffer .. chunk
            local head_end = buffer:find("\r\n\r\n", 1, true)
            if not head_end then
                return
            end
            local head = buffer:sub(1, head_end - 1)
            local length = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
            local body = buffer:sub(head_end + 4)
            if #body < length or answered then
                return
            end
            answered = true
            -- Scheduled out of the libuv fast context, so the response pipeline
            -- may use `vim.*` helpers freely (same shape as the other e2e scripts).
            vim.schedule(function()
                local response = handle_request(provider, body)
                pcall(client.write, client, response, function()
                    pcall(client.close, client)
                end)
            end)
        end)
    end))
    return provider
end

-- ---------------------------------------------------------------------------
-- Fixtures: agent dir, settings, the temp tree and the project tree.
-- ---------------------------------------------------------------------------

---@param dir string
---@param port integer
local function write_agent_dir(dir, port)
    vim.fn.mkdir(dir, "p")
    local models = {
        providers = {
            [PROVIDER] = {
                name = "E2EComp",
                baseUrl = ("http://127.0.0.1:%d/v1"):format(port),
                apiKey = "sk-e2e-test",
                api = "openai-completions",
                models = {
                    {
                        id = MODEL_ID,
                        name = "E2E Model",
                        contextWindow = 200000,
                        maxTokens = 4096,
                        cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 },
                    },
                    {
                        -- The L4 prune phase needs a window small enough for
                        -- `high_water` to be reachable within a few turns.
                        id = PRUNE_MODEL_ID,
                        name = "E2E Small Window",
                        contextWindow = PRUNE_CONTEXT_WINDOW,
                        maxTokens = 2048,
                        cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 },
                    },
                },
            },
        },
    }
    local f = assert(io.open(dir .. "/models.json", "w"))
    f:write(vim.json.encode(models))
    f:close()
    -- keepRecentTokens small enough that a manual `compact` summarizes the
    -- whole first span and keeps only the tail; a big window so auto-compaction
    -- never fires during the run. The small model reserves NOTHING, so its
    -- auto-compaction threshold is the whole window: the prune phase must never
    -- be turned into a summarisation by accident.
    local s = assert(io.open(dir .. "/settings.json", "w"))
    s:write(vim.json.encode({
        compaction = {
            reserveTokens = 16384,
            keepRecentTokens = 2000,
            modelOverrides = {
                [PROVIDER .. "/" .. PRUNE_MODEL_ID] = { reserveTokens = 0, keepRecentTokens = 2000 },
            },
        },
    }))
    s:close()
end

--- Write the runtime config file the extension re-reads on every compaction.
---@param path string
---@param cfg table
local function write_runtime_config(path, cfg)
    local f = assert(io.open(path, "w"))
    f:write(vim.json.encode(cfg))
    f:close()
end

---@param path string
---@param lines string[]
local function write_lines(path, lines)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    assert(vim.fn.writefile(lines, path) == 0, "write " .. path)
end

---@return string[] temp_paths
---@return string[] project_paths
---@return string big_path
local function create_fixture_files()
    local temp_dir = RUN_ROOT .. "/tmp-scratch"
    local project_dir = PROJECT_ROOT .. "/project"
    local temp_paths = {}
    local project_paths = {}
    -- Each file is deliberately NOT tiny (~200 chars -> a ~50 token tool
    -- result). The 120 tool results are what the cut point walks past: they must
    -- together exceed `keepRecentTokens` (2000) so the cut lands AFTER the
    -- assistant message that holds the read calls. A tiny result set makes pi
    -- cut AT that assistant message, the calls stay in the kept tail, and no
    -- file op is ever extracted -- the whole experiment then proves nothing.
    for index = 1, N_TEMP do
        local path = ("%s/tmpread-%03d.txt"):format(temp_dir, index)
        write_lines(path, {
            ("scratch content file %03d line one"):format(index),
            "scratch filler line padding padding pad",
            "scratch filler line padding padding pad",
            "scratch filler line padding padding pad",
        })
        temp_paths[#temp_paths + 1] = path
    end
    for index = 1, N_PROJECT do
        local path = ("%s/projread-%03d.txt"):format(project_dir, index)
        write_lines(path, {
            ("project content file %03d line one"):format(index),
            "project filler line padding padding pad",
            "project filler line padding padding pad",
            "project filler line padding padding pad",
        })
        project_paths[#project_paths + 1] = path
    end
    -- 1500 lines x ~40 chars: the read tool returns it (truncated to 2000 lines /
    -- 50KB, so effectively the whole file), which is ~15k tokens — well past
    -- keepRecentTokens, which is what makes phase 2 compact anything at all.
    local big_lines = {}
    for index = 1, 1500 do
        big_lines[index] = ("large file filler line %04d abcdefghij"):format(index)
    end
    local big_path = project_dir .. "/big-project-file.txt"
    write_lines(big_path, big_lines)
    return temp_paths, project_paths, big_path
end

--- The L4 fixtures: `PRUNE_FILES` files of ~`PRUNE_CHARS` chars, each carrying
--- its own `PRUNE-SENTINEL-<n>` marker. A read of one is a big tool result
--- (~1000 tokens), which is what makes the high water mark reachable and what a
--- pruned pointer must replace.
---@return string[] paths
local function create_prune_files()
    local dir = PROJECT_ROOT .. "/prune"
    local paths = {}
    local line_count = math.floor(PRUNE_CHARS / 40)
    for file_index = 1, PRUNE_FILES do
        local sentinel = ("%s%d"):format(PRUNE_SENTINEL_PREFIX, file_index)
        local lines = { sentinel .. " starts the file" }
        for line = 1, line_count do
            lines[#lines + 1] = ("prune filler line %03d for file %d abcd"):format(line, file_index)
        end
        local path = ("%s/prune-%d.txt"):format(dir, file_index)
        write_lines(path, lines)
        paths[#paths + 1] = path
    end
    return paths
end

--- Run a command, returning its exit code and stdout.
---@param argv string[]
---@param cwd string
---@return integer code
---@return string out
local function sh(argv, cwd)
    local result = vim.system(argv, { text = true, cwd = cwd }):wait()
    return result.code or -1, result.stdout or ""
end

--- A real (tiny) git repo for the snapshot's `## Git` section: one committed
--- file that is later modified, plus one untracked file. The L3 snapshot runs
--- `git status --short` in the session cwd, so this fixture is that cwd.
---@return string cwd
local function create_git_fixture()
    check(vim.fn.executable("git") == 1, "git is required for the L3 snapshot fixture")
    local cwd = PROJECT_ROOT .. "/state-project"
    write_lines(cwd .. "/committed.txt", { "committed line" })
    ---@param args string[]
    ---@return string
    local function git(args)
        local full = { "git", "-C", cwd }
        vim.list_extend(full, args)
        local code, out = sh(full, cwd)
        check(code == 0, "git " .. table.concat(args, " ") .. " failed", { out = out })
        return out
    end
    git({ "init", "-q" })
    git({ "add", "committed.txt" })
    git({ "-c", "user.name=pi2 e2e", "-c", "user.email=e2e@pi2.invalid", "commit", "-q", "-m", "fixture" })
    -- Modified after the commit (" M committed.txt") and never added ("?? untracked.txt").
    write_lines(cwd .. "/committed.txt", { "committed line", "modified line" })
    write_lines(cwd .. "/untracked.txt", { "untracked line" })
    return cwd
end

-- ---------------------------------------------------------------------------
-- RPC backend
-- ---------------------------------------------------------------------------

---@class CompactionE2EBackend
---@field job integer
---@field session_dir string
---@field events table[]
---@field stderr string

---@param session_dir string
---@param cwd string
---@param extra_extensions? string[] further `-e` paths, loaded AFTER the bundled one
---@return CompactionE2EBackend
local function start_backend(session_dir, cwd, extra_extensions)
    vim.fn.mkdir(session_dir, "p")
    vim.fn.mkdir(cwd, "p")
    ---@type CompactionE2EBackend
    local backend = { job = 0, session_dir = session_dir, events = {}, stderr = "" }
    local partial = { out = "" }
    -- Extension load order is argv order, and `session_before_compact` handlers
    -- chain last-wins: a competitor passed in `extra_extensions` therefore
    -- replaces our summary (that is what the owner-conflict phase relies on).
    local argv = { "pi", "--mode", "rpc", "--no-extensions", "-e", EXTENSION }
    for _, path in ipairs(extra_extensions or {}) do
        argv[#argv + 1] = "-e"
        argv[#argv + 1] = path
    end
    vim.list_extend(argv, {
        "--no-mcp",
        "--no-skills",
        "--no-prompt-templates",
        "--no-context-files",
        "--session-dir",
        session_dir,
    })
    backend.job = vim.fn.jobstart(argv, {
        cwd = cwd,
        on_stdout = function(_, data)
            if not data then
                return
            end
            data[1] = partial.out .. (data[1] or "")
            partial.out = data[#data] or ""
            for index = 1, #data - 1 do
                local line = (data[index] or ""):gsub("\r$", "")
                if line ~= "" then
                    local ok, decoded = pcall(vim.json.decode, line)
                    if ok and type(decoded) == "table" then
                        decoded._n = #backend.events + 1
                        backend.events[#backend.events + 1] = decoded
                    end
                end
            end
        end,
        on_stderr = function(_, data)
            if not data then
                return
            end
            backend.stderr = backend.stderr .. table.concat(data, "")
        end,
        stdout_buffered = false,
        stderr_buffered = false,
    })
    check(backend.job > 0, "backend process started")
    return backend
end

---@param backend CompactionE2EBackend
---@param message table
local function send(backend, message)
    check(vim.fn.chansend(backend.job, vim.json.encode(message) .. "\n") > 0, "send " .. tostring(message.type))
end

---@param backend CompactionE2EBackend
---@param predicate fun(ev: table): boolean
---@param timeout_ms integer
---@param what string
---@return table?
local function wait_event(backend, predicate, timeout_ms, what)
    local found = nil
    local settled = vim.wait(timeout_ms, function()
        for _, ev in ipairs(backend.events) do
            if predicate(ev) then
                found = ev
                return true
            end
        end
        return false
    end, 50)
    if settled and found then
        return found
    end
    local seen = {}
    for _, ev in ipairs(backend.events) do
        seen[#seen + 1] = string.format("%d:%s", ev._n, tostring(ev.type))
    end
    print(("[debug] %s timed out; events=%s; stderr=%s"):format(what, table.concat(seen, ","), backend.stderr))
    return nil
end

---@param backend CompactionE2EBackend
local function stop_backend(backend)
    pcall(vim.fn.chanclose, backend.job, "stdin")
    pcall(vim.fn.jobstop, backend.job)
    pcall(vim.fn.jobwait, { backend.job }, 5000)
end

---@param backend CompactionE2EBackend
---@param message string
---@param timeout_ms integer
local function run_turn(backend, message, timeout_ms)
    local since = #backend.events
    send(backend, { type = "prompt", message = message })
    local settled = wait_event(backend, function(ev)
        return ev.type == "agent_settled" and ev._n > since
    end, timeout_ms, "agent_settled")
    check(settled ~= nil, "the scripted run settles", { stderr = backend.stderr, message = message })
end

--- Send `compact` and return the response (or nil after printing the events).
---@param backend CompactionE2EBackend
---@param what string
---@return table?
local function run_compact(backend, what)
    local since = #backend.events
    send(backend, { type = "compact" })
    local response = wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "compact" and ev._n > since
    end, 180000, what)
    if response == nil then
        return nil
    end
    check(response.success == true, what .. ": compact response must be success:true", { response = response })
    return response
end

--- `get_session_stats` data: the L4 phase reports the context history it prunes on.
---@param backend CompactionE2EBackend
---@param what string
---@return table?
local function session_stats(backend, what)
    local since = #backend.events
    send(backend, { type = "get_session_stats" })
    local response = wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "get_session_stats" and ev._n > since
    end, 30000, what)
    if response == nil or response.success == false then
        return nil
    end
    return type(response.data) == "table" and response.data or nil
end

-- ---------------------------------------------------------------------------
-- Session JSONL (ground truth)
-- ---------------------------------------------------------------------------

---@param session_dir string
---@return table[]
local function session_entries(session_dir)
    local names = vim.fn.readdir(session_dir)
    table.sort(names)
    local entries = {}
    for _, name in ipairs(names) do
        if name:match("%.jsonl$") then
            local text = read_file(session_dir .. "/" .. name) or ""
            for line in text:gmatch("[^\n]+") do
                local ok, decoded = pcall(vim.json.decode, line)
                if ok and type(decoded) == "table" then
                    entries[#entries + 1] = decoded
                end
            end
        end
    end
    return entries
end

---@param entries table[]
---@param kind string
---@return table[]
local function by_type(entries, kind)
    local out = {}
    for _, entry in ipairs(entries) do
        if entry.type == kind then
            out[#out + 1] = entry
        end
    end
    return out
end

---@param entries table[]
---@param custom_type string
---@return table[]
local function custom_entries(entries, custom_type)
    local out = {}
    for _, entry in ipairs(entries) do
        if entry.type == "custom" and entry.customType == custom_type then
            out[#out + 1] = entry
        end
    end
    return out
end

--- Every `.jsonl` of a session dir, concatenated: the raw ground truth for
--- "the original is still in the transcript, byte for byte".
---@param session_dir string
---@return string
local function session_jsonl_text(session_dir)
    local names = vim.fn.readdir(session_dir)
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        if name:match("%.jsonl$") then
            parts[#parts + 1] = read_file(session_dir .. "/" .. name) or ""
        end
    end
    return table.concat(parts, "\n")
end

--- The pointer line the extension must produce for one tool call. Byte-for-byte
--- the same string `prunePointer()` builds, on purpose: a different wording in
--- the test would let a drifting pointer pass.
---@param tool_name string
---@param tool_call_id string
---@return string
local function prune_pointer(tool_name, tool_call_id)
    return ("[pruned tool result: %s %s; original retained in the session transcript]"):format(tool_name, tool_call_id)
end

--- Body of the `<read-files>` block a summary ends with.
---@param summary string
---@return string?
local function read_files_block(summary)
    return summary:match("<read%-files>\n(.-)\n</read%-files>")
end

---@param block string?
---@return string[]
local function block_paths(block)
    local paths = {}
    if not block then
        return paths
    end
    for line in block:gmatch("[^\n]+") do
        paths[#paths + 1] = line
    end
    return paths
end

---@param list string[]
---@param value string
---@return boolean
local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

--- How many times `needle` occurs in `text` (plain search, no patterns).
---@param text string
---@param needle string
---@return integer
local function count_occurrences(text, needle)
    local count = 0
    local start = 1
    while true do
        local index = text:find(needle, start, true)
        if index == nil then
            return count
        end
        count = count + 1
        start = index + #needle
    end
end

--- The sections of a snapshot WITHOUT the `## Compaction` facts block. The facts
--- carry this compaction's token counts, so they differ between two compactions
--- of an identical state; everything else must be byte-identical.
---@param text string
---@return string
local function state_sections(text)
    local kept = {}
    for _, block in ipairs(vim.split(text, "\n\n", { plain = true })) do
        if block:find("## Compaction", 1, true) ~= 1 then
            kept[#kept + 1] = block
        end
    end
    return table.concat(kept, "\n\n")
end

-- ---------------------------------------------------------------------------

local function cleanup()
    pcall(vim.fn.delete, RUN_ROOT, "rf")
    pcall(vim.fn.delete, PROJECT_ROOT, "rf")
end

local function main()
    check(vim.fn.executable("pi") == 1, "pi binary not found in PATH (required for this e2e)")
    vim.fn.mkdir(RUN_ROOT, "p")
    local agent_dir = RUN_ROOT .. "/agent"
    local config_path = RUN_ROOT .. "/compaction-config.json"

    vim.env.PI_CODING_AGENT_DIR = agent_dir
    vim.env.PI_OFFLINE = "1"
    -- Published by pi.nvim's config.setup() in the real plugin; the extension
    -- re-reads this file on every compaction event. Absent at first, so the
    -- built-in defaults apply to phase 1.
    vim.env.PI_NVIM_COMPACTION_FILE = config_path

    local temp_paths, project_paths, big_path = create_fixture_files()
    local prune_paths = create_prune_files()
    ---@type CompactionE2EProvider
    local provider = {
        mode = "l1",
        turn = 0,
        summarizations = {},
        checkpoint_requests = {},
        requests = {},
        temp_paths = temp_paths,
        project_paths = project_paths,
        big_path = big_path,
        prune_paths = prune_paths,
    }
    start_fake_provider(provider)
    local addr = provider.server:getsockname()
    local port = type(addr) == "table" and addr.port or nil
    check(type(port) == "number" and port > 0, "fake provider did not bind a port", { addr = addr })
    write_agent_dir(agent_dir, port)
    step(("fixtures ready: %d temp + %d project files, provider on 127.0.0.1:%d"):format(N_TEMP, N_PROJECT, port))

    local backend = start_backend(RUN_ROOT .. "/sessions", PROJECT_ROOT .. "/project")
    send(backend, { type = "set_model", provider = PROVIDER, modelId = MODEL_ID })
    local pinned = wait_event(backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, "set_model")
    check(pinned ~= nil and pinned.success ~= false, "fake model selected", { stderr = backend.stderr })
    step("model pinned to the fake provider")

    -- Phase 1: one assistant message with 120 read calls, then a text turn.
    run_turn(backend, "Read every file you can see.", 180000)
    check(provider.turn == 2, "phase 1 ran both scripted turns", { turn = provider.turn })
    step("phase 1: 120 read tool calls executed")

    local response = run_compact(backend, "compact #1")
    check(response ~= nil, "compaction #1 returned an RPC response")
    step("compaction #1 finished")

    local entries = session_entries(backend.session_dir)
    local compactions = by_type(entries, "compaction")
    local cleaners = custom_entries(entries, "pi2-compaction-cleaner")
    check(#compactions == 1, "exactly one compaction entry after compaction #1", { count = #compactions })
    check(#cleaners == 1, "the cleaner wrote one custom entry", { count = #cleaners })

    -- A1/A2: the summary pi stored.
    local first = compactions[1]
    local first_summary = first.summary
    check(type(first_summary) == "string" and #first_summary > 0, "the first summary is a non-empty string")
    local block = read_files_block(first_summary)
    check(block ~= nil, "the first summary carries a <read-files> block")
    local first_paths = block_paths(block)
    check(first_summary:find("/tmp/", 1, true) == nil, "no scratch path survives in the summary")
    for _, path in ipairs(temp_paths) do
        local name = vim.fn.fnamemodify(path, ":t")
        check(first_summary:find(name, 1, true) == nil, "a dropped scratch file must not appear in the summary", {
            name = name,
        })
        check(first_summary:find(path, 1, true) == nil, "a dropped scratch path must not appear in the summary")
    end
    check(
        #first_paths == MAX_READ_DEFAULT,
        ("the read list is capped at max_read (%d), got %d"):format(MAX_READ_DEFAULT, #first_paths),
        { paths = #first_paths }
    )
    for _, path in ipairs(first_paths) do
        check(
            path:sub(1, #PROJECT_ROOT) == PROJECT_ROOT,
            "every kept read path must be a project path, never a scratch path",
            { path = path }
        )
    end
    check(type(first.details) == "table", "native details are still written", { details = first.details })
    check(type(first.details.readFiles) == "table", "native details.readFiles is still an array")
    check(type(first.details.modifiedFiles) == "table", "native details.modifiedFiles is still an array")
    check(#first.details.readFiles == #first_paths, "native details carry the SAME cleaned list", {
        details = #first.details.readFiles,
        block = #first_paths,
    })
    check(first.fromHook ~= true, "pi wrote its own compaction entry (fromHook falsy)", { fromHook = first.fromHook })
    step(("A1/A2 summary holds %d project paths, 0 scratch paths, native details intact"):format(#first_paths))

    -- A3: the cleaner's own record.
    local first_report = cleaners[1].data or {}
    check(first_report.readKept == #first_paths, "the custom entry reports the kept read count", {
        report = first_report,
    })
    check(
        first_report.readOmitted >= N_TEMP,
        ("the custom entry reports readOmitted >= %d"):format(N_TEMP),
        { report = first_report }
    )
    check(first_report.strippedPrevious == false, "phase 1 has no previous summary to strip", { report = first_report })
    check(first_report.engine == "cleaner", "the custom entry is tagged with its engine", { report = first_report })
    step(
        ("A3 cleaner entry: readKept=%d readOmitted=%d strippedPrevious=false"):format(
            first_report.readKept,
            first_report.readOmitted
        )
    )

    -- Phase 2: publish max_read=5, then two more turns (a big one and a small
    -- one) so the next compaction has a real user-message span to summarize.
    write_runtime_config(config_path, {
        enabled = true,
        cleaner = { max_read = MAX_READ_PHASE2 },
    })
    run_turn(backend, "Acknowledge this prompt.", 180000)
    run_turn(backend, "Read the large project file.", 180000)
    -- 2 phase-1 turns + 1 text turn + (read turn -> text turn) = 5.
    check(provider.turn == 5, "phase 2 ran every scripted turn", { turn = provider.turn })
    step("phase 2: runtime config republished, two more turns ran")

    response = run_compact(backend, "compact #2")
    check(response ~= nil, "compaction #2 returned an RPC response")
    step("compaction #2 finished")

    entries = session_entries(backend.session_dir)
    compactions = by_type(entries, "compaction")
    cleaners = custom_entries(entries, "pi2-compaction-cleaner")
    check(#compactions == 2, "two compaction entries after compaction #2", { count = #compactions })
    check(#cleaners == 2, "the cleaner wrote a second custom entry", { count = #cleaners })

    -- A5: the second compaction honours the new cap.
    local second = compactions[2]
    local second_paths = block_paths(read_files_block(second.summary))
    check(
        #second_paths > 0 and #second_paths <= MAX_READ_PHASE2,
        ("the second read list is capped at max_read=%d, got %d"):format(MAX_READ_PHASE2, #second_paths),
        { paths = second_paths }
    )
    check(
        type(second.details) == "table"
            and type(second.details.readFiles) == "table"
            and #second.details.readFiles <= MAX_READ_PHASE2,
        "the second compaction's native details are capped too",
        { details = second.details }
    )
    check(
        contains(second_paths, provider.big_path),
        "the most recent read survives the cap (recent entries are kept)",
        { paths = second_paths, big = provider.big_path }
    )
    local second_report = cleaners[2].data or {}
    check(second_report.strippedPrevious == true, "the second compaction stripped the previous file lists", {
        report = second_report,
    })
    check(
        second_report.readKept == #second.details.readFiles,
        "the second custom entry reports the kept read count",
        { report = second_report }
    )
    step(
        ("A5 second summary holds %d project paths (<= %d), strippedPrevious=true"):format(
            #second_paths,
            MAX_READ_PHASE2
        )
    )

    -- A4: what the summariser was actually handed. The stored first summary DID
    -- contain a <read-files> block (asserted above), so a request that carries
    -- <previous-summary> WITHOUT that block proves the strip happened before the
    -- prompt was built.
    check(#provider.summarizations >= 2, "both compactions issued summarisation requests", {
        count = #provider.summarizations,
    })
    local saw_previous = false
    for index, text in ipairs(provider.summarizations) do
        if text:find("<previous-summary>", 1, true) ~= nil then
            saw_previous = true
        end
        check(
            text:find("<read-files>", 1, true) == nil,
            "no summarisation request may carry a <read-files> block",
            { request = index }
        )
        check(
            text:find("</modified-files>", 1, true) == nil,
            "no summarisation request may carry a <modified-files> block",
            { request = index }
        )
    end
    check(saw_previous, "phase 2 must really take the update-prompt path (<previous-summary> present)")
    step(
        ("A4 %d summarisation requests, none carries a file list, the update path was used"):format(
            #provider.summarizations
        )
    )

    -- A1 (second half): the FIRST summary is what carried the list into the
    -- update prompt, so the strip above is the only reason A4 holds.
    check(
        read_files_block(first.summary) ~= nil,
        "the first summary keeps its native file block (the extension only bounds it)"
    )

    -- -----------------------------------------------------------------------
    -- Phase 3: L2 checkpoint. Flip `checkpoint.enabled` on in the runtime file
    -- (the extension re-reads it per event, so no respawn is needed) and prompt
    -- with two backticked literals; the fake summary keeps one and drops the
    -- other, which is what exercises `## Retained Identifiers`.
    -- -----------------------------------------------------------------------
    write_runtime_config(config_path, {
        enabled = true,
        cleaner = { max_read = MAX_READ_PHASE2 },
        checkpoint = {
            enabled = true,
            model = PROVIDER .. "/" .. MODEL_ID,
            language = "auto",
            max_words = CHECKPOINT_MAX_WORDS,
        },
    })
    provider.mode = "checkpoint"
    provider.turn = 0
    run_turn(
        backend,
        ("Remember the literals `%s` and `%s`, then read the large project file."):format(SENTINEL, DROPPED_LITERAL),
        180000
    )
    check(provider.turn == 2, "the checkpoint phase ran both scripted turns", { turn = provider.turn })
    step("phase 3: checkpoint enabled, prompt with two literals answered by a big read")

    response = run_compact(backend, "compact #3 (checkpoint)")
    check(response ~= nil, "compaction #3 returned an RPC response")
    step("compaction #3 finished")

    entries = session_entries(backend.session_dir)
    compactions = by_type(entries, "compaction")
    cleaners = custom_entries(entries, "pi2-compaction-cleaner")
    check(#compactions == 3, "three compaction entries after compaction #3", { count = #compactions })
    check(#cleaners == 3, "the extension wrote a third custom entry", { count = #cleaners })

    -- A7: the request that ran was OURS, not pi's native prompt.
    check(#provider.checkpoint_requests >= 1, "the checkpoint summariser issued a request", {
        count = #provider.checkpoint_requests,
    })
    local request = provider.checkpoint_requests[1]
    check(request:find("pi2-compaction", 1, true) ~= nil, "the request carries our system prompt")
    check(request:find(SENTINEL, 1, true) ~= nil, "the request carries the conversation (sentinel literal)")
    for _, heading in ipairs(CHECKPOINT_HEADINGS) do
        check(request:find(heading, 1, true) ~= nil, "the request asks for every section", { heading = heading })
    end
    check(
        request:find("<previous-summary>", 1, true) ~= nil,
        "phase 3 takes the update path (<previous-summary> present)"
    )
    check(
        request:find("<read-files>", 1, true) == nil,
        "the previous summary reaches the checkpoint prompt without a file list"
    )
    check(
        request:find("</modified-files>", 1, true) == nil,
        "no modified-files block reaches the checkpoint prompt either"
    )
    step("A7 checkpoint request carries every heading + the stripped previous summary")

    -- A8/A9/A10: what pi stored.
    local third = compactions[3]
    local third_details = third.details or {}
    check(third.fromHook == true, "the stored compaction is the extension's (fromHook true)", {
        fromHook = third.fromHook,
    })
    check(third_details.engine == "pi2", "the stored details are tagged engine=pi2", { details = third_details })
    check(
        third_details.model == PROVIDER .. "/" .. MODEL_ID,
        "the stored details name the pinned model",
        { model = third_details.model }
    )
    local third_summary = third.summary
    check(type(third_summary) == "string", "the checkpoint summary is a string")
    check(
        third_summary:sub(1, #"## Goal") == "## Goal",
        "the checkpoint starts at ## Goal (not pi's native preamble)",
        { head = third_summary:sub(1, 40) }
    )
    for _, heading in ipairs(CHECKPOINT_HEADINGS) do
        check(third_summary:find(heading, 1, true) ~= nil, "the checkpoint has every section", { heading = heading })
    end
    check(third_summary:find(SENTINEL, 1, true) ~= nil, "the checkpoint keeps the sentinel literal")
    check(third_summary:find(DROPPED_LITERAL, 1, true) ~= nil, "a literal the model dropped is restored verbatim")
    check(
        third_summary:find("## Retained Identifiers", 1, true) ~= nil,
        "the restored literal is listed under ## Retained Identifiers"
    )
    local third_block = read_files_block(third_summary)
    check(third_block ~= nil, "the checkpoint carries the appended <read-files> block")
    local third_paths = block_paths(third_block)
    check(contains(third_paths, provider.big_path), "the appended block lists the freshly read file", {
        paths = third_paths,
    })
    check(type(third_details.readFiles) == "table", "the stored details carry the read list")
    check(
        #third_paths == #third_details.readFiles,
        "the appended block is the same list details record",
        { block = #third_paths, details = #third_details.readFiles }
    )
    check(type(third_details.readFilesOmitted) == "number", "the stored details carry readFilesOmitted")
    check(third_details.previousSummaryStripped == true, "L1 stripped the previous lists before L2 ran")
    local third_body = (third_summary:gsub("<read%-files>.-</read%-files>", "")):gsub(
        "<modified%-files>.-</modified%-files>",
        ""
    )
    local third_words = word_count(third_body)
    check(
        third_words <= CHECKPOINT_MAX_WORDS * 2,
        ("the checkpoint stays inside the 2x hard stop (%d <= %d)"):format(third_words, CHECKPOINT_MAX_WORDS * 2),
        { words = third_words }
    )
    step(
        ("A8/A9 checkpoint: fromHook, engine=pi2, model=%s, %d headings, %d words, %d files"):format(
            third_details.model,
            #CHECKPOINT_HEADINGS,
            third_words,
            #third_paths
        )
    )

    local third_report = cleaners[3].data or {}
    check(third_report.engine == "checkpoint", "the custom entry reports engine=checkpoint", {
        report = third_report,
    })
    check(third_report.checkpoint == true, "the custom entry reports checkpoint=true", { report = third_report })
    check(
        third_report.model == PROVIDER .. "/" .. MODEL_ID,
        "the custom entry names the model",
        { report = third_report }
    )
    check(type(third_report.durationMs) == "number", "the custom entry records the duration", {
        report = third_report,
    })
    check(third_report.strippedPrevious == true, "the custom entry records the strip", { report = third_report })
    step("A10 custom entry: engine=checkpoint, checkpoint=true, model + duration recorded")

    -- A6: nothing failed.
    local errors = {}
    for _, ev in ipairs(backend.events) do
        if ev.type == "extension_error" then
            errors[#errors + 1] = ev
        end
    end
    check(#errors == 0, "the extension never raised an error event", { errors = errors })
    for _, ev in ipairs(backend.events) do
        if ev.type == "response" and ev.command == "compact" and ev.success ~= true then
            error("a compact response failed: " .. vim.inspect(ev), 0)
        end
    end
    step("A6 no extension_error events, every compact response succeeded")

    -- -----------------------------------------------------------------------
    -- Phase 4 (A11): fail open. A fresh session with the SAME checkpoint config;
    -- the fake provider answers the checkpoint request with an EMPTY completion,
    -- so the extension must return undefined and pi's native summariser runs.
    -- -----------------------------------------------------------------------
    provider.mode = "fallback"
    provider.turn = 0
    local fallback_backend = start_backend(RUN_ROOT .. "/sessions-fallback", PROJECT_ROOT .. "/project")
    send(fallback_backend, { type = "set_model", provider = PROVIDER, modelId = MODEL_ID })
    local fallback_pinned = wait_event(fallback_backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, "set_model (fallback)")
    check(fallback_pinned ~= nil and fallback_pinned.success ~= false, "the fallback model is selected", {
        stderr = fallback_backend.stderr,
    })
    run_turn(fallback_backend, "Read the large project file before compacting.", 180000)
    check(provider.turn == 2, "the fallback phase ran both scripted turns", { turn = provider.turn })
    local checkpoint_requests_before = #provider.checkpoint_requests
    response = run_compact(fallback_backend, "compact (fallback)")
    check(response ~= nil, "the fallback compaction returned an RPC response")
    check(
        #provider.checkpoint_requests == checkpoint_requests_before + 1,
        "the checkpoint summariser ran and was answered with an empty completion",
        { before = checkpoint_requests_before, now = #provider.checkpoint_requests }
    )

    local fallback_entries = session_entries(fallback_backend.session_dir)
    local fallback_compactions = by_type(fallback_entries, "compaction")
    check(#fallback_compactions == 1, "pi stored exactly one compaction in the fallback session", {
        count = #fallback_compactions,
    })
    local fallback = fallback_compactions[1]
    check(fallback.fromHook ~= true, "the fallback stored pi's native compaction (fromHook falsy)", {
        fromHook = fallback.fromHook,
    })
    check(type(fallback.details) == "table", "the fallback carries pi's native details")
    check(fallback.details.engine == nil, "the fallback details are native (no engine tag)", {
        details = fallback.details,
    })
    check(type(fallback.details.readFiles) == "table", "the fallback details carry native file lists")
    local fallback_cleaners = custom_entries(fallback_entries, "pi2-compaction-cleaner")
    check(#fallback_cleaners == 1, "the extension still records the fallback compaction", {
        count = #fallback_cleaners,
    })
    local fallback_report = fallback_cleaners[1].data or {}
    check(fallback_report.engine == "checkpoint", "the fallback entry reports the enabled mode", {
        report = fallback_report,
    })
    check(fallback_report.checkpoint == false, "the fallback entry reports checkpoint=false", {
        report = fallback_report,
    })
    check(fallback_report.model == nil, "no model is recorded when L2 did not run", { report = fallback_report })
    local fallback_errors = {}
    for _, ev in ipairs(fallback_backend.events) do
        if ev.type == "extension_error" then
            fallback_errors[#fallback_errors + 1] = ev
        end
    end
    check(#fallback_errors == 0, "the empty completion raised no extension_error", { errors = fallback_errors })
    stop_backend(fallback_backend)
    step("A11 empty completion: native compaction stored, checkpoint=false recorded, pi exited cleanly")

    -- -----------------------------------------------------------------------
    -- Phase 5 (A12-A15): L3 state snapshot. A fresh session in a REAL tiny git
    -- repo, with `extensions/todo.ts` loaded so the snapshot folds an actual
    -- `todo_write` result. Checkpoint stays off (that phase is done), the state
    -- layer stays at its default.
    -- -----------------------------------------------------------------------
    provider.mode = "state"
    provider.turn = 0
    local state_cwd = create_git_fixture()
    local _, branch_out = sh({ "git", "-C", state_cwd, "rev-parse", "--abbrev-ref", "HEAD" }, state_cwd)
    local state_branch = branch_out:gsub("%s+$", "")
    check(state_branch ~= "", "the git fixture has a branch")
    write_runtime_config(config_path, {
        enabled = true,
        state = { enabled = true, max_tokens = 400 },
    })
    local state_backend = start_backend(RUN_ROOT .. "/sessions-state", state_cwd, { TODO_EXTENSION })
    send(state_backend, { type = "set_model", provider = PROVIDER, modelId = MODEL_ID })
    local state_pinned = wait_event(state_backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, "set_model (state)")
    check(state_pinned ~= nil and state_pinned.success ~= false, "the state-phase model is selected", {
        stderr = state_backend.stderr,
    })

    -- Pre-compaction: the todo list is written and the big file read, so the
    -- NEXT compaction has both state to fold and content to summarize.
    local pre_mark = #provider.requests
    run_turn(state_backend, "Record the plan and read the large file.", 180000)
    check(provider.turn == 2, "the state phase ran both scripted turns", { turn = provider.turn })
    check(#provider.requests > pre_mark, "the state phase issued conversation requests")
    check(
        count_occurrences(provider.requests[pre_mark + 1], STATE_MARKER) == 0,
        "no snapshot exists before the first compaction (a fresh session injects nothing)"
    )
    step("phase 5: todo_write + big read ran, no snapshot injected yet")

    response = run_compact(state_backend, "compact #4 (state)")
    check(response ~= nil, "the state compaction returned an RPC response")
    entries = session_entries(state_backend.session_dir)
    compactions = by_type(entries, "compaction")
    local state_rows = custom_entries(entries, "pi2-compaction-state")
    check(#compactions == 1, "one compaction entry in the state session", { count = #compactions })
    check(#state_rows == 1, "the extension persisted exactly one state snapshot", { count = #state_rows })
    local snapshot = state_rows[1].data or {}

    -- A12: the record itself.
    check(type(snapshot.text) == "string" and snapshot.text ~= "", "the snapshot text is a non-empty string", {
        data = snapshot,
    })
    check(
        snapshot.text:find(STATE_MARKER .. " Post-compaction state snapshot", 1, true) == 1,
        "the snapshot starts with the [pi2 state] header",
        { head = snapshot.text:sub(1, 80) }
    )
    check(snapshot.reason == "manual", "the snapshot records the compaction reason", { reason = snapshot.reason })
    check(
        type(snapshot.hash) == "string" and snapshot.hash:match("^%x%x%x%x%x%x%x%x$") ~= nil,
        "the snapshot carries an 8-hex-char content hash",
        { hash = snapshot.hash }
    )
    check(type(snapshot.tokensBefore) == "number", "the snapshot records tokensBefore", { data = snapshot })
    check(
        type(snapshot.tokensBeforeAfter) == "number" and snapshot.tokensBeforeAfter < snapshot.tokensBefore,
        "the snapshot records the estimated tokens after (smaller than before)",
        { data = snapshot }
    )
    check(snapshot.text:find("## Compaction", 1, true) ~= nil, "the snapshot carries the compaction facts")
    check(snapshot.text:find("- reason: manual", 1, true) ~= nil, "the compaction facts name the reason")
    check(snapshot.text:find(STATE_TODO_ONE, 1, true) ~= nil, "the snapshot carries the unfinished todo item")
    check(snapshot.text:find("- [ ] ", 1, true) ~= nil, "todo items render as unchecked boxes")
    check(snapshot.text:find(STATE_TODO_THREE, 1, true) == nil, "no item exists yet that was never written")
    check(snapshot.text:find("## Git", 1, true) ~= nil, "the snapshot carries the git section")
    check(snapshot.text:find("root: " .. state_cwd, 1, true) ~= nil, "the git section names the toplevel", {
        root = state_cwd,
    })
    check(
        snapshot.text:find("branch: " .. state_branch, 1, true) ~= nil,
        "the git section names the branch",
        { branch = state_branch }
    )
    check(snapshot.text:find("?? untracked.txt", 1, true) ~= nil, "the git section lists the untracked file")
    check(snapshot.text:find("M committed.txt", 1, true) ~= nil, "the git section lists the modified file")
    check(snapshot.text:find("[truncated]", 1, true) == nil, "the 400-token budget did not drop a section")
    step(
        ("A12 snapshot: %d chars, todos folded, git on %s (%s), hash=%s, %d -> %d tokens"):format(
            #snapshot.text,
            state_branch,
            state_cwd,
            snapshot.hash,
            snapshot.tokensBefore,
            snapshot.tokensBeforeAfter
        )
    )

    -- A13: exactly one request carries it, and the next prompt carries none.
    local rc_mark = #provider.requests
    run_turn(state_backend, "Continue after the compaction.", 180000)
    check(provider.turn == 3, "the post-compaction prompt ran", { turn = provider.turn })
    check(#provider.requests > rc_mark, "the post-compaction prompt issued a request")
    local injected = provider.requests[rc_mark + 1]
    check(
        count_occurrences(injected, STATE_MARKER) == 1,
        "the FIRST post-compaction request carries the snapshot exactly once",
        { count = count_occurrences(injected, STATE_MARKER) }
    )
    check(injected:find(STATE_TODO_TWO, 1, true) ~= nil, "the injected text is the snapshot's todo state")
    local next_mark = #provider.requests
    run_turn(state_backend, "A second prompt with unchanged state.", 180000)
    check(provider.turn == 4, "the follow-up prompt ran", { turn = provider.turn })
    local follow_up = provider.requests[next_mark + 1]
    check(
        count_occurrences(follow_up, STATE_MARKER) == 0,
        "a second prompt with unchanged state carries the snapshot ZERO times",
        { count = count_occurrences(follow_up, STATE_MARKER) }
    )
    step("A13 injected once into the first request, never per turn")

    -- A14: an unchanged state is byte-stable and must not be re-injected.
    run_turn(state_backend, "Read the large file again so the next compaction has work.", 180000)
    check(provider.turn == 6, "the pre-compaction read ran", { turn = provider.turn })
    response = run_compact(state_backend, "compact #5 (state unchanged)")
    check(response ~= nil, "the second state compaction returned an RPC response")
    entries = session_entries(state_backend.session_dir)
    state_rows = custom_entries(entries, "pi2-compaction-state")
    check(#state_rows == 2, "the second compaction persisted a second snapshot", { count = #state_rows })
    local stable = state_rows[2].data or {}
    check(stable.hash == snapshot.hash, "an unchanged state hashes identically", {
        first = snapshot.hash,
        second = stable.hash,
    })
    check(
        state_sections(stable.text) == state_sections(snapshot.text),
        "an unchanged state renders byte-identically outside the compaction facts",
        { first = state_sections(snapshot.text), second = state_sections(stable.text) }
    )
    check(stable.text ~= snapshot.text, "the facts still record this compaction (its own token counts)")
    local stable_mark = #provider.requests
    run_turn(state_backend, "Nothing changed, keep going.", 180000)
    check(provider.turn == 7, "the post-compaction prompt after #2 ran", { turn = provider.turn })
    check(
        count_occurrences(provider.requests[stable_mark + 1], STATE_MARKER) == 0,
        "a byte-identical state is NOT injected a second time",
        { count = count_occurrences(provider.requests[stable_mark + 1], STATE_MARKER) }
    )
    step(("A14 unchanged state: same hash %s, same state sections, no fresh injection"):format(stable.hash))

    -- A15: a changed todo list changes the hash and injects exactly once.
    local update_mark = #provider.requests
    run_turn(state_backend, "Update the todo list and read the large file.", 180000)
    check(provider.turn == 9, "the todo update ran both scripted turns", { turn = provider.turn })
    check(
        count_occurrences(provider.requests[update_mark + 1], STATE_MARKER) == 0,
        "the todo update's request carries no stale snapshot"
    )
    response = run_compact(state_backend, "compact #6 (state changed)")
    check(response ~= nil, "the third state compaction returned an RPC response")
    entries = session_entries(state_backend.session_dir)
    state_rows = custom_entries(entries, "pi2-compaction-state")
    check(#state_rows == 3, "the third compaction persisted a third snapshot", { count = #state_rows })
    local changed = state_rows[3].data or {}
    check(changed.hash ~= snapshot.hash, "a changed todo list changes the snapshot hash", {
        before = snapshot.hash,
        after = changed.hash,
    })
    check(changed.text:find(STATE_TODO_THREE, 1, true) ~= nil, "the new snapshot carries the new item")
    check(
        changed.text:find(STATE_TODO_ONE, 1, true) == nil,
        "a completed item is no longer carried in the unfinished list"
    )
    local fresh_mark = #provider.requests
    run_turn(state_backend, "One more prompt after the change.", 180000)
    check(provider.turn == 10, "the post-change prompt ran", { turn = provider.turn })
    local fresh = provider.requests[fresh_mark + 1]
    check(
        count_occurrences(fresh, STATE_MARKER) == 1,
        "a changed snapshot is injected exactly once",
        { count = count_occurrences(fresh, STATE_MARKER) }
    )
    check(fresh:find(STATE_TODO_THREE, 1, true) ~= nil, "the injected text is the NEW snapshot")
    local state_errors = {}
    for _, ev in ipairs(state_backend.events) do
        if ev.type == "extension_error" then
            state_errors[#state_errors + 1] = ev
        end
    end
    check(#state_errors == 0, "the state layer never raised an extension_error", { errors = state_errors })
    step(("A15 changed state: new hash %s, new item injected exactly once"):format(changed.hash))
    stop_backend(state_backend)

    -- -----------------------------------------------------------------------
    -- Phase 6 (A16-A17): owner conflict. The competitor is loaded AFTER ours, so
    -- it wins the `session_before_compact` chain and supplies the summary. Ours
    -- must say so ONCE, stand L2 down, and keep L1 + the state snapshot alive.
    -- -----------------------------------------------------------------------
    local competitor_path = RUN_ROOT .. "/competitor-compaction.ts"
    local competitor_file = assert(io.open(competitor_path, "w"))
    competitor_file:write(COMPETITOR_SOURCE)
    competitor_file:close()
    write_runtime_config(config_path, {
        enabled = true,
        checkpoint = {
            enabled = true,
            model = PROVIDER .. "/" .. MODEL_ID,
            language = "auto",
            max_words = CHECKPOINT_MAX_WORDS,
        },
        state = { enabled = true },
        owner = { detect = true },
    })
    provider.mode = "checkpoint"
    provider.turn = 0
    --- Count the `notify` UI requests that mention the conflict.
    ---@param target CompactionE2EBackend
    ---@return integer
    local function conflict_notices(target)
        local count = 0
        for _, ev in ipairs(target.events) do
            if
                ev.type == "extension_ui_request"
                and ev.method == "notify"
                and type(ev.message) == "string"
                and ev.message:find(OWNER_CONFLICT_NOTICE, 1, true) ~= nil
            then
                count = count + 1
            end
        end
        return count
    end
    local conflict_backend = start_backend(RUN_ROOT .. "/sessions-conflict", PROJECT_ROOT .. "/project", {
        competitor_path,
    })
    send(conflict_backend, { type = "set_model", provider = PROVIDER, modelId = MODEL_ID })
    local conflict_pinned = wait_event(conflict_backend, function(ev)
        return ev.type == "response" and ev.command == "set_model"
    end, 30000, "set_model (conflict)")
    check(conflict_pinned ~= nil and conflict_pinned.success ~= false, "the conflict-phase model is selected", {
        stderr = conflict_backend.stderr,
    })
    run_turn(conflict_backend, "Read the large project file before the contested compaction.", 180000)
    check(provider.turn == 2, "the conflict phase ran both scripted turns", { turn = provider.turn })

    -- A16: the FIRST contested compaction. Ours is loaded first, so its
    -- checkpoint request happens; the competitor then replaces the result.
    local checkpoints_before = #provider.checkpoint_requests
    response = run_compact(conflict_backend, "compact #7 (contested)")
    check(response ~= nil, "the contested compaction returned an RPC response")
    check(
        #provider.checkpoint_requests == checkpoints_before + 1,
        "our checkpoint layer ran before the competitor overwrote it (load order)",
        { before = checkpoints_before, now = #provider.checkpoint_requests }
    )
    local conflict_entries = session_entries(conflict_backend.session_dir)
    local conflict_compactions = by_type(conflict_entries, "compaction")
    check(#conflict_compactions == 1, "one compaction entry in the conflict session", {
        count = #conflict_compactions,
    })
    local contested = conflict_compactions[1]
    check(contested.fromHook == true, "the contested compaction came from an extension", {
        fromHook = contested.fromHook,
    })
    local contested_details = contested.details or {}
    check(
        contested_details.engine ~= nil and contested_details.engine ~= "pi2",
        "the stored summary is NOT ours (details.engine is the competitor's)",
        { details = contested_details }
    )
    check(contested_details.engine == "competitor", "the last-loaded extension supplied the summary", {
        details = contested_details,
    })
    check(
        contested.summary:find(COMPETITOR_MARKER, 1, true) ~= nil,
        "the stored summary is the competitor's text",
        { summary = contested.summary }
    )
    check(conflict_notices(conflict_backend) == 1, "the conflict notice was emitted exactly once", {
        count = conflict_notices(conflict_backend),
    })
    step("A16 contested compaction: competitor's summary stored, ONE conflict notice emitted")

    -- A17: the SECOND contested compaction must not re-notify and must not run
    -- our checkpoint layer at all (L2 stood down); L1 and L3 kept working.
    run_turn(conflict_backend, "Read the large project file once more.", 180000)
    check(provider.turn == 4, "the pre-compaction turn ran", { turn = provider.turn })
    checkpoints_before = #provider.checkpoint_requests
    response = run_compact(conflict_backend, "compact #8 (contested, L2 stood down)")
    check(response ~= nil, "the second contested compaction returned an RPC response")
    check(
        #provider.checkpoint_requests == checkpoints_before,
        "L2 stood down: no checkpoint request for the second contested compaction",
        { before = checkpoints_before, now = #provider.checkpoint_requests }
    )
    check(conflict_notices(conflict_backend) == 1, "the conflict notice is rate-limited to once per session", {
        count = conflict_notices(conflict_backend),
    })
    conflict_entries = session_entries(conflict_backend.session_dir)
    conflict_compactions = by_type(conflict_entries, "compaction")
    check(#conflict_compactions == 2, "two contested compactions are stored", { count = #conflict_compactions })
    check(
        (conflict_compactions[2].details or {}).engine == "competitor",
        "the second contested compaction is the competitor's too",
        { details = conflict_compactions[2].details }
    )
    local conflict_cleaners = custom_entries(conflict_entries, "pi2-compaction-cleaner")
    check(#conflict_cleaners == 2, "L1 kept recording through the conflict (two cleaner entries)", {
        count = #conflict_cleaners,
    })
    local conflict_states = custom_entries(conflict_entries, "pi2-compaction-state")
    check(#conflict_states == 2, "L3 kept recording through the conflict (two state snapshots)", {
        count = #conflict_states,
    })
    local conflict_errors = {}
    for _, ev in ipairs(conflict_backend.events) do
        if ev.type == "extension_error" then
            conflict_errors[#conflict_errors + 1] = ev
        end
    end
    check(#conflict_errors == 0, "the conflict path raised no extension_error", { errors = conflict_errors })
    stop_backend(conflict_backend)
    step("A17 L2 stood down after the conflict, L1 + L3 still active, one notice total")

    -- -----------------------------------------------------------------------
    -- Phase 7 (A18-A20): L4 prune ON. A fresh session on the SMALL-window model
    -- (`PRUNE_CONTEXT_WINDOW`), `high_water = 0.2` and `min_turns = 1`: four
    -- turns each read a 4000-char fixture with its own sentinel, so the window
    -- fills, the oldest results become pointers and the newest turn stays whole.
    -- -----------------------------------------------------------------------
    --- The L4 scripted conversation: `PRUNE_FILES` prompts, each answered by a
    --- read turn (one ~1000-token result) and a text turn. Returns the context
    --- percent `get_session_stats` reported after each prompt.
    ---@param backend CompactionE2EBackend
    ---@return table[] percents
    local function run_prune_conversation(backend)
        local percents = {}
        for index = 1, PRUNE_FILES do
            run_turn(backend, ("Read prune file %d."):format(index), 180000)
            local stats = session_stats(backend, ("session stats after prune prompt %d"):format(index))
            local usage = stats and stats.contextUsage
            percents[#percents + 1] = type(usage) == "table" and usage.percent or nil
        end
        check(provider.turn == PRUNE_FILES * 2, "the prune phase ran every scripted turn", { turn = provider.turn })
        return percents
    end

    ---@param session_name string
    ---@return CompactionE2EBackend
    local function start_prune_backend(session_name)
        local backend = start_backend(RUN_ROOT .. "/" .. session_name, PROJECT_ROOT .. "/prune")
        send(backend, { type = "set_model", provider = PROVIDER, modelId = PRUNE_MODEL_ID })
        local pinned = wait_event(backend, function(ev)
            return ev.type == "response" and ev.command == "set_model"
        end, 30000, "set_model (" .. session_name .. ")")
        check(pinned ~= nil and pinned.success ~= false, "the small-window model is selected", {
            stderr = backend.stderr,
        })
        return backend
    end

    write_runtime_config(config_path, {
        enabled = true,
        prune = { enabled = true, high_water = PRUNE_HIGH_WATER, min_turns = PRUNE_MIN_TURNS },
    })
    provider.mode = "prune"
    provider.turn = 0
    local prune_mark = #provider.requests
    local prune_backend = start_prune_backend("sessions-prune")
    local prune_percents = run_prune_conversation(prune_backend)
    local prune_reqs = {}
    for index = prune_mark + 1, #provider.requests do
        prune_reqs[#prune_reqs + 1] = provider.requests[index]
    end
    check(#prune_reqs >= PRUNE_FILES * 2 - 1, "the prune phase issued conversation requests", {
        count = #prune_reqs,
    })
    local oldest_id = "call_prune_1"
    local newest_id = ("call_prune_%d"):format(PRUNE_FILES)
    local last = prune_reqs[#prune_reqs]
    check(last ~= nil, "the prune phase has a final conversation request")
    check(
        last:find(prune_pointer("read", oldest_id), 1, true) ~= nil,
        "the final request replaces the OLDEST tool result with its pointer",
        { pointer = prune_pointer("read", oldest_id) }
    )
    check(
        last:find(PRUNE_SENTINEL_PREFIX .. "1", 1, true) == nil,
        "the pruned result's sentinel body is GONE from the request",
        { request = #prune_reqs }
    )
    check(
        last:find(PRUNE_SENTINEL_PREFIX .. PRUNE_FILES, 1, true) ~= nil,
        "the most recent turn's tool result is delivered in full"
    )
    check(last:find(prune_pointer("read", newest_id), 1, true) == nil, "the newest turn is never pruned")
    step(
        ("A18 oldest result pruned (pointer for %s), its body gone, newest turn (%s) intact; context %% per prompt: %s"):format(
            oldest_id,
            newest_id,
            table.concat(
                vim.tbl_map(function(value)
                    return tostring(value)
                end, prune_percents),
                " -> "
            )
        )
    )

    -- A19: the pointer text never churns, and the set never shrinks.
    local pointer_texts = {}
    for _, text in ipairs(prune_reqs) do
        for pointer in text:gmatch("%[pruned tool result:[^%]]*%]") do
            local id = pointer:match("^%[pruned tool result: %S+ (%S+);")
            check(id ~= nil, "the pointer names its tool call", { pointer = pointer })
            pointer_texts[id] = pointer_texts[id] or {}
            pointer_texts[id][pointer] = true
        end
    end
    local pointer_ids = vim.tbl_keys(pointer_texts)
    check(#pointer_ids > 0, "at least one pointer rode the prune-phase requests")
    for _, id in ipairs(pointer_ids) do
        local variants = vim.tbl_keys(pointer_texts[id])
        check(#variants == 1, "a pruned result keeps ONE fixed pointer text (no churn)", {
            id = id,
            variants = variants,
        })
    end
    local previous_pointers = 0
    for index, text in ipairs(prune_reqs) do
        local pointers = count_occurrences(text, PRUNE_POINTER_PREFIX)
        check(pointers >= previous_pointers, "no request un-prunes a tool result (the prefix does not churn)", {
            request = index,
            pointers = pointers,
            previous = previous_pointers,
        })
        previous_pointers = pointers
    end
    step(
        ("A19 %d distinct pruned ids, one pointer text each, monotone pointer count (max %d per request)"):format(
            #pointer_ids,
            previous_pointers
        )
    )

    -- A20: the decision is persisted, deduped, and NOTHING is lost.
    local prune_entries = session_entries(prune_backend.session_dir)
    local prune_compactions = by_type(prune_entries, "compaction")
    check(#prune_compactions == 0, "the prune phase never compacted (the window was not exceeded)", {
        count = #prune_compactions,
    })
    local prune_rows = custom_entries(prune_entries, "pi2-compaction-prune")
    check(#prune_rows >= 1, "the extension persisted at least one prune decision", { count = #prune_rows })
    local previous_signature = nil
    for _, row in ipairs(prune_rows) do
        local data = row.data or {}
        check(type(data.pruned) == "table" and #data.pruned > 0, "the decision names the pruned ids", { data = data })
        check(
            type(data.savedChars) == "number" and data.savedChars > 0,
            "the decision records the character estimate it saved",
            { data = data }
        )
        check(
            type(data.atFraction) == "number" and data.atFraction >= PRUNE_HIGH_WATER,
            "the decision records the reported fraction that triggered it",
            { data = data }
        )
        local ids = {}
        for _, pruned in ipairs(data.pruned) do
            check(
                type(pruned.id) == "string" and type(pruned.toolName) == "string",
                "every decision row carries an id and a toolName",
                { row = pruned }
            )
            ids[#ids + 1] = pruned.id
        end
        local joined = table.concat(ids, ",")
        check(joined ~= previous_signature, "an identical decision is never appended twice", {
            signature = joined,
        })
        previous_signature = joined
    end
    local first_decision = prune_rows[1].data or {}
    local first_row = (first_decision.pruned or {})[1] or {}
    check(
        first_row.id == oldest_id and first_row.toolName == "read",
        "the first decision starts with the OLDEST tool result",
        { row = first_row }
    )
    local prune_jsonl = session_jsonl_text(prune_backend.session_dir)
    check(
        count_occurrences(prune_jsonl, PRUNE_SENTINEL_PREFIX .. "1") >= 1,
        "the session transcript still holds the pruned result's original bytes"
    )
    check(
        count_occurrences(prune_jsonl, PRUNE_POINTER_PREFIX) == 0,
        "the pointer is a request view only: it is never persisted"
    )
    local prune_errors = {}
    for _, ev in ipairs(prune_backend.events) do
        if ev.type == "extension_error" then
            prune_errors[#prune_errors + 1] = ev
        end
    end
    check(#prune_errors == 0, "the prune path raised no extension_error", { errors = prune_errors })
    stop_backend(prune_backend)
    step(
        ("A20 %d prune decisions, deduped by id set, %d chars claimed saved, original sentinel still in the JSONL"):format(
            #prune_rows,
            (prune_rows[#prune_rows].data or {}).savedChars or 0
        )
    )

    -- A22: the decision survives a process restart. A FRESH pi opens the prune
    -- session's file, so the extension instance is rebuilt from scratch and its
    -- in-memory set is empty: the SAME pointer has to come back out of the
    -- persisted `pi2-compaction-prune` entry, and no pruned body may reappear.
    local prune_session_path
    for _, name in ipairs(vim.fn.readdir(prune_backend.session_dir)) do
        if name:match("%.jsonl$") then
            prune_session_path = prune_backend.session_dir .. "/" .. name
        end
    end
    check(prune_session_path ~= nil, "the prune session is on disk")
    local resumed_backend = start_prune_backend("sessions-prune-resume")
    send(resumed_backend, { type = "switch_session", sessionPath = prune_session_path })
    local switched = wait_event(resumed_backend, function(ev)
        return ev.type == "response" and ev.command == "switch_session"
    end, 60000, "switch_session (prune resume)")
    check(switched ~= nil and switched.success ~= false, "the resumed backend switched onto the prune session", {
        response = switched,
        stderr = resumed_backend.stderr,
    })
    -- The resumed conversation continues with a plain text answer (every scripted
    -- read has been used already), so the request carries only history.
    provider.turn = PRUNE_FILES * 2
    local resumed_mark = #provider.requests
    run_turn(resumed_backend, "Continue after the restart.", 180000)
    local resumed_request = provider.requests[resumed_mark + 1]
    check(resumed_request ~= nil, "the resumed session issued a conversation request")
    check(
        resumed_request:find(prune_pointer("read", oldest_id), 1, true) ~= nil,
        "a resumed process serves the SAME pointer text",
        { pointer = prune_pointer("read", oldest_id) }
    )
    check(
        resumed_request:find(PRUNE_SENTINEL_PREFIX .. "1", 1, true) == nil,
        "the resumed request does not bring the pruned body back"
    )
    local resumed_errors = {}
    for _, ev in ipairs(resumed_backend.events) do
        if ev.type == "extension_error" then
            resumed_errors[#resumed_errors + 1] = ev
        end
    end
    check(#resumed_errors == 0, "the resume path raised no extension_error", { errors = resumed_errors })
    stop_backend(resumed_backend)
    step("A22 a fresh process re-seeds the persisted decision and serves the identical pointer")

    -- -----------------------------------------------------------------------
    -- Phase 8 (A21): the negative control. Same conversation, same model, same
    -- window — only `prune.enabled` is false. Every body must be delivered and
    -- nothing may be recorded.
    -- -----------------------------------------------------------------------
    write_runtime_config(config_path, {
        enabled = true,
        prune = { enabled = false, high_water = PRUNE_HIGH_WATER, min_turns = PRUNE_MIN_TURNS },
    })
    provider.mode = "prune"
    provider.turn = 0
    local control_mark = #provider.requests
    local control_backend = start_prune_backend("sessions-prune-off")
    run_prune_conversation(control_backend)
    local control_reqs = {}
    for index = control_mark + 1, #provider.requests do
        control_reqs[#control_reqs + 1] = provider.requests[index]
    end
    check(#control_reqs >= PRUNE_FILES * 2 - 1, "the control phase issued conversation requests", {
        count = #control_reqs,
    })
    for index, text in ipairs(control_reqs) do
        check(count_occurrences(text, PRUNE_POINTER_PREFIX) == 0, "prune.enabled=false never replaces a tool result", {
            request = index,
        })
    end
    local control_last = control_reqs[#control_reqs]
    check(control_last ~= nil, "the control phase has a final conversation request")
    check(
        control_last:find(PRUNE_SENTINEL_PREFIX .. "1", 1, true) ~= nil,
        "with pruning off the OLDEST tool result body is delivered in full"
    )
    local control_entries = session_entries(control_backend.session_dir)
    check(
        #custom_entries(control_entries, "pi2-compaction-prune") == 0,
        "with pruning off no prune decision is recorded"
    )
    local control_errors = {}
    for _, ev in ipairs(control_backend.events) do
        if ev.type == "extension_error" then
            control_errors[#control_errors + 1] = ev
        end
    end
    check(#control_errors == 0, "the control path raised no extension_error", { errors = control_errors })
    stop_backend(control_backend)
    step("A21 negative control: prune off delivers every full body, no pointer, no decision")

    stop_backend(backend)
    print(
        ("ALL compaction cases passed (cleaner bounds + strips, checkpoint summaries structured/deduped, fail open, state snapshot injected once per change, owner conflict detected, tool results pruned at a turn boundary with the newest turn intact and the negative control untouched) in %.2fs"):format(
            (uv.hrtime() - run_started) / 1e9
        )
    )
    cleanup()
    vim.cmd("cq 0")
end

local ok, err = pcall(main)
if not ok then
    io.stderr:write("e2e compaction: " .. tostring(err) .. "\n")
    cleanup()
    vim.cmd("cq 1")
end
