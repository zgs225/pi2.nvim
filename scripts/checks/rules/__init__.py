"""The registered rules, in run order. Explicit so a reviewer sees the gate set."""

from __future__ import annotations

from ..framework import Check
from .config_read_at_call_time import ConfigReadAtCallTime
from .config_three_spots import ConfigThreeSpots
from .docs_api import DocsApi
from .docs_commands import DocsCommands
from .docs_config import DocsConfig
from .docs_highlights import DocsHighlights
from .docs_keymaps import DocsKeymaps
from .expr_mapping import ExprMapping
from .parse_luajit import ParseLuajit
from .skill_inline_pkill import SkillInlinePkill
from .spec_scope import SpecScope
from .test_isolation import TestIsolation
from .uv_fast_event import UvFastEvent

ALL: list[Check] = [
    ParseLuajit(),
    ConfigThreeSpots(),
    ConfigReadAtCallTime(),
    SpecScope(),
    ExprMapping(),
    TestIsolation(),
    UvFastEvent(),
    DocsCommands(),
    DocsConfig(),
    DocsHighlights(),
    DocsKeymaps(),
    DocsApi(),
    SkillInlinePkill(),
]
