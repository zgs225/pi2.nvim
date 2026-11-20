"""G14 — `before_each` / `after_each` must sit inside a `describe(...)` closure.

Plenary's busted runner only honours `before_each` / `after_each` when they are
registered on a `describe` block. Placed at the top of a spec file — or inside
any function that is not a `describe` callback — they are evaluated while the
file is loaded, attach to nothing, and **silently** do nothing; the spec body
then runs a second time without its setup (or `make test` exits 1 with no
assertion message to show, which is worse: the file looks broken and the cause
is one line away). Nothing in the test run names the mistake, so it has to be a
static gate: regressions of this shape have shipped before (gotcha G14).

The detector, in three sentences
--------------------------------
Every `tests/*_spec.lua` is lexed with `lua.code_tokens` — comments and string
bodies never reach the matcher, so a `-- before_each` note or the literal
`"before_each"` in an assertion is not evidence — and the token stream is
walked once, maintaining a stack of open frames: one per `function`, one per
`if` / `do` / `for` / `while` block (`end` closes the innermost of either), and
one per `(` / `{` / `[` bracket. When a `function` opens, the frame is marked
`describe_arg` if the innermost open bracket is a `(` whose callee name token is
`describe` — i.e. the token before that `(` is `describe`, whether the closure
is the only argument or follows a name/comma. A `before_each` / `after_each`
name token that is a call (the next token is `(`) is a finding unless its
**innermost enclosing function frame** is a `describe_arg`, so a hook at the
chunk top level, inside a top-level `if`/`do` block, or inside any other
function (an `it` callback, a local helper) is reported at the hook's own line.

What it deliberately cannot catch
---------------------------------
* **Aliasing.** `local be = before_each; be(fn)` — the callee token is `be`, so
  the rule is blind to it. Same for `before_each` passed around as a value and
  called through a variable.
* **A hook behind a wrapper function.** `describe("x", wrap(function() …
  before_each(…) end))` (or a shared `local function setup()` that calls
  `before_each` and is itself called inside a `describe`) is reported, because
  the innermost enclosing function is `wrap`'s / `setup`'s closure, not
  `describe`'s. That direction is a false positive by design: it is the same
  lexical shape as `it(...)` callbacks, and telling "this helper is only called
  from a describe" apart is a call-graph question, not a lexical one.
* **A non-literal `describe`.** `local d = describe; d("x", function() … end)`
  is not modelled; only the literal name token is.

Measured numbers (this tree, commit `d9ebcaf`)
----------------------------------------------
* **174** files match `tests/*_spec.lua` (154 of them contain a hook at all)
  and the step costs about 2 s of lexing, no `git` call and no child process.
* **478** raw `before_each` / `after_each` substring mentions across those
  files, of which **472** are name tokens in code — every one of them
  call-shaped, i.e. followed by `(`. The other **6** live in a comment or a
  string body and never reach the matcher, which is why this rule tokenizes
  instead of grepping (G24).
* **0 violations**: every hook call is lexically inside a `describe(...)`
  closure. `make check` on this tree stays exit 0, and no allowlist exists —
  the rule has no exception table to rot.

Warn vs error
-------------
Same split as every other rule (contract 3):

  `CheckError` (exit 2)  no `tests/` directory under `--root`: the subject tree
                         is missing, so this is the wrong tree rather than a
                         clean one (and never a silent pass).
  `warn` (exit 1)        `tests/` exists but holds no `*_spec.lua`: a fact about
                         the tree, exactly one warning, so a `--root` run over a
                         partial checkout stays usable and the gap is visible.
  `error` (exit 1)       one finding per misplaced hook, at its own line, with
                         the repo-relative path (`tests/foo_spec.lua`).

The glob is `tests/*_spec.lua` and deliberately not recursive: fixture trees
(`scripts/checks/fixtures/**`) and nested helper directories are inputs, never
subjects.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

SPEC_DIR = "tests"
SPEC_GLOB = "*_spec.lua"
HOOKS = frozenset({"before_each", "after_each"})
DESCRIBE = "describe"

FUNCTION = "function"
BLOCK = "block"
LOOP = "loop"  # a `for` / `while` whose closing `do` has not been seen yet
BRACKET = "bracket"

_OPENERS = frozenset({"(", "{", "["})
_CLOSERS = frozenset({")", "}", "]"})


@dataclass
class _Frame:
    """One open lexical scope: a function body, an `end`-closed block, or a bracket."""

    kind: str
    describe_arg: bool = False  # function: the closure is an argument of `describe(...)`
    callee: str | None = None  # bracket `(`: the name token immediately before it


class SpecScope(Check):
    name = "spec-scope"
    summary = "`before_each`/`after_each` is inside a `describe(...)` closure in every tests/*_spec.lua (G14)"
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        # Only a missing subject tree is a harness problem; everything else is a
        # verdict about this tree.
        spec_dir = root / SPEC_DIR
        if not spec_dir.is_dir():
            raise CheckError(f"no {SPEC_DIR}/ directory under {root} — wrong tree?")

        specs = sorted(path for path in spec_dir.glob(SPEC_GLOB) if path.is_file())
        if not specs:
            return [
                self.finding(
                    f"{SPEC_DIR}/ holds no {SPEC_GLOB} file — nothing to check hook scoping on",
                    f"{SPEC_DIR}/",
                    severity="warn",
                )
            ]

        findings: list[Finding] = []
        for path in specs:
            rel = path.relative_to(root).as_posix()
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                raise CheckError(f"cannot read {rel}: {exc}") from exc
            for line, message in _scan(lua.code_tokens(text)):
                findings.append(self.finding(message, rel, line))
        return findings

    def fixtures(self) -> list[Fixture]:
        return [
            self.fixture(
                "good",
                0,
                "every hook is inside a `describe(...)` closure (including a nested describe), while a comment "
                "and a string literal mentioning `before_each` prove the matcher only ever sees code tokens",
            ),
            self.fixture("bad", 1, "one `before_each` at the chunk top level next to a compliant describe"),
            self.fixture(
                "bad-both",
                2,
                "both hooks at the chunk top level: G14 says these no-op and the file fails with no assertion",
            ),
            self.fixture(
                "bad-blocks",
                3,
                "hooks inside a top-level `if` block, a top-level `do` block and a local helper function inside a "
                "describe — open blocks are not a `describe` closure either",
            ),
            self.fixture(
                "empty",
                1,
                "tests/ with no `*_spec.lua`: the rule has nothing to check, which warns exactly once instead of "
                "reporting a clean tree",
            ),
            self.fixture(
                "no-tests",
                0,
                "no tests/ directory at all: the subject tree is missing, so the rule refuses the input with a "
                "CheckError (exit 2) instead of reporting it clean or warned",
                expect_error=True,
            ),
        ]


def _scan(tokens: list[lua.Token]) -> list[tuple[int, str]]:
    """Return (line, message) for every hook call that is not inside a describe closure."""
    frames: list[_Frame] = []
    out: list[tuple[int, str]] = []

    for index, token in enumerate(tokens):
        if token.kind == "punct":
            if token.text in _OPENERS:
                callee = None
                if token.text == "(" and index > 0 and tokens[index - 1].kind == "name":
                    callee = tokens[index - 1].text
                frames.append(_Frame(BRACKET, callee=callee))
            elif token.text in _CLOSERS:
                _close_bracket(frames)
            continue

        if token.kind != "name":
            continue
        name = token.text

        if name == FUNCTION:
            frames.append(_Frame(FUNCTION, describe_arg=_is_describe_argument(frames)))
        elif name in ("if", "do", "for", "while", "end"):
            _block_keyword(frames, name)
        elif name in HOOKS and _is_call(tokens, index):
            enclosing = _enclosing_function(frames)
            if enclosing is None:
                out.append(
                    (
                        token.line,
                        f"`{name}` is outside any `function` (chunk top level, or a top-level block) — a "
                        "`describe(...)` closure is the only place plenary honours it, so this one silently "
                        "no-ops and the file fails with no assertion (G14)",
                    )
                )
            elif not enclosing.describe_arg:
                out.append(
                    (
                        token.line,
                        f"`{name}` is inside a function that is not a `describe(...)` argument — plenary only "
                        "honours hooks registered on a describe block (G14)",
                    )
                )
    return out


def _block_keyword(frames: list[_Frame], name: str) -> None:
    """Maintain the `end`-closed block stack for `if` / `do` / `for` / `while` / `end`."""
    if name == "end":
        for position in range(len(frames) - 1, -1, -1):
            if frames[position].kind in (FUNCTION, BLOCK, LOOP):
                del frames[position:]
                return
        return  # stray `end`: the parse gate owns real syntax errors

    if name in ("for", "while"):
        frames.append(_Frame(LOOP))
        return

    if name == "do":
        # A `for` / `while` header ends in its own `do`, which opens no block.
        innermost = _innermost_scope(frames)
        if innermost is not None and innermost.kind == LOOP:
            innermost.kind = BLOCK
        else:
            frames.append(_Frame(BLOCK))
        return

    frames.append(_Frame(BLOCK))  # `if`


def _close_bracket(frames: list[_Frame]) -> None:
    """Pop the innermost bracket frame; ignore a closer with no opener."""
    for position in range(len(frames) - 1, -1, -1):
        if frames[position].kind == BRACKET:
            del frames[position]
            return


def _innermost_scope(frames: list[_Frame]) -> _Frame | None:
    """The innermost frame that is not a bracket (expressions sit inside brackets)."""
    for frame in reversed(frames):
        if frame.kind != BRACKET:
            return frame
    return None


def _enclosing_function(frames: list[_Frame]) -> _Frame | None:
    """The innermost open `function` frame, if any."""
    for frame in reversed(frames):
        if frame.kind == FUNCTION:
            return frame
    return None


def _is_describe_argument(frames: list[_Frame]) -> bool:
    """Is the `function` being opened an argument of a `describe(...)` call?

    True when the innermost open bracket is a `(` whose callee name token is
    `describe` — the closure is then `describe(name, function() … end)` or
    `describe(function() … end)`, and a nested `describe` simply becomes the new
    innermost bracket.
    """
    if not frames:
        return False
    innermost = frames[-1]
    return innermost.kind == BRACKET and innermost.callee == DESCRIBE


def _is_call(tokens: list[lua.Token], index: int) -> bool:
    """Is the name token at `index` called — `name(` — rather than defined or accessed?"""
    if index + 1 >= len(tokens) or not tokens[index + 1].is_punct("("):
        return False
    if index == 0:
        return True
    previous = tokens[index - 1]
    # `function before_each(...)` is a definition; `M.before_each(...)` and
    # `obj:before_each(...)` are somebody else's function, not the plenary hook.
    if previous.kind == "name" and previous.text == FUNCTION:
        return False
    return not (previous.kind == "punct" and previous.text in (".", ":"))
