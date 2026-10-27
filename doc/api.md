# Lua API

Everything exposed by the [user commands](../README.md#commands) is also available from Lua. Grab the module once and call into it directly:

```lua
local pi = require("pi")

-- Setup (called once from your config entrypoint)
pi.setup(opts?)

-- Chat lifecycle
pi.show(opts?)                -- open the chat; opts: { layout = "side"|"float" }
pi.toggle(opts?)              -- open or hide the chat
pi.toggle_chat()              -- hide/show the chat windows for the current tab
pi.toggle_layout(cb?)         -- swap side ↔ float; cb runs after the swap completes
pi.is_visible()               -- boolean: is the chat shown in the current tab?
pi.layout()                   -- "side" | "float" | nil

-- Sessions
pi.new_tab()                  -- open a fresh conversation in a new tabpage (:PiNewTab)
pi.continue_session(opts?)    -- load the most recent session for the current cwd
pi.resume_session(opts?)      -- pick a past session for the current cwd
pi.new_session()              -- start a fresh conversation in the current tab
pi.tree()                     -- navigate the session tree (:PiTree)
pi.fork()                     -- new session from a past user message; picks forkable
                              -- messages, then prefills the prompt for re-asking (:PiFork)
pi.clone()                    -- duplicate the current branch into a new session (:PiClone)
pi.sessions()                 -- toggle the live sessions overview (:PiSessions)
pi.tasks()                    -- toggle the background tasks panel (:PiTasks): the
                              -- background bash tasks reported by the bg-tasks
                              -- extension, with status and durations (see
                              -- doc/usage.md#background-tasks)
pi.session_stats(session?)  -- show the stats dashboard for a session: identity, tokens, cost, cache
                              -- waste, context: current tab's session by default; `s` in :PiSessions
                              -- shows the stats of the session under the cursor (:PiSessionStats)
pi.diff_review(session?)      -- review the git diff of every file changed by a session (:PiDiff);
                              -- `d` in :PiSessions reviews the session under the cursor
pi.set_session_name(name?)    -- set the session display name; without an arg, opens an
                              -- input dialog prefilled with the current name
pi.compact(instructions?, session?) -- manually compact a session (optional guidance); `c` in
                              -- :PiSessions compacts the session under the cursor
pi.toggle_auto_compaction()   -- flip automatic compaction on/off; the statusline
                              -- `compaction` component (a 󰏗 icon) shows the state
pi.changed_files()            -- string[]: files modified by edit/write tools this session

-- Agent control
pi.abort()                    -- cancel the current agent turn, keep the session alive.
                              -- On a parent session it cascades: all of its sub-sessions
                              -- and their batches are interrupted too; a child that
                              -- already received its task keeps its RPC process, while
                              -- one still spawning is reclaimed. While viewing a
                              -- sub-session it aborts only that child (plus any children
                              -- it spawned);
                              -- the parent is NOT interrupted — a parent blocked in
                              -- wait_subagents wakes up because the child's pending
                              -- batch items are settled as `cancelled`
pi.abort_bash()               -- cancel the running direct bash (!) command
pi.abort_retry()              -- cancel the auto-retry backoff ("Retrying…" state); only
                              -- takes effect while the core is between retry attempts
pi.set_steering_mode(mode)    -- how queued steering messages are delivered: "all" (every
                              -- queued steer after the current turn and its tool calls) or
                              -- "one-at-a-time" (one per turn boundary; backend default)
pi.set_follow_up_mode(mode)   -- how queued follow-up messages are delivered: "all" (every
                              -- queued follow-up at completion) or "one-at-a-time" (one
                              -- per completion; backend default)
pi.stop()                     -- kill the RPC process and close the chat for the current tab

-- Sub-sessions
pi.sub_new()                  -- spawn a background sub-session (:PiSubNew)
pi.sub_switch()               -- picker to switch to a child sub-session
pi.sub_parent()               -- return to parent session from child view
pi.sub_close()                -- close current sub-session process (file retained)
pi.sub_view()                 -- picker to view a child sub-session in a read-only float with live streaming (:PiSubView)

-- Prompt input
pi.send_mention(args?, opts?) -- insert an @-mention for the current buffer / selection
pi.attach_image(path)         -- queue an image file as an attachment
pi.paste_image()              -- queue an image from the clipboard (requires img-clip.nvim)
pi.invoke("/command")         -- invoke a backend slash command programmatically

-- Models
pi.cycle_model()              -- step to the next model in the configured (or all) list
pi.select_model()             -- dialog: pick from configured models, then pi's model scope
                              -- (--models/enabledModels), then all models
pi.select_model_all()         -- dialog: pick from every backend-available model

-- Thinking
pi.toggle_thinking()          -- show/hide thinking blocks in the history
pi.cycle_thinking_level()     -- step to the next thinking level
pi.select_thinking_level()    -- dialog: pick a thinking level

-- History blocks
pi.toggle_startup_details()   -- collapse/expand the startup block
pi.toggle_history_blocks()    -- collapse/expand all expandable history blocks

-- Attention queue
pi.attention()                -- open the oldest queued request, switching tab if needed
pi.attention_count(tab?)      -- integer: pending requests in a tab (current tab if omitted)
pi.attention_total()          -- integer: pending requests across all tabs
pi.attention_state(tab?)      -- full state snapshot for custom UI
pi.has_attention(tab?)        -- boolean shortcut for attention_count > 0

-- Navigation inside the chat
pi.focus_chat_history()
pi.focus_chat_prompt()
pi.focus_chat_attachments()
pi.scroll_chat_history(direction, lines?)          -- direction: "up" | "down"; lines defaults to 15
pi.scroll_chat_history_to_bottom()
pi.scroll_chat_history_to_first_agent_response()
pi.scroll_chat_history_to_last_agent_response()
pi.goto_file_under_cursor()   -- open the file referenced on the history line under the cursor

-- Debug
pi.toggle_debug()             -- toggle RPC debug logging for the current Neovim session
```

Most functions are no-ops (or warn) when no session is active in the current tab — safe to bind unconditionally. See [Usage](usage.md) and [Keymaps](keymaps.md) for how these fit into a working setup.

## Queue modes

`pi.set_steering_mode(mode)` and `pi.set_follow_up_mode(mode)` map to the backend's
`set_steering_mode` / `set_follow_up_mode` RPC commands and mirror the
`:PiSteeringMode [mode]` / `:PiFollowUpMode [mode]` user commands. An invalid
mode is rejected (an error notification), and a success notification reports the
mode now in effect.

- **Steering** controls messages queued while the agent is running (the `steer`
  RPC / `streamingBehavior = "steer"`). `"all"` delivers every queued steer
  after the current assistant turn's tool calls; `"one-at-a-time"` (backend
  default) delivers one steer per turn boundary.
- **Follow-up** controls messages queued for after completion (the `follow_up`
  RPC). `"all"` delivers every queued message once the agent finishes;
  `"one-at-a-time"` (backend default) delivers one per completion.

With no argument the commands read the backend's current value (`get_state`)
and switch to the other mode. The mode is per-session backend state, so — like
thinking level, model, and auto-compaction — it applies to the current tab's
session and is not cascaded to sub-sessions; a sub-session keeps its own mode
and can be changed from its view.

## Web console

The web-console bridge is its own module (it is not required for normal editor use, and `pi.setup()` only starts it when [`web.enabled = true`](configuration.md)):

```lua
local web = require("pi.web")

web.setup(opts?)  -- { host?: boolean, start?: boolean, autocmds?: boolean }
web.start()       -- start the bridge; lazily spawns `pi2 daemon` when the socket is missing
web.stop()        -- stop the bridge (sessions and the daemon keep running)
web.status()      -- table: enabled/started/ready/socket/workspace/instance/sessions/host
web.enabled()     -- boolean: configured or currently running
web.start_daemon() -- boolean, err?; spawns the resolved `pi2 daemon` when the socket is missing
```

Daemon resolution and the local login handshake are separate modules, so extensions can reuse them without starting the bridge:

```lua
local runtime = require("pi.web.runtime")

runtime.resolve_daemon(opts?) -- { bin, source = "config"|"path"|"plugin-data"|"checkout"|"npx" } | nil
runtime.read_daemon_json(dir?) -- decoded <runtime>/daemon.json or nil (pure, never throws)

local login = require("pi.web.login")

login.url(opts?)  -- POST /api/v1/console/session; signed-in URL or nil + reason
login.open(opts?) -- login.url() + the platform opener; returns url, opener_err?
```

`opts` exists for tests and custom openers: `runtime_dir`, `timeout` (ms, default 5000), `system` (a `vim.system` replacement), `opener` (a `fun(url): boolean, err?`) and `config`. `login.open()` is the loopback sign-in path that `:PiWeb` uses; other devices pair via `:PiWebPair` instead of being signed in. The CLI token from `<runtime>/cli.token` is sent on stdin and never printed, logged, or placed in argv.

The daemon-side entry point is `require("pi.host").start(workspace?)`, which the daemon (`pi2 daemon`) calls from a headless Neovim (`--headless --listen <sock> -c 'lua require("pi.host").start()'`). See [Web console](usage.md#web-console).

The protocol surface is not part of the public API, but it is reachable for extensions that need to answer a daemon record themselves:

```lua
local commands = require("pi.web.commands")

commands.handlers["workspace.query"]  -- fun(params, ctx): ack, result
commands.dispatch(method, params, ctx) -- same, with unknown-method handling; errors as { code, message }
```

`ctx` carries `session_id`, `id` (request id being answered), `bridge`, and the daemon's `method`, `params` and `client_request_id`. The state a snapshot is built from lives in `require("pi.web.instance")` (`instance()` returns the singleton; it is `nil` while the bridge is stopped). Command contracts and event names are documented in [Web console](usage.md#command-contracts).
