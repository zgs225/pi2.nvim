/**
 * Sub-agent tools for pi.nvim parent sessions.
 *
 * Observation tools (list/read) read the manifest + JSONL directly from disk.
 * Action tools tunnel through a silent host select (`__pi_subagent__`)
 * handled by lua/pi/ui/extension.lua.
 *
 * Do not inject a live child inventory into the system prompt or `context`
 * event: that text changes with status and would bust the prompt-cache prefix
 * (see extensions/vision.ts CAPABILITY_NOTE). list_subagents is the live source.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";

const HOST_TITLE = "__pi_subagent__";

const ModelRefSchema = Type.Object({
	provider: Type.String(),
	id: Type.String(),
});

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

async function hostRequest(ctx: ExtensionContext, action: string, params: Record<string, unknown> = {}) {
	if (!ctx.hasUI) {
		return toolResult({ error: "host UI not available" });
	}
	const payload = JSON.stringify({ action, params });
	const result = await ctx.ui.select(HOST_TITLE, [payload]);
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

const DispatchItemSchema = Type.Union([
	Type.Object({
		ref: Type.Optional(Type.String({ description: "Correlation id for poll results" })),
		task: Type.String({ description: "Task for a new sub-agent" }),
		name: Type.Optional(Type.String()),
		model: Type.Optional(ModelRefSchema),
		thinking_level: Type.Optional(Type.String()),
	}),
	Type.Object({
		ref: Type.Optional(Type.String()),
		target: Type.String({
			description:
				"Existing sub-agent UUID from list_subagents. Reuse dormant/completed/failed/interrupted children too; the host revives the process. Do not spawn a new child only because status is not active.",
		}),
		message: Type.String(),
	}),
]);

export default function subagentBridge(pi: ExtensionAPI) {
	pi.registerTool({
		name: "list_subagents",
		label: "List Sub-agents",
		description:
			"List sub-agents owned by the current parent session, including dormant, completed, failed, and interrupted children. Call this before dispatch_subagents when continuing prior work. Returns { subagents: [{ id, name, status, ... }] }. Use id (UUID) as target — not the display name. Closed (dormant) children remain reusable.",
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
		description:
			"Read the projected tail of a sub-agent session log (observation only). Use to inspect a child without dispatching new work.",
		parameters: Type.Object({
			target: Type.String({ description: "Sub-agent session id from list_subagents" }),
			tail: Type.Optional(Type.Number({ description: "Number of JSONL entries to read (default 50)" })),
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
		description:
			"Run one or more sub-agent tasks in parallel. Each item is either { task } (spawn a new child) or { target, message } (reuse an existing id from list_subagents). Prefer { target, message } when list_subagents already has a matching child — dormant/completed/failed/interrupted ids still work; the host revives the process. Do not spawn a new child only because status is not active. Returns batch_id; use poll_subagents or set wait:true to collect results. Default failure policy: collect_errors.",
		parameters: Type.Object({
			items: Type.Array(DispatchItemSchema),
			wait: Type.Optional(
				Type.Boolean({
					description: "When true, block until the batch finishes (same as dispatch + wait_subagents). Default false.",
				}),
			),
			timeout_ms: Type.Optional(Type.Number({ description: "Max wait when wait:true (default from config)" })),
			cancel_siblings_on_fail: Type.Optional(
				Type.Boolean({
					description: "When true, cancel remaining items after the first failure (default false).",
				}),
			),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			return hostRequest(ctx, "dispatch_subagents", params);
		},
	});

	pi.registerTool({
		name: "poll_subagents",
		label: "Poll Sub-agent Batch",
		description: "Poll progress of a dispatch_subagents batch by batch_id. Idempotent; safe to call repeatedly.",
		parameters: Type.Object({
			batch_id: Type.String(),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			return hostRequest(ctx, "poll_subagents", params);
		},
	});

	pi.registerTool({
		name: "wait_subagents",
		label: "Wait Sub-agent Batch",
		description:
			"Block until a dispatch_subagents batch reaches a terminal state (completed, partial, failed, or cancelled). Same result shape as poll_subagents.",
		parameters: Type.Object({
			batch_id: Type.String(),
			timeout_ms: Type.Optional(Type.Number({ description: "Max wait in ms (default from config)" })),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			return hostRequest(ctx, "wait_subagents", params);
		},
	});

	pi.registerTool({
		name: "list_batches",
		label: "List Sub-agent Batches",
		description: "List dispatch batches for the current parent session (newest first).",
		parameters: Type.Object({}),
		async execute(_toolCallId, _params, _signal, _onUpdate, ctx) {
			return hostRequest(ctx, "list_batches", {});
		},
	});

	pi.registerTool({
		name: "stop_subagents",
		label: "Stop Sub-agents",
		description:
			"Stop one or more sub-agent RPC processes (session files retained; revive later via dispatch_subagents or :PiSubSwitch).",
		parameters: Type.Object({
			targets: Type.Array(Type.String({ description: "Sub-agent session ids from list_subagents" })),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
			return hostRequest(ctx, "stop_subagents", params);
		},
	});
}
