/**
 * Sub-agent worker note for pi.nvim child (sub-session) processes.
 *
 * Loaded into child RPC processes only — parent sessions load
 * extensions/subagent.ts instead, and `subagent.enabled = false` loads
 * neither (see lua/pi/cli.lua). The child has no sub-agent tools and no
 * host bridge; this extension's only job is to append a worker note to the
 * system prompt on every turn (before_agent_start).
 *
 * Prompt-cache friendly: the note is either byte-constant or constant for the
 * whole process. The worktree paragraph is derived once per process from
 * `PI_NVIM_WORKTREE_PATH` (set by lua/pi/rpc.lua from the session's worktree),
 * so the prompt prefix stays stable across turns — same rationale as
 * extensions/vision.ts CAPABILITY_NOTE. The per-task brief travels in the
 * conversation as the child's first user message, not in the system prompt.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Appended to the child system prompt per turn (before_agent_start).
 * Declares the worker contract: no interactive user, the last assistant
 * message is the final report, no questions, strict task scope, and no
 * nested sub-agents. Keep it static (see file header).
 */
const WORKER_NOTE = [
	"You are a sub-agent worker session (pi.nvim):",
	"- There is no interactive user: a parent agent reads your output and nobody can answer questions. Never ask for clarification — make reasonable assumptions and state them.",
	"- Your last assistant message is your final report to the parent: make it complete and self-contained — findings, changed files, open issues.",
	"- Stay strictly within the given task: no scope expansion, no unrelated refactoring, no follow-up work; report blockers instead.",
	"- You cannot spawn or manage sub-agents; do all the work yourself.",
].join("\n");

/** Env var carrying the child's isolated worktree path (lua/pi/rpc.lua). */
const WORKTREE_ENV = "PI_NVIM_WORKTREE_PATH";

/**
 * Worktree paragraph, appended only when this child runs in an isolated
 * checkout. States the cwd and forbids nested worktrees — the parent owns the
 * worktree lifecycle, and a nested checkout would never be released.
 *@param path Isolated worktree root (`PI_NVIM_WORKTREE_PATH`).
 */
function worktreeNote(path: string): string {
	return [
		`You are running inside an isolated git worktree at ${path}.`,
		"- That directory is your working directory: read, edit and run commands there, never in the parent check-out, and do not switch branches.",
		"- Do not create nested git worktrees or sub-sessions; the parent owns worktree lifecycle and cleanup.",
	].join("\n");
}

/**
 * Suffix appended after WORKER_NOTE: the worktree paragraph when this process
 * runs in an isolated checkout, the empty string (byte-identical prompt to the
 * pre-worktree behavior) otherwise.
 */
function worktreeSuffix(): string {
	const path = process.env[WORKTREE_ENV];
	if (!path) {
		return "";
	}
	return `\n\n${worktreeNote(path)}`;
}

export default function subagentChild(pi: ExtensionAPI): void {
	pi.on("before_agent_start", (event) => {
		const note = WORKER_NOTE + worktreeSuffix();
		return { systemPrompt: `${event.systemPrompt}\n\n${note}` };
	});
}
