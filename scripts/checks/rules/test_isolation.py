"""G17/G18 — a test or developer script must never touch the user's real pi data.

Two accidents this rule exists to prevent, both silent until the damage is done:

  G17  a test instance and the user's live pi share `stdpath("data")/pi/...`.
       A spec that lets the plugin resolve its own storage writes the test's
       sentinel prompts into the user's `prompt_history.json`, overwrites their
       unsent draft, or races their live instance for the same file.
  G18  "clean up the test sessions by grepping for my test text". With the
       backend stubbed (`chat._agent.send = function(_) end`) the RPC send never
       happens, so no test transcript is written — there is nothing to clean up.
       The `grep -rl "first prompt" ~/.pi/agent/sessions/` hits are *real*
       sessions whose assistant text quoted the test script under discussion,
       and deleting them destroys real work.

The two bans
------------
Ban 1 (`error`) — a call to `stdpath` whose first argument is the string literal
`"data"`, reported at the call's line. The remedy is a temp path:
`vim.env.PI_CODING_AGENT_DIR = vim.fn.tempname()` before the first send/recall.

Ban 2 (`error`, G18) — an enclosing function (or the chunk itself) that *both*
runs an external command whose command text mentions `grep` (`vim.fn.system`,
`vim.system`, `io.popen`) *and* deletes files (`os.remove`, `vim.fn.delete`, or an
`rm` word inside such a command string). Reported at the delete call, because the
delete is the destructive half. The message names the stub-write path: with the
backend stubbed no test transcript exists, so the cleanup has nothing to delete
and its grep can only ever match real sessions. "Same enclosing function" means
one site's `function` chain is a prefix of the other's, so a grep in an outer
function and the delete in its callback are one defect — and two *sibling*
functions that grep and delete independently are not (fixture
`sibling-functions`). That narrowing is deliberate: a file that greps for one
thing in one function and removes its own temp files in another is ordinary
correct code, and a rule that fires on it would be the false positive that gets
the gate deleted. Code at chunk level counts as its own scope, so a script that
does both at top level still fires. The narrowing only holds while every block
keyword pushes its own frame: the first version of this rule pushed nothing for
`for`/`while`, so a loop's `end` popped the enclosing *function*, everything
after the loop looked chunk-level, and two independent helpers were paired
(fixture `sibling-functions` fired at its `os.remove` line before that fix;
fixture `inside-loop` keeps the opposite direction — a loop between the two
halves of one function is still reported).

Subject
-------
Exactly `tests/**/*.lua` and `scripts/e2e/**/*.lua`, globbed by directory *name*
from `--root` (plus `tests/*.lua`, the depth this tree uses today). Never
`root.rglob("*.lua")`: that walks `scripts/checks/fixtures/**` and every other
fixture tree in the repo, where a deliberately-bad `stdpath("data")` line is the
*point* of the file — the rule would fire on its own fixtures. A directory that
is not a subject is not scanned even when it holds Lua.

Everything is matched on tokens (`lua.code_tokens`), never on raw source. Two
measured reasons, both in this tree today: `tests/minimal_init.lua:34` is a
*comment* that explains the isolation guard by spelling `stdpath("data")`, and the
guard itself one line later is `prompt_history._set_base_dir(vim.fn.tempname())`.
A line-oriented grep reports the comment and credits the compliant guard as the
violation. Same class of error one directory over: a raw grep counts 30 command
calls in the subject trees, the token scan 29, and the difference is the comment
at `tests/cli_args_spec.lua:3`.

The prefilter is not a matcher
------------------------------
Before tokenizing, a file must *contain* the bytes a finding needs — `stdpath`
for ban 1, and `grep` together with one of `remove` / `delete` / `rm` for ban 2 —
because a name token and a string literal are both spelled in the file. It never
decides anything: a comment that mentions them passes straight through to the
token matcher (the `good` fixture proves it), and the needles are matched as
substrings, so `os\n.remove(` still gets tokenized. It exists only to keep the
gate cheap: 10 of the 203 subject files survive it. Tokenizing all of them costs
2.1 s (`lua.tokenize` builds 434 649 tokens for 2.87 MB of Lua), which is how much
a shell-only version of this rule measured before the prefilter; the dispatch on
the root identifier (`vim` / `os` / `io`) instead of trying all six call chains
at every token took the rest: the full eight-rule gate measures 2.74 s, of which
the other seven are 2.66 s, so this rule is ~0.1 s (0.19 s including a bare
interpreter start).

What this rule cannot catch (deliberate non-catches)
----------------------------------------------------
* A spec that sets `require("pi.config").options.prompt.history.path` or calls
  `require("pi.draft")._set_path(tmp)` and never restores it. Deciding that a
  redirect is *effective* (set before the first send/recall, restored in
  `after_each`) needs semantic knowledge of the setup, not a token pattern —
  issue #117 lists it as the softer follow-up. A rule that guessed here would
  fire on the compliant specs too.
* Any `stdpath` call whose *argument* is not a literal second token
  (`stdpath(kind)`, `stdpath("da" .. "ta")`), and any wrapper defined outside
  the subject tree (`require("pi.prompt_history").base_dir()` is the real one:
  the literal `stdpath` lives in `lua/pi/prompt_history.lua:219`, not in the spec). A literal
  `vim.fn.stdpath("data")` inside a helper *in a subject file* is still caught —
  the ban is on the call, not on where the call sits.
* A command assembled from a variable — `local cmd = "grep -rl " .. text;
  vim.fn.system(cmd)` — is not read as grep, and `os.execute("rm -rf …")` is not
  one of the three command calls. Both are stated limits, not guesses.
* `vim.cmd("!rm -rf …")` beside a `grep` command is not a delete this rule sees:
  only `os.remove`, `vim.fn.delete` and an `rm` inside a *system* command string
  (the three forms above) count.
* `vim.fn["stdpath"](…)` — bracket-form member access — is not a call the chain
  matcher follows; it reads `.`-chains only.

Measured on this tree (the reason the rule ships with no allowlists — a rule that
needs one on its own repo gets switched off): 203 subject files (184
`tests/*.lua`, 19 `scripts/e2e/*.lua`, 2.87 MB, no Lua below their top level),
**0** hits for ban 1 and **0** for ban 2. The only `stdpath("data")` in the tree
is the comment above. The scan is not vacuous: it walks 29 command calls and 151
delete calls (83 `os.remove(` + 68 `vim.fn.delete(`) across those files and finds
no file, function or chunk holding both halves.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from .. import lua
from ..framework import Check, CheckError, Finding, Fixture

# Directory names, relative to `--root`. Globbed by name, never walked from the
# root: `scripts/checks/fixtures/**` is full of intentional `stdpath("data")`.
SUBJECT_DIRS = ("tests", "scripts/e2e")
DATA_ARG = "data"

# A `grep`/`rm` *word*: `rgrep`, `grepobj` and `perform` must not match.
GREP_RE = re.compile(r"\bgrep\b")
RM_RE = re.compile(r"\brm\b")

# The three ways a developer script runs an external command, as name/punct
# chains (never as a regex over source).
COMMAND_CALLS: tuple[tuple[str, ...], ...] = (
    ("vim", ".", "fn", ".", "system", "("),
    ("vim", ".", "system", "("),
    ("io", ".", "popen", "("),
)

# The deletes the rule can name. An `rm` inside a command string (above) is the
# third form and is reported with the same message.
DELETE_CALLS: tuple[tuple[str, ...], ...] = (
    ("os", ".", "remove", "("),
    ("vim", ".", "fn", ".", "delete", "("),
)


# Necessary-condition prefilter (see the module docstring): a hit needs these
# bytes in the file, so a file without them cannot hold one. Never a verdict.
STDPATH_NEEDLE = "stdpath"
GREP_NEEDLE = "grep"
DELETE_NEEDLES = ("remove", "delete", "rm")

# A `function` opens a scope; `for`/`while` are closed by their own `do`.
_FOR_WHILE = frozenset({"for", "while"})
_BLOCK_OPENERS = frozenset({"if", "repeat"})
_BLOCK_CLOSERS = frozenset({"end", "until"})


def _by_root(patterns: tuple[tuple[str, ...], ...]) -> dict[str, tuple[tuple[str, ...], ...]]:
    """Group call chains by their root identifier, for the dispatch below."""
    grouped: dict[str, list[tuple[str, ...]]] = {}
    for pattern in patterns:
        grouped.setdefault(pattern[0], []).append(pattern)
    return {root: tuple(chains) for root, chains in grouped.items()}


# A chain can only start on its root identifier, so the six chains are tried at
# the ~4 % of tokens that are `vim` / `os` / `io`, not at all 434 649 of them
# (measured: 2.1 s -> 0.15 s for the matching pass).
_COMMANDS_BY_ROOT = _by_root(COMMAND_CALLS)
_DELETES_BY_ROOT = _by_root(DELETE_CALLS)


@dataclass(frozen=True)
class _Site:
    """One grep or delete occurrence: its token index, line, and what it is."""

    index: int
    line: int
    what: str


class TestIsolation(Check):
    name = "test-isolation"
    summary = "tests and e2e scripts never touch the real pi data dir and never grep-then-delete sessions (G17/G18)"
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        # Only a missing subject tree is a harness problem: without either
        # directory this rule cannot tell a plugin tree from a random one.
        present = [rel for rel in SUBJECT_DIRS if (root / rel).is_dir()]
        if not present:
            raise CheckError(f"no {'/ or '.join(SUBJECT_DIRS)} directory under {root} — wrong tree?")

        files = _subject_files(root, present)
        if not files:
            # Anti-silent-pass (G25): no file scanned is not "isolated", it is a
            # tree this rule has nothing to verify.
            return [
                self.finding(
                    f"no *.lua file under {', '.join(present)} — nothing to check for test isolation (G17/G18)",
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
                'a comment mentioning `stdpath("data")`, a long string containing it, a temp-dir '
                '`vim.env.PI_CODING_AGENT_DIR` and a read-only `vim.fn.system({ "grep", … })` with no '
                "delete — every negative control must stay quiet",
            ),
            self.fixture(
                "bad-stdpath",
                1,
                '`local dir = vim.fn.stdpath("data") .. "/pi"`: the call resolves the user\'s real data dir',
            ),
            self.fixture(
                "bad-grep-delete",
                1,
                "one function that greps sessions and then `os.remove`s every match — the G18 cleanup pattern",
            ),
            self.fixture(
                "sibling-functions",
                0,
                "a `for`-loop grep function and a `while`-loop delete function in the same file: the loops must "
                "not pop the enclosing function frame, so the two helpers are never paired (the false positive "
                "this fixture locks)",
            ),
            self.fixture(
                "inside-loop",
                1,
                "one function whose loop sits between the grep and the delete: tracking the loop must not switch "
                "the pairing off, so the G18 defect is still reported at the delete",
            ),
            self.fixture(
                "empty",
                1,
                "tests/ exists but holds no *.lua file: nothing scanned is not the same as isolated, so the "
                "rule warns instead of reporting a clean tree",
            ),
            self.fixture(
                "no-subject",
                0,
                "neither tests/ nor scripts/e2e/ exists: the subject tree is missing, so the rule refuses the "
                "input with a CheckError (exit 2) instead of reporting a clean tree",
                expect_error=True,
            ),
        ]


def _subject_files(root: Path, present: list[str]) -> list[Path]:
    """Every `*.lua` under the subject directories (any depth), sorted."""
    files: list[Path] = []
    for rel in present:
        files.extend((root / rel).glob("**/*.lua"))
    return sorted(files)


def _check_file(check: Check, rel: str, text: str) -> list[Finding]:
    """Both bans over one file."""
    if not _may_hit(text):
        return []
    tokens = lua.code_tokens(text)
    findings: list[Finding] = []
    greps: list[_Site] = []
    deletes: list[_Site] = []

    for index, token in enumerate(tokens):
        if _is_stdpath_data(tokens, index):
            findings.append(
                check.finding(
                    f'stdpath("{DATA_ARG}") resolves the user\'s real pi data dir — point the test at a temp '
                    "path instead (G17: `vim.env.PI_CODING_AGENT_DIR = vim.fn.tempname()`)",
                    rel,
                    token.line,
                )
            )
        if token.kind != "name":
            continue
        for pattern in _COMMANDS_BY_ROOT.get(token.text, ()):
            if not _match(tokens, index, pattern):
                continue
            command = _command_text(_first_arg(tokens, index + len(pattern) - 1))
            if GREP_RE.search(command):
                greps.append(_Site(index, token.line, "a `grep` command"))
            if RM_RE.search(command):
                deletes.append(_Site(index, token.line, "an `rm` in a command string"))
        for pattern in _DELETES_BY_ROOT.get(token.text, ()):
            if _match(tokens, index, pattern):
                name = "".join(pattern[:-1])
                deletes.append(_Site(index, token.line, f"`{name}`"))

    if not (greps and deletes):
        return findings
    # Scopes are computed only for a file that holds both halves — the walk is
    # ~10 % of a full tokenize and no file in this tree needs it today.
    scopes = _scopes(tokens)
    reported: set[int] = set()
    for site in deletes:
        grep = next((g for g in greps if _same_enclosing(scopes[g.index], scopes[site.index])), None)
        if grep is None or site.index in reported:
            continue
        reported.add(site.index)
        findings.append(
            check.finding(
                f"{site.what} in the same function as {grep.what} (line {grep.line}) — with the backend "
                "stubbed (`chat._agent.send = function(_) end`) no test transcript is written, so there are "
                "no test sessions to clean up and the grep can only match a real one (G18); drop the cleanup",
                rel,
                site.line,
            )
        )
    return findings


def _may_hit(text: str) -> bool:
    """False when the file provably cannot contain a hit (necessary-condition only)."""
    if STDPATH_NEEDLE in text:
        return True
    return GREP_NEEDLE in text and any(needle in text for needle in DELETE_NEEDLES)


def _is_stdpath_data(tokens: list[lua.Token], index: int) -> bool:
    """`stdpath("data")` — a literal `"data"` as the first argument of the call."""
    if not tokens[index].is_name("stdpath"):
        return False
    if index + 2 >= len(tokens) or not tokens[index + 1].is_punct("("):
        return False
    argument = tokens[index + 2]
    return argument.kind == "string" and (argument.value or "").strip() == DATA_ARG


def _match(tokens: list[lua.Token], index: int, pattern: tuple[str, ...]) -> bool:
    """Does the name/punct chain `pattern` start at `index`?"""
    if index + len(pattern) > len(tokens):
        return False
    for offset, part in enumerate(pattern):
        token = tokens[index + offset]
        if part in (".", "("):
            if not token.is_punct(part):
                return False
        elif not token.is_name(part):
            return False
    return True


def _command_text(arg: list[lua.Token]) -> str:
    """The string literals of a call's first argument, space-joined.

    Space-joined rather than concatenated because the argv form
    (`{ "grep", "-rl", text }`) would otherwise read as `grep-rl…` and defeat the
    word boundary. A command built from a variable contributes nothing — the
    deliberate limit stated in the module docstring.
    """
    return " ".join(token.value for token in arg if token.kind == "string" and token.value is not None)


def _first_arg(tokens: list[lua.Token], open_index: int) -> list[lua.Token]:
    """Tokens of the first argument of the call whose `(` is at `open_index`."""
    depth = 0
    brace = 0
    out: list[lua.Token] = []
    for index in range(open_index, len(tokens)):
        token = tokens[index]
        text = token.text if token.kind == "punct" else None
        if text == "(":
            depth += 1
            if depth == 1:
                continue
        elif text == ")":
            depth -= 1
            if depth == 0:
                break
        elif text in ("{", "["):
            brace += 1
        elif text in ("}", "]"):
            brace -= 1
        elif text == "," and depth == 1 and brace == 0:
            break
        out.append(token)
    return out


def _scopes(tokens: list[lua.Token]) -> list[tuple[int, ...]]:
    """Per token, the chain of enclosing `function` token indices (`()` = chunk)."""
    out: list[tuple[int, ...]] = []
    blocks: list[str] = []
    functions: list[int] = []
    pending_do = False
    for index, token in enumerate(tokens):
        out.append(tuple(functions))
        if token.kind != "name":
            continue
        word = token.text
        if word == "function":
            blocks.append("function")
            functions.append(index)
        elif word in _BLOCK_OPENERS:
            blocks.append("block")
        elif word in _FOR_WHILE:
            # `for … do` / `while … do` is ONE block: the frame is opened by the
            # keyword itself and the header's own `do` is not a second frame.
            # Without this push the loop's `end` pops the *enclosing function*
            # (`blocks.pop() == "function"`), so every site after the loop looks
            # chunk-level — and `()`, a prefix of every chain, then pairs a
            # delete in one function with a grep in an unrelated one.
            blocks.append("block")
            pending_do = True
        elif word == "do":
            if pending_do:
                pending_do = False
            else:
                blocks.append("block")
        elif word in _BLOCK_CLOSERS:
            if blocks and blocks.pop() == "function" and functions:
                functions.pop()
    return out


def _same_enclosing(a: tuple[int, ...], b: tuple[int, ...]) -> bool:
    """True when one site's function chain is a prefix of the other's."""
    shortest = min(len(a), len(b))
    return a[:shortest] == b[:shortest]
