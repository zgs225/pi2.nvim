"""Docs sync, symbol class 1 of N: user commands.

`AGENTS.md` requires every user-visible change to update `README.md` /
`doc/*.md` in the same commit, and the develop skill turns that into a
pre-merge gate ("Docs sync gate"). Until now that gate was a human checklist —
which is exactly the kind of rule that decays.

This rule checks one symbol class end-to-end and is the template for the rest
(keymaps, config keys, highlight groups, public API — see the tracking issue
referenced in `.agents/skills/develop/references/checks.md`):

  code -> docs   every command registered with `nvim_create_user_command` must
                 be mentioned as `:Pi<Name>` somewhere in README.md or doc/*.md.
  docs -> code   every `:Pi<Name>` mention must name a real command, or be a
                 prefix of one (`:PiSub` is accepted shorthand for the
                 `:PiSubNew` / `:PiSubClose` / ... family).

Source is tokenized, so a commented-out registration is not a command and a
`:PiFoo` inside a fenced code block is still a mention.

Warn vs error
-------------
The two failure kinds answer different questions, so this rule uses both:

  `CheckError`  the rule cannot even find its subject tree (no `lua/` directory
                under `--root`, or a file it cannot read). That is a harness
                problem, not a verdict about the code — exit 2.
  `warn` finding  the subject tree exists, so the rule ran, but *this* tree has
                nothing for it to check (no `nvim_create_user_command(` at all,
                or commands and an empty doc corpus). That is a fact about the
                tree and is reported as a finding — exit 1.

The distinction exists because a hard error for "nothing to verify" makes
`--root <partial tree>` useless: one rule's tree-sensitivity would hide every
other rule's findings behind exit 2. With commands present the tree is a real
plugin tree, and a partial checkout must not turn a `--root` run into a hard
failure.
"""

from __future__ import annotations

import re
from pathlib import Path

from .. import lua
from ..docs import Docs
from ..framework import Check, CheckError, Finding, Fixture

CREATE_CALL = "nvim_create_user_command"
# `:Pi`, `:PiXxx` — a mention in prose, a table cell or inline code.
MENTION_RE = re.compile(r"(?<![A-Za-z0-9_]):(Pi[A-Za-z]*)")


class DocsCommands(Check):
    name = "docs-commands"
    summary = "every :Pi* command is documented, and every :Pi* mention in the docs exists"
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        # Only a missing subject tree is a harness problem: without `lua/` the
        # rule cannot know whether this is a plugin tree at all.
        if not (root / "lua").is_dir():
            raise CheckError(f"no lua/ directory under {root} — wrong tree?")

        commands, dynamic = _commands(root)
        if not commands and not dynamic:
            # Deliberate anti-silent-pass design (G25): a tree with no commands
            # is not "in sync", it is a tree where this rule has nothing to
            # verify. A warning says so without breaking a `--root` run.
            return [
                self.finding(
                    "no `nvim_create_user_command(` under lua/ — nothing to verify on this tree",
                    "lua",
                    severity="warn",
                )
            ]

        findings: list[Finding] = [
            self.finding(
                f"command name is not a string literal (`{expr}`): docs sync cannot be verified statically — "
                "use a literal name in `nvim_create_user_command`",
                rel,
                line,
            )
            for rel, line, expr in dynamic
        ]

        docs = Docs(root)
        if not docs.files:
            # Commands exist, so this is a real plugin tree; an empty doc corpus
            # is a property of a partial checkout, not a broken gate.
            findings.append(
                self.finding(
                    "no README.md or doc/*.md — the docs corpus is empty, so docs sync has nothing to compare against",
                    "",
                    severity="warn",
                )
            )
            return findings

        mentions = docs.find(MENTION_RE)
        documented = {match.group(1) for _, _, match in mentions}

        for name, (rel, line) in sorted(commands.items()):
            if name not in documented:
                findings.append(
                    self.finding(
                        f"`:{name}` is registered but never mentioned in README.md or doc/*.md "
                        "(user-visible changes update the docs in the same change)",
                        rel,
                        line,
                    )
                )

        for rel, line, match in mentions:
            name = match.group(1)
            if name in commands:
                continue
            if any(real.startswith(name) and real != name for real in commands):
                continue  # family shorthand, e.g. `:PiSub` -> :PiSubNew / :PiSubClose / ...
            findings.append(
                self.finding(
                    f"`:{name}` is mentioned but no such command is registered "
                    f"(stale docs; closest registered: {_closest(name, commands)})",
                    rel,
                    line,
                )
            )

        return findings

    def fixtures(self) -> list[Fixture]:
        return [
            self.fixture(
                "good",
                0,
                "in-sync tree: two documented commands, one commented-out registration, one `:PiSub` family shorthand",
            ),
            self.fixture(
                "bad",
                2,
                "one undocumented command + one stale doc mention",
            ),
            self.fixture(
                "empty",
                1,
                "lua/ with no `nvim_create_user_command(` at all: a tree with no commands warns instead of "
                "breaking the gate, so a `--root` run over a partial tree stays usable",
            ),
            self.fixture(
                "no-docs",
                1,
                "one command registered but no README.md and no doc/: the docs corpus is empty, which warns "
                "instead of raising",
            ),
            self.fixture(
                "no-lua",
                0,
                "no lua/ directory at all: the subject tree is missing, so the rule refuses the input with a "
                "CheckError (exit 2) rather than reporting a clean or a warned tree",
                expect_error=True,
            ),
        ]


def _commands(root: Path) -> tuple[dict[str, tuple[str, int]], list[tuple[str, int, str]]]:
    """Map command name -> (path, line); plus names that are not literals."""
    found: dict[str, tuple[str, int]] = {}
    dynamic: list[tuple[str, int, str]] = []
    source_root = root / "lua"
    if not source_root.is_dir():
        return found, dynamic

    for path in sorted(source_root.rglob("*.lua")):
        rel = path.relative_to(root).as_posix()
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            raise CheckError(f"cannot read {rel}: {exc}") from exc
        tokens = lua.code_tokens(text)
        for index, token in enumerate(tokens):
            if not token.is_name(CREATE_CALL):
                continue
            cursor = index + 1
            if cursor >= len(tokens) or not tokens[cursor].is_punct("("):
                continue
            cursor += 1
            if cursor >= len(tokens):
                break
            arg = tokens[cursor]
            if arg.kind == "string" and arg.value:
                found[arg.value] = (rel, arg.line)
            elif arg.kind != "comment":
                dynamic.append((rel, arg.line, arg.text))
    return found, dynamic


def _closest(name: str, commands: dict[str, tuple[str, int]]) -> str:
    """Cheap "did you mean" for the finding message: nearest name by prefix length."""
    best = max(commands, key=lambda candidate: _common_prefix(candidate, name), default="")
    return f":{best}" if best else "none"


def _common_prefix(a: str, b: str) -> int:
    count = 0
    for left, right in zip(a, b):
        if left != right:
            break
        count += 1
    return count
