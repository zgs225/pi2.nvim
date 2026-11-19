# Gitea issues — `gt` (gitea-cli)

**This repo's issue tracker lives exclusively on Gitea (`git.yuez.me/yuez/pi2.nvim`). GitHub is a public mirror only; do not open or leave personal development issues there. If one is accidentally created on GitHub, migrate it here and delete the GitHub copy (see the "Migrate from GitHub" row below).**

All issue interaction goes through **`gt`** — gitea-cli 1.2.0, installed system-wide at
`/usr/bin/gt`. `tea` is gone: gitea-cli replaced it (upstream moved to
`gitea.com/gitea/cli`, the binary is now `gt`, and its config lives in
`~/.config/gitea-cli/`). Do not invoke `tea`, and **never hand-roll curl against
the API** — labels and state must be set through `gt` so commands stay
reproducible.

## Auth

The token is stored in the **keyring** and `gt auth status` is the check:

```bash
gt auth status
# https://git.yuez.me  yuez  true  token  keyring  true   <- last column: can authenticate
```

**Pitfall — an exported `GITEA_TOKEN` breaks `gt`.** `gt` prefers the environment
token over the keyring and then demands to know which instance it belongs to:

```text
Error: GITEA_TOKEN requires GITEA_CLI_HOST or GITEA_INSTANCE_URL naming its instance
```

Either name the instance for the session, or fall back to the keyring credential:

```bash
export GITEA_INSTANCE_URL=https://git.yuez.me     # keep using $GITEA_TOKEN
env -u GITEA_TOKEN gt issue view 117 -R yuez/pi2.nvim   # or use the keyring
```

**Repo discovery:** the git remote here is the GitHub mirror, so `gt` will not
find the Gitea repo by itself — pass `-R yuez/pi2.nvim` (it is an inherited flag
on every `gt issue` command). Multiline bodies come from a file (`-F body.md`,
or `-F -` for stdin), never from shell quoting.

## Issue lifecycle cheat sheet

| Action | Command |
|--------|---------|
| Create | `gt issue create -R yuez/pi2.nvim -t "<title>" -F body.md -l original -l priority:low -l review:pending` |
| Migrate from GitHub | recreate here with the line above, then `gh issue delete --repo zgs225/pi2.nvim <gh-number> --yes` |
| List | `gt issue list -R yuez/pi2.nvim` (`-s all`, `-l label` to filter, `-L <n>` to limit) |
| Show one | `gt issue view -R yuez/pi2.nvim <index>` |
| Timeline | `gt issue timeline -R yuez/pi2.nvim <index>` |
| Comment (implementation notes) | `gt issue comment -R yuez/pi2.nvim <index> -F note.md` |
| Add a label (triage → approved) | `gt issue edit -R yuez/pi2.nvim <index> --add-label review:approved` |
| Swap labels | `gt issue edit -R yuez/pi2.nvim <index> --add-label pr:awaiting-review --remove-label review:pending` |
| Close | `gt issue close -R yuez/pi2.nvim <index>` (`-c "note"` comments first) |
| Reopen | `gt issue reopen -R yuez/pi2.nvim <index>` |

Notes: `-l` / `--add-label` take label **names** (no id mapping, and names must
exist in the repo — see `gt label list -R yuez/pi2.nvim`). `--dry-run` prints the
write requests without sending them, which is the cheapest way to check a
composite command.

## Conventions

- Issue **body is the spec** — never overwrite it (`gt issue edit -F` is for
  typos only). Implementation notes go in **comments**.
- Labels: type `original` (Neovim-specific feature) / `rpc` (pi RPC protocol),
  `priority:{high,medium,low}`, review gate `review:pending` → `review:approved` →
  `pr:awaiting-review` / `pr:changes-requested` / `pr:approved`.
