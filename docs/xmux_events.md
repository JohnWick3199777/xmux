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

This is the first structured shell lifecycle event. More events can be added later without changing the transport.

## Design Notes

- `xmux.log` remains the safer fallback for durable inspection.
- `xmux.port` is intentionally realtime and lightweight.
- The app tolerates failures silently so socket issues do not break terminal startup or shell execution.
- The event transport is local to the app process and intended for xmux-managed shells and local tooling.
