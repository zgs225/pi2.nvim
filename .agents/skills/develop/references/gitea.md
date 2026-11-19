# Gitea issues — `tea` when present, `scripts/gitea_issue.py` otherwise

**This repo's issue tracker lives exclusively on Gitea (`git.yuez.me/yuez/pi2.nvim`). GitHub is a public mirror only; do not open or leave personal development issues there. If one is accidentally created on GitHub, migrate it here and delete the GitHub copy (see the "Migrate from GitHub" row below).**

**Never hand-roll curl against the API.** Labels and state must be set through one
reproducible entry point so the lifecycle stays scriptable and reviewable. There
are two such entry points, and which one you use depends on one check:

```bash
command -v tea     # present → use tea; absent → use scripts/gitea_issue.py
```

`tea` is the preferred interface and is supposed to be installed by eos-bootstrap
(`/usr/bin/tea`). It has been missing on the workstation, and a `go install`ed
build (v1.3.x, config now under `~/.config/gitea-cli/`) does not persist a login,
so verify before relying on it. When it is absent, `scripts/gitea_issue.py` does
the same four operations with the same token — no `tea`, no curl:

```bash
GITEA_TOKEN=... python3 scripts/gitea_issue.py create "title" body.md original,priority:high,review:pending
GITEA_TOKEN=... python3 scripts/gitea_issue.py comment 117 note.md
GITEA_TOKEN=... python3 scripts/gitea_issue.py label 117 +pr:awaiting-review -review:pending
GITEA_TOKEN=... python3 scripts/gitea_issue.py close 117
```

It resolves label **names** to ids for you (`GITEA_URL` / `GITEA_REPO` override
the defaults `https://git.yuez.me` and `yuez/pi2.nvim`). Both paths use the same
`GITEA_TOKEN`.

## Login

Token lives in the chezmoi-encrypted `~/.zshrc.local` as `GITEA_TOKEN`; export it
before running either tool.

```bash
tea login add --url https://git.yuez.me --token "$GITEA_TOKEN" --name yuez
tea whoami   # verify
```

Outside a repo checkout, always pass `-r yuez/pi2.nvim`; inside the repo `tea`
discovers the repo from the git remote (which is GitHub here, so pass `-r` when in
doubt).

## Issue lifecycle cheat sheet

| Action | `tea` | `scripts/gitea_issue.py` |
|--------|-------|--------------------------|
| Create | `tea issue create -r yuez/pi2.nvim -t "<title>" -d "$(cat body.md)" -L "original,priority:low,review:pending"` | `… create "<title>" body.md original,priority:low,review:pending` |
| Migrate from GitHub (Gitea is the source of truth) | recreate on Gitea, then `gh issue delete --repo zgs225/pi2.nvim <gh-number> --yes` | same, with `… create` |
| List | `tea issue list -r yuez/pi2.nvim` | (read-only; `tea` or the web UI) |
| Show one | `tea issue show -r yuez/pi2.nvim <index>` | web UI |
| Comment (implementation notes) | `tea comments add -r yuez/pi2.nvim <index> "note"` | `… comment <index> note.md` |
| Add labels (triage → approved) | `tea issue edit -r yuez/pi2.nvim <index> -L "review:approved"` | `… label <index> +review:approved` |
| Swap labels | `tea issue edit -r yuez/pi2.nvim <index> -L "pr:awaiting-review" --remove-labels "review:pending"` | `… label <index> +pr:awaiting-review -review:pending` |
| Close | `tea issue close -r yuez/pi2.nvim <index>` | `… close <index>` |
| Reopen | `tea issue open -r yuez/pi2.nvim <index>` | web UI |

## Conventions

- Issue **body is the spec** — never overwrite it (editing the body is for typos
  only). Implementation notes go in **comments**.
- Labels: type `original` (Neovim-specific feature) / `rpc` (pi RPC protocol),
  `priority:{high,medium,low}`, review gate `review:pending` → `review:approved` →
  `pr:awaiting-review` / `pr:changes-requested` / `pr:approved`.
- Multiline bodies: write a temp file and pass its path (`-d "$(cat body.md)"` for
  `tea`; the file path directly for the script).
