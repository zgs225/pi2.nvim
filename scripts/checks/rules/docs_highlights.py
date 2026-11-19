"""Docs sync, symbol class 4 of N: highlight groups.

`AGENTS.md` requires every user-visible change to update `doc/` in the same
commit, and `doc/highlight-groups.md` is the reference table of `Pi*` groups.
`docs_commands.py` covers commands; this rule covers the highlight groups they
are rendered with, in both directions:

  code -> docs   every group defined by `nvim_set_hl(0, "Pi…", …)` under `lua/`
                 must have a row in `doc/highlight-groups.md` (finding at the
                 definition's `path:line`).
  docs -> code   every backticked `Pi…` name in a row of that table must name a
                 real definition (finding at `doc/highlight-groups.md:<line>`).

The multi-line trap
-------------------
`nvim_set_hl(0, "PiStartupLabel", …)` is usually written on one line, but nine
call sites in `lua/pi/ui/highlights.lua` break the line after the opening
paren, putting the name two lines below:

    vim.api.nvim_set_hl(
        0,
        "PiStartupLabel",
        { default = true, fg = normal.bg, bg = comment.fg }
    )

A line-oriented regex therefore silently loses those groups and the rule would
report green while nine groups went undocumented. The definition side is
tokenized with `lua.code_tokens` instead: find the `nvim_set_hl` name token,
then walk the call's argument tokens — second argument, whatever lines it
spans — so a commented-out call is not a definition and a name on a later line
still is.

Out of scope by design
----------------------
The dynamically generated `PiAnsi*` family (`lua/pi/ui/chat/ansi.lua`) is
created per ANSI style by string concatenation (`"PiAnsi" .. key:gsub(…)`), so
its names cannot be known statically, while the docs describe the family in
prose only. Both directions exclude any name starting with `PiAnsi`: no doc row
is required for it, and `nvim_set_hl` calls there are not definitions to check.
Names that are not string literals (`nvim_set_hl(0, name, {})` inside
`clear_default_groups`, `pcall(vim.api.nvim_set_hl, 0, name, …)`) are skipped
silently: a loop over runtime group names is not a definition site a doc row
could point at, and inventing a finding for it would punish correct code.

Warn vs error
-------------
A missing subject tree is a harness problem, not a verdict:

  `CheckError`   no `lua/` directory under `--root` (wrong tree), or a file that
                 cannot be read — exit 2.
  `warn` finding  `lua/` exists but has no literal `Pi*` definition at all
                 (exactly one finding: there is nothing to compare), or
                 `doc/highlight-groups.md` is missing (exactly one finding).
                 Both are facts about the tree and keep a `--root` run over a
                 partial checkout usable — exit 1.
  `error` finding  the actual mismatches, in either direction.

Today all 116 literal definitions have a row and every row names a definition,
so the real tree reports nothing.
"""

from __future__ import annotations

import re
from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

SET_CALL = "nvim_set_hl"
DOC_PATH = "doc/highlight-groups.md"
# A highlight-group name: `Pi` plus word characters, same shape on both sides so
# the two directions compare like for like.
NAME_RE = re.compile(r"^Pi[A-Za-z0-9]+$")
# Backticked mention inside a table row: `` | `PiFoo` | Role | ``.
ROW_MENTION_RE = re.compile(r"`(Pi[A-Za-z0-9]+)`")
# The dynamically generated family: out of scope in both directions.
EXCLUDED_PREFIX = "PiAnsi"


class DocsHighlights(Check):
    name = "docs-highlights"
    summary = "every Pi* highlight group is in doc/highlight-groups.md, and every row there exists"
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        # Only a missing subject tree is a harness problem: without `lua/` this
        # may not be a plugin tree at all, so no verdict is possible.
        if not (root / "lua").is_dir():
            raise CheckError(f"no lua/ directory under {root} — wrong tree?")

        defined = _definitions(root)
        if not defined:
            # Anti-silent-pass (G25): a tree with no literal definitions is not
            # "in sync", it is a tree where this rule has nothing to verify.
            return [
                self.finding(
                    "no literal `nvim_set_hl` definition of a `Pi*` name under lua/ — nothing to verify on this tree",
                    "lua",
                    severity="warn",
                )
            ]

        documented = _documented(root)
        if documented is None:
            return [
                self.finding(
                    f"`{DOC_PATH}` is missing — highlight groups cannot be checked against the docs",
                    DOC_PATH,
                    severity="warn",
                )
            ]

        findings: list[Finding] = []
        for name, (rel, line) in sorted(defined.items()):
            if name not in documented:
                findings.append(
                    self.finding(
                        f"`{name}` is defined with `nvim_set_hl` but has no row in `{DOC_PATH}` "
                        "(user-visible changes update the docs in the same change)",
                        rel,
                        line,
                    )
                )
        for name, line in sorted(documented.items()):
            if name not in defined:
                findings.append(
                    self.finding(
                        f"`{name}` is named in `{DOC_PATH}` but no `nvim_set_hl` call defines it "
                        "(stale docs, or a group that was renamed/removed)",
                        DOC_PATH,
                        line,
                    )
                )
        return findings

    def fixtures(self) -> list[Fixture]:
        return [
            self.fixture(
                "good",
                0,
                "in-sync tree: two documented groups, one of them defined across several lines (name on a later "
                "line), plus a `PiAnsi*` family module whose dynamic and family-literal definitions need no doc row",
            ),
            self.fixture(
                "bad",
                2,
                "one defined-but-undocumented group + one documented-but-undefined group",
            ),
            self.fixture(
                "empty",
                1,
                "lua/ present but no literal `nvim_set_hl` definition: a tree with no groups warns instead of "
                "breaking the gate, so a `--root` run over a partial tree stays usable",
            ),
            self.fixture(
                "no-lua",
                0,
                "no lua/ directory at all: the subject tree is missing, so the rule refuses the input with a "
                "CheckError (exit 2) rather than reporting a clean or a warned tree",
                expect_error=True,
            ),
        ]


def _definitions(root: Path) -> dict[str, tuple[str, int]]:
    """Map `Pi*` group name -> (path, line) of its first literal definition."""
    found: dict[str, tuple[str, int]] = {}
    source_root = root / "lua"
    if not source_root.is_dir():
        return found

    for path in sorted(source_root.rglob("*.lua")):
        rel = path.relative_to(root).as_posix()
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            raise CheckError(f"cannot read {rel}: {exc}") from exc
        tokens = lua.code_tokens(text)
        for index, token in enumerate(tokens):
            if not token.is_name(SET_CALL):
                continue
            name = _group_argument(tokens, index)
            if name is None:
                continue
            found.setdefault(name.value or "", (rel, name.line))
    return found


def _group_argument(tokens: list[lua.Token], index: int) -> lua.Token | None:
    """The second argument of the call whose callee is `tokens[index]`, if literal.

    Token-based rather than line-based on purpose: the argument is whatever token
    follows the first argument and its comma, so a name written two lines below
    `nvim_set_hl(` is still found. Returns `None` for anything that is not a
    literal `Pi*` name — including the `nvim_set_hl` that is passed as a value to
    `pcall` and therefore has no `(` after it.
    """
    cursor = index + 1
    if cursor >= len(tokens) or not tokens[cursor].is_punct("("):
        return None
    cursor += 1
    # First argument: the namespace (`0` in practice). Skipped, not validated:
    # a definition is a definition whichever namespace it targets.
    if cursor >= len(tokens):
        return None
    cursor += 1
    if cursor >= len(tokens) or not tokens[cursor].is_punct(","):
        return None
    cursor += 1
    if cursor >= len(tokens):
        return None
    candidate = tokens[cursor]
    if candidate.kind != "string" or not candidate.value:
        return None
    if not NAME_RE.fullmatch(candidate.value) or candidate.value.startswith(EXCLUDED_PREFIX):
        return None
    return candidate


def _documented(root: Path) -> dict[str, int] | None:
    """Map documented `Pi*` name -> first table-row line; `None` if the doc is missing.

    Only rows of the group table count: the prose around it mentions names (and
    the `PiAnsi*` family) in running text, which is documentation but not a
    table entry, and a finding needs a row to point at.
    """
    path = root / DOC_PATH
    if not path.is_file():
        return None
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise CheckError(f"cannot read {DOC_PATH}: {exc}") from exc

    found: dict[str, int] = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line.startswith("|"):
            continue
        for match in ROW_MENTION_RE.finditer(line):
            name = match.group(1)
            if name.startswith(EXCLUDED_PREFIX):
                continue
            found.setdefault(name, lineno)
    return found
