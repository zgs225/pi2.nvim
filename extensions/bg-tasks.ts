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
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, createWriteStream, openSync, readSync, statSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
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
	/** Resolves exactly once, when the process closes or spawn fails. */
	exited: Promise<void>;
	resolveExited: () => void;
}

const tasks = new Map<string, BgTaskState>();
/** Background process groups to kill best-effort when the pi process exits. */
const trackedPids = new Set<number>();
let exitHookInstalled = false;
/**
 * Whether an agent run is active. `turn_end` / `agent_before_settle` fire while
 * it is true, so a completion only needs the idle wake when it is false. Kept
 * here (not read from a ctx) because the exit callbacks run outside any event.
 */
let busy = false;

/** Kill a detached process group, falling back to the pid alone. */
function killProcessGroup(pid: number): void {
	try {
		process.kill(-pid, "SIGKILL");
	} catch {
		try {
			process.kill(pid, "SIGKILL");
		} catch {
			// Process already dead.
		}
	}
}

function ensureExitHook(): void {
	if (exitHookInstalled) {
		return;
	}
	exitHookInstalled = true;
	process.on("exit", () => {
		for (const pid of trackedPids) {
			killProcessGroup(pid);
		}
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
	// Delivery receipt + last-resort injector. `context` is the exact message
	// list about to be sent to the model, so it settles delivery truthfully:
	// the text we handed over earlier is either in there (confirmed) or it is
	// not (dropped by an abort, a discarded steering queue, or a stale extension
	// ctx — inject it now). Nothing is ever injected twice, because a task stops
	// being a candidate as soon as its text is observed. `event.messages` is a
	// deep copy; nothing here is persisted.
	// ------------------------------------------------------------------
	pi.on("context", (event) => {
		const outstanding = pendingReports();
		if (outstanding.length === 0) {
			return undefined;
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
		const task = startTask(command, event.cwd, buildSessionEnv(undefined));
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
	function startTask(command: string, cwd: string, env: NodeJS.ProcessEnv): BgTaskState {
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
				stdio: ["ignore", "pipe", "pipe"],
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
		" A wait_task result of \"still running\" is not a failure.";

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
			const task = startTask(command, ctx?.cwd ?? process.cwd(), buildSessionEnv(ctx));

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
}
