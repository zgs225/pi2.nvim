/**
 * Sub-agent worker note for pi.nvim child (sub-session) processes.
 *
 * Loaded into child RPC processes only — parent sessions load
 * extensions/subagent.ts instead, and `subagent.enabled = false` loads
 * neither (see lua/pi/cli.lua). The child has no sub-agent tools and no
 * host bridge; this extension's only job is to append a worker note to the
 * system prompt on every turn (before_agent_start).
 *
 * Prompt-cache friendly: the note is byte-constant, so the prompt prefix stays
 * stable across turns — same rationale as extensions/vision.ts CAPABILITY_NOTE.
 * The per-task brief travels in the conversation as the child's first user
 * message, not in the system prompt.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * Appended to the child system prompt per turn (before_agent_start).
 * Declares the worker contract: no interactive user, the last assistant
 * message is the final report, no questions, strict task scope, no nested
 * sub-agents, and how that report must be shaped (in-message, absolute
 * paths, outcome first, trailing STATUS marker). Keep it static (see file
 * header) — the reporting rules are plain text too, never interpolated, so
 * the note stays a byte-constant prefix across turns.
 */
const WORKER_NOTE = [
	"You are a sub-agent worker session (pi.nvim):",
	"- There is no interactive user: a parent agent reads your output and nobody can answer questions. Never ask for clarification — make reasonable assumptions and state them.",
	"- Your last assistant message is your final report to the parent: make it complete and self-contained — findings, changed files, open issues.",
	"- Stay strictly within the given task: no scope expansion, no unrelated refactoring, no follow-up work; report blockers instead.",
	"- You cannot spawn or manage sub-agents; do all the work yourself.",
	"- Write the report in your last message, not in a file: do not write the report to a file and point at it; the parent reads your last message only, so a file it never opens is a report you never delivered.",
	"- Give absolute file paths, never relative ones; the parent resolves them against its own working directory.",
	"- Lead with the outcome, then the evidence; stay under roughly 200 words unless the task asked for detail.",
	"- End the report with exactly one status line, one of: STATUS: ok, STATUS: blocked, STATUS: failed. Use blocked when you are unsure and say what you are stuck on.",
].join("\n");

export default function subagentChild(pi: ExtensionAPI): void {
	pi.on("before_agent_start", (event) => {
		return { systemPrompt: `${event.systemPrompt}\n\n${WORKER_NOTE}` };
	});
}
