/**
 * Compaction control for pi.nvim (Gitea #127).
 *
 * One bundled extension, four layers. This file implements L1, L2 and L3 plus
 * the owner/conflict detection and carries the skeleton for the rest, so a
 * follow-up task extends ONE file instead of inventing a second:
 *
 *  - L1 `cleaner` (default on, this file): bound the file lists pi appends to a
 *    summary, and keep the summarisation INPUT clean.
 *  - L2 `checkpoint` (opt-in, this file): return our own structured, deduped
 *    checkpoint from `session_before_compact`, with evidence tags, protected
 *    literals and the same file lists L1 bounds.
 *  - L3 `state` (default on, this file): after a successful compaction, persist
 *    one deterministic state snapshot (todos, background tasks, sub-agents, git,
 *    compaction facts) and replay it into the NEXT request exactly once through
 *    the `context` hook.
 *  - L4 `prune`: opt-in tool-result pruning (follow-up task).
 *
 * ## Owner / conflict detection
 *
 * Compaction handlers chain last-wins: another loaded extension may replace our
 * summary. When a successful compaction reports `fromExtension` with
 * `details.engine !== "pi2"`, a DIFFERENT extension supplied it. pi.nvim then
 * warns once per session and L2/L4 stand down for the rest of the session; L1
 * cleaning and the L3 snapshot stay active (they cost nothing and keep the
 * state note correct).
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
 * reads the `enabled`, `cleaner`, `checkpoint`, `state` and `owner` sections; L4
 * reads its own keys when it lands.
 */

import type {
	ExtensionAPI,
	ExtensionContext,
	SessionBeforeCompactEvent,
	SessionCompactEvent,
	SessionCompactFailedEvent,
} from "@earendil-works/pi-coding-agent";
import { convertToLlm, serializeConversation } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

const ENV_FILE = "PI_NVIM_COMPACTION_FILE";
/** Custom entry that records what the cleaner did for one compaction. */
const ENTRY_TYPE = "pi2-compaction-cleaner";
const DEFAULT_MAX_READ = 50;
const DEFAULT_MAX_MODIFIED = 100;
const DEFAULT_MAX_WORDS = 1500;
/** Default character budget of the L3 snapshot, in tokens (`max_tokens * 4` chars). */
const DEFAULT_STATE_MAX_TOKENS = 1000;
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

/** The L3 post-compaction snapshot options, as published by pi.nvim. */
interface StateSettings {
	enabled: boolean;
	max_tokens: number;
}

/** The owner/conflict detection switch, as published by pi.nvim. */
interface OwnerSettings {
	detect: boolean;
}

/** The part of the published runtime config these layers read. */
interface CompactionRuntimeConfig {
	enabled: boolean;
	cleaner: CleanerSettings;
	checkpoint: CheckpointSettings;
	state: StateSettings;
	owner: OwnerSettings;
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
		state: {
			enabled: true,
			max_tokens: DEFAULT_STATE_MAX_TOKENS,
		},
		owner: {
			detect: true,
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
	const rawState = parsed.state;
	if (rawState !== null && typeof rawState === "object") {
		const state = rawState as Record<string, unknown>;
		config.state.enabled = booleanOr(state.enabled, config.state.enabled);
		config.state.max_tokens = clampInteger(state.max_tokens, config.state.max_tokens, 100, 4000);
	}
	const rawOwner = parsed.owner;
	if (rawOwner !== null && typeof rawOwner === "object") {
		const owner = rawOwner as Record<string, unknown>;
		config.owner.detect = booleanOr(owner.detect, config.owner.detect);
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

// ---------------------------------------------------------------------------
// L3: post-compaction state snapshot (default on through `state.enabled`)
// ---------------------------------------------------------------------------

/** Custom entry that records one snapshot: its text, facts and content hash. */
const STATE_ENTRY_TYPE = "pi2-compaction-state";

/**
 * First line of every snapshot. Byte-constant on purpose: it says what the
 * block is (facts, not a summary) and what to do with it, so the model never
 * mistakes it for the summary it was injected next to. The e2e asserts it.
 */
const STATE_HEADER =
	"[pi2 state] Post-compaction state snapshot (facts, NOT a summary). Re-read files you still need; this replaces nothing.";

/** Per-section caps (the budget below is the hard limit, these keep it readable). */
const STATE_MAX_TODOS = 10;
const STATE_MAX_BG_TASKS = 5;
const STATE_MAX_SUBAGENTS = 5;
const STATE_MAX_GIT_LINES = 20;
const STATE_COMMAND_COLS = 60;
const STATE_TASK_COLS = 60;
/** A hung `git` must never block a compaction that already succeeded. */
const GIT_TIMEOUT_MS = 2000;

/** `extensions/todo.ts`: the tool result and the checkpoint entry it persists. */
const TODO_TOOL_NAME = "todo_write";
const TODO_CHECKPOINT_TYPE = "pi2-todo";
/** `extensions/bg-tasks.ts`: the custom (message) entries it pushes. */
const BG_TASK_TYPE = "pi2_bg_task";
/** pi.nvim's sub-session manifest, next to the session files. */
const SUBSESSION_MANIFEST = ".pi2-subsessions.json";

/**
 * The `fromExtension` / `details.engine` classification of one compaction:
 * `pi2` = ours, `foreign` = another extension, `native` = pi's own summariser.
 */
export type CompactionOwner = "pi2" | "foreign" | "native";

/**
 * Who supplied a successful compaction. `session_before_compact` handlers chain
 * last-wins, so a later explicit `--extension` (or a third-party summariser)
 * can replace ours; only `details.engine` tells the two apart.
 */
export function classifyCompactionOwner(fromExtension: unknown, details: unknown): CompactionOwner {
	if (fromExtension !== true) {
		return "native";
	}
	if (details === null || typeof details !== "object") {
		return "foreign";
	}
	return (details as { engine?: unknown }).engine === "pi2" ? "pi2" : "foreign";
}

/** Shown once per session when another extension owns the summary. */
const OWNER_CONFLICT_MESSAGE =
	"pi2-compaction: another compaction extension supplied this summary; the pi2 checkpoint/prune layers stand down for this session";

/** True once a foreign summariser was seen: L2 and L4 stand down (L1/L3 stay). */
let ownerConflict = false;
/** Session id already warned about a foreign summariser, so the notice is per session. */
let ownerWarnedFor: string | undefined;

/**
 * One snapshot, kept in module state so the `context` hook can replay it. The
 * `timestamp` is carried here on purpose: the injected message needs a stable
 * one, and the snapshot TEXT must stay timestamp-free (byte-stable hashing).
 */
interface StateSnapshot {
	text: string;
	hash: string;
	/** Fixed epoch ms for the injected message envelope. */
	timestamp: number;
	reason: string;
	tokensBefore: number;
	tokensAfter: number;
	/** Hash the last request already carried; equal to `hash` means "injected". */
	injectedHash?: string;
}

/** The most recent snapshot ("pending" until one request has carried it). */
let pendingState: StateSnapshot | undefined;

/** The subset of a session entry the snapshot folds (see session-format.md). */
interface SessionEntryLike {
	type?: string;
	customType?: string;
	data?: unknown;
	details?: unknown;
	message?: {
		role?: string;
		toolName?: string;
		details?: unknown;
	};
}

/** FNV-1a (32 bit) as 8 hex chars: cheap, stable across runs, no crypto import. */
function fnv1aHex(text: string): string {
	let hash = 0x811c9dc5;
	for (let index = 0; index < text.length; index += 1) {
		hash ^= text.charCodeAt(index);
		// `Math.imul` keeps the multiply in 32-bit space.
		hash = Math.imul(hash, 0x01000193) >>> 0;
	}
	return hash.toString(16).padStart(8, "0");
}

/** All whitespace runs collapsed to one space (a command or task on one line). */
function flatten(text: string): string {
	return text.replace(/\s+/g, " ").trim();
}

/** `flatten` plus a hard column cut (deterministic: the marker is always `...`). */
function cut(text: string, max: number): string {
	const flat = flatten(text);
	return flat.length > max ? `${flat.slice(0, Math.max(0, max - 3))}...` : flat;
}

/** One folded todo item (only `content` and `status` matter here). */
interface FoldedTodo {
	content: string;
	status: string;
}

/**
 * The array shape `todo_write` stores in `details.todos`. Anything malformed is
 * rejected as a whole (a half-read list would be worse than none).
 */
function validTodos(value: unknown): FoldedTodo[] | undefined {
	if (!Array.isArray(value)) {
		return undefined;
	}
	const todos: FoldedTodo[] = [];
	for (const item of value) {
		if (item === null || typeof item !== "object") {
			return undefined;
		}
		const content = (item as { content?: unknown }).content;
		const status = (item as { status?: unknown }).status;
		if (typeof content !== "string" || typeof status !== "string") {
			return undefined;
		}
		todos.push({ content, status });
	}
	return todos;
}

/**
 * Fold the session's todo state like `extensions/todo.ts` rebuilds it, except
 * that the newest source wins across BOTH: a compaction drops the tool results
 * whose `details` carried the list, while the `pi2-todo` checkpoint survives.
 */
function foldTodos(entries: SessionEntryLike[]): FoldedTodo[] {
	let latest: FoldedTodo[] = [];
	for (const entry of entries) {
		if (entry.type === "message") {
			const message = entry.message;
			if (message?.role !== "toolResult" || message.toolName !== TODO_TOOL_NAME) {
				continue;
			}
			const details = message.details as { error?: unknown; todos?: unknown } | undefined;
			if (!details || details.error) {
				continue;
			}
			const todos = validTodos(details.todos);
			if (todos) {
				latest = todos;
			}
		} else if (entry.type === "custom" && entry.customType === TODO_CHECKPOINT_TYPE) {
			const todos = validTodos((entry.data as { todos?: unknown } | undefined)?.todos);
			if (todos) {
				latest = todos;
			}
		}
	}
	return latest;
}

/** `## Todos` with the unfinished items only (completed work is in the summary). */
function renderTodos(todos: FoldedTodo[]): string {
	const open = todos.filter((todo) => todo.status !== "completed");
	if (open.length === 0) {
		return "";
	}
	const lines = [`## Todos (${open.length} unfinished)`];
	for (const todo of open.slice(0, STATE_MAX_TODOS)) {
		const content = todo.status === "in_progress" ? `${flatten(todo.content)} (in progress)` : flatten(todo.content);
		lines.push(`- [ ] ${content}`);
	}
	if (open.length > STATE_MAX_TODOS) {
		lines.push(`- ... ${open.length - STATE_MAX_TODOS} more unfinished`);
	}
	return lines.join("\n");
}

/** One background task record after the newest-wins fold. */
interface FoldedBgTask {
	id: string;
	state: string;
	command: string;
}

/** `bg-tasks.ts` kinds projected onto the state the snapshot reports. */
function bgTaskState(kind: unknown): string | undefined {
	if (kind === "started") {
		return "running";
	}
	if (kind === "completed") {
		return "completed";
	}
	if (kind === "failed") {
		return "failed";
	}
	if (kind === "stopped") {
		return "stopped";
	}
	if (kind === "unknown") {
		return "unknown";
	}
	return undefined;
}

/**
 * Fold `pi2_bg_task` records, newest per `taskId`. They are `custom_message`
 * entries in practice (they also enter LLM context) and `custom` entries when an
 * extension appends them directly, so both entry shapes are read.
 */
function foldBgTasks(entries: SessionEntryLike[]): FoldedBgTask[] {
	const byId = new Map<string, FoldedBgTask>();
	for (const entry of entries) {
		if (entry.customType !== BG_TASK_TYPE) {
			continue;
		}
		if (entry.type !== "custom" && entry.type !== "custom_message") {
			continue;
		}
		const details =
			entry.type === "custom"
				? (entry.data as Record<string, unknown> | undefined)
				: (entry.details as Record<string, unknown> | undefined);
		if (!details || typeof details.taskId !== "string" || details.taskId === "") {
			continue;
		}
		const state = bgTaskState(details.kind);
		if (!state) {
			continue;
		}
		byId.set(details.taskId, {
			id: details.taskId,
			state,
			command: typeof details.command === "string" ? details.command : "",
		});
	}
	return [...byId.values()].sort((left, right) => (left.id < right.id ? -1 : left.id > right.id ? 1 : 0));
}

/** `## Background tasks`: running / failed / unknown only (a clean exit is done). */
function renderBgTasks(tasks: FoldedBgTask[]): string {
	const open = tasks.filter(
		(task) => task.state === "running" || task.state === "failed" || task.state === "unknown",
	);
	if (open.length === 0) {
		return "";
	}
	const lines = ["## Background tasks"];
	for (const task of open.slice(0, STATE_MAX_BG_TASKS)) {
		lines.push(`- ${task.id} ${task.state} "${cut(task.command, STATE_COMMAND_COLS)}"`);
	}
	if (open.length > STATE_MAX_BG_TASKS) {
		lines.push(`- ... ${open.length - STATE_MAX_BG_TASKS} more`);
	}
	return lines.join("\n");
}

/** One sub-agent row the parent still has to hear from. */
interface SubagentRow {
	name: string;
	status: string;
	task: string;
}

/**
 * Rows of `.pi2-subsessions.json` next to the session file (the manifest pi.nvim
 * keeps per workspace): active children, plus completed/failed ones whose report
 * the parent has not collected yet. A missing/unreadable manifest is just "no
 * sub-agents" — never an error.
 */
function readSubagents(sessionFile: string | undefined): SubagentRow[] {
	if (typeof sessionFile !== "string" || sessionFile === "") {
		return [];
	}
	let parsed: Record<string, unknown>;
	try {
		const path = join(dirname(sessionFile), SUBSESSION_MANIFEST);
		parsed = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
	} catch {
		return [];
	}
	if (parsed === null || typeof parsed !== "object") {
		return [];
	}
	const rows: SubagentRow[] = [];
	for (const [id, raw] of Object.entries(parsed)) {
		// `__lineage__` and any future metadata key is not a child row.
		if (id.startsWith("__") || raw === null || typeof raw !== "object") {
			continue;
		}
		const row = raw as Record<string, unknown>;
		const status = typeof row.status === "string" ? row.status : "";
		const pending = (status === "completed" || status === "failed") && row.reported !== true;
		if (status !== "active" && !pending) {
			continue;
		}
		const name = typeof row.name === "string" && row.name !== "" ? row.name : id;
		const task =
			typeof row.task_prompt === "string" && row.task_prompt !== ""
				? row.task_prompt
				: typeof row.task === "string"
					? row.task
					: "";
		rows.push({ name, status, task });
	}
	rows.sort((left, right) => (left.name < right.name ? -1 : left.name > right.name ? 1 : 0));
	return rows;
}

/** `## Sub-agents`, one line per child the parent may still have to reconcile. */
function renderSubagents(rows: SubagentRow[]): string {
	if (rows.length === 0) {
		return "";
	}
	const lines = ["## Sub-agents"];
	for (const row of rows.slice(0, STATE_MAX_SUBAGENTS)) {
		const task = cut(row.task, STATE_TASK_COLS);
		lines.push(task === "" ? `- ${row.name} ${row.status}` : `- ${row.name} ${row.status} ${task}`);
	}
	if (rows.length > STATE_MAX_SUBAGENTS) {
		lines.push(`- ... ${rows.length - STATE_MAX_SUBAGENTS} more`);
	}
	return lines.join("\n");
}

/** What `git` says about the working tree, already capped for the snapshot. */
interface GitState {
	branch?: string;
	root?: string;
	status: string[];
	more: number;
}

/** `execFileSync` wrapper: any failure (no git, not a repo, timeout) is `undefined`. */
function runGit(cwd: string, args: string[]): string | undefined {
	try {
		return execFileSync("git", args, {
			cwd,
			timeout: GIT_TIMEOUT_MS,
			encoding: "utf8",
			// Never inherit stdout/stderr: git's own chatter must not reach the RPC stream.
			stdio: ["ignore", "pipe", "ignore"],
		}).trim();
	} catch {
		return undefined;
	}
}

/** Branch, root and a capped `status --short`; `undefined` when git is unusable. */
function readGit(cwd: string): GitState | undefined {
	if (typeof cwd !== "string" || cwd === "") {
		return undefined;
	}
	// `--no-optional-locks`: reading state must not take the index lock.
	const branch = runGit(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]);
	const root = runGit(cwd, ["rev-parse", "--show-toplevel"]);
	const status = runGit(cwd, ["--no-optional-locks", "status", "--short"]);
	if (branch === undefined && root === undefined && status === undefined) {
		return undefined;
	}
	const lines = status === undefined || status === "" ? [] : status.split("\n").filter((line) => line.trim() !== "");
	return {
		branch: branch === undefined || branch === "" ? undefined : branch,
		root: root === undefined || root === "" ? undefined : root,
		status: lines.slice(0, STATE_MAX_GIT_LINES),
		more: Math.max(0, lines.length - STATE_MAX_GIT_LINES),
	};
}

/** `## Git`: branch, root and the (capped) short status. */
function renderGit(git: GitState | undefined): string {
	if (!git) {
		return "";
	}
	const lines = ["## Git"];
	if (git.branch !== undefined) {
		lines.push(`- branch: ${git.branch}`);
	}
	if (git.root !== undefined) {
		lines.push(`- root: ${git.root}`);
	}
	if (git.status.length > 0) {
		const count = git.more > 0 ? `${git.status.length} of ${git.status.length + git.more}` : `${git.status.length}`;
		lines.push(`- status (${count}):`);
		lines.push(...git.status);
	}
	return lines.join("\n");
}

/** The `## Compaction` facts: what was compacted, and what L1 kept of it. */
function renderFacts(args: {
	reason: string;
	tokensBefore: number;
	tokensAfter: number;
	report: PendingReport | undefined;
}): string {
	const lines = ["## Compaction", `- reason: ${args.reason}`];
	lines.push(`- tokens: ${args.tokensBefore} -> ${args.tokensAfter} (after: estimated)`);
	const report = args.report;
	if (report) {
		lines.push(
			`- files: read ${report.readKept} kept / ${report.readOmitted} omitted; modified ${report.modifiedKept} kept / ${report.modifiedOmitted} omitted`,
		);
	}
	return lines.join("\n");
}

/**
 * Assemble the snapshot within `max_tokens * 4` characters. Sections render in a
 * fixed order (compaction, todos, background tasks, sub-agents, git), and the
 * budget is met by dropping git first, then sub-agents; anything else that still
 * does not fit is cut and marked `[truncated]`.
 *
 * `digest` is the same render WITHOUT the `## Compaction` facts, and it is what
 * the content hash covers: the facts carry this compaction's token counts, so
 * hashing them would make every snapshot look new and re-inject an unchanged
 * state after each compaction. The hash answers "is the folded state the same?",
 * which is the question the re-injection gate asks.
 */
function renderSnapshotText(
	parts: { facts: string; todos: string; bgTasks: string; subagents: string; git: string },
	maxTokens: number,
): { text: string; digest: string } {
	const budget = Math.max(1, Math.floor(maxTokens)) * 4;
	const sections = [
		{ name: "facts", text: parts.facts },
		{ name: "todos", text: parts.todos },
		{ name: "bg", text: parts.bgTasks },
		{ name: "subagents", text: parts.subagents },
		{ name: "git", text: parts.git },
	].filter((section) => section.text !== "");
	const dropped = new Set<string>();
	let truncated = false;
	const render = (): { text: string; digest: string } => {
		const kept = sections.filter((section) => !dropped.has(section.name));
		const trailer = truncated ? ["[truncated]"] : [];
		const body = kept.map((section) => section.text);
		const digestBody = kept.filter((section) => section.name !== "facts").map((section) => section.text);
		return {
			text: [STATE_HEADER, ...body, ...trailer].join("\n\n"),
			digest: [STATE_HEADER, ...digestBody, ...trailer].join("\n\n"),
		};
	};
	let rendered = render();
	for (const name of ["git", "subagents"]) {
		if (rendered.text.length <= budget) {
			break;
		}
		if (!sections.some((section) => section.name === name)) {
			continue;
		}
		dropped.add(name);
		truncated = true;
		rendered = render();
	}
	if (rendered.text.length > budget) {
		const tail = "\n\n[truncated]";
		const text = `${rendered.text.slice(0, Math.max(0, budget - tail.length)).trimEnd()}${tail}`;
		return { text, digest: text };
	}
	return rendered;
}

/** Warn once per session that another extension owns the summary. */
function warnOwnerConflictOnce(ctx: ExtensionContext): void {
	const sessionId = readSessionId(ctx) ?? "";
	if (ownerWarnedFor === sessionId) {
		return;
	}
	ownerWarnedFor = sessionId;
	try {
		ctx.ui.notify(OWNER_CONFLICT_MESSAGE, "warning");
	} catch {
		// A notify that cannot be delivered must not fail a successful compaction.
	}
}

/**
 * L3: build, persist and schedule one state snapshot for a successful
 * compaction. Never throws: the snapshot is an enhancement, not part of the
 * compaction contract.
 */
function publishStateSnapshot(
	pi: ExtensionAPI,
	event: SessionCompactEvent,
	ctx: ExtensionContext,
	config: CompactionRuntimeConfig,
	report: PendingReport | undefined,
): void {
	try {
		const entry = event.compactionEntry;
		const summary = typeof entry?.summary === "string" ? entry.summary : "";
		const tokensBefore = typeof entry?.tokensBefore === "number" ? entry.tokensBefore : 0;
		// pi's own chars/4 heuristic: the entry carries no "after" count.
		const tokensAfter = Math.ceil(summary.length / 4);
		const entries = ctx.sessionManager.getEntries() as unknown as SessionEntryLike[];
		const sessionFile = ctx.sessionManager.getSessionFile();
		const { text, digest } = renderSnapshotText(
			{
				facts: renderFacts({ reason: event.reason, tokensBefore, tokensAfter, report }),
				todos: renderTodos(foldTodos(entries)),
				bgTasks: renderBgTasks(foldBgTasks(entries)),
				subagents: renderSubagents(readSubagents(sessionFile)),
				git: renderGit(readGit(ctx.cwd)),
			},
			config.state.max_tokens,
		);
		const hash = fnv1aHex(digest);
		const timestamp = Date.now();
		// A snapshot with the SAME state hash stays "already injected": the bytes
		// the last request carried are unchanged, so a second copy is pure waste.
		const alreadyInjected = pendingState?.injectedHash === hash ? hash : undefined;
		pendingState = {
			text,
			hash,
			timestamp,
			reason: event.reason,
			tokensBefore,
			tokensAfter,
			injectedHash: alreadyInjected,
		};
		pi.appendEntry(STATE_ENTRY_TYPE, {
			text,
			reason: event.reason,
			tokensBefore,
			tokensBeforeAfter: tokensAfter,
			hash,
		});
	} catch {
		// Telemetry only: a failed snapshot must not undo a successful compaction.
		pendingState = undefined;
	}
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
		if (!config.checkpoint.enabled || ownerConflict) {
			// `undefined` = "no custom summary": pi keeps driving the compaction.
			// A session another extension owns also stands L2 down for good.
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

	pi.on("session_compact", async (event: SessionCompactEvent, ctx: ExtensionContext) => {
		const config = readConfig();
		const report = pendingReport;
		pendingReport = undefined;

		// Owner detection comes first: it must work even when this extension did
		// not supply the summary (a later handler overwrote ours, or we never
		// ran because the competing extension cancelled first).
		if (config.owner.detect) {
			const owner = classifyCompactionOwner(event.fromExtension, event.compactionEntry?.details);
			if (owner === "foreign") {
				ownerConflict = true;
				warnOwnerConflictOnce(ctx);
			}
		}

		if (report) {
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
		}

		// L3 stays active even when another extension owns the summary: the state
		// note is about the session (todos, tasks, git), not about the summary.
		if (config.enabled && config.state.enabled) {
			publishStateSnapshot(pi, event, ctx, config, report);
		}
	});

	pi.on("session_compact_failed", async (_event: SessionCompactFailedEvent) => {
		pendingReport = undefined;
	});

	// L3 injection: exactly ONE request after a compaction carries the snapshot,
	// and only when its content changed since the last injected one (same hash =
	// byte-stable, no second copy; never per turn). `event.messages` is a deep copy
	// and the returned array is a new one, so nothing is persisted to the session.
	pi.on("context", async (event) => {
		const snapshot = pendingState;
		if (!snapshot || snapshot.injectedHash === snapshot.hash) {
			return undefined;
		}
		const config = readConfig();
		if (!config.enabled || !config.state.enabled) {
			return undefined;
		}
		const messages = [
			{
				role: "user" as const,
				content: [{ type: "text" as const, text: snapshot.text }],
				// Fixed per snapshot: the injected envelope never drifts within a run.
				timestamp: snapshot.timestamp,
			},
			...event.messages,
		];
		snapshot.injectedHash = snapshot.hash;
		return { messages };
	});

	// L4 prune: implemented in a follow-up (opt-in tool-result pruning before a
	// summarisation starts, driven by `prune.high_water` / `prune.min_turns`).
}
