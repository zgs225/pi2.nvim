"""G24 — code must parse under the LuaJIT that Neovim ships.

The failure this prevents: the plugin loads fine on the author's nvim (whose
LuaJIT accepts a newer grammar) and dies on Neovim stable with
`E5108: ... loop or previous error loading module`, where the *real* error is a
parse error one message up. The plugin promises Neovim 0.10+, so "parses on my
machine" is not the bar — "parses under LuaJIT 2.1" is.

The gate is the compiler itself, not a regex: a LuaJIT 2.1 build rejects the
Lua 5.3 operators (`&`, `|`, `<<`, `>>`, `//`, `~`) and accepts the extensions
this repo actually uses (`goto` + `::label::`); the probe below exists because
not every build that calls itself 2.1 still does the first part. Regex
approximations of this rule
were measured to produce five hits on this repo, none of them real (see
`gotchas.md` G24 and the rationale in `lua.py`).

Probing the parser instead of trusting its name
-----------------------------------------------
"Any LuaJIT 2.1" is not, it turns out, a safe assumption: some 2.1 builds on
`PATH` (`/usr/bin/luajit` from a distro rolling release, for instance) accept
the Lua 5.3 bitwise operators and reject only `//`, so a run of this gate over a
plugin that cannot load on Neovim stable printed `ok: 0 findings`. A version
string cannot fix that — the binary lies about its own grammar, and checking
`luajit -v` only tells you what a build calls itself. So the gate probes the
capability directly at the start of every run: it compiles a control file with
valid Lua (which must succeed, or the binary cannot decide anything) and then
one file per Lua 5.3 operator (each must fail). A parser that accepts any of
them is refused with a `CheckError` naming the binary and the remedy, because a
lenient parser cannot answer the only question this rule asks: *does this load
on Neovim stable?*

Scope: `lua/` only — the code that ships and must load inside the user's
Neovim. `tests/` and `scripts/` are developer-run, so their grammar is nobody's
runtime constraint and they stay out of this gate; they are type-checked
instead (`make lint` with `.luarc-tests.json`), which is what caught the
digit-separator literals that made two specs unparseable under the pinned
LuaJIT.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Iterator

from ..framework import FIXTURES, Check, CheckError, Finding, Fixture

LUA_DIRS = ("lua",)
# `luajit: /abs/path/file.lua:12: 'end' expected near 'x'`
ERROR_RE = re.compile(r"^(?:luajit: )?(?P<path>.+?):(?P<line>\d+): (?P<msg>.+)$")
# Valid Lua that every parser must accept. If this one fails, the binary is not
# a Lua parser at all (`LUAJIT_BIN=/bin/false`) and its verdicts mean nothing.
CONTROL_PROBE = "local x = 1 + 2"
# One file per Lua 5.3-only operator. Separate files on purpose: a lenient
# parser may accept one of them and reject another (measured: `&` accepted,
# `//` rejected), so a single combined probe can go green on a bad binary.
LUA53_PROBES: tuple[tuple[str, str], ...] = (
    ("&", "local x = 1 & 2"),
    ("|", "local x = 1 | 2"),
    ("<<", "local x = 1 << 2"),
    (">>", "local x = 1 >> 2"),
    ("~", "local x = 1 ~ 2"),
    ("//", "local x = 1 // 2"),
)


class ParseLuajit(Check):
    name = "parse-luajit"
    summary = "every Lua file parses under LuaJIT 2.1, the parser Neovim ships (G24)"
    requires = ("luajit",)

    def __init__(self) -> None:
        # Keyed by resolved binary path, not a bare bool: `--self-test` points
        # LUAJIT_BIN at different binaries within one process, and each of them
        # needs its own verdict (a cached "good" must not launder a lenient
        # parser that a later fixture hands us).
        self._probed: set[str] = set()

    def run(self, root: Path) -> list[Finding]:
        # Same contract as every other rule: only a missing subject tree is a
        # harness problem (exit 2); a tree whose `lua/` is merely empty is a fact
        # about that tree and is reported as a warning (exit 1).
        if not (root / "lua").is_dir():
            raise CheckError(f"no lua/ directory under {root} — wrong tree?")
        exe = self._luajit()
        self._probe(exe)
        findings: list[Finding] = []
        parsed = 0
        for path in self._files(root):
            parsed += 1
            proc = subprocess.run(
                [exe, "-bl", str(path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            if proc.returncode == 0:
                continue
            findings.append(self._to_finding(root, path, proc.stderr))
        if not parsed:
            # A consequence of the scan, not a second directory check: nothing
            # compiled is not the same as everything compiling. Silence here
            # would read as "syntax is fine" on a tree that has no code.
            findings.append(
                self.finding(
                    f"no *.lua file under {root / 'lua'} — nothing to parse on this tree",
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
                "goto/labels and the `bit` library are LuaJIT, not 5.3-only — must stay quiet",
            ),
            self.fixture(
                "bad",
                2,
                "one file using `&`, one using `//` — both are Lua 5.3-only and fail on Neovim stable",
            ),
            Fixture(
                name="always-accept",
                root=FIXTURES / self.name / "good",
                expect=0,
                what="a `#!/bin/sh` stub that exits 0 for any input pretends to be a parser that "
                "accepts everything; the probe must refuse it instead of trusting it",
                env={"LUAJIT_BIN": str(FIXTURES / self.name / "always-accept.sh")},
                expect_error=True,
            ),
            self.fixture(
                "no-lua",
                0,
                "no lua/ directory at all: the subject tree is missing, so the rule refuses the input with a "
                "CheckError (exit 2) instead of reporting a clean run",
                expect_error=True,
            ),
            self.fixture(
                "empty",
                1,
                "lua/ exists but holds no *.lua file: nothing parsed is not the same as everything parsing, "
                "so the rule warns instead of reporting a clean run",
            ),
        ]

    # -- internals -------------------------------------------------------
    def _luajit(self) -> str:
        configured = os.environ.get("LUAJIT_BIN")
        exe = shutil.which(configured) if configured else shutil.which("luajit")
        if not exe:
            where = f"LUAJIT_BIN={configured!r} is not an executable" if configured else "luajit is not on PATH"
            raise CheckError(
                f"{where} — run `mise install` in the repo root, or set "
                "LUAJIT_BIN=/path/to/luajit (the gate probes it: a build that accepts Lua 5.3 syntax is "
                "refused)"
            )
        return exe

    def _probe(self, exe: str) -> None:
        """Refuse a parser that is not LuaJIT 2.1, whatever it calls itself.

        Binary-source independent on purpose: no version string, no `--version`
        parse, no hardcoded path — the parser must demonstrate that it rejects
        Lua 5.3 syntax. Raises `CheckError` (never skips) when it does not, or
        when it cannot even compile valid Lua.
        """
        if exe in self._probed:
            return

        with tempfile.TemporaryDirectory(prefix="pi-luajit-probe-") as tmp:
            tmpdir = Path(tmp)
            control = tmpdir / "control.lua"
            self._write(control, CONTROL_PROBE)
            if not self._compiles(exe, control):
                raise CheckError(
                    f"{exe} could not compile valid Lua ({CONTROL_PROBE!r}): a parser that rejects "
                    "correct code cannot be trusted to decide whether `lua/` loads on Neovim stable. "
                    "Run `mise install` in the repo root, or point LUAJIT_BIN at a LuaJIT 2.1 release "
                    "build."
                )

            for index, (operator, snippet) in enumerate(LUA53_PROBES):
                probe = tmpdir / f"probe-{index}.lua"
                self._write(probe, snippet)
                if self._compiles(exe, probe):
                    raise CheckError(
                        f"{exe} accepts the Lua 5.3 operator `{operator}` ({snippet!r} compiled), so it "
                        'is not a parser Neovim stable would use and it cannot answer "does this load '
                        'on Neovim stable?" — a lenient parser silently reports 0 findings for code '
                        "Neovim refuses to load. Fix: run `mise install` in the repo root with "
                        'LUAJIT_BIN unset (`.mise.toml` pins `luajit = "2.1.1744318430"` for exactly '
                        "this reason), or point LUAJIT_BIN at a LuaJIT 2.1 release build."
                    )

        self._probed.add(exe)

    @staticmethod
    def _write(path: Path, snippet: str) -> None:
        try:
            path.write_text(snippet + "\n", encoding="utf-8")
        except OSError as exc:
            # An unwritable temp dir must fail the gate, not skip the probe.
            raise CheckError(f"could not write the Lua probe file {path}: {exc}") from exc

    @staticmethod
    def _compiles(exe: str, path: Path) -> bool:
        try:
            proc = subprocess.run(
                [exe, "-bl", str(path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            return proc.returncode == 0
        except OSError as exc:
            raise CheckError(f"could not run {exe}: {exc}") from exc

    def _files(self, root: Path) -> Iterator[Path]:
        for dirname in LUA_DIRS:
            base = root / dirname
            if base.is_dir():
                yield from sorted(base.rglob("*.lua"))

    def _to_finding(self, root: Path, path: Path, stderr: str) -> Finding:
        rel = path.relative_to(root).as_posix()
        line = 0
        message = stderr.strip().splitlines()[-1] if stderr.strip() else "does not compile"
        match = ERROR_RE.match(message)
        if match:
            line = int(match.group("line"))
            message = match.group("msg")
        return self.finding(
            f"does not parse under LuaJIT 2.1 (Neovim stable will refuse to load it): {message}",
            rel,
            line,
        )
