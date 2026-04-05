# Pi Lifecycle in xmux

This document describes the `pi.*` events forwarded into `xmux.port`, the payload shape, and the recommended mapping for the Sessions panel.

## Forwarded event envelope

When `pi` is launched from an xmux-managed shell, the bundled wrapper injects the xmux forwarding extension.
Every forwarded event arrives as a JSON-RPC notification:

```json
{
  "jsonrpc": "2.0",
  "method": "pi.<event-name>",
  "params": {
    "terminal_id": "<xmux-terminal-uuid>",
    "pid": 12345,
    "session_file": "/Users/me/.pi/agent/sessions/.../<timestamp>_<session-id>.jsonl",
    "event": {
      "type": "<pi-event-type>",
      "...": "event-specific fields"
    }
  }
}
```

Important fields:

- `params.terminal_id`: xmux terminal UUID. Use this to associate pi activity with a terminal/session card.
- `params.pid`: process id of the running `pi` process.
- `params.session_file`: current pi session file path when available.
- `params.event`: the actual pi extension event payload.

## Session identity

For UI purposes, xmux derives a short pi session id from `params.session_file`.

Pi session files look like:

```text
~/.pi/agent/sessions/--<path>--/<timestamp>_<session-id>.jsonl
```

Example:

```text
/Users/me/.pi/agent/sessions/--Users-me-project--/2025-01-02T03-04-05.678Z_6f3a9d2c-....jsonl
```

Recommended extraction rule:

1. take the filename without `.jsonl`
2. split at the last `_`
3. use the suffix as the pi session id

For compact UI display, xmux shows the first 8 characters:

```text
pi 6f3a9d2c
```

## Lifecycle overview

A typical prompt/response flow looks like this:

```text
pi.session_start
pi.before_agent_start
pi.agent_start
pi.message_start
pi.message_update ...
pi.turn_start
pi.tool_execution_start / update / end ...
pi.turn_end
pi.message_end
pi.agent_end
```

Additional session-management events may also appear:

- `pi.session_before_switch`
- `pi.session_before_fork`
- `pi.session_before_compact`
- `pi.session_compact`
- `pi.session_before_tree`
- `pi.session_tree`
- `pi.session_shutdown`
- `pi.model_select`

Note: in real event streams, `pi.session_shutdown` is not guaranteed to be the final pi event.
Trailing notifications such as `pi.message_end`, `pi.turn_end`, or `pi.agent_end` may still arrive afterward.
Consumers should treat `pi.session_shutdown` as authoritative for clearing session state and ignore any trailing finalizers until a new `pi.session_start` / `pi.before_agent_start` / `pi.agent_start` occurs.

## Recommended Sessions panel status mapping

For the high-level session card state, xmux uses agent lifecycle events as the primary source of truth.
This is more stable than trying to infer status from message or tool events alone.

### Primary rule

- set status to **working** on:
  - `pi.before_agent_start`
  - `pi.agent_start`
- set status to **idle** on:
  - `pi.turn_end`
  - `pi.agent_end`
- clear pi status/session metadata on:
  - `pi.session_shutdown`

### Secondary rule

Other lifecycle events can refine display, but should not override an active in-flight agent run:

- if an agent is already running, keep status as **working** during:
  - `pi.turn_start`
  - `pi.message_start`
  - `pi.message_update`
  - `pi.tool_execution_start`
  - `pi.tool_execution_update`
  - `pi.turn_end`
  - `pi.message_end`
  - `pi.tool_execution_end`
- when no agent is running, treat these as **idle** indicators:
  - `pi.session_start`
  - `pi.session_before_switch`
  - `pi.session_before_fork`
  - `pi.session_before_compact`
  - `pi.session_compact`
  - `pi.session_before_tree`
  - `pi.session_tree`
  - `pi.model_select`

## Why xmux uses `turn_end` for idle

For xmux's sessions UI, the most useful signal is when the current response turn is done.
That means the card should stop looking busy as soon as the turn completes, even if pi later emits trailing lifecycle cleanup.

Important caveats:

- `message_end` can happen before the overall turn is finished
- `tool_execution_end` can happen while more tools or additional model output are still pending
- `agent_end` may arrive later than the moment the user expects the session to look idle

Because of that, xmux treats:

- **working** while a turn is active
- **idle** at `pi.turn_end`
- **none** at `pi.session_shutdown`

`pi.agent_end` is still accepted as an idle signal, but it is no longer the only one.

## Event payload notes

The forwarded `params.event` payload mirrors pi's extension event types.
Useful fields include:

### `pi.session_start`

```json
{
  "type": "session_start",
  "reason": "startup | reload | new | resume | fork",
  "previousSessionFile": "optional"
}
```

### `pi.before_agent_start`

```json
{
  "type": "before_agent_start",
  "prompt": "user prompt",
  "images": [],
  "systemPrompt": "resolved system prompt"
}
```

### `pi.agent_end`

```json
{
  "type": "agent_end",
  "messages": []
}
```

### `pi.turn_start`

```json
{
  "type": "turn_start",
  "turnIndex": 0,
  "timestamp": 1234567890
}
```

### `pi.message_update`

```json
{
  "type": "message_update",
  "message": { "role": "assistant" },
  "assistantMessageEvent": {
    "type": "text_delta"
  }
}
```

`assistantMessageEvent.type` can be one of:

- `start`
- `text_start`, `text_delta`, `text_end`
- `thinking_start`, `thinking_delta`, `thinking_end`
- `toolcall_start`, `toolcall_delta`, `toolcall_end`
- `done`
- `error`

### `pi.tool_execution_start`

```json
{
  "type": "tool_execution_start",
  "toolCallId": "...",
  "toolName": "bash",
  "args": { "command": "ls -la" }
}
```

### `pi.tool_execution_end`

```json
{
  "type": "tool_execution_end",
  "toolCallId": "...",
  "toolName": "bash",
  "result": {},
  "isError": false
}
```

### `pi.model_select`

```json
{
  "type": "model_select",
  "model": { "provider": "...", "id": "..." },
  "previousModel": { "provider": "...", "id": "..." },
  "source": "set | cycle | restore"
}
```

## Sessions panel display

Current xmux card format:

```text
pi <short-session-id> · <idle|working>
```

Examples:

- `pi 6f3a9d2c · working`
- `pi 6f3a9d2c · idle`

If no pi session has been observed for a terminal, the pi line is omitted.
