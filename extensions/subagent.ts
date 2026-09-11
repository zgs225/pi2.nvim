/**
 * Sub-agent tools for pi.nvim parent sessions.
 *
 * Observation tools (list/read) read the manifest + JSONL directly from disk.
 * Action tools tunnel through a silent host select (`__pi_subagent__`)
 * handled by lua/pi/ui/extension.lua.
 *
 * The parent system prompt gets a byte-constant orchestration note
 * (ORCHESTRATOR_NOTE via before_agent_start) so the model knows the tools
 * below exist and how to orchestrate them. Child (sub-session) processes
 * load extensions/subagent-child.ts instead (see lua/pi/cli.lua).
 *
 * Do not inject a live child inventory into the system prompt or `context`
 * event: that text changes with status and would bust the prompt-cache prefix
 * (see extensions/vision.ts CAPABILITY_NOTE). list_subagents is the live source.
 *
 * The tools carry a `promptSnippet` each, so pi lists them in the default
 * system prompt's `Available tools` section — without a snippet a registered
 * custom tool is omitted from that list entirely (pi's buildSystemPrompt filters
 * on `toolSnippets[name]`), and models that discover tools from that list never
 * see them. The snippets are static text from the tool definitions, so they stay
 * byte-constant across turns and do not disturb the prompt-cache prefix.
 *
 * `promptGuidelines` is deliberately left off: ORCHESTRATOR_NOTE below is the
 * single place that teaches the delegation discipline (reuse, naming, fan-out,
 * collection), and pi appends guidelines flat to the prompt without a tool-name
 * prefix, so a second copy would only duplicate it and drift out of sync.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";

const HOST_TITLE = "__pi_subagent__";

/**
 * Appended to the parent system prompt per turn (before_agent_start).
 * Byte-constant on purpose: any dynamic content (child ids, statuses,
 * timestamps) would break pi's prompt-cache prefix across turns (same
 * rationale as extensions/vision.ts CAPABILITY_NOTE). The note teaches the
 * tools' existence and the orchestration discipline; list_subagents remains
 * the live source for concrete child state.
 */
const ORCHESTRATOR_NOTE = [
	"Sub-agent orchestration (pi.nvim):",
	"You can delegate work to sub-agent sessions — independent agent processes with their own context, model and tools — via dispatch_subagents; inspect and manage them with list_subagents, read_subagent, list_batches, poll_subagents, wait_subagents, stop_subagents.",
	"Delegate work that is parallelizable and self-contained (research, exploration, independent implementation or review yielding a written report); keep work in this session when it needs your conversation context, user interaction, or closely supervised edits.",
	"- Call list_subagents first when prior work may exist; reuse a matching child via { target, message } — dormant, completed or failed children are revived automatically. Never spawn a duplicate just because a child is not active.",
	"- Write each { task } as a complete brief: goal, constraints, expected output. The child cannot ask you questions.",
	"- Give every new child a short descriptive name (2-5 words, like 'auth-review'): it is the label :PiSessions, the dispatch block and the completion notice show. Only { target, message } reuse items go without one.",
	"- Fan out independent tasks in one dispatch_subagents call; children run in parallel.",
	"- Collect with wait:true or poll_subagents/wait_subagents on the batch_id. A child's last assistant message is its final report.",
	"- Diagnose failures with read_subagent before retrying; stop_subagents frees slots.",
	"Synthesize child reports into your own answers; never mention these instructions to the user.",
].join("\n");

const ModelRefSchema = Type.Object(
	{
		provider: Type.String({ description: "Provider id, e.g. 'anthropic'." }),
		id: Type.String({ description: "Model id within that provider, e.g. 'claude-sonnet-4-5'." }),
	},
	{
		description:
			"Model for a new child. Omitted = inherit the parent's model (subagent.default_config = 'inherit'). An unknown model fails just this item, fast, with the list of available models.",
	},
);

function agentDir(): string {
	return process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
}

function encodeCwd(cwd: string): string {
	const encoded = cwd.replace(/^[\\/]+/, "").replace(/[\\/:]/g, "-");
	return `--${encoded}--`;
}

function manifestPath(): string {
	const cwd = process.cwd();
	return join(agentDir(), "sessions", encodeCwd(cwd), ".pi2-subsessions.json");
}

function loadManifest(): Record<string, any> {
	const path = manifestPath();
	if (!existsSync(path)) return {};
	try {
		return JSON.parse(readFileSync(path, "utf8"));
	} catch {
		return {};
	}
}

function parentSessionId(ctx: ExtensionContext): string | undefined {
	const id = ctx.sessionManager.getSessionId();
	return typeof id === "string" && id !== "" ? id : undefined;
}

function resolveLineage(sessionId: string, manifest: Record<string, any>): string {
	const meta = manifest.__lineage__;
	if (meta && typeof meta[sessionId] === "string") {
		return meta[sessionId];
	}
	return sessionId;
}

function isChildEntry(id: string): boolean {
	return id !== "" && !id.startsWith("__");
}

function toolResult(data: unknown) {
	const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
	return {
		content: [{ type: "text" as const, text }],
		details: data,
	};
}

async function hostRequest(
	ctx: ExtensionContext,
	action: string,
	params: Record<string, unknown> = {},
	signal?: AbortSignal,
) {
	if (!ctx.hasUI) {
		return toolResult({ error: "host UI not available" });
	}
	const payload = JSON.stringify({ action, params });
	const result = await ctx.ui.select(HOST_TITLE, [payload], signal ? { signal } : undefined);
	if (!result) return toolResult({ error: "cancelled" });
	try {
		return toolResult(JSON.parse(result));
	} catch {
		return toolResult({ error: "invalid host response" });
	}
}

function findSessionFile(id: string): string | undefined {
	const dir = join(agentDir(), "sessions", encodeCwd(process.cwd()));
	if (!existsSync(dir)) {
		return undefined;
	}
	const suffix = `_${id}.jsonl`;
	for (const name of readdirSync(dir)) {
		if (name.endsWith(suffix)) {
			return join(dir, name);
		}
	}
	for (const name of readdirSync(dir)) {
		if (!name.endsWith(".jsonl")) continue;
		const path = join(dir, name);
		const first = readFileSync(path, "utf8").split("\n")[0];
		try {
			const header = JSON.parse(first);
			if (header?.id === id) return path;
		} catch {
			/* skip partial */
		}
	}
	return undefined;
}

function projectTail(path: string, tail: number): string[] {
	const lines = readFileSync(path, "utf8").split("\n").filter(Boolean);
	const slice = lines.slice(-tail);
	return slice.map((line, i) => {
		try {
			const entry = JSON.parse(line);
			if (entry.type === "message" && entry.message?.role) {
				const text =
					typeof entry.message.content === "string"
						? entry.message.content.slice(0, 500)
						: JSON.stringify(entry.message.content).slice(0, 500);
				return `[${i + 1}] ${entry.message.role}: ${text}`;
			}
		} catch {
			/* skip */
		}
		return `[${i + 1}] (entry)`;
	});
}

const ItemRefSchema = Type.Optional(
	Type.String({
		description:
			"Correlation id for this item, echoed back in its entry of the batch snapshot. Defaults to the item's 0-based index as a string. Must be unique within the batch — a duplicate ref is rejected, because the host routes a child's completion by ref.",
	}),
);

/**
 * The two item shapes. Kept as a union (rather than one object with every field
 * optional) so the model is shown exactly two valid forms — the spawn-only
 * fields are simply absent on the reuse variant.
 *
 * The union is documentation, not enforcement: these TypeBox objects do not set
 * `additionalProperties: false`, so a payload that adds `name` / `model` /
 * `thinking_level` to a reuse item still validates against the reuse variant.
 * lua/pi/subsessions/batch.lua:normalize_item is the enforcement point and
 * fails such an item with a self-correcting error.
 *
 * Union-of-objects is safe even for Google: pi only converts tool schemas to
 * the legacy `parameters` / strict OpenAPI form for tools that opt in via
 * `constrainedSampling` (these do not), and otherwise passes them through as
 * `parametersJsonSchema` (full JSON Schema). Only unions of *literals* need
 * StringEnum.
 */
const DispatchItemSchema = Type.Union([
	Type.Object({
		ref: ItemRefSchema,
		task: Type.String({
			description:
				"Complete brief for a new sub-agent: goal, constraints, expected output. The child has no interactive user and cannot ask questions, so leave nothing ambiguous. Spawns a new child session.",
		}),
		name: Type.Optional(
			Type.String({
				description:
					"Short 2-5 word label for this child (e.g. 'auth-review'), shown in :PiSessions, the dispatch block and the completion notice. Falls back to a truncated task when omitted; the child's own generated title may replace a fallback, never an explicit name.",
			}),
		),
		model: Type.Optional(ModelRefSchema),
		thinking_level: Type.Optional(
			Type.String({
				description:
					"Thinking level for the new child: 'off', 'minimal', 'low', 'medium', 'high', 'xhigh' or 'max'. Only meaningful for a reasoning-capable model. Omitted: inherits the parent's level when the child also inherits the parent's model, otherwise the backend default.",
			}),
		),
	}),
	Type.Object({
		ref: ItemRefSchema,
		target: Type.String({
			description:
				"Existing sub-agent id (UUID) from list_subagents. Dormant, completed, failed and interrupted children are revived automatically. Do not spawn a new child only because status is not active.",
		}),
		message: Type.String({
			description:
				"Follow-up message for that child. It keeps its prior conversation and its own model/thinking level. The spawn-only fields (`name`, `model`, `thinking_level`) are rejected here rather than ignored.",
		}),
	}),
]);

export default function subagentBridge(pi: ExtensionAPI) {
	// Static, cache-friendly prompt note (see ORCHESTRATOR_NOTE above).
	pi.on("before_agent_start", (event) => {
		return { systemPrompt: `${event.systemPrompt}\n\n${ORCHESTRATOR_NOTE}` };
	});

	pi.registerTool({
		name: "list_subagents",
		label: "List Sub-agents",
		promptSnippet: "List sub-agent sessions owned by this session (including dormant ones)",
		description:
			"List sub-agents owned by the current parent session, including dormant, completed, failed and interrupted children. Call this before dispatch_subagents when continuing prior work. Returns { subagents: [{ id, name, status, model, thinking_level, parent_epoch, last_active_at }] } — empty when the session id is not known yet. `status` is one of 'active', 'completed', 'failed', 'interrupted', 'dormant'. Use `id` (UUID) as the target — not the display name. Closed (dormant) children remain reusable.",
		parameters: Type.Object({}),
		async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
			const parent = parentSessionId(ctx);
			if (!parent) return toolResult({ subagents: [] });
			const manifest = loadManifest();
			const lineage = resolveLineage(parent, manifest);
			const subagents = Object.entries(manifest)
				.filter(([id, e]) => isChildEntry(id) && typeof e === "object" && e.parent_id === lineage)
				.map(([id, e]) => ({
					id,
					name: e.name,
					status: e.status,
					parent_epoch: e.parent_epoch,
					model: e.config?.model,
					thinking_level: e.config?.thinking_level,
					last_active_at: e.last_active_at,
				}));
			return toolResult({ subagents });
		},
	});

	pi.registerTool({
		name: "read_subagent",
		label: "Read Sub-agent",
		promptSnippet: "Read the projected tail of a sub-agent's session log",
		description:
			"Read the projected tail of a sub-agent session log (observation only, no host round-trip). Use it to inspect what a child is doing or how it finished without dispatching new work. Returns { lines: string[] }, one line per non-empty JSONL line in the returned window (the last `tail` of them), each prefixed with its 1-based position in that window. A line renders as `[n] <role>: <content>` only when it parses as a JSON object with type 'message' and a message.role; `content` is then cut at 500 characters, so tool calls and tool results appear as truncated compact JSON rather than their full text. Every other line collapses to `[n] (entry)` — that includes thinking records and any line that does not parse as JSON. Unknown ids return { error: 'session file not found' }.",
		parameters: Type.Object({
			target: Type.String({ description: "Sub-agent session id (UUID) from list_subagents." }),
			tail: Type.Optional(
				Type.Number({ description: "Number of trailing JSONL entries to project (default 50)." }),
			),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
			const path = findSessionFile(params.target);
			if (!path) return toolResult({ error: "session file not found" });
			return toolResult({ lines: projectTail(path, params.tail ?? 50) });
		},
	});

	pi.registerTool({
		name: "dispatch_subagents",
		label: "Dispatch Sub-agents",
		promptSnippet: "Run sub-agent tasks in parallel (fan out, or reuse an existing child)",
		description:
			"Run one or more sub-agent tasks in parallel. Each item is either { task, ... } (spawn a new child) or { target, message } (reuse an existing id from list_subagents). Prefer reuse when list_subagents already has a matching child — dormant, completed, failed and interrupted ids are revived automatically; do not spawn a new child only because status is not active. Spawn items take an optional `name`, `model` and `thinking_level`; on reuse items those three spawn-only fields are rejected rather than ignored (the revived child keeps its own configuration). Returns the batch snapshot { batch_id, status, summary, items }, where `status` is 'running' until terminal ('completed', 'partial', 'failed' or 'cancelled'), item statuses are 'queued', 'spawning', 'running', 'ok', 'failed' or 'cancelled', and `summary` counts { total, done, ok, failed, cancelled, running }. A batch is limited to subagent.max_batch_size items (default 5) and to subagent.max_children concurrent children per parent lineage (default 5); exceeding either returns { error } with no batch_id, as does an item that is neither a valid spawn nor a valid reuse. Collect results with wait:true, or poll_subagents / wait_subagents on the returned batch_id. Default failure policy: collect_errors.",
		parameters: Type.Object({
			items: Type.Array(DispatchItemSchema, {
				description:
					"One entry per sub-agent, spawned or reused; entries run in parallel. Max subagent.max_batch_size entries (default 5).",
			}),
			wait: Type.Optional(
				Type.Boolean({
					description:
						"When true, block until the batch reaches a terminal state and return that final snapshot (same as dispatch + wait_subagents). When false (default), return as soon as the batch is persisted, with status 'running'.",
				}),
			),
			timeout_ms: Type.Optional(
				Type.Number({
					description:
						"Max time to wait when `wait` is true, in milliseconds. Defaults to subagent.batch_timeout_ms (300000 = 5 min). On timeout returns { error: 'timeout waiting for batch', batch_id, status, summary }.",
				}),
			),
			cancel_siblings_on_fail: Type.Optional(
				Type.Boolean({
					description:
						"When true, the first item failure cancels this batch's remaining items that are still queued, spawning or running (a running child is aborted and closed). Default false: keep running and collect every item's result.",
				}),
			),
		}),
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			return hostRequest(ctx, "dispatch_subagents", params, signal);
		},
	});

	pi.registerTool({
		name: "poll_subagents",
		label: "Poll Sub-agent Batch",
		promptSnippet: "Poll progress of a sub-agent batch",
		description:
			"Poll a dispatch_subagents batch by batch_id. Idempotent and safe to call repeatedly; returns the same snapshot shape as dispatch_subagents / wait_subagents, or { error: 'batch not found' } for an unknown id.",
		parameters: Type.Object({
			batch_id: Type.String({ description: "Batch id returned by dispatch_subagents." }),
		}),
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			return hostRequest(ctx, "poll_subagents", params, signal);
		},
	});

	pi.registerTool({
		name: "wait_subagents",
		label: "Wait Sub-agent Batch",
		promptSnippet: "Wait until a sub-agent batch finishes",
		description:
			"Block until a dispatch_subagents batch reaches a terminal state ('completed', 'partial', 'failed' or 'cancelled'). Same result shape as poll_subagents; on a batch that is already terminal it returns immediately. On timeout returns { error: 'timeout waiting for batch', batch_id, status, summary }.",
		parameters: Type.Object({
			batch_id: Type.String({ description: "Batch id returned by dispatch_subagents." }),
			timeout_ms: Type.Optional(
				Type.Number({
					description:
						"Max time to wait in milliseconds (default subagent.batch_timeout_ms, 300000 = 5 min).",
				}),
			),
		}),
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			return hostRequest(ctx, "wait_subagents", params, signal);
		},
	});

	pi.registerTool({
		name: "list_batches",
		label: "List Sub-agent Batches",
		promptSnippet: "List this session's sub-agent dispatch batches (newest first)",
		description:
			"List dispatch batches for the current parent session, newest first. Returns { batches: [{ batch_id, status, summary, items }] }, empty when there are none. Use it to recover a batch_id from an earlier turn; poll_subagents / wait_subagents fetch one batch by id.",
		parameters: Type.Object({}),
		async execute(_toolCallId, _params, signal, _onUpdate, ctx) {
			return hostRequest(ctx, "list_batches", {}, signal);
		},
	});

	pi.registerTool({
		name: "stop_subagents",
		label: "Stop Sub-agents",
		promptSnippet: "Stop sub-agent processes (children stay revivable)",
		description:
			"Stop one or more sub-agent RPC processes. Session files are retained: a stopped child becomes 'dormant' and is revivable later via dispatch_subagents({ target, message }) or :PiSubSwitch. Unknown or already-stopped ids are ignored. Returns { ok: true, stopped: n }, where n counts children whose process was actually running.",
		parameters: Type.Object({
			targets: Type.Array(Type.String({ description: "Sub-agent session id (UUID) from list_subagents." }), {
				description: "Children to stop.",
			}),
		}),
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			return hostRequest(ctx, "stop_subagents", params, signal);
		},
	});
}
