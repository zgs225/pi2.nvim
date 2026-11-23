/**
 * Compaction control for pi.nvim (Gitea #127).
 *
 * One bundled extension, four layers. This file implements L1 and L2 and
 * carries the skeleton for the rest, so a follow-up task extends ONE file
 * instead of inventing a second:
 *
 *  - L1 `cleaner` (default on, this file): bound the file lists pi appends to a
 *    summary, and keep the summarisation INPUT clean.
 *  - L2 `checkpoint` (opt-in, this file): return our own structured, deduped
 *    checkpoint from `session_before_compact`, with evidence tags, protected
 *    literals and the same file lists L1 bounds.
 *  - L3 `state`: inject a compact session state note before each request
 *    (follow-up task).
 *  - L4 `prune`: opt-in tool-result pruning (follow-up task).
 *
 * ## Why L1 exists
 *
 * pi's default compaction accumulates file operations across every default
 * compaction (`extractFileOperations` seeds `fileOps` from the previous
 * Pi-generated compaction's `details`) and appends the full lists to the
 * summary as `<read-files>` / `<modified-files>`. Two costs follow: the summary
 * carries every scratch path a long session ever touched (`/tmp/...`,
 * `node_modules/...`, lockfiles), and the NEXT compaction re-reads those lists
 * as input (the previous summary is embedded in the update prompt), so the
 * list grows the prompt it is supposed to shrink.
 *
 * The fix is deliberately small and uses the hook contract, not a replacement
 * summariser: `session_before_compact` hands the extension the exact
 * `preparation` object the core is about to consume, and `compact()` reads
 * `preparation.fileOps` AFTER the hook returns (`compact()` destructures
 * `firstKeptEntryId`, …, `previousSummary`, `fileOps` at call time and calls
 * `computeFileLists(fileOps)` only after the LLM call). Mutating the Sets in
 * place — never replacing `preparation` or `event.preparation.fileOps` — is
 * therefore enough for pi to build the summary from the cleaned lists, with
 * every native behaviour (native `details`, `fromHook: false`, the LLM prompt)
 * untouched. `scripts/e2e/compaction.lua` is the experiment that proves this
 * against a real pi binary; if that ever fails, the mechanism is gone, not the
 * test.
 *
 * L1 never cancels, never returns a `compaction` object and never throws: on
 * any error it warns once and leaves pi's default compaction completely alone.
 *
 * L2 is opt-in (`checkpoint.enabled`) and FAIL OPEN: whenever the pinned model
 * cannot be resolved, the prompt response is empty/invalid, or the resulting
 * summary would be at least as large as the context it replaces, it returns
 * `undefined` so pi's native summariser runs unchanged. Returning a custom
 * compaction also discards pi's default `details` (file lists are not carried
 * across `fromHook` entries), so L2 re-appends a bounded `<read-files>` /
 * `<modified-files>` block built from the L1-cleaned `preparation.fileOps`.
 *
 * ## Config
 *
 * `PI_NVIM_COMPACTION_FILE` points at a JSON file pi.nvim republishes on every
 * `setup()` (shape: `lua/pi/compaction/extension.lua`). The process env is
 * frozen at spawn, the file is re-read on every compaction event, so a live
 * `setup()` applies without respawning pi (same pattern as extensions/todo.ts).
 * Outside pi.nvim the file is absent and the defaults below apply. This file
 * reads the `enabled`, `cleaner` and `checkpoint` sections; L3/L4 read their own
 * keys when they land.
 */

import type {
	ExtensionAPI,
	ExtensionContext,
	SessionBeforeCompactEvent,
	SessionCompactEvent,
	SessionCompactFailedEvent,
} from "@earendil-works/pi-coding-agent";
import { convertToLlm, serializeConversation } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";

const ENV_FILE = "PI_NVIM_COMPACTION_FILE";
/** Custom entry that records what the cleaner did for one compaction. */
const ENTRY_TYPE = "pi2-compaction-cleaner";
const DEFAULT_MAX_READ = 50;
const DEFAULT_MAX_MODIFIED = 100;
const DEFAULT_MAX_WORDS = 1500;
/** Output limit used when the summarisation model does not report `maxTokens`. */
const DEFAULT_CHECKPOINT_MAX_TOKENS = 8192;
/** Never ask for less than this, even when the window is nearly full. */
const MIN_CHECKPOINT_MAX_TOKENS = 1024;
/** Room reserved for the next request when shrinking `maxTokens`. */
const CHECKPOINT_CONTEXT_MARGIN = 4096;
/** One warning per process per 10 minutes: a broken pin must not spam every compaction. */
const CHECKPOINT_WARN_INTERVAL_MS = 10 * 60 * 1000;
/** Upper bound on protected literals (and therefore on `## Retained Identifiers` bullets). */
const PROTECTED_LITERAL_LIMIT = 30;
/** How many of the newest user messages literals are harvested from. */
const PROTECTED_LITERAL_USER_MESSAGES = 5;

/**
 * Path SEGMENTS that mark a dependency/build/cache tree. Matched between
 * separators, never as a bare substring, so `src/build_info.ts` survives while
 * `packages/x/dist/index.js` does not.
 */
const BUILD_SEGMENTS = [
	"node_modules",
	"dist",
	"build",
	"target",
	".venv",
	"__pycache__",
	".cache",
	"coverage",
	"vendor",
	".git",
];

/** Lockfiles and manifests: no information value in a summary's file list. */
const LOCKFILE_NAMES = [
	"package-lock.json",
	"pnpm-lock.yaml",
	"yarn.lock",
	"bun.lockb",
	"Cargo.lock",
	"poetry.lock",
	"uv.lock",
	"go.sum",
	"composer.lock",
];

/**
 * Rooted scratch locations. `tmpdir()` is added at match time (it is the only
 * one that is not a fixed string), and `%temp%` covers a Windows-style path
 * after separator normalization.
 */
const TEMP_PREFIXES = ["/tmp/", "/var/folders/", "/dev/shm/", "%temp%/"];

/** pi's own artifacts: subagent transcripts, the subsession manifest, sessions. */
const PI_ARTIFACT_SEGMENTS = ["subagent-artifacts"];
const PI_ARTIFACT_NAMES = [".pi2-subsessions.json"];
/** pi.nvim's own editor run files (`stdpath("run")/pi2nvim-*`). */
const EDITOR_RUN_MARKER = "pi2nvim-";

const FILE_LIST_BLOCK = /<read-files>[\s\S]*?<\/read-files>|<modified-files>[\s\S]*?<\/modified-files>/g;

/** The L1 cleaner options, as published by pi.nvim. */
interface CleanerSettings {
	enabled: boolean;
	max_read: number;
	max_modified: number;
	drop_temp: boolean;
	drop_build: boolean;
	strip_previous_lists: boolean;
}

/** The languages the checkpoint summariser understands. */
type CheckpointLanguage = "auto" | "english" | "conversation";

/** The L2 checkpoint options, as published by pi.nvim. */
interface CheckpointSettings {
	enabled: boolean;
	model: string | null;
	thinking_level: string | null;
	language: CheckpointLanguage;
	max_words: number;
}

/** The part of the published runtime config these layers read. */
interface CompactionRuntimeConfig {
	enabled: boolean;
	cleaner: CleanerSettings;
	checkpoint: CheckpointSettings;
}

/** Fresh defaults per call: a caller may mutate what `readConfig` returns. */
function defaultConfig(): CompactionRuntimeConfig {
	return {
		enabled: true,
		cleaner: {
			enabled: true,
			max_read: DEFAULT_MAX_READ,
			max_modified: DEFAULT_MAX_MODIFIED,
			drop_temp: true,
			drop_build: true,
			strip_previous_lists: true,
		},
		checkpoint: {
			enabled: false,
			model: null,
			thinking_level: null,
			language: "auto",
			max_words: DEFAULT_MAX_WORDS,
		},
	};
}

/**
 * Positive integer with a fallback. pi.nvim clamps before writing, so this is
 * only the "someone edited the file by hand" guard; a rejected value keeps the
 * default instead of producing a summariser that asks for zero files.
 */
function positiveInteger(value: unknown, fallback: number): number {
	if (typeof value !== "number" || !Number.isFinite(value)) {
		return fallback;
	}
	const floored = Math.floor(value);
	return floored >= 1 ? floored : fallback;
}

function booleanOr(value: unknown, fallback: boolean): boolean {
	return typeof value === "boolean" ? value : fallback;
}

/** Non-empty string or null (`null` = "no pin"). */
function optionalString(value: unknown): string | null {
	return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

/**
 * Clamp a hand-edited integer into `[min, max]`. pi.nvim publishes already
 * normalized values, so this only guards a config file edited on disk.
 */
function clampInteger(value: unknown, fallback: number, min: number, max: number): number {
	if (typeof value !== "number" || !Number.isFinite(value)) {
		return fallback;
	}
	const floored = Math.floor(value);
	if (floored < min) {
		return min;
	}
	if (floored > max) {
		return max;
	}
	return floored;
}

function checkpointLanguage(value: unknown, fallback: CheckpointLanguage): CheckpointLanguage {
	if (value === "auto" || value === "english" || value === "conversation") {
		return value;
	}
	return fallback;
}

/**
 * Re-read the runtime config file. A missing, unreadable or unparsable file is
 * NOT an error (pi.nvim may not be running, or the file may be caught
 * mid-rewrite): every key falls back to its default independently.
 */
function readConfig(): CompactionRuntimeConfig {
	const config = defaultConfig();
	const path = process.env[ENV_FILE];
	if (!path) {
		return config;
	}
	let parsed: Record<string, unknown>;
	try {
		parsed = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
	} catch {
		return config;
	}
	if (parsed === null || typeof parsed !== "object") {
		return config;
	}
	config.enabled = booleanOr(parsed.enabled, config.enabled);
	const rawCleaner = parsed.cleaner;
	if (rawCleaner !== null && typeof rawCleaner === "object") {
		const cleaner = rawCleaner as Record<string, unknown>;
		const target = config.cleaner;
		target.enabled = booleanOr(cleaner.enabled, target.enabled);
		target.max_read = positiveInteger(cleaner.max_read, target.max_read);
		target.max_modified = positiveInteger(cleaner.max_modified, target.max_modified);
		target.drop_temp = booleanOr(cleaner.drop_temp, target.drop_temp);
		target.drop_build = booleanOr(cleaner.drop_build, target.drop_build);
		target.strip_previous_lists = booleanOr(cleaner.strip_previous_lists, target.strip_previous_lists);
	}
	const rawCheckpoint = parsed.checkpoint;
	if (rawCheckpoint !== null && typeof rawCheckpoint === "object") {
		const checkpoint = rawCheckpoint as Record<string, unknown>;
		const target = config.checkpoint;
		target.enabled = booleanOr(checkpoint.enabled, target.enabled);
		target.model = optionalString(checkpoint.model);
		target.thinking_level = optionalString(checkpoint.thinking_level);
		target.language = checkpointLanguage(checkpoint.language, target.language);
		target.max_words = clampInteger(checkpoint.max_words, target.max_words, 200, 6000);
	}
	return config;
}

/**
 * One pending compaction report. Module-level because `session_compact` carries
 * no reference back to the `session_before_compact` invocation; one pi process
 * runs one compaction at a time (`agent-session` aborts the previous one), so a
 * single slot is correct. `session_compact_failed` clears it.
 *
 * One slot also means "no second custom entry": the `pi2-compaction-cleaner`
 * record reports what BOTH layers did for this compaction.
 */
interface CleanerReport {
	reason: string;
	readKept: number;
	readOmitted: number;
	modifiedKept: number;
	modifiedOmitted: number;
	strippedPrevious: boolean;
}

/** The cleaner report plus the L2 outcome, as recorded in the custom entry. */
interface PendingReport extends CleanerReport {
	engine: "cleaner" | "checkpoint";
	checkpoint: boolean;
	model?: string;
	thinkingLevel?: string;
	durationMs?: number;
	language?: CheckpointLanguage;
	summaryChars?: number;
}

let pendingReport: PendingReport | undefined;

/** Normalized comparison form: lowercase, `/` separators, no trailing slash. */
function normalizePath(path: string): string {
	const slashed = path.replace(/\\/g, "/").toLowerCase();
	return slashed.length > 1 ? slashed.replace(/\/+$/, "") : slashed;
}

/** Segment test: `/<name>/` inside the wrapped path, so `dist-info` never matches `dist`. */
function hasSegment(normalized: string, name: string): boolean {
	return `/${normalized}/`.includes(`/${name}/`);
}

function basename(normalized: string): string {
	const cut = normalized.lastIndexOf("/");
	return cut >= 0 ? normalized.slice(cut + 1) : normalized;
}

/**
 * Where pi keeps sessions and its own artifacts: `$PI_CODING_AGENT_DIR` or the
 * built-in `~/.pi/agent`. Both are considered, because a session file from
 * before the env var changed is still an artifact of ours.
 */
function agentDirs(): string[] {
	const dirs = new Set<string>();
	const fromEnv = process.env.PI_CODING_AGENT_DIR;
	if (fromEnv) {
		dirs.add(normalizePath(fromEnv));
	}
	dirs.add(normalizePath(`${homedir()}/.pi/agent`));
	return [...dirs];
}

/**
 * Is this a path with no value in a summary's file list? True means "drop".
 *
 * Everything here is deliberately literal: a scratch path, a build output, a
 * lockfile, or one of pi's own artifacts. Anything else — source files, tests,
 * docs, configs a human wrote — is kept.
 */
function isNoisePath(path: string, cleaner: CleanerSettings, agentDirList: string[]): boolean {
	const normalized = normalizePath(path);
	if (normalized === "") {
		return true;
	}
	if (cleaner.drop_temp) {
		const roots = [...TEMP_PREFIXES];
		const ownTmp = normalizePath(tmpdir());
		roots.push(`${ownTmp}/`);
		const wrapped = `${normalized}/`;
		for (const root of roots) {
			if (wrapped.startsWith(root)) {
				return true;
			}
		}
		if (PI_ARTIFACT_SEGMENTS.some((segment) => hasSegment(normalized, segment))) {
			return true;
		}
		const name = basename(normalized);
		if (PI_ARTIFACT_NAMES.includes(name) || name.includes(EDITOR_RUN_MARKER)) {
			return true;
		}
		for (const dir of agentDirList) {
			if (normalized.startsWith(`${dir}/`) && normalized.endsWith(".jsonl")) {
				return true;
			}
		}
	}
	if (cleaner.drop_build) {
		if (BUILD_SEGMENTS.some((segment) => hasSegment(normalized, segment))) {
			return true;
		}
		if (LOCKFILE_NAMES.includes(basename(normalized))) {
			return true;
		}
	}
	return false;
}

/**
 * Rebuild `set` in place with only the MOST RECENT `max` entries. Sets preserve
 * insertion order, which is chronological for `fileOps`: the newest tool call
 * is last. Clearing and re-adding keeps the identity of the Set the core holds.
 */
function capRecent(set: Set<string>, max: number): void {
	const all = [...set];
	if (all.length <= max) {
		return;
	}
	const kept = all.slice(all.length - max);
	set.clear();
	for (const path of kept) {
		set.add(path);
	}
}

/**
 * `written` and `edited` count as ONE modified list, so the cap is applied to
 * their union while both Sets keep their own membership: a path that was
 * written then edited stays in both, and the rebuild order stays deterministic
 * (written entries in their original order, then edited-only ones).
 */
function capModified(written: Set<string>, edited: Set<string>, max: number): void {
	const order: string[] = [];
	const seen = new Set<string>();
	for (const path of written) {
		if (!seen.has(path)) {
			seen.add(path);
			order.push(path);
		}
	}
	for (const path of edited) {
		if (!seen.has(path)) {
			seen.add(path);
			order.push(path);
		}
	}
	if (order.length <= max) {
		return;
	}
	const kept = new Set(order.slice(order.length - max));
	const nextWritten = [...written].filter((path) => kept.has(path));
	const nextEdited = [...edited].filter((path) => kept.has(path));
	written.clear();
	for (const path of nextWritten) {
		written.add(path);
	}
	edited.clear();
	for (const path of nextEdited) {
		edited.add(path);
	}
}

/** Drop noise from a Set in place (iteration order is preserved). */
function dropNoise(set: Set<string>, cleaner: CleanerSettings, agentDirList: string[]): void {
	for (const path of [...set]) {
		if (isNoisePath(path, cleaner, agentDirList)) {
			set.delete(path);
		}
	}
}

/**
 * Remove the `<read-files>` / `<modified-files>` blocks pi appends to a summary.
 * The previous summary is passed back into the NEXT summarisation request inside
 * `<previous-summary>`, so a stale list is re-sent as prompt input; stripping it
 * keeps that prompt (and the model's attention) on the work, not on paths.
 *
 * A summary that consists of nothing but lists is left alone: an empty
 * `previous-summary` would say less than the list it replaced.
 */
function stripFileLists(summary: string): { text: string; stripped: boolean } {
	const stripped = summary.replace(FILE_LIST_BLOCK, "");
	if (stripped === summary) {
		return { text: summary, stripped: false };
	}
	const text = stripped.replace(/[ \t]+$/gm, "").replace(/\n{3,}/g, "\n\n").trimEnd();
	if (text.trim() === "") {
		return { text: summary, stripped: false };
	}
	return { text, stripped: true };
}

/**
 * L1: bound `preparation.fileOps` in place and clean `preparation.previousSummary`.
 *
 * `fileOps` is `{read, written, edited}` as Sets of the file paths pi extracted
 * from the messages being summarized (plus, cumulatively, the previous
 * Pi-generated compaction's lists). pi has not consumed it yet: `compact()`
 * destructures it and calls `computeFileLists` after the LLM call, so what this
 * leaves behind is exactly what the summary and `details` will contain.
 */
function cleanPreparation(
	preparation: SessionBeforeCompactEvent["preparation"],
	cleaner: CleanerSettings,
	reason: string,
): CleanerReport {
	const fileOps = preparation.fileOps;
	const dirs = agentDirs();
	const readTotal = fileOps.read.size;
	const modifiedTotal = fileOps.written.size + fileOps.edited.size;

	dropNoise(fileOps.read, cleaner, dirs);
	dropNoise(fileOps.written, cleaner, dirs);
	dropNoise(fileOps.edited, cleaner, dirs);
	capRecent(fileOps.read, cleaner.max_read);
	capModified(fileOps.written, fileOps.edited, cleaner.max_modified);

	const readKept = fileOps.read.size;
	const modifiedKept = fileOps.written.size + fileOps.edited.size;

	let strippedPrevious = false;
	if (cleaner.strip_previous_lists && typeof preparation.previousSummary === "string") {
		const result = stripFileLists(preparation.previousSummary);
		if (result.stripped) {
			preparation.previousSummary = result.text;
			strippedPrevious = true;
		}
	}

	return {
		reason,
		readKept,
		readOmitted: Math.max(0, readTotal - readKept),
		modifiedKept,
		modifiedOmitted: Math.max(0, modifiedTotal - modifiedKept),
		strippedPrevious,
	};
}

function warnOnce(ctx: ExtensionContext, detail: string): void {
	try {
		ctx.ui.notify(`pi2-compaction: cleaner failed — using pi's default compaction (${detail})`, "warning");
	} catch {
		// A notify that cannot be delivered must not turn a warning into a failure.
	}
}

// ---------------------------------------------------------------------------
// L2: structured checkpoint summary (opt-in through `checkpoint.enabled`)
// ---------------------------------------------------------------------------

/** The section headings the checkpoint must contain, in this order. */
const CHECKPOINT_SECTIONS = [
	"## Goal",
	"## Constraints & Preferences",
	"## Progress",
	"### Done",
	"### In Progress",
	"### Blocked",
	"## Key Decisions",
	"## Artifact Trail",
	"## Next Steps",
	"## Critical Context",
	"## Open Questions",
	"## Rejected Approaches",
];

/** Names this layer in the prompt, so the e2e can assert the request is ours. */
const CHECKPOINT_SYSTEM_PROMPT = [
	"You are pi2-compaction, a context checkpoint summariser for a coding agent.",
	"Read the conversation and produce ONE markdown checkpoint that another LLM can use to continue the work.",
	"Output markdown only: no preamble, no explanation, no tool calls, no fence around the whole answer.",
].join("\n");

/** Thinking levels pi accepts (`clampThinkingLevel` in pi-ai). */
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

/** One literal the summary must reproduce verbatim. */
interface ProtectedLiteral {
	text: string;
	/** `user` = seen in a user message, `previous` = only in the previous summary. */
	source: "user" | "previous";
}

/** The subset of pi-ai's `AssistantMessage` this layer reads. */
interface SummarizationResponse {
	content?: Array<{ type?: unknown; text?: unknown }>;
	usage?: unknown;
	stopReason?: string;
}

/** What a successful checkpoint produced (already sanitized and validated). */
interface CheckpointOutcome {
	summary: string;
	usage: unknown;
	model: string;
	thinkingLevel: string | undefined;
	language: CheckpointLanguage;
	durationMs: number;
	summaryChars: number;
}

/** The active model, with the same shape `ctx.model` exposes. */
type ContextModel = NonNullable<ExtensionContext["model"]>;

/** One warning per process per 10 minutes: a broken pin must not spam. */
let checkpointWarnedAt = 0;

function warnCheckpointOnce(ctx: ExtensionContext): void {
	const now = Date.now();
	if (now - checkpointWarnedAt < CHECKPOINT_WARN_INTERVAL_MS) {
		return;
	}
	checkpointWarnedAt = now;
	try {
		ctx.ui.notify(
			"pi2-compaction: checkpoint summary failed — using pi's native compaction",
			"warning",
		);
	} catch {
		// A notify that cannot be delivered must not turn a warning into a failure.
	}
}

/**
 * Valid thinking level for the model call. An unparsable value falls back to
 * the session level instead of asking the provider for a level it cannot use.
 */
function resolveThinkingLevel(requested: unknown, fallback: string | undefined): string | undefined {
	if (typeof requested === "string" && requested !== "") {
		return THINKING_LEVELS.includes(requested) ? requested : fallback;
	}
	return fallback;
}

/**
 * `checkpoint.model` is `provider/modelId`. An unresolvable pin NEVER fails the
 * compaction: the session model is used, silently (the pin is a preference).
 */
function resolveCheckpointModel(
	ctx: ExtensionContext,
	pin: string | null,
): { model: ContextModel; pinned: boolean } | undefined {
	const fallback = ctx.model;
	if (pin !== null) {
		const cut = pin.indexOf("/");
		if (cut > 0 && cut < pin.length - 1) {
			const provider = pin.slice(0, cut);
			const id = pin.slice(cut + 1);
			try {
				const found = ctx.modelRegistry.find(provider, id);
				if (found) {
					return { model: found, pinned: true };
				}
			} catch {
				// Fall through to the session model.
			}
		}
	}
	return fallback ? { model: fallback, pinned: false } : undefined;
}

/**
 * Output limit for the summarisation call: the model's own limit if known,
 * else 8192, reduced when `tokensBefore` already fills most of the window.
 */
function resolveCheckpointMaxTokens(model: ContextModel, tokensBefore: number): number {
	const base =
		typeof model.maxTokens === "number" && Number.isFinite(model.maxTokens) && model.maxTokens > 0
			? Math.floor(model.maxTokens)
			: DEFAULT_CHECKPOINT_MAX_TOKENS;
	const window =
		typeof model.contextWindow === "number" && Number.isFinite(model.contextWindow) && model.contextWindow > 0
			? Math.floor(model.contextWindow)
			: 0;
	if (window === 0) {
		return base;
	}
	const room = window - Math.max(0, tokensBefore) - CHECKPOINT_CONTEXT_MARGIN;
	if (room >= base) {
		return base;
	}
	return Math.max(MIN_CHECKPOINT_MAX_TOKENS, room);
}

/** Text blocks of one message, joined (string content is taken as-is). */
function messageText(message: unknown): string {
	if (message === null || typeof message !== "object") {
		return "";
	}
	const content = (message as { content?: unknown }).content;
	if (typeof content === "string") {
		return content;
	}
	if (!Array.isArray(content)) {
		return "";
	}
	const parts: string[] = [];
	for (const block of content) {
		if (block === null || typeof block !== "object") {
			continue;
		}
		const typed = block as { type?: unknown; text?: unknown };
		if (typed.type === "text" && typeof typed.text === "string") {
			parts.push(typed.text);
		}
	}
	return parts.join("\n");
}

/**
 * Literal patterns whose matches must survive into the checkpoint: backticked
 * spans, quoted spans, paths, commands with a flag, URLs, hex ids and `#123`
 * references. Order matters only for the cap: earlier patterns are stronger
 * signals than a bare path-looking token.
 */
function addLiteral(
	out: ProtectedLiteral[],
	seen: Set<string>,
	raw: unknown,
	source: ProtectedLiteral["source"],
): void {
	if (typeof raw !== "string") {
		return;
	}
	const value = raw.trim();
	if (value === "" || value.length > 200 || !/[A-Za-z0-9]/.test(value)) {
		return;
	}
	if (seen.has(value)) {
		return;
	}
	seen.add(value);
	out.push({ text: value, source });
}

const LITERAL_PATTERNS: Array<{ pattern: RegExp; group: number }> = [
	{ pattern: /`([^`\n]{1,200})`/g, group: 1 },
	{ pattern: /"([^"\n]{3,120})"/g, group: 1 },
	{ pattern: /'([^'\n]{3,120})'/g, group: 1 },
	{ pattern: /https?:\/\/[^\s)>\]"']+/g, group: 0 },
	{ pattern: /[\w./-]+\.\w{1,5}/g, group: 0 },
	{ pattern: /\b\w+\s+--?\w[\w-]*/g, group: 0 },
	{ pattern: /#\d+/g, group: 0 },
	{ pattern: /\b[0-9a-fA-F]{7,}\b/g, group: 0 },
];

function collectLiteralsFrom(
	text: string,
	source: ProtectedLiteral["source"],
	out: ProtectedLiteral[],
	seen: Set<string>,
): void {
	if (text === "") {
		return;
	}
	for (const entry of LITERAL_PATTERNS) {
		for (const match of text.matchAll(entry.pattern)) {
			addLiteral(out, seen, match[entry.group], source);
			if (out.length >= PROTECTED_LITERAL_LIMIT) {
				return;
			}
		}
	}
}

/**
 * Up to 30 literals from the newest user messages (tagged `[VERIFIED]` when they
 * are missing) and the previous summary (`[REPORTED]`). User matches win: they
 * are collected first, so the cap never drops them for summary noise.
 */
function collectProtectedLiterals(userTexts: string[], previousSummary: string): ProtectedLiteral[] {
	const out: ProtectedLiteral[] = [];
	const seen = new Set<string>();
	for (const text of userTexts) {
		collectLiteralsFrom(text, "user", out, seen);
	}
	collectLiteralsFrom(previousSummary, "previous", out, seen);
	return out.slice(0, PROTECTED_LITERAL_LIMIT);
}

/** The language rule, injected into the prompt for the checkpoint's language. */
function checkpointLanguageRule(language: CheckpointLanguage): string {
	if (language === "english") {
		return "LANGUAGE: write everything in English.";
	}
	if (language === "conversation") {
		return "LANGUAGE: write in the conversation's dominant language; the section headings may be translated too.";
	}
	return "LANGUAGE: write the body in the conversation's dominant language, but keep every section heading in English.";
}

/** System prompt + one user message, as pi's own summariser does it. */
function buildCheckpointPrompt(args: {
	conversationText: string;
	previousSummary: string;
	language: CheckpointLanguage;
	maxWords: number;
}): string {
	const rules = [
		"RULES:",
		"- Tag every claim with its evidence: [USER] for what the user said, [VERIFIED] for what was checked or produced, [REPORTED] for what a tool or the previous summary reported, [UNCERTAIN] for an inference. Never present an inference as a fact.",
		"- Keep exact literals verbatim: file paths, commands, error strings, ids, commit SHAs and URLs.",
		"- Preserve ALL information from the previous summary: reconcile it with the new messages, dedupe it, and delete only what the new messages supersede.",
		"- Never keep a bullet that duplicates another bullet.",
		"- Never list the same item under both Done and In Progress.",
		"- Do not copy file lists into the body; the artifact trail names only the artifacts that matter.",
	].join("\n");
	const parts = [
		"Write a context checkpoint with EXACTLY these sections, in this order:",
		CHECKPOINT_SECTIONS.join("\n"),
		rules,
		checkpointLanguageRule(args.language),
		`LENGTH: aim for about ${args.maxWords} words and never exceed ${args.maxWords * 2}.`,
	];
	if (args.previousSummary !== "") {
		parts.push(`<previous-summary>\n${args.previousSummary}\n</previous-summary>`);
	}
	parts.push(`<conversation>\n${args.conversationText}\n</conversation>`);
	parts.push("Write the checkpoint now.");
	return parts.join("\n\n");
}

/**
 * Strip a fence around the whole answer, collapse runs of blank lines and drop
 * exact duplicate bullets. Lines inside fenced code blocks are never deduped
 * (a fence may legitimately repeat a line).
 */
function sanitizeSummary(text: string): string {
	let out = text.trim();
	out = out.replace(/^```(?:markdown|md)?[ \t]*\r?\n/, "");
	out = out.replace(/\r?\n```[ \t]*$/, "");
	const seen = new Set<string>();
	const kept: string[] = [];
	let inFence = false;
	for (const line of out.split("\n")) {
		const trimmed = line.trim();
		if (trimmed.startsWith("```")) {
			inFence = !inFence;
			kept.push(line);
			continue;
		}
		if (!inFence && /^[-*] |^\d+\. /.test(trimmed)) {
			if (seen.has(trimmed)) {
				continue;
			}
			seen.add(trimmed);
		}
		kept.push(line);
	}
	return kept.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

/** Append the literals the model dropped: never fail, always record them. */
function appendRetainedLiterals(summary: string, literals: ProtectedLiteral[]): string {
	const missing = literals.filter((literal) => !summary.includes(literal.text));
	if (missing.length === 0) {
		return summary;
	}
	const lines = ["## Retained Identifiers"];
	for (const literal of missing) {
		const tag = literal.source === "user" ? "[VERIFIED]" : "[REPORTED]";
		const rendered = literal.text.includes("`") ? literal.text : `\`${literal.text}\``;
		lines.push(`- ${rendered} ${tag}`);
	}
	return `${summary}\n\n${lines.join("\n")}`;
}

/** pi's `computeFileLists`: a modified path is never repeated as a read path. */
function fileListsFromOps(fileOps: SessionBeforeCompactEvent["preparation"]["fileOps"]): {
	readFiles: string[];
	modifiedFiles: string[];
} {
	const modified = new Set<string>([...fileOps.edited, ...fileOps.written]);
	const readFiles = [...fileOps.read].filter((path) => !modified.has(path)).sort();
	const modifiedFiles = [...modified].sort();
	return { readFiles, modifiedFiles };
}

/** The `<read-files>` / `<modified-files>` block pi appends, same shape and order. */
function renderFileBlock(readFiles: string[], modifiedFiles: string[]): string {
	const sections: string[] = [];
	if (readFiles.length > 0) {
		sections.push(`<read-files>\n${readFiles.join("\n")}\n</read-files>`);
	}
	if (modifiedFiles.length > 0) {
		sections.push(`<modified-files>\n${modifiedFiles.join("\n")}\n</modified-files>`);
	}
	return sections.length === 0 ? "" : `\n\n${sections.join("\n")}`;
}

/** Session id for the request; the cache retains nothing, so it is cosmetic. */
function readSessionId(ctx: ExtensionContext): string | undefined {
	try {
		const id = ctx.sessionManager?.getSessionId?.();
		return typeof id === "string" && id !== "" ? id : undefined;
	} catch {
		return undefined;
	}
}

/**
 * L2: ask the model for a structured checkpoint and return it only when it is
 * usable. Every rejection is a `undefined` return: the caller then leaves pi's
 * native summariser untouched (fail open, never cancel).
 */
async function runCheckpoint(
	preparation: SessionBeforeCompactEvent["preparation"],
	checkpoint: CheckpointSettings,
	ctx: ExtensionContext,
	signal: AbortSignal,
): Promise<CheckpointOutcome | undefined> {
	const startedAt = Date.now();
	const messages = [...preparation.messagesToSummarize, ...preparation.turnPrefixMessages];
	if (messages.length === 0) {
		return undefined;
	}
	const resolved = resolveCheckpointModel(ctx, checkpoint.model);
	if (!resolved) {
		return undefined;
	}
	const model = resolved.model;
	const previousSummary = typeof preparation.previousSummary === "string" ? preparation.previousSummary.trim() : "";
	const userTexts: string[] = [];
	for (const message of messages) {
		if (message !== null && typeof message === "object" && (message as { role?: unknown }).role === "user") {
			userTexts.push(messageText(message));
		}
	}
	const literals = collectProtectedLiterals(
		userTexts.slice(-PROTECTED_LITERAL_USER_MESSAGES),
		previousSummary,
	);
	const thinkingLevel = resolveThinkingLevel(checkpoint.thinking_level, ctx.thinkingLevel);
	const prompt = buildCheckpointPrompt({
		conversationText: serializeConversation(convertToLlm(messages)),
		previousSummary,
		language: checkpoint.language,
		maxWords: checkpoint.max_words,
	});
	const options: Record<string, unknown> = {
		maxTokens: resolveCheckpointMaxTokens(model, preparation.tokensBefore),
		signal,
		cacheRetention: "none",
	};
	const sessionId = readSessionId(ctx);
	if (sessionId !== undefined) {
		options.sessionId = sessionId;
	}
	if (thinkingLevel !== undefined) {
		options.reasoning = thinkingLevel;
	}
	// `streamSimple` is the provider-neutral entry point (it interprets `reasoning`
	// and clamps an out-of-range level); `complete()` forwards API-specific options
	// to the provider, where `reasoning` would be silently ignored.
	const response = (await ctx.modelRegistry
		.streamSimple(
			model,
			{
				systemPrompt: CHECKPOINT_SYSTEM_PROMPT,
				messages: [{ role: "user", content: [{ type: "text", text: prompt }], timestamp: Date.now() }],
			},
			options,
		)
		.result()) as unknown as SummarizationResponse;
	const blocks = Array.isArray(response?.content) ? response.content : [];
	if (blocks.some((block) => block?.type === "toolCall")) {
		return undefined;
	}
	const text = blocks
		.filter((block) => block?.type === "text" && typeof block.text === "string")
		.map((block) => block.text as string)
		.join("\n")
		.trim();
	if (text === "") {
		return undefined;
	}
	let summary = sanitizeSummary(text);
	if (summary === "") {
		return undefined;
	}
	summary = appendRetainedLiterals(summary, literals);
	const { readFiles, modifiedFiles } = fileListsFromOps(preparation.fileOps);
	summary += renderFileBlock(readFiles, modifiedFiles);
	// A summary at least as large as the context it replaces saves nothing.
	if (Math.ceil(summary.length / 4) >= preparation.tokensBefore) {
		return undefined;
	}
	return {
		summary,
		usage: response.usage,
		model: `${model.provider}/${model.id}`,
		thinkingLevel,
		language: checkpoint.language,
		durationMs: Date.now() - startedAt,
		summaryChars: summary.length,
	};
}

/** Report for a compaction whose L1 cleaning was switched off by config. */
function untouchedReport(preparation: SessionBeforeCompactEvent["preparation"], reason: string): CleanerReport {
	const fileOps = preparation.fileOps;
	return {
		reason,
		readKept: fileOps.read.size,
		readOmitted: 0,
		modifiedKept: fileOps.written.size + fileOps.edited.size,
		modifiedOmitted: 0,
		strippedPrevious: false,
	};
}

export default function compaction(pi: ExtensionAPI): void {
	pi.on("session_before_compact", async (event, ctx) => {
		const config = readConfig();
		if (!config.enabled || (!config.cleaner.enabled && !config.checkpoint.enabled)) {
			pendingReport = undefined;
			return undefined;
		}
		let cleaner: CleanerReport;
		try {
			cleaner = config.cleaner.enabled
				? cleanPreparation(event.preparation, config.cleaner, event.reason)
				: untouchedReport(event.preparation, event.reason);
		} catch (error) {
			// Never throw and never cancel: pi's own compaction is the safe fallback.
			pendingReport = undefined;
			warnOnce(ctx, error instanceof Error ? error.message : String(error));
			return undefined;
		}
		const report: PendingReport = {
			...cleaner,
			// `engine` describes the mode, `checkpoint` whether L2 actually produced
			// the summary: an enabled-but-failed checkpoint still reports its mode.
			engine: config.checkpoint.enabled ? "checkpoint" : "cleaner",
			checkpoint: false,
		};
		pendingReport = report;
		if (!config.checkpoint.enabled) {
			// `undefined` = "no custom summary": pi keeps driving the compaction.
			return undefined;
		}
		try {
			const outcome = await runCheckpoint(event.preparation, config.checkpoint, ctx, event.signal);
			if (!outcome) {
				if (!event.signal?.aborted) {
					warnCheckpointOnce(ctx);
				}
				return undefined;
			}
			report.checkpoint = true;
			report.model = outcome.model;
			report.thinkingLevel = outcome.thinkingLevel;
			report.durationMs = outcome.durationMs;
			report.language = outcome.language;
			report.summaryChars = outcome.summaryChars;
			const { readFiles, modifiedFiles } = fileListsFromOps(event.preparation.fileOps);
			// A custom compaction discards pi's `details`, so the bounded file lists
			// are carried here (L1's cap stays in force in L2 mode).
			const compaction = {
				summary: outcome.summary,
				firstKeptEntryId: event.preparation.firstKeptEntryId,
				tokensBefore: event.preparation.tokensBefore,
				usage: outcome.usage,
				details: {
					engine: "pi2",
					readFiles,
					modifiedFiles,
					readFilesOmitted: report.readOmitted,
					modifiedFilesOmitted: report.modifiedOmitted,
					model: outcome.model,
					thinkingLevel: outcome.thinkingLevel ?? null,
					durationMs: outcome.durationMs,
					language: outcome.language,
					previousSummaryStripped: report.strippedPrevious,
				},
			};
			return { compaction };
		} catch (error) {
			// Fail open: pi's native summariser runs unchanged.
			if (!event.signal?.aborted) {
				warnCheckpointOnce(ctx);
			}
			return undefined;
		}
	});

	pi.on("session_compact", async (event: SessionCompactEvent) => {
		const report = pendingReport;
		pendingReport = undefined;
		if (!report) {
			return;
		}
		try {
			const entry = event.compactionEntry;
			const data: Record<string, unknown> = {
				reason: report.reason,
				tokensBefore: entry?.tokensBefore,
				firstKeptEntryId: entry?.firstKeptEntryId,
				readKept: report.readKept,
				readOmitted: report.readOmitted,
				modifiedKept: report.modifiedKept,
				modifiedOmitted: report.modifiedOmitted,
				strippedPrevious: report.strippedPrevious,
				engine: report.engine,
				checkpoint: report.checkpoint,
			};
			if (report.checkpoint) {
				data.model = report.model;
				data.thinkingLevel = report.thinkingLevel ?? null;
				data.durationMs = report.durationMs;
				data.language = report.language;
				data.summaryChars = report.summaryChars;
			}
			pi.appendEntry(ENTRY_TYPE, data);
		} catch {
			// The record is telemetry: losing it must not fail a successful compaction.
		}
	});

	pi.on("session_compact_failed", async (_event: SessionCompactFailedEvent) => {
		pendingReport = undefined;
	});

	// L3 state: implemented in a follow-up (a `context` handler that injects one
	// compact session-state note before each request).
	// L4 prune: implemented in a follow-up (opt-in tool-result pruning before a
	// summarisation starts, driven by `prune.high_water` / `prune.min_turns`).
}
