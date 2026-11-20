"""G20 — read `config.options` at call time, never capture it at module load.

`pi` is lazy-loaded inside the first `<leader>ap`, on a machine where
`~/.pi/agent/sessions` is multi-GB and `pi.setup()` runs on the keypress path.
The consequence that matters here is subtle and silent: `require("pi.config")`
returns a module table whose `options` field is the *deepcopy that existed when
that module was first loaded*. A binding evaluated while the chunk loads
(`local label = Config.options.labels.tool`, `local tools = require("pi.config")
.options.subagent.tools`) therefore freezes the pre-`setup()` defaults — the
option exists, the docs describe it, the user sets it, and the feature keeps
using the old value forever. No crash, no test failure, no warning (G20).

This rule reports a binding whose initializer reaches `.options` (or
`["options"]`) of a `pi.config` handle while the chunk is still running, at the
nesting depth of the chunk body:

  * the base of the member access must be `require("pi.config")` itself (with or
    without the call parens), or a **chunk-top-level** alias bound to exactly
    that call (`local Config = require("pi.config")`) and declared above it;
  * "chunk top level" means depth 0 — outside every `function` / `do` / `if` /
    `for` / `while` body. A `Config.options…` read inside a function is the
    correct pattern and never fires, and neither does an alias created inside
    one;
  * a nested `function` inside the initializer is skipped too, so
    `local M = { get = function() return Config.options.x end }` stays quiet: the
    read happens when `get()` is called, which is exactly right.

Token-level on purpose (G24): the source is tokenized with `lua.code_tokens`, so
a commented-out capture (`-- local cfg = Config.options`) and a string literal
containing the same text are never mistaken for one. The statement end is found
token by token (bracket depth plus consecutive values), never by a line regex, so
a capture split across lines is still one binding.

What this rule cannot catch — and deliberately does not pretend to
-------------------------------------------------------------------
  * a capture through a helper — **deliberate narrowing**, because deciding it
    needs the helper's body evaluated: `local o = cfg()`, `local o =
    M.options()`, or a chunk-level `local function cfg() return
    require("pi.config").options end` that a chunk-level binding then calls;
  * **a miss, not a narrowing:** a non-`local` chunk-level binding freezes
    exactly the same way and is invisible to this detector, which only looks at
    `local` declarations — `M.opts = require("pi.config").options` and a table
    field `local M = { opts = Config.options }` both go unreported;
  * **a miss:** a parenthesized base, `local o =
    (require("pi.config")).options` — the base token is then an opaque `)` and
    `_config_base` only recognises the bare call;
  * `Table.options` reached through an unrelated table (`local o =
    SomeOtherTable.options`, or a re-export such as `local options =
    require("pi").options`), because only a `pi.config` base is provable;
  * an alias created inside a function and captured later at chunk level, an
    alias re-bound after use, and `package.loaded["pi.config"]` indirection;
  * a capture inside a chunk-level `if` / `do` / `for` body: the rule's subject
    is depth 0 only, so `if x then local cfg = Config.options end` — which does
    run at load time — is a documented narrowing, not a reported defect;
    reporting it would make the guard depend on a line-oriented notion of
    "block" that the tokens cannot settle without evaluating the condition;
  * a capture whose value is later re-read correctly — the module is not
    evaluated, so a pattern is all this rule can see;
  * Lua outside `lua/` (`tests/`, `scripts/e2e/`), which are developer-run.

Measured on this tree (2026-02, `feat/remaining-gates`): 77 `*.lua` files under
`lua/`, 38 of them mentioning `require("pi.config")` — 34 bind the alias at chunk
level and 4 only inside a function — and **0** module-level captures. The idiom
in use is the safe one: `local Config = require("pi.config")` at the top, and
207 `options` reads inside function bodies (call time), so the real tree reports
nothing and this rule ships **without an allowlist**. Re-measured after the
`for` / `while` depth fix: still 0 captures, and `lua/` has 0 chunk-level
`for` / `while` at all — so the leak that was hiding later captures never masked
a real one here, which is precisely why it needed a fixture rather than a green
run. That number is also why the
detector is narrowed rather than allowed: any widening that starts reporting the
34 compliant aliases would make the gate red on a clean tree, so the alias itself
is never a finding — only a `.options` read at chunk depth is.

Warn vs error
-------------
  `CheckError`  no `lua/` directory under `--root`, or a file that cannot be
                read: the tree is wrong or the harness is broken, so exit 2
                rather than a verdict.
  `warn` finding  `lua/` exists but holds no `*.lua` file at all — there is
                nothing to check, which is a fact about the tree, not a pass
                (contract 3). Exactly one warning.
  `error` finding  one per capturing binding, at the binding's own line.
"""

from __future__ import annotations

from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

CONFIG_MODULE = "pi.config"
OPTION_KEY = "options"
REQUIRE = "require"

# Block structure, by keyword. `elseif` / `else` / `then` neither open nor close.
# `for` / `while` are separate because their header is closed by its own `do`,
# which opens nothing: counting both leaked one level per loop and made every
# later chunk-level capture invisible (`for i = 1, 2 do end` then a capture
# reported 0 findings).
HEADER_OPENERS = frozenset({"for", "while"})
BLOCK_OPENERS = HEADER_OPENERS | frozenset({"function", "do", "if", "repeat"})
BLOCK_CLOSERS = frozenset({"end", "until"})

# Tokens that start a new statement: the initializer of a `local` ends here.
STATEMENT_KEYWORDS = frozenset(
    {
        "local",
        "function",
        "if",
        "for",
        "while",
        "do",
        "return",
        "repeat",
        "until",
        "end",
        "break",
        "goto",
        "else",
        "elseif",
        "then",
    }
)
BRACKET_OPEN = frozenset("([{")
BRACKET_CLOSE = frozenset(")]}")
# A token that can end a value: two of these in a row is a new statement, not an
# expression continuation (`local x = Config.options.a` then `M.foo()`).
VALUE_KINDS = frozenset({"name", "string", "number"})
VALUE_PUNCT = frozenset({")", "]", "}"})


class _Blocks:
    """Block depth over a token stream, with `for` / `while` headers counted once.

    `for` / `while` open their block at the keyword and then spell a `do` that
    opens nothing; every other opener (`function`, `do`, `if`, `repeat`) opens,
    and `end` / `until` close. The header `do` is remembered per depth, so a `do`
    statement in a nested body (`for i = 1, f(function() do end) do`) cannot be
    mistaken for a header. Leaking a level was a real false negative: one
    chunk-level loop hid every chunk-level capture below it.
    """

    def __init__(self) -> None:
        self.depth = 0
        self._header_do: set[int] = set()

    def advance(self, token: lua.Token) -> None:
        """Update the depth for `token`; non-name tokens change nothing."""
        if token.kind != "name":
            return
        if token.text in HEADER_OPENERS:
            self.depth += 1
            self._header_do.add(self.depth)
            return
        if token.text in BLOCK_OPENERS:
            if token.text == "do" and self.depth in self._header_do:
                self._header_do.discard(self.depth)  # the header's own `do`: already counted
            else:
                self.depth += 1
            return
        if token.text in BLOCK_CLOSERS:
            self.depth = max(self.depth - 1, 0)
            self._header_do = {depth for depth in self._header_do if depth <= self.depth}


class ConfigReadAtCallTime(Check):
    name = "config-read-at-call-time"
    summary = 'no module-level binding captures require("pi.config").options (G20 — a frozen pre-setup() snapshot)'
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        # Only a missing subject tree is a harness problem: without `lua/` this
        # may not be a plugin tree at all, so no verdict is possible.
        source = root / "lua"
        if not source.is_dir():
            raise CheckError(f"no lua/ directory under {root} — wrong tree?")

        files = sorted(source.rglob("*.lua"))
        if not files:
            # Anti-silent-pass (G25): no Lua under `lua/` is not "clean", it is a
            # tree where this rule has nothing to verify.
            return [
                self.finding(
                    "no *.lua file under lua/ — nothing to check for a module-level config capture",
                    "lua",
                    severity="warn",
                )
            ]

        findings: list[Finding] = []
        for path in files:
            rel = path.relative_to(root).as_posix()
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                raise CheckError(f"cannot read {rel}: {exc}") from exc
            for binding, base, line in _captures(lua.code_tokens(text)):
                findings.append(
                    self.finding(
                        f"`local {binding}` captures `{base}.{OPTION_KEY}` while the chunk loads — the value is "
                        "frozen before `setup()` and a later config change never reaches it; read it inside the "
                        "function that needs it (G20)",
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
                'a chunk-top-level `local Config = require("pi.config")` alias plus call-time reads inside '
                "functions — and, as negative controls, a commented-out capture and a string literal that spells "
                "the banned form",
            ),
            self.fixture(
                "bad",
                3,
                "three of the four capture forms at chunk top level: `Config.options…`, "
                '`Config.options.subagent.tools`, and `require("pi.config")["options"]`',
            ),
            self.fixture(
                "after-loop",
                1,
                "a chunk-level `for … do … end` and `while … do … end` followed by a chunk-level capture: the "
                "header `do` opens nothing, so the loop must not leak a level and hide the capture below it",
            ),
            self.fixture(
                "empty-lua",
                1,
                "lua/ present but no *.lua file at all: a tree with nothing to check warns exactly once instead "
                "of reporting a clean gate",
            ),
            self.fixture(
                "no-lua",
                0,
                "no lua/ directory at all: the subject tree is missing, so the rule refuses the input with a "
                "CheckError (exit 2) instead of reporting a clean or a warned tree",
                expect_error=True,
            ),
        ]


def _captures(tokens: list[lua.Token]) -> list[tuple[str, str, int]]:
    """Every chunk-level `local … = <pi.config handle>.options …` binding.

    Returns `(binding_name, base_text, line)` triples. One pass, in file order, so
    an alias is only in scope below its own declaration — a capture written above
    the alias would read a nil global, not a snapshot, and is not this defect.
    """
    found: list[tuple[str, str, int]] = []
    aliases: set[str] = set()
    blocks = _Blocks()
    index = 0
    while index < len(tokens):
        token = tokens[index]
        blocks.advance(token)

        if blocks.depth == 0 and token.is_name("local"):
            names, span = _binding(tokens, index)
            if span is not None:
                start, end = span
                if len(names) == 1 and _is_config_require(tokens, start, end):
                    # `local Config = require("pi.config")` is the safe idiom:
                    # only the `.options` read is a defect, never the alias.
                    aliases.add(names[0])
                else:
                    base = _option_base(tokens, start, end, aliases)
                    if base is not None:
                        binding = names[0] if len(names) == 1 else ", ".join(names)
                        found.append((binding, base, token.line))
        index += 1
    return found


def _binding(tokens: list[lua.Token], start: int) -> tuple[list[str], tuple[int, int] | None]:
    """Names and initializer span of the `local …` at `tokens[start]`.

    `local function f()` is a declaration with no initializer expression, and
    `local x` alone has no initializer at all; both come back as `([], None)` or
    `(names, None)`.
    """
    index = start + 1
    if index < len(tokens) and tokens[index].is_name("function"):
        return [], None
    names: list[str] = []
    while index < len(tokens) and tokens[index].kind == "name":
        names.append(tokens[index].text)
        index += 1
        if index < len(tokens) and tokens[index].is_punct(","):
            index += 1
            continue
        break
    if not names or index >= len(tokens) or not tokens[index].is_punct("="):
        return names, None
    begin = index + 1
    return names, (begin, _expression_end(tokens, begin))


def _expression_end(tokens: list[lua.Token], start: int) -> int:
    """Index one past the initializer expression that starts at `tokens[start]`.

    Deliberately shallow: bracket depth keeps calls and table constructors
    together, block depth keeps a `function` body's `return`/`end` from ending
    the statement, and a keyword or a second consecutive value at both depths 0
    is the next statement. At depth 0 a block *opener* other than `function`
    (`if`, `do`, `for`, `while`, `repeat`) cannot be part of an expression, so it
    ends the statement — getting this wrong let an initializer swallow the block
    that followed it and lose the alias declared before it.
    """
    brackets = 0
    blocks = _Blocks()
    index = start
    while index < len(tokens):
        token = tokens[index]
        if token.kind == "punct":
            if token.text in BRACKET_OPEN:
                brackets += 1
            elif token.text in BRACKET_CLOSE:
                if brackets == 0:
                    return index
                brackets -= 1
            elif token.text == ";" and brackets == 0 and blocks.depth == 0:
                return index
            index += 1
            continue
        if token.kind == "name" and brackets == 0:
            if blocks.depth == 0:
                if token.text in BLOCK_OPENERS:
                    if token.text != "function":
                        return index  # `if`/`do`/`for`/`while`/`repeat` is never inside an expression
                elif token.text in STATEMENT_KEYWORDS:
                    return index
                elif index > start and _ends_value(tokens[index - 1]):
                    return index
            blocks.advance(token)
        index += 1
    return len(tokens)


def _ends_value(token: lua.Token) -> bool:
    """Whether `token` can be the last token of a value expression."""
    return token.kind in VALUE_KINDS or (token.kind == "punct" and token.text in VALUE_PUNCT)


def _is_config_require(tokens: list[lua.Token], start: int, end: int) -> bool:
    """Whether `tokens[start:end]` is exactly one `require("pi.config")` call."""
    span = tokens[start:end]
    if len(span) == 4:
        return (
            span[0].is_name(REQUIRE) and span[1].is_punct("(") and _is_config_module(span[2]) and span[3].is_punct(")")
        )
    if len(span) == 2:
        return span[0].is_name(REQUIRE) and _is_config_module(span[1])
    return False


def _is_config_module(token: lua.Token) -> bool:
    """Whether `token` is the string `"pi.config"`."""
    return token.kind == "string" and token.value == CONFIG_MODULE


def _option_base(tokens: list[lua.Token], start: int, end: int, aliases: set[str]) -> str | None:
    """The base text when the initializer reaches a `pi.config` handle's `.options`.

    A `function` inside the initializer bumps `blocks`, so a read inside a
    callback stored in a table (`local M = { get = function() … end }`) is a
    call-time read and is not reported.
    """
    blocks = _Blocks()
    for index in range(start, end):
        token = tokens[index]
        if token.kind == "name":
            blocks.advance(token)
            continue
        if blocks.depth or index <= start:
            continue
        if not (token.is_punct(".") or token.is_punct("[")):
            continue
        if not _is_option_key(tokens, index, end):
            continue
        base = _config_base(tokens, index - 1, aliases)
        if base is not None:
            return base
    return None


def _is_option_key(tokens: list[lua.Token], index: int, end: int) -> bool:
    """Whether the access opener at `tokens[index]` selects the `options` field."""
    key = index + 1
    if key >= end:
        return False
    if tokens[index].is_punct("."):
        return tokens[key].is_name(OPTION_KEY)
    return (
        tokens[key].kind == "string"
        and tokens[key].value == OPTION_KEY
        and key + 1 < end
        and tokens[key + 1].is_punct("]")
    )


def _config_base(tokens: list[lua.Token], index: int, aliases: set[str]) -> str | None:
    """The rendering of `tokens[index]` when it is a live `pi.config` handle.

    Three shapes only: a chunk-top-level alias by name, the closing paren of
    `require("pi.config")`, and the parenthesis-free `require "pi.config"`.
    """
    token = tokens[index]
    if token.kind == "name":
        return token.text if token.text in aliases else None
    if token.is_punct(")") and index >= 3:
        if (
            tokens[index - 3].is_name(REQUIRE)
            and tokens[index - 2].is_punct("(")
            and _is_config_module(tokens[index - 1])
        ):
            return f'{REQUIRE}("{CONFIG_MODULE}")'
        return None
    if _is_config_module(token) and index >= 1 and tokens[index - 1].is_name(REQUIRE):
        return f'{REQUIRE}("{CONFIG_MODULE}")'
    return None
