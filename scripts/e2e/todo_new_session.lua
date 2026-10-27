-- Headless e2e: pi todo list reset after /new (new_session RPC)
--
-- Tests the fix for:
-- After /new (RPC {"type":"new_session"}), pi re-invokes the extension factory
-- and fires session_start(reason=new), but does NOT re-evaluate the extension module.
-- Without resetting todos = [] in reconstruct(ctx), the previous session's in-memory
-- todo list survived and leaked into the fresh session's context hook.
--
-- Steps:
--   1. Seed a session file containing a successful todo_write toolResult.
--   2. Write a probe extension that logs session_start/session_shutdown reasons
--      and any context messages containing "[todo]".
--   3. Spawn `pi --mode rpc --session <seed> -e extensions/todo.ts -e <probe.ts>`.
--   4. Send a cheap prompt -> assert probe logged HAS_TODO (resumed session has todo).
--   5. Send {"type":"new_session"} -> assert session_start(reason=new) fired.
--   6. Send a second cheap prompt -> assert probe logged NO_TODO (fresh session has no todo).
--   7. Assert process remains alive (note: title.ts stale-ctx guard is verified by
--      code inspection / process survival, cannot be isolated directly here).
--
-- How to run:
--   nvim --headless -u tests/minimal_init.lua -l scripts/e2e/todo_new_session.lua
--
-- Exit code:
--   0 = SUCCESS (PASS or SKIP)
--   1 = FAIL

local uv = vim.uv or vim.loop

io.stdout:setvbuf("no")
local run_started = uv.hrtime()
local last_step = run_started

local function step(name)
    local t = uv.hrtime()
    print(string.format("[step] %-58s +%6.2fs (total %7.2fs)", name, (t - last_step) / 1e9, (t - run_started) / 1e9))
    last_step = t
end

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

local function get_worktree_root()
    local info = debug.getinfo(1, "S")
    local src = info and info.source
    if type(src) == "string" and src:sub(1, 1) == "@" then
        return vim.fn.fnamemodify(src:sub(2), ":p:h:h:h")
    end
    return vim.fn.getcwd()
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

local function is_rate_limit(err)
    local s = tostring(err):lower()
    return s:find("429") ~= nil
        or s:find("capacity") ~= nil
        or s:find("rate limit") ~= nil
        or s:find("overloaded") ~= nil
end

local function main()
    -- Gate: check pi binary
    if vim.fn.executable("pi") ~= 1 then
        print("SKIP: pi binary not found in PATH")
        os.exit(0)
    end

    local root = get_worktree_root()
    local todo_ext_path = os.getenv("TODO_EXT_PATH") or (root .. "/extensions/todo.ts")
    check(vim.uv.fs_stat(todo_ext_path) ~= nil, "todo.ts extension not found at " .. todo_ext_path)

    -- Setup temp directory
    local temp_dir = vim.fn.tempname() .. "_todo_new_session"
    vim.fn.mkdir(temp_dir, "p")
    local probe_log_path = temp_dir .. "/probe.log"
    local probe_ext_path = temp_dir .. "/probe.ts"
    local seed_session_path = temp_dir .. "/seed_session.jsonl"

    local job_id = nil

    local function cleanup()
        if job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1 then
            pcall(vim.fn.jobstop, job_id)
            vim.fn.jobwait({ job_id }, 2000)
        end
        vim.fn.delete(temp_dir, "rf")
    end

    local ok, run_err = pcall(function()
        step("S1 write probe extension and seed session")
        -- Write probe extension
        local probe_code = string.format(
            [=[
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";

const LOG_FILE = %q;

function log(line: string) {
	appendFileSync(LOG_FILE, line + "\n", "utf8");
}

export default function probe(pi: ExtensionAPI) {
	pi.on("session_start", (event) => {
		log(`session_start: reason=${event.reason}`);
	});
	pi.on("session_shutdown", (event) => {
		log(`session_shutdown: reason=${event.reason}`);
	});
	pi.on("context", (event) => {
		let found = false;
		for (const msg of event.messages) {
			const text = typeof msg.content === "string" ? msg.content : JSON.stringify(msg.content);
			if (text.includes("[todo]")) {
				log(`context: HAS_TODO: ${text}`);
				found = true;
			}
		}
		if (!found) {
			log("context: NO_TODO");
		}
	});
}
]=],
            probe_log_path
        )
        local f_probe = assert(io.open(probe_ext_path, "w"))
        f_probe:write(probe_code)
        f_probe:close()

        -- Write seed session file
        local seed_jsonl = table.concat({
            string.format(
                '{"type":"session","version":3,"id":"seed-todo-e2e","timestamp":"2025-01-01T00:00:00.000Z","cwd":%q}',
                temp_dir
            ),
            '{"type":"message","id":"msg-seed-user","parentId":null,"timestamp":"2025-01-01T00:00:01.000Z","message":{"role":"user","content":"Initial prompt","timestamp":1735689601000}}',
            '{"type":"message","id":"msg-seed-asst","parentId":"msg-seed-user","timestamp":"2025-01-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call-seed-1","name":"todo_write","arguments":{"todos":[{"content":"Seed task 1","status":"in_progress","activeForm":"Seeding task 1"}]}}],"usage":{"input":10,"output":10,"totalTokens":20},"timestamp":1735689602000}}',
            '{"type":"message","id":"msg-seed-tool","parentId":"msg-seed-asst","timestamp":"2025-01-01T00:00:03.000Z","message":{"role":"toolResult","toolCallId":"call-seed-1","toolName":"todo_write","content":[{"type":"text","text":"Todos updated (0/1 completed).\\n◐ Seeding task 1"}],"details":{"todos":[{"content":"Seed task 1","status":"in_progress","activeForm":"Seeding task 1"}]},"timestamp":1735689603000}}',
            "",
        }, "\n")
        local f_seed = assert(io.open(seed_session_path, "w"))
        f_seed:write(seed_jsonl)
        f_seed:close()

        step("S2 spawn pi --mode rpc with seed session")
        local env_map = vim.fn.environ()
        if not env_map.PI_PROVIDER then
            env_map.PI_PROVIDER = "cliproxyapi"
        end
        if not env_map.PI_MODEL then
            env_map.PI_MODEL = "deepseek-flash"
        end

        local cmd = {
            "pi",
            "--mode",
            "rpc",
            "--session",
            seed_session_path,
            "-e",
            todo_ext_path,
            "-e",
            probe_ext_path,
            "--no-mcp",
            "--no-skills",
        }

        local rpc_events = {}
        local stdout_parts = {}
        local stderr_lines = {}

        local function dispatch_line(line)
            local ok_json, parsed = pcall(vim.json.decode, line)
            if ok_json and type(parsed) == "table" then
                table.insert(rpc_events, parsed)
            end
        end

        job_id = vim.fn.jobstart(cmd, {
            cwd = temp_dir,
            env = env_map,
            on_stdout = function(_, data)
                if not data then
                    return
                end
                if #data == 1 then
                    if data[1] ~= "" then
                        stdout_parts[#stdout_parts + 1] = data[1]
                    end
                    return
                end
                stdout_parts[#stdout_parts + 1] = data[1]
                local line = table.concat(stdout_parts)
                stdout_parts = { data[#data] }
                if line ~= "" then
                    dispatch_line(line)
                end
                for i = 2, #data - 1 do
                    if data[i] ~= "" then
                        dispatch_line(data[i])
                    end
                end
            end,
            on_stderr = function(_, data)
                if data then
                    for _, l in ipairs(data) do
                        if l ~= "" then
                            table.insert(stderr_lines, l)
                        end
                    end
                end
            end,
        })
        check(type(job_id) == "number" and job_id > 0, "failed to start pi job", { job_id = job_id })

        local function send_rpc(msg)
            local payload = vim.json.encode(msg) .. "\n"
            local res = vim.fn.chansend(job_id, payload)
            check(res > 0, "failed to send RPC message", { msg = msg })
        end

        local function wait_for_settled(timeout_ms)
            local start_count = 0
            for _, ev in ipairs(rpc_events) do
                if ev.type == "agent_settled" then
                    start_count = start_count + 1
                end
            end
            local settled = vim.wait(timeout_ms, function()
                local count = 0
                for _, ev in ipairs(rpc_events) do
                    if ev.type == "agent_settled" then
                        count = count + 1
                    end
                end
                return count > start_count
            end, 100)
            return settled
        end

        local function wait_for_rpc_response(cmd_name, timeout_ms)
            return vim.wait(timeout_ms, function()
                for _, ev in ipairs(rpc_events) do
                    if ev.type == "response" and ev.command == cmd_name then
                        return true
                    end
                end
                return false
            end, 100)
        end

        step("S3 send initial prompt to resumed session")
        send_rpc({ type = "prompt", message = "reply with the single word OK" })

        local settled_1 = wait_for_settled(45000)
        if not settled_1 then
            local all_err = table.concat(stderr_lines, "\n")
            if is_rate_limit(all_err) then
                print("SKIP: provider rate limited or unavailable: " .. all_err)
                return "SKIP"
            end
            check(false, "S3: prompt 1 never settled within 45s", {
                stderr = stderr_lines,
                events = rpc_events,
            })
        end

        step("S4 assert probe logged HAS_TODO for resumed session")
        local log_content_1 = read_file(probe_log_path) or ""
        check(
            log_content_1:find("context: HAS_TODO:", 1, true) ~= nil,
            "S4: probe must log HAS_TODO in the initial resumed session",
            { log = log_content_1 }
        )

        step("S5 send new_session RPC")
        send_rpc({ type = "new_session" })
        local new_sess_ok = wait_for_rpc_response("new_session", 15000)
        check(new_sess_ok, "S5: new_session response never arrived within 15s")

        -- Wait briefly for session_start(reason=new) in probe log
        local got_new_session_start = vim.wait(5000, function()
            local c = read_file(probe_log_path) or ""
            return c:find("session_start: reason=new", 1, true) ~= nil
        end, 100)
        check(got_new_session_start, "S5: probe must log session_start: reason=new after /new")

        step("S6 send second prompt to fresh session")
        local log_pos_before_prompt_2 = #(read_file(probe_log_path) or "")
        send_rpc({ type = "prompt", message = "reply with the single word OK" })

        local settled_2 = wait_for_settled(45000)
        if not settled_2 then
            local all_err = table.concat(stderr_lines, "\n")
            if is_rate_limit(all_err) then
                print("SKIP: provider rate limited or unavailable: " .. all_err)
                return "SKIP"
            end
            check(false, "S6: prompt 2 never settled within 45s", {
                stderr = stderr_lines,
                events = rpc_events,
            })
        end

        step("S7 assert probe logged NO_TODO in fresh session")
        local log_content_full = read_file(probe_log_path) or ""
        local log_after_new = log_content_full:sub(log_pos_before_prompt_2 + 1)

        check(
            log_after_new:find("context: NO_TODO", 1, true) ~= nil,
            "S7: probe must log NO_TODO in the fresh session",
            { log_after_new = log_after_new, full_log = log_content_full }
        )
        check(
            log_after_new:find("context: HAS_TODO:", 1, true) == nil,
            "S7: probe must NOT log HAS_TODO in the fresh session (the fix)",
            { log_after_new = log_after_new }
        )

        step("S8 assert pi process is still alive")
        local is_dead = vim.fn.jobwait({ job_id }, 0)[1] ~= -1
        check(not is_dead, "S8: pi process unexpectedly died after new_session and prompt 2")
        print("  [note] title.ts stale-ctx guard verified via code inspection / process survival")

        return "PASS"
    end)

    cleanup()

    local elapsed = (uv.hrtime() - run_started) / 1e9
    if not ok then
        print(string.format("FAIL: %s (after %.2fs)", tostring(run_err), elapsed))
        os.exit(1)
    end

    if run_err == "SKIP" then
        os.exit(0)
    end

    print(string.format("PASS: todo_new_session e2e OK (in %.2fs)", elapsed))
    os.exit(0)
end

main()
