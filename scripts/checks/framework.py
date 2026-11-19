"""The check framework: findings, the rule registry, the runner, and self-tests.

Three design rules, all of them consequences of past fake-green incidents
(gotcha G25):

* **A missing tool is an error, not a skip.** `run()` raises `CheckError` when a
  binary it needs is absent; the runner exits 2 and prints the remedy. Skipping
  a check because a tool vanished is how a suite reports green while checking
  nothing.
* **Every rule ships a failing fixture.** `self_test()` refuses to pass a rule
  that declares no fixture or whose fixtures do not include both a clean tree
  and a tree that must produce findings. If the gate has never been seen to
  fail, it is not a gate.
* **Findings are `path:line: severity: [rule] message`.** Grep-able, clickable
  in an editor, and stable enough to diff in CI logs.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent / "fixtures"


class CheckError(RuntimeError):
    """A check could not run at all (missing tool, unreadable tree).

    Distinct from a finding: findings mean "the code is wrong", a CheckError
    means "the gate is broken". The runner reports the two with different exit
    codes so CI never confuses them.
    """


@dataclass
class Finding:
    """One violated rule, at one location."""

    check: str
    message: str
    path: str = ""
    line: int = 0
    severity: str = "error"

    def render(self) -> str:
        where = f"{self.path}:{self.line}" if self.line else (self.path or "<repo>")
        return f"{where}: {self.severity}: [{self.check}] {self.message}"

    def as_dict(self) -> dict:
        return {
            "check": self.check,
            "message": self.message,
            "path": self.path,
            "line": self.line,
            "severity": self.severity,
        }


@dataclass
class Fixture:
    """A tree under `fixtures/<rule>/` with the finding count it must produce.

    `expect = 0` proves the rule does not fire on compliant code; `expect > 0`
    proves it fires on the defect it exists for. Both are mandatory.
    """

    name: str
    root: Path
    expect: int
    what: str


class Check:
    """Base class for a rule.

    Subclasses set `name`/`summary`, implement `run`, and declare `fixtures()`.
    Nothing here knows about git, CI, or nvim: `run(root)` takes any directory
    tree, which is what makes the fixtures possible.
    """

    name: str = ""
    summary: str = ""
    requires: Sequence[str] = ()

    def run(self, root: Path) -> list[Finding]:  # pragma: no cover - interface
        raise NotImplementedError

    def fixtures(self) -> list[Fixture]:
        return []

    # -- helpers ---------------------------------------------------------
    def finding(self, message: str, path: str = "", line: int = 0, severity: str = "error") -> Finding:
        return Finding(check=self.name, message=message, path=path, line=line, severity=severity)

    def fixture(self, name: str, expect: int, what: str) -> Fixture:
        return Fixture(name=name, root=FIXTURES / self.name / name, expect=expect, what=what)


def load_checks() -> list[Check]:
    """Import the rule list. Explicit, not discovery-based: reviewers see it."""
    from .rules import ALL

    return list(ALL)


def run_checks(root: Path, only: Sequence[str] | None = None) -> tuple[list[Finding], list[str], int]:
    """Run every (or the selected) check. Returns (findings, errors, checks_run)."""
    checks = load_checks()
    if only:
        unknown = [n for n in only if n not in {c.name for c in checks}]
        if unknown:
            return [], [f"unknown check(s): {', '.join(unknown)} (known: {', '.join(c.name for c in checks)})"], 0
        checks = [c for c in checks if c.name in set(only)]

    findings: list[Finding] = []
    errors: list[str] = []
    for check in checks:
        try:
            findings.extend(check.run(root))
        except CheckError as exc:
            errors.append(f"[{check.name}] {exc}")
        except Exception as exc:  # a broken rule must not look like a clean run
            errors.append(f"[{check.name}] crashed: {type(exc).__name__}: {exc}")
    return findings, errors, len(checks)


def self_test() -> int:
    """Prove each rule both passes clean trees and fails dirty ones.

    Also enforces the meta-rule: a rule with no fixtures, or with fixtures that
    never exercise the failure path, is itself a failure.
    """
    failures: list[str] = []
    checks = load_checks()
    if not checks:
        print("self-test: no checks registered", file=sys.stderr)
        return 1

    for check in checks:
        fixtures = check.fixtures()
        if not fixtures:
            failures.append(f"[{check.name}] declares no fixtures — a gate that cannot fail is not a gate (G25)")
            continue
        if not any(fx.expect == 0 for fx in fixtures):
            failures.append(f"[{check.name}] has no clean fixture (expect=0): cannot prove it stays quiet")
        if not any(fx.expect > 0 for fx in fixtures):
            failures.append(f"[{check.name}] has no failing fixture (expect>0): cannot prove it can fire")

        for fx in fixtures:
            if not fx.root.is_dir():
                failures.append(f"[{check.name}] fixture '{fx.name}' missing: {fx.root}")
                continue
            try:
                got = check.run(fx.root)
            except CheckError as exc:
                failures.append(f"[{check.name}] fixture '{fx.name}' could not run: {exc}")
                continue
            if len(got) != fx.expect:
                rendered = "; ".join(f.render() for f in got) or "none"
                failures.append(
                    f"[{check.name}] fixture '{fx.name}': expected {fx.expect} finding(s), "
                    f"got {len(got)} ({fx.what}) — {rendered}"
                )

    if failures:
        print("self-test: FAIL", file=sys.stderr)
        for line in failures:
            print(f"  {line}", file=sys.stderr)
        return 1

    total = sum(len(check.fixtures()) for check in checks)
    print(f"self-test: ok — {len(checks)} check(s), {total} fixture(s), every check fires and stays quiet")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python3 -m scripts.checks",
        description="Static gates for pi.nvim. Exit 0 = clean, 1 = findings, 2 = broken gate.",
    )
    parser.add_argument("--root", default=str(REPO_ROOT), help="tree to check (default: repo root)")
    parser.add_argument("--only", action="append", metavar="NAME", help="run one check (repeatable)")
    parser.add_argument("--list", action="store_true", help="list checks and exit")
    parser.add_argument("--self-test", action="store_true", help="prove every check can fail, using fixtures")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--quiet", action="store_true", help="only print findings and the summary line")
    args = parser.parse_args(argv)

    if args.list:
        for check in load_checks():
            extra = f" (needs: {', '.join(check.requires)})" if check.requires else ""
            print(f"{check.name:16} {check.summary}{extra}")
        return 0

    if args.self_test:
        return self_test()

    root = Path(args.root).resolve()
    findings, errors, count = run_checks(root, args.only)

    for err in errors:
        print(f"error: {err}", file=sys.stderr)

    if args.json:
        print(json.dumps({"findings": [f.as_dict() for f in findings], "errors": errors, "checks": count}, indent=2))
    else:
        for finding in sorted(findings, key=lambda f: (f.path, f.line, f.check)):
            print(finding.render())
        if findings:
            print(f"\n{len(findings)} finding(s) from {count} check(s)", file=sys.stderr)
        elif not errors:
            print(f"ok: {count} check(s), 0 findings", file=sys.stderr)

    if errors:
        return 2
    return 1 if findings else 0
