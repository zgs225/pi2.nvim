/**
 * Background bash tasks for pi.nvim.
 *
 * pi core deliberately has no background bash. This extension fills the gap by
 * OVERRIDING the built-in `bash` tool (extension tools with the same name win —
 * agent-session _refreshToolRegistry writes extension definitions over the
 * builtin Map entries) and adding an optional `run_in_background` parameter.
 * The tool name stays "bash", so the pi.nvim RPC frontend keeps using its
 * existing bash renderer; only the schema the model sees changes.
 *
 * Foreground path (run_in_background absent/false) delegates byte-for-byte to
 * the built-in definition re-created via the publicly exported
 * `createBashToolDefinition()` from "@earendil-works/pi-coding-agent", so
 * streaming, truncation, temp-file spill, timeout kill, abort handling, shell
 * resolution and PI_* session env exposure are identical to stock pi.
 *
 * Background path (`run_in_background: true`):
 *  - Spawns `getShellConfig().shell -c <command>` detached + unref'd, with
 *    stdout/stderr streamed to `join(tmpdir(), "pi-bash-<taskId>.log")` — the
 *    same naming convention core uses for truncated-output spill files.
 *  - Returns immediately; the model is told the task id and output file and
 *    explicitly instructed NOT to poll.
 *  - The process is reaped via the "close" event; completion is reported by a
 *    custom message (customType "pi2_bg_task", display:false) sent with
 *    `{ triggerTurn: true, deliverAs: "followUp" }`. Core's convertToLlm maps
 *    custom messages to user-role context, so the report text reaches the LLM
 *    AND wakes the agent after the current turn. A `context` handler
 *    registered at load time is the fallback injector for completions that
 *    could not be delivered (e.g. stale extension ctx after reload); it reads
 *    the module-level task table and marks deliveries so nothing is injected
 *    twice.
 *  - A process.on("exit") hook SIGKILLs every tracked background process group
 *    best-effort, mirroring core's killTrackedDetachedChildren (that helper is
 *    not exported from the package root, so we track pids ourselves).
 *
 * Also handles the `user_bash` event: a leading `&` token on an interactive
 * `!`-prefixed command routes to the same background path and returns a
 * BashResult immediately (rpc-mode asks extensions before executing).
 *
 * NOTE(verify): core's `trackDetachedChildPid` / `getShellEnv` are not
 * exported from the package root, so background spawns use `{...process.env}`
 * (missing pi's bin-dir PATH prefix) and our own pid tracking; a custom
 * `shellPath` from settings.json is likewise invisible to us.
 * NOTE(verify): custom messages reach the LLM regardless of `display:false`
 * (convertToLlm maps role "custom" to user). Keep message content LLM-safe.
 */

import type { ExtensionAPI, ExtensionContext, UserBashEventResult } from "@earendil-works/pi-coding-agent";
import { createBashToolDefinition, getShellConfig } from "@earendil-works/pi-coding-agent";
import type { BashToolDetails, BashToolInput, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createWriteStream } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Type, type Static, type TSchema } from "typebox";

const CUSTOM_TYPE = "pi2_bg_task";
const BACKGROUND_PREFIX = "&";

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
	pid?: number;
	completed: boolean;
	exitCode: number | null;
	signal: string | null;
	spawnError?: string;
	/** Completion report handed to the session stream (or context injector). */
	delivered: boolean;
}

const tasks = new Map<string, BgTaskState>();
/** Background process groups to kill best-effort when the pi process exits. */
const trackedPids = new Set<number>();
let exitHookInstalled = false;

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

/**
 * Completion report text. Shared by the sendMessage path and the context
 * fallback so the agent sees exactly the same sentence either way.
 */
function buildFinishNote(task: BgTaskState): string {
	const reason = task.spawnError
		? `failed to start: ${task.spawnError}`
		: task.signal !== null
			? `was stopped (signal ${task.signal})`
			: `finished with exit code ${task.exitCode}`;
	return `[Background task ${task.taskId} ("${task.command}") ${reason}. Output: ${task.outputFile}]`;
}

/**
 * Session env for background spawns — mirrors core's resolveSpawnContext:
 * start from the parent env minus stale PI_* session variables, then expose
 * the current session metadata when a tool ctx is available. NOTE(verify):
 * core prepends its bin dir to PATH via getShellEnv(); that helper is not
 * exported, so background tasks get the parent's PATH unmodified.
 */
function buildSessionEnv(ctx: ExtensionContext | undefined): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = { ...process.env };
	delete env.PI_SESSION_ID;
	delete env.PI_SESSION_FILE;
	delete env.PI_PROVIDER;
	delete env.PI_MODEL;
	delete env.PI_REASONING_LEVEL;
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

export default function bgTasks(pi: ExtensionAPI) {
	// ------------------------------------------------------------------
	// Context fallback injector: registered ONCE at module load. Before
	// every LLM call, inject completion reports that never made it into
	// the session stream (sendMessage threw, e.g. stale ctx). Tasks whose
	// report was delivered are skipped, so the two paths never duplicate.
	// event.messages is a deep copy; nothing here is persisted.
	// ------------------------------------------------------------------
	pi.on("context", (event) => {
		const pending = [...tasks.values()].filter((task) => task.completed && !task.delivered);
		if (pending.length === 0) {
			return undefined;
		}
		for (const task of pending) {
			event.messages.push({ role: "user", content: buildFinishNote(task), timestamp: Date.now() });
			task.delivered = true;
		}
		return { messages: event.messages };
	});

	// ------------------------------------------------------------------
	// user_bash: a leading "&" token routes interactive `!` commands to
	// the background path; anything else returns undefined so core keeps
	// its normal foreground execution.
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
		const task = startBackgroundTask(command, event.cwd, buildSessionEnv(undefined));
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
	// Background spawn. Returns immediately after wiring up the process;
	// completion reporting happens in the close/error handlers.
	// ------------------------------------------------------------------
	function startBackgroundTask(command: string, cwd: string, env: NodeJS.ProcessEnv): BgTaskState {
		const taskId = "b" + randomUUID().replace(/-/g, "").substring(0, 6);
		const outputFile = join(tmpdir(), `pi-bash-${taskId}.log`);
		const task: BgTaskState = {
			taskId,
			command,
			cwd,
			outputFile,
			startedAt: Date.now(),
			completed: false,
			exitCode: null,
			signal: null,
			delivered: false,
		};
		tasks.set(taskId, task);

		let log: ReturnType<typeof createWriteStream>;
		try {
			log = createWriteStream(outputFile);
		} catch (error) {
			task.completed = true;
			task.spawnError = error instanceof Error ? error.message : String(error);
			reportCompletion(task);
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
			task.completed = true;
			task.spawnError = error instanceof Error ? error.message : String(error);
			log.end();
			reportCompletion(task);
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
			task.completed = true;
			task.spawnError = error.message;
			if (child.pid) {
				trackedPids.delete(child.pid);
			}
			log.end();
			reportCompletion(task);
		});
		child.once("close", (code, signal) => {
			task.completed = true;
			task.exitCode = code;
			task.signal = signal;
			if (child.pid) {
				trackedPids.delete(child.pid);
			}
			log.end();
			reportCompletion(task);
		});
		// Let the pi process exit even while this task runs; the exit hook
		// above kills the process group. Streams must be unref'd too, a
		// piped child alone keeps the event loop alive.
		child.unref();
		(child.stdout as { unref?: () => void } | null | undefined)?.unref?.();
		(child.stderr as { unref?: () => void } | null | undefined)?.unref?.();

		// Frontend notification (task panel). Never triggerTurn here: this
		// fires mid-tool-execution and must not interrupt the running turn;
		// while streaming, core defers display:false messages to turn end.
		try {
			pi.sendMessage({
				customType: CUSTOM_TYPE,
				content: `[Background task ${taskId} started: ${command}]`,
				display: false,
				details: {
					kind: "started",
					taskId,
					command,
					pid: child.pid,
					outputFile,
				} satisfies BgTaskDetails,
			});
		} catch {
			// Stale ctx after reload: the task still runs; only the panel misses it.
		}

		return task;
	}

	/**
	 * Report a finished task to the session stream: display:false custom
	 * message + triggerTurn followUp, so pi.nvim's RPC channel sees the event
	 * and the agent is woken with the report in its context (convertToLlm maps
	 * custom messages to user role). On success the task is marked delivered;
	 * the context handler above back-fills any delivery that threw here.
	 */
	function reportCompletion(task: BgTaskState): void {
		if (task.delivered) {
			return;
		}
		const kind: BgTaskDetails["kind"] = task.spawnError
			? "failed"
			: task.signal !== null
				? "stopped"
				: task.exitCode === 0
					? "completed"
					: "failed";
		try {
			pi.sendMessage(
				{
					customType: CUSTOM_TYPE,
					content: buildFinishNote(task),
					display: false,
					details: {
						kind,
						taskId: task.taskId,
						command: task.command,
						pid: task.pid,
						outputFile: task.outputFile,
						exitCode: task.exitCode,
						signal: task.signal,
					} satisfies BgTaskDetails,
				},
				{ triggerTurn: true, deliverAs: "followUp" },
			);
			task.delivered = true;
		} catch {
			// Stale ctx after reload etc.: leave undelivered; the context
			// handler injects the report before the next LLM call instead.
		}
	}

	// ------------------------------------------------------------------
	// Override the built-in bash tool. The foreground path delegates to
	// the exact built-in definition; only the schema (one extra optional
	// boolean) and the description differ.
	// ------------------------------------------------------------------
	const builtin = createBashToolDefinition(process.cwd());

	const bgBashParameters = Type.Object({
		...(builtin.parameters as unknown as { properties: Record<string, TSchema> }).properties,
		run_in_background: Type.Optional(
			Type.Boolean({
				description:
					"Run the command as a background task instead of blocking. Use for long-running commands such as dev servers, watchers, long builds, or test suites that take minutes. The command starts immediately, output streams to a log file whose path is returned, and you are notified with the result when it finishes. Do not poll the output file and do not append '&' to background commands. The timeout parameter does not apply to background tasks.",
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

	/** Details carried in background-mode tool results (frontend task tracking). */
	interface BgBashToolDetails extends BashToolDetails {
		background?: boolean;
		taskId?: string;
		command?: string;
		pid?: number;
		outputFile?: string;
	}

	const BG_GUIDE =
		" To run a command in the background (dev servers, watchers, long builds, long-running tests), pass run_in_background: true instead of appending '&'. You will be notified when the task completes — do not poll the output file or re-run the command to check progress. The timeout parameter does not apply to background tasks.";

	const { prepareArguments: _unusedPrepareArguments, ...builtinRest } = builtin;
	void _unusedPrepareArguments; // typed for the old schema; the new schema needs no shim

	const overridden: ToolDefinition<typeof bgBashParameters, BgBashToolDetails | undefined> = {
		...builtinRest,
		description: `${builtin.description}${BG_GUIDE}`,
		parameters: bgBashParameters,
		async execute(toolCallId, params, signal, onUpdate, ctx) {
			const { run_in_background, command, timeout } = params;
			if (!run_in_background) {
				// Foreground: exact built-in semantics (streaming, truncation,
				// timeout kill, abort, PI_* env exposure) via delegation.
				const foregroundParams: BashToolInput = { command };
				if (timeout !== undefined) {
					foregroundParams.timeout = timeout;
				}
				return builtin.execute(toolCallId, foregroundParams, signal, onUpdate, ctx);
			}
			if (typeof command !== "string" || command.trim() === "") {
				throw new Error("bg-tasks: 'command' must be a non-empty string");
			}
			const task = startBackgroundTask(command, ctx?.cwd ?? process.cwd(), buildSessionEnv(ctx));
			return {
				content: [
					{
						type: "text" as const,
						text: `Task ${task.taskId} running in background: ${command}\nOutput: ${task.outputFile}\nYou will be notified when it completes.`,
					},
				],
				details: {
					background: true,
					taskId: task.taskId,
					command,
					pid: task.pid,
					outputFile: task.outputFile,
				},
			};
		},
	};

	pi.registerTool(overridden);
}
