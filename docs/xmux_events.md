# Xmux Events

## Overview

Xmux now has a live event transport alongside `xmux.log`.

- `xmux.log` is the append-only human-readable command log.
- `xmux.port` is the live machine-readable event stream.

The intent is:

- `xmux.log` for durable command history
- `xmux.port` for realtime structured events

## Transport

`xmux.port` is a Unix-domain socket at:

```text
~/.xmux/xmux.port
```

Xmux starts the socket listener during app startup and injects its absolute path into each shell as:

```text
XMUX_PORT
```

Shells and helper processes can then send newline-delimited JSON messages to that socket.

## Message Format

The event stream uses newline-delimited JSON. The intended shape is JSON-RPC 2.0 notifications or requests.

Example notification:

```json
{"jsonrpc":"2.0","method":"command.start","params":{"command":"git status","terminal_id":"B5A6..."}}
```

Current expectations:

- one JSON message per line
- UTF-8 text
- typically JSON-RPC notifications
- requests are also accepted, but the app does not currently generate JSON-RPC responses

## CLI

The standalone CLI exposes the event transport through:

```bash
xmux event send --notify --param "command=git status" command.start
xmux event show
xmux event show --once
```

### `xmux event send`

`xmux event send` writes a single newline-delimited JSON message to `XMUX_PORT` or `~/.xmux/xmux.port`.

Supported forms:

```bash
xmux event send --notify command.start
xmux event send --notify --param "command=git status" command.start
xmux event send --id 1 pane.focus '{"pane":"left"}'
echo '{"jsonrpc":"2.0","method":"ping","id":1}' | xmux event send
```

Notes:

- `--notify` omits the JSON-RPC `id`
- `--param key=value` builds a string-valued params object
- raw JSON can be passed on stdin

### `xmux event show`

`xmux event show` connects to the live event socket and prints events as they arrive.

Use:

```bash
xmux event show
xmux event show --once
```

`--once` prints the first received event and exits.

## App Integration

The app-side event system has three parts:

1. `XmuxEventPort` starts the Unix socket listener and keeps a small in-memory ring buffer of recent events.
2. `XmuxEventPanel` renders that ring buffer in the UI.
3. `ContentView` places the event panel beside the live log panel under the main terminal.

The live panel is intended for quick inspection while developing shell hooks, agents, or app-side event producers.

## Shell Integration

The zsh integration emits `command.start` before each interactive command runs.

Current behavior in `_xmux_preexec`:

1. append the raw command to `xmux.log`
2. emit a `command.start` notification to `xmux.port`

The emitted payload includes:

- `command`: the command line exactly as passed to `preexec`
- `terminal_id`: the xmux terminal UUID when available

Example:

```json
{"jsonrpc":"2.0","method":"command.start","params":{"command":"ls -la","terminal_id":"..."}}
```

## UI Behavior

The bottom area under the terminal now has two live panels:

- `xmux.log`
- `xmux.port`

The event panel:

- shows the `xmux.port` path in its header
- auto-scrolls as new events arrive
- keeps a bounded recent history in memory
- can be cleared from the UI without affecting the socket listener

## Current Event Set

Currently documented and emitted:

- `command.start`
- `xmux.session.start`
- `xmux.session.end`
- `pi.session_start`
- `pi.session_before_switch`
- `pi.session_before_fork`
- `pi.session_before_compact`
- `pi.session_compact`
- `pi.session_before_tree`
- `pi.session_tree`
- `pi.session_shutdown`
- `pi.before_agent_start`
- `pi.agent_start`
- `pi.agent_end`
- `pi.turn_start`
- `pi.turn_end`
- `pi.message_start`
- `pi.message_update`
- `pi.message_end`
- `pi.tool_execution_start`
- `pi.tool_execution_update`
- `pi.tool_execution_end`
- `pi.model_select`

### Pi forwarded events

When `pi` is launched from an xmux-managed shell, the injected `Resources/xmux/bin/pi` wrapper adds the bundled `Resources/xmux/extensions/pi-xmux-events.ts` extension.

That extension forwards pi lifecycle, streaming, and tool execution events to `xmux.port` as JSON-RPC notifications whose method name is `pi.<event-type>`.

For the forwarded payload shape, lifecycle summary, and the Sessions panel `idle` / `working` mapping, see [pi_lifecycle.md](pi_lifecycle.md).

Example events:

```json
{"jsonrpc":"2.0","method":"xmux.session.start","params":{"id":"44CB117A-25F5-4C0A-991F-EF4630EAB9E9","index":2}}
{"jsonrpc":"2.0","method":"pi.session_start","params":{"terminal_id":"...","pid":12345,"session_file":"/Users/me/.pi/agent/sessions/.../session.jsonl","event":{"reason":"startup","previousSessionFile":null}}}
{"jsonrpc":"2.0","method":"pi.message_update","params":{"terminal_id":"...","pid":12345,"session_file":"/Users/me/.pi/agent/sessions/.../session.jsonl","event":{"assistantMessageEvent":{"type":"text_delta","delta":"Hello"}}}}
{"jsonrpc":"2.0","method":"pi.tool_execution_start","params":{"terminal_id":"...","pid":12345,"session_file":"/Users/me/.pi/agent/sessions/.../session.jsonl","event":{"toolName":"bash","args":{"command":"ls -la"}}}}
```


## Design Notes

- `xmux.log` remains the safer fallback for durable inspection.
- `xmux.port` is intentionally realtime and lightweight.
- The app tolerates failures silently so socket issues do not break terminal startup or shell execution.
- The event transport is local to the app process and intended for xmux-managed shells and local tooling.
