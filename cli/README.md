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
```

`xmux log <data>` is also supported as a shorthand for `xmux log add <data>`.

`xmux log show` prints the current log and keeps following new lines until interrupted. Use `xmux log show --once` for a snapshot.
