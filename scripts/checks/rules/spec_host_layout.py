"""G34 — a spec must never spell out the host's filesystem layout.

`stdpath("run")` is `/run/user/<uid>/nvim…` on a systemd Linux box and
`$TMPDIR/nvim.<user>/<random>` on macOS — and any `$XDG_RUNTIME_DIR` the user
picked anywhere else. `tempname()` is `/tmp/…` on Linux and a **symlink**
(`/var/folders/…` → `/private/var/folders/…`) on macOS (G32); the temp, data,
cache and home dirs all differ the same way. A spec that spells one of those
answers asserts *the machine it was written on*, and the failure only shows up on
a developer's other laptop: `tests/compaction_extension_spec.lua` asserted
`assert.matches("[/\\\\]run[/\\\\]", path)` for the run-dir config file, was red on
macOS, green on Linux and green in CI — because every CI job is `ubuntu-latest`,
so no gate ever ran it where it fails.

The two signals the rule decides (both `error`)
------------------------------------------------
Both are claims about the *host*, not about the product. Everything is matched on
tokens (`lua.code_tokens`), never on raw source: the fix's own comment spells
`[/\\\\]run[/\\\\]`, and a line-oriented grep would report it (G24 in reverse).

1. **A match pattern that names a host location.** The pattern argument of
   `assert.matches` / `assert.are.matches` / `assert.not_matches` is normalized
   first — a separator class (`[/\\\\]`, `[\\\\/]`, `[/]`) becomes `/`, and Lua's
   `%/` becomes `/` — because the defect's shape is *separator-aware, root-blind*:
   the pattern reads `[/\\\\]run[/\\\\]` and never says `/run/`. After
   normalization, a system-root segment (`/run/`, `/tmp/`, `/var/`, `/private/`,
   …) anywhere in the pattern is the finding. Reported at the literal's line.

2. **An equality assertion that pins a host location against a computed value.**
   The expected literal (alone, or a leading `"…" ..`) names a host location, the
   compared value is **computed** (a call expression, or a bare local name — never
   a field/index, which is data the spec itself built), and the literal is
   **spelled exactly once in the file**:
   `assert.are.equal("/run/user/1000/nvim/…", Extension.state_path())`, and
   `local path = Extension.state_path()` +
   `assert.are.equal("/run/user/1000/…", path)`. The `once` clause is what
   separates an expectation from an input — a literal the spec also hands to the
   product is a transformation assertion
   (`Path.resolve("/etc/hosts", base) == "/etc/hosts"`, a `_set_path("/tmp/…")`
   round trip) and stays quiet.

The remedy both findings carry: derive the expectation — `vim.fn.stdpath("run")`,
`vim.fn.tempname()`, `vim.uv.os_homedir()` — or build a path the test owns.

What it deliberately cannot catch
---------------------------------
* **An indirection.** A literal built at runtime (`local root = "/" .. "run"`), a
  pattern from a variable, or `vim.fn["stdpath"]("run")` are invisible; so is any
  expectation derived from a module's own default in another file. The
  behavioural half of this gate is the run-dir probe in `scripts/run_tests.lua`
  (children run with a `XDG_RUNTIME_DIR` whose path has no `/run/` component), and
  that probe is what catches the shapes a static matcher cannot see.
* **The e2e assertion helper.** `scripts/e2e/*.lua` assert through their own
  `check(cond, msg)` helper, so a host location spelled inside one is only caught
  if it reaches an `assert.*` name — the `find`/`match` channel below.
* **A literal spelled twice.** The `once` clause in signal 2 is a count, so two
  copies of the same host path in one file read as input + expectation and stay
  quiet, and a path built from parts (`"/" .. "run"`) is invisible.
* **A field or index on the compared side.** `assert.are.equal("/tmp/x.jsonl",
  session.file)` / `items[1].filename` are struct data the spec built, so only a
  call or a bare local name counts as "computed".
* **`find` / `match` / `gsub` patterns.** Dropped after measuring both hits in the
  tree: `tests/wait_task_spec.lua:699` searches the *extension's source text* for
  `/proc/` (compliant — the assertion is about the TypeScript), and
  `scripts/e2e/compaction.lua`'s `summary:find("/tmp/")` (since fixed) was a
  *weak* assertion on macOS rather than a broken one — a `find` on an arbitrary
  string cannot be told apart from a `find` on a path.
* **Aliasing** (`local eq = assert.are.equal; eq("/run/…", x)`), `vim.api`-style
  receivers, and a not-equal comparison (`assert.are_not.equal("/tmp/x", y)` is an
  inequality, not a layout claim).
* **A table expectation.** `assert.are.same({ file = "/tmp/x.jsonl" }, got)` starts
  with `{`, and the fixture paths inside it are opaque data, not expectations
  about a location.

Measured numbers (this tree, after the fix)
-------------------------------------------
* **226** subject files (203 `tests/*.lua`, 23 `scripts/e2e/*.lua`), **39** match
  assertions and **4594** equality assertions, 0.4 s of tokenizing — `make check`
  stays under ~2.2 s.
* **0 findings.** On the pre-fix tree the rule reports exactly **1**, the G34
  defect itself (`tests/compaction_extension_spec.lua:42`), which is the behaviour
  a gate is for: the tree that shipped the bug is the tree it is red on.
* Three further sites spelled `/tmp/pi2nvim-…-test` as an override expectation and
  were fixed anyway (derived from `vim.fn.tempname()`, not allowlisted). The rule
  was already quiet on them — the literal is also the `_set_path` argument, so it
  is input, and signal 2's `once` clause says so — which is the documented
  direction, not a miss that needed an exception table.
* The zero is the matcher working, not a blind one: the `bad-pattern` fixture
  (2 findings, one per subject directory) and `bad-equal` (2, inline and through a
  local) each fire, and the `good` fixture holds every negative control measured
  above — a comment, a long string, a derived `stdpath("run")` expectation, a
  literal that is also the compared call's input (`/etc/hosts`), a `_set_path`
  round trip, a `find("/proc/")` over source text and a `/tmp/x.jsonl` fixture
  path compared to a field.

Warn vs error
-------------
  `CheckError` (exit 2)  neither `tests/` nor `scripts/e2e/` under `--root`: the
                         subject tree is missing, so this is the wrong tree rather
                         than a clean one (and never a silent pass).
  `warn` (exit 1)        the subject directories exist but hold no `*.lua`: a fact
                         about the tree, exactly one warning, so a `--root` run
                         over a partial checkout stays usable and the gap is
                         visible.
  `error` (exit 1)       one finding per hardcoded host location, at the literal's
                         line, with the repo-relative path.
"""

from __future__ import annotations

import re
from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

#: Subject trees, globbed by directory name from `--root` — never
#: `root.rglob("*.lua")`, which would walk `scripts/checks/fixtures/**`, where a
#: deliberately-bad assertion is the *point* of the file.
SUBJECT_DIRS = ("tests", "scripts/e2e")

#: First path segments that only ever mean "where this machine keeps things".
#: A literal is a *host layout claim* only when it is rooted at one of these;
#: `/repo/wt`, `/src/a.ts` and `sessions/one.jsonl` are fixture data.
SYSTEM_ROOTS = frozenset(
    {
        "run",
        "tmp",
        "var",
        "private",
        "proc",
        "sys",
        "etc",
        "usr",
        "dev",
        "home",
        "Users",
        "Library",
        "opt",
        "mnt",
        "Volumes",
        "srv",
    }
)

#: Positive deep/equality assertions whose first argument is an expectation.
EQUALITY = frozenset(
    {
        ("assert", "are", "equal"),
        ("assert", "equal"),
        ("assert", "equals"),
        ("assert", "are", "same"),
        ("assert", "same"),
    }
)

#: Assertions whose *pattern* argument can only be a claim about a layout.
MATCHERS = frozenset(
    {
        ("assert", "matches"),
        ("assert", "are", "matches"),
        ("assert", "not_matches"),
    }
)

#: `[/\\]`, `[\\/]`, `[/]`, `[ \\ ]` — a separator in a pattern is a character
#: class, so the defect reads `[/\\]run[/\\]`, not `/run/`.
_SEPARATOR_CLASS = re.compile(r"\[\s*[/\\]{1,2}\s*\]")

#: A Windows drive root is a host location too, and this plugin mostly runs on
#: Unix — `C:\\…` written as an expectation is the same mistake in another shape.
_DRIVE_ROOT = re.compile(r"^[A-Za-z]:[\\/]")

_OPENERS = ("(", "{", "[")
_CLOSERS = (")", "}", "]")


class SpecHostLayout(Check):
    name = "spec-host-layout"
    summary = "specs and e2e scripts derive host paths (run/temp/home dirs) instead of spelling them out (G34)"
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        present = [rel for rel in SUBJECT_DIRS if (root / rel).is_dir()]
        if not present:
            raise CheckError(f"no {'/ or '.join(SUBJECT_DIRS)} directory under {root} — wrong tree?")

        files = sorted(path for rel in present for path in (root / rel).glob("**/*.lua"))
        if not files:
            return [
                self.finding(
                    f"no *.lua file under {', '.join(present)} — nothing to check for a hardcoded host layout (G34)",
                    present[0],
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
            findings.extend(_check_file(self, rel, text))
        return findings

    def fixtures(self) -> list[Fixture]:
        return [
            self.fixture(
                "good",
                0,
                "every negative control in one spec: a comment and a long string spelling "
                '`[/\\\\]run[/\\\\]`, a derived `stdpath("run")` expectation, a literal that is also the '
                'compared call\'s input (`/etc/hosts`), a `find("/proc/")` over source text, and a '
                "`/tmp/x.jsonl` fixture path compared to a field — all quiet",
            ),
            self.fixture(
                "bad-pattern",
                2,
                '`assert.matches("[/\\\\]run[/\\\\]", …)` once in a spec and once in an e2e script: the '
                "separator-aware, root-blind pattern the rule exists for, in both subject directories",
            ),
            self.fixture(
                "bad-equal",
                2,
                '`assert.are.equal("/run/user/1000/nvim.0/…", state_path())` inline and the same shape '
                "through a `local path = state_path()`: the expected value pins this machine's run dir against "
                "a value the product computed",
            ),
            self.fixture(
                "empty",
                1,
                "tests/ exists but holds no *.lua: nothing scanned is not the same as portable, so the rule "
                "warns instead of reporting a clean tree",
            ),
            self.fixture(
                "no-subject",
                0,
                "neither tests/ nor scripts/e2e/ exists: the subject tree is missing, so the rule refuses the "
                "input with a CheckError (exit 2) instead of reporting a clean tree",
                expect_error=True,
            ),
        ]


def _check_file(check: Check, rel: str, text: str) -> list[Finding]:
    """Both signals over one file."""
    tokens = lua.code_tokens(text)
    spelled = _spellings(tokens)
    findings: list[Finding] = []
    for index, token in enumerate(tokens):
        if not token.is_punct("("):
            continue
        callee = _callee(tokens, index)
        if callee in MATCHERS:
            literal = _pattern_claim(tokens, index)
            if literal is not None:
                findings.append(
                    check.finding(
                        f"`{'.'.join(callee)}` pattern names the host location "
                        f"{_location(literal.value or '')!r}: the run/temp/home dir differs per platform "
                        "(linux `/run/user/<uid>/…`, macOS `$TMPDIR/nvim.<user>/…`), so derive it — "
                        '`vim.fn.stdpath("run")`, `vim.fn.tempname()`, `vim.uv.os_homedir()` (G34)',
                        rel,
                        literal.line,
                    )
                )
        elif callee in EQUALITY:
            literal = _equality_claim(tokens, index, spelled)
            if literal is not None:
                findings.append(
                    check.finding(
                        f"expected value pins the host location {_location(literal.value or '')!r} against a "
                        "computed path: it differs per platform (linux vs macOS vs a user's "
                        '`$XDG_RUNTIME_DIR`), so derive the expectation — `vim.fn.stdpath("run")`, '
                        "`vim.fn.tempname()`, `vim.uv.os_homedir()` — or build a path the test owns (G34)",
                        rel,
                        literal.line,
                    )
                )
    return findings


def _callee(tokens: list[lua.Token], index: int) -> tuple[str, ...] | None:
    """The dotted name called by the `(` at `index`, e.g. `("assert", "are", "equal")`."""
    if index < 1 or tokens[index - 1].kind != "name":
        return None
    parts = [tokens[index - 1].text]
    walk = index - 2
    while walk >= 1 and tokens[walk].is_punct(".") and tokens[walk - 1].kind == "name":
        parts.append(tokens[walk - 1].text)
        walk -= 2
    return tuple(reversed(parts))


def _arguments(tokens: list[lua.Token], open_index: int) -> list[list[lua.Token]]:
    """The top-level arguments of the call whose `(` is at `open_index`."""
    args: list[list[lua.Token]] = []
    current: list[lua.Token] = []
    depth = 0
    for token in tokens[open_index:]:
        text = token.text if token.kind == "punct" else None
        if text in _OPENERS:
            depth += 1
            if depth == 1:
                continue
        elif text in _CLOSERS:
            depth -= 1
            if depth == 0:
                args.append(current)
                return args
        elif text == "," and depth == 1:
            args.append(current)
            current = []
            continue
        current.append(token)
    args.append(current)
    return args


def _normalized(value: str) -> str:
    """A pattern with its separator classes and escapes collapsed to `/`."""
    return _SEPARATOR_CLASS.sub("/", value).replace("%/", "/")


def _names_location(value: str) -> bool:
    """Is `value` rooted at a system location (`/run`, `/tmp/x`, `C:\\`, `%temp%`)?"""
    if value.startswith("%temp%") or _DRIVE_ROOT.match(value):
        return True
    return any(value == "/" + name or value.startswith("/" + name + "/") for name in SYSTEM_ROOTS)


def _pattern_names_location(pattern: str) -> bool:
    """Does the pattern claim a system location *anywhere* (`^/var/folders`, `[/\\]run[/\\]`)?"""
    text = _normalized(pattern)
    if _names_location(text):
        return True
    return any("/" + name + "/" in text or text.endswith("/" + name) for name in SYSTEM_ROOTS)


def _location(value: str) -> str:
    """The matched system root, for the finding's message (`/run`, `/tmp`, …)."""
    text = _normalized(value)
    for name in sorted(SYSTEM_ROOTS):
        if "/" + name + "/" in text or text.endswith("/" + name) or text.startswith("/" + name):
            return "/" + name
    if _DRIVE_ROOT.match(text):
        return text[:2] + "/"
    return "%temp%" if text.startswith("%temp%") else text


def _pattern_claim(tokens: list[lua.Token], index: int) -> lua.Token | None:
    """The literal at fault when a match assertion's pattern names a host location."""
    for argument in _arguments(tokens, index):
        if not argument or argument[0].kind != "string":
            continue
        value = argument[0].value or ""
        if _pattern_names_location(value):
            return argument[0]
    return None


def _equality_claim(tokens: list[lua.Token], index: int, spelled: dict[str, int]) -> lua.Token | None:
    """The literal at fault when an equality assertion pins a host location.

    Two shapes count, in either order: `equal("<host path>", computed)` and
    `equal(computed, "<host path>")`. `computed` is a call expression or a bare
    local name; the literal must also be spelled only once in the file, i.e. it is
    an expectation rather than data the spec also feeds to the product.
    """
    args = [argument for argument in _arguments(tokens, index) if argument]
    if len(args) < 2:
        return None
    for expected, actual in ((args[0], args[1]), (args[1], args[0])):
        if expected[0].kind != "string":
            continue
        value = expected[0].value or ""
        if not _names_location(value):
            continue
        if len(expected) > 1 and not expected[1].is_punct(".."):
            continue
        if not _computed(actual):
            continue
        if spelled.get(value, 0) > 1:
            continue
        return expected[0]
    return None


def _computed(expression: list[lua.Token]) -> bool:
    """Is this a value the product computed (a call) or a local holding one?"""
    if any(token.is_punct("(") for token in expression):
        return True
    return len(expression) == 1 and expression[0].kind == "name"


def _spellings(tokens: list[lua.Token]) -> dict[str, int]:
    """How often each host-location literal is spelled in the file."""
    counts: dict[str, int] = {}
    for token in tokens:
        if token.kind == "string" and token.value and _names_location(token.value):
            counts[token.value] = counts.get(token.value, 0) + 1
    return counts
