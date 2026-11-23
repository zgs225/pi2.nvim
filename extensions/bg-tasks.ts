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
 *  - foreground (default) — stay attached for the attach window (`timeout` in
 *    seconds, default 2 minutes). If the process exits inside the window the
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
 *    delivered when the process exits with nobody attached. Whether it may BUY a
 *    provider request is the completion-wake policy below; a report that rides a
 *    turn which is going to continue anyway is always delivered for free.
 *
 * Delivery ladder (why it is four stages instead of one `sendMessage`). A
 * steering message is discarded when the run is aborted, so a report sent that
 * way can vanish with no trace; a `delivered` flag set at send time then hides
 * the loss from the fallback. Instead a report walks through
 * `none -> sent -> confirmed`, and only `confirmed` stops further delivery:
 *
 *  1. idle at exit -> `sendMessage(..., { triggerTurn: true })` starts a turn
 *     immediately, but only when `completionWakeHold` allows a paid turn (the
 *     default policy `never` does not). The wake is COALESCED: a short timer
 *     merges every completion of one burst (and of a settle that is about to
 *     flush anyway) into ONE message and ONE turn, instead of one wake per task,
 *     each paying a full context read;
 *  2. a run is active -> the next actionable boundary (`turn_end`, then
 *     `agent_before_settle`) appends ONE aggregated `custom_message` entry. A
 *     boundary that still has tool results is going to make a provider request
 *     anyway, so the entry rides it for free; a boundary with nothing left —
 *     the model just produced its final answer — is a PAID turn, decided by the
 *     same gate, and at most ONE such continuation is bought per run. Entries
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
 * a report that rides a continuing turn costs nothing, and a report that would
 * buy a turn stays pending for the next user turn. `wait_task` covers the case
 * where the model wants the result before it can say anything else — it blocks
 * server-side until the process exits or its own deadline hits. Both are
 * advertised in the bash tool description and in every result that starts or
 * hands off a task.
 *
 * `wait_task` can also wait for a LINE instead of an exit (`until`). A match
 * settles the call but does NOT consume the completion: the lease is released
 * and the process keeps running, so its exit report still arrives exactly once.
 * The watch is a literal, case-sensitive substring (no regex) scanned from
 * offset 0 in 250 ms increments, so a line printed earlier still counts.
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
 * Every task owns ONE log file, `tmpdir()/pi-bash-<taskId>.log`, because the log
 * is what `wait_task`, the panel and the wake tail all read. A foreground command
 * that exits cleanly and untruncated deletes its own file on the spot; a
 * background one is kept, since that task outlives the call that started it.
 * Those files are the one thing here that accumulates, so their lifetime is
 * explicit: a log nobody references any more dies of old age after
 * `DEFAULT_LOG_TTL_MS` (7 days, `LOG_TTL_ENV` overrides) and is removed by ONE
 * sweep at `session_start`, after the transcript fold. The sweep only ever
 * considers our own file-name shape, and never a task THIS process has a record
 * for — a live writer, an adopted task, or a row the user can still open.
 * Immediate deletion is the panel's `D`, not the sweep's job.
 *
 * Two NOTIFY-ONLY timers cover the other half of that hole — a task that runs
 * far longer than anyone expected while the agent simply never hears about it.
 * (1) `deadline_ms`, the model-facing bash parameter next to
 * `run_in_background`: when a task BECOMES a background task it is armed, and
 * on expiry it sends ONE check-in carrying the task id, its elapsed time and an
 * output tail. (2) An advisory lifetime note, armed for every background task
 * from `DEFAULT_MAX_LIFETIME_MS` (overridable through the `LIFETIME_ENV`
 * environment variable, read at arm time), sent once when the cap passes and
 * saying the process is NOT being killed. Neither timer kills, signals or
 * finishes anything: killing is `stop_task`'s job and the user's decision, and
 * the exit report still arrives through the ladder below exactly once. Both are
 * one-shot (`deadlineNoted` / `lifetimeNoted`), both are unref'd, both are
 * cleared in `finishTask`, and neither is ever armed for an adopted task. A
 * check-in is deliberately OUTSIDE the `none -> sent -> confirmed` ladder: it
 * carries no `details` (so it cannot fabricate a panel row), marks no delivery
 * state and is best-effort.
 *
 * The COMPLETION WAKE is the expensive path, so it is gated
 * (`completionWakeHold`). A completion is delivered for free when the turn it
 * joins has natural tool work; a completion that would BUY a provider request —
 * an idle wake, or the final answer's boundary — is priced by the whole
 * conversation, not by the report, and is harshest where it is least useful:
 * nobody at the editor, prompt cache expired (a wake minutes later re-reads
 * everything at full input price instead of the cache read), a task that
 * predates the newest user message (old news), or a report whose run already
 * bought its one continuation. So the paid branch consults a policy the frontend
 * publishes (`PREFS_ENV`, re-read per decision): `never` (default: no paid turn),
 * `budgeted` (`wake_budget` paid turns per user prompt, then hold), `failure`
 * (only a burst with a non-zero exit, signal, spawn error or unknown exit may
 * buy one), or `always` (the pre-policy behaviour; bypasses every rule). A held
 * report is NOT dropped and gets no new channel: it stays `none`, so the next
 * boundary with natural work, the user's next turn, or the `context` fallback
 * carries it exactly as before. What the hold adds is the REASON (`policy` /
 * `absent` / `cache` / `stale` / `failure` / `continuation` / `budget`), shown by
 * `:PiTasks` and `list_tasks`, because a hold nobody can explain reads as a lost
 * report.
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
 * `display: false` custom messages. They are only pushed for tasks that actually
 * become background tasks — a foreground command that finishes inside its window
 * never touches the panel. Every panel send passes `{ triggerTurn: false }`
 * EXPLICITLY: without options `pi.sendMessage` defaults to `deliverAs: "steer"`
 * while a run is active, and a steering message is queued as new input and opens
 * a turn of its own. A status ping that buys a turn is indistinguishable from
 * autonomous work, which is exactly the bug this contract exists to prevent.
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
import { closeSync, createWriteStream, openSync, readFileSync, readSync, readdirSync, statSync, unlinkSync } from "node:fs";
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
/**
 * Poll interval for a `wait_task({ until })` text watch: slower than the live
 * ticker because a readiness line is not a live view, and far below any attach
 * window it runs inside.
 */
const UNTIL_POLL_MS = 250;
/**
 * Longest accepted `until` needle. There is no regex syntax, so a short literal
 * is always enough — a longer one would only buy scan cost.
 */
const MAX_UNTIL_LENGTH = 512;
/** Line count is only computed when the log is small enough to read whole. */
const COUNT_LINES_UP_TO_BYTES = 8 * 1024 * 1024;
/** Bound on the output tail inlined in a wake report. */
const WAKE_TAIL_LINES = 40;
const WAKE_TAIL_BYTES = 4 * 1024;
/** Bound on the output tail inlined in a check-in (smaller: it is advisory). */
const CHECK_IN_TAIL_LINES = 20;
const CHECK_IN_TAIL_BYTES = 2 * 1024;
/**
 * `deadline_ms` bounds: a deadline produces ONE check-in, never a kill, so the
 * only thing worth bounding is how far out a model may point it.
 */
const MIN_DEADLINE_MS = 500;
const MAX_DEADLINE_MS = 24 * 60 * 60 * 1000;
/**
 * Advisory lifetime cap for every background task: after this, ONE note says
 * the task is still running and that it is not being killed. Overridable per
 * process through `LIFETIME_ENV` (milliseconds), which is read LAZILY when a
 * timer is armed — a child process's environment therefore applies.
 */
const DEFAULT_MAX_LIFETIME_MS = 24 * 60 * 60 * 1000;
const LIFETIME_ENV = "PI_BG_TASK_MAX_LIFETIME_MS";
/** Default lifetime of a finished task's log; the sweep deletes anything older. */
const DEFAULT_LOG_TTL_MS = 7 * 24 * 60 * 60 * 1000;
/** Overrides `DEFAULT_LOG_TTL_MS` (milliseconds), read when the sweep runs. */
const LOG_TTL_ENV = "PI_BG_TASK_LOG_TTL_MS";
/** The only files the sweep may touch: the logs THIS extension writes. */
const LOG_FILE_PATTERN = /^pi-bash-(b[0-9a-f]{6})\.log$/;
/**
 * Where the frontend publishes its completion-wake policy (JSON:
 * `{wake_on_completion, wake_budget, wake_cache_window_ms, present}`), re-read at
 * every decision so a live `setup()` call or a focus change applies without
 * respawning the process. Absent file = defaults (see `readWakePrefs`).
 */
const PREFS_ENV = "PI_NVIM_BG_TASKS_FILE";
/**
 * What a completion may buy: nothing (`never`, the default), a bounded number of
 * paid turns (`budgeted`), a paid turn only when the burst contains a failure
 * (`failure`), or a turn on every completion (`always`). "Paid" means a provider
 * request that would not otherwise happen; a report that rides a boundary with
 * natural tool work is always delivered for free.
 */
const WAKE_POLICIES = ["never", "budgeted", "failure", "always"] as const;
type WakePolicy = (typeof WAKE_POLICIES)[number];
const DEFAULT_WAKE_POLICY: WakePolicy = "never";
/** Paid wakes allowed per user prompt under `budgeted` and `failure`. */
const DEFAULT_WAKE_BUDGET = 2;
const MAX_WAKE_BUDGET = 10;
/**
 * How stale the prompt cache may be before an idle wake is held. A wake costs
 * one full request priced by the CONVERSATION, and a request after the cache
 * lifetime (5 minutes by default) re-reads all of it at full input price instead
 * of the cache-read price. 0 disables the window.
 */
const DEFAULT_WAKE_CACHE_WINDOW_MS = 5 * 60 * 1000;
/** Anything longer than a day is a typo, not a policy. */
const MAX_WAKE_CACHE_WINDOW_MS = 24 * 60 * 60 * 1000;
/**
 * Grace window for an idle wake: a message sent this recently may still be on
 * its way into context, so the `context` fallback waits one boundary before
 * concluding it was dropped. Only applies to the `wake` channel — boundary
 * entries are durable and are read from context on the very next request.
 */
const IDLE_WAKE_GRACE_MS = 5_000;
/**
 * How long an idle completion waits for companions. Two tasks that exit in the
 * same event-loop tick would otherwise send two wakes — two turns, each paying a
 * full context read for one burst. A short timer merges the burst (and merges it
 * with a settle that is about to flush anyway); 40 ms is far below the delay a
 * human or a model can perceive in a wake.
 */
const WAKE_COALESCE_MS = 40;
/**
 * How many times one report may be re-armed after a run settled carrying it only
 * through a failed request (see `rearmLostFallbacks`). Bounded on purpose: a
 * provider that keeps producing new runs without ever accepting a request would
 * otherwise cycle settle -> re-arm -> wake -> settle with no user input at all.
 * Past the cap the report stays `sent` and still rides the `context` fallback on
 * the next user turn, so nothing is lost — only the wake loop is.
 */
const MAX_REARMS = 3;

/** How far a completion report has got on its way into model context. */
type DeliveryState = "none" | "sent" | "confirmed";
/**
 * Why a completion report was HELD instead of spent. Recorded on the task so the
 * panel and `list_tasks` can explain it — a hold nobody can see is
 * indistinguishable from a report that was lost.
 */
type HoldReason = "policy" | "absent" | "cache" | "stale" | "failure" | "continuation" | "budget";

/** The frontend-published completion-wake policy (see `PREFS_ENV`). */
interface WakePrefs {
	policy: WakePolicy;
	budget: number;
	cacheWindowMs: number;
	/** Whether a human is at the editor (frontend `FocusGained`/`FocusLost`). */
	present: boolean;
}
/** Channel that carried a report's text. */
type DeliveryChannel = "boundary" | "wake" | "fallback" | "tool-result";

/** Payload of the display:false custom messages the frontend (pi.nvim) receives. */
interface BgTaskDetails {
	kind: "started" | "completed" | "failed" | "stopped" | "unknown";
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
	/** Set when the report is waiting for the next user turn, not for a wake. */
	held?: HoldReason;
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
	 * Why the paid completion for this report was held (see `completionWakeHold`). Cleared
	 * as soon as a channel carries the report, so the panel never shows a stale
	 * reason for a report that has since been delivered.
	 */
	held?: HoldReason;
	/** When the hold was recorded (ms), so the UI can age it. */
	heldAt?: number;
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
	/**
	 * The one deadline check-in, and the one advisory lifetime note. Both are
	 * NOTIFY-ONLY, one-shot, unref'd, and cleared in `finishTask`; neither is ever
	 * armed for an adopted task (its timers died with the process that armed them).
	 */
	deadlineTimer?: ReturnType<typeof setTimeout>;
	lifetimeTimer?: ReturnType<typeof setTimeout>;
	/** The single deadline check-in has been sent. */
	deadlineNoted?: boolean;
	/** The single lifetime note has been sent. */
	lifetimeNoted?: boolean;
	/**
	 * How many times this report has been re-armed because the only carrier it
	 * ever had was a failed request (`rearmLostFallbacks`). Capped by `MAX_REARMS`
	 * so a provider that never accepts a request cannot cycle settle -> re-arm ->
	 * wake -> settle forever; past the cap the report stays `sent` and the next
	 * user turn's `context` fallback carries it.
	 */
	rearmCount?: number;
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
 * The pending coalesced idle wake, if one is queued. Module-level because the
 * exit hook and `session_shutdown` have to clear it, and because one burst must
 * never queue two.
 */
let wakeTimer: ReturnType<typeof setTimeout> | undefined;
/**
 * Whether this process already swept stale log files. Once per process is the
 * whole policy: a `/reload` re-evaluates the module, and the next process sweeps
 * again, so nothing has to remember a sweep across restarts.
 */
let sweptLogs = false;
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
 * Wake-budget bookkeeping. `lastUserAt` is the newest real user input (typed or
 * API): a task that started BEFORE it is reporting old news. `lastRequestAt` is
 * when a request was last handed over, which is the closest proxy for "the
 * prompt cache is warm". `wakesThisTurn` is the per-prompt allowance, reset by
 * the next user input rather than by a clock. `continuedThisRun` caps the
 * boundary channel at ONE paid continuation per run: the next request it buys in
 * the same run would be a turn the model did not ask for.
 */
let lastUserAt = 0;
let lastRequestAt: number | undefined;
let wakesThisTurn = 0;
let continuedThisRun = false;
/** Last read of the frontend policy file, keyed by mtime+size. */
let prefsCache: { key: string; value: WakePrefs } | undefined;

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
		// A queued wake must not outlive the process that scheduled it: nothing
		// could deliver it, and the exit is the last thing this process does.
		if (wakeTimer !== undefined) {
			clearTimeout(wakeTimer);
			wakeTimer = undefined;
		}
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
		`id="${escapeAttr(task.taskId)}"`,
		`status="${reportStatus(task)}"`,
		`exit_code="${escapeAttr(`${task.exitCode ?? ""}`)}"`,
		`signal="${escapeAttr(task.signal ?? "")}"`,
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
	// Every interpolation is escaped: a record FOLDED from a doctored session
	// transcript carries an id this extension never generated, and an unescaped
	// one could close the element's attribute or forge a second element.
	const id = escapeText(task.taskId);
	const head =
		`Background task ${id} ("${escapeAttr(task.command)}") ` +
		`${escapeText(describeExit(task))} after ${elapsed}.`;
	// Only the TEXT of the tail is escaped (attributes need more): output is
	// arbitrary program output and may well print `</system-reminder>`.
	const lines = tail.text.trim()
		? [
				`${head} Output tail:`,
				"",
				escapeText(tail.text),
				`Full output: ${escapeText(task.outputFile)} (or wait_task ${id}).`,
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
 * What a check-in is about: the model-supplied deadline, or the advisory
 * lifetime cap. Both are NOTIFY-ONLY — nothing is killed on either.
 */
type CheckInKind = "deadline" | "lifetime";

/**
 * Check-in text for a task that is STILL RUNNING.
 *
 * A check-in is not a result, and it must not read like one: the second line
 * says so explicitly, the element carries `check_in` (instead of `exit_code` /
 * `signal` / `duration_ms`) and `status="running"`, and the whole thing is
 * built from the same escapers and the same `wrapReminder` as a report, so a
 * reader cannot be handed a block that looks like an exit it never got. The
 * output tail is escaped as TEXT for the same reason a report's is: a program
 * that prints `</system-reminder>` must not be able to end the block.
 *
 * Deliberately carries no `details` and no delivery bookkeeping (see
 * `sendCheckIn`): a check-in is advisory, best-effort, and outside the
 * `none -> sent -> confirmed` ladder the exit report walks.
 */
function buildCheckInNote(task: BgTaskState, kind: CheckInKind): string {
	const elapsedMs = Date.now() - task.startedAt;
	const elapsed = formatSeconds(elapsedMs);
	const tail = readOutputTail(task.outputFile, CHECK_IN_TAIL_BYTES, CHECK_IN_TAIL_LINES);
	// Same escaping rules as a report: a folded record's id is arbitrary text too.
	const id = escapeText(task.taskId);
	const attrs =
		`id="${escapeAttr(task.taskId)}" status="${reportStatus(task)}" ` +
		(kind === "deadline" ? 'check_in="deadline"' : 'check_in="lifetime"') +
		` elapsed_ms="${elapsedMs}" output="${escapeAttr(task.outputFile)}"`;
	const quoted = `Background task ${id} ("${escapeAttr(task.command)}")`;
	const head =
		kind === "deadline"
			? `${quoted} is still running after ${elapsed}.`
			: `${quoted} is still running after ${elapsed}: the lifetime cap passed. ` +
				`It is NOT being killed — stop_task ${id} ends it.`;
	const lines = tail.text.trim()
		? [
				`${head} Output tail:`,
				"",
				escapeText(tail.text),
				`Full output: ${escapeText(task.outputFile)} (or wait_task ${id}).`,
			]
		: [head, "No output tail was read: the output file above is the only copy of its output."];
	return (
		`[SYSTEM NOTIFICATION - NOT USER INPUT]\n` +
		"This is an automated task notification, not a message from the user. The task is still running: " +
		"this is a check-in, not a result, and the process was not touched.\n" +
		wrapReminder(`<background-task ${attrs}>\n${lines.join("\n")}\n</background-task>`)
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

interface NeedleScan {
	/** The needle was found in the bytes scanned by THIS call. */
	matched: boolean;
	/** The line the needle sat on, flattened and bounded (empty when no match). */
	line: string;
	/** Offset to resume the next scan from (never rewinds). */
	offset: number;
}

/** Bytes read per `scanForNeedle` iteration (a log can be hundreds of KB). */
const NEEDLE_SCAN_CHUNK = 64 * 1024;
/** Bounded slice used on a side whose line boundary is outside the window. */
const NEEDLE_LINE_FALLBACK = 200;
/**
 * How far right of a match a line is followed when no newline is in sight. Wide
 * enough that the elision below always ends on a character, never on a byte
 * count: 4 KiB is at least 1024 characters in any UTF-8 text.
 */
const NEEDLE_LINE_TAIL = 4 * 1024;
/** Display width of a matched line before it is elided. */
const NEEDLE_LINE_WIDTH = 200;

/**
 * Flatten one log line: trim it, squeeze internal whitespace (a progress or
 * table line is mostly whitespace) and elide it past the display width.
 * `\uFFFD` is what a slice through a multi-byte character decodes to, so it is
 * trimmed away at both ends.
 */
function flattenMatchedLine(raw: string): string {
	const flat = raw.replace(/^\uFFFD+|\uFFFD+$/g, "").replace(/\s+/g, " ").trim();
	return flat.length > NEEDLE_LINE_WIDTH ? `${flat.slice(0, NEEDLE_LINE_WIDTH - 1)}…` : flat;
}

/**
 * Extract the line around the match at `at` (ending at byte `end`) from
 * `window`, whose first byte sits at file offset `base`.
 *
 * A boundary that is not visible in the window degrades instead of being
 * guessed: a window that began mid-line (`base > 0`, no newline before the
 * match) shows a bounded slice left of the match, so the needle itself stays
 * visible; a line that runs past the window end is followed far enough for the
 * elision below to apply.
 */
function lineAroundMatch(window: Buffer, base: number, at: number, end: number): string {
	let start = at > 0 ? window.lastIndexOf(0x0a, at - 1) + 1 : 0;
	if (start === 0 && base > 0 && at > NEEDLE_LINE_FALLBACK) {
		start = Math.max(0, at - NEEDLE_LINE_FALLBACK);
	}
	let stop = window.indexOf(0x0a, end);
	if (stop < 0) {
		stop = Math.min(window.length, end + NEEDLE_LINE_TAIL);
	}
	return flattenMatchedLine(window.toString("utf8", start, stop));
}

/**
 * Scan `file` from byte `offset` for the literal `needle`.
 *
 * Pure, synchronous and read-only: this runs on a timer for the whole time a
 * `wait_task({ until })` call is attached, so it must never load the log whole,
 * never throw (the panel may have deleted the file under us) and never rewind.
 * Matching is BYTE-level (`Buffer#indexOf`) — decoding first would misplace
 * every offset past a multi-byte character — and a needle straddling a chunk
 * boundary is caught by carrying the last `needle.length - 1` bytes into the
 * next window. One call reads until it matches or hits EOF; the returned
 * `offset` keeps that same carry tail, so a needle split by a line written later
 * still matches on the next tick.
 */
function scanForNeedle(file: string, needle: string, offset: number): NeedleScan {
	if (needle === "") {
		// Defensive: an empty needle would "match" at every position.
		return { matched: false, line: "", offset };
	}
	const needleBytes = Buffer.byteLength(needle, "utf8");
	// A needle can straddle a chunk boundary, so the tail that the next window
	// re-checks is one byte shorter than the needle itself.
	const keep = Math.max(0, needleBytes - 1);
	let pos = offset;
	let carry = Buffer.alloc(0);
	let fd: number | undefined;
	try {
		fd = openSync(file, "r");
		for (;;) {
			const buffer = Buffer.allocUnsafe(NEEDLE_SCAN_CHUNK);
			let read: number;
			try {
				read = readSync(fd, buffer, 0, NEEDLE_SCAN_CHUNK, pos);
			} catch {
				return { matched: false, line: "", offset: pos };
			}
			if (read > 0) {
				const chunk = read === NEEDLE_SCAN_CHUNK ? buffer : buffer.subarray(0, read);
				const window = carry.length > 0 ? Buffer.concat([carry, chunk]) : chunk;
				const at = window.indexOf(needle, 0, "utf8");
				if (at >= 0) {
					const base = pos - carry.length;
					return { matched: true, line: lineAroundMatch(window, base, at, at + needleBytes), offset: pos + read };
				}
				pos += read;
				carry = keep > 0 ? Buffer.from(window.subarray(window.length - keep)) : Buffer.alloc(0);
			}
			if (read < NEEDLE_SCAN_CHUNK) {
				// EOF: hand back a resume point that still covers the last `keep` bytes,
				// so a needle split by whatever is appended next is still caught.
				return { matched: false, line: "", offset: Math.max(offset, pos - keep) };
			}
		}
	} catch {
		// Missing or unreadable log (scratch space; a task may already be gone).
		return { matched: false, line: "", offset };
	} finally {
		if (fd !== undefined) {
			closeSync(fd);
		}
	}
}

function formatBytes(bytes: number): string {
	return bytes >= 1024 * 1024 ? `${(bytes / (1024 * 1024)).toFixed(1)}MB` : `${(bytes / 1024).toFixed(1)}KB`;
}

/**
 * The foreground attach window, in MILLISECONDS. The model-facing `timeout`
 * parameter is in SECONDS (pi's bash schema), so `clampAttachWindow` converts it
 * here — treating a raw seconds value as milliseconds made every `timeout: 30`
 * detach after 1 s (the old minimum), which turned ordinary commands into
 * background tasks and made completions wake the model far more often than the
 * extension ever intended.
 */
function clampAttachWindow(timeoutSeconds: number | undefined): number {
	if (typeof timeoutSeconds !== "number" || !Number.isFinite(timeoutSeconds) || timeoutSeconds <= 0) {
		return DEFAULT_ATTACH_MS;
	}
	return Math.min(MAX_ATTACH_MS, Math.max(MIN_ATTACH_MS, Math.round(timeoutSeconds * 1000)));
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

/**
 * The model-supplied check-in deadline, or `undefined` when none was given.
 * Unlike the attach and wait windows there is no default: a task without a
 * `deadline_ms` simply gets no deadline check-in (the lifetime note still runs).
 */
function clampDeadlineMs(deadline: number | undefined): number | undefined {
	if (typeof deadline !== "number" || !Number.isFinite(deadline) || deadline <= 0) {
		return undefined;
	}
	return Math.min(MAX_DEADLINE_MS, Math.max(MIN_DEADLINE_MS, Math.floor(deadline)));
}

/**
 * The advisory lifetime cap, read LAZILY at arm time: the process environment is
 * what a spawned child actually got, and `LIFETIME_ENV` may have changed since
 * this module loaded. Any positive finite number is accepted; anything else
 * (unset, empty, `NaN`, `0`, negative) falls back to the default.
 */
function lifetimeCapMs(): number {
	const raw = process.env[LIFETIME_ENV];
	if (raw !== undefined && raw.trim() !== "") {
		const value = Number(raw);
		if (Number.isFinite(value) && value > 0) {
			return Math.floor(value);
		}
	}
	return DEFAULT_MAX_LIFETIME_MS;
}

/**
 * How long a finished task's log may sit in `tmpdir()` before the startup sweep
 * removes it. Read LAZILY for the same reason as `lifetimeCapMs`: the sweep runs
 * after the environment of this process is what it is, and a test needs to point
 * it at a tiny TTL to prove the decision is really made on `mtime`. Any positive
 * finite number is accepted — even 1 ms.
 */
function logTtlMs(): number {
	const raw = process.env[LOG_TTL_ENV];
	if (raw !== undefined && raw.trim() !== "") {
		const value = Number(raw);
		if (Number.isFinite(value) && value > 0) {
			return Math.floor(value);
		}
	}
	return DEFAULT_LOG_TTL_MS;
}

/**
 * Remove log files this extension wrote in an earlier process that are older
 * than the TTL. Returns how many were removed.
 *
 * Best-effort by construction: every filesystem call is guarded, because a sweep
 * that throws on `session_start` would break the extension for a mere cleanup.
 * Only our OWN file name shape is touched (a log this extension would write), and
 * a task this process still has a record for is never swept — `list_tasks` and
 * the panel may still point at that path.
 */
function sweepLogFiles(): number {
	const ttl = logTtlMs();
	let names: string[];
	try {
		names = readdirSync(tmpdir());
	} catch {
		return 0; // an unreadable tmpdir is not an error worth surfacing
	}
	const now = Date.now();
	let removed = 0;
	for (const name of names) {
		const match = LOG_FILE_PATTERN.exec(name);
		if (!match) {
			continue; // not ours: another tool's spill file, a directory, …
		}
		if (tasks.has(match[1])) {
			// The process still has a record for it (running, adopted, or finished
			// this session) — a `list_tasks`/panel row and a `wait_task` may still
			// point at this path, so age alone is not enough.
			continue;
		}
		const file = join(tmpdir(), name);
		try {
			const stats = statSync(file);
			if (now - stats.mtimeMs < ttl) {
				continue;
			}
			unlinkSync(file);
			removed += 1;
		} catch {
			// Gone between the readdir and the stat, or not ours to remove.
		}
	}
	return removed;
}

type WaitOutcome = "exited" | "deadline" | "aborted" | "matched";

interface AttachOptions {
	deadlineMs: number;
	signal?: AbortSignal;
	/** When set, the live tail is pushed through it (throttled). */
	onUpdate?: (tail: string) => void;
	/** Wait for this literal text to appear in the log instead of only for the exit. */
	until?: string;
}

/**
 * Attach a tool call to a task and settle on the first of: process exit, the
 * call's own deadline, abort, or — when `until` was given — the needle showing
 * up in the log.
 *
 * The observer lease is what keeps completion delivery exactly-once: the
 * counter is incremented for the whole time this call is attached, and the
 * exit handler suppresses the wake report while it is > 0, because THIS call is
 * about to hand the terminal state back to the model. Releasing on a deadline,
 * abort or a text match re-arms the wake for a later exit. Without a needle
 * there is no polling: the promise races the task's `exited` promise against a
 * timer and the abort signal. A text match DOES poll, because the log is the
 * only place the needle can appear.
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
		// The text watch is its own timer: the live tail may be off (no `onUpdate`)
		// while a needle is still being watched, and they run at different rates.
		let scanTimer: ReturnType<typeof setInterval> | undefined;
		let scanOffset = 0;
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
			if (scanTimer) {
				clearInterval(scanTimer);
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
		const needle = options.until;
		if (needle !== undefined && needle !== "") {
			const scan = (): void => {
				const result = scanForNeedle(task.outputFile, needle, scanOffset);
				scanOffset = result.offset;
				if (result.matched) {
					finish("matched");
				}
			};
			// Scan immediately: a line printed before this call is still a hit, and
			// the first tick would otherwise wait a full `UNTIL_POLL_MS`.
			scan();
			if (!settled) {
				scanTimer = setInterval(scan, UNTIL_POLL_MS);
				scanTimer.unref?.();
			}
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
				// `confirmed` keeps the vanished record from waking the model, but the
				// panel still needs the row: without this the record would not exist
				// there at all instead of reading `unknown`.
				task.delivery = "confirmed";
				task.panelStarted = true;
				reportPanel(task);
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
			// `triggerTurn: false` is explicit on purpose: without options the
			// message defaults to `steer` while a run is active, and a steering
			// message opens a turn by itself.
			pi.sendMessage({ customType: CUSTOM_TYPE, content: startupNote.text, display: false }, { triggerTurn: false });
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
		// AFTER the fold, never before: an adopted task is in `tasks` now, so a
		// running task's log survives even when it is older than the TTL. Once per
		// process — a `/reload` re-evaluates this module, and the next process
		// sweeps again.
		if (!sweptLogs) {
			sweptLogs = true;
			sweepLogFiles();
		}
		return undefined;
	});

	pi.on("session_shutdown", (event) => {
		// A wake queued a moment ago belongs to THIS instance. The successor (a
		// `/new`, a resume, a fork) folds the transcript again and runs its own
		// ladder, so a timer left behind would fire into it and deliver this
		// session's report there — or into nothing at all. The exit hook clears the
		// same timer for the process-level case.
		if (wakeTimer !== undefined) {
			clearTimeout(wakeTimer);
			wakeTimer = undefined;
		}
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
		// Every request is one more chance that the prompt cache is warm; the
		// closest thing to a cache timestamp an extension can observe.
		lastRequestAt = Date.now();
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
	// aggregated `custom_message` entry — durable, unlike a steering message — and
	// ask for a continuation only when the completion-wake gate allows it. A
	// boundary with natural tool work is free; a boundary with nothing left is a
	// paid turn and is gated exactly like the idle wake.
	// ------------------------------------------------------------------
	// ------------------------------------------------------------------
	// User presence. A real input (typed, or sent through the API) opens a new wake
	// budget and makes every task that predates it old news (`completionWakeHold`'s
	// `stale` rule). Messages another extension sends through `sendUserMessage` are
	// not user presence and must reset neither.
	// ------------------------------------------------------------------
	pi.on("input", (event) => {
		if (event.source === "extension") {
			return undefined;
		}
		lastUserAt = Date.now();
		wakesThisTurn = 0;
		continuedThisRun = false;
		return undefined;
	});

	pi.on("agent_start", () => {
		busy = true;
		// One paid continuation per run: a new run starts with a fresh allowance.
		continuedThisRun = false;
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
		// after every settled handler completes. The wake is coalesced, so a
		// completion landing while this settle runs shares this one.
		scheduleWake();
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
		armCheckIns(task);
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
		// Both check-in timers are advisory and one-shot: a task that has exited has
		// nothing left to be checked in about, and a timer that fired after the exit
		// report would be a stale note about a task that is already done.
		if (task.deadlineTimer) {
			clearTimeout(task.deadlineTimer);
			task.deadlineTimer = undefined;
		}
		if (task.lifetimeTimer) {
			clearTimeout(task.lifetimeTimer);
			task.lifetimeTimer = undefined;
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
			scheduleWake();
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
		// A report a channel now carries is no longer held for the user; a stale
		// reason would make the panel contradict `list_tasks`.
		task.held = undefined;
		task.heldAt = undefined;
	}

	/**
	 * Record that a completion is waiting for the USER, not for a turn.
	 *
	 * The report is deliberately left `none`: the boundary path (`deliverAtBoundary`
	 * / the `context` fallback) already carries unelected reports on the next user
	 * turn, so deferring needs no new channel and cannot double-deliver. What the
	 * hold adds is the reason, which the panel and `list_tasks` show — the value of
	 * the gate is that its cost is visible, and an invisible hold would read as a
	 * lost report.
	 */
	function markHeld(batch: BgTaskState[], reason: HoldReason): void {
		for (const task of batch) {
			if (task.held === reason) {
				continue;
			}
			task.held = reason;
			task.heldAt = Date.now();
			reportPanel(task);
		}
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
	 *
	 * Bounded by `MAX_REARMS`: every re-arm buys one more wake, and a provider that
	 * fails in a way that keeps producing FRESH runs would otherwise let one report
	 * wake the agent forever. Past the cap the report stays `sent`, which is still
	 * recoverable — `context` injects it before the next user turn.
	 */
	function rearmLostFallbacks(): void {
		for (const task of tasks.values()) {
			if (task.delivery === "sent" && task.sentVia === "fallback") {
				if ((task.rearmCount ?? 0) >= MAX_REARMS) {
					// A provider that never accepts a request can produce settle ->
					// re-arm -> wake -> settle with no user input at all, so the re-arm
					// is bounded. The report is NOT lost: `context` still injects a
					// `sent` report on the next user turn, which is what the whole
					// ladder exists for; only the self-sustaining wake loop is gone.
					continue;
				}
				task.rearmCount = (task.rearmCount ?? 0) + 1;
				task.delivery = "none";
				task.sentText = undefined;
				task.sentVia = undefined;
				task.sentAt = undefined;
			}
		}
	}

	/**
	 * Whether a terminal report describes a failure worth spending a turn on: a
	 * non-zero exit, a signal, a spawn error, or an exit nobody observed. A clean
	 * exit is exactly what `wake_on_completion = "failure"` leaves for the next
	 * user turn.
	 */
	function reportFailed(task: BgTaskState): boolean {
		if (task.spawnError !== undefined || task.exitUnknown) {
			return true;
		}
		if (task.signal !== null) {
			return true;
		}
		return task.exitCode !== null && task.exitCode !== 0;
	}

	/**
	 * Append the outstanding reports to a boundary proposal.
	 *
	 * A boundary that still has tool results to hand back is going to make a
	 * provider request anyway, so the report rides it for free (`continue` is not
	 * requested). A boundary with nothing left — the model just produced its final
	 * answer — is the expensive one: whether it may buy a turn is decided by
	 * `completionWakeHold`, the same gate the idle channel uses. A held report
	 * stays `none` and is injected by `context` on the next user turn.
	 *
	 * An aborted turn keeps a committed entry but never asks for a continuation,
	 * so Esc still stops the run.
	 */
	function deliverAtBoundary(event: {
		entries: unknown[];
		outcome?: string;
		toolResults?: unknown[];
	}): { entries: unknown[]; continue?: boolean } | undefined {
		const pending = pendingReports().filter((task) => task.delivery === "none" && task.observers === 0);
		if (pending.length === 0) {
			return undefined;
		}
		const aborted = event.outcome === "aborted";
		const naturalWork = (event.toolResults?.length ?? 0) > 0;
		const prefs = readWakePrefs();
		if (!aborted && !naturalWork) {
			const hold = completionWakeHold(pending, prefs, "boundary");
			if (hold !== undefined) {
				markHeld(pending, hold);
				return undefined;
			}
		}
		const text = buildBatchNote(pending);
		for (const task of pending) {
			markSent(task, "boundary", text);
		}
		const continueRun = !aborted && !naturalWork;
		if (continueRun) {
			wakesThisTurn += 1;
			if (prefs.policy !== "always") {
				continuedThisRun = true;
			}
		}
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
			...(continueRun ? { continue: true } : {}),
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
				options.wake ? { triggerTurn: true } : { triggerTurn: false },
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
	 * The frontend-published completion-wake policy. A plain pi (TUI, SDK, no
	 * pi.nvim) gets the same default as pi.nvim — `never` — and `present: true`
	 * because there is no focus to observe. `wake_on_idle` is the old key and is
	 * still read as a fallback, so a frontend and a backend from different updates
	 * agree on what the user asked for.
	 *
	 * The read is cached by mtime+size so the per-completion decision costs one
	 * `stat`; a live `setup()` or a focus change rewrites the file and the next
	 * decision sees it, without respawning the RPC process.
	 */
	function readWakePrefs(): WakePrefs {
		const fallback: WakePrefs = {
			policy: DEFAULT_WAKE_POLICY,
			budget: DEFAULT_WAKE_BUDGET,
			cacheWindowMs: DEFAULT_WAKE_CACHE_WINDOW_MS,
			present: true,
		};
		const path = process.env[PREFS_ENV];
		if (!path) {
			return fallback;
		}
		try {
			const stat = statSync(path);
			const key = `${stat.mtimeMs}:${stat.size}`;
			if (prefsCache?.key === key) {
				return prefsCache.value;
			}
			const parsed = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
			const rawPolicy = parsed.wake_on_completion ?? parsed.wake_on_idle;
			const policy =
				typeof rawPolicy === "string" && (WAKE_POLICIES as readonly string[]).includes(rawPolicy)
					? (rawPolicy as WakePolicy)
					: fallback.policy;
			const budget =
				typeof parsed.wake_budget === "number" && Number.isFinite(parsed.wake_budget)
					? Math.min(MAX_WAKE_BUDGET, Math.max(0, Math.floor(parsed.wake_budget)))
					: fallback.budget;
			const cacheWindowMs =
				typeof parsed.wake_cache_window_ms === "number" && Number.isFinite(parsed.wake_cache_window_ms)
					? Math.min(MAX_WAKE_CACHE_WINDOW_MS, Math.max(0, Math.floor(parsed.wake_cache_window_ms)))
					: fallback.cacheWindowMs;
			const value: WakePrefs = {
				policy,
				budget,
				cacheWindowMs,
				present: typeof parsed.present === "boolean" ? parsed.present : true,
			};
			prefsCache = { key, value };
			return value;
		} catch {
			// Missing, unreadable, or caught mid-rewrite: keep the last good value
			// rather than flipping the policy for one burst.
			return prefsCache?.value ?? fallback;
		}
	}

	/**
	 * Decide whether this burst of completions may BUY a provider request.
	 *
	 * A paid turn is one full request whose price is the CONVERSATION, not the
	 * report — and that price is highest exactly where it is least useful: nobody
	 * is looking (`absent`), the prompt cache expired so the whole conversation is
	 * re-read at full input price (`cache`), the task predates the newest user
	 * message so its result is old news (`stale`), the burst has no failure under
	 * `failure`, this run already bought its one continuation (`continuation`), or
	 * the prompt's allowance is spent (`budget`). Holding is never dropping: the
	 * report stays `none` and rides the next boundary with natural work or the
	 * `context` fallback, i.e. the user's next turn.
	 *
	 * Order matters. The policy explains every hold it causes; presence is the
	 * user's own signal; then the cache window (the most expensive mistake); then
	 * staleness; then the failure filter; then the per-run continuation cap; and
	 * the budget last, so a report held for a cheaper reason keeps that reason
	 * instead of degrading to `budget`. `always` bypasses every rule, including
	 * the cap — it is the explicit "old behaviour" escape hatch.
	 */
	function completionWakeHold(
		reports: BgTaskState[],
		prefs: WakePrefs,
		channel: "boundary" | "idle",
	): HoldReason | undefined {
		if (prefs.policy === "never") {
			return "policy";
		}
		if (prefs.policy === "always") {
			return undefined;
		}
		if (!prefs.present) {
			return "absent";
		}
		if (prefs.cacheWindowMs > 0 && lastRequestAt !== undefined && Date.now() - lastRequestAt > prefs.cacheWindowMs) {
			return "cache";
		}
		if (lastUserAt > 0 && reports.every((task) => task.startedAt < lastUserAt)) {
			return "stale";
		}
		if (prefs.policy === "failure" && !reports.some(reportFailed)) {
			return "failure";
		}
		if (channel === "boundary" && continuedThisRun) {
			return "continuation";
		}
		if (wakesThisTurn >= prefs.budget) {
			return "budget";
		}
		return undefined;
	}

	/**
	 * Schedule ONE wake for every report that is pending when it fires. Idempotent
	 * inside the window, so N completions in the same tick cost one `sendMessage`
	 * (and `flushPending` drains all of them into one message). A pending wake does
	 * not keep the process alive.
	 */
	function scheduleWake(): void {
		if (wakeTimer !== undefined) {
			return;
		}
		wakeTimer = setTimeout(() => {
			wakeTimer = undefined;
			if (busy) {
				// A run became active inside the window (a user prompt, or another
				// wake): `triggerTurn` would now queue the report as a FOLLOW-UP TURN
				// instead of letting it arrive at a boundary of the run that is already
				// going. Leave the reports `none`; `deliverAtBoundary` (turn_end /
				// agent_before_settle) carries them inside this run, and the next
				// `agent_settled` re-arms a wake if the run ends first.
				return;
			}
			const pending = pendingReports().filter((task) => task.delivery === "none" && task.observers === 0);
			if (pending.length === 0) {
				return;
			}
			const hold = completionWakeHold(pending, readWakePrefs(), "idle");
			if (hold !== undefined) {
				// Held, not dropped: the report stays `none`, so the next boundary or
				// the `context` fallback carries it on the user's next turn.
				markHeld(pending, hold);
				return;
			}
			wakesThisTurn += 1;
			flushPending({ wake: true });
		}, WAKE_COALESCE_MS);
		wakeTimer.unref?.();
	}

	/**
	 * Send ONE advisory check-in for a task that is still running.
	 *
	 * It is NOT a report: no `details` (the frontend registry keys on
	 * `details.taskId`, so a check-in must not fabricate a panel row), no
	 * `pendingReports` entry and no delivery state — the exit report still
	 * arrives through the ladder exactly once, and nothing here may mark it. It
	 * is best-effort by construction: a stale extension ctx (after a reload) must
	 * not throw into a timer, so the send is wrapped.
	 */
	function sendCheckIn(task: BgTaskState, kind: CheckInKind): void {
		if (task.completed) {
			return;
		}
		const text = buildCheckInNote(task, kind);
		try {
			// A check-in is worth a turn only when nothing else is happening and the
			// policy allows one: `never` stores it without a turn, so it rides the
			// next user request instead of paying for an advisory note.
			const mayWake = !busy && readWakePrefs().policy !== "never";
			pi.sendMessage(
				{ customType: CUSTOM_TYPE, content: text, display: false },
				mayWake ? { triggerTurn: true } : { triggerTurn: false },
			);
		} catch {
			// Stale ctx after reload: a check-in is advisory, and the exit report is
			// still coming through the ladder.
		}
	}

	/**
	 * Arm the two NOTIFY-ONLY timers for a task that just became a background
	 * task: the one deadline check-in (when the model asked for one) and the one
	 * advisory lifetime note. Neither timer signals, kills or finishes anything;
	 * both are one-shot, unref'd and cleared in `finishTask`, and an adopted task
	 * is never armed (its timers died with the process that armed them, and the
	 * successor would only repeat a note this session already sent).
	 */
	function armCheckIns(task: BgTaskState, deadlineMs?: number): void {
		if (task.adopted || task.completed) {
			return;
		}
		const lifetimeMs = lifetimeCapMs();
		task.lifetimeTimer = setTimeout(() => {
			task.lifetimeTimer = undefined;
			if (task.completed || task.lifetimeNoted) {
				return;
			}
			task.lifetimeNoted = true;
			sendCheckIn(task, "lifetime");
		}, lifetimeMs);
		task.lifetimeTimer.unref?.();
		if (deadlineMs === undefined) {
			return;
		}
		task.deadlineTimer = setTimeout(() => {
			task.deadlineTimer = undefined;
			if (task.completed || task.deadlineNoted) {
				return;
			}
			task.deadlineNoted = true;
			sendCheckIn(task, "deadline");
		}, deadlineMs);
		task.deadlineTimer.unref?.();
	}

	/**
	 * Frontend notification (task panel): a display:false custom message sent
	 * WITHOUT options, so core appends it instantly when idle and at the next
	 * turn end while streaming. Never `triggerTurn` — this fires mid-tool and
	 * must not interrupt the running turn; delivering it through followUp
	 * instead would strand the panel on "running" for the rest of the run.
	 */
	function reportPanel(task: BgTaskState): void {
		// Same ordering as `reportStatus`, because the panel must not contradict it.
		// The `exitUnknown` test sits AFTER the signal test and BEFORE the exit-code
		// test: an adopted task that vanished with nobody watching has no exit code
		// and no signal, so falling through would export it as `failed`.
		const kind: BgTaskDetails["kind"] = !task.completed
			? "started"
			: task.spawnError
				? "failed"
				: task.signal !== null
					? "stopped"
					: task.exitUnknown
						? "unknown"
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
			// A terminal report that is held for the next user turn says so, so the
			// panel can distinguish "done" from "done and waiting for you".
			held: task.held,
			// The message is stamped when it is sent, so an adopted task would
			// otherwise render as if it had just started.
			startedAt: task.startedAt,
			// Ownership: a session may only adopt/control tasks whose record names it.
			sessionId: task.sessionId ?? currentSessionId,
		} satisfies BgTaskDetails;
		try {
			// The panel ping is TUI-only in intent, but it is still a custom
			// message; without `triggerTurn: false` the streaming default is
			// `steer`, which opens a turn and made a mere status update look like
			// autonomous work. (The model-visible delivery reports are a separate
			// channel, see `deliverAtBoundary`/`flushPending`.)
			pi.sendMessage(
				{
					customType: CUSTOM_TYPE,
					content: `[Background task ${task.taskId} ${kind}]`,
					display: false,
					details,
				},
				{ triggerTurn: false },
			);
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
				// Mirrors `reportPanel`'s ordering: an exit nobody observed is `unknown`,
				// never `failed`.
				kind: task.spawnError
					? "failed"
					: task.signal !== null
						? "stopped"
						: task.exitUnknown
							? "unknown"
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
					"Run the command as a background task instead of staying attached. Use for long-running commands such as dev servers, watchers, long builds, or test suites that take minutes. The command starts immediately, output streams to a log file whose path is returned, and its result is delivered on a later turn (call wait_task to read it now). Do not poll the output file and do not append '&' to background commands. The timeout parameter does not apply to background tasks.",
			}),
		),
		deadline_ms: Type.Optional(
			Type.Number({
				description:
					"For a background task: send ONE 'still running' check-in (with an output tail) once this many milliseconds have passed, and keep running. It does NOT kill the process and it is not a result: the exit report still arrives exactly once when the command finishes. Minimum 500, maximum 86400000.",
				minimum: MIN_DEADLINE_MS,
				maximum: MAX_DEADLINE_MS,
			}),
		),
		// The spread above is runtime-exact but types as a plain Record; pin the
		// static shape so Static<> keeps command/timeout/run_in_background/deadline_ms.
	}) as unknown as Type.TObject<{
		command: Type.TString;
		timeout: Type.TOptional<Type.TNumber>;
		run_in_background: Type.TOptional<Type.TBoolean>;
		deadline_ms: Type.TOptional<Type.TNumber>;
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
		" Never wait with `sleep` and never poll a task's output file: you are told the task id, and when the process exits its status and output tail are delivered on a later turn (or read the log, or call wait_task)." +
		" If you have other work, do it. If the task's result is all that is left, ending your turn is correct (the result arrives on a later turn; a turn is not bought for it by default), or call wait_task, which blocks until the task exits or its timeout hits and returns the output." +
		" A wait_task result of \"still running\" is not a failure." +
		" A task you no longer need — a dev server holding a port, a watcher for a file you already fixed — is stopped with stop_task(task_id), which signals its whole process group; list_tasks shows what is still running." +
		" A background task keeps its stdin open: if it is waiting on input (a confirmation, a name, a REPL line), answer it with task_input(task_id, data) instead of killing and restarting it." +
		" deadline_ms gives ONE 'still running' check-in (with an output tail) at the deadline and does NOT kill the process.";

	const { prepareArguments: _unusedPrepareArguments, ...builtinRest } = builtin;
	void _unusedPrepareArguments; // typed for the old schema; the new schema needs no shim

	const overridden: ToolDefinition<typeof bgBashParameters, BgBashToolDetails | undefined> = {
		...builtinRest,
		description: `${builtin.description}${BG_GUIDE}`,
		parameters: bgBashParameters,
		async execute(toolCallId, params, signal, onUpdate, ctx) {
			const { run_in_background, deadline_ms, command, timeout } = params;
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
				// The task BECOMES a background task here: this is the one place the
				// model's `deadline_ms` can take effect (see `armCheckIns`).
				armCheckIns(task, clampDeadlineMs(deadline_ms));
				task.panelStarted = true;
				reportPanel(task);
				return {
					content: [
						{
							type: "text" as const,
							text: `Task ${task.taskId} running in background: ${command}\nOutput: ${task.outputFile}\nIts result is delivered on a later turn. Do not \`sleep\` or poll the file. If you need the result before continuing, call wait_task(task_id: "${task.taskId}").`,
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
			// A `timeout` the command outlived is the attach window, not a check-in
			// deadline: arm only the advisory lifetime note.
			armCheckIns(task);
			task.panelStarted = true;
			reportPanel(task);
			const soFar = tail.text.trim() ? `\n\nOutput so far:\n${tail.text}` : "";
			return {
				content: [
					{
						type: "text" as const,
						text: `[still running] ${command}\nThe command outlived its ${formatSeconds(window)} attach window and keeps running as background task ${task.taskId} (not killed).\nOutput: ${task.outputFile}${soFar}\nCall wait_task(task_id: "${task.taskId}") to block until it exits; ending your turn is safe, its result arrives on a later turn. Do not \`sleep\`.`,
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
					"How long to stay attached, in milliseconds (default 120000, max 1800000). Reaching it does NOT kill the task and is NOT a failure: call again, or end your turn; the report is delivered on a later turn.",
			}),
		),
		until: Type.Optional(
			Type.String({
				description:
					'Wait until this literal text appears in the task\'s output, instead of only waiting for the process to exit (no regex, case-sensitive). The task keeps running: use it for a readiness line ("listening on"), a build stage, or a prompt. Returns as soon as the line appears, when the process exits, or when the timeout hits — whichever comes first.',
			}),
		),
	});

	type WaitTaskParams = Static<typeof waitTaskParameters>;

	interface WaitTaskDetails {
		taskId: string;
		status: "exited" | "still_running" | "cancelled" | "matched";
		command: string;
		exitCode?: number | null;
		signal?: string | null;
		outputFile?: string;
		wallTimeSeconds: number;
		/** The `until` needle this call was watching, when it passed one. */
		until?: string;
		/** The line the needle sat on (matched results only). */
		matchedLine?: string;
	}

	pi.registerTool({
		name: "wait_task",
		label: "Wait for background task",
		description:
			"Stay attached to a background bash task until it exits or the timeout hits, then return its output. Use this instead of `sleep` whenever you need a task's result before you can continue. Reaching the timeout is not a failure: the process keeps running and you can wait again (or end your turn; the report is delivered on a later turn). Pass `until` to wait for a LINE instead (a server's ready line, a port binding, a build stage): the call returns as soon as the text appears, the process keeps running, and its exit is still reported exactly once.",
		promptSnippet:
			"Block until a background task exits, prints a line you pass as `until`, or the timeout hits, and return its output",
		promptGuidelines: [
			"Use wait_task (not `sleep`) when you need a background task's result before continuing: it returns as soon as the process exits, and a \"still running\" result is not a failure.",
			"If a task's result is all that is left and you have nothing else to do, ending your turn is correct — the report is delivered on a later turn; call wait_task if you need it now.",
			"To wait for a task to reach a state (a server's ready line, a port binding line, a build stage), pass `until` with the literal text to look for instead of `sleep`-polling its output file; a match does NOT stop the task, and its exit is still reported once.",
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

			// A literal needle, never a pattern: the watch is a substring search, so
			// there is no regex to compile and no ReDoS to risk. An empty or blank one
			// would "match" everywhere, and an unbounded one would only buy scan cost.
			const until = typeof params.until === "string" ? params.until : undefined;
			if (until !== undefined && until.trim() === "") {
				throw new Error("wait_task: `until` must be a non-empty literal string (there is no regex syntax).");
			}
			if (until !== undefined && until.length > MAX_UNTIL_LENGTH) {
				throw new Error(`wait_task: \`until\` is limited to ${MAX_UNTIL_LENGTH} characters.`);
			}

			const window = clampWaitWindow(params.timeout_ms);
			const started = Date.now();
			const outcome = await attachWait(task, {
				deadlineMs: window,
				signal,
				until,
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
									until,
								} satisfies WaitTaskDetails,
							});
						}
					: undefined,
			});

			const wallTimeSeconds = (Date.now() - started) / 1000;
			const tail = readOutputTail(task.outputFile, MAX_OUTPUT_BYTES, MAX_OUTPUT_LINES);
			const elapsed = formatSeconds((task.endedAt ?? Date.now()) - task.startedAt);
			const waited = formatSeconds(Date.now() - started);

			if (outcome === "matched" && until !== undefined) {
				// A text match is NOT the task's result: the process is still running, so
				// its exit report must still arrive exactly once. `markConfirmed` would
				// retire that report forever — never call it on this path. The observer
				// lease was already released by `attachWait`'s `finish`.
				const matchedLine = scanForNeedle(task.outputFile, until, 0).line;
				const matchTail = readOutputTail(task.outputFile, CHECK_IN_TAIL_BYTES, CHECK_IN_TAIL_LINES).text;
				let text = `[matched] Task ${task.taskId} printed "${until}" after ${waited} (running for ${elapsed}).\nThe process is still running — this is not its result; its exit report still arrives exactly once.`;
				if (matchedLine) {
					text += `\n\nMatched line: ${matchedLine}`;
				}
				if (matchTail) {
					text += `\n\nRecent output:\n\n${matchTail}`;
				}
				return {
					content: [{ type: "text" as const, text }],
					details: {
						taskId: task.taskId,
						status: "matched",
						command: task.command,
						outputFile: task.outputFile,
						wallTimeSeconds,
						until,
						matchedLine,
					} satisfies WaitTaskDetails,
				};
			}

			if (outcome === "exited") {
				// This result carries the terminal state: the report is delivered.
				markConfirmed(task);
				let head = `Task ${task.taskId} ${describeExit(task)} after ${elapsed}.`;
				if (until !== undefined) {
					// The log is final, so this is the authoritative answer to "was it
					// ever printed?" even though the exit won the race.
					head =
						scanForNeedle(task.outputFile, until, 0).matched === true
							? `${head} Pattern "${until}" was printed.`
							: `${head} The output never contained "${until}".`;
				}
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
						until,
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
						until,
					} satisfies WaitTaskDetails,
					isError: true,
				};
			}

			const soFar = tail.text.trim() ? `\n\nOutput so far:\n${tail.text}` : "";
			// A deadline never matched, so state the negative explicitly: otherwise a
			// model reads "still running" and cannot tell whether the line ever appeared.
			const neverPrinted = until === undefined ? "" : ` The output never contained "${until}".`;
			return {
				content: [
					{
						type: "text" as const,
						text: `[still running] Task ${task.taskId} has not exited after ${formatSeconds(window)} attached (running for ${elapsed}). This is not a failure — the process is still alive and was not killed.${neverPrinted}${soFar}\nCall wait_task again with a larger timeout_ms, or end your turn; the report is delivered on a later turn. Do not \`sleep\`.`,
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
					until,
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

	/**
	 * Display state of a task — the descriptor `describeTaskLine` puts in the
	 * brackets, flags included.
	 */
	function describeTaskState(task: BgTaskState): string {
		const state = task.completed
			? describeExit(task)
			: task.foreign
				? `running elsewhere (${task.foreignNote ?? "another session"}) — not controllable here`
				: task.adopted
					? "running (adopted from an earlier pi process)"
					: "running";
		// Only a live background task can be fed, and the model can only see that here.
		const stdin = !task.completed && task.stdinOpen ? ", stdin open" : "";
		// A held report is still pending delivery: say why, so the model can decide
		// to `wait_task` instead of assuming the completion was swallowed.
		const held = task.held !== undefined ? `, report held (${task.held})` : "";
		return `${state}${stdin}${held}`;
	}

	/** One `list_tasks` row: id, state, elapsed, command, log file. */
	function describeTaskLine(task: BgTaskState): string {
		const elapsed = formatSeconds((task.endedAt ?? Date.now()) - task.startedAt);
		let command = task.command.replace(/\s+/g, " ").trim();
		if (command.length > LISTED_COMMAND_WIDTH - 3) {
			command = `${command.substring(0, LISTED_COMMAND_WIDTH - 3)}...`;
		}
		return `- ${task.taskId} [${describeTaskState(task)}] ${elapsed} "${command}" (output: ${task.outputFile})`;
	}

	/**
	 * The same row in the shape the chat renders it.
	 *
	 * The model-facing line above leads with the task id, because recovering an
	 * id is the model's job. A reader wants the command first — the way a
	 * `wait_task` block names the task it waits on (`command · id`) — so the
	 * frontend is handed the pieces (command, id, a short state, the elapsed
	 * time) rather than having to take that line apart again. Same ordering as
	 * `describeExit`, so the two views cannot disagree about an exit.
	 */
	function taskRow(task: BgTaskState): { id: string; command: string; state: string; elapsed: string } {
		let state: string;
		if (!task.completed) {
			state = task.foreign ? "running elsewhere" : task.adopted ? "running (adopted)" : "running";
		} else if (task.spawnError) {
			state = "failed to start";
		} else if (task.exitUnknown) {
			state = "exit unknown";
		} else if (task.signal !== null) {
			state = `stopped (${task.signal})`;
		} else {
			state = task.exitCode === 0 ? "done" : `failed (exit ${task.exitCode})`;
		}
		const flags = [
			!task.completed && task.stdinOpen ? "stdin open" : "",
			task.held !== undefined ? `held (${task.held})` : "",
		].filter((f) => f !== "");
		return {
			id: task.taskId,
			command: task.command.replace(/\s+/g, " ").trim(),
			state: flags.length > 0 ? `${state}, ${flags.join(", ")}` : state,
			elapsed: formatSeconds((task.endedAt ?? Date.now()) - task.startedAt),
		};
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
				details: { total: all.length, running: runningCount, listed: shown.length, tasks: shown.map(taskRow) },
			};
		},
	});
}
