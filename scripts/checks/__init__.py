"""Static gates for pi.nvim — the harness rules that can be decided by a machine.

Everything in this package exists because a rule that only lives in prose is a
rule that decays. `AGENTS.md` and
`.agents/skills/develop/references/gotchas.md` are the authority on *what* the
rules are; the checks here are the ones that can be enforced without a human.

Layout
------
    framework.py   Finding / Check / Fixture, the registry, the runner, self-test
    lua.py         a small Lua lexer (comments and strings are not code)
    docs.py        the doc corpus (README.md + doc/*.md) as an addressable index
    rules/         one module per rule; `rules/__init__.py` lists them explicitly
    fixtures/      per-rule good/bad trees, used by --self-test

Adding a rule
-------------
1. Write `rules/<name>.py` subclassing `Check`, with `name`, `summary`,
   `run(root) -> list[Finding]` and at least two `Fixture`s: one that must
   produce zero findings and one that must produce a known number. A rule
   without a failing fixture is untested (gotcha G25) and `--self-test` rejects
   it. A fixture may set `env={...}` (applied only while it runs) and
   `expect_error=True` when the rule must *refuse* its input with a `CheckError`
   instead of returning findings — e.g. a parser binary that accepts syntax
   Neovim stable rejects.
2. Add the instance to `ALL` in `rules/__init__.py`.
3. If the rule needs an external binary, resolve it in `run()` and raise
   `CheckError` when it is missing — never skip. A gate that silently skips is
   the fake-green failure mode from G25. If the binary's *capabilities* matter
   (a compiler whose grammar decides the answer), probe them at runtime too: a
   tool that calls itself the right thing may still answer wrongly.

Run
---
    make check                 # every rule, human-readable output
    make check-selftest        # prove every rule can fail (fixtures)
    python3 -m scripts.checks --only docs-commands --json
"""

from .framework import (  # noqa: F401  (re-exported API)
    Check,
    CheckError,
    Finding,
    Fixture,
    load_checks,
    run_checks,
    self_test,
)
