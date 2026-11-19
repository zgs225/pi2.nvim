"""G24 — code must parse under the LuaJIT that Neovim ships.

The failure this prevents: the plugin loads fine on the author's nvim (whose
LuaJIT accepts a newer grammar) and dies on Neovim stable with
`E5108: ... loop or previous error loading module`, where the *real* error is a
parse error one message up. The plugin promises Neovim 0.10+, so "parses on my
machine" is not the bar — "parses under LuaJIT 2.1" is.

The gate is the compiler itself, not a regex: any LuaJIT 2.1 build rejects the
Lua 5.3 operators (`&`, `|`, `<<`, `>>`, `//`) and accepts the extensions this
repo actually uses (`goto` + `::label::`). Regex approximations of this rule
were measured to produce five hits on this repo, none of them real (see
`gotchas.md` G24 and the rationale in `lua.py`).

Scope: `lua/` only — the code that ships and must load inside the user's
Neovim. `tests/` and `scripts/` are developer-run and already use a grammar
newer than Neovim 0.10's LuaJIT (e.g. `180_000`), so gating them here would
flag code that is nobody's runtime constraint.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Iterator, List

from ..framework import Check, CheckError, Finding, Fixture

LUA_DIRS = ("lua",)
# `luajit: /abs/path/file.lua:12: 'end' expected near 'x'`
ERROR_RE = re.compile(r"^(?:luajit: )?(?P<path>.+?):(?P<line>\d+): (?P<msg>.+)$")


class ParseLuajit(Check):
    name = "parse-luajit"
    summary = "every Lua file parses under LuaJIT 2.1, the parser Neovim ships (G24)"
    requires = ("luajit",)

    def run(self, root: Path) -> List[Finding]:
        exe = self._luajit()
        findings: List[Finding] = []
        for path in self._files(root):
            proc = subprocess.run(
                [exe, "-bl", str(path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            if proc.returncode == 0:
                continue
            findings.append(self._to_finding(root, path, proc.stderr))
        return findings

    def fixtures(self) -> List[Fixture]:
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
        ]

    # -- internals -------------------------------------------------------
    def _luajit(self) -> str:
        configured = os.environ.get("LUAJIT_BIN")
        exe = shutil.which(configured) if configured else shutil.which("luajit")
        if not exe:
            where = f"LUAJIT_BIN={configured!r} is not an executable" if configured else "luajit is not on PATH"
            raise CheckError(
                f"{where} — run `mise install` in the repo root, or set "
                "LUAJIT_BIN=/path/to/luajit (any LuaJIT 2.1 build rejects Lua 5.3 syntax)"
            )
        return exe

    def _files(self, root: Path) -> Iterator[Path]:
        for dirname in LUA_DIRS:
            base = root / dirname
            if base.is_dir():
                for path in sorted(base.rglob("*.lua")):
                    yield path

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
