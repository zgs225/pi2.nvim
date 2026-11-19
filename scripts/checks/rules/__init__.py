"""The registered rules, in run order. Explicit so a reviewer sees the gate set."""

from __future__ import annotations

from ..framework import Check
from .docs_api import DocsApi
from .docs_commands import DocsCommands
from .docs_config import DocsConfig
from .docs_highlights import DocsHighlights
from .docs_keymaps import DocsKeymaps
from .parse_luajit import ParseLuajit

ALL: list[Check] = [
    ParseLuajit(),
    DocsCommands(),
    DocsConfig(),
    DocsHighlights(),
    DocsKeymaps(),
    DocsApi(),
]
