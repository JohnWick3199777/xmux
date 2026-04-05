from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import os
import sys
import time

TOP_LEVEL_HELP = """usage: xmux [-h] <command> ...

Commands:
  log    Append to or display the xmux log
"""

LOG_HELP = """usage:
  xmux log add [--] <data>
  xmux log show [--once]
  xmux log <data>
"""


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in {"-h", "--help", "help"}:
        print(TOP_LEVEL_HELP)
        return 0

    command = args[0]
    if command == "log":
        return run_log(args[1:])

    print(f"xmux: unknown command: {command}", file=sys.stderr)
    print(TOP_LEVEL_HELP, file=sys.stderr)
    return 2


def run_log(args: list[str]) -> int:
    if not args or args[0] in {"-h", "--help", "help"}:
        print(LOG_HELP)
        return 0

    subcommand = args[0]
    if subcommand == "show":
        follow = True
        show_args = args[1:]
        if show_args and show_args[0] in {"-h", "--help", "help"}:
            print(LOG_HELP)
            return 0
        if show_args == ["--once"]:
            follow = False
        elif show_args:
            print("xmux log show: unexpected arguments", file=sys.stderr)
            print(LOG_HELP, file=sys.stderr)
            return 2
        return show_log(resolve_log_path(), follow=follow)

    payload_args = args[1:] if subcommand == "add" else args
    if payload_args and payload_args[0] == "--":
        payload_args = payload_args[1:]

    payload = " ".join(payload_args)
    if not payload:
        payload = read_stdin_payload()

    if not payload:
        print("xmux log add: missing log data", file=sys.stderr)
        print(LOG_HELP, file=sys.stderr)
        return 2

    return add_log(resolve_log_path(), payload)


def resolve_log_path() -> Path:
    env_path = os.environ.get("XMUX_LOG")
    if env_path:
        return Path(env_path).expanduser()
    return Path.home() / ".xmux" / "xmux.log"


def add_log(log_path: Path, payload: str) -> int:
    line = f"{timestamp_utc()}\t{normalize_payload(payload)}\n"
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(line)
    except OSError:
        # Logging must never break shell hooks or wrapper scripts.
        return 0
    return 0


def show_log(log_path: Path, *, follow: bool) -> int:
    try:
        if follow:
            wait_for_log(log_path)

        if not log_path.exists():
            return 0

        with log_path.open("r", encoding="utf-8") as handle:
            stream_log(handle, follow=follow)
    except OSError as exc:
        print(f"xmux log show: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0
    return 0


def read_stdin_payload() -> str:
    if sys.stdin.isatty():
        return ""
    return sys.stdin.read()


def timestamp_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_payload(payload: str) -> str:
    normalized = payload.replace("\r\n", "\n").replace("\r", "\n")
    return normalized.replace("\n", "\\n")


def wait_for_log(log_path: Path) -> None:
    while not log_path.exists():
        time.sleep(0.1)


def stream_log(handle: object, *, follow: bool) -> None:
    while True:
        chunk = handle.read()
        if chunk:
            sys.stdout.write(chunk)
            sys.stdout.flush()

        if not follow:
            return

        time.sleep(0.1)
