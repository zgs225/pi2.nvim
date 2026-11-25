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
 *      description that no longer advertises grep/find, and the grep/find/ls
 *      rules are *replaced* (not appended) in `sections.rules`. Replacement
 *      matters: these tools ship no guidelines, so appending would duplicate
 *      the bullets on every request.
 *   2. registerTool — override the bash declaration itself, so the tool's
 *      `description` (what the request's `tools` array carries) stops telling
 *      the model to grep. `...builtin` is essential: it carries
 *      outputSchema, constrainedSampling, the renderers and prepareArguments,
 *      so only the prompt-facing strings change.
 *
 *   3. registerTool for `grep` — the builtin grep only answers "matching lines".
 *      Four extra parameters (`output`, `exclude`, `max_per_file`, `word`) cover
 *      the questions a model otherwise shells out to `rg`/`grep -c`/`grep -l`
 *      for. The search itself is never re-implemented: the builtin runs first
 *      and its text output is parsed, filtered and re-emitted, so ripgrep's
 *      auto-download, the 50KB/500-char caps, `details` and path relativization
 *      all stay pi's. Every call is post-processed (there is deliberately no
 *      fast path), because rows under `.git/` are always dropped: ripgrep runs
 *      with `--hidden` and would otherwise hand the model `.git/logs/HEAD`.
 */

import type { ExtensionAPI, GrepToolDetails, GrepToolInput, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { createBashToolDefinition, createGrepToolDefinition } from "@earendil-works/pi-coding-agent";
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
 * Parse the builtin grep's text output. Both row forms survive verbatim: match
 * rows (`path:line: text`, the ones `max_per_file` counts) and the context rows
 * ripgrep emits for `context > 0` (`path-line- text`, which it must never
 * count). The trailing `[notice]` block and `No matches found` are dropped.
 */
function parseGrepOutput(text: string): GrepRow[] {
	const notice = text.indexOf("\n\n[");
	const body = notice >= 0 ? text.slice(0, notice) : text;
	const rows: GrepRow[] = [];
	for (const line of body.split("\n")) {
		if (line === "" || line === GREP_NO_MATCHES || line.startsWith("[")) {
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

	const builtin = createBashToolDefinition(process.cwd());
	const bash: ToolDefinition = {
		...builtin,
		description: `${builtin.description}\n\n${BASH_RULE}`,
		promptSnippet: BASH_SNIPPET,
		promptGuidelines: [...(builtin.promptGuidelines ?? []), BASH_RULE],
	};
	pi.registerTool(bash);

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
				description: "Match the pattern as a whole word (wraps it as \\b(?:pattern)\\b).",
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
			// Every call is post-processed — there is deliberately no fast path: the
			// `.git` filter below must apply to a plain search too.
			// The post-filters below run after ripgrep, so ask for a wider window than the
			// caller's limit: otherwise the cap would be spent on rows we then drop.
			const internalLimit = Math.min(
				GREP_MAX_INTERNAL_LIMIT,
				Math.max(raw.limit ?? GREP_DEFAULT_LIMIT, GREP_MIN_INTERNAL_LIMIT) * 5,
			);
			const delegated: GrepToolInput = {
				...raw,
				pattern: raw.word === true ? `\\b(?:${raw.pattern})\\b` : raw.pattern,
				limit: internalLimit,
			};
			const result = await builtinGrep.execute(toolCallId, delegated, signal, onUpdate, ctx);
			const text = result.content?.map((block) => (block.type === "text" ? block.text : "")).join("\n") ?? "";
			const rows = parseGrepOutput(text);
			// Only a full window of matches proves the cap cut results off (context rows
			// do not count towards the builtin's limit either).
			const capped = rows.filter((row) => row.isMatch).length >= internalLimit;

			const globs: CompiledGlob[] = [];
			for (const glob of raw.exclude ?? []) {
				if (typeof glob === "string" && glob !== "") {
					globs.push(compileGlob(glob));
				}
			}
			const maxPerFile = raw.max_per_file === undefined ? undefined : Math.max(1, Math.floor(raw.max_per_file));
			const perFile = new Map<string, number>();
			const kept: GrepRow[] = [];
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
				kept.push(row);
			}

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
			const withLimitNotice = capped
				? `${body}\n\n[${internalLimit} matches limit reached. Use a narrower pattern, exclude or glob for more.]`
				: body;
			return {
				content: [{ type: "text" as const, text: capGrepBytes(withLimitNotice) }],
				details: capped ? { ...(result.details ?? {}), matchLimitReached: internalLimit } : result.details,
			};
		},
	};
	pi.registerTool(grep);
}
