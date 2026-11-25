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
 * Two independent levers, because the model sees both:
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
 */

import type { ExtensionAPI, ToolDefinition } from "@earendil-works/pi-coding-agent";
import { createBashToolDefinition } from "@earendil-works/pi-coding-agent";

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
}
