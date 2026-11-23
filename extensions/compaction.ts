/**
 * Compaction control for pi.nvim (Gitea #127).
 *
 * One bundled extension, four layers. This file implements L1 and carries the
 * skeleton for the rest, so a follow-up task extends ONE file instead of
 * inventing a second:
 *
 *  - L1 `cleaner` (default on, this file): bound the file lists pi appends to a
 *    summary, and keep the summarisation INPUT clean.
 *  - L2 `checkpoint`: an opt-in model-generated checkpoint (follow-up task).
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
 * ## Config
 *
 * `PI_NVIM_COMPACTION_FILE` points at a JSON file pi.nvim republishes on every
 * `setup()` (shape: `lua/pi/compaction/extension.lua`). The process env is
 * frozen at spawn, the file is re-read on every compaction event, so a live
 * `setup()` applies without respawning pi (same pattern as extensions/todo.ts).
 * Outside pi.nvim the file is absent and the defaults below apply. Only the
 * `enabled` and `cleaner` sections are read here; L2/L3/L4 read their own keys
 * when they land.
 */

import type {
	ExtensionAPI,
	ExtensionContext,
	SessionBeforeCompactEvent,
	SessionCompactEvent,
	SessionCompactFailedEvent,
} from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";

const ENV_FILE = "PI_NVIM_COMPACTION_FILE";
/** Custom entry that records what the cleaner did for one compaction. */
const ENTRY_TYPE = "pi2-compaction-cleaner";
const DEFAULT_MAX_READ = 50;
const DEFAULT_MAX_MODIFIED = 100;

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

/** The part of the published runtime config this layer reads. */
interface CompactionRuntimeConfig {
	enabled: boolean;
	cleaner: CleanerSettings;
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
	return config;
}

/**
 * One pending cleaner report. Module-level because `session_compact` carries no
 * reference back to the `session_before_compact` invocation; one pi process
 * runs one compaction at a time (`agent-session` aborts the previous one), so a
 * single slot is correct. `session_compact_failed` clears it.
 */
interface PendingCleanerReport {
	reason: string;
	readKept: number;
	readOmitted: number;
	modifiedKept: number;
	modifiedOmitted: number;
	strippedPrevious: boolean;
}

let pendingCleaner: PendingCleanerReport | undefined;

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
): PendingCleanerReport {
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

export default function compaction(pi: ExtensionAPI): void {
	pi.on("session_before_compact", async (event, ctx) => {
		const config = readConfig();
		if (!config.enabled || !config.cleaner.enabled) {
			pendingCleaner = undefined;
			return undefined;
		}
		try {
			pendingCleaner = cleanPreparation(event.preparation, config.cleaner, event.reason);
		} catch (error) {
			// Never throw and never cancel: pi's own compaction is the safe fallback.
			pendingCleaner = undefined;
			warnOnce(ctx, error instanceof Error ? error.message : String(error));
		}
		// `undefined` = "no custom summary": pi keeps driving the compaction.
		return undefined;
	});

	pi.on("session_compact", async (event: SessionCompactEvent) => {
		const report = pendingCleaner;
		pendingCleaner = undefined;
		if (!report) {
			return;
		}
		try {
			const entry = event.compactionEntry;
			pi.appendEntry(ENTRY_TYPE, {
				reason: report.reason,
				tokensBefore: entry?.tokensBefore,
				firstKeptEntryId: entry?.firstKeptEntryId,
				readKept: report.readKept,
				readOmitted: report.readOmitted,
				modifiedKept: report.modifiedKept,
				modifiedOmitted: report.modifiedOmitted,
				strippedPrevious: report.strippedPrevious,
				engine: "cleaner",
			});
		} catch {
			// The record is telemetry: losing it must not fail a successful compaction.
		}
	});

	pi.on("session_compact_failed", async (_event: SessionCompactFailedEvent) => {
		pendingCleaner = undefined;
	});

	// L2 checkpoint: implemented in a follow-up (session_before_compact returns a
	// `compaction` object with a model-generated checkpoint summary).
	// L3 state: implemented in a follow-up (a `context` handler that injects one
	// compact session-state note before each request).
	// L4 prune: implemented in a follow-up (opt-in tool-result pruning before a
	// summarisation starts, driven by `prune.high_water` / `prune.min_turns`).
}
