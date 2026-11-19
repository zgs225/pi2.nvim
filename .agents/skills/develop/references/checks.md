# Checks — the machine-checkable half of the harness

`AGENTS.md` and `gotchas.md` are the authority on *what* the rules are. This file
covers the rules a machine can decide, and the gates that decide them.

The premise: a rule that only lives in prose decays. Every rule that can be
stated as a predicate over the source should be a check, because the alternative
is a checklist that gets skimmed, and the failure mode is not "someone forgot" —
it is "everything is green while the defect ships" (G25).

## What runs, and where

| Gate | Command | Needs | CI |
|------|---------|-------|----|
| Formatting | `make style` | `stylua`, `ruff` | `style` job |
| Types / undefined symbols / Python smells | `make lint` | `lua-language-server`, `ruff` | `lint` job |
| LuaJIT parse (G24) + docs sync | `make check` | `luajit`, `python3` | `checks` job |
| Prove the gates can fail | `make check-selftest` | same as above | `checks` job (runs first) |
| Doc links + anchors | `make docs-links` | `python3` | `checks` job |
| Behaviour | `make test` / `make smoke` / GUI | nvim (+ plenary) | **not yet** (issue #118) |

`make check` is the fast, hermetic half: no nvim, no plugin loading, no fixture
data — it reads the tree and answers questions about it in about a second.

## Toolchain: `.mise.toml`

The gate binaries are pinned in `.mise.toml`, which is **the only place a version
lives**:

```toml
[tools]
stylua = "2.5.2"
"aqua:LuaLS/lua-language-server" = "3.18.2"
ruff = "0.17.5"
luajit = "2.1.1744318430"
```

- `.github/workflows/lint.yml` parses this file for the stylua, lua-language-server
  and ruff versions, so local and CI cannot drift.
- **The Python is gated too** (`ruff`, config `ruff.toml`): until that landed, the
  check harness itself — the most-edited code in the repo — had no formatter and
  no linter, because stylua only reads Lua and lua-language-server only reads
  `lua/`. `make style` runs `ruff format --check`, `make lint` runs `ruff check`.
- `mise install` (after a one-time `mise trust`) is the whole setup. No global
  installs, no version managers per tool, same on Linux and macOS (aqua backend
  ships official release binaries).
- `LUAJIT_BIN` overrides the luajit binary (`make parse LUAJIT_BIN=/usr/bin/luajit`).
  Any LuaJIT 2.1 build is the same authority on Lua 5.3 syntax, so a distro
  package is fine; CI uses `apt install luajit` rather than mise.
- Deliberately not pinned: **nvim** (the test layers must run on the editor you
  actually use the plugin in), **python3** (the checks are stdlib-only and run on
  3.8+ — the *linter* is pinned, the interpreter is not the contract), and
  **gt** (gitea-cli, the issue tracker workflow tool — see `gitea.md`).

## Architecture

```
scripts/checks/
  framework.py        Finding / Check / Fixture · registry · runner · self-test
  lua.py              Lua lexer — comments and string bodies never reach a matcher
  docs.py             the doc corpus (README.md + doc/*.md), addressable by line
  rules/__init__.py   ALL = [ … ]  (explicit, in run order)
  rules/*.py          one module per rule
  fixtures/<rule>/    good/ (expect 0) and bad/ (expect N) trees
```

- Entry point: `python3 -m scripts.checks` (`make check`). `--only NAME`,
  `--list`, `--json`, `--root`, `--self-test`.
- Exit codes: **0** clean, **1** findings, **2** a gate is broken (missing tool,
  unreadable tree, unknown rule). CI treats 2 as failure — a broken gate must not
  look like a clean run.
- Findings render as `path:line: severity: [rule] message` — grep-able and
  clickable in an editor.

### The three contracts

1. **A missing tool is an error, not a skip.** `run()` raises `CheckError`; the
   runner prints the remedy (`mise install`, `LUAJIT_BIN=…`) and exits 2.
2. **Every rule ships both fixtures.** `--self-test` fails a rule that has no
   `expect=0` fixture (cannot prove it stays quiet) or no `expect>0` fixture
   (cannot prove it fires). This is G25 turned into a meta-rule.
3. **No regex over raw Lua.** Rules tokenize with `lua.code_tokens` first. The
   G24 "banned syntax" greps that shipped for a year matched
   `-- Buffer & windows ---` and the string `"&Yes\n&No"` in this very repo —
   five hits, zero real. A rule that cries wolf gets deleted.

## Adding a rule

1. Write `rules/<name>.py`:

   ```python
   class DocsKeymaps(Check):
       name = "docs-keymaps"
       summary = "every keymap in the chat is documented in doc/keymaps.md"
       requires = ("python3",)

       def run(self, root: Path) -> List[Finding]:
           ...  # lua.code_tokens(...) + docs.Docs(root).find(...)
           return findings

       def fixtures(self) -> List[Fixture]:
           return [
               self.fixture("good", 0, "in sync"),
               self.fixture("bad", 1, "a keymap missing from the docs"),
           ]
   ```

2. Add `scripts/checks/fixtures/<name>/{good,bad}/…` — the fixture root mimics a
   repo tree (`lua/`, `doc/`, …), because `run(root)` is tree-relative by design.
   Fixture trees are listed in `.styluaignore`: the `bad/` tree must not parse at
   all, so letting `make format`/`make style` walk them is not an option.
3. Register it in `rules/__init__.py::ALL`.
4. `make check-selftest` (must pass), then `make check` (must be green on
   `main` — if it is not, the tree is wrong, not the rule; fix the tree or add an
   allowlist entry *with a reason string*).
5. Update the rule table below and, if it encodes a new rule of conduct, the
   prose that states it (`AGENTS.md` / `gotchas.md`).

## Rules in place

| Rule | Guards | Notes |
|------|--------|-------|
| `parse-luajit` | G24 — a Lua 5.3-only operator merges green and the plugin fails to *load* on Neovim stable | Compiles every file under `lua/` with the LuaJIT that Neovim embeds. `tests/` and `scripts/` are deliberately out of scope: they are developer-run and already use a newer grammar than Neovim 0.10's LuaJIT (`180_000`), so gating them would flag code that is nobody's runtime constraint. |
| `docs-commands` | The docs sync gate for `:Pi*` — a new command must be documented in the same change, and a stale doc mention must die with the command | Both directions. A doc mention that is a strict prefix of real commands (`:PiSub` for `:PiSubFirst`/… family) is accepted shorthand. |

The rest of the class-2/class-3 backlog — config three-spots (G19), spec hook
scoping (G14), config-read-at-call-time (G20), uv fast events (G26), expr
mappings (G1/G2), test isolation (G17/G18), keymaps/config/highlights/API docs
sync — is specified item by item in Gitea issue **#117**
(`harness: remaining machine-checkable gates`).

## What is not a static check

- **Rendering and layout** (G6/G7/G9): `conceallevel`, extmark counts, "does the
  markdown look right". Only a GUI screenshot proves pixels; a unit assertion can
  only pin the invariants (`conceallevel == 0`, attach succeeded, extmarks > 0).
- **Timing and event ordering** (G3/G4/G5): deferred `TextChangedI`, insert-mode
  persistence across `feedkeys` calls. Behaviour under a real event loop is a test-
  layer question, never a source predicate.
- **Judgement**: architecture choices, whether a doc sentence is still *true*,
  which test layer is enough, commit granularity.

Those belong to `references/testing.md` (the layers) and to review. Issue **#118**
tracks the coverage gaps the audit found.

## Anti-patterns

- **Skipping when a tool is absent.** `if not shutil.which(...): return []` — the
  gate then silently checks nothing forever. Raise instead.
- **Prose-parity rules that cannot fail.** If removing the fix from the codebase
  still passes, the check is decoration. `make check-selftest` exists to make that
  impossible for the rules we write.
- **`warn` rules that block merges.** A heuristic (fast-event detection, hot-path
  API bans) is `severity="warn"` and must say so in its docstring; only rules with
  no false positives get to fail CI.
- **Adopting a linter because it exists.** No luacheck/selene/ast-grep: the
  *checks* stay stdlib-only Python (no third-party packages at runtime) plus
  binaries the gates already need. `ruff` is the one added linter, and it exists
  because its absence was a measured hole, not a preference — the Python had no
  formatter and no linter at all. Revisit `ast-grep` only when a rule needs
  structural matching tokens cannot express.
