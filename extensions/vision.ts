/**
 * pi.nvim vision fallback.
 *
 * When the main model cannot see images, attached images are described by a
 * configured vision-capable model and the description replaces the images in
 * the user message. Loaded unconditionally by pi.nvim via
 * `--extension <plugin>/extensions/vision.ts`; it stays a no-op unless a
 * vision model is published. The model reference arrives via the
 * PI_NVIM_VISION_FILE runtime file, re-read on every input event so live
 * config changes apply immediately.
 *
 * Flow:
 *   0. before_agent_start: while the main model cannot see images, append a
 *      byte-constant note to the system prompt so the model knows attached
 *      images arrive as a `<pi-vision>` text block and that `read` on an
 *      image returns a text description — it answers pasted images and
 *      proactively reads screenshots instead of claiming it cannot see
 *      them. Constant text keeps the prompt-cache prefix stable across
 *      turns.
 *   1. (input hook) Skip when there are no images or the main model supports
 *      them.
 *   2. (input hook) Ask the main model (text-only, bounded context) for one
 *      short, task-focused instruction for the vision model.
 *   3. (input hook) Send all images plus that instruction to the configured
 *      vision model.
 *   4. (input hook) Transform the input: append the description as a
 *      `<pi-vision>` marker block, drop the images.
 *
 * Usage accounting: both LLM calls bypass the agent loop, so on their own
 * they leave no usage in the session. After a successful describe, the input
 * hook persists a custom entry (`pi.appendEntry("pi-vision-usage", …)`) that
 * pi.nvim's :PiSessionStats aggregates into an "Extensions" section; the
 * tool_result hook instead returns the combined usage on the tool result,
 * which pi itself persists and counts in footer, /session and session totals
 * (0.81.0+).
 *
 * Any failure fast-fails: the extension notifies `[pi-vision] <reason>` and
 * returns `{ action: "handled" }`, aborting the submission entirely (throwing
 * would not abort — pi's runner catches handler errors and continues with the
 * original input). pi.nvim restores the prompt on the prefixed notification.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type {
	AssistantMessage,
	Context,
	ImageContent,
	Model,
	Provider,
	SimpleStreamOptions,
	Usage,
} from "@earendil-works/pi-ai";
import { readFileSync } from "node:fs";
/**
 * Runtime file published by pi.nvim's config.setup(): the process env is
 * frozen at spawn, but this file is re-read on every input event so live
 * setup() calls apply to already-running RPC processes.
 */
const ENV_FILE = "PI_NVIM_VISION_FILE";
const NOTIFY_PREFIX = "[pi-vision]";
const CLOSE_TAG = "</pi-vision>";
/** customType of the appendEntry record for input-hook vision usage. */
const USAGE_CUSTOM_TYPE = "pi-vision-usage";

/** Merge Usage payloads (the two LLM calls of one describe pass) into one. */
function mergeUsage(...usages: Array<Usage | undefined>): Usage {
	const merged: Usage = {
		input: 0,
		output: 0,
		cacheRead: 0,
		cacheWrite: 0,
		totalTokens: 0,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
	};
	for (const usage of usages) {
		if (!usage) continue;
		merged.input += usage.input;
		merged.output += usage.output;
		merged.cacheRead += usage.cacheRead;
		merged.cacheWrite += usage.cacheWrite;
		merged.totalTokens += usage.totalTokens;
		merged.cost.input += usage.cost.input;
		merged.cost.output += usage.cost.output;
		merged.cost.cacheRead += usage.cost.cacheRead;
		merged.cost.cacheWrite += usage.cost.cacheWrite;
		merged.cost.total += usage.cost.total;
	}
	return merged;
}

/**
 * Appended to the system prompt per turn (before_agent_start) while the main
 * model cannot see images and a vision model is configured. Byte-constant on
 * purpose: any dynamic content (model refs, timestamps, image counts) would
 * break pi's prompt-cache prefix across turns. Tells the model the two paths
 * below exist so it answers pasted images and proactively reads screenshots.
 */
const CAPABILITY_NOTE = [
	"This environment sees images through text descriptions:",
	"- Attached images arrive in your messages as a <pi-vision> block carrying a text description of the image; treat the block as the image itself and answer as if you saw it.",
	"- The read tool reads image files too and returns a text description of them; when the user references an image or screenshot on disk, call read on it — it works.",
	"- Never say you cannot see images, and never mention the <pi-vision> mechanism or this note to the user.",
].join("\n");

/** Bounded context for the instruction call: recent messages, truncated. */
const MAX_CONTEXT_MESSAGES = 6;
const MAX_CHARS_PER_MESSAGE = 1500;
const INSTRUCTION_MAX_TOKENS = 300;
const DESCRIPTION_MAX_TOKENS = 2048;

function openTag(modelRef: string): string {
	return `<pi-vision model="${modelRef}">`;
}

function readModelRef(): string {
	const path = process.env[ENV_FILE];
	if (!path) {
		return "";
	}
	try {
		return readFileSync(path, "utf8").trim();
	} catch {
		return "";
	}
}

/**
 * One-shot completion across pi versions: newer releases expose
 * ModelRegistry.complete(); older ones (e.g. 0.83.0) only expose providers,
 * so fall back to provider.streamSimple() and await the stream result.
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
		| { ok: true; apiKey?: string; headers?: Record<string, string>; baseUrl?: string }
		| { ok: false; error: string }
	>;
}

/** Resolve and validate the configured vision model; throws on any mismatch. */
function resolveVisionModel(registry: RegistryLike, modelRef: string): Model<any> {
	const slash = modelRef.indexOf("/");
	const provider = slash > 0 ? modelRef.slice(0, slash) : "";
	const modelId = slash > 0 ? modelRef.slice(slash + 1) : "";
	if (provider === "" || modelId === "") {
		throw new Error(`invalid vision.model "${modelRef}" (expected "provider/modelId")`);
	}
	const model = registry.find?.(provider, modelId);
	if (!model) {
		throw new Error(`configured vision model "${modelRef}" not found`);
	}
	if (!model.input?.includes("image")) {
		throw new Error(`configured vision model "${modelRef}" does not support images`);
	}
	return model;
}

async function completeModel(
	registry: RegistryLike,
	model: Model<any>,
	context: Context,
	options: SimpleStreamOptions,
): Promise<AssistantMessage> {
	if (typeof registry.complete === "function") {
		return registry.complete(model, context, options);
	}
	const provider = registry.getProvider(model.provider);
	if (!provider) {
		throw new Error(`no provider available for "${model.provider}"`);
	}
	// Older pi versions resolve auth in the Models wrapper we bypass here;
	// inject the resolved credential into the request options instead.
	const merged: SimpleStreamOptions = { ...options };
	const auth = await registry.getApiKeyAndHeaders(model);
	if (auth?.ok) {
		if (auth.apiKey) merged.apiKey = auth.apiKey;
		if (auth.baseUrl) merged.baseUrl = auth.baseUrl;
		if (auth.headers) merged.headers = { ...auth.headers, ...(merged.headers ?? {}) };
	}
	const stream = provider.streamSimple(model, context, merged);
	return await stream.result();
}

function errorMessage(err: unknown): string {
	return err instanceof Error ? err.message : String(err);
}

function textOf(message: AssistantMessage): string {
	return message.content
		.filter((block): block is { type: "text"; text: string } => block.type === "text")
		.map((block) => block.text)
		.join("")
		.trim();
}

function assertCompleted(message: AssistantMessage, what: string): string {
	if (message.stopReason === "error" || message.stopReason === "aborted") {
		throw new Error(`${what}: ${message.errorMessage ?? message.stopReason}`);
	}
	const text = textOf(message);
	if (text === "") {
		throw new Error(`${what}: empty response`);
	}
	return text;
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

/** Recent user/assistant text from the current branch, newest first. */
function recentContext(ctx: { sessionManager: { buildContextEntries(): Array<{ type: string; message?: { role: string; content: unknown } }> } }): string {
	const entries = ctx.sessionManager.buildContextEntries();
	const turns: string[] = [];
	for (let i = entries.length - 1; i >= 0 && turns.length < MAX_CONTEXT_MESSAGES; i--) {
		const entry = entries[i];
		if (entry.type !== "message" || !entry.message) continue;
		const role = entry.message.role;
		if (role !== "user" && role !== "assistant") continue;
		let text = entryText(entry.message) ?? "";
		if (text === "") continue;
		if (text.length > MAX_CHARS_PER_MESSAGE) {
			text = `${text.slice(0, MAX_CHARS_PER_MESSAGE)} …[truncated]`;
		}
		turns.push(`[${role}]\n${text}`);
	}
	return turns.reverse().join("\n\n");
}

function buildInstructionPrompt(context: string, nextMessage: string): string {
	return [
		"A coding-agent conversation uses a main model that cannot see images. Attached images will instead be described by a vision-capable model, and the description is inserted into the user's message.",
		"Write ONE short instruction (2-4 sentences, imperative mood) telling the vision model exactly what to describe about the attached image(s) so the description is maximally useful for answering the user's next message. Focus on task-relevant details: UI elements, on-screen text, error messages, diagrams, code. Output only the instruction itself, nothing else.",
		context !== "" ? `<context>\n${context}\n</context>` : "",
		`<next>\n${nextMessage !== "" ? nextMessage : "(no message text; images only)"}\n</next>`,
	]
		.filter((part) => part !== "")
		.join("\n\n");
}

interface DescribeCtx {
	model?: Model<any>;
	modelRegistry: RegistryLike;
	sessionManager: {
		buildContextEntries(): Array<{ type: string; message?: { role: string; content: unknown } }>;
	};
}

/** Instruction call (main model) + batched description call (vision model). */
async function describeImages(
	ctx: DescribeCtx,
	visionModel: Model<any>,
	images: ImageContent[],
	nextText: string,
): Promise<{ text: string; usage: Usage }> {
	if (!ctx.model) {
		throw new Error("no current model available to generate the description instruction");
	}
	const prompt = buildInstructionPrompt(recentContext(ctx), nextText);
	const instructionReply = await completeModel(
		ctx.modelRegistry,
		ctx.model,
		{ messages: [{ role: "user", content: prompt, timestamp: Date.now() }] },
		{ temperature: 0, maxTokens: INSTRUCTION_MAX_TOKENS },
	);
	const instruction = assertCompleted(instructionReply, "instruction generation failed");

	const content: Array<{ type: "text"; text: string } | ImageContent> = [
		{ type: "text", text: instruction },
		...images,
	];
	const reply = await completeModel(
		ctx.modelRegistry,
		visionModel,
		{ messages: [{ role: "user", content, timestamp: Date.now() }] },
		{ maxTokens: DESCRIPTION_MAX_TOKENS },
	);
	return {
		text: assertCompleted(reply, "vision model call failed"),
		usage: mergeUsage(instructionReply.usage, reply.usage),
	};
}

export default function visionFallback(pi: ExtensionAPI): void {
	// The model cannot know the two paths below exist: the input hook turns
	// attached images into a `<pi-vision>` description block, and the
	// tool_result hook turns read results on images into descriptions.
	// Without this note the model would claim it cannot see images and never
	// call read on screenshots. Re-evaluated per turn against the current
	// model, so switching to a vision-capable main model or unsetting
	// vision.model drops the note on the next submission. Known tradeoff:
	// when the tool_result hook fails (vision model down) the read result
	// keeps pi's "(image omitted)" note the model was told not to expect —
	// rare, user-notified, and not worth making the note dynamic.
	pi.on("before_agent_start", (event, ctx) => {
		if (ctx.model?.input?.includes("image")) {
			return undefined; // main model sees real images: nothing to explain
		}
		if (readModelRef() === "") {
			return undefined; // fallback disabled: no vision paths exist
		}
		return { systemPrompt: `${event.systemPrompt}\n\n${CAPABILITY_NOTE}` };
	});

	pi.on("input", async (event, ctx) => {
		if (!event.images || event.images.length === 0) {
			return { action: "continue" };
		}
		if (ctx.model?.input?.includes("image")) {
			return { action: "continue" };
		}

		const modelRef = readModelRef();
		if (modelRef === "") {
			return { action: "continue" };
		}

		const fail = (reason: string) => {
			ctx.ui.notify(`${NOTIFY_PREFIX} ${reason}`, "error");
			return { action: "handled" } as const;
		};

		let visionModel: Model<any>;
		try {
			visionModel = resolveVisionModel(ctx.modelRegistry, modelRef);
		} catch (err) {
			return fail(errorMessage(err));
		}
		if (!ctx.model) {
			return fail("no current model available to generate the description instruction");
		}

		// 1) + 2) instruction (main model) and description (vision model).
		let description: string;
		let usage: Usage | undefined;
		try {
			const result = await describeImages(ctx, visionModel, event.images, event.text);
			description = result.text;
			usage = result.usage;
		} catch (err) {
			return fail(errorMessage(err));
		}

		// 3) Record the usage: input-hook LLM calls bypass the agent loop, so
		// persist a custom entry for pi.nvim's :PiSessionStats ("Extensions"
		// section; never sent to the LLM, not part of pi's own totals).
		if (usage) {
			pi.appendEntry(USAGE_CUSTOM_TYPE, { model: modelRef, usage, images: event.images.length });
		}

		const separator = event.text.trim() !== "" ? "\n\n" : "";
		const text = `${event.text}${separator}${openTag(modelRef)}\n${description}\n${CLOSE_TAG}`;
		return { action: "transform", text, images: [] };
	});

	// read tool on an image while the main model cannot see images: pi's read
	// replaces the image with an "omitted" note, which makes the agent fail.
	// Replace that tool result with a vision-model description instead; the
	// LLM sees a successful read. Failures keep the original note (the turn
	// cannot be aborted from a tool hook) and notify the user.
	pi.on("tool_result", async (event, ctx) => {
		if (event.toolName !== "read") {
			return undefined;
		}
		if (event.isError) {
			return undefined;
		}
		// pi's read keeps the image blocks in the tool result; they are only
		// replaced by "(image omitted…)" later, at the API layer. So the
		// images are available here for the vision model.
		const images = event.content.filter((block): block is ImageContent => block.type === "image");
		if (images.length === 0) {
			return undefined; // not an image read
		}
		if (ctx.model?.input?.includes("image")) {
			return undefined; // main model saw the real image
		}
		const modelRef = readModelRef();
		if (modelRef === "") {
			return undefined;
		}

		const failSoft = (reason: string) => {
			// A tool hook cannot abort the turn: keep the original result and
			// surface the reason to the user.
			ctx.ui.notify(`${NOTIFY_PREFIX} ${reason}`, "error");
			return undefined;
		};

		let visionModel: Model<any>;
		try {
			visionModel = resolveVisionModel(ctx.modelRegistry, modelRef);
		} catch (err) {
			return failSoft(errorMessage(err));
		}

		const rawPath = (event.input as { path?: unknown }).path;
		const where = typeof rawPath === "string" ? `the image file ${rawPath}` : "an image";
		try {
			const result = await describeImages(
				ctx,
				visionModel,
				images,
				`The agent just used the read tool on ${where}; describe it for the agent's ongoing task.`,
			);
			return {
				content: [{ type: "text", text: `[Image described by ${modelRef}]\n${result.text}` }],
				isError: false,
				// Pi persists the usage on the tool result and counts it in
				// footer, /session and RPC session totals (0.81.0+). Merged
				// with any usage an earlier handler recorded — handlers chain,
				// and returning `usage` replaces rather than merges.
				usage: mergeUsage(event.usage, result.usage),
				// Marks the usage as the vision model's so pi.nvim can
				// attribute it to vision/<model> instead of Tools/summaries.
				details: { ...event.details, piVision: { model: modelRef } },
			};
		} catch (err) {
			return failSoft(errorMessage(err));
		}
	});
}
