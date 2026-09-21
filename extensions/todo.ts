/**
 * Session todo list for pi.nvim (backend for the planned pi.nvim todo panel).
 *
 * Single tool `todo_write` with FULL-REPLACEMENT semantics (the converged
 * design of Claude Code / Codex / opencode): every call submits the complete
 * list, items are identified by their content (no ids), an empty array clears
 * the list. State lives in the tool result's `details` field — the official
 * examples/extensions/todo.ts pattern — so it is branch-correct: after a
 * branch switch, session_start / session_tree scan the branch's toolResults
 * and take the latest successful details.
 *
 * Context management is layered (static vs dynamic), mirroring
 * extensions/subagent.ts:
 *  - L1 `before_agent_start`: appends TODO_NOTE to the system prompt. The
 *    text is byte-constant on purpose — any dynamic content (list, counts,
 *    timestamps) would break pi's prompt-cache prefix across turns. Tool
 *    existence is taught by the tool's `promptSnippet` in the default system
 *    prompt's `Available tools` section; the note only carries the discipline.
 *  - L2 `context`: before every LLM call, when the list is non-empty, append
 *    a compact synthetic status message (and, predicate-gated, a reminder
 *    after remind_after_turns turns without a todo_write call). event.messages
 *    is a deep copy, so this is non-destructive: nothing is persisted to the
 *    session, and the injection re-appears after compaction because it is
 *    re-computed on every call. Dynamic content is fine here.
 *  - L3 persistence: on every successful write the state is also stored via
 *    pi.appendEntry (checkpoint). If the branch scan finds no usable
 *    toolResult (e.g. old results dropped after compaction), the latest
 *    checkpoint entry is the fallback.
 *
 * Config travels via the PI_NVIM_TODO_FILE runtime file (JSON:
 * {"enabled":bool,"remind_after_turns":number,"max_items":number}) published
 * by pi.nvim's config; the process env is frozen at spawn but the file is
 * re-read on every relevant event, so live setup() calls apply immediately
 * (same pattern as extensions/title.ts). Outside pi.nvim the file is absent:
 * defaults apply. When `enabled` is false at load the extension registers
 * nothing; a flip to false afterwards turns every handler into a no-op.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Text } from "@earendil-works/pi-tui";
import { readFileSync } from "node:fs";
import { Type } from "typebox";

const ENV_FILE = "PI_NVIM_TODO_FILE";
const TOOL_NAME = "todo_write";
const CHECKPOINT_TYPE = "pi2-todo";
const MAX_CONTEXT_ITEMS = 10;
const COLLAPSED_ITEMS = 5;
const DEFAULT_MAX_ITEMS = 20;
const DEFAULT_REMIND_AFTER_TURNS = 3;

interface TodoItem {
	content: string;
	status: "pending" | "in_progress" | "completed";
	activeForm?: string;
}

interface TodoDetails {
	todos: TodoItem[];
	completed: number;
	total: number;
	error?: string;
}

interface TodoConfig {
	enabled: boolean;
	remind_after_turns: number;
	max_items: number;
}

function readConfig(): TodoConfig {
	const path = process.env[ENV_FILE];
	const cfg: TodoConfig = {
		enabled: true,
		remind_after_turns: DEFAULT_REMIND_AFTER_TURNS,
		max_items: DEFAULT_MAX_ITEMS,
	};
	if (!path) {
		return cfg;
	}
	try {
		const parsed = JSON.parse(readFileSync(path, "utf8")) as {
			enabled?: unknown;
			remind_after_turns?: unknown;
			max_items?: unknown;
		};
		if (typeof parsed.enabled === "boolean") cfg.enabled = parsed.enabled;
		if (typeof parsed.remind_after_turns === "number" && Number.isInteger(parsed.remind_after_turns) && parsed.remind_after_turns >= 0) {
			cfg.remind_after_turns = parsed.remind_after_turns;
		}
		if (typeof parsed.max_items === "number" && Number.isInteger(parsed.max_items) && parsed.max_items > 0) {
			cfg.max_items = parsed.max_items;
		}
	} catch {
		// Unreadable/corrupt file: fall back to defaults.
	}
	return cfg;
}

/**
 * Appended to the system prompt per turn (before_agent_start). Byte-constant
 * on purpose: any dynamic content (the list itself, counts, timestamps) would
 * break pi's prompt-cache prefix across turns (same rationale as
 * extensions/subagent.ts ORCHESTRATOR_NOTE). The live list is injected by the
 * `context` handler below (L2), not here.
 */
const TODO_NOTE = [
	"You have a todo_write tool for tracking progress on multi-step work. Use it when a task has roughly three or more steps, spans several files or parts, is ambiguous enough to need an explicit plan, or the user asked you to track tasks; skip it for single trivial steps and pure questions. Every todo_write call replaces the entire list (an empty array clears it), so always submit the complete list. Keep exactly one item in_progress at a time. Mark an item completed immediately when it is truly done — verified, tests passing — never batch completions; if blocked, keep the item in_progress and add an item describing the blocker. Write content as an imperative (\"Run the test suite\") and give the in-progress item an activeForm in present continuous (\"Running the test suite\").",
].join("\n");

const TODO_DESCRIPTION = [
	"Write the session todo list used to track progress on multi-step work.",
	"When to use: the task has roughly three or more steps, spans multiple files or parts, is ambiguous enough to need an explicit plan first, or the user asked to track tasks.",
	"When NOT to use: single trivial steps or pure Q&A — just do the work.",
	"FULL REPLACEMENT semantics: every call submits the complete list; items are identified by their content (no ids), reordering is just a new list, and an empty `todos` array clears the list.",
	"Discipline: keep exactly ONE item `in_progress` at any moment — a call with more than one is rejected. Mark an item `completed` IMMEDIATELY when it is truly done (verified, tests passing) — never batch completions. Only mark `completed` when it is actually finished; if blocked, keep the item `in_progress` and add an item describing the blocker. Drop items that turned out unnecessary instead of leaving them pending.",
	"`content` is the imperative form (\"Run the test suite\"); `activeForm` is the present-continuous form (\"Running the test suite\") and is recommended for the item marked `in_progress` (used for progress display).",
	"On validation errors the result states exactly what to fix — correct the arguments and call again; the previous list is unchanged.",
].join(" ");

const TodoItemSchema = Type.Object(
	{
		content: Type.String({
			description: "What to do, imperative form, e.g. 'Run the test suite'.",
		}),
		status: StringEnum(["pending", "in_progress", "completed"] as const, {
			description: "Item state. Exactly one item may be in_progress at a time.",
		}),
		activeForm: Type.Optional(
			Type.String({
				description: "Present-continuous form shown while the item is in_progress, e.g. 'Running the test suite'.",
			}),
		),
	},
	// `additionalProperties` is intentionally not set (same as subagent.ts):
	// the schema documents the shape; the strict checks live in execute().
);

function countCompleted(items: TodoItem[]): number {
	return items.filter((item) => item.status === "completed").length;
}

function isValidTodos(value: unknown): value is TodoItem[] {
	return (
		Array.isArray(value) &&
		value.every(
			(item) =>
				item !== null &&
				typeof item === "object" &&
				typeof (item as TodoItem).content === "string" &&
				typeof (item as TodoItem).status === "string",
		)
	);
}

/** Details for a rejected write: error text plus the unchanged current list. */
function errorDetails(current: TodoItem[], error: string): TodoDetails {
	return { todos: [...current], completed: countCompleted(current), total: current.length, error };
}

function toolResult(details: TodoDetails) {
	const lines: string[] = [];
	if (details.error) {
		lines.push(`Error: ${details.error}`);
		lines.push("Fix the arguments and call todo_write again; the current list is unchanged.");
	} else {
		lines.push(
			`Todos updated (${details.completed}/${details.total} completed). Keep tracking progress with todo_write.`,
		);
		for (const item of details.todos) {
			if (item.status === "completed") {
				lines.push(`✓ ${item.content}`);
			} else if (item.status === "in_progress") {
				lines.push(`◐ ${item.activeForm ?? item.content}`);
			} else {
				lines.push(`○ ${item.content}`);
			}
		}
	}
	return {
		content: [{ type: "text" as const, text: lines.join("\n") }],
		details,
	};
}

/**
 * The L2 context-injection text (or undefined — never called with an empty
 * list). Compact by design: a header line with progress, one line per
 * incomplete item, truncated beyond MAX_CONTEXT_ITEMS, plus the
 * predicate-gated stale-list reminder.
 */
function buildContextNote(cfg: TodoConfig): string {
	const total = todos.length;
	const completed = countCompleted(todos);
	const inProgress = todos.find((item) => item.status === "in_progress");
	const lines = [
		`[todo] ${completed}/${total} completed` +
			(inProgress ? ` — in progress: ${inProgress.activeForm ?? inProgress.content}` : ""),
	];
	const incomplete = todos.filter((item) => item.status !== "completed");
	for (const item of incomplete.slice(0, MAX_CONTEXT_ITEMS)) {
		if (item.status === "in_progress") {
			lines.push(`- ◐ ${item.activeForm ?? item.content}`);
		} else {
			lines.push(`- ○ ${item.content}`);
		}
	}
	if (incomplete.length > MAX_CONTEXT_ITEMS) {
		lines.push(`- … ${incomplete.length - MAX_CONTEXT_ITEMS} more incomplete items`);
	}
	const turnsSinceWrite = turnCount - lastWriteTurn;
	if (cfg.remind_after_turns > 0 && incomplete.length > 0 && turnsSinceWrite > cfg.remind_after_turns) {
		lines.push(
			`[todo] reminder: the list has not been updated for ${turnsSinceWrite} turns. ` +
				"If you are still working through the plan, call todo_write with the full list to sync statuses; " +
				"mark items completed immediately as they finish.",
		);
	}
	return lines.join("\n");
}

// In-memory state, reconstructed from the session on session_start/session_tree.
let todos: TodoItem[] = [];
// Monotonic counter of turn_start events; the reminder compares it against
// the value captured at the last successful todo_write call.
let turnCount = 0;
let lastWriteTurn = 0;

function reconstruct(ctx: ExtensionContext): void {
	// Branch scan: latest successful todo_write toolResult wins (getBranch
	// returns entries root → leaf, so the last match is the newest).
	let fromBranch: TodoItem[] | undefined;
	for (const entry of ctx.sessionManager.getBranch()) {
		if (entry.type !== "message") continue;
		const message = entry.message as { role?: string; toolName?: string; details?: unknown };
		if (message?.role !== "toolResult" || message.toolName !== TOOL_NAME) continue;
		const details = message.details as TodoDetails | undefined;
		if (!details || details.error || !isValidTodos(details.todos)) continue;
		fromBranch = details.todos;
	}
	if (fromBranch) {
		todos = fromBranch.map((item) => ({ ...item }));
		lastWriteTurn = turnCount;
		return;
	}
	// Fallback: latest appendEntry checkpoint (compaction survival).
	for (const entry of [...ctx.sessionManager.getEntries()].reverse()) {
		if (entry.type !== "custom" || entry.customType !== CHECKPOINT_TYPE) continue;
		const data = entry.data as { todos?: unknown } | undefined;
		if (data && isValidTodos(data.todos)) {
			todos = data.todos.map((item) => ({ ...item }));
			break;
		}
	}
	lastWriteTurn = turnCount;
}

export default function todo(pi: ExtensionAPI) {
	// Register nothing when disabled at load time. A later flip to false
	// still turns every handler below into a no-op via readConfig().
	if (!readConfig().enabled) {
		return;
	}

	// L1: byte-constant discipline note (prompt-cache friendly).
	pi.on("before_agent_start", (event) => {
		if (!readConfig().enabled) return undefined;
		return { systemPrompt: `${event.systemPrompt}\n\n${TODO_NOTE}` };
	});

	// L2 bookkeeping: count agent turns for the stale-list reminder.
	pi.on("turn_start", () => {
		turnCount += 1;
	});

	// L3: rebuild state when the session (re)starts or the branch changes.
	pi.on("session_start", async (_event, ctx) => reconstruct(ctx));
	pi.on("session_tree", async (_event, ctx) => reconstruct(ctx));

	// L2: dynamic status (and reminder) before every LLM call. event.messages
	// is a deep copy, so the appended message never reaches the session file.
	pi.on("context", (event) => {
		const cfg = readConfig();
		if (!cfg.enabled || todos.length === 0) return undefined;
		event.messages.push({ role: "user", content: buildContextNote(cfg), timestamp: Date.now() });
		return { messages: event.messages };
	});

	pi.registerTool({
		name: TOOL_NAME,
		label: "Todo Write",
		promptSnippet: "Create and update the session task list to track progress on multi-step work",
		description: TODO_DESCRIPTION,
		parameters: Type.Object({
			todos: Type.Array(TodoItemSchema, {
				description:
					"The complete todo list; replaces the previous one. Empty array clears the list. Keep exactly one item in_progress.",
			}),
		}),
		async execute(_toolCallId, params, _signal, _onUpdate, _ctx) {
			if (!readConfig().enabled) {
				return toolResult(errorDetails(todos, "todo extension is disabled"));
			}
			const raw: unknown = (params as { todos?: unknown })?.todos;
			if (!Array.isArray(raw)) {
				return toolResult(errorDetails(todos, 'params.todos must be an array of { content, status, activeForm? } items'));
			}
			const cfg = readConfig();
			const items: TodoItem[] = [];
			for (const [index, entry] of raw.entries()) {
				const item = entry as { content?: unknown; status?: unknown; activeForm?: unknown };
				const content = typeof item?.content === "string" ? item.content.trim() : "";
				if (content === "") {
					return toolResult(
						errorDetails(
							todos,
							`item ${index} is missing a non-empty "content" — every item needs an imperative description (e.g. "Run the test suite")`,
						),
					);
				}
				if (item?.status !== "pending" && item?.status !== "in_progress" && item?.status !== "completed") {
					return toolResult(
						errorDetails(
							todos,
							`item ${index} has an invalid "status" (${String(item?.status)}) — use exactly one of "pending", "in_progress", "completed"`,
						),
					);
				}
				const activeForm =
					typeof item?.activeForm === "string" && item.activeForm.trim() !== "" ? item.activeForm.trim() : undefined;
				items.push(activeForm ? { content, status: item.status as TodoItem["status"], activeForm } : { content, status: item.status as TodoItem["status"] });
			}
			if (items.length > cfg.max_items) {
				return toolResult(
					errorDetails(
						todos,
						`${items.length} items exceeds the limit of ${cfg.max_items} — trim the list to the essential steps (merge or drop sub-steps) and call again`,
					),
				);
			}
			const inProgressCount = items.filter((item) => item.status === "in_progress").length;
			if (inProgressCount > 1) {
				return toolResult(
					errorDetails(
						todos,
						`${inProgressCount} items are in_progress — keep exactly one item in_progress (the task you are working on right now) and set the others to pending or completed`,
					),
				);
			}
			todos = items;
			lastWriteTurn = turnCount;
			const details: TodoDetails = {
				todos: [...todos],
				completed: countCompleted(todos),
				total: todos.length,
			};
			// Checkpoint for compaction survival (L3 fallback path).
			pi.appendEntry(CHECKPOINT_TYPE, { todos: details.todos, completed: details.completed, total: details.total });
			return toolResult(details);
		},

		renderCall(args, theme, _context) {
			const raw: unknown = args?.todos;
			const count = Array.isArray(raw) ? raw.length : 0;
			const text =
				theme.fg("toolTitle", theme.bold("todo_write ")) +
				theme.fg("muted", count === 0 ? "clear list" : `${count} item${count === 1 ? "" : "s"}`);
			return new Text(text, 0, 0);
		},

		renderResult(result, { expanded }, theme, _context) {
			const details = result.details as TodoDetails | undefined;
			if (details?.error) {
				return new Text(theme.fg("error", `Error: ${details.error}`), 0, 0);
			}
			const list = details && isValidTodos(details.todos) ? details.todos : todos;
			if (list.length === 0) {
				return new Text(theme.fg("dim", "Todo list cleared"), 0, 0);
			}
			let text = theme.fg("muted", `${countCompleted(list)}/${list.length} completed`);
			const shown = expanded ? list : list.slice(0, COLLAPSED_ITEMS);
			for (const item of shown) {
				if (item.status === "completed") {
					text += `\n${theme.fg("success", "✓")} ${theme.fg("dim", item.content)}`;
				} else if (item.status === "in_progress") {
					text += `\n${theme.fg("accent", "◐")} ${theme.fg("text", item.activeForm ?? item.content)}`;
				} else {
					text += `\n${theme.fg("dim", "○")} ${theme.fg("text", item.content)}`;
				}
			}
			if (!expanded && list.length > COLLAPSED_ITEMS) {
				text += `\n${theme.fg("dim", `... ${list.length - COLLAPSED_ITEMS} more`)}`;
			}
			return new Text(text, 0, 0);
		},
	});
}
