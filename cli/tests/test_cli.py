from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import os
import sys
import threading
import time
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from xmux_cli import cli, main


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


if __name__ == "__main__":
    unittest.main()
