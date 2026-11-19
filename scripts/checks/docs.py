"""The documentation corpus: README.md plus doc/*.md, addressable by line.

Docs are scanned as text (there is no doc AST worth building): for the rules
here, a mention is a line number plus the matched span, which is exactly what a
`path:line` finding needs. Both `make docs-links` (link/anchor validity) and the
`docs-*` rules consume this same corpus so "what counts as documentation" stays
defined in one place.
"""

from __future__ import annotations

from pathlib import Path
from typing import Match, Pattern

DOC_GLOBS = ("README.md", "doc/*.md")


class Docs:
    """Every user-facing doc file, keyed by repo-relative path."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.files: dict[str, str] = {}
        for pattern in DOC_GLOBS:
            for path in sorted(root.glob(pattern)):
                if path.is_file():
                    self.files[path.relative_to(root).as_posix()] = path.read_text(encoding="utf-8", errors="replace")

    def find(self, pattern: Pattern[str]) -> list[tuple[str, int, Match[str]]]:
        """All matches as (relative path, 1-based line, match object)."""
        hits: list[tuple[str, int, Match[str]]] = []
        for rel, text in self.files.items():
            for lineno, line in enumerate(text.splitlines(), 1):
                for match in pattern.finditer(line):
                    hits.append((rel, lineno, match))
        return hits

    def contains(self, needle: str) -> bool:
        return any(needle in text for text in self.files.values())
