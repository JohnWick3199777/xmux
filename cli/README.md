# xmux CLI

This directory contains the standalone Python CLI consumed by xmux-managed shell environments.

Install it locally with `uv tool install ./cli`.

For active development, use `uv tool install --editable ./cli` so changes in this directory are picked up without reinstalling.

## Commands

```bash
uv tool install ./cli
xmux log add "git status"
xmux log show
xmux log show --once
xmux event send --notify --param "command=git status" command.start
xmux event show
xmux event show --once
```

`xmux log <data>` is also supported as a shorthand for `xmux log add <data>`.

`xmux log show` prints the current log and keeps following new lines until interrupted. Use `xmux log show --once` for a snapshot.

`xmux event send` writes newline-delimited JSON-RPC messages to `XMUX_PORT` (or `~/.xmux/xmux.port` by default). Use `--param key=value` for shell-safe string params or pass raw JSON on stdin.

`xmux event show` connects to `xmux.port` and prints live events until interrupted. Use `--once` to print the first event and exit.
