"""Docs sync, symbol class 2 of N: config keys.

`doc/configuration.md` opens with a `require("pi").setup({ ... })` example that
is the user-facing contract for every option, while the real defaults are the
`local defaults = { ... }` table in `lua/pi/config.lua`. Nothing kept the two in
step: a key added to one side and forgotten on the other ships as a documented
option that does nothing, or an option that exists only in source.

This rule compares the two trees end-to-end, in both directions:

  code -> docs   every dotted path in `defaults` must appear in the `setup()`
                 example, or the option is undocumented.
  docs -> code   every dotted path in the example must appear in `defaults`, or
                 the doc promises an option that does not exist.

Both sides are *parsed*, not grepped. The doc side in particular has to be: the
example is a Lua table literal with nested tables, positional array values
(`left = { "context", "attention" }`), inline `--` comments and a commented-out
option in almost every block (`-- lang = "zh-CN"`). A text match would count
those commented keys — they are exactly the drift this rule exists to catch —
and would also treat `statusline.components.context.warn = 70` as a top-level
key. So the example is tokenized with `lua.code_tokens` (comments and string
bodies never reach the matcher) and parsed as a table literal. Only `name =
value` entries are keys; positional entries are values, never keys, because
`{ "a", "b" }` has no config path. A bracket key (`["x"] = ...`) is refused with
a `CheckError` rather than silently mishandled.

Warn vs error
-------------
Same split as the other `docs-*` rules:

  `CheckError`  the subject tree is missing (no `lua/` directory under `--root`)
                or a file cannot be read. That is a harness problem, not a
                verdict — exit 2.
  `warn` finding  the tree exists, so the rule ran, but this tree has nothing to
                compare: no `local defaults = {` table in `lua/pi/config.lua`, or
                no fenced `setup({` block in `doc/configuration.md` (or no such
                file). Exactly one warning, never mixed with errors.
  `error` finding  a real difference in either direction. One finding per dotted
                path, naming the path.

A defaults-only path has no line in the doc to point at, so it is reported on
`doc/configuration.md` at the line of the example's opening fence — consistently,
for every such path; a doc-only path points at its own key line.
"""

from __future__ import annotations

from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

CONFIG_REL = "lua/pi/config.lua"
DOC_REL = "doc/configuration.md"
DEFAULTS_KEY = "defaults"
SETUP_CALL = "setup"
OPENERS = ("(", "{", "[")
CLOSERS = (")", "}", "]")
FENCE = "```"


class DocsConfig(Check):
    name = "docs-config"
    summary = "every option in lua/pi/config.lua defaults appears in the setup() example, and vice versa"
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        # Only a missing subject tree is a harness problem: without `lua/` the
        # rule cannot tell a plugin tree from an arbitrary directory.
        if not (root / "lua").is_dir():
            raise CheckError(f"no lua/ directory under {root} — wrong tree?")

        defaults = _defaults_paths(root)
        if defaults is None:
            # Anti-silent-pass (G25): no defaults table is not "in sync", it is
            # a tree this rule has nothing to verify.
            return [
                self.finding(
                    f"no `local {DEFAULTS_KEY} = {{` table in {CONFIG_REL} — nothing to compare against",
                    CONFIG_REL,
                    severity="warn",
                )
            ]

        example = _doc_example(root)
        if example is None:
            return [
                self.finding(
                    f"no fenced `{SETUP_CALL}({{` block in {DOC_REL} — nothing to compare against",
                    DOC_REL,
                    severity="warn",
                )
            ]
        documented, fence_line = example

        findings: list[Finding] = []
        for path in sorted(defaults):
            if path not in documented:
                findings.append(
                    self.finding(
                        f"{path} is in {CONFIG_REL} defaults but missing from the {SETUP_CALL}() example",
                        DOC_REL,
                        fence_line,
                    )
                )
        for path, line in sorted(documented.items()):
            if path not in defaults:
                findings.append(
                    self.finding(
                        f"{path} is in the {SETUP_CALL}() example in {DOC_REL} but not in {CONFIG_REL} defaults",
                        DOC_REL,
                        line,
                    )
                )
        return findings

    def fixtures(self) -> list[Fixture]:
        return [
            self.fixture(
                "good",
                0,
                "in-sync tree: nested table, a one-key table, and a positional array value that is not a key",
            ),
            self.fixture(
                "bad",
                2,
                "one option only in defaults + one option only in the setup() example, one finding each way",
            ),
            self.fixture(
                "empty",
                1,
                "lua/pi/config.lua without a `local defaults = {` table: the rule has nothing to compare, which "
                "warns instead of reporting a clean tree or breaking the gate",
            ),
            self.fixture(
                "no-lua",
                0,
                "no lua/ directory at all: the subject tree is missing, so the rule refuses the input with a "
                "CheckError (exit 2) instead of reporting a clean or a warned tree",
                expect_error=True,
            ),
        ]


def _defaults_paths(root: Path) -> dict[str, int] | None:
    """Dotted paths of the `local defaults = { ... }` table, or None if absent."""
    path = root / CONFIG_REL
    if not path.is_file():
        return None
    tokens = lua.code_tokens(_read(path, CONFIG_REL))
    for index in range(len(tokens) - 3):
        if not tokens[index].is_name("local"):
            continue
        if not tokens[index + 1].is_name(DEFAULTS_KEY):
            continue
        if not tokens[index + 2].is_punct("=") or not tokens[index + 3].is_punct("{"):
            continue
        found: dict[str, int] = {}
        _collect(tokens, index + 3, "", found, CONFIG_REL)
        return found
    return None


def _doc_example(root: Path) -> tuple[dict[str, int], int] | None:
    """Dotted paths of the setup() example, plus its opening fence line."""
    path = root / DOC_REL
    if not path.is_file():
        return None
    lines = _read(path, DOC_REL).splitlines()

    inside = False
    fence_line = 0
    body: list[str] = []
    for lineno, line in enumerate(lines, 1):
        if line.lstrip().startswith(FENCE):
            if not inside:
                inside = True
                fence_line = lineno
                body = []
                continue
            return _setup_paths("\n".join(body), fence_line + 1, fence_line)
        if inside:
            body.append(line)
    return None  # opening fence with no closing one: not a usable example


def _setup_paths(source: str, first_line: int, fence_line: int) -> tuple[dict[str, int], int] | None:
    """Parse the table literal passed to `setup(...)` in one fenced block.

    `first_line` is the real file line of the block's first content line, so
    token lines are shifted back into file coordinates.
    """
    tokens = lua.code_tokens(source)
    shifted = [lua.Token(t.kind, t.text, t.line + first_line - 1, t.value) for t in tokens]
    for index in range(len(shifted) - 2):
        if not shifted[index].is_name(SETUP_CALL):
            continue
        if not shifted[index + 1].is_punct("(") or not shifted[index + 2].is_punct("{"):
            continue
        found: dict[str, int] = {}
        _collect(shifted, index + 2, "", found, DOC_REL)
        return found, fence_line
    return None


def _collect(tokens: list[lua.Token], open_index: int, prefix: str, out: dict[str, int], where: str) -> None:
    """Record every `name = value` key under `tokens[open_index] == "{"` in `out`."""
    for entry in _entries(tokens, open_index):
        if not entry:
            continue
        head = entry[0]
        if head.is_punct("["):
            raise CheckError(f"{where}:{head.line}: bracket key `[...] =` — this rule only understands `name = value`")
        if head.kind != "name" or len(entry) < 2 or not entry[1].is_punct("="):
            continue  # positional array entry (or a bare value): never a config path
        path = f"{prefix}.{head.text}" if prefix else head.text
        out[path] = head.line
        value = entry[2:]
        if value and value[0].is_punct("{"):
            _collect(value, 0, path, out, where)


def _entries(tokens: list[lua.Token], open_index: int) -> list[list[lua.Token]]:
    """Split the table literal opened at `tokens[open_index]` into entry slices."""
    entries: list[list[lua.Token]] = []
    current: list[lua.Token] = []
    depth = 0
    index = open_index + 1
    while index < len(tokens):
        token = tokens[index]
        if token.kind == "punct" and token.text in OPENERS:
            depth += 1
        elif token.kind == "punct" and token.text in CLOSERS:
            if depth == 0:
                if token.text == "}":
                    break  # end of this table literal
            else:
                depth -= 1
        elif token.kind == "punct" and token.text == "," and depth == 0:
            entries.append(current)
            current = []
            index += 1
            continue
        current.append(token)
        index += 1
    entries.append(current)
    return entries


def _read(path: Path, rel: str) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise CheckError(f"cannot read {rel}: {exc}") from exc
