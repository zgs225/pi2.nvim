"""Docs sync, symbol class 2 of N: default keymaps.

`AGENTS.md` requires every user-visible change to update `README.md` /
`doc/*.md` in the same commit, and the develop skill turns that into a
pre-merge gate ("Docs sync gate"). Keymaps are the symbol class users notice
first when it drifts: a binding that ships undocumented is a feature nobody
finds, a documented binding that no longer exists is a broken promise.

This rule checks the default keymap set end-to-end, both directions against the
same slice of `doc/keymaps.md`:

  code -> docs   every literal lhs of a `vim.keymap.set(` call inside
                 `Chat:_set_keymaps` (`lua/pi/ui/chat/init.lua`) must be
                 mentioned in the `"bind on its own"` list of
                 `doc/keymaps.md`.
  docs -> code   every angle-bracket key written as inline code (a backticked
                 span matching `<[A-Za-z0-9-]+>`, outside fenced blocks) in the
                 `"bind on its own"` list of `doc/keymaps.md` must be the
                 literal lhs of some `vim.keymap.set(` anywhere under `lua/`.

Both directions are anchored to one sentence, not to the whole file. The line
`What the plugin does bind on its own:` introduces the bullet list that actually
claims plugin-owned bindings, so the scan starts there and stops at the next
heading (or end of file), skipping fenced blocks.

The consequence, in both directions: a key that appears only in
`## Example setup` — the user's own example mappings and placeholders — does
NOT document a plugin binding. That section tells the reader to rebind
`<S-Up>` / `<S-Down>`, so scanning the whole file flagged correct docs (false
positive) and, worse, credited a newly bound plugin key with "documentation"
that was really the user's own `map(event.buf, "<C-q>", …)` example (false
negative). One anchored slice fixes both.

Source is tokenized with `lua.code_tokens` and the mode argument is skipped, so
a string inside a `desc` or a commented-out registration is never mistaken for
a binding; the lhs is the first argument after the (string or table) mode
argument.

Out of scope (deliberately, both directions)
-------------------------------------------
The lhs of a `vim.keymap.set(` call is only checked when it is a *string
literal*. Non-literal lhs values cannot be resolved statically and produce no
finding in either direction:

  * the loop variable in `for _, key in ipairs({ ... }) do vim.keymap.set(...)`,
  * table lookups such as `entry.lhs`,
  * `Keys.bind(...)` and every other binding helper that does not call
    `vim.keymap.set(` directly.

Bare-word keys (`gf`, `dd`, `o`, `x`, `T`, `?`) are checked in the forward
direction (a chat lhs must be mentioned) but are out of scope for the reverse
direction: prose and backticked one-liners like `` `q` closes the review ``
cannot be told apart from ordinary English or a command name, so the reverse
direction only trusts `<...>` notation.

Warn vs error
-------------
Same contract as `docs-commands`:

  `CheckError`  the rule cannot find its subject tree (no `lua/` directory
                under `--root`, or a file it cannot read) — harness problem.
  `warn` finding  the tree exists but has nothing for this rule to anchor on:
                no literal chat keymap at all, no `doc/keymaps.md`, or a
                `doc/keymaps.md` that no longer contains the
                `"bind on its own"` sentence. A rewritten doc must make the gate
                say so instead of going green, and a warn keeps a
                `--root <partial tree>` run usable instead of hiding every other
                rule behind exit 2.
  `error` finding  real drift: an undocumented chat lhs, or a documented angle
                key in the anchor list that no module binds.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

CHAT_MODULE = "lua/pi/ui/chat/init.lua"
KEYMAP_SET = ("vim", "keymap", "set")
SET_KEYMAPS = "_set_keymaps"
DOC_KEYMAPS = "doc/keymaps.md"
# The sentence that introduces the bullet list claiming plugin-owned bindings.
ANCHOR = "bind on its own"

# One backticked span on one line: docs.py-style line scanning, no markdown AST.
CODE_SPAN_RE = re.compile(r"`([^`\n]+)`")
INLINE_KEY_RE = re.compile(r"^<[A-Za-z0-9-]+>$")
FENCE_RE = re.compile(r"^\s*(?:```|~~~)")

_BLOCK_OPENERS = frozenset({"function", "if", "for", "while", "do", "repeat"})
_BLOCK_CLOSERS = frozenset({"end", "until"})


class DocsKeymaps(Check):
    name = "docs-keymaps"
    summary = "every default chat keymap is documented, and every documented <Key> is really bound under lua/"
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        # Without `lua/` the rule cannot tell a plugin tree from any other tree.
        if not (root / "lua").is_dir():
            raise CheckError(f"no lua/ directory under {root} — wrong tree?")

        bound = _chat_keymaps(root)
        if not bound:
            # Anti-silent-pass design (G25): no keymaps is not "in sync", it is
            # a tree where this rule has nothing to verify.
            return [
                self.finding(
                    f"no literal `vim.keymap.set(` lhs in `Chat:{SET_KEYMAPS}` ({CHAT_MODULE}) — "
                    "nothing to verify on this tree",
                    "lua",
                    severity="warn",
                )
            ]

        doc = root / DOC_KEYMAPS
        if not doc.is_file():
            return [
                self.finding(
                    f"{DOC_KEYMAPS} is missing — the keymap docs have nothing to compare against",
                    DOC_KEYMAPS,
                    severity="warn",
                )
            ]

        text = _read(doc, root)
        section = _anchor_section(text)
        if section is None:
            # A rewritten doc must not turn the docs→code direction green just
            # because its anchor sentence disappeared (G25).
            return [
                self.finding(
                    f'{DOC_KEYMAPS} no longer has a "{ANCHOR}" list — the reverse docs→code direction '
                    "has nothing to anchor to",
                    DOC_KEYMAPS,
                    severity="warn",
                )
            ]

        claimed, claims_text = section
        findings: list[Finding] = []

        for key, line in bound:
            # Only the anchor list documents a binding: a key that appears just
            # once in `## Example setup` is the user's own mapping, not ours.
            if not _mentioned(key, claims_text):
                findings.append(
                    self.finding(
                        f"`{key}` is bound in `Chat:{SET_KEYMAPS}` but never mentioned in {DOC_KEYMAPS} "
                        "(user-visible changes update the docs in the same change)",
                        CHAT_MODULE,
                        line,
                    )
                )

        registered = _literal_lhs_under_lua(root)
        for key, line in claimed:
            if key not in registered:
                findings.append(
                    self.finding(
                        f"`{key}` is documented as a plugin binding but no `vim.keymap.set(` under lua/ binds it "
                        "(stale docs)",
                        DOC_KEYMAPS,
                        line,
                    )
                )

        return findings

    def fixtures(self) -> list[Fixture]:
        return [
            self.fixture(
                "good",
                0,
                "in-sync tree: the anchor list documents both chat lhs (one call after a mode table), the second "
                "of which is bound in another module; the `## Example setup` section after the list mentions an "
                "unbound `<S-Up>` placeholder and must not fire",
            ),
            self.fixture(
                "bad",
                2,
                "one chat lhs missing from doc/keymaps.md + one stale angle key inside the anchor list",
            ),
            self.fixture(
                "example-only",
                1,
                "regression for the forward false negative: a chat lhs mentioned only inside the fenced "
                "`## Example setup` block is the user's own mapping, not documentation of a plugin binding, so "
                "the binding is still reported",
            ),
            self.fixture(
                "empty",
                1,
                "lua/ with no `vim.keymap.set(` at all: a tree with no keymaps warns instead of breaking the "
                "gate, so a `--root` run over a partial tree stays usable",
            ),
            self.fixture(
                "no-anchor",
                1,
                "a chat keymap that is documented, but doc/keymaps.md dropped the `bind on its own` sentence: "
                "the reverse direction has nothing to anchor to, so it warns instead of going green",
            ),
            self.fixture(
                "no-lua",
                0,
                "no lua/ directory at all: the subject tree is missing, so the rule refuses the input with a "
                "CheckError (exit 2) rather than reporting a clean or a warned tree",
                expect_error=True,
            ),
        ]


def _read(path: Path, root: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise CheckError(f"cannot read {path.relative_to(root).as_posix()}: {exc}") from exc


def _mentioned(key: str, text: str) -> bool:
    """Is `key` mentioned in the docs as a key, not as part of a longer one?

    `<CR>` inside `<A-CR>` is a different binding, so the neighbours matter.
    """
    pattern = re.compile(r"(?<![<A-Za-z0-9-])" + re.escape(key) + r"(?![>A-Za-z0-9-])")
    return pattern.search(text) is not None


def _chat_keymaps(root: Path) -> list[tuple[str, int]]:
    """Literal lhs of every `vim.keymap.set(` inside `Chat:_set_keymaps`, by line."""
    path = root / CHAT_MODULE
    if not path.is_file():
        return []
    tokens = lua.code_tokens(_read(path, root))
    span = _function_span(tokens, SET_KEYMAPS)
    if span is None:
        return []
    start, end = span
    return [(lhs.value, lhs.line) for lhs in _lhs_literals(tokens) if start <= lhs.index < end]


def _literal_lhs_under_lua(root: Path) -> dict[str, tuple[str, int]]:
    """Every literal lhs bound anywhere under `lua/`, mapped to (path, line)."""
    found: dict[str, tuple[str, int]] = {}
    source_root = root / "lua"
    if not source_root.is_dir():
        return found
    for path in sorted(source_root.rglob("*.lua")):
        rel = path.relative_to(root).as_posix()
        tokens = lua.code_tokens(_read(path, root))
        for lhs in _lhs_literals(tokens):
            found.setdefault(lhs.value, (rel, lhs.line))
    return found


@dataclass(frozen=True)
class _Lhs:
    """A literal lhs token plus its offset, so callers can scope by position."""

    index: int
    line: int
    value: str


def _lhs_literals(tokens: list[lua.Token]) -> list[_Lhs]:
    """Literal lhs of every `vim.keymap.set(` call, non-literal calls skipped.

    `vim.keymap.set(mode, lhs, rhs)`: the mode argument is skipped as one
    argument (a string, a `{ "n", "v" }` table, or a name), then the lhs is
    taken only when it is a single string token.
    """
    found: list[_Lhs] = []
    limit = len(tokens) - 6
    for index in range(limit):
        if not (tokens[index].is_name(KEYMAP_SET[0]) and tokens[index + 1].is_punct(".")):
            continue
        if not (tokens[index + 2].is_name(KEYMAP_SET[1]) and tokens[index + 3].is_punct(".")):
            continue
        if not (tokens[index + 4].is_name(KEYMAP_SET[2]) and tokens[index + 5].is_punct("(")):
            continue
        lhs = _skip_one_argument(tokens, index + 6)
        if lhs is None or lhs >= len(tokens) or tokens[lhs].kind != "string":
            continue  # loop variable, table field, helper: not statically resolvable
        value = tokens[lhs].value
        if value:
            found.append(_Lhs(lhs, tokens[lhs].line, value))
    return found


def _skip_one_argument(tokens: list[lua.Token], start: int) -> int | None:
    """Index of the token after the argument starting at `start` (past its comma)."""
    depth = 0
    for index in range(start, len(tokens)):
        token = tokens[index]
        if token.kind != "punct":
            continue
        if token.text in "({[":
            depth += 1
        elif token.text in ")}]":
            if depth == 0:
                return None
            depth -= 1
        elif token.text == "," and depth == 0:
            return index + 1
    return None


def _function_span(tokens: list[lua.Token], name: str) -> tuple[int, int] | None:
    """Token range `[start, end)` of `function <prefix>[.:]<name>(...)`, `end` included."""
    for index, token in enumerate(tokens):
        if not token.is_name("function"):
            continue
        probe = index + 1
        matched = False
        while probe < len(tokens) and tokens[probe].kind == "name":
            matched = tokens[probe].is_name(name)
            separated = (
                probe + 2 < len(tokens)
                and tokens[probe + 1].kind == "punct"
                and tokens[probe + 1].text in (":", ".")
                and tokens[probe + 2].kind == "name"
            )
            if not separated:
                break
            probe += 2
        if matched:
            return index, _block_end(tokens, index)
    return None


def _block_end(tokens: list[lua.Token], start: int) -> int:
    """Index just past the `end` matching the block opened at `start`."""
    depth = 0
    pending_do = 0
    for index in range(start, len(tokens)):
        token = tokens[index]
        if token.kind != "name":
            continue
        text = token.text
        if text in ("for", "while"):
            depth += 1
            pending_do += 1  # the `do` that closes the header is not a block
        elif text == "do":
            if pending_do:
                pending_do -= 1
            else:
                depth += 1
        elif text in _BLOCK_OPENERS:
            depth += 1
        elif text in _BLOCK_CLOSERS:
            depth -= 1
            if depth <= 0:
                return index + 1
    return len(tokens)


def _anchor_section(text: str) -> tuple[list[tuple[str, int]], str] | None:
    """The `"bind on its own"` list: (claimed angle keys, its text).

    Returns `None` when the anchor sentence is gone, so the caller can warn
    instead of reporting an empty — and therefore silently green — scan. The
    slice runs from the anchor line to the next heading or end of file, skipping
    fenced blocks, and feeds *both* directions: `## Example setup` documents the
    user's own mappings, so a key mentioned there claims nothing about a plugin
    binding.
    """
    lines = text.splitlines()
    start = next((index for index, line in enumerate(lines) if ANCHOR in line), None)
    if start is None:
        return None

    hits: list[tuple[str, int]] = []
    claims: list[str] = []
    fenced = False
    for lineno, line in enumerate(lines[start:], start + 1):
        if FENCE_RE.match(line):
            fenced = not fenced
            continue
        if fenced:
            continue
        if lineno > start + 1 and line.strip().startswith("#"):
            break  # the claim list ends at the next section
        claims.append(line)
        for span in CODE_SPAN_RE.finditer(line):
            body = span.group(1).strip()
            if INLINE_KEY_RE.match(body):
                hits.append((body, lineno))
    return hits, "\n".join(claims)
