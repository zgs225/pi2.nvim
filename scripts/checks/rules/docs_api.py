"""Docs sync, symbol class 2 of N: the public Lua API.

`AGENTS.md` requires every user-visible change to update the docs in the same
change, and the develop skill turns that into a pre-merge gate ("Docs sync
gate"). `docs_commands.py` covers `:Pi*` commands; the public API is a separate
symbol class with a separate naming convention:

  code -> docs   every public definition in `lua/pi/init.lua` — a
                 `function M.<name>(...)` statement, or the equivalent
                 `M.<name> = function` assignment — must be mentioned as
                 `pi.<name>` in `doc/api.md`. A `M.x` definition therefore maps
                 to exactly one doc symbol, `pi.x`.
  docs -> code   every `pi.<name>` mention in `doc/api.md` must name a real
                 `function M.<name>`, or it is a stale doc mention.

The two sides are extracted differently on purpose. The Lua side is tokenized
with `lua.code_tokens`, so a commented-out `-- function M.gone() end` is not a
definition (regexing source is how gates get switched off — gotcha G24). The doc
side is plain text: a mention is a `path:line` plus the matched name, which is
exactly what a finding needs, so a regex over the file is correct there.

Warn vs error
-------------
The failure kinds answer different questions, so this rule uses both:

  `CheckError`  there is no `lua/` directory at all, or a file exists but cannot
                be read. The rule cannot locate its subject tree — a harness
                problem, not a verdict about the code — exit 2.
  `warn` finding  the tree exists, but *this* tree has nothing for the rule to
                check: `lua/pi/init.lua` is absent, or it defines no
                `function M.<name>`, or `doc/api.md` is missing. That is a fact
                about a partial checkout, so it is a finding — exit 1 — instead
                of a hard failure that would hide every other rule's findings.
  `error` finding  both sides exist: a definition without a doc mention, or a
                doc mention without a definition.

A warn is never emitted together with error findings: "nothing to verify" and
"this is wrong" cannot both be true, and mixing them makes the count
meaningless.
"""

from __future__ import annotations

import re
from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

API_SOURCE = "lua/pi/init.lua"
API_DOC = "doc/api.md"
# `pi.<name>` — in a fenced block as `pi.name(args?)`, in prose as `` `pi.name(...)` ``.
# Docs are text, so a regex is the right tool here (unlike the Lua side).
MENTION_RE = re.compile(r"pi\.([a-z_][a-z0-9_]*)")


class DocsApi(Check):
    name = "docs-api"
    summary = "every function M.<name> in lua/pi/init.lua is documented as pi.<name> in doc/api.md, and vice versa"
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        # Without `lua/` the rule cannot even tell whether this is a plugin tree.
        if not (root / "lua").is_dir():
            raise CheckError(f"no lua/ directory under {root} — wrong tree?")

        if not (root / API_SOURCE).is_file():
            return [
                self.finding(
                    f"no {API_SOURCE} — the public API cannot be located on this tree, so docs sync has "
                    "nothing to compare against",
                    API_SOURCE,
                    severity="warn",
                )
            ]

        definitions = _definitions(_read(root, API_SOURCE))
        if not definitions:
            # Anti-silent-pass (G25): a tree with no public function is not "in
            # sync", it is a tree where this rule has nothing to verify.
            return [
                self.finding(
                    f"no `function M.<name>` in {API_SOURCE} — nothing to verify on this tree",
                    API_SOURCE,
                    severity="warn",
                )
            ]

        if not (root / API_DOC).is_file():
            return [
                self.finding(
                    f"no {API_DOC} — the public API is defined but undocumented, so docs sync has nothing "
                    "to compare against",
                    API_DOC,
                    severity="warn",
                )
            ]

        documented = _mentions(_read(root, API_DOC))
        findings: list[Finding] = []

        for name, line in definitions.items():
            if name not in documented:
                findings.append(
                    self.finding(
                        f"`M.{name}` is a public API function but `pi.{name}` is never documented in {API_DOC} "
                        "(user-visible changes update the docs in the same change)",
                        API_SOURCE,
                        line,
                    )
                )

        for name, line in documented.items():
            if name not in definitions:
                findings.append(
                    self.finding(
                        f"`pi.{name}` is documented in {API_DOC} but no `function M.{name}` exists in "
                        f"{API_SOURCE} (stale doc mention)",
                        API_DOC,
                        line,
                    )
                )

        return findings

    def fixtures(self) -> list[Fixture]:
        return [
            self.fixture(
                "good",
                0,
                "in-sync tree: two documented functions, one commented-out definition the lexer must not see",
            ),
            self.fixture(
                "bad",
                2,
                "one public function with no doc mention + one stale `pi.gone(` mention",
            ),
            self.fixture(
                "empty",
                1,
                "lua/pi/init.lua with no `function M.<name>` at all: a tree with nothing to verify warns "
                "instead of breaking the gate",
            ),
            self.fixture(
                "no-lua",
                0,
                "no lua/ directory at all: the subject tree is missing, so the rule refuses the input with a "
                "CheckError (exit 2)",
                expect_error=True,
            ),
        ]


def _read(root: Path, rel: str) -> str:
    try:
        return (root / rel).read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise CheckError(f"cannot read {rel}: {exc}") from exc


def _definitions(text: str) -> dict[str, int]:
    """Map public name -> line of its `function M.<name>` definition, in file order.

    Comments are already dropped by `code_tokens`, so a commented-out definition
    never reaches the matcher. Both statement forms are accepted:
    `function M.x(...)` and `M.x = function`.
    """
    tokens = lua.code_tokens(text)
    found: dict[str, int] = {}
    for index, token in enumerate(tokens):
        if token.is_name("function"):
            member = _member_at(tokens, index + 1)
            if member is not None:
                found.setdefault(member.text, token.line)
            continue
        member = _member_at(tokens, index)
        if member is None:
            continue
        cursor = index + 3
        if cursor + 1 < len(tokens) and tokens[cursor].is_punct("=") and tokens[cursor + 1].is_name("function"):
            found.setdefault(member.text, token.line)
    return found


def _member_at(tokens: list[lua.Token], index: int) -> lua.Token | None:
    """If `tokens[index:]` starts `M . <name>`, return the `<name>` token."""
    if index + 2 >= len(tokens):
        return None
    if not tokens[index].is_name("M"):
        return None
    if not tokens[index + 1].is_punct("."):
        return None
    name = tokens[index + 2]
    return name if name.kind == "name" else None


def _mentions(text: str) -> dict[str, int]:
    """Map documented name -> line of its first `pi.<name>` mention, in file order."""
    found: dict[str, int] = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        for match in MENTION_RE.finditer(line):
            found.setdefault(match.group(1), lineno)
    return found
