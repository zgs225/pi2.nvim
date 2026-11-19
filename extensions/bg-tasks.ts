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
 *     the transcript (stage 2) and is injected on the next turn (stage 3). The
 *     injection is NOT itself a delivery: `event.messages` is a per-request deep
 *     copy that is never persisted, so a request that fails takes the injected
 *     text with it. A fallback report therefore stays `sent` and is confirmed
 *     only by a `turn_end` whose outcome is `completed` — a failed or aborted
 *     request leaves it `sent`, and the next attempt injects it again;
 *  4. `agent_settled` (with `aborted !== true`) flushes reports that finished
 *     after the last boundary, because nothing else would wake the agent. It
 *     first RE-ARMS every report whose only carrier was a failed request (stage
 *     3), because a run that settles without a completed turn — retries
 *     exhausted, hard provider failure — leaves such a report `sent` and no
 *     later stage would ever look at it again; re-arming it as `none` lets this
 *     very settle deliver it as a persisted message. A failed request can delay
 *     a report, never swallow it.
 *
 * An `agent_settled` for an aborted run deliberately wakes nothing (the user
 * asked for the run to stop) and re-arms nothing (the report is read on the next
 * turn, as before); the report waits for stage 3.
 *
 * The report TEXT is a structured reminder block, not prose. The exact string
 * that is handed over is stored on the task (`task.sentText`), and stage 3
 * compares precisely that string, verbatim, against the message list about to
 * be sent: the receipt can never match a report built differently. Line 1 is
 * the `[SYSTEM NOTIFICATION - NOT USER INPUT]` banner,
 * line 2 one prose line, and the payload sits in `<system-reminder>` around one
 * `<background-task id status exit_code signal duration_ms output>` element per
 * task (a single task also carries its output tail; a batch keeps one element
 * per task and omits the tails). Attributes are escaped, because a command is
 * arbitrary shell text: a reader gets the task id, its status, the exit code,
 * the signal and the duration from the element instead of having to parse a
 * sentence. Element text (the command, the exit summary, the output tail) is
 * escaped as TEXT, so a program that prints `</system-reminder>` cannot end the
 * block or forge a second element.
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
 * The task table OUTLIVES the process that built it, and the SESSION TRANSCRIPT
 * is the only place it is written. Every state transition already reaches it as
 * a `pi2_bg_task` custom message (`started` carries command/pid/pidStartTime/
 * outputFile/startedAt/sessionId, a terminal one the exit status), so
 * `session_start` folds those entries back into the table: no sidecar file,
 * nothing to keep in sync, and the history travels with the session wherever it
 * is copied, exported or forked. Records rebuilt this way are ADOPTED when the
 * pid is alive AND is still the same process — identity is the pid's start time,
 * recorded when it was spawned (`pidStartTime`), because a pid alone is recycled
 * by the kernel and the command line is not identity either (a shell execs the
 * last command of its `-c` script, so a recorded `sh -c '… sleep 900'` is a live
 * `sleep 900`). A record without that fingerprint is refused, not guessed at.
 * An adopted task is polled — the `ChildProcess` died with the process that
 * owned it, so no `close` event is coming — with its exit reported as `was
 * stopped (signal …)` when a `stop_task` caused it and as an explicit *status
 * unknown* when it vanished unobserved. One summary message tells the model what
 * the fold found; `list_tasks` remains the authoritative view.
 *
 * Ownership is the SESSION ID that produced a record, never the pid. pi copies
 * every entry when a session is forked or cloned, so a fork can read the
 * parent's task records — and must not adopt them: two processes watching one
 * task would report one exit twice and could signal a process that is not
 * theirs. Such records are `foreign`: listed for reference (only with
 * `include_finished`), refused by `wait_task`/`stop_task`/`task_input`, never
 * reported. Two processes on the SAME session are the other side of that coin —
 * pi takes no lock on the session file — so the process that adopts a task
 * appends a `pi2_bg_tasks_claim` entry (a `type: "custom"` entry: persisted, not
 * model context) naming its pid, and a later process honours an unexpired claim
 * from a live pid instead of adopting the same task a second time. On `quit`
 * the instance appends `pi2_bg_task_shutdown` with the ids it is about to kill,
 * so the next process reads those as `stopped (SIGKILL)` instead of having to
 * guess; if that write is lost, the pid-liveness check downstream still gives
 * the truthful (if vaguer) answer.
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
 * marks what it injects, so an injection is repeated only when the request it
 * went into failed (an injection is not durable — see stage 3 above).
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
import type { BashToolDetails, BashToolInput, SessionEntry, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { execFileSync, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, createWriteStream, openSync, readFileSync, readSync, statSync, unlinkSync } from "node:fs";
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
 * How many records are rebuilt from the transcript. A session accumulates
 * history forever; only the newest records are worth reconstructing.
 */
const MAX_FOLDED_TASKS = 60;
/**
 * How long a "still running" record stays adoptable. A pid recycled after a day
 * is far more likely to belong to something else, and an adopted task only
 * exists to keep `wait_task`/`stop_task` usable across a reload or a crash.
 */
const MAX_ADOPT_AGE_MS = 24 * 60 * 60 * 1000;
/** Liveness poll interval for an adopted (or foreign) task — no `close` event. */
const ADOPT_POLL_MS = 1_000;
/**
 * Custom entries (never model context) that carry ownership bookkeeping: a
 * process that ADOPTS a task claims it, and a process that quits records the
 * task ids it killed.
 */
const CLAIM_TYPE = "pi2_bg_tasks_claim";
const SHUTDOWN_TYPE = "pi2_bg_task_shutdown";
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
	/**
	 * Identity of the process `pid` names, read when it was spawned (see
	 * `pidStartTime`). A pid alone cannot be trusted across a crash — the kernel
	 * recycles it — so adoption verifies that the pid is still the *same*
	 * process, not merely a live one.
	 */
	pidStartTime?: string;
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
	/**
	 * The session that PRODUCED this record. Ownership of a background task is
	 * that id, never the pid: a forked/cloned session inherits the transcript
	 * (and with it these entries) but not the processes, so it must not adopt
	 * — and must not wait on or signal — a task another session started.
	 */
	sessionId?: string;
}

/** Module-level task table; read by the context handler and the renderers. */
interface BgTaskState {
	taskId: string;
	command: string;
	outputFile: string;
	startedAt: number;
	endedAt?: number;
	pid?: number;
	/** The spawned process's start time, the identity check for an adopted pid. */
	pidStartTime?: string;
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
	 * Whether this record was rebuilt from the transcript rather than spawned by
	 * this process — either adopted (a `/reload`, or a resume after a crash) or a
	 * foreign record from a fork. Neither has a `ChildProcess` behind it, so the
	 * exit is discovered by polling and the status can be genuinely unknown.
	 */
	adopted?: boolean;
	/** The process is gone but nobody saw it exit, so the status is unknowable. */
	exitUnknown?: boolean;
	/** Liveness poll for an adopted task; cleared when the task settles. */
	adoptPoll?: ReturnType<typeof setInterval>;
	/** The session that produced the record this task was rebuilt from. */
	sessionId?: string;
	/**
	 * The record belongs to another session (a fork/clone of the one that
	 * started it) or is watched by another pi process. It is listed for
	 * reference, never adopted, waited on, signalled or reported.
	 */
	foreign?: boolean;
	/** Why it is foreign: another session, or another live pi process. */
	foreignNote?: string;
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

const tasks = new Map<string, BgTaskState>();
/** Background process groups to kill best-effort when the pi process exits. */
const trackedPids = new Set<number>();
let exitHookInstalled = false;
/**
 * Session whose transcript this process folds, and the owner id its own records
 * carry. Set on `session_start`.
 */
let currentSessionId: string | undefined;

/** A task record rebuilt from this session's transcript. */
interface FoldedTask {
	taskId: string;
	command: string;
	outputFile: string;
	/** The session that produced the record — the task's owner. */
	sessionId?: string;
	startedAt?: number;
	endedAt?: number;
	pid?: number;
	/** The identity of that pid, recorded when the task was spawned. */
	pidStartTime?: string;
	completed: boolean;
	exitCode: number | null;
	signal: string | null;
	/** The process vanished without anyone observing how it ended. */
	exitUnknown?: boolean;
}

/** Ownership claim appended by the pi process that adopted a task. */
interface TaskClaim {
	pid?: number;
	at?: number;
	sessionId?: string;
}

/** First 8 characters of a session id, for model-facing text. */
function shortSessionId(id: string | undefined): string {
	if (!id) {
		return "unknown";
	}
	return id.length > 8 ? id.slice(0, 8) : id;
}

/**
 * Rebuild the task table from the session transcript.
 *
 * The transcript is the single source of truth: every state transition already
 * reaches it as a `pi2_bg_task` custom message (`started` carries command/pid/
 * outputFile/startedAt/sessionId, a terminal one the exit status), so a reload
 * or a resumed session needs no sidecar file and cannot drift from it. Two
 * `type: "custom"` entries carry the bookkeeping that is nobody's business but
 * ours (they never enter model context): an adoption CLAIM, and the ids a
 * quitting process killed.
 *
 * Folding mirrors `lua/pi/tasks.lua:handle_event` on purpose — the model-facing
 * table and the frontend panel must agree about what happened.
 *
 * `getEntries()` returns EVERY entry, in append order, across branches: a task
 * started on a branch that is no longer active is still visible here.
 */
function foldTaskEntries(
	entries: readonly SessionEntry[],
): { records: FoldedTask[]; claims: Map<string, TaskClaim> } {
	const order: string[] = [];
	const byId = new Map<string, FoldedTask>();
	const claims = new Map<string, TaskClaim>();

	const ensure = (taskId: string, details?: BgTaskDetails): FoldedTask => {
		let record = byId.get(taskId);
		if (!record) {
			record = { taskId, command: "", outputFile: "", completed: false, exitCode: null, signal: null };
			byId.set(taskId, record);
			order.push(taskId);
		}
		if (details) {
			if (!record.command && typeof details.command === "string") {
				record.command = details.command;
			}
			if (!record.outputFile && typeof details.outputFile === "string") {
				record.outputFile = details.outputFile;
			}
			if (record.pid === undefined && typeof details.pid === "number") {
				record.pid = details.pid;
			}
			if (record.pidStartTime === undefined && typeof details.pidStartTime === "string") {
				record.pidStartTime = details.pidStartTime;
			}
			if (record.sessionId === undefined && typeof details.sessionId === "string") {
				record.sessionId = details.sessionId;
			}
		}
		return record;
	};

	for (const entry of entries) {
		if (entry.type === "custom") {
			const data = entry.data as
				| { taskId?: unknown; taskIds?: unknown; pid?: unknown; at?: unknown; sessionId?: unknown; signal?: unknown }
				| undefined;
			if (entry.customType === CLAIM_TYPE && typeof data?.taskId === "string") {
				claims.set(data.taskId, {
					pid: typeof data.pid === "number" ? data.pid : undefined,
					at: typeof data.at === "number" ? data.at : undefined,
					sessionId: typeof data.sessionId === "string" ? data.sessionId : undefined,
				});
			} else if (entry.customType === SHUTDOWN_TYPE && Array.isArray(data?.taskIds)) {
				const signal = typeof data.signal === "string" ? data.signal : "SIGKILL";
				const stamp = Date.parse(entry.timestamp);
				for (const id of data.taskIds) {
					if (typeof id !== "string") {
						continue;
					}
					const record = ensure(id);
					record.completed = true;
					record.endedAt = Number.isFinite(stamp) ? stamp : Date.now();
					record.signal = signal;
					record.exitCode = null;
				}
			}
			continue;
		}
		if (entry.type !== "custom_message" || entry.customType !== CUSTOM_TYPE) {
			continue;
		}
		const details = entry.details as BgTaskDetails | undefined;
		if (!details || typeof details.taskId !== "string" || details.taskId === "") {
			continue;
		}
		const record = ensure(details.taskId, details);
		const stamp = Date.parse(entry.timestamp);
		if (details.kind === "started") {
			// A duplicate (or late) `started` for a settled task must not resurrect it.
			if (record.completed) {
				continue;
			}
			const startedAt = typeof details.startedAt === "number" ? details.startedAt : stamp;
			if (record.startedAt === undefined && Number.isFinite(startedAt)) {
				record.startedAt = startedAt;
			}
			continue;
		}
		record.completed = true;
		record.endedAt = Number.isFinite(stamp) ? stamp : Date.now();
		record.exitCode =
			details.exitCode === undefined ? (details.kind === "completed" ? 0 : null) : details.exitCode;
		record.signal = details.signal ?? null;
		record.exitUnknown = record.exitCode === null && record.signal === null;
	}

	const records = order
		.map((id) => byId.get(id))
		.filter((record): record is FoldedTask => record !== undefined)
		.sort((a, b) => (b.startedAt ?? b.endedAt ?? 0) - (a.startedAt ?? a.endedAt ?? 0))
		.slice(0, MAX_FOLDED_TASKS);
	return { records, claims };
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
 * Start time of a live process — its identity, as far as adoption cares.
 *
 * A pid recorded by a dead process can be recycled by anything, and acting on
 * the new owner (a SIGKILL from `stop_task`, a `wait_task` that never settles)
 * is worse than admitting the record is stale. The pid's start time is the
 * cheap, exact discriminator: it is stable for the life of the process (an
 * exec does not change it) and differs for every later process reusing the
 * number.
 *
 * Reading it from the command line instead (what this used to do) is *not*
 * exact: a shell execs the last command of its `-c` script, so the recorded
 * `sh -c 'build && serve'` becomes a live `serve` — nothing on the command
 * line matches the text that was recorded. Identity must not depend on how the
 * shell chose to exec.
 *
 * `/proc` is Linux-only; elsewhere `ps -o lstart=` is the same field, and both
 * sides of the comparison go through this function so the format always agrees.
 */
function pidStartTime(pid: number): string | undefined {
	if (!Number.isInteger(pid) || pid <= 1) {
		return undefined;
	}
	try {
		const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
		// `comm` (field 2) is parenthesised and may itself contain ")" or spaces,
		// so the fields after it are counted from the LAST ")" — the first one
		// after that is field 3, which makes starttime (field 22) index 19.
		const after = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
		const start = after[19];
		return start === undefined || start === "" ? undefined : start;
	} catch {
		// No `/proc` (macOS/BSD), or the pid is gone: fall back to `ps` below.
	}
	try {
		const out = execFileSync("ps", ["-o", "lstart=", "-p", String(pid)], {
			encoding: "utf8",
			timeout: 2_000,
			stdio: ["ignore", "pipe", "ignore"],
		});
		const trimmed = out.trim();
		return trimmed === "" ? undefined : trimmed;
	} catch {
		return undefined;
	}
}

/**
 * Whether `pid` is still the very process whose start time was recorded.
 *
 * A record with no fingerprint (written by an older pi, or by a session that
 * never got a pid) is refused rather than guessed at: adopting the wrong
 * process is the one outcome this check exists to prevent.
 */
function pidIsRecordedProcess(pid: number, recorded: string | undefined): boolean {
	if (recorded === undefined) {
		return false;
	}
	return pidStartTime(pid) === recorded;
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
		// Nothing can be appended to the transcript from here (the session is
		// already disposed); `session_shutdown` records the same kills while it
		// still can, and a SIGKILLed process leaves "running" records that the
		// next instance resolves by pid liveness.
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
	if (task.exitUnknown) {
		return "is no longer running (no pi process was watching when it ended, so its exit status is unknown)";
	}
	if (task.signal !== null) {
		return `was stopped (signal ${task.signal})`;
	}
	return `exited with code ${task.exitCode}`;
}

/**
 * Machine-readable status of a report element. Deliberately NOT the panel's
 * `kind` vocabulary (see `reportPanel`, which opens with "started" instead of
 * "running"): this one is the model-facing word for what happened.
 */
function reportStatus(task: BgTaskState): "running" | "completed" | "failed" | "stopped" | "unknown" {
	if (!task.completed) {
		return "running";
	}
	if (task.spawnError) {
		return "failed";
	}
	if (task.signal !== null) {
		return "stopped";
	}
	// An adopted task that vanished unobserved has no exit code and no signal:
	// calling that "failed" would contradict the prose line right above it.
	if (task.exitUnknown) {
		return "unknown";
	}
	if (task.exitCode === 0) {
		return "completed";
	}
	return "failed";
}

/**
 * Escape a value for element TEXT. `&` and `<` are the only characters that can
 * open or end a tag inside a text node, so `>` and `"` are left alone — real
 * output (`a > b`, `"quoted"`) stays readable, and nothing can forge the
 * delimiters around the block.
 */
function escapeText(value: string): string {
	return value.replace(/&/g, "&amp;").replace(/</g, "&lt;");
}

/**
 * Escape a value for an ATTRIBUTE (or a "…" in the prose line): `escapeText`
 * plus `>` and `"`. Attribute values are arbitrary shell text too — a command
 * like `awk '{print $1}' && echo "<done>"` must not be able to close the quote
 * or the tag.
 */
function escapeAttr(value: string): string {
	return escapeText(value).replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Attributes of one `<background-task>` element, in a fixed order. */
function taskAttrs(task: BgTaskState): string {
	const durationMs = (task.endedAt ?? Date.now()) - task.startedAt;
	return [
		`id="${task.taskId}"`,
		`status="${reportStatus(task)}"`,
		`exit_code="${task.exitCode ?? ""}"`,
		`signal="${task.signal ?? ""}"`,
		`duration_ms="${durationMs}"`,
		`output="${escapeAttr(task.outputFile)}"`,
	].join(" ");
}

/**
 * One reminder block around a report payload. Both builders go through this
 * single helper, so the delimiters a reader (a model, a test) looks for can
 * never drift apart between the single and the batched form.
 */
function wrapReminder(body: string): string {
	return `<system-reminder>\n${body}\n</system-reminder>`;
}

/**
 * Completion report text for the wake path. Shared by sendMessage and the
 * context fallback so the agent sees exactly the same text either way — stage 3
 * of the ladder above compares the `sentText` it stored, so nothing here may
 * vary between the two callers.
 *
 * The "[SYSTEM NOTIFICATION ...]" banner stays the first line for the same
 * reason Claude Code added it: this lands in the agent's context as a user-role
 * message, and without the banner models read it as human input (and sometimes
 * as approval for whatever they proposed before going quiet). Under it: one
 * prose line, then a reminder block carrying one `<background-task>` element
 * whose attributes say what happened without a reader having to parse the
 * sentence.
 */
function buildWakeNote(task: BgTaskState): string {
	const elapsed = formatSeconds((task.endedAt ?? Date.now()) - task.startedAt);
	const tail = readOutputTail(task.outputFile, WAKE_TAIL_BYTES, WAKE_TAIL_LINES);
	const head =
		`Background task ${task.taskId} ("${escapeAttr(task.command)}") ` +
		`${escapeText(describeExit(task))} after ${elapsed}.`;
	// Only the TEXT of the tail is escaped (attributes need more): output is
	// arbitrary program output and may well print `</system-reminder>`.
	const lines = tail.text.trim()
		? [
				`${head} Output tail:`,
				"",
				escapeText(tail.text),
				`Full output: ${escapeText(task.outputFile)} (or wait_task ${task.taskId}).`,
			]
		: [head, "No output tail was read: the output file above is the only copy of its output."];
	return (
		`[SYSTEM NOTIFICATION - NOT USER INPUT]\n` +
		"This is an automated task notification, not a message from the user.\n" +
		wrapReminder(`<background-task ${taskAttrs(task)}>\n${lines.join("\n")}\n</background-task>`)
	);
}

/**
 * One report for every task that finished since the last flush.
 *
 * A single task keeps the full wake note (status + output tail). Several tasks
 * share ONE message with one element per task and no tails: a burst of
 * completions must not push N × 4 KB of tails into context, and the model can
 * read the files (or call `wait_task` on any id) when it actually needs the
 * output. This mirrors what the other frontends do — push a signal, let the
 * reader pull the detail.
 */
function buildBatchNote(batch: BgTaskState[]): string {
	if (batch.length === 1) {
		return buildWakeNote(batch[0]);
	}
	const elements = batch.map(
		(task) => `<background-task ${taskAttrs(task)}>${escapeText(task.command)}</background-task>`,
	);
	// ONE sentence (docs/usage.md and docs/extensions.md both say line 2 is a
	// single sentence): banner, then this, then the block.
	const notice =
		"This is an automated task notification, not a message from the user: several background " +
		"tasks finished together, and their output tails are omitted — read the files (or call " +
		"wait_task on a task id) if you need the output.";
	return `[SYSTEM NOTIFICATION - NOT USER INPUT]\n${notice}\n${wrapReminder(elements.join("\n"))}`;
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
	// Reconciling with the transcript. `session_start` fires for every kind of
	// start — including the one right after `/reload`, where the processes are
	// still running but their `ChildProcess` handles died with the old module
	// instance — so this is where this session's own records become usable
	// tasks again.
	//
	// Ownership is the SESSION ID that produced a record, never the pid. A
	// forked or cloned session inherits the parent transcript (pi copies every
	// entry), so its records are readable but not adoptable: adopting them
	// would leave two processes watching — and reporting, and able to signal —
	// one task. `list_tasks` still shows them, marked with their owner.
	// ------------------------------------------------------------------
	/** Summary of what the transcript held, delivered once (not per request). */
	let startupNote: { text: string } | undefined;

	function restoreTask(record: FoldedTask): BgTaskState {
		let resolveExited = (): void => {};
		const exited = new Promise<void>((resolve) => {
			resolveExited = resolve;
		});
		const task: BgTaskState = {
			taskId: record.taskId,
			command: record.command,
			outputFile: record.outputFile,
			startedAt: record.startedAt ?? Date.now(),
			completed: record.completed,
			exitCode: record.exitCode,
			signal: record.signal,
			// A restored terminal record was reported when it ended; re-delivering
			// that report now would be a stale wake.
			delivery: record.completed ? "confirmed" : "none",
			panelStarted: false,
			observers: 0,
			adopted: true,
			stdinOpen: false,
			exited,
			resolveExited: () => resolveExited(),
		};
		if (record.endedAt !== undefined) {
			task.endedAt = record.endedAt;
		}
		if (record.pid !== undefined) {
			task.pid = record.pid;
		}
		if (record.pidStartTime !== undefined) {
			task.pidStartTime = record.pidStartTime;
		}
		if (record.exitUnknown) {
			task.exitUnknown = true;
		}
		if (record.sessionId !== undefined) {
			task.sessionId = record.sessionId;
		}
		return task;
	}

	/**
	 * Poll a restored task's pid. Neither an adopted nor a foreign task has a
	 * `ChildProcess` (`close` event) left to fire, so its exit is discovered by
	 * polling. Whether the discovery is *reported* is decided by `delivery`:
	 * an owned task may wake the model, a foreign one never does.
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

	/**
	 * Record that this process now watches `task`.
	 *
	 * Two pi processes *can* open the same session (pi takes no lock on the
	 * session file), and both would otherwise adopt the same pid and report the
	 * same exit twice. The claim is a `type: "custom"` entry — persisted with the
	 * session, never part of model context — and a later process honours it
	 * while the claiming pid is still alive.
	 */
	function claimTask(task: BgTaskState): void {
		try {
			pi.appendEntry(CLAIM_TYPE, {
				taskId: task.taskId,
				pid: process.pid,
				at: Date.now(),
				sessionId: currentSessionId,
			});
		} catch {
			// A claim is a mutual-exclusion hint; losing it must not break adoption.
		}
	}

	function reconcileSession(ctx: ExtensionContext): void {
		const sessionId = ctx.sessionManager.getSessionId();
		if (!sessionId || sessionId === currentSessionId) {
			return;
		}
		currentSessionId = sessionId;
		const { records, claims } = foldTaskEntries(ctx.sessionManager.getEntries());
		if (records.length === 0) {
			return;
		}

		const now = Date.now();
		const rows: string[] = [];
		let adopted = 0;
		let foreign = 0;
		let claimed = 0;
		let stale = 0;
		for (const record of records) {
			if (tasks.has(record.taskId)) {
				continue;
			}
			const task = restoreTask(record);
			tasks.set(record.taskId, task);
			const command = record.command.replace(/\s+/g, " ").trim() || "(unknown command)";
			if (record.completed) {
				// History. A resumed session has hundreds of these and each one would
				// be noise in the summary; `list_tasks(include_finished: true)` is
				// where they belong.
				continue;
			}
			if (record.sessionId !== sessionId) {
				foreign += 1;
				task.foreign = true;
				task.foreignNote = `session ${shortSessionId(record.sessionId)}`;
				task.delivery = "confirmed";
				watchAdopted(task);
				rows.push(
					`- ${task.taskId} ("${command}") belongs to session ${shortSessionId(record.sessionId)} (pid ${record.pid ?? "?"}); it is not this session's to adopt. Output: ${record.outputFile}`,
				);
				continue;
			}
			const claim = claims.get(record.taskId);
			if (
				claim !== undefined &&
				claim.sessionId === sessionId &&
				claim.pid !== undefined &&
				claim.pid !== process.pid &&
				pidAlive(claim.pid) &&
				now - (claim.at ?? 0) < MAX_ADOPT_AGE_MS
			) {
				claimed += 1;
				task.foreign = true;
				task.foreignNote = `pi process ${claim.pid}`;
				task.delivery = "confirmed";
				watchAdopted(task);
				rows.push(
					`- ${task.taskId} ("${command}") is being watched by another pi process (pid ${claim.pid}); leaving it to that process. Output: ${record.outputFile}`,
				);
				continue;
			}
			const adoptable =
				record.pid !== undefined &&
				record.startedAt !== undefined &&
				record.startedAt > now - MAX_ADOPT_AGE_MS &&
				pidAlive(record.pid) &&
				pidIsRecordedProcess(record.pid, record.pidStartTime);
			if (!adoptable) {
				stale += 1;
				task.completed = true;
				task.exitUnknown = true;
				task.delivery = "confirmed";
				rows.push(
					`- ${task.taskId} ("${command}") was recorded as running, but pid ${record.pid ?? "?"} is gone or no longer runs it, so its exit status is unknown. Output: ${record.outputFile}`,
				);
				continue;
			}
			adopted += 1;
			watchAdopted(task);
			claimTask(task);
			rows.push(
				`- ${task.taskId} ("${command}") is STILL RUNNING (pid ${record.pid}, started ${formatSeconds(now - (record.startedAt ?? now))} ago). Output: ${record.outputFile}`,
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
			foreign > 0 ? `${foreign} from another session` : "",
			claimed > 0 ? `${claimed} watched by another pi process` : "",
			stale > 0 ? `${stale} unverifiable` : "",
		].filter((part) => part !== "");
		const shown = rows.slice(0, MAX_LISTED_TASKS);
		const hidden =
			rows.length > shown.length ? `\n(${rows.length - shown.length} older record(s) not shown; list_tasks sees all of them.)` : "";
		startupNote = {
			text:
				`[SYSTEM NOTIFICATION - NOT USER INPUT]\n[Background bash tasks found in this session's transcript: ${rows.length} — ${counts.join(", ")}]\n` +
				`${shown.join("\n")}${hidden}\n` +
				"This is an automated startup report, not a message from the user. A task listed as running in THIS session was started before this process: wait_task, stop_task, task_input and list_tasks work on it exactly as on a task you start now, and its exit is reported when its pid disappears. A record that belongs to another session (a fork or clone of this one) or to another pi process is listed for reference only — it cannot be waited on, fed or stopped from here. Do not start a second copy of something listed above as still running.",
		};
		try {
			pi.sendMessage({ customType: CUSTOM_TYPE, content: startupNote.text, display: false }, undefined);
		} catch {
			// Not deliverable yet: the `context` handler injects it before the first
			// request instead (the same fallback the wake reports use).
		}
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

	pi.on("session_shutdown", (event) => {
		// This instance is going away — replaced by a reload/session switch, or
		// followed by the exit hook. Stop polling adopted tasks first: the
		// successor folds the same records and watches them again, and a stale
		// poller would report one exit twice.
		for (const task of tasks.values()) {
			if (task.adoptPoll) {
				clearInterval(task.adoptPoll);
				task.adoptPoll = undefined;
			}
		}
		// Only a quit ends these processes: `reload`, `new`, `resume` and `fork`
		// replace the extension instance while the tasks keep running, and their
		// records must stay "running" for the successor to adopt.
		if (event.reason !== "quit") {
			return undefined;
		}
		const killed: string[] = [];
		for (const task of tasks.values()) {
			if (!task.completed && task.pid !== undefined && trackedPids.has(task.pid)) {
				killed.push(task.taskId);
			}
		}
		if (killed.length === 0) {
			return undefined;
		}
		// Best effort by construction: if this does not reach the file, the next
		// process resolves the same tasks by pid liveness and calls them unknown.
		try {
			pi.appendEntry(SHUTDOWN_TYPE, { taskIds: killed, signal: "SIGKILL", at: Date.now() });
		} catch {
			// Nothing else to do here; the exit hook kills the processes either way.
		}
		return undefined;
	});

	// ------------------------------------------------------------------
	// Delivery receipt + last-resort injector. `context` is the exact message
	// list about to be sent to the model, so it settles delivery truthfully:
	// the text we handed over earlier is either in there (confirmed) or it is
	// not (dropped by an abort, a discarded steering queue, or a stale extension
	// ctx — inject it now). A task stops being a candidate as soon as its text is
	// observed in the payload, so a delivered report is never injected twice; a
	// report injected into a request that then FAILED is still outstanding, and
	// injecting it again into the retry is exactly the point. `event.messages` is
	// a deep copy; nothing here is persisted.
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
			// The injection lives in a per-request deep copy that is never
			// persisted, so handing it over proves nothing: the report stays
			// `sent` until a completed `turn_end` shows the request arrived.
			markSent(task, "fallback", text);
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

	pi.on("turn_end", (event) => {
		// The request this turn belongs to finished, so a report the `context`
		// fallback injected into it was actually seen. Any other outcome means the
		// request died (provider error, abort) and took the injection with it;
		// the report stays `sent` and the next attempt injects it again.
		if (event.outcome === "completed") {
			confirmFallbackReports();
		}
		return deliverAtBoundary(event);
	});

	pi.on("agent_before_settle", (event) => deliverAtBoundary(event));

	pi.on("agent_settled", (event) => {
		busy = false;
		if (event.aborted) {
			// The user asked for the run to stop: keep the report (it is already
			// committed for an aborted turn, or stays pending) and let the next
			// `context` deliver it. Waking here would fight the abort.
			return undefined;
		}
		// A report that only a failed request ever carried is invisible to both
		// durable channels; hand it back to them before the flush below.
		rearmLostFallbacks();
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
			outputFile,
			// The owner. Everything this process reports carries it, which is what
			// keeps a fork from adopting (or signalling) this session's tasks.
			sessionId: currentSessionId,
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
			task.pidStartTime = pidStartTime(child.pid);
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
		// Nothing to write here: the `started` message this task reports (below, on
		// the background paths) is the transcript record a later process folds.
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
		// An adopted task has nobody to report its exit: keep the signal this
		// process established (`stop_task` records what it sent) instead of
		// overwriting it with the `null` the liveness poll can offer.
		if (code !== null) {
			task.exitCode = code;
		}
		if (signal !== null) {
			task.signal = signal;
		}
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
	 * payload or carried by a tool result — never at send time, and never merely
	 * because it was injected (an injection is not durable).
	 */
	function markConfirmed(task: BgTaskState): void {
		task.delivery = "confirmed";
	}

	/**
	 * Confirm reports that only the `context` fallback has carried so far. Called at
	 * a `turn_end` whose outcome is `completed`: that request — which is the one the
	 * injection was added to — finished, so the model saw the text. An `error` or
	 * `aborted` outcome leaves the report `sent` and the next attempt injects it
	 * again, because nothing about that request survives.
	 */
	function confirmFallbackReports(): void {
		for (const task of tasks.values()) {
			if (task.delivery === "sent" && task.sentVia === "fallback") {
				markConfirmed(task);
			}
		}
	}

	/**
	 * Hand a report whose only carrier was a failed request back to the durable
	 * channels. An injection is not persisted, and while the run retries the
	 * `context` handler re-injects it into the next attempt; but a run that settles
	 * without a `completed` turn_end (retries exhausted, hard provider failure)
	 * leaves it `sent` and nothing would ever look at it again — `flushPending` and
	 * `deliverAtBoundary` carry only `none`. Re-arming it as `none` makes the
	 * settle's own wake deliver it as a persisted message, so a failed request can
	 * delay a report but never swallow it. Only the `fallback` channel is re-armed:
	 * a `wake`/`boundary` delivery is already durable.
	 */
	function rearmLostFallbacks(): void {
		for (const task of tasks.values()) {
			if (task.delivery === "sent" && task.sentVia === "fallback") {
				task.delivery = "none";
				task.sentText = undefined;
				task.sentVia = undefined;
				task.sentAt = undefined;
			}
		}
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
			pidStartTime: task.pidStartTime,
			outputFile: task.outputFile,
			exitCode: task.exitCode,
			signal: task.signal,
			// The message is stamped when it is sent, so an adopted task would
			// otherwise render as if it had just started.
			startedAt: task.startedAt,
			// Ownership: a session may only adopt/control tasks whose record names it.
			sessionId: task.sessionId ?? currentSessionId,
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

	/**
	 * Refuse to act on a task this session does not own.
	 *
	 * A forked or cloned session inherits the parent's transcript, so it can see
	 * records for processes it never started — and still running. Waiting on,
	 * feeding or signalling one of those would make two sessions fight over one
	 * process (one stop reported twice, one wake delivered to the wrong context),
	 * so the tools refuse it by name instead.
	 */
	function assertOwned(task: BgTaskState, tool: string): void {
		if (!task.foreign) {
			return;
		}
		throw new Error(
			`${tool}: task ${task.taskId} is not this session's to control — it belongs to ${task.foreignNote ?? "another session"}. The record came with this session's transcript (a fork or clone copies it), but the process is not ours to wait on, feed or signal. list_tasks shows it for reference.`,
		);
	}

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
			assertOwned(task, "wait_task");

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
			assertOwned(task, "stop_task");

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
			if (task.adopted) {
				// No `ChildProcess`, so no exit signal to read: the one we sent is the
				// only truthful account, and recording it NOW means the terminal report
				// says "stopped" even when the liveness poll notices the exit first.
				task.signal = "SIGTERM";
				task.exitUnknown = undefined;
			}
			let outcome = await waited;

			if (outcome === "deadline" && !task.completed) {
				escalated = true;
				waited = attachWait(task, { deadlineMs: STOP_KILL_SETTLE_MS, signal });
				signalled = signalProcessGroup(task.pid, "SIGKILL") || signalled;
				if (task.adopted) {
					task.signal = "SIGKILL";
				}
				outcome = await waited;
			}

			const tail = readOutputTail(task.outputFile, MAX_OUTPUT_BYTES, MAX_OUTPUT_LINES);
			const elapsed = formatSeconds((task.endedAt ?? Date.now()) - task.startedAt);

			if (task.completed) {
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
			assertOwned(task, "task_input");

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
			: task.foreign
				? `running elsewhere (${task.foreignNote ?? "another session"}) — not controllable here`
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
			// "Running" means running and OURS: a record inherited from a fork is
			// listed only when the caller asks for the full history, and is marked
			// with the session it belongs to.
			const running = all.filter((task) => !task.completed && !task.foreign);
			const listed = params.include_finished
				? all
				: all.filter((task) => !task.completed && !task.foreign);
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
				"\nUse stop_task(task_id) to stop one, wait_task(task_id) to block on one, task_input(task_id, data) to answer a prompt, or read its output file for the full log. A task marked \"running elsewhere\" belongs to another session and cannot be controlled from here.";
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
