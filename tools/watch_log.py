#!/usr/bin/env python3
"""Live viewer for ~/.xmux/xmux.log — prints new lines as they are appended."""

import os
import sys
import time

LOG_PATH = os.path.expanduser("~/.xmux/xmux.log")


def wait_for_file(path: str) -> None:
    if not os.path.exists(path):
        print(f"Waiting for {path} to appear...", flush=True)
        while not os.path.exists(path):
            time.sleep(0.5)
    print(f"Tailing {path}\n", flush=True)


def tail(path: str) -> None:
    with open(path, "r") as f:
        f.seek(0, os.SEEK_END)  # start at end, only show new lines
        while True:
            line = f.readline()
            if line:
                print(line, end="", flush=True)
            else:
                time.sleep(0.1)


if __name__ == "__main__":
    try:
        wait_for_file(LOG_PATH)
        tail(LOG_PATH)
    except KeyboardInterrupt:
        sys.exit(0)
