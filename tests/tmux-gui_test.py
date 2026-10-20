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

    def attach(mode, notice, width=80, status=True, details="", reopen=False):
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, width, 0, 0))
            os.execvpe(
                "bash",
                ["bash", str(ROOT / "bin/lib/mycodex-tmux.sh"), "review", mode, notice,
                 details, "1" if reopen else "0"],
                env,
            )
        children.append((pid, fd))
        if details or reopen:
            return fd
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
        tmux("detach-client", "-s", "=review")

        # Long reports survive alternate-screen apps and remain available after
        # dismissal. Shell and tmux syntax inside messages must stay literal.
        details = "Codex 0.160.0 is available\n" + "\n".join(
            f"Detail {i}: information that must remain readable" for i in range(40)
        ) + "\nEND_OF_REPORT $(touch /tmp/mycodex-notice-injection) #{pane_id}"
        spectator = attach("none", "Another attached client", status=False)
        report = attach("none", "GUI access disabled (headless)", details=details)
        read_until(report, b"Codex 0.160.0 is available")
        spectator_output = b""
        while select.select([spectator], [], [], 0.1)[0]:
            spectator_output += os.read(spectator, 65536)
        assert b"Codex 0.160.0 is available" not in spectator_output
        os.write(report, b"G")
        read_until(report, b"END_OF_REPORT")
        assert tmux("show-options", "-qv", "-t", "review", "@mycodex-notices").startswith(
            "GUI access disabled (headless)\n\n" + details
        )
        assert not Path("/tmp/mycodex-notice-injection").exists()
        os.write(report, b"q")
        read_until(report, b"ACTIVE_APPLICATION")
        tmux("detach-client", "-s", "=review")
        report = attach("none", "GUI access disabled (headless)", reopen=True, width=40)
        read_until(report, b"Codex 0.160.0 is available")
        os.write(report, b"q")
        assert "ACTIVE_APPLICATION" in tmux("capture-pane", "-p", "-t", pane)
        print("PASS: tmux GUI badges, persistent scrollable reports, reattach, clients, and narrow terminals")

        # Emulate a terminal answering primary device-attribute queries. Holding
        # the popup beyond tmux's five-second startup timeout must not postpone
        # those queries until dismissal and leak the reply into shell input.
        tmux("detach-client", "-s", "=review")
        prompt = "MYCODEX_TEST_PROMPT>"
        tmux("respawn-pane", "-k", "-t", pane,
             f"env PS1='{prompt} ' INPUTRC=/dev/null bash --noprofile --norc -i")
        for reopen in (False, True):
            report = attach("none", "GUI access disabled (headless)",
                            details="TERMINAL_HANDSHAKE_NOTICE" if not reopen else "",
                            reopen=reopen)
            output = b""
            replies = 0
            first_reply_at = visible_at = closed_at = None
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                if select.select([report], [], [], 0.05)[0]:
                    output += os.read(report, 65536)
                # Count in the accumulated stream so split escape sequences
                # still receive exactly one immediate response each.
                while replies < output.count(b"\x1b[c"):
                    os.write(report, b"\x1b[?62;1;4c")
                    replies += 1
                    if first_reply_at is None:
                        first_reply_at = time.monotonic()
                now = time.monotonic()
                if visible_at is None and b"TERMINAL_HANDSHAKE_NOTICE" in output:
                    visible_at = now
                if visible_at is not None and closed_at is None and now - visible_at >= 6:
                    os.write(report, b"q")
                    closed_at = now
                if closed_at is not None and now - closed_at >= 1:
                    break
            assert closed_at is not None, f"Popup did not render: {output!r}"
            contents = tmux("capture-pane", "-p", "-t", pane).rstrip()
            assert contents == prompt, f"Popup leaked input into the shell: {contents!r}"
            assert first_reply_at is not None and first_reply_at < closed_at, (
                "Terminal identification waited for popup dismissal"
            )
            tmux("detach-client", "-s", "=review")
        print("PASS: startup and reopened notices preserve terminal handshake and clean shell input")
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
