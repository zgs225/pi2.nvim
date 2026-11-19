/**
 * Background bash tasks + first-class waiting for pi.nvim.
 *
 * pi core deliberately has no background bash. This extension fills the gap by
 * OVERRIDING the built-in `bash` tool (extension tools with the same name win —
 * agent-session _refreshToolRegistry writes extension definitions over the
 * builtin Map entries) and adding two extras: an optional `run_in_background`
 * parameter and a companion `wait_task` tool.
 *
 * Both paths share ONE spawn routine (`startTask`): the process is spawned
 * detached and unref'd, stdout/stderr stream into
 * `join(tmpdir(), "pi-bash-<taskId>.log")` — the same naming convention core
 * uses for truncated-output spill files. What differs is only the ATTACH
 * policy:
 *
 *  - `run_in_background: true` — return immediately with the task id.
 *  - foreground (default) — stay attached for the attach window (`timeout`,
 *    default DEFAULT_ATTACH_MS). If the process exits inside the window the
 *    call returns its output like a normal bash call. If it outlives the
 *    window it is NOT killed (P0-2): it keeps running as a background task and
 *    the call returns "[still running]" plus the task id. This is the one
 *    semantic difference from stock pi, whose bash kills on timeout.
 *
 * Waiting model (P0-3). A completion is reported to the model through exactly
 * one of two channels, never both (see `attachWait`'s observer lease):
 *
 *  - the tool result of a call that was attached when the process exited
 *    (a foreground call that finished inside its window, or `wait_task`), or
 *  - the wake report — a `pi2_bg_task` custom message carrying the exit status,
 *    sent when the process exits with nobody attached.
 *
 * Delivery ladder (why it is four stages instead of one `sendMessage`). A
 * steering message is discarded when the run is aborted, so a report sent that
 * way can vanish with no trace; a `delivered` flag set at send time then hides
 * the loss from the fallback. Instead a report walks through
 * `none -> sent -> confirmed`, and only `confirmed` stops further delivery:
 *
 *  1. idle at exit -> `sendMessage(..., { triggerTurn: true })` starts a turn
 *     immediately (the completion is the only thing left to do);
 *  2. a run is active -> the next actionable boundary (`turn_end`, then
 *     `agent_before_settle`) appends ONE aggregated `custom_message` entry and
 *     asks for `continue: true`, so the model acts on it in this run. Entries
 *     are committed even when the turn ends in an abort (verified), unlike a
 *     steering queue, and `continue` is suppressed for an aborted turn so an
 *     abort still ends the run;
 *  3. `context` is the ground-truth receipt and the last resort: the exact text
 *     handed over is searched for in the message list about to be sent, which
 *     confirms it, and anything still missing is injected before that request.
 *     This is what makes an aborted run cost nothing — the report survives in
 *     the transcript (stage 2) and is injected on the next turn (stage 3);
 *  4. `agent_settled` (with `aborted !== true`) flushes reports that finished
 *     after the last boundary, because nothing else would wake the agent.
 *
 * An `agent_settled` for an aborted run deliberately wakes nothing (the user
 * asked for the run to stop); the report waits for stage 3.
 *
 * The wake report is why `sleep` must never be the model's waiting primitive:
 * it is delivered mid-run at the next turn boundary, so a model that has other
 * work to do loses nothing by continuing, and a model with nothing left to do
 * only has to end its turn. `wait_task` covers the third case — the model wants
 * the result before it can say anything else — by blocking server-side until
 * the process exits or its own deadline hits. Both are advertised in the bash
 * tool description and in every result that starts or hands off a task.
 *
 * `stop_task` / `list_tasks` make the task table usable by the model, not only by
 * the panel: a task nobody wants any more (a stale dev server holding its port, a
 * watcher for a file that is already fixed) is stopped through the same
 * process-GROUP signal the panel's `x` uses, and `list_tasks` recovers an id the
 * model no longer has in front of it. Both go through the same observer lease,
 * so the exit a stop causes is reported by the stop's own tool result instead of
 * arriving later as a wake for a result nobody asked for.
 *
 * A background task keeps its STDIN OPEN (P0-3), and `task_input` writes to it.
 * `stdio: ["ignore", …]` — stock pi's answer — means a command that asks a
 * question gets EOF instead of an answer: an interactive tool (`npm init`, a
 * prompt, a REPL, anything waiting on a TTY-less read) either aborts or blocks
 * forever, which is exactly the "never exits, never notifies" hole. Only the
 * background paths get a pipe: a foreground command keeps `ignore`, so its
 * behaviour is byte-for-byte stock, and a foreground command that outlives its
 * window and detaches has no stdin (`task_input` says so instead of silently
 * dropping what it was given).
 *
 * The task table OUTLIVES the process that built it (P0-1). Every state change
 * snapshots it to `join(tmpdir(), "pi-bash-tasks-<sessionId>.json")`, and the
 * next instance — a `/reload`, or a resumed session after a crash — reconciles
 * against that file on `session_start`: records that are already terminal are
 * restored as terminal (their report was delivered by a process that is gone),
 * and a record still marked running is ADOPTED when its pid is alive and still
 * runs the same command, so `wait_task` / `stop_task` / `list_tasks` keep
 * working on a task nobody remembers starting. Adoption polls the pid (a
 * record written by a dead process has no exit event left to fire) and reports
 * the exit with an honest "status unknown" when the process disappears. The
 * pid is verified against `ps` first, because a recorded pid can be recycled by
 * an unrelated process between the crash and the reconcile — signalling or
 * waiting on that one would be worse than forgetting the task. One summary
 * message tells the model what was found, so a reload does not cost it the
 * knowledge of what is still running; `list_tasks` remains the authoritative
 * view either way.
 *
 * Panel reporting is separate from the wake path and never triggers a turn:
 * the frontend (`:PiTasks`) needs the exit status even when a tool call already
 * consumed the result, so `started` / terminal events are pushed as
 * `display: false` custom messages with no options. They are only pushed for
 * tasks that actually become background tasks — a foreground command that
 * finishes inside its window never touches the panel.
 *
 * A load-time `context` handler is the fallback injector for wake reports whose
 * send threw (stale extension ctx); it reads the module-level task table and
 * marks deliveries so nothing is injected twice.
 *
 * A process.on("exit") hook SIGKILLs every tracked process group best-effort,
 * mirroring core's killTrackedDetachedChildren (that helper is not exported
 * from the package root, so we track pids ourselves).
 *
 * Also handles the `user_bash` event: a leading `&` token on an interactive
 * `!`-prefixed command routes to the same background path and returns a
 * BashResult immediately (rpc-mode asks extensions before executing).
 *
 * NOTE(verify): background and foreground spawns both build their env from
 * `buildSessionEnv`, which approximates core's resolveSpawnContext (parent env,
 * stale PI_* dropped, current session metadata exposed, exec bin dir prepended
 * to PATH). A custom `shellPath` from settings.json is still invisible to us —
 * shell resolution goes through the exported getShellConfig().
 * NOTE(verify): custom messages reach the LLM regardless of `display:false`
 * (convertToLlm maps role "custom" to user). Keep message content LLM-safe.
 */

import type { ExtensionAPI, ExtensionContext, UserBashEventResult } from "@earendil-works/pi-coding-agent";
import { createBashToolDefinition, getShellConfig } from "@earendil-works/pi-coding-agent";
import type { BashToolDetails, BashToolInput, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
	closeSync,
	createWriteStream,
	openSync,
	readFileSync,
	readSync,
	renameSync,
	statSync,
	unlinkSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { Writable } from "node:stream";
import { Type, type Static, type TSchema } from "typebox";

const CUSTOM_TYPE = "pi2_bg_task";
const BACKGROUND_PREFIX = "&";

/** Foreground attach window when the model passes no `timeout`. */
const DEFAULT_ATTACH_MS = 120_000;
/** Bounds for the foreground attach window (model-supplied `timeout`). */
const MIN_ATTACH_MS = 1_000;
const MAX_ATTACH_MS = 600_000;
/** `wait_task` bounds. */
const DEFAULT_WAIT_MS = 120_000;
const MIN_WAIT_MS = 1_000;
const MAX_WAIT_MS = 1_800_000;
/** `stop_task` bounds: SIGTERM grace before SIGKILL, and the settle after it. */
const DEFAULT_STOP_GRACE_MS = 5_000;
const MIN_STOP_GRACE_MS = 500;
const MAX_STOP_GRACE_MS = 30_000;
const STOP_KILL_SETTLE_MS = 5_000;
/** `list_tasks` output cap (a long-lived process accumulates tasks). */
const MAX_LISTED_TASKS = 40;
/** Longest command quoted in a `list_tasks` row. */
const LISTED_COMMAND_WIDTH = 120;
/**
 * Task-table persistence. The snapshot is debounced (a burst of starts and
 * exits must not rewrite the file per event) and bounded (the table grows for
 * the life of the process).
 */
const TASK_FILE_PREFIX = "pi-bash-tasks-";
const TASK_FILE_VERSION = 1;
const PERSIST_DEBOUNCE_MS = 250;
const MAX_PERSISTED_TASKS = 60;
/**
 * How long a record may sit in the file before it is no longer adopted. A pid
 * recycled after a day is far more likely to belong to something else, and an
 * adopted task only exists to keep `wait_task`/`stop_task` usable across a
 * reload or a crash.
 */
const MAX_ADOPT_AGE_MS = 24 * 60 * 60 * 1000;
/** Liveness poll interval for an adopted task (there is no `close` event left). */
const ADOPT_POLL_MS = 1_000;
/** Model-facing output cap per call (matches pi's built-in bash). */
const MAX_OUTPUT_BYTES = 50 * 1024;
const MAX_OUTPUT_LINES = 2000;
/** Live (`onUpdate`) view: bounded so the RPC stream stays cheap. */
const LIVE_TAIL_LINES = 200;
const LIVE_TAIL_BYTES = 8 * 1024;
/** Minimum interval between live updates. */
const UPDATE_INTERVAL_MS = 500;
/** Line count is only computed when the log is small enough to read whole. */
const COUNT_LINES_UP_TO_BYTES = 8 * 1024 * 1024;
/** Bound on the output tail inlined in a wake report. */
const WAKE_TAIL_LINES = 40;
const WAKE_TAIL_BYTES = 4 * 1024;
/**
 * Grace window for an idle wake: a message sent this recently may still be on
 * its way into context, so the `context` fallback waits one boundary before
 * concluding it was dropped. Only applies to the `wake` channel — boundary
 * entries are durable and are read from context on the very next request.
 */
const IDLE_WAKE_GRACE_MS = 5_000;

/** How far a completion report has got on its way into model context. */
type DeliveryState = "none" | "sent" | "confirmed";
/** Channel that carried a report's text. */
type DeliveryChannel = "boundary" | "wake" | "fallback" | "tool-result";

/** Payload of the display:false custom messages the frontend (pi.nvim) receives. */
interface BgTaskDetails {
	kind: "started" | "completed" | "failed" | "stopped";
	taskId: string;
	command: string;
	pid?: number;
	outputFile: string;
	exitCode?: number | null;
	signal?: string | null;
	/**
	 * When the process actually started (epoch ms). The message that carries
	 * this is stamped when it is SENT, so an adopted task — one whose process
	 * started minutes ago, in another pi process — would otherwise be rendered
	 * as if it had just started.
	 */
	startedAt?: number;
}

/** Module-level task table; read by the context handler and the renderers. */
interface BgTaskState {
	taskId: string;
	command: string;
	cwd: string;
	outputFile: string;
	startedAt: number;
	endedAt?: number;
	pid?: number;
	completed: boolean;
	exitCode: number | null;
	signal: string | null;
	spawnError?: string;
	/** Whether a "started" event was pushed to the frontend panel. */
	panelStarted: boolean;
	/**
	 * Number of attached tool calls that will return this task's terminal
	 * state themselves. While > 0 at exit time the wake report is suppressed
	 * and the result is delivered by the attached call instead.
	 */
	observers: number;
	/**
	 * Report delivery progress. `none` = never handed to a channel, `sent` =
	 * handed over but not observed in model context yet, `confirmed` = seen in
	 * a `context` message list (or carried by a tool result). Only `none` tasks
	 * are candidates for a new channel, so a report is never delivered twice
	 * while its first attempt may still land.
	 */
	delivery: DeliveryState;
	/** Exact text handed to the channel, matched against `context` messages. */
	sentText?: string;
	/** When `sentText` was handed over (ms), for the idle-wake grace window. */
	sentAt?: number;
	/** Which channel carried `sentText`. */
	sentVia?: DeliveryChannel;
	/**
	 * Whether this record was rebuilt from a snapshot written by an earlier pi
	 * process (a `/reload`, or a resume after a crash). An adopted task has no
	 * `ChildProcess` behind it, so its exit is discovered by polling and its
	 * status can be genuinely unknown.
	 */
	adopted?: boolean;
	/** The process is gone but nobody saw it exit, so the status is unknowable. */
	exitUnknown?: boolean;
	/** Liveness poll for an adopted task; cleared when the task settles. */
	adoptPoll?: ReturnType<typeof setInterval>;
	/**
	 * The child's stdin pipe. Only background paths get one (a foreground command
	 * keeps stock behaviour, where stdin is ignored); an adopted task never has
	 * one, because the pipe died with the process that owned it.
	 */
	stdin?: Writable;
	/** Whether that pipe can still be written to. */
	stdinOpen: boolean;
	/** Resolves exactly once, when the process closes or spawn fails. */
	exited: Promise<void>;
	resolveExited: () => void;
}

/**
 * The durable half of a task record — what a later pi process needs to rebuild
 * the table. Runtime bookkeeping (`delivery`, `observers`, promises) is
 * deliberately absent: delivery state belongs to the process that had the
 * report, and a restored record is never re-delivered.
 */
interface PersistedTask {
	taskId: string;
	command: string;
	cwd: string;
	outputFile: string;
	startedAt: number;
	endedAt?: number;
	pid?: number;
	completed: boolean;
	exitCode: number | null;
	signal: string | null;
	exitUnknown?: boolean;
	spawnError?: string;
}

const tasks = new Map<string, BgTaskState>();
/** Background process groups to kill best-effort when the pi process exits. */
const trackedPids = new Set<number>();
let exitHookInstalled = false;
/**
 * Session whose snapshot file this process writes. Set on `session_start`; the
 * file is per session (not per process) so a resume finds what a crash left.
 */
let currentSessionId: string | undefined;
let persistTimer: ReturnType<typeof setTimeout> | undefined;

function taskFilePath(sessionId: string): string {
	return join(tmpdir(), `${TASK_FILE_PREFIX}${sessionId}.json`);
}

function serializeTask(task: BgTaskState): PersistedTask {
	const record: PersistedTask = {
		taskId: task.taskId,
		command: task.command,
		cwd: task.cwd,
		outputFile: task.outputFile,
		startedAt: task.startedAt,
		completed: task.completed,
		exitCode: task.exitCode,
		signal: task.signal,
	};
	if (task.endedAt !== undefined) {
		record.endedAt = task.endedAt;
	}
	if (task.pid !== undefined) {
		record.pid = task.pid;
	}
	if (task.exitUnknown) {
		record.exitUnknown = true;
	}
	if (task.spawnError !== undefined) {
		record.spawnError = task.spawnError;
	}
	return record;
}

/**
 * Write the snapshot NOW. Synchronous on purpose: the exit hook and
 * `session_shutdown` run when there is no later turn of the event loop to be
 * called back on. Never throws — a read-only tmpdir must not break a session.
 */
function persistNow(): void {
	if (persistTimer) {
		clearTimeout(persistTimer);
		persistTimer = undefined;
	}
	const sessionId = currentSessionId;
	if (!sessionId) {
		return;
	}
	const file = taskFilePath(sessionId);
	const records = [...tasks.values()]
		.sort((a, b) => b.startedAt - a.startedAt)
		.slice(0, MAX_PERSISTED_TASKS)
		.map(serializeTask);
	const body = JSON.stringify({
		version: TASK_FILE_VERSION,
		sessionId,
		updatedAt: Date.now(),
		tasks: records,
	});
	try {
		const temporary = `${file}.tmp`;
		writeFileSync(temporary, body, { mode: 0o600 });
		// Rename rather than write in place: a process killed mid-write must leave
		// the previous snapshot intact, not half of a new one.
		renameSync(temporary, file);
	} catch {
		// Best effort: the task table is runtime state, the file only a hint for
		// the next process. `list_tasks` still answers within this one.
	}
}

/** Coalesce a burst of state changes into one snapshot write. */
function schedulePersist(): void {
	if (persistTimer) {
		return;
	}
	persistTimer = setTimeout(() => {
		persistTimer = undefined;
		persistNow();
	}, PERSIST_DEBOUNCE_MS);
	// A pending snapshot must not keep the process alive on its own.
	persistTimer.unref?.();
}

function isPersistedTask(value: unknown): value is PersistedTask {
	if (value === null || typeof value !== "object") {
		return false;
	}
	const record = value as Partial<PersistedTask>;
	return (
		typeof record.taskId === "string" &&
		/^b[0-9a-f]+$/.test(record.taskId) &&
		typeof record.command === "string" &&
		typeof record.cwd === "string" &&
		typeof record.outputFile === "string" &&
		typeof record.startedAt === "number" &&
		typeof record.completed === "boolean"
	);
}

/**
 * Read the snapshot a previous process left for this session. Anything that does
 * not look like one of our records is dropped rather than trusted: this file
 * lives in the world-writable temp dir.
 */
function readPersistedTasks(sessionId: string): PersistedTask[] {
	let raw: string;
	try {
		raw = readFileSync(taskFilePath(sessionId), "utf8");
	} catch {
		return [];
	}
	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch {
		return [];
	}
	const body = parsed as { version?: unknown; tasks?: unknown };
	if (body?.version !== TASK_FILE_VERSION || !Array.isArray(body.tasks)) {
		return [];
	}
	const scratch = tmpdir();
	return body.tasks
		.filter(isPersistedTask)
		// Only our own log directory: a tampered path must not become a file the
		// model is told to read.
		.filter((record) => record.outputFile.startsWith(scratch))
		.sort((a, b) => b.startedAt - a.startedAt)
		.slice(0, MAX_PERSISTED_TASKS);
}

/** Whether a pid is still in the process table (EPERM means alive, not ours). */
function pidAlive(pid: number): boolean {
	if (!Number.isInteger(pid) || pid <= 1) {
		return false;
	}
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}

/**
 * Whether a live pid still runs the command it was recorded with.
 *
 * A pid recorded by a dead process can be recycled by anything, and acting on
 * the new owner (a SIGKILL from `stop_task`, a `wait_task` that never settles)
 * is worse than admitting the record is stale. `ps` is the portable-enough
 * check: every task is spawned through a shell, so the command's first token
 * appears in the process's command line for both `shell -c "npm run dev"` and
 * the exec'd form `node …/npm run dev`.
 */
function pidMatchesCommand(pid: number, command: string): boolean {
	const first = command.trim().split(/\s+/)[0] ?? "";
	if (first === "") {
		return false;
	}
	try {
		const out = execFileSync("ps", ["-o", "command=", "-p", String(pid)], {
			encoding: "utf8",
			timeout: 2_000,
			stdio: ["ignore", "pipe", "ignore"],
		});
		return out.includes(first);
	} catch {
		// No `ps`, or the pid is gone: do not adopt.
		return false;
	}
}
/**
 * Whether an agent run is active. `turn_end` / `agent_before_settle` fire while
 * it is true, so a completion only needs the idle wake when it is false. Kept
 * here (not read from a ctx) because the exit callbacks run outside any event.
 */
let busy = false;

/**
 * Signal a detached process group, falling back to the bare pid.
 *
 * Every task is spawned `detached: true`, so its pid is also its process-group
 * id and its children — `node` under `npm`, the compiler under `make`, each
 * stage of a pipeline — belong to that group. Signalling the group is the only
 * way to stop what was actually started: a bare-pid signal kills the shell and
 * leaves the children running, holding the port.
 *
 * Returns whether a signal was delivered. The fallback covers a pid whose group
 * is gone (a task inherited from a pi process that already exited).
 */
function signalProcessGroup(pid: number, signal: NodeJS.Signals): boolean {
	if (!Number.isInteger(pid) || pid <= 1) {
		return false;
	}
	try {
		process.kill(-pid, signal);
		return true;
	} catch {
		try {
			process.kill(pid, signal);
			return true;
		} catch {
			return false;
		}
	}
}

/** Kill a detached process group, falling back to the pid alone. */
function killProcessGroup(pid: number): void {
	signalProcessGroup(pid, "SIGKILL");
}

function ensureExitHook(): void {
	if (exitHookInstalled) {
		return;
	}
	exitHookInstalled = true;
	process.on("exit", () => {
		// The kill below is the last thing that will ever happen to these tasks,
		// and their `close` events will never run: record the terminal state we
		// are imposing, or the next process would adopt a corpse as "running".
		const now = Date.now();
		for (const task of tasks.values()) {
			if (!task.completed && task.pid !== undefined && trackedPids.has(task.pid)) {
				task.completed = true;
				task.endedAt = now;
				task.signal = "SIGKILL";
				task.exitCode = null;
			}
		}
		for (const pid of trackedPids) {
			killProcessGroup(pid);
		}
		// Synchronous: the event loop is over, a debounced write would never run.
		persistNow();
	});
}

function formatSeconds(ms: number): string {
	return `${(ms / 1000).toFixed(ms < 10_000 ? 1 : 0)}s`;
}

/** Human/agent-facing exit summary for one task. */
function describeExit(task: BgTaskState): string {
	if (task.spawnError) {
		return `failed to start: ${task.spawnError}`;
	}
	if (task.exitUnknown) {
		return "is no longer running (its exit status is unknown: it was started by an earlier pi process)";
	}
	if (task.signal !== null) {
		return `was stopped (signal ${task.signal})`;
	}
	return `exited with code ${task.exitCode}`;
}

/**
 * Completion report text for the wake path. Shared by sendMessage and the
 * context fallback so the agent sees exactly the same text either way.
 *
 * The "[SYSTEM NOTIFICATION ...]" banner exists for the same reason Claude
 * Code added it: this lands in the agent's context as a user-role message, and
 * without the banner models read it as human input (and sometimes as approval
 * for whatever they proposed before going quiet).
 */
function buildWakeNote(task: BgTaskState): string {
	const elapsed = formatSeconds((task.endedAt ?? Date.now()) - task.startedAt);
	const head = `[SYSTEM NOTIFICATION - NOT USER INPUT]\n[Background task ${task.taskId} ("${task.command}") ${describeExit(task)} after ${elapsed}. Output: ${task.outputFile}]`;
	const tail = readOutputTail(task.outputFile, WAKE_TAIL_BYTES, WAKE_TAIL_LINES);
	if (!tail.text.trim()) {
		return `${head}\nThis is an automated task notification, not a message from the user. Nothing was waiting on it, so no tool result carried the output: read the file above (or call wait_task on the task id) if you need more than this summary.`;
	}
	return `${head}\nThis is an automated task notification, not a message from the user. Output tail:\n\n${tail.text}`;
}

/**
 * One report for every task that finished since the last flush.
 *
 * A single task keeps the full wake note (status + output tail). Several tasks
 * share ONE message with the status lines only: a burst of completions must not
 * push N × 4 KB of tails into context, and the model can read the files (or
 * call `wait_task` on any id) when it actually needs the output. This mirrors
 * what the other frontends do — push a signal, let the reader pull the detail.
 */
function buildBatchNote(batch: BgTaskState[]): string {
	if (batch.length === 1) {
		return buildWakeNote(batch[0]);
	}
	const lines = batch.map((task) => {
		const elapsed = formatSeconds((task.endedAt ?? Date.now()) - task.startedAt);
		return `- ${task.taskId} ("${task.command}") ${describeExit(task)} after ${elapsed}. Output: ${task.outputFile}`;
	});
	return (
		`[SYSTEM NOTIFICATION - NOT USER INPUT]\n[Background tasks: ${batch.length} finished]\n${lines.join("\n")}\n` +
		"This is an automated task notification, not a message from the user. Output tails are omitted for a batched report: read the files above (or call wait_task on a task id) if you need the output."
	);
}

/**
 * Plain text of a message in a `context` payload, for receipt matching. Custom
 * messages map to a user-role message whose content is the string that was
 * sent; user/tool messages carry a content-part array.
 */
function messageText(message: unknown): string | undefined {
	const content = (message as { content?: unknown } | null | undefined)?.content;
	if (typeof content === "string") {
		return content;
	}
	if (Array.isArray(content)) {
		return content
			.map((part) =>
				part !== null && typeof part === "object" && (part as { type?: string }).type === "text"
					? String((part as { text?: unknown }).text ?? "")
					: "",
			)
			.join("");
	}
	return undefined;
}

/**
 * Session env for spawns — mirrors core's resolveSpawnContext: start from the
 * parent env minus stale PI_* session variables, expose the current session
 * metadata when a tool ctx is available, and prepend pi's own bin directory to
 * PATH (core calls the same idea getShellEnv(); it is not exported, so derive
 * the directory from process.execPath).
 */
function buildSessionEnv(ctx: ExtensionContext | undefined): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = { ...process.env };
	delete env.PI_SESSION_ID;
	delete env.PI_SESSION_FILE;
	delete env.PI_PROVIDER;
	delete env.PI_MODEL;
	delete env.PI_REASONING_LEVEL;
	const binDir = dirname(process.execPath ?? "");
	if (binDir && binDir !== ".") {
		env.PATH = `${binDir}:${env.PATH ?? ""}`;
	}
	if (ctx?.sessionManager) {
		env.PI_SESSION_ID = ctx.sessionManager.getSessionId();
		const sessionFile = ctx.sessionManager.getSessionFile();
		if (sessionFile) {
			env.PI_SESSION_FILE = sessionFile;
		}
		if (ctx.model) {
			env.PI_PROVIDER = ctx.model.provider;
			env.PI_MODEL = ctx.model.id;
		}
		if (ctx.thinkingLevel) {
			env.PI_REASONING_LEVEL = ctx.thinkingLevel;
		}
	}
	return env;
}

interface OutputTail {
	text: string;
	/** Total lines in the file when it was cheap to count them, else undefined. */
	totalLines?: number;
	truncated: boolean;
}

/**
 * Read the tail of a task log, bounded by both bytes and lines, with pi's
 * built-in bash footer when anything was dropped. Never throws: a missing or
 * unreadable log yields empty text (the file is best-effort scratch space).
 */
function readOutputTail(file: string, maxBytes: number, maxLines: number): OutputTail {
	let size: number;
	try {
		size = statSync(file).size;
	} catch {
		return { text: "", truncated: false };
	}
	if (size === 0) {
		return { text: "", totalLines: 0, truncated: false };
	}
	// Only ever read a bounded window off the end: a chatty watcher can write
	// gigabytes, and this runs on every live update tick. The window is wider
	// than the cap so a byte-limited tail can still be trimmed to whole lines.
	const headroom = Math.max(maxBytes * 4, 64 * 1024);
	const windowBytes = Math.min(size, headroom);
	const offset = size - windowBytes;
	const buffer = Buffer.allocUnsafe(windowBytes);
	let fd: number | undefined;
	try {
		fd = openSync(file, "r");
		readSync(fd, buffer, 0, windowBytes, offset);
	} catch {
		return { text: "", truncated: false };
	} finally {
		if (fd !== undefined) {
			closeSync(fd);
		}
	}

	let raw = buffer.toString("utf8");
	if (offset > 0) {
		// The window starts mid-line: drop that partial first line.
		const firstBreak = raw.indexOf("\n");
		raw = firstBreak >= 0 ? raw.slice(firstBreak + 1) : raw;
	}
	const lines = raw.split("\n");
	// A trailing newline produces one empty final element; it is not a line.
	if (lines.length > 0 && lines[lines.length - 1] === "") {
		lines.pop();
	}
	// Line numbers in the footer need a real count, which is only affordable
	// when the window covered the whole file and the file is small.
	const totalLines = offset === 0 && size <= COUNT_LINES_UP_TO_BYTES ? lines.length : undefined;

	let kept = lines;
	if (kept.length > maxLines) {
		kept = kept.slice(kept.length - maxLines);
	}
	let text = kept.join("\n");
	let droppedLines = lines.length - kept.length;
	if (Buffer.byteLength(text, "utf8") > maxBytes) {
		// Byte cap: keep the newest whole lines that fit.
		const out: string[] = [];
		let bytes = 0;
		for (let i = kept.length - 1; i >= 0; i--) {
			const cost = Buffer.byteLength(kept[i], "utf8") + 1;
			if (bytes + cost > maxBytes) {
				break;
			}
			bytes += cost;
			out.unshift(kept[i]);
		}
		droppedLines += kept.length - out.length;
		kept = out;
		text = kept.join("\n");
	}
	if (droppedLines <= 0) {
		return { text, totalLines, truncated: false };
	}
	const cap = `${(maxBytes / 1024).toFixed(1)}KB limit`;
	const footer =
		totalLines === undefined
			? `\n\n[Output truncated to the last ${formatBytes(maxBytes)}. Full output: ${file}]`
			: `\n\n[Showing lines ${totalLines - kept.length + 1}-${totalLines} of ${totalLines} (${cap}). Full output: ${file}]`;
	return { text: `${text}${footer}`, totalLines, truncated: true };
}

function formatBytes(bytes: number): string {
	return bytes >= 1024 * 1024 ? `${(bytes / (1024 * 1024)).toFixed(1)}MB` : `${(bytes / 1024).toFixed(1)}KB`;
}

function clampAttachWindow(timeout: number | undefined): number {
	if (typeof timeout !== "number" || !Number.isFinite(timeout) || timeout <= 0) {
		return DEFAULT_ATTACH_MS;
	}
	return Math.min(MAX_ATTACH_MS, Math.max(MIN_ATTACH_MS, Math.floor(timeout)));
}

function clampWaitWindow(timeout: number | undefined): number {
	if (typeof timeout !== "number" || !Number.isFinite(timeout) || timeout <= 0) {
		return DEFAULT_WAIT_MS;
	}
	return Math.min(MAX_WAIT_MS, Math.max(MIN_WAIT_MS, Math.floor(timeout)));
}

function clampStopGrace(timeout: number | undefined): number {
	if (typeof timeout !== "number" || !Number.isFinite(timeout) || timeout <= 0) {
		return DEFAULT_STOP_GRACE_MS;
	}
	return Math.min(MAX_STOP_GRACE_MS, Math.max(MIN_STOP_GRACE_MS, Math.floor(timeout)));
}

type WaitOutcome = "exited" | "deadline" | "aborted";

interface AttachOptions {
	deadlineMs: number;
	signal?: AbortSignal;
	/** When set, the live tail is pushed through it (throttled). */
	onUpdate?: (tail: string) => void;
}

/**
 * Attach a tool call to a task and settle on the first of: process exit, the
 * call's own deadline, or abort.
 *
 * The observer lease is what keeps completion delivery exactly-once: the
 * counter is incremented for the whole time this call is attached, and the
 * exit handler suppresses the wake report while it is > 0, because THIS call is
 * about to hand the terminal state back to the model. Releasing on a deadline
 * or abort re-arms the wake for a later exit. There is no polling: the promise
 * races the task's `exited` promise against a timer and the abort signal.
 */
function attachWait(task: BgTaskState, options: AttachOptions): Promise<WaitOutcome> {
	task.observers += 1;
	let released = false;
	const release = (): void => {
		if (!released) {
			released = true;
			task.observers = Math.max(0, task.observers - 1);
		}
	};

	return new Promise<WaitOutcome>((resolve) => {
		let settled = false;
		let lastSent = "";
		let timer: ReturnType<typeof setTimeout> | undefined;
		let ticker: ReturnType<typeof setInterval> | undefined;
		const onAbort = (): void => finish("aborted");

		function finish(outcome: WaitOutcome): void {
			if (settled) {
				return;
			}
			settled = true;
			if (timer) {
				clearTimeout(timer);
			}
			if (ticker) {
				clearInterval(ticker);
			}
			options.signal?.removeEventListener("abort", onAbort);
			release();
			resolve(outcome);
		}

		function pushLive(): void {
			const onUpdate = options.onUpdate;
			if (!onUpdate) {
				return;
			}
			const tail = readOutputTail(task.outputFile, LIVE_TAIL_BYTES, LIVE_TAIL_LINES).text;
			if (tail === lastSent) {
				return;
			}
			lastSent = tail;
			onUpdate(tail);
		}

		if (task.completed) {
			finish("exited");
			return;
		}
		if (options.signal?.aborted) {
			finish("aborted");
			return;
		}
		options.signal?.addEventListener("abort", onAbort);
		timer = setTimeout(() => finish("deadline"), options.deadlineMs);
		if (options.onUpdate) {
			ticker = setInterval(pushLive, UPDATE_INTERVAL_MS);
			pushLive();
		}
		void task.exited.then(() => finish("exited"));
	});
}

export default function bgTasks(pi: ExtensionAPI) {
	// ------------------------------------------------------------------
	// Reconciling with a previous pi process (P0-1). `session_start` fires for
	// every kind of start — including the one right after `/reload`, where the
	// processes are still running but their `ChildProcess` handles died with the
	// old module instance — so this is where a snapshot written earlier becomes
	// usable task records again.
	// ------------------------------------------------------------------
	/** Summary of what the snapshot contained, delivered once (not per request). */
	let startupNote: { text: string } | undefined;

	function restoreTask(record: PersistedTask): BgTaskState {
		let resolveExited = (): void => {};
		const exited = new Promise<void>((resolve) => {
			resolveExited = resolve;
		});
		const task: BgTaskState = {
			taskId: record.taskId,
			command: record.command,
			cwd: record.cwd,
			outputFile: record.outputFile,
			startedAt: record.startedAt,
			completed: record.completed,
			exitCode: record.exitCode ?? null,
			signal: record.signal ?? null,
			// A restored terminal record was reported by the process that owned it;
			// re-delivering that report now would be a stale wake. Its state is
			// visible through `list_tasks`, which is the authoritative view.
			delivery: record.completed ? "confirmed" : "none",
			panelStarted: false,
			observers: 0,
			adopted: true,
			exited,
			resolveExited: () => resolveExited(),
		};
		if (record.endedAt !== undefined) {
			task.endedAt = record.endedAt;
		}
		if (record.pid !== undefined) {
			task.pid = record.pid;
		}
		if (record.exitUnknown) {
			task.exitUnknown = true;
		}
		if (record.spawnError !== undefined) {
			task.spawnError = record.spawnError;
		}
		return task;
	}

	/**
	 * Poll an adopted task's pid: an adopted task has no `ChildProcess`
	 * (`close` event) left to fire, so its exit has to be discovered. Reported as
	 * an unknown status — nobody can know the code of a process that was reaped
	 * while no pi process was watching it.
	 */
	function watchAdopted(task: BgTaskState): void {
		const pid = task.pid;
		if (pid === undefined) {
			return;
		}
		const timer = setInterval(() => {
			if (task.completed) {
				clearInterval(timer);
				return;
			}
			if (pidAlive(pid)) {
				return;
			}
			clearInterval(timer);
			task.adoptPoll = undefined;
			// With a call attached, that call owns the account of the exit (it is
			// the one that signalled); only an unobserved disappearance is unknown.
			if (task.observers === 0) {
				task.exitUnknown = true;
			}
			finishTask(task, null, null);
		}, ADOPT_POLL_MS);
		timer.unref?.();
		task.adoptPoll = timer;
	}

	function reconcileSession(ctx: ExtensionContext): void {
		const sessionId = ctx.sessionManager.getSessionId();
		if (!sessionId || sessionId === currentSessionId) {
			return;
		}
		if (currentSessionId !== undefined) {
			// Switching sessions keeps the process-level tasks; flush them under the
			// session we are leaving before the writer moves to the new file.
			persistNow();
		}
		currentSessionId = sessionId;
		const records = readPersistedTasks(sessionId);
		if (records.length === 0) {
			return;
		}

		const now = Date.now();
		const rows: string[] = [];
		let adopted = 0;
		let restored = 0;
		let stale = 0;
		for (const record of records) {
			if (tasks.has(record.taskId)) {
				continue;
			}
			const task = restoreTask(record);
			tasks.set(task.taskId, task);
			const command = record.command.replace(/\s+/g, " ").trim();
			if (record.completed) {
				restored += 1;
				const span = formatSeconds((task.endedAt ?? task.startedAt) - task.startedAt);
				rows.push(`- ${task.taskId} ("${command}") ${describeExit(task)} after ${span}. Output: ${task.outputFile}`);
				continue;
			}
			const adoptable =
				record.pid !== undefined &&
				record.startedAt > now - MAX_ADOPT_AGE_MS &&
				pidAlive(record.pid) &&
				pidMatchesCommand(record.pid, record.command);
			if (!adoptable) {
				stale += 1;
				task.completed = true;
				task.exitUnknown = true;
				task.delivery = "confirmed";
				rows.push(
					`- ${task.taskId} ("${command}") was recorded as running, but pid ${record.pid ?? "?"} is gone or no longer runs it, so its exit status is unknown. Output: ${task.outputFile}`,
				);
				continue;
			}
			adopted += 1;
			task.adopted = true;
			watchAdopted(task);
			rows.push(
				`- ${task.taskId} ("${command}") is STILL RUNNING (pid ${record.pid}, started ${formatSeconds(now - record.startedAt)} ago). Output: ${task.outputFile}`,
			);
			// Give the human a panel row too: `x` must be able to stop a task that
			// outlived the process that started it.
			task.panelStarted = true;
			reportPanel(task);
		}
		if (rows.length === 0) {
			return;
		}

		const counts = [
			adopted > 0 ? `${adopted} still running` : "",
			restored > 0 ? `${restored} already finished` : "",
			stale > 0 ? `${stale} unverifiable` : "",
		].filter((part) => part !== "");
		const shown = rows.slice(0, MAX_LISTED_TASKS);
		const hidden =
			rows.length > shown.length ? `\n(${rows.length - shown.length} older record(s) not shown; list_tasks sees all of them.)` : "";
		startupNote = {
			text:
				`[SYSTEM NOTIFICATION - NOT USER INPUT]\n[Background bash tasks recorded by an earlier pi process in this session: ${rows.length} — ${counts.join(", ")}]\n` +
				`${shown.join("\n")}${hidden}\n` +
				"This is an automated startup report, not a message from the user. These tasks were started before this process: wait_task, stop_task and list_tasks work on them exactly as on a task you start now, and an adopted task's exit is reported when its pid disappears. The exit status of a task that vanished while no pi process was watching it is unknown. Do not start a second copy of something listed above as still running.",
		};
		try {
			pi.sendMessage({ customType: CUSTOM_TYPE, content: startupNote.text, display: false }, undefined);
		} catch {
			// Not deliverable yet: the `context` handler injects it before the first
			// request instead (the same fallback the wake reports use).
		}
		schedulePersist();
	}

	/**
	 * Push the startup summary into the request about to be sent, unless it is
	 * already there (the `sendMessage` on session_start landed). Exactly one of
	 * the two channels carries it.
	 */
	function applyStartupNote(event: { messages: unknown[] }): boolean {
		if (!startupNote) {
			return false;
		}
		const note = startupNote;
		startupNote = undefined;
		if (event.messages.some((message) => messageText(message) === note.text)) {
			return false;
		}
		event.messages.push({ role: "user", content: note.text, timestamp: Date.now() });
		return true;
	}

	pi.on("session_start", (_event, ctx) => {
		reconcileSession(ctx);
		return undefined;
	});

	pi.on("session_shutdown", () => {
		// The instance is going away. On `quit` the exit hook flushes again after
		// recording the kills it is about to issue; on `reload` the processes stay
		// alive and their records stay "running" for the replacement to adopt.
		persistNow();
		return undefined;
	});

	// ------------------------------------------------------------------
	// Delivery receipt + last-resort injector. `context` is the exact message
	// list about to be sent to the model, so it settles delivery truthfully:
	// the text we handed over earlier is either in there (confirmed) or it is
	// not (dropped by an abort, a discarded steering queue, or a stale extension
	// ctx — inject it now). Nothing is ever injected twice, because a task stops
	// being a candidate as soon as its text is observed. `event.messages` is a
	// deep copy; nothing here is persisted.
	// ------------------------------------------------------------------
	pi.on("context", (event) => {
		const injectedStartup = applyStartupNote(event);
		const outstanding = pendingReports();
		if (outstanding.length === 0) {
			return injectedStartup ? { messages: event.messages } : undefined;
		}
		const texts = new Set<string>();
		for (const message of event.messages) {
			const text = messageText(message);
			if (text !== undefined) {
				texts.add(text);
			}
		}
		const missing: BgTaskState[] = [];
		for (const task of outstanding) {
			if (task.sentText !== undefined && texts.has(task.sentText)) {
				markConfirmed(task);
				continue;
			}
			if (task.observers > 0) {
				// An attached tool call is about to return this terminal state
				// itself; injecting now would deliver it twice.
				continue;
			}
			if (
				task.delivery === "sent" &&
				task.sentVia === "wake" &&
				task.sentAt !== undefined &&
				Date.now() - task.sentAt < IDLE_WAKE_GRACE_MS
			) {
				// A wake sent a moment ago may still be landing; give it one
				// boundary before concluding it was dropped.
				continue;
			}
			missing.push(task);
		}
		if (missing.length === 0) {
			return undefined;
		}
		const text = buildBatchNote(missing);
		event.messages.push({ role: "user", content: text, timestamp: Date.now() });
		for (const task of missing) {
			// Injected into THIS request: the text is by definition delivered.
			markSent(task, "fallback", text);
			markConfirmed(task);
		}
		return { messages: event.messages };
	});

	// ------------------------------------------------------------------
	// Run state + actionable boundaries. `turn_end` is the earliest point a
	// report can join the conversation (after the turn's tool calls, before the
	// next provider request) and the only one that fires for an aborted turn;
	// `agent_before_settle` is the final chance of a normal run. Both append ONE
	// aggregated `custom_message` entry — durable, unlike a steering message —
	// and ask for one continuation so the model can act on it in this run.
	// ------------------------------------------------------------------
	pi.on("agent_start", () => {
		busy = true;
		return undefined;
	});

	pi.on("turn_end", (event) => deliverAtBoundary(event));

	pi.on("agent_before_settle", (event) => deliverAtBoundary(event));

	pi.on("agent_settled", (event) => {
		busy = false;
		if (event.aborted) {
			// The user asked for the run to stop: keep the report (it is already
			// committed for an aborted turn, or stays pending) and let the next
			// `context` deliver it. Waking here would fight the abort.
			return undefined;
		}
		// Reports that finished after the last boundary: nothing else would
		// wake the agent, and a run requested from a settled handler starts
		// after every settled handler completes.
		flushPending({ wake: true });
		return undefined;
	});

	// ------------------------------------------------------------------
	// user_bash: a leading "&" token routes interactive `!` commands to
	// the background path; anything else returns undefined so core keeps
	// its normal foreground execution (which, for RPC, is our bash tool).
	// ------------------------------------------------------------------
	pi.on("user_bash", (event): UserBashEventResult | undefined => {
		const trimmed = event.command.trimStart();
		if (!trimmed.startsWith(BACKGROUND_PREFIX)) {
			return undefined;
		}
		const command = trimmed.replace(/^&[ \t]*/, "");
		if (command.trim() === "") {
			return {
				result: {
					output: "bg-tasks: missing command after the '&' background prefix",
					exitCode: 1,
					cancelled: false,
					truncated: false,
				},
			};
		}
		const task = startTask(command, event.cwd, buildSessionEnv(undefined), { stdin: true });
		task.panelStarted = true;
		reportPanel(task);
		return {
			result: {
				output: `Task ${task.taskId} started in background (task ${task.taskId}). Use the task panel to view.`,
				exitCode: 0,
				cancelled: false,
				truncated: false,
			},
		};
	});

	// ------------------------------------------------------------------
	// Spawn. Returns immediately after wiring up the process; the caller
	// decides how long to stay attached. Completion reporting happens in
	// the close/error handlers.
	// ------------------------------------------------------------------
	function startTask(
		command: string,
		cwd: string,
		env: NodeJS.ProcessEnv,
		options?: { stdin?: boolean },
	): BgTaskState {
		const taskId = "b" + randomUUID().replace(/-/g, "").substring(0, 6);
		const outputFile = join(tmpdir(), `pi-bash-${taskId}.log`);
		let resolveExited = (): void => {};
		const exited = new Promise<void>((resolve) => {
			resolveExited = resolve;
		});
		const task: BgTaskState = {
			taskId,
			command,
			cwd,
			outputFile,
			startedAt: Date.now(),
			completed: false,
			exitCode: null,
			signal: null,
			delivery: "none",
			panelStarted: false,
			observers: 0,
			stdinOpen: false,
			exited,
			resolveExited: () => resolveExited(),
		};
		tasks.set(taskId, task);

		let log: ReturnType<typeof createWriteStream>;
		try {
			log = createWriteStream(outputFile);
		} catch (error) {
			finishTask(task, null, null, error instanceof Error ? error.message : String(error));
			return task;
		}
		log.on("error", () => {
			// A failed log write must not crash the agent process.
		});

		let child;
		try {
			const shellConfig = getShellConfig();
			child = spawn(shellConfig.shell, [...shellConfig.args, command], {
				cwd,
				env,
				detached: true,
				// `ignore` for a foreground command (stock pi), a pipe when the task is
				// meant to be fed — see `task_input`.
				stdio: [options?.stdin ? "pipe" : "ignore", "pipe", "pipe"],
				windowsHide: true,
			});
		} catch (error) {
			log.end();
			finishTask(task, null, null, error instanceof Error ? error.message : String(error));
			return task;
		}

		task.pid = child.pid;
		if (child.pid) {
			trackedPids.add(child.pid);
			ensureExitHook();
		}
		if (child.stdin) {
			task.stdin = child.stdin;
			task.stdinOpen = true;
			// A command that closes its stdin (or dies) must not turn the next
			// `task_input` into an unhandled stream error.
			child.stdin.on("error", () => {
				task.stdinOpen = false;
			});
			// The pipe must not keep the pi process alive on its own.
			(child.stdin as { unref?: () => void }).unref?.();
		}
		// Synchronous, not debounced, and AFTER the pid is known: the record that
		// matters most is the one a crash leaves behind, and a task can start and
		// die inside the coalescing window. Finishes are coalesced instead.
		persistNow();
		child.stdout?.on("data", (data: Buffer) => {
			log.write(data);
		});
		child.stderr?.on("data", (data: Buffer) => {
			log.write(data);
		});
		child.once("error", (error) => {
			if (child.pid) {
				trackedPids.delete(child.pid);
			}
			log.end();
			finishTask(task, null, null, error.message);
		});
		child.once("close", (code, signal) => {
			if (child.pid) {
				trackedPids.delete(child.pid);
			}
			// Flush before anyone reads the tail: `end()` is async, so the
			// completion callbacks run after the stream had its chance.
			log.end(() => finishTask(task, code, signal));
		});
		// Let the pi process exit even while this task runs; the exit hook
		// above kills the process group. Streams must be unref'd too, a
		// piped child alone keeps the event loop alive.
		child.unref();
		(child.stdout as { unref?: () => void } | null | undefined)?.unref?.();
		(child.stderr as { unref?: () => void } | null | undefined)?.unref?.();
		return task;
	}

	/** Mark a task terminal and route the completion to exactly one channel. */
	function finishTask(task: BgTaskState, code: number | null, signal: string | null, spawnError?: string): void {
		if (task.completed) {
			return;
		}
		task.completed = true;
		task.endedAt = Date.now();
		task.exitCode = code;
		task.signal = signal;
		if (spawnError !== undefined) {
			task.spawnError = spawnError;
		}
		if (task.panelStarted) {
			reportPanel(task);
		}
		if (task.adoptPoll) {
			clearInterval(task.adoptPoll);
			task.adoptPoll = undefined;
		}
		task.stdinOpen = false;
		if (task.observers > 0) {
			// An attached call will return this terminal state itself and mark the
			// report confirmed. Leave it pending rather than "consumed": a call
			// that is aborted before it returns then still gets the report through
			// the `context` fallback instead of losing it.
		} else if (busy) {
			// A run is active: the next actionable boundary carries the report.
		} else {
			flushPending({ wake: true });
		}
		task.resolveExited();
		schedulePersist();
	}

	/** Outstanding reports: completed and not yet confirmed in model context. */
	function pendingReports(): BgTaskState[] {
		return [...tasks.values()].filter((task) => task.completed && task.delivery !== "confirmed");
	}

	/** Record that a channel now carries this report (not yet observed). */
	function markSent(task: BgTaskState, via: DeliveryChannel, text: string): void {
		task.delivery = "sent";
		task.sentVia = via;
		task.sentText = text;
		task.sentAt = Date.now();
	}

	/**
	 * Stop delivering this report. Set when the text was observed in a `context`
	 * payload, injected there, or carried by a tool result — never at send time.
	 */
	function markConfirmed(task: BgTaskState): void {
		task.delivery = "confirmed";
	}

	/**
	 * Append the outstanding reports to a boundary proposal.
	 *
	 * `continue: true` guarantees one follow-up provider request, so a model that
	 * ended its turn while a task was still running does not go quiet holding the
	 * result. A turn that is ending because it was aborted keeps the entry (it is
	 * committed with the turn — verified) but asks for no continuation, so the
	 * abort still stops the run; the report is read on the next turn instead.
	 */
	function deliverAtBoundary(event: {
		entries: unknown[];
		outcome?: string;
	}): { entries: unknown[]; continue?: boolean } | undefined {
		const pending = pendingReports().filter((task) => task.delivery === "none" && task.observers === 0);
		if (pending.length === 0) {
			return undefined;
		}
		const text = buildBatchNote(pending);
		for (const task of pending) {
			markSent(task, "boundary", text);
		}
		const aborted = event.outcome === "aborted";
		return {
			entries: [
				...event.entries,
				{
					type: "custom_message",
					customType: CUSTOM_TYPE,
					content: text,
					display: false,
					// A batched report covers several tasks: omit `details` so the
					// frontend does not upsert a phantom task row for the batch. The
					// per-task `reportPanel` messages are what drive the panel.
					...batchDetails(pending),
				},
			],
			...(aborted ? {} : { continue: true }),
		};
	}

	/**
	 * Hand every undelivered report to the session as ONE custom message.
	 *
	 * `wake` asks for a turn (only used when the session is otherwise idle, i.e.
	 * the completion is the only thing left to do). The message is a plain
	 * `pi2_bg_task` custom message without `deliverAs`, so core appends it at once
	 * when idle and at the next turn boundary while streaming. Delivery is not
	 * assumed: the text is checked for in the next `context` payload, and a
	 * message that never got there is injected by the fallback.
	 */
	function flushPending(options: { wake: boolean }): void {
		const pending = pendingReports().filter((task) => task.delivery === "none" && task.observers === 0);
		if (pending.length === 0) {
			return;
		}
		const text = buildBatchNote(pending);
		try {
			pi.sendMessage(
				{
					customType: CUSTOM_TYPE,
					content: text,
					display: false,
					...batchDetails(pending),
				},
				options.wake ? { triggerTurn: true } : undefined,
			);
		} catch {
			// Stale ctx after reload etc.: leave the reports pending; the `context`
			// handler injects them before the next LLM call instead.
			return;
		}
		for (const task of pending) {
			markSent(task, "wake", text);
		}
	}

	/**
	 * Frontend notification (task panel): a display:false custom message sent
	 * WITHOUT options, so core appends it instantly when idle and at the next
	 * turn end while streaming. Never `triggerTurn` — this fires mid-tool and
	 * must not interrupt the running turn; delivering it through followUp
	 * instead would strand the panel on "running" for the rest of the run.
	 */
	function reportPanel(task: BgTaskState): void {
		const kind: BgTaskDetails["kind"] = !task.completed
			? "started"
			: task.spawnError
				? "failed"
				: task.signal !== null
					? "stopped"
					: task.exitCode === 0
						? "completed"
						: "failed";
		const details = {
			kind,
			taskId: task.taskId,
			command: task.command,
			pid: task.pid,
			outputFile: task.outputFile,
			exitCode: task.exitCode,
			signal: task.signal,
			// The message is stamped when it is sent, so an adopted task would
			// otherwise render as if it had just started.
			startedAt: task.startedAt,
		} satisfies BgTaskDetails;
		try {
			pi.sendMessage({
				customType: CUSTOM_TYPE,
				content: `[Background task ${task.taskId} ${kind}]`,
				display: false,
				details,
			});
		} catch {
			// Stale ctx after reload: the task still runs; only the panel misses it.
		}
	}

	/**
	 * `details` for a report message. Only a single-task report carries them: the
	 * frontend task registry keys on `details.taskId`, so a batched message with
	 * one representative id would fabricate a task row. Panel state always comes
	 * from the per-task `reportPanel` messages, so omitting them loses nothing.
	 */
	function batchDetails(batch: BgTaskState[]): { details?: BgTaskDetails } {
		if (batch.length !== 1) {
			return {};
		}
		const task = batch[0];
		return {
			details: {
				kind: task.spawnError
					? "failed"
					: task.signal !== null
						? "stopped"
						: task.exitCode === 0
							? "completed"
							: "failed",
				taskId: task.taskId,
				command: task.command,
				pid: task.pid,
				outputFile: task.outputFile,
				exitCode: task.exitCode,
				signal: task.signal,
			} satisfies BgTaskDetails,
		};
	}

	// ------------------------------------------------------------------
	// Override the built-in bash tool: one spawn routine, two attach
	// policies, plus the extra optional boolean. The tool name stays
	// "bash" so pi.nvim keeps using its existing bash renderer.
	// ------------------------------------------------------------------
	const builtin = createBashToolDefinition(process.cwd());

	const bgBashParameters = Type.Object({
		...(builtin.parameters as unknown as { properties: Record<string, TSchema> }).properties,
		run_in_background: Type.Optional(
			Type.Boolean({
				description:
					"Run the command as a background task instead of staying attached. Use for long-running commands such as dev servers, watchers, long builds, or test suites that take minutes. The command starts immediately, output streams to a log file whose path is returned, and you are notified with the result when it finishes. Do not poll the output file and do not append '&' to background commands. The timeout parameter does not apply to background tasks.",
			}),
		),
		// The spread above is runtime-exact but types as a plain Record; pin the
		// static shape so Static<> keeps command/timeout/run_in_background.
	}) as unknown as Type.TObject<{
		command: Type.TString;
		timeout: Type.TOptional<Type.TNumber>;
		run_in_background: Type.TOptional<Type.TBoolean>;
	}>;

	type BgBashParams = Static<typeof bgBashParameters>;

	/** Details carried in bash tool results (frontend task tracking + handoff info). */
	interface BgBashToolDetails extends BashToolDetails {
		background?: boolean;
		detachedByTimeout?: boolean;
		taskId?: string;
		command?: string;
		pid?: number;
		outputFile?: string;
		cancelled?: boolean;
	}

	/**
	 * The four sentences that make `sleep` unnecessary. They are deliberately
	 * phrased as permissions ("ending your turn is correct"), not only as bans:
	 * the observed failure mode is a model that treats ending its turn while
	 * work is still running as giving up.
	 */
	const BG_GUIDE =
		" Long-running commands can be backgrounded two ways: pass run_in_background: true (for a dev server, watcher or anything you do not need now) or just run it and let it outlive the attach window (timeout, default 2 minutes) — an outlived command is NOT killed, it keeps running as a background task and the call returns its task id." +
		" Never wait with `sleep` and never poll a task's output file: you are told the task id, and when the process exits with nobody attached you are woken with its status and output tail." +
		" If you have other work, do it. If the task's result is all that is left, either end your turn (that is the correct action, not giving up — the wake report starts a new turn) or call wait_task, which blocks until the task exits or its timeout hits and returns the output." +
		" A wait_task result of \"still running\" is not a failure." +
		" A task you no longer need — a dev server holding a port, a watcher for a file you already fixed — is stopped with stop_task(task_id), which signals its whole process group; list_tasks shows what is still running." +
		" A background task keeps its stdin open: if it is waiting on input (a confirmation, a name, a REPL line), answer it with task_input(task_id, data) instead of killing and restarting it.";

	const { prepareArguments: _unusedPrepareArguments, ...builtinRest } = builtin;
	void _unusedPrepareArguments; // typed for the old schema; the new schema needs no shim

	const overridden: ToolDefinition<typeof bgBashParameters, BgBashToolDetails | undefined> = {
		...builtinRest,
		description: `${builtin.description}${BG_GUIDE}`,
		parameters: bgBashParameters,
		async execute(toolCallId, params, signal, onUpdate, ctx) {
			const { run_in_background, command, timeout } = params;
			if (typeof command !== "string" || command.trim() === "") {
				throw new Error("bg-tasks: 'command' must be a non-empty string");
			}
			void toolCallId;
			const task = startTask(command, ctx?.cwd ?? process.cwd(), buildSessionEnv(ctx), {
				// A foreground command keeps stock behaviour: no stdin pipe, so nothing
				// waits on input that will never come. If it outlives its window it
				// detaches without one and `task_input` says so.
				stdin: Boolean(run_in_background),
			});

			if (run_in_background) {
				task.panelStarted = true;
				reportPanel(task);
				return {
					content: [
						{
							type: "text" as const,
							text: `Task ${task.taskId} running in background: ${command}\nOutput: ${task.outputFile}\nYou are woken with the result when it exits. Do not \`sleep\` or poll the file. If you have nothing else to do, ending your turn is the correct move; if you need the result before continuing, call wait_task(task_id: "${task.taskId}").`,
						},
					],
					details: {
						background: true,
						taskId: task.taskId,
						command,
						pid: task.pid,
						outputFile: task.outputFile,
					} satisfies BgBashToolDetails,
				};
			}

			const window = clampAttachWindow(timeout);
			const outcome = await attachWait(task, {
				deadlineMs: window,
				signal,
				onUpdate: onUpdate
					? (tail) => {
							onUpdate({
								content: [{ type: "text" as const, text: tail }],
								details: { taskId: task.taskId, command, outputFile: task.outputFile } satisfies BgBashToolDetails,
							});
						}
					: undefined,
			});

			if (outcome === "aborted") {
				if (task.pid) {
					killProcessGroup(task.pid);
				}
				// The kill lands as a "stopped" exit a moment later. The model
				// already got the cancellation in this result, so confirm the report
				// instead of sending the kill back as a fresh event.
				markConfirmed(task);
				const partial = readOutputTail(task.outputFile, MAX_OUTPUT_BYTES, MAX_OUTPUT_LINES).text;
				return {
					content: [
						{
							type: "text" as const,
							text: partial ? `[cancelled] ${command}\n\n${partial}` : `[cancelled] ${command}`,
						},
					],
					details: {
						cancelled: true,
						taskId: task.taskId,
						command,
						pid: task.pid,
						outputFile: task.outputFile,
					} satisfies BgBashToolDetails,
					isError: true,
				};
			}

			const tail = readOutputTail(task.outputFile, MAX_OUTPUT_BYTES, MAX_OUTPUT_LINES);
			const exitCode = task.spawnError ? 1 : (task.exitCode ?? 1);

			if (outcome === "exited") {
				// This result carries the terminal state: the report is delivered.
				markConfirmed(task);
				// Foreground command that finished inside its window: the log is
				// scratch space now (unless the footer points at it), so keep
				// /tmp proportional to *running* tasks instead of to every call.
				if (!tail.truncated) {
					try {
						unlinkSync(task.outputFile);
					} catch {
						// Already gone or not ours: nothing to clean up.
					}
				}
				// Same shape the built-in bash returns: output (or "(no output)"),
				// then a trailing exit-code line for failures.
				const output = tail.text.trim() ? tail.text : "(no output)";
				const failed = task.spawnError !== undefined || (task.exitCode !== null && task.exitCode !== 0);
				const body = failed && !task.spawnError ? `${output}\n\nCommand exited with code ${task.exitCode}` : output;
				return {
					content: [
						{
							type: "text" as const,
							text: body,
						},
					],
					details: {
						command,
						exitCode,
						truncated: tail.truncated,
						outputFile: tail.truncated ? task.outputFile : undefined,
					} satisfies BgBashToolDetails,
					isError: failed,
				};
			}

			// Deadline: hand the command over to the background instead of
			// killing it (P0-2). It becomes a visible task and a normal wake
			// target from here on.
			task.panelStarted = true;
			reportPanel(task);
			const soFar = tail.text.trim() ? `\n\nOutput so far:\n${tail.text}` : "";
			return {
				content: [
					{
						type: "text" as const,
						text: `[still running] ${command}\nThe command outlived its ${formatSeconds(window)} attach window and keeps running as background task ${task.taskId} (not killed).\nOutput: ${task.outputFile}${soFar}\nCall wait_task(task_id: "${task.taskId}") to block until it exits, or end your turn and you will be woken with the result. Do not \`sleep\`.`,
					},
				],
				details: {
					background: true,
					detachedByTimeout: true,
					taskId: task.taskId,
					command,
					pid: task.pid,
					outputFile: task.outputFile,
				} satisfies BgBashToolDetails,
			};
		},
	};

	pi.registerTool(overridden);

	// ------------------------------------------------------------------
	// wait_task: the blocking primitive that replaces `sleep`. Same attach
	// lease as the foreground bash path, so an exit observed here never
	// produces a duplicate wake.
	// ------------------------------------------------------------------
	const waitTaskParameters = Type.Object({
		task_id: Type.String({
			description: "Task id returned by a bash call (e.g. \"b3f2a1\").",
		}),
		timeout_ms: Type.Optional(
			Type.Number({
				description:
					"How long to stay attached, in milliseconds (default 120000, max 1800000). Reaching it does NOT kill the task and is NOT a failure: call again, or end your turn and let the wake report deliver the result.",
			}),
		),
	});

	type WaitTaskParams = Static<typeof waitTaskParameters>;

	interface WaitTaskDetails {
		taskId: string;
		status: "exited" | "still_running" | "cancelled";
		command: string;
		exitCode?: number | null;
		signal?: string | null;
		outputFile?: string;
		wallTimeSeconds: number;
	}

	pi.registerTool({
		name: "wait_task",
		label: "Wait for background task",
		description:
			"Stay attached to a background bash task until it exits or the timeout hits, then return its output. Use this instead of `sleep` whenever you need a task's result before you can continue. Reaching the timeout is not a failure: the process keeps running and you can wait again (or end your turn and be woken when it exits).",
		promptSnippet: "Block until a background task exits (or the timeout hits) and return its output",
		promptGuidelines: [
			"Use wait_task (not `sleep`) when you need a background task's result before continuing: it returns as soon as the process exits, and a \"still running\" result is not a failure.",
			"If a task's result is all that is left and you have nothing else to do, ending your turn is correct — wait_task's sibling wake report will deliver the result and start a new turn.",
		],
		parameters: waitTaskParameters,
		// Shared mutable task table + a long-lived wait: serialize with itself.
		executionMode: "sequential",
		async execute(toolCallId, params, signal, onUpdate) {
			void toolCallId;
			const task = tasks.get(params.task_id);
			if (!task) {
				const known = [...tasks.values()]
					.filter((candidate) => !candidate.completed || candidate.observers > 0)
					.map((candidate) => candidate.taskId);
				const knownNote = known.length > 0 ? ` Known task ids in this session: ${known.join(", ")}.` : "";
				throw new Error(`wait_task: unknown task id "${params.task_id}".${knownNote} Task ids come from bash results.`);
			}

			const window = clampWaitWindow(params.timeout_ms);
			const started = Date.now();
			const outcome = await attachWait(task, {
				deadlineMs: window,
				signal,
				onUpdate: onUpdate
					? (tail) => {
							onUpdate({
								content: [
									{
										type: "text" as const,
										text: `[still running] ${task.command} (${formatSeconds(Date.now() - task.startedAt)})\n${tail}`,
									},
								],
								details: {
									taskId: task.taskId,
									status: "still_running",
									command: task.command,
									outputFile: task.outputFile,
									wallTimeSeconds: (Date.now() - started) / 1000,
								} satisfies WaitTaskDetails,
							});
						}
					: undefined,
			});

			const wallTimeSeconds = (Date.now() - started) / 1000;
			const tail = readOutputTail(task.outputFile, MAX_OUTPUT_BYTES, MAX_OUTPUT_LINES);
			const elapsed = formatSeconds((task.endedAt ?? Date.now()) - task.startedAt);

			if (outcome === "exited") {
				// This result carries the terminal state: the report is delivered.
				markConfirmed(task);
				const head = `Task ${task.taskId} ${describeExit(task)} after ${elapsed}.`;
				return {
					content: [{ type: "text" as const, text: tail.text ? `${head}\n\n${tail.text}` : head }],
					details: {
						taskId: task.taskId,
						status: "exited",
						command: task.command,
						exitCode: task.spawnError ? 1 : task.exitCode,
						signal: task.signal,
						outputFile: tail.truncated ? task.outputFile : undefined,
						wallTimeSeconds,
					} satisfies WaitTaskDetails,
					isError: task.spawnError !== undefined || (task.exitCode !== null && task.exitCode !== 0),
				};
			}

			if (outcome === "aborted") {
				return {
					content: [
						{
							type: "text" as const,
							text: `[cancelled] stopped waiting for task ${task.taskId}; the process keeps running.${tail.text ? `\n\nOutput so far:\n${tail.text}` : ""}`,
						},
					],
					details: {
						taskId: task.taskId,
						status: "cancelled",
						command: task.command,
						exitCode: task.exitCode,
						signal: task.signal,
						outputFile: task.outputFile,
						wallTimeSeconds,
					} satisfies WaitTaskDetails,
					isError: true,
				};
			}

			const soFar = tail.text.trim() ? `\n\nOutput so far:\n${tail.text}` : "";
			return {
				content: [
					{
						type: "text" as const,
						text: `[still running] Task ${task.taskId} has not exited after ${formatSeconds(window)} attached (running for ${elapsed}). This is not a failure — the process is still alive and was not killed.${soFar}\nCall wait_task again with a larger timeout_ms, or end your turn and you will be woken with the result. Do not \`sleep\`.`,
					},
				],
				details: {
					taskId: task.taskId,
					status: "still_running",
					command: task.command,
					exitCode: task.exitCode,
					signal: task.signal,
					outputFile: task.outputFile,
					wallTimeSeconds,
				} satisfies WaitTaskDetails,
			};
		},
	});

	// ------------------------------------------------------------------
	// stop_task: the model-side counterpart of the panel's `x`. The kill has
	// to be a process GROUP signal (`detached: true` makes pid == pgid), and
	// the caller takes the observer lease BEFORE signalling so the exit this
	// call causes is reported by its own result instead of as a wake.
	// ------------------------------------------------------------------
	const stopTaskParameters = Type.Object({
		task_id: Type.String({
			description: 'Task id returned by a bash call (e.g. "b3f2a1").',
		}),
		timeout_ms: Type.Optional(
			Type.Number({
				description: `How long the task gets to exit after SIGTERM before it is SIGKILLed, in milliseconds (default 5000, max 30000). Most tasks exit on the first signal; the escalation covers a process that traps or ignores it.`,
			}),
		),
	});

	type StopTaskParams = Static<typeof stopTaskParameters>;

	interface StopTaskDetails {
		taskId: string;
		status: "stopped" | "already_exited" | "still_running" | "cancelled";
		command: string;
		exitCode?: number | null;
		signal?: string | null;
		/** Whether SIGTERM was not enough and SIGKILL had to be sent. */
		escalated: boolean;
		outputFile?: string;
		wallTimeSeconds: number;
	}

	pi.registerTool({
		name: "stop_task",
		label: "Stop background task",
		description:
			"Stop a running background bash task: SIGTERM its whole process group, and SIGKILL it if it has not exited within the grace window. Use this when a task is no longer needed — a dev server that has to give its port back, a watcher for a file that is already fixed, a run you now know is wrong — instead of leaving it alive for the rest of the session. This stops a task; to get a task's result use wait_task instead.",
		promptSnippet: "Stop a running background task (SIGTERM its process group, SIGKILL if it ignores it)",
		promptGuidelines: [
			"Stop a task you no longer need instead of leaving it running: a stale dev server holds its port, and a stale watcher keeps rewriting files.",
			"stop_task signals the task's whole process group, so the children of `npm`, `make` or a pipeline are stopped too — nothing is left behind holding the port.",
			"Do not wait_task a task whose result you no longer want; stop it. Stopping is not an error and the task's output up to that point is returned.",
		],
		parameters: stopTaskParameters,
		// Mutates the shared task table and takes the observer lease.
		executionMode: "sequential",
		async execute(toolCallId, params, signal) {
			void toolCallId;
			const task = tasks.get(params.task_id);
			if (!task) {
				const known = [...tasks.values()].map((candidate) => candidate.taskId);
				const knownNote = known.length > 0 ? ` Known task ids in this session: ${known.join(", ")}.` : "";
				throw new Error(`stop_task: unknown task id "${params.task_id}".${knownNote} Task ids come from bash results.`);
			}

			const started = Date.now();
			const grace = clampStopGrace(params.timeout_ms);
			const detailsOf = (status: StopTaskDetails["status"], escalated: boolean, outputFile?: string): StopTaskDetails => ({
				taskId: task.taskId,
				status,
				command: task.command,
				exitCode: task.exitCode,
				signal: task.signal,
				escalated,
				outputFile,
				wallTimeSeconds: (Date.now() - started) / 1000,
			});

			if (task.completed) {
				const elapsed = formatSeconds((task.endedAt ?? Date.now()) - task.startedAt);
				return {
					content: [
						{
							type: "text" as const,
							text: `Task ${task.taskId} is not running: it ${describeExit(task)} after ${elapsed}. Nothing to stop.`,
						},
					],
					details: detailsOf("already_exited", false),
				};
			}

			if (task.pid === undefined) {
				throw new Error(`stop_task: task ${task.taskId} has no process id (it failed to start).`);
			}

			// Take the lease BEFORE signalling: the exit this call causes must be
			// reported by its own result, not as a wake that races it.
			let waited = attachWait(task, { deadlineMs: grace, signal });
			let signalled = signalProcessGroup(task.pid, "SIGTERM");
			let escalated = false;
			let outcome = await waited;

			if (outcome === "deadline" && !task.completed) {
				escalated = true;
				waited = attachWait(task, { deadlineMs: STOP_KILL_SETTLE_MS, signal });
				signalled = signalProcessGroup(task.pid, "SIGKILL") || signalled;
				outcome = await waited;
			}

			const tail = readOutputTail(task.outputFile, MAX_OUTPUT_BYTES, MAX_OUTPUT_LINES);
			const elapsed = formatSeconds((task.endedAt ?? Date.now()) - task.startedAt);

			if (task.completed) {
				// An adopted task has no ChildProcess to report the signal it died
				// from; the one this call sent is the only truthful account, and the
				// liveness poll cannot know it.
				if (task.adopted && task.signal === null) {
					task.signal = escalated ? "SIGKILL" : "SIGTERM";
					task.exitUnknown = undefined;
				}
				// This result carries the terminal state: suppress the wake report.
				markConfirmed(task);
				const how = escalated ? "was SIGKILLed (it ignored SIGTERM)" : describeExit(task);
				const head = `Task ${task.taskId} ${how} after ${elapsed} (stopped).`;
				return {
					content: [{ type: "text" as const, text: tail.text ? `${head}\n\n${tail.text}` : head }],
					details: detailsOf("stopped", escalated, tail.truncated ? task.outputFile : undefined),
					// A task that died on our signal is not a failure of the call; the
					// output it produced is still returned above.
					isError: false,
				};
			}

			if (outcome === "aborted") {
				return {
					content: [
						{
							type: "text" as const,
							text: `[cancelled] stopped waiting for task ${task.taskId} to die; ${signalled ? "SIGTERM was sent" : "no signal could be delivered"} and the process may still be exiting. It will report on its own if it does.`,
						},
					],
					details: detailsOf("cancelled", escalated, task.outputFile),
					isError: true,
				};
			}

			const soFar = tail.text.trim() ? `\n\nOutput so far:\n${tail.text}` : "";
			return {
				content: [
					{
						type: "text" as const,
						text: `[still running] Task ${task.taskId} did not exit: ${signalled ? "SIGTERM and SIGKILL were sent to its process group" : "no signal could be delivered to its process group"} (running for ${elapsed}). It may be stuck in an uninterruptible state; its output file is ${task.outputFile}.${soFar}`,
					},
				],
				details: detailsOf("still_running", escalated, task.outputFile),
				isError: true,
			};
		},
	});

	// ------------------------------------------------------------------
	// task_input: the write half of a background task's stdin. A command that
	// asks a question has no other way to be answered once it is backgrounded —
	// with stdin ignored it sees EOF and aborts, and with a pipe nobody writes to
	// it blocks forever (the "never exits, never notifies" hole).
	// ------------------------------------------------------------------
	const taskInputParameters = Type.Object({
		task_id: Type.String({
			description: 'Task id returned by a bash call (e.g. "b3f2a1").',
		}),
		data: Type.String({
			description: "Text to write to the task's standard input.",
		}),
		newline: Type.Optional(
			Type.Boolean({
				description:
					"Append a newline after `data` — pressing Enter, which is what a line-oriented prompt expects (default true). Pass false to send raw characters, e.g. a single key or a partial line.",
			}),
		),
	});

	type TaskInputParams = Static<typeof taskInputParameters>;

	interface TaskInputDetails {
		taskId: string;
		command: string;
		status: "written" | "no_stdin" | "exited";
		/** Bytes written, including the newline. */
		bytes?: number;
		outputFile: string;
	}

	pi.registerTool({
		name: "task_input",
		label: "Feed a background task",
		description:
			"Write text to a running background bash task's standard input, then return the output it produced so far. Use it to answer a command that is waiting on input — a confirmation, a name, a password prompt, a REPL line — instead of starting it again. Only tasks you started in the background have a stdin; a foreground command that outlived its window and detached does not.",
		promptSnippet: "Write text to a background task's stdin (answer a prompt, feed a REPL)",
		promptGuidelines: [
			"Use task_input when a background task is waiting for input; do not kill and restart it just to answer a prompt.",
			"`newline` defaults to true (pressing Enter). Pass false for a single key or a line you are still composing.",
			"The call returns the output so far; the task keeps running and is reported when it exits.",
		],
		parameters: taskInputParameters,
		async execute(toolCallId, params) {
			void toolCallId;
			const task = tasks.get(params.task_id);
			if (!task) {
				const known = [...tasks.values()].map((candidate) => candidate.taskId);
				const knownNote = known.length > 0 ? ` Known task ids in this session: ${known.join(", ")}.` : "";
				throw new Error(`task_input: unknown task id "${params.task_id}".${knownNote} Task ids come from bash results.`);
			}

			const detailsOf = (status: TaskInputDetails["status"], bytes?: number): TaskInputDetails => ({
				taskId: task.taskId,
				command: task.command,
				status,
				bytes,
				outputFile: task.outputFile,
			});

			if (task.completed) {
				return {
					content: [
						{
							type: "text" as const,
							text: `Task ${task.taskId} ${describeExit(task)} — its stdin is gone, so there is nothing to write to. Its output is in ${task.outputFile}.`,
						},
					],
					details: detailsOf("exited"),
					isError: true,
				};
			}

			const stdin = task.stdin;
			if (!stdin || !task.stdinOpen) {
				const why = task.stdin
					? `it closed its stdin (it may have finished reading input, or it is exiting)`
					: `it was started without a stdin pipe — only run_in_background (or a \`&\` command in the prompt) keeps one open, and a foreground command that outlived its attach window has none`;
				return {
					content: [
						{
							type: "text" as const,
							text: `Task ${task.taskId} has no usable stdin: ${why}. Its output is in ${task.outputFile}; the task is still running and is reported when it exits.`,
						},
					],
					details: detailsOf("no_stdin"),
					isError: true,
				};
			}

			const newline = params.newline !== false;
			const payload = !newline || params.data.endsWith("\n") ? params.data : `${params.data}\n`;
			try {
				stdin.write(payload);
			} catch (error) {
				task.stdinOpen = false;
				return {
					content: [
						{
							type: "text" as const,
							text: `Task ${task.taskId} could not be written to: ${error instanceof Error ? error.message : String(error)}. Its output is in ${task.outputFile}.`,
						},
					],
					details: detailsOf("no_stdin"),
					isError: true,
				};
			}

			const tail = readOutputTail(task.outputFile, WAKE_TAIL_BYTES, WAKE_TAIL_LINES);
			const head = `Wrote ${Buffer.byteLength(payload, "utf8")} byte(s) to task ${task.taskId}'s stdin.`;
			const body = tail.text.trim()
				? `${head}\n\nOutput so far:\n${tail.text}`
				: `${head} It has not produced output since this write — it may still be reading, or waiting for another line.`;
			return {
				content: [{ type: "text" as const, text: body }],
				details: detailsOf("written", Buffer.byteLength(payload, "utf8")),
			};
		},
	});

	// ------------------------------------------------------------------
	// list_tasks: the model's view of the task table. Cheap and bounded — the
	// table grows for the life of the process, so the output is capped.
	// ------------------------------------------------------------------
	const listTasksParameters = Type.Object({
		include_finished: Type.Optional(
			Type.Boolean({
				description: "Also list tasks that have already exited (default false: running tasks only).",
			}),
		),
	});

	/** One `list_tasks` row: id, state, elapsed, command, log file. */
	function describeTaskLine(task: BgTaskState): string {
		const elapsed = formatSeconds((task.endedAt ?? Date.now()) - task.startedAt);
		let command = task.command.replace(/\s+/g, " ").trim();
		if (command.length > LISTED_COMMAND_WIDTH - 3) {
			command = `${command.substring(0, LISTED_COMMAND_WIDTH - 3)}...`;
		}
		const state = task.completed
			? describeExit(task)
			: task.adopted
				? "running (adopted from an earlier pi process)"
				: "running";
		// Only a live background task can be fed, and the model can only see that here.
		const stdin = !task.completed && task.stdinOpen ? ", stdin open" : "";
		return `- ${task.taskId} [${state}${stdin}] ${elapsed} "${command}" (output: ${task.outputFile})`;
	}

	pi.registerTool({
		name: "list_tasks",
		label: "List background tasks",
		description:
			"List the background bash tasks of this session: task id, state, elapsed time, command and output file. It also lists tasks an earlier pi process left behind (they are marked as adopted, and their exit status may be unknown). Use it to find the id of a task you started earlier in the session (before stopping it with stop_task or waiting on it with wait_task) instead of guessing ids.",
		promptSnippet: "List this session's background bash tasks with their ids and states",
		promptGuidelines: [
			"Call list_tasks when you need a task id you no longer have in front of you; do not guess ids — wait_task and stop_task reject unknown ones.",
			"list_tasks lists running tasks by default; pass include_finished: true to also see the ones that already exited.",
		],
		parameters: listTasksParameters,
		async execute(toolCallId, params) {
			void toolCallId;
			const all = [...tasks.values()];
			const running = all.filter((task) => !task.completed);
			const listed = params.include_finished ? all : running;
			const runningCount = running.length;

			if (listed.length === 0) {
				return {
					content: [
						{
							type: "text" as const,
							text: params.include_finished
								? "No background tasks in this session. Start one with bash(run_in_background: true)."
								: "No running background tasks in this session.",
						},
					],
					details: { total: 0, running: 0, listed: 0 },
				};
			}

			// Running first (oldest first), then the finished ones newest first —
			// the panel's order, so the two views never disagree.
			listed.sort((a, b) => {
				if (a.completed !== b.completed) {
					return a.completed ? 1 : -1;
				}
				return a.completed ? (b.endedAt ?? 0) - (a.endedAt ?? 0) : a.startedAt - b.startedAt;
			});
			const shown = listed.slice(0, MAX_LISTED_TASKS);
			const finishNote = runningCount > 0 ? `, ${runningCount} running` : "";
			const header = `${shown.length} of ${listed.length} background task${listed.length === 1 ? "" : "s"}${finishNote}:`;
			const hidden =
				listed.length > shown.length
					? `\n(${listed.length - shown.length} older task${listed.length - shown.length === 1 ? "" : "s"} not shown.)`
					: "";
			const footer =
				"\nUse stop_task(task_id) to stop one, wait_task(task_id) to block on one, or read its output file for the full log.";
			return {
				content: [
					{
						type: "text" as const,
						text: `${header}\n${shown.map(describeTaskLine).join("\n")}${hidden}${footer}`,
					},
				],
				details: { total: all.length, running: runningCount, listed: shown.length },
			};
		},
	});
}
