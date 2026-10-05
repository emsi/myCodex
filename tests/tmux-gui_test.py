#!/usr/bin/env python3
"""Exercise the actual attach UI on an isolated tmux server and real PTYs."""

import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time


ROOT = Path(__file__).resolve().parents[1]
TMUX = shutil.which("tmux")
assert TMUX, "tmux is required for the attach UI test"


def read_until(fd, needle, timeout=5):
    output = b""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                output += os.read(fd, 65536)
            except OSError as error:
                raise AssertionError(f"Terminal exited before {needle!r}: {output!r}") from error
            if needle in output:
                return output
    raise AssertionError(f"Did not render {needle!r}: {output!r}")


with tempfile.TemporaryDirectory(prefix="mycodex-tmux-test.") as directory:
    temp = Path(directory)
    socket = str(temp / "server")
    env = dict(os.environ, TERM="xterm-256color", HISTFILE="/dev/null")
    env.pop("TMUX", None)
    env.pop("TMUX_PANE", None)
    # Only this private server is ever addressed, including by the helper.
    (temp / "tmux").write_text(
        '#!/bin/sh\nexec "$MYCODEX_TEST_TMUX" -S "$MYCODEX_TEST_SOCKET" "$@"\n'
    )
    (temp / "tmux").chmod(0o755)
    env.update(
        PATH=f"{temp}:{env['PATH']}",
        MYCODEX_TEST_TMUX=TMUX,
        MYCODEX_TEST_SOCKET=socket,
    )

    def tmux(*args):
        return subprocess.check_output(
            [TMUX, "-S", socket, *args], env=env, text=True
        ).rstrip("\n")

    children = []

    def attach(mode, notice, width=80, status=True):
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, width, 0, 0))
            os.execvpe(
                "bash",
                ["bash", str(ROOT / "bin/lib/mycodex-tmux.sh"), "review", mode, notice],
                env,
            )
        children.append((pid, fd))
        read_until(fd, notice.encode())
        os.write(fd, b"\x1b")  # Dismiss tmux's message, without typing a command.
        badge = {"wayland": b"GUI:WL", "x11": b"GUI:X11", "none": b"GUI:off"}[mode]
        if status:
            read_until(fd, badge)
        return fd

    try:
        tmux("-f", "/dev/null", "new-session", "-d", "-s", "review", "-x", "80", "-y", "24",
             "printf '\\033[?1049h\\033[2JACTIVE_APPLICATION\\n'; exec cat")
        tmux("new-session", "-d", "-s", "other", "exec cat")
        # Keep a dynamic Byobu-style status command, and its global sizing.
        original = '#(printf Byobu) [#S] '
        tmux("set-option", "-g", "status-left", original)
        tmux("set-option", "-g", "status-left-length", "256")
        tmux("set-option", "-g", "status-right", "")
        tmux("set-option", "-g", "status-interval", "1")
        pane = tmux("display-message", "-p", "-t", "=review", "#{pane_id}")

        first = attach("wayland", "GUI access enabled: Wayland")
        left = tmux("show-options", "-Av", "-t", "review", "status-left")
        assert left == '#{@mycodex-gui} ' + original, left
        assert tmux("show-options", "-Av", "-t", "other", "status-left") == original

        # Byobu adjusts these global widths after a resize. Keep the badge
        # visible without pinning or replacing the user's status layout.
        tmux("set-option", "-g", "status-left-length", "10")
        while select.select([first], [], [], 0.1)[0]:
            os.read(first, 65536)
        attach("wayland", "Wayland access on reattach", width=40)
        other_client_output = b""
        while select.select([first], [], [], 0.1)[0]:
            other_client_output += os.read(first, 65536)
        assert b"Wayland access on reattach" not in other_client_output
        assert tmux("show-options", "-Av", "-t", "review", "status-left") == left
        tmux("refresh-client", "-S")
        assert "ACTIVE_APPLICATION" in tmux("capture-pane", "-p", "-t", pane)

        tmux("detach-client", "-s", "=review")
        attach("x11", "GUI access enabled: X11")
        tmux("detach-client", "-s", "=review")
        attach("none", "GUI access disabled (headless)")
        assert tmux("show-options", "-Av", "-t", "review", "status-left") == left
        assert tmux("display-message", "-p", "-t", "=review", "#{pane_id}") == pane
        tmux("detach-client", "-s", "=review")
        tmux("set-option", "-t", "review", "status", "off")
        attach("wayland", "GUI access enabled: Wayland", status=False)
        print("PASS: real tmux attach notices, persistent badges, reattach, clients, and narrow terminals")
    finally:
        subprocess.run([TMUX, "-S", socket, "kill-server"], env=env, capture_output=True)
        for pid, fd in children:
            os.close(fd)
            # tmux normally exits when its server closes; bound cleanup on failure.
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
