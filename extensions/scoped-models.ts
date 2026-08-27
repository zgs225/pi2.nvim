/**
 * pi.nvim model-scope bridge.
 *
 * pi resolves `--models` / `enabledModels` (settings.json) into a session
 * model scope (`ctx.scopedModels`, pi 0.83.0+), which the TUI uses for both
 * cycling and its model picker. The RPC protocol never exposes that list —
 * `get_available_models` returns the full catalogue and `get_state` only a
 * boolean `isScoped` — so frontends cannot mirror "scoped > all" pickers.
 *
 * This bridge serializes the resolved scope to a runtime file on every
 * session_start. pi.nvim reads it when :PiSelectModel falls back from its own
 * `config.models` to the backend scope, matching the cycle command and TUI.
 * The scope is process-stable in RPC mode (only /scoped-models rewrites it,
 * which has no caller here), so writing once per session_start is enough;
 * the file is per-tab (project settings may differ across session cwds) and
 * removed by pi.nvim before each spawn to avoid stale reads.
 *
 * Outside pi.nvim the env var is unset: the extension is a no-op.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { writeFileSync } from "node:fs";

const ENV_FILE = "PI_NVIM_SCOPE_FILE";

export default function scopedModelsBridge(pi: ExtensionAPI) {
	pi.on("session_start", (_event, ctx) => {
		const path = process.env[ENV_FILE];
		if (!path) {
			return;
		}
		const scoped = (ctx as unknown as { scopedModels?: unknown }).scopedModels;
		if (!Array.isArray(scoped)) {
			// pi < 0.83.0 or unexpected API shape: stay silent, nvim keeps its
			// config.models / all-models fallbacks.
			return;
		}
		const models: { provider: string; id: string }[] = [];
		for (const entry of scoped) {
			const model = (entry as { model?: { provider?: unknown; id?: unknown } }).model;
			if (model && typeof model.provider === "string" && typeof model.id === "string") {
				models.push({ provider: model.provider, id: model.id });
			}
		}
		try {
			writeFileSync(path, JSON.stringify({ models }));
		} catch {
			// Best-effort reporting; unreadable paths degrade to all-models fallback.
		}
	});
}
