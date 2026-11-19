"""A small Lua lexer: enough to tell code from strings and comments.

Why not regex the source directly? Because that is how gates get switched off.
The 5.3-operator audit commands recorded in `gotchas.md` (G24) match
`-- Buffer & windows ---` and the string `"&Yes\\n&No"` in this very repo — five
hits, zero of them real. Any rule that reads Lua source tokenizes first and
matches on tokens; comments and string bodies never reach the matcher.

Deliberately *not* a parser. Syntax authority is the LuaJIT binary in
`rules/parse_luajit.py`; this module only needs to know which bytes are code.
"""

from __future__ import annotations

import string
from dataclasses import dataclass
from typing import Iterator

NAME_START = frozenset(string.ascii_letters + "_")
NAME_CHARS = NAME_START | frozenset(string.digits)
DIGITS = frozenset(string.digits)
HEX = frozenset(string.digits + "abcdefABCDEF")

# Multi-character operators, longest first, so `...` does not lex as `.` `.` `.`.
OPERATORS = (
    "...",
    "..",
    "==",
    "~=",
    "<=",
    ">=",
    "::",
    "//",
    "<<",
    ">>",
    "->",
    "+",
    "-",
    "*",
    "/",
    "%",
    "^",
    "#",
    "&",
    "~",
    "|",
    "<",
    ">",
    "=",
    "(",
    ")",
    "{",
    "}",
    "[",
    "]",
    ";",
    ":",
    ",",
    ".",
)


@dataclass(frozen=True)
class Token:
    """One lexical token. `line` is 1-based, `value` is the decoded string body."""

    kind: str  # name | number | string | punct | comment
    text: str
    line: int
    value: str | None = None

    def is_punct(self, text: str) -> bool:
        return self.kind == "punct" and self.text == text

    def is_name(self, text: str) -> bool:
        return self.kind == "name" and self.text == text


def _long_bracket_open(src: str, i: int) -> tuple[int | None, int]:
    """If `src[i] == '['` opens a long bracket, return (content_start, level)."""
    j = i + 1
    level = 0
    while j < len(src) and src[j] == "=":
        level += 1
        j += 1
    if j < len(src) and src[j] == "[":
        return j + 1, level
    return None, 0


def _long_bracket_end(src: str, start: int, level: int) -> int:
    """Index of the character after the matching `]==]` (or len(src))."""
    close = "]" + "=" * level + "]"
    idx = src.find(close, start)
    return len(src) if idx < 0 else idx + len(close)


_SIMPLE_ESCAPES = {
    "a": "\a",
    "b": "\b",
    "f": "\f",
    "n": "\n",
    "r": "\r",
    "t": "\t",
    "v": "\v",
    "\\": "\\",
    '"': '"',
    "'": "'",
    "\n": "\n",
}


def _decode(body: str) -> str:
    """Best-effort unescape. Command names are plain ASCII; this is for safety."""
    out: list[str] = []
    i = 0
    while i < len(body):
        ch = body[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        i += 1
        if i >= len(body):
            break
        esc = body[i]
        if esc in _SIMPLE_ESCAPES:
            out.append(_SIMPLE_ESCAPES[esc])
            i += 1
        elif esc == "z":
            i += 1
            while i < len(body) and body[i] in " \t\r\n\v\f":
                i += 1
        elif esc == "x":
            hexpart = body[i + 1 : i + 3]
            try:
                out.append(chr(int(hexpart, 16)))
                i += 3
            except ValueError:
                i += 1
        elif esc in DIGITS:
            numpart = ""
            while i < len(body) and body[i] in DIGITS and len(numpart) < 3:
                numpart += body[i]
                i += 1
            out.append(chr(int(numpart, 10)))
        else:
            out.append(esc)
            i += 1
    return "".join(out)


def tokenize(src: str) -> list[Token]:
    """Lex `src`. Never raises: malformed input yields tokens up to the damage."""
    tokens: list[Token] = []
    i = 0
    line = 1
    n = len(src)
    while i < n:
        ch = src[i]

        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch in " \t\r\v\f":
            i += 1
            continue

        # Comments: `--` then optional long bracket, else to end of line.
        if ch == "-" and i + 1 < n and src[i + 1] == "-":
            start = i
            content_start, level = _long_bracket_open(src, i + 2)
            if content_start is not None:
                end = _long_bracket_end(src, content_start, level)
                text = src[start:end]
                tokens.append(Token("comment", text, line))
                line += text.count("\n")
                i = end
            else:
                end = src.find("\n", i)
                end = n if end < 0 else end
                tokens.append(Token("comment", src[start:end], line))
                i = end
            continue

        # Long strings: `[[ ... ]]`, `[==[ ... ]==]`.
        if ch == "[":
            content_start, level = _long_bracket_open(src, i)
            if content_start is not None:
                end = _long_bracket_end(src, content_start, level)
                text = src[i:end]
                body = text[level + 2 : -(level + 2)] if end <= n else text[level + 2 :]
                if body.startswith("\n"):
                    body = body[1:]
                tokens.append(Token("string", text, line, value=body))
                line += text.count("\n")
                i = end
                continue

        # Short strings.
        if ch in "\"'":
            quote = ch
            start = i
            j = i + 1
            buf: list[str] = []
            while j < n:
                c = src[j]
                if c == "\\" and j + 1 < n:
                    buf.append(src[j : j + 2])
                    j += 2
                    continue
                if c == quote:
                    j += 1
                    break
                if c == "\n":  # unterminated; real Lua errors here
                    break
                buf.append(c)
                j += 1
            text = src[start:j]
            tokens.append(Token("string", text, line, value=_decode("".join(buf))))
            line += text.count("\n")
            i = j
            continue

        # Numbers.
        if ch in DIGITS or (ch == "." and i + 1 < n and src[i + 1] in DIGITS):
            start = i
            j = i
            if src.startswith(("0x", "0X"), i):
                j += 2
                while j < n and (src[j] in HEX or src[j] == "."):
                    j += 1
                if j < n and src[j] in "pP":
                    j += 1
                    if j < n and src[j] in "+-":
                        j += 1
                    while j < n and src[j] in DIGITS:
                        j += 1
            else:
                while j < n and src[j] in DIGITS:
                    j += 1
                if j + 1 < n and src[j] == "." and src[j + 1] in DIGITS:
                    j += 1
                    while j < n and src[j] in DIGITS:
                        j += 1
                if j < n and src[j] in "eE":
                    k = j + 1
                    if k < n and src[k] in "+-":
                        k += 1
                    if k < n and src[k] in DIGITS:
                        j = k
                        while j < n and src[j] in DIGITS:
                            j += 1
            tokens.append(Token("number", src[start:j], line))
            i = j
            continue

        # Names.
        if ch in NAME_START:
            j = i + 1
            while j < n and src[j] in NAME_CHARS:
                j += 1
            tokens.append(Token("name", src[i:j], line))
            i = j
            continue

        # Operators / punctuation.
        for op in OPERATORS:
            if src.startswith(op, i):
                tokens.append(Token("punct", op, line))
                i += len(op)
                break
        else:  # unknown byte: keep going, the parse gate owns real errors
            i += 1

    return tokens


def code_tokens(src: str) -> list[Token]:
    """Tokens with comments dropped — everything a rule should ever match on."""
    return [t for t in tokenize(src) if t.kind != "comment"]


def mask(src: str) -> str:
    """`src` with comment and string *contents* blanked, offsets/lines preserved.

    Useful for rules that want line-oriented context (e.g. "is this call at the
    top level?") without re-implementing the lexer in regex form.
    """
    out: list[str] = []
    i = 0
    for token in tokenize(src):
        idx = src.find(token.text, i)
        if idx < 0:
            out.append(src[i:])
            return "".join(out)
        out.append(src[i:idx])
        if token.kind in ("comment", "string"):
            out.append("".join("\n" if c == "\n" else " " for c in token.text))
        else:
            out.append(token.text)
        i = idx + len(token.text)
    out.append(src[i:])
    return "".join(out)


def iter_names(tokens: list[Token]) -> Iterator[Token]:
    return (t for t in tokens if t.kind == "name")
