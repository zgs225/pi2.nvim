# The ask tool

The bundled [`ask`](extensions.md#bundled-ask-extension-extensionsaskts) extension gives the model one more tool: it can stop mid-turn and ask **you** a bounded set of multiple-choice questions. It is meant for the decisions only you can make — which of two designs to keep, which branch to target, whether a file may be deleted — instead of guessing, or asking in prose and ending the turn.

One call asks **1–4 questions** at once (each with 2–4 options, or no options at all for a free-text question), optionally multi-select, and blocks until you answer, cancel, or `ask.timeout_ms` fires. Answers come back to the model one line per question, so it acts on your choice instead of re-reading a paragraph.

The tool ships on by default (`ask.enabled = true`) and is injected into parent sessions only — a sub-session can never ask you anything.

## What it looks like

The questionnaire is a float over the chat window (filetype `pi-ask`):

```
┌─ ask ───────────────────────────────────────────────────────────┐
│  ask · 1/3                                                      │
│  ■Scope  □Storage  [Rollout]                                    │
│                                                                 │
│  Where should the shared cache live?                            │
│                                                                 │
│  > 1. Redis     shared across pods, needs a Service             │
│    2. Local     no dependencies, per-node cold starts           │
│    3. Type your own answer…                                     │
│                                                                 │
│  j/k move · h/l question · ⏎ confirm · i type · ZZ submit · Esc  │
└─────────────────────────────────────────────────────────────────┘
```


- **Progress line** — `ask · 1/3`, only on a multi-question ask.
- **Chip row** — one chip per question: `■` answered, `□` still open, and the current question in `[brackets]`. A single-question ask has neither progress line nor chips.
- **Question line** — the model's question, one sentence.
- **Option rows** — `> ` marks the cursor, `1.` / `2.` are the digits you can press, and the dim text after a label is the model's one-line description of that choice. On a multi-select question every option also carries `■` (picked) or `□` (not picked).
- **`Type your own answer…`** — the last row, numbered after the model's options, never part of the model's own option list (the extension rejects an option labelled `Other`, `Type something`, `Skip` and friends, so the entry cannot be duplicated). Once you have typed something it shows the text after a `(wrote)` marker. With `ask.allow_free_text = false` the row is gone, except on a question that has no options at all — there it is the only way to answer.
- **Hint row** — the keys for the current state (the set shrinks on a single-select or single-question ask).
- **Review page** — a multi-question ask gets one extra page after the last question: each question with `■`/`□`, the answer you gave, and `Unanswered` when you skipped it.

The chrome (title, marks, hints, `Type your own answer…`) follows `title.lang` / the UI locale, like every other π label.

## Keys

All keys are **buffer-local** to the ask float and only fire while it has focus. They are configured under `ask.keys` ([Configuration](configuration.md)) and accept [key specs](keymaps.md#key-specs).

| Key | Default | What it does |
| --- | --- | --- |
| Move the cursor | `j` / `k` | Down / up one option |
| Switch question | `l` / `h` | Next / previous question (multi-question asks only) |
| First / last option | `gg` / `G` | Jump to the top / bottom of the option list |
| Select | `<CR>` | Single-select: confirm the cursored option and advance; on the last question, submit |
| Toggle | `<Space>` | Multi-select: tick/untick the cursored option; on a single-select question it behaves like `<CR>` |
| Direct pick | `1`–`9` | Select the option at that position (always bound, not configurable) |
| Clear | `x` | Clear every selection of the current question |
| Free text | `i` | Answer the current question with your own text instead of an option |
| Submit | `ZZ` | Send the whole questionnaire; if any question is still unanswered it asks first |
| Cancel | `<Esc>` / `q` / `ZQ` | Cancels the whole ask |
| Collapse | closing the float (`:q`, `<C-w>c`) | Hides it **without** answering for you: the request goes back into the [attention queue](attention.md#immediate-vs-queued) and stays there — it does not pop back up on its own, `:PiAttention` reopens it |

The float is a normal-mode window: it refuses insert mode (typing `i` opens the free-text dialog instead), and answering it hands insert mode back to the window that had it.

Differences by shape: a single-question ask hides the progress line and chips, and `h`/`l` do nothing; a multi-question ask advances on `<CR>` and ends on the review page, where `<CR>` or `ZZ` submits and `h`/`l` walk back to a question you want to change. `ZZ` submits from any page (with a confirmation when something is still unanswered); `Esc` always cancels.

## Multi-select and free text

- A `multi` question accepts several options: `<Space>` ticks and unticks, and the selection is sent as a list.
- Free text and options are **exclusive for one question**: `i` opens the input (empty input returns you to the options), and answering with text replaces the question's selections rather than adding to them.
- `x` clears the current question on a multi-select ask (on a single-select question it does nothing — pick another option instead).
- A text answer is marked `(wrote)` in the result, so the model can tell a label it offered from something you typed.

What the model receives looks like this — one `User answered:` line, then one line per question:

```
User answered:
- scope: Both (option 1)
- storage: (wrote) whatever the cluster already has
- rollout: Unanswered
```

A cancellation is `User cancelled the ask; no answers were provided. …`, and the model is told to continue with a stated assumption. **Cancelling is a normal outcome, not an error** — no error block, no failure status.

## Turning it off

```lua
require("pi").setup({
    ask = { enabled = false },
})
```

The tool then disappears from the model's tool list entirely. Details that matter:

- It is **on by default** and the switch applies **live**: the extension re-reads the published options on every tool call and every turn start, so the next turn already cannot ask — no restart, no respawn.
- A questionnaire **already on screen** stays answerable; disabling does not dismiss it.
- With the tool off, the model is told asking is disabled and to continue with a sensible default plus the assumption it made.
- Sub-sessions never get the tool, whatever the setting says.
- `ask.ui` currently accepts only `"float"`; `ask.max_questions` / `ask.max_options` / `ask.allow_free_text` are limits the extension enforces (an over-limit call is rejected with an error the model can correct).

## Waiting, timeouts, and troubleshooting

The ask is an [attention request](attention.md), but a stricter one: because the model is stalled until it is answered, it pops up as soon as it arrives while its own tab is showing — no waiting for the prompt to gain focus, no draft check. A request for a session in another tab, or for a detached background session, is queued with a statusline indicator and a notification; the agent stays blocked either way.

- **It did not pop up.** Its session lives in a tab you are not looking at, or it runs detached in the background. Switch to that tab, or `:PiAttention` (or `pi.attention()` from Lua) to open the oldest queued request.
- **I closed it by accident.** Closing the window (`:q`, `<C-w>c`, a plugin cleaning floats up) only hides it — the request goes back to the queue, stops popping back up, and `:PiAttention` reopens it. Switching windows does not close it. Only `<Esc>`, `q`, `ZQ` or `ask.timeout_ms` actually cancel it.
- **It waits forever.** That is the default (`ask.timeout_ms = nil`). Set a number of milliseconds to have the ask cancelled automatically; the model is then told no answers were provided and has to proceed on a stated assumption — the same outcome as cancelling by hand.
- **One dialog per question instead of the float.** The host did not understand the payload, so the extension degraded to one plain `ctx.ui.select` per question (rendered by the host's own select dialog, with a free-text escape hatch). Nothing is lost; the tool result carries `details.degraded = true`.
- **No UI at all** (`pi -p`, JSON mode): the tool answers immediately with a one-line "no interactive UI" instruction and the model continues — it never blocks.
- **`:checkhealth pi`** reports the bundled `ask` extension (file found), whether the runtime config file was written, and — as a warning — a `pi` older than the **1.6.0** floor the blocking host call needs. Below that floor the degraded path above takes over rather than failing.
