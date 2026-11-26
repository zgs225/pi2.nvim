/**
 * The `ask` tool: a bounded set of multiple-choice questions the model blocks
 * on, answered by the human in the pi.nvim UI.
 *
 * Wire protocol (TS ↔ lua/pi/ui/ask.lua, both sides must stay in sync):
 *
 *  - down: `ctx.ui.select("__pi_ask__", [JSON.stringify({ v: 1, questions })], { signal })`
 *    with one element, so the host always sees exactly one payload line:
 *    `{"v":1,"questions":[{"id","header","question","options":[{"label","description?"}],"multi"?,"placeholder"?}]}`
 *  - up: the selected string is JSON
 *    `{"v":1,"answers":[{"id","answered","selected":[i],"labels":["..."],"custom":null}],"cancelled":false}`
 *    or `{"v":1,"cancelled":true}`; a host that does not know the tool answers
 *    `{"v":1,"error":"unsupported"}`.
 *
 * Hosts that cannot run the dialog degrade instead of failing: `unsupported` /
 * a malformed answer falls back to one plain `ctx.ui.select` per question (with
 * a free-text escape hatch) and the result is marked `degraded` in `details`.
 *
 * Config travels via the PI_NVIM_ASK_FILE runtime file
 * ({"enabled","max_questions","max_options","allow_free_text","timeout_ms"})
 * published by pi.nvim's config. The process env is frozen at spawn, but the
 * file is re-read on every tool call and every before_agent_start event, so
 * live setup() calls apply immediately (same pattern as extensions/todo.ts).
 * Outside pi.nvim the file is absent and the defaults apply.
 *
 * `details` is what the pi.nvim renderer and the tests read:
 * `{ questions, answers, cancelled, degraded? }`.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { Type } from "typebox";

const ENV_FILE = "PI_NVIM_ASK_FILE";
const HOST_TITLE = "__pi_ask__";
const TOOL_NAME = "ask";

const DEFAULT_MAX_QUESTIONS = 4;
const DEFAULT_MAX_OPTIONS = 4;

/** Labels the UI adds itself; a question that ships one would duplicate it. */
const RESERVED_LABELS = new Set([
	"other",
	"type something",
	"custom",
	"none of the above",
	"skip",
	"其它",
	"其他",
	"自定义",
]);

/** The extra entry the degraded path appends to every option list. */
const FALLBACK_FREE_TEXT = "Type your own answer";

const DISABLED_TEXT =
	"Asking the user is disabled (ask.enabled = false). Continue with a sensible default and state the assumption.";

const CANCELLED_TEXT =
	"User cancelled the ask; no answers were provided. Continue with sensible defaults and state which assumption you made.";

const NO_UI_TEXT =
	"Asking the user is unavailable: this session has no interactive UI. Continue with a sensible default and state the assumption.";

interface AskOption {
	label: string;
	description?: string;
}

interface AskQuestion {
	id: string;
	header: string;
	question: string;
	options?: AskOption[];
	multi?: boolean;
	placeholder?: string;
}

interface AskAnswer {
	id: string;
	answered: boolean;
	selected: number[];
	labels: string[];
	custom?: string;
}

interface AskDetails {
	questions: AskQuestion[];
	answers: AskAnswer[];
	cancelled: boolean;
	degraded?: boolean;
}

interface AskConfig {
	enabled: boolean;
	max_questions: number;
	max_options: number;
	allow_free_text: boolean;
	timeout_ms: number | null;
}

/** A host answer: either answers, a cancellation, or a reason to degrade. */
interface HostResult {
	answers?: AskAnswer[];
	cancelled?: boolean;
	error?: string;
}

/**
 * Read the pi.nvim-published options. Mirrors extensions/todo.ts:72-99: a
 * missing or corrupt file falls back to the defaults, and every field is
 * type-checked before it is trusted.
 */
function readConfig(): AskConfig {
	const path = process.env[ENV_FILE];
	const cfg: AskConfig = {
		enabled: true,
		max_questions: DEFAULT_MAX_QUESTIONS,
		max_options: DEFAULT_MAX_OPTIONS,
		allow_free_text: true,
		timeout_ms: null,
	};
	if (!path) {
		return cfg;
	}
	try {
		const parsed = JSON.parse(readFileSync(path, "utf8")) as {
			enabled?: unknown;
			max_questions?: unknown;
			max_options?: unknown;
			allow_free_text?: unknown;
			timeout_ms?: unknown;
		};
		if (typeof parsed.enabled === "boolean") cfg.enabled = parsed.enabled;
		if (
			typeof parsed.max_questions === "number" &&
			Number.isInteger(parsed.max_questions) &&
			parsed.max_questions > 0
		) {
			cfg.max_questions = parsed.max_questions;
		}
		if (typeof parsed.max_options === "number" && Number.isInteger(parsed.max_options) && parsed.max_options > 0) {
			cfg.max_options = parsed.max_options;
		}
		if (typeof parsed.allow_free_text === "boolean") cfg.allow_free_text = parsed.allow_free_text;
		if (typeof parsed.timeout_ms === "number" && Number.isInteger(parsed.timeout_ms) && parsed.timeout_ms > 0) {
			cfg.timeout_ms = parsed.timeout_ms;
		}
	} catch {
		// Unreadable/corrupt file: fall back to defaults.
	}
	return cfg;
}

const AskOptionSchema = Type.Object(
	{
		label: Type.String({
			description:
				"Short answer shown in the option list (a few words). Do not use 'Other', 'Custom', 'Skip' or similar: the UI adds a free-text entry itself.",
			minLength: 1,
		}),
		description: Type.Optional(
			Type.String({
				description: "One line of context shown next to the label, e.g. the tradeoff of choosing it.",
			}),
		),
	},
	{
		description: "One selectable answer.",
		additionalProperties: false,
	},
);

const AskQuestionSchema = Type.Object(
	{
		id: Type.String({
			description: "Stable short identifier (lowercase, no spaces) used to attach the answer to this question.",
			minLength: 1,
		}),
		header: Type.String({
			description: "Very short title (1-3 words) naming the topic, e.g. 'Storage' or 'Test runner'.",
			minLength: 1,
		}),
		question: Type.String({
			description:
				"The question itself, one sentence, specific enough that each option is a complete answer.",
			minLength: 1,
		}),
		options: Type.Optional(
			Type.Array(AskOptionSchema, {
				description:
					"2-4 mutually exclusive answers, best answer first. Omit the whole array for a free-text-only question.",
				minItems: 2,
				maxItems: 4,
			}),
		),
		multi: Type.Optional(
			Type.Boolean({
				description: "true when more than one option may be selected (default false: single choice).",
			}),
		),
		placeholder: Type.Optional(
			Type.String({
				description: "Placeholder for the free-text field, e.g. 'e.g. a version pin'. Also used when there are no options.",
			}),
		),
	},
	{
		description: "One question with its candidate answers.",
		additionalProperties: false,
	},
);

const AskParams = Type.Object(
	{
		questions: Type.Array(AskQuestionSchema, {
			description:
				"Everything you need to know, asked at once: 1-4 questions, each with 2-4 options (or none for free text).",
			minItems: 1,
			maxItems: DEFAULT_MAX_QUESTIONS,
		}),
	},
	{
		description: "The questions to put to the user.",
		additionalProperties: false,
	},
);

/** Comparison form of a label: trimmed, lowercased, trailing dots removed. */
function normalizeLabel(label: string): string {
	return label
		.trim()
		.toLowerCase()
		.replace(/[.。]+$/, "")
		.trim();
}

/**
 * Reject a call the model can fix itself, with the reason spelled out. Returns
 * undefined when the parameters are acceptable.
 */
function validate(params: { questions?: AskQuestion[] } | undefined, cfg: AskConfig): string | undefined {
	const questions = params?.questions ?? [];
	if (questions.length === 0) {
		return "ask needs at least one question — pass one or more questions, or answer the user in plain text instead of calling ask.";
	}
	if (questions.length > cfg.max_questions) {
		return `${questions.length} questions exceeds the limit of ${cfg.max_questions} — ask at most ${cfg.max_questions} at once, merging or dropping the rest.`;
	}
	const seenIds = new Set<string>();
	for (const [index, question] of questions.entries()) {
		const id = typeof question.id === "string" ? question.id.trim() : "";
		const where = id === "" ? `question ${index + 1}` : `question "${id}"`;
		if (id === "") {
			return `question ${index + 1} has an empty "id" — give every question a short stable id.`;
		}
		if (seenIds.has(id)) {
			return `duplicate question id "${id}" — each question needs its own id so the answers stay attachable.`;
		}
		seenIds.add(id);
		const options = question.options ?? [];
		if (options.length > cfg.max_options) {
			return `${where} has ${options.length} options, more than the limit of ${cfg.max_options} — keep the ${cfg.max_options} most likely answers.`;
		}
		if (options.length === 1) {
			return `${where} has a single option — give at least 2 options, or omit "options" entirely for a free-text question.`;
		}
		const seenLabels = new Set<string>();
		for (const option of options) {
			const label = typeof option.label === "string" ? option.label : "";
			const key = normalizeLabel(label);
			if (RESERVED_LABELS.has(key)) {
				return `${where} uses the reserved option label "${label}" — the UI adds a free-text / other entry itself, so use a concrete answer instead.`;
			}
			if (seenLabels.has(key)) {
				return `${where} repeats the option label "${label}" — every option must be distinct.`;
			}
			seenLabels.add(key);
		}
	}
	return undefined;
}

/** The details block for a call that produced no answers at all. */
function emptyDetails(): AskDetails {
	return { questions: [], answers: [], cancelled: false };
}

/**
 * Ask the host UI one payload for all questions. Every failure mode is a
 * value, never a throw: the caller decides between degrading and erroring.
 */
async function askHost(
	ctx: ExtensionContext,
	questions: AskQuestion[],
	signal?: AbortSignal,
): Promise<HostResult> {
	if (!ctx.hasUI) return { error: "no-ui" };
	const cfg = readConfig();
	const options: { signal?: AbortSignal; timeout?: number } = {};
	if (signal) options.signal = signal;
	if (cfg.timeout_ms !== null) options.timeout = cfg.timeout_ms;
	const payload = JSON.stringify({ v: 1, questions });
	const raw = await ctx.ui.select(HOST_TITLE, [payload], options);
	if (!raw) return { cancelled: true };
	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch {
		return { error: "bad-host-response" };
	}
	if (parsed === null || typeof parsed !== "object") return { error: "bad-host-response" };
	const response = parsed as { v?: unknown; answers?: unknown; cancelled?: unknown; error?: unknown };
	if (response.v !== 1) return { error: "bad-host-response" };
	if (typeof response.error === "string") return { error: response.error };
	if (response.cancelled === true) return { cancelled: true };
	if (!Array.isArray(response.answers)) return { error: "bad-host-response" };
	return { answers: response.answers as AskAnswer[], cancelled: false };
}

/**
 * Degraded path for hosts without the payload protocol: one plain
 * `ctx.ui.select` per question, the free-text entry appended by hand. A
 * multi-select question collapses to a single choice (that is the degradation),
 * and cancelling any step cancels the whole ask.
 */
async function askFallback(ctx: ExtensionContext, questions: AskQuestion[]): Promise<HostResult> {
	const answers: AskAnswer[] = [];
	for (const question of questions) {
		const labels = (question.options ?? []).map((option) => option.label);
		const choices = labels.concat([FALLBACK_FREE_TEXT]);
		const title = `${question.header} · ${question.question}`;
		const picked = await ctx.ui.select(title, choices);
		if (!picked) return { cancelled: true };
		if (picked === FALLBACK_FREE_TEXT) {
			const text = await ctx.ui.input(question.header, question.placeholder ?? question.question);
			if (!text) return { cancelled: true };
			answers.push({ id: question.id, answered: true, selected: [], labels: [], custom: text });
			continue;
		}
		const index = labels.indexOf(picked);
		if (index < 0) return { cancelled: true };
		// 1-based, matching the float's numbered rows (see answerText).
		answers.push({ id: question.id, answered: true, selected: [index + 1], labels: [picked] });
	}
	return { answers, cancelled: false };
}

/**
 * The text the model reads. Fixed phrasing on purpose (a test and the
 * renderer both read the details, but the model reads this line by line):
 * one line per question, so a 4-question ask is still scannable.
 */
function answerText(answers: AskAnswer[]): string {
	const lines = ["User answered:"];
	for (const answer of answers) {
		if (typeof answer.custom === "string" && answer.custom.trim() !== "") {
			lines.push(`- ${answer.id}: (wrote) ${answer.custom}`);
		} else if (answer.answered && answer.labels.length > 0) {
			// Both hosts report 1-based positions: the float numbers its option rows
			// 1..n and the degraded path stores `index + 1` below. Do not shift.
			const positions = answer.selected.join(", ");
			lines.push(`- ${answer.id}: ${answer.labels.join(", ")} (option ${positions})`);
		} else {
			lines.push(`- ${answer.id}: Unanswered`);
		}
	}
	return lines.join("\n");
}

const ASK_DESCRIPTION = [
	"Ask the user a small, bounded set of multiple-choice questions and block until they answer.",
	"Use it when you are genuinely blocked on a decision that is the user's to make: one you cannot resolve from the request, the code, or a sensible default. Each call asks everything you need at once (1-4 questions, each with 2-4 options or none for a free-text answer).",
	"Never use it to ask permission for a command or an edit — that is what the diff review path is for.",
	"Put the option you recommend first and append ' (Recommended)' to its label, and give each option a one-line description when the tradeoff is not obvious.",
	"Never add an 'Other' / 'Type something' / 'Skip' option: the UI adds a free-text entry itself and such a label is rejected.",
	"The result states that the user answered, cancelled, or that asking is unavailable; when you proceed without an answer, say which assumption you made.",
	"Prefer reading the code or choosing a conventional default over asking.",
].join(" ");

export default function ask(pi: ExtensionAPI) {
	// Read the config once at load: it decides whether the tool starts active
	// for this process. before_agent_start re-reads it so a live setup() flip
	// reaches an already-spawned process.
	const cfgAtLoad = readConfig();

	pi.registerTool({
		name: TOOL_NAME,
		label: "Ask",
		promptSnippet: "Ask the user a bounded set of multiple-choice questions and block until answered",
		description: ASK_DESCRIPTION,
		promptGuidelines: [
			"Use ask only when you are blocked on a decision that is genuinely the user's to make — one you cannot resolve from the request, the code, or a sensible default.",
			"Never use ask to request permission for a command or an edit; that is the diff review path.",
			"Put the option you recommend first and append ' (Recommended)' to its label.",
			"Never include an option like 'Other' or 'Type something' — the UI adds it automatically and such a label is rejected.",
			"Ask at most 4 questions per call and at most 4 options per question, and ask everything you need at once instead of one question per turn.",
			"Prefer reading the code or choosing a conventional default over asking; when you do proceed without an answer, say which assumption you made.",
		],
		parameters: AskParams,
		// One blocking dialog at a time: two concurrent asks would fight over
		// the same float and the same answers.
		executionMode: "sequential",
		// A disabled tool is registered but inactive, so a later
		// before_agent_start can activate it without a respawn.
		...(cfgAtLoad.enabled ? {} : { defaultActive: false }),
		async execute(_toolCallId, params, signal, _onUpdate, ctx) {
			const cfg = readConfig();
			if (!cfg.enabled) {
				return { content: [{ type: "text" as const, text: DISABLED_TEXT }], details: emptyDetails() };
			}
			const error = validate(params as { questions?: AskQuestion[] }, cfg);
			if (error) {
				return { content: [{ type: "text" as const, text: error }], details: emptyDetails(), isError: true };
			}
			const questions: AskQuestion[] = (params.questions ?? []).map((question) => ({
				...question,
				...(question.options ? { options: question.options.map((option) => ({ ...option })) } : {}),
			}));

			let result = await askHost(ctx, questions, signal);
			if (result.error === "no-ui") {
				return {
					content: [{ type: "text" as const, text: NO_UI_TEXT }],
					details: { questions, answers: [], cancelled: true },
					isError: true,
				};
			}
			let degraded = false;
			if (result.error !== undefined) {
				// A host that does not implement the payload protocol (or answered
				// garbage) still has working select/input: ask the same questions
				// one by one instead of failing the call.
				degraded = true;
				result = await askFallback(ctx, questions);
				if (result.error === "no-ui") {
					return {
						content: [{ type: "text" as const, text: NO_UI_TEXT }],
						details: { questions, answers: [], cancelled: true },
						isError: true,
					};
				}
			}
			const cancelled = result.cancelled === true;
			const answers = cancelled ? [] : (result.answers ?? []);
			const details: AskDetails = { questions, answers, cancelled };
			if (degraded) details.degraded = true;
			return {
				content: [{ type: "text" as const, text: cancelled ? CANCELLED_TEXT : answerText(answers) }],
				details,
			};
		},
	});

	// Enable/disable reconciliation: a live setup() call publishes the new
	// `ask.enabled` to the runtime file, and this hook brings the active tool
	// set in line on the next turn (the old host API may lack the mutators, in
	// which case the registration above stays authoritative).
	pi.on("before_agent_start", () => {
		const enabled = readConfig().enabled;
		const api = pi as { getActiveTools?: () => string[]; setActiveTools?: (names: string[]) => void };
		const get = api.getActiveTools;
		const set = api.setActiveTools;
		if (typeof get !== "function" || typeof set !== "function") {
			return undefined;
		}
		try {
			const active = get.call(pi);
			if (!Array.isArray(active)) return undefined;
			const names = active.filter((name): name is string => typeof name === "string");
			const present = names.includes(TOOL_NAME);
			if (enabled && !present) {
				set.call(pi, [...names, TOOL_NAME]);
			} else if (!enabled && present) {
				set.call(pi, names.filter((name) => name !== TOOL_NAME));
			}
		} catch {
			// Host rejected the change: the tool keeps the state it has.
		}
		return undefined;
	});
}
