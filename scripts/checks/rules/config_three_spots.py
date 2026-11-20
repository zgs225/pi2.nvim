"""G19 — the config spots must agree: `---@class` fields vs the `defaults` table.

`lua/pi/config.lua` describes every option twice: as a tree of `---@class pi.*`
annotations (`pi.Options` plus one class per nested table) and as the runtime
`local defaults = { ... }` table. `M.setup()` resolves with
`vim.tbl_deep_extend("force", defaults, opts)`, which can only merge keys that
exist in `defaults`. So the failure this rule prevents is quiet and permanent:

  * a key in `defaults` but not in a `---@class` never appears in the documented
    defaults block and gets no LuaLS completion — the option exists and nobody
    can find it;
  * a required `---@field` with no entry in `defaults` is worse: the annotation
    promises a value, `tbl_deep_extend` has nothing to merge it with, and the
    feature ships permanently disabled while the docs say it is configured.

Neither shows up as a crash or a failing test — the option simply does nothing
(G19, "new config option does nothing"). That is exactly the shape of defect a
static gate has to own.

Why `lua.tokenize` and not `lua.code_tokens`
--------------------------------------------
Both structures this rule compares are *not code* in the same way. The
annotations are **comments** (`---@class`, `---@field`), so `code_tokens` drops
the entire annotation side; only `tokenize` keeps comments. The `defaults` table
is code, but it contains `--` comments of its own (the deliberate `tools` note in
`subagent`), which the table parser skips explicitly. One token stream, comments
included, is therefore the only input that can see both sides.

The other half of the same lesson (G24): the rule never regexes the *structure*.
Comments are matched line-wise because that is what an annotation is — a comment
line — but the `defaults` table is parsed from tokens with real brace/`(`/`[`
nesting, and every key is recorded with the line it sits on. Positional array
entries (`args = { "-x" }`, the `verbs.pairs` list, `statusline.layout.left`) are
values, never keys, and a string or a comment can never be mistaken for one.

Decisions
---------
* **Optional fields may be absent from `defaults`.** `---@field name? type` is
  documented as "may be unset", and a `nil` default cannot be expressed through
  `tbl_deep_extend` in a useful way: `subagent.tools = nil` means "inherit every
  tool", `layout.side.height = nil` means "computed". Measured on this tree:
  **13** optional fields on the classes this walk reaches have no `defaults`
  entry (`panels.history.bash_title?`, `panels.*.name?`, `layout.side.height?`,
  `layout.float.win?`, `statusline.components.cost.warn?` / `.error?`,
  `subagent.tools?`, `subagent.sessions_list.collapsed?`, `vision.model?`,
  `vision.status_message?`). Reporting them would make the rule fire 13 times
  on a clean tree, so it would be deleted within a week — they are skipped
  by design. A *required* field missing from `defaults` is always a finding.
* **Descent follows declared types only.** A field's type is split on `|`; the
  rule recurses into the corresponding `defaults` subtable only when the first
  alternative is exactly `pi.<Name>`, that class is declared, and a subtable
  exists. Unions (`pi.SpinnerPreset|string[]`), inline table types
  (`table<string, pi.X>`), arrays (`pi.VerbPair[]`, `pi.ModelEntry[]`), function
  types and anything unresolvable are skipped **silently**: they describe a
  shape the annotation deliberately does not model as a class, and guessing at
  them produces false findings.
* **Direction is checked both ways.** A required field with no default and a
  default key with no `---@field` are both findings, each carrying the dotted
  path from `pi.Options` (`pi.Options field `diff.icons.add` has no entry in
  defaults`).

Warn vs error
-------------
`CheckError` (exit 2) is reserved for a harness problem: no `lua/` directory, or
`lua/pi/config.lua` unreadable. Everything else is a fact about the tree and is
reported as a finding:

  * no `---@class pi.Options` at all → exactly one `warn` finding. A partial
    checkout or a non-config tree must not turn a `--root` run into exit 2, and
    silence would read as "in sync".
  * `pi.Options` present but no `local defaults = {` → exactly one `warn`
    finding, same reason, for the tree that only has annotations.
  * otherwise: mismatches are errors only.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

SUBJECT = "lua/pi/config.lua"
ROOT_CLASS = "pi.Options"

# `---@class pi.SidePanels` — nothing else on the line.
_CLASS_RE = re.compile(r"^---@class\s+(pi\.[A-Za-z_]\w*)\s*$")
# `---@field name? type description` — `?` marks the field optional.
_FIELD_RE = re.compile(r"^---@field\s+([A-Za-z_]\w*)(\?)?\s+(\S.*?)\s*$")
# A plain `pi.<Name>` as the *whole* first alternative of a type: `pi.SideLayout`
# (end of text), `pi.LayoutConfig|fun(): ...` (union), `pi.SubagentConfig Float
# window sizing ...` (description). `pi.VerbPair[]` and `table<string, pi.X>` do
# not match on purpose — arrays and inline tables are not a class reference.
_REF_RE = re.compile(r"^(pi\.[A-Za-z_]\w*)(?:\||\s|$)")

_OPENERS = frozenset("{([")
_CLOSERS = frozenset("})]")
_SEPARATORS = frozenset({",", ";"})


@dataclass
class _Field:
    """One `---@field` line of a class annotation."""

    name: str
    line: int
    required: bool
    ref: str | None


@dataclass
class _Class:
    """One `---@class pi.<Name>` block and the fields it declares."""

    name: str
    line: int
    fields: list[_Field] = field(default_factory=list)


@dataclass
class _Entry:
    """One key of the `defaults` table, with its line and nested keys."""

    line: int
    children: dict[str, _Entry] | None = None


class ConfigThreeSpots(Check):
    name = "config-three-spots"
    summary = "every `---@class pi.*` field matches the `defaults` table, in both directions (G19)"
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        # Only a missing subject tree (or an unreadable subject file) is a
        # harness problem; everything else is a verdict about this tree.
        if not (root / "lua").is_dir():
            raise CheckError(f"no lua/ directory under {root} — wrong tree?")

        try:
            text = (root / SUBJECT).read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            return [
                self.finding(
                    f"{SUBJECT} not found — no `---@class {ROOT_CLASS}` and no `defaults` table to compare",
                    SUBJECT,
                    severity="warn",
                )
            ]
        except OSError as exc:
            raise CheckError(f"cannot read {SUBJECT}: {exc}") from exc

        # Comments included on purpose: the annotation side *is* comments.
        tokens = lua.tokenize(text)

        classes = _classes(tokens)
        root_class = classes.get(ROOT_CLASS)
        if root_class is None:
            return [
                self.finding(
                    f"no `---@class {ROOT_CLASS}` annotation in {SUBJECT} — nothing to compare the `defaults` "
                    "table against",
                    SUBJECT,
                    severity="warn",
                )
            ]

        table = _defaults_table(tokens)
        if table is None:
            return [
                self.finding(
                    f"`---@class {ROOT_CLASS}` is annotated but there is no `local defaults = {{` table to "
                    "compare it with",
                    SUBJECT,
                    root_class.line,
                    severity="warn",
                )
            ]
        entries, _ = table

        mismatches: list[tuple[int, str]] = []
        _walk(classes, ROOT_CLASS, "", entries, mismatches)
        return [self.finding(message, SUBJECT, line) for line, message in sorted(mismatches)]

    def fixtures(self) -> list[Fixture]:
        return [
            self.fixture(
                "good",
                0,
                "nested `pi.Nested` agrees with its `defaults` subtable in both directions, and an optional "
                "field (`status_message?`) is deliberately absent from `defaults` — the allowance must stay quiet",
            ),
            self.fixture(
                "bad",
                2,
                "a required `---@field` with no entry in `defaults`, and a `defaults` key that no class declares",
            ),
            self.fixture(
                "empty",
                1,
                "a config module with no `---@class pi.Options` at all: the rule warns exactly once instead of "
                "breaking a `--root` run over a partial tree",
            ),
            self.fixture(
                "no-lua",
                0,
                "no lua/ directory at all: the subject tree is missing, so the rule refuses the input with a "
                "CheckError (exit 2) rather than reporting a clean tree",
                expect_error=True,
            ),
        ]


def _classes(tokens: list[lua.Token]) -> dict[str, _Class]:
    """Map class name -> its `---@field` declarations, from comment tokens.

    A `---@class` starts a block; `---@field` lines on the immediately following
    lines extend it. Any other token — code, a prose comment, `---@alias`,
    `---@type` — ends the block, so a `---@field` can never attach to the wrong
    class further up the file.
    """
    classes: dict[str, _Class] = {}
    current: _Class | None = None
    next_line = 0
    for token in tokens:
        if token.kind != "comment":
            current = None
            continue
        end_line = token.line + token.text.count("\n")

        class_match = _CLASS_RE.match(token.text)
        if class_match:
            current = _Class(name=class_match.group(1), line=token.line)
            classes[current.name] = current
            next_line = end_line + 1
            continue

        field_match = _FIELD_RE.match(token.text)
        if field_match and current is not None and token.line == next_line:
            current.fields.append(
                _Field(
                    name=field_match.group(1),
                    line=token.line,
                    required=field_match.group(2) is None,
                    ref=_class_ref(field_match.group(3)),
                )
            )
            next_line = end_line + 1
            continue

        current = None
    return classes


def _class_ref(type_text: str) -> str | None:
    """`pi.<Name>` when the first type alternative is a plain class reference."""
    match = _REF_RE.match(type_text.strip())
    return match.group(1) if match else None


def _defaults_table(tokens: list[lua.Token]) -> tuple[dict[str, _Entry], int] | None:
    """Locate `local defaults = {` and parse it; `None` when it is absent."""
    for index in range(len(tokens) - 3):
        if (
            tokens[index].is_name("local")
            and tokens[index + 1].is_name("defaults")
            and tokens[index + 2].is_punct("=")
            and tokens[index + 3].is_punct("{")
        ):
            entries, _ = _parse_table(tokens, index + 3)
            return entries, tokens[index + 3].line
    return None


def _parse_table(tokens: list[lua.Token], index: int) -> tuple[dict[str, _Entry], int]:
    """Parse the table constructor at `tokens[index]`, returning its keys and the next index.

    Keyed entries are recorded with their line; positional entries (array values)
    are skipped by `_skip_value`, so they are values, never keys.
    """
    index += 1  # past `{`
    entries: dict[str, _Entry] = {}
    while index < len(tokens):
        token = tokens[index]
        if token.kind == "comment":
            index += 1
            continue
        if token.is_punct("}"):
            return entries, index + 1
        if token.kind == "punct" and token.text in _SEPARATORS:
            index += 1
            continue

        key: str | None = None
        key_line = 0
        if token.kind == "name" and index + 1 < len(tokens) and tokens[index + 1].is_punct("="):
            key, key_line = token.text, token.line
            index += 2
        elif token.is_punct("["):
            key, key_line, index = _bracket_key(tokens, index)

        if key is None:
            index = _skip_value(tokens, index)
            continue
        if index < len(tokens) and tokens[index].is_punct("{"):
            children, index = _parse_table(tokens, index)
            entries[key] = _Entry(line=key_line, children=children)
        else:
            index = _skip_value(tokens, index)
            entries[key] = _Entry(line=key_line)
    return entries, index


def _bracket_key(tokens: list[lua.Token], index: int) -> tuple[str | None, int, int]:
    """Parse `["name"] = value`; return (key, line, next_index) or (None, line, index)."""
    start = index
    line = tokens[index].line
    parts: list[str] = []
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token.kind == "comment":
            index += 1
            continue
        if token.is_punct("]"):
            index += 1
            break
        if token.kind == "string" and token.value is not None and not parts:
            parts.append(token.value)
        elif token.kind == "name":
            parts.append(token.text)
        index += 1
    else:
        return None, line, start
    if index < len(tokens) and tokens[index].is_punct("="):
        return "".join(parts) or "?", line, index + 1
    return None, line, start


def _skip_value(tokens: list[lua.Token], index: int) -> int:
    """Advance past one value, respecting nested brackets, to the next key boundary."""
    depth = 0
    while index < len(tokens):
        token = tokens[index]
        if token.kind == "comment":
            index += 1
            continue
        if token.kind == "punct":
            if token.text in _OPENERS:
                depth += 1
            elif token.text in _CLOSERS:
                if depth == 0:
                    return index
                depth -= 1
            elif depth == 0 and token.text in _SEPARATORS:
                return index
        index += 1
    return index


def _walk(
    classes: dict[str, _Class],
    class_name: str,
    dotted: str,
    entries: dict[str, _Entry],
    out: list[tuple[int, str]],
) -> None:
    """Compare one class against its `defaults` subtable, then recurse into class-typed fields."""
    declared = {declared_field.name: declared_field for declared_field in classes[class_name].fields}

    for name, entry in entries.items():
        if name not in declared:
            where = f"{dotted}.{name}" if dotted else name
            out.append(
                (
                    entry.line,
                    f"{ROOT_CLASS} defaults key `{where}` is not declared by a `---@field` in {class_name}",
                )
            )

    for declared_field in classes[class_name].fields:
        where = f"{dotted}.{declared_field.name}" if dotted else declared_field.name
        entry = entries.get(declared_field.name)
        if entry is None:
            # Optional fields legitimately have no default — see the docstring.
            if declared_field.required:
                out.append((declared_field.line, f"{ROOT_CLASS} field `{where}` has no entry in defaults"))
            continue
        if entry.children is None:
            continue
        child = declared_field.ref
        if child is None or child not in classes:
            continue  # union / array / inline table / alias / undeclared: not modelled as a class
        _walk(classes, child, where, entry.children, out)
