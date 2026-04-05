from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import errno
import json
import os
import socket
import sys
import time
from typing import TextIO

TOP_LEVEL_HELP = """usage: xmux [-h] <command> ...

Commands:
  event  Send to or display the xmux JSON-RPC event port
  log    Append to or display the xmux log
"""

LOG_HELP = """usage:
  xmux log add [--] <data>
  xmux log show [--once]
  xmux log <data>
"""

EVENT_HELP = """usage:
  xmux event send [--id <id> | --notify] [--param <key=value>]... [--] <method> [params-json]
  xmux event send
  xmux event show [--once]
"""

AUTO_REQUEST_ID = object()
RETRYABLE_EVENT_CONNECT_ERRNOS = {
    errno.ENOENT,
    errno.ECONNREFUSED,
    errno.ENOTSOCK,
}


class UsageError(ValueError):
    pass


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in {"-h", "--help", "help"}:
        print(TOP_LEVEL_HELP)
        return 0

    command = args[0]
    if command == "event":
        return run_event(args[1:])
    if command == "log":
        return run_log(args[1:])

    print(f"xmux: unknown command: {command}", file=sys.stderr)
    print(TOP_LEVEL_HELP, file=sys.stderr)
    return 2


def run_event(args: list[str]) -> int:
    if not args or args[0] in {"-h", "--help", "help"}:
        print(EVENT_HELP)
        return 0

    subcommand = args[0]
    if subcommand == "send":
        send_args = args[1:]
        if send_args and send_args[0] in {"-h", "--help", "help"}:
            print(EVENT_HELP)
            return 0
        try:
            payload = parse_event_send_payload(send_args)
        except UsageError as exc:
            print(f"xmux event send: {exc}", file=sys.stderr)
            print(EVENT_HELP, file=sys.stderr)
            return 2
        return send_event(resolve_port_path(), payload)

    if subcommand == "show":
        show_args = args[1:]
        if show_args and show_args[0] in {"-h", "--help", "help"}:
            print(EVENT_HELP)
            return 0

        once = False
        if show_args == ["--once"]:
            once = True
        elif show_args:
            print("xmux event show: unexpected arguments", file=sys.stderr)
            print(EVENT_HELP, file=sys.stderr)
            return 2

        return show_events(resolve_port_path(), once=once)

    print(f"xmux event: unknown subcommand: {subcommand}", file=sys.stderr)
    print(EVENT_HELP, file=sys.stderr)
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


def resolve_port_path() -> Path:
    env_path = os.environ.get("XMUX_PORT")
    if env_path:
        return Path(env_path).expanduser()
    return Path.home() / ".xmux" / "xmux.port"


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


def parse_event_send_payload(args: list[str]) -> str:
    notify = False
    request_id: object = AUTO_REQUEST_ID
    named_params: dict[str, str] = {}
    positionals: list[str] = []
    index = 0

    while index < len(args):
        arg = args[index]
        if arg == "--":
            positionals.extend(args[index + 1 :])
            break
        if arg == "--notify":
            if request_id is not AUTO_REQUEST_ID:
                raise UsageError("cannot combine --notify with --id")
            notify = True
            index += 1
            continue
        if arg == "--id":
            if notify:
                raise UsageError("cannot combine --id with --notify")
            if index + 1 >= len(args):
                raise UsageError("missing value for --id")
            request_id = parse_request_id(args[index + 1])
            index += 2
            continue
        if arg == "--param":
            if index + 1 >= len(args):
                raise UsageError("missing value for --param")
            key, value = parse_named_param(args[index + 1])
            named_params[key] = value
            index += 2
            continue

        positionals.extend(args[index:])
        break

    if not positionals:
        payload = read_stdin_payload()
        if not payload.strip():
            raise UsageError("missing JSON payload")
        return parse_raw_event_payload(payload)

    if len(positionals) > 2:
        raise UsageError("unexpected arguments")

    method = positionals[0]
    request: dict[str, object] = {
        "jsonrpc": "2.0",
        "method": method,
    }

    if len(positionals) == 2:
        if named_params:
            raise UsageError("cannot combine --param with params JSON")
        request["params"] = parse_event_params(positionals[1])
    elif named_params:
        request["params"] = named_params

    if not notify:
        request["id"] = default_request_id() if request_id is AUTO_REQUEST_ID else request_id

    return json.dumps(request, separators=(",", ":"))


def parse_named_param(raw_value: str) -> tuple[str, str]:
    key, separator, value = raw_value.partition("=")
    if separator != "=" or not key:
        raise UsageError("named params must use key=value syntax")
    return key, value


def parse_request_id(raw_value: str) -> object:
    try:
        parsed = json.loads(raw_value)
    except json.JSONDecodeError:
        return raw_value

    if parsed is None or isinstance(parsed, str | int | float):
        return parsed

    raise UsageError("id must be a JSON string, number, or null")


def parse_event_params(raw_value: str) -> object:
    try:
        parsed = json.loads(raw_value)
    except json.JSONDecodeError as exc:
        raise UsageError(f"invalid params JSON: {exc.msg}") from exc

    if not isinstance(parsed, dict | list):
        raise UsageError("params must decode to a JSON object or array")

    return parsed


def parse_raw_event_payload(payload: str) -> str:
    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise UsageError(f"invalid JSON payload: {exc.msg}") from exc

    if not isinstance(parsed, dict | list):
        raise UsageError("payload must decode to a JSON object or batch array")

    return json.dumps(parsed, separators=(",", ":"))


def default_request_id() -> str:
    return f"xmux-{int(time.time() * 1000)}"


def send_event(port_path: Path, payload: str) -> int:
    try:
        with connect_event_socket(port_path, wait=False) as client:
            client.sendall(payload.encode("utf-8") + b"\n")
    except OSError as exc:
        print(f"xmux event send: {exc}", file=sys.stderr)
        return 1

    return 0


def show_events(port_path: Path, *, once: bool) -> int:
    try:
        while True:
            with connect_event_socket(port_path, wait=True) as client:
                with client.makefile("r", encoding="utf-8") as handle:
                    if stream_event_lines(handle, once=once):
                        return 0

            if not once:
                time.sleep(0.1)
    except OSError as exc:
        print(f"xmux event show: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0


def connect_event_socket(port_path: Path, *, wait: bool) -> socket.socket:
    while True:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.connect(os.fspath(port_path))
            return client
        except OSError as exc:
            client.close()
            if wait and should_retry_event_connect(exc):
                time.sleep(0.1)
                continue
            raise


def should_retry_event_connect(exc: OSError) -> bool:
    return exc.errno in RETRYABLE_EVENT_CONNECT_ERRNOS


def stream_event_lines(handle: TextIO, *, once: bool) -> bool:
    while True:
        line = handle.readline()
        if not line:
            return False

        sys.stdout.write(line)
        sys.stdout.flush()

        if once:
            return True


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
