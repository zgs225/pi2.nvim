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
| Types / undefined symbols / Python smells | `make lint` | `lua-language-server` over `lua/` (strict, `.luarc.json`), `tests/` + `scripts/e2e/` (`.luarc-tests.json`), and `ruff` over `scripts/` | `lint` job |
| 7 rules: LuaJIT parse (G24), docs sync, config three-spots (G19) | `make check` | `luajit`, `python3` | `checks` job |
| Prove the gates can fail | `make check-selftest` | same as above | `checks` job (runs first) |
| Doc links + anchors | `make docs-links` | `python3` | `checks` job |
| Behaviour | `make test` / `make smoke` / GUI | nvim (+ plenary, optional render-markdown) | `tests` job (`make test` only; `make smoke` and the GUI layer stay local — they load the user's own config) |

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
  no linter, because stylua only reads Lua and lua-language-server only reads Lua
  trees (never the Python under `scripts/`). `make style` runs
  `ruff format --check`, `make lint` runs `ruff check`.
- **`make lint` covers three trees, with two configs** (§ `.luarc-tests.json`
  below). It used to read `lua/` only, so nothing type-checked `tests/` or
  `scripts/e2e/` at all.
- `mise install` (after a one-time `mise trust`) is the whole setup. No global
  installs, no version managers per tool, same on Linux and macOS (aqua backend
  ships official release binaries).
- `LUAJIT_BIN` overrides the luajit binary (`make parse LUAJIT_BIN=/usr/bin/luajit`).
  It does **not** buy a blanket permission: a version number is what a build calls
  itself, not what its grammar accepts, so `parse-luajit` probes the parser before
  every run (contract 2 below) and refuses one that accepts Lua 5.3 syntax — with
  exit 2 and the remedy — instead of reporting `ok: 0 findings`. A distro build is
  fine exactly when it passes that probe; the pinned build
  (`2.1.1744318430`) and CI's `apt install luajit` both do.
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
- Findings render as `path:line: severity: [rule] message` — grep-able and
  clickable in an editor.

### Exit codes

| Code | Meaning | When |
|------|---------|------|
| `0` | clean | every rule ran and reported nothing blocking |
| `1` | findings | at least one **blocking** (`error`/`warn`) finding — **whether or not a rule also failed to run** |
| `2` | broken gate | no blocking findings, but at least one rule could not run (missing tool, unreadable or absent subject tree, unknown rule name) |

Findings deliberately outrank a broken gate: a run that found real violations must
not be reported as "the gate is broken", or the violations get ignored while
someone debugs the harness. Errors always go to **stderr** and `--json` always
carries both `findings` and `errors`, so nothing is hidden when both happen at
once. CI needs no special handling — any non-zero fails the job. A `warn` finding
is a finding: it exits 1 (see contract 3).

### Severities

| Severity | Blocks? | For |
|----------|---------|-----|
| `error` | yes | the code is wrong, at a location the rule can name |
| `warn` | yes | a fact about the tree ("nothing here for this rule") or a real defect the rule cannot localize |
| `info` | **no** | an advisory heuristic whose premise static analysis cannot prove |

`info` is the only non-blocking severity, and it exists because one backlog rule
could not be written honestly without it: `uv-fast-event` (G26) asks whether a
`vim.uv`/`vim.system` callback touches the editor without `vim.schedule`, and no
static reachability proof of "this callback runs on a fast event" is possible — a
heuristic that fires on compliant code must not be able to fail a merge, and
turning it into a `warn` (which exits 1) would make the gate red on a clean tree.
So an `info` finding is printed, counted and carried in `--json`, and the runner
still prints `ok: … 0 blocking findings (N advisory)` and exits 0. The consequences
are deliberate: a rule that *can* prove its finding must use `error`; `info` is
never a place to park a real defect, and a rule made only of `info` findings is not
a gate — it is a report, and the rule's docstring has to say so.

### The four contracts

Each is a scar from a run that reported green while checking nothing (G25).

1. **A missing tool is an error, not a skip.** `run()` raises `CheckError`; the
   runner prints the remedy (`mise install`, `LUAJIT_BIN=…`) and exits 2.
   `if not shutil.which(...): return []` is how a gate checks nothing forever.
2. **Trust nothing that cannot demonstrate it — probe the binary, never regex raw
   Lua.** A version string is a claim, not a capability; a binary must show that
   it rejects the thing it is supposed to reject before its verdicts count.
   `parse-luajit` compiles a control file of valid Lua (which must succeed, or the
   binary is not a parser at all) and then one file per Lua 5.3-only operator —
   `&`, `|`, `<<`, `>>`, `~`, `//` — each of which must **fail**; a parser that
   accepts any of them is refused with a `CheckError` leading to exit 2, naming the
   binary, the operator and the remedy. The verdict is cached per *resolved binary
   path*, because `--self-test` hands the rule different binaries in one process
   and a cached "good" must not launder a lenient parser.

   This is measured, not defensive: `/usr/bin/luajit` 2.1.1794386141 accepts
   `1 & 2` (it rejects only `//`), so on a tree whose only Lua 5.3 use is `&` the
   old gate printed `ok: 0 findings` where the pinned 2.1.1744318430 finds one —
   and on `fixtures/parse-luajit/bad` (one `&` file, one `//` file) the lenient
   build reports 1 of the 2 findings, silently dropping the `&` file. The same
   distrust applies to text matching: rules tokenize with `lua.code_tokens`
   first, because the G24 "banned syntax" greps that shipped for a year matched
   `-- Buffer & windows ---` and the string `"&Yes\n&No"` in this very repo — five
   hits, zero real. A rule that cries wolf gets deleted.
3. **A tree is never silently clean: warn vs error.** One contract, all seven
   rules — the two original ones illustrate it here.
   The *subject tree is absent or unreadable* → `CheckError`, exit 2: a root with
   no `lua/` directory is refused by both `docs-commands` and `parse-luajit`,
   because then the rule cannot even tell whether this is a plugin tree. The *tree
   exists but holds nothing for the rule* → **exactly one** `severity="warn"`
   finding, exit 1: `docs-commands` warns when `lua/` has no
   `nvim_create_user_command(` and when commands exist but `README.md`/`doc` are
   empty; `parse-luajit` warns when `lua/` holds no `*.lua` file. A warn is not a
   pass — the run is not green, it is a fact about the tree. The split exists
   because a hard error for "nothing to verify" makes
   `python3 -m scripts.checks --root <partial tree>` useless (one rule's
   tree-sensitivity would hide every other rule's findings behind exit 2), and
   silence makes an empty tree read as "in sync".
4. **Every rule ships both fixtures — and a refusal is a fixture too.**
   `--self-test` fails a rule that has no `expect=0` fixture (cannot prove it stays
   quiet) or no `expect>0` fixture (cannot prove it fires): G25 as a meta-rule. Two
   optional knobs on `Fixture` cover the opposite direction:
   - `env: dict[str, str]` is applied to `os.environ` for that fixture only (keys
     absent before are deleted again afterwards), so a rule that resolves an
     external binary can be pointed at a stub without leaking a `LUAJIT_BIN` into
     the next fixture.
   - `expect_error=True` means the fixture passes only if `run()` raises
     `CheckError`; such a fixture counts as neither clean nor failing for the
     meta-rule.

   `fixtures/parse-luajit/always-accept.sh` — a `#!/bin/sh` that exits 0 for any
   input — is the point: the probe must refuse it rather than trust it. The same
   two knobs prove a rule refuses a wrong tree (`no-lua/`). `--self-test` is now
   32 fixtures across 7 rules.

## Linting the developer trees: `.luarc-tests.json`

`make lint` is three passes plus the Python, not one:

```bash
lua-language-server --check lua          --configpath .luarc.json        # strict: full diagnostic set
lua-language-server --check tests        --configpath .luarc-tests.json  # narrower, documented
lua-language-server --check scripts/e2e  --configpath .luarc-tests.json  # narrower, documented
ruff check scripts
```

`lua/` ships inside the user's Neovim, so it is held to library quality. `tests/`
and `scripts/e2e/` ship nothing and run only under a developer's own Neovim, so
their annotations are not — but "not library quality" is not "not checked". Before
this config existed `make lint` read `lua/` alone, and pointing the strict config at
`tests/` measured **7995 problems in 140 files**, 78 of them real `Errors` nobody
had seen: Lua 5.4 digit separators (`60_000`) that the pinned LuaJIT cannot parse
at all (removed from two specs and `scripts/e2e/bg_tasks_delivery.lua`). The config
is deliberately explicit, so a reader can audit every exemption:

- `diagnostics.globals`: `vim`, `it`, `describe`, `before_each`, `after_each`,
  `pending` — the busted/plenary globals no type system declares.
- `diagnostics.disable`, each class measured as harness noise rather than a defect:
  - `undefined-field` — 5513 hits, the bulk of it: plenary extends `assert` with
    `is_nil` / `is_true` / …, which no type system knows.
  - `need-check-nil`, `param-type-mismatch`, `duplicate-set-field`,
    `missing-parameter`, `missing-return`, `inject-field`, `undefined-doc-name` —
    annotation debt in specs, not behaviour.
  - `return-type-mismatch`, `redundant-parameter` — exactly 2 findings, both
    LuaLS inference limits.

Everything else stays on, and the 3 real defects that pass found were fixed in the
specs rather than disabled. `runtime.version` is `LuaJIT`, so the type check and
the parse gate agree on the grammar even though `tests/` is **not** in the parse
gate: `make parse` remains `lua/`-only on purpose (the plugin's runtime constraint
is what that gate answers; the developer trees are not it).

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
   all, so letting `make format`/`make style` walk them is not an option. A
   fixture that needs a specific binary passes `env={"LUAJIT_BIN": …}`; one that
   must be *refused* passes `expect_error=True` (contract 4 above).
3. Register it in `rules/__init__.py::ALL`.
4. `make check-selftest` (must pass), then `make check` (must be green on
   `main` — if it is not, the tree is wrong, not the rule; fix the tree or add an
   allowlist entry *with a reason string*).
5. Update the rule table below and, if it encodes a new rule of conduct, the
   prose that states it (`AGENTS.md` / `gotchas.md`).

## Rules in place

| Rule | Guards | Notes |
|------|--------|-------|
| `parse-luajit` | G24 — a Lua 5.3-only operator merges green and the plugin fails to *load* on Neovim stable | Compiles every file under `lua/` with the LuaJIT that Neovim embeds, after probing that this binary actually rejects Lua 5.3 syntax (contract 2). `tests/` and `scripts/` stay out of this gate — they are developer-run, not the plugin's runtime constraint — but they are type-checked by `make lint` with `.luarc-tests.json`, which is what caught the digit separators that made them unparseable. |
| `docs-commands` | The docs sync gate for `:Pi*` — a new command must be documented in the same change, and a stale doc mention must die with the command | Both directions. A doc mention that is a strict prefix of real commands (`:PiSub` for `:PiSubFirst`/… family) is accepted shorthand. |
| `config-three-spots` | G19 — a `---@class pi.*` field and the `defaults` entry it is merged with can disagree, and the option silently does nothing | Both directions, code against code: the `---@class pi.Options` + `---@field` tree vs the `local defaults = { … }` table, both in `lua/pi/config.lua` (`vim.tbl_deep_extend("force", defaults, opts)` can only merge keys `defaults` has). Optional fields (`---@field name?`) may be absent from `defaults` — `nil` is the meaning, 13 measured deliberate cases (`subagent.tools`, `layout.side.height`, …) — and descent follows a field's declared type only when its first `|` alternative is a plain `pi.<Class>`. |
| `docs-config` | Docs sync, config keys — an option ships documented-but-dead, or exists only in source | Both directions between the `defaults` table in `lua/pi/config.lua` (code) and the fenced `require("pi").setup({ … })` example that opens `doc/configuration.md` (docs). Both sides are tokenized and parsed as table literals, so a positional array value (`left = { "context", "attention" }`) is never a key — and a commented-out option is not documentation, so commenting a key out is exactly the drift it reports. Found real drift on its first run: `title.lang` / `title.model` were in `defaults` but missing from the example, now documented as `nil`. |
| `docs-keymaps` | Docs sync, default keymaps — a binding ships undocumented, or a documented one no longer exists | Both directions read the same anchored slice: the bullet list introduced by the `"bind on its own"` sentence in `doc/keymaps.md`, ending at the next heading, fenced blocks excluded. Forward: every literal lhs of a `vim.keymap.set(` inside `Chat:_set_keymaps` (`lua/pi/ui/chat/init.lua`) must be mentioned in that list. Reverse: every backticked `<Key>` name in it must be a literal lhs somewhere under `lua/`. Both are anchored because a key mentioned in `## Example setup` is the user's own example, not a claim about plugin bindings — counting it as one flagged correct docs *and* credited a plugin binding with documentation it did not have. Bare-word keys (`q`, `gf`) are trusted in the forward direction only, and a non-literal lhs (`for _, key in ipairs(…)`, `entry.lhs`, `Keys.bind`) in neither. |
| `docs-highlights` | Docs sync, highlight groups — a `Pi*` group ships undocumented, or a documented row names a dead group | Both directions between `nvim_set_hl(0, "Pi…", …)` under `lua/` and the rows of `doc/highlight-groups.md`. Token-level rather than line-oriented, because 9 definitions in `lua/pi/ui/highlights.lua` put the group name two lines below the call. The dynamically built `PiAnsi*` family is excluded in both directions (names made by string concatenation, prose-only in the docs). |
| `docs-api` | Docs sync, public API — a public function ships undocumented, or `doc/api.md` promises one that no longer exists | Both directions between `function M.<name>` (or `M.<name> = function`) in `lua/pi/init.lua`, tokenized so a commented-out definition does not count, and `pi.<name>` mentions in `doc/api.md`, plain text there because a mention is only ever a regex. |

What is still missing from that class — spec hook scoping (G14),
config-read-at-call-time (G20), uv fast events (G26), expr mappings (G1/G2), test
isolation (G17/G18), and the CI-only changelog rule — is specified item by item
in Gitea issue **#117** (`harness: remaining machine-checkable gates`). Gone
from that backlog are the docs-sync classes: commands, config keys, keymaps,
highlight groups and the public API are all gated now, and closing them paid for
itself on arrival, since `docs-config` found real drift on its first run.

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
- **A `warn` that means "never mind".** `severity="warn"` is neither a pass nor
  a mute: it still exits 1. Use it for a fact about the tree (nothing here for the
  rule to check, contract 3) or for a real defect the rule cannot localize — never
  to keep a run green by softening a real defect. The non-blocking channel is
  `info`, and it is reserved for heuristics whose premise static analysis cannot
  prove (see § Severities).
- **Adopting a linter because it exists.** No luacheck/selene/ast-grep: the
  *checks* stay stdlib-only Python (no third-party packages at runtime) plus
  binaries the gates already need. `ruff` is the one added linter, and it exists
  because its absence was a measured hole, not a preference — the Python had no
  formatter and no linter at all. Revisit `ast-grep` only when a rule needs
  structural matching tokens cannot express.
