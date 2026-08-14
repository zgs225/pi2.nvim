/**
 * pi.nvim vision fallback.
 *
 * When the main model cannot see images, attached images are described by a
 * configured vision-capable model and the description replaces the images in
 * the user message. Loaded by pi.nvim via `--extension <plugin>/extensions/vision.ts`
 * when `require("pi").setup({ vision = { model = "provider/modelId" } })` is
 * configured; the model reference arrives via PI_NVIM_VISION_MODEL.
 *
 * Flow (input hook):
 *   1. Skip when there are no images or the main model supports them.
 *   2. Ask the main model (text-only, bounded context) for one short,
 *      task-focused instruction for the vision model.
 *   3. Send all images plus that instruction to the configured vision model.
 *   4. Transform the input: append the description as a `<pi-vision>` marker
 *      block, drop the images.
 *
 * Any failure fast-fails: the extension notifies `[pi-vision] <reason>` and
 * returns `{ action: "handled" }`, aborting the submission entirely (throwing
 * would not abort — pi's runner catches handler errors and continues with the
 * original input). pi.nvim restores the prompt on the prefixed notification.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { AssistantMessage, ImageContent, Model } from "@earendil-works/pi-ai";

const ENV_MODEL = "PI_NVIM_VISION_MODEL";
const NOTIFY_PREFIX = "[pi-vision]";
const CLOSE_TAG = "</pi-vision>";

/** Bounded context for the instruction call: recent messages, truncated. */
const MAX_CONTEXT_MESSAGES = 6;
const MAX_CHARS_PER_MESSAGE = 1500;
const INSTRUCTION_MAX_TOKENS = 300;
const DESCRIPTION_MAX_TOKENS = 2048;

function openTag(modelRef: string): string {
	return `<pi-vision model="${modelRef}">`;
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

export default function visionFallback(pi: ExtensionAPI): void {
	const modelRef = (process.env[ENV_MODEL] ?? "").trim();
	if (modelRef === "") {
		return;
	}

	const slash = modelRef.indexOf("/");
	const provider = slash > 0 ? modelRef.slice(0, slash) : "";
	const modelId = slash > 0 ? modelRef.slice(slash + 1) : "";

	pi.on("input", async (event, ctx) => {
		if (!event.images || event.images.length === 0) {
			return { action: "continue" };
		}
		if (ctx.model?.input?.includes("image")) {
			return { action: "continue" };
		}

		const fail = (reason: string) => {
			ctx.ui.notify(`${NOTIFY_PREFIX} ${reason}`, "error");
			return { action: "handled" } as const;
		};

		if (provider === "" || modelId === "") {
			return fail(`invalid vision.model "${modelRef}" (expected "provider/modelId")`);
		}
		const visionModel: Model<any> | undefined = ctx.modelRegistry.find(provider, modelId);
		if (!visionModel) {
			return fail(`configured vision model "${modelRef}" not found`);
		}
		if (!visionModel.input?.includes("image")) {
			return fail(`configured vision model "${modelRef}" does not support images`);
		}
		if (!ctx.model) {
			return fail("no current model available to generate the description instruction");
		}

		// 1) Main model: context-aware instruction for the vision model.
		let instruction: string;
		try {
			const prompt = buildInstructionPrompt(recentContext(ctx), event.text);
			const reply = await ctx.modelRegistry.complete(
				ctx.model,
				{ messages: [{ role: "user", content: prompt, timestamp: Date.now() }] },
				{ reasoning: "minimal", temperature: 0, maxTokens: INSTRUCTION_MAX_TOKENS },
			);
			instruction = assertCompleted(reply, "instruction generation failed");
		} catch (err) {
			return fail(errorMessage(err));
		}

		// 2) Vision model: describe all images in one batched call.
		let description: string;
		try {
			const content: Array<{ type: "text"; text: string } | ImageContent> = [
				{ type: "text", text: instruction },
				...event.images,
			];
			const reply = await ctx.modelRegistry.complete(
				visionModel,
				{ messages: [{ role: "user", content, timestamp: Date.now() }] },
				{ reasoning: "minimal", maxTokens: DESCRIPTION_MAX_TOKENS },
			);
			description = assertCompleted(reply, "vision model call failed");
		} catch (err) {
			return fail(errorMessage(err));
		}

		const separator = event.text.trim() !== "" ? "\n\n" : "";
		const text = `${event.text}${separator}${openTag(modelRef)}\n${description}\n${CLOSE_TAG}`;
		return { action: "transform", text, images: [] };
	});
}
