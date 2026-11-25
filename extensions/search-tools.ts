/**
 * Search-tool steering (backend for pi.nvim's `search_tools` config).
 *
 * pi's own bash tool advertises itself as `Execute bash commands (ls, grep,
 * find, etc.)`, and the dedicated grep/find/ls tools carry no
 * `promptGuidelines` at all. The model reads that as "bash is how you search"
 * and shells out to rg/grep/find for work these tools do better (capped
 * output that says how to widen the search, structure-aware rendering in the
 * UI, no shell quoting traps).
 *
 * Three levers, because the model sees them all:
 *
 *   1. before_agent_start — rewrite the prompt sections that are already
 *      assembled for this run: the bash entry in `sections.tools` gets a
 *      snippet that no longer advertises grep/find, and the grep/find/ls
 *      rules are *replaced* (not appended) in `sections.rules`. Replacement
 *      matters: these tools ship no guidelines, so appending would duplicate
 *      the bullets on every request. bash *does* carry its own guidelines, so
 *      the search rule is appended there instead (idempotently: one rule per
 *      run, however many turns reuse the options).
 *
 *      There is deliberately no registerTool for `bash`. `bg-tasks.ts`
 *      already overrides that tool, pi.nvim injects it first and
 *      unconditionally, and pi refuses to load two extensions registering the
 *      same tool name (`Tool "bash" conflicts with …`) — the whole session
 *      then fails to start, so a second registration is not an option. What
 *      the model reads in `<tools>` is the snippet above anyway; the
 *      declaration's `description` is not what this extension steers.
 *
 *   2. registerTool for `grep` — the builtin grep only answers "matching lines".
 *      Four extra parameters (`output`, `exclude`, `max_per_file`, `word`) cover
 *      the questions a model otherwise shells out to `rg`/`grep -c`/`grep -l`
 *      for. The search itself is never re-implemented: the builtin runs first
 *      and its text output is parsed, filtered and re-emitted, so ripgrep's
 *      auto-download, the 50KB/500-char caps, `details` and path relativization
 *      all stay pi's. Every call is post-processed (there is deliberately no
 *      fast path), because rows under `.git/` are always dropped: ripgrep runs
 *      with `--hidden` and would otherwise hand the model `.git/logs/HEAD`.
 *
 *   3. registerTool for `find` — the same shape. A path pattern reads as
 *      "everything under tests/", but pi hands it to fd as a full-path glob, so
 *      a nested `pkg/tests/a_spec.lua` is a legitimate hit for a pattern the
 *      model meant as rooted. `rooted` (default true) keeps only the pattern's
 *      literal leading directory; `sort` orders by path (default) or by
 *      modification time, newest first. Paths under `.git/` are always dropped
 *      (fd runs with `--hidden`).
 */

import type {
	ExtensionAPI,
	FindToolDetails,
	FindToolInput,
	GrepToolDetails,
	GrepToolInput,
	ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { createFindToolDefinition, createGrepToolDefinition } from "@earendil-works/pi-coding-agent";
import fs from "node:fs";
import path from "node:path";
import { Type, type TSchema } from "typebox";

const BASH_SNIPPET = "Execute shell commands (build, test, git, network, pipelines)";

const BASH_RULE = [
	"Do NOT use this tool to search or read files while a dedicated tool is active:",
	"- File contents: use `grep` (NOT bash grep/rg/git grep)",
	"- File paths: use `find` (NOT find/ls)",
	"- Reading a file: use `read` (NOT cat/head/tail)",
	"- Listing a directory: use `ls` (NOT ls/tree)",
	"Those tools cap their output and say how to widen a search; shell output does neither.",
	"Keep this tool for builds, tests, git, package managers, network calls and pipelines the dedicated tools cannot express.",
].join("\n");

const GREP_NOTE =
	"Supports output modes (content|files|count), exclude globs, a per-file match cap and whole-word matching; paths under .git are always skipped.";

/** How a delegated grep run is re-shaped before it reaches the model. */
type GrepOutputMode = "content" | "files" | "count";

/** The builtin grep input plus this extension's four extra parameters. */
type GrepParams = GrepToolInput & {
	output?: GrepOutputMode;
	exclude?: string[];
	max_per_file?: number;
	word?: boolean;
};

/** One row of the builtin grep's output: a match (`path:line: text`) or a context line (`path-line- text`). */
interface GrepRow {
	path: string;
	line: number;
	text: string;
	/** False for the context lines ripgrep emits around a match when `context > 0`. */
	isMatch: boolean;
}

/** A compiled `exclude` glob. A glob without a `/` matches a file name at any depth (as pi's `glob` does). */
interface CompiledGlob {
	re: RegExp;
	basenameOnly: boolean;
}

const GREP_MATCH_ROW = /^(.+?):(\d+):\s?(.*)$/;
const GREP_CONTEXT_ROW = /^(.+?)-(\d+)-\s?(.*)$/;
const GREP_DEFAULT_LIMIT = 100;
const GREP_MIN_INTERNAL_LIMIT = 200;
const GREP_MAX_INTERNAL_LIMIT = 5000;
const GREP_NO_MATCHES = "No matches found";
/** The builtin's own output budget; a rebuilt result must not grow past it. */
const GREP_MAX_BYTES = 50 * 1024;
const GREP_BYTES_NOTICE = "[50KB limit reached]";
const GREP_LINES_NOTICE = "[Some lines truncated to 500 chars. Use read tool to see full lines]";

/** How a delegated find run is ordered before it reaches the model. */
type FindSort = "path" | "mtime";

/** The builtin find input plus this extension's two extra parameters. */
type FindParams = FindToolInput & {
	rooted?: boolean;
	sort?: FindSort;
};

const FIND_DEFAULT_LIMIT = 1000;
const FIND_MIN_INTERNAL_LIMIT = 200;
const FIND_MAX_INTERNAL_LIMIT = 5000;
const FIND_NO_FILES = "No files found matching pattern";
const FIND_BYTES_NOTICE = "[50KB limit reached]";
const FIND_NOTE =
	"Set rooted: false to match the pattern at any depth (the default anchors a relative path pattern at the search directory, as pi 1.6 does); sort: 'mtime' returns the newest files first; paths under .git are always skipped.";

/** Escape RegExp metacharacters, so a caller's text can be used verbatim as a pattern. */
function escapeRegExp(text: string): string {
	return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Escape a glob into a RegExp source: `**` crosses directories, `*`/`?` never do. */
function globToSource(glob: string): string {
	let source = "";
	for (let index = 0; index < glob.length; index++) {
		const ch = glob[index];
		if (ch === "*") {
			if (glob[index + 1] === "*") {
				index++;
				if (glob[index + 1] === "/") {
					// `**/` also matches zero directories, so `src/**/a.ts` finds `src/a.ts`.
					index++;
					source += "(?:.*/)?";
				} else {
					source += ".*";
				}
			} else {
				source += "[^/]*";
			}
			continue;
		}
		if (ch === "?") {
			source += "[^/]";
			continue;
		}
		source += /[.+^${}()|[\]\\]/.test(ch) ? `\\${ch}` : ch;
	}
	return source;
}

/** @param glob an `exclude` entry, e.g. `dist/**` or `*.min.js` */
function compileGlob(glob: string): CompiledGlob {
	return { re: new RegExp(`^${globToSource(glob)}$`), basenameOnly: !glob.includes("/") };
}

/** @param filePath a path as the builtin grep prints it (relative to the search root) */
function isUnderGit(filePath: string): boolean {
	return filePath.split("/").includes(".git");
}

/**
 * The builtin's own trailing notice block, which is never a result row:
 * `[<n> matches limit reached …]`, `[<n> results limit reached …]`,
 * `[50KB limit reached]` and `[Some lines truncated …]`. A path that merely
 * starts with `[` (a `[slug].tsx` route file) is a row and parses before this
 * ever runs.
 *
 * @param line one line of the builtin's output
 */
function isBuiltinNotice(line: string): boolean {
	if (/^\[\d+ [a-z]/i.test(line)) {
		return true;
	}
	return line.startsWith("[50KB limit reached") || line.startsWith("[Some lines truncated");
}

/**
 * Parse the builtin grep's text output. Both row forms survive verbatim: match
 * rows (`path:line: text`, the ones `max_per_file` counts) and the context rows
 * ripgrep emits for `context > 0` (`path-line- text`, which it must never
 * count). `No matches found` and the trailing `[notice]` block are dropped.
 */
function parseGrepOutput(text: string): GrepRow[] {
	const rows: GrepRow[] = [];
	for (const line of text.split("\n")) {
		if (line === "" || line === GREP_NO_MATCHES) {
			continue;
		}
		// Match rows first: a match's own text may contain something like `-12-`.
		const match = GREP_MATCH_ROW.exec(line);
		if (match) {
			rows.push({ path: match[1], line: Number(match[2]), text: match[3], isMatch: true });
			continue;
		}
		const context = GREP_CONTEXT_ROW.exec(line);
		if (context) {
			rows.push({ path: context[1], line: Number(context[2]), text: context[3], isMatch: false });
			continue;
		}
		// Unparseable and not a notice: nothing to keep either way.
		if (isBuiltinNotice(line)) {
			continue;
		}
	}
	return rows;
}

/** @param row a row parsed by {@link parseGrepOutput} */
function formatGrepRow(row: GrepRow): string {
	return row.isMatch ? `${row.path}:${row.line}: ${row.text}` : `${row.path}-${row.line}- ${row.text}`;
}

/**
 * Keep a rebuilt result inside the builtin's 50KB budget, cutting at a line
 * boundary so no row is left half-printed.
 *
 * @param text the rebuilt output
 */
function capGrepBytes(text: string): string {
	// TextEncoder/TextDecoder, not Buffer: the extension must not depend on a Node
	// global that some host runtimes do not expose.
	const bytes = new TextEncoder().encode(text);
	if (bytes.length <= GREP_MAX_BYTES) {
		return text;
	}
	const head = new TextDecoder().decode(bytes.subarray(0, GREP_MAX_BYTES));
	const lastNewline = head.lastIndexOf("\n");
	const kept = lastNewline > 0 ? head.slice(0, lastNewline) : head;
	return `${kept}\n\n${GREP_BYTES_NOTICE}`;
}

/**
 * Drop the leading `./` segments, exactly as the builtin find does before it
 * matches.
 *
 * @param pattern a find glob
 */
function normalizeFindPattern(pattern: string): string {
	return pattern.replace(/^(?:\.\/)+/, "");
}

/**
 * Widen a relative path pattern to the "matches at any depth" reading.
 *
 * pi 1.6.0 hands a relative path pattern to `fd --full-path` anchored at the
 * search root, so `src/*.ts` never matches `pkg/src/a.ts` (pi #12066). That is
 * the default this tool keeps (`rooted: true`); `rooted: false` asks for the
 * wider reading, which is what the double-star prefix produces. Absolute
 * patterns are handed to fd as given and are left alone.
 *
 * @param pattern a find glob
 */
function widenFindPattern(pattern: string): string {
	const normalized = normalizeFindPattern(pattern);
	if (path.isAbsolute(normalized) || !normalized.includes("/") || normalized.startsWith("**/")) {
		return normalized;
	}
	return `**/${normalized}`;
}

/**
 * The literal leading directory of a glob: everything before its first `*`, `?`,
 * `[` or `{`, cut back to the last `/`. An empty result means "no rooting" — a
 * pattern that starts with a wildcard (a leading double-star, or `*.ts`)
 * searches everywhere by construction.
 *
 * @param pattern a find glob
 */
function findLiteralDir(pattern: string): string {
	const normalized = normalizeFindPattern(pattern);
	let end = normalized.length;
	for (let index = 0; index < normalized.length; index++) {
		if ("*?[{".includes(normalized[index])) {
			end = index;
			break;
		}
	}
	const slash = normalized.slice(0, end).lastIndexOf("/");
	const dir = slash >= 0 ? normalized.slice(0, slash).replace(/\/+$/, "") : "";
	return dir === "." ? "" : dir;
}

/**
 * Parse the builtin find's text output. Blank lines, `No files found matching
 * pattern` and the trailing notice block are dropped; a path that starts with
 * `[` (`[slug].tsx`) is kept.
 *
 * @param text the builtin's `content[*].text`
 */
function parseFindOutput(text: string): string[] {
	const paths: string[] = [];
	for (const line of text.split("\n")) {
		if (line === "" || line === FIND_NO_FILES || isBuiltinNotice(line)) {
			continue;
		}
		paths.push(line);
	}
	return paths;
}

const GUIDELINES: Record<string, string[]> = {
	grep: ["Use grep to search file contents instead of bash grep/rg/git grep; its output is capped and tells you how to widen the search."],
	find: ["Use find to locate files by glob instead of bash find/ls; a path pattern such as 'tests/*.lua' is rooted at the search directory."],
	ls: ["Use ls to list a directory instead of bash ls/tree."],
};

export default function searchTools(pi: ExtensionAPI) {
	pi.on("before_agent_start", (event) => {
		const active = new Set(pi.getActiveTools());
		const options = event.systemPromptOptions;
		if (active.has("bash")) {
			options.toolSnippets.bash = BASH_SNIPPET;
			// bash ships its own guidelines, so the search rule is appended to them.
			// Idempotent: the options object is reused across turns, and a second copy
			// of the rule would keep growing the prompt (and its cache prefix).
			const rules = options.toolGuidelines.bash ?? [];
			if (!rules.includes(BASH_RULE)) {
				options.toolGuidelines.bash = [...rules, BASH_RULE];
			}
		}
		for (const [name, rules] of Object.entries(GUIDELINES)) {
			if (!active.has(name)) {
				continue;
			}
			// Replace (do not append): the builtin grep/find/ls carry no guidelines, and
			// a per-turn append would duplicate them on every request.
			options.toolGuidelines[name] = [...rules];
		}
	});

	// ------------------------------------------------------------------
	// grep: the builtin, plus output modes / exclude / per-file cap / word.
	// ------------------------------------------------------------------
	const builtinGrep = createGrepToolDefinition(process.cwd());

	// The spread is runtime-exact (every builtin parameter survives) but types as a
	// plain Record, so pin the static shape for Static<>.
	const grepParameters = Type.Object({
		...(builtinGrep.parameters as unknown as { properties: Record<string, TSchema> }).properties,
		output: Type.Optional(
			Type.Union([Type.Literal("content"), Type.Literal("files"), Type.Literal("count")], {
				description:
					"Output shape: 'content' (default, matching lines), 'files' (matching file paths only, de-duplicated) or 'count' (one 'path:N' line per file).",
			}),
		),
		exclude: Type.Optional(
			Type.Array(Type.String(), {
				description:
					"Glob patterns to drop from the results, e.g. ['dist/**', '*.min.js']. A pattern without '/' matches a file name at any depth.",
			}),
		),
		max_per_file: Type.Optional(
			Type.Number({
				description: "Keep at most this many matches per file (the first ones, in file order).",
				minimum: 1,
			}),
		),
		word: Type.Optional(
			Type.Boolean({
				description:
					"Match the pattern as a whole word (wraps it as \\b(?:pattern)\\b). With literal: true the pattern is escaped first, so `foo.bar` matches only `foo.bar`.",
			}),
		),
	}) as unknown as Type.TObject<{
		pattern: Type.TString;
		path: Type.TOptional<Type.TString>;
		glob: Type.TOptional<Type.TString>;
		ignoreCase: Type.TOptional<Type.TBoolean>;
		literal: Type.TOptional<Type.TBoolean>;
		context: Type.TOptional<Type.TNumber>;
		limit: Type.TOptional<Type.TNumber>;
		output: Type.TOptional<Type.TUnion<[Type.TLiteral<"content">, Type.TLiteral<"files">, Type.TLiteral<"count">]>>;
		exclude: Type.TOptional<Type.TArray<Type.TString>>;
		max_per_file: Type.TOptional<Type.TNumber>;
		word: Type.TOptional<Type.TBoolean>;
	}>;

	const grep: ToolDefinition<typeof grepParameters, GrepToolDetails | undefined> = {
		...builtinGrep,
		description: `${builtinGrep.description}\n\n${GREP_NOTE}`,
		parameters: grepParameters,
		async execute(toolCallId, params, signal, onUpdate, ctx) {
			const raw = params as unknown as GrepParams;
			const callerLimit = Math.max(1, Math.floor(raw.limit ?? GREP_DEFAULT_LIMIT));
			// Every call is post-processed — there is deliberately no fast path: the
			// `.git` filter below must apply to a plain search too.
			// The post-filters below run after ripgrep, so ask for a wider window than the
			// caller's limit: otherwise the cap would be spent on rows we then drop.
			const internalLimit = Math.min(
				GREP_MAX_INTERNAL_LIMIT,
				Math.max(callerLimit, GREP_MIN_INTERNAL_LIMIT) * 5,
			);
			// `literal` would hand ripgrep `\b(?:x)\b` as fixed text, which can never match,
			// so a whole-word match on a literal pattern escapes the text itself instead.
			const wholeWord = raw.word === true;
			const delegated: GrepToolInput = {
				...raw,
				pattern: wholeWord
					? `\\b(?:${raw.literal === true ? escapeRegExp(raw.pattern) : raw.pattern})\\b`
					: raw.pattern,
				literal: wholeWord ? false : raw.literal,
				limit: internalLimit,
			};
			const result = await builtinGrep.execute(toolCallId, delegated, signal, onUpdate, ctx);
			const text = result.content?.map((block) => (block.type === "text" ? block.text : "")).join("\n") ?? "";
			const rows = parseGrepOutput(text);

			const globs: CompiledGlob[] = [];
			for (const glob of raw.exclude ?? []) {
				if (typeof glob === "string" && glob !== "") {
					globs.push(compileGlob(glob));
				}
			}
			const maxPerFile = raw.max_per_file === undefined ? undefined : Math.max(1, Math.floor(raw.max_per_file));
			const perFile = new Map<string, number>();
			const filtered: GrepRow[] = [];
			let matchCount = 0;
			for (const row of rows) {
				// `.git` first, always: ripgrep runs with --hidden.
				if (isUnderGit(row.path)) {
					continue;
				}
				const basename = row.path.slice(row.path.lastIndexOf("/") + 1);
				const excluded = globs.some(
					(glob) => glob.re.test(row.path) || (glob.basenameOnly && glob.re.test(basename)),
				);
				if (excluded) {
					continue;
				}
				// Only matches spend the per-file budget; a context line rides along.
				if (row.isMatch && maxPerFile !== undefined) {
					const seen = perFile.get(row.path) ?? 0;
					if (seen >= maxPerFile) {
						continue;
					}
					perFile.set(row.path, seen + 1);
				}
				if (row.isMatch) {
					matchCount++;
				}
				filtered.push(row);
			}

			// The delegate was asked for a wider window, so the caller's own limit is applied
			// here, to matches only. The first match past the limit ends the list, which takes
			// that match's context rows with it (they describe a row that is not shown).
			const kept: GrepRow[] = [];
			let shown = 0;
			for (const row of filtered) {
				if (row.isMatch) {
					if (shown >= callerLimit) {
						break;
					}
					shown++;
				}
				kept.push(row);
			}
			// Either the builtin hit its own (wider) window, or the caller's limit cut the list.
			const capped = result.details?.matchLimitReached != null || matchCount >= callerLimit;

			const mode: GrepOutputMode = raw.output ?? "content";
			let body = GREP_NO_MATCHES;
			if (kept.length > 0 && mode === "files") {
				const seen = new Set<string>();
				const paths: string[] = [];
				for (const row of kept) {
					if (row.isMatch && !seen.has(row.path)) {
						seen.add(row.path);
						paths.push(row.path);
					}
				}
				body = paths.length > 0 ? paths.join("\n") : GREP_NO_MATCHES;
			} else if (kept.length > 0 && mode === "count") {
				const counts = new Map<string, number>();
				for (const row of kept) {
					if (row.isMatch) {
						counts.set(row.path, (counts.get(row.path) ?? 0) + 1);
					}
				}
				body = counts.size > 0 ? [...counts].map(([filePath, count]) => `${filePath}:${count}`).join("\n") : GREP_NO_MATCHES;
			} else if (kept.length > 0) {
				body = kept.map(formatGrepRow).join("\n");
			}
			const withNotices =
				body +
				(capped
					? `\n\n[${callerLimit} matches limit reached. Use limit=${callerLimit * 2} for more, or refine pattern]`
					: "") +
				// The builtin still owns these two: re-emitting its text must not lose them.
				(result.details?.truncation?.truncated === true ? `\n\n${GREP_BYTES_NOTICE}` : "") +
				(result.details?.linesTruncated === true ? `\n\n${GREP_LINES_NOTICE}` : "");
			return {
				content: [{ type: "text" as const, text: capGrepBytes(withNotices) }],
				details: capped ? { ...(result.details ?? {}), matchLimitReached: callerLimit } : result.details,
			};
		},
	};
	pi.registerTool(grep);

	// ------------------------------------------------------------------
	// find: the builtin, plus rooted / sort.
	// ------------------------------------------------------------------
	const builtinFind = createFindToolDefinition(process.cwd());

	// Same runtime-exact spread as grep; the static shape is pinned for Static<>.
	const findParameters = Type.Object({
		...(builtinFind.parameters as unknown as { properties: Record<string, TSchema> }).properties,
		rooted: Type.Optional(
			Type.Boolean({
				description:
					"Anchor a relative path pattern at the search directory (default: true, as pi 1.6 does). Set false to match it at any depth, so 'tests/*.lua' also finds 'pkg/tests/a.lua'. Absolute patterns are always matched as given.",
			}),
		),
		sort: Type.Optional(
			Type.Union([Type.Literal("path"), Type.Literal("mtime")], {
				description: "Result order: 'path' (default, lexicographic) or 'mtime' (newest first).",
			}),
		),
	}) as unknown as Type.TObject<{
		pattern: Type.TString;
		path: Type.TOptional<Type.TString>;
		limit: Type.TOptional<Type.TNumber>;
		rooted: Type.TOptional<Type.TBoolean>;
		sort: Type.TOptional<Type.TUnion<[Type.TLiteral<"path">, Type.TLiteral<"mtime">]>>;
	}>;

	const find: ToolDefinition<typeof findParameters, FindToolDetails | undefined> = {
		...builtinFind,
		description: `${builtinFind.description}\n\n${FIND_NOTE}`,
		parameters: findParameters,
		async execute(toolCallId, params, signal, onUpdate, ctx) {
			const raw = params as unknown as FindParams;
			const rooted = raw.rooted !== false && !path.isAbsolute(normalizeFindPattern(raw.pattern));
			const sort: FindSort = raw.sort ?? "path";
			const limit = Math.max(1, Math.floor(raw.limit ?? FIND_DEFAULT_LIMIT));
			// The post-filters below drop paths, so ask fd for a wider window than the
			// caller's limit: a cap spent on dropped paths would under-report.
			const internalLimit = Math.min(
				FIND_MAX_INTERNAL_LIMIT,
				Math.max(limit, FIND_MIN_INTERNAL_LIMIT) * 5,
			);
			const delegated: FindToolInput = { ...raw, pattern: widenFindPattern(raw.pattern), limit: internalLimit };
			const result = await builtinFind.execute(toolCallId, delegated, signal, onUpdate, ctx);
			const text = result.content?.map((block) => (block.type === "text" ? block.text : "")).join("\n") ?? "";

			// `.git` first, always: fd runs with --hidden.
			let paths = parseFindOutput(text).filter((filePath) => !isUnderGit(filePath));
			if (rooted) {
				const literalDir = findLiteralDir(raw.pattern);
				if (literalDir !== "") {
					paths = paths.filter((filePath) => filePath === literalDir || filePath.startsWith(`${literalDir}/`));
				}
			}

			if (sort === "mtime") {
				// The paths are relative to the *search* root (fd is run there and the builtin
				// relativizes against it), so the stat join must use that root, not the cwd.
				const root = path.resolve(ctx?.cwd ?? process.cwd(), raw.path ?? ".");
				const stamps = new Map<string, number>();
				await Promise.all(
					paths.map(async (filePath) => {
						try {
							const stat = await fs.promises.stat(path.join(root, filePath));
							stamps.set(filePath, stat.mtimeMs);
						} catch {
							// A path fd listed but stat cannot see is not "newest": sort it last.
							stamps.set(filePath, 0);
						}
					}),
				);
				paths.sort((a, b) => (stamps.get(b) ?? 0) - (stamps.get(a) ?? 0) || a.localeCompare(b));
			} else {
				paths.sort((a, b) => a.localeCompare(b));
			}

			// Either fd hit the builtin's own (wider) window, or the caller's limit cut the list.
			const capped = result.details?.resultLimitReached != null || paths.length > limit;
			const kept = capped ? paths.slice(0, limit) : paths;
			const body = kept.length > 0 ? kept.join("\n") : FIND_NO_FILES;
			const withNotices =
				body +
				(capped ? `\n\n[${limit} results limit reached. Use limit=${limit * 2} for more, or refine pattern]` : "") +
				// The builtin still owns this one: re-emitting its text must not lose it.
				(result.details?.truncation?.truncated === true ? `\n\n${FIND_BYTES_NOTICE}` : "");
			return {
				content: [{ type: "text" as const, text: withNotices }],
				details: capped ? { ...(result.details ?? {}), resultLimitReached: limit } : result.details,
			};
		},
	};
	pi.registerTool(find);
}
