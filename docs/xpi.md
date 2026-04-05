# xpi

`xpi` is the xmux-friendly pi launcher in this repo.

It keeps the stock `pi` interactive TUI, but injects a passive extension that taps every currently subscribable pi extension hook and mirrors those events to:

- a local JSONL tap file
- `xmux.port` as JSON-RPC notifications when `XMUX_PORT` is available

## Files

- `./xpi` — local launcher
- `Resources/xmux/bin/xpi` — xmux shell launcher
- `./pi-event-tap-extension.ts` — passive event tap / forwarder

## What it captures

The tap subscribes to all currently documented extension events that are safe to observe passively:

- `resources_discover`
- `session_start`
- `session_before_switch`
- `session_before_fork`
- `session_before_compact`
- `session_compact`
- `session_before_tree`
- `session_tree`
- `session_shutdown`
- `before_agent_start`
- `agent_start`
- `agent_end`
- `turn_start`
- `turn_end`
- `message_start`
- `message_update`
- `message_end`
- `tool_execution_start`
- `tool_execution_update`
- `tool_execution_end`
- `context`
- `before_provider_request`
- `model_select`
- `tool_call`
- `tool_result`
- `user_bash`
- `input`

These are passive observers only. The extension does not block or rewrite tool calls, context, prompts, or provider payloads.

## Usage

```bash
./xpi
./xpi -c
./xpi --model sonnet:high
xpi
```

## Environment

### Event file

`xpi` writes JSONL events to `PI_TAP_EVENTS_FILE`.

You can also use `XPI_EVENTS_FILE` as a friendly alias.

```bash
XPI_EVENTS_FILE=/tmp/xpi.jsonl ./xpi
```

If no path is provided, `xpi` creates one under `/tmp`.

By default the file is truncated on start. To append instead:

```bash
PI_TAP_EVENTS_APPEND=1 ./xpi
```

### xmux forwarding

If `XMUX_PORT` is set, the extension also forwards each tapped event as a JSON-RPC notification:

```json
{
  "jsonrpc": "2.0",
  "method": "pi.message_update",
  "params": {
    "terminal_id": "...",
    "pid": 12345,
    "session_file": "...",
    "session_name": null,
    "cwd": "...",
    "event": { ... }
  }
}
```

Disable socket forwarding while keeping the file tap:

```bash
PI_TAP_FORWARD_TO_XMUX=0 ./xpi
```

## Notes

- This gets you stock pi TUI plus a broad lifecycle/event tap.
- It does **not** expose raw RPC commands/responses; it captures the extension-observable runtime events.
- There is no subscribeable `extension_error` hook inside an extension, so that event cannot be self-tapped from this layer.
