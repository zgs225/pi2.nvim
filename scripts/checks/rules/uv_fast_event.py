"""G26, advisory only: a uv callback that touches the editor without `vim.schedule`.

G26 (`.agents/skills/develop/references/gotchas.md`) collects three traps from
one layer. A `vim.system(...)` or `vim.uv.new_timer()` callback runs in a
**libuv fast-event context**, where most `vim.api` / `vim.fn` calls raise
`E5560: … must not be called in a lua loop callback`; `timer:start(timeout,
repeat, cb)` with `repeat = 0` is a *one-shot*, so a "periodic" flush fires
exactly once; and the handle has to be held for the life of the component.
This rule reports the first two where they meet at one call site, and says
nothing about handle lifetime — that is not a source predicate.

**Static reachability cannot prove that a given callback runs on a libuv fast
event, so every finding here is `severity="info"`: the framework prints it,
counts it and carries it in `--json`, but it never changes the exit code. That
makes this rule a report and never a merge blocker — `make check` stays exit 0
however many hits it prints, and a false positive cannot block a merge. A rule
that can prove its finding uses `error` instead** (checks.md, § Severities).

Two signals, both same-function
------------------------------
signal 1 — the one-shot that looks periodic
    A `uv.new_timer()` / `vim.uv.new_timer()` assigned to a name inside a
    function, plus a `<name>:start(timeout, 0, <callback>)` (or `.start(...)`)
    in that same function: the second argument, `repeat`, is the literal `0`,
    so the timer fires once although the call reads like a periodic tick.
signal 2 — `vim.system`'s callback
    A `vim.system(cmd, opts, <callback>)` whose callback argument is a literal
    `function(...) … end` that calls `vim.api.…`, `vim.fn.…` or an `nvim_*`
    function and is not lexically inside a `vim.schedule(…)` /
    `vim.schedule_wrap(…)`.

A call is reported only when both halves hold (one-shot **and** an unguarded
editor call; spawn **and** an unguarded editor call). The finding points at the
**editor call**, not at the timer or the spawn: that is the line to fix, and
the guard belongs around it. One finding per unguarded call, so one body with
two unguarded calls reports two.

What it cannot catch
--------------------
Every one of these is a non-catch by construction, not a suppressed finding:

* A callback handed to `vim.schedule_wrap(function() … end)` is guarded and is
  never reported — 12 of the 13 timer callbacks in this tree are exactly that.
* A named helper is not resolved. `vim.system(cmd, opts, done)`,
  `vim.system` inside `pcall(...)` (the callback is then the *outer* call's
  last argument), and `local fn = function() … end` passed by name are all
  invisible: resolving them needs a scope and alias model, and the rule is
  deliberately same-function. `ensure_timer():start(...)`
  (`lua/pi/attention.lua`) is the timer-side equivalent — the handle comes back
  from a factory call, so there is no local name to match.
* Only a `repeat` of the literal `0` is a signal. A *repeating* timer whose
  callback is unguarded is the same crash class and is not reported, and
  `<handle>.start(handle, timeout, repeat, cb)` (the dot form with the handle as
  its first argument) shifts the argument positions and is a miss.
* The guard is judged lexically, per call: an unguarded call in a body that
  also contains one `vim.schedule` is still reported, but a call into a helper
  that schedules internally reads as unguarded — a false positive.
* `vim.uv.*` / luv calls (`vim.uv.kill`, `fs_stat`, `now`) are legal in a fast
  event and are never matched, nor is anything outside `lua/**/*.lua`.

Measured numbers (this tree: 77 `*.lua` files, 1.94 MB under `lua/`)
--------------------------------------------------------------------
There are 14 `new_timer()` sites and 8 direct `vim.system(` calls, and the rule
reports **0 findings** on all of them:

* 13 of the 14 timers are started as `<name>:start(...)` on the assigned name;
  `lua/pi/attention.lua:98` is the 14th, and its `:start(...)` lives in another
  function on a handle `ensure_timer()` returns, so it is a non-catch.
* 6 of those 13 pass the literal `0` as `repeat`. 5 of the 6 wrap the callback
  in `vim.schedule_wrap(function() … end)`; the 6th
  (`lua/pi/tasks.lua:709`) is an inline one-shot whose body calls no editor API
  (`pcall(timer.stop, timer)`, `M.kill_group`, `pcall(timer.close, timer)`).
  Overall 12 of the 13 callbacks are a `vim.schedule_wrap(...)`.
* 7 of the 8 `vim.system(` calls take an inline callback and all 7 wrap its
  body in `vim.schedule` (`lua/pi/ui/diff_review.lua`); the 8th
  (`lua/pi/cache/files.lua:309`) is `:wait()`, with no callback and no fast
  event. The other 6 `vim.system` mentions are `pcall(vim.system, …)`
  references — not calls, so invisible here (their callbacks are
  `vim.schedule_wrap`'d anyway, e.g. `lua/pi/image_compress.lua`'s `done`).

So the real tree is clean because of its guards, not because the matcher is
blind: unwrapping `vim.schedule_wrap` in the matcher (a diagnostic run, not
shipped) makes the same traversal report
`lua/pi/ui/chat/history.lua:1578/1597/1599` and
`lua/pi/ui/chat/decorators.lua:101`. The fixtures below are still what proves
the rule can fire, which is why it ships as an advisory report and not as a
gate.

Cost, since `make check` is the fast gate: a file whose raw bytes contain
neither `new_timer` nor `system` is skipped before the lexer (a token's text is
a raw substring, so a skipped file provably holds no signal) — that keeps 30 of
the 77 files, 1.27 of 1.94 MB. Tokenizing and matching the kept files is
338 ms (best of 3, vs 681 ms unfiltered); the matching itself is ~40 ms and the
rest is `lua.tokenize`, dominated by `lua/pi/ui/chat/history.lua`. Nothing here
runs at Neovim startup — the rule only runs under `python3 -m scripts.checks`.

Warn vs error
-------------
  `CheckError`  no `lua/` directory under `--root`: the rule cannot tell a
                plugin tree from an arbitrary directory (exit 2).
  `warn` finding  `lua/` exists but holds no `new_timer(` and no
                `vim.system(` call: nothing for this rule to inspect. Exactly
                one warning, and it blocks (exit 1) — a tree with nothing to
                check is not a clean tree.
  `info` finding  the advisory hits described above; never changes the exit
                code.
"""

from __future__ import annotations

from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

LUA_DIR = "lua"
SUFFIX = ".lua"
NEW_TIMER = "new_timer"
SYSTEM = "system"
VIM = "vim"
SCHEDULE = "schedule"
SCHEDULE_WRAP = "schedule_wrap"
EDITOR_ROOTS = ("api", "fn")
NVIM_PREFIX = "nvim_"
ONE_SHOT = "0"
SUBJECT_MARKERS = (NEW_TIMER, "system")
KEYWORD_OPENERS = frozenset(("function", "do", "if", "repeat"))
KEYWORD_CLOSERS = frozenset(("end", "until"))
KEYWORD_BOUNDARIES = frozenset(("return", "local", "then", "do"))
PUNCT_OPENERS = frozenset(("(", "{", "["))
PUNCT_CLOSERS = frozenset((")", "}", "]"))
SEPARATORS = (":", ".")
INLINE = "inline"
GUARDED = "guarded"


class UvFastEvent(Check):
    name = "uv-fast-event"
    summary = "G26 (advisory): a one-shot uv timer or a vim.system callback that calls the editor unguarded"
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        # Only a missing subject tree is a harness problem: without `lua/` the
        # rule cannot tell a plugin tree from an arbitrary directory.
        lua_dir = root / LUA_DIR
        if not lua_dir.is_dir():
            raise CheckError(f"no {LUA_DIR}/ directory under {root} — wrong tree?")

        findings: list[tuple[str, int, str]] = []
        saw_subject = False
        for path in sorted(lua_dir.rglob(f"*{SUFFIX}")):
            if not path.is_file():
                continue
            rel = path.relative_to(root).as_posix()
            source = _read(path, rel)
            if not any(marker in source for marker in SUBJECT_MARKERS):
                # A token's text is a raw substring of the file, so a file without
                # these substrings provably holds no signal. Filtering before the
                # lexer prunes 47 of the 77 files here for free.
                continue
            hits, subject = _scan(lua.code_tokens(source))
            saw_subject = saw_subject or subject
            findings.extend((rel, line, message) for line, message in hits)

        if not saw_subject:
            # Anti-silent-pass (G25): nothing to inspect is not "clean".
            return [
                self.finding(
                    f"no `{NEW_TIMER}(` and no `{VIM}.{SYSTEM}(` call under {LUA_DIR}/ — nothing for this rule "
                    "to inspect",
                    LUA_DIR,
                    severity="warn",
                )
            ]

        return [self.finding(message, rel, line, severity="info") for rel, line, message in sorted(findings)]

    def fixtures(self) -> list[Fixture]:
        return [
            self.fixture(
                "good",
                0,
                "compliant shapes: a repeating timer whose editor work is behind `vim.schedule`, a "
                "`vim.system` callback doing the same, and a one-shot timer whose callback touches only plain Lua",
            ),
            self.fixture(
                "bad-timer",
                1,
                "one-shot timer (`repeat = 0`) whose callback calls `vim.api.nvim_buf_set_lines` unguarded: "
                "one finding, at the editor call",
            ),
            self.fixture(
                "bad-system",
                2,
                "`vim.system` callback calling `vim.api.…` and `vim.fn.…` unguarded: one finding per unguarded "
                "call, so two",
            ),
            self.fixture(
                "empty",
                1,
                "lua/ without a single `new_timer(` or `vim.system(` call: one warning, because a tree this rule "
                "cannot inspect is not a clean tree",
            ),
            self.fixture(
                "no-lua",
                0,
                "no lua/ directory at all: the subject tree is missing, so the rule refuses the input with a "
                "CheckError (exit 2) instead of reporting a clean or a warned tree",
                expect_error=True,
            ),
        ]


def _scan(tokens: list[lua.Token]) -> tuple[list[tuple[int, str]], bool]:
    """Every advisory hit in one file, plus whether the file holds either signal."""
    spans = _function_spans(tokens)
    hits: dict[tuple[int, str], str] = {}
    subject = False

    for index, token in enumerate(tokens):
        if token.is_name(NEW_TIMER) and _is_call(tokens, index):
            subject = True
            for line, chain, name in _one_shot_calls(tokens, spans, index):
                hits.setdefault(
                    (line, chain),
                    f"`{name}:start(…, {ONE_SHOT}, …)` is a one-shot timer (repeat = {ONE_SHOT}) and its callback "
                    f"calls `{chain}` from the fast event — pass the interval as `repeat` and wrap the editor "
                    "work in `vim.schedule`",
                )
            continue
        if token.is_name(VIM) and _system_open(tokens, index) is not None:
            subject = True
            for line, chain in _unguarded_system_calls(tokens, index):
                hits.setdefault(
                    (line, chain),
                    f"`{VIM}.{SYSTEM}` callback calls `{chain}` unguarded — a uv callback is a fast event, so wrap "
                    "the editor work in `vim.schedule`",
                )

    return [(line, message) for (line, _), message in sorted(hits.items())], subject


def _one_shot_calls(tokens: list[lua.Token], spans: list[tuple[int, int]], index: int) -> list[tuple[int, str, str]]:
    """Hits for one `new_timer()` site: unguarded editor calls in a one-shot's callback."""
    name = _assigned_name(tokens, index)
    if name is None:
        return []  # returned, stored in a field of an expression, or passed on: no name to follow
    start, end = _enclosing(spans, index, len(tokens))
    hits: list[tuple[int, str, str]] = []
    for cursor in range(start, end):
        if not tokens[cursor].is_name(name):
            continue
        if cursor + 3 >= len(tokens):
            continue
        separator, method, paren = tokens[cursor + 1], tokens[cursor + 2], tokens[cursor + 3]
        if not (separator.kind == "punct" and separator.text in SEPARATORS):
            continue
        if not method.is_name("start") or not paren.is_punct("("):
            continue
        args = _call_args(tokens, cursor + 3)
        if len(args) < 3 or not _is_one_shot(tokens, args[1]):
            continue  # a repeating timer (or an unresolvable `repeat`): not this signal
        kind, body_start, body_end = _callback(tokens, *args[2])
        if kind != INLINE:
            continue  # a guarded wrap, or a named helper this token scan cannot follow
        hits.extend((line, chain, name) for line, chain in _unguarded_calls(tokens, body_start, body_end))
    return hits


def _unguarded_system_calls(tokens: list[lua.Token], index: int) -> list[tuple[int, str]]:
    """Hits for one `vim.system(...)` site: unguarded editor calls in its callback.

    A call without a callback (`vim.system(...):wait()`) spawns on the main loop
    and reports nothing; so does the `pcall(vim.system, …)` form, whose callback
    is the *outer* call's last argument and therefore invisible here.
    """
    open_paren = _system_open(tokens, index)
    if open_paren is None:
        return []
    args = [arg for arg in _call_args(tokens, open_paren) if arg[0] < arg[1]]
    if not args:
        return []
    kind, body_start, body_end = _callback(tokens, *args[-1])
    if kind != INLINE:
        return []  # no callback, a guarded wrap, or a named helper
    return _unguarded_calls(tokens, body_start, body_end)


def _callback(tokens: list[lua.Token], start: int, end: int) -> tuple[str | None, int, int]:
    """Classify one call argument: an inline function body, a guarded wrap, or unresolvable."""
    if start >= end:
        return None, 0, 0
    first = tokens[start]
    if (
        first.is_name(VIM)
        and start + 2 < end
        and tokens[start + 1].is_punct(".")
        and tokens[start + 2].is_name(SCHEDULE_WRAP)
    ):
        return GUARDED, 0, 0
    if first.is_name("function"):
        return INLINE, start, _block_end(tokens, start)
    return None, 0, 0  # a bare name (a helper), a parenthesized expression, a field…


def _unguarded_calls(tokens: list[lua.Token], start: int, end: int) -> list[tuple[int, str]]:
    """Editor calls in a callback body that no `vim.schedule(…)` span covers."""
    guards = _guard_spans(tokens, start, end)
    hits: list[tuple[int, str]] = []
    for index, chain in _editor_calls(tokens, start, end):
        if any(guard_start <= index <= guard_end for guard_start, guard_end in guards):
            continue
        hits.append((tokens[index].line, chain))
    return hits


def _editor_calls(tokens: list[lua.Token], start: int, end: int) -> list[tuple[int, str]]:
    """Indices of `vim.api.X(…)` / `vim.fn.X(…)` / `nvim_X(…)` calls in a span."""
    hits: list[tuple[int, str]] = []
    index = start
    while index < end:
        token = tokens[index]
        if token.kind != "name":
            index += 1
            continue
        name_index = _editor_root_name(tokens, index)
        if name_index is not None:
            # `vim.api.nvim_…` is one call: report the longest chain, once, and
            # skip past the bare `nvim_…` name it contains.
            hits.append((name_index, ".".join(t.text for t in tokens[index : name_index + 1] if t.kind == "name")))
            index = name_index + 1
            continue
        if token.text.startswith(NVIM_PREFIX) and _is_call(tokens, index):
            hits.append((index, token.text))
        index += 1
    return hits


def _editor_root_name(tokens: list[lua.Token], index: int) -> int | None:
    """Index of the called name in `vim.api.X(…)` / `vim.fn.X(…)`, else None."""
    if not tokens[index].is_name(VIM) or index + 5 >= len(tokens):
        return None
    if not tokens[index + 1].is_punct("."):
        return None
    root = tokens[index + 2]
    if root.kind != "name" or root.text not in EDITOR_ROOTS:
        return None
    if not tokens[index + 3].is_punct("."):
        return None
    if tokens[index + 4].kind != "name" or not tokens[index + 5].is_punct("("):
        return None
    return index + 4


def _guard_spans(tokens: list[lua.Token], start: int, end: int) -> list[tuple[int, int]]:
    """Token ranges covered by a `vim.schedule(…)` / `vim.schedule_wrap(…)` call."""
    spans: list[tuple[int, int]] = []
    for index in range(start, end):
        if not tokens[index].is_name(VIM) or index + 3 >= len(tokens):
            continue
        if not tokens[index + 1].is_punct("."):
            continue
        name = tokens[index + 2]
        if name.kind != "name" or name.text not in (SCHEDULE, SCHEDULE_WRAP):
            continue
        if not tokens[index + 3].is_punct("("):
            continue
        spans.append((index, _paren_end(tokens, index + 3)))
    return spans


def _system_open(tokens: list[lua.Token], index: int) -> int | None:
    """Index of the `(` of a `vim.system(` call whose `vim` token is at `index`."""
    if not tokens[index].is_name(VIM) or index + 3 >= len(tokens):
        return None
    if not tokens[index + 1].is_punct("."):
        return None
    if not tokens[index + 2].is_name(SYSTEM) or not tokens[index + 3].is_punct("("):
        return None
    return index + 3


def _assigned_name(tokens: list[lua.Token], index: int) -> str | None:
    """The name assigned the value holding `tokens[index]`, if it is a plain assignment.

    `local timer = assert(uv.new_timer())` yields `timer`, `state.timer =
    uv.new_timer()` yields `timer`: the start call is matched on that bare name,
    which is also how `self._timer:start(...)` is written.
    """
    for back in range(index - 1, -1, -1):
        token = tokens[back]
        if token.kind == "punct" and token.text == ";":
            return None
        if token.is_punct("="):
            previous = tokens[back - 1] if back else None
            return previous.text if previous is not None and previous.kind == "name" else None
        if token.kind == "name" and (token.text in KEYWORD_CLOSERS or token.text in KEYWORD_BOUNDARIES):
            return None
    return None


def _function_spans(tokens: list[lua.Token]) -> list[tuple[int, int]]:
    """`(function token, its `end` token)` for every function in the file, in one pass."""
    spans: list[tuple[int, int]] = []
    stack: list[tuple[str, int]] = []
    for index, token in enumerate(tokens):
        if token.kind != "name":
            continue
        if token.text in KEYWORD_OPENERS:
            stack.append((token.text, index))
        elif token.text in KEYWORD_CLOSERS and stack:
            kind, opener = stack.pop()
            if kind == "function":
                spans.append((opener, index))
    return spans


def _enclosing(spans: list[tuple[int, int]], index: int, count: int) -> tuple[int, int]:
    """The narrowest function span holding `index`, or the whole file at top level.

    This is what keeps the timer matcher same-function: `ensure_timer()` returns a
    handle whose `:start(...)` lives in another function, and that is a non-catch.
    """
    best = (0, count - 1)
    for start, end in spans:
        if start < index < end and (end - start) < (best[1] - best[0]):
            best = (start, end)
    return best


def _block_end(tokens: list[lua.Token], start: int) -> int:
    """Index of the `end` / `until` closing the block opened at `tokens[start]`."""
    depth = 0
    for index in range(start, len(tokens)):
        token = tokens[index]
        if token.kind != "name":
            continue
        if token.text in KEYWORD_OPENERS:
            depth += 1
        elif token.text in KEYWORD_CLOSERS:
            depth -= 1
            if depth == 0:
                return index
    return len(tokens) - 1


def _paren_end(tokens: list[lua.Token], open_index: int) -> int:
    """Index of the bracket closing the one at `open_index`."""
    depth = 0
    for index in range(open_index, len(tokens)):
        token = tokens[index]
        if token.kind != "punct":
            continue
        if token.text in PUNCT_OPENERS:
            depth += 1
        elif token.text in PUNCT_CLOSERS:
            depth -= 1
            if depth == 0:
                return index
    return len(tokens) - 1


def _call_args(tokens: list[lua.Token], open_index: int) -> list[tuple[int, int]]:
    """Token ranges of the arguments of the call whose `(` is at `open_index`."""
    args: list[tuple[int, int]] = []
    depth = 0
    current_start = open_index + 1
    index = open_index + 1
    while index < len(tokens):
        token = tokens[index]
        if token.kind == "punct" and token.text in PUNCT_OPENERS:
            depth += 1
        elif token.kind == "punct" and token.text in PUNCT_CLOSERS:
            if depth == 0:
                args.append((current_start, index))
                return args
            depth -= 1
        elif token.kind == "punct" and token.text == "," and depth == 0:
            args.append((current_start, index))
            current_start = index + 1
        index += 1
    args.append((current_start, len(tokens)))
    return args


def _is_one_shot(tokens: list[lua.Token], arg: tuple[int, int]) -> bool:
    """Whether one argument is the literal `0` (the `repeat` slot)."""
    start, end = arg
    return end - start == 1 and tokens[start].kind == "number" and tokens[start].text == ONE_SHOT


def _is_call(tokens: list[lua.Token], index: int) -> bool:
    return index + 1 < len(tokens) and tokens[index + 1].is_punct("(")


def _read(path: Path, rel: str) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise CheckError(f"cannot read {rel}: {exc}") from exc
