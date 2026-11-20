"""Gotcha G16 as a gate: no inline `pkill -f` / `pgrep -f` one-liner in a skill code fence.

`.agents/skills/develop/references/gotchas.md` documents G16. A cleanup one-liner
such as

    bash -c "… pgrep -f 'wezterm-gui.*pi_gui_test' …"

matches the pid of *that shell*: `pgrep -f` / `pkill -f` match the full command
line, and the pattern the command searches for is part of the shell's own argv.
Killing (or re-observing) the pid it just printed therefore terminates the very
shell that is cleaning up, so every later step (rm, restore, summary) silently
never runs. The `[p]attern` trick does not help when the literal also appears
elsewhere in the cmdline (e.g. on the right-hand side of `PAT='…pi_gui_test…'`).

The sanctioned form is a **script file** — `.agents/skills/develop/scripts/`
(`gui_cleanup.sh` and friends). Its cmdline is `bash /path/gui_cleanup.sh`, which
carries no feature string, and the script can capture pids first and kill them in
a second step. Cleanup and process observation belong in files; what a reader
pastes out of a markdown code fence is exactly the one-liner that eats its own
shell.

So this rule reports one class of line only: an inline one-liner inside a
markdown code fence under `.agents/skills/`. The boundaries are the substance of
the rule, because a gate that also fires on the documentation of the hazard gets
switched off:

  * a hit inside a `.sh` / `.py` / any non-markdown file is **not** a finding.
    Scripts are the fix, not the defect: the rule never reads them.
  * prose outside a fence is **not** a finding. That is where the gotcha names
    the anti-pattern it warns about.
  * only fences whose info string is `bash`, `sh`, `shell`, `console`, `zsh`, or
    empty (an untagged fence is a shell block by convention here) are scanned. A
    `python` fence showing `subprocess.run(["pkill", "-f", …])` is a snippet about
    the tool, not a shell one-liner a reader pastes into a terminal.
  * "full command line" means the `pkill`/`pgrep` command itself carries a short
    flag cluster containing `f` (`-f`, `-af`, `-lf`, `-fa`) or `--full`.
    `pgrep -l pattern` matches the process *name*, not the cmdline, and is fine.
    Only the options before the pattern are read, so a pattern that happens to
    contain `-f` cannot look like a flag.
  * a comment line inside a shell fence (`# pkill -f matches this shell`) does not
    execute and is skipped, like prose.

Warn vs error, same contract as `docs-keymaps`:

  `CheckError`    there is no `.agents/skills/` directory under `--root`, so the
                  rule cannot tell a plugin tree from any other tree.
  `warn` finding  the skills tree exists but contains no shell-fence line at all:
                  the rule then has nothing to scan, and a gate with nothing to
                  scan must say so instead of going green (G25).
  `error` finding an inline full-cmdline `pkill`/`pgrep` one-liner in a shell
                  fence: real G16 drift.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Iterator

from ..framework import Check, CheckError, Finding, Fixture

SKILLS_DIR = ".agents/skills"
SCRIPT_DIR = ".agents/skills/develop/scripts"

# A fence line: the marker run (>=3 backticks or tildes) plus an optional info string.
FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})\s*([^\s`]*)")
# A command word, so `pkill_helper` / `gui_pkill` do not match.
COMMAND_RE = re.compile(r"\b(pkill|pgrep)\b")
# A short flag cluster carrying `f` (`-f`, `-af`, `-lf`, `-fa`); `-F` is a different flag.
SHORT_FULL_RE = re.compile(r"^-[A-Za-z]*f[A-Za-z]*$")
LONG_FULL = "--full"
# Where an argument list ends: the next shell operator. Inside them the words are one command.
SEPARATORS = frozenset(";|&)`")

SHELL_FENCES = frozenset({"", "bash", "sh", "shell", "console", "zsh"})


class SkillInlinePkill(Check):
    name = "skill-inline-pkill"
    summary = (
        "no inline `pkill -f` / `pgrep -f` one-liner in a `.agents/skills/**/*.md` code fence "
        "(G16: the pattern matches the shell that runs it — put the cleanup in a script)"
    )
    requires = ("python3",)

    def run(self, root: Path) -> list[Finding]:
        skills = root / SKILLS_DIR
        if not skills.is_dir():
            # Without the skills tree the rule cannot tell a plugin tree from any other tree.
            raise CheckError(f"no {SKILLS_DIR}/ directory under {root} — wrong tree?")

        findings: list[Finding] = []
        scanned = 0
        for path in sorted(skills.rglob("*.md")):
            rel = path.relative_to(root).as_posix()
            for lineno, line in _shell_fence_lines(_read(path, root).splitlines()):
                scanned += 1
                hit = _full_cmdline_hit(line)
                if hit is None:
                    continue
                findings.append(
                    self.finding(
                        f"inline `{hit}` matches full command lines, so it also matches the shell running it "
                        f"and kills the cleanup mid-run (G16); move it into a script under {SCRIPT_DIR}/ "
                        "whose cmdline is clean",
                        rel,
                        lineno,
                    )
                )

        if not scanned:
            # Anti-silent-pass design (G25): no shell fence means nothing was verified.
            return [
                self.finding(
                    f"no shell-fence line under {SKILLS_DIR}/ — nothing to scan for inline `pkill -f` one-liners",
                    SKILLS_DIR,
                    severity="warn",
                )
            ]
        return findings

    def fixtures(self) -> list[Fixture]:
        return [
            self.fixture(
                "bad",
                4,
                "four inline full-cmdline one-liners in shell fences (tagged `bash`, tagged `sh`, untagged, "
                "tagged `console` in a nested file), while a `text` fence, a `python` fence, a comment line, a "
                "`pgrep -l` process-name match, a prose mention and a `.sh` script that does the same thing all "
                "stay quiet",
            ),
            self.fixture(
                "good",
                0,
                "the sanctioned form: prose names the anti-pattern, a `bash` fence calls the cleanup script, a "
                "`pgrep -l` line stays quiet, and the inline `pkill -f` / `pgrep -af` live in "
                ".agents/skills/develop/scripts/gui_cleanup.sh (scripts are the fix, not a finding)",
            ),
            self.fixture(
                "no-fences",
                1,
                "a skills tree with prose but no shell fence at all: the rule warns that it has nothing to scan "
                "instead of reporting a clean tree",
            ),
            self.fixture(
                "no-skills",
                0,
                "no .agents/skills/ directory at all: the subject tree is missing, so the rule refuses the input "
                "with a CheckError (exit 2) rather than reporting a clean tree",
                expect_error=True,
            ),
        ]


def _read(path: Path, root: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise CheckError(f"cannot read {path.relative_to(root).as_posix()}: {exc}") from exc


def _shell_fence_lines(lines: list[str]) -> Iterator[tuple[int, str]]:
    """Yield `(line number, line)` for every line inside a shell code fence.

    A fence closes on a bare marker of the same character, at least as long as the
    opener, with no info string — so a nested ``` inside a ```` block stays
    content and cannot end the outer fence early.
    """
    marker: str | None = None
    shell = False
    for lineno, line in enumerate(lines, 1):
        stripped = line.strip()
        if marker is None:
            opener = FENCE_RE.match(line)
            if opener:
                marker = opener.group(1)
                shell = opener.group(2).lower() in SHELL_FENCES
            continue
        if len(stripped) >= len(marker) and set(stripped) == {marker[0]}:
            marker, shell = None, False
            continue
        if shell and not stripped.startswith("#"):
            yield lineno, line


def _full_cmdline_hit(line: str) -> str | None:
    """The `pkill`/`pgrep` invocation on `line` that matches full cmdlines, if any."""
    for match in COMMAND_RE.finditer(line):
        flags = _option_words(line, match.end())
        for flag in flags:
            if flag == LONG_FULL or SHORT_FULL_RE.match(flag):
                return " ".join([match.group(1), *flags])
    return None


def _option_words(line: str, start: int) -> list[str]:
    """Option words after a command word, up to the first operand or shell operator.

    Options only, because the pattern is where a literal `-f` could legitimately
    appear (`pgrep -f "x -f y"`); anything after the first non-option word cannot
    turn name matching into cmdline matching.
    """
    flags: list[str] = []
    pos = start
    while pos < len(line):
        while pos < len(line) and line[pos].isspace():
            pos += 1
        if pos >= len(line) or line[pos] in SEPARATORS:
            break
        end = pos
        while end < len(line) and not line[end].isspace() and line[end] not in SEPARATORS:
            end += 1
        word = line[pos:end]
        if not word.startswith("-") or word == "-":
            break
        flags.append(word)
        pos = end
    return flags
