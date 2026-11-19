"""The registered rules, in run order. Explicit so a reviewer sees the gate set."""

from __future__ import annotations

from typing import List

from ..framework import Check
from .docs_commands import DocsCommands
from .parse_luajit import ParseLuajit

ALL: List[Check] = [
    ParseLuajit(),
    DocsCommands(),
]
