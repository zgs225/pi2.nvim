#!/usr/bin/env python3
"""Issue operations against this repo's Gitea tracker, without `tea`.

`tea` is the documented interface (see `.agents/skills/develop/references/gitea.md`)
and this script is the fallback for when it is not installed on the box — it uses
the same token (`GITEA_TOKEN`, from the chezmoi-encrypted shell env) and the same
API, and covers exactly the four operations the issue lifecycle needs. Never
hand-roll curl: labels and state must go through one reproducible entry point.

    GITEA_TOKEN=... python3 scripts/gitea_issue.py create "title" body.md original,priority:high,review:pending
    GITEA_TOKEN=... python3 scripts/gitea_issue.py comment 117 note.md
    GITEA_TOKEN=... python3 scripts/gitea_issue.py label 117 +pr:awaiting-review -review:pending
    GITEA_TOKEN=... python3 scripts/gitea_issue.py close 117

Environment: `GITEA_TOKEN` (required), `GITEA_URL` (default https://git.yuez.me),
`GITEA_REPO` (default yuez/pi2.nvim).
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional

BASE = os.environ.get("GITEA_URL", "https://git.yuez.me").rstrip("/")
REPO = os.environ.get("GITEA_REPO", "yuez/pi2.nvim")
API = f"{BASE}/api/v1"


def _request(method: str, path: str, payload: Optional[Dict[str, Any]] = None) -> Any:
    token = os.environ.get("GITEA_TOKEN")
    if not token:
        raise SystemExit("GITEA_TOKEN is not set (see .agents/skills/develop/references/gitea.md)")
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        f"{API}{path}",
        data=data,
        headers={"Content-Type": "application/json", "Authorization": f"token {token}"},
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:600]
        raise SystemExit(f"{method} {path} → HTTP {exc.code}: {detail}") from exc
    return json.loads(body) if body else None


def _label_ids(names: List[str]) -> List[int]:
    """Resolve label names to ids (the issue endpoints take ids, not names)."""
    existing = {label["name"]: label["id"] for label in _request("GET", f"/repos/{REPO}/labels") or []}
    missing = [name for name in names if name not in existing]
    if missing:
        raise SystemExit(f"unknown label(s): {', '.join(missing)}\nknown: {', '.join(sorted(existing))}")
    return [existing[name] for name in names]


def cmd_create(args: List[str]) -> None:
    if len(args) < 2:
        raise SystemExit("usage: create <title> <body.md> [label,label,...]")
    title, body_file = args[0], args[1]
    labels = [name for name in (args[2] if len(args) > 2 else "").split(",") if name]
    payload: Dict[str, Any] = {"title": title, "body": open(body_file, encoding="utf-8").read()}
    if labels:
        payload["labels"] = _label_ids(labels)
    issue = _request("POST", f"/repos/{REPO}/issues", payload)
    print(f"#{issue['number']} {issue['html_url']}")


def cmd_comment(args: List[str]) -> None:
    if len(args) < 2:
        raise SystemExit("usage: comment <index> <body.md>")
    index, body_file = args[0], args[1]
    body = open(body_file, encoding="utf-8").read()
    _request("POST", f"/repos/{REPO}/issues/{index}/comments", {"body": body})
    print(f"commented on #{index}")


def cmd_label(args: List[str]) -> None:
    if len(args) < 2:
        raise SystemExit("usage: label <index> +name,-name,...")
    index, spec = args[0], args[1]
    add = [entry[1:] for entry in spec.split(",") if entry.startswith("+")]
    remove = [entry[1:] for entry in spec.split(",") if entry.startswith("-")]
    issue = _request("GET", f"/repos/{REPO}/issues/{index}")
    keep = [label["id"] for label in issue.get("labels", []) if label["name"] not in set(remove)]
    labels = keep + _label_ids(add)
    _request("PATCH", f"/repos/{REPO}/issues/{index}", {"labels": labels})
    print(f"#{index} labels: {' '.join(sorted(set(keep + _label_ids(add))))}")


def cmd_close(args: List[str]) -> None:
    if not args:
        raise SystemExit("usage: close <index>")
    _request("PATCH", f"/repos/{REPO}/issues/{args[0]}", {"state": "closed"})
    print(f"closed #{args[0]}")


COMMANDS = {"create": cmd_create, "comment": cmd_comment, "label": cmd_label, "close": cmd_close}


def main(argv: List[str]) -> int:
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        return 2
    COMMANDS[argv[1]](argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
