/**
 * Auto session title generation (backend for pi.nvim's `title` config).
 *
 * pi itself does not name sessions: `session_info.name` in the .jsonl is only
 * written when someone calls setSessionName. This extension gives unnamed
 * sessions a display name by asking the session's own model for a short
 * title after the first turn, then persisting it with pi.setSessionName().
 * pi.nvim already routes the resulting session_info_changed into its
 * :PiSessions / :PiResume lists, so the name appears there with no extra
 * plumbing.
 *
 * Trigger — pi.on("turn_end") with turnIndex === 0, i.e. right after the
 * first assistant reply (and its tool results) of a run. Skipped when the
 * session already has a name (pi.getSessionName() !== undefined), which
 * makes the feature "generate once, never overwrite a user-set name".
 *
 * Async — the extension runner awaits handlers, so awaiting a model call
 * inside turn_end would stall the agent loop between turns. The generation
 * is therefore fire-and-forget: the handler only schedules a microtask and
 * returns immediately. Progress is surfaced via ctx.ui.setStatus("pi-title")
 * — pi.nvim renders a spinner in the :PiSessions row while that key is
 * set, and the spinner goes away when the name arrives (or the status is
 * cleared on failure).
 *
 * Config — options travel via the PI_NVIM_TITLE_FILE runtime file (JSON:
 * {"enabled":bool,"maxChars":number,"lang":string|null}) published by
 * pi.nvim's config.setup(); the process env is frozen at spawn but the file
 * is re-read on every turn_end, so live setup() calls apply immediately.
 * Outside pi.nvim the file is absent: the extension falls back to defaults.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type {
	AssistantMessage,
	Context,
	Model,
	Provider,
	SimpleStreamOptions,
} from "@earendil-works/pi-ai";
import { readFileSync } from "node:fs";

const ENV_FILE = "PI_NVIM_TITLE_FILE";
const STATUS_KEY = "pi-title";
const STATUS_GENERATING = "generating";

/** Defaults when the runtime file is absent (e.g. pi run outside pi.nvim). */
const DEFAULT_MAX_CHARS = 40;
/**
 * Floor for the title completion's maxTokens. Display length is still
 * enforced by clampTitle(maxChars); this budget has to cover models that
 * keep emitting reasoning even after the adapter sends thinking:disabled
 * (CommandCode DeepSeek V4 Flash was measured to fill 40 tokens with
 * reasoning and return no text content).
 */
const TITLE_MIN_TOKENS = 1024;

interface TitleConfig {
	enabled: boolean;
	maxChars: number;
	lang: string | null;
	model: string | null;
}

function readConfig(): TitleConfig {
	const path = process.env[ENV_FILE];
	const cfg: TitleConfig = { enabled: true, maxChars: DEFAULT_MAX_CHARS, lang: null, model: null };
	if (!path) {
		return cfg;
	}
	try {
		const parsed = JSON.parse(readFileSync(path, "utf8")) as {
			enabled?: unknown;
			maxChars?: unknown;
			lang?: unknown;
			model?: unknown;
		};
		if (typeof parsed.enabled === "boolean") cfg.enabled = parsed.enabled;
		if (typeof parsed.maxChars === "number" && parsed.maxChars > 0) cfg.maxChars = parsed.maxChars;
		if (typeof parsed.lang === "string" && parsed.lang !== "") cfg.lang = parsed.lang;
		if (typeof parsed.model === "string" && parsed.model !== "") cfg.model = parsed.model;
	} catch {
		// Unreadable/corrupt file: fall back to defaults.
	}
	return cfg;
}

/**
 * One-shot completion that honors SimpleStreamOptions (including reasoning).
 *
 * ModelRegistry.complete() in pi 0.84 is typed as SimpleStreamOptions but
 * calls runtime.complete() → provider.stream(), which only understands
 * reasoningEffort. `reasoning: "off"` is dropped. Prefer
 * provider.streamSimple() so the simple-options adapter maps it; inject
 * auth because that path skips ModelRuntime.prepareRequest(). Fall back to
 * registry.complete() only when streamSimple is unavailable.
 */
interface RegistryLike {
	complete?: (
		model: Model<any>,
		context: Context,
		options?: SimpleStreamOptions,
	) => Promise<AssistantMessage>;
	getProvider: (id: string) => Provider | undefined;
	find?: (provider: string, modelId: string) => Model<any> | undefined;
	getApiKeyAndHeaders: (model: Model<any>) => Promise<
		| {
				ok: true;
				apiKey?: string;
				headers?: Record<string, string>;
				baseUrl?: string;
				env?: Record<string, string>;
		  }
		| { ok: false; error: string }
	>;
}

async function completeModel(
	registry: RegistryLike,
	model: Model<any>,
	context: Context,
	options: SimpleStreamOptions,
): Promise<AssistantMessage> {
	const provider =
		typeof registry.getProvider === "function" ? registry.getProvider(model.provider) : undefined;
	if (provider && typeof provider.streamSimple === "function") {
		const merged: SimpleStreamOptions = { ...options };
		let requestModel = model;
		if (typeof registry.getApiKeyAndHeaders === "function") {
			const auth = await registry.getApiKeyAndHeaders(model);
			if (auth && auth.ok === false) {
				throw new Error(auth.error);
			}
			if (auth?.ok) {
				if (auth.apiKey) merged.apiKey = auth.apiKey;
				if (auth.headers) merged.headers = { ...auth.headers, ...(merged.headers ?? {}) };
				if (auth.env) merged.env = { ...auth.env, ...(merged.env ?? {}) };
				// stream() reads model.baseUrl, not options.baseUrl.
				if (auth.baseUrl) requestModel = { ...model, baseUrl: auth.baseUrl };
			}
		}
		return await provider.streamSimple(requestModel, context, merged).result();
	}
	if (typeof registry.complete === "function") {
		return registry.complete(model, context, options);
	}
	throw new Error(`no provider available for "${model.provider}"`);
}

/** Text content of a session message entry, images/tool calls dropped. */
function entryText(message: { role: string; content: unknown }): string | undefined {
	if (typeof message.content === "string") return message.content;
	if (!Array.isArray(message.content)) return undefined;
	const parts: string[] = [];
	for (const block of message.content) {
		if (block && typeof block === "object" && block.type === "text" && typeof block.text === "string") {
			parts.push(block.text);
		}
	}
	return parts.join("");
}

/** First user message + this turn's assistant text, truncated, as title basis. */
const MAX_BASIS_CHARS = 2000;

function titleBasis(
	sessionManager: { buildContextEntries(): Array<{ type: string; message?: { role: string; content: unknown } }> },
	assistantText: string,
): string {
	const entries = sessionManager.buildContextEntries();
	let userText = "";
	for (const entry of entries) {
		if (entry.type !== "message" || !entry.message) continue;
		if (entry.message.role !== "user") continue;
		userText = entryText(entry.message) ?? "";
		if (userText !== "") break;
	}
	const clip = (s: string) => {
		const t = s.trim();
		return t.length > MAX_BASIS_CHARS ? `${t.slice(0, MAX_BASIS_CHARS)} …[truncated]` : t;
	};
	const parts = [
		userText !== "" ? `<user>\n${clip(userText)}\n</user>` : "",
		assistantText !== "" ? `<assistant>\n${clip(assistantText)}\n</assistant>` : "",
	];
	return parts.filter((p) => p !== "").join("\n\n");
}

function buildPrompt(cfg: TitleConfig, basis: string, assistantText: string): string {
	const langLine =
		cfg.lang !== null
			? `The conversation should be titled in the language code "${cfg.lang}".`
			: "Determine the language of the user's message and title the conversation in that same language. (If the user's message is not in a natural language — e.g. just a path or a URL — use English.)";
	return [
		"You name coding-agent conversation sessions after their task.",
		langLine,
		`Output ONLY the title itself: at most ${cfg.maxChars} characters (count characters, not bytes), no quotes, no surrounding explanation, no trailing period.`,
		"Summarize the task concisely (e.g. 'fix login redirect', 'add PiSessions spinner animation').",
		basis !== "" ? basis : `<assistant>\n${clipForPrompt(assistantText)}\n</assistant>`,
	]
		.filter((part) => part !== "")
		.join("\n\n");
}

function clipForPrompt(text: string): string {
	const t = text.trim();
	return t.length > MAX_BASIS_CHARS ? `${t.slice(0, MAX_BASIS_CHARS)} …[truncated]` : t;
}

/** Hard clamp: truncate by code points (not bytes), append an ellipsis. */
function clampTitle(title: string, maxChars: number): string {
	const trimmed = title.trim().replace(/^["'“”`]+|["'“”`]+$/g, "").replace(/[.。]+$/, "");
	if (Array.from(trimmed).length <= maxChars) {
		return trimmed;
	}
	return Array.from(trimmed).slice(0, maxChars).join("") + "…";
}

function textOf(message: AssistantMessage): string {
	return message.content
		.filter((block): block is { type: "text"; text: string } => block.type === "text")
		.map((block) => block.text)
		.join("")
		.trim();
}

async function generateTitle(pi: ExtensionAPI, ctx: {
	model?: Model<any>;
	modelRegistry: RegistryLike;
	sessionManager: { buildContextEntries(): Array<{ type: string; message?: { role: string; content: unknown } }> };
	ui: { setStatus(key: string, text: string | undefined): void };
}, assistantText: string): Promise<string | undefined> {
	const cfg = readConfig();
	if (!cfg.enabled) {
		return undefined;
	}
	// A pinned model (title.model = "provider/modelId") makes title
	// generation independent of the conversation's model — e.g. a cheap or
	// fast one. Unresolvable pins fall back to the session's own model.
	let model = ctx.model;
	if (cfg.model !== null && typeof ctx.modelRegistry?.find === "function") {
		const slash = cfg.model.indexOf("/");
		const provider = slash > 0 ? cfg.model.slice(0, slash) : "";
		const modelId = slash > 0 ? cfg.model.slice(slash + 1) : "";
		model = ctx.modelRegistry.find(provider, modelId) ?? model;
	}
	if (!model) {
		return undefined;
	}
	const prompt = buildPrompt(cfg, titleBasis(ctx.sessionManager, assistantText), assistantText);
	const reply = await completeModel(
		ctx.modelRegistry,
		model,
		{ messages: [{ role: "user", content: prompt, timestamp: Date.now() }] },
		{
			temperature: 0,
			maxTokens: Math.max(TITLE_MIN_TOKENS, Math.ceil(cfg.maxChars * 2)),
			// SimpleStreamOptions.reasoning is typed without "off"; streamSimple
			// still accepts it and maps it to reasoningEffort: undefined.
			reasoning: "off",
		} as SimpleStreamOptions,
	);
	if (reply.stopReason === "error" || reply.stopReason === "aborted") {
		throw new Error(`title generation failed: ${reply.errorMessage ?? reply.stopReason}`);
	}
	const title = clampTitle(textOf(reply), cfg.maxChars);
	if (title === "") {
		throw new Error("title generation returned no text");
	}
	return title;
}

export default function autoTitle(pi: ExtensionAPI): void {
	pi.on("turn_end", (event, ctx) => {
		if (event.turnIndex !== 0) {
			return;
		}
		// Already named (user-set or previously generated): never overwrite.
		if (typeof pi.getSessionName !== "function" || (pi.getSessionName() ?? "").trim() !== "") {
			return;
		}
		if (typeof ctx.ui?.setStatus !== "function") {
			return;
		}
		const assistantText = event.message ? entryText(event.message as { role: string; content: unknown }) ?? "" : "";
		// Fire-and-forget: the runner awaits handlers, so awaiting a model
		// call here would stall the agent loop between turns.
		queueMicrotask(() => {
			void (async () => {
				let title: string | undefined;
				let started = false;
				try {
					ctx.ui.setStatus(STATUS_KEY, STATUS_GENERATING);
					started = true;
					title = await generateTitle(pi, ctx, assistantText);
				} catch {
					title = undefined;
				}
				if (title) {
					try {
						pi.setSessionName(title);
					} catch {
						// Name not persisted; stay unnamed (first-message fallback).
					}
				}
				// Clear only after the name is persisted (or generation failed):
				// the spinner stays while the new name is on its way.
				if (started) {
					ctx.ui.setStatus(STATUS_KEY, undefined);
				}
			})();
		});
	});
}