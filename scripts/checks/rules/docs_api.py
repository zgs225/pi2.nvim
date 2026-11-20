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

Shorthand and module paths
--------------------------
`doc/api.md` legitimately writes three different things that look alike, and
only two of them are API mentions:

  `pi.worktree_new(...)`  a plain mention: one doc symbol, one definition.
  `pi.worktree_*`         a FAMILY claim — "every function whose name starts
                          with `worktree_`". It is shorthand, not a stale name,
                          but it is still a claim about the code and must fail
                          when the family is gone: a mention immediately
                          followed by `*` is valid only if at least one defined
                          `function M.<prefix>...` starts with that prefix, and
                          in the forward direction a definition counts as
                          documented when it matches exactly or falls under a
                          documented `prefix*` shorthand. `docs_commands.py`
                          accepts `:PiSub` as a family shorthand for the same
                          reason.
  `require("pi.worktree")` a MODULE PATH, not the `pi.worktree()` API. It names
                          a Lua module, so it is not a mention of anything the
                          module table exposes. A mention must therefore start a
                          token (no word character, `.`, `/`, `"` or `'` right
                          before `pi`), and must not continue into a field path:
                          `require("pi.worktree")`, `pi.foo.bar` and `xpi.foo`
                          are all excluded by the regex.

A module path can also appear *bare* — `` `pi.worktree` also exposes `_reset`
`` — which no lookbehind can catch, because it is textually identical to a
mention. So a bare `pi.<name>` (no call parens) that names a published submodule
(`lua/pi/<name>.lua`, e.g. `worktree`) is read as a module reference, not a
stale API name. A *call* `pi.<name>(...)` stays an API claim even then, so
removing a function that shares a submodule's name is still caught; the only
miss is a stale bare reference to an existing submodule, which is the cheaper
error — a false positive here blocks the gate for a doc style that is correct.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

API_SOURCE = "lua/pi/init.lua"
API_DOC = "doc/api.md"
# `pi.<name>` — in a fenced block as `pi.name(args?)`, in prose as `` `pi.name(...)` ``.
# Docs are text, so a regex is the right tool here (unlike the Lua side).
#
# `(?<![\w./"'])` keeps module paths out: `require("pi.worktree")` is a Lua
# module, not the `pi.worktree()` API, and `xpi.foo` is a different symbol.
# `(?!\w|\.)` stops a mention from continuing into a field path (`pi.foo.bar`).
# The trailing `(\*?)` captures family shorthand (`pi.worktree_*`), `(\(?)`
# records whether the mention is a call (`pi.foo(`) or a bare name (`pi.foo`).
MENTION_RE = re.compile(r"(?<![\w./\"'])pi\.([a-z_][a-z0-9_]*)(\*?)(\(?)(?!\w|\.)")


@dataclass(frozen=True)
class _Mention:
    """One `pi.<name>` mention: the name, family shorthand, call form, and line."""

    name: str
    family: bool
    called: bool
    line: int

    def render(self) -> str:
        return f"pi.{self.name}*" if self.family else f"pi.{self.name}"


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

        mentions = _mentions(_read(root, API_DOC))
        documented = {mention.name for mention in mentions if not mention.family}
        families = {mention.name for mention in mentions if mention.family}
        # Submodule stems are module paths, not API names (see the module docstring).
        modules = _modules(root) - set(definitions)
        findings: list[Finding] = []

        for name, line in definitions.items():
            if name in documented:
                continue
            if any(name.startswith(prefix) for prefix in families):
                continue
            findings.append(
                self.finding(
                    f"`M.{name}` is a public API function but `pi.{name}` is never documented in {API_DOC} "
                    "(user-visible changes update the docs in the same change)",
                    API_SOURCE,
                    line,
                )
            )

        for mention in mentions:
            if mention.family:
                if any(name.startswith(mention.name) for name in definitions):
                    continue
                findings.append(
                    self.finding(
                        f"`{mention.render()}` documents a family but no `function M.{mention.name}...` exists "
                        f"in {API_SOURCE} (stale doc mention)",
                        API_DOC,
                        mention.line,
                    )
                )
                continue
            if mention.name in definitions:
                continue
            if not mention.called and mention.name in modules:
                continue  # `pi.worktree` = the published `lua/pi/worktree.lua` module
            findings.append(
                self.finding(
                    f"`{mention.render()}` is documented in {API_DOC} but no `function M.{mention.name}` exists "
                    f"in {API_SOURCE} (stale doc mention)",
                    API_DOC,
                    mention.line,
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
                "family",
                0,
                "family shorthand `pi.worktree_*` plus a `require()` module path and a bare submodule mention: "
                "none of them is drift, so nothing fires",
            ),
            self.fixture(
                "family-stale",
                1,
                "`pi.gone_*` names a family that no longer exists: the shorthand is a claim and must fail once",
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


def _mentions(text: str) -> list[_Mention]:
    """Every `pi.<name>` (or `pi.<prefix>*`) mention, deduplicated, in file order.

    One entry per name: the first line it appears on, and `called` true when *any*
    occurrence is a call (`pi.foo(`) — one call makes the name an API claim even
    if another line mentions it bare as a module path.
    """
    seen: dict[tuple[str, bool], _Mention] = {}
    for lineno, line in enumerate(text.splitlines(), 1):
        for match in MENTION_RE.finditer(line):
            key = (match.group(1), bool(match.group(2)))
            called = bool(match.group(3))
            previous = seen.get(key)
            if previous is None:
                seen[key] = _Mention(key[0], key[1], called, lineno)
            elif called and not previous.called:
                seen[key] = _Mention(previous.name, previous.family, True, previous.line)
    return list(seen.values())


def _modules(root: Path) -> set[str]:
    """Stems of the published submodules (`lua/pi/<name>.lua`), e.g. `worktree`.

    Real trees ship modules like `pi.worktree` that `doc/api.md` mentions on
    purpose; those are module paths, not functions the module table exposes.
    """
    found: set[str] = set()
    source = root / "lua" / "pi"
    if not source.is_dir():
        return found
    for path in sorted(source.glob("*.lua")):
        if path.stem != "init":
            found.add(path.stem)
    return found
