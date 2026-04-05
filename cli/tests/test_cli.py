from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
import sys
import threading
import time
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from xmux_cli import cli, main


class FakeEventSocket:
    def __init__(self, *, read_data: str = "") -> None:
        self.read_data = read_data
        self.sent: list[bytes] = []

    def __enter__(self) -> FakeEventSocket:
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> bool:
        return False

    def sendall(self, data: bytes) -> None:
        self.sent.append(data)

    def makefile(self, mode: str, encoding: str | None = None) -> io.StringIO:
        return io.StringIO(self.read_data)


class XmuxCliTests(unittest.TestCase):
    def test_log_add_appends_timestamped_record(self) -> None:
        with TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "xmux.log"

            with patch.dict(os.environ, {"XMUX_LOG": str(log_path)}):
                exit_code = main(["log", "add", "git status"])

            self.assertEqual(exit_code, 0)
            timestamp, payload = log_path.read_text(encoding="utf-8").strip().split("\t", 1)
            self.assertRegex(timestamp, r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
            self.assertEqual(payload, "git status")

    def test_log_alias_without_add_is_supported(self) -> None:
        with TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "xmux.log"

            with patch.dict(os.environ, {"XMUX_LOG": str(log_path)}):
                exit_code = main(["log", "claude_init"])

            self.assertEqual(exit_code, 0)
            self.assertTrue(log_path.read_text(encoding="utf-8").strip().endswith("\tclaude_init"))

    def test_log_show_prints_existing_contents(self) -> None:
        with TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "xmux.log"
            log_path.write_text("2026-04-05T10:00:00Z\tgit status\n", encoding="utf-8")
            stdout = io.StringIO()
            stderr = io.StringIO()

            with patch.dict(os.environ, {"XMUX_LOG": str(log_path)}):
                with redirect_stdout(stdout), redirect_stderr(stderr):
                    exit_code = main(["log", "show", "--once"])

            self.assertEqual(exit_code, 0)
            self.assertEqual(stdout.getvalue(), "2026-04-05T10:00:00Z\tgit status\n")
            self.assertEqual(stderr.getvalue(), "")

    def test_log_show_help_is_supported(self) -> None:
        stdout = io.StringIO()
        stderr = io.StringIO()

        with redirect_stdout(stdout), redirect_stderr(stderr):
            exit_code = main(["log", "show", "--help"])

        self.assertEqual(exit_code, 0)
        self.assertIn("xmux log show [--once]", stdout.getvalue())
        self.assertEqual(stderr.getvalue(), "")

    def test_log_show_follows_new_lines(self) -> None:
        with TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "xmux.log"
            log_path.write_text("2026-04-05T10:00:00Z\tseed\n", encoding="utf-8")
            stdout = io.StringIO()
            stderr = io.StringIO()
            result: list[int] = []

            def run_show() -> None:
                with patch.dict(os.environ, {"XMUX_LOG": str(log_path)}):
                    with redirect_stdout(stdout), redirect_stderr(stderr):
                        result.append(main(["log", "show"]))

            thread = threading.Thread(target=run_show)
            thread.start()

            deadline = time.time() + 2
            while "seed" not in stdout.getvalue():
                if time.time() >= deadline:
                    self.fail("xmux log show did not print existing content")
                time.sleep(0.01)

            with log_path.open("a", encoding="utf-8") as handle:
                handle.write("2026-04-05T10:00:01Z\tfollow-up\n")

            deadline = time.time() + 2
            while "follow-up" not in stdout.getvalue():
                if time.time() >= deadline:
                    self.fail("xmux log show did not stream appended content")
                time.sleep(0.01)

            with patch.object(cli.time, "sleep", side_effect=KeyboardInterrupt):
                thread.join(timeout=2)

            self.assertFalse(thread.is_alive())
            self.assertEqual(result, [0])
            self.assertEqual(stderr.getvalue(), "")

    def test_log_add_preserves_tabs_in_payload(self) -> None:
        with TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "xmux.log"

            with patch.dict(os.environ, {"XMUX_LOG": str(log_path)}):
                exit_code = main(["log", "add", "claude.command\tclaude --print"])

            self.assertEqual(exit_code, 0)
            self.assertTrue(
                log_path.read_text(encoding="utf-8").strip().endswith("\tclaude.command\tclaude --print")
            )

    def test_log_add_reads_stdin_when_no_payload_args(self) -> None:
        with TemporaryDirectory() as tmpdir:
            log_path = Path(tmpdir) / "xmux.log"
            stdin = io.StringIO('{"event":"claude"}\n{"event":"done"}')
            stdin.isatty = lambda: False  # type: ignore[assignment]

            with patch.dict(os.environ, {"XMUX_LOG": str(log_path)}):
                with patch.object(sys, "stdin", stdin):
                    exit_code = main(["log", "add"])

            self.assertEqual(exit_code, 0)
            self.assertTrue(
                log_path.read_text(encoding="utf-8").strip().endswith('\t{"event":"claude"}\\n{"event":"done"}')
            )

    def test_event_send_writes_notification_to_socket(self) -> None:
        with TemporaryDirectory() as tmpdir:
            port_path = Path(tmpdir) / "xmux.port"
            fake_socket = FakeEventSocket()

            with patch.dict(os.environ, {"XMUX_PORT": str(port_path)}):
                with patch.object(cli, "connect_event_socket", return_value=fake_socket) as mock_connect:
                    exit_code = main(["event", "send", "--notify", "pane.focus", '{"pane":"left"}'])

            self.assertEqual(exit_code, 0)
            mock_connect.assert_called_once_with(port_path, wait=False)
            self.assertEqual(
                json.loads(fake_socket.sent[0].decode("utf-8")),
                {
                    "jsonrpc": "2.0",
                    "method": "pane.focus",
                    "params": {"pane": "left"},
                },
            )

    def test_event_send_reads_raw_json_payload_from_stdin(self) -> None:
        with TemporaryDirectory() as tmpdir:
            port_path = Path(tmpdir) / "xmux.port"
            fake_socket = FakeEventSocket()
            stdin = io.StringIO('{"jsonrpc":"2.0","method":"ping","id":1}')
            stdin.isatty = lambda: False  # type: ignore[assignment]

            with patch.dict(os.environ, {"XMUX_PORT": str(port_path)}):
                with patch.object(sys, "stdin", stdin):
                    with patch.object(cli, "connect_event_socket", return_value=fake_socket) as mock_connect:
                        exit_code = main(["event", "send"])

            self.assertEqual(exit_code, 0)
            mock_connect.assert_called_once_with(port_path, wait=False)
            self.assertEqual(
                json.loads(fake_socket.sent[0].decode("utf-8")),
                {
                    "jsonrpc": "2.0",
                    "method": "ping",
                    "id": 1,
                },
            )

    def test_event_send_builds_named_params_object(self) -> None:
        with TemporaryDirectory() as tmpdir:
            port_path = Path(tmpdir) / "xmux.port"
            fake_socket = FakeEventSocket()

            with patch.dict(os.environ, {"XMUX_PORT": str(port_path)}):
                with patch.object(cli, "connect_event_socket", return_value=fake_socket) as mock_connect:
                    exit_code = main(
                        [
                            "event",
                            "send",
                            "--notify",
                            "--param",
                            "command=git status",
                            "--param",
                            "terminal_id=abc123",
                            "command.start",
                        ]
                    )

            self.assertEqual(exit_code, 0)
            mock_connect.assert_called_once_with(port_path, wait=False)
            self.assertEqual(
                json.loads(fake_socket.sent[0].decode("utf-8")),
                {
                    "jsonrpc": "2.0",
                    "method": "command.start",
                    "params": {
                        "command": "git status",
                        "terminal_id": "abc123",
                    },
                },
            )

    def test_event_show_prints_first_message_with_once(self) -> None:
        with TemporaryDirectory() as tmpdir:
            port_path = Path(tmpdir) / "xmux.port"
            stdout = io.StringIO()
            stderr = io.StringIO()
            fake_socket = FakeEventSocket(read_data='{"jsonrpc":"2.0","method":"tick"}\n')

            with patch.dict(os.environ, {"XMUX_PORT": str(port_path)}):
                with patch.object(cli, "connect_event_socket", return_value=fake_socket) as mock_connect:
                    with redirect_stdout(stdout), redirect_stderr(stderr):
                        exit_code = main(["event", "show", "--once"])

            self.assertEqual(exit_code, 0)
            mock_connect.assert_called_once_with(port_path, wait=True)
            self.assertEqual(stdout.getvalue(), '{"jsonrpc":"2.0","method":"tick"}\n')
            self.assertEqual(stderr.getvalue(), "")

    def test_event_send_rejects_scalar_params(self) -> None:
        stderr = io.StringIO()

        with redirect_stderr(stderr):
            exit_code = main(["event", "send", "--notify", "pane.focus", "1"])

        self.assertEqual(exit_code, 2)
        self.assertIn("params must decode to a JSON object or array", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
