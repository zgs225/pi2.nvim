"""G1/G2 — the two ways an `<expr>` mapping fails *silently*.

Both defects recorded in `gotchas.md` are invisible to the compiler, the type
checker and (usually) the test suite, because both happen at Neovim's
expression-mapping boundary and neither raises:

  G2  a fallback that inserts raw bytes  An `<expr>` callback that returns
      `vim.keycode("<Up>")` — or `nvim_replace_termcodes("<Up>", …)`, or
      `vim.api.nvim_replace_termcodes(…)` — hands the editor the *internal*
      keycode bytes. Inside an `<expr>` mapping those are ordinary text, so
      instead of moving the cursor the buffer receives `\\x80ku`. The key must
      be returned as the literal angle-bracket string, `"<Up>"`.
  G1  a dropped buffer edit  Neovim forbids mutating the buffer while the
      expression of an `<expr>` mapping is being evaluated: the write is
      discarded with no error and no message. The write has to be deferred with
      `vim.schedule(...)` (or `vim.schedule_wrap(...)`).

Severities differ because the two defects do. G2 is a wrong line of code at a
line the rule can name, so it is an `error`. G1 needs the judgement "is this
write deferred?", which a static rule can only answer lexically (see the
non-catches below), so it is a `warn` — still blocking, never a mute.

How the subject is found
------------------------
Everything is matched on tokens from `lua.code_tokens`, never on raw source: a
commented-out registration or a `desc = "returns vim.keycode(...)"` string must
not reach the matcher (gotcha G24). A mapping is `vim.keymap.set(mode, lhs, rhs,
opts)` whose fourth argument is a table literal containing `expr = true`. Its
callback is the third argument, resolved in exactly two shapes:

  * an inline `function(...) … end`, and
  * a single bare name whose same-file definition is `function name(`,
    `local function name(` or `name = function`.

The body of that function is then the only place a detector looks. A callback
that is anything else (`opts.callback`, a module function, `require(…)`) is not
resolved and produces no finding. Two spellings of the same intent are accepted:
the `expr` key counts both bare (`expr = true`) and bracket-string
(`{ ["expr"] = true }`), and a returned call may be parenthesised
(`return (vim.keycode(…))`) — the `(` between `return` and the call is skipped
when matching the returned expression.

What this rule cannot catch (deliberately, all seven are out of static reach)
-----------------------------------------------------------------------------
  * a callback passed as a table field — `vim.keymap.set(m, l, { … })` and
    `vim.keymap.set(m, l, opts.cb, …)` — because the function is not lexically
    at the call site;
  * a callback that is a function defined in *another* file, or a method such as
    `self:history_prev()`: following a method call is a different rule (and
    following it is exactly what would make the current tree red, see below);
  * `vim.api.nvim_set_keymap(…)`, the deprecated string-rhs form, which cannot
    take a Lua callback and so cannot carry either defect;
  * a write reached through a helper call: a wrapper that itself writes the
    buffer (`Prompt:_replace_lines(…)`, `History:_append_lines(…)`) carries the
    mutation one call away, where this detector does not follow it. What *is*
    matched: the callee name `nvim_buf_set_lines` (bare or `vim.api.`-qualified)
    and an aliased `set_lines`, never a `:set_lines` method call — and the write
    is quiet only when an enclosing `vim.schedule` / `vim.schedule_wrap` call in
    the same body lexically contains it;
  * a helper behind `pcall` / `xpcall` inside an `<expr>` callback:
    `pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, { "" })` passes the
    callee as a *value*, so there is no `name(` for the detector to see and the
    dropped write goes unreported;
  * a keymap registered through an alias of the module — `local keymap =
    vim.keymap; keymap.set(…)` — which is the same call under a different
    receiver. On a tree that did this *exclusively* the rule would also emit its
    single "no `vim.keymap.set(` … nothing to verify" warn: the run is not green,
    but it is the tree-level warning, not a per-mapping finding;
  * any buffer mutator other than `nvim_buf_set_lines` / an aliased `set_lines`
    (`vim.api.nvim_buf_set_text`, `nvim_put`, `vim.fn.setline`, …): the write
    detector is a name list, not a model of Neovim's buffer API.

Measured on this tree (no allowlist, `make check` is green with it)
-------------------------------------------------------------------
  * `lua/` holds exactly 3 `expr = true` mappings, all in
    `lua/pi/ui/chat/init.lua`: the calls start on 418 (`<Esc>`), 447 (`<Up>`) and
    454 (`<Down>`), their `expr = true` option sits on 421, 452 and 467. Each
    callback returns the literal `"<Esc>"` / `"<Up>"` / `"<Down>"`, so 0 G2 hits
    (findings name the call's first line, 418 / 447 / 454).
  * 0 of those callbacks write the buffer, so 0 G1 hits: the writes the recall
    paths need live in other methods behind `vim.schedule`
    (`Chat:history_prev` → `lua/pi/ui/chat/init.lua:1219-1228`, the prompt
    setters in `lua/pi/ui/chat/prompt.lua:345-386`). This is why the rule is
    same-function only: resolving `self:history_prev()` would report the real,
    correct tree.
  * The subject is 77 `*.lua` files / 1.95 MB under `lua/`. Only the 14 that
    contain the byte substring `keymap` are lexed at all (`CALL_MARKER`: a file
    without it cannot spell `vim.keymap.set`, so the prefilter can only be too
    generous, never too strict), which is what keeps the rule at 0.27 s — lexing
    all 77 cost 1.4 s, and the whole 8-rule `make check` (including this one) is
    3.1 s.

Warn vs error, and the tree contract
------------------------------------
  `CheckError`  no `lua/` directory under `--root`: the rule cannot tell a
                plugin tree from any other tree, so it refuses (exit 2).
  `warn` finding (the only one)  `lua/` exists but holds no `vim.keymap.set(`
                at all — nothing to verify is a fact about the tree, not a pass
                (G25). Reported once, not per file.
  `error` finding  a G2 violation; `warn` finding  a G1 violation. Both block.
"""

from __future__ import annotations

from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

KEYMAP_SET = ("vim", "keymap", "set")
# G2: helpers that turn "<Up>" into the internal keycode bytes.
KEYCODE_CHAINS = (
    ("vim", "keycode"),
    ("vim", "api", "nvim_replace_termcodes"),
    ("nvim_replace_termcodes",),
)
# G1: deferrals that make a buffer write legal inside an <expr> mapping.
SCHEDULE_CHAINS = (("vim", "schedule"), ("vim", "schedule_wrap"))
# G1: callee names that mutate buffer text. `set_lines` covers an alias such as
# `local set_lines = vim.api.nvim_buf_set_lines`; a `:set_lines` method call is
# excluded below because it is a different function.
WRITE_NAMES = frozenset({"nvim_buf_set_lines", "set_lines"})

_BLOCK_OPENERS = frozenset({"function", "if", "do", "repeat"})
_BLOCK_CLOSERS = frozenset({"end", "until"})

# Cheap byte prefilter before the lexer: a file without the substring `keymap`
# cannot spell `vim.keymap.set`. It can only ever be too generous (a `keymap` in
# a comment costs one lex, and the token scan then decides), never too strict —
# which is why the number is derived from the bytes and not from a second gate.
CALL_MARKER = "keymap"


class ExprMapping(Check):
    name = "expr-mapping"
    summary = (
        "an expr=true mapping must return a literal <Key> string (G2) and must not write the buffer unwrapped (G1)"
    )
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        source_root = root / "lua"
        # Without `lua/` the rule cannot tell a plugin tree from any other tree.
        if not source_root.is_dir():
            raise CheckError(f"no lua/ directory under {root} — wrong tree?")

        findings: list[Finding] = []
        mappings = 0
        for path in sorted(source_root.rglob("*.lua")):
            rel = path.relative_to(root).as_posix()
            text = _read(path, rel)
            if CALL_MARKER not in text:
                continue  # cannot hold a `vim.keymap.set(`, so nothing to lex
            found, seen = _inspect(text, rel)
            mappings += seen
            findings.extend(found)

        if mappings == 0:
            # Anti-silent-pass design (G25): a tree with no keymap is not clean,
            # it is a tree where this rule has nothing to verify.
            findings.append(
                self.finding(
                    "no `vim.keymap.set(` call anywhere under lua/ — nothing to verify on this tree",
                    "lua",
                    severity="warn",
                )
            )
        return findings

    def fixtures(self) -> list[Fixture]:
        return [
            self.fixture(
                "good",
                0,
                "six negative controls in one tree: an <expr> mapping returning the literal `<Esc>`, an "
                "<expr> callback whose `nvim_buf_set_lines` sits inside `vim.schedule(...)`, a NON-expr "
                "mapping writing the buffer directly, an <expr> mapping whose same-file named callback "
                "returns the literal `<Up>`, a bracket-string option table with no `expr` key writing the "
                "buffer, and an <expr> mapping returning a parenthesised literal `<Down>`",
            ),
            self.fixture(
                "bad-keycode",
                1,
                'G2: an <expr> callback returning `vim.keycode("<Up>")` instead of the literal `"<Up>"`',
            ),
            self.fixture(
                "bad-bracketed",
                1,
                'the two spelling bypasses: `{ ["expr"] = true }` plus `return (vim.keycode("<Up>"))` — one '
                "G2 error, so both the bracket-string option key and the parenthesised return really fire",
            ),
            self.fixture(
                "bad-write",
                1,
                "G1: an <expr> callback calling `vim.api.nvim_buf_set_lines` with no `vim.schedule` around it",
            ),
            self.fixture(
                "named-callback",
                1,
                "G2 through the second callback shape: the same-file function passed by name returns "
                "`vim.keycode(...)`, so the name resolution must really resolve its body",
            ),
            self.fixture(
                "no-keymaps",
                1,
                "lua/ with no `vim.keymap.set(` at all: a tree with nothing to verify warns once instead of "
                "reporting green (contract 3)",
            ),
            self.fixture(
                "no-lua",
                0,
                "no lua/ directory at all: the subject tree is missing, so the rule refuses the input with a "
                "CheckError (exit 2)",
                expect_error=True,
            ),
        ]


def _read(path: Path, rel: str) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise CheckError(f"cannot read {rel}: {exc}") from exc


def _inspect(text: str, rel: str) -> tuple[list[Finding], int]:
    """Findings for one file (`rel` is its repo-relative path) and the call count."""
    tokens = lua.code_tokens(text)
    # Deferred: a file with no `expr = true` never pays for the schedule scan.
    scheduled: list[tuple[int, int]] | None = None
    findings: list[Finding] = []
    seen = 0

    for index, token in enumerate(tokens):
        open_index = _call_open(tokens, index, KEYMAP_SET)
        if open_index is None:
            continue
        close_index = _matching(tokens, open_index)
        if close_index is None:
            continue
        seen += 1
        arguments = _arguments(tokens, open_index, close_index)
        if len(arguments) < 4:
            continue  # `vim.keymap.set(mode, lhs, rhs)`: no option table
        if not _has_expr_true(tokens, *arguments[3]):
            continue

        body = _callback_body(tokens, arguments[2])
        if body is None:
            continue  # not lexically resolvable: see the module docstring
        body_start, body_end = body

        lhs = _literal(tokens, arguments[1])
        label = f"`{lhs}`" if lhs else "a keymap"
        call_line = token.line

        keycode = _keycode_return(tokens, body_start, body_end)
        if keycode is not None:
            helper, helper_line = keycode
            findings.append(
                Finding(
                    check=ExprMapping.name,
                    severity="error",
                    path=rel,
                    line=call_line,
                    message=(
                        f"{label} is registered with `expr = true` and its callback returns "
                        f"`{helper}(...)` (line {helper_line}): an <expr> mapping must return the literal "
                        'angle-bracket string (e.g. "<Up>"), never the internal keycode bytes, which get '
                        "inserted as text (G2)"
                    ),
                )
            )

        if scheduled is None:
            scheduled = _call_spans(tokens, SCHEDULE_CHAINS)
        write = _direct_write(tokens, body_start, body_end, scheduled)
        if write is not None:
            callee, write_line = write
            findings.append(
                Finding(
                    check=ExprMapping.name,
                    severity="warn",
                    path=rel,
                    line=call_line,
                    message=(
                        f"{label} is registered with `expr = true` and its callback calls `{callee}(...)` "
                        f"(line {write_line}) without `vim.schedule`: Neovim drops a buffer write made while "
                        "the expression is being evaluated — defer it in `vim.schedule(function() … end)` (G1)"
                    ),
                )
            )

    return findings, seen


def _call_open(tokens: list[lua.Token], index: int, chain: tuple[str, ...]) -> int | None:
    """Index of the `(` when `tokens[index:]` spells `a.b.c(` for `chain`."""
    probe = index
    for position, name in enumerate(chain):
        if position:
            if probe >= len(tokens) or not tokens[probe].is_punct("."):
                return None
            probe += 1
        if probe >= len(tokens) or not tokens[probe].is_name(name):
            return None
        probe += 1
    if probe < len(tokens) and tokens[probe].is_punct("("):
        return probe
    return None


def _call_spans(tokens: list[lua.Token], chains: tuple[tuple[str, ...], ...]) -> list[tuple[int, int]]:
    """Token spans `(open_paren, close_paren)` of every call in `chains`, file-wide."""
    spans: list[tuple[int, int]] = []
    for index in range(len(tokens)):
        for chain in chains:
            open_index = _call_open(tokens, index, chain)
            if open_index is None:
                continue
            close_index = _matching(tokens, open_index)
            if close_index is not None:
                spans.append((open_index, close_index))
    return spans


def _matching(tokens: list[lua.Token], open_index: int) -> int | None:
    """Index of the bracket closing the one at `open_index` (`(`, `[` or `{`)."""
    depth = 0
    for index in range(open_index, len(tokens)):
        token = tokens[index]
        if token.kind != "punct":
            continue
        if token.text in "([{":
            depth += 1
        elif token.text in ")]}":
            depth -= 1
            if depth == 0:
                return index
    return None


def _arguments(tokens: list[lua.Token], open_index: int, close_index: int) -> list[tuple[int, int]]:
    """Token spans `(start, end)` of each argument of the call, `end` exclusive."""
    spans: list[tuple[int, int]] = []
    depth = 0
    start = open_index + 1
    for index in range(open_index + 1, close_index):
        token = tokens[index]
        if token.kind != "punct":
            continue
        if token.text in "([{":
            depth += 1
        elif token.text in ")]}":
            depth -= 1
        elif token.text == "," and depth == 0:
            spans.append((start, index))
            start = index + 1
    spans.append((start, close_index))
    return spans


def _has_expr_true(tokens: list[lua.Token], start: int, end: int) -> bool:
    """Does the option-table span set `expr = true`, bare or `["expr"] = true`?

    Both spellings are the same Lua field. The bracket-string form puts its key
    one bracket deeper (`{` -> 1, `[` -> 2), which is why the key is looked for
    at depth 1 when bare and at depth 2 when bracketed: a nested table such as
    `{ cb = { ["expr"] = true } }` is a field of a *different* table and must not
    turn this mapping into an `<expr>` one.
    """
    if start >= end or not tokens[start].is_punct("{"):
        return False
    depth = 0
    for index in range(start, end):
        token = tokens[index]
        if token.kind == "punct" and token.text in "([{":
            depth += 1
            continue
        if token.kind == "punct" and token.text in ")]}":
            depth -= 1
            continue
        if depth == 1 and token.is_name("expr") and _assigns_true(tokens, index + 1, end):
            return True
        bracketed = (
            depth == 2
            and token.kind == "string"
            and token.value == "expr"
            and index > start
            and tokens[index - 1].is_punct("[")
            and index + 1 < end
            and tokens[index + 1].is_punct("]")
        )
        if bracketed and _assigns_true(tokens, index + 2, end):
            return True
    return False


def _assigns_true(tokens: list[lua.Token], index: int, end: int) -> bool:
    """Do the tokens at `index` (within `end`) read `= true`?"""
    return index + 1 < end and tokens[index].is_punct("=") and tokens[index + 1].is_name("true")


def _callback_body(tokens: list[lua.Token], span: tuple[int, int]) -> tuple[int, int] | None:
    """Token body of the callback argument: an inline function or a same-file name."""
    start, end = span
    if start >= end:
        return None
    if tokens[start].is_name("function"):
        return start, _block_end(tokens, start)
    if end - start == 1 and tokens[start].kind == "name":
        return _named_function(tokens, tokens[start].text)
    if tokens[start].is_punct("("):
        # `(function() … end)` — a parenthesised function expression.
        probe = start + 1
        if probe < end and tokens[probe].is_name("function"):
            return probe, _block_end(tokens, probe)
    return None


def _named_function(tokens: list[lua.Token], name: str) -> tuple[int, int] | None:
    """Body of `function name(`, `local function name(` or `name = function`."""
    for index, token in enumerate(tokens):
        if not token.is_name("function"):
            continue
        probe = index + 1
        if probe < len(tokens) and tokens[probe].is_name(name):
            return index, _block_end(tokens, index)
        assigned = (
            index >= 2
            and tokens[index - 1].is_punct("=")
            and tokens[index - 2].is_name(name)
            and not (index >= 3 and tokens[index - 3].is_punct("."))
        )
        if assigned:
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


def _literal(tokens: list[lua.Token], span: tuple[int, int]) -> str | None:
    """The string value of a single-string-token span, else None."""
    start, end = span
    if end - start == 1 and tokens[start].kind == "string":
        return tokens[start].value
    return None


def _keycode_return(tokens: list[lua.Token], start: int, end: int) -> tuple[str, int] | None:
    """First `return [(]…<keycode helper>(` inside the body, as (helper, line).

    A `(` right after `return` is skipped (repeatedly), because
    `return (vim.keycode("<Up>"))` is the same expression as
    `return vim.keycode("<Up>")` — the parenthesis is cosmetic and must not hide
    the G2 defect.
    """
    for index in range(start, end):
        if not tokens[index].is_name("return"):
            continue
        probe = index + 1
        while probe < end and tokens[probe].is_punct("("):
            probe += 1
        for chain in KEYCODE_CHAINS:
            if _call_open(tokens, probe, chain) is not None:
                return ".".join(chain), tokens[index].line
    return None


def _direct_write(
    tokens: list[lua.Token],
    start: int,
    end: int,
    scheduled: list[tuple[int, int]],
) -> tuple[str, int] | None:
    """First buffer write in the body that no `vim.schedule` call encloses."""
    for index in range(start, end):
        token = tokens[index]
        if token.kind != "name" or token.text not in WRITE_NAMES:
            continue
        if index + 1 >= len(tokens) or not tokens[index + 1].is_punct("("):
            continue
        if index > 0 and tokens[index - 1].is_punct(":"):
            continue  # `x:set_lines(...)` is a method, not the buffer API
        if any(open_index < index < close_index for open_index, close_index in scheduled):
            continue  # deferred: Neovim accepts the write from the scheduled callback
        return token.text, token.line
    return None
